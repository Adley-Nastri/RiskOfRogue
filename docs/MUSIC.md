# RoR2 music (optional, testing branch)

Risk of Rogue can replace Deadzone's in-run music with Risk of Rain 2's soundtrack, timed to
Deadzone's own music cues. The code is `Scripts/parts/music.lua`; the player is `native/ror_audio/`.

Status: in testing. Works in game; the songs still have to be extracted by hand (a player-facing
extractor like the icon tool is still to do), and the audio player DLL isn't shipped yet.

## What the player hears

| Moment | What plays |
|---|---|
| Ship, main menu, anything outside a run | nothing (Deadzone's music is held off while the option is on) |
| Run start | one calm RoR2 stage song for the whole run, never the same as the previous run's (remembered in `music_last.txt`, so also across restarts) |
| A wave or room starts | a RoR2 teleporter/boss track, a different one every wave, from its beginning |
| Wave cleared | back to the calm song, which kept playing silently, so it carries on where it was |
| Death | the fight track drops; the calm song comes back ~3 dB quieter, as in vanilla |
| Leaving a map | cut over 0.2 s when travel starts, as in vanilla |

Volume follows the game's **Music** and **Master** sliders (read from `GameUserSettings.ini` once a
second). Music at 0 is silent.

Turn it off with `music = deadzone` in `Mods/RiskOfRogue/music.txt` (restart the game). If the songs
or the player are missing, the mod falls back to Deadzone's music on its own.

## Timings

Measured from a music-only loopback recording of vanilla Deadzone (4 waves, `music = observe`), at
0.1 s resolution:

| Event | Vanilla | Here |
|---|---|---|
| Mission start | fade in ~3.5 s | 3.5 s fade in |
| Wave start (`CombatState-Combat`) | ~1 s transition at the cue, calm music drops, fight music lands 3.2-4.8 s after the cue (on a bar), ~+6 dB | calm song holds 2.2 s then fades over 1 s; fight track in at 3.0 s over 0.6 s (no long silent gap); +6 dB |
| Wave cleared (`CombatState-Safe`) | fight drops 0.6-0.8 s after the cue over ~0.5 s, calm within ~1 s | 0.6 s, 0.5 s out, 1 s in |
| Death (`DeadOrAlive-PlayerDead`) | drops ~0.5 s after the cue, then ~3 dB under calm | 0.5 s, 0.6 s, calm at 70 % |
| Leaving (`MatchState` LeavingMap) | cut over 0.2 s at travel start | 0.2 s |

All values are in `Music.cfg`.

## Songs

`music/` holds Ogg Vorbis files decoded from the player's own RoR2 install
(`Risk of Rain 2_Data/StreamingAssets/Audio/GeneratedSoundBanks/Windows/Media/<id>.wem`, decoded with
vgmstream, encoded with ffmpeg at `-q:a 6`):

- `<song>_explore.ogg`: a stage song's full in-game mix (Wwise `..._LVL`, `IN-GAME`, `Map`, `FULL`).
- `wave_<song>.ogg`: a teleporter/boss track, levelled to about 4 dB above the stage songs.

Which stage song goes with which teleporter track comes from RoR2's own stage definitions (each
`SceneDef`'s `mainTrack`/`bossTrack`, matched to the Wwise folders through the track definitions'
state IDs). The table is `Music.stages`. Tracks without a usable pair are left out: Commencement
(boss music in phases), Prime Meridian (a one-minute stage track), Void Fields (no teleporter).
Mire, Fungal and Sanctum share a boss track whose Wwise ID didn't match a folder name; they use the
DLC4 "Mush" boss track as the closest fit.

## Why it can't go through Deadzone's own audio engine

Deadzone plays music through Wwise, inside the game. Getting RoR2's songs into that system would be
the clean way, and every route is closed:

- **Archive override:** the game checks its `.pak` signatures. A test pak was refused with
  `Failed PAK principal signature table check`, and the game's archives are encrypted.
- **New sound banks:** UE4SS can't load extra Wwise banks into the running game (only the init bank is
  exposed). A bank would also have to be built with Deadzone's exact Wwise version, which means an
  Audiokinetic account and a multi-GB Wwise install for every player.
- **Wwise external sources:** Deadzone's music doesn't use them, so there's no slot to feed a file into.
- **Unreal's media player:** the game ships without media decoder plugins (only Bink and ImgMedia),
  so it can't open `.wav`, `.ogg` or `.m4a` files.
- **Lua:** UE4SS Lua has no audio output of its own.

So the mod mutes Deadzone's music with its own `MusicVolume` game parameter and plays RoR2's songs
through `ror_audio.dll`, on the same output device as the game. The timing comes from Deadzone's
music states (the only hook); the exact moment Wwise moves to the next bar happens inside Wwise and
never reaches game code, which is why the timings above were measured from recordings.

## Things learned the hard way

- Hooking `SetSwitch` (static or on `AkComponent`) crashed UE4SS about 10 s after the ship loaded.
  Only `AkGameplayStatics:SetState` is hooked.
- Reading `ValGameUserSettings.SavedSettingsConfig` (a TMap) every tick crashed when the game saved
  its settings at the same moment. The sliders come from the `.ini` on disk instead.
- The mod's own timers are cleared on map changes and stop while paused, so the music has its own
  clock (`Music.later`) and runs from the main loop before the map-settle wait.
- Deadzone re-applies the music slider on loads and settings changes; the mute is re-set every tick.

## Developer tools (testing branch)

- `music_log.txt`: every cue and every player command, with times.
- `music = observe`: Deadzone's own music; in each mission it records the game's output to
  `observe_<n>.wav` with sound effects, voice and ambience turned down, and marks every cue in
  `observe_<n>.wav.marks.txt`. This is how the timings were measured.
