-- Risk of Rogue: core.lua
-- Shared constants, small helpers and the timer scheduler. Loaded first.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

-- Risk of Rogue: Risk of Rain 2 items in Deadzone: Rogue
-- Risk of Rain 2 items (offered in Deadzone's item orbs) and the RoR2 difficulty clock inside Deadzone runs.
-- Data (items, tiers, tuning) comes from data_gen.lua, generated from the design sheets.
-- The host runs all game logic; clients receive state over PlayerController:ClientMessage
-- and only draw the HUD (plus their own extra jumps).

Data = require("data_gen")
SYS = Data.SYS
MOD = "ue4ss/Mods/RiskOfRogue/"
TAG = "R2|"
VIS, HID = 3, 1 -- ESlateVisibility HitTestInvisible / Collapsed
-- shared, assigned further down: fx, fx_at, can_take, patch_inventory, spawn_fx_local, draw_menu -- defined further down
ShownCards = {} -- bundle keys whose RoR2 card this player can see

function log(s) print("[RiskOfRogue] " .. tostring(s) .. "\n") end
function valid(o) return o ~= nil and type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
function addr(o) return valid(o) and o:GetAddress() or 0 end
function clamp(x, a, b) if x < a then return a elseif x > b then return b end return x end

