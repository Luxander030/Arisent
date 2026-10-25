## The player's weapons: knife, pistol, rifle, sniper (keys 1-4 / scroll). Left click
## fires (hitscan from the crosshair), R reloads. Spread grows when moving and is huge in
## the air (as in CS); recoil kicks the camera up. Placeholder gun models, tracers,
## impact marks, muzzle flash and synthesized sounds.
class_name WeaponHolder
extends Node3D

signal fired(weapon_id: String)

var player: Player
var current := "rifle"
var ammo := {}        ## id -> [in magazine, reserve]
var infinite_ammo := false   ## console /ammo infinite
var _cooldown := 0.0
var _reloading := 0.0
var _recoil := 0.0    ## accumulated kick (radians), decays
var _model: Node3D
var _was_firing := false


func _ready() -> void:
	for id: String in WeaponDefs.WEAPONS:
		var d := WeaponDefs.get_def(id)
		ammo[id] = [int(d.get("magazine", 0)), int(d.get("reserve", 0))]
	equip(current)


func equip(id: String) -> void:
	current = id
	_reloading = 0.0
	_cooldown = 0.3
	if _model:
		_model.queue_free()
	_model = _gun_model(id)
	add_child(_model)
	player.weapon_max_speed = float(WeaponDefs.get_def(id).move_speed)


func _unhandled_input(event: InputEvent) -> void:
	if not player.input_enabled:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: equip("rifle")
			KEY_2: equip("pistol")
			KEY_3: equip("knife")
			KEY_4: equip("sniper")
			KEY_R: reload()
	elif event is InputEventMouseButton and event.pressed:
		var order := ["rifle", "pistol", "knife", "sniper"]
		var i := order.find(current)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			equip(order[(i + 3) % 4])
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			equip(order[(i + 1) % 4])


func reload() -> void:
	var d := WeaponDefs.get_def(current)
	var a: Array = ammo[current]
	if d.get("melee", false) or a[0] >= int(d.magazine) or a[1] <= 0 or _reloading > 0.0:
		return
	_reloading = float(d.reload_time)
	SynthAudio.play_at(self, "reload", global_position, -6.0)


## Called by the player every physics tick with the fire button state.
func tick(dt: float, firing: bool) -> void:
	_cooldown -= dt
	_recoil = move_toward(_recoil, 0.0, dt * 0.25)
	var d := WeaponDefs.get_def(current)
	if _reloading > 0.0:
		_reloading -= dt
		if _reloading <= 0.0:
			var a: Array = ammo[current]
			var take := mini(int(d.magazine) - int(a[0]), int(a[1]))
			a[0] += take
			a[1] -= take
		return
	var trigger: bool = firing and (bool(d.get("automatic", false)) or not _was_firing)
	_was_firing = firing
	if trigger and _cooldown <= 0.0:
		fire()


func fire() -> void:
	var d := WeaponDefs.get_def(current)
	_cooldown = float(d.fire_interval)
	var cam := player.cam.camera
	var eye := cam.global_position
	var aim := -cam.global_basis.z
	var q := player.get_queries()
	var exclude: Array[RID] = [player.get_rid()]
	if d.get("melee", false):
		var origin := player.global_position + Vector3.UP * player.eye_height()
		var hits := Hitscan.fire(q, origin, Vector3(aim.x, aim.y * 0.5, aim.z).normalized(), d, exclude)
		SynthAudio.play_at(self, "knife", global_position)
		for h in hits:
			CombatFx.impact(_fx_parent(), h.position, h.normal, h.hitgroup != "")
		fired.emit(current)
		return
	var a: Array = ammo[current]
	if a[0] <= 0:
		SynthAudio.play_at(self, "empty", global_position, -4.0)
		reload()
		return
	if not infinite_ammo:
		a[0] -= 1
	# Spread: base + moving + airborne (CS's run-and-gun penalty), plus recoil.
	var speed_frac := clampf(player.horizontal_speed() / player.settings.m(player.settings.max_speed), 0.0, 1.0)
	var spread: float = d.spread + d.spread_move * speed_frac + (d.spread_air if not player.on_ground else 0.0)
	spread += _recoil * 0.5
	var dir := (aim + Vector3(randfn(0, spread), randfn(0, spread), randfn(0, spread))).normalized()
	# Trace from the camera so the crosshair is honest; skip anything between camera and player.
	var start := eye + aim * eye.distance_to(player.global_position + Vector3.UP * player.eye_height())
	var hits := Hitscan.fire(q, start, dir, d, exclude)
	var muzzle := _model.global_position + -global_basis.z * 0.4
	var end := start + dir * float(d.range)
	if not hits.is_empty():
		end = hits[-1].position
	CombatFx.tracer(_fx_parent(), muzzle, end)
	for h in hits:
		CombatFx.impact(_fx_parent(), h.position, h.normal, h.hitgroup != "")
	CombatFx.muzzle_flash(_model)
	SynthAudio.play_at(self, "shot_" + current, global_position, -2.0)
	_recoil += float(d.recoil)
	player.cam.pitch = minf(player.cam.pitch + float(d.recoil) * 0.6, 1.1)
	fired.emit(current)


func to_save() -> Dictionary:
	return {"current": current, "ammo": ammo.duplicate(true)}


func from_save(d: Dictionary) -> void:
	if d.is_empty():
		return
	for id: Variant in d.get("ammo", {}):
		if ammo.has(id):
			var a: Array = d.ammo[id]
			ammo[id] = [int(a[0]), int(a[1])]
	equip(str(d.get("current", current)))


func status_text() -> String:
	var d := WeaponDefs.get_def(current)
	if d.get("melee", false):
		return d.name
	var a: Array = ammo[current]
	return "%s  %d / %d%s" % [d.name, a[0], a[1], "  reloading…" if _reloading > 0.0 else ""]


## Placeholder gun: a few dark boxes (longer for rifles).
static func _gun_model(id: String) -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.13)
	mat.metallic = 0.6
	mat.roughness = 0.4
	var parts: Array = []
	match id:
		"knife": parts = [[Vector3(0, 0, -0.12), Vector3(0.02, 0.04, 0.22)], [Vector3(0, 0, 0.02), Vector3(0.03, 0.035, 0.1)]]
		"pistol": parts = [[Vector3(0, 0, -0.08), Vector3(0.035, 0.05, 0.2)], [Vector3(0, -0.07, 0.02), Vector3(0.03, 0.1, 0.05)]]
		"rifle": parts = [[Vector3(0, 0, -0.25), Vector3(0.05, 0.07, 0.75)], [Vector3(0, -0.08, -0.15), Vector3(0.035, 0.12, 0.06)],
			[Vector3(0, -0.02, 0.18), Vector3(0.05, 0.1, 0.22)]]
		"sniper": parts = [[Vector3(0, 0, -0.35), Vector3(0.05, 0.06, 1.0)], [Vector3(0, 0.07, -0.15), Vector3(0.045, 0.045, 0.3)],
			[Vector3(0, -0.02, 0.2), Vector3(0.05, 0.1, 0.25)]]
	for p in parts:
		var mi := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = p[1]
		b.material = mat
		mi.mesh = b
		mi.position = p[0]
		root.add_child(mi)
	return root


## Effects go in the running scene (or next to the player when there is none, e.g. tests).
func _fx_parent() -> Node:
	var scene := get_tree().current_scene
	return scene if scene else player.get_parent()
