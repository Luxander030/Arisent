## Rendering benchmark on a saved map: fixed camera views, average FPS, triangles and
## draw calls per view. Used to compare LOD settings.
## Run: godot --path . --resolution 1600x900 --script res://tests/bench_lod.gd -- <map folder> <out json> [quality]
extends SceneTree

var ed: EditorMain


func _initialize() -> void:
	create_timer(400.0).timeout.connect(func() -> void: quit(2))
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	ed = load("res://editor/editor_main.tscn").instantiate()
	root.add_child(ed)
	await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var vp_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	ed.open_map(args[0])
	if args.size() > 2 and ed.has_method("set_quality"):
		ed.set_quality(args[2])
	var map := ed.map
	print("city merge %d ms, video memory %.0f MB, buffers %.0f MB" % [ed.world.city.build_ms,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) / 1048576.0])
	var city := Vector3(map.city.plaza[0], 0, map.city.plaza[1]) if map.city.has("plaza") else Vector3.ZERO
	city.y = ed.world.terrain.get_height(city)
	var forest := _find_biome(GenParams.Biome.TEMPERATE_FOREST)
	var views := {
		"city_street": [city + Vector3(120, 4, 160), city],
		"city_overview": [city + Vector3(300, 320, 420), city],
		"forest_floor": [forest + Vector3(0, 3, 0), forest + Vector3(60, 2, -60)],
		"panorama": [Vector3(0, 900, map.map_m * 0.62), Vector3(0, 0, -map.map_m * 0.1)],
	}
	var results := {}
	for name: String in views:
		var v: Array = views[name]
		var eye: Vector3 = v[0]
		eye.y = maxf(eye.y, ed.world.terrain.get_height(eye) + 2.0)
		ed.camera.look_from(eye, v[1])
		for i in 90:
			await process_frame
		var frames := 0
		var prims := 0
		var draws := 0
		var gpu_ms := 0.0
		var cpu_ms := 0.0
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < 2500000:
			await process_frame
			frames += 1
			prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
			draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
			gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
			cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
		var fps := frames / ((Time.get_ticks_usec() - t0) / 1000000.0)
		results[name] = {"fps": snappedf(fps, 0.1), "triangles": prims / frames, "draw_calls": draws / frames,
			"gpu_ms": snappedf(gpu_ms / frames, 0.01), "cpu_ms": snappedf(cpu_ms / frames, 0.01)}
		print("%-14s fps %5.1f  gpu %5.2f ms  render-cpu %5.2f ms  triangles %9d  draw calls %5d" % [name, fps,
			gpu_ms / frames, cpu_ms / frames, prims / frames, draws / frames])
		root.get_texture().get_image().save_png(args[1].get_base_dir().path_join("bench_%s.png" % name))
		if OS.has_environment("BENCH_BREAKDOWN"):
			var parts := {"city": ed.world.city, "impostors": ed.world.impostors, "water": ed.world.water,
				"entities": ed.world.entities, "grass": ed.world.terrain.get_node_or_null("Grass")}
			for pname in parts:
				var node: Node3D = parts[pname]
				if node == null:
					continue
				node.visible = false
				for i in 8:
					await process_frame
				print("    without %-10s triangles %9d  draw calls %5d" % [pname,
					RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
					RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
				node.visible = true
			ed.world.sun.shadow_enabled = false
			for i in 8:
				await process_frame
			print("    without %-10s triangles %9d  draw calls %5d" % ["shadows",
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)])
			ed.world.sun.shadow_enabled = true
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(results, "\t"))
	quit()


func _find_biome(b: int) -> Vector3:
	var map := ed.map
	var n := map.layout_n
	var best := Vector3.ZERO
	var best_d := INF
	for k in n * n:
		if map.layout_biome[k] == b and map.layout_weights[b][k] > 230:
			var p := Vector3((float(k % n) + 0.5) / n * map.map_m - map.map_m * 0.5, 0, (float(k / n) + 0.5) / n * map.map_m - map.map_m * 0.5)
			var d := p.length()
			if d < best_d:
				best_d = d
				best = p
	best.y = ed.world.terrain.get_height(best)
	return best
