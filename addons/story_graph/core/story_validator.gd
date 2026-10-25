@tool
class_name StoryValidator
extends RefCounted
## Finds problems in a StoryGraph: missing start/ending, duplicate ids, broken or invalid
## connections, dead ends, disconnected and unreachable cells, missing or impossible
## prerequisites, circular prerequisites, endless loops, undeclared flags/variables and
## invalid expressions.

enum Severity { ERROR, WARNING, INFO }

class Issue:
	var severity: int
	var cell_id: String   ## "" = the whole story
	var message: String

	func _init(severity_: int, cell_id_: String, message_: String) -> void:
		severity = severity_
		cell_id = cell_id_
		message = message_

	func _to_string() -> String:
		return "%s %s: %s" % [["ERROR", "WARNING", "INFO"][severity], cell_id if cell_id != "" else "<story>", message]


static func validate(graph: StoryGraph) -> Array[Issue]:
	var issues: Array[Issue] = []
	var err := func(id: String, msg: String) -> void: issues.append(Issue.new(Severity.ERROR, id, msg))
	var warn := func(id: String, msg: String) -> void: issues.append(Issue.new(Severity.WARNING, id, msg))
	var info := func(id: String, msg: String) -> void: issues.append(Issue.new(Severity.INFO, id, msg))
	if graph == null:
		err.call("", "No story.")
		return issues

	# --- ids -----------------------------------------------------------------------------
	var by_id := {}
	for c in graph.cells:
		if c.id.strip_edges() == "":
			err.call("", "A cell (\"%s\") has an empty ID." % c.title)
		elif by_id.has(c.id):
			err.call(c.id, "Duplicate ID \"%s\": IDs must be unique." % c.id)
		else:
			by_id[c.id] = c
	var ids: Array[String] = []
	for k: String in by_id:
		ids.append(k)

	var starts: Array[StoryCell] = graph.get_start_cells()
	if starts.is_empty():
		err.call("", "The story has no Start cell, so it can't begin.")
	if not graph.cells.any(func(c: StoryCell) -> bool: return c.type == StoryCell.Type.END):
		err.call("", "The story has no End cell, so it never finishes.")

	# Names that something sets (flags / variables / events marked done by actions).
	var set_flags := {}
	var set_vars := {}
	var marked_events := {}
	for c in graph.cells:
		for a in c.actions:
			match a.kind:
				StoryAction.Kind.SET_FLAG, StoryAction.Kind.CLEAR_FLAG:
					set_flags[a.target] = true
				StoryAction.Kind.SET_VARIABLE, StoryAction.Kind.ADD_VARIABLE:
					set_vars[a.target] = true
				StoryAction.Kind.MARK_COMPLETED:
					marked_events[a.target] = true
	var known_flags := set_flags.duplicate()
	for f in graph.flags:
		known_flags[f] = true
	var known_vars := set_vars.duplicate()
	for v: Variant in graph.variables:
		known_vars[str(v)] = true
	var var_names: PackedStringArray = []
	for v: String in known_vars:
		if v.is_valid_identifier():
			var_names.append(v)
	var used_flags := {}
	var used_vars := {}

	# --- per cell: outputs, conditions, actions -----------------------------------------
	var edges := {}           # id -> Array of target ids (valid connections only)
	var incoming := {}        # id -> count
	for c in graph.cells:
		if not by_id.has(c.id) or by_id[c.id] != c:
			continue
		var outs: Array = []
		if c.type == StoryCell.Type.END and not c.outputs.is_empty():
			err.call(c.id, "End cells can't have outputs (remove them or change the type).")
		if c.type == StoryCell.Type.CHOICE and c.outputs.is_empty():
			err.call(c.id, "This choice has no options.")
		if c.type == StoryCell.Type.CONDITION:
			if c.outputs.is_empty():
				err.call(c.id, "This condition has no branches.")
			elif c.outputs.all(func(o: StoryOutput) -> bool: return o.has_condition()):
				warn.call(c.id, "No Else branch: if no condition passes, the story gets stuck here.")
		if c.type != StoryCell.Type.END and c.outputs.is_empty() and c.type != StoryCell.Type.CHOICE and c.type != StoryCell.Type.CONDITION:
			warn.call(c.id, "Dead end: this cell leads nowhere and isn't an End.")
		for i in c.outputs.size():
			var o := c.outputs[i]
			var oname := "\"%s\"" % o.label if o.label != "" else "Output %d" % (i + 1)
			if c.type == StoryCell.Type.CHOICE and o.label.strip_edges() == "":
				warn.call(c.id, "Option %d has no text." % (i + 1))
			if o.target_id == "":
				if c.type != StoryCell.Type.END:
					warn.call(c.id, "%s isn't connected to anything (dead end)." % oname)
			elif not by_id.has(o.target_id):
				err.call(c.id, "%s connects to \"%s\", which doesn't exist." % [oname, o.target_id])
			else:
				var t: StoryCell = by_id[o.target_id]
				if t.type == StoryCell.Type.START:
					err.call(c.id, "%s connects into Start cell \"%s\"; Start cells can't have inputs." % [oname, t.id])
				else:
					outs.append(t.id)
					incoming[t.id] = int(incoming.get(t.id, 0)) + 1
			if o.has_condition():
				_check_condition(o.condition, c.id, "Condition of %s" % oname, by_id, known_flags, known_vars,
					var_names, used_flags, used_vars, false, issues)
		edges[c.id] = outs
		if c.has_prerequisites():
			_check_condition(c.prerequisites, c.id, "Prerequisite", by_id, known_flags, known_vars,
				var_names, used_flags, used_vars, true, issues)
		for a in c.actions:
			if a.target.strip_edges() == "":
				err.call(c.id, "Action \"%s\" has no name." % StoryAction.KIND_NAMES[a.kind])
			elif (a.kind == StoryAction.Kind.MARK_COMPLETED or a.kind == StoryAction.Kind.RESET_EVENT) and not by_id.has(a.target):
				err.call(c.id, "Action \"%s\" refers to missing cell \"%s\"." % [a.describe(), a.target])
			elif a.kind == StoryAction.Kind.ADD_VARIABLE and not (StoryCondition.parse_value(a.value) is int or StoryCondition.parse_value(a.value) is float):
				err.call(c.id, "Action \"%s\" must add a number." % a.describe())
		if c.type == StoryCell.Type.DIALOGUE and c.text.strip_edges() == "":
			info.call(c.id, "This dialogue has no text.")

	# --- connectivity ------------------------------------------------------------------
	var roots: Array[String] = []
	for c in starts:
		if by_id.get(c.id) == c:
			roots.append(c.id)
	for id in ids:
		var c: StoryCell = by_id[id]
		if c.type != StoryCell.Type.START and not incoming.has(id) and c.has_prerequisites():
			roots.append(id)  # triggerable event
	var reach := _reach(roots, edges)
	for id in ids:
		var c: StoryCell = by_id[id]
		if c.type == StoryCell.Type.START:
			continue
		var has_in := incoming.has(id)
		var has_out := not (edges[id] as Array).is_empty()
		if not has_in and not has_out and not c.has_prerequisites():
			warn.call(id, "Disconnected: nothing leads here and it leads nowhere.")
		elif not has_in and not c.has_prerequisites():
			warn.call(id, "Nothing leads to this cell, so it can never happen (connect it, or give it prerequisites to make it a triggerable event).")
		elif not has_in:
			info.call(id, "Triggerable event: the game starts it when its prerequisites are met.")
		elif not reach.has(id):
			warn.call(id, "Unreachable: no path from any Start cell or event leads here.")
	for s in roots:
		if (by_id[s] as StoryCell).type != StoryCell.Type.START:
			continue
		var r := _reach([s], edges)
		if not r.keys().any(func(k: String) -> bool: return (by_id[k] as StoryCell).type == StoryCell.Type.END):
			warn.call(s, "No End can be reached from this Start.")

	# --- loops --------------------------------------------------------------------------
	for comp: Array in _sccs(ids, edges):
		var looped := comp.size() > 1 or (edges[comp[0]] as Array).has(comp[0])
		if not looped:
			continue
		var in_comp := {}
		for id: String in comp:
			in_comp[id] = true
		var exits := false
		var steered := false
		for id: String in comp:
			var c: StoryCell = by_id[id]
			if c.type == StoryCell.Type.CHOICE or c.type == StoryCell.Type.CONDITION or not c.repeatable or c.has_prerequisites():
				steered = true
			for o in c.outputs:
				if o.has_condition():
					steered = true
			for t: String in edges[id]:
				if not in_comp.has(t):
					exits = true
		var names := ", ".join(PackedStringArray(comp.map(func(x: String) -> String: return "\"%s\"" % x)))
		if not exits:
			err.call(comp[0], "Endless loop: %s only lead to each other, with no way out." % names)
		elif not steered:
			err.call(comp[0], "Loop through %s has no choice, condition or one-time cell, so the story would cycle forever." % names)

	# --- prerequisites ------------------------------------------------------------------
	var pre_edges := {}
	for id in ids:
		var c: StoryCell = by_id[id]
		var req: Array = []
		if c.has_prerequisites():
			for r in c.prerequisites.required_events():
				if by_id.has(r):
					req.append(r)
		pre_edges[id] = req
	for comp: Array in _sccs(ids, pre_edges):
		if comp.size() > 1:
			err.call(comp[0], "Circular prerequisites: %s each require the other, so none can happen." %
				", ".join(PackedStringArray(comp.map(func(x: String) -> String: return "\"%s\"" % x))))
	for id in ids:
		var needs: Array = pre_edges[id]
		if needs.is_empty():
			continue
		var without := _reach(roots.filter(func(r: String) -> bool: return r != id), edges, id)
		for r: String in needs:
			if r == id or marked_events.has(r):
				continue
			if not reach.has(r) and incoming.has(r):
				warn.call(id, "Requires \"%s\", which can never be reached." % r)
			elif reach.has(r) and not without.has(r):
				err.call(id, "Requires \"%s\", but \"%s\" can only be reached by going through this cell." % [r, r])

	# --- declarations -------------------------------------------------------------------
	for f: String in used_flags:
		if not known_flags.has(f) and f != "":
			warn.call("", "Flag \"%s\" is checked but never declared or set." % f)
	for v: String in used_vars:
		if not known_vars.has(v) and v != "":
			warn.call("", "Variable \"%s\" is checked but never declared or set." % v)

	issues.sort_custom(func(a: Issue, b: Issue) -> bool: return a.severity < b.severity)
	return issues


static func _check_condition(cond: StoryCondition, cell_id: String, what: String, by_id: Dictionary,
		known_flags: Dictionary, known_vars: Dictionary, var_names: PackedStringArray,
		used_flags: Dictionary, used_vars: Dictionary, is_prereq: bool, issues: Array[Issue]) -> void:
	match cond.kind:
		StoryCondition.Kind.ALL, StoryCondition.Kind.ANY, StoryCondition.Kind.NOT:
			if cond.children.is_empty() and cond.kind != StoryCondition.Kind.ALL:
				issues.append(Issue.new(Severity.WARNING, cell_id, "%s has an empty %s group." % [what, StoryCondition.KIND_NAMES[cond.kind]]))
			for c in cond.children:
				if c:
					_check_condition(c, cell_id, what, by_id, known_flags, known_vars, var_names, used_flags, used_vars, is_prereq, issues)
		StoryCondition.Kind.COMPLETED, StoryCondition.Kind.NOT_COMPLETED:
			if cond.target == "":
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s doesn't say which event." % what))
			elif not by_id.has(cond.target):
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s refers to missing event \"%s\"." % [what, cond.target]))
			elif cond.target == cell_id and is_prereq and cond.kind == StoryCondition.Kind.COMPLETED:
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s requires this cell itself to be completed first." % what))
		StoryCondition.Kind.FLAG_SET, StoryCondition.Kind.FLAG_NOT_SET:
			if cond.target == "":
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s has no flag name." % what))
			used_flags[cond.target] = true
		StoryCondition.Kind.VARIABLE:
			if cond.target == "":
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s has no variable name." % what))
			if not StoryCondition.OPS.has(cond.op):
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s uses unknown operator \"%s\"." % [what, cond.op]))
			used_vars[cond.target] = true
		StoryCondition.Kind.EXPRESSION:
			var e := StoryState.expression_error(cond.expression, var_names)
			if e != "":
				issues.append(Issue.new(Severity.ERROR, cell_id, "%s: expression error (%s)." % [what, e]))


## Ids reachable from roots along edges, never entering `blocked`.
static func _reach(roots: Array, edges: Dictionary, blocked := "") -> Dictionary:
	var seen := {}
	var stack: Array = []
	for r: String in roots:
		if r != blocked and not seen.has(r):
			seen[r] = true
			stack.append(r)
	while not stack.is_empty():
		var id: String = stack.pop_back()
		for t: String in edges.get(id, []):
			if t != blocked and not seen.has(t):
				seen[t] = true
				stack.append(t)
	return seen


## Strongly connected components (Kosaraju, iterative so large stories don't overflow).
static func _sccs(ids: Array[String], edges: Dictionary) -> Array:
	var order: Array[String] = []
	var visited := {}
	for s in ids:
		if visited.has(s):
			continue
		visited[s] = true
		var stack: Array = [[s, 0]]
		while not stack.is_empty():
			var top: Array = stack[-1]
			var nbrs: Array = edges.get(top[0], [])
			if int(top[1]) < nbrs.size():
				var n: String = nbrs[top[1]]
				top[1] = int(top[1]) + 1
				if not visited.has(n) and edges.has(n):
					visited[n] = true
					stack.append([n, 0])
			else:
				order.append(top[0])
				stack.pop_back()
	var rev := {}
	for a in ids:
		for b: String in edges.get(a, []):
			if not rev.has(b):
				rev[b] = []
			(rev[b] as Array).append(a)
	var assigned := {}
	var result: Array = []
	for i in range(order.size() - 1, -1, -1):
		var s := order[i]
		if assigned.has(s):
			continue
		assigned[s] = true
		var comp: Array = []
		var st: Array = [s]
		while not st.is_empty():
			var x: String = st.pop_back()
			comp.append(x)
			for y: String in rev.get(x, []):
				if not assigned.has(y):
					assigned[y] = true
					st.append(y)
		result.append(comp)
	return result
