-- Risk of Rogue: engine_procs.lua
-- Item engine, part 3: firing triggers, special items, HUD buff states and proc messages.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

-- run one trigger for one player -----------------------------------------------------------
function fire(trigger, ctx)
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
function ctx_for(pc, extra)
  local name = player_name(pc)
  local st = pstate(name)
  local c = { pc = pc, name = name, st = st, g = gstate(st), pawn = pc.Pawn }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

-- specials -------------------------------------------------------------------------------------
Infected = {} -- Networked Suffering: bot addr -> {bot, owner name}
Pool = 0
Scorp = {}    -- Symbiotic Scorpion: bot addr .. name -> stacks
function special_hit(ctx)
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
function special_kill(ctx)
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
function special_hurt(ctx)
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
function special_lowhp(ctx)
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

