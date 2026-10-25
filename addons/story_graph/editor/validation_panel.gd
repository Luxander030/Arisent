@tool
extends VBoxContainer
## Lists StoryValidator issues. Click one to jump to its cell.

signal cell_activated(cell_id: String)

const COLORS := [Color(1, 0.45, 0.45), Color(1, 0.8, 0.4), Color(0.6, 0.8, 1)]
const NAMES := ["Error", "Warning", "Info"]

var _summary: Label
var _list: ItemList
var _show_info: CheckBox
var _issues: Array = []


func _ready() -> void:
	var bar := HBoxContainer.new()
	_summary = Label.new()
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_summary)
	_show_info = CheckBox.new()
	_show_info.text = "Show info"
	_show_info.toggled.connect(func(_on: bool) -> void: _fill())
	bar.add_child(_show_info)
	add_child(bar)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_pick)
	_list.item_activated.connect(_on_pick)
	add_child(_list)
	_fill()


func set_issues(issues: Array) -> void:
	_issues = issues
	if is_node_ready():
		_fill()


func counts() -> Array[int]:
	var c: Array[int] = [0, 0, 0]
	for i: StoryValidator.Issue in _issues:
		c[i.severity] += 1
	return c


func _fill() -> void:
	_list.clear()
	var c := counts()
	_summary.text = "No problems found." if c[0] + c[1] == 0 else "%d error(s), %d warning(s)" % [c[0], c[1]]
	for issue: StoryValidator.Issue in _issues:
		if issue.severity == StoryValidator.Severity.INFO and not _show_info.button_pressed:
			continue
		var where := issue.cell_id if issue.cell_id != "" else "story"
		var idx := _list.add_item("%s  [%s]  %s" % [NAMES[issue.severity], where, issue.message])
		_list.set_item_custom_fg_color(idx, COLORS[issue.severity])
		_list.set_item_metadata(idx, issue.cell_id)
		_list.set_item_tooltip(idx, issue.message)


func _on_pick(idx: int) -> void:
	var id := str(_list.get_item_metadata(idx))
	if id != "":
		cell_activated.emit(id)
