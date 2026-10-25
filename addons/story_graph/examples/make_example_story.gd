extends SceneTree
## Builds res://stories/example_story.tres, a small tavern quest that uses every feature:
## choices (one hidden behind a condition, one that can only be picked once), a Condition
## cell with an Expression branch, AND/OR prerequisites, actions (flags, variables, game
## events), a triggerable event and several endings, organised into groups.
## Run: godot --headless --script res://addons/story_graph/examples/make_example_story.gd

const OUT := "res://stories/example_story.tres"


func _initialize() -> void:
	var g := build()
	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var err := ResourceSaver.save(g, OUT)
	print("saved %s (%s)" % [OUT, error_string(err)])
	for issue in StoryValidator.validate(g):
		print("  ", issue)
	quit(0 if err == OK else 1)


static func build() -> StoryGraph:
	var T := StoryCell.Type
	var K := StoryCondition.Kind
	var A := StoryAction.Kind
	var g := StoryGraph.new()
	g.title = "The Tavern Job"
	g.description = "Example story for the Story Graph plugin: a short quest in a village tavern."
	g.variables = {"gold": 15, "reputation": 0, "reward": 20}
	g.flags = PackedStringArray(["brave"])

	var cell := func(type: StoryCell.Type, id: String, title: String, pos: Vector2, speaker := "", text := "") -> StoryCell:
		var c := StoryCell.create(type, id, pos)
		c.title = title
		c.speaker = speaker
		c.text = text
		c.outputs.clear()
		c.actions.clear()
		g.cells.append(c)
		return c
	var link := func(from: StoryCell, to: StoryCell, label := "", cond: StoryCondition = null) -> void:
		from.outputs.append(StoryOutput.make(label, to.id, cond))

	var start: StoryCell = cell.call(T.START, "start", "Arrive at the tavern", Vector2(0, 160), "",
		"The player walks into the Rusty Tankard.")
	var greet: StoryCell = cell.call(T.DIALOGUE, "greet", "Greeting", Vector2(320, 160), "Innkeeper",
		"Welcome, traveller! You look like someone who can handle a bit of trouble.")
	greet.actions.append(StoryAction.make(A.SET_FLAG, "met_innkeeper"))
	var main: StoryCell = cell.call(T.CHOICE, "main_menu", "What now?", Vector2(680, 140), "",
		"You have {gold} gold. What do you say?")
	var job: StoryCell = cell.call(T.DIALOGUE, "job_offer", "Job offer", Vector2(1080, -120), "Innkeeper",
		"Rats in the cellar. Big ones. Clear them out and I'll pay you {reward} gold.")
	var take: StoryCell = cell.call(T.CHOICE, "take_job", "Take the job?", Vector2(1420, -120), "", "Take the job?")
	var accept: StoryCell = cell.call(T.ACTION, "accept_job", "Accept the job", Vector2(1760, -200))
	accept.actions.append(StoryAction.make(A.SET_FLAG, "job_accepted"))
	accept.actions.append(StoryAction.make(A.ADD_VARIABLE, "reputation", "1"))
	accept.actions.append(StoryAction.make(A.EMIT_EVENT, "quest_started", "cellar_rats"))
	accept.repeatable = false
	var key: StoryCell = cell.call(T.DIALOGUE, "give_key", "Cellar key", Vector2(2080, -200), "Innkeeper",
		"Here's the key. Mind the big one.")
	key.actions.append(StoryAction.make(A.SET_FLAG, "has_key"))
	var drink: StoryCell = cell.call(T.ACTION, "buy_drink", "Pay for a drink", Vector2(1080, 220))
	drink.actions.append(StoryAction.make(A.ADD_VARIABLE, "gold", "-10"))
	drink.actions.append(StoryAction.make(A.ADD_VARIABLE, "reputation", "1"))
	var drink_line: StoryCell = cell.call(T.DIALOGUE, "drink_line", "Drink", Vector2(1400, 220), "Innkeeper",
		"Here you go. Next one's on the house… maybe.")
	var rumor: StoryCell = cell.call(T.DIALOGUE, "cellar_rumor", "Rumour", Vector2(1080, 480), "Old drunk",
		"They say something bigger than rats lives down there.")
	rumor.repeatable = false
	rumor.notes = "One-time: once heard, the option is greyed out."
	var leave: StoryCell = cell.call(T.END, "leave", "Walk away", Vector2(1080, 700), "", "You walk out into the night.")

	var cellar: StoryCell = cell.call(T.DIALOGUE, "cellar", "The cellar", Vector2(1080, 1000), "",
		"The cellar is dark and smells of old wine. Something big moves behind the barrels.")
	cellar.prerequisites = StoryCondition.group(K.ALL, [
		StoryCondition.make(K.COMPLETED, "accept_job"),
		StoryCondition.group(K.ANY, [StoryCondition.make(K.FLAG_SET, "has_key"), StoryCondition.make(K.VARIABLE, "reputation", ">=", "3")]),
	])
	cellar.notes = "Needs the job AND (the key OR a good reputation)."
	var fight: StoryCell = cell.call(T.CONDITION, "fight", "Strong enough?", Vector2(1420, 1000))
	var win: StoryCell = cell.call(T.DIALOGUE, "win", "Victory", Vector2(1760, 920), "",
		"You drive the rats out. The innkeeper pays you {reward} gold.")
	win.actions.append(StoryAction.make(A.ADD_VARIABLE, "gold", "20"))
	var lose: StoryCell = cell.call(T.DIALOGUE, "lose", "Retreat", Vector2(1760, 1140), "",
		"The giant rat is too much. You scramble back up the stairs.")
	var hero: StoryCell = cell.call(T.END, "hero_ending", "Rat slayer", Vector2(2100, 920), "",
		"The village toasts the rat slayer.")
	var flee: StoryCell = cell.call(T.END, "flee_ending", "Cellar coward", Vector2(2100, 1140), "",
		"Nobody mentions the cellar again.")

	var ambush: StoryCell = cell.call(T.DIALOGUE, "night_ambush", "Night ambush (event)", Vector2(2460, 920), "Stranger",
		"So you're the one who killed our pet. Come with us.")
	ambush.prerequisites = StoryCondition.group(K.ALL, [StoryCondition.make(K.COMPLETED, "hero_ending")])
	ambush.repeatable = false
	ambush.notes = "Triggerable event: nothing leads here. The game triggers it once the hero ending happened."
	var cont: StoryCell = cell.call(T.END, "to_be_continued", "To be continued", Vector2(2800, 920), "", "To be continued…")

	link.call(start, greet)
	link.call(greet, main)
	link.call(main, job, "I'm looking for work.")
	link.call(main, drink, "A drink, please. (10 gold)", StoryCondition.make(K.VARIABLE, "gold", ">=", "10"))
	link.call(main, rumor, "What's down in the cellar?", StoryCondition.make(K.COMPLETED, "job_offer"))
	link.call(main, cellar, "Head down to the cellar.")
	link.call(main, leave, "Leave the tavern.")
	link.call(job, take)
	link.call(take, accept, "Deal.", StoryCondition.make(K.NOT_COMPLETED, "accept_job"))
	link.call(take, main, "Not right now.")
	link.call(accept, key)
	link.call(key, main)
	link.call(drink, drink_line)
	link.call(drink_line, main)
	link.call(rumor, main)
	link.call(cellar, fight)
	var strong := StoryCondition.make(K.EXPRESSION)
	strong.expression = "reputation >= 2 or flag(\"brave\")"
	link.call(fight, win, "Strong", strong)
	link.call(fight, lose, "Else")
	link.call(win, hero)
	link.call(lose, flee)
	link.call(ambush, cont)

	var group := func(id: String, title: String, ids: Array[String], color: Color) -> void:
		var f := StoryFrame.new()
		f.id = id
		f.title = title
		f.cell_ids = PackedStringArray(ids)
		f.color = color
		var rect := Rect2()
		var first := true
		for cid in ids:
			var r := Rect2(g.get_cell(cid).position, Vector2(260, 140))
			rect = r if first else rect.merge(r)
			first = false
		f.position = rect.position - Vector2(30, 60)
		f.size = rect.size + Vector2(60, 90)
		g.frames.append(f)
	group.call("group_1", "Tavern", ["greet", "main_menu", "job_offer", "take_job", "accept_job", "give_key",
		"buy_drink", "drink_line", "cellar_rumor"] as Array[String], Color(0.55, 0.4, 0.2, 0.5))
	group.call("group_2", "Cellar", ["cellar", "fight", "win", "lose"] as Array[String], Color(0.3, 0.3, 0.55, 0.5))
	return g
