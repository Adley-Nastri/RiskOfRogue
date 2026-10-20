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

1. **Install UE4SS, the mod loader.**
   Download the *experimental* release from [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) (the normal zip, not `zDEV`) and unzip it into `Deadzone Rogue\Valhalla\Binaries\Win64`.
   Then copy [`VTableLayout.ini`](ue4ss_overrides/VTableLayout.ini) into the new `ue4ss` folder, and in `ue4ss\UE4SS-settings.ini` set `MajorVersion = 5` and `MinorVersion = 6`.

2. **Add the mod.**
   Download this page (**Code → Download ZIP**), unzip it, and copy `mod\RiskOfRogue` into `Win64\ue4ss\Mods\`.

3. **Get the icons.**
   Double-click `tools\Extract RoR2 Icons.bat`. It copies the item icons from your own Risk of Rain 2, which takes about 15 seconds.

4. **Play.** The RoR2 timer shows up in the top right after the first door.

> 💡 To find the game folder: in Steam, right-click Deadzone: Rogue → **Manage → Browse local files**.

## Help

| Problem | Fix |
|---|---|
| Game crashes on start | Re-check step 1: `VTableLayout.ini` and the two version numbers. |
| Mod doesn't load | The folder must be `Mods\RiskOfRogue` and contain `enabled.txt`. |
| Items have no icons | Run step 3 again. |

Still stuck? [Open an issue](../../issues) and attach `Win64\ue4ss\UE4SS.log`.

**Uninstall:** delete `Mods\RiskOfRogue`.
**Co-op:** should work, but hasn't been tested with two players yet.

## How this was made

Risk of Rogue was built by [Revolt](https://github.com/RevoltOfTheAtoms) together with **Claude**, Anthropic's AI. Most of the code and docs were written by AI, and every item was played and tested in-game. If something feels off, an issue report helps a lot.

## Credits

Risk of Rain 2 by Hopoo Games. Deadzone: Rogue by its developers. Made possible by [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) and [UnityPy](https://github.com/K0lb3/UnityPy).

*Unofficial fan mod, not affiliated with either game. No game files are included: the icons come from your own copy of Risk of Rain 2.* Code is [MIT licensed](LICENSE).
