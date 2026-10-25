## TerrainBackend implemented with the Terrain3D plugin (1.1+, runtime editing).
class_name Terrain3DBackend
extends TerrainBackend

const REGION_SIZE := 256

var terrain: Terrain3D
var _editor: Terrain3DEditor
var _shim: TerrainPluginShim
var _brush_img: Image
var _map_m := 0.0
var _spacing := 1.0
var _stroke_rect := Rect2()
var _stroking := false
var _brush := {}
var _instanced: Array = []
var _lod_scale := 1.0


func setup(map_m: float, spacing: float, camera: Camera3D) -> void:
	_map_m = map_m
	_spacing = spacing
	if terrain:
		terrain.queue_free()
	terrain = Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.debug_level = Terrain3D.ERROR
	terrain.free_editor_textures = false
	add_child(terrain)
	terrain.change_region_size(Terrain3D.SIZE_256)
	terrain.vertex_spacing = spacing
	terrain.collision_mode = Terrain3DCollision.DYNAMIC_GAME
	terrain.collision_radius = 96
	terrain.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON
	if camera:
		terrain.set_camera(camera)
	_setup_textures()
	var mat := terrain.material
	mat.auto_shader_enabled = false
	mat.world_background = Terrain3DMaterial.NONE
	mat.texture_filtering = Terrain3DMaterial.LINEAR_ANISOTROPIC
	mat.dual_scaling_enabled = true
	mat.macro_variation_enabled = true
	mat.projection_enabled = true
	# Runtime editor (no Godot editor involved) + our undo shim.
	_shim = TerrainPluginShim.new()
	_shim.name = "PluginShim"
	add_child(_shim)
	if undo_redo:
		_shim.undo_redo = undo_redo
	terrain.set_plugin(_shim)
	_editor = Terrain3DEditor.new()
	terrain.set_editor(_editor)
	_editor.set_terrain(terrain)
	# A fresh editor defaults to the Region tool, which overlays the region grid.
	_editor.set_tool(Terrain3DEditor.TOOL_MAX)
	_editor.set_operation(Terrain3DEditor.OP_MAX)
	_brush_img = _make_round_brush(256)


## Distance (m, × the detail scale) out to which the terrain blends the materials of the
## four nearest cells per pixel; beyond it each pixel takes one cell's material (picked
## with the blend weights, by a hash fixed in the world, so borders dither instead of
## stair-stepping). Heights, normals and colours still blend everywhere. The blend is
## Terrain3D's most expensive part (up to 4 × 3 texture pairs per pixel) and it applied
## it almost to the horizon: about half of the frame in a typical view.
const MATERIAL_BLEND_DISTANCE := 40.0
var _optimized := false


## Swaps Terrain3D's generated shader for a copy patched for speed (see
## MATERIAL_BLEND_DISTANCE). The copy is made from the shader Terrain3D generates now, so
## call it again after changing material features; editor overlays (grids, brush views)
## need the stock shader, so the editor leaves this off. Returns false (and keeps the
## stock shader) if the generated code no longer matches what the patch expects.
func optimize_shader(on: bool) -> bool:
	var mat := terrain.material
	mat.shader_override_enabled = false
	_optimized = false
	if not on:
		return true
	var stock := RenderingServer.shader_get_code(mat.get_shader_rid())
	if OS.has_environment("LUX_DUMP_TERRAIN_SHADER"):
		FileAccess.open(OS.get_environment("LUX_DUMP_TERRAIN_SHADER"), FileAccess.WRITE).store_string(stock)
	var code := patched_shader(stock, MATERIAL_BLEND_DISTANCE)
	if code == "":
		push_warning("Terrain3D shader changed: the speed patch was not applied")
		return false
	var sh := Shader.new()
	sh.code = code
	mat.shader_override = sh
	mat.shader_override_enabled = true
	_optimized = true
	return true


static func patched_shader(code: String, distance: float) -> String:
	# Terrain3D injects its editor brush preview into every shader it uses, overrides too:
	# take the copy's injected part out, or it would be declared twice.
	var ed := code.find("uniform highp sampler2D _editor_brush_texture")
	if ed >= 0:
		var end := code.find("\nvoid vertex()", ed)
		if end < 0:
			return ""
		code = code.substr(0, ed) + code.substr(end)
		code = code.replace("ALBEDO = get_decal(ALBEDO, uv);", "")
	var re := RegEx.create_from_string("\\n\\s*bool bilerp = [^;]*;")
	var m := re.search(code)
	var first := "accumulate_material(base_ddx, base_ddy, TNB, weights[3], index[3], control[3], t_weights[3],\n texture_ids[3], index_normal[3], h[3], mat);"
	var tw := " if (bilerp) {\n t_weights = "
	var rest := " if (bilerp) {\n accumulate_material("
	if m == null or code.count(first) != 1 or code.count(tw) != 1 or code.count(rest) != 1:
		return ""
	var pick := m.get_string() + """
 // Lux: blend the four cells' materials only near the camera (dithered edge).
 float lux_r = lux_hash(floor(v_vertex.xz * 2.0));
 bool lux_full = bilerp && v_vertex_xz_dist < %.1f * lod_scale * (0.75 + 0.25 * lux_hash(floor(v_vertex.xz * 2.0) + 7.0));
 int lux_k = 3;
 if (bilerp && !lux_full) {
  lux_k = lux_r < weights[0] ? 0 : lux_r < weights[0] + weights[1] ? 1 : lux_r < weights[0] + weights[1] + weights[2] ? 2 : 3;
 }""" % distance
	code = code.substr(0, m.get_start()) + pick + code.substr(m.get_end())
	code = code.replace(first, first.replace("[3]", "[lux_k]"))
	code = code.replace(tw, tw.replace("bilerp", "lux_full"))
	code = code.replace(rest, rest.replace("bilerp", "lux_full"))
	var helpers := """
global uniform float lod_scale;
// Lux: integer hash in [0, 1) (stable at large world coordinates, unlike sin hashes).
float lux_hash(vec2 p) {
 uvec2 q = uvec2(ivec2(p) + 32768);
 uint h = q.x * 1597334677u ^ q.y * 3812015801u;
 h = (h ^ (h >> 16u)) * 2246822519u;
 h ^= h >> 13u;
 return float(h & 0xFFFFFFu) / 16777216.0;
}
"""
	var at := code.find("\nfloat random(")
	if at < 0:
		return ""
	return code.substr(0, at) + helpers + code.substr(at)


func set_undo_redo(ur: UndoRedo) -> void:
	undo_redo = ur
	if _shim:
		_shim.undo_redo = ur


func _setup_textures() -> void:
	var assets := Terrain3DAssets.new()
	var list: Array[Terrain3DTextureAsset] = []
	for i in TerrainTextureSet.SLOTS.size():
		var s: Array = TerrainTextureSet.SLOTS[i]
		var t := Terrain3DTextureAsset.new()
		t.name = s[1]
		t.id = i
		t.albedo_texture = load(TerrainTextureSet.DIR + s[0] + "_ah.png")
		t.normal_texture = load(TerrainTextureSet.DIR + s[0] + "_nr.png")
		t.uv_scale = s[2]
		t.detiling_rotation = 0.25
		t.detiling_shift = 0.25
		list.append(t)
	assets.texture_list = list
	terrain.assets = assets


func import_maps(height: Image, control: Image, color: Image, origin: Vector3) -> void:
	for loc in terrain.data.get_region_locations():
		terrain.data.remove_regionl(loc, false)
	terrain.data.import_images([height, control, color], origin, 0.0, 1.0)
	terrain.data.update_maps(Terrain3DRegion.TYPE_MAX, true, false)


func get_height(pos: Vector3) -> float:
	var h := terrain.data.get_height(pos)
	return 0.0 if is_nan(h) else h


func get_normal(pos: Vector3) -> Vector3:
	var nrm := terrain.data.get_normal(pos)
	return Vector3.UP if is_nan(nrm.x) else nrm


func raycast(from: Vector3, dir: Vector3) -> Vector3:
	var hit := terrain.get_intersection(from, dir.normalized(), false)
	if is_nan(hit.x) or is_nan(hit.y) or hit.y > 1.0e30 or hit.length() > 1.0e7:
		return Vector3.INF
	return hit


func begin_stroke(tool: Tool, pos: Vector3, brush: Dictionary) -> void:
	_brush = brush
	var size: float = brush.get("size", 20.0)
	var data := {
		"size": size, "strength": float(brush.get("strength", 30.0)),
		"brush": [_brush_img, ImageTexture.create_from_image(_brush_img)],
		"height": float(brush.get("height", get_height(pos))), "slope": Vector2(0, 90),
		"invert": false, "align_to_view": false, "auto_regions": false, "gamma": 1.0,
		"brush_spin_speed": 0.0, "modifier_shift": false, "modifier_ctrl": false, "modifier_alt": false,
	}
	match tool:
		Tool.RAISE:
			_editor.set_tool(Terrain3DEditor.SCULPT)
			_editor.set_operation(Terrain3DEditor.ADD)
		Tool.LOWER:
			_editor.set_tool(Terrain3DEditor.SCULPT)
			_editor.set_operation(Terrain3DEditor.SUBTRACT)
		Tool.SMOOTH:
			_editor.set_tool(Terrain3DEditor.SCULPT)
			_editor.set_operation(Terrain3DEditor.AVERAGE)
		Tool.FLATTEN:
			_editor.set_tool(Terrain3DEditor.HEIGHT)
			_editor.set_operation(Terrain3DEditor.REPLACE)
		Tool.HOLES:
			_editor.set_tool(Terrain3DEditor.HOLES)
			_editor.set_operation(Terrain3DEditor.SUBTRACT if brush.get("erase", false) else Terrain3DEditor.ADD)
		_:
			return
	_editor.set_brush_data(data)
	_stroking = true
	_stroke_rect = Rect2(Vector2(pos.x, pos.z) - Vector2(size, size) * 0.5, Vector2(size, size))
	_editor.start_operation(pos)
	_editor.operate(pos, 0.0)


func stroke(pos: Vector3) -> void:
	if not _stroking:
		return
	var size: float = _brush.get("size", 20.0)
	_stroke_rect = _stroke_rect.merge(Rect2(Vector2(pos.x, pos.z) - Vector2(size, size) * 0.5, Vector2(size, size)))
	_editor.operate(pos, 0.0)


func end_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	_editor.stop_operation()
	_editor.set_tool(Terrain3DEditor.TOOL_MAX)
	terrain.collision.update(Vector2i.MAX, true)
	stroke_finished.emit(_stroke_rect)


func world_to_pixel(pos: Vector3) -> Vector2i:
	return Vector2i(floori((pos.x + _map_m * 0.5) / _spacing), floori((pos.z + _map_m * 0.5) / _spacing))


func pixel_to_world(px: Vector2i) -> Vector3:
	return Vector3(px.x * _spacing - _map_m * 0.5, 0.0, px.y * _spacing - _map_m * 0.5)


func full_res() -> int:
	return roundi(_map_m / _spacing)


## Iterates the regions overlapping a pixel rectangle: f(region, rect_in_region, offset_in_rect).
func _for_regions(rect: Rect2i, f: Callable) -> void:
	var half_px := full_res() / 2
	var r0 := Vector2i(floori(float(rect.position.x - half_px) / REGION_SIZE), floori(float(rect.position.y - half_px) / REGION_SIZE))
	var r1 := Vector2i(floori(float(rect.end.x - 1 - half_px) / REGION_SIZE), floori(float(rect.end.y - 1 - half_px) / REGION_SIZE))
	for ry in range(r0.y, r1.y + 1):
		for rx in range(r0.x, r1.x + 1):
			var region := terrain.data.get_region(Vector2i(rx, ry))
			if region == null:
				continue
			var reg_px := Rect2i(Vector2i(rx, ry) * REGION_SIZE + Vector2i(half_px, half_px), Vector2i(REGION_SIZE, REGION_SIZE))
			var part := reg_px.intersection(rect)
			if part.size.x <= 0 or part.size.y <= 0:
				continue
			f.call(region, Rect2i(part.position - reg_px.position, part.size), part.position - rect.position)


static func _format(map_type: int) -> Image.Format:
	return Image.FORMAT_RGBA8 if map_type == Terrain3DRegion.TYPE_COLOR else Image.FORMAT_RF


func _read_rect(rect: Rect2i, map_type: int) -> PackedByteArray:
	var out := Image.create_empty(rect.size.x, rect.size.y, false, _format(map_type))
	_for_regions(rect, func(region: Terrain3DRegion, src: Rect2i, dst: Vector2i) -> void:
		var img: Image = region.get_map(map_type)
		if img.get_format() != out.get_format():
			img = img.duplicate()
			img.convert(out.get_format())
		out.blit_rect(img, src, dst))
	return out.get_data()


func _write_rect(rect: Rect2i, map_type: int, bytes: PackedByteArray) -> void:
	var src := Image.create_from_data(rect.size.x, rect.size.y, false, _format(map_type), bytes)
	_for_regions(rect, func(region: Terrain3DRegion, dst: Rect2i, from: Vector2i) -> void:
		var img: Image = region.get_map(map_type)
		if img.get_format() != src.get_format():
			img.convert(src.get_format())
		img.blit_rect(src, Rect2i(from, dst.size), dst.position)
		region.set_map(map_type, img)
		region.set_modified(true)
		region.set_edited(true)
		if map_type == Terrain3DRegion.TYPE_HEIGHT:
			region.calc_height_range())
	terrain.data.update_maps(map_type, false, false)
	_for_regions(rect, func(region: Terrain3DRegion, _a: Rect2i, _b: Vector2i) -> void: region.set_edited(false))
	if map_type == Terrain3DRegion.TYPE_HEIGHT:
		terrain.collision.update(Vector2i.MAX, true)


func read_heights(rect: Rect2i) -> PackedFloat32Array:
	return _read_rect(rect, Terrain3DRegion.TYPE_HEIGHT).to_float32_array()


func write_heights(rect: Rect2i, heights: PackedFloat32Array) -> void:
	_write_rect(rect, Terrain3DRegion.TYPE_HEIGHT, heights.to_byte_array())


func read_control(rect: Rect2i) -> PackedInt32Array:
	return _read_rect(rect, Terrain3DRegion.TYPE_CONTROL).to_int32_array()


func write_control(rect: Rect2i, control: PackedInt32Array) -> void:
	_write_rect(rect, Terrain3DRegion.TYPE_CONTROL, control.to_byte_array())


func read_color(rect: Rect2i) -> PackedByteArray:
	return _read_rect(rect, Terrain3DRegion.TYPE_COLOR)


func write_color(rect: Rect2i, rgba: PackedByteArray) -> void:
	_write_rect(rect, Terrain3DRegion.TYPE_COLOR, rgba)


func full_height_image() -> Image:
	return terrain.data.layered_to_image(Terrain3DRegion.TYPE_HEIGHT)


func setup_instancer(entries: Array) -> void:
	_instanced = entries
	for i in entries.size():
		var e: Dictionary = entries[i]
		var m := Terrain3DMeshAsset.new()
		m.name = e.id
		# Prefer the pre-built LOD chain (LOD0..LODn, maybe impostor cards last).
		var scene := LodSettings.lod_scene(e.id)
		m.set_scene_file(scene if scene else load(e.path))
		m.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON if e.get("shadows", false) else RenderingServer.SHADOW_CASTING_SETTING_OFF
		_set_ranges(m, e, _lod_scale)
		terrain.assets.set_mesh_asset(i, m)
	terrain.assets.update_mesh_list()


## LOD distances for every instanced mesh = category tiers × detail scale.
## Terrain3D rebuilds everything on each LOD setter, so the new ranges are set with its
## change notifications paused, then regions are rebuilt a few per frame, nearest first
## (no hitch). Until that finishes, vegetation_scale() reports the smaller of the old and
## new scale so far-tree cards never leave a gap.
func apply_lod_scale(scale: float) -> void:
	var old := _lod_scale
	_lod_scale = scale
	if terrain == null or terrain.assets == null or _instanced.is_empty():
		return
	var paused := []
	for i in _instanced.size():
		var m := terrain.assets.get_mesh_asset(i)
		if m == null:
			continue
		for c in m.get_signal_connection_list("instancer_setting_changed"):
			paused.append([m, c.callable])
			m.instancer_setting_changed.disconnect(c.callable)
		_set_ranges(m, _instanced[i], scale)
	for p in paused:
		(p[0] as Object).connect("instancer_setting_changed", p[1])
	_transition_scale = minf(old, scale) if _rebuild_queue.is_empty() else minf(_transition_scale, scale)
	_queue_rebuild()


func _set_ranges(m: Terrain3DMeshAsset, e: Dictionary, scale: float) -> void:
	var cat: String = e.category
	var tiers := LodSettings.tiers(cat, scale)
	var impostor := LodSettings.has_impostor(e.id)
	# Impostor cards are drawn by ImpostorLayer (one draw call per region), so the
	# instancer stops at the last real model.
	var count := mini(m.get_lod_count() - (1 if impostor else 0), tiers.size())
	m.last_lod = count - 1
	# The last real level always reaches where the next thing takes over: the impostors
	# (plus half a 32 m cell: the instancer switches per cell, so no gap) or the view limit.
	var last_end := tiers[tiers.size() - 2] + 23.0 * terrain.vertex_spacing if impostor else tiers[-1]
	for l in count:
		m.set_lod_range(l, last_end if l == count - 1 else tiers[l])
	m.fade_margin = last_end * 0.05
	m.last_shadow_lod = mini(int(LodSettings.SHADOW_LODS.get(cat, 0)), count - 1)


var _rebuild_queue: Array[Vector2i] = []
var _transition_scale := 1.0
## Terrain3D does the rebuild work later in the frame (the call itself returns at once),
## so the budget is a number of regions per frame, not a time.
const REBUILD_REGIONS_PER_FRAME := 4


func _queue_rebuild() -> void:
	var cam := terrain.get_camera()
	var here := cam.global_position if cam else Vector3.ZERO
	var size := REGION_SIZE * _spacing
	_rebuild_queue.assign(terrain.data.get_region_locations())
	_rebuild_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Vector2((a.x + 0.5) * size - here.x, (a.y + 0.5) * size - here.z).length() \
			< Vector2((b.x + 0.5) * size - here.x, (b.y + 0.5) * size - here.z).length())


func _process(_delta: float) -> void:
	Perf.begin(&"terrain_rebuild")
	_process_body(_delta)
	Perf.end(&"terrain_rebuild")


func _process_body(_delta: float) -> void:
	if _rebuild_queue.is_empty():
		return
	for i in mini(REBUILD_REGIONS_PER_FRAME, _rebuild_queue.size()):
		# rebuild_all=false: only this region (true would destroy every region's MMIs).
		terrain.instancer.update_mmis(-1, _rebuild_queue.pop_front(), false)
	if _rebuild_queue.is_empty():
		_transition_scale = _lod_scale


func set_texture_extras(on: bool) -> void:
	var mat := terrain.material
	if mat.dual_scaling_enabled == on and mat.projection_enabled == on:
		return
	mat.dual_scaling_enabled = on
	mat.projection_enabled = on
	# Terrain3D generated a new shader: patch that one.
	if _optimized:
		optimize_shader(true)


func is_rebuilding() -> bool:
	return not _rebuild_queue.is_empty()


## Scale the vegetation is (at least) drawn at right now — see apply_lod_scale.
func vegetation_scale() -> float:
	return _lod_scale if _rebuild_queue.is_empty() else _transition_scale


func region_rects() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var half_px := full_res() / 2
	for loc: Vector2i in terrain.data.get_region_locations():
		out.append(Rect2i(loc * REGION_SIZE + Vector2i(half_px, half_px), Vector2i(REGION_SIZE, REGION_SIZE)))
	return out


func set_region_instances(region_px: Rect2i, mesh_id: int, xforms: Array[Transform3D]) -> void:
	var half_px := full_res() / 2
	var loc := Vector2i(floori(float(region_px.position.x - half_px) / REGION_SIZE), floori(float(region_px.position.y - half_px) / REGION_SIZE))
	terrain.instancer.clear_by_location(loc, mesh_id)
	if xforms.is_empty():
		return
	var colors := PackedColorArray()
	colors.resize(xforms.size())
	colors.fill(Color.WHITE)
	terrain.instancer.add_transforms(mesh_id, xforms, colors, false)


## Instance transforms of one region in world space: {mesh_id: Array[Transform3D]}.
func region_instances(region_px: Rect2i) -> Dictionary:
	var half_px := full_res() / 2
	var loc := Vector2i(floori(float(region_px.position.x - half_px) / REGION_SIZE), floori(float(region_px.position.y - half_px) / REGION_SIZE))
	var region := terrain.data.get_region(loc)
	var out := {}
	if region == null:
		return out
	var origin := Vector3(loc.x * REGION_SIZE * _spacing, 0.0, loc.y * REGION_SIZE * _spacing)
	var inst: Dictionary = region.instances
	for mid in inst:
		var list: Array = []
		var cells: Dictionary = inst[mid]
		for cell in cells:
			for xf: Transform3D in cells[cell][0]:
				list.append(Transform3D(xf.basis, xf.origin + origin))
		out[mid] = list
	return out


func nav_faces(aabb: AABB) -> PackedVector3Array:
	return terrain.generate_nav_mesh_source_geometry(aabb, false)


func _region_rect_at(pos: Vector3) -> Rect2i:
	var px := world_to_pixel(pos)
	for r in region_rects():
		if r.has_point(px):
			return r
	return Rect2i()


func instances_near(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	var a := world_to_pixel(pos - Vector3(radius, 0, radius))
	var b := world_to_pixel(pos + Vector3(radius, 0, radius))
	var area := Rect2i(a, b - a + Vector2i.ONE)
	for rect in region_rects():
		if not rect.intersects(area):
			continue
		var inst := region_instances(rect)
		for mid: int in inst:
			for xf: Transform3D in inst[mid]:
				if Vector2(xf.origin.x - pos.x, xf.origin.z - pos.z).length() <= radius:
					out.append({"mesh_id": mid, "position": xf.origin})
	return out


func remove_instance_near(mesh_id: int, pos: Vector3, eps: float) -> bool:
	var rect := _region_rect_at(pos)
	if rect.size == Vector2i.ZERO:
		return false
	var inst := region_instances(rect)
	var list: Array = inst.get(mesh_id, [])
	var best := -1
	var best_d := eps
	for i in list.size():
		var d := Vector2((list[i] as Transform3D).origin.x - pos.x, (list[i] as Transform3D).origin.z - pos.z).length()
		if d <= best_d:
			best_d = d
			best = i
	if best < 0:
		return false
	list.remove_at(best)
	var xforms: Array[Transform3D] = []
	xforms.assign(list)
	set_region_instances(rect, mesh_id, xforms)
	var half_px := full_res() / 2
	var loc := Vector2i(floori(float(rect.position.x - half_px) / REGION_SIZE), floori(float(rect.position.y - half_px) / REGION_SIZE))
	terrain.instancer.update_mmis(mesh_id, loc, true)
	return true


func refresh_instances() -> void:
	terrain.instancer.update_mmis(-1, Vector2i.MAX, true)


func snap_instances(rect: Rect2) -> void:
	terrain.instancer.update_transforms(AABB(Vector3(rect.position.x, -1000.0, rect.position.y), Vector3(rect.size.x, 4000.0, rect.size.y)))


func enable_grass(texture_id: int) -> void:
	var old := get_node_or_null("Grass")
	if old:
		old.free()
	var scene: PackedScene = load("res://addons/terrain_3d/extras/particle_example/Terrain3DParticles.tscn")
	var g: Node3D = scene.instantiate()
	g.name = "Grass"
	var pm: ShaderMaterial = (g.get("process_material") as ShaderMaterial).duplicate()
	pm.set_shader_parameter("texture_filter", texture_id)
	g.set("process_material", pm)
	add_child(g)
	g.set("instance_spacing", 0.375)
	g.set("terrain", terrain)


func set_focus(node: Node3D, radius := 64.0) -> void:
	terrain.set_collision_target(node)
	terrain.collision_radius = int(radius)


func save_to(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for loc in terrain.data.get_region_locations():
		terrain.data.save_region(loc, dir, false)


func load_from(dir: String) -> void:
	terrain.data.load_directory(dir)


static func _make_round_brush(size: int) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_RF)
	var c := size * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - c, y + 0.5 - c).length() / c
			var v := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(v * v * (3.0 - 2.0 * v), 0, 0))
	return img
