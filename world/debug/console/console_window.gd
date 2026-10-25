## The console window: title bar (drag, double-click maximises, close), the log, the
## completion dropdown, the input line with its ghost suffix, the status bar and a resize
## grip. Built in code on the debug surface (scaled by DebugZoom). Keys while it is open:
## Return runs (or completes), Tab accepts a suggestion, Esc dismisses → clears → closes,
## ↑↓ step suggestions then history, PgUp/PgDn scroll, Cmd/Ctrl +/−/0 zoom.
class_name ConsoleWindow
extends Control

const T := preload("res://world/debug/console/console_theme.gd")

var console: DebugConsole
var model: ConsoleModel
var completion: ConsoleCompletion
var history := ConsoleHistory.new()

var _log: RichTextLabel
var _field: TextEdit
var _ghost: Label
var _prompt: Label
var _title_left: Label
var _title_right: Label
var _status_left: Label
var _status_right: Label
var _dropdown: Control
var _rendered: Array[Dictionary] = []   ## {seq, paragraphs} of blocks in the log, oldest first
var _dirty := true
var _input_rows := 1
var _row_h := 18.0
var _char_w := 9.0

var _desired := Rect2(Vector2(T.INSET, T.INSET), T.DEFAULT_SIZE)
var _maximized := false
var _drag := ""          ## "", "move", "resize"
var _grab := Vector2.ZERO
var _last_title_click := 0.0
var _hot := ""           ## hovered decoration: "close", "grip"
var _settling := false


func _init(c: DebugConsole) -> void:
	console = c
	model = c.model
	completion = ConsoleCompletion.new(model)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false
	_row_h = T.row_height()
	_char_w = T.char_width()
	_title_left = _label(T.TITLE_TEXT)
	_title_right = _label(T.TITLE_STATUS)
	_title_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.context_menu_enabled = true
	_log.focus_mode = Control.FOCUS_NONE
	_log.add_theme_font_override("normal_font", T.font())
	_log.add_theme_font_override("mono_font", T.font())
	_log.add_theme_font_size_override("normal_font_size", T.FONT_SIZE)
	_log.add_theme_font_size_override("mono_font_size", T.FONT_SIZE)
	_log.add_theme_color_override("default_color", Color.from_string(T.KIND_COLORS[T.Kind.INFO], Color.WHITE))
	_log.add_theme_color_override("selection_color", Color(T.DROPDOWN_SEL, 0.8))
	_log.add_theme_constant_override("line_separation", 0)
	_log.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_log.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_style_scrollbar(_log.get_v_scroll_bar())
	add_child(_log)
	_dropdown = Control.new()
	_dropdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dropdown.draw.connect(_draw_dropdown)
	_prompt = _label(T.PROMPT)
	_prompt.text = ">"
	_field = TextEdit.new()
	_field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_field.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_field.scroll_fit_content_height = false
	_field.caret_blink = true
	_field.caret_blink_interval = T.CARET_BLINK
	_field.context_menu_enabled = true
	_field.highlight_current_line = false
	_field.add_theme_font_override("font", T.font())
	_field.add_theme_font_size_override("font_size", T.FONT_SIZE)
	_field.add_theme_color_override("font_color", T.INPUT_TEXT)
	_field.add_theme_color_override("caret_color", T.CARET)
	_field.add_theme_color_override("selection_color", Color(T.DROPDOWN_SEL, 0.9))
	_field.add_theme_constant_override("line_spacing", 0)
	_field.add_theme_constant_override("caret_width", 2)
	for s in ["normal", "focus", "read_only"]:
		_field.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	_field.gui_input.connect(_on_field_input)
	_field.text_changed.connect(_on_text_changed)
	add_child(_field)
	_ghost = _label(T.GHOST)
	_status_left = _label(T.STATUS_BUSY)
	_status_right = _label(T.STATUS_IDLE)
	_status_right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_dropdown)
	model.block_appended.connect(_on_block)
	model.cleared.connect(_rebuild_log)
	model.display_level_changed.connect(_rebuild_log)
	_load_rect()
	_rebuild_log()
	resized.connect(_layout)


func _label(col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", T.font())
	l.add_theme_font_size_override("font_size", T.FONT_SIZE)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	add_child(l)
	return l


func _style_scrollbar(sb: VScrollBar) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = T.SCROLL_TRACK
	track.content_margin_left = 4
	track.content_margin_right = 4
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = T.SCROLL_THUMB
	thumb.set_corner_radius_all(3)
	var hot := thumb.duplicate() as StyleBoxFlat
	hot.bg_color = T.SCROLL_HOT
	sb.add_theme_stylebox_override("scroll", track)
	sb.add_theme_stylebox_override("grabber", thumb)
	sb.add_theme_stylebox_override("grabber_highlight", hot)
	sb.add_theme_stylebox_override("grabber_pressed", hot)
	sb.custom_minimum_size.x = 11


# --- open / close ------------------------------------------------------------------------------

func opened() -> void:
	fit()
	move_to_front()
	_scroll_to_bottom()
	_field.grab_focus()
	_refresh_input()
	var y := position.y
	modulate.a = 0.0
	position.y = y - 12.0
	var tw := create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	tw.tween_property(self, "position:y", y, 0.18)


func closed() -> void:
	_field.release_focus()
	_drag = ""
	_save_rect()


# --- geometry ----------------------------------------------------------------------------------

func canvas_size() -> Vector2:
	var p := get_parent_control()
	return p.size if p else get_viewport_rect().size


## Size and place the window on the surface (the wanted rect shrinks to fit; restoring a
## bigger surface brings the wanted size back).
func fit() -> void:
	var cs := canvas_size()
	var wanted := Vector2(INF, INF) if _maximized else _desired.size
	var at := Vector2(T.INSET, T.INSET) if _maximized else _desired.position
	var s := Vector2(
		minf(cs.x, maxf(T.MIN_SIZE.x, minf(wanted.x, cs.x - 2.0 * T.INSET))),
		minf(cs.y, maxf(T.MIN_SIZE.y, minf(wanted.y, cs.y - 2.0 * T.INSET))))
	size = s
	position = Vector2(clampf(at.x, 0.0, maxf(0.0, cs.x - s.x)), clampf(at.y, 0.0, maxf(0.0, cs.y - s.y)))
	_layout()


func _title_rect() -> Rect2:
	return Rect2(T.BORDER, T.BORDER, size.x - 2 * T.BORDER, T.TITLE_BAR)


func _close_rect() -> Rect2:
	return Rect2(size.x - T.BORDER - T.CLOSE - (T.TITLE_BAR - T.CLOSE) / 2.0, T.BORDER + (T.TITLE_BAR - T.CLOSE) / 2.0, T.CLOSE, T.CLOSE)


func _grip_rect() -> Rect2:
	return Rect2(size - Vector2(T.GRIP + T.BORDER, T.GRIP + T.BORDER), Vector2(T.GRIP, T.GRIP))


func _status_shown() -> bool:
	return _status_left.text != "" or _status_right.text != ""


func _layout() -> void:
	if _log == null:
		return
	var b := float(T.BORDER)
	var p := float(T.PADDING)
	var inner_w := size.x - 2.0 * b
	var title := _title_rect()
	_title_left.position = Vector2(b + p, b + (T.TITLE_BAR - _row_h) / 2.0)
	_title_right.position = Vector2(b + p, _title_left.position.y)
	var title_w := title.size.x - 2.0 * p - T.CLOSE - p
	_title_right.size = Vector2(title_w, _row_h)
	_title_left.size = Vector2(title_w, _row_h)
	var status_h := _row_h if _status_shown() else 0.0
	var furniture := 2.0 * b + T.TITLE_BAR + status_h
	var allowed := clampi(int((size.y - furniture - 3.0 * _row_h - p) / _row_h), 1, T.MAX_INPUT_ROWS)
	var rows := mini(_input_rows, allowed)
	var input_h := p + rows * _row_h
	var bottom := size.y - b - status_h
	_prompt.position = Vector2(b + p, bottom - input_h + p * 0.5)
	_prompt.size = Vector2(T.PROMPT_WIDTH, _row_h)
	_field.position = Vector2(b + p + T.PROMPT_WIDTH, bottom - input_h + p * 0.5)
	_field.size = Vector2(inner_w - 2.0 * p - T.PROMPT_WIDTH - T.GRIP * 0.5, rows * _row_h)
	_log.position = Vector2(b + p, b + T.TITLE_BAR + p * 0.5)
	_log.size = Vector2(inner_w - p, bottom - input_h - _log.position.y - p * 0.5)
	_status_left.position = Vector2(b + p, size.y - b - status_h)
	_status_left.size = Vector2(inner_w * 0.6, _row_h)
	_status_right.position = Vector2(b + inner_w * 0.4, size.y - b - status_h)
	_status_right.size = Vector2(inner_w * 0.6 - p - T.GRIP - p, _row_h)
	_status_left.visible = status_h > 0.0
	_status_right.visible = status_h > 0.0
	model.columns = maxi(1, int((_log.size.x - 14.0) / _char_w))
	_place_ghost()
	_place_dropdown()
	queue_redraw()


# --- drawing -----------------------------------------------------------------------------------

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(Rect2(T.SHADOW, size), T.SHADOW_COLOR)
	draw_rect(r, T.BACKGROUND)
	draw_rect(_title_rect(), T.TITLE_BG)
	var input_top := _field.position.y - T.PADDING * 0.5
	draw_rect(Rect2(T.BORDER, input_top, size.x - 2 * T.BORDER, _field.size.y + T.PADDING), T.INPUT_BG)
	if _status_shown():
		draw_rect(Rect2(T.BORDER, _status_left.position.y, size.x - 2 * T.BORDER, _row_h), T.STATUS_BG)
	draw_rect(r.grow(-T.BORDER / 2.0), T.BORDER_COLOR, false, T.BORDER)
	var c := _close_rect()
	draw_rect(c, T.CLOSE_HOT if _hot == "close" else T.CLOSE_BG)
	var m := c.grow(-4.0)
	draw_line(m.position, m.end, T.CLOSE_GLYPH, 1.5)
	draw_line(Vector2(m.end.x, m.position.y), Vector2(m.position.x, m.end.y), T.CLOSE_GLYPH, 1.5)
	var g := _grip_rect()
	var gc := T.GRIP_HOT if _hot == "grip" else T.GRIP_COLOR
	for i in 3:
		var o := 4.0 + i * 4.0
		draw_line(g.end - Vector2(o, 1), g.end - Vector2(1, o), gc, 1.5)


func _draw_dropdown() -> void:
	if not completion.is_open():
		return
	var w := completion.window()
	var p := float(T.PADDING)
	var bw := float(T.BORDER)
	_dropdown.draw_rect(Rect2(Vector2.ZERO, _dropdown.size), T.DROPDOWN_BG)
	_dropdown.draw_rect(Rect2(Vector2.ONE, _dropdown.size - Vector2(2, 2)), T.BORDER_COLOR, false, bw)
	var f := T.font()
	var asc := f.get_ascent(T.FONT_SIZE)
	var hl := completion.highlight_length()
	for i in range(w.x, w.y):
		var y := p + (i - w.x) * _row_h
		if i == completion.selected:
			_dropdown.draw_rect(Rect2(bw, y, _dropdown.size.x - 2.0 * bw, _row_h), T.DROPDOWN_SEL)
		var text := completion.display(i)
		var head := text.substr(0, hl)
		var x := p + bw
		_dropdown.draw_string(f, Vector2(x, y + asc), head, HORIZONTAL_ALIGNMENT_LEFT, -1, T.FONT_SIZE, Color.from_string(T.AMBER, Color.WHITE))
		_dropdown.draw_string(f, Vector2(x + head.length() * _char_w, y + asc), text.substr(hl), HORIZONTAL_ALIGNMENT_LEFT, -1, T.FONT_SIZE, T.DROPDOWN_TEXT)


func _place_dropdown() -> void:
	if not completion.is_open():
		_dropdown.visible = false
		return
	var w := completion.window()
	var widest := 0
	for i in range(w.x, w.y):
		widest = maxi(widest, completion.display(i).length())
	var n := w.y - w.x
	var s := Vector2(widest * _char_w + 2.0 * T.PADDING + 2.0 * T.BORDER, n * _row_h + 2.0 * T.PADDING)
	s.x = minf(s.x, size.x - _field.position.x - T.BORDER)
	_dropdown.size = s
	_dropdown.position = Vector2(T.BORDER + T.PADDING + T.PROMPT_WIDTH, _field.position.y - T.PADDING * 0.5 - s.y)
	_dropdown.visible = true
	_dropdown.move_to_front()
	_dropdown.queue_redraw()


func _place_ghost() -> void:
	var g := completion.ghost()
	_ghost.text = g
	if g == "":
		_ghost.visible = false
		return
	var t := _field.text
	# The face is monospaced, so the pen position after the last character is arithmetic
	# (TextEdit.get_pos_at_line_column is -1 before layout and a character early after).
	var cols := maxi(1, int(_field.size.x / _char_w))
	var row := mini(t.length() / cols, _input_rows - 1)
	var pos := Vector2((t.length() % cols) * _char_w, (row + 1) * _row_h - 2.0)
	_ghost.visible = true
	_ghost.position = _field.position + Vector2(pos.x + 2.0, pos.y - _row_h + 2.0)  # just past the caret
	_ghost.size = Vector2(maxf(0.0, _field.position.x + _field.size.x - _ghost.position.x), _row_h)


# --- per frame ---------------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if not visible:
		return
	var cs := canvas_size()
	if not _settling and (position.x + size.x > cs.x + 0.5 or position.y + size.y > cs.y + 0.5):
		fit()
	var tr := model.bars.render(ConsoleBars.Slot.TITLE_RIGHT)
	var tl := model.bars.render(ConsoleBars.Slot.TITLE_LEFT)
	var avail := int(_title_right.size.x / _char_w)
	if tl.length() + 2 + tr.length() > avail:
		tl = ""
	if _title_left.text != tl:
		_title_left.text = tl
	if _title_right.text != tr:
		_title_right.text = tr
	var was := _status_shown()
	var sl := model.bars.render(ConsoleBars.Slot.STATUS_LEFT)
	var sr := model.bars.render(ConsoleBars.Slot.STATUS_RIGHT)
	if _status_left.text != sl:
		_status_left.text = sl
	if _status_right.text != sr:
		_status_right.text = sr
	if was != _status_shown():
		_layout()


# --- log ---------------------------------------------------------------------------------------

func _rebuild_log() -> void:
	if _log == null:
		return
	_log.clear()
	_rendered.clear()
	for b in model.blocks:
		_on_block(b)
	_scroll_to_bottom()


func _on_block(b: Dictionary) -> void:
	if _log == null or not model.is_visible(b):
		return
	var oldest := int(model.blocks[0].seq) if not model.blocks.is_empty() else 0
	while not _rendered.is_empty() and int(_rendered[0].seq) < oldest:
		for i in int(_rendered[0].paragraphs):
			_log.remove_paragraph(0)
		_rendered.pop_front()
	var text := ConsoleModel.block_bbcode(b)
	var first := _rendered.is_empty()
	if not first and _log.get_paragraph_count() > 0:
		_log.append_text("\n")
	_log.append_text(text)
	_rendered.append({"seq": int(b.get("seq", 0)), "paragraphs": str(b.text).count("\n") + 1})


func _scroll_to_bottom() -> void:
	if _log:
		_log.scroll_following = true
		_log.scroll_to_line(maxi(0, _log.get_line_count() - 1))


func scroll_rows(rows: int) -> void:
	var sb := _log.get_v_scroll_bar()
	sb.value = clampf(sb.value + rows * _row_h, 0.0, sb.max_value)


# --- input -------------------------------------------------------------------------------------

func _on_field_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed:
		return
	if console.handle_global_key(k):
		_field.accept_event()
		return
	var cmd := k.meta_pressed if OS.get_name() == "macOS" else k.ctrl_pressed
	match k.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			if not k.echo:
				submit()
		KEY_TAB:
			if not k.echo:
				accept_completion()
		KEY_ESCAPE:
			if not k.echo:
				escape()
		KEY_UP:
			recall(-1)
		KEY_DOWN:
			recall(1)
		KEY_PAGEUP:
			scroll_rows(-10)
		KEY_PAGEDOWN:
			scroll_rows(10)
		KEY_C:
			if cmd and not _field.has_selection() and _log.get_selected_text() != "":
				DisplayServer.clipboard_set(_log.get_selected_text())
			else:
				return
		_:
			return
	_field.accept_event()


func _on_text_changed() -> void:
	if _field.text.contains("\n"):
		var col := _field.get_caret_column()
		_field.text = _field.text.replace("\r", "").replace("\n", " ")
		_field.set_caret_column(col)
	history.to_bottom()
	_refresh_input()


## Recomputes suggestions, ghost, dropdown and the input height.
func _refresh_input() -> void:
	completion.refresh(_field.text)
	var rows := _field.get_line_wrap_count(0) + 1 if _field.get_line_count() > 0 else 1
	if rows != _input_rows:
		_input_rows = rows
	_layout()


func set_line(text: String) -> void:
	_field.text = text
	_field.set_caret_line(0)
	_field.set_caret_column(text.length())
	_refresh_input()


func line() -> String:
	return _field.text


func accept_completion() -> void:
	if completion.selected >= 0:
		set_line(completion.apply(_field.text))


func submit() -> void:
	if completion.completes_on_submit():
		accept_completion()
		if model.is_short_of_arguments(_field.text):
			return
	var submitted := _field.text
	_field.text = ""
	history.to_bottom()
	completion.reset()
	_refresh_input()
	if submitted.strip_edges() == "":
		return
	history.record(submitted)
	_scroll_to_bottom()
	model.execute(submitted)
	_scroll_to_bottom()


func escape() -> void:
	if completion.is_open():
		completion.dismiss()
		_layout()
	elif _field.text != "":
		set_line("")
	else:
		console.set_open(false)


func recall(delta: int) -> void:
	if completion.can_step(delta):
		completion.move(delta)
		_place_ghost()
		_place_dropdown()
		return
	var v: Variant = history.up() if delta < 0 else history.down()
	if v == null:
		return
	_field.text = str(v)
	_field.set_caret_column(_field.text.length())
	completion.refresh(_field.text)
	completion.withhold()
	_layout()


# --- mouse -------------------------------------------------------------------------------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if not mb.pressed:
			if _drag != "":
				_drag = ""
				_save_rect()
			_field.grab_focus()
			accept_event()
			return
		move_to_front()
		var p := mb.position
		if _close_rect().has_point(p):
			console.set_open(false)
		elif _grip_rect().grow(4.0).has_point(p):
			_drag = "resize"
			_grab = size - p
			_maximized = false
		elif _title_rect().has_point(p):
			var now := Time.get_ticks_msec() / 1000.0
			if now - _last_title_click < T.DOUBLE_CLICK:
				_drag = ""
				toggle_maximized()
				_last_title_click = 0.0
			else:
				_last_title_click = now
				if not _maximized:
					_drag = "move"
					_grab = p
		accept_event()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		var cs := canvas_size()
		if _drag == "move":
			var at := position + mm.position - _grab
			position = Vector2(clampf(at.x, 0.0, maxf(0.0, cs.x - size.x)), clampf(at.y, 0.0, maxf(0.0, cs.y - size.y)))
			_desired.position = position
		elif _drag == "resize":
			var s := (mm.position + _grab).max(T.MIN_SIZE)
			s = s.min(cs - position)
			size = s
			_desired = Rect2(position, s)
		var hot := "close" if _close_rect().has_point(mm.position) else ("grip" if _grip_rect().grow(4.0).has_point(mm.position) else "")
		if hot != _hot:
			_hot = hot
			queue_redraw()
		accept_event()


func toggle_maximized() -> void:
	_maximized = not _maximized
	fit()
	_save_rect()


func _save_rect() -> void:
	if not DebugZoom.persist:
		return
	var cfg := ConfigFile.new()
	cfg.load(DevGate.SETTINGS)
	cfg.set_value("console", "rect", [_desired.position.x, _desired.position.y, _desired.size.x, _desired.size.y])
	cfg.set_value("console", "maximized", _maximized)
	cfg.save(DevGate.SETTINGS)


func _load_rect() -> void:
	var cfg := ConfigFile.new()
	if not DebugZoom.persist or cfg.load(DevGate.SETTINGS) != OK:
		return
	var r: Variant = cfg.get_value("console", "rect", null)
	if r is Array and (r as Array).size() == 4:
		_desired = Rect2(r[0], r[1], r[2], r[3])
	_maximized = bool(cfg.get_value("console", "maximized", false))
