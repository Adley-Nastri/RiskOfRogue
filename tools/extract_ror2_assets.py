#!/usr/bin/env python3
"""Risk of Rogue: copy the item and buff icons the mod needs out of YOUR OWN Risk of Rain 2 install.

The mod ships no Risk of Rain 2 art. This script reads RoR2's asset bundles on your PC and writes
95 small PNGs (74 item icons + 21 buff icons) into the mod's icons folder.

Usage (Windows, from the repo folder):
    py -m pip install -r tools/requirements.txt
    py tools/extract_ror2_assets.py

Both games are found automatically through Steam. If that fails, point at them yourself:
    py tools/extract_ror2_assets.py --ror2 "D:/SteamLibrary/steamapps/common/Risk of Rain 2"
                                    --out  "D:/SteamLibrary/steamapps/common/Deadzone Rogue/Valhalla/Binaries/Win64/ue4ss/Mods/RiskOfRogue/icons"

Options:
    --ror2 PATH   Risk of Rain 2 folder (the one containing "Risk of Rain 2_Data")
    --out PATH    where to write the PNGs (default: the installed mod's icons folder)
    --force       overwrite icons that already exist
"""
import argparse, glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, 'ror2_assets.json')
ROR2_DIR = 'Risk of Rain 2'
DZ_DIR = 'Deadzone Rogue'
MOD_ICONS = os.path.join('Valhalla', 'Binaries', 'Win64', 'ue4ss', 'Mods', 'RiskOfRogue', 'icons')
BUNDLES = os.path.join('Risk of Rain 2_Data', 'StreamingAssets', 'aa', 'StandaloneWindows64')


def steam_libraries():
    """Every Steam library folder on this PC (Windows registry + libraryfolders.vdf)."""
    roots = []
    if sys.platform == 'win32':
        try:
            import winreg
            for hive, key in ((winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam'),
                              (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Valve\Steam')):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        for name in ('SteamPath', 'InstallPath'):
                            try: roots.append(winreg.QueryValueEx(k, name)[0])
                            except OSError: pass
                except OSError:
                    pass
        except ImportError:
            pass
        roots.append(r'C:\Program Files (x86)\Steam')
    roots += [os.path.expanduser('~/.steam/steam'), os.path.expanduser('~/.local/share/Steam')]
    libs = []
    for r in roots:
        vdf = os.path.join(r, 'steamapps', 'libraryfolders.vdf')
        if os.path.isfile(vdf):
            for m in re.finditer(r'"path"\s+"([^"]+)"', open(vdf, encoding='utf-8', errors='ignore').read()):
                libs.append(m.group(1).replace('\\\\', '\\'))
        libs.append(r)
    seen, out = set(), []
    for l in libs:
        n = os.path.normcase(os.path.abspath(l))
        if n not in seen and os.path.isdir(l):
            seen.add(n); out.append(l)
    return out


def find_game(folder):
    for lib in steam_libraries():
        p = os.path.join(lib, 'steamapps', 'common', folder)
        if os.path.isdir(p):
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description='Extract the icons Risk of Rogue needs from your own Risk of Rain 2 install.')
    ap.add_argument('--ror2', help='Risk of Rain 2 install folder')
    ap.add_argument('--out', help="output folder (default: the installed mod's icons folder)")
    ap.add_argument('--force', action='store_true', help='overwrite existing icons')
    a = ap.parse_args()

    try:
        import UnityPy
    except ImportError:
        sys.exit('UnityPy is missing. Install it with:  py -m pip install -r tools/requirements.txt')

    ror2 = a.ror2 or find_game(ROR2_DIR)
    if not ror2 or not os.path.isdir(os.path.join(ror2, BUNDLES)):
        sys.exit('Could not find Risk of Rain 2. Pass its folder with --ror2 "<path to Risk of Rain 2>".')
    out = a.out
    if not out:
        dz = find_game(DZ_DIR)
        if not dz:
            sys.exit('Could not find Deadzone: Rogue. Pass the output folder with --out "<...\\Mods\\RiskOfRogue\\icons>".')
        out = os.path.join(dz, MOD_ICONS)
        if not os.path.isdir(os.path.dirname(out)):
            sys.exit(f'The mod is not installed yet ({os.path.dirname(out)} is missing). Install it first, see README.')
    os.makedirs(out, exist_ok=True)
    aa = os.path.join(ror2, BUNDLES)
    print(f'Risk of Rain 2: {ror2}\nwriting icons to: {out}\n')

    spec = json.load(open(ASSETS, encoding='utf-8'))
    jobs = spec['items'] + spec['buffs']
    todo = [j for j in jobs if a.force or not os.path.exists(os.path.join(out, j['png'] + '.png'))]
    if not todo:
        print(f'All {len(jobs)} icons are already there (use --force to redo them).')
        return

    # load each bundle set once; several icons share a bundle
    by_files = {}
    for j in todo:
        files = sorted({f for pat in j['bundles'] for f in glob.glob(os.path.join(aa, pat))})
        by_files.setdefault(tuple(files), []).append(j)
    done, missing = 0, []
    for files, group in by_files.items():
        if not files:
            missing += [j['png'] for j in group]
            continue
        want = {j['texture']: j for j in group}
        try:
            env = UnityPy.load(*files)
        except Exception as e:
            print(f'  could not read {os.path.basename(files[0])}: {e}')
            missing += [j['png'] for j in group]
            continue
        for o in env.objects:
            if o.type.name != 'Texture2D' or not want:
                continue
            try:
                name = o.peek_name()
            except Exception:
                name = None
            if name is not None and name not in want:
                continue
            tex = o.read()
            j = want.pop(tex.m_Name, None)
            if j:
                tex.image.save(os.path.join(out, j['png'] + '.png'))
                done += 1
        missing += [j['png'] for j in want.values()]
        print(f'  {done}/{len(todo)}', end='\r', flush=True)

    print(f'\nExtracted {done} of {len(todo)} icons.')
    if missing:
        print('Missing (your Risk of Rain 2 version may differ, or a DLC is not installed):')
        for m in sorted(missing):
            print('  ' + m)
        sys.exit(1)
    print('Done. Start Deadzone: Rogue and the RoR2 items will have their icons.')


if __name__ == '__main__':
    main()
