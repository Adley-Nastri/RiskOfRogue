-- Risk of Rogue: music.lua
-- Optional: Risk of Rain 2's music in place of Deadzone's, timed to Deadzone's own music cues.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).
--
-- How it works (docs/MUSIC.md has the full story, and why it can't go through Wwise itself):
--   * Deadzone's music is held at zero through its MusicVolume game parameter, everywhere.
--   * Like Deadzone, a calm piece plays between waves and a fight piece during them.
--     Calm: one RoR2 stage song per run, never the previous run's. Fight: a different RoR2
--     teleporter (boss) song every wave or room. Outside a run (ship, menus) there's no music.
--   * The songs (extracted from the player's own copy of RoR2 into music/) play through
--     audio/ror_audio.dll, a small open-source player, on the same output device as the game.
--   * The only game hook is AkGameplayStatics:SetState (Deadzone's music states). Its handler just
--     queues the cue; everything runs from Music.tick, which the main loop calls every tick,
--     through pauses and map loads too (the mod's own timers stop or are cleared then).
--   * Volume follows the game's Music and Master sliders, read from GameUserSettings.ini on
--     disk (reading the settings object in memory while the game saves it crashed UE4SS).
--
-- music.txt in the mod folder: "music = ror2" (default) or "music = deadzone".
-- Developer builds (devtools.txt) also log to music_log.txt and accept "music = observe": Deadzone's
-- own music, recorded to observe_<n>.wav (effects muted) with every cue marked, for measuring timings.

Music = {
  on = false,
  mode = "off",        -- "mission" while a run's music plays, "off" otherwise
  phase = "calm",      -- "calm" (stage song), "gap" (wave started, fight music not in yet), "fight"
  combat = false,      -- Deadzone says a wave is on
  token = 0,           -- bumped on every change, so stale delayed steps do nothing
  q = {},              -- cues from the SetState hook, handled on the next tick
  later = {},          -- own timers (os.clock based; map changes don't clear them)
  level = 1,           -- calm level (lower after a death, like vanilla)
  music = 60, master = 70, ini_t = -1e9, last_g = nil,

  -- Timings measured from a music-only recording of vanilla Deadzone (4 waves, observe mode).
  cfg = {
    -- level: matched by ear to Deadzone's music at Music 60 % / Master 70 %, then scaled by the sliders
    anchor_gain = 0.325, anchor_music = 60, anchor_master = 70,
    wave_gain = 1.25,    -- fights sit ~6 dB over calm (the fight tracks are levelled +4 dB, this adds 2)
    arrive_fade = 3500,  -- mission start: fades in over ~3.5 s
    leave_fade = 200,    -- leaving a map: cut over 0.2 s when travel starts
    -- wave starts: vanilla plays a ~1 s transition, drops the calm music and lands the fight music
    -- 3.2-4.8 s after the cue; here the calm song fades out as the fight track comes in (no long gap)
    calm_hold = 2.2, calm_out = 1000, wave_delay = 3.0, wave_in = 600,
    -- wave cleared: fight music drops 0.6-0.8 s after the cue over ~0.5 s; calm back within ~1 s
    clear_delay = 0.6, wave_out = 500, calm_in = 1000,
    -- death: fight music drops ~0.5 s after the cue; what's left is ~3 dB under calm
    death_delay = 0.5, death_fade = 600, death_level = 0.7,
  },

  -- RoR2's stages: { name, stage song, teleporter song }, read from RoR2's own stage definitions
  -- (SceneDef main/boss track). All expansions form one pool; songs not in music/ are skipped.
  -- Calm songs come from the second column, fight tracks from the third.
  stages = {
    { "Titanic Plains",         "song18",       "wave_song05" },
    { "Distant Roost",          "song07",       "wave_song05" },
    { "Abandoned Aqueduct",     "song19",       "wave_song05" },
    { "Gilded Coast",           "song02",       "wave_song05" },
    { "Wetland Aspect",         "song06",       "wave_song22" },
    { "Scorched Acres",         "song18",       "wave_song22" },
    { "Siren's Call",           "song13",       "wave_song22" },
    { "Rallypoint Delta",       "song02",       "wave_song16" },
    { "Abyssal Depths",         "song19",       "wave_song16" },
    { "Sundered Grove",         "dlc1_09",      "wave_song16" },
    { "Sky Meadow",             "song14",       "wave_song23" },
    { "Siphoned Forest",        "dlc1_03",      "wave_dlc1_10" },
    { "Aphelian Sanctuary",     "dlc1_01",      "wave_dlc1_10" },
    { "Sulfur Pools",           "dlc1_06",      "wave_dlc1_12" },
    { "Void Locus",             "dlc1_08",      "wave_dlc1_10" },
    { "Verdant Falls",          "dlc2_07",      "wave_dlc2_08" },
    { "Treeborn Colony",        "dlc2_02",      "wave_dlc2_08" },
    { "Shattered Abodes",       "dlc2_09",      "wave_dlc2_04" },
    { "Reformed Altar",         "dlc2_01",      "wave_dlc2_04" },
    { "Helminth Hatchery",      "dlc2_05",      "wave_dlc2_06" },
    { "Pretender's Precipice",  "dlc3_02",      "wave_dlc3_07" },
    { "Iron Alluvium",          "dlc3_03",      "wave_dlc3_07" },
    { "Repurposed Crater",      "dlc3_04",      "wave_dlc3_07" },
    { "Conduit Canyon",         "dlc3_06",      "wave_dlc3_07" },
    { "Solutional Haunt",       "dlc3_01",      "wave_dlc3_08" },
    { "Computational Exchange", "dlc3_05",      "wave_dlc1_10" },
    { "Mire",                   "dlc4_mire",    "wave_dlc4_mush" },
    { "Fungal",                 "dlc4_fungal",  "wave_dlc4_mush" },
    { "Sanctum",                "dlc4_sanctum", "wave_dlc4_mush" },
  },
  extra_waves = { "wave_dlc4_lynx" },  -- RoR2 boss music with no stage of its own
}

local AUDIO = MOD .. "audio/"
local MUSIC_DIR = MOD .. "music/"
local RTPC_DIR = "/Game/WwiseAudio/Game_Parameters/AudioGameParameters/"
local LAST_FILE = MOD .. "music_last.txt"

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function read_all(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function write_all(p, s) local f = io.open(p, "wb"); if f then f:write(s); f:close() end end

-- developer builds: what the music did and which cues arrived (music_log.txt)
function Music.note(s)
  if not Dev.enabled then return end
  local f = io.open(MOD .. "music_log.txt", "a")
  if f then f:write(string.format("%9.2f %-8s %s\n", os.clock(), Music.mode, s)); f:close() end
end

-- one command to the audio player (it reads cmd.txt and answers in status.txt)
function Music.send(c)
  local f = io.open(AUDIO .. "cmd.txt", "wb"); if not f then return "" end
  f:write(c); f:close()
  pcall(Music.fn)
  local st = read_all(AUDIO .. "status.txt") or ""
  Music.note("> " .. c:sub(1, 48) .. "  [" .. st:sub(1, 30):gsub("%s+$", "") .. "]")
  return st
end

local Ak, RTPC_MUSIC, RTPC_MASTER
local function ak()
  if not valid(Ak) then Ak = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end
  if not valid(RTPC_MUSIC) then RTPC_MUSIC = StaticFindObject(RTPC_DIR .. "MusicVolume.MusicVolume") end
  if not valid(RTPC_MASTER) then RTPC_MASTER = StaticFindObject(RTPC_DIR .. "MasterVolume.MasterVolume") end
  return valid(Ak) and valid(RTPC_MUSIC)
end
local function get_rtpc(r)
  local v, t = {}, {}
  pcall(function() Ak:GetRTPCValue(r, 0, 1, v, t, nil) end)
  return v.Value
end
local function set_rtpc(r, x) pcall(function() Ak:SetRTPCValue(r, x, 0, nil) end) end

local function in_mission()
  local ok, m = pcall(function()
    local gm = FindFirstOf("GameModeBase")
    return valid(gm) and gm:GetClass():GetFName():ToString():find("Dungeon") ~= nil
  end)
  return ok and m
end
local function match_state()
  local ok, ms = pcall(function()
    local gs = FindFirstOf("GameState")
    return valid(gs) and gs.MatchState:ToString() or nil
  end)
  return ok and ms or nil
end
local function leaving(ms) return ms == "LeavingMap" or ms == "WaitingPostMatch" end

-- a random entry, not the same as `last` (when there's a choice)
local function pick(list, last)
  local l = {}
  for _, x in ipairs(list) do if x ~= last then l[#l + 1] = x end end
  if #l == 0 then l = list end
  return l[math.random(#l)]
end
local function after_s(sec, fn) Music.later[#Music.later + 1] = { t = os.clock() + sec, fn = fn } end

---------------------------------------------------------------------------
-- volume: the sliders, from Deadzone's saved settings (0..1 there; keys only appear once changed)
---------------------------------------------------------------------------
function Music.read_sliders()
  local la = os.getenv("LOCALAPPDATA")
  local s = la and read_all(la .. "\\Valhalla\\Saved\\Config\\Windows\\GameUserSettings.ini") or ""
  local m = tonumber(s:match('"MusicSoundVolume",%s*"([%d%.]+)"'))
  local ma = tonumber(s:match('"MasterSoundVolume",%s*"([%d%.]+)"'))
  Music.music = m and m * 100 or 60
  if ma then Music.master = ma * 100
  elseif valid(RTPC_MASTER) then Music.master = get_rtpc(RTPC_MASTER) or Music.master end
end
function Music.gain()
  local c = Music.cfg
  return c.anchor_gain * (Music.music / c.anchor_music) * (Music.master / c.anchor_master)
end
-- the current phase at the current slider level
function Music.apply(fade)
  if Music.mode ~= "mission" then return end
  local g = Music.gain()
  Music.last_g = g
  fade = fade or 300
  if Music.phase == "fight" then Music.send(string.format("mix 0 %.4f %d", g * Music.cfg.wave_gain, fade))
  elseif Music.phase == "gap" then Music.send(string.format("mix 0 0 %d", fade))
  else Music.send(string.format("mix %.4f 0 %d", g * Music.level, fade)) end
end

---------------------------------------------------------------------------
-- arriving, leaving, waves
---------------------------------------------------------------------------
-- one calm song per run, never the previous run's (remembered across game restarts)
local function calm_for_run()
  if Music.run_ref == Run and Music.calm then return end
  Music.run_ref = Run
  local last = Music.calm or (read_all(LAST_FILE) or ""):match("[%w_]+")
  Music.calm = pick(Music.calm_ok, last)
  if Music.calm then write_all(LAST_FILE, Music.calm) end
end

function Music.arrive()
  if not in_mission() then Music.leave(); return end
  if Music.mode == "mission" then return end
  calm_for_run()
  if not Music.calm then return end
  Music.read_sliders()
  Music.mode, Music.phase, Music.combat, Music.level = "mission", "calm", false, 1
  Music.token = Music.token + 1
  Music.last_g = Music.gain()
  Music.send(string.format("play %d 1 %.4f %s%s_explore.ogg", Music.cfg.arrive_fade, Music.last_g, MUSIC_DIR, Music.calm))
  Music.note("calm " .. Music.calm)
end

function Music.leave()
  if Music.mode ~= "mission" then return end
  Music.send("stop " .. Music.cfg.leave_fade)
  Music.mode, Music.phase, Music.combat = "off", "calm", false
  Music.token = Music.token + 1
end

-- wave starts: the calm song fades out, a new fight track comes in from its beginning
function Music.on_combat()
  if Music.mode ~= "mission" or Music.combat then return end
  Music.combat = true
  Music.token = Music.token + 1
  local my, c = Music.token, Music.cfg
  local function live() return my == Music.token and Music.mode == "mission" end
  after_s(c.calm_hold, function()
    if not live() then return end
    Music.phase, Music.level = "gap", 1
    Music.send(string.format("mix 0 0 %d", c.calm_out))
  end)
  after_s(c.wave_delay, function()
    if not live() then return end
    Music.wave = pick(Music.wave_ok, Music.wave)   -- a different fight track every wave or room
    Music.phase = "fight"
    Music.note("fight " .. Music.wave)
    Music.send(string.format("layer %d 1 %.4f %s%s.ogg", c.wave_in, Music.gain() * c.wave_gain, MUSIC_DIR, Music.wave))
  end)
end

-- back to the calm song (it kept playing silently, so it carries on where it was)
local function back_to_calm(delay, out_ms, in_ms, level)
  if Music.mode ~= "mission" then return end
  Music.combat = false
  Music.token = Music.token + 1
  local my = Music.token
  after_s(delay, function()
    if my ~= Music.token or Music.mode ~= "mission" or Music.phase == "calm" then return end
    Music.phase, Music.level = "calm", level or 1
    Music.send("unlayer " .. out_ms)
    Music.send(string.format("mix %.4f 0 %d", Music.gain() * Music.level, in_ms))
  end)
end
function Music.on_safe()
  local c = Music.cfg
  if Music.combat then back_to_calm(c.clear_delay, c.wave_out, c.calm_in) end
end
function Music.on_dead()
  local c = Music.cfg
  back_to_calm(c.death_delay, c.death_fade, c.death_fade, c.death_level)
end

---------------------------------------------------------------------------
-- developer builds, music = observe: record vanilla's music in each mission (effects, voice and
-- ambience turned down meanwhile) to observe_<n>.wav, with every cue marked in it
---------------------------------------------------------------------------
local QUIET = { "SFXVolume", "VOXVolume", "AmbientVolume" }
local function observe_tick()
  if not Music.rec then
    if not in_mission() then return end
    Music.rec_n = (Music.rec_n or 0) + 1
    Music.saved = {}
    for _, n in ipairs(QUIET) do
      local r = StaticFindObject(RTPC_DIR .. n .. "." .. n)
      Music.saved[n] = get_rtpc(r) or 100
      set_rtpc(r, 0)
    end
    Music.send("record start " .. MOD .. "observe_" .. Music.rec_n .. ".wav")
    Music.rec = true
    return
  end
  local ms = match_state()
  if ms and ms ~= Music.match then Music.match = ms; Music.send("mark match " .. ms) end
  if leaving(ms) or not in_mission() then
    Music.send("record stop")
    for n, v in pairs(Music.saved or {}) do set_rtpc(StaticFindObject(RTPC_DIR .. n .. "." .. n), v) end
    Music.rec, Music.match = false, nil
  end
end

---------------------------------------------------------------------------
-- the tick (called by the main loop in tick.lua, before it waits out map loads)
---------------------------------------------------------------------------
local function run_queue()
  local q = Music.q
  Music.q = {}
  for _, f in ipairs(q) do
    local ok, err = pcall(f)
    if not ok then log("music: " .. tostring(err)) end
  end
end

function Music.tick(settling)
  if not Music.on or not ak() then return end
  if Music.observe then
    if not settling then run_queue(); pcall(observe_tick) end
    return
  end
  set_rtpc(RTPC_MUSIC, 0)   -- every tick: the game re-applies its slider on loads and settings changes
  local now = os.clock()
  if #Music.later > 0 then
    local keep, due = {}, {}
    for _, t in ipairs(Music.later) do if t.t <= now then due[#due + 1] = t.fn else keep[#keep + 1] = t end end
    Music.later = keep
    for _, f in ipairs(due) do local ok, err = pcall(f); if not ok then log("music: " .. tostring(err)) end end
  end
  if settling then return end   -- cues wait until the new map is there
  if #Music.q > 0 then run_queue() end
  -- once a second: sliders, and whether we're still (or now) in a run
  if now - Music.ini_t >= 1 then
    Music.ini_t = now
    Music.read_sliders()
    if Music.mode == "mission" and not in_mission() then
      Music.note("left the run"); Music.leave()          -- main menu, ship, anything else
    elseif Music.mode ~= "mission" and #Music.q == 0 and in_mission() and match_state() == "InProgress" then
      Music.note("in a run without a loading cue"); Music.arrive()
    end
    if Music.mode == "mission" and math.abs(Music.gain() - (Music.last_g or 0)) > 0.0005 then Music.apply(300) end
  end
  -- vanilla cuts the music the moment travel starts, and once the match has ended
  if Music.mode == "mission" and leaving(match_state()) then Music.leave() end
end

---------------------------------------------------------------------------
-- start-up
---------------------------------------------------------------------------
local CUES = {
  ["CombatState-Combat"] = function() Music.on_combat() end,
  ["CombatState-Safe"] = function() Music.on_safe() end,
  ["DeadOrAlive-PlayerDead"] = function() Music.on_dead() end,
  ["LoadingState-Loading"] = function() Music.arrive() end,
}

function Music.init()
  local choice = ((read_all(MOD .. "music.txt") or ""):match("music%s*=%s*([%w_]+)") or "ror2"):lower()
  Music.observe = choice == "observe" and Dev.enabled
  if choice ~= "ror2" and not Music.observe then log("music: Deadzone's own (music.txt)"); return end

  Music.calm_ok, Music.wave_ok = {}, {}
  local seen = {}
  local function add(list, name, file)
    if not seen[name] and exists(MUSIC_DIR .. file) then seen[name] = true; list[#list + 1] = name end
  end
  for _, st in ipairs(Music.stages) do
    add(Music.calm_ok, st[2], st[2] .. "_explore.ogg")
    add(Music.wave_ok, st[3], st[3] .. ".ogg")
  end
  for _, w in ipairs(Music.extra_waves) do add(Music.wave_ok, w, w .. ".ogg") end
  if not Music.observe and (#Music.calm_ok == 0 or #Music.wave_ok == 0) then
    log("music: no RoR2 songs in music/, using Deadzone's own"); return
  end

  local fn, err = package.loadlib(AUDIO .. "ror_audio.dll", "ror_audio_cmd")
  if not fn then log("music: audio/ror_audio.dll not loaded (" .. tostring(err) .. "), using Deadzone's own"); return end
  Music.fn = fn
  math.randomseed(os.time())

  local ok, herr = pcall(function()
    RegisterHook("/Script/AkAudio.AkGameplayStatics:SetState", function(self, sv)
      local okn, name = pcall(function() return sv:get():GetFName():ToString() end)
      if not okn then return end
      if Dev.enabled then
        Music.q[#Music.q + 1] = function()
          Music.note("cue " .. name)
          if Music.rec then Music.send("mark cue " .. name) end
        end
      end
      local f = CUES[name]
      if f and not Music.observe then Music.q[#Music.q + 1] = f end
    end)
  end)
  if not ok then log("music: hook failed (" .. tostring(herr) .. "), using Deadzone's own"); return end

  Music.on = true
  if Music.observe then log("music: observing Deadzone's own music (music.txt)"); return end
  Music.q[#Music.q + 1] = Music.arrive   -- in case the mod loads inside a mission
  log("music: Risk of Rain 2 (" .. #Music.calm_ok .. " calm songs, " .. #Music.wave_ok .. " fight tracks)")
end
Music.init()
if Dev.enabled then _G.RoR_Music = Music end   -- for the test-command file
