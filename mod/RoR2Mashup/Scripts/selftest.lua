-- RoR2 Mashup in-game self-test (loaded fresh by the mod each time it starts; see main.lua R2I).
-- Gives each RoR2 item on its own, sets off its trigger against real enemies and records what
-- changed: your stats, enemy health, statuses on the enemy, healing, shields, jumps.
local I = _G.R2I
local Data, SYS, MOD, Dev = I.Data, I.SYS, I.MOD, I.Dev
local after, log, valid, alive, addr, attr = I.after, I.log, I.valid, I.alive, I.addr, I.attr
local bots_near, nearest, deal, apply_status, note_status = I.bots_near, I.nearest, I.deal, I.apply_status, I.note_status
local pstate, gstate, ctx_for, player_name, local_pc, server = I.pstate, I.gstate, I.ctx_for, I.player_name, I.local_pc, I.server
local give, take_all, apply_items, on_damaged = I.give, I.take_all, I.apply_items, I.on_damaged
local engine_all, engine_orb, BUFF_FROM, cd_of = I.engine_all, I.engine_orb, I.buff_from, I.cd_of
local OUT = MOD .. "selftest.txt"
local FAILED = MOD .. "selftest_failed.txt"
local function wout(line)
  local f = io.open(OUT, "a"); if f then f:write(line .. "\n"); f:close() end
end
local WATCH = { ShieldMax = true, HealthMax = true }
for _, it in ipairs(Data.ITEMS) do
  for _, a in ipairs({ it.attr, it.attr2, it.pattr }) do if a and a ~= "" and a ~= "Health" and a ~= "JumpMaxCount" then WATCH[a] = true end end
end
local function tagcount(b)
  local n = 0
  pcall(function() n = b.AbilitySystemComponent:GetOwnedGameplayTags().GameplayTags:GetArrayNum() end)
  return n
end
-- enemy attributes the element statuses change (Chill/Freeze: speed, Shock: crit resistance,
-- Corruption: damage, Irradiate: weak points, Fracture: stagger, Infect)
local STATUS_ATTRS = { "MovementSpeed", "MaxGroundSpeedMultiplier", "CriticalChanceResistanceModifier", "GlobalDamageMultiplier",
  "WeakpointDamageMitigationMultiplier", "IncomingStaggerChance", "NanoInfectReplenishmentChance" }
local target = nil
local MEASURE_SHIELD = false
local function snap(pc)
  local pawn = pc.Pawn
  if not alive(pawn) then error("WAIT: player died") end
  local s = { attrs = {}, hp = pawn:GetHealth(), bots = {}, credits = 0, jumps = pawn.JumpMaxCount }
  for a in pairs(WATCH) do s.attrs[a] = attr(pawn, a, 0) end
  if MEASURE_SHIELD then s.attrs.TemporaryShield = attr(pawn, "TemporaryShield", 0) end
  for _, b in ipairs(bots_near(pawn, 6000, nil)) do
    local sig, tg = 0, 0
    if target and addr(b) == addr(target) then
      for _, an in ipairs(STATUS_ATTRS) do sig = sig + math.abs(attr(b, an, 0)) end
      tg = tagcount(b)
    end
    s.bots[addr(b)] = { b = b, hp = b:GetHealth(), tags = tg, sig = sig }
  end
  pcall(function() s.credits = pc.PlayerState.r_MatchCurrency end)
  return s
end
local COUNT_STATUS = true
local function diff(a, b, skip)
  local out, dmg, tags, kills = {}, 0, 0, 0
  for k, v in pairs(b.attrs) do
    local d = v - (a.attrs[k] or 0)
    if math.abs(d) > 1e-4 then out[#out + 1] = string.format("%s %+.3g", k, d) end
  end
  for k, e in pairs(a.bots) do
    if not skip[k] then
      local now = b.bots[k]
      if now then
        dmg = dmg + math.max(0, e.hp - now.hp)
        tags = tags + math.max(0, now.tags - e.tags)
        if math.abs((now.sig or 0) - (e.sig or 0)) > 1e-3 then tags = tags + 1 end
      elseif valid(e.b) and e.b:GetHealth() <= 0 then kills = kills + 1; dmg = dmg + e.hp end
    end
  end
  if dmg > 0 then out[#out + 1] = string.format("enemy damage %.0f", dmg) end
  if kills > 0 then out[#out + 1] = "kills " .. kills end
  if tags > 0 and COUNT_STATUS then out[#out + 1] = "statuses +" .. tags end
  if b.hp - a.hp > 0.5 then out[#out + 1] = string.format("healed %.0f", b.hp - a.hp) end
  if b.credits ~= a.credits then out[#out + 1] = "credits +" .. (b.credits - a.credits) end
  if b.jumps ~= a.jumps then out[#out + 1] = "jumps " .. a.jumps .. "->" .. b.jumps end
  return out
end
local function fake_hit(pawn, amount, crit) return { Amount = -amount, bCriticalHit = crit, bFromProcAbility = false, bShieldDamage = false, bShieldBroke = false, Instigator = { Get = function() return pawn end } } end
local function fake_hurt(src, amount) return { Amount = -amount, bCriticalHit = false, bFromProcAbility = false, bShieldDamage = false, bShieldBroke = true, Instigator = { Get = function() return src end } } end
local MANUAL = {
  FallBoots = "needs a real jump and landing",
  Duplicator = "needs a real orb pick of a RoR2 card",
  Clover = "only raises item chances (passive)",
  StrengthenBurn = "boosts Fire burns from other items",
}
-- UE4SS can't touch game objects from inside a Lua coroutine, so each item's test is a chain
-- of steps run by the mod's own timer (after()), with waits between them.
local function run_item(pc, it, done)
  local name = player_name(pc)
  local st = pstate(name)
  local pawn = pc.Pawn
  local g = gstate(st)
  if not alive(pawn) then return done("WAIT", "waiting for you to respawn") end
  local near = nearest(bots_near(pawn, 5000, nil), pawn, 6)
  if #near == 0 then return done("WAIT", "no enemies within 50 m") end
  local t = { target = near[1], skip = {}, pawn_addr = addr(pawn) }
  target = near[1]
  local tr, k, c = it.trigger, it.kind, it.cond
  local LEGACY_EL = { Ukulele = true, Gasoline = true, Wisp = true, Behemoth = true }
  COUNT_STATUS = it.element ~= "none" or it.status ~= "none" or LEGACY_EL[it.id] or it.id == "TriggerEnemyDebuffs"
  local SHIELD_ITEMS = { BarrierOnOverHeal = true, TeleportOnLowHealth = true }
  MEASURE_SHIELD = it.action == "barrier" or SHIELD_ITEMS[it.id] or false
  local steps = {}
  local function S(ms, fn) steps[#steps + 1] = { ms, fn } end
  S(0, function()
    pawn:SetHealth(pawn:GetHealthMax() * 1.0)
    g.last_fire, g.counter = {}, {}
    I.clear_auras()
    st.items = {}; apply_items(name)
    for _, b in pairs(g.buffs) do b.untilT = 0 end
  end)
  S(0, function()
    if MEASURE_SHIELD then
      Dev.inv_t = I.now() + 1e9 -- pause god mode's invulnerability (it fills the temporary shield)
      local function guard(n)
        if n <= 0 or (Dev.inv_t or 0) < I.now() then return end
        if alive(pawn) then pcall(function() pawn:SetHealth(pawn:GetHealthMax() * 1.0) end) end
        after(100, function() guard(n - 1) end)
      end
      guard(40)
      for _, set in ipairs(FindAllOf("ValAttributeSet") or {}) do
        if valid(set) and addr(set:GetOuter()) == addr(pawn) then set.TemporaryShield.BaseValue = 0; set.TemporaryShield.CurrentValue = 0 end
      end
    end
  end)
  S(MEASURE_SHIELD and 2300 or 400, function()
    if MEASURE_SHIELD then
      for _, set in ipairs(FindAllOf("ValAttributeSet") or {}) do
        if valid(set) and addr(set:GetOuter()) == addr(pawn) then set.TemporaryShield.BaseValue = 0; set.TemporaryShield.CurrentValue = 0 end
      end
    end
    t.s0 = snap(pc)
    if MEASURE_SHIELD then
      t.peak = 0
      local function sample(n)
        if n <= 0 or t.ev then return end
        local p = local_pc()
        if not p or not valid(p.Pawn) or addr(p.Pawn) ~= t.pawn_addr then return end
        t.peak = math.max(t.peak, attr(p.Pawn, "TemporaryShield", 0))
        after(100, function() sample(n - 1) end)
      end
      sample(80)
    end
    if it.id == "StrengthenBurn" then st.items.Gasoline = 1 end
    if it.id == "BarrierOnOverHeal" then st.items.Seed = 4 end -- 4 HP per hit, so the overheal makes at least 2 shield
    give(name, it.id, 1)
  end)
  S(500, function()
    t.s1 = snap(pc)
    local target = t.target
    t.hp_ema = I.get_hp_ema()
    if c == "v_elite" or c == "v_elite_low" or tr == "elitekill" then I.set_hp_ema(1) end
    if c == "v_elite_low" then target:SetHealth(target:GetHealthMax() * 0.05) end
    if c == "charged" then g.charge = 99 end
    if c == "v_debuffed" or it.id == "TriggerEnemyDebuffs" then
      local who = (it.id == "TriggerEnemyDebuffs" and near[2]) or target
      for _, id in ipairs({ "fire", "lightning" }) do local el = Data.ELEMENT_BY_ID[id]; apply_status(pawn, who, el); note_status(who, id, el.duration_s) end
    end
    if c == "ooc" or k == "regen" then g.last_hit, g.last_hurt = -1e9, -1e9 end
    if c == "in_combat" then g.last_hit = I.now() end
    if c == "buffs" then BUFF_FROM({ id = "TestBuff", ge = Data.ITEM_BY_ID.Hoof.ge, op = "mult", k = 0.01, k_per = 0, ge2 = "", dur = 6, dur_per = 0, cap = 1, cap_per = 0 }, 1, ctx_for(pc)) end
    local healer = k == "regen" or it.action == "heal" or it.action == "heal_all" or it.action == "refund" or it.id == "Tooth" or it.id == "Medkit"
      or it.id == "ArmorPlate" or it.id == "DelayedDamage" or it.id == "Plant" or it.id == "Mushroom"
    if healer then pawn:SetHealth(pawn:GetHealthMax() * 0.6); t.s1.hp = pawn:GetHealth() end
    -- hits
    local base = g.base
    local amount = (c == "hit_big") and base * 8 or base
    if tr == "hit" or tr == "crit" or it.id == "Ukulele" or it.id == "Behemoth" or it.id == "PermanentDebuffOnHit" or it.id == "SharedSuffering" or it.id == "BarrierOnOverHeal" or it.id == "TriggerEnemyDebuffs" then
      local hits = (c == "every" or c == "every_target") and it.cv or 3
      for _ = 1, hits do on_damaged(target, fake_hit(pawn, amount, true)) end
      if it.id == "SharedSuffering" then
        for x = 2, math.min(3, #near) do on_damaged(near[x], fake_hit(pawn, amount, false)) end
        for _ = 1, 3 do on_damaged(target, fake_hit(pawn, amount * 3, false)) end
      end
    end
    -- getting hurt
    if tr == "hurt" or tr == "shieldbreak" or it.id == "ArmorPlate" or it.id == "Medkit" or it.id == "DelayedDamage" then
      pawn:SetHealth(math.max(1, pawn:GetHealth() - 30))
      t.s1.hp = pawn:GetHealth()
      on_damaged(pawn, fake_hurt(target, 30))
    end
    -- low health
    if tr == "lowhp" or it.id == "HealingPotion" or it.id == "FragileDamageBonus" then
      pawn:SetHealth(pawn:GetHealthMax() * 0.2); t.s1.hp = pawn:GetHealth()
    end
    if tr == "encounter" then engine_all("encounter") end
    if tr == "orb" then engine_orb(pc) end
  end)
  -- kills (each a real kill credited to you, so the game's own kill event fires)
  if tr == "kill" or tr == "elitekill" or tr == "multikill" or it.id == "Tooth" or it.id == "Wisp" or it.id == "Gasoline"
    or it.id == "Infusion" or it.id == "TriggerEnemyDebuffs" or it.id == "StrengthenBurn" then
    local victims = (tr == "multikill") and math.min(4, #near) or 1
    local first = (it.id == "TriggerEnemyDebuffs" and #near >= 2) and 2 or 1
    for x = first, first + victims - 1 do
      S(tr == "multikill" and 0 or 250, function()
        local v = near[x]
        if alive(v) then t.skip[addr(v)] = true; deal(pawn, v, v:GetHealth() + 1) end
      end)
    end
  end
  local waitms = 600
  if it.id == "DelayedDamage" or it.id == "Medkit" then waitms = SYS.medkit_delay_ms + 600 end
  if tr == "periodic" then waitms = math.floor(cd_of(it, 1) * 1000) + 700 end
  if c == "tesla" then
    local period = math.floor(it.cv * 1000)
    local phase = (I.now() + 1000) % (2 * period) -- ~1 s of earlier steps before this wait starts
    if phase > period - 2000 then waitms = (2 * period - phase) + 1500 else waitms = 1500 end
  end
  if it.id == "SharedSuffering" then waitms = 3400 end
  if k == "regen" or k == "cstat" then waitms = (c == "still") and 2500 or 1600 end
  S(waitms, function() t.smid = snap(pc) end)
  S(2500, function()
    t.s2 = snap(pc)
    I.set_hp_ema(t.hp_ema)
    local ev = {}
    for _, x in ipairs(diff(t.s0, t.s1, {})) do ev[#ev + 1] = "on pickup: " .. x end
    for _, x in ipairs(diff(t.s1, t.smid, t.skip)) do ev[#ev + 1] = "on trigger: " .. x end
    for _, x in ipairs(diff(t.smid, t.s2, t.skip)) do ev[#ev + 1] = "after: " .. x end
    if t.peak and t.peak > 0.5 then ev[#ev + 1] = string.format("TemporaryShield peaked at %.0f", t.peak) end
    take_all(name)
    Dev.inv_t = 0
    for _, b in pairs(g.buffs) do b.untilT = 0 end
    pawn:SetHealth(pawn:GetHealthMax() * 1.0)
    t.ev = ev
  end)
  local function finish()
    Dev.inv_t = 0
    local ev = t.ev or {}
    if t.err and tostring(t.err):find("WAIT: player died", 1, true) then return done("WAIT", "died mid-item; retrying after respawn") end
    if t.err then return done("FAIL", "error: " .. tostring(t.err)) end
    if MANUAL[it.id] and #ev == 0 then return done("MANUAL", MANUAL[it.id]) end
    if (c == "moving" or c == "above" or c == "still") and #ev == 0 then
      return done("MANUAL", "needs you to " .. (c == "moving" and "sprint" or c == "above" and "shoot from higher ground" or "stand still"))
    end
    if c == "ooc" and #ev == 0 then return done("MANUAL", "needs 5 s without being hit (enemies kept attacking during the test)") end
    if it.action == "ammo" and #ev == 0 then return done("MANUAL", "refills ammo (can't be measured from the mod)") end
    if #ev > 0 then return done("PASS", table.concat(ev, "; ")) end
    return done("FAIL", "no measurable effect")
  end
  local function nextstep(x)
    if x > #steps then return finish() end
    after(steps[x][1], function()
      -- never touch this item's saved objects once you've died or the map changed: they may be gone
      local p = local_pc()
      local pa = (p and valid(p.Pawn)) and addr(p.Pawn) or 0
      if pa ~= t.pawn_addr then return done("WAIT", "you died or the map changed mid-item; retrying") end
      if not t.err then
        local ok, e = pcall(steps[x][2])
        if not ok then t.err = e end
      end
      nextstep(x + 1)
    end)
  end
  nextstep(1)
end
local results = {}
local function start(only)
  if Dev.ST.running then return "already running" end
  local pc = local_pc()
  if not valid(pc) or not server() then return "host only" end
  local f = io.open(OUT, "w"); if f then f:write("RoR2 Mashup self-test " .. os.date() .. "\n\n"); f:close() end
  results = { PASS = 0, FAIL = 0, MANUAL = 0, SKIP = 0, WAIT = 0 }
  local saved = {}
  for kk, v in pairs(pstate(player_name(pc)).items) do saved[kk] = v end
  local list = {}
  for _, it in ipairs(Data.ITEMS) do if not only or only[it.id] then list[#list + 1] = it end end
  Dev.ST.running = true
  Dev.ST.stop = false
  local was_god = Dev.god
  Dev.god = true
  -- called by the mod when the map changes (death, new floor, back to ship): pending steps are gone
  Dev.ST.on_abort = function()
    wout("\nStopped: the map changed (death, new floor or back to the ship).")
    local p = local_pc()
    if p then pcall(function() pstate(player_name(p)).items = saved end) end
    Dev.ST.running = false; _G.R2_FORCE = false; Dev.inv_t = 0; Dev.god = was_god
    Dev.msg = "Self-test stopped: the map changed"; Dev.msg_t = I.now()
  end
  _G.R2_FORCE = true
  local failed = {}
  local function finish_all()
    local ff = io.open(FAILED, "w")
    if ff then for _, id in ipairs(failed) do ff:write(id .. "\n") end; ff:close() end
    local name = player_name(pc)
    local st = pstate(name)
    st.items = saved; apply_items(name)
    wout(string.format("\nPASS %d  FAIL %d  MANUAL %d  SKIP %d", results.PASS, results.FAIL, results.MANUAL, results.SKIP))
    Dev.ST.running = false; _G.R2_FORCE = false; Dev.inv_t = 0
    Dev.god = was_god
    Dev.msg = "Self-test done: see selftest.txt"; Dev.msg_t = I.now()
  end
  local function do_item(x, tries)
    if Dev.ST.stop then Dev.ST.stop = false; wout("\nStopped from the test menu after " .. (x - 1) .. " of " .. #list .. " items."); return finish_all() end
    if x > #list then return finish_all() end
    local it = list[x]
    local ok, e = pcall(run_item, pc, it, function(verdict, why)
      if verdict == "WAIT" and tries < 60 then return after(2000, function() do_item(x, tries + 1) end) end
      results[verdict] = (results[verdict] or 0) + 1
      if verdict == "FAIL" then failed[#failed + 1] = it.id end
      wout(string.format("%-6s %-28s [%s/%s] %s", verdict, it.name, it.kind, it.trigger ~= "" and it.trigger or it.cond, why))
      Dev.msg = string.format("Self-test %d/%d: %s %s", x, #list, it.name, verdict); Dev.msg_t = I.now()
      after(300, function() do_item(x + 1, 0) end)
    end)
    if not ok then
      results.FAIL = results.FAIL + 1
      failed[#failed + 1] = it.id
      wout(string.format("%-6s %-28s error: %s", "FAIL", it.name, tostring(e)))
      after(300, function() do_item(x + 1, 0) end)
    end
  end
  do_item(1, 0)
  return "started (" .. #list .. " items)"
end
return start
