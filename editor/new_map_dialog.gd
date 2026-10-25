## The "New Map" screen: pick size, seed, biomes and sliders; a live preview updates as
## you change them (quick low-res first, then refined). "Generate" builds the real map.
class_name NewMapDialog
extends Control

signal generate_requested(params: GenParams, layout: WorldLayout)
signal cancelled

const PREVIEW_STEPS := [128, 256, 512]

var params := GenParams.new()
var _preview_rect: TextureRect
var _status: Label
var _layer := PreviewPainter.Mode.BIOMES
var _layout: WorldLayout       ## latest finished preview layout
var _layout_size := 0
var _layout_id := -1
var _generate_btn: Button
var _seed_edit: LineEdit

# Background preview worker (owns its LayoutGenerator so stage caches stay warm).
var _thread: Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _gen := LayoutGenerator.new()
var _request := {}            ## {id, params, size}
var _request_id := 0
var _quit := false
var _dirty_time := -1.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.1, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build_ui()
	_thread = Thread.new()
	_thread.start(_worker)
	_schedule()


func _exit_tree() -> void:
	_mutex.lock()
	_quit = true
	_mutex.unlock()
	_gen.cancelled = true
	_sem.post()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()


func set_params(p: GenParams) -> void:
	params = p.duplicate_params()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)
	var title := Label.new()
	title.text = "New Map"
	title.add_theme_font_size_override("font_size", 26)
	root.add_child(title)

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 24)
	root.add_child(cols)

	# Left: settings.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 440
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cols.add_child(scroll)
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_theme_constant_override("separation", 6)
	scroll.add_child(form)

	_section(form, "Map")
	var name_row := _row(form, "Name")
	var name_edit := LineEdit.new()
	name_edit.text = params.name
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_changed.connect(func(t: String) -> void: params.name = t)
	name_row.add_child(name_edit)

	var size_row := _row(form, "Size")
	var size_opt := OptionButton.new()
	for km in GenParams.SIZES_KM:
		size_opt.add_item("%d × %d km" % [km, km], km)
	size_opt.select(GenParams.SIZES_KM.find(params.size_km))
	size_opt.item_selected.connect(func(i: int) -> void:
		params.size_km = GenParams.SIZES_KM[i]
		_schedule())
	size_row.add_child(size_opt)

	var seed_row := _row(form, "Seed")
	_seed_edit = LineEdit.new()
	_seed_edit.text = params.seed
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_edit.tooltip_text = "Any word or number. Same seed + same settings = same map."
	_seed_edit.text_changed.connect(func(t: String) -> void:
		params.seed = t if t != "" else "0"
		_schedule())
	seed_row.add_child(_seed_edit)
	var dice := Button.new()
	dice.text = "🎲 Random"
	dice.pressed.connect(func() -> void:
		_seed_edit.text = str(randi() % 1000000)
		params.seed = _seed_edit.text
		_schedule())
	seed_row.add_child(dice)

	_section(form, "Biomes")
	var grid := GridContainer.new()
	grid.columns = 2
	for b in GenParams.BIOME_COUNT:
		var cb := CheckBox.new()
		cb.text = GenParams.BIOME_NAMES[b]
		cb.button_pressed = params.biomes[b]
		var swatch := PreviewPainter.BIOME_COLORS[b]
		cb.add_theme_color_override("font_color", swatch.lightened(0.35))
		cb.toggled.connect(func(on: bool) -> void:
			params.biomes[b] = on
			_schedule())
		grid.add_child(cb)
	form.add_child(grid)

	_section(form, "Land & water")
	_slider(form, "land_water", "Mainland ↔ Archipelago", "How much of the map is sea.")
	_slider(form, "islands", "Islands", "Extra islands off the coast.")
	_slider(form, "coast_rough", "Coastline roughness", "Smooth bays ↔ ragged coasts.")
	_slider(form, "rivers", "Rivers", "How many rivers.")
	_slider(form, "lakes", "Lakes", "How many lakes (only where it's wet enough).")
	_section(form, "Shape of the land")
	_slider(form, "mountains", "Mountains", "Height and spread of mountain ranges.")
	_slider(form, "hilliness", "Hilliness", "Flat plains ↔ rolling hills.")
	_slider(form, "rifts", "Canyons & rifts", "Cracks and canyons cut into the land.")
	_slider(form, "blend_width", "Biome blending", "Sharp ↔ wide transitions between biomes.")
	_slider(form, "vegetation", "Vegetation", "How dense forests and plants are.")

	_section(form, "City")
	var city_cb := CheckBox.new()
	city_cb.text = "Large city"
	city_cb.button_pressed = params.city
	city_cb.toggled.connect(func(on: bool) -> void:
		params.city = on
		_schedule())
	form.add_child(city_cb)
	_slider(form, "city_size", "City size", "Town ↔ huge city (share of the map).")
	var walls := CheckBox.new()
	walls.text = "Old town walls"
	walls.button_pressed = params.city_walls
	walls.toggled.connect(func(on: bool) -> void: params.city_walls = on)
	form.add_child(walls)
	_slider(form, "city_modern", "Modern districts", "Share of the city built in the modern style.")

	# Right: preview.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	cols.add_child(right)
	var layer_row := HBoxContainer.new()
	right.add_child(layer_row)
	var lbl := Label.new()
	lbl.text = "Preview:"
	layer_row.add_child(lbl)
	for i in ["Biomes", "Height", "Water"].size():
		var b := Button.new()
		b.text = ["Biomes", "Height", "Water"][i]
		b.toggle_mode = true
		b.button_pressed = i == 0
		b.button_group = layer_row.get_meta("group") if layer_row.has_meta("group") else ButtonGroup.new()
		layer_row.set_meta("group", b.button_group)
		b.pressed.connect(func() -> void:
			_layer = i
			_repaint())
		layer_row.add_child(b)
	_preview_rect = TextureRect.new()
	_preview_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	right.add_child(_preview_rect)
	_status = Label.new()
	_status.text = "Generating preview…"
	right.add_child(_status)
	var legend := Label.new()
	legend.text = "North is up. The orange ring is the city; the dark ring inside it is the old town wall."
	legend.modulate = Color(1, 1, 1, 0.6)
	right.add_child(legend)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 10)
	root.add_child(buttons)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: cancelled.emit())
	buttons.add_child(cancel)
	_generate_btn = Button.new()
	_generate_btn.text = "  Generate map  "
	_generate_btn.pressed.connect(_on_generate)
	buttons.add_child(_generate_btn)


func _section(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	box.add_child(HSeparator.new())
	box.add_child(l)


func _row(box: VBoxContainer, label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 70
	row.add_child(l)
	box.add_child(row)
	return row


func _slider(box: VBoxContainer, key: String, label: String, tip: String) -> void:
	var l := Label.new()
	l.text = label
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	box.add_child(l)
	var row := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 100
	s.step = 1
	s.value = float(params.get(key)) * 100.0
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.tooltip_text = tip
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 44
	v.text = "%d%%" % int(s.value)
	row.add_child(v)
	s.value_changed.connect(func(x: float) -> void:
		v.text = "%d%%" % int(x)
		params.set(key, x / 100.0)
		_schedule())
	box.add_child(row)


# --- preview pipeline ----------------------------------------------------------

func _schedule() -> void:
	_dirty_time = 0.08  # small debounce while dragging


func _process(delta: float) -> void:
	if _dirty_time >= 0.0:
		_dirty_time -= delta
		if _dirty_time < 0.0:
			_request_id += 1
			_post(PREVIEW_STEPS[0])


func _post(size: int) -> void:
	_mutex.lock()
	_request = {"id": _request_id, "params": params.duplicate_params(), "size": size}
	_mutex.unlock()
	_gen.cancelled = true  # abandon whatever is running; the worker picks up the new request
	_sem.post()
	_status.text = "Generating preview (%d²)…" % size


func _worker() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		var quit := _quit
		var req := _request.duplicate()
		_request = {}
		_mutex.unlock()
		if quit:
			return
		if req.is_empty():
			continue
		var t := Time.get_ticks_msec()
		var L := _gen.generate(req.params, req.size)
		if L == null:
			continue  # cancelled by a newer request
		_on_layout_ready.call_deferred(L, req.id, req.size, Time.get_ticks_msec() - t)


func _on_layout_ready(L: WorldLayout, id: int, size: int, ms: int) -> void:
	if id != _request_id:
		return
	_layout = L
	_layout_size = size
	_layout_id = id
	_repaint()
	var idx := PREVIEW_STEPS.find(size)
	if idx < PREVIEW_STEPS.size() - 1:
		_post(PREVIEW_STEPS[idx + 1])
		_status.text = "Refining… (%d² took %d ms)" % [size, ms]
	else:
		_status.text = "Ready — %d rivers, %d lakes%s. (%d ms)" % [L.rivers.size(), L.lakes.size(),
			", city %.1f km across" % (L.city_radius * 2.0 / 1000.0) if L.has_city else "", ms]


func _repaint() -> void:
	if _layout:
		_preview_rect.texture = ImageTexture.create_from_image(PreviewPainter.paint(_layout, _layer))


func _on_generate() -> void:
	if _layout and _layout_size == PREVIEW_STEPS[-1] and _layout_id == _request_id and _dirty_time < 0.0:
		generate_requested.emit(params.duplicate_params(), _layout)
	else:
		# The refined layout isn't ready yet: the editor will build it.
		generate_requested.emit(params.duplicate_params(), null)
