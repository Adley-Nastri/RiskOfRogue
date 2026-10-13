# RoR2 Mashup for Deadzone: Rogue

Risk of Rain 2 inside Deadzone: Rogue. You play Deadzone runs as normal, with three things from Risk of Rain 2 added:

- **RoR2 items in Deadzone's item orbs.** Item orbs can offer a RoR2 item as one of their cards: the real icon, the name in its rarity colour, "// RISK OF RAIN 2 … ITEM" and what it does. Pick it and you get that RoR2 item instead of the orb's normal reward. Orb RoR2 items roll 70% white, 25% green and 5% red. RoR2 items never drop on their own.
- **Native items.** Each RoR2 item becomes a real Deadzone item definition (name, description, rarity). It fills a slot in Deadzone's own inventory next to your Deadzone items and counts toward the 18-slot limit. In the Tab menu and on the end-of-run screen, hovering it shows Deadzone's own item tooltip. Only RoR2 items stack ("x2", "x3"…); a full inventory still accepts more copies of RoR2 items you already have.
- **The difficulty clock.** A RoR2-style timer in the top right climbs from Easy through Medium, Hard, Very Hard, Insane and Impossible to I SEE YOU, I'M COMING FOR YOU and HAHAHAHA, moving up a tier every 5 minutes. Every enemy that spawns gets more health, damage and speed the longer the run goes on.
- **RoR2 buff icons and Deadzone effects.** Procs show RoR2 buff icons on the HUD and play Deadzone's own effects (lightning for Ukulele, explosions for Will-o'-the-wisp, Gasoline and Brilliant Behemoth, a heal effect for Medkit and Monster Tooth).

Solo and co-op. In co-op the host runs the items and the clock, and each player's own screens show their own items.

## Items

| Item | Rarity | In Deadzone |
|---|---|---|
| Soldier's Syringe | white | +15% fire rate per stack |
| Lens-Maker's Glasses | white | +10% crit chance per stack |
| Paul's Goat Hoof | white | +14% move speed per stack |
| Tougher Times | white | 15% chance to dodge a hit (stacks hyperbolically, like RoR2) |
| Crowbar | white | +12% damage per stack (simplified: RoR2's only applies to enemies above 90% health) |
| Repulsion Armor Plate | white | each hit to your health is reduced by 12 per stack |
| Monster Tooth | white | heal 10 (+5 per stack) on kill |
| Medkit | white | heal 25 per stack 2 s after taking damage |
| Gasoline | white | kills burn enemies within 12 m (+4 m per stack) |
| Ukulele | green | 25% on hit: lightning chains to 3 (+2 per stack) nearby enemies for 80% of the hit |
| Will-o'-the-wisp | green | kills detonate, damaging enemies within 12 m (+2.4 m per stack) |
| Hopoo Feather | green | +1 jump per stack |
| Infusion | green | +1 max health per kill, per stack (up to 100 per stack) |
| Brilliant Behemoth | red | every hit explodes for 60% of its damage within 4 m (+2.5 m per stack) |

## Test menu

Press **F1** in a run to open the test menu (host or solo only). The other keys only work while it's open, so stray presses do nothing.

| Key | Does |
|---|---|
| F1 | open / close the menu |
| F2 | god mode on / off (keeps you at full health) |
| Up / Down (or F3 / F4) | move through the RoR2 item list |
| Right / Enter (or F5) | give 1 of the selected item |
| Left / Backspace (or F6) | remove 1 of the selected item |
| F7 | give 1 of every RoR2 item |
| F8 | remove all RoR2 items |
| F9 | jump the difficulty clock to the next tier (wraps back to the start) |
| F10 | kill every enemy within 30 m; the kills count as yours, so on-kill items fire |

The menu lists every RoR2 item with how many you hold and its element, plus the god mode state and the clock.

## Requirements

- Deadzone: Rogue (Steam), with UE4SS experimental 3.0.1-1165 installed in `Valhalla\Binaries\Win64`.
- Risk of Rain 2. The item icons come from your own copy and are never shipped with the mod.

## Install (what's on this PC now)

1. UE4SS goes in `Deadzone Rogue\Valhalla\Binaries\Win64\` (`dwmapi.dll` plus the `ue4ss` folder).
2. Copy `ue4ss_overrides\VTableLayout.ini` to `ue4ss\VTableLayout.ini`. Deadzone's engine build has a non-standard memory-allocator layout, and UE4SS crashes on start without this file. Also set `MajorVersion = 5` and `MinorVersion = 6` in `UE4SS-settings.ini`.
3. Copy the `RoR2Mashup` folder to `ue4ss\Mods\`. It needs `Scripts\main.lua`, `Scripts\data_gen.lua` and `enabled.txt`.
4. Put the item icons in `RoR2Mashup\icons\`. They're extracted from your RoR2 install with `tools/extract_icons.py`.

To turn the mod off, delete `RoR2Mashup\enabled.txt`. To remove the loader too, delete `dwmapi.dll`.

## How it's built

The design lives in `sheets/` (items, rarities, difficulty tiers, tuning, hooks, verified APIs). `preflight.py` cross-checks every cell. For example, it confirms each item's icon exists, each game effect it names exists in the game, and each trigger has a hook. `gen.py` refuses to generate until preflight is clean, then writes `Scripts/data_gen.lua`. `main.lua` is the runtime, and it only reads that data.

The game-side techniques, all verified in the running game, are listed in `sheets/apis.json`.

## Known limits

- **More enemies isn't possible.** The clock makes enemies tougher, faster and harder-hitting. It doesn't add more of them, because the game's bot spawner wouldn't spawn on demand from a mod.
- **Not yet in the item row under the minimap.** RoR2 items show in the Tab menu and end-of-run screen, but not yet in the in-run item row next to the Tactical Dataslate. Parked for later.
- **Co-op is untested.** The host-to-client sync works through the game's own PlayerController messages, and it was checked on one PC. Two real players have not tested it yet.
- **Dio's Best Friend was removed.** You asked for this, and the game ends a solo run on death before a mod can step in.
