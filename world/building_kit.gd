## Builds building meshes ("archetypes") from the modular Kenney Fantasy Town pieces:
## stone ground floor, timber upper floors, windows and a door, plus a generated roof.
## Each archetype is merged into one mesh (one surface per material) and cached, so a
## whole city is drawn with one MultiMesh per archetype.
class_name BuildingKit
extends RefCounted

const MODULE := 3.0  ## metres per kit module
const TOWN := "res://assets/models/town/"
const ROOF_COLORS := [Color(0.62, 0.27, 0.2), Color(0.36, 0.33, 0.42), Color(0.55, 0.38, 0.22), Color(0.3, 0.42, 0.5)]

static var _cache := {}
static var _pieces := {}
static var _mats := {}


static func _piece(name: String, lod := 0) -> Array:
	## [ [mesh, surface, material, local transform], ... ] for a kit piece at a LOD level.
	var key := "%s#%d" % [name, lod]
	if _pieces.has(key):
		return _pieces[key]
	var out := []
	var lod_scene := LodSettings.lod_scene("town." + name) if lod > 0 else null
	if lod_scene:
		var m := LodSettings.lod_mesh(lod_scene, lod)
		for s in m.get_surface_count():
			out.append([m, s, m.surface_get_material(s), Transform3D()])
		_pieces[key] = out
		return out
	var scene: PackedScene = load(TOWN + name + ".glb")
	if scene:
		var inst := scene.instantiate()
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var m: Mesh = (mi as MeshInstance3D).mesh
			var local := (mi as MeshInstance3D).transform
			for s in m.get_surface_count():
				out.append([m, s, m.surface_get_material(s), local])
		inst.free()
	_pieces[key] = out
	return out


## Roof colour of a building variant — applied per instance, not baked into the mesh.
static func roof_color(variant: int) -> Color:
	return ROOF_COLORS[variant % ROOF_COLORS.size()]


## Shared white roof material, tinted per building (see LodMaterials / lod_lit shader).
static func _roof_mat() -> StandardMaterial3D:
	var m := _mat(Color.WHITE)
	m.set_meta("instance_tint", true)
	return m


static func _mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.85
		m.cull_mode = BaseMaterial3D.CULL_DISABLED  # generated roofs: winding-agnostic
		_mats[key] = m
	return _mats[key]


## Medieval house / keep. wm, dm = footprint in modules; local +Z is the front (door).
## lod 0 = full kit pieces, lod 1 = simplified pieces (see tools/lod/build_lods.gd).
static func medieval(wm: int, dm: int, floors: int, variant: int, keep := false, lod := 0) -> ArrayMesh:
	var key := "m_%d_%d_%d_%d_%s_%d" % [wm, dm, floors, variant % 2, keep, lod]
	if _cache.has(key):
		return _cache[key]
	var tools := {}  # material -> SurfaceTool
	var wood := not keep
	for f in floors:
		var ground := f == 0
		for i in wm:
			for j in dm:
				var cx := (i - (wm - 1) * 0.5)
				var cz := (j - (dm - 1) * 0.5)
				var faces := []
				if j == dm - 1: faces.append(Vector3(0, 0, 1))
				if j == 0: faces.append(Vector3(0, 0, -1))
				if i == wm - 1: faces.append(Vector3(1, 0, 0))
				if i == 0: faces.append(Vector3(-1, 0, 0))
				for face: Vector3 in faces:
					var name := _wall_piece(ground or not wood, ground and face.z > 0.0 and i == wm / 2, (i + j + f + variant % 2) % 3)
					var yaw := atan2(-face.z, face.x)  # rotate the +X panel to face `face`
					var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(cx, f, cz))
					_add_piece(tools, name, Transform3D().scaled(Vector3.ONE * MODULE) * xf, lod)
	var w := wm * MODULE
	var d := dm * MODULE
	var top := floors * MODULE
	_add_box(tools, _mat(Color(0.45, 0.42, 0.4)), Vector3(0, -1.5, 0), Vector3(w + 0.3, 3.0, d + 0.3))  # foundation
	if keep:
		_add_pyramid_roof(tools, _roof_mat(), w, d, top, minf(w, d) * 0.7)
	else:
		_add_gable_roof(tools, _roof_mat(), _mat(Color(0.86, 0.8, 0.68)), w, d, top)
	var mesh := _commit(tools)
	_cache[key] = mesh
	return mesh


## Distant version of a medieval building: plain walls + the same roof (~30 triangles).
static func medieval_lod(wm: int, dm: int, floors: int, variant: int, keep := false) -> ArrayMesh:
	var key := "lod_%d_%d_%d_%s" % [wm, dm, floors, keep]
	if _cache.has(key):
		return _cache[key]
	var tools := {}
	var w := wm * MODULE
	var d := dm * MODULE
	var top := floors * MODULE
	var wall_col := Color(0.62, 0.6, 0.58) if keep else Color(0.88, 0.82, 0.7)
	_add_box(tools, _mat(wall_col), Vector3(0, (top - 3.0) * 0.5, 0), Vector3(w, top + 3.0, d))
	if keep:
		_add_pyramid_roof(tools, _roof_mat(), w, d, top, minf(w, d) * 0.7)
	else:
		_add_gable_roof(tools, _roof_mat(), _mat(Color(0.86, 0.8, 0.68)), w, d, top)
	var mesh := _commit(tools)
	_cache[key] = mesh
	return mesh


## One wall panel. Each floor keeps to one colour family of the kit: stone pieces are
## blue-grey plaster, wood pieces brown timber. (The kit's "wall-wood-window-small" is
## plaster, not timber — mixed into a timber floor it made a brown/blue checkerboard —
## so timber floors use the glass window instead.)
static func _wall_piece(stone: bool, door: bool, v: int) -> String:
	if stone:
		if door:
			return "wall-door"
		return ["wall-window-shutters", "wall-window-small", "wall"][v]
	if door:
		return "wall-wood-door"
	return ["wall-wood-window-shutters", "wall-wood-window-glass", "wall-wood"][v]


## One surface per material. Kit pieces keep the normals they were made with (low-poly,
## flat-shaded: recomputing them smoothed every bevel into smeared gradients); the shapes
## built here (foundation, roofs, gables, distant boxes) get flat normals.
static func _commit(tools: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for m: Material in tools:
		var st: SurfaceTool = tools[m]
		if _generated(m):
			st.generate_normals()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	return mesh


## Materials made here (so their surfaces have no normals of their own yet).
static func _generated(m: Material) -> bool:
	return _mats.values().has(m)


static func _st_for(tools: Dictionary, mat: Material) -> SurfaceTool:
	if not tools.has(mat):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_smooth_group(-1)  # flat normals for the shapes built here (generate_normals)
		tools[mat] = st
	return tools[mat]


static func _add_piece(tools: Dictionary, name: String, xf: Transform3D, lod := 0) -> void:
	for e in _piece(name, lod):
		var mesh: Mesh = e[0]
		var st := _st_for(tools, e[2])
		st.append_from(mesh, e[1], xf * (e[3] as Transform3D))


static func _add_box(tools: Dictionary, mat: Material, center: Vector3, size: Vector3) -> void:
	var st := _st_for(tools, mat)
	var h := size * 0.5
	var c := [Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	for q in [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [3, 7, 6, 2]]:
		_quad(st, center + c[q[0]], center + c[q[1]], center + c[q[2]], center + c[q[3]])


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)


static func _add_gable_roof(tools: Dictionary, roof: Material, gable: Material, w: float, d: float, y: float) -> void:
	var o := 0.5  # overhang
	var along_x := w >= d
	var span := (d if along_x else w) * 0.5 + o
	var length := (w if along_x else d) * 0.5 + o
	var rise := span * 0.75
	var st := _st_for(tools, roof)
	var g := _st_for(tools, gable)
	if along_x:
		var a := Vector3(-length, y, -span); var b := Vector3(length, y, -span)
		var c := Vector3(length, y + rise, 0); var dd := Vector3(-length, y + rise, 0)
		_quad(st, a, dd, c, b)
		_quad(st, Vector3(length, y, span), c, dd, Vector3(-length, y, span))
		for sx in [-1.0, 1.0]:
			var x: float = (length - o) * sx
			var tri := [Vector3(x, y, -span + o), Vector3(x, y + rise * (span - o) / span, 0), Vector3(x, y, span - o)]
			if sx < 0: tri.reverse()
			for v in tri: g.add_vertex(v)
	else:
		var a := Vector3(-span, y, -length); var b := Vector3(-span, y, length)
		var c := Vector3(0, y + rise, length); var dd := Vector3(0, y + rise, -length)
		_quad(st, a, b, c, dd)
		_quad(st, Vector3(span, y, length), Vector3(span, y, -length), dd, c)
		for sz in [-1.0, 1.0]:
			var z: float = (length - o) * sz
			var tri := [Vector3(-span + o, y, z), Vector3(span - o, y, z), Vector3(0, y + rise * (span - o) / span, z)]
			if sz < 0: tri.reverse()
			for v in tri: g.add_vertex(v)


static func _add_pyramid_roof(tools: Dictionary, roof: Material, w: float, d: float, y: float, h: float) -> void:
	var st := _st_for(tools, roof)
	var hx := w * 0.5 + 0.6
	var hz := d * 0.5 + 0.6
	var top := Vector3(0, y + h, 0)
	var c := [Vector3(-hx, y, -hz), Vector3(hx, y, -hz), Vector3(hx, y, hz), Vector3(-hx, y, hz)]
	for i in 4:
		st.add_vertex(c[i])
		st.add_vertex(top)
		st.add_vertex(c[(i + 1) % 4])


## Wall segment / tower meshes (stone blocks) for the city wall.
static func wall_block() -> Mesh:
	return _merged_scene("wall-block")


static func tower_roof() -> Mesh:
	return _merged_scene("roof-high-point")


static func _merged_scene(name: String) -> Mesh:
	var key := "scene_" + name
	if _cache.has(key):
		return _cache[key]
	var tools := {}
	_add_piece(tools, name, Transform3D())
	var mesh := ArrayMesh.new()
	for m in tools:
		(tools[m] as SurfaceTool).commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	_cache[key] = mesh
	return mesh


## Whole-building model (modern kit) at a LOD level, from its LOD scene if built.
static func model_lod(id: String, path: String, lod: int) -> Mesh:
	var key := "model_%s_%d" % [id, lod]
	if _cache.has(key):
		return _cache[key]
	var scene := LodSettings.lod_scene(id)
	var mesh: Mesh = LodSettings.lod_mesh(scene, lod) if scene else model_mesh(path)
	_cache[key] = mesh
	return mesh


## Single mesh of a whole-building model (modern kit), merged.
static func model_mesh(path: String) -> Mesh:
	var key := "model_" + path
	if _cache.has(key):
		return _cache[key]
	var tools := {}
	var scene: PackedScene = load(path)
	var inst := scene.instantiate()
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = (mi as MeshInstance3D).mesh
		for s in m.get_surface_count():
			_st_for(tools, m.surface_get_material(s)).append_from(m, s, (mi as MeshInstance3D).transform)
	inst.free()
	var mesh := ArrayMesh.new()
	for m in tools:
		(tools[m] as SurfaceTool).commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	_cache[key] = mesh
	return mesh
