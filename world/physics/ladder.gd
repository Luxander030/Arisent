## A climbable ladder: generated rails + rungs, solid back panel so you don't walk through
## it, and a climb volume (TRIGGER area with meta "ladder_normal") reaching a little above
## the top so climbers get lifted over the edge. Local -Z is the side you climb from.
class_name Ladder
extends StaticBody3D

const WIDTH := 0.6
const DEPTH := 0.08

var height := 4.0


func _ready() -> void:
	collision_layer = PhysicsLayers.WORLD | PhysicsLayers.EDITOR_PICK
	set_meta("surface", "wood")
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.55, 0.38, 0.22)
	wood.roughness = 0.9
	for side in [-1.0, 1.0]:
		_bar(Vector3(side * WIDTH * 0.5, height * 0.5, 0), Vector3(0.06, height, 0.06), wood)
	var rungs := int(height / 0.3)
	for i in rungs:
		_bar(Vector3(0, 0.25 + i * 0.3, 0), Vector3(WIDTH, 0.04, 0.04), wood)
	# Solid behind the rungs (the wall side).
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(WIDTH + 0.1, height, DEPTH)
	cs.shape = box
	cs.position = Vector3(0, height * 0.5, DEPTH)
	add_child(cs)
	var area := Area3D.new()
	area.name = "Climb"
	area.collision_layer = PhysicsLayers.TRIGGER
	area.collision_mask = 0
	area.monitoring = false
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(WIDTH + 0.2, height + 0.8, 0.5)
	acs.shape = abox
	acs.position = Vector3(0, (height + 0.8) * 0.5, -0.2)
	area.add_child(acs)
	add_child(area)
	area.set_meta("ladder", true)  # climb direction = the area's -Z, read when touched


func _bar(pos: Vector3, size: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	add_child(mi)
