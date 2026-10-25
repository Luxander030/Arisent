extends TestCase
## Movement maths (pure) and the controller on a physics test course (Jolt, headless).

const U := MovementSettings.U
const DT := 1.0 / 64.0

var s := MovementSettings.new()


# --- maths -------------------------------------------------------------------------

func test_ground_accel_reaches_run_speed() -> void:
	var v := Vector3.ZERO
	var t := 0.0
	while v.length() < s.m(s.max_speed) * 0.99 and t < 3.0:
		v = SourceMovement.friction(v, s, DT)
		v = SourceMovement.accelerate(v, Vector3.FORWARD, s.m(s.max_speed), s.accelerate, DT)
		t += DT
	check(t < 1.2, "reaches run speed in %.2f s" % t)
	check(v.length() <= s.m(s.max_speed) + 0.001, "never exceeds run speed on the ground")

func test_friction_stops_in_about_half_a_second() -> void:
	var v := Vector3(s.m(s.max_speed), 0, 0)
	var t := 0.0
	while v.length() > 0.0 and t < 3.0:
		v = SourceMovement.friction(v, s, DT)
		t += DT
	check(t > 0.3 and t < 0.6, "stops in %.2f s" % t)

func test_air_strafe_gains_speed_but_straight_air_does_not() -> void:
	var v := Vector3(0, 0, -s.m(s.max_speed))
	var straight := SourceMovement.air_accelerate(v, Vector3.FORWARD, s.m(s.max_speed), s, DT)
	check(straight.length() <= v.length() + 0.0001, "pressing forward in the air adds nothing at speed")
	# Strafe: wish direction stays ~90° to velocity while turning.
	for i in 64:
		var side := v.normalized().cross(Vector3.UP)
		v = SourceMovement.air_accelerate(v, side, s.m(s.max_speed), s, DT)
	check(v.length() > s.m(s.max_speed) * 1.2, "air strafing builds speed (%.2f m/s)" % v.length())

func test_clip_velocity_slides_along_wall() -> void:
	var v := SourceMovement.clip_velocity(Vector3(1, 0, -1), Vector3(0, 0, 1))
	check(absf(v.z) < 0.0001 and absf(v.x - 1.0) < 0.0001, "velocity into the wall removed")

func test_fall_damage_thresholds() -> void:
	eq(SourceMovement.fall_damage(sqrt(2.0 * s.m(s.gravity) * 4.0), s), 0.0, "4 m fall is safe")
	var d10 := SourceMovement.fall_damage(sqrt(2.0 * s.m(s.gravity) * 10.0), s)
	check(d10 > 30.0 and d10 < 70.0, "10 m fall hurts (%.0f)" % d10)


# --- controller on a test course ------------------------------------------------------

var _root: Node3D

func _course() -> Node3D:
	_root = Node3D.new()
	Engine.get_main_loop().root.add_child(_root)
	_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))                     # floor
	# Stairs: 6 steps of 18 u, 0.6 m deep, going -Z from z = -5.
	for i in 6:
		var h := (i + 1) * 18.0 * U
		_box(Vector3(0, h * 0.5, -5.0 - 0.3 - i * 0.6), Vector3(3, h, 0.6))
	_box(Vector3(10, 0.25, -5.3), Vector3(3, 0.5, 0.6))                    # 0.5 m (19.7 u) step: too tall
	_ramp(Vector3(20, 0, -5), 44.0)
	_ramp(Vector3(30, 0, -5), 47.0)
	_box(Vector3(40, 0.85, -5.5), Vector3(3, 1.7, 1.0))                    # 1.7 m ledge
	_box(Vector3(60, 5.0, 0), Vector3(4, 10, 4))                           # tower for fall tests (top at 10 m)
	return _root

func _box(center: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	b.position = center
	_root.add_child(b)
	return b

func _ramp(foot: Vector3, deg: float) -> void:
	var b := _box(Vector3.ZERO, Vector3(3, 0.5, 30))
	b.rotation.x = deg_to_rad(deg)
	# Low end of the top surface at `foot`, rising toward -Z.
	b.position = foot + Vector3(0, 0, -15.0 * cos(deg_to_rad(deg))) + Vector3(0, 15.0 * sin(deg_to_rad(deg)), 0) \
		- Vector3(0, 0.25 * cos(deg_to_rad(deg)), 0.25 * sin(deg_to_rad(deg)))

func _player(at: Vector3) -> PlayerController:
	var p := PlayerController.new()
	_root.add_child(p)
	p.global_position = at
	return p

func _ticks(n: int) -> void:
	for i in n:
		await Engine.get_main_loop().physics_frame

func _cleanup() -> void:
	_root.queue_free()
	await _ticks(2)


func test_runs_and_stops() -> void:
	_course()
	var p := _player(Vector3(-20, 0.05, 20))
	await _ticks(10)
	p.input.move = Vector2(0, 1)
	await _ticks(64)
	var top := p.horizontal_speed()
	check(absf(top - s.m(s.max_speed)) < 0.15, "runs at %.2f m/s (CS 250 u/s = 6.35)" % top)
	p.input.move = Vector2.ZERO
	await _ticks(40)
	check(p.horizontal_speed() < 0.05, "stops within 0.6 s")
	await _cleanup()

func test_jump_height() -> void:
	_course()
	var p := _player(Vector3(-20, 0.05, 20))
	await _ticks(10)
	var y0 := p.global_position.y
	p.input.jump = true
	var apex := y0
	for i in 80:
		await _ticks(1)
		apex = maxf(apex, p.global_position.y)
	var h := apex - y0
	check(absf(h - 57.0 * U) < 0.06, "jumps %.2f m (CS 57 u = 1.45 m)" % h)
	await _cleanup()

func test_climbs_stairs_but_not_tall_step() -> void:
	_course()
	var p := _player(Vector3(0, 0.05, -2))
	var q := _player(Vector3(10, 0.05, -2))
	await _ticks(10)
	p.input.move = Vector2(0, 1)
	q.input.move = Vector2(0, 1)
	var top := 0.0
	for i in 160:
		await _ticks(1)
		top = maxf(top, p.global_position.y)
	check(top > 6 * 18.0 * U - 0.05, "climbed 18 u stairs to %.2f m" % top)
	check(q.global_position.y < 0.1, "0.5 m step blocks (y %.2f)" % q.global_position.y)
	await _cleanup()

func test_slope_limit() -> void:
	_course()
	var walk := _player(Vector3(20, 0.05, -3))
	var steep := _player(Vector3(30, 0.05, -3))
	await _ticks(10)
	walk.input.move = Vector2(0, 1)
	steep.input.move = Vector2(0, 1)
	await _ticks(128)
	check(walk.global_position.y > 2.0, "walks up a 44° ramp (y %.2f)" % walk.global_position.y)
	check(steep.global_position.y < 0.6, "can't walk up a 47° ramp (y %.2f)" % steep.global_position.y)
	await _cleanup()

func test_crouch_jump_reaches_higher_ledge() -> void:
	_course()
	var a := _player(Vector3(39, 0.05, 2))
	var b := _player(Vector3(41, 0.05, 2))
	await _ticks(10)
	for p in [a, b]:
		p.input.move = Vector2(0, 1)
	# Run up, jump ~1.3 m before the ledge face (z = -5); b holds crouch in the air.
	while a.global_position.z > -3.7:
		await _ticks(1)
	for p in [a, b]:
		p.input.jump = true
	await _ticks(6)
	b.input.crouch = true  # crouch-jump: tuck the legs up at the start of the jump
	await _ticks(64)
	check(a.global_position.y < 1.0, "plain jump can't reach a 1.7 m ledge (y %.2f)" % a.global_position.y)
	check(b.global_position.y > 1.6, "crouch-jump reaches it (y %.2f)" % b.global_position.y)
	await _cleanup()

func test_crouch_and_walk_speeds() -> void:
	_course()
	var c := _player(Vector3(-30, 0.05, 20))
	var w := _player(Vector3(-40, 0.05, 20))
	await _ticks(10)
	c.input.move = Vector2(0, 1)
	c.input.crouch = true
	w.input.move = Vector2(0, 1)
	w.input.walk = true
	# Source's maths: low wish speeds accelerate slowly against friction (~1.7 s to crouch speed).
	await _ticks(192)
	check(absf(c.horizontal_speed() - s.m(s.max_speed) * s.duck_scale) < 0.1, "crouch-walk %.2f m/s" % c.horizontal_speed())
	check(absf(w.horizontal_speed() - s.m(s.max_speed) * s.walk_scale) < 0.1, "shift-walk %.2f m/s" % w.horizontal_speed())
	await _cleanup()

func test_bunnyhop_is_capped_by_default() -> void:
	_course()
	var p := _player(Vector3(-20, 0.05, 40))
	await _ticks(10)
	p.velocity = Vector3(0, 0, -s.m(s.max_speed) * 1.6)  # arrive fast (e.g. from a strafe)
	p.input.jump = true
	await _ticks(2)
	check(p.horizontal_speed() <= 1.1 * s.m(s.max_speed) + 0.05, "jump caps speed to 1.1× run (%.2f)" % p.horizontal_speed())
	await _cleanup()

func test_fall_damage_from_tower() -> void:
	_course()
	var p := _player(Vector3(60, 10.05, 0))
	await _ticks(10)
	p.input.move = Vector2(0, 1)
	await _ticks(160)
	check(p.health < 100.0 and p.health > 0.0, "a 10 m fall hurts but doesn't kill (health %.0f)" % p.health)
	await _cleanup()

func test_pushes_light_crate_more_than_heavy() -> void:
	_course()
	var light := _crate(Vector3(-60, 0.4, 16), 10.0)
	var heavy := _crate(Vector3(-70, 0.4, 16), 400.0)
	var a := _player(Vector3(-60, 0.05, 20))
	var b := _player(Vector3(-70, 0.05, 20))
	await _ticks(10)
	a.input.move = Vector2(0, 1)
	b.input.move = Vector2(0, 1)
	await _ticks(128)
	var dl := light.global_position.distance_to(Vector3(-60, 0.4, 16))
	var dh := heavy.global_position.distance_to(Vector3(-70, 0.4, 16))
	check(dl > 2.0, "light crate pushed %.2f m" % dl)
	check(dh < dl * 0.5, "heavy crate moves much less (%.2f m)" % dh)
	await _cleanup()

func _crate(at: Vector3, mass: float) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.mass = mass
	b.collision_layer = PhysicsLayers.PROP
	b.collision_mask = PhysicsLayers.PROP_MASK
	b.physics_material_override = SurfaceProps.material("wood")
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.8, 0.8, 0.8)
	cs.shape = sh
	b.add_child(cs)
	b.position = at
	_root.add_child(b)
	return b

func test_swimming_floats_and_surfaces() -> void:
	_course()
	var p := _player(Vector3(-80, 0.05, -40))
	p.water_level_func = func(_q: Vector3) -> float: return 3.0
	await _ticks(10)
	check(p.swimming, "waist-deep in water = swimming")
	var y0 := p.global_position.y
	p.input.jump = true
	await _ticks(64)
	check(p.global_position.y > y0 + 1.0, "swims up (%.2f -> %.2f)" % [y0, p.global_position.y])
	await _cleanup()
