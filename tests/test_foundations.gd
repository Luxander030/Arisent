extends TestCase
## Gameplay-systems foundations (P0): map format v2, entity schema, shapes, spatial grid,
## zone index, data registries, kind registry, terrain-aware traces, clocks, console,
## session attach/detach, debug drawing, and the editor/runtime export boundary.


## A flat terrain at y = 10 (no physics collision), like Terrain3D far from the player.
class FlatTerrain extends TerrainBackend:
	var level := 10.0
	func get_height(_p: Vector3) -> float:
		return level
	func raycast(from: Vector3, dir: Vector3) -> Vector3:
		if is_zero_approx(dir.y) or (from.y - level) * dir.y > 0.0:
			return Vector3.INF
		return from + dir * ((level - from.y) / dir.y)


func _tmp_dir(name: String) -> String:
	var d := OS.get_user_data_dir().path_join("test_tmp").path_join(name)
	DirAccess.make_dir_recursive_absolute(d)
	return d


# --- map format ------------------------------------------------------------------------

func test_map_v2_roundtrip_identity_and_types() -> void:
	var m := MapData.new()
	m.name = "T"
	var e := EntityKinds.make("e1", "gameplay.spawner", "spawner", Vector3(1, 2, 3), 45.0, 1.0)
	e.props.count = 7
	m.entities = [e]
	var z := EntityKinds.make("z1", "", "zone", Vector3(10, 0, 10), 0.0, 1.0)
	z.props.spawn_table = [{"archetype": "wolf", "weight": 2.0, "group_min": 2, "group_max": 3, "level_min": 0, "level_max": 0}]
	m.entities.append(z)
	var dir := _tmp_dir("map_v2.luxmap")
	eq(MapIO.save(m, null, dir), OK, "saves")
	check(m.map_uid.length() == 16 and m.revision == 1, "uid assigned, revision 1")
	MapIO.save(m, null, dir)
	eq(m.revision, 2, "revision increments per save")
	var back := MapIO.load_map(dir)
	check(back != null, "loads: " + MapIO.last_error)
	if back:
		eq(back.map_uid, m.map_uid, "uid kept")
		eq(back.lineage.size(), 2, "lineage recorded")
		var be: Dictionary = back.entities[0]
		check(be.props.count is int and be.props.count == 7, "int prop is an int again")
		check(be.props.respawn is float, "float prop is a float")
		var row: Dictionary = back.entities[1].props.spawn_table[0]
		check(row.group_min is int and row.archetype == "wolf", "table rows typed")
		eq(back.entities[1].shape.type, "polygon", "zone shape kept")


func test_old_map_rejected() -> void:
	var dir := _tmp_dir("map_v1.luxmap")
	var f := FileAccess.open(dir.path_join("map.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema_version": 1, "name": "old"}))
	f.close()
	check(MapIO.load_map(dir) == null, "v1 map refused")
	check(MapIO.last_error.contains("re-create"), "with a clear reason: " + MapIO.last_error)


func test_normalize_fills_defaults() -> void:
	var e := EntityKinds.normalize({"id": "x", "kind": "spawner", "pos": [1, 2, 3]})
	eq(e.asset, "", "asset normalised")
	eq(e.props.movement, "wander", "defaults filled")
	check(e.rot is Array and e.rot.size() == 3, "rotation filled")
	var p := EntityKinds.normalize({"id": "p", "kind": "path", "pos": [0, 0, 0]})
	eq(p.shape.type, "polyline", "shaped kinds get a default shape")


# --- geometry, grid, zones ---------------------------------------------------------------

func test_zone_shapes() -> void:
	var sq := EntityKinds.make("a", "", "zone", Vector3(100, 0, 100), 0.0, 1.0)  # 40×40 square
	check(ZoneShape.contains(sq, Vector3(110, 0, 90)) and not ZoneShape.contains(sq, Vector3(125, 0, 100)), "polygon contains")
	check(is_equal_approx(ZoneShape.area(sq), 1600.0), "polygon area")
	var c := EntityKinds.make("c", "", "zone", Vector3(0, 0, 0), 0.0, 1.0)
	c.shape = {"type": "circle", "radius": 10.0}
	check(ZoneShape.contains(c, Vector3(7, 0, 7)) and not ZoneShape.contains(c, Vector3(8, 0, 8)), "circle contains")
	var b := EntityKinds.make("b", "", "zone", Vector3(0, 0, 0), 90.0, 1.0)
	b.shape = {"type": "box", "size": [40.0, 4.0]}
	check(ZoneShape.contains(b, Vector3(0, 0, 15)) and not ZoneShape.contains(b, Vector3(15, 0, 0)), "box rotates with yaw")
	var r := ZoneShape.aabb(sq)
	check(r.position.is_equal_approx(Vector2(80, 80)) and r.size.is_equal_approx(Vector2(40, 40)), "aabb")


func test_world_grid() -> void:
	var g := WorldGrid.new()
	g.put(&"npcs", "a", Vector3(10, 0, 10))
	g.put(&"npcs", "b", Vector3(500, 0, 500))
	g.put(&"npcs", "c", Vector3(-70, 0, 5))
	var near := g.query_radius(&"npcs", Vector3.ZERO, 80.0)
	check(near.has("a") and near.has("c") and not near.has("b"), "radius query by cells")
	g.put(&"npcs", "b", Vector3(20, 0, 20))
	check(g.query_radius(&"npcs", Vector3.ZERO, 30.0).has("b"), "moved")
	g.remove(&"npcs", "a")
	check(not g.query_radius(&"npcs", Vector3.ZERO, 30.0).has("a") and g.count(&"npcs") == 2, "removed")
	g.put_rect(&"zones", "big", Rect2(-200, -200, 400, 400))
	check(g.query_rect(&"zones", Rect2(150, 150, 1, 1)).has("big"), "rect spans cells")
	var seg := g.query_segment(&"npcs", Vector3(-100, 0, 20), Vector3(200, 0, 20))
	check(seg.has("b"), "segment query")
	eq(WorldGrid.region_of(Vector3(300, 0, -10)), Vector2i(1, -1), "256 m regions")


func test_zone_index_priority() -> void:
	var idx := ZoneIndex.new(WorldGrid.new())
	var big := EntityKinds.make("big", "", "zone", Vector3.ZERO, 0.0, 1.0)
	big.shape = {"type": "circle", "radius": 100.0}
	var small := EntityKinds.make("small", "", "zone", Vector3.ZERO, 0.0, 1.0)
	small.shape = {"type": "circle", "radius": 10.0}
	small.props.roles = ["no_spawn"]
	var top := EntityKinds.make("top", "", "zone", Vector3.ZERO, 0.0, 1.0)
	top.shape = {"type": "circle", "radius": 50.0}
	top.props.priority = 5
	for z in [big, small, top]:
		idx.set_zone(z)
	var stack := idx.zones_at(Vector3(1, 0, 1)).map(func(z: Dictionary) -> String: return z.id)
	eq(stack, ["top", "small", "big"], "priority first, then smaller area")
	check(idx.has_role_at(Vector3(1, 0, 1), "no_spawn") and not idx.has_role_at(Vector3(30, 0, 0), "no_spawn"), "role lookup")
	idx.set_zone({"id": "camp", "kind": "zone", "pos": [60.0, 0.0, 0.0], "rot": [0, 0, 0], "props": {"roles": ["no_spawn"]}, "shape": {"type": "circle", "radius": 5.0}}, true)
	check(idx.has_role_at(Vector3(60, 0, 0), "no_spawn"), "runtime zone")
	idx.clear_runtime()
	check(not idx.has_role_at(Vector3(60, 0, 0), "no_spawn"), "runtime zones cleared")


# --- registries --------------------------------------------------------------------------

func test_defs_and_kinds() -> void:
	Defs.reload()
	check(Defs.errors.is_empty(), "data files valid: %s" % str(Defs.errors))
	for reg in Defs.REGISTRIES:
		check(not Defs.ids(reg).is_empty(), "%s has entries" % reg)
	var wolf := Defs.get_def("creatures", "wolf")
	check(wolf.body == "quadruped" and wolf.has("leash") and wolf.attack.damage > 0, "creature defaults merged")
	for c: Dictionary in Defs.all("creatures"):
		if str(c.loot_table) != "":
			check(Defs.has("loot_tables", c.loot_table), "%s loot table exists" % c.id)
	for t: Dictionary in Defs.all("loot_tables"):
		for r: Dictionary in t.rows:
			check(r.has("ref") and Defs.has("loot_tables", r.ref) or Defs.has("items", str(r.get("item", ""))), "%s row valid" % t.id)
	for k: String in EntityKinds.KINDS:
		check(KindRegistry.of(k) != null, "%s has a behaviour" % k)


func test_export_includes_data() -> void:
	var cfg := FileAccess.get_file_as_string("res://export_presets.cfg")
	var n := 0
	for line in cfg.split("\n"):
		if line.begins_with("include_filter=") and line.contains("assets/data/*"):
			n += 1
	eq(n, 4, "every export preset ships assets/data")


## Runtime code (shipped in the game) must not use editor/ or worldgen/ classes.
func test_runtime_does_not_reference_editor_code() -> void:
	var names: Array[String] = []
	for dir in ["res://editor", "res://worldgen"]:
		_collect_class_names(dir, names)
	var offenders: Array[String] = []
	for dir in ["res://world", "res://game", "res://core", "res://addons/story_graph/core"]:
		_scan(dir, names, offenders)
	check(offenders.is_empty(), "runtime scripts reference editor/worldgen classes: %s" % ", ".join(offenders))


func _collect_class_names(dir: String, out: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			for line in FileAccess.get_file_as_string(dir.path_join(f)).split("\n"):
				if line.begins_with("class_name "):
					out.append(line.trim_prefix("class_name ").strip_edges())
	for d in DirAccess.get_directories_at(dir):
		_collect_class_names(dir.path_join(d), out)


func _scan(dir: String, names: Array[String], offenders: Array[String]) -> void:
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".gd"):
			continue
		var src := FileAccess.get_file_as_string(dir.path_join(f))
		if src.contains("res://editor/") or src.contains("res://worldgen/"):
			offenders.append(f + " (path)")
		for n in names:
			var re := RegEx.create_from_string("\\b%s\\b" % n)
			for raw in src.split("\n"):
				var line := raw.get_slice("##", 0)
				if line.strip_edges().begins_with("#"):
					continue
				if re.search(line):
					offenders.append("%s uses %s" % [f, n])
					break
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), names, offenders)


# --- traces, hitscan ---------------------------------------------------------------------

var _root: Node3D

func _scene() -> Node3D:
	_root = Node3D.new()
	Engine.get_main_loop().root.add_child(_root)
	return _root

func _wall(center: Vector3, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	b.position = center
	_root.add_child(b)
	return b


func test_trace_stops_at_terrain_beyond_collision() -> void:
	_scene()
	var wall := _wall(Vector3(0, 5, -150), Vector3(10, 30, 1))
	await Engine.get_main_loop().physics_frame
	var q := WorldQueries.for_space(_root.get_world_3d().direct_space_state, FlatTerrain.new())
	# Shooting down through the "hill" (terrain at y=10) toward the wall behind it.
	var hit := q.trace(Vector3(0, 20, 0), Vector3(0, 0, -200), PhysicsLayers.WORLD)
	check(hit.get("terrain", false), "terrain stops the ray before the wall")
	check(absf(float(hit.position.y) - 10.0) < 0.01, "at the terrain surface")
	var flat := q.trace(Vector3(0, 12, 0), Vector3(0, 12, -200), PhysicsLayers.WORLD)
	check(flat.get("collider") == wall, "level shot reaches the wall")
	check(not q.line_of_sight(Vector3(0, 20, 0), Vector3(0, 0, -200)), "no line of sight through the hill")
	q.terrain.free()
	_root.queue_free()


func test_hitscan_record_fallback_merged_by_distance() -> void:
	_scene()
	_wall(Vector3(0, 1, -50), Vector3(10, 4, 1))
	await Engine.get_main_loop().physics_frame
	var q := WorldQueries.for_space(_root.get_world_3d().direct_space_state)
	var got := {"n": 0, "dmg": 0.0}
	var rec_at := {"z": -20.0}
	q.record_ray = func(from: Vector3, to: Vector3) -> Array:
		var p := Vector3(0, 1, rec_at.z)
		var t := (p.z - from.z) / (to.z - from.z)
		if t < 0.0 or t > 1.0:
			return []
		return [{"position": p, "normal": Vector3.BACK, "distance": from.distance_to(p),
			"apply": func(info: DamageInfo) -> void:
				got.n += 1
				got.dmg = info.amount}]
	var hits := Hitscan.fire(q, Vector3(0, 1, 0), Vector3.FORWARD, WeaponDefs.get_def("rifle"))
	check(got.n == 1 and got.dmg > 30.0 and hits.size() == 1, "nodeless record in front of the wall is hit")
	rec_at.z = -80.0
	got.n = 0
	Hitscan.fire(q, Vector3(0, 1, 0), Vector3.FORWARD, WeaponDefs.get_def("rifle"))
	eq(got.n, 0, "record behind the wall is not hit")
	_root.queue_free()


# --- clocks, console, session -------------------------------------------------------------

func test_clocks() -> void:
	var c := SimClock.new()
	c.advance(1.5)
	c.scale = 2.0
	c.advance(1.0)
	c.skip(10.0)
	check(is_equal_approx(c.now, 13.5), "sim clock: %.2f" % c.now)
	var t := TimeOfDay.new()
	t.set_hours(23.0)
	t.add_hours(2.0)
	check(is_equal_approx(t.hours, 1.0) and t.day == 1, "day wraps")
	check(TimeOfDay.in_window(23.0, 20.0, 6.0) and TimeOfDay.in_window(3.0, 20.0, 6.0) and not TimeOfDay.in_window(12.0, 20.0, 6.0), "night window")
	check(TimeOfDay.in_window(12.0, 0.0, 24.0), "full day")


func test_console_and_session() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var game := GameSession.new()
	root.add_child(game)
	var view := WorldView.new()
	root.add_child(view)
	var focus := Node3D.new()
	view.add_child(focus)
	var s := WorldSession.attach(view, game, focus)
	await Engine.get_main_loop().process_frame
	check(WorldSession.of(focus) == s and game.world == s, "session reachable from nodes under the view")
	var c := game.console
	check(c.has_command("show") and c.has_command("time") and c.has_command("info"), "services registered commands")
	check(not view.debug.any_on(), "game: overlays off by default")
	c.run("show zones")
	check(view.debug.is_on("zones"), "console turns a channel on")
	c.run("hide all")
	check(not view.debug.any_on(), "and off")
	check(c.run("nope").begins_with("Unknown"), "unknown command")
	c.run("skip 2")
	check(is_equal_approx(game.clock.now, 7200.0), "skip advances the sim clock")
	s.detach()
	await Engine.get_main_loop().process_frame
	check(not c.has_command("show") and view.session == null, "detach removes the session's commands")
	check(c.has_command("time"), "game-level commands stay")
	view.queue_free()
	game.queue_free()
	await Engine.get_main_loop().process_frame


func test_debug_draw_providers() -> void:
	var dd := DebugDraw.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(dd)
	var calls := {"n": 0}
	dd.add_provider(func(d: DebugDraw) -> void:
		calls.n += 1
		if d.is_on("spawns"):
			d.circle(Vector3.ZERO, 5.0, Color.RED, false)
			d.text(Vector3.ZERO, "hi"))
	await Engine.get_main_loop().process_frame
	eq(calls.n, 0, "providers not called while every channel is off")
	dd.set_channel("spawns", true)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	check(calls.n >= 1, "called when a channel is on")
	check((dd._lines_mi.mesh as ArrayMesh).get_surface_count() == 1, "lines drawn")
	dd.queue_free()
	await Engine.get_main_loop().process_frame
