@tool
extends GraphNode
## Graph view of one StoryCell: a title bar in the type's colour, a preview of the text,
## prerequisite / action summaries, one input port (except Start) and one output port per
## output. Port i on the right is cell.outputs[i].

signal add_output_pressed(cell_id: String)

const WIDTH := 260.0
const Ed := preload("edscale.gd")
const PREVIEW_CHARS := 140

var cell: StoryCell
var issue_level := -1     ## -1 none, else StoryValidator.Severity
var sim_mark := 0         ## 0 none, 1 visited in the simulator, 2 current
var _ports_color := Color(0.85, 0.85, 0.9)


func setup(c: StoryCell) -> void:
	cell = c
	custom_minimum_size.x = Ed.px(WIDTH)
	resizable = false
	refresh()


## Rebuilds rows, ports and colours from the cell (call after the cell changed).
func refresh() -> void:
	if cell == null:
		return
	for child in get_children():
		remove_child(child)
		child.queue_free()
	clear_all_slots()
	var color: Color = StoryCell.TYPE_COLORS[cell.type]
	title = "%s  ·  %s" % [StoryCell.TYPE_NAMES[cell.type], cell.display_name()]
	tooltip_text = "%s\nID: %s%s" % [StoryCell.TYPE_HINTS[cell.type], cell.id, "\n\n" + cell.notes if cell.notes != "" else ""]
	_apply_style(color)

	# Row 0: summary (input port on the left).
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(_label("#" + cell.id, Color(1, 1, 1, 0.45), 11))
	var preview := ""
	if cell.speaker != "" and (cell.type == StoryCell.Type.DIALOGUE or cell.type == StoryCell.Type.CHOICE):
		preview = cell.speaker + ": "
	preview += cell.text.strip_edges().replace("\n", " ")
	if preview.length() > PREVIEW_CHARS:
		preview = preview.substr(0, PREVIEW_CHARS - 1) + "…"
	if preview.strip_edges() != "":
		var l := _label(preview, Color(1, 1, 1, 0.9), 13)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = Ed.px(WIDTH - 30)
		body.add_child(l)
	if cell.has_prerequisites():
		body.add_child(_label("Requires: " + cell.prerequisites.describe(), Color(1.0, 0.8, 0.45), 11, true))
	if not cell.actions.is_empty():
		var acts := PackedStringArray(cell.actions.map(func(a: StoryAction) -> String: return a.describe()))
		body.add_child(_label("Does: " + ", ".join(acts), Color(0.55, 0.9, 0.85), 11, true))
	var extras: PackedStringArray = []
	if not cell.repeatable and cell.type != StoryCell.Type.START:
		extras.append("once")
	if not cell.tags.is_empty():
		extras.append("tags: " + ", ".join(cell.tags))
	if not extras.is_empty():
		body.add_child(_label(" · ".join(extras), Color(1, 1, 1, 0.5), 11))
	add_child(body)
	set_slot(0, cell.has_input(), 0, _ports_color, false, 0, _ports_color)

	# One row per output.
	for i in cell.outputs.size():
		var o := cell.outputs[i]
		var l := _label(cell.output_caption(i) + ("" if o.target_id != "" else "  (unconnected)"),
			Color(1, 1, 1, 0.85) if o.target_id != "" else Color(1, 0.6, 0.5, 0.9), 12, true)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(l)
		set_slot(get_child_count() - 1, false, 0, _ports_color, true, 0, color.lightened(0.35))
	if cell.type == StoryCell.Type.CHOICE or cell.type == StoryCell.Type.CONDITION:
		var add := Button.new()
		add.text = "+ Option" if cell.type == StoryCell.Type.CHOICE else "+ Branch"
		add.flat = true
		add.focus_mode = Control.FOCUS_NONE
		add.pressed.connect(func() -> void: add_output_pressed.emit(cell.id))
		add_child(add)


func _label(text_: String, color: Color, size_: int, wrap := false) -> Label:
	var l := Label.new()
	l.text = text_
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", Ed.font(size_))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = Ed.px(WIDTH - 30)
	return l


func set_issue_level(level: int) -> void:
	if level != issue_level:
		issue_level = level
		_apply_style(StoryCell.TYPE_COLORS[cell.type])


func set_sim_mark(mark: int) -> void:
	if mark != sim_mark:
		sim_mark = mark
		_apply_style(StoryCell.TYPE_COLORS[cell.type])


func _apply_style(color: Color) -> void:
	var base_title := get_theme_stylebox("titlebar", "GraphNode")
	var base_panel := get_theme_stylebox("panel", "GraphNode")
	var tb := _flat(base_title)
	tb.bg_color = color.darkened(0.15)
	add_theme_stylebox_override("titlebar", tb)
	var tbs := _flat(get_theme_stylebox("titlebar_selected", "GraphNode"))
	tbs.bg_color = color.lightened(0.1)
	add_theme_stylebox_override("titlebar_selected", tbs)
	var border := Color(0, 0, 0, 0)
	var width := 0
	if sim_mark == 2:
		border = Color(1.0, 0.85, 0.2)
		width = 3
	elif issue_level == StoryValidator.Severity.ERROR:
		border = Color(0.95, 0.3, 0.3)
		width = 2
	elif issue_level == StoryValidator.Severity.WARNING:
		border = Color(0.95, 0.75, 0.3)
		width = 2
	elif sim_mark == 1:
		border = Color(0.45, 0.85, 0.5)
		width = 2
	for key in ["panel", "panel_selected"]:
		var p := _flat(get_theme_stylebox(key, "GraphNode") if has_theme_stylebox(key, "GraphNode") else base_panel)
		p.bg_color = Color(0.13, 0.14, 0.17, 0.96) if key == "panel" else Color(0.17, 0.18, 0.22, 0.98)
		p.border_color = border if width > 0 else (Color(1, 1, 1, 0.55) if key == "panel_selected" else Color(1, 1, 1, 0.08))
		p.set_border_width_all(maxi(width, 1 if key == "panel" else 2))
		p.border_width_top = 0
		add_theme_stylebox_override(key, p)
	var title_label := _title_label()
	if title_label:
		title_label.add_theme_color_override("font_color", Color.WHITE)


func _title_label() -> Label:
	for c in get_titlebar_hbox().get_children():
		if c is Label:
			return c
	return null


static func _flat(sb: StyleBox) -> StyleBoxFlat:
	if sb is StyleBoxFlat:
		return (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
	var f := StyleBoxFlat.new()
	f.set_content_margin_all(8)
	f.set_corner_radius_all(4)
	return f
