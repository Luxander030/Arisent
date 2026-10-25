## Small always-on-top readouts (frame time, world counts…) on the debug surface, in the
## console's look. Panels sit in a corner (stacked), can be dragged away (/monitor <name>
## pin puts them back), and toggle with their key or Shift+` (all). A panel is a
## Callable() -> String re-read four times a second; registering systems own theirs.
class_name MonitorPanels
extends Control

const T := preload("res://world/debug/console/console_theme.gd")
const CORNERS := ["top_left", "top_right", "bottom_left", "bottom_right"]
const REFRESH := 0.25

var _panels: Array[MonitorPanel] = []
var _t := 0.0


class MonitorPanel extends Control:
	var key_name := ""
	var title := ""
	var corner := "top_right"
	var fn: Callable
	var key: KeyCombo
	var owner_ref: WeakRef
	var moved := false
	var text := ""
	var _drag := false
	var _grab := Vector2.ZERO

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func refresh() -> void:
		var t := str(fn.call()) if fn.is_valid() else "(gone)"
		if t != text:
			text = t
			var lines := text.split("\n")
			var w := title.length() + 4
			for l in lines:
				w = maxi(w, l.length())
			var cw := T.char_width()
			var rh := T.row_height()
			size = Vector2(w * cw + 2.0 * T.PADDING + 2.0 * T.BORDER, T.TITLE_BAR + lines.size() * rh + T.PADDING * 2.0)
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(Rect2(T.SHADOW * 0.5, size), T.SHADOW_COLOR)
		draw_rect(r, Color(T.BACKGROUND, 0.9))
		draw_rect(Rect2(T.BORDER, T.BORDER, size.x - 2 * T.BORDER, T.TITLE_BAR - T.BORDER), T.TITLE_BG)
		draw_rect(r.grow(-T.BORDER / 2.0), T.BORDER_COLOR, false, T.BORDER)
		var f := T.font()
		var asc := f.get_ascent(T.FONT_SIZE)
		var rh := T.row_height()
		var x := T.BORDER + T.PADDING
		draw_string(f, Vector2(x, (T.TITLE_BAR - rh) / 2.0 + asc + 1), title + ("  (%s)" % str(key) if key else ""),
			HORIZONTAL_ALIGNMENT_LEFT, -1, T.FONT_SIZE, T.TITLE_TEXT)
		var y := T.TITLE_BAR + T.PADDING
		for l in text.split("\n"):
			draw_string(f, Vector2(x, y + asc), l, HORIZONTAL_ALIGNMENT_LEFT, -1, T.FONT_SIZE, Color.from_string(T.KIND_COLORS[T.Kind.INFO], Color.WHITE))
			y += rh

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_drag = e.pressed and (e as InputEventMouseButton).position.y < T.TITLE_BAR
			_grab = (e as InputEventMouseButton).position
			if e.pressed:
				move_to_front()
			accept_event()
		elif e is InputEventMouseMotion and _drag:
			position += (e as InputEventMouseMotion).position - _grab
			moved = true
			accept_event()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # sized by DebugConsole with the surface


## `key` toggles it (null for none). Re-adding a name replaces that panel.
func add(name: String, title: String, corner: String, fn: Callable, key: KeyCombo = null, owner: Object = null) -> void:
	assert(name != "all", "'all' is reserved")
	remove(name)
	var p := MonitorPanel.new()
	p.key_name = name
	p.title = title
	p.corner = corner if corner in CORNERS else "top_right"
	p.fn = fn
	p.key = key
	p.owner_ref = weakref(owner) if owner else null
	p.visible = false
	add_child(p)
	_panels.append(p)


func remove(name: String) -> bool:
	var p := find(name)
	if p == null:
		return false
	_panels.erase(p)
	p.queue_free()
	_stack()
	return true


func remove_owner(owner: Object) -> void:
	for p in _panels.duplicate():
		if p.owner_ref and (p.owner_ref.get_ref() == owner or p.owner_ref.get_ref() == null):
			remove(p.key_name)


func find(name: String) -> MonitorPanel:
	for p in _panels:
		if p.key_name.to_lower() == name.to_lower():
			return p
	return null


func panels() -> Array[MonitorPanel]:
	return _panels


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _panels:
		out.append(p.key_name)
	return out


func show_panel(name: String, on: bool) -> bool:
	var p := find(name)
	if p == null:
		return false
	p.visible = on
	if on:
		p.refresh()
	_stack()
	return true


func any_shown() -> bool:
	for p in _panels:
		if p.visible:
			return true
	return false


## Shows all if none are shown, otherwise hides all. Returns whether they are now shown.
func toggle_all() -> bool:
	var on := not any_shown()
	for p in _panels:
		p.visible = on
		if on:
			p.refresh()
	_stack()
	return on


func pin(name: String) -> void:
	for p in _panels:
		if name == "all" or p.key_name == name:
			p.moved = false
	_stack()


## A panel's own key (console closed). True if one toggled.
func handle_key(e: InputEventKey) -> bool:
	for p in _panels:
		if p.key and p.key.matches(e):
			show_panel(p.key_name, not p.visible)
			return true
	return false


func _process(dt: float) -> void:
	_t -= dt
	if _t > 0.0:
		return
	_t = REFRESH
	var any := false
	for p in _panels:
		if p.visible:
			p.refresh()
			any = true
	if any:
		_stack()


## Stacks panels that were not dragged in their corners.
func _stack() -> void:
	var offs := {}
	for c: String in CORNERS:
		offs[c] = T.INSET
	for p in _panels:
		if not p.visible or p.moved:
			continue
		var y: float = offs[p.corner]
		var right: bool = p.corner.ends_with("right")
		var bottom: bool = p.corner.begins_with("bottom")
		p.position = Vector2(size.x - p.size.x - T.INSET if right else T.INSET, size.y - p.size.y - y if bottom else y)
		offs[p.corner] = y + p.size.y + 8.0
