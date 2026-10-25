## Editor camera: hold right mouse to look around, WASD/QE to fly, wheel changes speed
## while flying (or dollies forward/back otherwise), Shift = fast.
## Follow mode (Simulate → drive the pawn): stays behind `follow`; right mouse still turns
## the view, the wheel changes the distance, WASD is left to the pawn.
class_name FlyCamera
extends Camera3D

signal moved

var speed := 80.0
var looking := false
var _yaw := 0.0
var _pitch := -0.5
var follow: Node3D
var follow_distance := 9.0
## Ground height at a position (set with `follow`), so the camera never dips under terrain.
var ground_height: Callable


func _ready() -> void:
	far = 16000.0
	near = 0.25
	fov = 65.0


func look_from(pos: Vector3, target: Vector3) -> void:
	position = pos
	var d := (target - pos).normalized()
	_yaw = atan2(-d.x, -d.z)
	_pitch = asin(clampf(d.y, -1.0, 1.0))
	_apply_rotation()
	moved.emit()


func _apply_rotation() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			looking = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if looking else Input.MOUSE_MODE_VISIBLE
			return true
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			if follow:
				follow_distance = clampf(follow_distance * (0.85 if up else 1.18), 3.0, 60.0)
			elif looking:
				speed = clampf(speed * (1.25 if up else 0.8), 5.0, 3000.0)
			else:
				position += -global_basis.z * speed * 0.6 * (1.0 if up else -1.0)
				moved.emit()
			return true
	elif event is InputEventMouseMotion and looking:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.0035
		_pitch = clampf(_pitch - mm.relative.y * 0.0035, -1.55, 1.55)
		_apply_rotation()
		return true
	return false


## Yaw of the view (the driven pawn walks relative to it).
func yaw() -> float:
	return _yaw


func _process(delta: float) -> void:
	if follow and is_instance_valid(follow):
		var target := follow.global_position + Vector3.UP * 1.6
		var p := target + global_basis.z * follow_distance
		if ground_height.is_valid():
			p.y = maxf(p.y, float(ground_height.call(p)) + 1.0)
		position = p
		look_at(target)  # keep the pawn centred even when the camera is lifted over a slope
		_pitch = rotation.x
		_yaw = rotation.y
		moved.emit()
		return
	if not looking:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir -= global_basis.z
	if Input.is_key_pressed(KEY_S): dir += global_basis.z
	if Input.is_key_pressed(KEY_A): dir -= global_basis.x
	if Input.is_key_pressed(KEY_D): dir += global_basis.x
	if Input.is_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_key_pressed(KEY_Q): dir -= Vector3.UP
	if dir != Vector3.ZERO:
		var fast := 4.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		position += dir.normalized() * speed * fast * delta
		moved.emit()
