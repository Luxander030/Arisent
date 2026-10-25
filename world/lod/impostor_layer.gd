## Far trees: crossed cards for every tree species, one MultiMesh per terrain region
## (a single draw call per 256 m), using one shared texture atlas. Each card hides itself
## when the real tree is close enough to be drawn by the terrain instancer.
class_name ImpostorLayer
extends Node3D

const SHADER := preload("res://world/lod/lod_impostor.gdshader")
const CELL_PX := 256
const COLUMNS := 8

var _species := {}       ## instancer mesh id -> {rect: Color(x, y, w, h), w, h, y0, cx, cz}
var _material: ShaderMaterial
var _nodes := {}         ## region pixel rect -> MultiMeshInstance3D
var _category := "tree"
var _lod_scale := 1.0


## Builds the atlas from the impostor levels of the given catalog entries (index = mesh id).
func setup(entries: Array) -> void:
	_species.clear()
	var images: Array[Image] = []
	var ids: Array[int] = []
	for i in entries.size():
		var e: Dictionary = entries[i]
		if not LodSettings.has_impostor(e.id):
			continue
		var scene := LodSettings.lod_scene(e.id)
		var count := LodSettings.lod_count(scene)
		var card := LodSettings.lod_mesh(scene, count - 1)
		var mat := card.surface_get_material(0) as BaseMaterial3D
		var img := (mat.albedo_texture as Texture2D).get_image()
		img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		# Leave a transparent border so mipmaps don't bleed between atlas cells.
		img.resize(CELL_PX - 8, CELL_PX - 8, Image.INTERPOLATE_BILINEAR)
		var cellimg := Image.create_empty(CELL_PX, CELL_PX, false, Image.FORMAT_RGBA8)
		cellimg.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(4, 4))
		images.append(cellimg)
		ids.append(i)
		var lod0 := LodSettings.lod_mesh(scene, 0)
		var a := lod0.get_aabb()
		_species[i] = {"w": maxf(a.size.x, a.size.z), "h": a.size.y, "y0": a.position.y,
			"cx": a.get_center().x, "cz": a.get_center().z}
	if images.is_empty():
		return
	var rows := ceili(float(images.size()) / COLUMNS)
	var atlas := Image.create_empty(CELL_PX * COLUMNS, CELL_PX * rows, false, Image.FORMAT_RGBA8)
	for k in images.size():
		var col := k % COLUMNS
		var row := k / COLUMNS
		atlas.blit_rect(images[k], Rect2i(0, 0, CELL_PX, CELL_PX), Vector2i(col * CELL_PX, row * CELL_PX))
		var px := 4.0 / (CELL_PX * COLUMNS)
		var py := 4.0 / (CELL_PX * rows)
		_species[ids[k]]["rect"] = Color(float(col) / COLUMNS + px, float(row) / rows + py,
			1.0 / COLUMNS - 2.0 * px, 1.0 / rows - 2.0 * py)
	atlas.generate_mipmaps()
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("atlas", ImageTexture.create_from_image(atlas))
	_apply_band()


func has_species() -> bool:
	return not _species.is_empty()


func is_impostor(mesh_id: int) -> bool:
	return _species.has(mesh_id)


var _begin_scale := 1.0


## Visible from where the terrain instancer's last real level ends (at the scale the
## vegetation is actually drawn at, which can lag behind) to the last tier.
func set_vegetation_scale(s: float) -> void:
	if absf(s - _begin_scale) > 0.001:
		_begin_scale = s
		_apply_band()


func _apply_band() -> void:
	if _material == null:
		return
	var t := LodSettings.tiers(_category)
	_material.set_shader_parameter("lod_begin_abs", t[t.size() - 2] * _begin_scale)
	_material.set_shader_parameter("lod_end", t[t.size() - 1])
	for n: MultiMeshInstance3D in _nodes.values():
		n.visibility_range_end = (t[-1] * _lod_scale) + 200.0


func apply_lod_scale(scale: float) -> void:
	_lod_scale = scale
	_apply_band()


## Rebuilds the cards of one region from its instance transforms {mesh_id: Array[Transform3D]}.
func set_region(region_px: Rect2i, by_mesh: Dictionary) -> void:
	if _nodes.has(region_px):
		(_nodes[region_px] as Node).queue_free()
		_nodes.erase(region_px)
	if _material == null:
		return
	var xforms: Array[Transform3D] = []
	var cells: Array[Color] = []
	for mid in by_mesh:
		if not _species.has(mid):
			continue
		var sp: Dictionary = _species[mid]
		var card := Basis.from_scale(Vector3(sp.w, sp.h, sp.w))
		var offset := Vector3(sp.cx, sp.y0, sp.cz)
		for xf: Transform3D in by_mesh[mid]:
			xforms.append(Transform3D(xf.basis * card, xf.origin + xf.basis * offset))
			cells.append(sp.rect)
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _card_mesh()
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
		mm.set_instance_custom_data(k, cells[k])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = LodSettings.tiers(_category, _lod_scale)[-1] + 200.0
	add_child(mmi)
	_nodes[region_px] = mmi


static var _card: ArrayMesh

## Unit cards: two crossed 1×1 quads standing on y = 0; the front card shows the left half
## of a species cell (front view), the side card the right half (side view).
static func _card_mesh() -> ArrayMesh:
	if _card:
		return _card
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for card in [[Vector3(1, 0, 0), 0.0], [Vector3(0, 0, 1), 0.5]]:
		var ax: Vector3 = card[0] * 0.5
		var u0: float = card[1]
		var quad := [[-ax, Vector2(u0, 1)], [ax, Vector2(u0 + 0.5, 1)], [ax + Vector3.UP, Vector2(u0 + 0.5, 0)],
			[-ax, Vector2(u0, 1)], [ax + Vector3.UP, Vector2(u0 + 0.5, 0)], [-ax + Vector3.UP, Vector2(u0, 0)]]
		for v in quad:
			st.set_normal(Vector3.UP)
			st.set_uv(v[1])
			st.add_vertex(v[0])
	_card = st.commit()
	return _card
