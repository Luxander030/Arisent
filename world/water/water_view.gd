## Builds the visible water: ocean plane, lake planes, river ribbons, ice + ice collision.
## Input is plain map data (dictionaries), so the game and the editor share it.
class_name WaterView
extends Node3D

const SHADER := preload("res://world/water/water.gdshader")

var _normal_a: NoiseTexture2D
var _normal_b: NoiseTexture2D
var _mask_tex: ImageTexture


func _ready() -> void:
	_normal_a = _make_normal(0.02, 11)
	_normal_b = _make_normal(0.035, 23)


## water: {"ocean": bool, "lakes": [...], "rivers": [...]} as stored in water.json.
## mask: layout-res RGB image (R ocean, G sea ice, B lake).
func build(water: Dictionary, mask: Image, map_m: float) -> void:
	for c in get_children():
		c.queue_free()
	if _normal_a == null:
		_ready()
	var m := mask.duplicate() as Image
	_dilate(m, 2)
	_mask_tex = ImageTexture.create_from_image(m)
	if water.get("ocean", false):
		_build_ocean(map_m, mask)
	for lake in water.get("lakes", []):
		_build_lake(lake, map_m)
	for rv in water.get("rivers", []):
		_build_river(rv, map_m)


func _material(mode: int, map_m: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("water_mask", _mask_tex)
	mat.set_shader_parameter("map_origin", Vector2(-map_m * 0.5, -map_m * 0.5))
	mat.set_shader_parameter("map_size", map_m)
	mat.set_shader_parameter("normal_a", _normal_a)
	mat.set_shader_parameter("normal_b", _normal_b)
	if mode == 1:
		mat.set_shader_parameter("shallow_color", Color(0.2, 0.55, 0.55))
		mat.set_shader_parameter("deep_color", Color(0.04, 0.2, 0.3))
		mat.set_shader_parameter("depth_range", 8.0)
	elif mode == 2:
		mat.set_shader_parameter("shallow_color", Color(0.3, 0.6, 0.6))
		mat.set_shader_parameter("deep_color", Color(0.08, 0.28, 0.34))
		mat.set_shader_parameter("depth_range", 3.0)
		mat.set_shader_parameter("foam_width", 0.5)
	return mat


func _ice_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.82, 0.92, 0.98)
	mat.roughness = 0.25
	mat.metallic_specular = 0.7
	mat.normal_enabled = true
	mat.normal_texture = _normal_a
	mat.normal_scale = 0.25
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(0.05, 0.05, 0.05)
	return mat


## Ocean tile resolution by distance (subdivisions, view distance in m): fine near the
## camera for the waves, coarse far away where the waves are invisible anyway.
const OCEAN_LODS := [[96, 900.0], [24, 2200.0], [4, 20000.0]]


func _build_ocean(map_m: float, mask: Image) -> void:
	# A grid of tiles, each with three resolutions switched by distance; reaches past the map.
	var tile := 512.0
	var reach := map_m * 0.5 + 1536.0
	var meshes: Array[PlaneMesh] = []
	for l in OCEAN_LODS:
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(tile, tile)
		mesh.subdivide_width = l[0]
		mesh.subdivide_depth = l[0]
		meshes.append(mesh)
	var mat := _material(0, map_m)
	var count := ceili(reach * 2.0 / tile)
	for j in count:
		for i in count:
			var begin := 0.0
			for l in OCEAN_LODS.size():
				var mi := MeshInstance3D.new()
				mi.mesh = meshes[l]
				mi.material_override = mat
				mi.position = Vector3(-reach + (i + 0.5) * tile, 0.0, -reach + (j + 0.5) * tile)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visibility_range_begin = begin
				mi.visibility_range_end = OCEAN_LODS[l][1]
				begin = OCEAN_LODS[l][1]
				add_child(mi)
	_build_sea_ice_collision(mask, map_m)


## Walkable sea ice: one thin box per horizontal run of ice cells.
func _build_sea_ice_collision(mask: Image, map_m: float) -> void:
	var n := mask.get_width()
	var cell := map_m / n
	var body := StaticBody3D.new()
	body.name = "SeaIce"
	add_child(body)
	for j in n:
		var i := 0
		while i < n:
			if mask.get_pixel(i, j).g < 0.5:
				i += 1
				continue
			var start := i
			while i < n and mask.get_pixel(i, j).g >= 0.5:
				i += 1
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3((i - start) * cell, 0.4, cell)
			shape.shape = box
			shape.position = Vector3(-map_m * 0.5 + (start + i) * 0.5 * cell, -0.2, -map_m * 0.5 + (j + 0.5) * cell)
			body.add_child(shape)


func _build_lake(lake: Dictionary, map_m: float) -> void:
	var r: Array = lake.rect  # [x0, z0, x1, z1] world
	var level: float = lake.level
	var margin := 24.0
	var size := Vector2(r[2] - r[0] + margin * 2.0, r[3] - r[1] + margin * 2.0)
	var mesh := PlaneMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.name = "Lake_%d" % int(lake.id)
	mi.mesh = mesh
	mi.position = Vector3((r[0] + r[2]) * 0.5, level, (r[1] + r[3]) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if lake.get("frozen", false):
		mi.material_override = _ice_material()
		mi.position.y += 0.05
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(size.x, 0.4, size.y)
		shape.shape = box
		shape.position.y = -0.2
		body.add_child(shape)
		mi.add_child(body)
	else:
		mi.material_override = _material(1, map_m)
	add_child(mi)


func _build_river(rv: Dictionary, map_m: float) -> void:
	var pts: Array = rv.points
	var ws: Array = rv.widths
	if pts.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dist := 0.0
	var prev := Vector3.ZERO
	for i in pts.size():
		var p := Vector3(pts[i][0], pts[i][1], pts[i][2])
		var a := Vector3(pts[maxi(i - 1, 0)][0], 0, pts[maxi(i - 1, 0)][2])
		var b := Vector3(pts[mini(i + 1, pts.size() - 1)][0], 0, pts[mini(i + 1, pts.size() - 1)][2])
		var dir := (b - a).normalized()
		var side := Vector3(-dir.z, 0.0, dir.x) * (float(ws[i]) * 0.5 + 1.0)
		if i > 0:
			dist += p.distance_to(prev)
		prev = p
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, dist / 10.0))
		st.add_vertex(p - side)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(1.0, dist / 10.0))
		st.add_vertex(p + side)
	for i in pts.size() - 1:
		var k := i * 2
		st.add_index(k)
		st.add_index(k + 2)
		st.add_index(k + 1)
		st.add_index(k + 1)
		st.add_index(k + 2)
		st.add_index(k + 3)
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _ice_material() if rv.get("frozen", false) else _material(2, map_m)
	add_child(mi)


static func _make_normal(freq: float, seed_value: int) -> NoiseTexture2D:
	var nt := NoiseTexture2D.new()
	nt.width = 512
	nt.height = 512
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = 6.0
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = freq
	n.fractal_octaves = 3
	nt.noise = n
	return nt


## Grow white areas by `steps` pixels (so masks slightly overlap shorelines).
static func _dilate(img: Image, steps: int) -> void:
	for s in steps:
		var src := img.duplicate() as Image
		var w := img.get_width()
		var h := img.get_height()
		for y in h:
			for x in w:
				var c := src.get_pixel(x, y)
				for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var q: Vector2i = Vector2i(x, y) + o
					if q.x >= 0 and q.y >= 0 and q.x < w and q.y < h:
						var d := src.get_pixel(q.x, q.y)
						c = Color(maxf(c.r, d.r), maxf(c.g, d.g), maxf(c.b, d.b))
				img.set_pixel(x, y, c)
