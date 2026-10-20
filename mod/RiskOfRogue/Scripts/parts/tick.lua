-- Risk of Rogue: tick.lua
-- Host tick, the test-command file, and the main loop that drives everything.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- host tick: clock, pawn changes, sync
---------------------------------------------------------------------------
last_sync = 0
function host_tick(gm)
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
  if Dev.enabled and Dev.god then
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
TEST_IN, TEST_OUT = MOD .. "test_cmd.lua", MOD .. "test_out.txt"
function test_mode()
  if not Dev.enabled then return end
  local f = io.open(TEST_IN, "r")
  if not f then return end
  local code = f:read("*a"); f:close(); os.remove(TEST_IN)
  local fn, err = load(code, "test_cmd", "t", setmetatable({ R2 = _G.RiskOfRogue }, { __index = _G }))
  local res
  if fn then local ok, r = pcall(fn); res = (ok and "OK: " or "ERR: ") .. tostring(r) else res = "COMPILE ERR: " .. tostring(err) end
  local o = io.open(TEST_OUT, "a"); if o then o:write(res .. "\n== done\n"); o:close() end
end

hud_acc = 0
test_acc = 0
Settle = { pc = 0, until_ms = 0 }
LoopAsync(TICK_MS, function()
  ExecuteInGameThread(function()
    local ok, err = pcall(function()
      local lp = local_pc()
      -- A real pause (solo) stops the game's clock. Then the mod's clock stops too, so buffs,
      -- cooldowns and timers freeze with the game. In multiplayer the game never pauses, so
      -- this never triggers there and only the HUD hides (in draw_hud).
      local wt = nil
      if lp then pcall(function() wt = cls("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(lp) end) end
      local paused = wt ~= nil and Settle.wt ~= nil and wt == Settle.wt
      Settle.wt = wt
      Settle.paused = paused
      if not paused then now_ms = now_ms + TICK_MS end
      -- After a map load the old world's widgets and actors are being torn down. When the local
      -- player controller changes, drop the HUD and wait a moment before touching game objects.
      local la = lp and addr(lp) or 0
      if la ~= Settle.pc then
        Settle.pc = la; Settle.until_ms = now_ms + SYS.map_settle_ms; HUD = nil; Run.gs = nil
        -- everything that still points at the old world goes: pending timers, cached attribute
        -- sets, auras and infected enemies (calling into a destroyed object crashes UE4SS)
        timers = {}; ATTRSET = {}; Auras = {}; Infected = {}
        if Dev.ST and Dev.ST.running and Dev.ST.on_abort then pcall(Dev.ST.on_abort) end
      end
      if now_ms < Settle.until_ms then return end
      if not paused then
        run_timers()
        local srv, gm = server()
        if srv then host_tick(gm) end
      end
      hud_acc = hud_acc + TICK_MS
      -- follow Deadzone's HUD on every tick, so hiding/showing doesn't wait for the next refresh
      local vis = true
      if HUD and valid(HUD.visor) then pcall(function() vis = HUD.visor:IsVisible() and true or false end) end
      if vis ~= Settle.vis then Settle.vis = vis; hud_acc = SYS.hud_refresh_ms end
      if hud_acc >= SYS.hud_refresh_ms then
        hud_acc = 0; draw_hud()
        local okv, errv = pcall(patch_version)
        if not okv then log("version text: " .. tostring(errv)) end
      end
      local okt, errt = pcall(update_tip)
      if not okt then log("tooltip: " .. tostring(errt)) end
      test_acc = test_acc + TICK_MS
      if test_acc >= 500 then test_acc = 0; test_mode() end
    end)
    if not ok then log("tick error: " .. tostring(err)) end
  end)
  return false
end)

