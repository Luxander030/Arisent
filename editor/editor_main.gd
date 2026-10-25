## The World Editor application: start screen, New Map, 3D viewport with tools,
## save/open of .luxmap folders. Built from runtime nodes (no Godot-editor APIs), so it
## ships as its own executable (export preset "World Editor").
class_name EditorMain
extends Node

const CONFIG_PATH := "user://editor.cfg"
const MAX_RECENT := 8

var world: WorldView
var camera: FlyCamera
var undo := UndoRedo.new()
var map: MapData
var dirty := false

var tools: Array[EditorTool] = []
var tool: EditorTool

# UI
var _ui: Control
var _viewport_blocker: Control
var _inspector: VBoxContainer
var _tool_buttons: Array[Button] = []
var _status: Label
var _hint: Label
var _minimap: TextureRect
var _minimap_marker: Control
var _start_screen: Control
var _progress_panel: PanelContainer
var _progress_bar: ProgressBar
var _progress_label: Label
var _new_map_dialog: NewMapDialog
var _menu_file: PopupMenu
var _brush_decal: Decal

# Background generation
var _gen_thread: Thread
var _builder: TerrainBuilder
var _gen_stage := ""
var _regenerating := false
var _keep := {}  ## edits carried into a regenerated map

var _hit := Vector3.INF
var _ground_rules: TextureRules
var _scatter_ctx: Scatter.Context
var _id_counter := 0
var simulate: SimulateMode


func _ready() -> void:
	get_window().title = "Lux's RPG — World Editor"
	get_window().min_size = Vector2i(1100, 700)
	undo.max_steps = 40
	world = WorldView.new()
	world.name = "World"
	add_child(world)
	camera = FlyCamera.new()
	camera.name = "Camera"
	world.add_child(camera)
	camera.look_from(Vector3(0, 400, 600), Vector3.ZERO)
	camera.current = true
	_make_brush_decal()
	# Authoring gizmos are on by default in the editor (off in the game).
	world.debug.set_channel("zones", true)
	world.debug.set_channel("spawns", true)
	simulate = SimulateMode.new()
	simulate.name = "Simulate"
	simulate.editor = self
	add_child(simulate)
	simulate.toggled.connect(func(running: bool) -> void:
		if tool:
			if running:
				tool.deactivate()
				for c in _inspector.get_children():
					c.queue_free()
				EditorTool.add_label(_inspector, "Editing is locked while simulating. Press F5 (Play → Simulate) to stop.", true)
			else:
				set_tool(tools.find(tool))  # rebuilds the inspector
		_toast("Simulating: creatures spawn and act around the middle of the screen. Editing is locked (F5 stops)." if running else "Simulation stopped; nothing was changed."))
	tools = [SelectTool.new(), SculptTool.new(), PaintTool.new(), VegetationTool.new(), RiftTool.new(), WaterTool.new(), PlaceTool.new(),
		ZoneTool.new(), PathTool.new()]
	for t in tools:
		t.editor = self
	_build_ui()
	_show_start_screen(true)


# --- UI construction -----------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.theme = EditorTheme.build()
	_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 0)
	_ui.add_child(vbox)

	vbox.add_child(_build_menu())

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	middle.add_theme_constant_override("separation", 0)
	vbox.add_child(middle)

	# Left tool palette.
	var palette := PanelContainer.new()
	palette.custom_minimum_size.x = 96
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 4)
	palette.add_child(pv)
	var group := ButtonGroup.new()
	for i in tools.size():
		var b := Button.new()
		b.text = "%d  %s" % [i + 1, tools[i].tool_name()]
		b.toggle_mode = true
		b.button_group = group
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(set_tool.bind(i))
		pv.add_child(b)
		_tool_buttons.append(b)
	middle.add_child(palette)

	# Viewport area (transparent: the 3D world shows through).
	_viewport_blocker = Control.new()
	_viewport_blocker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_viewport_blocker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	middle.add_child(_viewport_blocker)
	_build_minimap(_viewport_blocker)

	# Right inspector.
	var right := PanelContainer.new()
	right.custom_minimum_size.x = 300
	var rs := ScrollContainer.new()
	rs.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(rs)
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 8)
	rs.add_child(_inspector)
	middle.add_child(right)

	# Status bar.
	var bar := PanelContainer.new()
	var bh := HBoxContainer.new()
	bar.add_child(bh)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(_status)
	_hint = Label.new()
	_hint.modulate = Color(1, 1, 1, 0.65)
	bh.add_child(_hint)
	vbox.add_child(bar)

	_build_progress_panel()


func _build_menu() -> Control:
	var bar := PanelContainer.new()
	var menu := MenuBar.new()
	bar.add_child(menu)
	_menu_file = PopupMenu.new()
	_menu_file.name = "File"
	_menu_file.add_item("New Map…", 0, KEY_MASK_CMD_OR_CTRL | KEY_N)
	_menu_file.add_item("Open Map…", 1, KEY_MASK_CMD_OR_CTRL | KEY_O)
	_menu_file.add_separator()
	_menu_file.add_item("Save", 2, KEY_MASK_CMD_OR_CTRL | KEY_S)
	_menu_file.add_item("Save As…", 3, KEY_MASK_CMD_OR_CTRL | KEY_MASK_SHIFT | KEY_S)
	_menu_file.add_item("Give This Map a New Identity", 5)
	_menu_file.add_separator()
	_menu_file.add_item("Quit", 4, KEY_MASK_CMD_OR_CTRL | KEY_Q)
	_menu_file.id_pressed.connect(_on_file_menu)
	menu.add_child(_menu_file)
	var edit := PopupMenu.new()
	edit.name = "Edit"
	edit.add_item("Undo", 0, KEY_MASK_CMD_OR_CTRL | KEY_Z)
	edit.add_item("Redo", 1, KEY_MASK_CMD_OR_CTRL | KEY_MASK_SHIFT | KEY_Z)
	edit.id_pressed.connect(func(id: int) -> void:
		if id == 0: do_undo()
		else: do_redo())
	menu.add_child(edit)
	var view := PopupMenu.new()
	view.name = "View"
	var detail := PopupMenu.new()
	detail.name = "DetailMenu"
	var modes := LodSettings.PRESETS.keys() + ["Adaptive", "No LOD"]
	for i in modes.size():
		detail.add_radio_check_item(modes[i], i)
	detail.set_item_checked(modes.find(world.lod.mode), true)
	detail.id_pressed.connect(func(id: int) -> void:
		for k in detail.item_count:
			detail.set_item_checked(k, k == id)
		set_quality(modes[id]))
	view.add_child(detail)
	view.add_submenu_node_item("Detail level", detail)
	var overlays := PopupMenu.new()
	overlays.name = "OverlaysMenu"
	for i in DebugDraw.CHANNELS.size():
		overlays.add_check_item(DebugDraw.CHANNELS[i].capitalize(), i)
		overlays.set_item_checked(i, world.debug.is_on(DebugDraw.CHANNELS[i]))
	overlays.id_pressed.connect(func(id: int) -> void:
		var ch := DebugDraw.CHANNELS[id]
		world.debug.set_channel(ch, not world.debug.is_on(ch))
		overlays.set_item_checked(id, world.debug.is_on(ch)))
	world.debug.channels_changed.connect(func() -> void:
		for i in DebugDraw.CHANNELS.size():
			overlays.set_item_checked(i, world.debug.is_on(DebugDraw.CHANNELS[i])))
	view.add_child(overlays)
	view.add_submenu_node_item("Debug overlays", overlays)
	menu.add_child(view)
	var play := PopupMenu.new()
	play.name = "Play"
	play.add_item("Simulate here (start / stop)", 0, KEY_F5)
	play.add_item("Drive the pawn (start / stop)", 2, KEY_F6)
	play.add_item("Check spawning problems…", 1)
	play.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			simulate.toggle()
		elif id == 2:
			simulate.set_driving(not simulate.driving)
		else:
			_show_problems())
	menu.add_child(play)
	var gen := PopupMenu.new()
	gen.name = "Generate"
	gen.add_item("Regenerate with these settings…", 0)
	gen.id_pressed.connect(func(_id: int) -> void: _open_new_map(true))
	menu.add_child(gen)
	return bar


func _build_minimap(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-236, 10)
	panel.custom_minimum_size = Vector2(226, 226)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -236
	panel.offset_right = -10
	panel.offset_top = 10
	panel.offset_bottom = 236
	parent.add_child(panel)
	_minimap = TextureRect.new()
	_minimap.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_minimap.stretch_mode = TextureRect.STRETCH_SCALE
	_minimap.mouse_filter = Control.MOUSE_FILTER_STOP
	_minimap.tooltip_text = "Click to fly there"
	_minimap.gui_input.connect(_on_minimap_input)
	panel.add_child(_minimap)
	_minimap_marker = Control.new()
	_minimap_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap_marker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_minimap_marker.draw.connect(_draw_minimap_marker)
	_minimap.add_child(_minimap_marker)
	panel.visible = false
	panel.name = "Minimap"


func _build_progress_panel() -> void:
	_progress_panel = PanelContainer.new()
	_progress_panel.set_anchors_preset(Control.PRESET_CENTER)
	_progress_panel.custom_minimum_size = Vector2(420, 110)
	_progress_panel.position = Vector2(-210, -55)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_progress_panel.add_child(v)
	_progress_label = Label.new()
	_progress_label.text = "Generating…"
	v.add_child(_progress_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.max_value = 1.0
	_progress_bar.step = 0.001
	v.add_child(_progress_bar)
	_progress_panel.visible = false
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_progress_panel)
	_ui.add_child(center)


func _show_start_screen(show: bool) -> void:
	if _start_screen:
		_start_screen.queue_free()
		_start_screen = null
	if not show:
		return
	_start_screen = CenterContainer.new()
	_start_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.add_child(bg)
	holder.add_child(_start_screen)
	_start_screen = holder
	var center := holder.get_child(1)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(460, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var title := Label.new()
	title.text = "World Editor"
	title.add_theme_font_size_override("font_size", 30)
	v.add_child(title)
	var sub := Label.new()
	sub.text = "Lux's RPG"
	sub.modulate = Color(1, 1, 1, 0.6)
	v.add_child(sub)
	var new_btn := Button.new()
	new_btn.text = "New Map…"
	new_btn.pressed.connect(func() -> void: _open_new_map(false))
	v.add_child(new_btn)
	var open_btn := Button.new()
	open_btn.text = "Open Map…"
	open_btn.pressed.connect(_open_dialog)
	v.add_child(open_btn)
	var recent := _recent_maps()
	if not recent.is_empty():
		v.add_child(HSeparator.new())
		var rl := Label.new()
		rl.text = "Recent maps"
		v.add_child(rl)
		for path in recent:
			var b := Button.new()
			b.text = path.get_file()
			b.tooltip_text = path
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(open_map.bind(path))
			v.add_child(b)
	_ui.add_child(holder)


# --- tools ----------------------------------------------------------------------

func set_tool(i: int) -> void:
	if tool:
		tool.deactivate()
	tool = tools[i]
	_tool_buttons[i].button_pressed = true
	tool.activate()
	for c in _inspector.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = tool.tool_name()
	title.add_theme_font_size_override("font_size", 20)
	_inspector.add_child(title)
	tool.build_settings(_inspector)
	_hint.text = tool.tool_hint()


func _make_brush_decal() -> void:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.0))
	g.add_point(0.82, Color(1, 1, 1, 0.0))
	g.add_point(0.9, Color(1.0, 0.8, 0.3, 0.9))
	g.set_color(g.get_point_count() - 1, Color(1.0, 0.8, 0.3, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	_brush_decal = Decal.new()
	_brush_decal.texture_albedo = tex
	_brush_decal.upper_fade = 0.0
	_brush_decal.lower_fade = 0.0
	_brush_decal.visible = false
	world.add_child(_brush_decal)


# --- input -----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if map == null or world.terrain == null or _new_map_dialog or _progress_panel.visible:
		return
	if camera.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if simulate.active:
		return  # editing is locked while simulating
	if event is InputEventMouse:
		_hit = _pick((event as InputEventMouse).position)
	if tool and tool.on_input(event, _hit):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode >= KEY_1 and k.keycode < KEY_1 + tools.size() and not k.is_command_or_control_pressed():
			set_tool(k.keycode - KEY_1)
		elif tool and tool.uses_brush():
			match k.keycode:
				KEY_BRACKETLEFT: tool.size = maxf(1.0, tool.size / 1.2)
				KEY_BRACKETRIGHT: tool.size = minf(400.0, tool.size * 1.2)
				KEY_MINUS: tool.strength = maxf(1.0, tool.strength - 5.0)
				KEY_EQUAL: tool.strength = minf(100.0, tool.strength + 5.0)
				_: return
			set_tool(tools.find(tool))


func _pick(screen_pos: Vector2) -> Vector3:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	return world.terrain.raycast(from, dir)


func _process(delta: float) -> void:
	_poll_generation()
	if map == null or world.terrain == null:
		return
	if tool and not simulate.active:
		tool.process(delta, _hit)
	var show_brush := tool != null and tool.uses_brush() and _hit != Vector3.INF and not camera.looking and not simulate.active
	_brush_decal.visible = show_brush
	if show_brush:
		_brush_decal.position = _hit
		_brush_decal.size = Vector3(tool.size, 800.0, tool.size)
	var info := "FPS %d   detail ×%.2f%s" % [Engine.get_frames_per_second(), world.lod.scale,
		(" (adaptive, holding: lower detail wasn't helping)" if world.lod.is_holding() else " (adaptive)") if world.lod.mode == "Adaptive" else ""]
	if _hit != Vector3.INF:
		info = "x %.0f  z %.0f  height %.1f m   %s   |  %s" % [_hit.x, _hit.z, _hit.y, _biome_at(_hit), info]
	if simulate.active:
		info = simulate.status_text() + "   |  " + info
	_status.text = info
	_minimap_marker.queue_redraw()


func _biome_at(p: Vector3) -> String:
	if map.layout_n == 0:
		return ""
	var n := map.layout_n
	var i := clampi(floori((p.x / map.map_m + 0.5) * n), 0, n - 1)
	var j := clampi(floori((p.z / map.map_m + 0.5) * n), 0, n - 1)
	return GenParams.BIOME_NAMES[map.layout_biome[j * n + i]]


## Detail level: "Low" / "Medium" / "High" / "Ultra" (fixed) or "Adaptive" (holds the target FPS).
func set_quality(mode: String) -> void:
	world.lod.set_mode(mode)
	_toast("Detail level: %s" % mode)


## Lists every spawning problem in the map; click one to select the entity.
func _show_problems() -> void:
	if map == null:
		return
	var list := SpawnChecks.all_problems(world)
	var dlg := AcceptDialog.new()
	dlg.title = "Spawning problems (%d)" % list.size()
	var items := ItemList.new()
	items.custom_minimum_size = Vector2(620, 320)
	if list.is_empty():
		items.add_item("No problems found.")
	for row: Array in list:
		var e := world.entities.entity(str(row[0]))
		var i := items.add_item("%s  —  %s" % [EntityKinds.label(str(e.get("kind", ""))), row[1]])
		items.set_item_metadata(i, row[0])
	items.item_activated.connect(func(i: int) -> void:
		var id: Variant = items.get_item_metadata(i)
		if id == null:
			return
		set_tool(0)
		(tools[0] as SelectTool).select_entity(str(id))
		var p := EntityKinds.position_of(world.entities.entity(str(id)))
		camera.look_from(p + Vector3(0, 60, 80), p)
		dlg.hide())
	dlg.add_child(items)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	_ui.add_child(dlg)
	dlg.popup_centered()


func do_undo() -> void:
	if simulate.active:
		return
	if undo.has_undo():
		undo.undo()
		mark_dirty()


func do_redo() -> void:
	if simulate.active:
		return
	if undo.has_redo():
		undo.redo()
		mark_dirty()


# --- minimap ---------------------------------------------------------------------

func _on_minimap_input(event: InputEvent) -> void:
	if map == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var uv: Vector2 = event.position / _minimap.size
		var target := Vector3((uv.x - 0.5) * map.map_m, 0.0, (uv.y - 0.5) * map.map_m)
		target.y = world.terrain.get_height(target)
		var back := -camera.global_basis.z
		back.y = 0
		back = back.normalized() if back.length() > 0.01 else Vector3.FORWARD
		camera.look_from(target - back * 260.0 + Vector3.UP * 180.0, target)


func _draw_minimap_marker() -> void:
	if map == null:
		return
	var s := _minimap.size
	var p := Vector2((camera.position.x / map.map_m + 0.5) * s.x, (camera.position.z / map.map_m + 0.5) * s.y)
	var f := -camera.global_basis.z
	var d := Vector2(f.x, f.z).normalized() * 14.0
	_minimap_marker.draw_line(p, p + d, Color(1, 1, 1), 2.0)
	_minimap_marker.draw_circle(p, 4.0, Color(1.0, 0.3, 0.2))


# --- new map / generation ----------------------------------------------------------

func _open_new_map(from_current: bool) -> void:
	if _new_map_dialog:
		return
	_regenerating = from_current and map != null
	_new_map_dialog = NewMapDialog.new()
	if from_current and map and not map.gen_params.is_empty():
		var p := GenParams.new()
		p.from_dict(map.gen_params)
		_new_map_dialog.set_params(p)
	_new_map_dialog.generate_requested.connect(_on_generate_requested)
	_new_map_dialog.cancelled.connect(func() -> void:
		_new_map_dialog.queue_free()
		_new_map_dialog = null)
	_ui.add_child(_new_map_dialog)


func _on_generate_requested(p: GenParams, layout: WorldLayout) -> void:
	_new_map_dialog.queue_free()
	_new_map_dialog = null
	_show_start_screen(false)
	_progress_panel.visible = true
	_progress_label.text = "Generating “%s”…" % p.name
	_keep = _collect_edits(p) if _regenerating else {}
	_builder = TerrainBuilder.new()
	_gen_stage = "Laying out the world"
	_gen_thread = Thread.new()
	_gen_thread.start(_generate_worker.bind(p, layout))


func _generate_worker(p: GenParams, layout: WorldLayout) -> Dictionary:
	var L := layout
	if L == null:
		L = LayoutGenerator.new().generate(p, 512)
	_gen_stage = "Building the city"
	var t0 := Time.get_ticks_msec()
	var city := CityGen.new().generate(L, p)
	print("city: %d buildings in %d ms" % [city.get("buildings", []).size(), Time.get_ticks_msec() - t0])
	_gen_stage = ""
	var r := _builder.build(L, p, city)
	_gen_stage = "Planting vegetation"
	var m := MapFactory.create(p, L, r, city)
	if not _keep.is_empty():
		_gen_stage = "Re-applying your edits"
		_reapply_edits(m, r)
	var rects: Array[Rect2i] = []
	for y in range(0, r.res, 256):
		for x in range(0, r.res, 256):
			rects.append(Rect2i(x, y, 256, 256))
	var t := Time.get_ticks_msec()
	var veg := VegetationBuilder.scatter_all(VegetationBuilder.make_context(m), rects, r.height, r.control)
	print("vegetation scattered in %d ms" % (Time.get_ticks_msec() - t))
	return {"map": m, "layout": L, "result": r, "vegetation": veg}


func _poll_generation() -> void:
	if _gen_thread == null:
		return
	if _gen_stage != "":
		_progress_bar.value = 0.02 if _builder.progress < 1.0 else 0.97
		_progress_label.text = _gen_stage + "…"
	else:
		_progress_bar.value = _builder.progress
		_progress_label.text = _builder.status + "…"
	if _gen_thread.is_alive():
		return
	var out: Dictionary = _gen_thread.wait_to_finish()
	_gen_thread = null
	_progress_label.text = "Building the 3D world…"
	await get_tree().process_frame
	_finish_generation(out.map, out.layout, out.result, out.vegetation)
	_progress_panel.visible = false


func _finish_generation(m: MapData, L: WorldLayout, r: TerrainBuilder.Result, veg: Array) -> void:
	_set_map(m)
	world.terrain.import_maps(r.height_image(), r.control_image(), r.color_image(), r.origin())
	if not _keep.is_empty():
		# Ground textures where edits changed the terrain (rifts/rivers become rock and gravel).
		for mod: Dictionary in m.modifiers:
			refresh_ground(Modifiers.bounds(mod))
		_keep = {}
	for item in veg:
		VegetationBuilder.apply(world.terrain, item[0], item[1])
	world.finish_terrain()
	world.build_water()
	world.build_city()
	world.build_entities()
	var c := Vector3(L.city_center.x, L.city_height, L.city_center.y) if L.has_city else Vector3.ZERO
	camera.look_from(c + Vector3(0, 280, 420), c)
	mark_dirty()


## Snapshot of everything the user authored, taken before regenerating.
## Sculpting is kept as D = current height - procedural height (only if the size is unchanged).
func _collect_edits(p: GenParams) -> Dictionary:
	var keep := {"path": map.path, "map_uid": map.map_uid, "revision": map.revision, "lineage": map.lineage.duplicate(true), "modifiers": map.modifiers.duplicate(true), "entities": map.entities.duplicate(true),
		"overrides": map.overrides.duplicate(true), "scatter_paint": map.scatter_paint,
		"lakes": map.water.get("lakes", []).filter(func(l: Dictionary) -> bool: return l.get("origin", "") == "user"),
		"rivers": map.water.get("rivers", []).filter(func(r: Dictionary) -> bool: return r.get("origin", "") == "user")}
	if p.size_km == map.size_km and map.procedural_height:
		var R := world.terrain.full_res()
		var current := world.terrain.read_heights(Rect2i(0, 0, R, R))
		var P := map.procedural_height.get_data().to_float32_array()
		if current.size() == P.size():
			var mod_d := PackedFloat32Array()
			mod_d.resize(P.size())
			for k in P.size():
				mod_d[k] = current[k] - P[k]
			keep["sculpt"] = mod_d
	return keep


## Runs on the generation thread: P_new + modifiers + D, then authored data.
func _reapply_edits(m: MapData, r: TerrainBuilder.Result) -> void:
	var R := r.res
	for mod: Dictionary in _keep.modifiers:
		var b := Modifiers.bounds(mod)
		var a := Vector2i(floori((b.position.x + r.map_m * 0.5) / r.spacing), floori((b.position.y + r.map_m * 0.5) / r.spacing))
		var e := Vector2i(ceili((b.end.x + r.map_m * 0.5) / r.spacing), ceili((b.end.y + r.map_m * 0.5) / r.spacing))
		var px := Rect2i(a, e - a).intersection(Rect2i(0, 0, R, R))
		if px.size.x <= 0 or px.size.y <= 0:
			continue
		var hs := PackedFloat32Array()
		for y in px.size.y:
			hs.append_array(r.height.slice((px.position.y + y) * R + px.position.x, (px.position.y + y) * R + px.end.x))
		var d := Modifiers.delta(mod, px, r.spacing, r.map_m, hs)
		for y in px.size.y:
			for x in px.size.x:
				r.height[(px.position.y + y) * R + px.position.x + x] += d[y * px.size.x + x]
	m.procedural_height = r.height_image()  # P includes modifiers
	var sculpt: PackedFloat32Array = _keep.get("sculpt", PackedFloat32Array())
	if sculpt.size() == r.height.size():
		for k in sculpt.size():
			r.height[k] += sculpt[k]
	m.modifiers = _keep.modifiers
	m.entities = _keep.entities
	m.overrides = _keep.overrides
	m.scatter_paint = _keep.scatter_paint
	m.path = _keep.path
	m.map_uid = _keep.map_uid  # regenerating keeps the map's identity (same map, new terrain)
	m.revision = _keep.revision
	m.lineage = _keep.lineage
	m.water["lakes"] = m.water.get("lakes", []) + _keep.lakes
	m.water["rivers"] = m.water.get("rivers", []) + _keep.rivers
	var n := m.water_mask.get_width()
	for lake: Dictionary in _keep.lakes:
		var rc: Array = lake.rect
		for j in range(clampi(floori((rc[1] / r.map_m + 0.5) * n), 0, n - 1), clampi(ceili((rc[3] / r.map_m + 0.5) * n), 0, n - 1) + 1):
			for i in range(clampi(floori((rc[0] / r.map_m + 0.5) * n), 0, n - 1), clampi(ceili((rc[2] / r.map_m + 0.5) * n), 0, n - 1) + 1):
				var px := m.water_mask.get_pixel(i, j)
				m.water_mask.set_pixel(i, j, Color(px.r, px.g, 1.0))


func _set_map(m: MapData) -> void:
	if simulate and simulate.active:
		simulate.stop()
	map = m
	undo.clear_history()
	world.setup_terrain(m, camera, undo)
	world.terrain.stroke_finished.connect(func(rect: Rect2) -> void:
		refresh_ground(rect)
		_after_terrain_change(rect))
	_ground_rules = null
	_scatter_ctx = null
	_minimap.texture = ImageTexture.create_from_image(m.minimap) if m.minimap else null
	_minimap.get_parent().visible = m.minimap != null
	if tool == null:
		set_tool(0)
	_update_title()


# --- open / save ---------------------------------------------------------------------

func _on_file_menu(id: int) -> void:
	match id:
		0: _open_new_map(false)
		1: _open_dialog()
		2: save()
		3: _save_as_dialog()
		4: get_tree().quit()
		5: _reidentify()


func _open_dialog() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = "Open a .luxmap folder"
	fd.dir_selected.connect(func(dir: String) -> void:
		open_map(dir)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered_ratio(0.6)


func _save_as_dialog() -> void:
	if map == null:
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.title = "Save map"
	fd.current_file = map.name.validate_filename() + MapData.EXTENSION
	fd.add_filter("*" + MapData.EXTENSION, "Lux map")
	fd.file_selected.connect(func(path: String) -> void:
		if not path.ends_with(MapData.EXTENSION):
			path += MapData.EXTENSION
		fd.queue_free()
		_ask_identity(path))
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered_ratio(0.6)


## Save As to another folder: the same map (save games keep working) or a copy (its own
## save games). Saves are keyed by the map's identity, not its folder.
func _ask_identity(path: String) -> void:
	if map.map_uid == "" or path == map.path:
		save_to(path)
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "Save As"
	dlg.dialog_text = "Is this the same map in a new place, or a copy?\n\nSame map: existing save games keep working with it.\nCopy: it gets its own identity and its own save games."
	dlg.ok_button_text = "Same map"
	dlg.add_button("Copy", true, "copy")
	dlg.confirmed.connect(func() -> void:
		save_to(path)
		dlg.queue_free())
	dlg.custom_action.connect(func(_a: StringName) -> void:
		map.map_uid = MapData.new_uid()
		map.lineage.clear()
		save_to(path)
		dlg.hide()
		dlg.queue_free())
	dlg.canceled.connect(dlg.queue_free)
	_ui.add_child(dlg)
	dlg.popup_centered()


func _reidentify() -> void:
	if map == null:
		return
	map.map_uid = MapData.new_uid()
	map.lineage.clear()
	mark_dirty()
	_toast("This map has a new identity (save games made with the old one won't load it). Save to keep it.")


func save() -> void:
	if map == null:
		return
	if simulate.active:
		simulate.stop()
	if map.path == "":
		_save_as_dialog()
	else:
		save_to(map.path)


func save_to(path: String) -> void:
	_bake_zone_cache()
	var err := MapIO.save(map, world.terrain, path)
	if err != OK:
		_toast("Could not save: %s" % error_string(err))
		return
	dirty = false
	_add_recent(path)
	_update_title()
	_toast("Saved " + path.get_file())


func open_map(path: String) -> void:
	var m := MapIO.load_map(path)
	if m == null:
		_toast("Can't open %s: %s" % [path.get_file(), MapIO.last_error])
		return
	_show_start_screen(false)
	_set_map(m)
	MapIO.load_terrain(m, world.terrain)
	world.finish_terrain()
	world.build_water()
	world.build_city()
	world.build_entities()
	camera.look_from(Vector3(0, 500, m.map_m * 0.25), Vector3.ZERO)
	dirty = false
	_add_recent(path)
	_update_title()
	_check_duplicate_identity(m)


## A folder copied in Finder has the same identity as the original; save games would mix.
func _check_duplicate_identity(m: MapData) -> void:
	for other in _recent_maps():
		if other == m.path:
			continue
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(other.path_join("map.json")))
		if meta is Dictionary and str(meta.get("map_uid", "")) == m.map_uid and m.map_uid != "":
			_toast("Warning: %s has the same identity as %s (copied folder?). Use File → Give This Map a New Identity." % [m.path.get_file(), other.get_file()])
			return


## Spawn zones' usable points, stored with the map so the game doesn't bake them at load.
func _bake_zone_cache() -> void:
	var fresh := {}
	for z in world.entities.entities_of_kind("zone"):
		if EntityKinds.has_role(z, "spawn"):
			# Always re-bake: sculpting changes the ground under a zone without changing the zone.
			fresh[z.id] = {"key": ZoneCandidates.key_of(z), "points": ZoneCandidates.bake(z, world)}
	map.zone_cache = fresh


func _recent_maps() -> PackedStringArray:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var list: PackedStringArray = cfg.get_value("recent", "maps", PackedStringArray())
	var out := PackedStringArray()
	for p in list:
		if MapIO.is_map_folder(p):
			out.append(p)
	return out


func _add_recent(path: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var list: PackedStringArray = cfg.get_value("recent", "maps", PackedStringArray())
	var idx := list.find(path)
	if idx >= 0:
		list.remove_at(idx)
	list.insert(0, path)
	if list.size() > MAX_RECENT:
		list.resize(MAX_RECENT)
	cfg.set_value("recent", "maps", list)
	cfg.save(CONFIG_PATH)


func mark_dirty() -> void:
	dirty = true
	_update_title()


func _update_title() -> void:
	var t := "Lux's RPG — World Editor"
	if map:
		t = "%s%s — %s" % [map.display_name(), " •" if dirty else "", t]
	get_window().title = t


func toast(text: String) -> void:
	_toast(text)


func _toast(text: String) -> void:
	_hint.text = text
	print(text)


# --- edit helpers used by tools ------------------------------------------------------

func new_id() -> String:
	_id_counter += 1
	return "%x-%x-%x" % [Time.get_unix_time_from_system() * 1000.0, Time.get_ticks_usec(), _id_counter]


func ensure_paint_lock() -> Image:
	if map.paint_lock == null:
		map.paint_lock = Image.create_empty(map.res(), map.res(), false, Image.FORMAT_L8)
	return map.paint_lock


func _world_rect_to_px(rect: Rect2) -> Rect2i:
	var t := world.terrain
	var a := t.world_to_pixel(Vector3(rect.position.x, 0, rect.position.y))
	var b := t.world_to_pixel(Vector3(rect.end.x, 0, rect.end.y)) + Vector2i.ONE
	return Rect2i(a, b - a).intersection(Rect2i(0, 0, t.full_res(), t.full_res()))


## Re-derives automatic ground textures in a world rectangle (keeps hand-painted pixels).
func refresh_ground(rect: Rect2) -> void:
	if map.layout_n == 0:
		return
	var px := _world_rect_to_px(rect.grow(2.0))
	if px.size.x <= 0 or px.size.y <= 0:
		return
	var rules := _rules()
	var t := world.terrain
	var grown := px.grow(1).intersection(Rect2i(0, 0, t.full_res(), t.full_res()))
	var hg := t.read_heights(grown)
	# Pad to exactly px grown by one (clamped at the map edge).
	var H := PackedFloat32Array()
	for y in range(px.position.y - 1, px.end.y + 1):
		var yy := clampi(y, grown.position.y, grown.end.y - 1) - grown.position.y
		for x in range(px.position.x - 1, px.end.x + 1):
			var xx := clampi(x, grown.position.x, grown.end.x - 1) - grown.position.x
			H.append(hg[yy * grown.size.x + xx])
	var lock := PackedByteArray()
	if map.paint_lock:
		lock = map.paint_lock.get_region(px).get_data()
	var old := t.read_control(px)
	var res := rules.compute(px, H, PackedFloat32Array(), PackedByteArray(), old, lock)
	t.write_control(px, res[0])
	var col: PackedByteArray = res[1]
	if not lock.is_empty():
		var old_col := t.read_color(px)
		for k in lock.size():
			if lock[k] != 0:
				for c in 4:
					col[k * 4 + c] = old_col[k * 4 + c]
	t.write_color(px, col)


func _rules() -> TextureRules:
	if _ground_rules:
		return _ground_rules
	var p := GenParams.new()
	p.from_dict(map.gen_params)
	var n := map.layout_n
	var water := PackedFloat32Array()
	water.resize(n * n)
	if map.water_mask:
		for k in n * n:
			var c := map.water_mask.get_pixel(k % n, k / n)
			water[k] = maxf(c.r, c.b)
	var weights := []
	for q: PackedByteArray in map.layout_weights:
		var w := PackedFloat32Array()
		w.resize(q.size())
		for k in q.size():
			w[k] = q[k] / 255.0
		weights.append(w)
	_ground_rules = TextureRules.new(map.res(), map.spacing, map.map_m, Rng.derive(p.seed_int(), 50),
		p.blend_width, n, map.layout_biome, map.layout_temp, water, weights)
	return _ground_rules


## Adds an authored modifier (e.g. a rift) to the procedural layer and the terrain.
func add_modifier(mod: Dictionary) -> void:
	var px := _world_rect_to_px(Modifiers.bounds(mod))
	if px.size.x <= 0 or px.size.y <= 0:
		return
	var d := Modifiers.delta(mod, px, map.spacing, map.map_m, world.terrain.read_heights(px))
	undo.create_action("Add " + str(mod.type))
	undo.add_do_method(_apply_modifier.bind(mod, px, d, 1.0))
	undo.add_undo_method(_apply_modifier.bind(mod, px, d, -1.0))
	undo.commit_action(true)
	mark_dirty()


func _apply_modifier(mod: Dictionary, px: Rect2i, d: PackedFloat32Array, sign: float) -> void:
	var t := world.terrain
	var h := t.read_heights(px)
	for k in h.size():
		h[k] += d[k] * sign
	t.write_heights(px, h)
	if map.procedural_height:
		var P := map.procedural_height
		for y in px.size.y:
			for x in px.size.x:
				var v := P.get_pixel(px.position.x + x, px.position.y + y).r
				P.set_pixel(px.position.x + x, px.position.y + y, Color(v + d[y * px.size.x + x] * sign, 0, 0))
	if sign > 0.0:
		map.modifiers.append(mod)
	else:
		map.modifiers.erase(mod)
	var r := Rect2(t.pixel_to_world(px.position).x, t.pixel_to_world(px.position).z, px.size.x * map.spacing, px.size.y * map.spacing)
	refresh_ground(r)
	_after_terrain_change(r)


## Keeps things that sit on the terrain on it after the ground changed.
func _after_terrain_change(rect: Rect2) -> void:
	world.terrain.snap_instances(rect)
	world.refresh_impostors(rect)
	if map.city.has("center"):
		var c := Vector2(map.city.center[0], map.city.center[1])
		var rad: float = map.city.radius
		if Rect2(c - Vector2(rad, rad), Vector2(rad, rad) * 2.0).grow(20.0).intersects(rect):
			world.build_city()


# --- entities, city edits, vegetation, water -------------------------------------------

func add_entity(e: Dictionary) -> void:
	undo.create_action("Place object")
	undo.add_do_method(_do_add_entity.bind(e))
	undo.add_undo_method(_do_remove_entity.bind(e))
	undo.commit_action(true)
	mark_dirty()


func remove_entity(e: Dictionary) -> void:
	if e.is_empty():
		return
	undo.create_action("Delete object")
	undo.add_do_method(_do_remove_entity.bind(e))
	undo.add_undo_method(_do_add_entity.bind(e))
	undo.commit_action(true)
	mark_dirty()


func _do_add_entity(e: Dictionary) -> void:
	map.entities.append(e)
	world.entities.add_entity(e)


func _do_remove_entity(e: Dictionary) -> void:
	for i in map.entities.size():
		if map.entities[i].id == e.id:
			map.entities.remove_at(i)
			break
	world.entities.remove_entity(e.id)


## Records an already-applied change of one entity (before -> after) for undo.
func commit_entity_change(before: Dictionary, after: Dictionary, label: String) -> void:
	undo.create_action(label)
	undo.add_do_method(_set_entity.bind(after))
	undo.add_undo_method(_set_entity.bind(before))
	undo.commit_action(true)
	mark_dirty()


func _set_entity(e: Dictionary) -> void:
	for i in map.entities.size():
		if map.entities[i].id == e.id:
			var props_changed: bool = map.entities[i].get("props", {}) != e.get("props", {})
			map.entities[i] = e.duplicate(true)
			if props_changed:
				world.entities.rebuild_entity(map.entities[i])
			else:
				world.entities.update_entity(map.entities[i])
			return


func delete_city_building(key: String) -> void:
	undo.create_action("Delete city building")
	undo.add_do_method(_set_override.bind("city:" + key, {"deleted": true}))
	undo.add_undo_method(_set_override.bind("city:" + key, {}))
	undo.commit_action(true)
	mark_dirty()


func _set_override(key: String, value: Dictionary) -> void:
	if value.is_empty():
		map.overrides.erase(key)
	else:
		map.overrides[key] = value
	world.build_city()


func invalidate_scatter() -> void:
	_scatter_ctx = null


## Re-scatters vegetation in every terrain region touching a world rectangle.
func rescatter(rect: Rect2) -> void:
	if _scatter_ctx == null:
		_scatter_ctx = VegetationBuilder.make_context(map)
	var px := _world_rect_to_px(rect)
	for reg in world.terrain.region_rects():
		if reg.intersects(px):
			VegetationBuilder.apply(world.terrain, reg, VegetationBuilder.scatter_region(_scatter_ctx, world.terrain, reg))
	world.terrain.refresh_instances()
	world.refresh_impostors(rect)


func add_lake(level: float, rect: Rect2, cells: Array[Vector2], frozen: bool) -> void:
	var lake := {"id": "u" + new_id(), "level": level, "frozen": frozen,
		"rect": [rect.position.x, rect.position.y, rect.end.x, rect.end.y], "origin": "user"}
	var old_mask := map.water_mask.duplicate() as Image
	var new_mask := map.water_mask.duplicate() as Image
	var n := new_mask.get_width()
	for c in cells:
		var i := clampi(floori((c.x / map.map_m + 0.5) * n), 0, n - 1)
		var j := clampi(floori((c.y / map.map_m + 0.5) * n), 0, n - 1)
		var px := new_mask.get_pixel(i, j)
		new_mask.set_pixel(i, j, Color(px.r, px.g, 1.0))
	undo.create_action("Add lake")
	undo.add_do_method(_set_lakes.bind(lake, true, new_mask))
	undo.add_undo_method(_set_lakes.bind(lake, false, old_mask))
	undo.commit_action(true)
	mark_dirty()


func _set_lakes(lake: Dictionary, add: bool, mask: Image) -> void:
	var lakes: Array = map.water.get("lakes", [])
	if add:
		lakes.append(lake)
	else:
		for i in lakes.size():
			if lakes[i].id == lake.id:
				lakes.remove_at(i)
				break
	map.water["lakes"] = lakes
	map.water_mask.copy_from(mask)
	world.build_water()
	_scatter_ctx = null


## A river from upstream to downstream points: the water level only ever falls,
## the bed is carved as a modifier, and the water surface is added to water.json.
func add_river(points: Array, width: float, depth: float, frozen: bool) -> void:
	var pts := []
	var level := INF
	for i in points.size():
		var a: Vector3 = points[i]
		var steps := 1 if i == points.size() - 1 else maxi(1, ceili(a.distance_to(points[i + 1]) / 8.0))
		for s in steps:
			var q: Vector3 = a if i == points.size() - 1 else a.lerp(points[i + 1], float(s) / steps)
			level = minf(level, world.terrain.get_height(q) - 0.4)
			pts.append([q.x, level, q.z])
	var widths := []
	for q in pts:
		widths.append(width)
	var mod := {"type": "river", "id": new_id(), "points": pts, "width": width, "depth": depth}
	var river := {"id": mod.id, "points": pts, "widths": widths, "frozen": frozen, "origin": "user"}
	undo.create_action("Add river")
	undo.add_do_method(func() -> void:
		map.water["rivers"] = map.water.get("rivers", []) + [river]
		world.build_water())
	undo.add_undo_method(func() -> void:
		var rv: Array = map.water.get("rivers", [])
		rv.erase(river)
		map.water["rivers"] = rv
		world.build_water())
	undo.commit_action(true)
	add_modifier(mod)
