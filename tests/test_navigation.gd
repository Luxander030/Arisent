extends TestCase
## P5: navigation tiles baked around the player; creatures that move with physics walk
## around obstacles instead of into them.


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _box(parent: Node, center: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	b.position = center
	parent.add_child(b)


func test_walks_around_a_wall() -> void:
	Defs.reload()
	var game := GameSession.new()
	_tree().root.add_child(game)
	var view := WorldView.new()
	_tree().root.add_child(view)
	view.entities.simulate_physics = true
	_box(view, Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	_box(view, Vector3(10, 2, 0), Vector3(1, 4, 30))   # wall between start and goal
	var player := PlayerController.new()
	view.add_child(player)
	player.global_position = Vector3(-20, 0.05, 30)
	var s := WorldSession.attach(view, game, player)
	var nav := s.navigator as NavMeshNavigator
	for i in 600:
		await _tree().physics_frame
		if nav.ready_count() >= 25:
			break
	check(nav.ready_count() >= 9, "tiles baked around the player (%d)" % nav.ready_count())
	await _tree().physics_frame
	var path := NavigationServer3D.map_get_path(view.get_world_3d().navigation_map, Vector3(0, 0, 0), Vector3(20, 0, 0), true)
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	check(path.size() > 2 and length > 30.0, "path goes around the wall (%d points, %.0f m)" % [path.size(), length])
	# A creature told to go to the other side gets there with physics.
	var boar := s.npcs.spawn("boar", Vector3(0, 0, 0), {"movement": "idle"})
	for i in 10:
		await _tree().physics_frame
	boar.state = NpcBrain.WANDER
	boar.move_target = Vector3(20, 0, 0)
	boar.move_speed = 5.0
	boar.progress_t = s.now()
	var reached := false
	for i in 64 * 12:
		await _tree().physics_frame
		boar.state = NpcBrain.WANDER
		boar.move_target = Vector3(20, 0, 0)
		boar.progress_t = s.now()
		if Vector2(boar.pos.x - 20.0, boar.pos.z).length() < 1.5:
			reached = true
			break
	check(boar.physics_mode, "moved with physics near the player")
	check(reached, "walked around the wall to the goal (ended at %s)" % str(boar.pos))
	s.detach()
	view.queue_free()
	game.queue_free()
	await _tree().process_frame
