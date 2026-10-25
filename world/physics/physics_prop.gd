## A Source-style prop_physics: pushable rigid body with a surface material, optional
## health (breaks into debris), impact damage to the player, and physics LOD (frozen when
## far from the player so thousands of props cost nothing).
class_name PhysicsProp
extends RigidBody3D

signal broken

## Terrain collision only exists within 64 m of the player, so props freeze before that
## edge (and wake inside it) instead of falling through the ground.
const FREEZE_DISTANCE := 56.0
const WAKE_DISTANCE := 48.0
const HARD_FREEZE_DISTANCE := 60.0  ## freeze even while still moving
## Source's impact damage table for players (m/s of impact -> damage), from u/s.
const IMPACT_TABLE := [[3.8, 5.0], [6.35, 10.0], [11.4, 20.0], [14.0, 50.0], [17.8, 100.0]]

var health := 0.0        ## 0 = unbreakable
var surface := "default"
var lod_frozen := false
var _last_speed := 0.0


func _ready() -> void:
	if health > 0.0 or mass >= 2.0:
		contact_monitor = true
		max_contacts_reported = 2
		body_entered.connect(_on_body_entered)


func _physics_process(_dt: float) -> void:
	_last_speed = linear_velocity.length()


## Physics LOD: called periodically by the world with the distance to the player.
func update_lod(dist: float) -> void:
	if not lod_frozen and dist > FREEZE_DISTANCE and (sleeping or dist > HARD_FREEZE_DISTANCE):
		lod_frozen = true
		freeze = true
	elif lod_frozen and dist < WAKE_DISTANCE:
		lod_frozen = false
		freeze = false


func _on_body_entered(other: Node) -> void:
	var speed := _last_speed
	if speed < 0.6:
		return
	if other is PlayerController and mass >= 2.0:
		var dmg := 0.0
		for row in IMPACT_TABLE:
			if speed >= row[0]:
				dmg = row[1]
		if mass < 5.0:
			dmg = minf(dmg, 5.0)
		if dmg > 0.0:
			(other as PlayerController).take_damage(dmg, "impact")
	if health > 0.0 and speed > 6.0:
		take_damage(speed * mass * 0.05)


func take_damage(amount: float, impulse := Vector3.ZERO, at := Vector3.ZERO) -> void:
	if impulse != Vector3.ZERO:
		apply_impulse(impulse, at - global_position)
	if health <= 0.0:
		return
	health -= amount
	if health <= 0.0:
		_break()


## Breaks into a few debris pieces (world-only collision) that fade after a while.
func _break() -> void:
	var parent := get_parent()
	var box := _size()
	for i in 6:
		var gib := RigidBody3D.new()
		gib.mass = maxf(0.5, mass / 8.0)
		gib.collision_layer = PhysicsLayers.DEBRIS
		gib.collision_mask = PhysicsLayers.DEBRIS_MASK
		gib.continuous_cd = true
		gib.physics_material_override = physics_material_override
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = box * 0.35
		cs.shape = sh
		gib.add_child(cs)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sh.size
		mi.mesh = bm
		gib.add_child(mi)
		parent.add_child(gib)
		gib.global_position = global_position + Vector3(randf_range(-0.3, 0.3), box.y * 0.5 + randf_range(0, 0.3), randf_range(-0.3, 0.3))
		gib.linear_velocity = linear_velocity + Vector3(randf_range(-2, 2), randf_range(1, 3), randf_range(-2, 2))
		get_tree().create_timer(8.0).timeout.connect(gib.queue_free)
	broken.emit()
	queue_free()


func _size() -> Vector3:
	for c in get_children():
		if c is CollisionShape3D and c.shape is BoxShape3D:
			return (c.shape as BoxShape3D).size
	return Vector3.ONE * 0.6
