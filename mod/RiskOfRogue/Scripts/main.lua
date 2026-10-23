-- Risk of Rogue: Risk of Rain 2 items in Deadzone: Rogue
--
-- This file only loads the mod. The code lives in Scripts/parts/, one file per area, and every
-- part runs in ONE shared environment, in the order below: a name a part defines at its top level
-- is visible to the parts after it (and to functions in earlier parts once they run). Lua and
-- UE4SS globals (print, FindAllOf, RegisterHook, ...) are reached through that environment.
-- See docs/DEVELOPMENT.md for which part does what.

local PARTS_DIR = "ue4ss/Mods/RiskOfRogue/Scripts/parts/"
local PARTS = {
  "core",           -- constants, helpers, timer scheduler
  "game",           -- game helpers: classes, bots, attributes, damage, elemental statuses
  "state",          -- run state, messages to clients, giving and taking items
  "clock",          -- difficulty clock
  "orbs",           -- RoR2 cards in item orbs
  "engine_base",    -- item engine: context, shields and healing, damage helpers
  "engine_actions", -- item engine: actions, buffs, conditions
  "engine_procs",   -- item engine: firing triggers, specials, buff states, proc messages
  "engine_tick",    -- item engine: per-tick work, entry points for the hooks
  "hooks",          -- game hooks
  "fx",             -- visual effects
  "native",         -- RoR2 items as native Deadzone items
  "hud_widgets",    -- HUD building blocks
  "devmenu",        -- developer test menu (only with devtools.txt)
  "hud",            -- the HUD
  "music",          -- optional: Risk of Rain 2 music in place of Deadzone's
  "tick",           -- host tick, test-command file, main loop
  "api",            -- self-test launcher and debug API (last)
}

local env = setmetatable({}, { __index = _G })
for _, name in ipairs(PARTS) do
  local chunk, err = loadfile(PARTS_DIR .. name .. ".lua", "t", env)
  if not chunk then
    print("[RiskOfRogue] could not load parts/" .. name .. ".lua: " .. tostring(err) .. "\n")
    return
  end
  local ok, runerr = pcall(chunk)
  if not ok then
    print("[RiskOfRogue] error in parts/" .. name .. ".lua: " .. tostring(runerr) .. "\n")
    return
  end
end
