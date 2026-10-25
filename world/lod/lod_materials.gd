## Turns ordinary materials into per-object-LOD materials (lod_lit shaders) for a given
## distance band, and builds merged meshes that remember each object's centre (CUSTOM0)
## so even a merged chunk can switch detail building by building.
class_name LodMaterials
extends RefCounted

const LIT := preload("res://world/lod/lod_lit.gdshader")
const LIT_2S := preload("res://world/lod/lod_lit_2s.gdshader")

static var _mats := {}
static var _meshes := {}


## Material with the same look as `src`, visible only within [begin, end) (metres at scale 1).
static func banded(src: Material, begin: float, end: float, merged := false) -> ShaderMaterial:
	var key := "%d_%s_%s_%s" % [src.get_instance_id() if src else 0, begin, end, merged]
	if _mats.has(key):
		return _mats[key]
	var two_sided := false
	var m := ShaderMaterial.new()
	if src is BaseMaterial3D:
		var b := src as BaseMaterial3D
		two_sided = b.cull_mode == BaseMaterial3D.CULL_DISABLED
		m.set_shader_parameter("albedo", b.albedo_color)
		m.set_shader_parameter("use_texture", b.albedo_texture != null)
		m.set_shader_parameter("albedo_texture", b.albedo_texture)
		m.set_shader_parameter("roughness", b.roughness)
		m.set_shader_parameter("metallic", b.metallic)
		m.set_shader_parameter("specular", b.metallic_specular)
		m.set_shader_parameter("use_instance_color", b.has_meta("instance_tint"))
		m.set_shader_parameter("tint_palette", tint_palette)
	m.shader = LIT_2S if two_sided else LIT
	m.set_shader_parameter("lod_begin", begin)
	m.set_shader_parameter("lod_end", end)
	m.set_shader_parameter("center_from_custom0", merged)
	_mats[key] = m
	return m


## A banded material with a fixed tint baked into its albedo (single nodes: e.g. one of
## the roof colours), shared by every node using that colour.
static func tinted(banded_mat: ShaderMaterial, tint: Color) -> ShaderMaterial:
	var key := "tint_%d_%s" % [banded_mat.get_instance_id(), tint.to_html()]
	if _mats.has(key):
		return _mats[key]
	var m := banded_mat.duplicate() as ShaderMaterial
	var base: Color = m.get_shader_parameter("albedo")
	m.set_shader_parameter("albedo", base * tint)
	m.set_shader_parameter("use_instance_color", false)
	_mats[key] = m
	return m


## Copy of `mesh` whose surfaces use banded materials (cached).
static func banded_mesh(mesh: Mesh, begin: float, end: float) -> ArrayMesh:
	var key := "%d_%s_%s" % [mesh.get_instance_id(), begin, end]
	if _meshes.has(key):
		return _meshes[key]
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(s))
		out.surface_set_material(s, banded(mesh.surface_get_material(s), begin, end))
	_meshes[key] = out
	return out


## Colours referenced by CUSTOM0.w in merged meshes (roof colours).
static var tint_palette: PackedVector3Array = PackedVector3Array()


## Merges many [mesh, transform, tint index] objects into one mesh (one surface per
## material), storing each object's world centre in CUSTOM0.xyz and its tint palette index
## in CUSTOM0.w (-1 = none), so the shader can switch and tint each object individually.
## Split in two so the heavy part can run on worker threads:
##   merge_arrays (any thread, pure data) -> arrays_to_mesh (main thread).
static func merge_banded(items: Array, begin: float, end: float) -> ArrayMesh:
	return arrays_to_mesh(merge_arrays(items), begin, end)


static func merge_arrays(items: Array) -> Dictionary:
	var groups := {}  # material -> {v, n, uv, c, i}
	for item in items:
		var mesh: Mesh = item[0]
		var xf: Transform3D = item[1]
		var tint_idx: float = float(item[2]) if item.size() > 2 else -1.0
		var rot := Transform3D(xf.basis.orthonormalized(), Vector3.ZERO)
		var tag := PackedFloat32Array([xf.origin.x, xf.origin.y, xf.origin.z, tint_idx])
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s)
			if not groups.has(mat):
				groups[mat] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(),
					"c": PackedFloat32Array(), "i": PackedInt32Array()}
			var g: Dictionary = groups[mat]
			var arr := _arrays(mesh, s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n := verts.size()
			var gv: PackedVector3Array = g.v
			var gn: PackedVector3Array = g.n
			var guv: PackedVector2Array = g.uv
			var gc: PackedFloat32Array = g.c
			var base := gv.size()
			# Bulk (engine-side) transforms; only the index offset is a script loop.
			gv.append_array(xf * verts)
			var nrm = arr[Mesh.ARRAY_NORMAL]
			gn.append_array(rot * (nrm as PackedVector3Array) if nrm != null else _filled3(n, Vector3.UP))
			var uvs = arr[Mesh.ARRAY_TEX_UV]
			guv.append_array(uvs if uvs != null else _filled2(n))
			gc.append_array(_repeat(tag, n))
			g.v = gv
			g.n = gn
			g.uv = guv
			g.c = gc
			var idx = arr[Mesh.ARRAY_INDEX]
			var gi: PackedInt32Array = g.i
			if idx == null:
				for k in n:
					gi.append(base + k)
			else:
				var src: PackedInt32Array = idx
				var start := gi.size()
				gi.resize(start + src.size())
				for k in src.size():
					gi[start + k] = src[k] + base
			g.i = gi
	return groups


static func arrays_to_mesh(groups: Dictionary, begin: float, end: float) -> ArrayMesh:
	var out := ArrayMesh.new()
	for mat in groups:
		var g: Dictionary = groups[mat]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g.v
		arrays[Mesh.ARRAY_NORMAL] = g.n
		arrays[Mesh.ARRAY_TEX_UV] = g.uv
		arrays[Mesh.ARRAY_CUSTOM0] = g.c
		arrays[Mesh.ARRAY_INDEX] = g.i
		var fmt := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
		out.surface_set_material(out.get_surface_count() - 1, banded(mat, begin, end, true))
	return out


## Surface arrays are cached per mesh: the same few meshes are merged thousands of times.
static var _arr_cache := {}
static var _arr_mutex := Mutex.new()

static func _arrays(mesh: Mesh, s: int) -> Array:
	var key := "%d_%d" % [mesh.get_instance_id(), s]
	_arr_mutex.lock()
	var a: Array = _arr_cache.get(key, [])
	_arr_mutex.unlock()
	if a.is_empty():
		a = mesh.surface_get_arrays(s)
		_arr_mutex.lock()
		_arr_cache[key] = a
		_arr_mutex.unlock()
	return a


## `values` repeated `count` times (doubling: few engine-side appends).
static func _repeat(values: PackedFloat32Array, count: int) -> PackedFloat32Array:
	var out := values.duplicate()
	var target := values.size() * count
	while out.size() * 2 <= target:
		out.append_array(out)
	if out.size() < target:
		out.append_array(out.slice(0, target - out.size()))
	return out


static func _filled3(n: int, v: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(n)
	out.fill(v)
	return out


static func _filled2(n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(n)
	return out
