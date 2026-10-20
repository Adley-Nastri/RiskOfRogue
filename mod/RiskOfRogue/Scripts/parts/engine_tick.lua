-- Risk of Rogue: engine_tick.lua
-- Item engine, part 4: per-tick work and the entry points the hooks call.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

-- per-tick work for every player (host) ---------------------------------------------------------
cond_acc, regen_acc, pool_acc = 0, 0, 0
function engine_tick()
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
function engine_kill(victim, killer)
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
function engine_hit(victim, inst, amount, d)
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
function engine_hurt(victim, amount, d)
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
function engine_all(trigger)
  for _, pc in ipairs(FindAllOf("ValPlayerController") or {}) do
    if valid(pc) and alive(pc.Pawn) then fire(trigger, ctx_for(pc)) end
  end
end
function engine_orb(pc) if valid(pc) and alive(pc.Pawn) then fire("orb", ctx_for(pc)) end end
function engine_stage_start() Run.stage = (Run.stage or 0) + 1; engine_all("stage") end

