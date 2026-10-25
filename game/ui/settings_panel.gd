## Graphics settings screen (main menu Options, and the game's pause menu). Every change
## applies at once and is saved (GraphicsSettings); `world` is the running world, if any.
class_name SettingsPanel
extends PanelContainer

signal closed

var world: WorldView
var settings := GraphicsSettings.current()

var _quality: OptionButton
var _min_res: HSlider
var _min_res_label: Label
var _res: HSlider
var _res_label: Label
var _vsync: CheckButton
var _cap: OptionButton
var _fullscreen: CheckButton
var _show_fps: CheckButton
var _hint: Label
var _rows := {}  ## control -> its label (to hide a row that doesn't apply)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(560, 0)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.11, 0.14, 0.96)
	bg.set_corner_radius_all(6)
	bg.set_content_margin_all(22)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)
	var title := Label.new()
	title.text = "Graphics"
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 10)
	box.add_child(grid)

	_quality = OptionButton.new()
	for q: String in GraphicsSettings.QUALITIES:
		_quality.add_item(q + ("  (recommended)" if q == "Adaptive" else ""))
	_quality.item_selected.connect(func(i: int) -> void:
		settings.quality = GraphicsSettings.QUALITIES[i]
		_changed())
	_row(grid, "Quality", _quality)
	_min_res = _slider(func(v: float) -> void: settings.min_resolution = v)
	_min_res_label = Label.new()
	_row(grid, "Lowest resolution", _with_value(_min_res, _min_res_label))
	_res = _slider(func(v: float) -> void: settings.resolution = v)
	_res_label = Label.new()
	_row(grid, "Resolution", _with_value(_res, _res_label))
	_vsync = CheckButton.new()
	_vsync.toggled.connect(func(on: bool) -> void:
		settings.vsync = on
		_changed())
	_row(grid, "Vertical sync", _vsync)
	_cap = OptionButton.new()
	for f: int in GraphicsSettings.FPS_CAPS:
		_cap.add_item("Off" if f == 0 else "%d fps" % f)
	_cap.item_selected.connect(func(i: int) -> void:
		settings.max_fps = GraphicsSettings.FPS_CAPS[i]
		_changed())
	_row(grid, "Frame-rate cap", _cap)
	_fullscreen = CheckButton.new()
	_fullscreen.text = "Full screen"
	_fullscreen.toggled.connect(func(on: bool) -> void:
		settings.fullscreen = on
		_changed())
	_row(grid, "Display", _fullscreen)
	_show_fps = CheckButton.new()
	_show_fps.toggled.connect(func(on: bool) -> void:
		settings.show_fps = on
		_changed())
	_row(grid, "Frame-rate counter", _show_fps)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size.x = 520
	_hint.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_hint)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(func() -> void: closed.emit())
	box.add_child(back)
	_show()


func _row(grid: GridContainer, label: String, control: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)
	_rows[control] = l


func _slider(setter: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.5
	s.max_value = 1.0
	s.step = 0.05
	s.custom_minimum_size.x = 220
	s.value_changed.connect(func(v: float) -> void:
		setter.call(v)
		_changed())
	return s


func _with_value(s: HSlider, l: Label) -> HBoxContainer:
	var h := HBoxContainer.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(s)
	l.custom_minimum_size.x = 56
	h.add_child(l)
	return h


## Puts the settings into the controls (without triggering changes).
func _show() -> void:
	_quality.select(GraphicsSettings.QUALITIES.find(settings.quality))
	_min_res.set_value_no_signal(settings.min_resolution)
	_res.set_value_no_signal(settings.resolution)
	_vsync.set_pressed_no_signal(settings.vsync)
	_cap.select(maxi(0, GraphicsSettings.FPS_CAPS.find(settings.max_fps)))
	_fullscreen.set_pressed_no_signal(settings.fullscreen)
	_show_fps.set_pressed_no_signal(settings.show_fps)
	_update_labels()


func _update_labels() -> void:
	var adaptive := settings.quality == "Adaptive"
	_min_res.editable = adaptive
	_res.editable = not adaptive
	# Only the resolution setting that applies is shown.
	for c: Control in [_min_res.get_parent(), _res.get_parent()]:
		var on: bool = (c == _min_res.get_parent()) == adaptive
		c.visible = on
		(_rows[c] as Label).visible = on
	_min_res_label.text = "%d %%" % roundi(settings.min_resolution * 100.0)
	_res_label.text = "%d %%" % roundi(settings.resolution * 100.0)
	if adaptive:
		_hint.text = "Adaptive keeps the game at %d fps: when the computer is busy it renders fewer pixels (down to the lowest resolution), then drops ambient occlusion, then draw distance — and brings them back when it can." % int(settings.target_fps())
	else:
		_hint.text = "%s detail at a fixed %d %% resolution%s." % [settings.quality, roundi(settings.resolution * 100.0),
			"; ground textures are simplified" if settings.quality in ["Medium", "Low"] else ""]


func _changed() -> void:
	_update_labels()
	settings.apply_window(get_window())
	if world and is_instance_valid(world):
		settings.apply_world(world)
	settings.save_file()
