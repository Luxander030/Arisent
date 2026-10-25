@tool
class_name StoryGraph
extends Resource
## A branching story: cells joined by their outputs, plus declared variables and flags.
## Save it as a .tres (editable in the Story tab) and play it in the game with StoryRunner:
##     var runner := StoryRunner.new(load("res://stories/intro.tres"))
##     runner.dialogue.connect(...)
##     runner.start()

const FORMAT_VERSION := 1

@export var title := "Untitled story"
@export_multiline var description := ""
@export var cells: Array[StoryCell] = []
@export var frames: Array[StoryFrame] = []
@export var variables := {}                 ## name -> default value (int, float, bool or String)
@export var flags: PackedStringArray = []   ## declared flag names (all start unset)


func get_cell(id: String) -> StoryCell:
	for c in cells:
		if c.id == id:
			return c
	return null


func has_cell(id: String) -> bool:
	return get_cell(id) != null


## id -> StoryCell (first wins on duplicate ids).
func index() -> Dictionary:
	var d := {}
	for c in cells:
		if not d.has(c.id):
			d[c.id] = c
	return d


func get_start_cells() -> Array[StoryCell]:
	var out: Array[StoryCell] = []
	for c in cells:
		if c.type == StoryCell.Type.START:
			out.append(c)
	return out


## Cells with an output leading to `id`.
func incoming(id: String) -> Array[StoryCell]:
	var out: Array[StoryCell] = []
	for c in cells:
		for o in c.outputs:
			if o.target_id == id:
				out.append(c)
				break
	return out


## A free id like "dialogue_3".
func new_id(prefix: String) -> String:
	var base := prefix.to_snake_case().strip_edges()
	if base == "":
		base = "cell"
	var used := index()
	var i := 1
	while used.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]


func new_frame_id() -> String:
	var used := {}
	for f in frames:
		used[f.id] = true
	var i := 1
	while used.has("group_%d" % i):
		i += 1
	return "group_%d" % i


func add_cell(type: StoryCell.Type, pos := Vector2.ZERO) -> StoryCell:
	var c := StoryCell.create(type, new_id(StoryCell.TYPE_NAMES[type]), pos)
	cells.append(c)
	return c


## Removes a cell and every output pointing at it. Prerequisites that mention it are kept,
## so the validator reports them as missing instead of silently changing logic.
func remove_cell(id: String) -> void:
	for i in range(cells.size() - 1, -1, -1):
		if cells[i].id == id:
			cells.remove_at(i)
	for c in cells:
		for o in c.outputs:
			if o.target_id == id:
				o.target_id = ""
	for f in frames:
		var ids := f.cell_ids
		if ids.has(id):
			ids.remove_at(ids.find(id))
			f.cell_ids = ids


## Changes a cell id and updates connections, prerequisites, conditions, actions and groups.
## Returns false if new_id is empty or already used.
func rename_cell(old_id: String, new_id_: String) -> bool:
	new_id_ = new_id_.strip_edges()
	if new_id_ == "" or (new_id_ != old_id and has_cell(new_id_)):
		return false
	if new_id_ == old_id:
		return true
	for c in cells:
		if c.id == old_id:
			c.id = new_id_
	for c in cells:
		for o in c.outputs:
			if o.target_id == old_id:
				o.target_id = new_id_
			if o.condition:
				o.condition.rename_event(old_id, new_id_)
		if c.prerequisites:
			c.prerequisites.rename_event(old_id, new_id_)
		for a in c.actions:
			if (a.kind == StoryAction.Kind.MARK_COMPLETED or a.kind == StoryAction.Kind.RESET_EVENT) and a.target == old_id:
				a.target = new_id_
	for f in frames:
		var ids := f.cell_ids
		var idx := ids.find(old_id)
		if idx >= 0:
			ids[idx] = new_id_
			f.cell_ids = ids
	return true


func to_dict() -> Dictionary:
	return {
		"format": "story_graph", "version": FORMAT_VERSION, "title": title, "description": description,
		"variables": variables.duplicate(), "flags": Array(flags),
		"cells": cells.map(func(c: StoryCell) -> Dictionary: return c.to_dict()),
		"frames": frames.map(func(f: StoryFrame) -> Dictionary: return f.to_dict()),
	}


## Replaces this graph's contents (in place, so references to the resource stay valid).
func load_dict(d: Dictionary) -> void:
	title = str(d.get("title", "Untitled story"))
	description = str(d.get("description", ""))
	var vars: Variant = d.get("variables", {})
	variables = {}
	if vars is Dictionary:
		for k: Variant in vars:
			var v: Variant = (vars as Dictionary)[k]
			# JSON stores every number as a float; keep whole numbers as ints.
			variables[str(k)] = int(v) if v is float and is_equal_approx(v, roundf(v)) else v
	flags = PackedStringArray(d.get("flags", []))
	var new_cells: Array[StoryCell] = []
	for c: Variant in d.get("cells", []):
		if c is Dictionary:
			new_cells.append(StoryCell.from_dict(c))
	cells = new_cells
	var new_frames: Array[StoryFrame] = []
	for f: Variant in d.get("frames", []):
		if f is Dictionary:
			new_frames.append(StoryFrame.from_dict(f))
	frames = new_frames
	emit_changed()


func to_json() -> String:
	return JSON.stringify(to_dict(), "\t")


## Returns null if the text isn't a story graph.
static func from_json(text: String) -> StoryGraph:
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary) or not (data as Dictionary).has("cells"):
		return null
	var g := StoryGraph.new()
	g.load_dict(data)
	return g
