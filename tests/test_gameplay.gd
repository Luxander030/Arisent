extends TestCase
## Ladders, +use pickup, hitscan weapons (falloff, hitgroups, penetration), ragdolls,
## moving platforms and pushaway clutter on a headless physics course (Jolt).

const U := MovementSettings.U

var _root: Node3D


func _course() -> Node3D:
	_root = Node3D.new()
	Engine.get_main_loop().root.add_child(_root)
	_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))  # floor
	return _root

func _box(center: Vector3, size: Vector3, surface := "") -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	b.position = center
	if surface != "":
		b.set_meta("surface", surface)
	_root.add_child(b)
	return b

func _prop(at: Vector3, mass: float, size: float, pushaway := false) -> RigidBody3D:
	var vis := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE * size
	vis.mesh = bm
	vis.position.y = size * 0.5
	var body := PropLibrary.make_body({"physics": {"mass": mass, "material": "wood", "pushaway": pushaway}}, vis, true)
	_root.add_child(body)
	body.global_position = at
	return body

func _player(at: Vector3) -> PlayerController:
	var p := PlayerController.new()
	_root.add_child(p)
	p.global_position = at
	return p

func _ticks(n: int) -> void:
	for i in n:
		await Engine.get_main_loop().physics_frame

func _space() -> PhysicsDirectSpaceState3D:
	return _root.get_world_3d().direct_space_state

func _cleanup() -> void:
	_root.queue_free()
	await _ticks(2)


# --- ladders ----------------------------------------------------------------------------

func _ladder_course() -> PlayerController:
	_course()
	# A 4 m wall with a ladder on its -Z face; the top of the wall is a platform to climb onto.
	_box(Vector3(0, 2.0, 1.0), Vector3(4, 4, 2))
	var l := Ladder.new()
	l.height = 4.0
	l.position = Vector3(0, 0, -0.05)
	_root.add_child(l)
	var p := _player(Vector3(0, 0.05, -1.0))
	p.input.yaw = PI  # facing +Z, toward the ladder
	return p

func test_ladder_climb_and_exit_at_top() -> void:
	var p := _ladder_course()
	await _ticks(10)
	p.input.move = Vector2(0, 1)
	var grabbed := false
	for i in 300:
		await _ticks(1)
		grabbed = grabbed or p.on_ladder
		if p.global_position.y > 3.95 and p.global_position.z > 0.1:
			break
	check(grabbed, "grabs the ladder when walking into it")
	check(p.global_position.y > 3.95, "climbed to the top (%.2f m)" % p.global_position.y)
	check(p.global_position.z > 0.1, "stepped off onto the top (z %.2f)" % p.global_position.z)
	await _ticks(30)
	check(not p.on_ladder and p.on_ground, "standing on top, off the ladder")
	await _cleanup()

func test_ladder_climb_speed_and_jump_off() -> void:
	var p := _ladder_course()
	await _ticks(10)
	p.input.move = Vector2(0, 1)
	for i in 40:
		await _ticks(1)
	check(p.on_ladder, "on the ladder")
	var y0 := p.global_position.y
	await _ticks(16)
	var rate := (p.global_position.y - y0) * 4.0
	check(absf(rate - 200.0 * U) < 0.6, "climbs at %.2f m/s (200 u/s = 5.08)" % rate)
	p.input.move = Vector2.ZERO
	p.input.jump = true
	await _ticks(2)
	p.input.jump = false
	check(not p.on_ladder, "jump lets go of the ladder")
	check(p.velocity.z < -2.0, "pushed away from the ladder (vz %.2f)" % p.velocity.z)
	await _cleanup()


# --- +use pickup --------------------------------------------------------------------------

func test_pickup_light_prop_not_heavy_and_throw() -> void:
	_course()
	var owner := _player(Vector3(0, 0.05, 0))
	var light := _prop(Vector3(0, 0, -1.5), 20.0, 0.4)
	var heavy := _prop(Vector3(4, 0, -1.5), 60.0, 0.4)
	await _ticks(20)
	check(PropCarrier.can_carry(light), "20 kg crate can be carried")
	check(not PropCarrier.can_carry(heavy), "60 kg crate is too heavy (limit 35 kg)")
	var c := PropCarrier.new(owner)
	var eye := owner.global_position + Vector3.UP * owner.eye_height()
	var aim := (light.global_position + Vector3.UP * 0.2 - eye).normalized()
	check(c.try_pick(_space(), eye, aim), "picks up the light crate it looks at")
	for i in 60:
		c.update(eye, Vector3.FORWARD, 1.0 / 64.0)
		await _ticks(1)
	var held_at := light.global_position
	check(held_at.y > 1.0 and absf(held_at.z - (eye.z - 1.6)) < 0.4, "held in front of the eyes (%s)" % str(held_at))
	c.drop(Vector3.FORWARD)
	check(c.held == null, "dropped")
	await _ticks(20)
	check(light.global_position.z < held_at.z - 2.0, "thrown forward (z %.2f)" % light.global_position.z)
	var eye2 := owner.global_position + Vector3(4, owner.eye_height(), 0)
	check(not c.try_pick(_space(), eye2, (heavy.global_position + Vector3.UP * 0.2 - eye2).normalized()), "can't pick the heavy crate")
	await _cleanup()


# --- hitscan --------------------------------------------------------------------------------

func test_range_falloff() -> void:
	_course()
	var near := _box(Vector3(0, 1, -5), Vector3(4, 2, 0.4), "concrete")
	var far := _box(Vector3(10, 1, -100), Vector3(4, 2, 0.4), "concrete")
	await _ticks(2)
	var d := WeaponDefs.get_def("pistol")
	var h1 := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 1, 0), Vector3.FORWARD, d)
	var h2 := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(10, 1, 0), Vector3.FORWARD, d)
	check(h1.size() > 0 and h1[0].collider == near and h2.size() > 0 and h2[0].collider == far, "both walls hit")
	if h1.size() > 0 and h2.size() > 0:
		var expect := 35.0 * pow(0.91, (h2[0].position.distance_to(Vector3(10, 1, 0)) / U) / 500.0)
		check(h1[0].damage > 33.5, "almost full damage at 5 m (%.1f)" % h1[0].damage)
		check(absf(h2[0].damage - expect) < 0.5 and h2[0].damage < 30.0, "falls off over 100 m (%.1f)" % h2[0].damage)
	await _cleanup()

func test_penetrates_thin_wood_not_thick_concrete() -> void:
	_course()
	_box(Vector3(0, 1, -3), Vector3(2, 2, 0.1), "wood")
	var behind := _box(Vector3(0, 1, -8), Vector3(2, 2, 0.4), "concrete")
	_box(Vector3(5, 1, -3), Vector3(2, 2, 0.3), "concrete")
	var behind2 := _box(Vector3(5, 1, -8), Vector3(2, 2, 0.4), "concrete")
	await _ticks(2)
	var d := WeaponDefs.get_def("rifle")
	var a := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 1, 0), Vector3.FORWARD, d)
	check(a.size() >= 2 and a[0].penetrated and a[1].collider == behind, "rifle goes through 10 cm of wood")
	if a.size() >= 2:
		check(a[1].damage < a[0].damage and a[1].damage > 5.0, "loses damage in the wood (%.1f -> %.1f)" % [a[0].damage, a[1].damage])
	var b := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(5, 1, 0), Vector3.FORWARD, d)
	check(b.size() == 1 and not b[0].penetrated, "30 cm of concrete stops it")
	check(b.all(func(h: Hitscan.Hit) -> bool: return h.collider != behind2), "nothing behind the concrete is hit")
	await _cleanup()

func test_headshot_kills_dummy_and_ragdoll_settles() -> void:
	_course()
	var dummy := TrainingDummy.new()
	_root.add_child(dummy)
	dummy.global_position = Vector3(0, 0, -6)
	await _ticks(4)
	var d := WeaponDefs.get_def("rifle")
	var body := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 1.28, 0), Vector3.FORWARD, d)
	check(body.size() > 0 and body[0].hitgroup == "chest", "chest hitbox hit")
	check(absf(dummy.health - (100.0 - body[0].damage if body.size() > 0 else 0.0)) < 0.01 and dummy.health > 0.0,
		"chest shot hurts (%.0f hp left)" % dummy.health)
	var head := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 1.66, 0), Vector3.FORWARD, d)
	check(head.size() > 0 and head[0].hitgroup == "head", "head hitbox hit")
	if head.size() > 0 and body.size() > 0:
		check(absf(head[0].damage - body[0].damage * 4.0) < 0.5, "headshot ×4 (%.0f)" % head[0].damage)
	check(dummy.health <= 0.0, "dummy killed")
	await _ticks(2)
	var rags := _root.get_children().filter(func(c: Node) -> bool: return c is Ragdoll)
	check(rags.size() == 1, "one ragdoll spawned")
	var after := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 1.66, 0), Vector3.FORWARD, d)
	check(after.is_empty() or after[0].collider is RigidBody3D or after[0].hitgroup == "", "dead dummy's hitboxes are off")
	if rags.size() == 1:
		var r: Ragdoll = rags[0]
		await _ticks(64 * 7)
		var pelvis: RigidBody3D = r.bodies["pelvis"]
		check(pelvis.global_position.y < 0.5, "ragdoll fell down (pelvis %.2f m)" % pelvis.global_position.y)
		check(pelvis.global_position.y > -0.2, "ragdoll stayed above the floor")
		var still := r.bodies.values().all(func(b: RigidBody3D) -> bool: return b.freeze or b.linear_velocity.length() < 0.3)
		check(still, "ragdoll settled")
	await _cleanup()

func test_ragdoll_cap() -> void:
	_course()
	for i in 11:
		Ragdoll.spawn(_root, Transform3D(Basis(), Vector3(i * 3.0, 0, 10)), Color.WHITE)
	await _ticks(2)
	var n := _root.get_children().filter(func(c: Node) -> bool: return c is Ragdoll and not c.is_queued_for_deletion()).size()
	check(n == Ragdoll.MAX_ACTIVE, "at most %d ragdolls (%d)" % [Ragdoll.MAX_ACTIVE, n])
	await _cleanup()

func test_bullet_pushes_prop() -> void:
	_course()
	var crate := _prop(Vector3(0, 0, -5), 20.0, 0.5)
	await _ticks(20)
	var hits := Hitscan.fire(WorldQueries.for_space(_space()), Vector3(0, 0.25, 0), Vector3.FORWARD, WeaponDefs.get_def("sniper"))
	check(hits.size() > 0 and hits[0].collider == crate, "crate hit")
	await _ticks(10)
	check(crate.linear_velocity.z < -0.3 or crate.global_position.z < -5.05, "crate pushed (v %s)" % str(crate.linear_velocity))
	await _cleanup()


# --- moving platforms --------------------------------------------------------------------

func _platform(at: Vector3, travel: Vector3) -> MovingPlatform:
	var m := MovingPlatform.new()
	m.travel = travel
	m.speed = 2.0
	m.wait = 0.5
	m.position = at
	_root.add_child(m)
	return m

func test_rides_horizontal_platform() -> void:
	_course()
	var m := _platform(Vector3(0, 1.0, 0), Vector3(8, 0, 0))
	var p := _player(Vector3(0, 1.1, 0))
	await _ticks(64 * 3)
	var dx := p.global_position.x - m.global_position.x
	check(m.global_position.x > 3.0, "platform moved (%.2f)" % m.global_position.x)
	check(absf(dx) < 0.3 and p.global_position.y > 0.95, "player rode along (offset %.2f, y %.2f)" % [dx, p.global_position.y])
	await _cleanup()

func test_rides_elevator_up_and_down() -> void:
	_course()
	var m := _platform(Vector3(0, 0.3, 0), Vector3(0, 5, 0))
	var p := _player(Vector3(0, 0.35, 0))
	await _ticks(64 * 3)
	check(m.global_position.y > 5.0 and p.global_position.y > m.global_position.y - 0.1, "carried up (%.2f)" % p.global_position.y)
	check(p.on_ground, "standing on the elevator")
	await _ticks(64 * 3)
	check(absf(p.global_position.y - m.global_position.y) < 0.15, "came down with it (%.2f vs %.2f)" % [p.global_position.y, m.global_position.y])
	await _cleanup()


# --- pushaway --------------------------------------------------------------------------

func test_walks_through_clutter_and_nudges_it() -> void:
	_course()
	var can := _prop(Vector3(0, 0, -3), 0.4, 0.12, true)
	var p := _player(Vector3(0, 0.05, 0))
	await _ticks(20)
	var start := can.global_position
	p.input.move = Vector2(0, 1)
	await _ticks(64)
	check(p.global_position.z < -5.0, "walked through the clutter (z %.2f)" % p.global_position.z)
	check(can.global_position.distance_to(start) > 0.15, "clutter nudged %.2f m" % can.global_position.distance_to(start))
	await _cleanup()


# --- editor placement ----------------------------------------------------------------------

func test_gameplay_entities_in_editor_and_game() -> void:
	_course()
	for simulate in [false, true]:
		var layer := EntityLayer.new()
		layer.simulate_physics = simulate
		_root.add_child(layer)
		var made := {}
		for asset: String in ["gameplay.ladder", "gameplay.platform", "gameplay.training_dummy", "gameplay.spawn_point"]:
			var entry := Catalog.get_entry(asset)
			var kind := EntityKinds.kind_for_category(str(entry.get("category", "")), entry)
			var e := EntityKinds.make(asset, asset, kind, Vector3(made.size() * 4.0, 0, 20), 0.0, 1.0)
			made[asset] = [e, layer.add_entity(e)]
		check(made["gameplay.ladder"][1] is Ladder, "ladder entity builds a Ladder")
		check(made["gameplay.platform"][1] is MovingPlatform and (made["gameplay.platform"][1] as MovingPlatform).active == simulate,
			"platform only moves in the game (simulate %s)" % simulate)
		check(made["gameplay.training_dummy"][1] is TrainingDummy, "dummy entity builds a TrainingDummy")
		eq(made["gameplay.spawn_point"][0].kind, "spawn_point", "spawn kind")
		check((made["gameplay.spawn_point"][1] is StaticBody3D) != simulate, "spawn marker pickable only in the editor")
		if not simulate:
			var e: Dictionary = made["gameplay.ladder"][0].duplicate(true)
			e.props.height = 9.0
			layer.rebuild_entity(e)
			var l := layer.node_for(e.id) as Ladder
			check(l != null and is_equal_approx(l.height, 9.0), "changing a setting rebuilds the ladder")
		layer.queue_free()
	await _cleanup()
