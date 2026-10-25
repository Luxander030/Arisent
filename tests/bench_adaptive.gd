## Adaptive detail: hold a heavy view and print how the detail scale reacts to the frame rate.
## Run: godot --path . --resolution 1600x900 --script res://tests/bench_adaptive.gd -- <map folder> [target fps]
extends SceneTree

func _initialize() -> void:
	create_timer(200.0).timeout.connect(func() -> void: quit(2))
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var ed: EditorMain = load("res://editor/editor_main.tscn").instantiate()
	root.add_child(ed)
	await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	ed.open_map(args[0])
	var map := ed.map
	var c := Vector3(map.city.plaza[0], 0, map.city.plaza[1])
	c.y = ed.world.terrain.get_height(c)
	ed.camera.look_from(c + Vector3(300, 320, 420), c)
	ed.world.lod.target_fps = float(args[1]) if args.size() > 1 else 60.0
	ed.set_quality("Ultra")
	for i in 60:
		await process_frame
	ed.set_quality("Adaptive")
	var t0 := Time.get_ticks_msec()
	var worst := 0.0
	var last := Time.get_ticks_usec()
	var next_print := 2000
	while Time.get_ticks_msec() - t0 < 24000:
		await process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		if Time.get_ticks_msec() - t0 >= next_print:
			next_print += 2000
			print("t=%4.1fs  fps %5.1f  detail ×%.2f  worst frame %5.1f ms  triangles %d" % [(Time.get_ticks_msec() - t0) / 1000.0,
				ed.world.lod.average_fps(), ed.world.lod.scale, worst,
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
			worst = 0.0
	quit()
