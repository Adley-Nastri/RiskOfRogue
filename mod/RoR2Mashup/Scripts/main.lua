-- RoR2 Mashup for Deadzone: Rogue
-- Risk of Rain 2 items (offered in Deadzone's item orbs) and the RoR2 difficulty clock inside Deadzone runs.
-- Data (items, tiers, tuning) comes from data_gen.lua, generated from the design sheets.
-- The host runs all game logic; clients receive state over PlayerController:ClientMessage
-- and only draw the HUD (plus their own extra jumps).

local Data = require("data_gen")
local SYS = Data.SYS
local MOD = "ue4ss/Mods/RoR2Mashup/"
local TAG = "R2|"
local VIS, HID = 3, 1 -- ESlateVisibility HitTestInvisible / Collapsed
local fx, fx_at, can_take, patch_inventory, spawn_fx_local, draw_menu -- defined further down
local ShownCards = {} -- bundle keys whose RoR2 card this player can see

local function log(s) print("[RoR2Mashup] " .. tostring(s) .. "\n") end
local function valid(o) return o ~= nil and type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function addr(o) return valid(o) and o:GetAddress() or 0 end
local function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

---------------------------------------------------------------------------
-- scheduler (everything runs on the game thread from one LoopAsync tick)
---------------------------------------------------------------------------
local TICK_MS = 100
local now_ms = 0
local timers = {}
local function after(ms, fn) timers[#timers + 1] = { t = now_ms + ms, fn = fn } end
local function run_timers()
  local due = {}
  local keep = {}
  for _, t in ipairs(timers) do if t.t <= now_ms then due[#due + 1] = t else keep[#keep + 1] = t end end
  timers = keep
  for _, t in ipairs(due) do local ok, err = pcall(t.fn); if not ok then log("timer error: " .. tostring(err)) end end
end

---------------------------------------------------------------------------
-- game helpers
---------------------------------------------------------------------------
local CLS = {}
local function cls(path)
  local c = CLS[path]
  if not valid(c) then c = StaticFindObject(path); CLS[path] = c end
  return c
end
local function ge_paths(path)
  local nm = path:match("[^/]+$")
  return path .. "." .. nm .. "_C", path .. ".Default__" .. nm .. "_C"
end
local SUICIDE = "/Game/Abilities/Effects/GE_Suicide.GE_Suicide_C"
local GE_MAXHP_MULT = "/Game/Abilities/DeviceUpgrades/Attributes/GE_GenericAttribute_MaxHealth"
local GE_DMG_ADD = "/Game/Abilities/DeviceUpgrades/Attributes/GE_GlobalDamageModifier"
local GE_SPEED_MULT = "/Game/Abilities/DeviceUpgrades/Attributes/GE_MovementSpeed"

-- Apply one of the game's SetByCaller attribute effects with our own magnitude:
-- the effect's default object is switched to a fixed magnitude for the call, then restored.
local function apply_magnitude(char, path, mag)
  local cpath, dpath = ge_paths(path)
  local c, cdo = cls(cpath), cls(dpath)
  if not valid(c) or not valid(cdo) or not valid(char) then return nil end
  local asc = char.AbilitySystemComponent
  if not valid(asc) then return nil end
  local m = cdo.Modifiers[1]
  local mm = m.ModifierMagnitude
  local mt, sv, dp = mm.MagnitudeCalculationType, mm.ScalableFloatMagnitude.Value, cdo.DurationPolicy
  mm.MagnitudeCalculationType = 0
  mm.ScalableFloatMagnitude.Value = mag
  cdo.DurationPolicy = 1 -- infinite
  local ok, h = pcall(function() return asc:BP_ApplyGameplayEffectToSelf(c, 1.0, asc:MakeEffectContext()) end)
  mm.MagnitudeCalculationType = mt
  mm.ScalableFloatMagnitude.Value = sv
  cdo.DurationPolicy = dp
  if ok and h and h.Handle and h.Handle >= 0 then return h end
  return nil
end
local function remove_effect(char, h)
  if h and valid(char) and valid(char.AbilitySystemComponent) then
    pcall(function() char.AbilitySystemComponent:RemoveActiveGameplayEffect(h, -1) end)
  end
end

local function is_bot(c)
  if not valid(c) then return false end
  if c:IsPlayerControlled() then return false end
  local ok, pet = pcall(function() return c.bIsPet end)
  if ok and pet then return false end
  return true
end
local function alive(c) return valid(c) and c:GetHealth() > 0 end
local function loc(a) local l = a:K2_GetActorLocation(); return l.X, l.Y, l.Z end
local function dist(a, b)
  local ax, ay, az = loc(a); local bx, by, bz = loc(b)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end
local function all_bots()
  local out = {}
  for _, c in ipairs(FindAllOf("ValCharacter") or {}) do if is_bot(c) and alive(c) then out[#out + 1] = c end end
  return out
end
local function bots_near(center, radius, except)
  local out = {}
  for _, c in ipairs(all_bots()) do
    if addr(c) ~= addr(except) and dist(c, center) <= radius then out[#out + 1] = c end
  end
  return out
end

-- Damage that counts as the attacker's: partial hits lower health, lethal hits go through
-- the game's own execute effect so the kill, credit and encounter progress are real.
local function deal(attacker, bot, amount)
  if not alive(bot) or amount <= 0 then return false end
  local sc = rawget(_G, "R2_DMG_SCALE")
  if sc then local ok, v = pcall(sc, attacker, bot, amount); if ok and type(v) == "number" then amount = v end end
  local hp = bot:GetHealth()
  if amount >= hp then
    if valid(attacker) and valid(attacker.AbilitySystemComponent) and valid(bot.AbilitySystemComponent) then
      local asc = attacker.AbilitySystemComponent
      pcall(function() asc:BP_ApplyGameplayEffectToTarget(cls(SUICIDE), bot.AbilitySystemComponent, 1.0, asc:MakeEffectContext()) end)
      -- make sure the kill counts for on-kill items even if the damage event has no instigator
      local cb = rawget(_G, "R2_ON_KILL")
      if cb and attacker:IsPlayerControlled() then after(150, function() if valid(bot) and bot:GetHealth() <= 0 then cb(bot, attacker) end end) end
      return true
    end
    bot:SetHealth(1.0)
    return false
  end
  bot:SetHealth(hp - amount)
  return false
end

-- Deadzone's elemental system: element damage scaled by the attacker's own element upgrades,
-- plus the element's real status effect (Ignite, Shock) on the target.
local ATTRSET = {}
local function attr(char, name, default)
  if name == "none" or not valid(char) then return default end
  local a = addr(char)
  local set = ATTRSET[a]
  if not valid(set) then
    set = nil
    for _, s in ipairs(FindAllOf("ValAttributeSet") or {}) do
      if valid(s) and addr(s:GetOuter()) == a then set = s; break end
    end
    ATTRSET[a] = set
  end
  local v = default
  if set then pcall(function() v = set[name].CurrentValue end) end
  return v
end
local function element_damage(attacker, el, base)
  if not el then return base end
  local mult = 1 + attr(attacker, el.dmg_attr, 0) + attr(attacker, SYS.elem_all_attr, 0)
  return base * math.max(0, mult) * attr(attacker, SYS.elem_proc_attr, 1)
end
local StatusAt = {}
local function apply_status(attacker, bot, el, dur_override)
  if not el or el.status_ge == "none" or not alive(bot) or not valid(attacker) then return end
  local key = addr(bot) .. el.id
  if (StatusAt[key] or -1e9) + el.status_cooldown_ms > now_ms then return end
  StatusAt[key] = now_ms
  local cpath, dpath = ge_paths(el.status_ge)
  local c, cdo = cls(cpath), cls(dpath)
  if not valid(c) then pcall(function() LoadAsset(el.status_ge) end); c, cdo = cls(cpath), cls(dpath) end
  local src, dst = attacker.AbilitySystemComponent, bot.AbilitySystemComponent
  if not valid(c) or not valid(cdo) or not valid(src) or not valid(dst) then return end
  local potency = attr(attacker, SYS.elem_potency_attr, 1)
  local dur = (dur_override or el.duration_s) * attr(attacker, SYS.elem_duration_attr, 1) + attr(attacker, el.duration_attr, 0)
  local extra = attr(attacker, el.mag_attr, 0)
  local mag = (el.status_mag + (el.status_mag < 0 and -extra or extra)) * potency
  -- SetByCaller magnitudes can't be set from a mod, so the default object gets fixed values for this one call
  local saved = {}
  local dm = cdo.DurationMagnitude
  local dt, dv = dm.MagnitudeCalculationType, dm.ScalableFloatMagnitude.Value
  if dt == 3 or (dt == 0 and dv == 0) then dm.MagnitudeCalculationType = 0; dm.ScalableFloatMagnitude.Value = dur end
  local mods = cdo.Modifiers
  for i = 1, mods:GetArrayNum() do
    local mm = mods[i].ModifierMagnitude
    saved[i] = { mm.MagnitudeCalculationType, mm.ScalableFloatMagnitude.Value }
    if saved[i][1] == 3 then mm.MagnitudeCalculationType = 0; mm.ScalableFloatMagnitude.Value = mag end
  end
  pcall(function() src:BP_ApplyGameplayEffectToTarget(c, dst, 1.0, src:MakeEffectContext()) end)
  for i = 1, mods:GetArrayNum() do
    local mm = mods[i].ModifierMagnitude
    mm.MagnitudeCalculationType = saved[i][1]; mm.ScalableFloatMagnitude.Value = saved[i][2]
  end
  dm.MagnitudeCalculationType = dt; dm.ScalableFloatMagnitude.Value = dv
end
-- one elemental hit from an item: element-scaled damage plus the element's status
local function item_hit(attacker, bot, it, base)
  local el = Data.ELEMENT_BY_ID[it.element]
  if not alive(bot) then return end
  apply_status(attacker, bot, el)
  deal(attacker, bot, element_damage(attacker, el, base))
end

local function heal(pawn, amount)
  if not alive(pawn) or amount <= 0 then return end
  local hp, mx = pawn:GetHealth(), pawn:GetHealthMax()
  pawn:SetHealth(math.min(mx, hp + amount) * 1.0)
end

local function server()
  local gm = FindFirstOf("GameModeBase")
  return valid(gm), gm
end
local function in_hub(gm)
  return valid(gm) and gm:GetClass():GetFName():ToString():find("StartingShip") ~= nil
end
local function player_name(pc)
  local ps = pc.PlayerState
  if valid(ps) then
    local ok, n = pcall(function() return ps:GetPlayerName():ToString() end)
    if ok and n and n ~= "" then return n end
  end
  return "player"
end
local function local_pc()
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and pc:IsLocalController() then return pc end
  end
  return nil
end
local function stack_mag(it, n)
  if it.stack == "power" then
    if it.op == "mult" then return (1 + it.k) ^ n end
    return (1 + it.k) ^ n - 1 -- additive modifier on a base of 1: the total change after n multiplicative stacks
  end
  if it.stack == "hyperbolic" then return 1 - 1 / (1 + it.k * n) end
  if it.op == "mult" then return 1 + it.k * n end
  return it.k * n
end

---------------------------------------------------------------------------
-- run state (authoritative on the host)
---------------------------------------------------------------------------
local Run = {}
local function reset_run()
  Run = {
    players = {},        -- name -> {items={}, handles={}, pawn=addr, base_jump=nil, infusion=0}
    clock = 0.0,         -- seconds of run time
    last_world_t = nil,
    buffed = {},         -- bot addr -> true
    killed = {},         -- bot addr -> true (dedupe kill hooks)
  }
end
reset_run()

local function pstate(name)
  local st = Run.players[name]
  if not st then st = { items = {}, handles = {}, pawn = 0, infusion = 0 }; Run.players[name] = st end
  return st
end
local function count(st, id) return st.items[id] or 0 end

-- view = what the local HUD draws (host fills it directly, clients from messages)
local View = { clock = 0, items = {}, banners = {}, ticker = {}, buffs = {}, bcount = {}, in_run = false }
local BUFF_BY_ID = {}
for _, b in ipairs(Data.BUFFS) do BUFF_BY_ID[b.id] = b end
-- RoR2 buff row states and proc messages for the sheet-driven items (filled in below the engine)
local Procs = { hits = 0 }
local function ticker(text)
  table.insert(View.ticker, 1, { text = text, t = now_ms })
  while #View.ticker > 4 do table.remove(View.ticker) end
end

-- message helpers ---------------------------------------------------------
local function send(pc, msg)
  if valid(pc) and not pc:IsLocalController() then
    pcall(function() pc:ClientMessage(TAG .. msg, FName("None"), 0.0) end)
  end
end
local function pc_of(name)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and player_name(pc) == name then return pc end
  end
end
local function notify(name, kind, payload)
  local pc = pc_of(name)
  if not valid(pc) then return end
  if pc:IsLocalController() then
    if kind == "p" then table.insert(View.banners, { id = payload, t = now_ms })
    elseif kind == "b" then local b = BUFF_BY_ID[payload]; if b then View.buffs[payload] = now_ms + b.duration_ms; View.bcount[payload] = 1 end
    elseif kind == "B" then
      local id, ms, c = payload:match("^([^|]+)|(%d+)|?(%d*)$")
      if id and BUFF_BY_ID[id] then View.buffs[id] = now_ms + tonumber(ms); View.bcount[id] = tonumber(c) or 1 end
    elseif kind == "t" then ticker(payload) end
  else
    send(pc, kind .. "|" .. payload)
  end
end

---------------------------------------------------------------------------
-- items
---------------------------------------------------------------------------
local function apply_items(name)
  local st = pstate(name)
  local pc = pc_of(name)
  if not valid(pc) then return end
  local pawn = pc.Pawn
  if not alive(pawn) then return end
  for _, it in ipairs(Data.ITEMS) do
    local n = count(st, it.id)
    if it.kind == "stat" or it.kind == "growth" then
      remove_effect(pawn, st.handles[it.id]); st.handles[it.id] = nil
      local mag = 0
      if it.kind == "stat" and n > 0 then mag = stack_mag(it, n) end
      if it.kind == "growth" and n > 0 then mag = math.min(st.infusion, it.dmg * n) end
      if n > 0 and mag ~= 0 then st.handles[it.id] = apply_magnitude(pawn, it.ge, mag) end
    end
    if it.kind == "stat" and it.ge2 ~= "" then
      remove_effect(pawn, st.handles[it.id .. "#2"]); st.handles[it.id .. "#2"] = nil
      local mag2 = it.op2 == "mult" and (1 + it.k2 * n) or (it.k2 * n)
      if n > 0 then st.handles[it.id .. "#2"] = apply_magnitude(pawn, it.ge2, mag2) end
    end
    if it.pge ~= "" then
      remove_effect(pawn, st.handles[it.id .. "#p"]); st.handles[it.id .. "#p"] = nil
      local magp = it.pop == "mult" and (1 + it.pk * n) or (it.pk * n)
      if n > 0 then st.handles[it.id .. "#p"] = apply_magnitude(pawn, it.pge, magp) end
    end
    if it.kind == "jump" then
      if not st.base_jump then st.base_jump = pawn.JumpMaxCount end
      pawn.JumpMaxCount = st.base_jump + math.floor(it.k * n)
      send(pc, "j|" .. tostring(pawn.JumpMaxCount))
    end
  end
end

local function give(name, id, n)
  local it = Data.ITEM_BY_ID[id]
  if not it then return end
  local st = pstate(name)
  st.items[id] = count(st, id) + (n or 1)
  log(name .. " picked up " .. it.name .. " (x" .. st.items[id] .. ")")
  apply_items(name)
  notify(name, "p", id)
end

local function take(name, id, n)
  local it = Data.ITEM_BY_ID[id]
  if not it then return end
  local st = pstate(name)
  st.items[id] = math.max(0, count(st, id) - (n or 1))
  if id == "Infusion" and st.items[id] == 0 then st.infusion = 0 end
  log(name .. " lost " .. it.name .. " (x" .. st.items[id] .. ")")
  apply_items(name)
end
local function take_all(name)
  local st = pstate(name)
  st.items = {}
  st.infusion = 0
  apply_items(name)
end

local function roll_rarity(weight_key)
  local total = 0
  for _, r in ipairs(Data.RARITIES) do total = total + r[weight_key] end
  local x = math.random() * total
  for _, r in ipairs(Data.RARITIES) do x = x - r[weight_key]; if x <= 0 then return r.id end end
  return Data.RARITIES[1].id
end
local function roll_item(rarity)
  local pool = {}
  for _, it in ipairs(Data.ITEMS) do if it.rarity == rarity then pool[#pool + 1] = it.id end end
  return pool[math.random(#pool)]
end

---------------------------------------------------------------------------
-- difficulty clock
---------------------------------------------------------------------------
local function tier_index(secs)
  local m = secs / 60
  local idx = 1
  for i, t in ipairs(Data.DIFFICULTY_TIERS) do if m >= t.start_min then idx = i end end
  return idx
end
local function clock_buff(bot, extra_hp, extra_dmg, extra_speed)
  local m = Run.clock / 60
  local hp_mult = (1 + SYS.clock_health_per_min * m) * (extra_hp or 1)
  local dmg_add = SYS.clock_damage_per_min * m + (extra_dmg or 0)
  local spd = (1 + math.min(SYS.clock_speed_cap, SYS.clock_speed_per_min * m)) * (extra_speed or 1)
  if hp_mult > 1.001 then apply_magnitude(bot, GE_MAXHP_MULT, hp_mult) end
  if dmg_add > 0.001 then apply_magnitude(bot, GE_DMG_ADD, dmg_add) end
  if spd > 1.001 then apply_magnitude(bot, GE_SPEED_MULT, spd) end
  bot:SetHealth(bot:GetHealthMax() * 1.0)
end

---------------------------------------------------------------------------
-- RoR2 cards in Deadzone's perk / augment orb menus
---------------------------------------------------------------------------
-- The host rolls one RoR2 card per perk/augment orb and tells every player which slot it
-- takes. Each player's HUD repaints that card in the orb menu; picking it cancels the game's
-- own reward (an invalid index) and the host closes the orb and gives the RoR2 item instead.
local Offers = {} -- bundle key -> {slot = 0-based index, item = id}
local function bundle_key(b)
  local x, y = loc(b)
  return string.format("%d_%d", math.floor(x / 10 + 0.5), math.floor(y / 10 + 0.5))
end
local function orb_row_for_class(b)
  local cn = b:GetClass():GetFName():ToString()
  for _, r in ipairs(Data.ORBS) do if cn:find(r.class_match) then return r end end
end
local function send_offer(pc, key, off) send(pc, "o|" .. key .. "|" .. off.slot .. "|" .. off.item) end
local function roll_offer(b, tries)
  tries = tries or 0
  if not valid(b) or not orb_row_for_class(b) then return end
  local n = 0
  pcall(function() n = b.BundleItems:GetArrayNum() end)
  if n == 0 then
    if tries < 20 then after(500, function() roll_offer(b, tries + 1) end) end
    return
  end
  local key = bundle_key(b)
  if Offers[key] or math.random() > SYS.orb_ror2_chance then return end
  local rar = roll_rarity("orb_weight")
  local off = { slot = math.random(n) - 1, item = roll_item(rar) }
  Offers[key] = off
  log("orb " .. b:GetClass():GetFName():ToString() .. " offers " .. off.item .. " in slot " .. off.slot)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do send_offer(pc, key, off) end
end
local function grant_orb(pc, b, off, key)
  Offers[key] = nil
  local name = player_name(pc)
  after(0, function()
    pcall(function() b:DestroyPickup() end)
    give(name, off.item, 1)
    local st = pstate(name)
    -- Substandard Duplicator: a temporary extra copy
    local dup = count(st, "Duplicator")
    if dup > 0 then
      local it = Data.ITEM_BY_ID.Duplicator
      give(name, off.item, 1)
      after(math.floor((it.dur + it.dur_per * (dup - 1)) * 1000), function() take(name, off.item, 1) end)
    end
  end)
end

local function find_named(root, name, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return nil end
  if root:GetFName():ToString() == name then return root end
  local found
  pcall(function()
    for i = 0, root:GetChildrenCount() - 1 do
      found = found or find_named(root:GetChildAt(i), name, depth + 1)
    end
  end)
  if not found then pcall(function() local wt = root.WidgetTree; if valid(wt) then found = find_named(wt.RootWidget, name, depth + 1) end end) end
  return found
end
local function find_all_class(root, cname, out, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return out end
  if root:GetClass():GetFName():ToString() == cname then out[#out + 1] = root; return out end
  pcall(function() for i = 0, root:GetChildrenCount() - 1 do find_all_class(root:GetChildAt(i), cname, out, depth + 1) end end)
  pcall(function() local wt = root.WidgetTree; if valid(wt) then find_all_class(wt.RootWidget, cname, out, depth + 1) end end)
  return out
end
local function find_all_named(root, name, out, depth)
  depth = depth or 0
  if not valid(root) or depth > 14 then return out end
  if root:GetFName():ToString() == name then out[#out + 1] = root end
  pcall(function() for i = 0, root:GetChildrenCount() - 1 do find_all_named(root:GetChildAt(i), name, out, depth + 1) end end)
  pcall(function() local wt = root.WidgetTree; if valid(wt) then find_all_named(wt.RootWidget, name, out, depth + 1) end end)
  return out
end

local patched = {} -- card addr -> item id (repaint is cheap but avoids text churn)
local function patch_orb_menu(tex)
  local ls = FindFirstOf("WBP_LootSelection_C")
  if not valid(ls) or not ls:IsVisible() then return end
  local b = ls.CachedBundle
  if not valid(b) then return end
  local okey = bundle_key(b)
  local off = Offers[okey]
  if not off then return end
  if not can_take(off.item) then ShownCards[okey] = nil; return end -- inventory full: no RoR2 card
  local lt = ls.LootType.TagName:ToString()
  local row
  for _, r in ipairs(Data.ORBS) do if r.loot_type == lt then row = r end end
  if not row then return end
  local cards = find_all_class(ls.DisplayTypeSwitcher, row.card_class, {})
  local card = cards[off.slot + 1]
  if not valid(card) then return end
  ShownCards[okey] = true
  local it = Data.ITEM_BY_ID[off.item]
  local rar = Data.RARITY_BY_ID[it.rarity]
  local nameW = find_named(card, row.name_widget)
  if valid(nameW) then
    nameW:SetText(FText(it.name))
    pcall(function() nameW:SetColorAndOpacity({ SpecifiedColor = { R = rar.color[1], G = rar.color[2], B = rar.color[3], A = 1 }, ColorUseRule = 0 }) end)
  end
  local typeW = find_named(card, row.type_widget)
  if valid(typeW) then typeW:SetText(FText("// " .. string.upper(Data.RARITY_BY_ID[it.rarity].name or it.rarity) .. " ITEM")) end
  local descs = find_all_named(card, row.desc_widget, {})
  for i, d in ipairs(descs) do
    pcall(function()
      if i == 1 then d:SetText(FText(it.pickup .. " " .. (it.desc_rich or it.desc))) else d:SetText(FText("")) end
    end)
  end
  local host = find_named(card, row.icon_host)
  local icon = valid(host) and find_named(host, row.icon_widget) or nil
  if valid(icon) and valid(tex[it.id]) then pcall(function() icon:SetBrushFromTexture(tex[it.id], false) end) end
  for name in string.gmatch(row.hide_widgets, "[^,]+") do
    local w = find_named(card, name)
    if valid(w) then pcall(function() w:SetVisibility(HID) end) end
  end
end

---------------------------------------------------------------------------
-- Generic RoR2 item engine. The 94 items added after the first 14 are described entirely by
-- their sheet row (kind, trigger, cond, action and numbers); this section runs them.
--   stat    permanent stat (handled by apply_items, incl. a second stat ge2)
--   cstat   stat while a condition holds (out of combat, enemies nearby, ...)
--   buff    timed, stacking stat gained on a trigger
--   effect  an action (damage, heal, shield, credits, ammo, aura, ...) on a trigger
--   regen   healing per second while a condition holds
--   growth2 a stat that grows with kills up to a cap
--   special a few items with their own small handler below
-- Everything runs on the host. Damage goes through deal()/item_hit(), so kills are credited.
---------------------------------------------------------------------------
local ITEMS_BY_TRIGGER = {}
local GENERIC_KINDS = { effect = true, buff = true, growth2 = true }
for _, it in ipairs(Data.ITEMS) do
  if GENERIC_KINDS[it.kind] and it.trigger ~= "" then
    ITEMS_BY_TRIGGER[it.trigger] = ITEMS_BY_TRIGGER[it.trigger] or {}
    table.insert(ITEMS_BY_TRIGGER[it.trigger], it)
  end
end
local COND_ITEMS, REGEN_ITEMS, PERIODIC_ITEMS = {}, {}, {}
for _, it in ipairs(Data.ITEMS) do
  if it.kind == "cstat" then COND_ITEMS[#COND_ITEMS + 1] = it end
  if it.kind == "regen" then REGEN_ITEMS[#REGEN_ITEMS + 1] = it end
  if it.trigger == "periodic" then PERIODIC_ITEMS[#PERIODIC_ITEMS + 1] = it end
end
local ELEMENT_IDS = {}
for _, e in ipairs(Data.ELEMENTS) do if e.elemental == 1 then ELEMENT_IDS[#ELEMENT_IDS + 1] = e.id end end

local function per(base, step, n) return base + step * (n - 1) end
local function sec_ms(s) return math.floor(s * 1000) end

-- player context ------------------------------------------------------------
local function gstate(st)
  if not st.g then
    st.g = { base = SYS.base_damage_start, last_fire = {}, counter = {}, buffs = {}, cstat = {}, growth = {},
             last_hit = -1e9, last_hurt = -1e9, low = false, still_since = nil, charge = 0, soul = 0,
             fall_from = nil, kills = {}, echo_ready = 0 }
  end
  return st.g
end
local function in_combat(g) return now_ms - math.max(g.last_hit, g.last_hurt) < SYS.combat_window_ms end
local function speed_of(pawn)
  local v = { X = 0, Y = 0, Z = 0 }
  pcall(function() v = pawn:GetVelocity() end)
  return math.sqrt(v.X * v.X + v.Y * v.Y)
end
local function luck(st) return count(st, "Clover") end
local function roll(st, p)
  if p >= 1 or rawget(_G, "R2_FORCE") then return true end
  for _ = 0, luck(st) do if math.random() < p then return true end end
  return false
end
local function chance_of(it, n)
  if it.stack == "hyperbolic" then return 1 - (1 - it.chance) ^ n end
  return math.min(1, per(it.chance, it.chance_per, n))
end
local function cd_of(it, n)
  if it.cd_per > 0 then return it.cd * it.cd_per ^ (n - 1) end
  return it.cd
end
local function ready(g, key, seconds)
  if seconds <= 0 then return true end
  if (g.last_fire[key] or -1e9) + sec_ms(seconds) > now_ms then return false end
  return true
end

-- elites: a bot whose max HP is well above the run's typical bot
local HpEma = nil
local function note_bot_hp(bot)
  local m = 0; pcall(function() m = bot:GetHealthMax() end)
  if m <= 0 then return end
  HpEma = HpEma and (HpEma * 0.95 + m * 0.05) or m
end
local function is_elite(bot)
  if not HpEma then return false end
  local m = 0; pcall(function() m = bot:GetHealthMax() end)
  return m >= HpEma * SYS.elite_hp_ratio
end

-- element statuses currently on a bot (for Death Mark / Noxious Thorn)
local StatusUntil = {}
local function note_status(bot, el_id, dur)
  StatusUntil[addr(bot) .. "|" .. el_id] = now_ms + sec_ms(dur)
end
local function statuses_on(bot)
  local a, out = addr(bot), {}
  for _, id in ipairs(ELEMENT_IDS) do
    if (StatusUntil[a .. "|" .. id] or 0) > now_ms then out[#out + 1] = id end
  end
  return out
end

-- shields, credits, invulnerability -----------------------------------------
local function apply_fixed(char, path, mag, target)
  local cpath, dpath = ge_paths(path)
  local c, cdo = cls(cpath), cls(dpath)
  if not valid(c) then pcall(function() LoadAsset(path) end); c, cdo = cls(cpath), cls(dpath) end
  if not valid(c) or not valid(cdo) or not valid(char) then return end
  local asc = char.AbilitySystemComponent
  if not valid(asc) then return end
  local saved = {}
  local mods = cdo.Modifiers
  for i = 1, mods:GetArrayNum() do
    local mm = mods[i].ModifierMagnitude
    saved[i] = { mm.MagnitudeCalculationType, mm.ScalableFloatMagnitude.Value }
    if mag and saved[i][1] == 3 then mm.MagnitudeCalculationType = 0; mm.ScalableFloatMagnitude.Value = mag end
  end
  pcall(function()
    if target then asc:BP_ApplyGameplayEffectToTarget(c, target.AbilitySystemComponent, 1.0, asc:MakeEffectContext())
    else asc:BP_ApplyGameplayEffectToSelf(c, 1.0, asc:MakeEffectContext()) end
  end)
  for i = 1, mods:GetArrayNum() do
    local mm = mods[i].ModifierMagnitude
    mm.MagnitudeCalculationType = saved[i][1]; mm.ScalableFloatMagnitude.Value = saved[i][2]
  end
end
local function barrier(pawn, amount)
  if not alive(pawn) or amount <= 0 then return end
  apply_fixed(pawn, SYS.temp_shield_ge, math.floor(amount))
end
local function award_credits(pc, amount)
  local gm = FindFirstOf("ValGameMode")
  amount = math.floor(amount * (1 + Run.clock / SYS.currency_clock_scale))
  if amount <= 0 or not valid(gm) or not valid(pc) then return end
  pcall(function() gm:AwardCurrency(pc.PlayerState, 0, amount) end)
end

-- healing that knows about Rejuvenation Rack, Aegis and N'kuhana's Opinion
local function heal_player(name, pawn, amount)
  if not alive(pawn) or amount <= 0 then return end
  local st = pstate(name)
  amount = amount * (1 + count(st, "IncreaseHealing"))
  local hp, mx = pawn:GetHealth(), pawn:GetHealthMax()
  local over = hp + amount - mx
  pawn:SetHealth(math.min(mx, hp + amount) * 1.0)
  local aegis = count(st, "BarrierOnOverHeal")
  if aegis > 0 and over > 0 then
    -- small heals (Leeching Seed's 1 HP, regen ticks) give fractions of a point: keep the remainder
    -- instead of rounding every one of them down to nothing
    local it = Data.ITEM_BY_ID.BarrierOnOverHeal
    st.aegis_acc = (st.aegis_acc or 0) + over * per(it.k, it.k_per, aegis)
    if st.aegis_acc >= 1 then
      local whole = math.floor(st.aegis_acc)
      st.aegis_acc = st.aegis_acc - whole
      barrier(pawn, whole)
    end
  end
end

-- timed stat effects ----------------------------------------------------------
local function stat_mag(op, raw) if op == "mult" then return 1 + raw end return raw end
local function set_stat(pawn, slot, key, ge, op, raw)
  remove_effect(pawn, slot[key]); slot[key] = nil
  if ge ~= "" and raw ~= 0 and alive(pawn) then slot[key] = apply_magnitude(pawn, ge, stat_mag(op, raw)) end
end

-- damage helpers ----------------------------------------------------------------
local function el_of(it) return Data.ELEMENT_BY_ID[it.element] end
-- one hit from a generic item: element damage, the element's status, and the item's extra status
local function ghit(pawn, bot, it, n, amount, extra_dur)
  if not alive(bot) then return end
  Procs.hits = Procs.hits + 1
  local el = el_of(it)
  if el and el.status_ge ~= "none" then apply_status(pawn, bot, el); note_status(bot, el.id, el.duration_s) end
  local sx = Data.ELEMENT_BY_ID[it.status]
  if sx and sx.status_ge ~= "none" then
    local d = extra_dur or (it.dur > 0 and per(it.dur, it.dur_per, n)) or sx.duration_s
    apply_status(pawn, bot, sx, d); note_status(bot, sx.id, d)
  end
  if amount and amount > 0 then deal(pawn, bot, element_damage(pawn, el, amount)) end
end
local function bots_in(center_x, center_y, center_z, radius)
  local out = {}
  for _, b in ipairs(all_bots()) do
    local x, y, z = loc(b)
    if math.sqrt((x - center_x) ^ 2 + (y - center_y) ^ 2 + (z - center_z) ^ 2) <= radius then out[#out + 1] = b end
  end
  return out
end
local function nearest(list, center, k)
  table.sort(list, function(a, b) return dist(a, center) < dist(b, center) end)
  local out = {}
  for i = 1, math.min(k, #list) do out[i] = list[i] end
  return out
end
local function shuffle(t) for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end return t end

-- auras: short-lived zones handled every tick (banner, turret, ice storm, healing plant, transmitter)
local Auras = {}

-- the action table ------------------------------------------------------------------
local ACTIONS = {}
local function base_value(it, ctx, target)
  if it.dmg_base == "base" then return ctx.g.base end
  if it.dmg_base == "vmax" then local m = 0; pcall(function() m = target:GetHealthMax() end); return m end
  return ctx.amount or ctx.g.base
end
local function dmg_of(it, n, ctx, target)
  return per(it.dmg, it.dmg_per, n) * base_value(it, ctx, target), 1
end
local function radius_of(it, n) return per(it.radius, it.radius_per, n) end
local function count_of(it, n) return math.floor(per(it.n, it.n_per, n)) end

ACTIONS.bonus = function(it, n, ctx)
  local d = dmg_of(it, n, ctx, ctx.victim)
  ghit(ctx.pawn, ctx.victim, it, n, d)
end
ACTIONS.single = function(it, n, ctx)
  local d, shots = dmg_of(it, n, ctx, ctx.victim)
  for _ = 1, shots do ghit(ctx.pawn, ctx.victim, it, n, d) end
  fx_at("behemoth_blast", ctx.victim)
end
ACTIONS.single_random = function(it, n, ctx)
  local list = bots_near(ctx.pawn, radius_of(it, n), nil)
  if #list == 0 then return end
  local t = list[math.random(#list)]
  local d = dmg_of(it, n, ctx, t)
  ghit(ctx.pawn, t, it, n, d); fx_at("behemoth_blast", t)
end
ACTIONS.aoe = function(it, n, ctx)
  local center = ctx.victim or ctx.pawn
  local x, y, z = loc(center)
  local d = dmg_of(it, n, ctx, center)
  fx("behemoth_blast", x, y, z)
  for _, b in ipairs(bots_in(x, y, z, radius_of(it, n))) do ghit(ctx.pawn, b, it, n, d) end
end
ACTIONS.aoe_self = function(it, n, ctx)
  local x, y, z = loc(ctx.pawn)
  local d = dmg_of(it, n, ctx, nil)
  if it.id == "ShieldBooster" then d = d + attr(ctx.pawn, "ShieldMax", 0) end
  fx("behemoth_blast", x, y, z)
  for _, b in ipairs(bots_in(x, y, z, radius_of(it, n))) do ghit(ctx.pawn, b, it, n, d) end
end
ACTIONS.aoe_random = function(it, n, ctx)
  local list = bots_near(ctx.pawn, radius_of(it, n), nil)
  if #list == 0 then return end
  local t = list[math.random(#list)]
  local x, y, z = loc(t)
  local d = dmg_of(it, n, ctx, t)
  fx("gasoline_blast", x, y, z)
  for _, b in ipairs(bots_in(x, y, z, 400)) do ghit(ctx.pawn, b, it, n, d) end
end
ACTIONS.chain = function(it, n, ctx)
  local d = dmg_of(it, n, ctx, ctx.victim)
  for _, b in ipairs(nearest(bots_near(ctx.victim, radius_of(it, n), ctx.victim), ctx.victim, count_of(it, n))) do
    fx_at("ukulele_hit", b); ghit(ctx.pawn, b, it, n, d)
  end
end
ACTIONS.chain_self = function(it, n, ctx)
  local d = dmg_of(it, n, ctx, nil)
  for _, b in ipairs(nearest(bots_near(ctx.pawn, radius_of(it, n), nil), ctx.pawn, count_of(it, n))) do
    fx_at("ukulele_hit", b); ghit(ctx.pawn, b, it, n, d)
  end
end
ACTIONS.multi = function(it, n, ctx)
  local list = shuffle(bots_near(ctx.pawn, radius_of(it, n), nil))
  if #list == 0 then return end
  local d, shots = dmg_of(it, n, ctx, nil)
  local k = count_of(it, n) * shots
  for i = 1, k do
    local b = list[(i - 1) % #list + 1]
    after(i * 60, function() if alive(b) then ghit(ctx.pawn, b, it, n, d) end end)
  end
end
ACTIONS.dot = function(it, n, ctx)
  local b, pawn = ctx.victim, ctx.pawn
  local total = dmg_of(it, n, ctx, b)
  if it.element == "fire" and count(ctx.st, "StrengthenBurn") > 0 then
    local tank = Data.ITEM_BY_ID.StrengthenBurn
    total = total * (1 + per(tank.k, tank.k_per, count(ctx.st, "StrengthenBurn")))
  end
  local ticks = math.max(1, math.floor(it.dur * 2))
  ghit(pawn, b, it, n, 0)
  for i = 1, ticks do after(i * 500, function() if alive(b) then Procs.crit = "none"; deal(pawn, b, element_damage(pawn, el_of(it), total / ticks)); Procs.crit = nil end end) end
end
ACTIONS.delayed = function(it, n, ctx)
  local b, pawn = ctx.victim, ctx.pawn
  local d = dmg_of(it, n, ctx, b)
  local x, y, z = loc(b)
  after(sec_ms(it.dur), function()
    if alive(b) then x, y, z = loc(b) end
    fx("gasoline_blast", x, y, z)
    for _, t in ipairs(bots_in(x, y, z, it.radius)) do ghit(pawn, t, it, n, d) end
  end)
end
ACTIONS.status = function(it, n, ctx) ghit(ctx.pawn, ctx.victim, it, n, 0) end
ACTIONS.execute = function(it, n, ctx) deal(ctx.pawn, ctx.victim, ctx.victim:GetHealth() + 1) end
ACTIONS.heal = function(it, n, ctx)
  local mx = ctx.pawn:GetHealthMax()
  heal_player(ctx.name, ctx.pawn, per(it.k, it.k_per, n) + per(it.dmg, it.dmg_per, n) * mx)
end
ACTIONS.heal_all = function(it, n, ctx)
  local times = math.max(1, count_of(it, n))
  for i = 0, times - 1 do
    after(i * 15000, function()
      for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
        local p = valid(pc) and pc.Pawn
        if alive(p) and alive(ctx.pawn) and dist(p, ctx.pawn) <= it.radius then
          heal_player(player_name(pc), p, it.dmg * p:GetHealthMax()); fx_at("heal", p)
        end
      end
    end)
  end
end
ACTIONS.barrier = function(it, n, ctx)
  barrier(ctx.pawn, per(it.k, it.k_per, n) + per(it.dmg, it.dmg_per, n) * ctx.pawn:GetHealthMax())
end
ACTIONS.currency = function(it, n, ctx) award_credits(ctx.pc, per(it.k, it.k_per, n)) end
ACTIONS.ammo = function(it, n, ctx) pcall(function() ctx.pawn:RefillAmmo(false) end) end
ACTIONS.refund = function(it, n, ctx)
  local pct = it.stack == "hyperbolic" and (1 - 1 / (1 + it.k * n)) or math.min(1, per(it.k, it.k_per, n))
  if ctx.pawn:GetHealth() > 0 then heal_player(ctx.name, ctx.pawn, ctx.amount * pct) end
end
local BUFF_FROM
ACTIONS.buff = function(it, n, ctx)
  BUFF_FROM(it, n, ctx)
  if it.invuln > 0 then apply_fixed(ctx.pawn, SYS.invuln_ge, nil) end
end
ACTIONS.aura = function(it, n, ctx)
  local x, y, z = loc(ctx.victim or ctx.pawn)
  local a = { it = it, n = n, name = ctx.name, pawn = ctx.pawn, st = ctx.st, x = x, y = y, z = z,
              start = now_ms + sec_ms(it.delay), stop = now_ms + sec_ms(it.delay + per(it.dur, it.dur_per, n)), next = 0, kills = 0 }
  if it.sub == "storm" then
    for _, o in ipairs(Auras) do
      if o.it.id == it.id and o.name == ctx.name and o.stop > now_ms then o.stop = a.stop; o.kills = o.kills + 1; return end
    end
  end
  if it.sub == "transmit" then barrier(ctx.pawn, it.k * ctx.pawn:GetHealthMax()) end
  Auras[#Auras + 1] = a
end
local function random_item(st, white_pct)
  local r = math.random() * 100
  local rar = r < white_pct and "white" or (r < white_pct + 20 and "green" or "red")
  return roll_item(rar)
end
ACTIONS.item = function(it, n, ctx)
  local id = random_item(ctx.st, it.k)
  if it.consume > 0 then take(ctx.name, it.id, 1) end
  give(ctx.name, id, 1)
  notify(ctx.name, "t", Data.ITEM_BY_ID[it.id].name .. ": " .. Data.ITEM_BY_ID[id].name)
end
ACTIONS.elite_strike = function(it, n, ctx)
  local best, bm = nil, 0
  for _, b in ipairs(bots_near(ctx.pawn, radius_of(it, n), nil)) do
    local m = b:GetHealthMax(); if m > bm then best, bm = b, m end
  end
  if not best or not is_elite(best) then return end
  local d, shots = dmg_of(it, n, ctx, best)
  local k = it.n * shots
  for i = 1, k do after(i * 120, function() if alive(best) then fx_at("behemoth_blast", best); ghit(ctx.pawn, best, it, n, d / it.n) end end) end
end

-- buffs -------------------------------------------------------------------------------
BUFF_FROM = function(it, n, ctx)
  local g = ctx.g
  local b = g.buffs[it.id] or { stacks = 0, h = {} }
  g.buffs[it.id] = b
  local cap = math.max(1, math.floor(per(it.cap, it.cap_per, n)))
  b.stacks = math.min(cap, b.stacks + 1)
  b.untilT = now_ms + sec_ms(per(it.dur, it.dur_per, n))
  b.it, b.n = it, n
  set_stat(ctx.pawn, b.h, 1, it.ge, it.op, b.stacks * per(it.k, it.k_per, n))
  if it.ge2 and it.ge2 ~= "" then set_stat(ctx.pawn, b.h, 2, it.ge2, it.op2, b.stacks * it.k2) end
end
local function expire_buffs(pawn, g)
  for id, b in pairs(g.buffs) do
    if b.untilT <= now_ms then
      remove_effect(pawn, b.h[1]); remove_effect(pawn, b.h[2])
      g.buffs[id] = nil
    end
  end
end
local function active_buffs(g) local c = 0; for _ in pairs(g.buffs) do c = c + 1 end return c end

-- conditions ------------------------------------------------------------------------------
local function cond_ok(it, n, ctx)
  local c, g, v = it.cond, ctx.g, ctx.victim
  if c == "" then return true end
  if c == "ooc" then return not in_combat(g) end
  if c == "in_combat" then return in_combat(g) end
  if c == "moving" then return speed_of(ctx.pawn) > 400 end
  if c == "shield" then return attr(ctx.pawn, "Shield", 0) > 0 end
  if c == "tesla" then return (now_ms // sec_ms(it.cv)) % 2 == 0 end
  if c == "v_elite" then return v and is_elite(v) end
  if c == "v_elite_low" then
    if not (v and is_elite(v)) then return false end
    local th = 1 - (1 - it.cv) ^ n
    return v:GetHealth() / math.max(1, v:GetHealthMax()) < th
  end
  if c == "v_near" then return v and dist(v, ctx.pawn) <= it.cv end
  if c == "v_hp_above" then return v and (v:GetHealth() + (ctx.amount or 0)) / math.max(1, v:GetHealthMax()) >= it.cv end
  if c == "v_debuffed" then return v and #statuses_on(v) >= it.cv end
  if c == "v_cooldown" then
    local key = it.id .. addr(v)
    if (g.last_fire[key] or -1e9) + sec_ms(it.cv) > now_ms then return false end
    g.last_fire[key] = now_ms; return true
  end
  if c == "above" then local _, _, pz = loc(ctx.pawn); local _, _, vz = loc(v); return pz - vz >= it.cv end
  if c == "hit_big" then return (ctx.amount or 0) >= it.cv * g.base end
  if c == "every" then g.counter[it.id] = (g.counter[it.id] or 0) + 1; return g.counter[it.id] % it.cv == 0 end
  if c == "every_target" then
    local key = it.id .. addr(v); g.counter[key] = (g.counter[key] or 0) + 1; return g.counter[key] % it.cv == 0
  end
  if c == "charged" then if g.charge >= it.cv then g.charge = 0; return true end return false end
  if c == "charges" then return ready(g, it.id .. "c", 10 / (it.cv + n - 1)) and (function() g.last_fire[it.id .. "c"] = now_ms; return true end)() end
  if c == "meteor" then return true end
  return false
end

-- run one trigger for one player -----------------------------------------------------------
local function fire(trigger, ctx)
  local list = ITEMS_BY_TRIGGER[trigger]
  if not list then return end
  for _, it in ipairs(list) do
    local n = count(ctx.st, it.id)
    if n > 0 then
      local p = chance_of(it, n)
      if it.cond == "meteor" and ctx.amount then p = p + 0.03 * n * math.max(0, ctx.amount / ctx.g.base - 1) end
      local cdv = trigger ~= "periodic" and cd_of(it, n) or 0
      if (trigger ~= "multikill" or #ctx.g.kills >= it.cv) and ready(ctx.g, it.id, cdv) and cond_ok(it, n, ctx) and roll(ctx.st, p) then
        if cdv > 0 then ctx.g.last_fire[it.id] = now_ms end
        if it.once == "stage" then
          if ctx.g.once and ctx.g.once[it.id] == Run.stage then goto continue end
          ctx.g.once = ctx.g.once or {}; ctx.g.once[it.id] = Run.stage
        end
        local ok, err
        Procs.hits = 0
        Procs.crit = Procs.crit_for(trigger, it, ctx)
        if it.kind == "buff" then ok, err = pcall(BUFF_FROM, it, n, ctx)
        elseif it.kind == "growth2" then
          local gr = ctx.g.growth
          local cap = per(it.cap, it.cap_per, n)
          local kills = math.min((gr[it.id] or 0) + 1, cap / it.k)
          gr[it.id] = kills
          ok, err = pcall(function()
            ctx.g.cstat[it.id] = ctx.g.cstat[it.id] or { h = {} }
            set_stat(ctx.pawn, ctx.g.cstat[it.id].h, 1, it.ge, it.op, kills * it.k)
            set_stat(ctx.pawn, ctx.g.cstat[it.id].h, 2, it.ge2, it.op2, kills * it.k2)
          end)
        else
          local fn = ACTIONS[it.action]
          if fn then ok, err = pcall(fn, it, n, ctx) end
        end
        if ok == false then log(it.id .. " " .. trigger .. ": " .. tostring(err))
        else pcall(Procs.say, ctx, it.id, Procs.hits) end
        Procs.crit = nil
      end
    end
    ::continue::
  end
end
local function ctx_for(pc, extra)
  local name = player_name(pc)
  local st = pstate(name)
  local c = { pc = pc, name = name, st = st, g = gstate(st), pawn = pc.Pawn }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

-- specials -------------------------------------------------------------------------------------
local Infected = {} -- Networked Suffering: bot addr -> {bot, owner name}
local Pool = 0
local Scorp = {}    -- Symbiotic Scorpion: bot addr .. name -> stacks
local function special_hit(ctx)
  local st, v = ctx.st, ctx.victim
  local scorp = count(st, "PermanentDebuffOnHit")
  if scorp > 0 then
    local it = Data.ITEM_BY_ID.PermanentDebuffOnHit
    local key = addr(v) .. ctx.name
    Scorp[key] = math.min(25, (Scorp[key] or 0) + 1)
    local pct = math.min(0.5, Scorp[key] * per(it.k, it.k_per, scorp))
    deal(ctx.pawn, v, ctx.amount * pct)
  end
  local ss = count(st, "SharedSuffering")
  if ss > 0 then
    local it = Data.ITEM_BY_ID.SharedSuffering
    local a = addr(v)
    local cnt = 0
    for k, e in pairs(Infected) do if alive(e.bot) then cnt = cnt + 1 else Infected[k] = nil end end
    if not Infected[a] and cnt < count_of(it, ss) then Infected[a] = { bot = v, name = ctx.name }; apply_status(ctx.pawn, v, Data.ELEMENT_BY_ID.void) end
  end
  local thorn = count(st, "TriggerEnemyDebuffs")
  if thorn > 0 and roll(st, Data.ITEM_BY_ID.TriggerEnemyDebuffs.chance) then
    ACTIONS.dot({ id = "NoxiousBleed", element = "nano", status = "none", dur = 2, dur_per = 0, dmg = 1.0, dmg_per = 0, dmg_base = "base", tag = "" }, 1, ctx)
  end
end
local function special_kill(ctx)
  local thorn = count(ctx.st, "TriggerEnemyDebuffs")
  if thorn > 0 and ctx.victim then
    local it = Data.ITEM_BY_ID.TriggerEnemyDebuffs
    local list = statuses_on(ctx.victim)
    if #list > 0 then
      for _, b in ipairs(nearest(bots_near(ctx.victim, radius_of(it, thorn), ctx.victim), ctx.victim, count_of(it, thorn))) do
        for _, id in ipairs(list) do local el = Data.ELEMENT_BY_ID[id]; apply_status(ctx.pawn, b, el); note_status(b, id, el.duration_s) end
      end
    end
  end
end
local function special_hurt(ctx)
  local st, g = ctx.st, ctx.g
  local echo = count(st, "DelayedDamage")
  if echo > 0 and g.echo_ready <= now_ms and ctx.pawn:GetHealth() > 0 then
    local it = Data.ITEM_BY_ID.DelayedDamage
    g.echo_ready = now_ms + sec_ms(it.cd)
    local back = ctx.amount
    heal(ctx.pawn, back)
    local hits = count_of(it, echo)
    local each = back * (1 - it.k) / hits
    g.echo_until = now_ms + hits * 1000
    for i = 1, hits do
      after(i * 1000, function()
        local p = ctx.pawn
        if alive(p) then p:SetHealth(math.max(1, p:GetHealth() - each) * 1.0) end
      end)
    end
  end
end
local function special_lowhp(ctx)
  local st = ctx.st
  if count(st, "HealingPotion") > 0 then
    take(ctx.name, "HealingPotion", 1)
    heal_player(ctx.name, ctx.pawn, Data.ITEM_BY_ID.HealingPotion.dmg * ctx.pawn:GetHealthMax())
    fx_at("heal", ctx.pawn)
    notify(ctx.name, "t", "Power Elixir used")
  end
  if count(st, "FragileDamageBonus") > 0 then
    st.items.FragileDamageBonus = 0
    apply_items(ctx.name)
    notify(ctx.name, "t", "Delicate Watch broke")
  end
end

-- RoR2 buff row and proc messages for the sheet-driven items -------------------------------------
-- Same process as the original four: the host decides, notify() shows it locally or messages the client.
function Procs.say(ctx, id, hits)
  local p = Data.PROC_BY_ID[id]
  if not p or not ctx.name then return end
  local text = p.text
  if text:find("{enemies}", 1, true) then
    if (hits or 0) <= 0 then return end
    text = text:gsub("{enemies}", hits == 1 and "1 enemy" or (hits .. " enemies"))
  end
  local g = ctx.g
  g.proc_t = g.proc_t or {}
  if (g.proc_t[id] or -1e9) + p.gap_ms > now_ms then return end
  g.proc_t[id] = now_ms
  notify(ctx.name, "t", text)
end
-- Deadzone keywords for RoR2 item damage (the mod deals it directly, so the game's own damage
-- calculation never sees it):
--  * Critical Hit: procs from a hit inherit that hit's crit, as in RoR2. Items that scale off the hit
--    already include it. Other procs roll your Crit Chance (+15% against Shocked targets, as Shock says).
--    A crit multiplies by your CriticalDamageMultiplier.
--  * Mark: Marked enemies take +50% damage (GE_GrenadeWeakened's text).
function Procs.crit_for(trigger, it, ctx)
  if trigger == "hit" or trigger == "crit" then
    if it.dmg_base ~= "base" and it.dmg_base ~= "vmax" then return "none" end
    local c = false
    pcall(function() c = ctx.d and ctx.d.bCriticalHit or false end)
    return c
  end
  return nil
end
_G.R2_DMG_SCALE = function(attacker, bot, amount)
  if not valid(attacker) or not attacker:IsPlayerControlled() then return amount end
  local c = Procs.crit
  if c == nil then
    local chance = attr(attacker, SYS.crit_chance_attr, 0)
    if (StatusUntil[addr(bot) .. "|lightning"] or 0) > now_ms then chance = chance + SYS.shock_crit_bonus end
    c = math.random() < chance
  end
  local out = amount
  if c == true then out = out * attr(attacker, SYS.crit_damage_attr, 1) end
  local marked = (StatusUntil[addr(bot) .. "|mark"] or 0) > now_ms
  if marked then out = out * (1 + SYS.mark_damage_taken) end
  Procs.last = { crit = c == true, marked = marked, base = amount, out = out }
  return out
end
function Procs.row(ctx)
  -- Mirrors RoR2's BuffDisplay: one icon per active buff, tinted with its BuffDef colour,
  -- and for stacking buffs the stack count ("x3", or "5%" for percentage buffs).
  local g, st = ctx.g, ctx.st
  local used = g.once and g.once.TeleportOnLowHealth == Run.stage
  for _, b in ipairs(Data.BUFFS) do
    local ms, cnt = 0, 1
    local n = count(st, b.item)
    if b.event == "buff" then
      local x = g.buffs[b.item]
      if x and x.untilT > now_ms then
        ms = x.untilT - now_ms; cnt = x.stacks or 1
        if b.stack_pct == 1 and x.it then cnt = math.floor(cnt * per(x.it.k, x.it.k_per, x.n or 1) * 100 + 0.5) end
      end
    elseif b.event == "aura" then
      for _, a in ipairs(Auras) do
        if a.it.id == b.item and a.name == ctx.name and a.stop > now_ms then ms = math.max(ms, a.stop - now_ms) end
      end
    elseif b.event == "cstat" then
      local c = g.cstat[b.item]
      if n > 0 and c and c.mag ~= 0 then ms = b.duration_ms; cnt = c.stacks or 1 end
    elseif b.event == "ooc" then
      if n > 0 and not in_combat(g) then ms = b.duration_ms end
    elseif b.event == "ready" then
      if n > 0 and (g.echo_ready or 0) <= now_ms then ms = b.duration_ms end
    elseif b.event == "echopending" then
      if n > 0 and (g.echo_until or 0) > now_ms then ms = g.echo_until - now_ms; cnt = math.ceil(ms / 1000) end
    elseif b.event == "tpready" then
      if n > 0 and not used then ms = b.duration_ms end
    elseif b.event == "tpused" then
      local active = false
      for _, a in ipairs(Auras) do if a.it.id == b.item and a.name == ctx.name and a.stop > now_ms then active = true end end
      if n > 0 and used and not active then ms = b.duration_ms end
    elseif b.event == "tesla" then
      -- Unstable Tesla Coil: on for cv seconds, off for cv seconds (same rule as its "tesla" condition)
      local it = Data.ITEM_BY_ID[b.item]
      local period = sec_ms(it.cv)
      if n > 0 and (now_ms // period) % 2 == 0 then ms = period - (now_ms % period) end
    elseif b.event == "ringcd" or b.event == "ringready" then
      local held, left = false, 0
      for _, id in ipairs({ "FireRing", "IceRing" }) do
        local k = count(st, id)
        local it = Data.ITEM_BY_ID[id]
        if k > 0 and it then
          held = true
          if not ready(g, id, cd_of(it, k)) then left = math.max(left, (g.last_fire[id] or 0) + sec_ms(cd_of(it, k)) - now_ms) end
        end
      end
      if b.event == "ringcd" and left > 0 then ms = left; cnt = math.ceil(left / 1000) end
      if b.event == "ringready" and held and left <= 0 then ms = b.duration_ms end
    end
    if ms > 0 then notify(ctx.name, "B", b.id .. "|" .. math.floor(ms) .. "|" .. math.floor(cnt)) end
  end
end

-- per-tick work for every player (host) ---------------------------------------------------------
local cond_acc, regen_acc, pool_acc = 0, 0, 0
local function engine_tick()
  cond_acc = cond_acc + TICK_MS; regen_acc = regen_acc + TICK_MS; pool_acc = pool_acc + TICK_MS
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and alive(pc.Pawn) then
      local ctx = ctx_for(pc)
      local g, st, pawn = ctx.g, ctx.st, ctx.pawn
      local hp, mx = pawn:GetHealth(), pawn:GetHealthMax()
      -- low health edge
      if hp / math.max(1, mx) < SYS.lowhp_frac then
        if not g.low then g.low = true; special_lowhp(ctx); fire("lowhp", ctx) end
      elseif hp / math.max(1, mx) > 0.5 then g.low = false end
      -- standing still / moving charge
      local sp = speed_of(pawn)
      if sp < 30 then g.still_since = g.still_since or now_ms else g.still_since = nil end
      if sp > 200 then g.charge = g.charge + TICK_MS / 1000 end
      g.last_hp = hp
      -- H3AD-5T v2: landing after a big fall
      if count(st, "FallBoots") > 0 then
        local falling = false
        pcall(function() falling = pawn.CharacterMovement:IsFalling() end)
        local _, _, z = loc(pawn)
        if falling then g.fall_from = math.max(g.fall_from or z, z)
        elseif g.fall_from then
          local drop = g.fall_from - z
          g.fall_from = nil
          local it = Data.ITEM_BY_ID.FallBoots
          local nn = count(st, "FallBoots")
          if drop > 400 and ready(g, "FallBoots", cd_of(it, nn)) then
            g.last_fire.FallBoots = now_ms
            local scale = clamp(drop / 400, 1, 10)
            local x, y, zz = loc(pawn); fx("behemoth_blast", x, y, zz)
            Procs.hits = 0
            for _, b in ipairs(bots_in(x, y, zz, clamp(it.radius * scale, 500, 3000))) do ghit(pawn, b, it, nn, it.dmg * scale * g.base) end
            pcall(Procs.say, ctx, "FallBoots", Procs.hits)
          end
        end
      end
      -- periodic items
      for _, it in ipairs(PERIODIC_ITEMS) do
        local n = count(st, it.id)
        if n > 0 and ready(g, it.id .. "p", cd_of(it, n)) then
          g.last_fire[it.id .. "p"] = now_ms
          local list = ITEMS_BY_TRIGGER.periodic
          local one = { it }
          ITEMS_BY_TRIGGER.periodic = one
          fire("periodic", ctx)
          ITEMS_BY_TRIGGER.periodic = list
        end
      end
      expire_buffs(pawn, g)
      -- conditional stats (twice a second)
      if cond_acc >= 500 then
        pcall(Procs.row, ctx)
        for _, it in ipairs(COND_ITEMS) do
          local n = count(st, it.id)
          local slot = g.cstat[it.id] or { h = {}, mag = 0 }
          g.cstat[it.id] = slot
          local stacks = 0
          if n > 0 then
            if it.cond == "nearby" then
              stacks = math.min(math.floor(per(it.cap, it.cap_per, n)), #bots_near(pawn, it.radius, nil))
            elseif it.cond == "buffs" then
              stacks = math.min(math.floor(per(it.cap, it.cap_per, n)), active_buffs(g))
            elseif it.cond == "ooc" then stacks = in_combat(g) and 0 or n
            elseif cond_ok(it, n, ctx) then stacks = n end
          end
          local unit = (it.cond == "nearby" or it.cond == "buffs") and per(it.k, it.k_per, n) or it.k
          local mag = stacks * unit
          slot.stacks = stacks
          if mag ~= slot.mag then
            slot.mag = mag
            set_stat(pawn, slot.h, 1, it.ge, it.op, mag)
            if it.ge2 ~= "" then set_stat(pawn, slot.h, 2, it.ge2, it.op2, stacks * it.k2) end
          end
        end
      end
      -- regeneration (once a second)
      if regen_acc >= 1000 then
        for _, it in ipairs(REGEN_ITEMS) do
          local n = count(st, it.id)
          if n > 0 then
            local on = (it.cond == "ooc" and not in_combat(g)) or (it.cond == "still" and g.still_since and now_ms - g.still_since >= 1000)
            if on then
              local amount = per(it.k, it.k_per, n) + per(it.dmg, it.dmg_per, n) * mx
              heal_player(ctx.name, pawn, amount)
              if it.radius > 0 then
                for _, opc in ipairs(FindAllOf("ValPlayerController") or {}) do
                  local p = valid(opc) and opc.Pawn
                  if alive(p) and addr(p) ~= addr(pawn) and dist(p, pawn) <= per(it.radius, it.radius_per, n) then heal_player(player_name(opc), p, per(it.dmg, it.dmg_per, n) * p:GetHealthMax()) end
                end
              end
            end
          end
        end
      end
    end
  end
  if cond_acc >= 500 then cond_acc = 0 end
  if regen_acc >= 1000 then regen_acc = 0 end
  -- Networked Suffering: pooled damage every 3 s
  if pool_acc >= 3000 then
    pool_acc = 0
    if Pool > 0 then
      for k, e in pairs(Infected) do
        if alive(e.bot) then
          local pc = pc_of(e.name)
          if pc and alive(pc.Pawn) then deal(pc.Pawn, e.bot, element_damage(pc.Pawn, Data.ELEMENT_BY_ID.void, Pool)) end
        else Infected[k] = nil end
      end
      Pool = 0
    end
  end
  -- auras
  local keep = {}
  for _, a in ipairs(Auras) do
    if a.stop > now_ms and alive(a.pawn) then
      keep[#keep + 1] = a
      if now_ms >= a.start and now_ms >= a.next then
        local it, n = a.it, a.n
        local period = it.cd > 0 and it.cd or 1
        a.next = now_ms + sec_ms(period)
        local ctx = { pawn = a.pawn, name = a.name, st = a.st, g = gstate(a.st) }
        if it.sub == "turret" then
          local list = bots_near(a.pawn, it.radius, nil)
          if #list > 0 then local t = list[math.random(#list)]; fx_at("ukulele_hit", t); ghit(a.pawn, t, it, n, per(it.dmg, it.dmg_per, n) * ctx.g.base) end
        elseif it.sub == "storm" then
          local r = math.min(per(it.cap, it.cap_per, n), it.radius + it.k * a.kills)
          for _, b in ipairs(bots_near(a.pawn, r, nil)) do ghit(a.pawn, b, it, n, it.dmg * ctx.g.base) end
        elseif it.sub == "transmit" then
          for _, b in ipairs(bots_near(a.pawn, it.radius, nil)) do ghit(a.pawn, b, it, n, it.dmg * ctx.g.base) end
        elseif it.sub == "heal_zone" then
          if not a.fx then a.fx = true; fx("heal", a.x, a.y, a.z) end
          for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
            local p = valid(pc) and pc.Pawn
            if alive(p) then
              local x, y, z = loc(p)
              if math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2) <= radius_of(it, n) then heal_player(player_name(pc), p, it.dmg * p:GetHealthMax()) end
            end
          end
        elseif it.sub == "buff_zone" then
          for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
            local p = valid(pc) and pc.Pawn
            if alive(p) then
              local x, y, z = loc(p)
              if math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2 + (z - a.z) ^ 2) <= radius_of(it, n) then
                local c2 = ctx_for(pc)
                BUFF_FROM({ id = it.id, ge = it.ge, op = it.op, k = it.k, k_per = 0, ge2 = it.ge2, op2 = it.op2, k2 = it.k2, dur = period + 0.2, dur_per = 0, cap = 1, cap_per = 0 }, 1, c2)
              end
            end
          end
        end
      end
    end
  end
  Auras = keep
end

-- entry points from the hooks -----------------------------------------------------------------
local function engine_kill(victim, killer)
  local pc = killer.Controller
  if not valid(pc) then return end
  local ctx = ctx_for(pc, { victim = victim })
  local g = ctx.g
  table.insert(g.kills, now_ms)
  local keep = {}
  for _, t in ipairs(g.kills) do if now_ms - t <= 7000 then keep[#keep + 1] = t end end
  g.kills = keep
  fire("kill", ctx)
  if is_elite(victim) then fire("elitekill", ctx) end
  -- multikill: Berzerker (4 in 1 s) and Resonance Disc (4 in 7 s)
  local recent1, recent7 = 0, #g.kills
  for _, t in ipairs(g.kills) do if now_ms - t <= 1000 then recent1 = recent1 + 1 end end
  local saved = g.kills
  for _, it in ipairs(ITEMS_BY_TRIGGER.multikill or {}) do
    local window = it.id == "WarCryOnMultiKill" and recent1 or recent7
    if window >= it.cv and count(ctx.st, it.id) > 0 then
      g.kills = { 1, 2, 3, 4, 5, 6, 7, 8 }
      local list = ITEMS_BY_TRIGGER.multikill
      ITEMS_BY_TRIGGER.multikill = { it }
      fire("multikill", ctx)
      ITEMS_BY_TRIGGER.multikill = list
      g.kills = (it.id == "LaserTurbine") and {} or saved
    end
  end
  special_kill(ctx)
end
local function engine_hit(victim, inst, amount, d)
  local pc = inst.Controller
  if not valid(pc) then return end
  local ctx = ctx_for(pc, { victim = victim, amount = amount, d = d })
  local g = ctx.g
  g.last_hit = now_ms
  g.base = g.base * 0.9 + amount * 0.1
  for _, b in pairs(g.buffs) do if b.it.refresh == "hit" then b.untilT = math.max(b.untilT, now_ms + sec_ms(per(b.it.dur, b.it.dur_per, b.n))) end end
  if Infected[addr(victim)] then Pool = Pool + amount * Data.ITEM_BY_ID.SharedSuffering.k end
  fire("hit", ctx)
  local crit = false
  pcall(function() crit = d.bCriticalHit end)
  if crit then fire("crit", ctx) end
  Procs.crit = "none"
  special_hit(ctx)
  Procs.crit = nil
end
local function engine_hurt(victim, amount, d)
  local pc = victim.Controller
  if not valid(pc) then return end
  local ctx = ctx_for(pc, { amount = amount, d = d })
  special_hurt(ctx)
  fire("hurt", ctx) -- before marking combat, so "out of combat" items see the first hit
  ctx.g.last_hurt = now_ms
  local broke = false
  pcall(function() broke = d.bShieldBroke end)
  if broke then fire("shieldbreak", ctx) end
end
local function engine_all(trigger)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and alive(pc.Pawn) then fire(trigger, ctx_for(pc)) end
  end
end
local function engine_orb(pc) if valid(pc) and alive(pc.Pawn) then fire("orb", ctx_for(pc)) end end
local function engine_stage_start() Run.stage = (Run.stage or 0) + 1; engine_all("stage") end

---------------------------------------------------------------------------
-- hooks (host)
---------------------------------------------------------------------------
local function on_bot_killed(victim, killer)
  local va = addr(victim)
  if va == 0 or Run.killed[va] then return end
  Run.killed[va] = true
  if not valid(killer) or not killer:IsPlayerControlled() then return end
  after(0, function()
    local okg, errg = pcall(engine_kill, victim, killer)
    if not okg then log("engine kill: " .. tostring(errg)) end
  end)
  local pc = killer.Controller
  if not valid(pc) then return end
  local name = player_name(pc)
  local st = pstate(name)
  local vmax = 250
  pcall(function() vmax = victim:GetHealthMax() end)
  local vx, vy, vz = 0, 0, 0
  pcall(function() vx, vy, vz = loc(victim) end)

  local tooth = count(st, "Tooth")
  if tooth > 0 then local it = Data.ITEM_BY_ID.Tooth; heal_player(name, killer, it.dmg + it.k * tooth); notify(name, "b", "tooth_regen"); fx_at("heal", killer) end

  local inf = count(st, "Infusion")
  if inf > 0 then
    local it = Data.ITEM_BY_ID.Infusion
    if st.infusion < it.dmg * inf then st.infusion = st.infusion + it.k * inf; after(0, function() apply_items(name) end) end
  end

  local wisp = count(st, "Wisp")
  if wisp > 0 then
    local it = Data.ITEM_BY_ID.Wisp
    local radius = it.radius + it.radius_per * (wisp - 1)
    local dmg = it.dmg * vmax * (1 + it.dmg_per * (wisp - 1))
    after(150, function()
      local n = 0
      fx("wisp_blast", vx, vy, vz)
      for _, b in ipairs(FindAllOf("ValCharacter") or {}) do
        if is_bot(b) and alive(b) then
          local bx, by, bz = loc(b)
          if math.sqrt((bx - vx) ^ 2 + (by - vy) ^ 2 + (bz - vz) ^ 2) <= radius then item_hit(killer, b, it, dmg); n = n + 1 end
        end
      end
      if n > 0 then notify(name, "t", "Will-o'-the-wisp detonated: " .. n .. " hit") end
    end)
  end

  local gas = count(st, "Gasoline")
  if gas > 0 then
    local it = Data.ITEM_BY_ID.Gasoline
    local radius = it.radius + it.radius_per * (gas - 1)
    local total = it.dmg * vmax * (1 + it.dmg_per * (gas - 1))
    local tank = count(st, "StrengthenBurn")
    if tank > 0 then local t = Data.ITEM_BY_ID.StrengthenBurn; total = total * (1 + per(t.k, t.k_per, tank)) end
    local targets = {}
    for _, b in ipairs(FindAllOf("ValCharacter") or {}) do
      if is_bot(b) and alive(b) and addr(b) ~= va then
        local bx, by, bz = loc(b)
        if math.sqrt((bx - vx) ^ 2 + (by - vy) ^ 2 + (bz - vz) ^ 2) <= radius then targets[#targets + 1] = b end
      end
    end
    if #targets > 0 then
      notify(name, "t", "Gasoline ignited " .. #targets .. " enemies")
      notify(name, "b", "on_fire")
      fx("gasoline_blast", vx, vy, vz)
      for _, b in ipairs(targets) do fx_at("gasoline_burn", b); apply_status(killer, b, Data.ELEMENT_BY_ID[it.element]) end
      for tick = 1, 3 do
        after(1000 * tick, function() for _, b in ipairs(targets) do if alive(b) then item_hit(killer, b, it, total / 3) end end end)
      end
    end
  end
end

_G.R2_ON_KILL = function(v, k) local ok, err = pcall(on_bot_killed, v, k); if not ok then log("kill error: " .. tostring(err)) end end
local function on_damaged(victim, d)
  if not valid(victim) then return end
  -- Kills: the game's OnBotKilled event stopped firing (no calls for gun or mod kills, checked
  -- live), so a killing blow on a bot is detected here instead. Covers mod kills too (GE_Suicide).
  if not victim:IsPlayerControlled() then
    local lethal = false
    pcall(function() lethal = d.bKillingBlow end)
    if not lethal then pcall(function() lethal = victim:GetHealth() <= 0 end) end
    if lethal then
      local killer = nil
      pcall(function() killer = d.Instigator:Get() end)
      if valid(killer) and killer:IsPlayerControlled() then
        local ok, err = pcall(on_bot_killed, victim, killer)
        if not ok then log("kill error: " .. tostring(err)) end
      end
      return
    end
  end
  -- Deadzone reports damage as a negative Amount (-910 for a sniper crit); the execute
  -- effect reports about -1e6, which is ours or an instant kill and is skipped.
  local amount = d.Amount and math.abs(d.Amount) or 0
  if amount <= 0 or amount > 100000 then return end
  if victim:IsPlayerControlled() then
    -- hurt items on the victim player
    local pc = victim.Controller
    if not valid(pc) then return end
    local name = player_name(pc)
    local st = pstate(name)
    local plate = count(st, "ArmorPlate")
    if plate > 0 and not d.bShieldDamage then
      local refund = math.min(amount - 1, Data.ITEM_BY_ID.ArmorPlate.k * plate)
      if refund > 0 and victim:GetHealth() > 0 then heal(victim, refund) end
    end
    local dd = { bShieldBroke = false }
    pcall(function() dd.bShieldBroke = d.bShieldBroke end)
    after(0, function()
      local okh, errh = pcall(engine_hurt, victim, amount, dd)
      if not okh then log("engine hurt: " .. tostring(errh)) end
    end)
    local med = count(st, "Medkit")
    if med > 0 then
      notify(name, "b", "medkit_heal")
      after(SYS.medkit_delay_ms, function() heal_player(name, victim, Data.ITEM_BY_ID.Medkit.k * med); fx_at("heal", victim) end)
    end
    return
  end
  -- on-hit items for the attacking player
  if d.bFromProcAbility then return end
  local inst = d.Instigator:Get()
  if not valid(inst) or not inst:IsPlayerControlled() then return end
  local pc = inst.Controller
  if not valid(pc) then return end
  local name = player_name(pc)
  local st = pstate(name)
  local dd = { bCriticalHit = false }
  pcall(function() dd.bCriticalHit = d.bCriticalHit end)
  after(0, function()
    local okh, errh = pcall(engine_hit, victim, inst, amount, dd)
    if not okh then log("engine hit: " .. tostring(errh)) end
  end)
  local uke = count(st, "Ukulele")
  if uke > 0 and roll(st, Data.ITEM_BY_ID.Ukulele.chance) then
    local it = Data.ITEM_BY_ID.Ukulele
    local targets = 3 + it.k * (uke - 1)
    local dmg = it.dmg * amount
    local near = bots_near(victim, it.radius, victim)
    table.sort(near, function(a, b) return dist(a, victim) < dist(b, victim) end)
    local hits = {}
    for i = 1, math.min(targets, #near) do hits[#hits + 1] = near[i] end
    if #hits > 0 then
      after(0, function() Procs.crit = "none"; for _, b in ipairs(hits) do fx_at("ukulele_hit", b); item_hit(inst, b, it, dmg) end; Procs.crit = nil end)
      notify(name, "t", "Ukulele chained to " .. #hits .. " enemies")
      notify(name, "b", "tesla")
    end
  end
  local beh = count(st, "Behemoth")
  if beh > 0 then
    local it = Data.ITEM_BY_ID.Behemoth
    local radius = it.radius + it.radius_per * (beh - 1)
    local near = bots_near(victim, radius, victim)
    if (st.last_behemoth or 0) + 150 <= now_ms then st.last_behemoth = now_ms; fx_at("behemoth_blast", victim) end
    if #near > 0 then after(0, function() Procs.crit = "none"; for _, b in ipairs(near) do item_hit(inst, b, it, it.dmg * amount) end; Procs.crit = nil end) end
  end
end

local function on_new_character(c)
  after(800, function()
    if not is_bot(c) or not alive(c) then return end
    local srv, gm = server()
    if not srv or in_hub(gm) then return end
    local a = addr(c)
    if Run.buffed[a] then return end
    Run.buffed[a] = true
    clock_buff(c)
    note_bot_hp(c)
  end)
end

local hooks_ok = {}
local function hook(id, fn)
  local target = Data.HOOKS[id]
  local ok, err = pcall(function() RegisterHook(target, fn) end)
  hooks_ok[id] = ok
  if not ok then log("hook " .. id .. " failed: " .. tostring(err)) end
end
hook("bot_killed", function(self, victim, killer)
  local srv = server(); if not srv then return end
  local v, k = victim:get(), killer:get()
  local ok, err = pcall(on_bot_killed, v, k); if not ok then log("kill error: " .. tostring(err)) end
end)
hook("damaged", function(self, data)
  local srv = server(); if not srv then return end
  local ok, err = pcall(on_damaged, self:get(), data:get()); if not ok then log("damage error: " .. tostring(err)) end
end)
local okn, errn = pcall(function() NotifyOnNewObject(Data.HOOKS.new_character, function(c) on_new_character(c) end) end)
if not okn then log("NotifyOnNewObject failed: " .. tostring(errn)) end
local okb, errb = pcall(function()
  NotifyOnNewObject(Data.HOOKS.new_bundle, function(b)
    after(500, function() if server() then roll_offer(b) end end)
  end)
end)
if not okb then log("bundle watch failed: " .. tostring(errb)) end

local last_encounter = -1e9
hook("encounter", function()
  if not server() or now_ms - last_encounter < 20000 then return end
  last_encounter = now_ms
  after(0, function() local ok, err = pcall(engine_all, "encounter"); if not ok then log("encounter: " .. tostring(err)) end end)
end)

-- every machine: the local player's click on an orb card
hook("request_pick", function(self, pickup, index)
  local pc, b, i = self:get(), pickup:get(), index:get()
  if not valid(b) or not valid(pc) then return end
  if server() and i ~= SYS.orb_block_index then after(0, function() pcall(engine_orb, pc) end) end
  local key = bundle_key(b)
  local off = Offers[key]
  if not off or off.slot ~= i or not ShownCards[key] then return end
  ShownCards[key] = nil
  if server() then
    index:set(SYS.orb_block_index)
    grant_orb(pc, b, off, key)
  else
    index:set(SYS.orb_client_index_offset + i)
  end
end)
-- host: a remote player's marked RoR2 pick
hook("server_pick", function(self, pickup, index)
  if not server() then return end
  local i = index:get()
  do local rpc = self:get(); after(0, function() pcall(engine_orb, rpc) end) end
  if i < SYS.orb_client_index_offset then return end
  local pc, b = self:get(), pickup:get()
  index:set(SYS.orb_block_index)
  if not valid(b) then return end
  local key = bundle_key(b)
  local off = Offers[key]
  if off and off.slot == i - SYS.orb_client_index_offset then grant_orb(pc, b, off, key) end
end)

-- client side: state from the host
local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
  return out
end
hook("client_message", function(self, s)
  local msg = s:get():ToString()
  if msg:sub(1, #TAG) ~= TAG then return end
  local f = split(msg:sub(#TAG + 1), "|")
  if f[1] == "s" then
    View.in_run = f[2] == "1"
    View.clock = tonumber(f[3]) or 0
    View.items = {}
    for _, kv in ipairs(split(f[4] or "", ",")) do
      local k, v = kv:match("([^:]+):(%d+)")
      if k then View.items[k] = tonumber(v) end
    end
  elseif f[1] == "o" then Offers[f[2]] = { slot = tonumber(f[3]) or 0, item = f[4] }
  elseif f[1] == "p" then table.insert(View.banners, { id = f[2], t = now_ms })
  elseif f[1] == "b" then local b = BUFF_BY_ID[f[2]]; if b then View.buffs[f[2]] = now_ms + b.duration_ms; View.bcount[f[2]] = 1 end
  elseif f[1] == "B" then if BUFF_BY_ID[f[2]] and tonumber(f[3]) then View.buffs[f[2]] = now_ms + tonumber(f[3]); View.bcount[f[2]] = tonumber(f[4]) or 1 end
  elseif f[1] == "t" then ticker(f[2])
  elseif f[1] == "f" then spawn_fx_local(f[2], tonumber(f[3]) or 0, tonumber(f[4]) or 0, tonumber(f[5]) or 0)
  elseif f[1] == "j" then
    local pc = local_pc()
    if pc and valid(pc.Pawn) then pc.Pawn.JumpMaxCount = tonumber(f[2]) or pc.Pawn.JumpMaxCount end
  end
end)

---------------------------------------------------------------------------
-- Deadzone effects for RoR2 procs (host spawns and tells clients)
---------------------------------------------------------------------------
local FX_BY_ID = {}
for _, f in ipairs(Data.FX) do FX_BY_ID[f.id] = f end
local NS_CACHE = {}
local function ns_asset(path)
  local a = NS_CACHE[path]
  if valid(a) then return a end
  a = StaticFindObject(path)
  if not valid(a) then pcall(function() a = LoadAsset(path) end) end
  NS_CACHE[path] = a
  return a
end
spawn_fx_local = function(id, x, y, z)
  local f = FX_BY_ID[id]
  if not f then return end
  local ns = ns_asset(f.system)
  local pc = local_pc()
  if not valid(ns) or not valid(pc) then return end
  pcall(function()
    cls("/Script/Niagara.Default__NiagaraFunctionLibrary"):SpawnSystemAtLocation(pc, ns, { X = x, Y = y, Z = z },
      { Pitch = 0, Yaw = 0, Roll = 0 }, { X = f.scale, Y = f.scale, Z = f.scale }, true, true, 0, true)
  end)
end
fx = function(id, x, y, z)
  spawn_fx_local(id, x, y, z)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    send(pc, string.format("f|%s|%d|%d|%d", id, math.floor(x), math.floor(y), math.floor(z)))
  end
end
fx_at = function(id, actor)
  if valid(actor) then local x, y, z = loc(actor); fx(id, x, y, z) end
end

---------------------------------------------------------------------------
-- RoR2 items as native Deadzone items.
-- Each RoR2 item gets its own Deadzone item definition (a rooted copy of a vanilla
-- ValAbilityAsset carrying the RoR2 name, description and rarity). Deadzone's own widgets then
-- draw it: the item row under the minimap (fed through the display's OnItemIdsChanged, with
-- GetAssetById hooked to resolve RoR2 ids), the Tab menu and end-of-run grids (UpdateAsset on
-- the next free slot) and Deadzone's own hover tooltip. Only RoR2 items stack (x2, x3...).
---------------------------------------------------------------------------
local INV = Data.INV
local Native = { defs = {}, by_name = {}, tex = nil, hooked = false, resolve_ok = nil, pushed = "" }
local function ror2_name(id) return "RoR2_" .. id end
local function ror2_asset_id(id)
  return { PrimaryAssetType = { Name = FName(INV.asset_type) }, PrimaryAssetName = FName(ror2_name(id)) }
end
local function item_def(it)
  local d = Native.defs[it.id]
  if valid(d) then return d end
  d = StaticFindObject("/Engine/Transient." .. ror2_name(it.id))
  if not valid(d) then
    local tmpl = StaticFindObject(INV.item_template)
    if not valid(tmpl) then pcall(function() tmpl = LoadAsset(INV.item_template) end) end
    if not valid(tmpl) then return nil end
    -- RF_Transient | RF_MarkAsRootSet: never saved, never garbage-collected
    d = StaticConstructObject(tmpl:GetClass(), StaticFindObject("/Engine/Transient"), FName(ror2_name(it.id)), 0xC0, 0, false, false, tmpl)
  end
  if not valid(d) then return nil end
  local rar = Data.RARITY_BY_ID[it.rarity]
  d.DisplayName = FText(it.name)
  d.Description = FText(it.pickup .. "\n" .. (it.desc_rich or ("<em>" .. it.desc .. "</>")) .. "\n// " .. string.upper(Data.RARITY_BY_ID[it.rarity].name or it.rarity) .. " ITEM")
  d.Rarity = rar.dz_rarity
  pcall(function() d.MaxStackSize = 999 end)
  pcall(function() d.AssetId = ror2_asset_id(it.id) end)
  Native.defs[it.id] = d
  Native.by_name[ror2_name(it.id)] = it
  return d
end
local function id_name(e)
  local s = nil
  pcall(function() s = e.PrimaryAssetName:ToString() end)
  return s
end
local function ror2_item_for(e)
  local n = id_name(e)
  return n and Native.by_name[n] or nil
end

local function install_native_hooks()
  if Native.hooked then return end
  Native.hooked = true
  -- RoR2 ids resolve to their definitions wherever Deadzone's UI looks an item up
  local ok, err = pcall(function()
    RegisterHook(INV.get_asset_fn, function() end, function(ctx, asset_id)
      local it = ror2_item_for(asset_id:get())
      if it then return item_def(it) end
    end)
  end)
  log("hook GetAssetById: " .. tostring(ok) .. " " .. tostring(err or ""))
  -- the HUD row's material gets the RoR2 icon
  ok, err = pcall(function()
    RegisterHook(INV.brush_fn, function(self, asset_id, mid)
      local it = ror2_item_for(asset_id:get())
      local m = mid:get()
      if it and valid(m) and Native.tex and valid(Native.tex[it.id]) then
        m:SetTextureParameterValue(FName(INV.icon_param), Native.tex[it.id])
        m:SetScalarParameterValue(FName("Rarity"), Data.RARITY_BY_ID[it.rarity].dz_rarity - 1)
      end
    end)
  end)
  log("hook UpdateBrushForItem: " .. tostring(ok) .. " " .. tostring(err or ""))
end

local function vanilla_ids(pc)
  local list = {}
  pcall(function()
    local a = pc.PlayerState[INV.owned_items]
    for i = 1, a:GetArrayNum() do
      local e = a[i]
      list[#list + 1] = { PrimaryAssetType = { Name = e.PrimaryAssetType.Name }, PrimaryAssetName = e.PrimaryAssetName }
    end
  end)
  return list
end
local function vanilla_count(pc)
  local n = 0
  pcall(function() n = pc.PlayerState[INV.owned_items]:GetArrayNum() end)
  return n
end
local function owned_list()
  local list = {}
  for _, it in ipairs(Data.ITEMS) do
    local n = View.items[it.id] or 0
    if n > 0 then list[#list + 1] = { id = it.id, n = n } end
  end
  return list
end
local INVENTORY_SLOTS = 18
can_take = function(id)
  if (View.items[id] or 0) > 0 then return true end
  local pc = local_pc()
  if not valid(pc) then return false end
  return vanilla_count(pc) + #owned_list() < INVENTORY_SLOTS
end

-- HUD item row under the minimap
local function find_hud_display()
  for _, w in ipairs(FindAllOf(INV.hud_display_class) or {}) do
    if valid(w) then
      local fn = w:GetFullName()
      if fn:find("^" .. INV.hud_display_class .. " /Engine/Transient") and fn:find(INV.hud_display_owner) then return w end
    end
  end
end
local function shown_ids(disp)
  local s = {}
  pcall(function()
    local a = disp.ActiveItemIds
    for i = 1, a:GetArrayNum() do local n = id_name(a[i]); if n then s[n] = true end end
  end)
  return s
end
local function push_hud(pc, list)
  local disp = find_hud_display()
  if not valid(disp) then return end
  local shown = shown_ids(disp)
  local want, key = {}, ""
  for _, e in ipairs(list) do
    if item_def(Data.ITEM_BY_ID[e.id]) then want[ror2_name(e.id)] = true; key = key .. e.id .. "," end
  end
  local stale = false
  for n in pairs(want) do if not shown[n] then stale = true end end
  for n in pairs(shown) do if Native.by_name[n] and not want[n] then stale = true end end
  if not stale then return end
  local ids = vanilla_ids(pc)
  for _, e in ipairs(list) do if want[ror2_name(e.id)] then ids[#ids + 1] = ror2_asset_id(e.id) end end
  local ok, err = pcall(function() disp:OnItemIdsChanged(ids) end)
  if not ok and Native.pushed ~= key then log("HUD item row: " .. tostring(err)) end
  Native.pushed = key
end

-- Tab menu / end-of-run grids: RoR2 items take the slots after the vanilla items
local function fill_slot(slot, it, n, ps)
  local d = item_def(it)
  if not valid(d) then return end
  local cur = nil
  pcall(function() cur = slot.CachedDataAsset end)
  if not (valid(cur) and addr(cur) == addr(d)) then
    pcall(function() slot:UpdateAsset(d, ps) end)
  end
  pcall(function() slot.bTooltipDisabled = false end)
  local icon, stack = slot[INV.slot_icon], slot[INV.slot_stack]
  local tex = Native.tex and Native.tex[it.id]
  if valid(icon) and valid(tex) then icon:SetBrushFromTexture(tex, false); icon:SetVisibility(VIS) end
  if valid(stack) then
    stack:SetText(FText(n > 1 and ("x" .. n) or ""))
    stack:SetVisibility(n > 1 and VIS or HID)
  end
end
patch_inventory = function(tex, pc)
  Native.tex = tex
  local list = owned_list()
  local ps = pc.PlayerState
  for _, g in ipairs(FindAllOf("UI_Equipment_Perks_Items_C") or {}) do
    local fn = valid(g) and g:GetFullName() or ""
    if fn:find("^[%w_]+ /Engine/Transient") and g:IsVisible() then
      if fn:find(INV.tab_grid_owner) or fn:find(INV.end_grid_owner) then
        local grid = find_named(g, "ItemGrid")
        if valid(grid) then
          local start = vanilla_count(pc)
          INVENTORY_SLOTS = grid:GetChildrenCount()
          for i, e in ipairs(list) do
            local idx = start + i - 1
            if idx < INVENTORY_SLOTS then
              local slot = grid:GetChildAt(idx)
              if valid(slot) then fill_slot(slot, Data.ITEM_BY_ID[e.id], e.n, ps) end
            end
          end
        end
      end
    end
  end
  -- The item row under the minimap is parked: feeding it RoR2 ids needed native hooks
  -- (GetAssetById / UpdateBrushForItem) that crashed the mod loader. See MODLOG.
end
local function update_tip() end -- Deadzone's own tooltip is used now

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local HUD = nil
local function new(classpath, outer, name) return StaticConstructObject(cls(classpath), outer, FName(name)) end
local function text(wt, canvas, name, size)
  local tb = new("/Script/UMG.TextBlock", wt, name)
  local f = tb.Font; f.Size = size; tb:SetFont(f)
  tb:SetShadowOffset({ X = 1.5, Y = 1.5 })
  tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
  local slot = canvas:AddChildToCanvas(tb)
  slot:SetAutoSize(true)
  return tb, slot
end
local function image(wt, canvas, name)
  local img = new("/Script/UMG.Image", wt, name)
  local slot = canvas:AddChildToCanvas(img)
  return img, slot
end
local function color(tb, c, a) tb:SetColorAndOpacity({ SpecifiedColor = { R = c[1], G = c[2], B = c[3], A = a or 1 }, ColorUseRule = 0 }) end
local function anchor(slot, ax, ay, px, py, sx, sy, alx, aly)
  slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
  slot:SetAlignment({ X = alx or 0, Y = aly or 0 })
  slot:SetPosition({ X = px, Y = py })
  if sx then slot:SetSize({ X = sx, Y = sy }) end
end

---------------------------------------------------------------------------
-- test menu: F1 opens it; the other keys only work while it is open (host or solo)
---------------------------------------------------------------------------
local Dev = { open = false, god = false, sel = 1, msg = "", msg_t = 0 }
local KEYS = {
  { "F1", "open / close this menu" },
  { "F2", "god mode on / off" },
  { "Up / Down  (or F3 / F4)", "select an item  (PgUp / PgDn: 10 at a time)" },
  { "Right / Enter  (or F5)", "give 1 of the selected item" },
  { "Left / Backspace  (or F6)", "remove 1 of the selected item" },
  { "F7", "give 1 of every RoR2 item" },
  { "F8", "remove all RoR2 items" },
  { "F9", "difficulty clock: jump to next tier" },
  { "F10", "kill enemies within 30 m (procs fire)" },
  { "Home", "run the item self-test (press again to stop)" },
  { "End", "re-test only the items that failed last time" },
}
local function dev_msg(t) Dev.msg = t; Dev.msg_t = now_ms; log("test menu: " .. t) end
draw_menu = function(H)
  local show = Dev.open
  H.menu_bg:SetVisibility(show and VIS or HID)
  for _, tb in ipairs(H.menu_lines) do tb:SetVisibility(show and VIS or HID) end
  if not show then return end
  local lines = {}
  local function add(t, c) lines[#lines + 1] = { t, c or { 0.88, 0.88, 0.88 } } end
  add("RoR2 MASHUP  //  TEST MENU", { 1, 0.85, 0.35 })
  add("God mode: " .. (Dev.god and "ON" or "off") .. "     Clock: " .. string.format("%02d:%02d", math.floor(View.clock) // 60, math.floor(View.clock) % 60) .. " " .. Data.DIFFICULTY_TIERS[tier_index(View.clock)].name,
      Dev.god and { 0.5, 1, 0.5 } or nil)
  add(" ")
  local rows = 20
  local first = clamp(Dev.sel - rows // 2, 1, math.max(1, #Data.ITEMS - rows + 1))
  add(string.format("Item %d / %d   (PgUp / PgDn jump 10)", Dev.sel, #Data.ITEMS), { 0.6, 0.65, 0.7 })
  for i = first, math.min(#Data.ITEMS, first + rows - 1) do
    local it = Data.ITEMS[i]
    local n = View.items[it.id] or 0
    local mark = (i == Dev.sel) and "> " or "   "
    local c = Data.RARITY_BY_ID[it.rarity].color
    if i ~= Dev.sel then c = { c[1] * 0.75, c[2] * 0.75, c[3] * 0.75 } end
    local el = it.element ~= "none" and ("  [" .. Data.ELEMENT_BY_ID[it.element].name .. "]") or ""
    add(mark .. it.name .. (n > 0 and ("  x" .. n) or "") .. el, c)
  end
  add(" ")
  for _, k in ipairs(KEYS) do add(k[1] .. "   " .. k[2], { 0.7, 0.75, 0.8 }) end
  add((now_ms - Dev.msg_t < 4000) and Dev.msg or " ", { 0.95, 0.9, 0.6 })
  for i, tb in ipairs(H.menu_lines) do
    local l = lines[i]
    if l then tb:SetText(FText(l[1])); color(tb, l[2]) else tb:SetText(FText("")) end
  end
end

local function dev_action(key)
  if key == "F1" then Dev.open = not Dev.open; return end
  if not Dev.open then return end
  local srv = server()
  local pc = local_pc()
  if not srv or not valid(pc) then dev_msg("Only the host (or solo) can use the test menu"); return end
  local name = player_name(pc)
  local it = Data.ITEMS[Dev.sel]
  if key == "F2" then
    Dev.god = not Dev.god
    if not Dev.god and alive(pc.Pawn) then
      for _, set in ipairs(FindAllOf("ValAttributeSet") or {}) do
        if valid(set) and addr(set:GetOuter()) == addr(pc.Pawn) then set.TemporaryShield.BaseValue = 0; set.TemporaryShield.CurrentValue = 0 end
      end
    end
    dev_msg("God mode " .. (Dev.god and "ON" or "off"))
  elseif key == "F3" then Dev.sel = (Dev.sel - 2) % #Data.ITEMS + 1
  elseif key == "F4" then Dev.sel = Dev.sel % #Data.ITEMS + 1
  elseif key == "PGUP" then Dev.sel = math.max(1, Dev.sel - 10)
  elseif key == "PGDN" then Dev.sel = math.min(#Data.ITEMS, Dev.sel + 10)
  elseif key == "F5" then give(name, it.id, 1); dev_msg("Gave " .. it.name)
  elseif key == "F6" then take(name, it.id, 1); dev_msg("Removed " .. it.name)
  elseif key == "F7" then
    local st = pstate(name)
    for _, x in ipairs(Data.ITEMS) do st.items[x.id] = count(st, x.id) + 1 end
    apply_items(name)
    dev_msg("Gave one of every item (" .. #Data.ITEMS .. ")")
  elseif key == "F8" then take_all(name); dev_msg("Removed all RoR2 items")
  elseif key == "F9" then
    local ti = tier_index(Run.clock)
    local nxt = Data.DIFFICULTY_TIERS[ti + 1]
    Run.clock = nxt and (nxt.start_min * 60 + 1) or 0
    dev_msg("Clock -> " .. Data.DIFFICULTY_TIERS[tier_index(Run.clock)].name)
  elseif key == "F10" then
    local pawn = pc.Pawn
    if not alive(pawn) then return end
    local n = 0
    for _, b in ipairs(bots_near(pawn, 3000, nil)) do deal(pawn, b, b:GetHealth() + 1); n = n + 1 end
    dev_msg("Killed " .. n .. " enemies")
  elseif key == "END" then
    if Dev.ST.running then Dev.ST.stop = true; dev_msg("Stopping the self-test after this item..."); return end
    local only, n = {}, 0
    local f = io.open(MOD .. "selftest_failed.txt", "r")
    if f then for line in f:lines() do local id = line:match("^%s*(%S+)") ; if id and Data.ITEM_BY_ID[id] then only[id] = true; n = n + 1 end end; f:close() end
    if n == 0 then dev_msg("No failed items to re-test (run the full self-test with Home first)")
    else dev_msg("Re-testing " .. n .. " failed item(s): " .. tostring(Dev.ST.start(only))) end
  elseif key == "HOME" then
    if Dev.ST.running then Dev.ST.stop = true; dev_msg("Stopping the self-test after this item...")
    else dev_msg("Self-test: " .. tostring(Dev.ST.start(nil)) .. "  (results: selftest.txt)") end
  end
end
-- extra keys for moving through the item list (they map onto the F-key actions)
local ALIAS = { UP_ARROW = "F3", DOWN_ARROW = "F4", RIGHT_ARROW = "F5", RETURN = "F5", LEFT_ARROW = "F6", BACKSPACE = "F6", PAGE_UP = "PGUP", PAGE_DOWN = "PGDN" }
for _, k in ipairs({ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "HOME", "END", "UP_ARROW", "DOWN_ARROW", "RIGHT_ARROW", "LEFT_ARROW", "RETURN", "BACKSPACE", "PAGE_UP", "PAGE_DOWN" }) do
  local ok, err = pcall(function()
    RegisterKeyBind(Key[k], function()
      ExecuteInGameThread(function()
        local act = ALIAS[k] or k
        if ALIAS[k] and not Dev.open then return end
        local ok2, err2 = pcall(dev_action, act)
        if not ok2 then log("test menu " .. k .. ": " .. tostring(err2)) end
      end)
    end)
  end)
  if not ok then log("keybind " .. k .. " failed: " .. tostring(err)) end
end

local function build_hud(pc)
  local w = new("/Script/UMG.UserWidget", pc, "RoR2MashupHUD")
  local wt = new("/Script/UMG.WidgetTree", w, "WT")
  w.WidgetTree = wt
  local canvas = new("/Script/UMG.CanvasPanel", wt, "Root")
  wt.RootWidget = canvas
  local krl = cls("/Script/Engine.Default__KismetRenderingLibrary")
  local tex = {}
  for _, it in ipairs(Data.ITEMS) do tex[it.id] = krl:ImportFileAsTexture2D(pc, MOD .. "icons/" .. it.icon .. ".png") end
  for _, b in ipairs(Data.BUFFS) do tex["buff_" .. b.id] = krl:ImportFileAsTexture2D(pc, MOD .. "icons/" .. b.icon .. ".png") end
  local H = { w = w, pc = pc, tex = tex, slots = {} }
  -- Imported textures are transient: keep each one referenced by a hidden image so the
  -- garbage collector can't free it while the HUD might still show it.
  local ki = 0
  for _, t in pairs(tex) do
    ki = ki + 1
    local keep = new("/Script/UMG.Image", wt, "TexKeep" .. ki)
    keep:SetBrushFromTexture(t, false)
    canvas:AddChildToCanvas(keep)
    keep:SetVisibility(HID)
  end

  -- difficulty clock (top right, under the currency counters)
  H.clock_bg, H.clock_bg_slot = image(wt, canvas, "ClockBg")
  H.clock_bg:SetColorAndOpacity({ R = 0.05, G = 0.05, B = 0.07, A = 0.55 })
  anchor(H.clock_bg_slot, 1, 0, -24, 64, 250, 76, 1, 0)
  H.clock, H.clock_slot = text(wt, canvas, "ClockTime", 26)
  anchor(H.clock_slot, 1, 0, -36, 66, nil, nil, 1, 0)
  H.tier, H.tier_slot = text(wt, canvas, "ClockTier", 15)
  anchor(H.tier_slot, 1, 0, -36, 104, nil, nil, 1, 0)
  H.bar_bg, H.bar_bg_slot = image(wt, canvas, "BarBg")
  H.bar_bg:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0.15 })
  anchor(H.bar_bg_slot, 1, 0, -36, 128, 226, 6, 1, 0)
  H.bar, H.bar_slot = image(wt, canvas, "Bar")
  anchor(H.bar_slot, 1, 0, -262, 128, 0, 6, 0, 0)

  -- pickup banner (lower centre)
  H.ban_bg, H.ban_bg_slot = image(wt, canvas, "BanBg")
  H.ban_bg:SetColorAndOpacity({ R = 0.03, G = 0.03, B = 0.05, A = 0.7 })
  anchor(H.ban_bg_slot, 0.5, 1, 0, -170, 560, 92, 0.5, 1)
  H.ban_icon, H.ban_icon_slot = image(wt, canvas, "BanIcon")
  anchor(H.ban_icon_slot, 0.5, 1, -270, -178, 76, 76, 0, 1)
  H.ban_name, H.ban_name_slot = text(wt, canvas, "BanName", 24)
  anchor(H.ban_name_slot, 0.5, 1, -180, -218, nil, nil, 0, 1)
  H.ban_desc, H.ban_desc_slot = text(wt, canvas, "BanDesc", 16)
  anchor(H.ban_desc_slot, 0.5, 1, -180, -186, nil, nil, 0, 1)
  for _, x in ipairs({ H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do x:SetVisibility(HID) end

  -- RoR2 buff row (just above Deadzone's health bar, bottom left)
  H.buffs = {}
  for i = 1, #Data.BUFFS do
    local img, sl = image(wt, canvas, "Buff" .. i)
    anchor(sl, 0, 1, 40 + (i - 1) * 38, -112 + (i - 1) * 38 * math.tan(math.rad(SYS.buff_row_tilt_deg)), 34, 34, 0, 1)
    pcall(function() img:SetRenderTransformAngle(SYS.buff_row_tilt_deg) end)
    img:SetVisibility(HID)
    -- stack count in the icon's lower right corner, like RoR2's BuffIcon
    local cnt, csl = text(wt, canvas, "BuffCount" .. i, 11)
    pcall(function() cnt:SetRenderTransformAngle(SYS.buff_row_tilt_deg) end)
    cnt:SetVisibility(HID)
    H.buffs[i] = { img = img, slot = sl, cnt = cnt, cslot = csl }
  end

  -- proc ticker (right middle)
  H.tick = {}
  for i = 1, 4 do
    local tb, s = text(wt, canvas, "Tick" .. i, 15)
    anchor(s, 1, 0.5, -40, -40 + 24 * i, nil, nil, 1, 0)
    tb:SetVisibility(HID)
    H.tick[i] = tb
  end

  -- test menu (F1), left middle; hidden until opened
  H.menu_bg, H.menu_bg_slot = image(wt, canvas, "MenuBg")
  H.menu_bg:SetColorAndOpacity({ R = 0.02, G = 0.03, B = 0.05, A = 0.86 })
  H.menu_lines = {}
  local MENU_ROWS = 20
  local nlines = math.min(#Data.ITEMS, MENU_ROWS) + 19
  local width = 520
  anchor(H.menu_bg_slot, 0, 0.5, 24, 0, width, 26 + nlines * 21, 0, 0.5)
  for i = 1, nlines do
    local tb, sl = text(wt, canvas, "Menu" .. i, i == 1 and 18 or 14)
    anchor(sl, 0, 0.5, 40, -(nlines * 21) / 2 + (i - 1) * 21, nil, nil, 0, 0)
    tb:SetVisibility(HID)
    H.menu_lines[i] = tb
  end
  H.menu_bg:SetVisibility(HID)

  -- the game's HUD uses Slate invalidation caching; mark our widgets volatile so updates repaint
  pcall(function() canvas:ForceVolatile(true) end)
  pcall(function() w:ForceVolatile(true) end)
  for _, x in ipairs({ H.clock_bg, H.clock, H.tier, H.bar_bg, H.bar, H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do pcall(function() x:ForceVolatile(true) end) end
  for _, t in ipairs(H.tick) do pcall(function() t:ForceVolatile(true) end) end
  for _, t in ipairs(H.menu_lines) do pcall(function() t:ForceVolatile(true) end) end
  pcall(function() H.menu_bg:ForceVolatile(true) end)
  for _, b in ipairs(H.buffs) do pcall(function() b.img:ForceVolatile(true); b.cnt:ForceVolatile(true) end) end
  w:AddToViewport(40)
  log("HUD built")
  return H
end

local function fmt_clock(secs)
  secs = math.floor(secs)
  return string.format("%02d:%02d", secs // 60, secs % 60)
end

local function draw_hud()
  local pc = local_pc()
  if not valid(pc) then HUD = nil; return end
  if HUD == nil or not valid(HUD.w) or addr(HUD.pc) ~= addr(pc) then
    local ok, h = pcall(build_hud, pc)
    if not ok then log("HUD build failed: " .. tostring(h)); return end
    HUD = h
  end
  local H = HUD
  local okp, errp = pcall(patch_orb_menu, H.tex)
  if not okp then log("orb menu patch: " .. tostring(errp)) end
  local show = View.in_run
  -- clock
  for _, x in ipairs({ H.clock_bg, H.clock, H.tier, H.bar_bg, H.bar }) do x:SetVisibility(show and VIS or HID) end
  if show then
    local ti = tier_index(View.clock)
    local t = Data.DIFFICULTY_TIERS[ti]
    H.clock:SetText(FText(fmt_clock(View.clock)))
    H.tier:SetText(FText(t.name))
    color(H.tier, t.color)
    color(H.clock, { 1, 1, 1 })
    local nxt = Data.DIFFICULTY_TIERS[ti + 1]
    local frac = 1
    if nxt then frac = clamp((View.clock / 60 - t.start_min) / (nxt.start_min - t.start_min), 0, 1) end
    H.bar:SetColorAndOpacity({ R = t.color[1], G = t.color[2], B = t.color[3], A = 0.95 })
    H.bar_slot:SetSize({ X = 226 * frac, Y = 6 })
  end
  -- RoR2 items inside Deadzone's own inventory views
  local okg, errg = pcall(patch_inventory, H.tex, pc)
  if not okg then log("inventory patch: " .. tostring(errg)) end
  -- banner
  while #View.banners > 3 do table.remove(View.banners, 1) end
  while #View.banners > 0 and now_ms - View.banners[1].t > SYS.pickup_banner_ms do table.remove(View.banners, 1); if View.banners[1] then View.banners[1].t = now_ms end end
  local b = View.banners[1]
  local it = b and Data.ITEM_BY_ID[b.id]
  for _, x in ipairs({ H.ban_bg, H.ban_icon, H.ban_name, H.ban_desc }) do x:SetVisibility(it and VIS or HID) end
  if it then
    if valid(H.tex[it.id]) then H.ban_icon:SetBrushFromTexture(H.tex[it.id], false) end
    H.ban_name:SetText(FText(it.name))
    color(H.ban_name, Data.RARITY_BY_ID[it.rarity].color)
    H.ban_desc:SetText(FText(it.pickup))
    color(H.ban_desc, { 0.85, 0.85, 0.85 })
  end
  -- buffs
  local active = {}
  for _, b in ipairs(Data.BUFFS) do
    local untilT = View.buffs[b.id]
    if untilT and untilT > now_ms and show then active[#active + 1] = { b = b, left = untilT - now_ms } end
  end
  for i, slot in ipairs(H.buffs) do
    local a = active[i]
    if a then
      if valid(H.tex["buff_" .. a.b.id]) then slot.img:SetBrushFromTexture(H.tex["buff_" .. a.b.id], false) end
      local bx, by = 40 + (i - 1) * 38, -112 + (i - 1) * 38 * math.tan(math.rad(SYS.buff_row_tilt_deg))
      anchor(slot.slot, 0, 1, bx, by, 34, 34, 0, 1)
      -- drawn exactly as the icon's own PNG colours, no tint, no fade
      slot.img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 1 })
      if slot.iv ~= 1 then slot.img:SetVisibility(VIS); slot.iv = 1 end
      local n = (View.bcount[a.b.id] or 1) + a.b.offset
      if a.b.stack == 1 and n > 1 then
        slot.cnt:SetText(FText(a.b.stack_pct == 1 and (n .. "%") or ("x" .. n)))
        color(slot.cnt, { 1, 1, 1 })
        anchor(slot.cslot, 0, 1, bx + 37, by + 3, nil, nil, 1, 1)
        if slot.cv ~= 1 then slot.cnt:SetVisibility(VIS); slot.cv = 1 end
      else
        if slot.cv ~= 0 then slot.cnt:SetVisibility(HID); slot.cv = 0 end
      end
    else
      if slot.iv ~= 0 then slot.img:SetVisibility(HID); slot.iv = 0 end
      if slot.cv ~= 0 then slot.cnt:SetVisibility(HID); slot.cv = 0 end
    end
  end
  -- ticker
  for i = 1, 4 do
    local e = View.ticker[i]
    if e and now_ms - e.t < 5000 and show then
      H.tick[i]:SetText(FText(e.text)); color(H.tick[i], { 0.95, 0.9, 0.6 }, 1 - (now_ms - e.t) / 5000)
      H.tick[i]:SetVisibility(VIS)
    else H.tick[i]:SetVisibility(HID) end
  end
  draw_menu(H)
end

---------------------------------------------------------------------------
-- host tick: clock, pawn changes, sync
---------------------------------------------------------------------------
local last_sync = 0
local function host_tick(gm)
  local hub = in_hub(gm)
  if hub then
    if not Run.is_reset then log("back on the ship: run reset"); reset_run(); Run.is_reset = true end
    View.in_run = false
    if now_ms - last_sync >= SYS.sync_ms then
      last_sync = now_ms
      for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do send(pc, "s|0|0|") end
    end
    return
  else
    Run.is_reset = false
    local ok, t = pcall(function() return cls("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(gm) end)
    -- The clock runs with Deadzone's own run timer, which starts at the first door, not at map load.
    local started = true
    pcall(function()
      if not valid(Run.gs) then Run.gs = FindFirstOf(SYS.run_timer_state) end
      if valid(Run.gs) then started = Run.gs:HasRunStarted() and true or false end
    end)
    if ok and t then
      if started and Run.last_world_t and t >= Run.last_world_t then Run.clock = Run.clock + (t - Run.last_world_t) end
      Run.last_world_t = t
    end
  end
  -- re-apply items when a player's pawn changes (respawn, new floor)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and valid(pc.Pawn) then
      local name = player_name(pc)
      local st = pstate(name)
      local a = addr(pc.Pawn)
      if st.pawn ~= a and alive(pc.Pawn) then
        st.pawn = a; st.handles = {}; st.base_jump = nil
        after(1000, function() apply_items(name) end)
      end
    end
  end
  -- test menu god mode: keep the local player at full health
  if Dev.god then
    local gpc = local_pc()
    local p = gpc and gpc.Pawn
    -- real invulnerability: Deadzone's own 2 s invulnerability effect (incoming damage x0),
    -- re-applied every 1.5 s, so bursts can't kill you between health refills
    if alive(p) and now_ms - (Dev.inv_t or 0) >= 1500 then
      Dev.inv_t = now_ms
      pcall(apply_fixed, p, SYS.invuln_ge, nil)
    end
    -- during the self-test the health refill only steps in near death, so healing items can be measured
    local floor = (Dev.ST and Dev.ST.running) and 0.15 or 1.0
    if alive(p) and p:GetHealth() < p:GetHealthMax() * floor then pcall(function() p:SetHealth(p:GetHealthMax() * 1.0) end) end
  end
  -- a new mission (a different game mode object while in a run) starts the 'stage' items
  if addr(gm) ~= Run.gm_addr then
    Run.gm_addr = addr(gm)
    after(3000, function() local ok, err = pcall(engine_stage_start); if not ok then log("stage: " .. tostring(err)) end end)
  end
  local oke, erre = pcall(engine_tick)
  if not oke then log("engine tick: " .. tostring(erre)) end
  -- local view
  local lpc = local_pc()
  View.in_run = not hub
  View.clock = Run.clock
  if lpc then View.items = pstate(player_name(lpc)).items end
  -- remote clients
  if now_ms - last_sync >= SYS.sync_ms then
    last_sync = now_ms
    for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
      if valid(pc) and not pc:IsLocalController() then
        local st = pstate(player_name(pc))
        local parts = {}
        for k, v in pairs(st.items) do if v > 0 then parts[#parts + 1] = k .. ":" .. v end end
        for key, off in pairs(Offers) do send_offer(pc, key, off) end
        send(pc, table.concat({ "s", hub and "0" or "1", string.format("%.1f", Run.clock), table.concat(parts, ",") }, "|"))
      end
    end
  end
end

-- test mode: a Lua snippet dropped into test_cmd.lua runs here with access to the mod's API;
-- its result is appended to test_out.txt. Nothing happens unless that file exists.
local TEST_IN, TEST_OUT = MOD .. "test_cmd.lua", MOD .. "test_out.txt"
local function test_mode()
  local f = io.open(TEST_IN, "r")
  if not f then return end
  local code = f:read("*a"); f:close(); os.remove(TEST_IN)
  local fn, err = load(code, "test_cmd", "t", setmetatable({ R2 = _G.RoR2Mashup }, { __index = _G }))
  local res
  if fn then local ok, r = pcall(fn); res = (ok and "OK: " or "ERR: ") .. tostring(r) else res = "COMPILE ERR: " .. tostring(err) end
  local o = io.open(TEST_OUT, "a"); if o then o:write(res .. "\n== done\n"); o:close() end
end

local hud_acc = 0
local test_acc = 0
local Settle = { pc = 0, until_ms = 0 }
LoopAsync(TICK_MS, function()
  ExecuteInGameThread(function()
    now_ms = now_ms + TICK_MS
    local ok, err = pcall(function()
      -- After a map load the old world's widgets and actors are being torn down. When the local
      -- player controller changes, drop the HUD and wait a moment before touching game objects.
      local lp = local_pc()
      local la = lp and addr(lp) or 0
      if la ~= Settle.pc then
        Settle.pc = la; Settle.until_ms = now_ms + SYS.map_settle_ms; HUD = nil; Run.gs = nil
        -- everything that still points at the old world goes: pending timers, cached attribute
        -- sets, auras and infected enemies (calling into a destroyed object crashes UE4SS)
        timers = {}; ATTRSET = {}; Auras = {}; Infected = {}
        if Dev.ST and Dev.ST.running and Dev.ST.on_abort then pcall(Dev.ST.on_abort) end
      end
      if now_ms < Settle.until_ms then return end
      run_timers()
      local srv, gm = server()
      if srv then host_tick(gm) end
      hud_acc = hud_acc + TICK_MS
      if hud_acc >= SYS.hud_refresh_ms then hud_acc = 0; draw_hud() end
      local okt, errt = pcall(update_tip)
      if not okt then log("tooltip: " .. tostring(errt)) end
      test_acc = test_acc + TICK_MS
      if test_acc >= 500 then test_acc = 0; test_mode() end
    end)
    if not ok then log("tick error: " .. tostring(err)) end
  end)
  return false
end)

---------------------------------------------------------------------------
-- In-game self-test: gives each RoR2 item on its own, sets off what triggers it (hits, kills,
-- getting hurt, low health, timers, encounter, orb pick) against real enemies, and records what
-- actually changed in the game: stats, enemy health, statuses on enemies, healing, shields, jumps.
-- Results go to ue4ss/Mods/RoR2Mashup/selftest.txt. Started from the test mode (R2.selftest()).
---------------------------------------------------------------------------
-- In-game self-test. The test itself lives in selftest.lua next to this file and is loaded fresh
-- every time it starts, so it can be changed without restarting the game. It reaches the mod's
-- internals through R2I below.
Dev.ST = { running = false }
_G.R2I = {
  Data = Data, SYS = SYS, MOD = MOD, Dev = Dev, View = View, Procs = Procs,
  now = function() return now_ms end, after = after, log = log,
  valid = valid, alive = alive, addr = addr, attr = attr, loc = loc, dist = dist,
  bots_near = bots_near, nearest = nearest, deal = deal, apply_status = apply_status, note_status = note_status,
  pstate = pstate, gstate = gstate, ctx_for = ctx_for, player_name = player_name, local_pc = local_pc, server = server,
  give = give, take_all = take_all, apply_items = apply_items, on_damaged = on_damaged,
  engine_all = engine_all, engine_orb = engine_orb, buff_from = function(...) return BUFF_FROM(...) end, cd_of = cd_of,
  get_hp_ema = function() return HpEma end, set_hp_ema = function(v) HpEma = v end,
  clear_auras = function() Auras = {} end,
  actions = ACTIONS, fire = fire, barrier = barrier, heal_player = heal_player,
}
function Dev.ST.start(only)
  if Dev.ST.running then return "already running" end
  local fn, err = loadfile(MOD .. "Scripts/selftest.lua")
  if not fn then return "selftest.lua: " .. tostring(err) end
  local ok, res = pcall(fn)
  if not ok then return "selftest.lua: " .. tostring(res) end
  return res(only)
end

-- test/debug surface (used by the dev bridge and the in-game test mode)
_G.RoR2Mashup = {
  give = function(id, n) local pc = local_pc(); if pc then give(player_name(pc), id, n or 1) end end,
  run = function() return Run end,
  view = function() return View end,
  hooks = function() return hooks_ok end,
  set_clock = function(s) Run.clock = s end,
  deal = deal,
  selftest = function(ids) local only = nil; if ids then only = {}; for _, i in ipairs(ids) do only[i] = true end end; return Dev.ST.start(only) end,
  selftest_running = function() return Dev.ST.running end,
  -- test: one elemental hit from an item on a bot, as the local player
  item_hit = function(item_id, bot, base) local pc = local_pc(); if pc then item_hit(pc.Pawn, bot, Data.ITEM_BY_ID[item_id], base or 10) end end,
  element_damage = function(item_id, base) local pc = local_pc(); return element_damage(pc.Pawn, Data.ELEMENT_BY_ID[Data.ITEM_BY_ID[item_id].element], base) end,
}
math.randomseed(os.time())
log("loaded: " .. #Data.ITEMS .. " items, " .. #Data.DIFFICULTY_TIERS .. " difficulty tiers")
