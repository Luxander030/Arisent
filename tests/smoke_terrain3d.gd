## Manual smoke test: Terrain3D runtime editing on this machine's renderer.
## Run: godot --path . --script res://tests/smoke_terrain3d.gd -- <out_dir>
extends SceneTree

class PluginStub extends Node:
	var ui: Node = Node.new()
	var undo := UndoRedo.new()
	func create_undo_action(n: String) -> void: undo.create_action(n)
	func add_undo_method(c: Callable) -> void: undo.add_undo_method(c)
	func add_do_method(c: Callable) -> void: undo.add_do_method(c)
	func commit_action(execute: bool) -> void: undo.commit_action(execute)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var out: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else OS.get_user_data_dir()
	var t := Terrain3D.new()
	t.region_size = Terrain3D.SIZE_1024
	t.collision_mode = Terrain3DCollision.DYNAMIC_GAME
	root.add_child(t)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = Vector3(0, 600, 900)
	cam.look_at(Vector3.ZERO)
	t.set_camera(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var fnl := FastNoiseLite.new()
	fnl.frequency = 0.002
	fnl.fractal_octaves = 6
	var tm := Time.get_ticks_msec()
	var img := fnl.get_image(2048, 2048, false, false, false)
	img.convert(Image.FORMAT_RF)
	t.data.import_images([img, null, null], Vector3(-1024, 0, -1024), 0.0, 300.0)
	print("import 2048^2 ms: ", Time.get_ticks_msec() - tm, " regions: ", t.data.get_region_count())
	await process_frame
	var h0: float = t.data.get_height(Vector3(10, 0, 10))
	var plugin := PluginStub.new()
	root.add_child(plugin)
	var ed := Terrain3DEditor.new()
	t.set_plugin(plugin)
	t.set_editor(ed)
	ed.set_terrain(t)
	var brush := Image.load_from_file("res://addons/terrain_3d/brushes/circle0.exr")
	brush.convert(Image.FORMAT_RF)
	ed.set_tool(Terrain3DEditor.SCULPT)
	ed.set_operation(Terrain3DEditor.ADD)
	ed.set_brush_data({"size": 60.0, "strength": 100.0, "brush": [brush, ImageTexture.create_from_image(brush)],
		"height": 0.0, "slope": Vector2(0, 90), "invert": false, "align_to_view": true, "auto_regions": false,
		"gamma": 1.0, "brush_spin_speed": 0.0, "modifier_shift": false, "modifier_ctrl": false, "modifier_alt": false})
	var p := Vector3(10, h0, 10)
	ed.start_operation(p)
	for i in 30:
		ed.operate(p, 0.0)
		await process_frame
	ed.stop_operation()
	var h1: float = t.data.get_height(Vector3(10, 0, 10))
	print("height before/after stroke: ", h0, " / ", h1, " undo available: ", plugin.undo.has_undo())
	plugin.undo.undo()
	print("after undo: ", t.data.get_height(Vector3(10, 0, 10)))
	plugin.undo.redo()
	var dir := out.path_join("t3d_smoke")
	DirAccess.make_dir_recursive_absolute(dir)
	t.data.save_directory(dir)
	t.data.load_directory(dir)
	await process_frame
	print("after save/load: ", t.data.get_height(Vector3(10, 0, 10)))
	for i in 10: await process_frame
	var shot := root.get_texture().get_image()
	shot.save_png(out.path_join("t3d_smoke.png"))
	print("renderer: ", RenderingServer.get_current_rendering_driver_name(), " ok")
	quit()
