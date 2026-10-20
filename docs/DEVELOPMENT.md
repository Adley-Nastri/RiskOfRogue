# Development

How Risk of Rogue is put together, and how to change it safely.

## Branches

| Branch | What it is |
|---|---|
| `main` | The release build. No developer tools. |
| `testing` | Day-to-day work. Has `mod/RiskOfRogue/devtools.txt` and `Scripts/selftest.lua`, which switch on the test menu, god mode and the self-test. |

Work on `testing`, then merge into `main` for a release. `main` deliberately doesn't have `devtools.txt` or `selftest.lua`, so a release can never ship the cheat menu.

## Layout

```
mod/RiskOfRogue/            what goes into ue4ss/Mods/
  Scripts/main.lua          loader: runs the parts below, in order, in one shared environment
  Scripts/parts/*.lua       the runtime (UE4SS Lua), one file per area (see "Code layout")
  Scripts/data_gen.lua      generated from sheets/ by gen.py: never edit by hand
  Scripts/selftest.lua      testing branch only: the in-game item self-test
  enabled.txt               UE4SS loads the mod when this exists
  devtools.txt              testing branch only: turns the developer tools on
  icons/                    made by tools/extract_ror2_assets.py, never committed
sheets/                     the design: items, elements, buffs, tuning, hooks, text
gen.py                      runs preflight.py, then writes data_gen.lua and docs/ITEMS.md
preflight.py                cross-checks every sheet before anything is generated
research/                   item builders and reference data read from both games
tools/                      the icon extractor for players
ue4ss_overrides/            VTableLayout.ini that UE4SS needs for Deadzone's engine build
docs/                       ITEMS.md (generated), this file, DEVLOG.md
```

## Code layout

`main.lua` only loads the parts. They run **in this order**, all in one shared environment:

| Part | What's in it |
|---|---|
| `core` | constants (`Data`, `SYS`, `MOD`), `log`, `valid`, `addr`, the timer scheduler (`after`, `run_timers`) |
| `game` | game helpers: class lookup, bots, attributes (`attr`), damage (`deal`), elemental statuses (`apply_status`) |
| `state` | run state (`Run`, `pstate`), the HUD's `View`, messages to clients (`notify`), `apply_items`, `give`, `take` |
| `clock` | difficulty tiers and the enemy buffs they apply |
| `orbs` | RoR2 cards in item-orb menus |
| `engine_base` | player context, shields and healing, timed stats, damage helpers |
| `engine_actions` | the action table (`ACTIONS`), item buffs, trigger conditions |
| `engine_procs` | `fire()`, special items, HUD buff states and proc messages (`Procs`) |
| `engine_tick` | per-tick work and the entry points the hooks call |
| `hooks` | game hooks: kills, damage, new characters, orbs, encounters, client messages |
| `fx` | Deadzone visual effects for procs |
| `native` | RoR2 items as native Deadzone items, inventory slots |
| `hud_widgets` | widget constructors and layout helpers |
| `devmenu` | F1 test menu (only with `devtools.txt`) |
| `hud` | building and drawing the mod HUD |
| `tick` | host tick, the test-command file, the main loop |
| `api` | self-test launcher and the debug API (`R2I`, `RiskOfRogue`) |

How the shared environment works:

- A name a part defines at its top level (`function foo()`, `Bar = {}`) is visible to every part loaded after it. Functions in earlier parts can also use it, because they only run after loading finishes.
- Inside functions, keep using `local` as normal. Top-level names are shared, so pick distinct ones. Preflight doesn't check this yet.
- Lua and UE4SS globals (`print`, `FindAllOf`, `RegisterHook`, …) are reached through the environment. The mod's own names never land in `_G`. Only the explicit `_G.R2I`, `_G.RiskOfRogue` and `_G.R2_*` hooks are global.
- A new part goes in `Scripts/parts/` and in the `PARTS` list in `main.lua`, at the point in the order where its top-level code should run.

The parts came from splitting the old single `main.lua`. Every line was kept, in its original order, and the only change was that top-level `local` became shared. The split was checked by reassembling the parts and comparing them with the original file. Both builds were also loaded in a mock UE4SS, where they registered identical hooks, keybinds and loop.

## The data pipeline

Everything a designer would tune lives in `sheets/*.json`. `main.lua` only reads the generated data.

1. Edit a sheet. For example, `sheets/items.json` holds the numbers, `sheets/item_text.json` the descriptions, and `sheets/systems.json` the global tuning.
2. Run `python gen.py`. It runs `preflight.py` first, which checks every cell. It confirms each item's trigger has a hook, each game effect it names exists in the game, each icon has an extraction rule, and each description's markup is balanced. Generation stops if anything is wrong.
3. Copy `mod/RiskOfRogue/Scripts/` (including `parts/`) into the game and restart Deadzone. The mod's Lua loads once at start. `selftest.lua` is reloaded every time a self-test starts.

`sheets/items.json` is itself built by `research/build_items.py`, from the Risk of Rain 2 item list and the per-item Deadzone mapping in that script. Descriptions come from `research/build_item_text.py`, which uses the same `<em>`, `<element_*>` and `<img id=.../>` rich-text tags as Deadzone's own perks.

## How items work in the game

- **Native items.** Each RoR2 item is a copy of a vanilla Deadzone item definition with its own name, description and rarity. That's why Deadzone's inventory, tooltips and rarity borders just work.
- **Stats** are Deadzone gameplay effects applied with a fixed magnitude. Elemental damage and statuses are Deadzone's own effects, with the mod dealing the damage itself.
- **Triggers** (hit, kill, crit, hurt, low health, shield break, encounter, orb pick, periodic) come from the game's damage events and a few hooks. They're listed in `sheets/hooks.json`.
- **The HUD** (clock, buff row, proc messages, pickup banner) is one UMG widget the mod builds. It's shown only while Deadzone's own HUD is visible.

The verified game-side techniques are listed in `sheets/apis.json`. The full story, including what crashed and why, is in [DEVLOG.md](DEVLOG.md).

## Developer tools (testing branch)

With `devtools.txt` in the mod folder:

| Key | Does |
|---|---|
| F1 | open / close the test menu |
| F2 | god mode on / off |
| Up / Down, PgUp / PgDn | pick an item |
| Right / Enter | give 1 of it |
| Left / Backspace | remove 1 of it |
| F7 / F8 | give all / remove all RoR2 items |
| F9 | jump the difficulty clock to the next tier |
| F10 | kill enemies within 30 m (your on-kill items fire) |
| Home | run the item self-test (press again to stop) |
| End | re-test only the items that failed last time |

The menu shows each item's HUD buff icons next to its name, so you know what to look for.

**Self-test:** stand near enemies and press Home. Each item is given on its own and its trigger is fired against real enemies. Then `selftest.txt` gets PASS with the evidence (stat change, damage dealt, status applied, shield, heal), FAIL, or MANUAL for items that need you, like sprinting or high ground. God mode turns itself on while it runs. Failed items are listed in `selftest_failed.txt` for End. Between waves it waits for enemies (ready up to continue). If a kill didn't land or the enemies ran out mid-item, it retries, and any FAIL is retried twice before it counts.

**Test-command file:** a Lua snippet saved as `Mods/RiskOfRogue/test_cmd.lua` runs inside the mod within half a second, and its result is appended to `test_out.txt`. `R2I` exposes the mod's internals. This only exists with `devtools.txt`, so the release build never runs files from disk.

## Rules that keep it stable

These are learned the hard way (see DEVLOG):

- **Never sweep all properties of a live object.** Reading arbitrary reflected properties crashes UE4SS. Read named properties and call named functions only.
- **No native hooks on hot paths.** Hooks on native functions such as `GetAssetById` crashed the Lua VM. Blueprint and UFunction hooks are fine.
- **No game calls from coroutines.** UE4SS can't call UObject methods inside a Lua coroutine. Use the mod's `after(ms, fn)` timer chain.
- **Map changes.** When the local player controller changes, the mod drops its HUD and pending timers and waits 1.5 s before touching game objects.
- **Enemy addresses get reused.** Deadzone reuses a dead enemy's memory for new spawns. Don't remember an enemy's address for long, and drop its entries when it dies.
- **One shared environment.** Top-level names in `Scripts/parts/` are shared between all parts (see "Code layout"), so give new ones distinct names and put related helpers in a table (`Procs`, `Native`, `Dev`).

## Releasing

1. On `testing`: run the full self-test (Home) and play a normal run across a couple of floors.
2. Merge `testing` into `main`. Keep `devtools.txt` and `selftest.lua` deleted on `main`.
3. Add a line to [CHANGELOG.md](../CHANGELOG.md), tag the commit (`v1.0.0`, …), and attach a zip of `mod/RiskOfRogue` plus `tools/` and `ue4ss_overrides/` to the GitHub release.
