## Skill tree: reading the project's tree file, prerequisites (any learned parent unlocks),
## points from levels, learning by id, saving and loading by id, refunds when the tree
## changes, and the screen (click to learn).
extends TestCase


func _tree() -> SkillTree:
	return SkillTree.from_dict({"format": "skill-tree", "version": 1, "name": "T", "nodes": [
		{"id": "root", "name": "Strike", "x": 0, "y": 0, "cost": 1, "maxRank": 2, "connections": ["a", "b"]},
		{"id": "a", "name": "Left", "x": -100, "y": -100, "cost": 1, "maxRank": 1, "connections": ["top"]},
		{"id": "b", "name": "Right", "x": 100, "y": -100, "cost": 2, "maxRank": 1, "connections": ["top"]},
		{"id": "top", "name": "Top", "x": 0, "y": -200, "cost": 3, "maxRank": 1, "shape": "diamond", "connections": []},
	]})


func test_project_tree_loads() -> void:
	var t := SkillTree.reload_project()
	eq(t.errors, [] as Array[String], "no problems in %s" % t.path)
	eq(t.name, "Arisent-DEMO", "name")
	eq(t.order.size(), 63, "every node")
	eq(Array(t.roots()), ["ME-001"], "Strike is the one root")
	var n := t.node("ME-002")
	check(n.name == "Charged Strike" and n.cost == 1 and n.max_rank == 10 and n.category == "melee" and n.shape == "circle", "node fields")
	eq(t.parents["M-001"], ["ME-004-2", "ME-004-1"], "parents from connections")
	check(t.total_cost() > 0 and t.categories().has("fire"), "costs and categories")
	var id_form := RegEx.create_from_string("^(ME|M|F|O|N|W)-\\d{3}(-(\\d|U))?$")
	for id in t.order:
		check(id_form.search(id) != null, "id %s follows the BRANCH-NNN[-n|-U] pattern" % id)
		check(not str(t.nodes[id].name).contains("placeholder"), "%s has a real name" % id)
	eq(t.parents["N-000"], ["N-001"], "Growth (N-000) hangs off Nature's Blessing")


func test_reading_rejects_and_reports() -> void:
	check(not SkillTree.from_dict({"format": "other", "version": 1}).errors.is_empty(), "other formats refused")
	check(SkillTree.from_dict({"format": "skill-tree", "version": 2}).errors[0].contains("version 2"), "other versions refused (no migrations)")
	var t := SkillTree.from_dict({"format": "skill-tree", "version": 1, "nodes": [
		{"id": "x", "connections": ["ghost"]}, {"id": "x"}, {"name": "no id"}, {"id": "y", "maxRank": 0, "cost": -3, "shape": "hexagon"}]})
	eq(t.order, ["x", "y"] as Array[String], "bad entries skipped")
	eq(t.errors.size(), 3, "dangling connection, duplicate id, missing id reported")
	check(t.node("y").max_rank == 1 and t.node("y").cost == 0 and t.node("y").shape == "circle", "values clamped")
	eq(Array(SkillTree.load_file("res://nope.json").errors), ["file not found"], "missing file")


func test_learning_rules() -> void:
	var t := _tree()
	var p := PlayerProgress.new()
	eq(p.skill_points(t), 0, "level 1 has no points")
	check(p.learn(t, "root").contains("needs 1 skill point"), "no points")
	p.xp = PlayerProgress.xp_for(3)
	eq(p.skill_points(t), 2 * PlayerProgress.SKILL_POINTS_PER_LEVEL, "points per level after the first")
	check(p.learn(t, "a") == "Learn Strike first.", "locked until a prerequisite is learned")
	check(p.learn(t, "nope").begins_with("There is no skill"), "unknown id")
	eq(p.learn(t, "root"), "", "learn the root")
	eq(p.learn(t, "root"), "", "second rank")
	check(p.learn(t, "root").contains("mastered"), "max rank")
	eq(p.learn(t, "a"), "", "its one prerequisite learned: open")
	eq(p.skill_points(t), 1, "4 − 3 spent")
	eq(p.learn(t, "top"), "Learn Right first.", "a node reached from two skills needs both (names only the missing one)")
	check(not t.is_unlocked(p.tree_ranks, "top"), "still locked with one of two")
	check(p.learn(t, "b").contains("needs 2 skill points (you have 1)"), "cost per rank")
	p.bonus_points = 5
	eq(p.learn(t, "b"), "", "learn the second prerequisite")
	eq(p.learn(t, "top"), "", "both learned: open")
	eq(p.skill_points(t), 1, "9 − 8 spent")
	p.reset_tree()
	eq(p.learn(t, "top"), "Learn Left and Right first.", "both missing are named")
	check(p.tree_ranks.is_empty() and p.skill_points(t) == 9, "reset refunds")


func test_saved_by_id() -> void:
	var t := _tree()
	var p := PlayerProgress.new()
	p.xp = PlayerProgress.xp_for(5)
	p.learn(t, "root")
	p.learn(t, "b")
	var d := p.to_dict()
	eq(d.tree, {"root": 1, "b": 1}, "ranks keyed by node id, not name")
	var bytes := var_to_bytes(d)
	var q := PlayerProgress.new()
	q.from_dict(bytes_to_var(bytes))
	eq(q.tree_ranks, {"root": 1, "b": 1}, "round trip")
	eq(q.skill_points(t), p.skill_points(t), "points follow")
	q.from_dict({"xp": 0})
	check(q.tree_ranks.is_empty() and q.bonus_points == 0, "saves from before the tree load empty")
	# The tree changed since the save: unknown ids and too-high ranks give their points back.
	var r := {"root": 5, "gone": 3, "b": 1}
	eq(Array(t.sanitize(r)), ["root", "gone"], "changed ids reported")
	eq(r, {"root": 2, "b": 1}, "clamped and dropped")


func test_game_save_keeps_tree() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var g := GameSession.new()
	root.add_child(g)
	g.progress.xp = PlayerProgress.xp_for(4)
	check(g.console.run("skilltree learn ME-001 2").begins_with("Learned 2 ranks of Strike"), "console learns like the player")
	check(g.console.run("skilltree learn ME-002").contains("Charged Strike"), "next node unlocked")
	check(g.console.run("skilltree learn F-001").begins_with("Learn Magical Reserves first."), "console respects prerequisites")
	# The project's example: Magical Reserves (M-001) is reached from Unbounded Counter
	# (ME-004-1) and Charged Spin Attack (ME-004-2) and needs both.
	var t := SkillTree.project()
	eq(Array(t.missing({"ME-004-1": 1}, "M-001")), ["ME-004-2"], "M-001 with only ME-004-1 still needs ME-004-2")
	check(t.is_unlocked({"ME-004-1": 1, "ME-004-2": 1}, "M-001"), "M-001 opens with both")
	var saved := g.to_save()
	g.queue_free()
	var h := GameSession.new()
	root.add_child(h)
	saved.progress.tree["OLD-ID"] = 2
	h.apply_save(saved)
	eq(h.progress.tree_ranks, {"ME-001": 2, "ME-002": 1}, "restored by id; unknown ids dropped")
	eq(h.progress.skill_points(SkillTree.project()), 6 - 3, "points recomputed")
	h.queue_free()


func test_panel_click_learns() -> void:
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var p := PlayerProgress.new()
	p.bonus_points = 1
	var panel := SkillTreePanel.new()
	panel.progress = p
	panel.tree = _tree()
	panel.size = Vector2(1000, 700)
	root.add_child(panel)
	panel.open()
	panel.size = Vector2(1000, 700)
	panel.center = Vector2(0, -100)
	panel.zoom = 1.0
	var at := panel.to_screen(Vector2.ZERO)
	eq(panel.node_at(at), "root", "hit test")
	eq(panel.state_of("root"), "affordable", "root affordable")
	eq(panel.state_of("a"), "locked", "child locked")
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = at
		panel._gui_input(e)
	eq(p.tree_rank("root"), 1, "click learned a rank")
	eq(panel.state_of("a"), "available", "child now open (not affordable)")
	var m := InputEventMouseMotion.new()
	m.position = panel.to_screen(Vector2(-100, -100))
	m.relative = Vector2.ZERO
	panel._gui_input(m)
	check(panel.hover == "a" and panel._tip.visible and panel._tip_text.text.contains("needs 1 skill point"), "tooltip explains")
	panel.queue_free()
