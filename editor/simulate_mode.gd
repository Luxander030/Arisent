## The World Editor's Simulate mode (F5): runs the game's spawning and creature AI on the
## map being edited, without launching the game and without changing the map. A stand-in
## pawn gives creatures someone to notice. By default it stands on the ground under the
## middle of the screen (fly the camera to move it); F6 switches to driving it yourself
## (WASD, Space jump, Shift walk, Ctrl crouch; the camera follows, right mouse turns it). Editing is locked while it runs; stopping
## removes every creature, item and runtime overlay again. The debug console (` or F1)
## works here too.
class_name SimulateMode
extends Node

signal toggled(running: bool)

var editor: EditorMain
var game: GameSession
var session: WorldSession
var pawn: PlayerController
var active := false
var driving := false
var _channels_before := {}


func start() -> void:
	if active or editor.map == null or editor.world.terrain == null:
		return
	active = true
	var w := editor.world
	game = GameSession.new()
	game.ephemeral = true
	add_child(game)
	pawn = PlayerController.new()
	pawn.name = "SimulatePawn"
	pawn.invulnerable = true
	w.add_child(pawn)
	pawn.global_position = _ground_focus()
	_pawn_visual()
	w.terrain.set_focus(pawn, 64.0)
	session = WorldSession.attach(w, game, pawn)
	session.teleport = func(p: Vector3) -> void:
		editor.camera.look_from(p + Vector3(0, 60, 80), p)
	for ch in DebugDraw.CHANNELS:
		_channels_before[ch] = w.debug.is_on(ch)
	w.debug.set_channel("ai", true)
	toggled.emit(true)


func stop() -> void:
	if not active:
		return
	set_driving(false)
	active = false
	var w := editor.world
	session.detach()
	session = null
	game.queue_free()
	game = null
	pawn.queue_free()
	pawn = null
	w.terrain.set_focus(editor.camera, 96.0)
	w.set_time_of_day(10.0)  # the editor works in daylight
	for ch: String in _channels_before:
		w.debug.set_channel(ch, bool(_channels_before[ch]))
	toggled.emit(false)


func toggle() -> void:
	if active:
		stop()
	else:
		start()


## F6: drive the pawn yourself, or let it follow the middle of the screen again.
func set_driving(on: bool) -> void:
	if on and not active:
		start()
	if not active:
		return
	driving = on
	editor.camera.follow = pawn if on else null
	editor.camera.ground_height = func(p: Vector3) -> float: return editor.world.terrain.get_height(p)
	if on:
		editor.camera.look_from(pawn.global_position + Vector3(0, 4, 9), pawn.global_position + Vector3.UP * 1.6)
	editor.toast("Driving the pawn: WASD, Space jump, Shift walk, Ctrl crouch; right mouse turns the view; F6 stops driving." if on
		else "The pawn follows the middle of the screen again.")


func _physics_process(_delta: float) -> void:
	if not active or pawn == null:
		return
	if driving:
		var i := pawn.input
		if game.console.is_open:  # typing into the console must not drive the pawn
			i.move = Vector2.ZERO
			i.jump = false
			i.yaw = editor.camera.yaw()
			return
		var x := float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		var y := float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		i.move = Vector2(x, y).limit_length(1.0)
		i.jump = Input.is_physical_key_pressed(KEY_SPACE)
		i.walk = Input.is_physical_key_pressed(KEY_SHIFT)
		i.crouch = Input.is_physical_key_pressed(KEY_CTRL)
		i.yaw = editor.camera.yaw()
		return
	pawn.input.move = Vector2.ZERO
	var p := _ground_focus()
	if p != Vector3.INF and (p.distance_to(pawn.global_position) > 0.5 or not pawn.is_on_floor()):
		pawn.global_position = Vector3(p.x, editor.world.terrain.get_height(p) + 0.05, p.z)  # pinned to the ground
		pawn.velocity = Vector3.ZERO


## The ground under the middle of the screen (or below the camera when looking up).
func _ground_focus() -> Vector3:
	var cam := editor.camera
	var vp := cam.get_viewport().get_visible_rect().size
	var hit := editor.world.terrain.raycast(cam.project_ray_origin(vp * 0.5), cam.project_ray_normal(vp * 0.5))
	if hit == Vector3.INF:
		hit = cam.global_position
		hit.y = editor.world.terrain.get_height(hit)
	return hit + Vector3.UP * 0.05


func _pawn_visual() -> void:
	var v := Boxman.build_visual(Color(0.4, 0.75, 1.0))
	pawn.add_child(v)


func status_text() -> String:
	if not active:
		return ""
	var c := session.npcs.count_by_tier()
	return "SIMULATING (F5 stops, F6 %s, ` console) — %d creatures: %d active, %d near, %d far · %s" % [
		"stops driving" if driving else "drives the pawn", session.npcs.records.size(), c[0], c[1], c[2], game.time_of_day.label()]
