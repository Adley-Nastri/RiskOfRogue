#!/usr/bin/env python3
"""Preflight: overlay every sheet, list unfilled cells and unresolved cross-sheet references."""
import json, os, sys
D=os.path.dirname(os.path.abspath(__file__)); S=os.path.join(D,'sheets')
L=lambda n: json.load(open(os.path.join(S,n)))
items,rar,tiers,sysv,hooks,apis,orbs,buffs,fx,inv = [L(n) for n in ['items.json','rarities.json','difficulty_tiers.json','systems.json','hooks.json','apis.json','orbs.json','buffs.json','fx.json','inventory.json']]
DUMP='/mnt/user-data/uploads/Deadzone Rogue/Valhalla/Binaries/Win64/ue4ss/Mods/DZBridge/'
classes=open(DUMP+'classes.txt').read(); funcs=open(DUMP+'q.txt').read()
ICONS='/mnt/user-data/outputs/dz/icons'
GE_CLASSES=set(open(os.path.join(D,'research','game_ge_classes.txt')).read().split())
DEVICE_ICONS=set(x[:-4] for x in open(os.path.join(D,'research','icons_on_device.txt')).read().split())
KINDS={ # legacy (hand-written handlers in main.lua) and generic (sheet-driven) kinds -> required columns
 'stat':['ge','attr','op','k','stack'], 'heal':['trigger','k'], 'refund':['trigger','k'], 'proc':['trigger','chance','radius','dmg'],
 'jump':['attr','k'], 'growth':['ge','attr','trigger','k','dmg'],
 'cstat':['cond','ge','attr','op','k'], 'buff':['trigger','ge','attr','op','k','dur','cap'], 'effect':['trigger','action'],
 'regen':['cond'], 'growth2':['trigger','ge','attr','op','k','cap'], 'special':[],
}
TRIGGERS={'kill','elitekill','hit','crit','hurt','lowhp','shieldbreak','multikill','orb','stage','encounter','periodic'}
ACTIONS={'bonus','single','aoe','aoe_self','aoe_random','chain','chain_self','multi','dot','delayed','status','execute',
         'heal','heal_all','barrier','currency','ammo','refund','buff','aura'}
CONDS={'','ooc','still','moving','shield','nearby','buffs','in_combat','tesla','v_elite','v_elite_low','v_near','v_hp_above','v_debuffed','v_cooldown',
       'above','hit_big','every','every_target','charged','charges','meteor'}
SUBS={'','buff_zone','turret','storm','heal_zone','transmit'}
SPECIALS={'DelayedDamage','HealingPotion','StrengthenBurn','TriggerEnemyDebuffs','BarrierOnOverHeal','Clover',
          'Duplicator','FallBoots','PermanentDebuffOnHit','SharedSuffering'}
LEGACY_IDS={'Syringe','Glasses','Hoof','Bear','ArmorPlate','Tooth','Medkit','Ukulele','Wisp','Gasoline','Feather','Infusion','Behemoth'}
errs=[]; checked=0
rids={r['id'] for r in rar['rows']}
elems=L('elements.json'); eids={r['id'] for r in elems['rows']}
ids=set()
def ge_ok(path): 
    nm=path.rsplit('/',1)[1]; return f"{path}.{nm}_C" in GE_CLASSES or f"{path}.{nm}_C" in classes
for r in items['rows']:
    i=r.get('id')
    for c in items['columns']:
        checked+=1
        if c not in r: errs.append(f"items.{i}.{c}: missing column")
    if i in ids: errs.append(f"items.{i}: duplicate id")
    ids.add(i)
    for c in ['id','name','rarity','icon','tex','pickup','kind','desc','src']:
        if r.get(c) in ('',None): errs.append(f"items.{i}.{c}: empty")
    if r['rarity'] not in rids: errs.append(f"items.{i}.rarity -> rarities: '{r['rarity']}' unresolved")
    k=r['kind']
    if k not in KINDS: errs.append(f"items.{i}.kind: unknown '{k}'"); continue
    for c in KINDS[k]:
        if r[c] in ('',None,0) and not (c=='k' and k in ('effect','special')): errs.append(f"items.{i}.{c}: required for kind {k} but empty")
    if k in ('proc','heal','refund','growth','jump') and i not in LEGACY_IDS|{'Infusion'}: errs.append(f"items.{i}.kind: '{k}' only has hand-written handlers for the original items")
    if k=='special' and i not in SPECIALS: errs.append(f"items.{i}: special kind but no handler in main.lua")
    if r['trigger'] and r['trigger'] not in TRIGGERS: errs.append(f"items.{i}.trigger: unknown {r['trigger']}")
    if r['action'] and r['action'] not in ACTIONS: errs.append(f"items.{i}.action: unknown {r['action']}")
    if r['cond'] not in CONDS: errs.append(f"items.{i}.cond: unknown {r['cond']}")
    if r.get('sub','') not in SUBS: errs.append(f"items.{i}.sub: unknown {r['sub']}")
    if r['action']=='aura' and not r.get('sub'): errs.append(f"items.{i}.sub: aura needs a sub type")
    for g in ('ge','ge2','pge'):
        if r.get(g) and not ge_ok(r[g]): errs.append(f"items.{i}.{g} -> game classes: {r[g]} not found")
    for g,a in (('ge','attr'),('ge2','attr2'),('pge','pattr')):
        if r.get(g) and not r.get(a): errs.append(f"items.{i}.{a}: empty for {g}")
    if r['element'] not in eids|{'none'}: errs.append(f"items.{i}.element -> elements: '{r['element']}' unresolved")
    if r['status'] not in eids|{'none'}: errs.append(f"items.{i}.status -> elements: '{r['status']}' unresolved")
    if r['action']=='status' and r['status']=='none': errs.append(f"items.{i}.status: status action needs a status")
    if r['dmg_base'] not in ('hit','base','vmax'): errs.append(f"items.{i}.dmg_base: unknown {r['dmg_base']}")
    if r['icon'] not in DEVICE_ICONS: errs.append(f"items.{i}.icon -> icons on the PC: {r['icon']}.png missing")
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
for r in elems['rows']:
    for c in elems['columns']:
        checked+=1
        if r.get(c) in ('',None): errs.append(f"elements.{r['id']}.{c}: empty")
    if r['status_ge']!='none' and not ge_ok(r['status_ge']): errs.append(f"elements.{r['id']}.status_ge -> game classes: not found")
    if not any(it.get('element')==r['id'] or it.get('status')==r['id'] for it in items['rows']): errs.append(f"elements.{r['id']}: no items use it")
print(f"preflight: {checked} cells over {len(items['rows'])} items, {len(rar['rows'])} rarities, {len(tiers['rows'])} tiers, {len(sysv['rows'])} systems, {len(hooks['rows'])} hooks, {len(apis['rows'])} apis")
if errs:
    print("\n".join("  FAIL "+e for e in errs)); sys.exit(1)
print("  clean")
