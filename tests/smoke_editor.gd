## Windowed end-to-end run of the editor: New Map -> preview -> generate -> sculpt,
## paint, rift, undo -> save -> reopen. Screenshots at each step.
## Run: godot --path . --script res://tests/smoke_editor.gd -- <out_dir> [size_km]
extends SceneTree

var out := ""
var ed: EditorMain


func _initialize() -> void:
	create_timer(420.0).timeout.connect(func() -> void:
		printerr("editor smoke test timed out")
		quit(2))
	_run.call_deferred()


func shot(name: String) -> void:
	for i in 12:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("ed_%s.png" % name))
	print("shot ", name)


func wait_until(cond: Callable, timeout_s: float) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		await process_frame
		if Time.get_ticks_msec() - t > timeout_s * 1000.0:
			return false
	return true


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	out = args[0] if args.size() > 0 else OS.get_user_data_dir()
	var size_km := int(args[1]) if args.size() > 1 else 2
	ed = load("res://editor/editor_main.tscn").instantiate()
	root.add_child(ed)
	await shot("01_start")

	ed._open_new_map(false)
	var dlg := ed._new_map_dialog
	dlg.params.size_km = size_km
	dlg.params.seed = "Frostvale"
	dlg.params.name = "Smoke Test"
	dlg._schedule()
	var ok := await wait_until(func() -> bool: return dlg._layout_size == 512 and dlg._layout_id == dlg._request_id, 60.0)
	print("preview refined: ", ok, " — ", dlg._status.text)
	await shot("02_new_map")

	var t := Time.get_ticks_msec()
	dlg._on_generate()
	ok = await wait_until(func() -> bool: return ed.map != null and not ed._progress_panel.visible, 180.0)
	print("generated: ", ok, " in ", Time.get_ticks_msec() - t, " ms")
	var t3d: Terrain3D = (ed.world.terrain as Terrain3DBackend).terrain
	var total := 0
	for i in t3d.assets.get_mesh_count():
		total += t3d.assets.get_mesh_asset(i).get_instance_count()
	print("instancer: %d meshes, %d instances, grass node: %s" % [t3d.assets.get_mesh_count(), total, ed.world.terrain.get_node_or_null("Grass")])
	await shot("03_generated")
	for i in 120:
		await process_frame
	print("fps after settling: %d, draw calls %d, primitives %d" % [Engine.get_frames_per_second(),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	for part in [ed.world.city, ed.world.water, ed.world.terrain.get_node_or_null("Grass")]:
		if part == null: continue
		part.visible = false
		for i in 10: await process_frame
		print("  without %s: primitives %d" % [part.name, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
		part.visible = true
	var cc := ed.camera.position
	var fwd := -ed.camera.global_basis.z
	var g := Vector3(cc.x + fwd.x * 300.0, 0.0, cc.z + fwd.z * 300.0)
	g.y = ed.world.terrain.get_height(g) + 25.0
	var saved := ed.camera.transform
	ed.camera.look_from(g, g + Vector3(fwd.x, -0.25, fwd.z) * 50.0)
	await shot("03b_ground")
	ed.camera.transform = saved

	# Sculpt: raise a hill near the camera target.
	var c := _ground_point(Vector2(0.5, 0.6))
	var h0 := ed.world.terrain.get_height(c)
	var sculpt: SculptTool = ed.tools[1]
	ed.set_tool(1)
	sculpt.size = 60.0
	sculpt.strength = 100.0
	ed.world.terrain.begin_stroke(TerrainBackend.Tool.RAISE, c, {"size": 60.0, "strength": 100.0})
	for i in 40:
		ed.world.terrain.stroke(c + Vector3(i * 0.5, 0, 0))
		await process_frame
	ed.world.terrain.end_stroke()
	var h1 := ed.world.terrain.get_height(c)
	print("sculpt height %.1f -> %.1f, undo available: %s" % [h0, h1, ed.undo.has_undo()])
	await shot("04_sculpt")

	# Rift across the view.
	ed.set_tool(4)
	var a := _ground_point(Vector2(0.3, 0.75))
	var b := _ground_point(Vector2(0.7, 0.55))
	ed.add_modifier({"type": "rift", "id": "smoke-rift", "a": [a.x, a.z], "b": [b.x, b.z], "width": 50.0, "depth": 35.0, "roughness": 0.6})
	print("modifiers: ", ed.map.modifiers.size())
	await shot("05_rift")
	ed.do_undo()
	print("after undo modifiers: ", ed.map.modifiers.size())
	ed.do_redo()

	# Place objects, paint vegetation, add a lake and a river, delete a city building.
	ed.set_tool(6)
	var place: PlaceTool = ed.tools[6]
	for i in 5:
		var q := _ground_point(Vector2(0.35 + i * 0.07, 0.7))
		ed.add_entity(EntityKinds.make(ed.new_id(), "nature.tree_oak", "prop", q, i * 30.0, 1.0))
	print("entities: ", ed.map.entities.size(), " nodes: ", ed.world.entities.get_child_count())
	ed.set_tool(3)
	var veg: VegetationTool = ed.tools[3]
	veg.mode = 2
	veg.size = 120.0
	veg.strength = 100.0
	var vp := _ground_point(Vector2(0.5, 0.45))
	veg._before = {0: veg._image().duplicate()}
	veg._stroke_rect = Rect2(Vector2(vp.x, vp.z), Vector2.ZERO)
	veg._dab(vp)
	var tv := Time.get_ticks_msec()
	veg._finish()
	print("vegetation repaint + rescatter: %d ms" % (Time.get_ticks_msec() - tv))
	ed.set_tool(5)
	var water: WaterTool = ed.tools[5]
	water.lake_depth = 4.0
	var lakes_before: int = ed.map.water.lakes.size()
	var mid := (a + b) * 0.5
	mid.y = ed.world.terrain.get_height(mid)
	water.make_lake(mid)
	print("lakes: %d -> %d" % [lakes_before, ed.map.water.lakes.size()])
	var tr := Time.get_ticks_msec()
	ed.add_river([_ground_point(Vector2(0.6, 0.5)), _ground_point(Vector2(0.65, 0.65)), _ground_point(Vector2(0.7, 0.8))], 12.0, 2.5, false)
	print("river added in %d ms, rivers %d, modifiers %d" % [Time.get_ticks_msec() - tr, ed.map.water.rivers.size(), ed.map.modifiers.size()])
	var cb: Array = ed.map.city.get("buildings", [])
	if not cb.is_empty():
		var before_count := ed.world.city.building_count
		ed.delete_city_building(str(cb[0].key))
		print("city buildings %d -> %d" % [before_count, ed.world.city.building_count])
	await shot("05b_edits")
	await _spawning()

	# Save and reopen.
	var dir := out.path_join("SmokeTest.luxmap")
	ed.save_to(dir)
	var saved_h := ed.world.terrain.get_height(c)
	ed.open_map(dir)
	await shot("06_reopened")
	print("reopened height %.1f (saved %.1f), modifiers %d, rivers %d, entities %d, overrides %d, paint layers %d" % [ed.world.terrain.get_height(c), saved_h,
		ed.map.modifiers.size(), ed.map.water.get("rivers", []).size(), ed.map.entities.size(), ed.map.overrides.size(), ed.map.scatter_paint.size()])

	# Regenerate with a different setting: edits must survive.
	var hill_before := ed.world.terrain.get_height(c) - ed.map.procedural_height.get_pixelv(ed.world.terrain.world_to_pixel(c)).r
	ed._open_new_map(true)
	var dlg2 := ed._new_map_dialog
	dlg2.params.rivers = 0.9
	dlg2._schedule()
	ok = await wait_until(func() -> bool: return dlg2._layout_size == 512 and dlg2._layout_id == dlg2._request_id, 60.0)
	dlg2._on_generate()
	ok = await wait_until(func() -> bool: return ed._gen_thread == null and not ed._progress_panel.visible, 180.0)
	var hill_after := ed.world.terrain.get_height(c) - ed.map.procedural_height.get_pixelv(ed.world.terrain.world_to_pixel(c)).r
	print("regenerated: sculpt delta %.1f -> %.1f m, entities %d, modifiers %d, overrides %d, user rivers %d, path kept %s" % [
		hill_before, hill_after, ed.map.entities.size(), ed.map.modifiers.size(), ed.map.overrides.size(),
		ed.map.water.rivers.filter(func(r: Dictionary) -> bool: return r.origin == "user").size(), ed.map.path != ""])
	await shot("07_regenerated")
	quit()


## Spawning authoring: a spawner, a spawn zone with a no-spawn hole, a patrol path and a
## spawn group; gizmos drawn with no session running; then Simulate shows creatures.
func _spawning() -> void:
	var c := _ground_point(Vector2(0.5, 0.62))
	ed.camera.look_from(c + Vector3(0, 70, 95), c)
	for i in 5:
		await process_frame
	c = _ground_point(Vector2(0.5, 0.6))
	var zone := EntityKinds.make(ed.new_id(), "", "zone", c, 0.0, 1.0)
	zone.shape = {"type": "polygon", "points": [[-45.0, -30.0], [40.0, -38.0], [50.0, 25.0], [-10.0, 40.0], [-50.0, 15.0]]}
	zone.props.name = "Wolf meadow"
	zone.props.max_alive = 6
	zone.props.min_player_dist = 0.0
	zone.props.spawn_table = [{"archetype": "wolf", "weight": 1.0, "group_min": 2, "group_max": 3, "level_min": 0, "level_max": 0},
		{"archetype": "deer", "weight": 2.0, "group_min": 1, "group_max": 2, "level_min": 0, "level_max": 0}]
	ed.add_entity(zone)
	var hole := EntityKinds.make(ed.new_id(), "", "zone", c + Vector3(-15, 0, 5), 0.0, 1.0)
	hole.shape = {"type": "circle", "radius": 12.0}
	hole.props.name = "Camp"
	hole.props.roles = ["no_spawn"]
	ed.add_entity(hole)
	var path := EntityKinds.make(ed.new_id(), "", "path", c + Vector3(30, 0, 30), 0.0, 1.0)
	path.shape = {"type": "polyline", "points": [[0.0, 0.0], [25.0, 5.0], [35.0, 30.0], [5.0, 35.0]], "waits": []}
	ed.add_entity(path)
	var group := EntityKinds.make(ed.new_id(), "gameplay.spawn_group", "spawn_group", c + Vector3(-40, 0, -40), 0.0, 1.0)
	group.props.name = "Bandit patrol"
	group.props.max_alive = 1
	ed.add_entity(group)
	for k in 2:
		var sp := EntityKinds.make(ed.new_id(), "gameplay.spawner", "spawner", c + Vector3(-45 + k * 12, 0, -50), 0.0, 1.0)
		sp.pos[1] = ed.world.terrain.get_height(EntityKinds.position_of(sp))
		sp.props.archetype = "bandit"
		sp.props.group = group.id
		sp.props.movement = "patrol" if k == 0 else "wander"
		sp.props.path = path.id if k == 0 else ""
		ed.add_entity(sp)
	var farm := EntityKinds.make(ed.new_id(), "gameplay.spawner", "spawner", c + Vector3(35, 0, -10), 0.0, 1.0)
	farm.pos[1] = ed.world.terrain.get_height(EntityKinds.position_of(farm))
	farm.props.archetype = "chicken"
	farm.props.count = 5
	farm.props.wander_radius = 10.0
	ed.add_entity(farm)
	var zt: ZoneTool = ed.tools[7]
	ed.set_tool(7)
	# Draw a zone with real mouse events: four clicks and Enter, then drag a handle; undo/redo.
	var vp := root.get_visible_rect().size
	var before_n: int = ed.map.entities.size()
	for uv in [Vector2(0.3, 0.75), Vector2(0.42, 0.74), Vector2(0.44, 0.88), Vector2(0.29, 0.86)]:
		_click(vp * uv)
		await process_frame
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	ed._unhandled_input(enter)
	var drawn: Dictionary = zt._entity()
	print("zone tool: entities %d -> %d, drawn %s with %d points" % [before_n, ed.map.entities.size(), drawn.get("kind", "-"), (drawn.get("shape", {}).get("points", []) as Array).size()])
	var h0: Vector3 = zt._handles()[0]
	var cam: Camera3D = ed.camera
	var from := cam.unproject_position(h0)
	_mouse(from, true)
	_motion(from + Vector2(-40, 10))
	_mouse(from + Vector2(-40, 10), false)
	var moved: Array = zt._entity().shape.points[0]
	ed.do_undo()
	var undone: Array = ed.world.entities.entity(drawn.id).shape.points[0]
	ed.do_redo()
	print("handle drag: %s -> %s, undo back to %s" % [str(drawn.shape.points[0]), str(moved), str(undone)])
	zt.select(zone.id)
	print("spawning problems: %s" % str(SpawnChecks.all_problems(ed.world)))
	print("zone candidates %d, usable %.0f%%" % [zt._preview_points.size(), ZoneCandidates.usable_fraction(zone, zt._preview_points) * 100.0])
	print("session while editing: %s" % ed.world.session)
	await shot("08_spawning_gizmos")
	var dirty_before: bool = ed.dirty
	ed.simulate.start()
	for i in 240:
		await physics_frame
	print(ed.simulate.status_text())
	await shot("09_simulate")
	# Drive the pawn on flat ground (the city plaza): hold W for two seconds.
	var plaza: Array = ed.map.city.get("plaza", ed.map.city.get("center", [0.0, 0.0]))
	var pz := Vector3(plaza[0], 0.0, plaza[1])
	pz.y = ed.world.terrain.get_height(pz)
	ed.camera.look_from(pz + Vector3(0, 60, 60), pz)
	for i in 30:
		await physics_frame
	ed.simulate.set_driving(true)
	var start: Vector3 = ed.simulate.pawn.global_position
	var w := InputEventKey.new()
	w.physical_keycode = KEY_W
	w.keycode = KEY_W
	w.pressed = true
	Input.parse_input_event(w)
	for i in 128:
		await physics_frame
	w.pressed = false
	Input.parse_input_event(w)
	var drove: float = ed.simulate.pawn.global_position.distance_to(start)
	var pp: Vector3 = ed.simulate.pawn.global_position
	print("pawn at height %.1f, ground %.1f (start %.1f, ground %.1f)" % [pp.y, ed.world.terrain.get_height(pp), start.y, ed.world.terrain.get_height(start)])
	print("drove the pawn %.1f m; camera %.1f m behind it" % [drove, ed.camera.global_position.distance_to(ed.simulate.pawn.global_position)])
	await shot("09b_driving")
	ed.simulate.set_driving(false)
	ed.simulate.stop()
	for i in 5:
		await process_frame
	print("after stop: session %s, npc nodes %d, dirty unchanged %s" % [ed.world.session, ed.world.find_children("*", "NpcBody", true, false).size(), ed.dirty == dirty_before])
	ed.set_tool(0)


func _click(at: Vector2) -> void:
	_mouse(at, true)
	_mouse(at, false)


func _mouse(at: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	ed._unhandled_input(ev)


func _motion(at: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = at
	ed._unhandled_input(ev)


## Terrain point under a normalized screen position.
func _ground_point(uv: Vector2) -> Vector3:
	var vp := root.get_visible_rect().size
	var hit := ed._pick(vp * uv)
	if hit == Vector3.INF:
		hit = Vector3.ZERO
		hit.y = ed.world.terrain.get_height(hit)
	return hit
