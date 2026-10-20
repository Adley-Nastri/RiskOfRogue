-- Risk of Rogue: api.lua
-- Self-test launcher and the debug/test API (R2I, RiskOfRogue). Last part loaded.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- In-game self-test: gives each RoR2 item on its own, sets off what triggers it (hits, kills,
-- getting hurt, low health, timers, encounter, orb pick) against real enemies, and records what
-- actually changed in the game: stats, enemy health, statuses on enemies, healing, shields, jumps.
-- Results go to ue4ss/Mods/RiskOfRogue/selftest.txt. Started from the test mode (R2.selftest()).
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
_G.RiskOfRogue = {
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
log("loaded: " .. #Data.ITEMS .. " items, " .. #Data.DIFFICULTY_TIERS .. " difficulty tiers" .. (Dev.enabled and " (developer tools ON)" or ""))
