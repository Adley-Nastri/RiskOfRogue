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
 # Every line checked against sheets/items.json and the handlers in the mod's Lua (2026-10-13 audit).
 # "average hit" = the engine's g.base: a running average of your hit damage.
 'Syringe': "*+15%* *Fire Rate* per stack.",
 'Glasses': "*+10%* {CRITCH} per stack.",
 'Hoof': "*+14%* *Movement Speed* per stack.",
 'Bear': "*15%* chance to *dodge* incoming damage (more with stacks, with diminishing returns).",
 'Crowbar': "*+75%* (*+75%* per stack) damage to enemies above *90%* {HEALTH}.",
 'ArmorPlate': "Damage to your {HEALTH} is reduced by *12* (*+12* per stack) per hit, down to a minimum of *1*.",
 'Tooth': "Killing an enemy heals *15* (*+5* per stack) {HEALTH}.",
 'Medkit': "*2 seconds* after taking damage, heal *25* (*+25* per stack) {HEALTH}.",
 'Ukulele': "*25%* chance on hit to fire chain lightning at up to *3* (*+2* per stack) enemies within *20m* for *80%* of the hit as {LIGHTNING}, applying {SHOCK}.",
 'Wisp': "Killed enemies detonate, dealing *35%* (*+26%* per stack) of their {MAXHEALTH} as {FIRE} to enemies within *12m* (*+2.4m* per stack), applying {IGNITE}.",
 'Gasoline': "Killed enemies burn everything within *12m* (*+4m* per stack) for *25%* (*+12.5%* per stack) of their {MAXHEALTH} as {FIRE} over *3 seconds*, applying {IGNITE}.",
 'Feather': "*+1* (*+1* per stack) extra jump.",
 'Infusion': "Killing an enemy permanently gives *+1* (*+1* per stack) {MAXHEALTH}, up to *100* (*+100* per stack).",
 'Behemoth': "Every hit explodes for *60%* of the hit as {FIRE} to other enemies within *4m* (*+2.5m* per stack), applying {IGNITE}.",
 'AttackSpeedAndMoveSpeed': "*+7.5%* *Fire Rate* and *+7%* *Movement Speed* per stack.",
 'AttackSpeedPerNearbyAllyOrEnemy': "*+10%* (*+3.5%* per stack) *Fire Rate* for each enemy within *20m*, up to *3* (*+1* per stack) enemies.",
 'BarrierOnKill': "Killing an enemy gives *15* (*+15* per stack) {TEMPSHIELD}.",
 'BleedOnHit': "*10%* (*+10%* per stack) chance on hit to deal *240%* of your average hit as {NANO} over *3 seconds*.",
 'BossDamageBonus': "*+20%* (*+20%* per stack) damage to {ELITE} enemies and bosses.",
 'CritAtLowerElevation': "Hitting an enemy at least *1.5m* below you grants *+1%* (*+1%* per stack) {CRITCH} and *+1%* {CRITDMG} for *10 seconds*, stacking up to *10* times.",
 'DelayedDamage': "Once every *15 seconds*, the next hit you take is reduced by *10%* and the rest is dealt to you over *3* (*+1* per stack) seconds instead. The delayed damage can't kill you.",
 'FlatHealth': "*+25* (*+25* per stack) {MAXHEALTH}.",
 'FragileDamageBonus': "*+20%* (*+20%* per stack) damage. Dropping below *25%* {HEALTH} breaks all of your Delicate Watches.",
 'HealWhileSafe': "Heal *3* (*+3* per stack) {HEALTH} per second while *out of combat* (*5 seconds* without dealing or taking damage).",
 'HealingPotion': "Dropping below *25%* {HEALTH} consumes one Power Elixir and heals *75%* of your {MAXHEALTH}.",
 'IncreaseDamageOnMultiKill': "Killing an enemy grants *+3.5%* (*+1%* per stack) damage for *7 seconds*, stacking up to *10* (*+5* per stack) times. Hitting enemies keeps it active.",
 'Mushroom': "After standing still for *1 second*, heal *4.5%* (*+2.25%* per stack) of your {MAXHEALTH} every second. Allies within *3m* (*+1.5m* per stack) are healed too.",
 'NearbyDamageBonus': "*+20%* (*+20%* per stack) damage to *nearby* enemies (within *13m*).",
 'OutOfCombatArmor': "While *out of combat*, the next hit you take is reduced by *50%* (more with stacks, with diminishing returns).",
 'PersonalShield': "*+20* (*+20* per stack) {MAXSHIELD}.",
 'SecondarySkillMagazine': "*+10%* (*+10%* per stack) magazine capacity.",
 'SprintBonus': "*+25%* (*+25%* per stack) *Sprint Speed*.",
 'StunChanceOnHit': "*5%* chance on hit to {FREEZE} an enemy for *2 seconds* (more with stacks, with diminishing returns).",
 'WardOnLevel': "When an encounter starts, drop a Warbanner for *30 seconds*. You and allies within *16m* (*+8m* per stack) of it gain *+30%* *Fire Rate* and *Movement Speed*.",
 'AttackSpeedOnCrit': "*+5%* (*+5%* per stack) {CRITCH}. {CRITHIT} grant *+12%* *Fire Rate* for *3 seconds*, stacking up to *3* (*+2* per stack) times.",
 'Bandolier': "*18%* chance on kill to refill all of your ammo (more with stacks, with diminishing returns).",
 'DeathMark': "Hitting an enemy that has *2* or more {ELEMDEBUFFS} from your items applies {MARK} for *7* (*+7* per stack) *seconds*. {MARKED} enemies take *+50%* damage.",
 'EquipmentMagazine': "*-15%* *Grenade* cooldown per stack.",
 'ExecuteLowHealthElite': "Instantly kill {ELITE} enemies below *13%* {HEALTH} (more with stacks, with diminishing returns).",
 'FireRing': "Hits that deal at least *4x* your average hit also burn the target for *300%* (*+300%* per stack) of that hit as {FIRE} over *3 seconds*, applying {IGNITE}. (*10 second* cooldown)",
 'HealOnCrit': "*+5%* (*+5%* per stack) {CRITCH}. {CRITHIT} heal *8* (*+4* per stack) {HEALTH}.",
 'IceRing': "Hits that deal at least *4x* your average hit also blast the target for *250%* (*+250%* per stack) of that hit as {CRYO}, applying {CHILL}. (*10 second* cooldown)",
 'JumpDamageStrike': "Moving builds charge. After *6 seconds* of moving, your next hit releases *400%* (*+280%* per stack) of your average hit as {LIGHTNING} to enemies within *17m* (*+7.5m* per stack), applying {SHOCK}.",
 'KnockBackHitEnemies': "Hitting an enemy launches it into the air for *1.5 seconds* and deals *+10%* damage. Each enemy can be launched once every *15 seconds*.",
 'MoveSpeedOnKill': "Killing an enemy grants *+125%* *Movement Speed* for *1* (*+0.5* per stack) *second*.",
 'Phasing': "Dropping below *25%* {HEALTH} makes you *Immune* to damage for *2 seconds* and grants *+40%* *Movement Speed* for *5 seconds*. (*30 second* cooldown, halved per stack)",
 'Seed': "Every hit heals you for *1* (*+1* per stack) {HEALTH}.",
 'ShieldBooster': "*+10* (*+10* per stack) {MAXSHIELD}. When your {SHIELD} break, release a pulse within *10m* that deals *100%* of your average hit plus your {MAXSHIELD} as {PSIONIC} and launches enemies.",
 'SlowOnHit': "Hits apply {CHILL} for *2* (*+2* per stack) *seconds*.",
 'SpeedOnPickup': "Taking an item orb reward grants *+3%* damage and *Movement Speed* for *20 seconds*, stacking up to *3* (*+2* per stack) times.",
 'SprintArmor': "While moving fast, damage you take is reduced by *23%* (more with stacks, with diminishing returns).",
 'SprintOutOfCombat': "*+30%* (*+30%* per stack) *Movement Speed* while *out of combat*.",
 'StrengthenBurn': "{FIRE} that burns over time from your items (Gasoline, Kjaro's Band) deals *+300%* (*+300%* per stack) damage.",
 'TPHealingNova': "When an encounter starts, heal yourself and allies within *30m* for *50%* of {MAXHEALTH}. Repeats *1* (*+1* per stack) times, *15 seconds* apart.",
 'TeleportOnLowHealth': "Once per mission, dropping below *25%* {HEALTH} grants {TEMPSHIELD} worth *30%* of your {MAXHEALTH}. For the next *8 seconds*, enemies within *10m* take *100%* of your average hit as {NANO} every second and are launched.",
 'TriggerEnemyDebuffs': "*10%* chance on hit to deal *100%* of your average hit as {NANO} over *2 seconds*. Killing an enemy passes its {ELEMDEBUFFS} on to *1* (*+1* per stack) enemy within *20m* (*+5m* per stack).",
 'WarCryOnMultiKill': "Killing *4* enemies within *1 second* sends you into a frenzy for *6* (*+4* per stack) *seconds*: *+50%* *Movement Speed* and *+100%* *Fire Rate*.",
 'AlienHead': "Abilities recharge *33%* faster (*+33%* per stack, compounding).",
 'ArmorReductionOnHit': "Every *5th* hit on the same enemy applies {MARK} for *8* (*+8* per stack) *seconds*. {MARKED} enemies take *+50%* damage.",
 'BarrierOnOverHeal': "Healing past full {HEALTH} grants {TEMPSHIELD} worth *50%* (*+50%* per stack) of the extra healing.",
 'BoostAllStats': "*+4%* damage and *Fire Rate* for each active item buff, up to *4* (*+4* per stack) buffs.",
 'Clover': "Item effects that rely on chance roll *1* (*+1* per stack) extra time for a favourable outcome.",
 'CritDamage': "*+35%* (*+35%* per stack) {CRITDMG}.",
 'Duplicator': "Taking an item from an item orb also grants a temporary copy of it for *10* (*+10* per stack) *seconds*.",
 'FallBoots': "*+30%* (*+30%* per stack) jump height. Landing after falling at least *4m* releases a kinetic blast of {PSIONIC} that grows with the fall height. (*10 second* cooldown, halved per stack)",
 'Icicle': "Killing an enemy surrounds you with an ice storm for *6 seconds* that deals *60%* of your average hit as {CRYO} every *0.5 seconds*, applying {CHILL}. Each kill grows it by *2m*, up to *18m* (*+12m* per stack).",
 'IncreaseHealing': "All healing is *+100%* (*+100%* per stack) stronger, including *Health Orbs*.",
 'KillEliteFrenzy': "Killing an {ELITE} enemy sends you into a frenzy for *4* (*+4* per stack) *seconds*: abilities recharge *10x* faster.",
 'PermanentDebuffOnHit': "Each hit permanently makes that enemy take *+2%* (*+2%* per stack) more damage from you, up to *+50%*.",
 'Plant': "Killing an enemy plants a seed that sprouts after *5 seconds*. For *10 seconds* it heals you and allies within *5m* (*+5m* per stack) for *10%* of {MAXHEALTH} every second.",
 'SharedSuffering': "Hits infect up to *4* (*+2* per stack) enemies with {CORRUPTION}. *45%* of all damage you deal to infected enemies is pooled, and every *3 seconds* each infected enemy takes the pool as {VOID}.",
 'ShockNearby': "Every *0.5 seconds*, zap *3* (*+2* per stack) enemies within *35m* for *200%* of your average hit as {LIGHTNING}, applying {SHOCK}. Switches on and off every *10 seconds*.",
 'Talisman': "Killing an enemy makes abilities recharge *11%* faster for *4* (*+2* per stack) *seconds*, stacking up to *5* times.",
 'UtilitySkillMagazine': "Dash recharges *50%* faster (*+50%* per stack, compounding). *+10%* (*+10%* per stack) *Sprint Speed*.",
}
# Flavour lines are RoR2's own; only the ones that promise something these items don't do here are reworded.
PICKUP = {
 'AttackSpeedPerNearbyAllyOrEnemy': "Increases your attack speed for every nearby enemy.",
 'BarrierOnKill': "Gain a temporary shield on kill.",
 'BossDamageBonus': "Deal extra damage to bosses and elites.",
 'SecondarySkillMagazine': "Increase your magazine size.",
 'StunChanceOnHit': "Chance to freeze on hit.",
 'WardOnLevel': "Drop a Warbanner when an encounter starts. Grants allies attack and movement speed.",
 'Bandolier': "Chance on kill to refill all of your ammo.",
 'DeathMark': "Enemies with 2 or more debuffs are marked, taking bonus damage.",
 'EquipmentMagazine': "Reduce grenade cooldown.",
 'JumpDamageStrike': "Moving around builds up charge. Your next hit discharges into an electric blast.",
 'KnockBackHitEnemies': "Enemies hit are launched and take bonus damage.",
 'Phasing': "Turn invincible at low health.",
 'ShieldBooster': "Gain extra shield. When shield breaks, release a stunning pulse that deals more damage the more shield you have.",
 'SpeedOnPickup': "Item orbs grant a stacking bonus to damage and movement speed.",
 'TPHealingNova': "Release a healing nova when an encounter starts.",
 'TeleportOnLowHealth': "Gain a temporary shield and a dimensional aura on low health.",
 'ArmorReductionOnHit': "Mark enemies after repeatedly striking them.",
 'BarrierOnOverHeal': "Healing past full grants you a temporary shield.",
 'BoostAllStats': "Your buffs increase your damage and attack speed.",
 'CritDamage': "Your 'Critical Strikes' deal more damage.",
 'FallBoots': "Increase jump height. Landing from a great height creates a kinetic blast.",
 'KillEliteFrenzy': "Skills recharge rapidly for a short period after killing an elite.",
 'PermanentDebuffOnHit': "Enemies you hit permanently take more damage from you.",
 'ShockNearby': "Shock nearby enemies. Turns on and off every 10 seconds.",
 'Talisman': "Kills make your abilities recharge faster.",
 'UtilitySkillMagazine': "Your dash recharges faster.",
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
    rich = expand(t)
    plain = re.sub(r'<img id="[^"]+"/>', '', rich); plain = re.sub(r'</?[A-Za-z_]*>', '', plain)
    rows.append({'id': r['id'], 'rich': rich, 'plain': plain, 'pickup': PICKUP.get(r['id'], r['pickup'])})
missing = [r['id'] for r in items if r['id'] not in T]
assert not missing, missing
json.dump({'columns': ['id', 'rich', 'plain', 'pickup'], 'rows': rows, 'keywords': {k: list(v) for k, v in K.items()}}, open(os.path.join(D, 'sheets', 'item_text.json'), 'w'), indent=1)
print(len(rows), 'descriptions;', sum(1 for r in rows if 'Critical Hit<' in r['rich']), 'with the crit note')
