#!/usr/bin/env python3
"""Preflight: overlay every sheet, list unfilled cells and unresolved cross-sheet references."""
import json, os, sys
D=os.path.dirname(os.path.abspath(__file__)); S=os.path.join(D,'sheets')
L=lambda n: json.load(open(os.path.join(S,n)))
items,rar,tiers,sysv,hooks,apis,orbs,buffs,fx,inv = [L(n) for n in ['items.json','rarities.json','difficulty_tiers.json','systems.json','hooks.json','apis.json','orbs.json','buffs.json','fx.json','inventory.json']]
DUMP='/mnt/user-data/uploads/Deadzone Rogue/Valhalla/Binaries/Win64/ue4ss/Mods/DZBridge/'
classes=open(DUMP+'classes.txt').read(); funcs=open(DUMP+'q.txt').read()
ICONS='/mnt/user-data/outputs/dz/icons'
REQ={ # which columns must be meaningful per kind
 'stat':['ge','attr','op','k','stack'],
 'heal':['trigger','k'],
 'refund':['trigger','k'],
 'proc':['trigger','chance','radius','dmg'],
 'jump':['attr','k'],
 'growth':['ge','attr','trigger','k','dmg'],
 'revive':['trigger'],
}
errs=[]; checked=0
rids={r['id'] for r in rar['rows']}
ids=set()
for r in items['rows']:
    for c in items['columns']:
        checked+=1
        if c not in r: errs.append(f"items.{r.get('id')}.{c}: missing column")
    i=r['id']
    if i in ids: errs.append(f"items.{i}: duplicate id")
    ids.add(i)
    for c in ['id','name','rarity','icon','pickup','kind','desc']:
        if r[c] in ('',None): errs.append(f"items.{i}.{c}: empty")
    if r['rarity'] not in rids: errs.append(f"items.{i}.rarity -> rarities: '{r['rarity']}' unresolved")
    if r['kind'] not in REQ: errs.append(f"items.{i}.kind: unknown '{r['kind']}'")
    for c in REQ.get(r['kind'],[]):
        if r[c] in ('',None,0) and not (c=='k' and r['kind']=='revive'): errs.append(f"items.{i}.{c}: required for kind {r['kind']} but empty")
    if r['ge']:
        nm=r['ge'].rsplit('/',1)[1]
        if f"{r['ge']}.{nm}_C" not in classes: errs.append(f"items.{i}.ge -> game classes: {r['ge']} not found")
    if not os.path.exists(os.path.join(ICONS,r['icon']+'.png')): errs.append(f"items.{i}.icon -> icons: {r['icon']}.png missing")
    if r['trigger'] and r['trigger'] not in ('kill','hit','hurt','death'): errs.append(f"items.{i}.trigger: unknown {r['trigger']}")
    if r['trigger']:
        need={'kill':'bot_killed','hit':'damaged','hurt':'damaged','death':'damaged'}[r['trigger']]
        if need not in {h['id'] for h in hooks['rows']}: errs.append(f"items.{i}.trigger -> hooks: {need} missing")
for r in rar['rows']:
    for c in rar['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"rarities.{r['id']}.{c}: empty")
    if not any(it['rarity']==r['id'] for it in items['rows']): errs.append(f"rarities.{r['id']}: no items of this rarity")
prev=-1
for r in tiers['rows']:
    for c in tiers['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"tiers.{r.get('name')}.{c}: empty")
    if r['start_min']<=prev: errs.append(f"tiers.{r['name']}: start_min not increasing")
    prev=r['start_min']
for r in sysv['rows']:
    checked+=len(sysv['columns'])
    if r['value'] in ('',None): errs.append(f"systems.{r['id']}.value: empty")
for r in hooks['rows']:
    checked+=len(hooks['columns'])
    if r['kind']=='RegisterHook':
        cls,fn=r['target'].split(':'); short=cls.replace('/Script/','')
        if f"{short}:{fn} " not in funcs and f"{short}:{fn}\n" not in funcs and not short.startswith('Engine.'):
            # q.txt only lists functions it was asked about; fall back to live verification note
            if 'live' not in r['verified']: errs.append(f"hooks.{r['id']}.target: {r['target']} not in dump and not verified live")
    if not r['verified'] or r['verified']=='pending': errs.append(f"hooks.{r['id']}.verified: unverified")
for r in apis['rows']:
    checked+=len(apis['columns'])
    if not r["verified"] or "pending" in r["verified"]: errs.append(f"apis.{r['id']}.verified: unverified")
for r in orbs['rows']:
    for c in orbs['columns']:
        checked+=1
        if c!='hide_widgets' and r.get(c) in ('',None): errs.append(f"orbs.{r['id']}.{c}: empty")
for need in ['request_pick','server_pick','new_bundle']:
    if need not in {h['id'] for h in hooks['rows']}: errs.append(f"orbs -> hooks: {need} missing")
for need in ['orb_ror2_chance','orb_block_index','orb_client_index_offset']:
    if need not in {r['id'] for r in sysv['rows']}: errs.append(f"orbs -> systems: {need} missing")
for r in rar['rows']:
    if 'orb_weight' not in r: errs.append(f"rarities.{r['id']}.orb_weight: missing")
for r in buffs['rows']:
    for c in buffs['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"buffs.{r['id']}.{c}: empty")
    if r['item'] not in ids: errs.append(f"buffs.{r['id']}.item -> items: {r['item']} unresolved")
    if not os.path.exists(os.path.join('/mnt/user-data/outputs/dz/buffs', r['icon']+'.png')): errs.append(f"buffs.{r['id']}.icon -> icons: {r['icon']}.png missing")
for r in fx['rows']:
    for c in fx['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"fx.{r['id']}.{c}: empty")
    if r['item'] not in ids: errs.append(f"fx.{r['id']}.item -> items: {r['item']} unresolved")
    if r['at'] not in ('target','victim','player'): errs.append(f"fx.{r['id']}.at: unknown {r['at']}")
for r in inv['rows']:
    checked+=3
    if not r['value']: errs.append(f"inventory.{r['id']}: empty")
elems=L('elements.json'); eids={r['id'] for r in elems['rows']}
for r in items['rows']:
    if r.get('element') not in eids|{'none'}: errs.append(f"items.{r['id']}.element -> elements: '{r.get('element')}' unresolved")
    if r.get('element')!='none' and r['kind']!='proc': errs.append(f"items.{r['id']}.element: only proc items deal element damage")
for r in elems['rows']:
    for c in elems['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"elements.{r['id']}.{c}: empty")
    nm=r['status_ge'].rsplit('/',1)[1]
    if f"{r['status_ge']}.{nm}_C" not in classes: errs.append(f"elements.{r['id']}.status_ge -> game classes: not found")
    if not any(it.get('element')==r['id'] for it in items['rows']): errs.append(f"elements.{r['id']}: no items use it")
print(f"preflight: {checked} cells over {len(items['rows'])} items, {len(rar['rows'])} rarities, {len(tiers['rows'])} tiers, {len(sysv['rows'])} systems, {len(hooks['rows'])} hooks, {len(apis['rows'])} apis")
if errs:
    print("\n".join("  FAIL "+e for e in errs)); sys.exit(1)
print("  clean")
