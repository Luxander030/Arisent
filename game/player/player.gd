## The playable character: PlayerController (Counter-Strike-style movement) + the animated
## player model (assets/models/main-character; RPG-style: it turns to run the way you steer
## and faces the camera's aim only while aiming (right mouse) or just after an attack;
## PlayerAnimator picks its clips) + the orbit camera + weapons (held
## in the model's right hand) + picking up props (E; left click throws). Plays its death
## animation when killed.
class_name Player
extends PlayerController

const MODEL := preload("res://assets/models/main-character/demo.glb")
const MODEL_HEIGHT := 1.8
const RIGHT_HAND := "bone_23"   ## the model's right hand (see tools/rig/bake_player_animations.gd)
const HAND_FINGER := "bone_24"  ## a finger of that hand: the hand points at it
const TURN_RATE := 12.0         ## how fast the model turns toward where you steer (1/s)
const AIM_TURN_RATE := 20.0     ## … and toward the aim
const AIM_HOLD := 0.8           ## seconds the model keeps facing the aim after an attack

var cam: OrbitCamera
var visual: Node3D
var weapons: WeaponHolder
var carrier: PropCarrier
var animator: PlayerAnimator
var _visual_yaw := 0.0
## Facing the camera's aim (aim held, or an attack moments ago) instead of the way of travel.
var aiming := false
var _aim_left := 0.0
var _use_held := false
## False while a text field (the debug console) or a menu has the keyboard.
var input_enabled := true
## The world the player is in (interaction, queries); set by the game host.
var session: WorldSession
## What "use" would do right now ({} = nothing; carrying/props are the fallback).
var use_target := {}
var _fire_held := false
## Console /noclip: fly through everything (WASD along the view, Space up, Ctrl down,
## Shift fast).
var noclip := false:
	set(v):
		noclip = v
		if _shape_node:
			_shape_node.disabled = v
		velocity = Vector3.ZERO


func _ready() -> void:
	super._ready()
	InputSetup.ensure()
	visual = Node3D.new()
	visual.name = "Visual"
	# Placed by hand every frame at the body's *interpolated* position (see _process): the
	# body moves at 64 Hz, frames come at ~60, and a child turned in _process loses
	# physics interpolation — it then drew at the raw tick position while the camera
	# followed the smooth one, a sawtooth that showed as stutter when strafing (A/D).
	visual.top_level = true
	visual.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(visual)
	var model: Node3D = MODEL.instantiate()
	model.name = "Model"
	visual.add_child(model)
	var aabb := _aabb(model)
	var k := 1.0
	if aabb.size.y > 0.01:
		k = MODEL_HEIGHT / aabb.size.y
		model.scale = Vector3.ONE * k
		model.position = Vector3(0, -aabb.position.y * k, 0)
	animator = PlayerAnimator.new()
	animator.name = "Animator"
	add_child(animator)
	animator.setup(self, model)
	cam = OrbitCamera.new()
	cam.name = "OrbitCamera"
	cam.target = self
	add_child(cam)
	carrier = PropCarrier.new(self)
	weapons = WeaponHolder.new()
	weapons.name = "Weapons"
	weapons.player = self
	_hold_in_right_hand(model, k)
	weapons.fired.connect(animator.on_fired)
	weapons.fired.connect(func(_w: String) -> void: _aim_left = AIM_HOLD)
	damaged.connect(func(_amount: float, _cause: String) -> void: animator.play_once("Hit_Chest"))
	died.connect(_on_died)


func _physics_process(dt: float) -> void:
	Perf.begin(&"player_tick")
	_physics_process_body(dt)
	Perf.end(&"player_tick")


func _physics_process_body(dt: float) -> void:
	var on := input_enabled
	if noclip:
		_fly(dt, on)
		return
	input.move = Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_back", "move_forward")) if on else Vector2.ZERO
	input.jump = on and Input.is_action_pressed("jump")
	input.crouch = on and Input.is_action_pressed("crouch")
	input.walk = on and Input.is_action_pressed("walk")
	input.yaw = cam.yaw
	input.pitch = cam.pitch
	_aim_left = maxf(0.0, _aim_left - dt)
	aiming = health > 0.0 and ((on and Input.is_action_pressed("aim")) or _aim_left > 0.0)
	if health <= 0.0:
		input.move = Vector2.ZERO
		input.jump = false
	super._physics_process(dt)
	if health <= 0.0:
		return
	# Third-person camera: pick up and hold from the character's eyes, aimed where the camera looks.
	var eye := global_position + Vector3.UP * eye_height()
	var fwd := -cam.camera.global_basis.z
	var use := on and Input.is_action_pressed("use")
	var fire := on and Input.is_action_pressed("fire") and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	use_target = session.interaction.best(global_position, fwd) if session and not carrier.held else {}
	if use and not _use_held:
		if carrier.held:
			carrier.drop()
		elif not use_target.is_empty():
			(use_target.act as Callable).call()
			animator.play_once("Interact")
		else:
			carrier.try_pick(get_world_3d().direct_space_state, eye, fwd)
	if carrier.held:
		carrier.update(eye, fwd, dt)
		if fire and not _fire_held:
			carrier.drop(fwd)
	else:
		weapons.tick(dt, fire)
	carried_body = carrier.held
	_use_held = use
	_fire_held = fire


func _fly(dt: float, on: bool) -> void:
	var b := cam.camera.global_basis
	var mv := Vector3.ZERO
	if on:
		var ax := Vector2(Input.get_axis("move_left", "move_right"), Input.get_axis("move_back", "move_forward"))
		mv = b.x * ax.x - b.z * ax.y
		mv.y += (1.0 if Input.is_action_pressed("jump") else 0.0) - (1.0 if Input.is_action_pressed("crouch") else 0.0)
	var speed := 60.0 if on and Input.is_action_pressed("walk") else 15.0
	velocity = mv.normalized() * speed if mv.length() > 0.01 else Vector3.ZERO
	global_position += velocity * dt
	on_ground = false


func _process(delta: float) -> void:
	Perf.begin(&"player")
	_process_body(delta)
	Perf.end(&"player")


func _process_body(delta: float) -> void:
	# RPG-style facing: the model turns and runs the way you steer (A/D/S turn it, rather than
	# sliding it sideways, which read as broken) and faces the aim only while aiming.
	var want := _facing_target()
	if not is_nan(want):
		var rate := AIM_TURN_RATE if aiming else TURN_RATE
		_visual_yaw = lerp_angle(_visual_yaw, want, 1.0 - exp(-rate * delta))
	var at := get_global_transform_interpolated().origin + Vector3.UP * visual_step_offset
	visual.global_transform = Transform3D(Basis(Vector3.UP, _visual_yaw), at)


## The yaw the model turns toward this frame (NAN: keep the current one). The model faces +Z.
func _facing_target() -> float:
	if health <= 0.0:
		return NAN
	if aiming:
		return cam.yaw + PI
	if on_ladder and ladder_normal != Vector3.ZERO:
		return atan2(-ladder_normal.x, -ladder_normal.z)
	var steer: Vector3 = _wish(false)[0] if input_enabled and not noclip else Vector3.ZERO
	if steer.length_squared() > 0.01:
		return atan2(steer.x, steer.z)
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() > 1.0 and not noclip:
		return atan2(flat.x, flat.y)  # sliding or pushed with no keys held
	return NAN


## Guns sit in the model's right hand (a BoneAttachment3D), barrel along the hand, so they
## follow the animations. The model is scaled to MODEL_HEIGHT; the gun is not.
func _hold_in_right_hand(model: Node3D, model_scale: float) -> void:
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var hand := BoneAttachment3D.new()
	hand.name = "RightHand"
	hand.bone_name = RIGHT_HAND
	sk.add_child(hand)
	# Barrel (-Z of the gun) along hand → finger, up = the model's up, in the hand's rest frame.
	var hand_rest := sk.get_bone_global_rest(sk.find_bone(RIGHT_HAND))
	var along := (sk.get_bone_global_rest(sk.find_bone(HAND_FINGER)).origin - hand_rest.origin).normalized()
	var aim := Basis.looking_at(hand_rest.basis.inverse() * along, hand_rest.basis.inverse() * Vector3.UP)
	weapons.transform = Transform3D(aim.scaled(Vector3.ONE / model_scale), Vector3.ZERO)
	hand.add_child(weapons)


func _on_died() -> void:
	carrier.drop()
	animator.on_died()


## Called by the game when respawning.
func revive(at: Vector3) -> void:
	health = 100.0
	stamina = 0.0
	velocity = Vector3.ZERO
	global_position = at
	reset_physics_interpolation()
	visual.visible = true
	animator.on_revived()


## Bounds of all meshes under `n`, in n's own space.
static func _aabb(n: Node, xf := Transform3D(), acc: Array = []) -> AABB:
	for c in n.get_children():
		var cxf := xf * (c as Node3D).transform if c is Node3D else xf
		if c is MeshInstance3D:
			var a: AABB = cxf * (c as MeshInstance3D).mesh.get_aabb()
			acc.append(a)
		_aabb(c, cxf, acc)
	if acc.is_empty():
		return AABB()
	var out: AABB = acc[0]
	for a: AABB in acc:
		out = out.merge(a)
	return out
