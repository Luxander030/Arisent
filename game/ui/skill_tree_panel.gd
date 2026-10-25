## The skill tree screen (K): the nodes of the project's SkillTree drawn where the file
## places them, joined by their connections. Click a skill to learn its next rank (paid
## with skill points); hover for its description and what it needs. Drag to move the view,
## wheel to zoom, Home to see everything.
##   learned   — filled in its colour (gold rim when mastered)
##   available — dark with a coloured rim (bright when you can afford it)
##   locked    — grey: learn one of the skills leading to it first
class_name SkillTreePanel
extends Control

signal learned(id: String)

const R := 24.0                 ## node radius in tree units
const MIN_ZOOM := 0.2
const MAX_ZOOM := 2.0
const GOLD := Color(1.0, 0.82, 0.3)
const LOCKED := Color(0.32, 0.33, 0.36)

var progress: PlayerProgress
var tree: SkillTree
var zoom := 0.85
var center := Vector2.ZERO      ## tree point at the middle of the screen
var hover := ""
var _placed := false
var _press_at := Vector2.INF
var _dragged := false
var _flash := {}                ## id -> seconds left
var _header: Label
var _hint: Label
var _tip: PanelContainer
var _tip_text: RichTextLabel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	_header = _label(22)
	_header.position = Vector2(20, 14)
	_hint = _label(15)
	_hint.modulate = Color(1, 1, 1, 0.65)
	_hint.text = "Click a skill to learn a rank  ·  drag to move  ·  wheel to zoom  ·  Home shows everything  ·  K or Esc closes"
	_tip = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.1, 0.96)
	sb.border_color = Color(0.5, 0.55, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	_tip.add_theme_stylebox_override("panel", sb)
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_text = RichTextLabel.new()
	_tip_text.bbcode_enabled = true
	_tip_text.fit_content = true
	_tip_text.custom_minimum_size.x = 340
	_tip_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_text.add_theme_font_size_override("normal_font_size", 15)
	_tip_text.add_theme_font_size_override("bold_font_size", 18)
	_tip.add_child(_tip_text)
	_tip.visible = false
	add_child(_tip)
	visible = false
	resized.connect(_place_labels)
	if progress:
		progress.tree_changed.connect(refresh)
		progress.leveled.connect(func(_l: int) -> void: refresh())


func _label(size_px: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _place_labels() -> void:
	_hint.position = Vector2(20, size.y - 34)


func open() -> void:
	if tree == null:
		tree = SkillTree.project()
	visible = true
	if not _placed:
		_placed = true
		var roots := tree.roots()
		center = (tree.node(roots[0]).pos as Vector2) + Vector2(0, -180) if not roots.is_empty() else tree.bounds().get_center()
	grab_focus()
	_place_labels()
	refresh()


func close() -> void:
	visible = false
	hover = ""
	_tip.visible = false


func refresh() -> void:
	if tree == null or progress == null:
		return
	var learned_n := 0
	for id: String in progress.tree_ranks:
		if tree.has(id) and progress.tree_rank(id) > 0:
			learned_n += 1
	_header.text = "%s   ·   Skill points: %d   ·   Level %d   ·   %d of %d skills learned" % [
		tree.name, progress.skill_points(tree), progress.level(), learned_n, tree.order.size()]
	if not tree.errors.is_empty() and tree.order.is_empty():
		_header.text = "No skill tree: %s (%s)" % [", ".join(tree.errors), tree.path]
	_update_tip()
	queue_redraw()


## Shows the whole tree.
func fit() -> void:
	var b := tree.bounds().grow(R * 3.0)
	center = b.get_center()
	zoom = clampf(minf((size.x - 40.0) / maxf(b.size.x, 1.0), (size.y - 120.0) / maxf(b.size.y, 1.0)), MIN_ZOOM, MAX_ZOOM)
	hover = node_at(get_local_mouse_position())
	_update_tip()
	queue_redraw()


func to_screen(p: Vector2) -> Vector2:
	return size * 0.5 + (p - center) * zoom


func to_tree(s: Vector2) -> Vector2:
	return center + (s - size * 0.5) / zoom


func node_at(screen_pos: Vector2) -> String:
	var p := to_tree(screen_pos)
	for id in tree.order:
		if (tree.nodes[id].pos as Vector2).distance_to(p) <= R * 1.15:
			return id
	return ""


## What a node looks like right now: "learned", "maxed", "available", "affordable" or "locked".
func state_of(id: String) -> String:
	var n := tree.node(id)
	var r := progress.tree_rank(id)
	if r >= int(n.max_rank):
		return "maxed"
	if r > 0:
		return "learned"
	if not tree.is_unlocked(progress.tree_ranks, id):
		return "locked"
	return "affordable" if progress.skill_points(tree) >= int(n.cost) else "available"


## Learns a rank of `id`; returns "" or why not (shown in the tooltip too).
func learn(id: String) -> String:
	var why := progress.learn(tree, id)
	if why == "":
		_flash[id] = 0.4
		learned.emit(id)
	return why


# --- drawing ---------------------------------------------------------------------------------

func _process(dt: float) -> void:
	if not visible:
		return
	for id: String in _flash.keys():
		_flash[id] = float(_flash[id]) - dt
		if float(_flash[id]) <= 0.0:
			_flash.erase(id)
	queue_redraw()  # available nodes pulse


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.035, 0.05, 0.97))
	if tree == null or progress == null:
		return
	var w := clampf(3.0 * zoom, 1.5, 5.0)
	var ranks := progress.tree_ranks
	for id in tree.order:
		var a := to_screen(tree.nodes[id].pos)
		for c in (tree.nodes[id].connections as PackedStringArray):
			if not tree.has(c):
				continue
			var b := to_screen(tree.nodes[c].pos)
			var col := Color(0.4, 0.42, 0.46, 0.35)
			if int(ranks.get(id, 0)) > 0:
				col = GOLD if int(ranks.get(c, 0)) > 0 else Color(tree.nodes[id].color as Color, 0.85).lightened(0.2)
			var dir := (b - a).normalized()
			draw_line(a + dir * R * zoom, b - dir * R * zoom, col, w, true)
	var font := ThemeDB.fallback_font
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 250.0)
	for id in tree.order:
		var n: Dictionary = tree.nodes[id]
		var p := to_screen(n.pos)
		if p.x < -100 or p.y < -100 or p.x > size.x + 100 or p.y > size.y + 100:
			continue
		var st := state_of(id)
		var base: Color = n.color
		var fill := base
		var rim := Color.WHITE
		match st:
			"maxed":
				rim = GOLD
			"learned":
				rim = Color(1, 1, 1, 0.9)
			"affordable":
				fill = base.darkened(0.65)
				rim = base.lightened(0.35).lerp(Color.WHITE, pulse * 0.6)
			"available":
				fill = base.darkened(0.65)
				rim = base.darkened(0.1)
			"locked":
				fill = Color(0.1, 0.1, 0.12)
				rim = LOCKED
		var r := R * zoom * (1.12 if id == hover else 1.0)
		if _flash.has(id):
			r *= 1.0 + float(_flash[id]) * 0.5
		_shape(p, r, n.shape, fill, true)
		_shape(p, r, n.shape, rim, false, clampf(2.5 * zoom, 1.5, 4.0) * (1.6 if st == "maxed" else 1.0))
		var fs := int(clampf(13.0 * zoom, 9.0, 20.0))
		if r >= 14.0:  # too small to read below that; the tooltip still has it
			var rank_text := "%d/%d" % [progress.tree_rank(id), n.max_rank]
			draw_string(font, p + Vector2(-r * 1.5, fs * 0.35), rank_text, HORIZONTAL_ALIGNMENT_CENTER, r * 3.0, fs,
				Color.WHITE if st != "locked" else Color(0.6, 0.6, 0.65))
		if zoom >= 0.55:
			var name_col := Color(0.9, 0.92, 0.96) if st != "locked" else Color(0.55, 0.56, 0.6)
			draw_string_outline(font, p + Vector2(-90, r + fs + 4), str(n.name), HORIZONTAL_ALIGNMENT_CENTER, 180, fs, 4, Color(0, 0, 0, 0.9))
			draw_string(font, p + Vector2(-90, r + fs + 4), str(n.name), HORIZONTAL_ALIGNMENT_CENTER, 180, fs, name_col)


func _shape(p: Vector2, r: float, shape: String, col: Color, filled: bool, width := 2.0) -> void:
	match shape:
		"square":
			var rect := Rect2(p - Vector2(r, r) * 0.88, Vector2(r, r) * 1.76)
			draw_rect(rect, col, filled, -1.0 if filled else width)
		"diamond":
			var pts := PackedVector2Array([p + Vector2(0, -r * 1.2), p + Vector2(r * 1.2, 0), p + Vector2(0, r * 1.2), p + Vector2(-r * 1.2, 0)])
			if filled:
				draw_colored_polygon(pts, col)
			else:
				pts.append(pts[0])
				draw_polyline(pts, col, width, true)
		_:
			if filled:
				draw_circle(p, r, col, true, -1.0, true)
			else:
				draw_arc(p, r, 0.0, TAU, 48, col, width, true)


# --- input -----------------------------------------------------------------------------------

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := to_tree(mb.position)
			zoom = clampf(zoom * (1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), MIN_ZOOM, MAX_ZOOM)
			center += before - to_tree(mb.position)  # zoom about the mouse
			accept_event()
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if mb.pressed:
				_press_at = mb.position
				_dragged = false
			else:
				if mb.button_index == MOUSE_BUTTON_LEFT and not _dragged:
					var id := node_at(mb.position)
					if id != "":
						learn(id)
				_press_at = Vector2.INF
			accept_event()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _press_at != Vector2.INF and mm.button_mask != 0:
			if _dragged or mm.position.distance_to(_press_at) > 5.0:
				_dragged = true
				center -= mm.relative / zoom
		hover = node_at(mm.position)
		_update_tip()
		accept_event()
	elif e is InputEventKey and e.pressed and (e as InputEventKey).keycode == KEY_HOME:
		fit()
		accept_event()


func _update_tip() -> void:
	if hover == "" or not tree.has(hover):
		_tip.visible = false
		return
	var n := tree.node(hover)
	var r := progress.tree_rank(hover)
	var lines := PackedStringArray()
	lines.append("[b][color=#%s]%s[/color][/b]" % [(n.color as Color).lightened(0.25).to_html(false), _esc(n.name)])
	lines.append("[color=#9aa3b5]%s  ·  rank %d of %d  ·  %d point%s per rank[/color]" % [_esc(str(n.category).capitalize()), r, n.max_rank,
		n.cost, "" if int(n.cost) == 1 else "s"])
	lines.append("")
	lines.append(_esc(n.description))
	lines.append("")
	var why := tree.why_not(progress.tree_ranks, progress.skill_points(tree), hover)
	if why == "":
		lines.append("[color=#7fe07f]Click to learn %s.[/color]" % ("rank %d" % (r + 1) if r > 0 else "it"))
	else:
		lines.append("[color=%s]%s[/color]" % ["#ffd479" if r >= int(n.max_rank) else "#ff8a7a", _esc(why)])
	_tip_text.text = "\n".join(lines)
	_tip.visible = true
	_tip.reset_size()
	var p := to_screen(n.pos) + Vector2(R * zoom + 16.0, -40.0)
	if p.x + _tip.size.x > size.x - 10.0:
		p.x = to_screen(n.pos).x - R * zoom - 16.0 - _tip.size.x
	p.y = clampf(p.y, 10.0, maxf(10.0, size.y - _tip.size.y - 10.0))
	_tip.position = p


static func _esc(t: String) -> String:
	return t.replace("[", "[lb]")
