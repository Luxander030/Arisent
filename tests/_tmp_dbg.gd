extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var t: Variant = load("res://tests/test_movement.gd").new()
	t._course()
	var c: PlayerController = t._player(Vector3(0, 0.05, -2))
	var r: PlayerController = t._player(Vector3(20, 0.05, -3))
	for i in 10: await physics_frame
	c.input.move = Vector2(0, 1)
	r.input.move = Vector2(0, 1)
	for i in 60:
		await physics_frame
		if i % 4 == 0:
			print("tick %d stairs: g=%s z=%.2f y=%.3f v=%s | ramp: g=%s z=%.2f y=%.3f v=%s" % [i, c.on_ground, c.global_position.z, c.global_position.y, c.velocity.snapped(Vector3.ONE*0.01), r.on_ground, r.global_position.z, r.global_position.y, r.velocity.snapped(Vector3.ONE*0.01)])
	quit()
