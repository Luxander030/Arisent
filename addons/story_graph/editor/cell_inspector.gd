@tool
extends VBoxContainer
## Side panel of the Story editor. Shows, depending on the selection:
##   one cell     -> all its properties, outputs, prerequisites, actions, problems
##   a group      -> its title, colour and members
##   many cells   -> bulk actions
##   nothing      -> story settings (title, description, variables, flags)
## Edits change the resource directly and tell the host (story_editor.gd), which redraws
## the graph and records undo steps.

const ConditionEditor := preload("condition_editor.gd")
const Ed := preload("edscale.gd")

var host   ## story_editor.gd (untyped: calls its editing API)
var cell: StoryCell
var frame: StoryFrame
var _multi: Array[StoryCell] = []


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func show_cell(c: StoryCell) -> void:
	cell = c
	frame = null
	_multi.clear()
	rebuild()


func show_frame(f: StoryFrame) -> void:
	cell = null
	frame = f
	_multi.clear()
	rebuild()


func show_multi(cells: Array[StoryCell]) -> void:
	cell = null
	frame = null
	_multi = cells
	rebuild()


func show_story() -> void:
	cell = null
	frame = null
	_multi.clear()
	rebuild()


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if host == null or host.get("graph") == null:
		_hint("Open or create a story to start.")
		return
	if cell:
		_build_cell()
	elif frame:
		_build_frame()
	elif not _multi.is_empty():
		_build_multi()
	else:
		_build_story()


# --- cell ------------------------------------------------------------------------------------

func _build_cell() -> void:
	var c := cell
	var color: Color = StoryCell.TYPE_COLORS[c.type]
	var bar := ColorRect.new()
	bar.color = color
	bar.custom_minimum_size.y = Ed.px(4)
	add_child(bar)
	_heading("%s cell" % StoryCell.TYPE_NAMES[c.type])
	_hint(StoryCell.TYPE_HINTS[c.type])

	_label("Type")
	var type := OptionButton.new()
	for i in StoryCell.TYPE_NAMES.size():
		type.add_item(StoryCell.TYPE_NAMES[i], i)
	type.select(c.type)
	type.item_selected.connect(func(i: int) -> void: _change_type(i as StoryCell.Type))
	add_child(type)

	_label("Name")
	var set_title := func(t: String) -> void: c.title = t
	_line(c.title, "Shown on the graph", set_title, false)

	_label("ID (unique; used by connections, prerequisites and the game)")
	var id_edit := LineEdit.new()
	id_edit.text = c.id
	var id_err := Label.new()
	id_err.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
	id_err.visible = false
	var apply_id := func() -> void:
		var new_id := id_edit.text.strip_edges()
		if new_id == c.id:
			id_err.visible = false
			return
		if not host.rename_cell(c.id, new_id):
			id_err.text = "That ID is empty or already used."
			id_err.visible = true
			id_edit.text = c.id
		else:
			id_err.visible = false
	id_edit.text_submitted.connect(func(_t: String) -> void: apply_id.call())
	id_edit.focus_exited.connect(apply_id)
	add_child(id_edit)
	add_child(id_err)

	if c.type == StoryCell.Type.DIALOGUE or c.type == StoryCell.Type.CHOICE:
		_label("Speaker")
		var set_speaker := func(t: String) -> void: c.speaker = t
		_line(c.speaker, "Who says it (optional)", set_speaker, false)
	if c.type != StoryCell.Type.CONDITION:
		var text_label := "Dialogue / script"
		match c.type:
			StoryCell.Type.CHOICE: text_label = "Prompt (shown with the options)"
			StoryCell.Type.END: text_label = "Ending text"
			StoryCell.Type.START, StoryCell.Type.ACTION: text_label = "Description"
		_label(text_label + "   ({variable} is replaced when played)")
		_text(c.text, 110, func(t: String) -> void: c.text = t)
	_label("Designer notes (never shown to players)")
	_text(c.notes, 60, func(t: String) -> void: c.notes = t)

	var rep := CheckBox.new()
	rep.text = "Can happen more than once"
	rep.button_pressed = c.repeatable
	rep.tooltip_text = "Off: once this cell has happened it can't be entered again (its connections are skipped)."
	rep.toggled.connect(func(on: bool) -> void:
		c.repeatable = on
		host.cell_changed(c, false)
		host.commit("Toggle repeatable"))
	add_child(rep)
	_label("Tags (comma separated)")
	var set_tags := func(t: String) -> void:
		var parts: PackedStringArray = []
		for p in t.split(","):
			if p.strip_edges() != "":
				parts.append(p.strip_edges())
		c.tags = parts
	_line(", ".join(c.tags), "e.g. chapter1, tavern", set_tags, false)

	if c.allows_outputs():
		_build_outputs(c)
	_build_prerequisites(c)
	_build_actions(c)
	_build_cell_issues(c)

	add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.add_child(_button("Play from here", func() -> void: host.simulate_from(c.id)))
	row.add_child(_button("Duplicate", func() -> void: host.duplicate_selection()))
	var del := _button("Delete", func() -> void: host.delete_cells([c.id]))
	row.add_child(del)
	add_child(row)


func _build_outputs(c: StoryCell) -> void:
	var titles := {StoryCell.Type.CHOICE: "Options", StoryCell.Type.CONDITION: "Branches (the first that passes is taken)"}
	_section(titles.get(c.type, "Outputs (the first open one is taken)"))
	if c.outputs.is_empty():
		_hint("No outputs. Add one, then connect it on the graph or pick a target below.")
	for i in c.outputs.size():
		var o := c.outputs[i]
		var box := VBoxContainer.new()
		var panel := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.04)
		sb.set_content_margin_all(6)
		sb.set_corner_radius_all(4)
		panel.add_theme_stylebox_override("panel", sb)
		panel.add_child(box)
		add_child(panel)

		var row := HBoxContainer.new()
		var placeholder := "Option text" if c.type == StoryCell.Type.CHOICE else "Label (optional)"
		var le := LineEdit.new()
		le.text = o.label
		le.placeholder_text = placeholder
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_changed.connect(func(t: String) -> void:
			o.label = t
			host.cell_changed(c, false))
		le.text_submitted.connect(func(_t: String) -> void: host.commit("Edit output"))
		le.focus_exited.connect(func() -> void: host.commit("Edit output"))
		row.add_child(le)
		row.add_child(_small_button("↑", "Move up", func() -> void: _move_output(c, i, -1), i == 0))
		row.add_child(_small_button("↓", "Move down", func() -> void: _move_output(c, i, 1), i == c.outputs.size() - 1))
		row.add_child(_small_button("×", "Remove", func() -> void:
			c.outputs.remove_at(i)
			_structural(c, "Remove output")))
		box.add_child(row)

		var row2 := HBoxContainer.new()
		var lab := Label.new()
		lab.text = "Goes to"
		row2.add_child(lab)
		var pick := OptionButton.new()
		pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pick.fit_to_longest_item = false
		pick.add_item("(not connected)")
		pick.set_item_metadata(0, "")
		for other in host.graph.cells:
			if other.type == StoryCell.Type.START:
				continue
			pick.add_item("%s  [%s]" % [other.display_name(), other.id])
			pick.set_item_metadata(pick.item_count - 1, other.id)
			if other.id == o.target_id:
				pick.select(pick.item_count - 1)
		if o.target_id != "" and not host.graph.has_cell(o.target_id):
			pick.add_item("%s (missing!)" % o.target_id)
			pick.set_item_metadata(pick.item_count - 1, o.target_id)
			pick.select(pick.item_count - 1)
		pick.item_selected.connect(func(idx: int) -> void:
			o.target_id = str(pick.get_item_metadata(idx))
			_structural(c, "Change connection"))
		row2.add_child(pick)
		if o.target_id != "" and host.graph.has_cell(o.target_id):
			row2.add_child(_small_button("→", "Select the target cell", func() -> void: host.focus_cell(o.target_id)))
		box.add_child(row2)

		var cond_toggle := CheckBox.new()
		cond_toggle.text = "Only if…" if c.type != StoryCell.Type.CONDITION else "Condition (off = Else)"
		cond_toggle.button_pressed = o.condition != null
		cond_toggle.toggled.connect(func(on: bool) -> void:
			if on:
				o.condition = StoryCondition.group(StoryCondition.Kind.ALL, [StoryCondition.make(StoryCondition.Kind.FLAG_SET)])
			else:
				o.condition = null
			_structural(c, "Toggle condition"))
		box.add_child(cond_toggle)
		if o.condition:
			box.add_child(_condition_editor(o.condition, c))
	var add_label := {StoryCell.Type.CHOICE: "+ Add option", StoryCell.Type.CONDITION: "+ Add branch"}
	add_child(_button(add_label.get(c.type, "+ Add output"), func() -> void: host.add_output(c.id)))


func _build_prerequisites(c: StoryCell) -> void:
	_section("Prerequisites")
	_hint("This cell can only happen when these pass. Use groups for AND / OR, and 'not completed' / 'flag is not set' for things that must not have happened.")
	var on := CheckBox.new()
	on.text = "Has prerequisites"
	on.button_pressed = c.prerequisites != null
	on.toggled.connect(func(enabled: bool) -> void:
		c.prerequisites = StoryCondition.group(StoryCondition.Kind.ALL, [StoryCondition.make(StoryCondition.Kind.COMPLETED)]) if enabled else null
		_structural(c, "Toggle prerequisites"))
	add_child(on)
	if c.prerequisites:
		add_child(_condition_editor(c.prerequisites, c))


func _build_actions(c: StoryCell) -> void:
	_section("Actions when entered")
	if c.actions.is_empty():
		_hint("None. Actions set flags and variables, mark events, or tell the game something happened.")
	for i in c.actions.size():
		var a := c.actions[i]
		var row := HBoxContainer.new()
		var kind := OptionButton.new()
		kind.fit_to_longest_item = false
		kind.custom_minimum_size.x = Ed.px(120)
		for k in StoryAction.KIND_NAMES.size():
			kind.add_item(StoryAction.KIND_NAMES[k], k)
		kind.select(a.kind)
		kind.item_selected.connect(func(k: int) -> void:
			a.kind = k as StoryAction.Kind
			_structural(c, "Change action"))
		row.add_child(kind)
		var placeholder := "event id" if (a.kind == StoryAction.Kind.MARK_COMPLETED or a.kind == StoryAction.Kind.RESET_EVENT) \
			else "game event" if a.kind == StoryAction.Kind.EMIT_EVENT else "name"
		var set_target := func(t: String) -> void: a.target = t.strip_edges()
		row.add_child(_inline_line(a.target, placeholder, set_target, c))
		if a.uses_value():
			var set_value := func(t: String) -> void: a.value = t
			var v := _inline_line(a.value, "value" if a.kind != StoryAction.Kind.EMIT_EVENT else "payload", set_value, c)
			v.custom_minimum_size.x = Ed.px(55)
			row.add_child(v)
		row.add_child(_small_button("×", "Remove action", func() -> void:
			c.actions.remove_at(i)
			_structural(c, "Remove action")))
		add_child(row)
	add_child(_button("+ Add action", func() -> void:
		c.actions.append(StoryAction.make(StoryAction.Kind.SET_FLAG, ""))
		_structural(c, "Add action")))


func _build_cell_issues(c: StoryCell) -> void:
	var list: Array = host.issues_for(c.id)
	if list.is_empty():
		return
	_section("Problems")
	for issue: StoryValidator.Issue in list:
		var l := Label.new()
		l.text = "• " + issue.message
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_color_override("font_color", [Color(1, 0.45, 0.45), Color(1, 0.8, 0.4), Color(0.6, 0.8, 1)][issue.severity])
		add_child(l)


func _change_type(t: StoryCell.Type) -> void:
	var c := cell
	if t == c.type:
		return
	c.type = t
	if t == StoryCell.Type.END:
		c.outputs.clear()
	elif c.outputs.is_empty():
		var fresh := StoryCell.create(t, c.id)
		c.outputs = fresh.outputs
	if t == StoryCell.Type.START:
		c.repeatable = false
	if c.title == "" or StoryCell.TYPE_NAMES.has(c.title):
		c.title = StoryCell.TYPE_NAMES[t]
	_structural(c, "Change cell type")


func _move_output(c: StoryCell, i: int, d: int) -> void:
	var j := i + d
	if j < 0 or j >= c.outputs.size():
		return
	var tmp := c.outputs[i]
	c.outputs[i] = c.outputs[j]
	c.outputs[j] = tmp
	_structural(c, "Reorder outputs")


func _structural(c: StoryCell, action: String) -> void:
	host.cell_changed(c, true)
	host.commit(action)
	rebuild.call_deferred()


func _condition_editor(cond: StoryCondition, c: StoryCell) -> Control:
	var ed: Variant = ConditionEditor.new()
	ed.setup(cond, host.cell_ids(), false)
	ed.changed.connect(func(_structural_change: bool) -> void: host.cell_changed(c, false))
	ed.commit_requested.connect(func() -> void: host.commit("Edit condition"))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(Ed.px(6)))
	margin.add_child(ed)
	return margin


# --- group / multi / story ----------------------------------------------------------------------

func _build_frame() -> void:
	var f := frame
	_heading("Group")
	_hint("Groups organise the graph. Drag cells onto a group to add them; the group moves with its cells.")
	_label("Title")
	var set_frame_title := func(t: String) -> void:
		f.title = t
		host.frame_changed(f)
	_line(f.title, "Group title", set_frame_title, true)
	_label("Colour")
	var picker := ColorPickerButton.new()
	picker.color = f.color
	picker.custom_minimum_size.y = Ed.px(28)
	picker.color_changed.connect(func(col: Color) -> void:
		f.color = col
		host.frame_changed(f))
	picker.popup_closed.connect(func() -> void: host.commit("Change group colour"))
	add_child(picker)
	_section("Cells (%d)" % f.cell_ids.size())
	for id in f.cell_ids:
		var b := _button(id, func() -> void: host.focus_cell(id))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.flat = true
		add_child(b)
	add_child(HSeparator.new())
	add_child(_button("Delete group (keeps the cells)", func() -> void: host.delete_frame(f.id)))


func _build_multi() -> void:
	_heading("%d cells selected" % _multi.size())
	_hint("Drag any of them to move them all. Ctrl+D duplicates, Delete removes.")
	add_child(_button("Group them", func() -> void: host.group_selection()))
	add_child(_button("Remove them from their groups", func() -> void: host.ungroup_selection()))
	add_child(_button("Duplicate", func() -> void: host.duplicate_selection()))
	add_child(_button("Delete", func() -> void: host.delete_cells(_multi.map(func(x: StoryCell) -> String: return x.id))))


func _build_story() -> void:
	var g: StoryGraph = host.graph
	_heading("Story settings")
	_hint("Click a cell to edit it. Double-click empty space or right-click to add cells; drag from a port to connect.")
	_label("Title")
	var set_story_title := func(t: String) -> void: g.title = t
	_line(g.title, "Story title", set_story_title, true)
	_label("Description")
	_text(g.description, 60, func(t: String) -> void: g.description = t)

	_section("Variables (name = starting value)")
	_hint("Numbers, true/false or text. Use them in conditions, actions and as {name} in text.")
	var names: Array = g.variables.keys()
	for k: Variant in names:
		var key := str(k)
		var row := HBoxContainer.new()
		var name_edit := LineEdit.new()
		name_edit.text = key
		name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var rename := func() -> void:
			var nk := name_edit.text.strip_edges()
			if nk == key or nk == "" or g.variables.has(nk):
				name_edit.text = key
				return
			var copy := {}
			for kk: Variant in g.variables:
				copy[nk if str(kk) == key else kk] = g.variables[kk]
			g.variables = copy
			host.commit("Rename variable")
			rebuild.call_deferred()
		name_edit.text_submitted.connect(func(_t: String) -> void: rename.call())
		name_edit.focus_exited.connect(rename)
		row.add_child(name_edit)
		var val := LineEdit.new()
		val.text = var_to_str(g.variables[k]) if not (g.variables[k] is String) else str(g.variables[k])
		val.custom_minimum_size.x = Ed.px(80)
		val.text_changed.connect(func(t: String) -> void: g.variables[key] = StoryCondition.parse_value(t))
		val.text_submitted.connect(func(_t: String) -> void: host.commit("Edit variable"))
		val.focus_exited.connect(func() -> void: host.commit("Edit variable"))
		row.add_child(val)
		row.add_child(_small_button("×", "Remove variable", func() -> void:
			g.variables.erase(k)
			host.commit("Remove variable")
			host.revalidate()
			rebuild.call_deferred()))
		add_child(row)
	add_child(_button("+ Add variable", func() -> void:
		var i := 1
		while g.variables.has("var_%d" % i):
			i += 1
		g.variables["var_%d" % i] = 0
		host.commit("Add variable")
		rebuild.call_deferred()))

	_section("Flags (start unset)")
	for i in g.flags.size():
		var row := HBoxContainer.new()
		var idx := i
		var set_flag := func(t: String) -> void:
			var fl := g.flags
			fl[idx] = t.strip_edges()
			g.flags = fl
		row.add_child(_inline_line(g.flags[i], "flag name", set_flag, null))
		row.add_child(_small_button("×", "Remove flag", func() -> void:
			var fl := g.flags
			fl.remove_at(idx)
			g.flags = fl
			host.commit("Remove flag")
			host.revalidate()
			rebuild.call_deferred()))
		add_child(row)
	add_child(_button("+ Add flag", func() -> void:
		var fl := g.flags
		fl.append("flag_%d" % (fl.size() + 1))
		g.flags = fl
		host.commit("Add flag")
		rebuild.call_deferred()))

	_section("Overview")
	var counts := {}
	for c in g.cells:
		counts[c.type] = int(counts.get(c.type, 0)) + 1
	var parts: PackedStringArray = []
	for t in StoryCell.TYPE_NAMES.size():
		if counts.has(t):
			parts.append("%d %s" % [counts[t], StoryCell.TYPE_NAMES[t]])
	_hint("%d cells: %s. %d groups." % [g.cells.size(), ", ".join(parts) if not parts.is_empty() else "none", g.frames.size()])


# --- widgets ------------------------------------------------------------------------------------

func _heading(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", Ed.font(17))
	add_child(l)


func _section(text: String) -> void:
	add_child(HSeparator.new())
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.75, 0.82, 1.0))
	add_child(l)


func _label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.modulate = Color(1, 1, 1, 0.7)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(l)


func _hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.modulate = Color(1, 1, 1, 0.55)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = Ed.px(200)
	add_child(l)


## A LineEdit for the current cell (or the story when `story_level`): live redraw, undo step when done.
func _line(text: String, placeholder: String, apply: Callable, story_level: bool) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.placeholder_text = placeholder
	le.text_changed.connect(func(t: String) -> void:
		apply.call(t)
		if cell and not story_level:
			host.cell_changed(cell, false))
	le.text_submitted.connect(func(_t: String) -> void: host.commit("Edit"))
	le.focus_exited.connect(func() -> void: host.commit("Edit"))
	add_child(le)
	return le


func _inline_line(text: String, placeholder: String, apply: Callable, c: StoryCell) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.placeholder_text = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size.x = Ed.px(60)
	le.text_changed.connect(func(t: String) -> void:
		apply.call(t)
		if c:
			host.cell_changed(c, false))
	le.text_submitted.connect(func(_t: String) -> void:
		host.commit("Edit")
		host.revalidate())
	le.focus_exited.connect(func() -> void:
		host.commit("Edit")
		host.revalidate())
	return le


func _text(text: String, height: float, apply: Callable) -> TextEdit:
	var te := TextEdit.new()
	te.text = text
	te.custom_minimum_size.y = Ed.px(height)
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.text_changed.connect(func() -> void:
		apply.call(te.text)
		if cell:
			host.cell_changed(cell, false))
	te.focus_exited.connect(func() -> void: host.commit("Edit text"))
	add_child(te)
	return te


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	return b


func _small_button(text: String, tip: String, on_press: Callable, disabled := false) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.flat = true
	b.disabled = disabled
	b.custom_minimum_size.x = Ed.px(24)
	b.pressed.connect(on_press)
	return b
