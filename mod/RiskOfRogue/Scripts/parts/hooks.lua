-- Risk of Rogue: hooks.lua
-- Game hooks (host): kills, damage, new characters, orbs, encounters, client messages.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- hooks (host)
---------------------------------------------------------------------------
function on_bot_killed(victim, killer)
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
function on_damaged(victim, d)
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

function on_new_character(c)
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

hooks_ok = {}
function hook(id, fn)
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
okn, errn = pcall(function() NotifyOnNewObject(Data.HOOKS.new_character, function(c) on_new_character(c) end) end)
if not okn then log("NotifyOnNewObject failed: " .. tostring(errn)) end
okb, errb = pcall(function()
  NotifyOnNewObject(Data.HOOKS.new_bundle, function(b)
    after(500, function() if server() then roll_offer(b) end end)
  end)
end)
if not okb then log("bundle watch failed: " .. tostring(errb)) end

last_encounter = -1e9
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
function split(s, sep)
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

