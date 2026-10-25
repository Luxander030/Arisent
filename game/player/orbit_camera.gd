## Third-person camera: mouse (or right stick) turns it around the player; the player's
## movement is relative to where the camera looks, so CS-style air strafing works by
## holding A/D and turning the mouse. A spring arm keeps it out of walls.
class_name OrbitCamera
extends Node3D

@export var distance := 4.0
@export var height_offset := 0.35
@export var mouse_sensitivity := 0.0025
@export var stick_speed := 2.6

var target: PlayerController
var yaw := 0.0
var pitch := -0.25
var _arm: SpringArm3D
var camera: Camera3D


func _ready() -> void:
	top_level = true
	_arm = SpringArm3D.new()
	_arm.spring_length = distance
	_arm.margin = 0.2
	_arm.collision_mask = PhysicsLayers.WORLD | PhysicsLayers.DYNAMIC
	var probe := SphereShape3D.new()
	probe.radius = 0.25
	_arm.shape = probe
	add_child(_arm)
	camera = Camera3D.new()
	camera.far = 8000.0
	camera.fov = 70.0
	_arm.add_child(camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch = clampf(pitch - event.relative.y * mouse_sensitivity, -1.35, 1.1)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and (target == null or target.get("input_enabled") != false):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	Perf.begin(&"camera")
	_process_body(delta)
	Perf.end(&"camera")


func _process_body(delta: float) -> void:
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.15:
		yaw -= stick.x * stick_speed * delta
		pitch = clampf(pitch - stick.y * stick_speed * delta, -1.35, 1.1)
	if target == null:
		return
	# Follow the interpolated body (smooth at any frame rate) plus step smoothing.
	var feet := target.get_global_transform_interpolated().origin
	global_position = feet + Vector3.UP * (target.eye_height() + height_offset + target.visual_step_offset)
	rotation = Vector3(pitch, yaw, 0)
