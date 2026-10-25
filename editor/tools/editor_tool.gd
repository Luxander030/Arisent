## Base class for editor tools (sculpt, paint, place, ...). The editor forwards viewport
## input with the terrain point under the mouse; the tool builds its own settings UI.
class_name EditorTool
extends RefCounted

var editor: Node  ## EditorMain

## Brush settings shared by brush-based tools.
var size := 30.0
var strength := 40.0


func tool_name() -> String:
	return "Tool"


func tool_hint() -> String:
	return ""


func uses_brush() -> bool:
	return false


func activate() -> void:
	pass


func deactivate() -> void:
	pass


## Fill the inspector with this tool's settings.
func build_settings(_box: VBoxContainer) -> void:
	pass


## hit = terrain point under the mouse (Vector3.INF if none). Return true if consumed.
func on_input(_event: InputEvent, _hit: Vector3) -> bool:
	return false


func process(_delta: float, _hit: Vector3) -> void:
	pass


# --- helpers for settings UI ---

static func add_slider(box: VBoxContainer, label: String, min_v: float, max_v: float, value: float,
		on_change: Callable, step: float = 1.0) -> HSlider:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size.x = 92
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size.x = 120
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 42
	v.text = str(snappedf(value, step))
	row.add_child(v)
	s.value_changed.connect(func(x: float) -> void:
		v.text = str(snappedf(x, step))
		on_change.call(x))
	box.add_child(row)
	return s


static func add_label(box: VBoxContainer, text: String, dim := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if dim:
		l.modulate = Color(1, 1, 1, 0.6)
	box.add_child(l)
	return l


static func add_option_buttons(box: VBoxContainer, names: Array, selected: int, on_pick: Callable) -> Array[Button]:
	var flow := HFlowContainer.new()
	var group := ButtonGroup.new()
	var buttons: Array[Button] = []
	for i in names.size():
		var b := Button.new()
		b.text = names[i]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.pressed.connect(on_pick.bind(i))
		flow.add_child(b)
		buttons.append(b)
	box.add_child(flow)
	return buttons
