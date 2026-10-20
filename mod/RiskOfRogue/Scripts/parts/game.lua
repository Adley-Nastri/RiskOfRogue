-- Risk of Rogue: game.lua
-- Game helpers: classes, characters, bots, attributes, damage, elemental statuses.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- scheduler (everything runs on the game thread from one LoopAsync tick)
---------------------------------------------------------------------------
TICK_MS = 100
now_ms = 0
timers = {}
function after(ms, fn) timers[#timers + 1] = { t = now_ms + ms, fn = fn } end
function run_timers()
  local due = {}
  local keep = {}
  for _, t in ipairs(timers) do if t.t <= now_ms then due[#due + 1] = t else keep[#keep + 1] = t end end
  timers = keep
  for _, t in ipairs(due) do local ok, err = pcall(t.fn); if not ok then log("timer error: " .. tostring(err)) end end
end

---------------------------------------------------------------------------
-- game helpers
---------------------------------------------------------------------------
CLS = {}
function cls(path)
  local c = CLS[path]
  if not valid(c) then c = StaticFindObject(path); CLS[path] = c end
  return c
end
function ge_paths(path)
  local nm = path:match("[^/]+$")
  return path .. "." .. nm .. "_C", path .. ".Default__" .. nm .. "_C"
end
SUICIDE = "/Game/Abilities/Effects/GE_Suicide.GE_Suicide_C"
GE_MAXHP_MULT = "/Game/Abilities/DeviceUpgrades/Attributes/GE_GenericAttribute_MaxHealth"
GE_DMG_ADD = "/Game/Abilities/DeviceUpgrades/Attributes/GE_GlobalDamageModifier"
GE_SPEED_MULT = "/Game/Abilities/DeviceUpgrades/Attributes/GE_MovementSpeed"

-- Apply one of the game's SetByCaller attribute effects with our own magnitude:
-- the effect's default object is switched to a fixed magnitude for the call, then restored.
function apply_magnitude(char, path, mag)
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
function remove_effect(char, h)
  if h and valid(char) and valid(char.AbilitySystemComponent) then
    pcall(function() char.AbilitySystemComponent:RemoveActiveGameplayEffect(h, -1) end)
  end
end

function is_bot(c)
  if not valid(c) then return false end
  if c:IsPlayerControlled() then return false end
  local ok, pet = pcall(function() return c.bIsPet end)
  if ok and pet then return false end
  return true
end
function alive(c) return valid(c) and c:GetHealth() > 0 end
function loc(a) local l = a:K2_GetActorLocation(); return l.X, l.Y, l.Z end
function dist(a, b)
  local ax, ay, az = loc(a); local bx, by, bz = loc(b)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2)
end
function all_bots()
  local out = {}
  for _, c in ipairs(FindAllOf("ValCharacter") or {}) do if is_bot(c) and alive(c) then out[#out + 1] = c end end
  return out
end
function bots_near(center, radius, except)
  local out = {}
  for _, c in ipairs(all_bots()) do
    if addr(c) ~= addr(except) and dist(c, center) <= radius then out[#out + 1] = c end
  end
  return out
end

-- Damage that counts as the attacker's: partial hits lower health, lethal hits go through
-- the game's own execute effect so the kill, credit and encounter progress are real.
function deal(attacker, bot, amount)
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
ATTRSET = {}
function attr(char, name, default)
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
function element_damage(attacker, el, base)
  if not el then return base end
  local mult = 1 + attr(attacker, el.dmg_attr, 0) + attr(attacker, SYS.elem_all_attr, 0)
  return base * math.max(0, mult) * attr(attacker, SYS.elem_proc_attr, 1)
end
StatusAt = {}
function apply_status(attacker, bot, el, dur_override)
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
function item_hit(attacker, bot, it, base)
  local el = Data.ELEMENT_BY_ID[it.element]
  if not alive(bot) then return end
  apply_status(attacker, bot, el)
  deal(attacker, bot, element_damage(attacker, el, base))
end

function heal(pawn, amount)
  if not alive(pawn) or amount <= 0 then return end
  local hp, mx = pawn:GetHealth(), pawn:GetHealthMax()
  pawn:SetHealth(math.min(mx, hp + amount) * 1.0)
end

function server()
  local gm = FindFirstOf("GameModeBase")
  return valid(gm), gm
end
function in_hub(gm)
  return valid(gm) and gm:GetClass():GetFName():ToString():find("StartingShip") ~= nil
end
function player_name(pc)
  local ps = pc.PlayerState
  if valid(ps) then
    local ok, n = pcall(function() return ps:GetPlayerName():ToString() end)
    if ok and n and n ~= "" then return n end
  end
  return "player"
end
function local_pc()
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and pc:IsLocalController() then return pc end
  end
  return nil
end
function stack_mag(it, n)
  if it.stack == "power" then
    if it.op == "mult" then return (1 + it.k) ^ n end
    return (1 + it.k) ^ n - 1 -- additive modifier on a base of 1: the total change after n multiplicative stacks
  end
  if it.stack == "hyperbolic" then return 1 - 1 / (1 + it.k * n) end
  if it.op == "mult" then return 1 + it.k * n end
  return it.k * n
end

