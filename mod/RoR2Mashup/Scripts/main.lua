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
  local hp = bot:GetHealth()
  if amount >= hp then
    if valid(attacker) and valid(attacker.AbilitySystemComponent) and valid(bot.AbilitySystemComponent) then
      local asc = attacker.AbilitySystemComponent
      pcall(function() asc:BP_ApplyGameplayEffectToTarget(cls(SUICIDE), bot.AbilitySystemComponent, 1.0, asc:MakeEffectContext()) end)
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
local function apply_status(attacker, bot, el)
  if not el or not alive(bot) or not valid(attacker) then return end
  local key = addr(bot) .. el.id
  if (StatusAt[key] or -1e9) + el.status_cooldown_ms > now_ms then return end
  StatusAt[key] = now_ms
  local cpath, dpath = ge_paths(el.status_ge)
  local c, cdo = cls(cpath), cls(dpath)
  if not valid(c) then pcall(function() LoadAsset(el.status_ge) end); c, cdo = cls(cpath), cls(dpath) end
  local src, dst = attacker.AbilitySystemComponent, bot.AbilitySystemComponent
  if not valid(c) or not valid(cdo) or not valid(src) or not valid(dst) then return end
  local potency = attr(attacker, SYS.elem_potency_attr, 1)
  local dur = el.duration_s * attr(attacker, SYS.elem_duration_attr, 1) + attr(attacker, el.duration_attr, 0)
  local extra = attr(attacker, el.mag_attr, 0)
  local mag = (el.status_mag + (el.status_mag < 0 and -extra or extra)) * potency
  -- SetByCaller magnitudes can't be set from a mod, so the default object gets fixed values for this one call
  local saved = {}
  local dm = cdo.DurationMagnitude
  local dt, dv = dm.MagnitudeCalculationType, dm.ScalableFloatMagnitude.Value
  if dt == 3 then dm.MagnitudeCalculationType = 0; dm.ScalableFloatMagnitude.Value = dur end
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
local View = { clock = 0, items = {}, banners = {}, ticker = {}, buffs = {}, in_run = false }
local BUFF_BY_ID = {}
for _, b in ipairs(Data.BUFFS) do BUFF_BY_ID[b.id] = b end
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
    elseif kind == "b" then local b = BUFF_BY_ID[payload]; if b then View.buffs[payload] = now_ms + b.duration_ms end
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
    elseif it.kind == "jump" then
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
  local off = { slot = math.random(n) - 1, item = roll_item(roll_rarity("orb_weight")) }
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
  if valid(typeW) then typeW:SetText(FText("// RISK OF RAIN 2  " .. string.upper(it.rarity) .. " ITEM")) end
  local descs = find_all_named(card, row.desc_widget, {})
  for i, d in ipairs(descs) do
    pcall(function()
      if i == 1 then d:SetText(FText(it.pickup .. " " .. it.desc)) else d:SetText(FText("")) end
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
-- hooks (host)
---------------------------------------------------------------------------
local function on_bot_killed(victim, killer)
  local va = addr(victim)
  if va == 0 or Run.killed[va] then return end
  Run.killed[va] = true
  if not valid(killer) or not killer:IsPlayerControlled() then return end
  local pc = killer.Controller
  if not valid(pc) then return end
  local name = player_name(pc)
  local st = pstate(name)
  local vmax = 250
  pcall(function() vmax = victim:GetHealthMax() end)
  local vx, vy, vz = 0, 0, 0
  pcall(function() vx, vy, vz = loc(victim) end)

  local tooth = count(st, "Tooth")
  if tooth > 0 then local it = Data.ITEM_BY_ID.Tooth; heal(killer, it.dmg + it.k * tooth); notify(name, "b", "tooth_regen"); fx_at("heal", killer) end

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

local function on_damaged(victim, d)
  if not valid(victim) then return end
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
    local med = count(st, "Medkit")
    if med > 0 then
      notify(name, "b", "medkit_heal")
      after(SYS.medkit_delay_ms, function() heal(victim, Data.ITEM_BY_ID.Medkit.k * med); fx_at("heal", victim) end)
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
  local uke = count(st, "Ukulele")
  if uke > 0 and math.random() < Data.ITEM_BY_ID.Ukulele.chance then
    local it = Data.ITEM_BY_ID.Ukulele
    local targets = 3 + it.k * (uke - 1)
    local dmg = it.dmg * amount
    local near = bots_near(victim, it.radius, victim)
    table.sort(near, function(a, b) return dist(a, victim) < dist(b, victim) end)
    local hits = {}
    for i = 1, math.min(targets, #near) do hits[#hits + 1] = near[i] end
    if #hits > 0 then
      after(0, function() for _, b in ipairs(hits) do fx_at("ukulele_hit", b); item_hit(inst, b, it, dmg) end end)
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
    if #near > 0 then after(0, function() for _, b in ipairs(near) do item_hit(inst, b, it, it.dmg * amount) end end) end
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

-- every machine: the local player's click on an orb card
hook("request_pick", function(self, pickup, index)
  local pc, b, i = self:get(), pickup:get(), index:get()
  if not valid(b) or not valid(pc) then return end
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
  elseif f[1] == "b" then local b = BUFF_BY_ID[f[2]]; if b then View.buffs[f[2]] = now_ms + b.duration_ms end
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
  d.Description = FText(it.pickup .. "\n<em>" .. it.desc .. "</>\n// RISK OF RAIN 2 " .. string.upper(it.rarity) .. " ITEM")
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
  { "Up / Down  (or F3 / F4)", "select an item" },
  { "Right / Enter  (or F5)", "give 1 of the selected item" },
  { "Left / Backspace  (or F6)", "remove 1 of the selected item" },
  { "F7", "give 1 of every RoR2 item" },
  { "F8", "remove all RoR2 items" },
  { "F9", "difficulty clock: jump to next tier" },
  { "F10", "kill enemies within 30 m (procs fire)" },
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
  for i, it in ipairs(Data.ITEMS) do
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
  if key == "F2" then Dev.god = not Dev.god; dev_msg("God mode " .. (Dev.god and "ON" or "off"))
  elseif key == "F3" then Dev.sel = (Dev.sel - 2) % #Data.ITEMS + 1
  elseif key == "F4" then Dev.sel = Dev.sel % #Data.ITEMS + 1
  elseif key == "F5" then give(name, it.id, 1); dev_msg("Gave " .. it.name)
  elseif key == "F6" then take(name, it.id, 1); dev_msg("Removed " .. it.name)
  elseif key == "F7" then for _, x in ipairs(Data.ITEMS) do give(name, x.id, 1) end; dev_msg("Gave one of every item")
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
  end
end
-- extra keys for moving through the item list (they map onto the F-key actions)
local ALIAS = { UP_ARROW = "F3", DOWN_ARROW = "F4", RIGHT_ARROW = "F5", RETURN = "F5", LEFT_ARROW = "F6", BACKSPACE = "F6" }
for _, k in ipairs({ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "UP_ARROW", "DOWN_ARROW", "RIGHT_ARROW", "LEFT_ARROW", "RETURN", "BACKSPACE" }) do
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
    anchor(sl, 0, 1, 40 + (i - 1) * 38, -112, 34, 34, 0, 1)
    img:SetVisibility(HID)
    H.buffs[i] = { img = img, slot = sl }
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
  local nlines = #Data.ITEMS + 16
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
  for _, b in ipairs(H.buffs) do pcall(function() b.img:ForceVolatile(true) end) end
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
      anchor(slot.slot, 0, 1, 40 + (i - 1) * 38, -112, 34, 34, 0, 1)
      local alpha = a.left < 500 and (0.35 + 0.65 * (a.left / 500)) or 1
      slot.img:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = alpha })
      slot.img:SetVisibility(VIS)
    else
      slot.img:SetVisibility(HID)
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
    if ok and t then
      if Run.last_world_t and t >= Run.last_world_t then Run.clock = Run.clock + (t - Run.last_world_t) end
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
    if alive(p) and p:GetHealth() < p:GetHealthMax() then pcall(function() p:SetHealth(p:GetHealthMax() * 1.0) end) end
  end
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
LoopAsync(TICK_MS, function()
  ExecuteInGameThread(function()
    now_ms = now_ms + TICK_MS
    local ok, err = pcall(function()
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

-- test/debug surface (used by the dev bridge and the in-game test mode)
_G.RoR2Mashup = {
  give = function(id, n) local pc = local_pc(); if pc then give(player_name(pc), id, n or 1) end end,
  run = function() return Run end,
  view = function() return View end,
  hooks = function() return hooks_ok end,
  set_clock = function(s) Run.clock = s end,
  deal = deal,
  -- test: one elemental hit from an item on a bot, as the local player
  item_hit = function(item_id, bot, base) local pc = local_pc(); if pc then item_hit(pc.Pawn, bot, Data.ITEM_BY_ID[item_id], base or 10) end end,
  element_damage = function(item_id, base) local pc = local_pc(); return element_damage(pc.Pawn, Data.ELEMENT_BY_ID[Data.ITEM_BY_ID[item_id].element], base) end,
}
math.randomseed(os.time())
log("loaded: " .. #Data.ITEMS .. " items, " .. #Data.DIFFICULTY_TIERS .. " difficulty tiers")
