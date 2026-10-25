## Graphics settings: saved and read back (only their own section of the file), applied
## to the detail controller (presets, the Adaptive resolution floor, the frame-rate target,
## lower presets dropping the terrain's texturing extras), the settings screen, and the
## game's pause menu.
extends TestCase


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func test_saved_and_read_back() -> void:
	var path := "user://test_settings.cfg"
	var other := ConfigFile.new()
	other.set_value("console", "scale", 1.5)
	other.save(path)
	var g := GraphicsSettings.new()
	g.quality = "Medium"
	g.min_resolution = 0.7
	g.resolution = 0.85
	g.vsync = false
	g.max_fps = 30
	g.show_fps = true
	eq(g.save_file(path), OK, "saves")
	var h := GraphicsSettings.new()
	h.load_file(path)
	check(h.quality == "Medium" and is_equal_approx(h.min_resolution, 0.7) and is_equal_approx(h.resolution, 0.85)
		and not h.vsync and h.max_fps == 30 and h.show_fps, "read back")
	eq(h.target_fps(), 30.0, "a 30 fps cap makes Adaptive aim for 30")
	other.load(path)
	eq(other.get_value("console", "scale"), 1.5, "other sections of the file kept")
	other.set_value("graphics", "quality", "Potato")
	other.set_value("graphics", "min_resolution", 0.1)
	other.save(path)
	h.load_file(path)
	check(h.quality == "Adaptive" and h.min_resolution == 0.5, "bad values fall back / are clamped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_applied_to_a_world() -> void:
	var w := WorldView.new()
	_root().add_child(w)
	var g := GraphicsSettings.new()
	g.quality = "High"
	g.resolution = 0.75
	g.apply_world(w)
	check(w.lod.mode == "High" and is_equal_approx(w.lod.render_scale, 0.75) and w.lod.scale == 1.0, "a preset at a fixed resolution")
	g.quality = "Adaptive"
	g.min_resolution = 0.8
	g.apply_world(w)
	for i in 12:
		w.lod.step(30.0, 0.5, true)
		w.lod._hold = 0.0
	eq(w.lod.rung, LodController.LADDER.size() - 1, "slow: the bottom of the ladder")
	check(w.lod.render_scale >= 0.8, "but never below the lowest resolution chosen (%.2f)" % w.lod.render_scale)
	_root().get_viewport().scaling_3d_scale = 1.0
	_root().get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	w.queue_free()


func test_lower_presets_drop_terrain_extras() -> void:
	var t := Terrain3DBackend.new()
	_root().add_child(t)
	t.setup(512.0, 2.0, null)
	await (Engine.get_main_loop() as SceneTree).process_frame
	t.set_texture_extras(false)
	var mat := t.terrain.material
	check(not mat.dual_scaling_enabled and not mat.projection_enabled, "extras off")
	t.set_texture_extras(true)
	check(mat.dual_scaling_enabled and mat.projection_enabled, "and back")
	t.queue_free()


## The speed patch on Terrain3D 1.1's generated shader (as the game gets it, editor brush
## code included; tests/fixtures). Headless runs have no shader code, so the game smoke
## test checks the live one.
func test_terrain_shader_patch() -> void:
	var stock := FileAccess.get_file_as_string("res://tests/fixtures/terrain3d_1.1_shader.txt")
	var code := Terrain3DBackend.patched_shader(stock, 40.0)
	check(code != "", "patch applies")
	check(code.contains("bool lux_full") and code.contains("weights[lux_k], index[lux_k]"), "single-cell pick beyond the blend distance")
	eq(code.count("if (lux_full) {"), 2, "the other three cells and their weights only within it")
	check(not code.contains("_editor_brush_texture"), "Terrain3D's brush code taken out (it adds it again)")
	eq(Terrain3DBackend.patched_shader("shader_type spatial;", 40.0), "", "unknown shader: no patch (stock shader kept)")


func test_settings_screen_applies() -> void:
	GraphicsSettings.use_defaults()
	var panel := SettingsPanel.new()
	_root().add_child(panel)
	panel._quality.select(GraphicsSettings.QUALITIES.find("Low"))
	panel._quality.item_selected.emit(GraphicsSettings.QUALITIES.find("Low"))
	eq(GraphicsSettings.current().quality, "Low", "choosing a preset")
	check(panel._res.editable and not panel._min_res.editable, "a preset uses the fixed resolution slider")
	check(panel._hint.text.contains("simplified"), "the hint says what Low gives up")
	panel.queue_free()
	GraphicsSettings.use_defaults()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(GraphicsSettings.FILE))  # (the test run's own user dir)


func test_pause_menu() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var menu := PauseMenu.new()
	_root().add_child(menu)
	var resumed := [false]
	menu.resumed.connect(func() -> void: resumed[0] = true)
	menu.open_settings()
	check(menu.settings_open(), "settings open from the pause menu")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	menu._unhandled_input(esc)
	check(not menu.settings_open() and not resumed[0], "Esc closes settings first")
	menu._unhandled_input(esc)
	check(resumed[0], "then resumes")
	menu.queue_free()
	await tree.process_frame
