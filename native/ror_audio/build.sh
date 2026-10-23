#!/bin/sh
# Builds ror_audio.dll (64-bit Windows) from ror_audio.c.
# Uses Zig's C compiler as a cross-compiler (pip install ziglang); any MinGW-w64 or MSVC compiler works too:
#   MSVC:   cl /O2 /LD ror_audio.c ole32.lib
set -e
cd "$(dirname "$0")"
python3 -m ziglang cc -target x86_64-windows-gnu -shared -O2 -s -o ror_audio.dll ror_audio.c -lole32
echo "built ror_audio.dll"
