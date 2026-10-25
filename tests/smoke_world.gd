## Windowed smoke test: generate a map, show it in 3D, take screenshots.
## Run: godot --path . --script res://tests/smoke_world.gd -- <out_dir> [seed] [size_km]
extends SceneTree

func _initialize() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		printerr("smoke test timed out")
		quit(2))
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else OS.get_user_data_dir()
	var p := GenParams.new()
	p.seed = args[1] if args.size() > 1 else "42"
	p.size_km = int(args[2]) if args.size() > 2 else 2
	var t := Time.get_ticks_msec()
	var L := LayoutGenerator.new().generate(p, 512)
	var r := TerrainBuilder.new().build(L, p)
	print("generated in ", Time.get_ticks_msec() - t, " ms")
	var map := MapFactory.create(p, L, r)
	var cam := Camera3D.new()
	cam.far = 12000.0
	root.add_child(cam)
	var world := WorldView.new()
	root.add_child(world)
	t = Time.get_ticks_msec()
	world.setup_terrain(map, cam)
	var ctrl_img: Image = null if OS.has_environment("SMOKE_NO_CONTROL") else r.control_image()
	var col_img: Image = null if OS.has_environment("SMOKE_NO_COLOR") else r.color_image()
	world.terrain.import_maps(r.height_image(), ctrl_img, col_img, r.origin())
	if not OS.has_environment("SMOKE_NO_WATER"):
		world.build_water()
	print("imported in ", Time.get_ticks_msec() - t, " ms")
	var only := OS.get_environment("SMOKE_VIEW")
	var views := [
		["overview", Vector3(0, map.map_m * 0.45, map.map_m * 0.62), Vector3(0, 0, 0)],
		["seam", Vector3(40, 120, 260), Vector3(0, 30, 100)],
		["city", Vector3(L.city_center.x + 300, L.city_height + 160, L.city_center.y + 420), Vector3(L.city_center.x, L.city_height, L.city_center.y)],
		["north", Vector3(0, 380, -map.map_m * 0.2), Vector3(0, 120, -map.map_m * 0.45)],
		["south", Vector3(0, 220, map.map_m * 0.2), Vector3(0, 40, map.map_m * 0.42)],
	]
	for v in views:
		if only != "" and v[0] != only:
			continue
		cam.position = v[1]
		cam.look_at(v[2])
		for i in 30:
			await process_frame
		root.get_texture().get_image().save_png(out.path_join("world_%s.png" % v[0]))
		print("shot ", v[0])
	quit()
