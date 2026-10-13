# Deploying

The mod's source of truth is this repo:

- `sheets/*.json`: the design (items, elements, rarities, tuning, hooks)
- `python gen.py`: runs `preflight.py` (cross-checks every sheet) and writes `mod/RoR2Mashup/Scripts/data_gen.lua`
- `mod/RoR2Mashup/Scripts/main.lua`: the runtime
- `research/build_items.py`: rebuilds `sheets/items.json` from the RoR2 item list and the Deadzone mapping

To install, copy `mod/RoR2Mashup/Scripts/*.lua` (and `enabled.txt`) into
`Deadzone Rogue\Valhalla\Binaries\Win64\ue4ss\Mods\RoR2Mashup\`, then restart the game.
Icons aren't in the repo; `tools/extract_icons.py` makes them from your own RoR2 install.
