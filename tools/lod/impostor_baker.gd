## Bakes a far-distance "impostor" for a model: two crossed vertical cards textured with
## renders of the model from the front and the side (flat ambient light = albedo colour,
## transparent background).
## The cards are lit like the ground at runtime (normals point up), so they blend in with
## real lighting, fog and time of day.
class_name ImpostorBaker
extends RefCounted

const TEX_H := 256


## Must run in a windowed (rendering) process. Returns an ArrayMesh with the cards.
static func bake(tree: SceneTree, mesh: ArrayMesh) -> ArrayMesh:
	var aabb := mesh.get_aabb()
	var w := maxf(aabb.size.x, aabb.size.z)
	var h := aabb.size.y
	var tex_w := clampi(roundi(TEX_H * w / h), 32, TEX_H * 2)
	var views: Array[Image] = []
	for angle in [0.0, PI * 0.5]:
		views.append(await _render(tree, mesh, aabb, angle, Vector2i(tex_w, TEX_H)))
	# Atlas: front view on the left, side view on the right.
	var atlas := Image.create_empty(tex_w * 2, TEX_H, false, Image.FORMAT_RGBA8)
	atlas.blit_rect(views[0], Rect2i(Vector2i.ZERO, views[0].get_size()), Vector2i.ZERO)
	atlas.blit_rect(views[1], Rect2i(Vector2i.ZERO, views[1].get_size()), Vector2i(tex_w, 0))
	_bleed(atlas)
	atlas.generate_mipmaps()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(atlas)
	# Cards are lit like flat ground (full sun); darken to match self-shadowed real models.
	mat.albedo_color = Color(0.8, 0.8, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.45
	mat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	mat.metallic_specular = 0.1
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Two crossed cards centred on the model's footprint.
	var c := aabb.get_center()
	var y0 := aabb.position.y
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_card(st, Vector3(c.x, y0, c.z), Vector3(1, 0, 0) * (w * 0.5), h, Rect2(0, 0, 0.5, 1))
	_card(st, Vector3(c.x, y0, c.z), Vector3(0, 0, 1) * (w * 0.5), h, Rect2(0.5, 0, 0.5, 1))
	var out := st.commit()
	out.surface_set_material(0, mat)
	return out


static func _card(st: SurfaceTool, base: Vector3, half_axis: Vector3, h: float, uv: Rect2) -> void:
	var a := base - half_axis
	var b := base + half_axis
	var up := Vector3(0, h, 0)
	var quad := [[a, Vector2(uv.position.x, 1)], [b, Vector2(uv.end.x, 1)], [b + up, Vector2(uv.end.x, 0)],
		[a, Vector2(uv.position.x, 1)], [b + up, Vector2(uv.end.x, 0)], [a + up, Vector2(uv.position.x, 0)]]
	for v in quad:
		st.set_normal(Vector3.UP)
		st.set_uv(v[1])
		st.add_vertex(v[0])


static func _render(tree: SceneTree, mesh: ArrayMesh, aabb: AABB, angle: float, size: Vector2i) -> Image:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(vp)
	# Flat white ambient light only: the picture is the plain albedo colour.
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 1.0
	env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	vp.add_child(env)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# Unshaded copies of the materials: the picture is exactly the albedo colour.
	for si in mesh.get_surface_count():
		var src := mesh.surface_get_material(si)
		if src is BaseMaterial3D:
			var flat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
			flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi.set_surface_override_material(si, flat)
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = aabb.size.y  # vertical extent fills the image height
	var c := aabb.get_center()
	var dir := Vector3(sin(angle), 0, cos(angle))
	cam.position = c + dir * (aabb.size.length() + 5.0)
	cam.near = 0.05
	cam.far = aabb.size.length() * 3.0 + 10.0
	vp.add_child(cam)
	cam.look_at(c, Vector3.UP)
	cam.current = true
	await tree.process_frame
	# Draw synchronously: background windows on macOS don't get regular frames.
	for i in 3:
		RenderingServer.force_draw(false)
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	vp.queue_free()
	return img


## Copies edge colours into transparent pixels so mipmaps don't fade to black halos.
static func _bleed(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	for pass_i in 4:
		var src := data.duplicate()
		for y in h:
			for x in w:
				var o := (y * w + x) * 4
				if src[o + 3] > 12:
					continue
				var r := 0
				var g := 0
				var b := 0
				var n := 0
				for q in [o - 4 if x > 0 else -1, o + 4 if x < w - 1 else -1, o - w * 4 if y > 0 else -1, o + w * 4 if y < h - 1 else -1]:
					if q >= 0 and src[q + 3] > 12:
						r += src[q]
						g += src[q + 1]
						b += src[q + 2]
						n += 1
				if n > 0:
					data[o] = r / n
					data[o + 1] = g / n
					data[o + 2] = b / n
	img.set_data(w, h, false, Image.FORMAT_RGBA8, data)
