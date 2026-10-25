## Inspector widgets for entity props, built from the kind's schema (EntityKinds.KINDS).
## Each finished change calls commit(key, value, structural) once (one undo step);
## structural = the inspector should be rebuilt (e.g. a zone role was switched on).
## Props tagged with a zone role are only shown while that role is enabled.
class_name PropEditors
extends RefCounted

const ConditionEditor := preload("res://addons/story_graph/editor/condition_editor.gd")


static func build_all(box: VBoxContainer, e: Dictionary, view: WorldView, commit: Callable) -> void:
	var roles: Array = e.props.get("roles", [])
	var section := ""
	for row: Array in EntityKinds.KINDS.get(e.kind, {}).get("props", []):
		var opts := EntityKinds.row_opts(row)
		var role := str(opts.get("role", ""))
		if role != "" and not roles.has(role):
			continue
		if role != section:
			section = role
			var head := Label.new()
			head.text = role.capitalize().replace("_", " ") + " settings" if role != "" else ""
			head.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
			box.add_child(HSeparator.new())
			box.add_child(head)
		build(box, row, e.props.get(row[0], row[2]), view, commit)


static func build(box: VBoxContainer, row: Array, value: Variant, view: WorldView, commit: Callable) -> void:
	var key: String = row[0]
	var opts := EntityKinds.row_opts(row)
	var t: Variant = row[1]
	var title := key.capitalize()
	var hint := str(opts.get("hint", ""))
	if t is int:
		match int(t):
			TYPE_FLOAT, TYPE_INT:
				var is_int := int(t) == TYPE_INT
				var s := EditorTool.add_slider(box, title, float(row[3]), float(row[4]), float(value),
					func(_v: float) -> void: pass, 1.0 if is_int else _step(float(row[3]), float(row[4])))
				s.drag_ended.connect(func(_changed: bool) -> void: commit.call(key, int(s.value) if is_int else s.value, false))
				s.tooltip_text = hint
			TYPE_BOOL:
				var cb := CheckBox.new()
				cb.text = title
				cb.tooltip_text = hint
				cb.button_pressed = bool(value)
				cb.toggled.connect(func(on: bool) -> void: commit.call(key, on, false))
				box.add_child(cb)
			TYPE_COLOR:
				_label(box, title)
				var cp := ColorPickerButton.new()
				cp.color = Color.from_string(str(value), Color.WHITE)
				cp.custom_minimum_size.y = 26
				cp.popup_closed.connect(func() -> void: commit.call(key, "#" + cp.color.to_html(true), false))
				box.add_child(cp)
			_:
				_label(box, title)
				var le := LineEdit.new()
				le.text = str(value)
				le.tooltip_text = hint
				le.text_submitted.connect(func(x: String) -> void: commit.call(key, x, false))
				le.focus_exited.connect(func() -> void:
					if le.text != str(value):
						commit.call(key, le.text, false))
				box.add_child(le)
		return
	var ts := str(t)
	if ts == "enum":
		_label(box, title)
		var ob := OptionButton.new()
		var options: Array = row[3]
		for i in options.size():
			ob.add_item(str(options[i]).replace("_", " "))
			if str(options[i]) == str(value):
				ob.select(i)
		ob.tooltip_text = hint
		ob.item_selected.connect(func(i: int) -> void: commit.call(key, str(options[i]), true))
		box.add_child(ob)
	elif ts.begins_with("ref:"):
		var reg := ts.trim_prefix("ref:")
		_label(box, title)
		var ob := OptionButton.new()
		ob.add_item("(none)")
		ob.set_item_metadata(0, "")
		for id in Defs.ids(reg):
			ob.add_item(str(Defs.get_def(reg, id).get("name", id)) + "  [%s]" % id)
			ob.set_item_metadata(ob.item_count - 1, id)
			if id == str(value):
				ob.select(ob.item_count - 1)
		if str(value) != "" and not Defs.has(reg, str(value)):
			ob.add_item("%s (missing!)" % value)
			ob.set_item_metadata(ob.item_count - 1, str(value))
			ob.select(ob.item_count - 1)
		ob.item_selected.connect(func(i: int) -> void: commit.call(key, str(ob.get_item_metadata(i)), true))
		box.add_child(ob)
	elif ts.begins_with("entity_ref:"):
		var kind := ts.trim_prefix("entity_ref:")
		_label(box, title)
		var ob := OptionButton.new()
		ob.add_item("(none)")
		ob.set_item_metadata(0, "")
		for other in view.entities.entities_of_kind(kind):
			var nm := str(other.props.get("name", ""))
			ob.add_item((nm if nm != "" else EntityKinds.label(kind)) + "  [%s]" % str(other.id).right(6))
			ob.set_item_metadata(ob.item_count - 1, other.id)
			if other.id == str(value):
				ob.select(ob.item_count - 1)
		ob.tooltip_text = hint
		ob.item_selected.connect(func(i: int) -> void: commit.call(key, str(ob.get_item_metadata(i)), true))
		box.add_child(ob)
	elif ts == "roles":
		_label(box, "Roles")
		var flow := HFlowContainer.new()
		var current: Array = (value as Array).duplicate() if value is Array else []
		for r: String in row[3]:
			var cb := CheckBox.new()
			cb.text = r.replace("_", " ")
			cb.button_pressed = current.has(r)
			cb.toggled.connect(func(on: bool) -> void:
				var now: Array = current.duplicate()
				if on and not now.has(r):
					now.append(r)
				elif not on:
					now.erase(r)
				commit.call(key, now, true))
			flow.add_child(cb)
		box.add_child(flow)
	elif ts.begins_with("table:"):
		_table(box, key, ts.trim_prefix("table:"), value as Array if value is Array else [], view, commit)
	elif ts == "condition":
		_condition(box, key, value as Dictionary if value is Dictionary else {}, commit)


static func _table(box: VBoxContainer, key: String, schema: String, rows: Array, view: WorldView, commit: Callable) -> void:
	var cols: Array = EntityKinds.TABLES.get(schema, [])
	_label(box, key.capitalize())
	for ri in rows.size():
		var panel := PanelContainer.new()
		var v := VBoxContainer.new()
		panel.add_child(v)
		var row: Dictionary = rows[ri]
		for c: Array in cols:
			build(v, c, row.get(c[0], c[2]), view, func(col: String, val: Variant, _s: bool) -> void:
				var copy := rows.duplicate(true)
				copy[ri][col] = val
				commit.call(key, copy, true))
		var rm := Button.new()
		rm.text = "Remove row"
		rm.pressed.connect(func() -> void:
			var copy := rows.duplicate(true)
			copy.remove_at(ri)
			commit.call(key, copy, true))
		v.add_child(rm)
		box.add_child(panel)
	var add := Button.new()
	add.text = "+ Add row"
	add.pressed.connect(func() -> void:
		var copy := rows.duplicate(true)
		var fresh := {}
		for c: Array in cols:
			fresh[c[0]] = c[2]
		copy.append(fresh)
		commit.call(key, copy, true))
	box.add_child(add)


static func _condition(box: VBoxContainer, key: String, value: Dictionary, commit: Callable) -> void:
	var on := CheckBox.new()
	on.text = "Only when (story condition)"
	on.button_pressed = not value.is_empty()
	on.toggled.connect(func(enabled: bool) -> void:
		var d := {} if not enabled else StoryCondition.group(StoryCondition.Kind.ALL, [StoryCondition.make(StoryCondition.Kind.FLAG_SET)]).to_dict()
		commit.call(key, d, true))
	box.add_child(on)
	if value.is_empty():
		return
	var cond := StoryCondition.from_dict(value)
	var ed: Variant = ConditionEditor.new()
	var graph := GameSession.story_graph()
	var ids := PackedStringArray()
	if graph:
		for c in graph.cells:
			ids.append(c.id)
	ed.setup(cond, ids, false)
	ed.commit_requested.connect(func() -> void:
		if cond.to_dict() != value:
			commit.call(key, cond.to_dict(), false))
	box.add_child(ed)


static func _label(box: VBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.modulate = Color(1, 1, 1, 0.75)
	box.add_child(l)


static func _step(lo: float, hi: float) -> float:
	var span := hi - lo
	return 0.01 if span <= 1.0 else (0.1 if span <= 100.0 else 1.0)
