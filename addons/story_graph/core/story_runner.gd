@tool
class_name StoryRunner
extends RefCounted
## Plays a StoryGraph. Connect the signals (or poll `status` / `current`), call start(),
## then advance() after dialogue and choose(i) at choices:
##
##     var runner := StoryRunner.new(load("res://stories/intro.tres"))
##     runner.dialogue.connect(func(cell, speaker, text): show_line(speaker, text))
##     runner.choices_presented.connect(func(cell, choices): show_buttons(choices))
##     runner.game_event.connect(func(name, payload): ...)
##     runner.start()
##
## Events with prerequisites and no incoming connection are "triggerable": the game asks
## get_available_events() and calls trigger(id) (e.g. when the player walks into a room).

signal cell_entered(cell: StoryCell)
signal dialogue(cell: StoryCell, speaker: String, text: String)
signal choices_presented(cell: StoryCell, choices: Array[Dictionary])
signal game_event(event_name: String, payload: String)
signal story_ended(cell: StoryCell, reason: String)

enum Status { IDLE, WAITING_CONTINUE, WAITING_CHOICE, ENDED }

const MAX_AUTO_STEPS := 1000  ## guards against endless loops of non-waiting cells

var graph: StoryGraph
var state := StoryState.new()
var current: StoryCell
var status := Status.IDLE
var end_reason := ""            ## "ending", "dead end", "no choices", "loop", "blocked"
var path: Array[String] = []    ## ids entered, in order


func _init(graph_: StoryGraph = null, state_: StoryState = null) -> void:
	graph = graph_
	if state_:
		state = state_


## Starts at entry_id (or the first Start cell). reset_state=false keeps flags/variables
## from earlier (e.g. a later chapter). Returns false if the entry can't be entered.
func start(entry_id := "", reset_state := true) -> bool:
	if graph == null:
		return false
	if reset_state:
		state.reset(graph)
	path.clear()
	status = Status.IDLE
	end_reason = ""
	current = null
	var entry: StoryCell = graph.get_cell(entry_id) if entry_id != "" else null
	if entry == null and entry_id == "":
		var starts := graph.get_start_cells()
		for s in starts:
			if can_enter(s):
				entry = s
				break
	if entry == null or not can_enter(entry):
		_end(entry, "blocked")
		return false
	_run_from(entry)
	return true


## Enters a triggerable event cell while keeping the current state.
func trigger(id: String) -> bool:
	var cell := graph.get_cell(id)
	if cell == null or not can_enter(cell):
		return false
	status = Status.IDLE
	end_reason = ""
	_run_from(cell)
	return true


func is_waiting() -> bool:
	return status == Status.WAITING_CONTINUE or status == Status.WAITING_CHOICE


func is_finished() -> bool:
	return status == Status.ENDED


## Prerequisites pass and (repeatable or not done yet).
func can_enter(cell: StoryCell) -> bool:
	if cell == null:
		return false
	if not cell.repeatable and state.is_completed(cell.id):
		return false
	return not cell.has_prerequisites() or cell.prerequisites.evaluate(state)


func is_output_open(o: StoryOutput) -> bool:
	if o.target_id == "":
		return false
	if o.has_condition() and not o.condition.evaluate(state):
		return false
	return can_enter(graph.get_cell(o.target_id))


## The options at the current Choice: [{index, label, target, open}]. Closed options are
## included (open = false) so a UI can grey them out; choose() only accepts open ones.
func get_choices() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if current == null or current.type != StoryCell.Type.CHOICE:
		return out
	for i in current.outputs.size():
		var o := current.outputs[i]
		out.append({"index": i, "label": interpolate(o.label if o.label != "" else "Option %d" % (i + 1)),
			"target": o.target_id, "open": is_output_open(o)})
	return out


func choose(index: int) -> bool:
	if status != Status.WAITING_CHOICE or index < 0 or index >= current.outputs.size():
		return false
	var o := current.outputs[index]
	if not is_output_open(o):
		return false
	_run_from(graph.get_cell(o.target_id))
	return true


## Continues after a Dialogue cell.
func advance() -> bool:
	if status != Status.WAITING_CONTINUE:
		return false
	var next := _next_of(current)
	if next == null:
		_end(current, "dead end")
		return true
	_run_from(next)
	return true


## Triggerable events whose prerequisites are met right now: cells that nothing leads to,
## that have prerequisites, and that can be entered.
func get_available_events() -> Array[StoryCell]:
	var out: Array[StoryCell] = []
	if graph == null:
		return out
	var has_incoming := {}
	for c in graph.cells:
		for o in c.outputs:
			has_incoming[o.target_id] = true
	for c in graph.cells:
		if c.type != StoryCell.Type.END and not has_incoming.has(c.id) and c.has_prerequisites() and can_enter(c):
			if c.repeatable or not state.is_completed(c.id):
				out.append(c)
	return out


## Replaces {name} with the variable's value.
func interpolate(text: String) -> String:
	if not text.contains("{"):
		return text
	var out := text
	for k: Variant in state.variables:
		out = out.replace("{%s}" % k, str(state.variables[k]))
	return out


func _next_of(cell: StoryCell) -> StoryCell:
	for o in cell.outputs:
		if is_output_open(o):
			return graph.get_cell(o.target_id)
	return null


func _run_from(cell: StoryCell) -> void:
	var steps := 0
	while cell != null:
		steps += 1
		if steps > MAX_AUTO_STEPS:
			_end(cell, "loop")
			return
		current = cell
		path.append(cell.id)
		state.mark_completed(cell.id)
		for a in cell.actions:
			a.apply(state)
			if a.kind == StoryAction.Kind.EMIT_EVENT:
				game_event.emit(a.target, interpolate(a.value))
		cell_entered.emit(cell)
		match cell.type:
			StoryCell.Type.DIALOGUE:
				status = Status.WAITING_CONTINUE
				dialogue.emit(cell, interpolate(cell.speaker), interpolate(cell.text))
				return
			StoryCell.Type.CHOICE:
				var choices := get_choices()
				if not choices.any(func(c: Dictionary) -> bool: return c.open):
					_end(cell, "no choices")
					return
				status = Status.WAITING_CHOICE
				if cell.text != "":
					dialogue.emit(cell, interpolate(cell.speaker), interpolate(cell.text))
				choices_presented.emit(cell, choices)
				return
			StoryCell.Type.END:
				_end(cell, "ending")
				return
			_:
				var next := _next_of(cell)
				if next == null:
					_end(cell, "dead end")
					return
				cell = next


func _end(cell: StoryCell, reason: String) -> void:
	status = Status.ENDED
	end_reason = reason
	if cell:
		current = cell
	story_ended.emit(cell, reason)
