<h1 align="center">Risk of Rogue</h1>

<p align="center">
  <b>Risk of Rain 2 items, in Deadzone: Rogue.</b><br>
  74 items · native look and feel · the RoR2 difficulty timer
</p>

<p align="center">
  <a href="docs/ITEMS.md">Item list</a> ·
  <a href="#install">Install</a> ·
  <a href="#help">Help</a> ·
  <a href="docs/DEVELOPMENT.md">For modders</a>
</p>

---

Grab a Soldier's Syringe, an Ukulele or a Brilliant Behemoth mid-run. Risk of Rogue adds 74 items from Risk of Rain 2 to Deadzone: Rogue. They come from the normal item orbs, sit in your inventory, and stack the way they do in RoR2.

<!-- Screenshot goes here: ![Risk of Rogue in game](docs/screenshot.png) -->

## Features

| | |
|---|---|
| 🎒 **74 items** | Common, Uncommon and Legendary, from the base game and the DLCs. |
| 🧩 **Feels native** | Deadzone's own item cards, inventory, tooltips and elemental damage. |
| ✨ **Buff icons** | RoR2's buff icons appear above your health bar. |
| ⏱️ **Difficulty timer** | The longer your run lasts, the tougher the enemies get. |

## Install

You'll need **Deadzone: Rogue** and **Risk of Rain 2** on the same PC, and **[Python](https://www.python.org/downloads/)**. When installing Python, tick *"Add python.exe to PATH"*.

### Download

Get **`RiskOfRogue_v1.0.0.zip`** from the [latest release](../../releases/latest). It contains only what you need:

| In the zip | What it is | What to do with it |
|---|---|---|
| `RiskOfRogue` folder | The mod | Copy into `Win64\ue4ss\Mods\` (step 3) |
| `ue4ss_overrides\VTableLayout.ini` | A fix UE4SS needs to run Deadzone | Copy into `Win64\ue4ss\` (step 2) |
| `tools` folder | The icon extractor | Run it once, from wherever you unzipped it (step 4) |
| `README.txt`, `LICENSE.txt` | These instructions and the licence | Nothing |

(The green **Code** button downloads the full source, which is for developers. Use the release zip to play.)

### Steps

`Win64` below means `Deadzone Rogue\Valhalla\Binaries\Win64`. To find it: in Steam, right-click Deadzone: Rogue → **Manage → Browse local files**, then open `Valhalla\Binaries\Win64`.

1. **Unzip Risk of Rogue** anywhere, for example your Desktop.

2. **Install UE4SS, the mod loader.**
   - Download the *experimental* release from [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) (the normal zip, not `zDEV`) and unzip it into `Win64`. You should now have `Win64\dwmapi.dll` and a `Win64\ue4ss` folder.
   - Copy `VTableLayout.ini` from Risk of Rogue's `ue4ss_overrides` folder into `Win64\ue4ss`.
   - Open `Win64\ue4ss\UE4SS-settings.ini` in Notepad, find `[EngineVersionOverride]`, set `MajorVersion = 5` and `MinorVersion = 6`, and save.

3. **Add the mod.** Copy the `RiskOfRogue` folder into `Win64\ue4ss\Mods`. Check that `Win64\ue4ss\Mods\RiskOfRogue\enabled.txt` exists.

4. **Get the icons.** Double-click `tools\Extract RoR2 Icons.bat`. The `tools` folder doesn't need to go anywhere special: run it straight from where you unzipped it. It finds both games through Steam and copies 95 icons from your own Risk of Rain 2 into `Mods\RiskOfRogue\icons`, in about 15 seconds. Do this after step 3, because it needs the mod folder to be in place.

5. **Play.** The pause menu shows *Risk of Rogue v.1.0.0* next to Deadzone's version, and the RoR2 timer appears in the top right once the run starts.

When you're done, `Win64` should look like this:

```
Win64
├─ dwmapi.dll
└─ ue4ss
   ├─ UE4SS-settings.ini      (MajorVersion = 5, MinorVersion = 6)
   ├─ VTableLayout.ini
   └─ Mods
      └─ RiskOfRogue
         ├─ enabled.txt
         ├─ icons            (95 .png files, made in step 4)
         └─ Scripts
```

After that, you can delete the folder you unzipped. Keep the `tools` folder if you might need to run the icon tool again, for example after a Risk of Rain 2 update.

## Help

| Problem | Fix |
|---|---|
| Game crashes on start | Re-check step 2: `VTableLayout.ini` and the two version numbers. |
| Mod doesn't load | The folder must be `Mods\RiskOfRogue` and contain `enabled.txt`. |
| Items have no icons | Run step 4 again (after step 3). |
| The icon tool can't find a game | Run it from a command prompt with `--ror2 "<path to Risk of Rain 2>"`. |

Still stuck? [Open an issue](../../issues) and attach `Win64\ue4ss\UE4SS.log`.

**Uninstall:** delete `Mods\RiskOfRogue`.
**Co-op:** should work, but hasn't been tested with two players yet.

## How this was made

Risk of Rogue was built by [Revolt](https://github.com/RevoltOfTheAtoms) together with **Claude**, Anthropic's AI. Most of the code and docs were written by AI, and every item was played and tested in-game. If something feels off, an issue report helps a lot.

## Credits

Risk of Rain 2 by Hopoo Games. Deadzone: Rogue by its developers. Made possible by [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) and [UnityPy](https://github.com/K0lb3/UnityPy).

*Unofficial fan mod, not affiliated with either game. No game files are included: the icons come from your own copy of Risk of Rain 2.* Code is [MIT licensed](LICENSE).
