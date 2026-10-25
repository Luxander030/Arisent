extends TestCase
## Story Graph plugin: conditions, the runner, the validator, saving/loading, and the
## editor panel (graph view, connections, undo, inspector, simulator) driven headlessly.

const Example := preload("res://addons/story_graph/examples/make_example_story.gd")
const StoryEditor := preload("res://addons/story_graph/editor/story_editor.gd")
const K := StoryCondition.Kind


func _state(vars := {}, flags: Array = [], done: Array = []) -> StoryState:
	var s := StoryState.new()
	s.variables = vars.duplicate()
	for f: String in flags:
		s.set_flag(f)
	for d: String in done:
		s.mark_completed(d)
	return s


func _issues_text(g: StoryGraph) -> String:
	return "\n".join(StoryValidator.validate(g).map(func(i: StoryValidator.Issue) -> String: return str(i)))


func _has_issue(g: StoryGraph, severity: int, cell_id: String, fragment: String) -> bool:
	for i in StoryValidator.validate(g):
		if i.severity == severity and i.cell_id == cell_id and i.message.contains(fragment):
			return true
	return false


# --- conditions -----------------------------------------------------------------------------

func test_condition_logic() -> void:
	var s := _state({"gold": 12, "name": "Lux"}, ["brave"], ["intro"])
	check(StoryCondition.make(K.COMPLETED, "intro").evaluate(s), "completed")
	check(StoryCondition.make(K.NOT_COMPLETED, "outro").evaluate(s), "not completed")
	check(StoryCondition.make(K.FLAG_SET, "brave").evaluate(s), "flag set")
	check(StoryCondition.make(K.FLAG_NOT_SET, "coward").evaluate(s), "flag not set")
	check(StoryCondition.make(K.VARIABLE, "gold", ">=", "10").evaluate(s), "gold >= 10")
	check(not StoryCondition.make(K.VARIABLE, "gold", "<", "10").evaluate(s), "gold < 10 is false")
	check(StoryCondition.make(K.VARIABLE, "name", "==", "Lux").evaluate(s), "string compare")
	check(StoryCondition.make(K.VARIABLE, "missing", "==", "0").evaluate(s), "missing variable counts as 0")
	var and_ := StoryCondition.group(K.ALL, [StoryCondition.make(K.FLAG_SET, "brave"), StoryCondition.make(K.COMPLETED, "nope")])
	var or_ := StoryCondition.group(K.ANY, [StoryCondition.make(K.FLAG_SET, "brave"), StoryCondition.make(K.COMPLETED, "nope")])
	var not_ := StoryCondition.group(K.NOT, [StoryCondition.make(K.COMPLETED, "nope")])
	check(not and_.evaluate(s) and or_.evaluate(s) and not_.evaluate(s), "AND / OR / NOT groups")
	var e := StoryCondition.make(K.EXPRESSION)
	e.expression = "gold > 10 and done(\"intro\") and flag(\"brave\") and times(\"intro\") == 1"
	check(e.evaluate(s), "expression with helpers")
	e.expression = "gold >"
	check(not e.evaluate(s), "broken expression is false")
	eq(and_.describe(), "(flag brave AND done(nope))", "describe")


func test_parse_value() -> void:
	eq(StoryCondition.parse_value("12"), 12, "int")
	eq(StoryCondition.parse_value("1.5"), 1.5, "float")
	eq(StoryCondition.parse_value("true"), true, "bool")
	eq(StoryCondition.parse_value("\"7\""), "7", "quoted string")
	eq(StoryCondition.parse_value("hello"), "hello", "string")


# --- runner ---------------------------------------------------------------------------------

func test_runner_plays_example_to_hero_ending() -> void:
	var g := Example.build()
	var r := StoryRunner.new(g)
	var lines: Array[String] = []
	var events: Array[String] = []
	r.dialogue.connect(func(_c: StoryCell, sp: String, t: String) -> void: lines.append("%s|%s" % [sp, t]))
	r.game_event.connect(func(n: String, p: String) -> void: events.append(n + ":" + p))
	check(r.start(), "starts")
	eq(r.current.id, "greet", "start runs into the greeting")
	check(r.state.has_flag("met_innkeeper"), "greeting action set a flag")
	r.advance()
	eq(r.status, StoryRunner.Status.WAITING_CHOICE, "waits at the main menu")
	check(lines.has("|You have 15 gold. What do you say?"), "prompt interpolates {gold}")
	var labels := r.get_choices().map(func(c: Dictionary) -> String: return "%s=%s" % [c.label, c.open])
	eq(labels, ["I'm looking for work.=true", "A drink, please. (10 gold)=true", "What's down in the cellar?=false",
		"Head down to the cellar.=false", "Leave the tavern.=true"], "choices and availability")
	check(not r.choose(3), "can't pick the cellar before taking the job")
	r.choose(1)  # drink: gold 15 -> 5, reputation 1
	eq(r.state.get_var("gold"), 5, "paid for the drink")
	r.advance()
	check(not r.get_choices()[1].open, "can't afford a second drink")
	r.choose(0)  # job offer
	check(lines.back().contains("20 gold"), "job offer interpolates {reward}")
	r.advance()
	r.choose(0)  # Deal -> accept (reputation 2, key)
	eq(events, ["quest_started:cellar_rats"], "game event emitted")
	r.advance()  # key -> main menu
	var ch := r.get_choices()
	check(ch[2].open and ch[3].open, "rumour and cellar unlocked")
	r.choose(2)
	r.advance()
	check(not r.get_choices()[2].open, "one-time rumour is closed afterwards")
	r.choose(3)  # cellar: prerequisites (job AND (key OR rep>=3)) pass
	eq(r.current.id, "cellar", "entered the cellar")
	r.advance()  # Condition: reputation >= 2 -> win
	eq(r.current.id, "win", "expression branch picked")
	r.advance()
	check(r.is_finished() and r.end_reason == "ending" and r.current.id == "hero_ending", "hero ending")
	eq(r.state.get_var("gold"), 25, "reward paid")
	# The triggerable event becomes available afterwards, once.
	var avail := r.get_available_events().map(func(c: StoryCell) -> String: return c.id)
	eq(avail, ["night_ambush"], "ambush available after the hero ending")
	check(r.trigger("night_ambush") and r.current.id == "night_ambush", "event triggered")
	r.advance()
	check(r.is_finished() and r.current.id == "to_be_continued", "event chain ends")
	check(r.get_available_events().is_empty(), "one-time event gone")


func test_runner_condition_else_and_dead_end() -> void:
	var g := Example.build()
	var r := StoryRunner.new(g)
	r.start()
	r.state.set_var("reputation", 0)
	r.state.mark_completed("accept_job")
	r.state.set_flag("has_key")
	check(r.trigger("cellar"), "cellar can be entered with job + key")
	r.advance()
	eq(r.current.id, "lose", "Else branch when not strong")
	# Dead end: a dialogue with no outputs.
	var g2 := StoryGraph.new()
	var s := g2.add_cell(StoryCell.Type.START)
	var d := g2.add_cell(StoryCell.Type.DIALOGUE)
	d.outputs.clear()
	s.outputs[0].target_id = d.id
	var r2 := StoryRunner.new(g2)
	r2.start()
	r2.advance()
	check(r2.is_finished() and r2.end_reason == "dead end", "dead end reported")


func test_runner_stops_endless_auto_loop() -> void:
	var g := StoryGraph.new()
	var s := g.add_cell(StoryCell.Type.START)
	var a := g.add_cell(StoryCell.Type.ACTION)
	var b := g.add_cell(StoryCell.Type.ACTION)
	s.outputs[0].target_id = a.id
	a.outputs[0].target_id = b.id
	b.outputs[0].target_id = a.id
	var r := StoryRunner.new(g)
	r.start()
	check(r.is_finished() and r.end_reason == "loop", "runaway loop stopped (%s)" % r.end_reason)


func test_state_roundtrip() -> void:
	var s := _state({"gold": 3}, ["x"], ["a", "a"])
	var t := StoryState.new()
	t.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	check(t.has_flag("x") and t.times_completed("a") == 2 and int(t.get_var("gold")) == 3, "state survives JSON")


# --- validator ------------------------------------------------------------------------------

func test_example_story_is_clean() -> void:
	var issues := StoryValidator.validate(Example.build())
	var bad := issues.filter(func(i: StoryValidator.Issue) -> bool: return i.severity != StoryValidator.Severity.INFO)
	check(bad.is_empty(), "no errors or warnings:\n" + "\n".join(bad.map(func(i: StoryValidator.Issue) -> String: return str(i))))


func test_validator_finds_problems() -> void:
	var g := StoryGraph.new()
	check(_has_issue(g, 0, "", "no Start"), "no start")
	check(_has_issue(g, 0, "", "no End"), "no end")
	var s := g.add_cell(StoryCell.Type.START)
	var d := g.add_cell(StoryCell.Type.DIALOGUE)
	var lonely := g.add_cell(StoryCell.Type.DIALOGUE)
	lonely.outputs.clear()
	var orphan := g.add_cell(StoryCell.Type.DIALOGUE)
	var e := g.add_cell(StoryCell.Type.END)
	s.outputs[0].target_id = d.id
	d.outputs[0].target_id = "ghost"
	orphan.outputs[0].target_id = e.id
	check(_has_issue(g, 0, d.id, "doesn't exist"), "connection to missing cell")
	check(_has_issue(g, 1, lonely.id, "Disconnected"), "disconnected cell")
	check(_has_issue(g, 1, orphan.id, "Nothing leads to this cell"), "never-entered cell")
	check(_has_issue(g, 1, s.id, "No End can be reached"), "no reachable ending")
	d.outputs[0].target_id = s.id
	check(_has_issue(g, 0, d.id, "into Start cell"), "connection into a Start cell")
	d.outputs[0].target_id = ""
	check(_has_issue(g, 1, d.id, "isn't connected"), "dangling output")
	# Unreachable: x <-> y loop that nothing from the start reaches.
	var x := g.add_cell(StoryCell.Type.CHOICE)
	var y := g.add_cell(StoryCell.Type.DIALOGUE)
	x.outputs[0].target_id = y.id
	x.outputs[1].target_id = e.id
	y.outputs[0].target_id = x.id
	check(_has_issue(g, 1, x.id, "Unreachable") or _has_issue(g, 1, y.id, "Unreachable"), "unreachable loop")
	# Prerequisites: missing event, self, circular, impossible.
	d.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, "nowhere")])
	check(_has_issue(g, 0, d.id, "missing event \"nowhere\""), "missing prerequisite")
	d.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, d.id)])
	check(_has_issue(g, 0, d.id, "itself"), "self prerequisite")
	d.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, e.id)])
	d.outputs[0].target_id = e.id
	check(_has_issue(g, 0, d.id, "can only be reached by going through this cell"), "impossible prerequisite")
	e.prerequisites = null
	var p := g.add_cell(StoryCell.Type.DIALOGUE)
	var q := g.add_cell(StoryCell.Type.DIALOGUE)
	p.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, q.id)])
	q.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, p.id)])
	check(_has_issue(g, 0, p.id, "Circular prerequisites") or _has_issue(g, 0, q.id, "Circular prerequisites"), "circular prerequisites")
	# Endless loop without an exit, and one without any steering.
	var l1 := g.add_cell(StoryCell.Type.ACTION)
	var l2 := g.add_cell(StoryCell.Type.ACTION)
	l1.actions.clear()
	l2.actions.clear()
	l1.outputs[0].target_id = l2.id
	l2.outputs[0].target_id = l1.id
	check(_has_issue(g, 0, l1.id, "Endless loop") or _has_issue(g, 0, l2.id, "Endless loop"), "loop without exit")
	l2.outputs.append(StoryOutput.make("", e.id))
	check(_has_issue(g, 0, l1.id, "no choice, condition") or _has_issue(g, 0, l2.id, "no choice, condition"), "unsteered loop")
	# Bad types / data.
	e.outputs.append(StoryOutput.make("", d.id))
	check(_has_issue(g, 0, e.id, "End cells can't have outputs"), "End with outputs")
	var c := g.add_cell(StoryCell.Type.CONDITION)
	c.outputs.remove_at(1)
	check(_has_issue(g, 1, c.id, "No Else branch"), "condition without else")
	var ex := StoryCondition.make(K.EXPRESSION)
	ex.expression = "gold >"
	c.outputs[0].condition = ex
	check(_has_issue(g, 0, c.id, "expression error"), "expression syntax")
	c.outputs[0].condition = StoryCondition.make(K.FLAG_SET, "undeclared_flag")
	check(_has_issue(g, 1, "", "Flag \"undeclared_flag\""), "undeclared flag")
	var dup := g.add_cell(StoryCell.Type.END)
	dup.id = e.id
	check(_has_issue(g, 0, e.id, "Duplicate ID"), "duplicate id")


# --- saving / loading -------------------------------------------------------------------------

func test_resource_and_json_roundtrip() -> void:
	var g := Example.build()
	var path := "user://story_roundtrip_test.tres"
	eq(ResourceSaver.save(g, path), OK, "saves")
	var loaded: StoryGraph = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(loaded != null, "loads back as StoryGraph")
	if loaded:
		eq(loaded.to_dict(), g.to_dict(), "resource round trip keeps everything")
		check(loaded.get_cell("cellar").prerequisites.children[1].kind == K.ANY, "nested conditions kept")
	var j := StoryGraph.from_json(g.to_json())
	check(j != null and j.to_dict() == g.to_dict(), "JSON round trip")
	check(StoryGraph.from_json("{\"nope\": 1}") == null, "rejects non-story JSON")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var saved: StoryGraph = load("res://stories/example_story.tres")
	# Layout (cell positions, frame boxes) may be rearranged in the Story editor; content may not.
	check(saved != null and _without_layout(saved.to_dict()) == _without_layout(g.to_dict()), "res://stories/example_story.tres matches the generator (ignoring layout)")


func test_rename_updates_references() -> void:
	var g := Example.build()
	check(g.rename_cell("accept_job", "job_taken"), "renamed")
	check(not g.rename_cell("greet", "main_menu"), "can't take an existing id")
	eq(g.get_cell("take_job").outputs[0].target_id, "job_taken", "connection updated")
	eq(g.get_cell("take_job").outputs[0].condition.target, "job_taken", "output condition updated")
	eq(g.get_cell("cellar").prerequisites.children[0].target, "job_taken", "prerequisite updated")
	check(g.frames[0].cell_ids.has("job_taken") and not g.frames[0].cell_ids.has("accept_job"), "group updated")
	g.remove_cell("job_taken")
	eq(g.get_cell("take_job").outputs[0].target_id, "", "removing a cell clears links to it")
	check(not g.frames[0].cell_ids.has("job_taken"), "removing a cell removes it from its group")


# --- editor panel ------------------------------------------------------------------------------

## A graph dictionary minus where things sit on the canvas.
static func _without_layout(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)
	for c: Dictionary in out.get("cells", []):
		c.erase("position")
	for f: Dictionary in out.get("frames", []):
		f.erase("position")
		f.erase("size")
	return out


func _panel(g: StoryGraph) -> Variant:
	var p: Variant = StoryEditor.new()
	p.size = Vector2(1400, 900)
	Engine.get_main_loop().root.add_child(p)
	p.edit_graph(g)
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	return p


func _connections(p: Variant) -> int:
	return (p.graph_edit as GraphEdit).get_connection_list().size()


func test_editor_shows_story() -> void:
	var g := Example.build()
	var p: Variant = await _panel(g)
	var outputs := 0
	for c in g.cells:
		for o in c.outputs:
			if o.target_id != "":
				outputs += 1
	eq((p._nodes as Dictionary).size(), g.cells.size(), "one node per cell")
	eq(_connections(p), outputs, "one line per connected output")
	eq((p._frames as Dictionary).size(), 2, "groups shown")
	var main: GraphNode = p._nodes["main_menu"]
	eq(main.get_output_port_count(), 5, "choice has a port per option")
	eq(main.get_input_port_count(), 1, "one input")
	eq((p._nodes["start"] as GraphNode).get_input_port_count(), 0, "start has no input")
	check(not p.dirty, "freshly opened story is not dirty")
	p.queue_free()


func test_editor_connect_disconnect_undo() -> void:
	var g := Example.build()
	var p: Variant = await _panel(g)
	var n0 := _connections(p)
	var leave: GraphNode = p._nodes["leave"]
	var take: GraphNode = p._nodes["take_job"]
	# Reconnect "Not right now." (port 1) from main_menu to the leave ending.
	p._on_connection_request(take.name, 1, leave.name, 0)
	eq(g.get_cell("take_job").outputs[1].target_id, "leave", "connection request rewires the output")
	eq(_connections(p), n0, "still one line for that output")
	check(p.dirty, "dirty after an edit")
	p.undo()
	eq(g.get_cell("take_job").outputs[1].target_id, "main_menu", "undo restores")
	p.redo()
	eq(g.get_cell("take_job").outputs[1].target_id, "leave", "redo reapplies")
	take = p._nodes["take_job"]
	leave = p._nodes["leave"]
	p._on_disconnection_request(take.name, 1, leave.name, 0)
	eq(g.get_cell("take_job").outputs[1].target_id, "", "disconnected")
	eq(_connections(p), n0 - 1, "line removed")
	check(p.issues_for("take_job").size() > 0, "validator flags the dangling option")
	p.queue_free()


func test_editor_add_duplicate_delete_group() -> void:
	var g := StoryEditor.new_story()
	var p: Variant = await _panel(g)
	var start: GraphNode = p._nodes["start_1"]
	# Drag from the start's output into empty space and pick "Choice" from the menu.
	p._on_connection_to_empty(start.name, 0, Vector2(400, 400))
	p._on_popup_id(StoryCell.Type.CHOICE)
	var choice := g.get_cell("choice_1")
	check(choice != null, "choice created")
	eq(g.get_cell("start_1").outputs[0].target_id, "choice_1", "dragged connection lands on the new cell")
	eq(p.selected_ids(), ["choice_1"] as Array[String], "new cell selected")
	await Engine.get_main_loop().process_frame
	check(p.inspector.cell == choice, "inspector shows the new cell")
	p.add_output("choice_1")
	eq(choice.outputs.size(), 3, "+ Option adds an output")
	# Duplicate two cells: links between copies follow the copies.
	choice.outputs[0].target_id = "dialogue_1"
	p._rebuild(["choice_1", "dialogue_1"] as Array[String])
	p.duplicate_selection()
	var c2 := g.get_cell("choice_2")
	var d2 := g.get_cell("dialogue_2")
	check(c2 != null and d2 != null, "duplicated with fresh ids")
	if c2 and d2:
		eq(c2.outputs[0].target_id, "dialogue_2", "copied link points at the copy")
		eq(d2.outputs[0].target_id, "end_1", "link to an uncopied cell is kept")
		check(c2.position != choice.position, "copy is offset")
	# Group the copies, then delete one.
	p.group_selection()
	eq(g.frames.size(), 1, "group created")
	var members := Array(g.frames[0].cell_ids)
	members.sort()
	eq(members, ["choice_2", "dialogue_2"], "group members")
	p.delete_cells(["dialogue_2"])
	check(g.get_cell("dialogue_2") == null and c2.outputs[0].target_id == "", "deleted cell and links to it")
	eq(Array(g.frames[0].cell_ids), ["choice_2"], "removed from the group")
	p.undo()
	check(g.get_cell("dialogue_2") != null, "undo brings it back")
	p.queue_free()


func test_editor_inspector_rename_and_edit() -> void:
	var g := Example.build()
	var p: Variant = await _panel(g)
	p.focus_cell("greet")
	await Engine.get_main_loop().process_frame
	check(p.inspector.cell == g.get_cell("greet"), "inspector follows selection")
	check(p.rename_cell("greet", "hello"), "rename through the editor")
	eq(g.get_cell("start").outputs[0].target_id, "hello", "references follow")
	check((p._nodes as Dictionary).has("hello"), "node re-keyed")
	var hello := g.get_cell("hello")
	hello.text = "Changed text"
	p.cell_changed(hello, false)
	p.commit("Edit text")
	p.undo()
	eq(g.get_cell("hello").text, "Welcome, traveller! You look like someone who can handle a bit of trouble.", "text edit undone")
	p.undo()
	check(g.get_cell("greet") != null and g.get_cell("start").outputs[0].target_id == "greet", "rename undone")
	p.queue_free()


func test_editor_simulator() -> void:
	var g := Example.build()
	var p: Variant = await _panel(g)
	var sim: Variant = p.simulator
	sim.play("")
	eq(sim.runner.current.id, "greet", "simulator starts")
	eq(p._sim_current, "greet", "graph marks the current cell")
	sim.advance()
	eq(sim.runner.status, StoryRunner.Status.WAITING_CHOICE, "at the menu")
	eq((sim._choices as VBoxContainer).get_child_count(), 5, "one button per option")
	sim.choose(1)
	eq(sim.runner.state.get_var("gold"), 5, "drink bought in the simulator")
	sim.step_back()
	eq(sim.runner.state.get_var("gold"), 15, "step back restores the state")
	eq(sim.runner.current.id, "main_menu", "and the position")
	sim.choose(4)
	check(sim.runner.is_finished(), "left the tavern: ending")
	check((sim._log as RichTextLabel).get_parsed_text().contains("THE END"), "transcript shows the ending")
	p.simulate_from("cellar")
	check(sim.runner.is_finished() and sim.runner.end_reason == "blocked", "can't start at the cellar without its prerequisites")
	p.queue_free()
