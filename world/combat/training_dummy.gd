## A target to shoot: box-man with CS hitboxes (head ×4, stomach ×1.25, legs ×0.75), takes
## damage, falls as a ragdoll when killed and stands up again after a while.
class_name TrainingDummy
extends StaticBody3D

signal killed

const COLOR := Color(0.75, 0.55, 0.35)

var max_health := 100.0
var health := 100.0
var respawn_time := 6.0
var active := true  ## false in the editor (no damage)
var _visual: Node3D
var _hitboxes: Node3D


func _ready() -> void:
	collision_layer = PhysicsLayers.NPC | PhysicsLayers.EDITOR_PICK
	set_meta("surface", "flesh")
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 1.8
	cs.shape = cyl
	cs.position.y = 0.9
	add_child(cs)
	_visual = Boxman.build_visual(COLOR)
	add_child(_visual)
	_hitboxes = Node3D.new()
	_hitboxes.name = "Hitboxes"
	add_child(_hitboxes)
	Boxman.build_hitboxes(self, _hitboxes)
	health = max_health


## Weapons call this with the damage (hitgroup multiplier already applied).
func apply_hit(damage: float, impulse: Vector3, at: Vector3, hitgroup := "") -> void:
	if not active or health <= 0.0:
		return
	health -= damage
	if health <= 0.0:
		_die(impulse, at, hitgroup)


func _die(impulse: Vector3, at: Vector3, hitgroup: String) -> void:
	var part: String = {"head": "head", "chest": "chest", "stomach": "pelvis", "arm": "upper_arm_r", "leg": "thigh_l"}.get(hitgroup, "chest")
	Ragdoll.spawn(get_parent(), global_transform, COLOR, Vector3.ZERO, part, impulse * 3.0, at)
	_set_alive(false)
	killed.emit()
	await get_tree().create_timer(respawn_time).timeout
	if is_instance_valid(self):
		health = max_health
		_set_alive(true)


func _set_alive(alive: bool) -> void:
	_visual.visible = alive
	for c in _hitboxes.get_children():
		(c as Area3D).collision_layer = PhysicsLayers.HITBOX if alive else 0
	collision_layer = (PhysicsLayers.NPC | PhysicsLayers.EDITOR_PICK) if alive else PhysicsLayers.EDITOR_PICK
