#!/usr/bin/env python3
"""Build sheets/items.json: the 14 tested items (kept as they are) plus every other white/green/red RoR2
item, each mapped onto a Deadzone mechanic. Names and pickup lines come from the user's own RoR2
language files (research/ror2_items.json); descriptions say what the item does in Deadzone."""
import json, os
D = os.path.dirname(os.path.abspath(__file__)); S = os.path.join(D, '..', 'sheets')
ror = {r['name']: r for r in json.load(open(os.path.join(D, 'ror2_items.json')))}
old = json.load(open(os.path.join(D, 'items_base14.json')))
TIER = {0: 'white', 1: 'green', 2: 'red'}
COLS = ['id','name','rarity','icon','tex','pickup','kind','trigger','cond','cv','chance','chance_per','action','ge','attr','op','k','k_per','stack',
        'ge2','attr2','op2','k2','dur','dur_per','cap','cap_per','cd','cd_per','radius','radius_per','n','n_per','dmg','dmg_per','dmg_base',
        'element','status','tag','pge','pattr','pop','pk','sub','refresh','once','consume','invuln','delay','src','desc']
DEF = dict(trigger='', cond='', cv=0, chance=1.0, chance_per=0, action='', ge='', attr='', op='', k=0, k_per=0, stack='linear',
           ge2='', attr2='', op2='', k2=0, dur=0, dur_per=0, cap=0, cap_per=0, cd=0, cd_per=0, radius=0, radius_per=0, n=0, n_per=0,
           dmg=0, dmg_per=0, dmg_base='hit', tex='', element='none', status='none', tag='', pge='', pattr='', pop='', pk=0, sub='', refresh='', once='', consume=0, invuln=0, delay=0, src='')
A = '/Game/Abilities/DeviceUpgrades/Attributes/'
G = {  # stat effects (path, attribute, op)
 'atk': (A+'GE_GenericAttribute_AttackRateMultiplier', 'AttackRateMultiplier', 'mult'),
 'move': (A+'GE_MovementSpeed', 'MovementSpeed', 'mult'),
 'dmg': (A+'GE_GlobalDamageModifier', 'GlobalDamageMultiplier', 'add'),
 'crit': (A+'GE_GenericAttribute_CriticalChanceModifier_Additive', 'CriticalChanceModifier', 'add'),
 'critdmg': (A+'GE_GenericAttribute_CriticalDamageMultiplier_Additive', 'CriticalDamageMultiplier', 'add'),
 'hp': (A+'GE_GenericAttribute_MaxHealth_Additive', 'HealthMax', 'add'),
 'shield': (A+'GE_GenericAttribute_MaxShield_Additive', 'ShieldMax', 'add'),
 'clip': (A+'GE_GenericAttribute_MaxClipSize_Multiplicative', 'ClipAmmoMaxMultiplicativeBonus', 'add'),
 'sprint': (A+'GE_GenericAttribute_SprintSpeed', 'SprintSpeedMultiplier', 'mult'),
 'jump': (A+'GE_GenericAttribute_JumpHeight', 'JumpHeightMultiplier', 'add'),
 'cdr': (A+'GE_GenericAttribute_UniversalCooldownModifier', 'UniversalCooldownModifier', 'mult'),
 'dashcd': (A+'GE_GenericAttribute_DashCooldownModifier', 'DashCooldownModifier', 'add'),  # a recharge RATE: higher = faster (checked in game)
 'grenadecd': (A+'GE_GenericAttribute_GrenadeCooldownModifier', 'GrenadeCooldownModifier', 'mult'),
 'orb': (A+'GE_GenericAttribute_HealthOrbValueMultiplier', 'HealthOrbValueMultiplier', 'mult'),
}
def st(key, k, **kw):
    g = G[key]; return dict(ge=g[0], attr=g[1], op=g[2], k=k, **kw)
def pst(key, k):
    g = G[key]; return dict(pge=g[0], pattr=g[1], pop=g[2], pk=k)
def st2(key, k):
    g = G[key]; return dict(ge2=g[0], attr2=g[1], op2=g[2], k2=k)
B = lambda **kw: kw
NEW = {
# ---------------- white ----------------
'AttackSpeedAndMoveSpeed': B(kind='stat', **st('atk', .075), **st2('move', .07), desc="+7.5% fire rate and +7% move speed per stack."),
'AttackSpeedPerNearbyAllyOrEnemy': B(kind='cstat', cond='nearby', radius=2000, cap=3, cap_per=1, **st('atk', .10), k_per=.035,
    desc="+10% fire rate (+3.5% per stack) for each enemy or ally within 20 m, up to 3 (+1 per stack)."),
'BarrierOnCooldown': B(kind='effect', trigger='periodic', cd=8, action='barrier', k=0, dmg=.08, dmg_per=.02,
    desc="Every 8 s, gain a temporary shield of 8% (+2% per stack) of your max health. (Deadzone has no skill cooldown events, so this runs on a timer.)"),
'BarrierOnKill': B(kind='effect', trigger='kill', action='barrier', k=15, k_per=15, desc="Gain a 15 (+15 per stack) temporary shield on kill."),
'BleedOnHit': B(kind='effect', trigger='hit', chance=.10, chance_per=.10, action='dot', dur=3, dmg=2.4, dmg_base='base', element='nano',
    desc="10% (+10% per stack) chance on hit to bleed an enemy for 240% base damage over 3 s. Deadzone Nano damage."),
'BossDamageBonus': B(kind='effect', trigger='hit', cond='v_elite', action='bonus', dmg=.20, dmg_per=.20, desc="Deal +20% (+20% per stack) damage to elites and bosses (the toughest enemies in the area)."),
'CritAtLowerElevation': B(kind='buff', trigger='hit', cond='above', cv=150, dur=10, cap=10, **st('crit', .01), k_per=.01, **st2('critdmg', .01),
    desc="Hitting an enemy from above grants +1% (+1% per stack) crit chance and crit damage, up to 10 times, for 10 s."),
'DelayedDamage': B(kind='special', cd=15, n=3, n_per=1, k=.10,
    desc="Every 15 s, the next hit you take is reduced by 10% and spread over 3 (+1 per stack) hits, one per second. The echoed hits can't kill you."),
'Firework': B(kind='effect', trigger='orb', action='multi', n=8, n_per=4, radius=4000, dmg=3.0, dmg_base='base', element='fire', tag='missile',
    desc="Choosing a reward from an orb launches 8 (+4 per stack) fireworks at enemies within 40 m for 300% base damage each. Deadzone Fire damage."),
'FlatHealth': B(kind='stat', **st('hp', 25), desc="+25 (+25 per stack) max health."),
'FragileDamageBonus': B(kind='stat', **st('dmg', .20), desc="+20% (+20% per stack) damage. Dropping below 25% health breaks all your Delicate Watches."),
'GoldOnHurt': B(kind='effect', trigger='hurt', action='currency', k=3, k_per=3, desc="Gain 3 (+3 per stack) credits when an enemy hurts you. Scales with the difficulty clock."),
'HealWhileSafe': B(kind='regen', cond='ooc', k=3, k_per=3, desc="Regenerate 3 (+3 per stack) health per second while out of combat (5 s without dealing or taking damage)."),
'HealingPotion': B(kind='special', dmg=.75, desc="Dropping below 25% health uses up one Power Elixir and heals you for 75% of max health."),
'IncreaseDamageOnMultiKill': B(kind='buff', trigger='kill', dur=7, cap=10, cap_per=5, refresh='hit', **st('dmg', .035), k_per=.01,
    desc="Each kill gives +3.5% (+1% per stack) damage, up to 10 (+5 per stack) times, for 7 s. Hitting enemies keeps it going."),
'Mushroom': B(kind='regen', cond='still', k=0, dmg=.045, dmg_per=.0225, radius=300, radius_per=150,
    desc="After standing still for 1 s, heal 4.5% (+2.25% per stack) of max health per second, along with allies within 3 m (+1.5 m per stack)."),
'NearbyDamageBonus': B(kind='effect', trigger='hit', cond='v_near', cv=1300, action='bonus', dmg=.20, dmg_per=.20, desc="+20% (+20% per stack) damage to enemies within 13 m."),
'OutOfCombatArmor': B(kind='effect', trigger='hurt', cond='ooc', action='refund', k=1.0, stack='hyperbolic', desc="While out of combat, the first hit you take is reduced by 50% (stacks like armor)."),
'PersonalShield': B(kind='stat', **st('shield', 20), desc="+20 (+20 per stack) max shield."),
'SecondarySkillMagazine': B(kind='stat', **st('clip', .10), desc="+10% (+10% per stack) magazine size. (Deadzone has no secondary-skill charges.)"),
'SpeedBoostPickup': B(kind='buff', trigger='periodic', cd=10, cd_per=.9, dur=12, cap=3, cap_per=3, **st('move', .12),
    desc="Every 10 s (-10% per stack), gain +12% move speed for 12 s, stacking up to 3 (+3 per stack) times."),
'SprintBonus': B(kind='stat', **st('sprint', .25), desc="+25% (+25% per stack) sprint speed."),
'StickyBomb': B(kind='effect', trigger='hit', chance=.05, chance_per=.05, action='delayed', dur=1.5, radius=300, dmg=1.8, element='fire',
    desc="5% (+5% per stack) chance on hit to attach a bomb that explodes after 1.5 s for 180% of the hit. Deadzone Fire damage."),
'StunChanceOnHit': B(kind='effect', trigger='hit', chance=.05, chance_per=.05, stack='hyperbolic', action='status', status='freeze', dur=2,
    desc="5% (+5% per stack) chance on hit to freeze an enemy in place for 2 s (Deadzone Cryo Freeze)."),
'TreasureCache': B(kind='effect', trigger='stage', action='item', k=80, consume=1,
    desc="At the start of the next mission, uses up one Rusted Key and gives you a random RoR2 item (80% white, 20% green)."),
'WardOnLevel': B(kind='effect', trigger='encounter', action='aura', sub='buff_zone', dur=30, radius=1600, radius_per=800, **st('atk', .30), **st2('move', .30),
    desc="When an encounter starts, drop a banner: you and allies within 16 m (+8 m per stack) get +30% fire rate and move speed for 30 s."),
# ---------------- green ----------------
'AttackSpeedOnCrit': B(kind='buff', trigger='crit', dur=3, cap=3, cap_per=2, **st('atk', .12), **pst('crit', .05), desc="Critical hits give +12% fire rate for 3 s, up to 3 (+2 per stack) times. Also +5% crit chance."),
'Bandolier': B(kind='effect', trigger='kill', chance=.18, chance_per=.10, stack='hyperbolic', action='ammo', desc="18% (+10% per stack) chance on kill to refill all your ammo."),
'BonusGoldPackOnKill': B(kind='effect', trigger='kill', chance=.04, chance_per=.04, action='currency', k=25, desc="4% (+4% per stack) chance on kill to gain 25 credits. Scales with the difficulty clock."),
'DeathMark': B(kind='effect', trigger='hit', cond='v_debuffed', cv=2, action='bonus', dmg=.5, status='radiation', dur=7, dur_per=7,
    desc="Enemies with 2 or more elemental debuffs are marked: your hits on them deal +50% damage and Irradiate them for 7 (+7 per stack) s."),
'DronesDropDynamite': B(kind='effect', trigger='periodic', cd=10, cond='in_combat', action='aoe_random', radius=3000, dmg=2.4, dmg_per=.85, dmg_base='base', element='fire', status='freeze', dur=1,
    desc="In combat, every 10 s a stick of dynamite drops on a nearby enemy for 240% (+85% per stack) base damage and stuns. Deadzone Fire damage. (No drones in Deadzone.)"),
'EnergizedOnEquipmentUse': B(kind='buff', trigger='elitekill', dur=8, dur_per=4, cap=1, **st('atk', .70), desc="Killing an elite gives +70% fire rate for 8 s (+4 s per stack). (Deadzone has no equipment.)"),
'EquipmentMagazine': B(kind='stat', **st('grenadecd', -.15), stack='power', desc="Grenade cooldown -15% per stack. (Deadzone's grenade stands in for RoR2 equipment.)"),
'ExecuteLowHealthElite': B(kind='effect', trigger='hit', cond='v_elite_low', cv=.13, action='execute', stack='hyperbolic', desc="Instantly kill elites below 13% (+13% per stack) health."),
'ExtraShrineItem': B(kind='special', k=.40, k_per=.10, desc="RoR2 cards in item orbs have a 40% (+10% per stack) chance to roll a higher rarity. (No shrines in Deadzone.)"),
'ExtraStatsOnLevelUp': B(kind='growth2', trigger='kill', **st('dmg', .001), cap=.20, cap_per=.05, **st2('hp', .25),
    desc="Each kill stores +0.1% damage and +0.25 max health, up to +20% (+5% per stack) damage. (Deadzone has no XP, so it grows with kills.)"),
'FireRing': B(kind='effect', trigger='hit', cond='hit_big', cv=4, cd=10, action='dot', dur=3, dmg=3.0, dmg_per=3.0, element='fire',
    desc="Hits over 4x your normal damage also set off a flame tornado for 300% (+300% per stack) of the hit over 3 s. 10 s cooldown. Deadzone Fire damage."),
'FreeChest': B(kind='effect', trigger='stage', action='item', k=79, k_per=0, desc="At the start of each mission, receive a RoR2 item (79% white, 20% green, 1% red)."),
'HealOnCrit': B(kind='effect', trigger='crit', action='heal', k=8, k_per=4, **pst('crit', .05), desc="+5% crit chance. Critical hits heal 8 (+4 per stack) health."),
'IceRing': B(kind='effect', trigger='hit', cond='hit_big', cv=4, cd=10, action='single', dmg=2.5, dmg_per=2.5, element='cryo', dur=3, dur_per=3,
    desc="Hits over 4x your normal damage also blast the enemy with ice for 250% (+250% per stack) of the hit and slow it for 3 s (+3 s per stack). 10 s cooldown. Deadzone Cryo."),
'IncreasePrimaryDamage': B(kind='effect', trigger='hit', cond='every', cv=5, action='single', dmg=1.75, dmg_per=.5, element='lightning',
    desc="Every 5th hit calls a lightning strike for 175% (+50% per stack) of the hit. Deadzone Lightning damage."),
'JumpBoost': B(kind='stat', **st('jump', .10), **st2('sprint', .08), desc="+10% jump height and +8% sprint speed per stack."),
'JumpDamageStrike': B(kind='effect', trigger='hit', cond='charged', cv=6, action='aoe', radius=1700, radius_per=750, dmg=4.0, dmg_per=2.8, dmg_base='base', element='lightning',
    desc="Moving builds charge. Once you've moved for 6 s, your next hit discharges for 400% (+280% per stack) base damage within 17 m (+7.5 m per stack). Deadzone Lightning damage."),
'KnockBackHitEnemies': B(kind='effect', trigger='hit', cond='v_cooldown', cv=15, action='bonus', dmg=.10, status='launch', dur=1.5,
    desc="Hitting an enemy launches it into the air (Deadzone Anti-Gravity stun) and it takes +10% damage. Each enemy can be launched once every 15 s."),
'LowerPricedChests': B(kind='special', desc="The first RoR2 item you pick each mission is doubled."),
'Missile': B(kind='effect', trigger='hit', chance=.10, action='single', dmg=3.0, dmg_per=3.0, element='fire', tag='missile',
    desc="10% chance on hit to fire a missile for 300% (+300% per stack) of the hit. Deadzone Fire damage."),
'MoveSpeedOnKill': B(kind='buff', trigger='kill', dur=1, dur_per=.5, cap=1, **st('move', 1.25), desc="Kills give +125% move speed for 1 s (+0.5 s per stack)."),
'Phasing': B(kind='effect', trigger='lowhp', cd=30, cd_per=.5, action='buff', dur=5, **st('move', .40), invuln=1,
    desc="Dropping below 25% health makes you invulnerable for 2 s and gives +40% move speed for 5 s. Recharges every 30 s (-50% per stack)."),
'PrimarySkillShuriken': B(kind='effect', trigger='hit', cond='charges', cv=3, cd=3.3, action='single', dmg=4.0, dmg_per=1.0, dmg_base='base', element='plasma',
    desc="Your hits also throw shurikens for 400% (+100% per stack) base damage. Hold up to 3 (+1 per stack); they reload over 10 s. Deadzone Plasma damage."),
'Seed': B(kind='effect', trigger='hit', action='heal', k=1, k_per=1, desc="Every hit heals you for 1 (+1 per stack) health."),
'ShieldBooster': B(kind='effect', trigger='shieldbreak', action='aoe_self', radius=1000, dmg=1.0, dmg_base='base', element='psionic', status='launch', dur=1, **pst('shield', 10),
    desc="+10 max shield per stack. When your shield breaks, release a stunning pulse for 100% base damage plus your max shield. Deadzone Psionic damage."),
'SlowOnHit': B(kind='effect', trigger='hit', action='status', status='cryo', dur=2, dur_per=2, desc="Hits slow enemies (Deadzone Cryo Chill) for 2 s (+2 s per stack)."),
'SpeedOnPickup': B(kind='buff', trigger='orb', dur=20, cap=3, cap_per=2, **st('dmg', .03), **st2('move', .03), desc="Choosing an orb reward gives +3% damage and move speed for 20 s, up to 3 (+2 per stack) times."),
'SprintArmor': B(kind='effect', trigger='hurt', cond='moving', action='refund', k=.3, stack='hyperbolic', desc="While moving fast, hits you take are reduced by 23% (stacks like armor)."),
'SprintOutOfCombat': B(kind='cstat', cond='ooc', **st('move', .30), desc="+30% (+30% per stack) move speed while out of combat."),
'Squid': B(kind='effect', trigger='orb', action='aura', sub='turret', dur=30, cd=1, radius=2500, dmg=1.0, dmg_per=1.0, dmg_base='base', element='plasma',
    desc="Choosing an orb reward summons an invisible squid turret: for 30 s it shoots an enemy within 25 m every second for 100% (+100% per stack) base damage. Deadzone Plasma damage."),
'StrengthenBurn': B(kind='special', k=3.0, k_per=3.0, desc="Your RoR2 burns (Fire damage over time) deal +300% (+300% per stack) damage."),
'TPHealingNova': B(kind='effect', trigger='encounter', action='heal_all', radius=3000, dmg=.5, n=1, n_per=1, desc="When an encounter starts, heal you and allies within 30 m for 50% of max health, 1 (+1 per stack) time(s) during the fight."),
'TeleportOnLowHealth': B(kind='effect', trigger='lowhp', once='stage', action='aura', sub='transmit', dur=8, radius=1000, dmg=1.0, dmg_base='base', element='nano', status='launch', k=.3,
    desc="Once per mission, dropping below 25% health gives a 30% temporary shield and for 8 s blasts away and damages enemies within 10 m. Deadzone Nano damage."),
'Thorns': B(kind='effect', trigger='hurt', action='multi', radius=2500, radius_per=1000, n=5, n_per=2, dmg=1.6, dmg_base='base', element='psionic',
    desc="Getting hit fires razors at up to 5 (+2 per stack) enemies within 25 m (+10 m per stack) for 160% base damage. Deadzone Psionic damage."),
'TriggerEnemyDebuffs': B(kind='special', chance=.10, radius=2000, radius_per=500, n=1, n_per=1, element='nano',
    desc="10% chance on hit to bleed (Nano). Killing an enemy passes its elemental debuffs on to 1 (+1 per stack) enemy within 20 m (+5 m per stack)."),
'WarCryOnMultiKill': B(kind='buff', trigger='multikill', cv=4, cd=1, dur=6, dur_per=4, cap=1, **st('move', .50), **st2('atk', 1.0),
    desc="Killing 4 enemies within 1 s sends you into a frenzy for 6 s (+4 s per stack): +50% move speed and +100% fire rate."),
# ---------------- red ----------------
'AlienHead': B(kind='stat', **st('cdr', -.25), stack='power', desc="All ability cooldowns -25% per stack."),
'ArmorReductionOnHit': B(kind='effect', trigger='hit', cond='every_target', cv=5, action='status', status='radiation', dur=8, dur_per=8,
    desc="Every 5th hit on the same enemy Irradiates it (weak points take more damage) for 8 s (+8 s per stack)."),
'BarrageOnBoss': B(kind='effect', trigger='periodic', cd=3, action='elite_strike', radius=4000, dmg=.025, dmg_per=.025, dmg_base='vmax', n=5, element='fire', tag='missile',
    desc="Every 3 s, 5 missiles strike the toughest enemy within 40 m for a total of 2.5% (+2.5% per stack) of its max health. Deadzone Fire damage."),
'BarrierOnOverHeal': B(kind='special', k=.5, k_per=.5, desc="Healing past full health gives a temporary shield worth 50% (+50% per stack) of the extra healing."),
'BoostAllStats': B(kind='cstat', cond='buffs', cap=4, cap_per=4, **st('dmg', .04), **st2('atk', .04), desc="+4% damage and fire rate for each active RoR2 buff, up to 4 (+4 per stack)."),
'BounceNearby': B(kind='effect', trigger='hit', chance=.20, chance_per=.20, stack='hyperbolic', action='chain', radius=3000, n=10, n_per=5, dmg=1.0, element='void',
    desc="20% (+20% per stack) chance on hit to fire hooks at up to 10 (+5 per stack) enemies for 100% of the hit. Deadzone Void damage."),
'CaptainDefenseMatrix': B(kind='effect', trigger='hurt', cd=5, cd_per=.5, action='refund', k=1.0, desc="Blocks one hit completely every 5 s (-50% per stack). (Deadzone projectiles can't be shot down, so this blocks the hit instead.)"),
'Clover': B(kind='special', desc="All RoR2 item chances roll +1 (+1 per stack) extra time for a good result."),
'CritDamage': B(kind='stat', **st('critdmg', .35), desc="+35% (+35% per stack) critical damage (doubles Deadzone's crit bonus)."),
'Dagger': B(kind='effect', trigger='kill', action='multi', radius=3000, n=3, dmg=1.5, dmg_per=1.5, dmg_base='base', element='plasma',
    desc="Killing an enemy fires 3 homing daggers at enemies within 30 m for 150% (+150% per stack) base damage. Deadzone Plasma damage."),
'Duplicator': B(kind='special', dur=10, dur_per=10, desc="Getting a RoR2 item also gives you a temporary copy of it for 10 s (+10 s per stack)."),
'FallBoots': B(kind='special', cd=10, cd_per=.5, radius=500, dmg=10.0, dmg_base='base', element='psionic', **pst('jump', .30),
    desc="+30% jump height. Landing after a big fall causes a kinetic blast that grows with the fall height. Recharges in 10 s (-50% per stack). Deadzone Psionic damage."),
'GhostOnKill': B(kind='effect', trigger='kill', chance=.07, action='aura', sub='turret', dur=30, dur_per=30, cd=1, radius=2000, dmg=1.5, dmg_base='base', element='void',
    desc="Kills have a 7% chance to raise a ghost that haunts you for 30 s (+30 s per stack), striking an enemy within 20 m each second for 150% base damage. Deadzone Void damage. (Deadzone can't spawn allies.)"),
'HeadHunter': B(kind='buff', trigger='elitekill', dur=8, dur_per=5, cap=1, **st('dmg', .30), **st2('move', .20), desc="Killing an elite gives +30% damage and +20% move speed for 8 s (+5 s per stack)."),
'Icicle': B(kind='effect', trigger='kill', action='aura', sub='storm', dur=6, cd=.5, radius=600, k=200, cap=1800, cap_per=1200, dmg=.6, dmg_base='base', element='cryo',
    desc="Kills surround you with an ice storm for 6 s that hits enemies for 60% base damage every 0.5 s and slows them. Each kill grows it by 2 m, up to 18 m (+12 m per stack). Deadzone Cryo."),
'ImmuneToDebuff': B(kind='effect', trigger='hurt', cd=5, action='barrier', dmg=.10, desc="Every 5 s, getting hit gives a temporary shield of 10% max health. (Deadzone debuffs can't be blocked, so this shields you instead.)"),
'IncreaseHealing': B(kind='stat', **st('orb', 1.0), desc="Healing orbs and RoR2 healing heal +100% (+100% per stack) more."),
'ItemDropChanceOnKill': B(kind='effect', trigger='elitekill', action='currency', k=50, k_per=10, desc="Killing an elite gives 50 (+10 per stack) credits. (RoR2 items never drop on their own here.)"),
'KillEliteFrenzy': B(kind='buff', trigger='elitekill', dur=4, dur_per=4, cap=1, **st('cdr', -.9), desc="Killing an elite sends you into a frenzy for 4 s (+4 s per stack) with 90% shorter ability cooldowns."),
'LaserTurbine': B(kind='effect', trigger='multikill', cv=4, cd=7, action='disc', radius=3000, dmg=3.0, dmg_per=3.0, dmg_base='base', k=10.0, k_per=10.0, element='plasma',
    desc="Killing 4 enemies within 7 s launches a disc: it hits every enemy within 30 m for 300% (+300% per stack) base damage and explodes on one for 1000% (+1000% per stack). Deadzone Plasma damage."),
'MeteorAttackOnHighDamage': B(kind='effect', trigger='hit', chance=.03, cond='meteor', action='aoe', radius=800, dmg=20.0, dmg_per=0, dmg_base='base', element='fire',
    desc="3% chance on hit to call a meteor for 2000% base damage, more likely and stronger the harder you hit (+3% chance per extra 100% damage). Deadzone Fire damage."),
'MoreMissile': B(kind='special', k=.5, desc="Missile items (Missile, Fireworks, War Bonds) fire 3 times. +50% missile damage per extra stack."),
'NovaOnHeal': B(kind='special', k=1.0, k_per=1.0, dmg=2.5, dmg_per=2.5, dmg_base='base', element='void',
    desc="Store 100% (+100% per stack) of healing. When it reaches 10% of max health, fire a skull at an enemy for 250% (+250% per stack) base damage plus 250% of the stored healing. Deadzone Void damage."),
'PermanentDebuffOnHit': B(kind='special', k=.02, k_per=.02, desc="Each hit permanently makes that enemy take +2% (+2% per stack) more damage from you, up to +50%."),
'PhysicsProjectile': B(kind='effect', trigger='periodic', cd=15, cond='in_combat', action='single_random', radius=3000, dmg=4.0, dmg_per=4.0, dmg_base='base', element='psionic',
    desc="Every 15 s in combat, launch a core at an enemy within 30 m for 400% (+400% per stack) base damage, +1% per 1% bonus move speed. Deadzone Psionic damage."),
'Plant': B(kind='effect', trigger='kill', action='aura', sub='heal_zone', dur=10, cd=1, radius=500, radius_per=500, dmg=.10, delay=5,
    desc="Kills plant a seed that grows after 5 s and for 10 s heals you and allies within 5 m (+5 m per stack) for 10% max health per second."),
'RandomEquipmentTrigger': B(kind='effect', trigger='orb', action='chaos', n=1, n_per=1, radius=1500, dmg=5.0, dmg_base='base',
    desc="Choosing an orb reward triggers 1 (+1 per stack) random effect: a blast, a heal, a temporary shield or a speed boost."),
'SharedSuffering': B(kind='special', n=4, n_per=2, k=.45, cd=3, element='void',
    desc="Infect up to 4 (+2 per stack) enemies. 45% of all damage they take is pooled, and every 3 s every infected enemy takes the pool. Deadzone Void damage."),
'ShockNearby': B(kind='effect', trigger='periodic', cd=.5, cond='tesla', cv=10, action='chain_self', radius=3500, n=3, n_per=2, dmg=2.0, dmg_base='base', element='lightning',
    desc="Zaps 3 (+2 per stack) enemies within 35 m for 200% base damage every 0.5 s. Switches off every 10 s. Deadzone Lightning damage."),
'StunAndPierce': B(kind='effect', trigger='hit', chance=.15, action='aoe', radius=800, dmg=1.2, dmg_per=1.2, dmg_base='base', element='lightning', status='freeze', dur=1,
    desc="15% chance on hit to throw a boomerang that hits enemies around the target for 120% (+120% per stack) base damage and stuns them. Deadzone Lightning damage."),
'Talisman': B(kind='buff', trigger='kill', dur=4, dur_per=2, cap=5, **st('cdr', -.10), desc="Kills give -10% ability cooldowns for 4 s (+2 s per stack), stacking up to 5 times."),
'UtilitySkillMagazine': B(kind='stat', **st('dashcd', .5), stack='power', **st2('sprint', .10), desc="Dash recharges 50% faster per stack (33% shorter cooldown) and +10% sprint speed."),
}
SKIP = {'RegeneratingScrap': 'needs 3D printers', 'DroneWeapons': 'needs drones', 'ExtraLife': "removed at the user's request (Dio)",
 # removed after review: the RoR2 mechanic doesn't exist in Deadzone, so the item would only be a stand-in
 'BarrierOnCooldown': 'needs skill-cooldown events', 'GoldOnHurt': 'gold/credits not visible in Deadzone runs',
 'BonusGoldPackOnKill': 'gold', 'ItemDropChanceOnKill': 'item drops (RoR2 items never drop)', 'BarrageOnBoss': 'gold and boss events',
 'SpeedBoostPickup': 'needs spawned pickups', 'TreasureCache': 'needs hidden caches', 'FreeChest': 'needs chests', 'LowerPricedChests': 'needs chests',
 'ExtraShrineItem': 'needs shrines', 'ExtraStatsOnLevelUp': 'needs experience levels', 'DronesDropDynamite': 'needs drones',
 'EnergizedOnEquipmentUse': 'needs an equipment slot', 'RandomEquipmentTrigger': 'needs equipment', 'IncreasePrimaryDamage': 'needs secondary-skill charges',
 'JumpBoost': 'the sprint-jump boost has no Deadzone equivalent', 'Squid': 'needs a turret ally', 'GhostOnKill': 'needs spawned allies',
 'PhysicsProjectile': 'needs a summoned unit', 'CaptainDefenseMatrix': 'enemy projectiles cannot be shot down', 'HeadHunter': 'needs elite affixes',
 'ImmuneToDebuff': 'debuffs on the player cannot be blocked',
 # removed: thrown or fired objects (projectiles, bombs, missiles) that Deadzone doesn't have
 'StunAndPierce': 'boomerang projectile', 'Missile': 'missiles', 'MoreMissile': 'missiles', 'Firework': 'fireworks',
 'StickyBomb': 'thrown bombs', 'PrimarySkillShuriken': 'thrown shurikens', 'Dagger': 'homing daggers', 'BounceNearby': 'thrown hooks',
 'Thorns': 'fired razors', 'LaserTurbine': 'thrown disc', 'NovaOnHeal': 'fired skull projectile', 'MeteorAttackOnHighDamage': 'meteor strikes'}
# existing ids of the 14 tested items -> RoR2 name, so they aren't added twice
OLD_SRC = {'Syringe':'Syringe','Glasses':'CritGlasses','Hoof':'Hoof','Bear':'Bear','Crowbar':'Crowbar','ArmorPlate':'ArmorPlate','Tooth':'Tooth',
           'Medkit':'Medkit','Ukulele':'ChainLightning','Wisp':'ExplodeOnDeath','Gasoline':'IgniteOnKill','Feather':'Feather','Infusion':'Infusion','Behemoth':'Behemoth'}
rows = []
for r in old['rows']:
    x = dict(DEF); x.update(r); x['src'] = OLD_SRC[r['id']]; x['tex'] = 'tex' + r['icon'] + 'Icon'
    if r['id'] == 'Crowbar':  # now faithful: bonus damage to healthy enemies
        x.update(kind='effect', trigger='hit', cond='v_hp_above', cv=.9, action='bonus', dmg=.75, dmg_per=.75, ge='', attr='', op='', k=0,
                 desc="+75% (+75% per stack) damage to enemies above 90% health.")
    rows.append(x)
icons = json.load(open(os.path.join(D, 'icon_names.json'))); texs = json.load(open(os.path.join(D, 'icon_textures.json')))
for name, spec in NEW.items():
    if name in SKIP: continue
    r = ror[name]
    x = dict(DEF); x.update({k: v for k, v in spec.items()})
    x.update(id=name, name=r['title'], rarity=TIER[r['tier']], icon=icons[name], tex=texs[name], pickup=r['pickup'], src=name)
    rows.append(x)
missing = [n for n in ror if n not in NEW and n not in SKIP and n not in OLD_SRC.values()]
assert not missing, missing
extra = sorted({k for r in rows for k in r} - set(COLS))
cols = COLS + extra
for r in rows:
    for c in cols: r.setdefault(c, DEF.get(c, 0 if c not in ('sub','refresh','once') else ''))
json.dump({'columns': cols, 'rows': rows, 'skipped': SKIP}, open(os.path.join(S, 'items.json'), 'w'), indent=1)
print(len(rows), 'items;', 'extra cols', extra, '; skipped', list(SKIP))
