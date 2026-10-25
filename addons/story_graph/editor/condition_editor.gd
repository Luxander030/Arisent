@tool
extends VBoxContainer
## Edits one StoryCondition and, for groups, its children (recursively).
## `changed(structural)` fires on every edit; `commit_requested` when an edit is finished
## (one undo step). Structural = the tree shape changed (the owner may want to redraw).

signal changed(structural: bool)
signal commit_requested
signal remove_requested

const Ed := preload("edscale.gd")

var condition: StoryCondition
var event_ids: PackedStringArray = []
var removable := false


func setup(cond: StoryCondition, ids: PackedStringArray, can_remove := false) -> void:
	condition = cond
	event_ids = ids
	removable = can_remove
	_build()


func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	var kind := OptionButton.new()
	kind.fit_to_longest_item = false
	kind.custom_minimum_size.x = Ed.px(150)
	kind.tooltip_text = "AND / OR / NOT groups combine the conditions inside them."
	for i in StoryCondition.KIND_NAMES.size():
		kind.add_item(StoryCondition.KIND_NAMES[i], i)
	kind.select(condition.kind)
	kind.item_selected.connect(func(i: int) -> void:
		condition.kind = i as StoryCondition.Kind
		_build()
		changed.emit(true)
		commit_requested.emit())
	row.add_child(kind)

	match condition.kind:
		StoryCondition.Kind.COMPLETED, StoryCondition.Kind.NOT_COMPLETED:
			var pick := OptionButton.new()
			pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			pick.fit_to_longest_item = false
			pick.add_item("(pick an event)")
			pick.set_item_metadata(0, "")
			var ids := Array(event_ids)
			if condition.target != "" and not ids.has(condition.target):
				ids.append(condition.target)
			for id: String in ids:
				pick.add_item(id if event_ids.has(id) else "%s (missing!)" % id)
				pick.set_item_metadata(pick.item_count - 1, id)
				if id == condition.target:
					pick.select(pick.item_count - 1)
			pick.item_selected.connect(func(i: int) -> void:
				condition.target = str(pick.get_item_metadata(i))
				changed.emit(false)
				commit_requested.emit())
			row.add_child(pick)
		StoryCondition.Kind.FLAG_SET, StoryCondition.Kind.FLAG_NOT_SET:
			row.add_child(_line(condition.target, "flag name", func(t: String) -> void: condition.target = t.strip_edges()))
		StoryCondition.Kind.VARIABLE:
			row.add_child(_line(condition.target, "variable", func(t: String) -> void: condition.target = t.strip_edges()))
			var op := OptionButton.new()
			for o: String in StoryCondition.OPS:
				op.add_item(o)
			op.select(maxi(0, StoryCondition.OPS.find(condition.op)))
			op.item_selected.connect(func(i: int) -> void:
				condition.op = StoryCondition.OPS[i]
				changed.emit(false)
				commit_requested.emit())
			row.add_child(op)
			var v := _line(condition.value, "value", func(t: String) -> void: condition.value = t)
			v.custom_minimum_size.x = Ed.px(60)
			row.add_child(v)
		StoryCondition.Kind.EXPRESSION:
			var e := _line(condition.expression, "gold >= 10 and done(\"intro\")", func(t: String) -> void: condition.expression = t)
			e.tooltip_text = "A Godot Expression. Variables are available by name; use done(\"id\"), flag(\"name\") and times(\"id\")."
			row.add_child(e)
		_:
			var spacer := Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(spacer)
	if removable:
		var rm := Button.new()
		rm.text = "×"
		rm.tooltip_text = "Remove this condition"
		rm.flat = true
		rm.pressed.connect(func() -> void: remove_requested.emit())
		row.add_child(rm)
	add_child(row)

	if condition.is_group():
		var indent := MarginContainer.new()
		indent.add_theme_constant_override("margin_left", int(Ed.px(18)))
		var box := VBoxContainer.new()
		indent.add_child(box)
		if condition.children.is_empty():
			var hint := Label.new()
			hint.text = "(empty: always true)"
			hint.modulate = Color(1, 1, 1, 0.5)
			box.add_child(hint)
		for child in condition.children:
			if child == null:
				continue
			var ed: Variant = (get_script() as GDScript).new()
			box.add_child(ed)
			ed.setup(child, event_ids, true)
			ed.changed.connect(func(s: bool) -> void: changed.emit(s))
			ed.commit_requested.connect(func() -> void: commit_requested.emit())
			ed.remove_requested.connect(func() -> void:
				condition.children.erase(child)
				_build()
				changed.emit(true)
				commit_requested.emit())
		var add := MenuButton.new()
		add.text = "+ Add condition"
		add.flat = false
		var popup := add.get_popup()
		for i in StoryCondition.KIND_NAMES.size():
			popup.add_item(StoryCondition.KIND_NAMES[i], i)
		popup.id_pressed.connect(func(i: int) -> void:
			condition.children.append(StoryCondition.make(i as StoryCondition.Kind))
			_build()
			changed.emit(true)
			commit_requested.emit())
		box.add_child(add)
		add_child(indent)


func _line(text: String, placeholder: String, apply: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = text
	le.placeholder_text = placeholder
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size.x = Ed.px(70)
	le.text_changed.connect(func(t: String) -> void:
		apply.call(t)
		changed.emit(false))
	le.text_submitted.connect(func(_t: String) -> void: commit_requested.emit())
	le.focus_exited.connect(func() -> void: commit_requested.emit())
	return le
