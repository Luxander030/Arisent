## One play-through: clocks, story state, player progress and inventory, the debug console
## and (later) saving. Outlives map changes: the game host swaps the WorldView and its
## WorldSession underneath it. The World Editor's Simulate mode makes an ephemeral one.
class_name GameSession
extends Node

const STORY_SETTING := "lux/story/graph_path"

var clock := SimClock.new()
var time_of_day := TimeOfDay.new()
var story_state := StoryState.new()
var inventory := Inventory.new()
var progress := PlayerProgress.new()
var last_skip := 0.0
## Messages for the player (kills, loot, level ups); the host shows them.
signal notified(text: String)
var console: DebugConsole
var commands: GameCommands
var notarget := false         ## console /notarget: creatures ignore the player
var save_started := 0         ## usec when the running save began (console status bar)
var last_save := {}           ## {ok, took, at (msec), error}
var world: WorldSession       ## the map currently being played
var ephemeral := false        ## Simulate mode: never saved
var dev_modified := false     ## set by cheat commands (spawn, god…)
var next_runtime_id := 1
var saves := SaveService.new()
## Identifies this play-through (new for every new game, kept by its saves).
var playthrough := MapData.new_uid()
var current_map_uid := ""
var known_maps := {}          ## map uid -> folder (to find the map again when loading)
## World states of maps visited this session but not loaded now (multi-map play-throughs).
var map_snapshots := {}
## Map data from the loaded save, per uid, until each map is entered.
var loaded_maps := {}


func _ready() -> void:
	name = "GameSession"
	console = DebugConsole.new()
	console.name = "Console"
	add_child(console)
	var graph := story_graph()
	story_state.reset(graph)
	commands = GameCommands.register(self)
	progress.leveled.connect(func(l: int) -> void:
		notify("Level up! You are level %d. +%d skill points (K opens the skill tree)." % [l, PlayerProgress.SKILL_POINTS_PER_LEVEL]))
	progress.skill_leveled.connect(func(sk: String, l: int) -> void: notify("%s is now level %d." % [sk.capitalize(), l]))


func _process(delta: float) -> void:
	Perf.begin(&"game_session")
	_process_body(delta)
	Perf.end(&"game_session")


func _process_body(delta: float) -> void:
	var dt := clock.advance(delta)
	time_of_day.advance(dt)
	saves.poll()
	if saves.busy() and save_started == 0:
		save_started = Time.get_ticks_usec()
	for r: Array in saves.take_results():
		var took := (Time.get_ticks_usec() - save_started) / 1e6 if save_started > 0 else 0.0
		save_started = 0
		last_save = {"ok": int(r[1]) == OK, "took": took, "at": Time.get_ticks_msec(), "error": str(r[2]) if r.size() > 2 else ""}
		if int(r[1]) == OK:
			notify("Saved (%s)." % r[0])
		else:
			notify("Saving '%s' FAILED: %s" % [r[0], r[2]])
			if console:
				console.log_line(ConsoleTheme.Kind.ERROR, "Save failed: %s" % str(r[2]))


## Everything game-wide, as plain data (the host adds the player).
func to_save() -> Dictionary:
	return {"sim_time": clock.now, "time_of_day": time_of_day.hours, "day": time_of_day.day,
		"day_minutes": time_of_day.day_minutes, "inventory": inventory.to_dict(), "progress": progress.to_dict(),
		"story": story_state.to_dict(), "next_runtime_id": next_runtime_id, "dev_modified": dev_modified,
		"current_map_uid": current_map_uid, "known_maps": known_maps.duplicate(), "playthrough": playthrough}


func apply_save(g: Dictionary) -> void:
	clock.now = float(g.get("sim_time", 0.0))
	time_of_day.hours = float(g.get("time_of_day", 9.0))
	time_of_day.day = int(g.get("day", 0))
	time_of_day.day_minutes = float(g.get("day_minutes", 48.0))
	inventory.from_dict(g.get("inventory", {}))
	progress.from_dict(g.get("progress", {}))
	# Skill ranks are saved by node id; ids the tree no longer has give their points back.
	var dropped := SkillTree.project().sanitize(progress.tree_ranks)
	if not dropped.is_empty():
		notify.call_deferred("The skill tree changed since this save: %s refunded." % ", ".join(dropped))
	story_state.from_dict(g.get("story", {}))
	next_runtime_id = int(g.get("next_runtime_id", 1))
	dev_modified = bool(g.get("dev_modified", false))
	current_map_uid = str(g.get("current_map_uid", ""))
	known_maps = (g.get("known_maps", {}) as Dictionary).duplicate()
	playthrough = str(g.get("playthrough", playthrough))


## The project's story graph (Project Settings → lux/story/graph_path), or null.
static func story_graph() -> StoryGraph:
	var path := str(ProjectSettings.get_setting(STORY_SETTING, ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as StoryGraph


func notify(text: String) -> void:
	notified.emit(text)
	if console:
		console.log_line(ConsoleTheme.Kind.INFO, text)


var _story_runner: StoryRunner


## Fires a story event (a cell id of the project's story graph): its dialogue lines go to
## the message feed; game events it emits ("spawn_group:<id>") reach the world.
## Choices wait (there is no dialogue UI yet).
func story_event(cell_id: String) -> void:
	var graph := story_graph()
	if graph == null:
		notify("(story event '%s' — no story graph configured)" % cell_id)
		return
	if _story_runner == null:
		_story_runner = StoryRunner.new(graph, story_state)
		_story_runner.dialogue.connect(func(_c: StoryCell, speaker: String, text: String) -> void:
			notify("%s%s" % [speaker + ": " if speaker != "" else "", text]))
		_story_runner.game_event.connect(_on_story_game_event)
	if not _story_runner.trigger(cell_id):
		notify("(story event '%s' is not available now)" % cell_id)
		return
	for i in 20:
		if _story_runner.status != StoryRunner.Status.WAITING_CONTINUE:
			break
		_story_runner.advance()


func _on_story_game_event(event_name: String, payload: String) -> void:
	if event_name == "spawn_group" and world:
		world.spawns.spawn_group(payload)
	elif event_name == "camp" and world:
		world.make_camp(payload.to_float() if payload != "" else 25.0)


func new_runtime_id() -> String:
	next_runtime_id += 1
	return "rt:%d" % (next_runtime_id - 1)


func mark_dev() -> void:
	dev_modified = true
