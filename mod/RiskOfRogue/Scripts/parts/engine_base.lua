-- Risk of Rogue: engine_base.lua
-- Item engine, part 1: player context, shields/healing, timed stats, damage helpers.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

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
ITEMS_BY_TRIGGER = {}
GENERIC_KINDS = { effect = true, buff = true, growth2 = true }
for _, it in ipairs(Data.ITEMS) do
  if GENERIC_KINDS[it.kind] and it.trigger ~= "" then
    ITEMS_BY_TRIGGER[it.trigger] = ITEMS_BY_TRIGGER[it.trigger] or {}
    table.insert(ITEMS_BY_TRIGGER[it.trigger], it)
  end
end
COND_ITEMS, REGEN_ITEMS, PERIODIC_ITEMS = {}, {}, {}
for _, it in ipairs(Data.ITEMS) do
  if it.kind == "cstat" then COND_ITEMS[#COND_ITEMS + 1] = it end
  if it.kind == "regen" then REGEN_ITEMS[#REGEN_ITEMS + 1] = it end
  if it.trigger == "periodic" then PERIODIC_ITEMS[#PERIODIC_ITEMS + 1] = it end
end
ELEMENT_IDS = {}
for _, e in ipairs(Data.ELEMENTS) do if e.elemental == 1 then ELEMENT_IDS[#ELEMENT_IDS + 1] = e.id end end

function per(base, step, n) return base + step * (n - 1) end
function sec_ms(s) return math.floor(s * 1000) end

-- player context ------------------------------------------------------------
function gstate(st)
  if not st.g then
    st.g = { base = SYS.base_damage_start, last_fire = {}, counter = {}, buffs = {}, cstat = {}, growth = {},
             last_hit = -1e9, last_hurt = -1e9, low = false, still_since = nil, charge = 0, soul = 0,
             fall_from = nil, kills = {}, echo_ready = 0 }
  end
  return st.g
end
function in_combat(g) return now_ms - math.max(g.last_hit, g.last_hurt) < SYS.combat_window_ms end
function speed_of(pawn)
  local v = { X = 0, Y = 0, Z = 0 }
  pcall(function() v = pawn:GetVelocity() end)
  return math.sqrt(v.X * v.X + v.Y * v.Y)
end
function luck(st) return count(st, "Clover") end
function roll(st, p)
  if p >= 1 or rawget(_G, "R2_FORCE") then return true end
  for _ = 0, luck(st) do if math.random() < p then return true end end
  return false
end
function chance_of(it, n)
  if it.stack == "hyperbolic" then return 1 - (1 - it.chance) ^ n end
  return math.min(1, per(it.chance, it.chance_per, n))
end
function cd_of(it, n)
  if it.cd_per > 0 then return it.cd * it.cd_per ^ (n - 1) end
  return it.cd
end
function ready(g, key, seconds)
  if seconds <= 0 then return true end
  if (g.last_fire[key] or -1e9) + sec_ms(seconds) > now_ms then return false end
  return true
end

-- elites: a bot whose max HP is well above the run's typical bot
HpEma = nil
function note_bot_hp(bot)
  local m = 0; pcall(function() m = bot:GetHealthMax() end)
  if m <= 0 then return end
  HpEma = HpEma and (HpEma * 0.95 + m * 0.05) or m
end
function is_elite(bot)
  if not HpEma then return false end
  local m = 0; pcall(function() m = bot:GetHealthMax() end)
  return m >= HpEma * SYS.elite_hp_ratio
end

-- element statuses currently on a bot (for Death Mark / Noxious Thorn)
StatusUntil = {}
function note_status(bot, el_id, dur)
  StatusUntil[addr(bot) .. "|" .. el_id] = now_ms + sec_ms(dur)
end
function statuses_on(bot)
  local a, out = addr(bot), {}
  for _, id in ipairs(ELEMENT_IDS) do
    if (StatusUntil[a .. "|" .. id] or 0) > now_ms then out[#out + 1] = id end
  end
  return out
end

-- shields, credits, invulnerability -----------------------------------------
function apply_fixed(char, path, mag, target)
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
function barrier(pawn, amount)
  if not alive(pawn) or amount <= 0 then return end
  apply_fixed(pawn, SYS.temp_shield_ge, math.floor(amount))
end
function award_credits(pc, amount)
  local gm = FindFirstOf("ValGameMode")
  amount = math.floor(amount * (1 + Run.clock / SYS.currency_clock_scale))
  if amount <= 0 or not valid(gm) or not valid(pc) then return end
  pcall(function() gm:AwardCurrency(pc.PlayerState, 0, amount) end)
end

-- healing that knows about Rejuvenation Rack, Aegis and N'kuhana's Opinion
function heal_player(name, pawn, amount)
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
function stat_mag(op, raw) if op == "mult" then return 1 + raw end return raw end
function set_stat(pawn, slot, key, ge, op, raw)
  remove_effect(pawn, slot[key]); slot[key] = nil
  if ge ~= "" and raw ~= 0 and alive(pawn) then slot[key] = apply_magnitude(pawn, ge, stat_mag(op, raw)) end
end

-- damage helpers ----------------------------------------------------------------
function el_of(it) return Data.ELEMENT_BY_ID[it.element] end
-- one hit from a generic item: element damage, the element's status, and the item's extra status
function ghit(pawn, bot, it, n, amount, extra_dur)
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
function bots_in(center_x, center_y, center_z, radius)
  local out = {}
  for _, b in ipairs(all_bots()) do
    local x, y, z = loc(b)
    if math.sqrt((x - center_x) ^ 2 + (y - center_y) ^ 2 + (z - center_z) ^ 2) <= radius then out[#out + 1] = b end
  end
  return out
end
function nearest(list, center, k)
  table.sort(list, function(a, b) return dist(a, center) < dist(b, center) end)
  local out = {}
  for i = 1, math.min(k, #list) do out[i] = list[i] end
  return out
end
function shuffle(t) for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end return t end

-- auras: short-lived zones handled every tick (banner, turret, ice storm, healing plant, transmitter)
Auras = {}

