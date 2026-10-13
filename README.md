# Risk of Rogue

**Risk of Rain 2 items in Deadzone: Rogue.**

A fan mod that brings 74 Risk of Rain 2 items into Deadzone: Rogue. They don't sit on top of the game: they become real Deadzone items. They show up in Deadzone's own item orbs, inventory, tooltips and HUD, use Deadzone's elements and keywords, and stack the way they do in Risk of Rain 2.

> Unofficial fan project. Not affiliated with or endorsed by Hopoo Games, Gearbox or the makers of Deadzone: Rogue. **No Risk of Rain 2 art is included.** The item icons are extracted from your own copy of Risk of Rain 2 by a script in this repo.

## Features

- **74 items** from Risk of Rain 2 and its DLCs, Common, Uncommon and Legendary: every one whose mechanic exists in Deadzone. Full list with exact numbers in [docs/ITEMS.md](docs/ITEMS.md).
- **Native item orbs.** Deadzone's item orbs can offer a RoR2 item as one of their cards, with its icon, its rarity and what it does. Pick it and it's yours.
- **Native inventory.** RoR2 items fill slots in Deadzone's own inventory, with Deadzone's rarity border, its tooltip on hover and "x2", "x3" stacks.
- **Deadzone's elements and keywords.** Items deal Fire, Lightning, Cryo, Void, Psionic and Nano damage, apply Ignite, Shock, Chill, Freeze, Corruption, Fracture and Mark, can Critical Hit, and scale with your elemental upgrades. Descriptions use Deadzone's own icons and highlighted keywords.
- **RoR2 buff icons.** A row of RoR2 buff icons above your health bar shows which item buffs are active, and short messages show notable procs ("Faraday Spur struck 4 enemies").
- **The RoR2 difficulty clock.** It starts with Deadzone's run timer and climbs from *Easy* to *HAHAHAHA*, one tier every 5 minutes. Enemies get tougher, hit harder and move faster the longer the run goes on.
- **Feels like part of the game.** The HUD hides with Deadzone's HUD, freezes while the game is paused, and keeps RoR2's flavour text.

## Requirements

- **Deadzone: Rogue** on Steam (Windows). Tested with game version 1.4.2.0.
- **Risk of Rain 2** installed on the same PC. It's only needed once, to extract the icons.
- **UE4SS** experimental build 3.0.1 (tested with build 1165, git `5e627997`). Deadzone runs on Unreal Engine 5.6, which needs this experimental build.
- **Python 3.10+**, for the one-time icon extraction. Get it from [python.org](https://www.python.org/downloads/) and tick "Add python.exe to PATH" while installing.

## Installation

The game folder is usually `C:\Program Files (x86)\Steam\steamapps\common\Deadzone Rogue`. In Steam: right-click Deadzone: Rogue → Manage → Browse local files. Below, `Win64` means `Deadzone Rogue\Valhalla\Binaries\Win64`.

### 1. Install UE4SS

1. Download UE4SS from the [RE-UE4SS releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases). Take the **experimental** release and the regular zip, not the one starting with `zDEV`.
2. Extract it into `Win64`, so you get `Win64\dwmapi.dll` and the folder `Win64\ue4ss\`.
3. Copy [`ue4ss_overrides/VTableLayout.ini`](ue4ss_overrides/VTableLayout.ini) from this repo into `Win64\ue4ss\`. Deadzone's engine build has a non-standard memory layout, and UE4SS crashes on start without this file.
4. Open `Win64\ue4ss\UE4SS-settings.ini` and set the engine version under `[EngineVersionOverride]`:
   ```ini
   [EngineVersionOverride]
   MajorVersion = 5
   MinorVersion = 6
   ```

### 2. Install the mod

1. Download this repo: **Code → Download ZIP** on GitHub, or the latest file from [Releases](../../releases), and unzip it anywhere.
2. Copy the folder `mod\RiskOfRogue` into `Win64\ue4ss\Mods\`, so you have `Win64\ue4ss\Mods\RiskOfRogue\Scripts\main.lua` and `Win64\ue4ss\Mods\RiskOfRogue\enabled.txt`.

### 3. Extract the icons from your Risk of Rain 2

In the unzipped repo, double-click **`tools\Extract RoR2 Icons.bat`**.

It installs the two Python packages it needs (UnityPy and Pillow), finds both games through Steam, and writes 95 icons into `Mods\RiskOfRogue\icons\`. It takes about 15 seconds. If a game isn't found automatically, run it from a command prompt and tell it where the games are:

```bat
py tools\extract_ror2_assets.py --ror2 "D:\SteamLibrary\steamapps\common\Risk of Rain 2"
py tools\extract_ror2_assets.py --out "D:\SteamLibrary\steamapps\common\Deadzone Rogue\Valhalla\Binaries\Win64\ue4ss\Mods\RiskOfRogue\icons"
```

### 4. Play

Start Deadzone: Rogue and begin a run. The RoR2 clock appears in the top right once you go through the first door, and item orbs start offering RoR2 items.

To check that it loaded, look in `Win64\ue4ss\UE4SS.log` for the line `[RiskOfRogue] loaded: 74 items, 9 difficulty tiers`.

## Updating and uninstalling

- **Update:** replace `Mods\RiskOfRogue\Scripts\` with the new one. Your icons stay. Re-run the extractor only if the changelog says new icons were added.
- **Turn off:** delete `Mods\RiskOfRogue\enabled.txt`.
- **Uninstall:** delete the `Mods\RiskOfRogue` folder. To remove UE4SS as well, delete `Win64\dwmapi.dll` and `Win64\ue4ss\`.

## How it plays

- **Getting items:** item orbs show a RoR2 card next to the normal choices. RoR2 cards roll Common 70%, Uncommon 25% and Legendary 5%. RoR2 items never drop on their own.
- **Inventory:** RoR2 items share Deadzone's 18 item slots. When your inventory is full, you can still take more copies of RoR2 items you already have.
- **Stacking:** every RoR2 item stacks. The description says what each extra copy adds, for example "(+20% per stack)".
- **The clock:** it doesn't add more enemies, but every enemy that spawns later is stronger. The clock resets when you return to the ship.

## Multiplayer

Solo is fully supported. In co-op the host runs the items and the clock, and each player sees their own items. **Co-op hasn't been tested with two players yet.** Reports are welcome.

## Troubleshooting

| Problem | Fix |
|---|---|
| Game crashes on start after installing UE4SS | Check that `VTableLayout.ini` is in `Win64\ue4ss\` and the engine version is set to 5.6. |
| No `[RiskOfRogue]` lines in `UE4SS.log` | The folder must be exactly `Mods\RiskOfRogue\` and contain `enabled.txt`. |
| RoR2 items have blank icons | Run the icon extractor (step 3). It prints any icon it couldn't find. |
| The extractor can't find a game | Pass the folder with `--ror2` or `--out` (see step 3). |
| "UnityPy is missing" | Run `py -m pip install -r tools\requirements.txt`. |
| Crash during a run | Please open an issue and attach `UE4SS.log` and the newest folder from `%LOCALAPPDATA%\Valhalla\Saved\Crashes`. |

## For modders and contributors

The `main` branch is the release. The [`testing`](../../tree/testing) branch has developer tools: an F1 test menu to give yourself any item, god mode, and an in-game self-test that triggers every item against real enemies and reports PASS or FAIL. Everything about how the mod is built is in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). The engineering log, with what was tried and what worked, is in [docs/DEVLOG.md](docs/DEVLOG.md).

## Credits

- **Risk of Rain 2** by Hopoo Games, published by Gearbox Publishing. Item names, effects and flavour text are theirs, and the icons come from your own copy.
- **Deadzone: Rogue** by its developers, whose UI, effects, elements and keywords this mod builds on.
- **[UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)**, the mod loader that makes Lua mods for Unreal games possible.
- **[UnityPy](https://github.com/K0lb3/UnityPy)**, used by the icon extractor.

## License

The mod's own code and data are under the [MIT License](LICENSE). Risk of Rain 2 and Deadzone: Rogue and their assets belong to their respective owners and are not covered by this license.
