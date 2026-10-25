## Console commands of a play-through (they stay across map changes): time and the day,
## the story, the bag, experience and skills, loot, audio and the /content inspectors.
## World commands live in WorldSession, creature ones in NpcManager and SpawnDirector,
## player and save ones in the game host.
class_name GameCommands
extends RefCounted

const R := preload("res://world/debug/console/console_result.gd")
const P := preload("res://world/debug/console/console_parse.gd")
const NAMED_HOURS := {"midnight": 0.0, "dawn": 6.0, "morning": 8.0, "noon": 12.0, "afternoon": 15.0,
	"dusk": 19.0, "evening": 20.0, "night": 22.0}

var game: GameSession


static func register(g: GameSession) -> GameCommands:
	var gc := GameCommands.new()
	gc.game = g
	gc._register(g.console)
	return gc


func _register(c: DebugConsole) -> void:
	var g := game
	c.verbs("time", "The in-game clock and the length of a day.", g) \
		.verb("show", "The time of day, its phase and play time.", _time_show) \
		.verb("set", "Sets the time of day (timers are not affected).", _time_set, 1, 1, "/time set <hh:mm|hours|noon|dusk|…>",
			P.hints_of(NAMED_HOURS.keys())) \
		.verb("add", "Moves the clock forward (or back with a minus) without passing time.", _time_add, 1, 1, "/time add <hours>") \
		.verb("day", "Sets the day number (day 1 is the first).", _time_day, 1, 1, "/time day <n>") \
		.verb("length", "Shows or sets how many real minutes a day lasts (default 48).", _time_length, 0, 1, "/time length [minutes]",
			P.hints_of(["24", "48", "96"]))
	c.command("skip", "Lets time pass: respawns, expiry and the day all advance.", "/skip <hours>", _skip, 1, 1,
		P.hints_of(["0.5", "1", "6", "24"]), g)
	c.verbs("timescale", "Speeds up or slows down play time (world) or the whole engine.", g) \
		.verb("show", "Both scales.", _ts_show) \
		.verb("world", "Play time only: the day, respawns and timers; physics stay real-time.", _ts_world, 1, 1, "/timescale world <x>",
			P.hints_of(["0", "0.5", "1", "2", "10", "60"])) \
		.verb("engine", "Everything (physics, animation, AI) via Engine.time_scale.", _ts_engine, 1, 1, "/timescale engine <x>",
			P.hints_of(["0.1", "0.25", "0.5", "1", "2"]))
	c.verbs("story", "The story graph: events, what is done, and running them.", g) \
		.verb("list", "Every event with how often it was completed.", _story_list) \
		.verb("show", "One event: its text, prerequisites and outputs.", _story_show, 1, 1, "/story show <event>", P.hints_of(_cell_ids)) \
		.verb("trigger", "Fires an event as the game would (dialogue goes to the feed).", _story_trigger, 1, 1, "/story trigger <event>", P.hints_of(_cell_ids)) \
		.verb("complete", "Marks an event completed without running it.", _story_complete, 1, 1, "/story complete <event>", P.hints_of(_cell_ids)) \
		.verb("reset", "Forgets all story progress, flags and variables.", _story_reset)
	c.command("flag", "Shows story flags, or one, or sets one.", "/flag [name] [on|off]", _flag, 0, 2,
		P.hints_by_position([func() -> Array: return game.story_state.flags.keys(), ["on", "off"]]), g)
	c.command("var", "Shows story variables, or one, or sets one (numbers, true/false or text).", "/var [name] [value]", _var, 0, 2,
		P.hints_by_position([func() -> Array: return game.story_state.variables.keys()]), g)
	c.command("give", "Puts items in your bag; #category gives one of each item in it.", "/give <item|#category> [count]", _give, 1, 2,
		P.hints_by_position([_item_and_tag_ids]), g)
	c.command("take", "Takes items out of your bag (all of them without a count).", "/take <item|#category|all> [count]", _take, 1, 2,
		P.hints_by_position([func() -> Array: return game.inventory.totals().keys() + _tags() + ["all"]]), g)
	c.verbs("inv", "Your bag.", g) \
		.verb("list", "What is in it (optionally only ids containing a word).", _inv_list, 0, 1, "/inv list [filter]") \
		.verb("clear", "Empties it.", _inv_clear)
	c.command("xp", "Shows experience, or adds some to you or to a skill.", "/xp [amount] [skill]", _xp, 0, 2,
		P.hints_by_position([null, func() -> Array: return game.progress.skills.keys()]), g)
	c.command("level", "Sets your character level (experience to match).", "/level <n>", _level, 1, 1, Callable(), g)
	c.verbs("skill", "Skill levels.", g) \
		.verb("list", "Every skill with its level and experience.", _skill_list) \
		.verb("set", "Sets a skill's level.", _skill_set, 2, 2, "/skill set <skill> <level>", P.hints_of(func() -> Array: return game.progress.skills.keys() + ["skinning", "gathering"])) \
		.verb("reset", "Forgets one skill or all of them.", _skill_reset, 0, 1, "/skill reset [skill]", P.hints_of(func() -> Array: return game.progress.skills.keys()))
	var node_ids := P.hints_of(func() -> Array: return SkillTree.project().order)
	c.verbs("skilltree", "The skill tree: points, learned skills (saved by id), cheats.", g) \
		.verb("show", "Free points, how they were earned, and what is learned.", _tree_show) \
		.verb("list", "Every skill (optionally one category) with its rank, cost and state.", _tree_list, 0, 1, "/skilltree list [category]",
			P.hints_of(func() -> Array: return Array(SkillTree.project().categories()))) \
		.verb("learn", "Learns ranks of a skill as the player would (needs points and a learned prerequisite).", _tree_learn, 1, 2,
			"/skilltree learn <id> [ranks]", node_ids) \
		.verb("set", "Sets a skill's rank directly, ignoring points and prerequisites.", _tree_set, 2, 2, "/skilltree set <id> <rank>", node_ids) \
		.verb("points", "Grants (or with a minus, takes) skill points.", _tree_points, 1, 1, "/skilltree points <n>") \
		.verb("reset", "Forgets every learned skill; all points come back.", _tree_reset) \
		.verb("reload", "Reads the skill tree file again (after editing it).", _tree_reload)
	c.verbs("loot", "Loot tables.", g) \
		.verb("tables", "Every loot table and its rows.", _loot_tables) \
		.verb("roll", "Rolls a table n times and counts what dropped (nothing is given).", _loot_roll, 1, 2, "/loot roll <table> [times]",
			P.hints_of(func() -> Array: return Defs.ids("loot_tables")))
	c.verbs("audio", "Sound: buses, volume, test sounds.", g) \
		.verb("status", "Every bus with its volume and whether it is muted.", _audio_status) \
		.verb("list", "The sounds /audio play knows.", _audio_list) \
		.verb("play", "Plays a sound (at the camera).", _audio_play, 1, 1, "/audio play <sound>", P.hints_of(_sound_names)) \
		.verb("volume", "Shows or sets a bus volume in dB, or as a percentage like 50%.", _audio_volume, 1, 2, "/audio volume <bus> [db|percent%]",
			P.hints_of(_bus_names)) \
		.verb("mute", "Mutes a bus (default Master).", _audio_mute.bind(true), 0, 1, "/audio mute [bus]", P.hints_of(_bus_names)) \
		.verb("unmute", "Unmutes a bus (default Master).", _audio_mute.bind(false), 0, 1, "/audio unmute [bus]", P.hints_of(_bus_names))
	var content := c.model.content
	content.verb("items", "Every item definition (optionally only ids containing a word).", _content_items, 0, 1, "/content items [filter]", Callable(), g)
	content.verb("creatures", "Every creature definition.", _content_creatures, 0, 1, "/content creatures [filter]", Callable(), g)
	content.verb("factions", "Factions and whom they are hostile to.", _content_factions, 0, 0, "", Callable(), g)
	content.verb("rules", "Ambient spawn rules per biome.", _content_rules, 0, 0, "", Callable(), g)
	content.verb("show", "One definition in full.", _content_show, 2, 2, "/content show <registry> <id>",
		P.hints_by_position([Defs.REGISTRIES, null]), g)
	content.verb("reload", "Reloads the JSON data files from disk.", _content_reload, 0, 0, "", Callable(), g)
	c.model.bars.add("game_time", ConsoleBars.Slot.TITLE_RIGHT, _bar_time, 500, g)
	c.model.bars.add("saves", ConsoleBars.Slot.STATUS_RIGHT, _bar_save, 10, g)


# --- bars ------------------------------------------------------------------------------------

func _bar_time() -> String:
	return "%s (%s)" % [game.time_of_day.label(), phase(game.time_of_day.hours)]


func _bar_save() -> String:
	if game.saves.busy():
		return "%s saving" % ConsoleBars.spinner()
	var ls := game.last_save
	if ls.is_empty():
		return ""
	if not ls.ok:
		return "save failed"
	if Time.get_ticks_msec() - int(ls.at) < 3000:
		return "saved in %s" % ConsoleBars.duration(float(ls.took))
	return ""


static func phase(h: float) -> String:
	if h >= 5.0 and h < 7.0:
		return "dawn"
	if h >= 7.0 and h < 18.0:
		return "day"
	if h >= 18.0 and h < 20.0:
		return "dusk"
	return "night"


# --- time ------------------------------------------------------------------------------------

func _time_show(_a: PackedStringArray) -> Variant:
	var t := game.time_of_day
	return "%s, %s. A day lasts %.0f real minutes; play time %s (world time ×%.2f)." % [
		t.label(), phase(t.hours), t.day_minutes, ConsoleBars.duration(game.clock.now), game.clock.scale]


## "14:30", "14.5", "noon" → hours, or -1.
static func parse_hours(s: String) -> float:
	var l := s.to_lower()
	if NAMED_HOURS.has(l):
		return NAMED_HOURS[l]
	if l.contains(":"):
		var hm := l.split(":")
		if hm.size() == 2 and hm[0].is_valid_int() and hm[1].is_valid_int():
			return hm[0].to_float() + hm[1].to_float() / 60.0
		return -1.0
	return l.to_float() if l.is_valid_float() else -1.0


func _time_set(a: PackedStringArray) -> Variant:
	var h := parse_hours(a[0])
	if h < 0.0 or h > 24.0:
		return R.failure("'%s' is not a time; use hh:mm, hours (0-24) or one of %s." % [a[0], ", ".join(NAMED_HOURS.keys())])
	game.time_of_day.set_hours(h)
	return "It is now %s (%s)." % [game.time_of_day.label(), phase(game.time_of_day.hours)]


func _time_add(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float():
		return R.failure("'%s' is not a number of hours." % a[0])
	game.time_of_day.add_hours(a[0].to_float())
	return "It is now %s (%s)." % [game.time_of_day.label(), phase(game.time_of_day.hours)]


func _time_day(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_int() or a[0].to_int() < 1:
		return R.failure("'%s' is not a day; days count from 1." % a[0])
	game.time_of_day.day = a[0].to_int() - 1
	return "It is now %s." % game.time_of_day.label()


func _time_length(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		if not a[0].is_valid_float() or a[0].to_float() < 1.0:
			return R.failure("'%s' is not a number of minutes (at least 1)." % a[0])
		game.time_of_day.day_minutes = a[0].to_float()
	return "A day lasts %.0f real minutes." % game.time_of_day.day_minutes


func _skip(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float() or a[0].to_float() <= 0.0:
		return R.failure("'%s' is not a number of hours." % a[0])
	var h := a[0].to_float()
	game.clock.skip(h * 3600.0)
	game.time_of_day.add_hours(h)
	game.last_skip = h * 3600.0
	if game.world:
		game.world.after_skip()
	return "%s passed. It is now %s." % [ConsoleBars.duration(h * 3600.0), game.time_of_day.label()]


func _ts_show(_a: PackedStringArray) -> Variant:
	return "World time ×%.2f (the day, respawns, timers). Engine time ×%.2f (everything)." % [game.clock.scale, Engine.time_scale]


func _ts_world(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float():
		return R.failure("'%s' is not a speed." % a[0])
	game.clock.scale = clampf(a[0].to_float(), 0.0, 1000.0)
	game.mark_dev()
	return "World time runs ×%.2f." % game.clock.scale


func _ts_engine(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float():
		return R.failure("'%s' is not a speed." % a[0])
	Engine.time_scale = clampf(a[0].to_float(), 0.0, 10.0)
	return "Everything runs ×%.2f." % Engine.time_scale


# --- story -----------------------------------------------------------------------------------

func _cell_ids() -> Array:
	var g := GameSession.story_graph()
	return g.index().keys() if g else []


func _story_list(_a: PackedStringArray) -> Variant:
	var graph := GameSession.story_graph()
	if graph == null:
		return R.failure("No story graph is configured (Project Settings → lux/story/graph_path).")
	var rows: Array = [["event", "type", "name", "done"]]
	var ids: Array = graph.index().keys()
	ids.sort()
	for id: String in ids:
		var cell := graph.get_cell(id)
		rows.append([id, StoryCell.Type.keys()[cell.type].to_lower(), cell.display_name(), game.story_state.times_completed(id)])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _story_show(a: PackedStringArray) -> Variant:
	var graph := GameSession.story_graph()
	var cell := graph.get_cell(a[0]) if graph else null
	if cell == null:
		return R.failure("No story event '%s'." % a[0])
	var d := cell.to_dict()
	var lines := PackedStringArray(["%s  (%s), completed %d time(s)" % [cell.id, StoryCell.Type.keys()[cell.type].to_lower(), game.story_state.times_completed(cell.id)]])
	for k: String in d:
		if k in ["id", "type", "pos", "size"]:
			continue
		lines.append("  %-14s %s" % [k, JSON.stringify(d[k])])
	return "\n".join(lines)


func _story_trigger(a: PackedStringArray) -> Variant:
	game.story_event(a[0])
	game.mark_dev()
	return null


func _story_complete(a: PackedStringArray) -> Variant:
	game.story_state.mark_completed(a[0])
	game.mark_dev()
	return "'%s' is completed (%d time(s))." % [a[0], game.story_state.times_completed(a[0])]


func _story_reset(_a: PackedStringArray) -> Variant:
	game.story_state.reset(GameSession.story_graph())
	game.mark_dev()
	return "Story progress, flags and variables are forgotten."


func _flag(a: PackedStringArray) -> Variant:
	var st := game.story_state
	if a.is_empty():
		return "No flags are set." if st.flags.is_empty() else "Flags: " + ", ".join(PackedStringArray(st.flags.keys()))
	if a.size() > 1:
		var f := P.flag(a[1])
		if f < 0:
			return R.failure("'%s' is not on or off." % a[1])
		st.set_flag(a[0], f == 1)
		game.mark_dev()
	return "%s is %s." % [a[0], "on" if st.has_flag(a[0]) else "off"]


func _var(a: PackedStringArray) -> Variant:
	var st := game.story_state
	if a.is_empty():
		if st.variables.is_empty():
			return "No story variables are set."
		var lines := PackedStringArray()
		for k: String in st.variables:
			lines.append("  %s = %s" % [k, var_to_str(st.variables[k])])
		return "\n".join(lines)
	if a.size() > 1:
		var v: Variant = a[1]
		if a[1].is_valid_int():
			v = a[1].to_int()
		elif a[1].is_valid_float():
			v = a[1].to_float()
		elif P.flag(a[1]) >= 0:
			v = P.flag(a[1]) == 1
		st.set_var(a[0], v)
		game.mark_dev()
	return "%s = %s" % [a[0], var_to_str(st.get_var(a[0]))]


# --- bag, experience -------------------------------------------------------------------------

func _tags() -> Array:
	var t := {}
	for d: Dictionary in Defs.all("items"):
		t["#" + str(d.get("category", "misc"))] = true
	return t.keys()


func _item_and_tag_ids() -> Array:
	return Array(Defs.ids("items")) + _tags()


## Item ids an argument means: one id, or every item of a #category.
func _items_of(arg: String) -> Array:
	if arg.begins_with("#"):
		var cat := arg.substr(1)
		return Defs.all("items").filter(func(d: Dictionary) -> bool: return str(d.get("category", "")) == cat).map(func(d: Dictionary) -> String: return str(d.id))
	return [arg] if Defs.has("items", arg) else []


func _give(a: PackedStringArray) -> Variant:
	var ids := _items_of(a[0])
	if ids.is_empty():
		var s := P.suggestions(_item_and_tag_ids(), a[0])
		return R.failure("No item or category '%s'.%s" % [a[0], " Did you mean %s?" % ", ".join(s) if not s.is_empty() else ""])
	var n := a[1].to_int() if a.size() > 1 else 1
	if n < 1:
		return R.failure("'%s' is not a count." % a[1])
	var parts := PackedStringArray()
	var short := 0
	for id: String in ids:
		var got := game.inventory.add(id, n)
		short += n - got
		if got > 0:
			parts.append("%d %s" % [got, Defs.get_def("items", id).get("name", id)])
	game.mark_dev()
	if parts.is_empty():
		return R.failure("Your bag is full.")
	return "Gave %s.%s" % [", ".join(parts), "  (%d did not fit.)" % short if short > 0 else ""]


func _take(a: PackedStringArray) -> Variant:
	var ids: Array = game.inventory.totals().keys() if a[0] == "all" else _items_of(a[0])
	if ids.is_empty():
		return R.failure("No item or category '%s'." % a[0])
	var n := 0
	for id: String in ids:
		n += game.inventory.remove(id, a[1].to_int() if a.size() > 1 else game.inventory.count_of(id))
	game.mark_dev()
	return "Took %d item%s." % [n, "" if n == 1 else "s"]


func _inv_list(a: PackedStringArray) -> Variant:
	var t := game.inventory.totals()
	var rows: Array = [["item", "name", "count", "category", "value"]]
	for k: String in t:
		if not a.is_empty() and not k.contains(a[0]):
			continue
		var d := Defs.get_def("items", k)
		rows.append([k, d.get("name", k), t[k], d.get("category", ""), int(d.get("value", 0)) * int(t[k])])
	if rows.size() == 1:
		return "Your bag is empty." if t.is_empty() else "Nothing matches '%s'." % a[0]
	return R.rich_text("%d of %d slots used.\n%s" % [game.inventory.stacks.size(), game.inventory.capacity,
		ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


func _inv_clear(_a: PackedStringArray) -> Variant:
	var n := game.inventory.stacks.size()
	game.inventory.from_dict({})
	game.inventory.changed.emit()
	game.mark_dev()
	return "Emptied %d stack%s." % [n, "" if n == 1 else "s"]


func _xp(a: PackedStringArray) -> Variant:
	var p := game.progress
	if not a.is_empty():
		if not a[0].is_valid_int():
			return R.failure("'%s' is not an amount." % a[0])
		if a.size() > 1:
			p.add_skill_xp(a[1], a[0].to_int())
		else:
			p.add_xp(a[0].to_int())
		game.mark_dev()
	return "Level %d, %d XP (%d to level %d)." % [p.level(), p.xp, PlayerProgress.xp_for(p.level() + 1) - p.xp, p.level() + 1]


func _level(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_int() or a[0].to_int() < 1:
		return R.failure("'%s' is not a level." % a[0])
	game.progress.xp = PlayerProgress.xp_for(a[0].to_int())
	game.mark_dev()
	return "You are level %d (%d XP)." % [game.progress.level(), game.progress.xp]


func _skill_list(_a: PackedStringArray) -> Variant:
	var p := game.progress
	if p.skills.is_empty():
		return "No skills yet (they grow by doing: skinning, gathering…)."
	var rows: Array = [["skill", "level", "xp", "next level at"]]
	for k: String in p.skills:
		rows.append([k, p.skill_level(k), int(p.skills[k]), PlayerProgress.xp_for(p.skill_level(k) + 1, PlayerProgress.SKILL_BASE_XP)])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _skill_set(a: PackedStringArray) -> Variant:
	if not a[1].is_valid_int() or a[1].to_int() < 1:
		return R.failure("'%s' is not a level." % a[1])
	game.progress.skills[a[0]] = PlayerProgress.xp_for(a[1].to_int(), PlayerProgress.SKILL_BASE_XP)
	game.mark_dev()
	return "%s is level %d." % [a[0].capitalize(), game.progress.skill_level(a[0])]


func _skill_reset(a: PackedStringArray) -> Variant:
	if a.is_empty():
		game.progress.skills.clear()
	elif game.progress.skills.erase(a[0]) == false:
		return R.failure("No skill '%s'." % a[0])
	game.mark_dev()
	return "Skills reset." if a.is_empty() else "%s reset." % a[0].capitalize()


# --- skill tree ------------------------------------------------------------------------------

func _tree_show(_a: PackedStringArray) -> Variant:
	var t := SkillTree.project()
	var p := game.progress
	if t.order.is_empty():
		return R.failure("No skill tree: %s (%s)." % [", ".join(t.errors), t.path])
	var learned := PackedStringArray()
	for id in t.order:
		if p.tree_rank(id) > 0:
			learned.append("%s %s %d/%d" % [id, t.nodes[id].name, p.tree_rank(id), t.nodes[id].max_rank])
	return "%s (%s): %d free skill points = %d earned (level %d × %d%s) − %d spent. Everything costs %d.\nLearned: %s" % [
		t.name, t.path, p.skill_points(t), p.points_earned(), p.level() - 1, PlayerProgress.SKILL_POINTS_PER_LEVEL,
		" + %d granted" % p.bonus_points if p.bonus_points != 0 else "", t.spent(p.tree_ranks), t.total_cost(),
		", ".join(learned) if not learned.is_empty() else "nothing yet"]


func _tree_list(a: PackedStringArray) -> Variant:
	var t := SkillTree.project()
	var rows: Array = [["id", "name", "category", "rank", "cost", "state"]]
	for id in t.order:
		var n: Dictionary = t.nodes[id]
		if not a.is_empty() and n.category != a[0]:
			continue
		var r := game.progress.tree_rank(id)
		var state := "mastered" if r >= int(n.max_rank) else ("learned" if r > 0 else ("open" if t.is_unlocked(game.progress.tree_ranks, id) else "locked"))
		rows.append([id, n.name, n.category, "%d/%d" % [r, n.max_rank], int(n.cost), state])
	if rows.size() == 1:
		return R.failure("No skills in category '%s'. Categories: %s." % [a[0], ", ".join(t.categories())])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _tree_learn(a: PackedStringArray) -> Variant:
	var t := SkillTree.project()
	var n := clampi(a[1].to_int() if a.size() > 1 else 1, 1, 100)
	var done := 0
	var why := ""
	for i in n:
		why = game.progress.learn(t, a[0])
		if why != "":
			break
		done += 1
	if done == 0:
		return R.failure(why)
	return "Learned %d rank%s of %s (now %d/%d); %d points left.%s" % [done, "" if done == 1 else "s", t.nodes[a[0]].name,
		game.progress.tree_rank(a[0]), t.nodes[a[0]].max_rank, game.progress.skill_points(t), "  Stopped: " + why if why != "" else ""]


func _tree_set(a: PackedStringArray) -> Variant:
	var t := SkillTree.project()
	if not t.has(a[0]):
		return R.failure("There is no skill '%s'." % a[0])
	if not a[1].is_valid_int():
		return R.failure("'%s' is not a rank." % a[1])
	var r := clampi(a[1].to_int(), 0, int(t.nodes[a[0]].max_rank))
	if r == 0:
		game.progress.tree_ranks.erase(a[0])
	else:
		game.progress.tree_ranks[a[0]] = r
	game.progress.tree_changed.emit()
	game.mark_dev()
	return "%s is rank %d/%d; %d points free." % [t.nodes[a[0]].name, r, t.nodes[a[0]].max_rank, game.progress.skill_points(t)]


func _tree_points(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_int():
		return R.failure("'%s' is not a number of points." % a[0])
	game.progress.bonus_points += a[0].to_int()
	game.progress.tree_changed.emit()
	game.mark_dev()
	return "%d free skill points." % game.progress.skill_points(SkillTree.project())


func _tree_reset(_a: PackedStringArray) -> Variant:
	game.progress.reset_tree()
	return "Every skill is forgotten; %d points free." % game.progress.skill_points(SkillTree.project())


func _tree_reload(_a: PackedStringArray) -> Variant:
	var t := SkillTree.reload_project()
	var dropped := t.sanitize(game.progress.tree_ranks)
	game.progress.tree_changed.emit()
	return "%s: %d skills from %s.%s%s" % [t.name, t.order.size(), t.path,
		"  Problems: " + "; ".join(t.errors) if not t.errors.is_empty() else "",
		"  Refunded (no longer in the tree): " + ", ".join(dropped) if not dropped.is_empty() else ""]


# --- loot ------------------------------------------------------------------------------------

func _loot_tables(_a: PackedStringArray) -> Variant:
	var rows: Array = [["table", "rows"]]
	for d: Dictionary in Defs.all("loot_tables"):
		var parts := PackedStringArray()
		for r: Dictionary in d.get("rows", []):
			var what := "→" + str(r.ref) if r.has("ref") else str(r.get("item", "?"))
			parts.append("%s %s%%%s" % [what, str(r.get("chance", 0)), " g%s" % str(r.group) if r.has("group") else ""])
		rows.append([d.id, ", ".join(parts)])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _loot_roll(a: PackedStringArray) -> Variant:
	if not Defs.has("loot_tables", a[0]):
		return R.failure("No loot table '%s'. Try /loot tables." % a[0])
	var n := clampi(a[1].to_int() if a.size() > 1 else 1, 1, 100000)
	var counts := {}
	var empty := 0
	for i in n:
		var drops := Loot.roll(a[0], randi())
		if drops.is_empty():
			empty += 1
		for d: Dictionary in drops:
			counts[d.item] = int(counts.get(d.item, 0)) + int(d.count)
	if n == 1:
		return "Nothing dropped." if counts.is_empty() else "Dropped: " + ", ".join(PackedStringArray(counts.keys().map(func(k: String) -> String: return "%d %s" % [counts[k], k])))
	var rows: Array = [["item", "total", "per roll"]]
	var keys: Array = counts.keys()
	keys.sort()
	for k: String in keys:
		rows.append([k, counts[k], "%.3f" % (float(counts[k]) / n)])
	return R.rich_text("%d rolls of %s, %d empty (%.1f%%).\n%s" % [n, a[0], empty, 100.0 * empty / n,
		ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


# --- audio -----------------------------------------------------------------------------------

const SOUNDS := ["shot_pistol", "shot_rifle", "shot_sniper", "knife", "empty", "reload", "impact", "impact_flesh"]


func _sound_names() -> Array:
	return SOUNDS


func _bus_names() -> Array:
	var out: Array = []
	for i in AudioServer.bus_count:
		out.append(AudioServer.get_bus_name(i))
	return out


func _audio_status(_a: PackedStringArray) -> Variant:
	var rows: Array = [["bus", "volume dB", "muted", "effects", "sends to"]]
	for i in AudioServer.bus_count:
		rows.append([AudioServer.get_bus_name(i), snappedf(AudioServer.get_bus_volume_db(i), 0.1), AudioServer.is_bus_mute(i),
			AudioServer.get_bus_effect_count(i), str(AudioServer.get_bus_send(i)) if i > 0 else ""])
	return R.rich_text("Output %s, mix rate %d Hz, latency %.0f ms.\n%s" % [AudioServer.get_output_device(), int(AudioServer.get_mix_rate()),
		AudioServer.get_output_latency() * 1000.0, ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


func _audio_list(_a: PackedStringArray) -> Variant:
	return "Sounds (synthesised at runtime): " + ", ".join(SOUNDS)


func _audio_play(a: PackedStringArray) -> Variant:
	if not a[0] in SOUNDS:
		return R.failure("No sound '%s'. Sounds: %s." % [a[0], ", ".join(SOUNDS)])
	var cam := game.get_viewport().get_camera_3d()
	if cam == null:
		var p := AudioStreamPlayer.new()
		p.stream = SynthAudio.get_sound(a[0])
		p.finished.connect(p.queue_free)
		game.add_child(p)
		p.play()
	else:
		SynthAudio.play_at(game, a[0], cam.global_position)
	return "Playing %s." % a[0]


func _audio_volume(a: PackedStringArray) -> Variant:
	var i := AudioServer.get_bus_index(a[0])
	if i < 0:
		return R.failure("No bus '%s'. Buses: %s." % [a[0], ", ".join(_bus_names())])
	if a.size() > 1:
		var v := a[1]
		if v.ends_with("%") and v.trim_suffix("%").is_valid_float():
			AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v.trim_suffix("%").to_float() / 100.0, 0.0001)))
		elif v.is_valid_float():
			AudioServer.set_bus_volume_db(i, clampf(v.to_float(), -80.0, 24.0))
		else:
			return R.failure("'%s' is not a volume; use dB (like -6) or a percentage (like 50%%)." % v)
	var db := AudioServer.get_bus_volume_db(i)
	return "%s is at %.1f dB (%d%%)." % [a[0], db, roundi(db_to_linear(db) * 100.0)]


func _audio_mute(a: PackedStringArray, on: bool) -> Variant:
	var bus := a[0] if not a.is_empty() else "Master"
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return R.failure("No bus '%s'. Buses: %s." % [bus, ", ".join(_bus_names())])
	AudioServer.set_bus_mute(i, on)
	return "%s is %s." % [bus, "muted" if on else "audible"]


# --- content ---------------------------------------------------------------------------------

func _content_items(a: PackedStringArray) -> Variant:
	var rows: Array = [["id", "name", "category", "stack", "value", "quest"]]
	for d: Dictionary in Defs.all("items"):
		if a.is_empty() or str(d.id).contains(a[0]):
			rows.append([d.id, d.get("name", ""), d.get("category", ""), int(d.get("stack", 1)), int(d.get("value", 0)), bool(d.get("quest", false))])
	return R.rich_text("%d items.\n%s" % [rows.size() - 1, ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


func _content_creatures(a: PackedStringArray) -> Variant:
	var rows: Array = [["id", "name", "faction", "behaviour", "level", "health", "loot"]]
	for d: Dictionary in Defs.all("creatures"):
		if a.is_empty() or str(d.id).contains(a[0]):
			rows.append([d.id, d.get("name", ""), d.get("faction", ""), d.get("behaviour", ""), str(d.get("level", "")),
				d.get("health", 0), d.get("loot", "")])
	return R.rich_text("%d creatures.\n%s" % [rows.size() - 1, ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


func _content_factions(_a: PackedStringArray) -> Variant:
	var rows: Array = [["faction", "hostile to"]]
	for d: Dictionary in Defs.all("factions"):
		rows.append([d.id, ", ".join(PackedStringArray(d.get("hostile_to", [])))])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _content_rules(_a: PackedStringArray) -> Variant:
	var rows: Array = [["rule", "biomes", "creatures (weight)"]]
	for d: Dictionary in Defs.all("spawn_rules"):
		var cs := PackedStringArray()
		for r: Dictionary in d.get("rows", []):
			cs.append("%s %s" % [r.get("archetype", "?"), str(r.get("weight", 1))])
		rows.append([d.id, ", ".join(PackedStringArray(d.get("biomes", []))), ", ".join(cs)])
	return R.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _content_show(a: PackedStringArray) -> Variant:
	if not a[0] in Defs.REGISTRIES:
		return R.failure("'%s' is not a registry. Registries: %s." % [a[0], ", ".join(Defs.REGISTRIES)])
	if not Defs.has(a[0], a[1]):
		return R.failure("No %s '%s'." % [a[0], a[1]])
	return JSON.stringify(Defs.get_def(a[0], a[1]), "  ", false)


func _content_reload(_a: PackedStringArray) -> Variant:
	Defs.reload()
	return "Reloaded %s." % ", ".join(Defs.REGISTRIES.map(func(r: String) -> String: return "%d %s" % [Defs.ids(r).size(), r]))
