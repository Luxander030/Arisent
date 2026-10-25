## A moving platform / lift (Source func_movelinear / prop_dynamic): an AnimatableBody3D
## that travels between its start and start + travel, waiting at each end. Players and
## props riding it are carried (it is on the DYNAMIC layer, which the player rides).
class_name MovingPlatform
extends AnimatableBody3D

var travel := Vector3(0, 4, 0)  ## metres from the start position
var speed := 2.0                ## m/s
var wait := 1.5                 ## seconds at each end
var size := Vector3(3, 0.3, 3)
var active := true              ## false in the editor

var _start := Vector3.ZERO
var _t := 0.0                   ## 0..1 along the path
var _dir := 1.0
var _wait_left := 0.0


func _ready() -> void:
	sync_to_physics = true
	collision_layer = PhysicsLayers.DYNAMIC | PhysicsLayers.EDITOR_PICK
	collision_mask = 0
	set_meta("surface", "metal")
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position.y = -size.y * 0.5
	add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.47, 0.52)
	mat.metallic = 0.5
	mat.roughness = 0.5
	bm.material = mat
	mi.mesh = bm
	mi.position.y = -size.y * 0.5
	add_child(mi)
	_start = global_position


func _physics_process(dt: float) -> void:
	if not active or travel.length() < 0.01:
		return
	if _wait_left > 0.0:
		_wait_left -= dt
		return
	_t += _dir * speed * dt / travel.length()
	if _t >= 1.0 or _t <= 0.0:
		_t = clampf(_t, 0.0, 1.0)
		_dir = -_dir
		_wait_left = wait
	global_position = _start + travel * _t
