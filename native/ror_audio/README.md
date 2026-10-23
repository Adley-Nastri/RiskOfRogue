# ror_audio (music player for the RoR2 music option)

A small native helper the mod loads with Lua's `package.loadlib`, because neither UE4SS Lua nor
Deadzone (no media decoder plugins, signed archives) can play audio files. It plays `.ogg` files
on the same output device as the game, found from the game's own Windows audio session.

- `ror_audio.c`: the player (our code). Command protocol is documented at the top of the file.
- `miniaudio.h` (miniaudio 0.11.21, public domain / MIT-0) and `stb_vorbis.c` (public domain / MIT):
  unmodified third-party libraries.
- `build.sh`: builds `ror_audio.dll`. The DLL itself is not committed.

Status: prototype. Verified in game: plays `.ogg`, follows the game's output device, two tracks
started sample-locked (RoR2 stage song + its teleporter layer) with independent fades.
