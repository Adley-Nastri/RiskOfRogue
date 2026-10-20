# CLAUDE.md

Context for Claude (and other AI assistants) working on this repo. The human-facing overview is `README.md`; it's kept short on purpose. Everything technical lives here and in `docs/`.

## What this is

**Risk of Rogue**: a UE4SS Lua mod for **Deadzone: Rogue** (Steam, Windows, Unreal Engine 5.6, game version 1.4.2.0) that adds **74 Risk of Rain 2 items** as native Deadzone items. Formerly called "RoR2 Mashup" (old folder `RoR2Mashup`; `docs/DEVLOG.md` uses that name).

- Items are offered in Deadzone's item orbs (one RoR2 card next to the normal choices; rarity weights Common 70 / Uncommon 25 / Legendary 5). They never drop on their own.
- Each RoR2 item is a copy of a vanilla Deadzone item definition (template `/Game/Items/Items/Item_ArmorValue`) with its own name, description and rarity, so Deadzone's inventory (18 slots, shared), tooltips and rarity borders work natively. Only RoR2 items stack ("x2"); a full inventory still accepts copies of RoR2 items already held.
- Items use Deadzone's elements and statuses (Fire/Ignite, Lightning/Shock, Cryo/Chill/Freeze, Void/Corruption, Psionic/Fracture, Nano/Infect, Mark = `GE_GrenadeWeakened`). Item damage can Critical Hit (procs from a hit inherit its crit; other procs roll the player's crit chance, +15% vs Shocked targets; DoT ticks never crit). Marked targets take +50% from item damage.
- HUD (one UMG widget the mod builds): RoR2 difficulty clock (top right, 9 tiers Easy→HAHAHAHA, 5 min each, starts with Deadzone's run timer via `ValGameState_SpaceDungeon:HasRunStarted()`), RoR2 buff-icon row above the health bar (tilted 2°, untinted PNGs, no stack numbers), proc-message ticker, pickup banner. Shown only while Deadzone's own HUD (`UI_Game_Visor_C`) is visible; the mod's clock freezes when the world clock stands still (solo pause).
- Co-op: host runs all logic; clients get state over `PlayerController:ClientMessage` and draw the HUD. **Untested with two players.**
- No RoR2 assets are shipped. `tools/extract_ror2_assets.py` extracts 95 PNGs (74 item icons + 21 buff icons) from the player's own RoR2 install.

## Install facts (verified on the maintainer's PC)

- UE4SS **experimental 3.0.1** (build 1165, git `5e627997`) in `Deadzone Rogue\Valhalla\Binaries\Win64` (`dwmapi.dll` + `ue4ss\`).
- Requires `ue4ss_overrides/VTableLayout.ini` copied into `Win64\ue4ss\` (UE4SS crashes on start without it) and `[EngineVersionOverride] MajorVersion = 5, MinorVersion = 6` in `UE4SS-settings.ini`.
- Mod folder: `Win64\ue4ss\Mods\RiskOfRogue\` with `Scripts\main.lua`, `Scripts\data_gen.lua`, `enabled.txt`, `icons\*.png`.
- Load check: `Win64\ue4ss\UE4SS.log` contains `[RiskOfRogue] loaded: 74 items, 9 difficulty tiers` (suffix ` (developer tools ON)` on the testing build).
- Crash reports: `%LOCALAPPDATA%\Valhalla\Saved\Crashes\<newest>\` (`CrashContext.runtime-xml`, `Valhalla.log`).
- Icon extractor: `tools\Extract RoR2 Icons.bat` (pip-installs `tools/requirements.txt`: UnityPy, Pillow; finds both games through Steam's registry + `libraryfolders.vdf`; `--ror2`, `--out`, `--force`). About 15 s; output verified pixel-identical to the development icons.

## Branches

| Branch | Contents |
|---|---|
| `main` | Release. No `mod/RiskOfRogue/devtools.txt`, no `Scripts/selftest.lua`. |
| `testing` | Development. Has both files; `devtools.txt` switches on the F1 test menu, god mode, self-test and the test-command file. |

Work on `testing`, merge to `main` for a release, keep the two dev files deleted on `main`. The maintainer wants **every change committed** so it can be rolled back.

## Layout and pipeline

See `docs/DEVELOPMENT.md` for the full version.

- `sheets/*.json`: the design (items, item_text, elements, buffs, procs, systems, hooks, inventory, rarities, difficulty_tiers, orbs, fx, apis).
- `python gen.py`: runs `preflight.py` (cross-checks every sheet; stops on any error), then writes `mod/RiskOfRogue/Scripts/data_gen.lua` and `docs/ITEMS.md`. **Never edit `data_gen.lua` or `docs/ITEMS.md` by hand.**
- `research/build_items.py` builds `sheets/items.json`; `research/build_item_text.py` builds `sheets/item_text.json` (Deadzone rich text: `<em>`, `<element_fire>` etc., `<img id="..."/>`; shorthand `*x*` and `{KEY}`).
- `research/game_classes.txt`, `game_functions.txt`, `game_ge_classes.txt`: names from a UE4SS dump, used by preflight.
- `tools/ror2_assets.json`: which RoR2 texture and bundle each icon comes from.
- `main.lua` and `data_gen.lua` load once at game start (restart to apply). `selftest.lua` reloads every time a self-test starts.

## Developer tools (testing branch, `devtools.txt` present)

F1 menu (F2 god mode, arrows/PgUp/PgDn select, Right/Enter give, Left/Backspace remove, F7/F8 give/remove all, F9 next clock tier, F10 kill within 30 m, Home self-test, End re-test failed items). Self-test writes `selftest.txt` (PASS / FAIL / MANUAL) and `selftest_failed.txt`. Test-command file: a Lua snippet saved as `Mods/RiskOfRogue/test_cmd.lua` runs within 0.5 s; result appended to `test_out.txt`; `R2I` exposes internals.

Last full self-test: 66 PASS, 3 FAIL (all fixed since: Topaz Brooch/Aegis measurement and Aegis rounding, Tesla Coil timing), 5 MANUAL (Hiker's Boots, Rose Buckler, Bandolier, 57 Leaf Clover, Substandard Duplicator need a human).

## Rules that keep it stable (learned from crashes, see DEVLOG)

- **Never sweep all properties of a live object** (generic reflection reads crash UE4SS). Read named properties and call named UFunctions only. Listing function *names* of a class is fine.
- **No native hooks** on hot paths (`GetAssetById` / `UpdateBrushForItem` crashed the Lua VM). Blueprint/UFunction hooks are OK but each adds risk; three slot-icon flash hooks were tried and reverted.
- **No game calls inside Lua coroutines.** Use `after(ms, fn)` timer chains.
- **Map changes:** when the local PlayerController changes, the mod drops its HUD, pending timers, cached attribute sets, auras and infected enemies, and waits 1.5 s (`map_settle_ms`).
- **`main.lua`'s main chunk is near Lua's 200-local limit.** Put new code in functions or tables (`Procs`, `Native`, `Dev`, `R2I`).
- Don't teleport the player (lands outside the level). Inspection scripts must be read-only.
- Ask before quitting the user's runs; if a tool call is rejected, stop and wait.

## Known limits / open items

- Item row under the minimap (`WBP_ActiveItemsDisplay_C`) doesn't show RoR2 items (parked).
- Brief default-icon flash when opening Tab (cosmetic; fixes reverted).
- Old War Stealthkit's RoR2 cooldown buff icon not found in the bundles, so not shown.
- Co-op untested.
