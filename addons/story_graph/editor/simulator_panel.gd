@tool
extends HSplitContainer
## Plays the story inside the editor with a StoryRunner: transcript, choice buttons
## (closed options shown greyed out), Continue, Step back, triggerable events, and a live
## view of completed events, flags and variables (variables and flags can be edited to
## test other paths). The graph highlights visited cells and the current one.

signal marks_changed(visited: Dictionary, current_id: String)
signal focus_requested(cell_id: String)

const Ed := preload("edscale.gd")

var graph: StoryGraph
var runner: StoryRunner

var _entry: OptionButton
var _follow: CheckBox
var _back: Button
var _log: RichTextLabel
var _choices: VBoxContainer
var _continue: Button
var _status: Label
var _tree: Tree
var _events: ItemList
var _trigger: Button
var _lines: Array[String] = []
var _history: Array[Dictionary] = []


func _ready() -> void:
	split_offset = int(Ed.px(560))
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "Start from"
	bar.add_child(lab)
	_entry = OptionButton.new()
	_entry.custom_minimum_size.x = Ed.px(160)
	_entry.fit_to_longest_item = false
	bar.add_child(_entry)
	bar.add_child(_btn("Play", func() -> void: play(str(_entry.get_item_metadata(_entry.selected)) if _entry.item_count > 0 else "")))
	_back = _btn("Step back", step_back)
	bar.add_child(_back)
	bar.add_child(_btn("Stop", stop))
	_follow = CheckBox.new()
	_follow.text = "Follow on graph"
	_follow.button_pressed = true
	bar.add_child(_follow)
	left.add_child(bar)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.custom_minimum_size.y = Ed.px(80)
	left.add_child(_log)
	var actions := HBoxContainer.new()
	_choices = VBoxContainer.new()
	_choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_choices)
	_continue = _btn("Continue ▸", advance)
	_continue.size_flags_horizontal = Control.SIZE_SHRINK_END
	actions.add_child(_continue)
	left.add_child(actions)
	_status = Label.new()
	_status.modulate = Color(1, 1, 1, 0.6)
	left.add_child(_status)
	add_child(left)

	var right := VBoxContainer.new()
	right.custom_minimum_size.x = Ed.px(300)
	_tree = Tree.new()
	_tree.columns = 2
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "State")
	_tree.set_column_title(1, "Value (editable)")
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 2)
	_tree.set_column_clip_content(0, true)
	_tree.item_edited.connect(_on_state_edited)
	right.add_child(_tree)
	var ev_label := Label.new()
	ev_label.text = "Triggerable events available now"
	right.add_child(ev_label)
	_events = ItemList.new()
	_events.custom_minimum_size.y = Ed.px(60)
	_events.item_activated.connect(func(_i: int) -> void: _trigger_selected())
	right.add_child(_events)
	_trigger = _btn("Trigger selected event", _trigger_selected)
	right.add_child(_trigger)
	add_child(right)
	set_graph(graph)


func set_graph(g: StoryGraph) -> void:
	graph = g
	runner = null
	_history.clear()
	_lines.clear()
	if not is_node_ready():
		return
	refresh_entries()
	_render()
	marks_changed.emit({}, "")


## Fills the "Start from" list with the Start cells (call when the graph changed).
func refresh_entries() -> void:
	if _entry == null:
		return
	var keep := str(_entry.get_item_metadata(_entry.selected)) if _entry.item_count > 0 and _entry.selected >= 0 else ""
	_entry.clear()
	if graph == null:
		return
	for c in graph.get_start_cells():
		_entry.add_item("%s  [%s]" % [c.display_name(), c.id])
		_entry.set_item_metadata(_entry.item_count - 1, c.id)
		if c.id == keep:
			_entry.select(_entry.item_count - 1)


func play(entry_id := "") -> void:
	if graph == null:
		return
	runner = StoryRunner.new(graph)
	runner.dialogue.connect(_on_dialogue)
	runner.game_event.connect(func(n: String, payload: String) -> void:
		_add("[color=#7fd8d0]» game event: [b]%s[/b](%s)[/color]" % [n, payload]))
	runner.cell_entered.connect(_on_entered)
	runner.story_ended.connect(_on_ended)
	_history.clear()
	_lines.clear()
	var entry := graph.get_cell(entry_id)
	_add("[color=#9aa]— Playing from [b]%s[/b] —[/color]" % (entry.display_name() if entry else "the first Start cell"))
	if not runner.start(entry_id):
		if entry and entry.has_prerequisites():
			_add("[color=#e88](Its prerequisites aren't met: %s)[/color]" % entry.prerequisites.describe())
	_render()


func stop() -> void:
	runner = null
	_history.clear()
	_lines.clear()
	_render()
	marks_changed.emit({}, "")


func advance() -> void:
	if runner == null or runner.status != StoryRunner.Status.WAITING_CONTINUE:
		return
	_push_history()
	runner.advance()
	_render()


func choose(index: int) -> void:
	if runner == null or runner.status != StoryRunner.Status.WAITING_CHOICE:
		return
	var o := runner.current.outputs[index]
	_push_history()
	_add("[color=#f0c060]  ▸ %s[/color]" % runner.interpolate(o.label if o.label != "" else "Option %d" % (index + 1)))
	runner.choose(index)
	_render()


func step_back() -> void:
	if runner == null or _history.is_empty():
		return
	var h: Dictionary = _history.pop_back()
	runner.state = (h.state as StoryState).copy()
	runner.current = graph.get_cell(str(h.current))
	runner.status = int(h.status) as StoryRunner.Status
	runner.end_reason = str(h.reason)
	runner.path = (h.path as Array[String]).duplicate()
	_lines.resize(int(h.lines))
	_render()


func _trigger_selected() -> void:
	if runner == null:
		runner = StoryRunner.new(graph)
		runner.state.reset(graph)
		runner.dialogue.connect(_on_dialogue)
		runner.cell_entered.connect(_on_entered)
		runner.story_ended.connect(_on_ended)
	var sel := _events.get_selected_items()
	if sel.is_empty():
		return
	var id := str(_events.get_item_metadata(sel[0]))
	_push_history()
	_add("[color=#9aa]— Event triggered: [b]%s[/b] —[/color]" % id)
	runner.trigger(id)
	_render()


func _push_history() -> void:
	_history.append({"state": runner.state.copy(), "current": runner.current.id if runner.current else "",
		"status": runner.status, "reason": runner.end_reason, "path": runner.path.duplicate(), "lines": _lines.size()})


func _on_entered(cell: StoryCell) -> void:
	for a in cell.actions:
		if a.kind != StoryAction.Kind.EMIT_EVENT:
			_add("[color=#888]  » %s[/color]" % a.describe())


func _on_dialogue(cell: StoryCell, speaker: String, text: String) -> void:
	if speaker != "":
		_add("[b][color=#8cb4ff]%s:[/color][/b] %s" % [_esc(speaker), _esc(text)])
	elif text != "":
		_add(_esc(text) if cell.type != StoryCell.Type.CHOICE else "[i]%s[/i]" % _esc(text))


func _on_ended(cell: StoryCell, reason: String) -> void:
	match reason:
		"ending":
			if cell and cell.text != "":
				_add("[i]%s[/i]" % _esc(runner.interpolate(cell.text)))
			_add("[color=#e07070][b]— THE END: %s —[/b][/color]" % (cell.display_name() if cell else ""))
		"dead end":
			_add("[color=#e0a040]— Stopped: \"%s\" has no open output (dead end) —[/color]" % (cell.display_name() if cell else ""))
		"no choices":
			_add("[color=#e0a040]— Stopped: none of the options at \"%s\" are available —[/color]" % cell.display_name())
		"loop":
			_add("[color=#e04040]— Stopped: more than %d steps without player input (endless loop?) —[/color]" % StoryRunner.MAX_AUTO_STEPS)
		"blocked":
			_add("[color=#e0a040]— Can't start here: the cell is missing or its prerequisites aren't met —[/color]")


func _add(line: String) -> void:
	_lines.append(line)


static func _esc(t: String) -> String:
	return t.replace("[", "[lb]")


func _render() -> void:
	if _log == null:
		return
	_log.text = "\n".join(_lines) if not _lines.is_empty() else "[color=#888]Press Play to run the story from a Start cell, or use \"Play from here\" on any cell.[/color]"
	for c in _choices.get_children():
		c.queue_free()
	var waiting_continue := runner != null and runner.status == StoryRunner.Status.WAITING_CONTINUE
	_continue.visible = waiting_continue
	_back.disabled = _history.is_empty()
	if runner and runner.status == StoryRunner.Status.WAITING_CHOICE:
		for ch: Dictionary in runner.get_choices():
			var b := Button.new()
			b.text = str(ch.label)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.disabled = not ch.open
			if not ch.open:
				b.tooltip_text = "Not available: its condition or the target's prerequisites don't pass."
			var idx: int = ch.index
			b.pressed.connect(func() -> void: choose(idx))
			_choices.add_child(b)
	var status_text := "Not running."
	if runner:
		status_text = ["Idle", "Waiting for Continue", "Waiting for a choice", "Finished (%s)" % runner.end_reason][runner.status]
		status_text += "   ·   at: %s   ·   steps: %d" % [runner.current.id if runner.current else "-", runner.path.size()]
	_status.text = status_text
	_fill_state()
	var visited := {}
	if runner:
		for id in runner.path:
			visited[id] = true
	var cur := runner.current.id if runner and runner.current else ""
	marks_changed.emit(visited, cur)
	if cur != "" and _follow.button_pressed:
		focus_requested.emit(cur)


func _fill_state() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var state: StoryState = runner.state if runner else null
	var comp := _tree.create_item(root)
	comp.set_text(0, "Completed events")
	if state:
		var ids: Array = state.completed.keys()
		ids.sort()
		for id: Variant in ids:
			var it := _tree.create_item(comp)
			it.set_text(0, str(id))
			it.set_text(1, "× %d" % int(state.completed[id]))
	var flags_item := _tree.create_item(root)
	flags_item.set_text(0, "Flags")
	var flag_names := {}
	if graph:
		for f in graph.flags:
			flag_names[f] = true
	if state:
		for f: Variant in state.flags:
			flag_names[str(f)] = true
	for f: String in flag_names:
		var it := _tree.create_item(flags_item)
		it.set_text(0, f)
		it.set_cell_mode(1, TreeItem.CELL_MODE_CHECK)
		it.set_checked(1, state != null and state.has_flag(f))
		it.set_editable(1, state != null)
		it.set_metadata(0, "flag")
	var vars_item := _tree.create_item(root)
	vars_item.set_text(0, "Variables")
	var values: Dictionary = state.variables if state else (graph.variables if graph else {})
	for k: Variant in values:
		var it := _tree.create_item(vars_item)
		it.set_text(0, str(k))
		it.set_text(1, str(values[k]))
		it.set_editable(1, state != null)
		it.set_metadata(0, "var")
	_events.clear()
	var probe: StoryRunner = runner if runner else (StoryRunner.new(graph) if graph else null)
	if probe and not runner:
		probe.state.reset(graph)
	if probe:
		for c in probe.get_available_events():
			_events.add_item("%s  [%s]" % [c.display_name(), c.id])
			_events.set_item_metadata(_events.item_count - 1, c.id)
	_trigger.disabled = _events.item_count == 0


func _on_state_edited() -> void:
	if runner == null:
		return
	var it := _tree.get_edited()
	match str(it.get_metadata(0)):
		"flag":
			runner.state.set_flag(it.get_text(0), it.is_checked(1))
		"var":
			runner.state.set_var(it.get_text(0), StoryCondition.parse_value(it.get_text(1)))
	_render.call_deferred()


func _btn(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	return b
