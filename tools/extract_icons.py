#!/usr/bin/env python3
"""Extract the RoR2 item icons this mod uses from the player's own Risk of Rain 2 install.

usage: extract_icons.py "<Risk of Rain 2 folder>" "<...\\ue4ss\\Mods\\RoR2Mashup\\icons>"
Needs UnityPy (pip install UnityPy). Nothing from RoR2 is shipped with the mod.
"""
import sys, os, glob, json
import UnityPy
src, out = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
items = json.load(open(os.path.join(here, '..', 'sheets', 'items.json')))['rows']
want = {f"tex{it['icon']}Icon": it['icon'] for it in items}
want['texTeleporterIcon'] = 'Teleporter'
aa = os.path.join(src, 'Risk of Rain 2_Data', 'StreamingAssets', 'aa', 'StandaloneWindows64')
os.makedirs(out, exist_ok=True)
found = set()
for f in sorted(glob.glob(os.path.join(aa, 'ror2-base-*_assets_all_*.bundle'))):
    env = UnityPy.load(f)
    for o in env.objects:
        if o.type.name != 'Texture2D': continue
        d = o.read()
        if d.m_Name in want and d.m_Name not in found:
            d.image.save(os.path.join(out, want[d.m_Name] + '.png')); found.add(d.m_Name)
missing = set(want) - found
print(f"extracted {len(found)} icons" + (f"; missing {sorted(missing)}" if missing else ""))
