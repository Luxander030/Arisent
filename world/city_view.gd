## Draws a generated city (map.city) with three levels of detail, switched per building on
## the GPU (world/lod/lod_common.gdshaderinc):
## - LOD0 (full kit models) and LOD1 (simplified; for medieval houses the same full kit
##   pieces, so one node covers both): one node per building — the engine culls each
##   exactly by distance, view and occlusion, so hidden heavy models are never sent to the
##   GPU (merged LOD1 chunks used to send ~4 M triangles the shader then threw away);
## - LOD2 (box + roof): merged per 320 m chunk into one
##   mesh per material whose vertices remember their building's centre and roof colour;
## - shadows come only from LOD2 (box + roof, ~30 triangles): an invisible shadow-only
##   merged copy per 192 m chunk — the same outline, a fraction of the shadow-pass cost.
## Distances: LodSettings tiers × the detail scale.
## Occluders: a box a little inside each building and wall segment, so the renderer skips
## whatever they hide (rendering/occlusion_culling/use_occlusion_culling).
## Also the wall, towers and simple box collision. Respects overrides (deleted buildings).
class_name CityView
extends Node3D

const MODERN_BLOCKS := ["a", "b", "c", "d", "f", "g", "h", "i", "l"]
const MODERN_TOWERS := ["a", "b", "c", "d", "e"]
## Chunk size per level (LOD0, LOD1, LOD2): small where models are heavy, so buildings
## hidden by the shader are rarely sent to the GPU at all.
const CHUNKS := [96.0, 192.0, 320.0]
const SHADOW_PROXY := 3  ## pseudo-level id for the shadow-only LOD2 copies (192 m chunks)

var _body: StaticBody3D
var building_count := 0
var _shapes := {}  ## building key -> CollisionShape3D
## Collision boxes by BOX_CELL grid cell of their centre: [[Transform3D, size]]. Lets
## boxes_in look at a few cells instead of every box in the city (it scanned ~7000 boxes
## for each navigation tile: 6 ms on the main thread, twice a second while tiles baked).
var _box_grid := {}
var _box_reach := 0.0  ## the largest box's centre-to-corner distance (XZ)
const BOX_CELL := 64.0
var _lod_scale := 1.0
var build_ms := 0  ## time spent merging chunk meshes (diagnostics)
var _occluders := {}  ## chunk -> [PackedVector3Array vertices, PackedInt32Array indices]


func build(city: Dictionary, overrides: Dictionary, terrain: TerrainBackend) -> void:
	for c in get_children():
		c.queue_free()
	building_count = 0
	_shapes.clear()
	_occluders.clear()
	_box_grid.clear()
	_box_reach = 0.0
	if city.is_empty():
		return
	_body = StaticBody3D.new()
	_body.name = "CityCollision"
	add_child(_body)
	LodMaterials.tint_palette = PackedVector3Array()
	for c in BuildingKit.ROOF_COLORS:
		var lin: Color = (c as Color).srgb_to_linear()  # plain vec3 uniforms are linear
		LodMaterials.tint_palette.append(Vector3(lin.r, lin.g, lin.b))
	var groups := {}  # mesh -> Array[Transform3D]   (city wall and towers: no LOD)
	var near := {}    # [chunk, category, level] -> {mesh -> Array[Transform3D]}   (LOD0, LOD1)
	var far := {}     # [chunk, category] -> {mesh -> Array[Transform3D]}           (LOD2, merged)
	for b: Dictionary in city.get("buildings", []):
		var ov: Dictionary = overrides.get("city:" + str(b.key), {})
		if ov.get("deleted", false):
			continue
		var pos := Vector2(b.x, b.z)
		var rot: float = b.rot
		var w: float = b.w
		var d: float = b.d
		var y := _ground(terrain, pos, rot, w, d)
		var lods: Array[Mesh] = []  # LOD0, LOD1, LOD2
		var category := "city_medieval"
		var scale := 1.0
		var height := 8.0
		var occluder := AABB()  # in the building's own space (before `scale`)
		match str(b.style):
			"medieval", "keep":
				var keep: bool = b.kind == "keep"
				var wm := clampi(roundi(w / BuildingKit.MODULE), 2, 9)
				var dm := clampi(roundi(d / BuildingKit.MODULE), 2, 9)
				var floors: int = maxi(1, int(b.floors))
				# The middle level uses the full kit pieces too: the simplified pieces saved only
				# a few dozen triangles per panel but turned windows into smeared patches,
				# which showed from ~40 m when the adaptive detail scale dropped.
				var full := BuildingKit.medieval(wm, dm, floors, int(b.variant), keep, 0)
				lods = [full, full, BuildingKit.medieval_lod(wm, dm, floors, int(b.variant), keep)]
				height = floors * BuildingKit.MODULE + 3.0
				# Walls stand on y = 0 up to the eaves (floors × MODULE), the foundation below.
				var half := Vector3(wm, 0.0, dm) * BuildingKit.MODULE * 0.5 - Vector3(OCCLUDER_INSET, 0.0, OCCLUDER_INSET)
				occluder = AABB(Vector3(-half.x, -2.5, -half.z), Vector3(half.x * 2.0, floors * BuildingKit.MODULE - 0.2 + 2.5, half.z * 2.0))
			"modern":
				var tower: bool = b.kind == "tower"
				var list: Array = MODERN_TOWERS if tower else MODERN_BLOCKS
				var letter: String = list[int(b.variant) % list.size()]
				var id := "modern.%s_%s" % ["skyscraper" if tower else "building", letter]
				var path := "res://assets/models/modern/building-%s%s.glb" % ["skyscraper-" if tower else "", letter]
				lods = [BuildingKit.model_lod(id, path, 0), BuildingKit.model_lod(id, path, 1), BuildingKit.model_lod(id, path, 2)]
				category = "building"
				scale = 12.0
				height = lods[0].get_aabb().size.y * scale
				# Lower half, shrunk 15 % a side (setbacks, open ground floors).
				var a := lods[0].get_aabb()
				occluder = AABB(a.position + Vector3(a.size.x, 0.0, a.size.z) * 0.15, a.size * Vector3(0.7, 0.5, 0.7))
		var xf := Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * scale), Vector3(pos.x, y, pos.y))
		var tint_idx := int(b.variant) % BuildingKit.ROOF_COLORS.size() if category == "city_medieval" else -1
		if lods[1] == lods[0]:
			_add_near_building(lods[0], xf, tint_idx, category, 0, 1)
		else:
			_add_near_building(lods[0], xf, tint_idx, category, 0, 0)
			_add_near_building(lods[1], xf, tint_idx, category, 1, 1)
		_push(near, [_chunk(pos, 1), category, SHADOW_PROXY], lods[2], [_shadow_xf(xf, lods[2], scale), tint_idx])
		_push(far, [_chunk(pos, 2), category], lods[2], [xf, tint_idx])
		if occluder.has_volume():
			_occluder_box(pos, xf, occluder)
		var cs := _add_box(Vector3(pos.x, y + height * 0.5, pos.y), rot, Vector3(w, height, d))
		cs.set_meta("city_key", str(b.key))
		_shapes[str(b.key)] = cs
		building_count += 1
	var wall: Dictionary = city.get("wall", {})
	if not wall.is_empty():
		_build_wall(wall, terrain, groups)
	_build_occluders()
	for mesh in groups:
		var items := []
		for xf in groups[mesh]:
			items.append([xf, Color.WHITE])
		_add_multimesh(mesh, items, "building", -1)
	# LOD1, shadow proxies and LOD2 are merged per chunk. The heavy part (building the
	# arrays) runs on worker threads; mesh data is fetched here first so the threads never
	# touch the renderer.
	var t0 := Time.get_ticks_msec()
	var jobs := []  # [items, begin, end, category, level]
	for key: Array in near:
		var tiers := LodSettings.tiers(key[1])
		var level: int = key[2]
		var proxy := level == SHADOW_PROXY
		jobs.append([_items(near[key]), 0.0 if proxy else tiers[level - 1], tiers[2] if proxy else tiers[level], key[1], level])
	for key: Array in far:
		var tiers := LodSettings.tiers(key[1])
		jobs.append([_items(far[key]), tiers[1], tiers[2], key[1], 2])
	for job in jobs:
		for it in job[0]:
			for si in (it[0] as Mesh).get_surface_count():
				LodMaterials._arrays(it[0], si)
	var results := []
	results.resize(jobs.size())
	var task := func(i: int) -> void: results[i] = LodMaterials.merge_arrays(jobs[i][0])
	var tid := WorkerThreadPool.add_group_task(task, jobs.size(), -1, true, "city merge")
	WorkerThreadPool.wait_for_group_task_completion(tid)
	for i in jobs.size():
		var job: Array = jobs[i]
		var mi := MeshInstance3D.new()
		mi.mesh = LodMaterials.arrays_to_mesh(results[i], job[1], job[2])
		_set_tier(mi, job[3], job[4])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if int(job[4]) == SHADOW_PROXY \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	build_ms = Time.get_ticks_msec() - t0
	apply_lod_scale(_lod_scale)


## Detail switching itself happens per building in the shader (global `lod_scale`);
## here we only cull whole chunks that are entirely outside a level's distance band.
func apply_lod_scale(scale: float) -> void:
	_lod_scale = scale
	for c in get_children():
		if c is GeometryInstance3D and c.has_meta("lod_category"):
			var gi := c as GeometryInstance3D
			var tiers := LodSettings.tiers(gi.get_meta("lod_category"), scale)
			var level: int = gi.get_meta("lod_level")
			if level < 0:  # no LOD: visible to the last tier
				gi.visibility_range_end = tiers[-1]
				continue
			if gi.has_meta("lod_exact"):  # one building, levels lod_level..lod_last
				var last: int = gi.get_meta("lod_last")
				gi.visibility_range_begin = 0.0 if level == 0 else maxf(0.0, tiers[level - 1] - 5.0)
				gi.visibility_range_end = tiers[last] + 5.0
				continue
			var proxy := level == SHADOW_PROXY
			# Chunks are culled by their centre-to-corner reach.
			var reach: float = CHUNKS[1 if proxy else level] * 0.71
			var begin := 0.0 if level == 0 or proxy else tiers[level - 1]
			gi.visibility_range_begin = maxf(0.0, begin - reach)
			gi.visibility_range_end = (tiers[2] if proxy else tiers[level]) + reach


static func _items(by_mesh: Dictionary) -> Array:
	var items := []
	for mesh: Mesh in by_mesh:
		for it: Array in by_mesh[mesh]:
			items.append([mesh, it[0], it[1]])
	return items


## The shadow stand-in sits a little inside the building (SHADOW_INSET on every side and
## at the top): placed exactly on the walls and roof it would shadow the building's own
## visible surfaces in stripes (shadow acne), but it still shades the ground and others.
const SHADOW_INSET := 0.3


static func _shadow_xf(xf: Transform3D, mesh: Mesh, scale: float) -> Transform3D:
	var size := mesh.get_aabb().size * scale
	var shrink := Vector3(maxf(0.5, 1.0 - 2.0 * SHADOW_INSET / maxf(size.x, 0.01)), maxf(0.5, 1.0 - SHADOW_INSET / maxf(size.y, 0.01)),
		maxf(0.5, 1.0 - 2.0 * SHADOW_INSET / maxf(size.z, 0.01)))
	var c := mesh.get_aabb().get_center()
	c.y = mesh.get_aabb().position.y  # keep it standing on the same ground
	# Scale about the footprint's centre at ground level, in the building's own space.
	return xf * Transform3D(Basis.from_scale(shrink), c - Basis.from_scale(shrink) * c)


## Levels `level`..`last` of one building: its own node, culled exactly by distance (and by
## the view and occluders); shadows come from the shadow proxy.
func _add_near_building(mesh: Mesh, xf: Transform3D, tint_idx: int, category: String, level: int, last: int) -> void:
	var tiers := LodSettings.tiers(category)
	var mi := MeshInstance3D.new()
	mi.mesh = LodMaterials.banded_mesh(mesh, 0.0 if level == 0 else tiers[level - 1], tiers[last])
	mi.transform = xf
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_set_tier(mi, category, level)
	mi.set_meta("lod_exact", true)
	mi.set_meta("lod_last", last)
	add_child(mi)
	# Roof colour: swap the tintable surface for one of a few shared pre-tinted materials.
	if tint_idx >= 0:
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s) as ShaderMaterial
			if m and m.get_shader_parameter("use_instance_color"):
				mi.set_surface_override_material(s, LodMaterials.tinted(m, BuildingKit.ROOF_COLORS[tint_idx]))


static func _chunk(pos: Vector2, level: int) -> Vector2i:
	var c: float = CHUNKS[level]
	return Vector2i(floori(pos.x / c), floori(pos.y / c))


func _set_tier(gi: GeometryInstance3D, category: String, level: int) -> void:
	gi.set_meta("lod_category", category)
	gi.set_meta("lod_level", level)


static func _push(dict: Dictionary, key: Variant, mesh: Mesh, item: Variant) -> void:
	var by_mesh: Dictionary = dict.get(key, {})
	var arr: Array = by_mesh.get(mesh, [])
	arr.append(item)
	by_mesh[mesh] = arr
	dict[key] = by_mesh


## items: [[Transform3D, tint Color], ...]
func _add_multimesh(mesh: Mesh, items: Array, category: String, level: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = items.size()
	for i in items.size():
		mm.set_instance_transform(i, items[i][0])
		mm.set_instance_color(i, items[i][1])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	_set_tier(mmi, category, level)
	add_child(mmi)
	return mmi


## Lowest ground under the footprint, so no building floats on a slope.
func _ground(terrain: TerrainBackend, pos: Vector2, rot: float, w: float, d: float) -> float:
	var bx := Vector2(cos(rot), -sin(rot))
	var bz := Vector2(sin(rot), cos(rot))
	var y := INF
	for c in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5), Vector2.ZERO]:
		var q: Vector2 = pos + bx * c.x * w + bz * c.y * d
		y = minf(y, terrain.get_height(Vector3(q.x, 0, q.y)))
	return y - 0.2


func shape_for(key: String) -> CollisionShape3D:
	return _shapes.get(key)


## Collision boxes (buildings, walls) whose centre is near an XZ rectangle (grown by
## their size): [[Transform3D, size]]. Used to carve buildings out of navigation meshes.
func boxes_in(rect: Rect2) -> Array:
	var out: Array = []
	var r := rect.grow(_box_reach)
	var c0 := Vector2i(floori(r.position.x / BOX_CELL), floori(r.position.y / BOX_CELL))
	var c1 := Vector2i(floori(r.end.x / BOX_CELL), floori(r.end.y / BOX_CELL))
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			for b: Array in _box_grid.get(Vector2i(cx, cz), []):
				var o: Vector3 = (b[0] as Transform3D).origin
				var size: Vector3 = b[1]
				if rect.grow(maxf(size.x, size.z)).has_point(Vector2(o.x, o.z)):
					out.append(b)
	return out


func _add_box(center: Vector3, rot: float, size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = Transform3D(Basis(Vector3.UP, rot), center)
	_body.add_child(cs)
	var cell := Vector2i(floori(center.x / BOX_CELL), floori(center.z / BOX_CELL))
	if not _box_grid.has(cell):
		_box_grid[cell] = []
	(_box_grid[cell] as Array).append([cs.transform, size])
	_box_reach = maxf(_box_reach, maxf(size.x, size.z))
	return cs


func _build_wall(wall: Dictionary, terrain: TerrainBackend, groups: Dictionary) -> void:
	var pts: Array = wall.points
	var h: float = wall.height
	var t: float = wall.thickness
	var gates: Array = wall.gates
	var gw: float = wall.gate_width
	var block := BuildingKit.wall_block()
	var arr: Array = groups.get(block, [])
	for i in pts.size() - 1:
		var a := Vector2(pts[i][0], pts[i][1])
		var b := Vector2(pts[i + 1][0], pts[i + 1][1])
		var mid := (a + b) * 0.5
		var near_gate := false
		for g in gates:
			if mid.distance_to(Vector2(g[0], g[1])) < gw * 0.5 + 2.0:
				near_gate = true
				break
		if near_gate:
			continue
		var len := a.distance_to(b) + 0.4
		var rot := atan2(b.x - a.x, b.y - a.y)
		var y := minf(terrain.get_height(Vector3(a.x, 0, a.y)), terrain.get_height(Vector3(b.x, 0, b.y))) - 1.0
		# wall-block is a 1 m cube centred on x/z, base at y = 0.
		# Scale in the block's own axes (thickness, height, length), then rotate.
		var xf := Transform3D(Basis(Vector3.UP, rot) * Basis.from_scale(Vector3(t, h + 1.0, len)), Vector3(mid.x, y, mid.y))
		arr.append(xf)
		_occluder_box(Vector2(mid.x, mid.y), Transform3D(Basis(Vector3.UP, rot), Vector3(mid.x, y, mid.y)),
			AABB(Vector3(-t * 0.5, 0.0, -len * 0.5), Vector3(t, h + 1.0, len)).grow(-OCCLUDER_INSET))
		_add_box(Vector3(mid.x, y + (h + 1.0) * 0.5, mid.y), rot, Vector3(t, h + 1.0, len))
	var roof := BuildingKit.tower_roof()
	var roofs: Array = groups.get(roof, [])
	var towers: Array = wall.towers.duplicate()
	for g in gates:
		var a: float = g[2]
		var side := Vector2(-sin(a), cos(a)) * (gw * 0.5 + 4.0)
		towers.append([g[0] + side.x, g[1] + side.y])
		towers.append([g[0] - side.x, g[1] - side.y])
	for tw in towers:
		var p := Vector2(tw[0], tw[1])
		var y := terrain.get_height(Vector3(p.x, 0, p.y)) - 1.0
		arr.append(Transform3D(Basis().scaled(Vector3(7.0, h + 6.0, 7.0)), Vector3(p.x, y, p.y)))
		roofs.append(Transform3D(Basis().scaled(Vector3(7.5, 6.0, 7.5)), Vector3(p.x, y + h + 6.0, p.y)))
		_add_box(Vector3(p.x, y + (h + 6.0) * 0.5, p.y), 0.0, Vector3(7.0, h + 6.0, 7.0))
	groups[block] = arr
	groups[roof] = roofs


## How far occluders sit inside what they stand for: never in front of a visible surface.
const OCCLUDER_INSET := 0.4
const OCCLUDER_CHUNK := 320.0


func _occluder_box(pos: Vector2, xf: Transform3D, box: AABB) -> void:
	var key := Vector2i(floori(pos.x / OCCLUDER_CHUNK), floori(pos.y / OCCLUDER_CHUNK))
	if not _occluders.has(key):
		_occluders[key] = [PackedVector3Array(), PackedInt32Array()]
	var v: PackedVector3Array = _occluders[key][0]
	var idx: PackedInt32Array = _occluders[key][1]
	var base := v.size()
	for i in 8:
		v.append(xf * (box.position + box.size * Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1)))
	# 6 faces, 2 triangles each (corner i: bit 0 = x, bit 1 = y, bit 2 = z).
	for f: Array in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
		idx.append_array(PackedInt32Array([base + f[0], base + f[1], base + f[2], base + f[0], base + f[2], base + f[3]]))
	_occluders[key] = [v, idx]


func _build_occluders() -> void:
	for key: Vector2i in _occluders:
		var occ := ArrayOccluder3D.new()
		occ.set_arrays(_occluders[key][0], _occluders[key][1])
		var oi := OccluderInstance3D.new()
		oi.name = "Occluder_%d_%d" % [key.x, key.y]
		oi.occluder = occ
		add_child(oi)
	_occluders.clear()
