> Engineering log kept while building the mod (it was called *RoR2 Mashup* until the public release, so older entries use that name and its folder `RoR2Mashup`).

# MODLOG: RoR2 Mashup for Deadzone: Rogue

## Versions
- Deadzone: Rogue, Steam, build `++Valhalla+Rogue-Release-1.4`. It's Unreal Engine 5.6 with the project name "Valhalla". The exe `Valhalla\Binaries\Win64\DeadzoneSteam-Win64-Shipping.exe` is SteamStub-wrapped (has a `.bind` section), but its `.text` isn't encrypted. There's no EAC or BattlEye.
- Risk of Rain 2, Unity 2021.3, Addressables bundles in `Risk of Rain 2_Data\StreamingAssets\aa\StandaloneWindows64\ror2-base-<item>_assets_all_*.bundle`.
- UE4SS experimental `v3.0.1-1165-g12ec45a0`.

## Route
UE4SS Lua (loader API). The game uses GAS (ValAttributeSet, ValAbilitySystemComponent), so stats go through the game's own GameplayEffects.

## UE4SS on Deadzone (two fixes needed)
1. **FMalloc vtable.** UE4SS crashed with an out-of-memory error ("allocating 0x7FF7…"). The Binned2 FMalloc vtable at RVA 0x88c3f58 has dtor, 2 unknown entries, Exec_Runtime/Dev/Editor, then Malloc at slot 6. UE4SS assumes Malloc at 0x10. Fix: `ue4ss\VTableLayout.ini` = the 5.6 template with `[FMalloc]` = `__vecDelDtor, Exec_Runtime_Dup, Exec_Runtime, Exec_Dev, Exec_Editor, Malloc, …`. UE4SS's FMalloc offsets are (index+1)*8.
2. Set `MajorVersion = 5`, `MinorVersion = 6` in UE4SS-settings.ini. That plus fix 1 = clean start.

## Game facts (verified live)
- Stat GEs: `/Game/Abilities/DeviceUpgrades/Attributes/GE_GenericAttribute_*`, one modifier with SetByCaller `Data.UpgradeMagnitude`. The spec handles can't round-trip through UE4SS Lua (TSharedPtr), so: temporarily switch the CDO modifier to ScalableFloat, call BP_ApplyGameplayEffectToSelf, restore. EvaluatedMagnitude replicates to clients.
- `GE_Suicide` applied from an attacker's ASC kills with credit (OnBotKilled killer = player). `ValCharacter:SetHealth` lowers HP but never kills (a 0-HP zombie is left behind).
- **OnDamaged DamageData.Amount is negative** for real hits (−910 sniper crit). The execute effect gives about −1e6.
- `bDoesNotDie` doesn't stop lethal hits. Reviving after death still ends a solo run (team eliminated fires first). That's why Dio's was dropped.
- Encounter rooms: GameMode `NotifyEncounterDoorsClosed` (fires more than once per room) and GameState `IncrementEncountersCleared`.
- Hub = GameMode class containing "StartingShip".
- `ValBotSpawnerBlueprintLibrary:SpawnAtNearestBotSpawner`, `ValBotSpawnVolume:TriggerEventSpawnBots` and `SpawnFirstWave` didn't spawn extra bots, and ValCheatComponent is compiled out.
- HUD: a UserWidget built with StaticConstructObject plus ImportFileAsTexture2D works. **Imported textures get garbage-collected unless a widget references them**: an access-violation crash in Slate paint. Fix: hidden keeper images.
- Don't hot-reload (Ctrl+R) with a HUD up. Old widgets stay on screen, and removing them crashed the game. Restart instead.

## Native item integration (verified live)
- Item definitions: `ValAbilityAsset` (ValItemAsset → ValDataAsset): DisplayName, Description (rich text, `<em>`), Rarity (ERarity: 1 Common, 2 Uncommon, 3 Rare, 4 Epic, 5 Legendary), MaxStackSize, TextureMap (FName → soft Texture2D).
- One rooted copy per RoR2 item: `StaticConstructObject(class, /Engine/Transient, "RoR2_<id>", 0xC0, 0, false, false, Item_ArmorValue)`.
- Tab and end-of-run grids: `UI_Equipment_Perk_C:UpdateAsset(def, PlayerState)` on the slot after the vanilla items, then a full-colour icon on BGMat and "xN" on StackText. Deadzone's own tooltip (WBP_Tooltip_Item) then shows the RoR2 text. Verified by the user.
- The in-run item row under the minimap is `WBP_ActiveItemsDisplay_C` in the visor (C++ `ValRHUIActiveItemDisplay`, painted natively, no child widgets). The BP feeds it through `OnItemIdsChanged(PerkIds)` → `ValBlueprintLibrary:GetAssetById` → `FindTexture` → `AddItem`/`UpdateBrushForItem`. Its material is `MI_UI_ItemEntry` (texture param `Icon`, scalar `Rarity` = ERarity−1).
- Open: GetAssetById is hooked (return override; hook registered OK) and `OnItemIdsChanged` is called with RoR2 ids without error, but the row doesn't show them. Next, check whether UE4SS's post-hook return actually overrides a native static function's return value.
- Bottom-centre `Perks_Active` only shows items with an active effect. The old bug picked the last `UI_Equipment_Perks_Minimal_C` in the visor, which was a subclass `UI_WeaponModList_C` on the weapon panel.
- Exe base and crash RIP can be read from `UEMinidump.dmp` (ModuleList and Exception streams); capstone on the device disassembles the exe.

## Elemental damage (verified live)
- Elements live in `/Game/Abilities/Elements/`: `GE_<Element>_Damage` (instant, `ValDamageExecutionCalc`) and statuses such as `GE_Fire_Ignite` (5 s, 0.5 s period, cue `GameplayCue.VFX.StatusOnFire`), `GE_Lightning_Shock` (SetByCaller duration and CritChanceResistanceModifier, cue `GameplayCue.Element.Lighting.Shock`), `GE_Cryo_Chill`, `GE_Radiation_Irradiate`. The other elements are Void, Plasma, Psionic, Nano, Chroma and Sonic.
- `ValDamageExecutionCalc` takes its damage from SetByCaller `Data.Damage`, which a mod can't set (spec handles). Applying `GE_Fire_Ignite` from the player's ASC with `BP_ApplyGameplayEffectToTarget` shows the burning effect on the enemy (seen by the user) but does 0 damage. So the mod deals the damage itself and adds the status.
- Player element attributes are additive from 0: `FireDamageModifier`, `AllElementDamageModifier` (0.3 with an upgrade), `ProcDamageMultiplier` (1), `ElementDebuffDurationMultiplier` and `ElementDebuffPotencyMultiplier` (1), `LightningShockDurationModifier`, `LightningShockCritChanceModifier`. There is no Lightning damage attribute.
- The mod: Ukulele = Lightning (Shock); Gasoline, Will-o'-the-wisp and Brilliant Behemoth = Fire (Ignite). Damage × (1 + element mod + all-element mod) × proc multiplier. Statuses are rate-limited per enemy (`sheets/elements.json`).

## Self-test findings (2026-10-13)
- OnBotKilled stopped firing: 0 calls for gun kills and mod kills (checked live). Kills are now detected in OnDamaged (bKillingBlow or health <= 0), and deal() also reports its own lethal hits. On-kill items work again.
- UE4SS can't call UObject methods from inside a Lua coroutine ("lua state has no instance"), so the self-test chains steps with the mod's timer.
- God mode re-applies GE_Invulnerability_Temporary every 1.5 s (incoming damage x0) on top of the health refill.
- The self-test (Scripts/selftest.lua) is reloaded each run and reaches the mod's internals through _G.R2I, so it can change without a game restart.

## Cooldown attributes (checked in game by the user)
- UniversalCooldownModifier and DashCooldownModifier are recharge RATES: higher = faster. Alien Head, Brainstalks, Soulbound Catalyst and Hardlight Afterburner raise them.
- GrenadeCooldownModifier is a cooldown MULTIPLIER: lower = faster. Fuel Cell lowers it (confirmed working).

## Mistakes during testing
- Native hooks on `GetAssetById`/`UpdateBrushForItem`, plus calling the HUD display's `OnItemIdsChanged` on every refresh (the RoR2 ids never stuck, so it re-fired constantly), crashed inside UE4SS's Lua VM (UE4SS.dll+0xc72210) about 15 s after getting 4 items. Most likely the native hook callbacks ran Lua off the game thread. Both are removed; the HUD row stays parked.
- Reading `TextureMap` (a map of soft object pointers) with `ForEach`/`:get()` crashed the game.
- Calling `ValRHUIActiveItemDisplay:AddItem` with a Lua table for `FActiveItemDisplay` crashed the game: fields not given (inside FSlateBrush) are left uninitialised, so a garbage UObject pointer was read.
- Teleporting the player with K2_SetActorLocation put them outside the level, and they died ("Suicide"). Don't teleport. Aim with SetControlRotation and fire instead.

## Item set
- 74 items after review with the user: removed RoR2 mechanics Deadzone lacks (gold, chests, shrines, drones, allies, equipment, XP) and thrown/fired objects (missiles, fireworks, boomerang, bombs, shurikens, daggers, hooks, razors, disc, skull, meteor). Full list in README and sheets/items.json "skipped".

## RoR2 buff row and proc messages (testing branch)
- Buff row above the health bar now covers the sheet-driven items: 24 entries in sheets/buffs.json, icons extracted from the player's own RoR2 install (never shipped in the repo).
- Drawn the way RoR2's `BuffIcon.UpdateIcon` does it (read from the player's RoR2.dll): sprite tinted with the BuffDef `buffColor`; stacking buffs show "x" + count, or count + "%" when `stackingDisplayMethod` is 1; no fade. Colours, canStack, displayOffset and stackingDisplayMethod come from the BuffDefs in the bundles.
- Extra RoR2 states: elemental rings ready / cooldown countdown, Warped Echo ready / pending (red), Unstable Transmitter ready / active / used.
- State buffs are refreshed by the engine every 500 ms (`Procs.row`) through `notify(name, "B", "id|ms|count")`; the original four still use `"b"` and are unchanged apart from the RoR2 tint and stack count.
- Row tilted 2 degrees (`buff_row_tilt_deg`) to run parallel to Deadzone's health bar.
- Proc messages: 13 items in sheets/procs.json, at most one per item every 2 s; frequent on-hit procs stay silent.

## End-of-run Items row
The results screen's "Items:" row is a UI_Equipment_Perks_Minimal_C that only creates one UI_Equipment_Perk slot per vanilla item, so the 18-slot grid patch never reached it. The mod now creates UI_Equipment_Perk slots (WidgetBlueprintLibrary.Create, AddChildToHorizontalBox on ItemGridHorizontal), copies the row's ScaleOverride (0.4) via UpdateScaleOverride, and fills them like the Tab grid. Verified in game.

## Enemy address reuse
Deadzone reuses a dead enemy's memory for new spawns, and everything the mod keeps per enemy is keyed by address. The kill dedupe (Run.killed) remembered addresses for the whole run, so on-kill items silently stopped firing for new enemies at reused addresses (checked live: 3 of 8 live enemies were already marked killed). The clock buff dedupe (Run.buffed) had the same flaw. Both are now time windows (kill_dedupe_ms 1000, spawn_dedupe_ms 2000), and on a kill forget_bot() drops the enemy's clock-buff mark, cached attribute set, Networked Suffering infection and status timers. Found through self-test kill items failing late in a run.

## Clock synced to Deadzone's run timer
Deadzone's run timer is UI_Game_TimeRemaining_C (top left, under the wave info); it keeps the whole seconds it shows in CachedCurrentTime. The RoR2 clock is now those seconds plus the time since they last changed (capped below 1 s), so both read the same mm:ss. Its bTimerInitialized flag stays false while it runs and must not be checked (the first version did, and fell back to the mod's own count, about 4 s ahead). Without the widget the mod's own count is used.

## Version in the menus
WBP_VersionNumber_C.VersionDisplay (main and pause menus) reads "v.1.4.2.0"; the mod appends "   Risk of Rogue v.<mod_version> (testing|main)" in the same text block. The branch comes from devtools.txt.

## Music research (RoR2 music option, 1.1 idea)
- Deadzone's audio is Wwise (AkAudio). Its music is driven by cues the mod can hook (AkGameplayStatics:SetState/SetSwitch, verified with a read-only watcher over two waves):
  - `MusicZone-MUS_Z{1-3}_{F1,F2,F3,MINIBOSS,BOSS}` (switch, set on mission load): which track.
  - `CombatState-Combat` / `CombatState-Safe` (state): Combat fires when a wave starts and stays on for the whole wave, lulls included; Safe fires when the wave is cleared.
  - `MusicStatus-On`, `MatchState-Active`, `LoadingState-*` on load. No separate music "play" event is posted from Blueprint.
- Deadzone's music volume is the Wwise RTPC `/Game/WwiseAudio/Game_Parameters/AudioGameParameters/MusicVolume` (AkGameplayStatics:SetRTPCValue).
- Unreal's MediaPlayer/FileMediaSource/MediaSoundComponent exist, but the game ships no audio decoder plugin (no WmfMedia/Electra; only Bink and ImgMedia): OpenSource/OpenFile fail for .wav, .ogg and .m4a. Playing RoR2 music needs a native .ogg player.
- RoR2's music is Ogg Vorbis inside its Wwise banks, so it can be extracted from the player's own install without re-encoding (like the icons).

## RoR2 music (testing)
Built as `parts/music.lua` plus `native/ror_audio` (see docs/MUSIC.md, which also explains why Wwise itself can't be used). Calm: one RoR2 stage song per run, never the previous run's; fight: a different teleporter track every wave. Timings measured from a music-only loopback recording of vanilla (observe mode). Fixed on the way: the music poll died on map changes (the mod clears its timers) and froze in pauses, so the music has its own clock; reading the settings TMap every tick crashed UE4SS while the game saved settings, so the sliders come from the .ini; RoR2's teleporter layer (`_BC`) is 15-25 dB under the stage mix and inaudible as a fight change, so waves use the boss tracks instead. Stage/boss pairs read from RoR2's SceneDefs.

## Status
Verified: RoR2 cards in item orbs, native Tab and end-of-run slots with Deadzone's tooltip, stacking counts, stat items, kill and hit procs, clock. The teleporter event, kill drops and Dio's Best Friend were removed at the user's request. Open: the HUD item row under the minimap, and co-op with two players.

Older notes:
Working solo: items, stat effects, kill procs, difficulty clock and bot buffs, teleporter charge, boss and reward, HUD.
Fix pending a restart: on-hit items (negative Amount).
Co-op sync written, but not tested with two players.
