## Navigation meshes baked at runtime in 64 m tiles (the world grid's cells) around the
## player, where creatures move with physics. Ground comes from the terrain (or, without
## Terrain3D, from parsed static colliders — used by tests); city buildings and walls are
## carved out as obstructions. Tiles bake one at a time in the background (the terrain's
## triangles are gathered on a worker thread too: ~3 ms per tile) and are dropped when
## the player moves on. Paths are cached per creature and refreshed when the target
## moves. Outside baked tiles creatures walk straight.
class_name NavMeshNavigator
extends Navigator

const TILE := WorldGrid.CELL
const RADIUS_TILES := 2        ## 5×5 tiles (320 m) around the player
const KEEP_TILES := 3
const AGENT_RADIUS := 0.5
const CELL_SIZE := 0.5
const REPATH := 1.0

var session: WorldSession
var parse_root: Node           ## fallback ground source (no terrain): static colliders under it
var _tiles := {}               ## Vector2i -> {rid, state: "baking"|"ready"}
var _map: RID
var _baking := false
var _paths := {}               ## record id -> {path: PackedVector3Array, i, target, t}
var _closed := false
## The tile whose terrain triangles a worker thread is gathering: {k, task, nm, src, grown, faces}.
var _gather := {}


func _init(s: WorldSession) -> void:
	session = s
	_map = s.view.get_world_3d().navigation_map
	NavigationServer3D.map_set_cell_size(_map, CELL_SIZE)
	NavigationServer3D.map_set_cell_height(_map, 0.25)
	NavigationServer3D.map_set_edge_connection_margin(_map, CELL_SIZE * 2.0)


func tile_of(p: Vector3) -> Vector2i:
	return WorldGrid.cell_coords(p)


func is_ready_at(p: Vector3) -> bool:
	var t: Variant = _tiles.get(tile_of(p))
	return t != null and t.state == "ready"


func ready_count() -> int:
	return _tiles.values().filter(func(t: Dictionary) -> bool: return t.state == "ready").size()


## Bakes missing tiles near the focus (one at a time) and drops far ones.
func update(focus: Vector3) -> void:
	var c := tile_of(focus)
	for k: Vector2i in _tiles.keys():
		if absi(k.x - c.x) > KEEP_TILES or absi(k.y - c.y) > KEEP_TILES:
			var t: Dictionary = _tiles[k]
			if t.state == "ready":
				NavigationServer3D.free_rid(t.rid)
				_tiles.erase(k)
	if not _gather.is_empty() and WorkerThreadPool.is_task_completed(_gather.task):
		WorkerThreadPool.wait_for_task_completion(_gather.task)
		var g := _gather
		_gather = {}
		_start_bake(g.k, g.nm, g.src, g.faces)
	if _baking or _closed:
		return
	var best := Vector2i(1 << 20, 0)
	var best_d := INF
	for dz in range(-RADIUS_TILES, RADIUS_TILES + 1):
		for dx in range(-RADIUS_TILES, RADIUS_TILES + 1):
			var k := c + Vector2i(dx, dz)
			if _tiles.has(k):
				continue
			var d := float(dx * dx + dz * dz)
			if d < best_d:
				best_d = d
				best = k
	if best_d < INF:
		_bake(best)


func _bake(k: Vector2i) -> void:
	var nm := NavigationMesh.new()
	nm.cell_size = CELL_SIZE
	nm.cell_height = 0.25
	nm.agent_radius = AGENT_RADIUS
	nm.agent_height = 1.75  # a whole number of 0.25 m cells (1.8 was rounded up, with a warning per bake)
	nm.agent_max_slope = 45.0
	nm.agent_max_climb = 0.5
	nm.border_size = AGENT_RADIUS * 2.0
	var x0 := k.x * TILE
	var z0 := k.y * TILE
	# Chunk baking: bake a slightly larger box and let border_size trim it back to the
	# tile, so neighbouring tiles meet edge to edge (no agent-radius gaps between them).
	var aabb := AABB(Vector3(x0, -2000.0, z0), Vector3(TILE, 6000.0, TILE))
	nm.filter_baking_aabb = AABB(aabb.position - Vector3(nm.border_size, 0, nm.border_size), aabb.size + Vector3(nm.border_size * 2.0, 0, nm.border_size * 2.0))
	var src := NavigationMeshSourceGeometryData3D.new()
	# Buildings and walls become holes.
	for b: Array in session.view.city.boxes_in(Rect2(x0, z0, TILE, TILE)):
		var xf: Transform3D = b[0]
		var size: Vector3 = b[1]
		var pts := PackedVector3Array()
		for c in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
			pts.append(xf * Vector3(c.x * size.x * 0.5, -size.y * 0.5, c.z * size.z * 0.5))
		src.add_projected_obstruction(pts, xf.origin.y - size.y * 0.5 - 1.0, size.y + 2.0, true)
	_tiles[k] = {"rid": RID(), "state": "baking"}
	_baking = true
	var grown := AABB(aabb.position - Vector3(4, 0, 4), aabb.size + Vector3(8, 0, 8))
	var terrain := session.view.terrain
	if terrain == null:
		_start_bake(k, nm, src, PackedVector3Array())
		return
	# The terrain is only read here (the game doesn't edit it while playing).
	var g := {"k": k, "nm": nm, "src": src, "faces": PackedVector3Array()}
	g.task = WorkerThreadPool.add_task(func() -> void: g.faces = terrain.nav_faces(grown), false, "nav tile terrain")
	_gather = g


func _start_bake(k: Vector2i, nm: NavigationMesh, src: NavigationMeshSourceGeometryData3D, faces: PackedVector3Array) -> void:
	if _closed or not _tiles.has(k):
		_baking = false
		return
	if not faces.is_empty():
		src.add_faces(faces, Transform3D.IDENTITY)
	elif parse_root:
		nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		nm.geometry_collision_mask = PhysicsLayers.WORLD
		NavigationServer3D.parse_source_geometry_data(nm, src, parse_root)
	NavigationServer3D.bake_from_source_geometry_data_async(nm, src, _on_baked.bind(k, nm))


func _on_baked(k: Vector2i, nm: NavigationMesh) -> void:
	_baking = false
	if _closed or not _tiles.has(k):
		return
	var rid := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(rid, _map)
	NavigationServer3D.region_set_navigation_mesh(rid, nm)
	_tiles[k] = {"rid": rid, "state": "ready", "polys": nm.get_polygon_count()}


func next_point(rec: NpcRecord, from: Vector3, target: Vector3) -> Vector3:
	if not is_ready_at(from) or not is_ready_at(target):
		_paths.erase(rec.id)
		return target
	var now := session.now()
	var p: Dictionary = _paths.get(rec.id, {})
	if p.is_empty() or (p.target as Vector3).distance_to(target) > 2.0 or now - float(p.t) > REPATH:
		var path := NavigationServer3D.map_get_path(_map, from, target, true)
		if path.size() < 2:
			_paths.erase(rec.id)
			return target
		p = {"path": path, "i": 1, "target": target, "t": now}
		_paths[rec.id] = p
	var path: PackedVector3Array = p.path
	var i := int(p.i)
	while i < path.size() - 1 and Vector2(path[i].x - from.x, path[i].z - from.z).length() < 0.8:
		i += 1
	p.i = i
	return path[i]


func forget(rec_id: String) -> void:
	_paths.erase(rec_id)


func path_of(rec_id: String) -> PackedVector3Array:
	return _paths.get(rec_id, {}).get("path", PackedVector3Array())


func debug_draw(dd: DebugDraw, focus: Vector3) -> void:
	if not dd.is_on("nav"):
		return
	for k: Vector2i in _tiles:
		var t: Dictionary = _tiles[k]
		var col := Color(0.3, 1.0, 0.6) if t.state == "ready" else Color(1.0, 0.8, 0.2)
		var x0 := k.x * TILE
		var z0 := k.y * TILE
		dd.ground_outline(PackedVector2Array([Vector2(x0, z0), Vector2(x0 + TILE, z0), Vector2(x0 + TILE, z0 + TILE), Vector2(x0, z0 + TILE)]), col, true, 0.5)
		if t.state == "ready":
			dd.text(Vector3(x0 + TILE * 0.5, dd.ground(x0 + TILE * 0.5, z0 + TILE * 0.5) + 2.0, z0 + TILE * 0.5), "nav %d polys" % int(t.get("polys", 0)), col, 32)
	for rid: String in _paths:
		var path: PackedVector3Array = _paths[rid].path
		for i in range(1, path.size()):
			dd.line(path[i - 1] + Vector3.UP * 0.5, path[i] + Vector3.UP * 0.5, Color(0.3, 1.0, 0.9), true)


## {tiles, ready, baking, paths, polys} for the console.
func status() -> Dictionary:
	var polys := 0
	for t: Dictionary in _tiles.values():
		polys += int(t.get("polys", 0))
	return {"tiles": _tiles.size(), "ready": ready_count(), "baking": _baking, "paths": _paths.size(), "polys": polys}


## Drops every tile so they bake again around the focus (after editing what they stand on).
func rebuild() -> int:
	var n := _tiles.size()
	for t: Dictionary in _tiles.values():
		if t.state == "ready":
			NavigationServer3D.free_rid(t.rid)
	_tiles.clear()
	_paths.clear()
	return n


func free_all() -> void:
	_closed = true
	if not _gather.is_empty():  # the worker still reads the terrain: let it finish first
		WorkerThreadPool.wait_for_task_completion(_gather.task)
		_gather = {}
	for t: Dictionary in _tiles.values():
		if t.state == "ready":
			NavigationServer3D.free_rid(t.rid)
	_tiles.clear()
	_paths.clear()
