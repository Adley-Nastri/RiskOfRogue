#!/usr/bin/env python3
"""Builds sheets/item_text.json: each RoR2 item's description in Deadzone's own rich-text markup
(the <em>, <element_*>, <img id=.../> tags vanilla perks use, collected from the game's assets).
Shorthand: *x* -> <em>x</>, {KEY} -> icon + coloured keyword."""
import json, os, re
D = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
K = {  # keyword -> (img id or None, tag, text)
 'CRITCH': ('Crit.CritChance', 'em', 'Crit Chance'), 'CRITDMG': ('Crit.CritDamage', 'em', 'Crit Damage'),
 'CRITHIT': ('Crit.CriticalHit', 'em', 'Critical Hits'), 'CRIT1': ('Crit.CriticalHit', 'em', 'Critical Hit'),
 'HEALTH': ('Stat.Health', 'em', 'Health'), 'MAXHEALTH': ('Stat.Health', 'em', 'Maximum Health'),
 'SHIELD': ('Stat.Shield', 'em', 'Shields'), 'MAXSHIELD': ('Stat.Shield', 'em', 'Maximum Shields'),
 'TEMPSHIELD': ('Stat.Shield', 'em', 'Temporary Shield'), 'ARMOR': ('Stat.Armor', 'em', 'Armor'),
 'ELITE': ('EnemyType.Elite', 'em', 'Elite'), 'ELITES': ('EnemyType.Elite', 'em', 'Elites'),
 'LIFESTEAL': ('Effect.Lifesteal', 'em', 'Lifesteal'), 'ELEMDEBUFFS': ('Elemental', 'em', 'Elemental Debuffs'),
 'PROC': ('ProcChance', 'em', 'Proc Chance'), 'MARK': ('Effect.Marked', 'em', 'Mark'), 'MARKED': ('Effect.Marked', 'em', 'Marked'),
 'WEAKPOINT': ('WeakpointDamage', 'em', 'Weakpoint Damage'),
 'FIRE': ('DamageType.Fire', 'element_fire', 'Fire Damage'), 'IGNITE': ('Element.Fire.Ignite', 'element_fire', 'Ignite'),
 'LIGHTNING': ('DamageType.Lightning', 'element_lightning', 'Lightning Damage'), 'SHOCK': ('Element.Lightning.Shock', 'element_lightning', 'Shock'),
 'CRYO': ('DamageType.Cryo', 'element_cryo', 'Cryo Damage'), 'CHILL': ('Element.Cryo.Chill', 'element_cryo', 'Chill'),
 'FREEZE': ('Element.Cryo.Freeze', 'element_cryo', 'Freeze'),
 'VOID': ('DamageType.Void', 'element_void', 'Void Damage'), 'CORRUPTION': ('Element.Void.Corruption', 'element_void', 'Corruption'),
 'RADIATION': ('DamageType.Radiation', 'element_Radiation', 'Radiation Damage'), 'IRRADIATE': ('Element.Radiation.Irradiate', 'element_Radiation', 'Irradiate'),
 'PSIONIC': ('DamageType.Psionic', 'element_Psionic', 'Psionic Damage'), 'FRACTURE': ('Element.Psionic.Fracture', 'element_Psionic', 'Fracture'),
 'NANO': ('DamageType.Nano', 'element_nano', 'Nano Damage'),
}
T = {
 'Syringe': "*+15%* *Fire Rate* per stack.",
 'Glasses': "*+10%* {CRITCH} per stack.",
 'Hoof': "*+14%* *Movement Speed* per stack.",
 'Bear': "*15%* chance to *dodge* a hit (stacks like RoR2).",
 'Crowbar': "*+75%* (*+75%* per stack) damage to enemies above *90%* {HEALTH}.",
 'ArmorPlate': "Each hit to your {HEALTH} is reduced by *12* per stack.",
 'Tooth': "Heal *10* (*+5* per stack) {HEALTH} on kill.",
 'Medkit': "Heal *25* {HEALTH} per stack *2 seconds* after taking damage.",
 'Ukulele': "*25%* chance on hit to chain {LIGHTNING} to *3* (*+2* per stack) enemies for *80%* damage, applying {SHOCK}.",
 'Wisp': "Kills detonate, dealing {FIRE} to enemies within *12m* (*+2.4m* per stack) and applying {IGNITE}.",
 'Gasoline': "Kills burn enemies within *12m* (*+4m* per stack) with {FIRE}, applying {IGNITE}.",
 'Feather': "*+1* jump per stack.",
 'Infusion': "*+1* {MAXHEALTH} per kill per stack (up to *100* per stack).",
 'Behemoth': "Every hit explodes for *60%* {FIRE} within *4m* (*+2.5m* per stack), applying {IGNITE}.",
 'AttackSpeedAndMoveSpeed': "*+7.5%* *Fire Rate* and *+7%* *Movement Speed* per stack.",
 'AttackSpeedPerNearbyAllyOrEnemy': "*+10%* *Fire Rate* (*+3.5%* per stack) for each enemy or ally within *20m*, up to *3* (*+1* per stack).",
 'BarrierOnKill': "Gain *15* (*+15* per stack) {TEMPSHIELD} on kill.",
 'BleedOnHit': "*10%* (*+10%* per stack) chance on hit to bleed an enemy for *240%* base {NANO} over *3 seconds*.",
 'BossDamageBonus': "*+20%* (*+20%* per stack) damage to {ELITE} enemies and bosses.",
 'CritAtLowerElevation': "Hitting an enemy from above grants *+1%* (*+1%* per stack) {CRITCH} and {CRITDMG}, up to *10* times, for *10 seconds*.",
 'DelayedDamage': "Every *15 seconds*, the next hit you take is reduced by *10%* and spread over *3* (*+1* per stack) hits, one per second. The echoed hits can't kill you.",
 'FlatHealth': "*+25* (*+25* per stack) {MAXHEALTH}.",
 'FragileDamageBonus': "*+20%* (*+20%* per stack) damage. Dropping below *25%* {HEALTH} breaks all your Delicate Watches.",
 'HealWhileSafe': "Regenerate *3* (*+3* per stack) {HEALTH} per second while *out of combat*.",
 'HealingPotion': "Dropping below *25%* {HEALTH} uses up one Power Elixir and heals *75%* of your {MAXHEALTH}.",
 'IncreaseDamageOnMultiKill': "Each kill gives *+3.5%* (*+1%* per stack) damage, up to *10* (*+5* per stack) times, for *7 seconds*. Hitting enemies keeps it going.",
 'Mushroom': "After standing still for *1 second*, heal *4.5%* (*+2.25%* per stack) of your {MAXHEALTH} per second, along with allies within *3m* (*+1.5m* per stack).",
 'NearbyDamageBonus': "*+20%* (*+20%* per stack) damage to *nearby* enemies (within *13m*).",
 'OutOfCombatArmor': "While *out of combat*, the first hit you take is reduced by *50%* (stacks like armor).",
 'PersonalShield': "*+20* (*+20* per stack) {MAXSHIELD}.",
 'SecondarySkillMagazine': "*+10%* (*+10%* per stack) magazine capacity.",
 'SprintBonus': "*+25%* (*+25%* per stack) *Sprint Speed*.",
 'StunChanceOnHit': "*5%* (*+5%* per stack) chance on hit to {FREEZE} an enemy for *2 seconds*.",
 'WardOnLevel': "When an encounter starts, drop a banner: you and allies within *16m* (*+8m* per stack) get *+30%* *Fire Rate* and *Movement Speed* for *30 seconds*.",
 'AttackSpeedOnCrit': "*+5%* {CRITCH}. {CRITHIT} give *+12%* *Fire Rate* for *3 seconds*, up to *3* (*+2* per stack) times.",
 'Bandolier': "*18%* (*+10%* per stack) chance on kill to refill all your ammo.",
 'DeathMark': "Enemies with *2* or more {ELEMDEBUFFS} are {MARKED}: your hits deal *+50%* damage to them, and they stay {MARKED} for *7* (*+7* per stack) *seconds*.",
 'EquipmentMagazine': "*-15%* *Grenade* cooldown per stack.",
 'ExecuteLowHealthElite': "Instantly kill {ELITE} enemies below *13%* (*+13%* per stack) {HEALTH}.",
 'FireRing': "Hits over *4x* your normal damage also set off a flame tornado for *300%* (*+300%* per stack) of the hit as {FIRE} over *3 seconds*. (*10 second* cooldown)",
 'HealOnCrit': "*+5%* {CRITCH}. {CRITHIT} heal *8* (*+4* per stack) {HEALTH}.",
 'IceRing': "Hits over *4x* your normal damage also blast the enemy for *250%* (*+250%* per stack) of the hit as {CRYO}, applying {CHILL} for *3 seconds* (*+3* per stack). (*10 second* cooldown)",
 'JumpDamageStrike': "Moving builds charge. After *6 seconds* of moving, your next hit discharges *400%* (*+280%* per stack) base {LIGHTNING} within *17m* (*+7.5m* per stack), applying {SHOCK}.",
 'KnockBackHitEnemies': "Hits launch enemies into the air with an *Anti-Gravity* stun and deal *+10%* damage. Each enemy can be launched once every *15 seconds*.",
 'MoveSpeedOnKill': "Kills give *+125%* *Movement Speed* for *1 second* (*+0.5* per stack).",
 'Phasing': "Dropping below *25%* {HEALTH} makes you *Immune* to all damage for *2 seconds* and gives *+40%* *Movement Speed* for *5 seconds*. (*30 second* cooldown, *-50%* per stack)",
 'Seed': "Every hit heals you for *1* (*+1* per stack) {HEALTH} through {LIFESTEAL}.",
 'ShieldBooster': "*+10* {MAXSHIELD} per stack. When your {SHIELD} break, release a pulse of *100%* base {PSIONIC} plus your {MAXSHIELD}, launching enemies.",
 'SlowOnHit': "Hits apply {CHILL} for *2 seconds* (*+2* per stack).",
 'SpeedOnPickup': "Choosing an orb reward gives *+3%* damage and *Movement Speed* for *20 seconds*, up to *3* (*+2* per stack) times.",
 'SprintArmor': "While moving fast, hits you take are reduced by *23%* (stacks like armor).",
 'SprintOutOfCombat': "*+30%* (*+30%* per stack) *Movement Speed* while *out of combat*.",
 'StrengthenBurn': "Your RoR2 burns ({FIRE} over time) deal *+300%* (*+300%* per stack) damage.",
 'TPHealingNova': "When an encounter starts, heal you and allies within *30m* for *50%* of {MAXHEALTH}, *1* (*+1* per stack) time during the fight.",
 'TeleportOnLowHealth': "Once per mission, dropping below *25%* {HEALTH} gives a *30%* {TEMPSHIELD} and for *8 seconds* blasts away enemies within *10m* with {NANO}.",
 'TriggerEnemyDebuffs': "*10%* chance on hit to bleed for {NANO}. Killing an enemy passes its {ELEMDEBUFFS} on to *1* (*+1* per stack) enemy within *20m* (*+5m* per stack).",
 'WarCryOnMultiKill': "Killing *4* enemies within *1 second* sends you into a frenzy for *6 seconds* (*+4* per stack): *+50%* *Movement Speed* and *+100%* *Fire Rate*.",
 'AlienHead': "Abilities recharge *33%* faster per stack (*25%* shorter cooldowns).",
 'ArmorReductionOnHit': "Every *5th* hit on the same enemy {MARK}s it, increasing damage taken by *50%* for *8 seconds* (*+8* per stack).",
 'BarrierOnOverHeal': "Healing past full {HEALTH} gives {TEMPSHIELD} worth *50%* (*+50%* per stack) of the extra healing.",
 'BoostAllStats': "*+4%* damage and *Fire Rate* for each active RoR2 buff, up to *4* (*+4* per stack).",
 'Clover': "All RoR2 item chances roll *+1* (*+1* per stack) extra time for a good result.",
 'CritDamage': "*+35%* (*+35%* per stack) {CRITDMG}.",
 'Duplicator': "Getting a RoR2 item also gives you a temporary copy of it for *10 seconds* (*+10* per stack).",
 'FallBoots': "*+30%* jump height. Landing after a big fall causes a kinetic blast of {PSIONIC} that grows with the fall height. (*10 second* cooldown, *-50%* per stack)",
 'Icicle': "Kills surround you with an ice storm for *6 seconds* that hits enemies for *60%* base {CRYO} every *0.5 seconds*, applying {CHILL}. Each kill grows it by *2m*, up to *18m* (*+12m* per stack).",
 'IncreaseHealing': "*+100%* (*+100%* per stack) *Health Orb* and RoR2 healing.",
 'KillEliteFrenzy': "Killing an {ELITE} enemy sends you into a frenzy for *4 seconds* (*+4* per stack): abilities recharge *10x* faster.",
 'PermanentDebuffOnHit': "Each hit permanently makes that enemy take *+2%* (*+2%* per stack) more damage from you, up to *+50%*.",
 'Plant': "Kills plant a seed that grows after *5 seconds* and for *10 seconds* heals you and allies within *5m* (*+5m* per stack) for *10%* of {MAXHEALTH} per second.",
 'SharedSuffering': "Infect up to *4* (*+2* per stack) enemies with {CORRUPTION}. *45%* of all damage they take is pooled, and every *3 seconds* each infected enemy takes the pool as {VOID}.",
 'ShockNearby': "Zaps *3* (*+2* per stack) enemies within *35m* for *200%* base {LIGHTNING} every *0.5 seconds*, applying {SHOCK}. Switches off every *10 seconds*.",
 'Talisman': "Kills make abilities recharge *11%* faster for *4 seconds* (*+2* per stack), stacking up to *5* times.",
 'UtilitySkillMagazine': "Dash recharges *50%* faster per stack (*33%* shorter cooldown) and *+10%* *Sprint Speed*.",
}
# appended to every item that deals RoR2 damage: the Deadzone keyword rules it follows
CRIT_NOTE = " Can {CRIT1}."
def expand(s):
    s = re.sub(r'\{(\w+)\}', lambda m: (f'<img id="{K[m.group(1)][0]}"/>' if K[m.group(1)][0] else '') + f'<{K[m.group(1)][1]}>{K[m.group(1)][2]}</>', s)
    s = re.sub(r'\*([^*]+)\*', r'<em>\1</>', s)
    return s
items = json.load(open(os.path.join(D, 'sheets', 'items.json')))['rows']
dmg_items = {r['id'] for r in items if (r.get('dmg') or 0) > 0 or r['id'] in ('BleedOnHit', 'ShockNearby', 'SharedSuffering', 'TriggerEnemyDebuffs')}
rows = []
for r in items:
    t = T[r['id']]
    if r['id'] in dmg_items and r['id'] not in ('Infusion', 'HealingPotion', 'Mushroom', 'Plant', 'TPHealingNova', 'Crowbar', 'BossDamageBonus', 'NearbyDamageBonus', 'FragileDamageBonus'):
        t += CRIT_NOTE
    rows.append({'id': r['id'], 'rich': expand(t)})
missing = [r['id'] for r in items if r['id'] not in T]
assert not missing, missing
json.dump({'columns': ['id', 'rich'], 'rows': rows, 'keywords': {k: list(v) for k, v in K.items()}}, open(os.path.join(D, 'sheets', 'item_text.json'), 'w'), indent=1)
print(len(rows), 'descriptions;', sum(1 for r in rows if 'Critical Hit<' in r['rich']), 'with the crit note')
