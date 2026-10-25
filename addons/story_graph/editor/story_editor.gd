@tool
extends VBoxContainer
## The Story editor (the "Story" main-screen tab). Shows a StoryGraph as a GraphEdit,
## a side inspector for the selection, and a bottom area with Problems and the Simulator.
##
## Every edit changes the StoryGraph resource directly and then calls commit(), which
## records an undo step (Godot's editor undo history when running inside the editor) as a
## before/after snapshot of the graph, re-runs validation and marks the story unsaved.

signal story_saved(path: String)

const CellNode := preload("cell_node.gd")
const CellInspector := preload("cell_inspector.gd")
const ValidationPanel := preload("validation_panel.gd")
const SimulatorPanel := preload("simulator_panel.gd")
const Ed := preload("edscale.gd")

const MENU_NEW := 0
const MENU_OPEN := 1
const MENU_SAVE := 2
const MENU_SAVE_AS := 3
const MENU_IMPORT_JSON := 5
const MENU_EXPORT_JSON := 6
const MENU_VIEW_ALL := 8
const POPUP_DUPLICATE := 100
const POPUP_DELETE := 101
const POPUP_GROUP := 102
const POPUP_UNGROUP := 103
const POPUP_PLAY := 104

var graph: StoryGraph
var editor_undo: Object        ## EditorUndoRedoManager, set by the plugin
var in_editor := false         ## true inside the Godot editor (use EditorFileDialog)
var dirty := false
var issues: Array = []

var graph_edit: GraphEdit
var inspector: CellInspector
var validation: ValidationPanel
var simulator: SimulatorPanel

var _undo := UndoRedo.new()
var _last := {}                ## snapshot after the last commit
var _nodes := {}               ## cell id -> CellNode
var _frames := {}              ## frame id -> GraphFrame
var _building := false
var _clipboard: Array[Dictionary] = []
var _paste_count := 0
var _pending := {}             ## connection waiting for a new cell from the add menu
var _popup_pos := Vector2.ZERO ## graph coordinates where the add menu was opened
var _search_hits: Array[String] = []
var _search_index := -1
var _sim_visited := {}
var _sim_current := ""
var _inspector_queued := false
var _name_serial := 0          ## graph element names are never reused (GraphEdit tracks frames by name)

var _body: Control
var _empty: Control
var _bottom: TabContainer
var _file_label: Label
var _problems_btn: Button
var _search: LineEdit
var _add_popup: PopupMenu
var _move_timer: Timer


func _ready() -> void:
	if graph_edit:
		return
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_toolbar()

	_body = VSplitContainer.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top := HSplitContainer.new()
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_edit = GraphEdit.new()
	graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_edit.right_disconnects = true
	graph_edit.snapping_enabled = true
	graph_edit.snapping_distance = 20
	graph_edit.minimap_enabled = true
	graph_edit.show_arrange_button = true
	graph_edit.zoom_min = 0.2
	graph_edit.connection_lines_thickness = 3.0
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.connection_to_empty.connect(_on_connection_to_empty)
	graph_edit.connection_from_empty.connect(_on_connection_from_empty)
	graph_edit.delete_nodes_request.connect(_on_delete_request)
	graph_edit.duplicate_nodes_request.connect(duplicate_selection)
	graph_edit.copy_nodes_request.connect(_copy_selection)
	graph_edit.cut_nodes_request.connect(func() -> void:
		_copy_selection()
		delete_cells(selected_ids()))
	graph_edit.paste_nodes_request.connect(_paste_clipboard)
	graph_edit.popup_request.connect(_on_popup_request)
	graph_edit.node_selected.connect(func(_n: Node) -> void: _queue_inspector())
	graph_edit.node_deselected.connect(func(_n: Node) -> void: _queue_inspector())
	graph_edit.end_node_move.connect(_sync_positions)
	graph_edit.graph_elements_linked_to_frame_request.connect(_on_linked_to_frame)
	graph_edit.gui_input.connect(_on_graph_input)
	top.add_child(graph_edit)

	var side := ScrollContainer.new()
	side.custom_minimum_size.x = Ed.px(340)
	side.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector = CellInspector.new()
	inspector.host = self
	side.add_child(inspector)
	top.add_child(side)
	_body.add_child(top)

	_bottom = TabContainer.new()
	_bottom.custom_minimum_size.y = Ed.px(200)
	validation = ValidationPanel.new()
	validation.name = "Problems"
	validation.cell_activated.connect(focus_cell)
	_bottom.add_child(validation)
	simulator = SimulatorPanel.new()
	simulator.name = "Simulator"
	simulator.marks_changed.connect(_on_sim_marks)
	simulator.focus_requested.connect(func(id: String) -> void:
		if _nodes.has(id):
			center_on(_nodes[id]))
	_bottom.add_child(simulator)
	_body.add_child(_bottom)
	add_child(_body)

	_empty = CenterContainer.new()
	_empty.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var ebox := VBoxContainer.new()
	var elabel := Label.new()
	elabel.text = "No story open.\nCreate one, open a StoryGraph resource (.tres),\nor double-click one in the FileSystem dock."
	elabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ebox.add_child(elabel)
	var ebtns := HBoxContainer.new()
	ebtns.alignment = BoxContainer.ALIGNMENT_CENTER
	ebtns.add_child(_button("New story…", func() -> void: _on_story_menu(MENU_NEW)))
	ebtns.add_child(_button("Open…", func() -> void: _on_story_menu(MENU_OPEN)))
	ebox.add_child(ebtns)
	_empty.add_child(ebox)
	add_child(_empty)

	_add_popup = PopupMenu.new()
	_add_popup.id_pressed.connect(_on_popup_id)
	_add_popup.popup_hide.connect(func() -> void: _clear_pending.call_deferred())
	add_child(_add_popup)

	_move_timer = Timer.new()
	_move_timer.one_shot = true
	_move_timer.wait_time = 0.3
	_move_timer.timeout.connect(_sync_positions)
	add_child(_move_timer)

	edit_graph(graph)


func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	var story_menu := MenuButton.new()
	story_menu.text = "Story"
	story_menu.flat = false
	var sp := story_menu.get_popup()
	sp.add_item("New Story…", MENU_NEW)
	sp.add_item("Open…", MENU_OPEN)
	sp.add_item("Save", MENU_SAVE)
	sp.add_item("Save As…", MENU_SAVE_AS)
	sp.add_separator()
	sp.add_item("Import JSON…", MENU_IMPORT_JSON)
	sp.add_item("Export JSON…", MENU_EXPORT_JSON)
	sp.add_separator()
	sp.add_item("Show Whole Story", MENU_VIEW_ALL)
	sp.id_pressed.connect(_on_story_menu)
	bar.add_child(story_menu)

	var add_menu := MenuButton.new()
	add_menu.text = "Add Cell"
	add_menu.flat = false
	var ap := add_menu.get_popup()
	for i in StoryCell.TYPE_NAMES.size():
		ap.add_item(StoryCell.TYPE_NAMES[i], i)
	ap.id_pressed.connect(func(t: int) -> void:
		_pending = {}
		_popup_pos = _view_center()
		_add_cell_at(t as StoryCell.Type, _popup_pos))
	bar.add_child(add_menu)
	bar.add_child(_button("Group Selected", group_selection, "Put the selected cells in a named group (Ctrl+G)"))
	bar.add_child(VSeparator.new())
	_search = LineEdit.new()
	_search.placeholder_text = "Find cell (id, name or text)…"
	_search.custom_minimum_size.x = Ed.px(220)
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _search_index = -1)
	_search.text_submitted.connect(func(_t: String) -> void: find_next())
	bar.add_child(_search)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_problems_btn = _button("Problems", func() -> void: _bottom.current_tab = 0, "Validate the story and list problems")
	_problems_btn.flat = true
	bar.add_child(_problems_btn)
	bar.add_child(_button("Play ▸", func() -> void:
		_bottom.current_tab = 1
		simulator.play(""), "Simulate the story from its first Start cell"))
	_file_label = Label.new()
	_file_label.modulate = Color(1, 1, 1, 0.6)
	bar.add_child(_file_label)
	add_child(bar)


# --- opening / snapshots / undo --------------------------------------------------------------

func edit_graph(g: StoryGraph) -> void:
	graph = g
	_last = g.to_dict() if g else {}
	dirty = false
	_undo.clear_history()
	_clipboard.clear()
	_sim_visited.clear()
	_sim_current = ""
	if graph_edit == null:
		return
	_body.visible = g != null
	_empty.visible = g == null
	_rebuild()
	revalidate()
	simulator.set_graph(g)
	inspector.show_story()
	_update_title()
	if g:
		view_all.call_deferred()


## Records an undo step if the graph changed since the last commit.
func commit(action: String) -> void:
	if graph == null:
		return
	var now := graph.to_dict()
	if now == _last:
		return
	var before := _last
	_last = now
	_set_dirty(true)
	if editor_undo:
		# Context = the story resource and mark_unsaved = false, so story edits don't mark the
		# open scene as changed (the story has its own unsaved state, see has_unsaved()).
		editor_undo.call("create_action", "Story: " + action, UndoRedo.MERGE_DISABLE, graph, false, false)
		editor_undo.call("add_do_method", self, "_apply_snapshot", graph, now)
		editor_undo.call("add_undo_method", self, "_apply_snapshot", graph, before)
		editor_undo.call("commit_action", false)
	else:
		_undo.create_action(action)
		_undo.add_do_method(_apply_snapshot.bind(graph, now))
		_undo.add_undo_method(_apply_snapshot.bind(graph, before))
		_undo.commit_action(false)
	revalidate()
	simulator.refresh_entries()


func undo() -> void:
	if editor_undo == null:
		_undo.undo()


func redo() -> void:
	if editor_undo == null:
		_undo.redo()


func _apply_snapshot(target: StoryGraph, data: Dictionary) -> void:
	target.load_dict(data)
	if target != graph:
		return  # an older story in the editor history; it's changed but not on screen
	_last = graph.to_dict()
	_set_dirty(true)
	var keep := selected_ids()
	_rebuild(keep)
	revalidate()
	simulator.refresh_entries()
	_queue_inspector(true)


func _set_dirty(on: bool) -> void:
	dirty = on
	_update_title()


func _update_title() -> void:
	if _file_label == null:
		return
	if graph == null:
		_file_label.text = ""
		return
	var path := graph.resource_path if graph.resource_path != "" else "(not saved yet)"
	_file_label.text = "%s — %s%s" % [graph.title, path, "  (unsaved)" if dirty else ""]


func has_unsaved() -> bool:
	return graph != null and dirty


# --- graph view -------------------------------------------------------------------------------

func _graph_elements() -> Array[GraphElement]:
	var out: Array[GraphElement] = []
	for c in graph_edit.get_children():
		if c is GraphElement and not c.is_queued_for_deletion():
			out.append(c)
	return out


func _rebuild(keep_selected: Array[String] = []) -> void:
	if graph_edit == null:
		return
	_building = true
	if keep_selected.is_empty():
		keep_selected = selected_ids()
	graph_edit.clear_connections()
	# Old elements stay children (hidden) until they are deleted at the end of the frame:
	# GraphEdit has deferred frame updates for them that expect them to still be there.
	for el in _graph_elements():
		if graph_edit.get_element_frame(el.name):
			graph_edit.detach_graph_element_from_frame(el.name)
	for el in _graph_elements():
		el.visible = false
		el.selected = false
		el.queue_free()
	_nodes.clear()
	_frames.clear()
	if graph == null:
		_building = false
		return
	for f in graph.frames:
		var gf := GraphFrame.new()
		_name_serial += 1
		gf.name = "frame_%d" % _name_serial
		gf.set_meta("frame_id", f.id)
		graph_edit.add_child(gf)
		gf.title = f.title
		gf.position_offset = f.position
		gf.size = f.size
		gf.tint_color_enabled = true
		gf.tint_color = f.color
		gf.autoshrink_enabled = true
		gf.position_offset_changed.connect(_on_element_moved)
		_frames[f.id] = gf
	for c in graph.cells:
		if _nodes.has(c.id):
			continue  # duplicate id; the validator reports it
		var n: CellNode = CellNode.new()
		_name_serial += 1
		n.name = "cell_%d" % _name_serial
		n.set_meta("cell_id", c.id)
		graph_edit.add_child(n)
		n.setup(c)
		n.position_offset = c.position
		n.position_offset_changed.connect(_on_element_moved)
		n.add_output_pressed.connect(add_output)
		_nodes[c.id] = n
	_connect_all()
	for f in graph.frames:
		for id in f.cell_ids:
			if _nodes.has(id) and _frames.has(f.id):
				graph_edit.attach_graph_element_to_frame((_nodes[id] as Node).name, (_frames[f.id] as Node).name)
	for id in keep_selected:
		if _nodes.has(id):
			(_nodes[id] as GraphElement).selected = true
	_apply_marks()
	_building = false


func _connect_all() -> void:
	graph_edit.clear_connections()
	for c in graph.cells:
		if not _nodes.has(c.id) or (_nodes[c.id] as CellNode).cell != c:
			continue
		for p in c.outputs.size():
			var t := c.outputs[p].target_id
			if _nodes.has(t) and (_nodes[t] as CellNode).cell.has_input():
				graph_edit.connect_node((_nodes[c.id] as Node).name, p, (_nodes[t] as Node).name, 0)


## Called by the inspector after it changed a cell. structural = connections/ports changed.
func cell_changed(c: StoryCell, structural: bool) -> void:
	if structural:
		_rebuild()
	elif _nodes.has(c.id):
		(_nodes[c.id] as CellNode).refresh()
	_set_dirty(true)


func frame_changed(f: StoryFrame) -> void:
	if _frames.has(f.id):
		var gf: GraphFrame = _frames[f.id]
		gf.title = f.title
		gf.tint_color = f.color
	_set_dirty(true)


func revalidate() -> void:
	issues = StoryValidator.validate(graph) if graph else []
	if validation:
		validation.set_issues(issues)
	_apply_marks()
	if _problems_btn:
		var c := [0, 0]
		for issue: StoryValidator.Issue in issues:
			if issue.severity < 2:
				c[issue.severity] += 1
		_problems_btn.text = "No problems" if c[0] + c[1] == 0 else "Problems: %d error(s), %d warning(s)" % [c[0], c[1]]
		_problems_btn.modulate = Color(1, 0.55, 0.55) if c[0] > 0 else (Color(1, 0.85, 0.5) if c[1] > 0 else Color(0.6, 1, 0.7))


func issues_for(id: String) -> Array:
	return issues.filter(func(i: StoryValidator.Issue) -> bool: return i.cell_id == id)


func cell_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	if graph:
		for c in graph.cells:
			out.append(c.id)
	return out


func _apply_marks() -> void:
	var level := {}
	for issue: StoryValidator.Issue in issues:
		if issue.cell_id != "" and issue.severity < 2:
			level[issue.cell_id] = mini(int(level.get(issue.cell_id, 9)), issue.severity)
	for id: String in _nodes:
		var n: CellNode = _nodes[id]
		n.set_issue_level(int(level.get(id, -1)))
		n.set_sim_mark(2 if id == _sim_current else (1 if _sim_visited.has(id) else 0))


func _on_sim_marks(visited: Dictionary, current_id: String) -> void:
	_sim_visited = visited
	_sim_current = current_id
	_apply_marks()


# --- selection ------------------------------------------------------------------------------------

func selected_ids() -> Array[String]:
	var out: Array[String] = []
	if graph_edit == null:
		return out
	for el in _graph_elements():
		if el.selected and el is CellNode:
			out.append(str(el.get_meta("cell_id")))
	return out


func _selected_frame() -> StoryFrame:
	for el in _graph_elements():
		if el.selected and el is GraphFrame:
			return _frame_by_id(str(el.get_meta("frame_id")))
	return null


func _frame_by_id(id: String) -> StoryFrame:
	for f in graph.frames:
		if f.id == id:
			return f
	return null


func _queue_inspector(force := false) -> void:
	if force:
		inspector.cell = null  # make the next show_* rebuild even for the same object
		inspector.frame = null
	if not _inspector_queued:
		_inspector_queued = true
		_update_inspector.call_deferred()


func _update_inspector() -> void:
	_inspector_queued = false
	if graph == null:
		inspector.show_story()
		return
	var ids := selected_ids()
	if ids.size() == 1:
		var c := graph.get_cell(ids[0])
		if c != inspector.cell:
			inspector.show_cell(c)
	elif ids.size() > 1:
		var cells: Array[StoryCell] = []
		for id in ids:
			cells.append(graph.get_cell(id))
		inspector.show_multi(cells)
	else:
		var f := _selected_frame()
		if f:
			if f != inspector.frame:
				inspector.show_frame(f)
		else:
			inspector.show_story()


func focus_cell(id: String) -> void:
	if not _nodes.has(id):
		return
	var n: CellNode = _nodes[id]
	graph_edit.set_selected(n)
	center_on(n)
	_queue_inspector()


func center_on(n: GraphElement) -> void:
	graph_edit.scroll_offset = (n.position_offset + n.size * 0.5) * graph_edit.zoom - graph_edit.size * 0.5


## Zooms and scrolls so every cell is visible.
func view_all() -> void:
	if graph == null or _nodes.is_empty() or graph_edit.size.x < 10:
		return
	var rect := Rect2()
	var first := true
	for el in _graph_elements():
		var r := Rect2(el.position_offset, el.size)
		rect = r if first else rect.merge(r)
		first = false
	rect = rect.grow(40)
	var z := clampf(minf(graph_edit.size.x / rect.size.x, graph_edit.size.y / rect.size.y), 0.35, 1.0)
	graph_edit.zoom = z
	graph_edit.scroll_offset = rect.position * z - (graph_edit.size - rect.size * z) * 0.5


func find_next() -> void:
	var q := _search.text.strip_edges().to_lower()
	if q == "" or graph == null:
		return
	_search_hits.clear()
	for c in graph.cells:
		if c.id.to_lower().contains(q) or c.title.to_lower().contains(q) or c.text.to_lower().contains(q) or c.speaker.to_lower().contains(q):
			_search_hits.append(c.id)
	if _search_hits.is_empty():
		_search.modulate = Color(1, 0.6, 0.6)
		return
	_search.modulate = Color.WHITE
	_search_index = (_search_index + 1) % _search_hits.size()
	focus_cell(_search_hits[_search_index])


func _view_center() -> Vector2:
	return _to_graph(graph_edit.size * 0.5) - Vector2(130, 40)


func _to_graph(local: Vector2) -> Vector2:
	return (local + graph_edit.scroll_offset) / graph_edit.zoom


# --- editing actions ----------------------------------------------------------------------------

func _add_cell_at(type: StoryCell.Type, pos: Vector2) -> StoryCell:
	if graph == null:
		return null
	if graph_edit.snapping_enabled:
		pos = (pos / graph_edit.snapping_distance).round() * graph_edit.snapping_distance
	var c := graph.add_cell(type, pos)
	if _pending.has("from"):
		var src := graph.get_cell(str(_pending.from))
		var port := int(_pending.port)
		if src and c.has_input() and port < src.outputs.size():
			src.outputs[port].target_id = c.id
	elif _pending.has("to") and not c.outputs.is_empty():
		var dst := graph.get_cell(str(_pending.to))
		if dst and dst.has_input():
			c.outputs[0].target_id = dst.id
	_pending = {}
	_rebuild([c.id] as Array[String])
	for el in _graph_elements():
		el.selected = el is CellNode and str(el.get_meta("cell_id")) == c.id
	commit("Add %s cell" % StoryCell.TYPE_NAMES[type])
	_queue_inspector()
	return c


func add_output(id: String) -> void:
	var c := graph.get_cell(id)
	if c == null or not c.allows_outputs():
		return
	match c.type:
		StoryCell.Type.CHOICE:
			c.outputs.append(StoryOutput.make("Option %d" % (c.outputs.size() + 1)))
		StoryCell.Type.CONDITION:
			var o := StoryOutput.make("", "", StoryCondition.group(StoryCondition.Kind.ALL, [StoryCondition.make(StoryCondition.Kind.FLAG_SET)]))
			var at := c.outputs.size()
			if at > 0 and not c.outputs[at - 1].has_condition():
				at -= 1  # keep the Else branch last
			c.outputs.insert(at, o)
		_:
			c.outputs.append(StoryOutput.make())
	_rebuild()
	commit("Add output")
	_queue_inspector(true)


func delete_cells(ids: Array) -> void:
	if graph == null or ids.is_empty():
		return
	for id: Variant in ids:
		graph.remove_cell(str(id))
	_rebuild([] as Array[String])
	commit("Delete cells")
	inspector.show_story()


func delete_frame(id: String) -> void:
	for i in range(graph.frames.size() - 1, -1, -1):
		if graph.frames[i].id == id:
			graph.frames.remove_at(i)
	_rebuild()
	commit("Delete group")
	inspector.show_story()


func rename_cell(old_id: String, new_id: String) -> bool:
	if not graph.rename_cell(old_id, new_id):
		return false
	_rebuild([new_id.strip_edges()] as Array[String])
	commit("Rename cell")
	_queue_inspector(true)
	return true


func duplicate_selection() -> void:
	var ids := selected_ids()
	if ids.is_empty():
		return
	var new_ids := _paste(_copy(ids), Vector2(60, 60))
	_rebuild(new_ids)
	for el in _graph_elements():
		el.selected = el is CellNode and new_ids.has(str(el.get_meta("cell_id")))
	commit("Duplicate cells")
	_queue_inspector()


func _copy(ids: Array[String]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in ids:
		var c := graph.get_cell(id)
		if c:
			out.append(c.to_dict())
	return out


## Adds copies of the cells with fresh ids; connections between copied cells follow the
## copies, connections to other cells are kept. Returns the new ids.
func _paste(dicts: Array[Dictionary], offset: Vector2) -> Array[String]:
	var map := {}
	var made: Array[StoryCell] = []
	var re := RegEx.create_from_string("_\\d+$")
	for d in dicts:
		var c := StoryCell.from_dict(d)
		var base := re.sub(c.id, "")
		c.id = graph.new_id(base)
		map[str(d.id)] = c.id
		c.position += offset
		graph.cells.append(c)
		made.append(c)
	var out: Array[String] = []
	for c in made:
		for o in c.outputs:
			if map.has(o.target_id):
				o.target_id = map[o.target_id]
		out.append(c.id)
	return out


func _copy_selection() -> void:
	_clipboard = _copy(selected_ids())
	_paste_count = 0


func _paste_clipboard() -> void:
	if _clipboard.is_empty() or graph == null:
		return
	_paste_count += 1
	var new_ids := _paste(_clipboard, Vector2(60, 60) * _paste_count)
	_rebuild(new_ids)
	for el in _graph_elements():
		el.selected = el is CellNode and new_ids.has(str(el.get_meta("cell_id")))
	commit("Paste cells")
	_queue_inspector()


func group_selection() -> void:
	var ids := selected_ids()
	if ids.is_empty() or graph == null:
		return
	_remove_from_frames(ids)
	var rect := Rect2()
	var first := true
	for id in ids:
		var n: CellNode = _nodes[id]
		var r := Rect2(n.position_offset, n.size)
		rect = r if first else rect.merge(r)
		first = false
	var f := StoryFrame.new()
	f.id = graph.new_frame_id()
	f.title = "Group %s" % f.id.trim_prefix("group_")
	f.cell_ids = PackedStringArray(ids)
	f.position = rect.position - Vector2(30, 60)
	f.size = rect.size + Vector2(60, 90)
	f.color = Color.from_hsv(fmod(graph.frames.size() * 0.17, 1.0), 0.45, 0.55, 0.55)
	graph.frames.append(f)
	_rebuild(ids)
	commit("Group cells")


func ungroup_selection() -> void:
	var ids := selected_ids()
	if ids.is_empty():
		return
	_remove_from_frames(ids)
	_rebuild(ids)
	commit("Remove from group")


func _remove_from_frames(ids: Array[String]) -> void:
	for f in graph.frames:
		var keep: PackedStringArray = []
		for id in f.cell_ids:
			if not ids.has(id):
				keep.append(id)
		f.cell_ids = keep


func simulate_from(id: String) -> void:
	_bottom.current_tab = 1
	simulator.play(id)


# --- GraphEdit signals --------------------------------------------------------------------------

func _cell_of(node_name: StringName) -> StoryCell:
	var n := graph_edit.get_node_or_null(NodePath(node_name))
	return (n as CellNode).cell if n is CellNode else null


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, _to_port: int) -> void:
	var a := _cell_of(from_node)
	var b := _cell_of(to_node)
	if a == null or b == null or from_port >= a.outputs.size() or not b.has_input():
		return
	a.outputs[from_port].target_id = b.id  # an output leads to one cell: replaces any old link
	(_nodes[a.id] as CellNode).refresh()
	_connect_all()
	commit("Connect cells")
	_queue_inspector(true)


func _on_disconnection_request(from_node: StringName, from_port: int, _to_node: StringName, _to_port: int) -> void:
	var a := _cell_of(from_node)
	if a == null or from_port >= a.outputs.size():
		return
	a.outputs[from_port].target_id = ""
	(_nodes[a.id] as CellNode).refresh()
	_connect_all()
	commit("Disconnect cells")
	_queue_inspector(true)


func _on_connection_to_empty(from_node: StringName, from_port: int, release_position: Vector2) -> void:
	var a := _cell_of(from_node)
	if a == null:
		return
	_open_add_popup(release_position, false)
	_pending = {"from": a.id, "port": from_port}


func _on_connection_from_empty(to_node: StringName, _to_port: int, release_position: Vector2) -> void:
	var b := _cell_of(to_node)
	if b == null:
		return
	_open_add_popup(release_position - Vector2(Ed.px(CellNode.WIDTH), 0) * graph_edit.zoom, false)
	_pending = {"to": b.id}


func _on_delete_request(names: Array[StringName]) -> void:
	var ids: Array[String] = []
	var frame_ids: Array[String] = []
	for n in names:
		var node := graph_edit.get_node_or_null(NodePath(n))
		if node is CellNode:
			ids.append(str(node.get_meta("cell_id")))
		elif node is GraphFrame:
			frame_ids.append(str(node.get_meta("frame_id")))
	if ids.is_empty() and frame_ids.is_empty():
		return
	for fid in frame_ids:
		for i in range(graph.frames.size() - 1, -1, -1):
			if graph.frames[i].id == fid:
				graph.frames.remove_at(i)
	for id in ids:
		graph.remove_cell(id)
	_rebuild([] as Array[String])
	commit("Delete")
	inspector.show_story()


func _on_linked_to_frame(elements: Array, frame: StringName) -> void:
	var gf := graph_edit.get_node_or_null(NodePath(frame))
	if gf == null:
		return
	var f := _frame_by_id(str(gf.get_meta("frame_id")))
	if f == null:
		return
	var ids: Array[String] = []
	for e: Variant in elements:
		var node := graph_edit.get_node_or_null(NodePath(str(e)))
		if node is CellNode:
			ids.append(str(node.get_meta("cell_id")))
	_remove_from_frames(ids)
	var members := f.cell_ids
	for id in ids:
		members.append(id)
	f.cell_ids = members
	_rebuild()
	commit("Add to group")


func _on_element_moved() -> void:
	if not _building and is_instance_valid(_move_timer) and _move_timer.is_inside_tree():
		_move_timer.start()


## Copies node/group positions back into the resource after a move.
func _sync_positions() -> void:
	if graph == null or _building:
		return
	for id: String in _nodes:
		var n: CellNode = _nodes[id]
		n.cell.position = n.position_offset
	for fid: String in _frames:
		var f := _frame_by_id(fid)
		var gf: GraphFrame = _frames[fid]
		if f:
			f.position = gf.position_offset
			f.size = gf.size
	commit("Move")


func _on_popup_request(at_position: Vector2) -> void:
	_open_add_popup(at_position, true)
	_pending = {}


func _on_graph_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
		_open_add_popup(event.position, false)
		_pending = {}
		graph_edit.accept_event()


func _open_add_popup(local_pos: Vector2, with_selection: bool) -> void:
	if graph == null:
		return
	_popup_pos = _to_graph(local_pos)
	_add_popup.clear()
	_add_popup.add_separator("Add cell")
	for i in StoryCell.TYPE_NAMES.size():
		_add_popup.add_item(StoryCell.TYPE_NAMES[i], i)
	var ids := selected_ids()
	if with_selection and not ids.is_empty():
		_add_popup.add_separator("Selection (%d)" % ids.size())
		_add_popup.add_item("Duplicate", POPUP_DUPLICATE)
		_add_popup.add_item("Delete", POPUP_DELETE)
		_add_popup.add_item("Group", POPUP_GROUP)
		_add_popup.add_item("Remove from group", POPUP_UNGROUP)
		if ids.size() == 1:
			_add_popup.add_item("Play from here", POPUP_PLAY)
	_add_popup.position = Vector2i(graph_edit.get_screen_position() + local_pos)
	_add_popup.reset_size()
	_add_popup.popup()


func _on_popup_id(id: int) -> void:
	match id:
		POPUP_DUPLICATE: duplicate_selection()
		POPUP_DELETE: delete_cells(selected_ids())
		POPUP_GROUP: group_selection()
		POPUP_UNGROUP: ungroup_selection()
		POPUP_PLAY:
			var ids := selected_ids()
			if not ids.is_empty():
				simulate_from(ids[0])
		_:
			if id >= 0 and id < StoryCell.TYPE_NAMES.size():
				_add_cell_at(id as StoryCell.Type, _popup_pos)


func _clear_pending() -> void:
	_pending = {}


func _shortcut_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	var mod := k.ctrl_pressed or k.meta_pressed
	if mod and k.keycode == KEY_G:
		group_selection()
		get_viewport().set_input_as_handled()
	elif mod and k.keycode == KEY_F and graph_edit.has_focus():
		_search.grab_focus()
		get_viewport().set_input_as_handled()
	elif editor_undo == null and mod and k.keycode == KEY_Z:
		redo() if k.shift_pressed else undo()
		get_viewport().set_input_as_handled()
	elif editor_undo == null and mod and k.keycode == KEY_S:
		save_story()
		get_viewport().set_input_as_handled()


# --- files --------------------------------------------------------------------------------------

func _on_story_menu(id: int) -> void:
	match id:
		MENU_NEW:
			_confirm_discard(func() -> void:
				edit_graph(new_story())
				_set_dirty(true)
				_save_as())
		MENU_OPEN:
			_confirm_discard(func() -> void:
				_file_dialog(false, PackedStringArray(["*.tres, *.res ; Story graphs"]), "Open a story", 0, func(path: String) -> void:
					var res := load(path)
					if res is StoryGraph:
						edit_graph(res)
					else:
						_alert("%s is not a StoryGraph resource." % path)))
		MENU_SAVE:
			save_story()
		MENU_SAVE_AS:
			_save_as()
		MENU_IMPORT_JSON:
			_file_dialog(false, PackedStringArray(["*.json ; JSON"]), "Import a story from JSON", 2, import_json)
		MENU_EXPORT_JSON:
			if graph:
				_file_dialog(true, PackedStringArray(["*.json ; JSON"]), "Export the story as JSON", 2, export_json)
		MENU_VIEW_ALL:
			view_all()


## A small starting story: Start -> Dialogue -> End.
static func new_story() -> StoryGraph:
	var g := StoryGraph.new()
	g.title = "New story"
	var s := g.add_cell(StoryCell.Type.START, Vector2(0, 0))
	var d := g.add_cell(StoryCell.Type.DIALOGUE, Vector2(340, 0))
	d.speaker = "Narrator"
	d.text = "Once upon a time…"
	var e := g.add_cell(StoryCell.Type.END, Vector2(700, 0))
	s.outputs[0].target_id = d.id
	d.outputs[0].target_id = e.id
	return g


## Saves to the resource's file (asks for one if it has none). Returns true on success.
func save_story() -> bool:
	if graph == null:
		return false
	var path := graph.resource_path
	if path == "" or not path.begins_with("res://") or path.contains("::"):
		_save_as()
		return false
	return _save_to(path)


func _save_to(path: String) -> bool:
	_sync_positions_silently()
	if graph.resource_path != path:
		graph.take_over_path(path)
	var err := ResourceSaver.save(graph, path)
	if err != OK:
		_alert("Couldn't save %s (error %d)." % [path, err])
		return false
	_set_dirty(false)
	story_saved.emit(path)
	return true


func _sync_positions_silently() -> void:
	for id: String in _nodes:
		var n: CellNode = _nodes[id]
		n.cell.position = n.position_offset
	_last = graph.to_dict()


func _save_as() -> void:
	if graph == null:
		return
	_file_dialog(true, PackedStringArray(["*.tres ; Story graph"]), "Save the story", 0, func(path: String) -> void:
		if not path.get_extension() in ["tres", "res"]:
			path += ".tres"
		_save_to(path))


func export_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_alert("Couldn't write %s." % path)
		return false
	f.store_string(graph.to_json())
	f.close()
	return true


func import_json(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary) or not (data as Dictionary).has("cells"):
		_alert("%s is not a story graph JSON file." % path)
		return false
	if graph == null:
		edit_graph(StoryGraph.new())
	graph.load_dict(data)
	_rebuild([] as Array[String])
	commit("Import JSON")
	inspector.show_story()
	view_all.call_deferred()
	return true


func _confirm_discard(then: Callable) -> void:
	if not has_unsaved():
		then.call()
		return
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "\"%s\" has unsaved changes. Discard them?" % graph.title
	dlg.ok_button_text = "Discard"
	dlg.confirmed.connect(then)
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


## access: 0 = res://, 2 = whole file system (same values for FileDialog and EditorFileDialog).
func _file_dialog(save: bool, filters: PackedStringArray, title: String, access: int, on_file: Callable) -> void:
	var dlg: Window
	if in_editor and ClassDB.class_exists("EditorFileDialog"):
		dlg = ClassDB.instantiate("EditorFileDialog")
	else:
		dlg = FileDialog.new()
	dlg.set("file_mode", 4 if save else 0)  # FILE_MODE_SAVE_FILE / FILE_MODE_OPEN_FILE
	dlg.set("access", access)
	dlg.set("filters", filters)
	dlg.title = title
	if save and graph and graph.resource_path.begins_with("res://") and access == 0:
		dlg.set("current_path", graph.resource_path)
	elif save and access == 0:
		dlg.set("current_dir", "res://stories" if DirAccess.dir_exists_absolute("res://stories") else "res://")
	dlg.connect("file_selected", func(p: String) -> void: on_file.call(p))
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered_ratio(0.55)


func _alert(text: String) -> void:
	push_warning("Story editor: " + text)
	var dlg := AcceptDialog.new()
	dlg.dialog_text = text
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _button(text: String, on_press: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(on_press)
	return b
