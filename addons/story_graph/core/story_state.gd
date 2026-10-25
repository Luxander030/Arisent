@tool
class_name StoryState
extends RefCounted
## What has happened so far: completed events (with counts), flags and variables.
## Plain dictionaries, so a game can store to_dict() in its save file.

var completed := {}   ## event id -> times entered
var flags := {}       ## flag name -> true
var variables := {}   ## name -> value


## Clears everything and loads the graph's variable defaults.
func reset(graph: StoryGraph = null) -> void:
	completed.clear()
	flags.clear()
	variables.clear()
	if graph:
		for k: Variant in graph.variables:
			var v: Variant = graph.variables[k]
			variables[str(k)] = StoryCondition.parse_value(v) if v is String else v


func is_completed(id: String) -> bool:
	return int(completed.get(id, 0)) > 0


func times_completed(id: String) -> int:
	return int(completed.get(id, 0))


func mark_completed(id: String) -> void:
	completed[id] = int(completed.get(id, 0)) + 1


func has_flag(name: String) -> bool:
	return flags.has(name)


func set_flag(name: String, on := true) -> void:
	if on:
		flags[name] = true
	else:
		flags.erase(name)


func get_var(name: String, default: Variant = null) -> Variant:
	return variables.get(name, default)


func set_var(name: String, value: Variant) -> void:
	variables[name] = value


# Helpers callable inside expressions, e.g.  done("met_guard") and gold >= 10 and flag("rich")
func done(id: String) -> bool:
	return is_completed(id)


func flag(name: String) -> bool:
	return has_flag(name)


func times(id: String) -> int:
	return times_completed(id)


## Evaluates a Godot Expression with the variables as inputs. Returns null if it fails.
func evaluate_expression(text: String) -> Variant:
	var names: PackedStringArray = []
	var values := []
	for k: Variant in variables:
		var key := str(k)
		if key.is_valid_identifier():
			names.append(key)
			values.append(variables[k])
	var e := Expression.new()
	if e.parse(text, names) != OK:
		return null
	var result: Variant = e.execute(values, self, false)
	return null if e.has_execute_failed() else result


## Parse error for an expression given the variable names it may use ("" if it parses).
static func expression_error(text: String, names: PackedStringArray) -> String:
	if text.strip_edges() == "":
		return "the expression is empty"
	var e := Expression.new()
	return e.get_error_text() if e.parse(text, names) != OK else ""


func copy() -> StoryState:
	var s := StoryState.new()
	s.completed = completed.duplicate(true)
	s.flags = flags.duplicate(true)
	s.variables = variables.duplicate(true)
	return s


func to_dict() -> Dictionary:
	return {"completed": completed.duplicate(true), "flags": flags.keys(), "variables": variables.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	completed = (d.get("completed", {}) as Dictionary).duplicate(true)
	flags.clear()
	for f: Variant in d.get("flags", []):
		flags[str(f)] = true
	variables = (d.get("variables", {}) as Dictionary).duplicate(true)
