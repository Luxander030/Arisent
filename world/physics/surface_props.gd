## Surface materials after Source's surfaceproperties.txt: friction, bounce (elasticity)
## and density (kg/m³, used for prop mass from volume). One shared PhysicsMaterial each.
class_name SurfaceProps
extends RefCounted

## name -> [friction, bounce, density, bullet resistance]
## Resistance: how hard a bullet finds it to go through (higher = thinner walls stop it);
## a weapon with penetration P goes through up to P × 0.1 m / resistance of it.
const TABLE := {
	"default": [0.8, 0.25, 2000.0, 1.5],
	"concrete": [0.8, 0.2, 2400.0, 3.0],
	"rock": [0.8, 0.2, 2400.0, 3.5],
	"metal": [0.8, 0.25, 2700.0, 2.0],
	"solidmetal": [0.8, 0.1, 2700.0, 4.0],
	"wood": [0.8, 0.1, 700.0, 0.6],
	"dirt": [0.8, 0.01, 1600.0, 2.5],
	"grass": [0.8, 0.01, 1600.0, 2.5],
	"gravel": [0.4, 0.2, 2400.0, 2.5],
	"glass": [0.5, 0.2, 2700.0, 0.3],
	"ice": [0.1, 0.1, 917.0, 1.2],
	"flesh": [0.8, 0.25, 900.0, 1.0],
	"cardboard": [0.8, 0.01, 500.0, 0.2],
	"rubber": [0.8, 0.4, 1100.0, 1.0],
}

static var _materials := {}


static func material(name: String) -> PhysicsMaterial:
	if not _materials.has(name):
		var row: Array = TABLE.get(name, TABLE["default"])
		var m := PhysicsMaterial.new()
		m.friction = row[0]
		m.bounce = row[1]
		_materials[name] = m
	return _materials[name]


static func density(name: String) -> float:
	return float(TABLE.get(name, TABLE["default"])[2])


static func bullet_resistance(name: String) -> float:
	return float(TABLE.get(name, TABLE["default"])[3])


## Surface of whatever a trace hit: bodies may carry meta "surface"; the world defaults.
static func of(collider: Object) -> String:
	if collider == null:
		return "default"
	if collider.has_meta("surface"):
		return str(collider.get_meta("surface"))
	if collider is PhysicsProp:
		return (collider as PhysicsProp).surface
	return "concrete" if collider is StaticBody3D else "dirt"
