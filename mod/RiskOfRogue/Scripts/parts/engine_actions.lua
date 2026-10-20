-- Risk of Rogue: engine_actions.lua
-- Item engine, part 2: the action table, buffs and trigger conditions.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

-- the action table ------------------------------------------------------------------
ACTIONS = {}
function base_value(it, ctx, target)
  if it.dmg_base == "base" then return ctx.g.base end
  if it.dmg_base == "vmax" then local m = 0; pcall(function() m = target:GetHealthMax() end); return m end
  return ctx.amount or ctx.g.base
end
function dmg_of(it, n, ctx, target)
  return per(it.dmg, it.dmg_per, n) * base_value(it, ctx, target), 1
end
function radius_of(it, n) return per(it.radius, it.radius_per, n) end
function count_of(it, n) return math.floor(per(it.n, it.n_per, n)) end

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
-- shared, assigned further down: BUFF_FROM
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
function random_item(st, white_pct)
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
function expire_buffs(pawn, g)
  for id, b in pairs(g.buffs) do
    if b.untilT <= now_ms then
      remove_effect(pawn, b.h[1]); remove_effect(pawn, b.h[2])
      g.buffs[id] = nil
    end
  end
end
function active_buffs(g) local c = 0; for _ in pairs(g.buffs) do c = c + 1 end return c end

-- conditions ------------------------------------------------------------------------------
function cond_ok(it, n, ctx)
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

