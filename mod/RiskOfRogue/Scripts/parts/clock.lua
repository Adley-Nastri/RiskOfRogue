-- Risk of Rogue: clock.lua
-- The RoR2 difficulty clock: tiers and the enemy buffs it applies.
-- Runs in the shared mod environment set up by main.lua (see docs/DEVELOPMENT.md).

---------------------------------------------------------------------------
-- difficulty clock
---------------------------------------------------------------------------
function tier_index(secs)
  local m = secs / 60
  local idx = 1
  for i, t in ipairs(Data.DIFFICULTY_TIERS) do if m >= t.start_min then idx = i end end
  return idx
end
function clock_buff(bot, extra_hp, extra_dmg, extra_speed)
  local m = Run.clock / 60
  local hp_mult = (1 + SYS.clock_health_per_min * m) * (extra_hp or 1)
  local dmg_add = SYS.clock_damage_per_min * m + (extra_dmg or 0)
  local spd = (1 + math.min(SYS.clock_speed_cap, SYS.clock_speed_per_min * m)) * (extra_speed or 1)
  if hp_mult > 1.001 then apply_magnitude(bot, GE_MAXHP_MULT, hp_mult) end
  if dmg_add > 0.001 then apply_magnitude(bot, GE_DMG_ADD, dmg_add) end
  if spd > 1.001 then apply_magnitude(bot, GE_SPEED_MULT, spd) end
  bot:SetHealth(bot:GetHealthMax() * 1.0)
end

