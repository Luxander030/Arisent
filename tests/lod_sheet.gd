## Renders every LOD level of some models side by side (lit), for eyeballing LOD quality.
## Run: godot --path . --script res://tests/lod_sheet.gd -- <out.png>
extends SceneTree

const IDS := ["nature.tree_oak", "nature.tree_pineTallA", "nature.tree_palmTall", "nature.cactus_tall",
	"nature.rock_largeB", "nature.plant_bushLarge", "modern.building_h", "modern.skyscraper_b", "town.wall-window-shutters"]
const CELL := 180


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Catalog.apply_palette()
	var sheet := Image.create_empty(CELL * 4, CELL * IDS.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.35, 0.38, 0.42))
	for row in IDS.size():
		var scene := LodSettings.lod_scene(IDS[row])
		var n := LodSettings.lod_count(scene)
		for l in n:
			var img := await _render(LodSettings.lod_mesh(scene, l))
			sheet.blit_rect(img, Rect2i(0, 0, CELL, CELL), Vector2i(l * CELL, row * CELL))
	sheet.save_png(OS.get_cmdline_user_args()[0])
	quit()


func _render(mesh: Mesh) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(CELL, CELL)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.38, 0.42)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 35, 0)
	vp.add_child(sun)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	vp.add_child(mi)
	var a := mesh.get_aabb()
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = maxf(a.size.y, maxf(a.size.x, a.size.z)) * 1.25
	var c := a.get_center()
	cam.position = c + Vector3(0.8, 0.45, 1.0).normalized() * (a.size.length() * 2.0 + 2.0)
	cam.far = a.size.length() * 6.0 + 10.0
	vp.add_child(cam)
	cam.look_at(c)
	cam.current = true
	await process_frame
	for i in 3:
		RenderingServer.force_draw(false)
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	vp.queue_free()
	return img
