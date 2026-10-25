## Placeholder humanoid made of capsules ("box-man"), 1.8 m tall, origin at the feet.
## The same part list drives the visual model, the hitboxes (CS hitgroups) and the ragdoll.
class_name Boxman
extends RefCounted

## name -> [radius, length, centre (standing pose), axis ("y" or "x"), hitgroup, mass kg, parent]
const PARTS := {
	"pelvis": [0.16, 0.18, Vector3(0, 0.98, 0), "x", "stomach", 12.0, ""],
	"chest": [0.18, 0.34, Vector3(0, 1.28, 0), "y", "chest", 22.0, "pelvis"],
	"head": [0.12, 0.08, Vector3(0, 1.66, 0), "y", "head", 5.0, "chest"],
	"upper_arm_l": [0.06, 0.26, Vector3(-0.26, 1.33, 0), "y", "arm", 2.5, "chest"],
	"lower_arm_l": [0.05, 0.26, Vector3(-0.26, 1.04, 0), "y", "arm", 2.0, "upper_arm_l"],
	"upper_arm_r": [0.06, 0.26, Vector3(0.26, 1.33, 0), "y", "arm", 2.5, "chest"],
	"lower_arm_r": [0.05, 0.26, Vector3(0.26, 1.04, 0), "y", "arm", 2.0, "upper_arm_r"],
	"thigh_l": [0.08, 0.36, Vector3(-0.1, 0.66, 0), "y", "leg", 8.0, "pelvis"],
	"shin_l": [0.065, 0.36, Vector3(-0.1, 0.24, 0), "y", "leg", 4.0, "thigh_l"],
	"thigh_r": [0.08, 0.36, Vector3(0.1, 0.66, 0), "y", "leg", 8.0, "pelvis"],
	"shin_r": [0.065, 0.36, Vector3(0.1, 0.24, 0), "y", "leg", 4.0, "thigh_r"],
}

## CS:GO hitgroup damage multipliers.
const HITGROUP_MULT := {"head": 4.0, "chest": 1.0, "stomach": 1.25, "arm": 1.0, "leg": 0.75}

static var _meshes := {}


static func part_basis(name: String) -> Basis:
	return Basis(Vector3.FORWARD, PI * 0.5) if PARTS[name][3] == "x" else Basis()


static func part_mesh(name: String, color: Color) -> Mesh:
	var key := "%s_%s" % [name, color.to_html()]
	if _meshes.has(key):
		return _meshes[key]
	var p: Array = PARTS[name]
	var m := CapsuleMesh.new()
	m.radius = p[0]
	m.height = p[1] + p[0] * 2.0
	m.radial_segments = 10
	m.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.2) if name == "head" else color
	mat.roughness = 0.8
	m.material = mat
	_meshes[key] = m
	return m


static func part_shape(name: String) -> CapsuleShape3D:
	var p: Array = PARTS[name]
	var c := CapsuleShape3D.new()
	c.radius = p[0]
	c.height = p[1] + p[0] * 2.0
	return c


## Visual model (one MeshInstance3D per part) under a new Node3D.
static func build_visual(color: Color) -> Node3D:
	var root := Node3D.new()
	for name: String in PARTS:
		var mi := MeshInstance3D.new()
		mi.name = name
		mi.mesh = part_mesh(name, color)
		mi.transform = Transform3D(part_basis(name), PARTS[name][2])
		root.add_child(mi)
	return root


## Hitboxes: one Area3D per part on the HITBOX layer, meta "hitgroup" and "owner_node".
static func build_hitboxes(owner_node: Node, parent: Node3D) -> void:
	for name: String in PARTS:
		var a := Area3D.new()
		a.name = "Hit_" + name
		a.collision_layer = PhysicsLayers.HITBOX
		a.collision_mask = 0
		a.monitoring = false
		a.set_meta("hitgroup", PARTS[name][4])
		a.set_meta("owner_node", owner_node)
		var cs := CollisionShape3D.new()
		cs.shape = part_shape(name)
		a.add_child(cs)
		a.transform = Transform3D(part_basis(name), PARTS[name][2])
		parent.add_child(a)
