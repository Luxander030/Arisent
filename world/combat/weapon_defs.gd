## Weapon definitions, after CS:GO's weapon scripts (rounded). Damage is per bullet before
## range falloff (× range_modifier per 500 u travelled) and hitgroup multipliers.
## Penetration: how many "wall units" a bullet can punch through (see SurfaceProps).
class_name WeaponDefs
extends RefCounted

const WEAPONS := {
	"knife": {
		"name": "Knife", "slot": 3, "melee": true, "damage": 40.0, "range": 1.6, "fire_interval": 0.4,
		"move_speed": 250.0, "automatic": true,
	},
	"pistol": {
		"name": "Pistol", "slot": 2, "damage": 35.0, "range_modifier": 0.91, "penetration": 1.0,
		"fire_interval": 0.17, "magazine": 12, "reserve": 48, "reload_time": 2.2, "move_speed": 240.0,
		"spread": 0.004, "spread_move": 0.012, "spread_air": 0.06, "recoil": 0.012, "automatic": false,
		"range": 140.0,
	},
	"rifle": {
		"name": "Rifle", "slot": 1, "damage": 36.0, "range_modifier": 0.98, "penetration": 2.0,
		"fire_interval": 0.1, "magazine": 30, "reserve": 90, "reload_time": 2.5, "move_speed": 215.0,
		"spread": 0.002, "spread_move": 0.04, "spread_air": 0.12, "recoil": 0.018, "automatic": true,
		"range": 210.0,
	},
	"sniper": {
		"name": "Sniper", "slot": 4, "damage": 115.0, "range_modifier": 0.99, "penetration": 2.5,
		"fire_interval": 1.45, "magazine": 5, "reserve": 20, "reload_time": 3.6, "move_speed": 200.0,
		"spread": 0.0005, "spread_move": 0.08, "spread_air": 0.2, "recoil": 0.05, "automatic": false,
		"range": 210.0,
	},
}

## Bullet push on physics props / ragdolls per point of damage (Source: 75 kg × 4 in/s).
const IMPULSE_PER_DAMAGE := 75.0 * 4.0 * MovementSettings.U * 0.5


static func get_def(id: String) -> Dictionary:
	return WEAPONS.get(id, {})
