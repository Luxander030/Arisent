## The game host. Owns the GameSession (clocks, story, inventory, console, saving) and the
## player, and swaps the map underneath them: a WorldView plus its WorldSession per map,
## never a scene change while playing. Leaving to the menu goes through leave() so the
## session can save first.
## Map choice: `-- --map <folder>` on the command line, else res://maps/default.luxmap,
## else (during development) the editor's most recent map.
extends Node

var game: GameSession
var world: WorldView
var session: WorldSession
var player: Player
var _spawn := Vector3.ZERO
var hud: GameHud
var _autosave_t := 0.0
var _loaded_player := {}   ## player state from the save being loaded
var pause_menu: PauseMenu

const AUTOSAVE_SECONDS := 300.0


func _ready() -> void:
	# Physics runs at 64 Hz (CS tick); rendering interpolates between ticks.
	get_tree().physics_interpolation = true
	GraphicsSettings.current().apply_window(get_window())
	game = GameSession.new()
	add_child(game)
	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.died.connect(_on_died)
	game.console.toggled.connect(func(_open: bool) -> void: _update_input())
	_register_commands()
	get_tree().auto_accept_quit = false
	hud = GameHud.new()
	hud.game = game
	hud.player = player
	add_child(hud)
	hud.inventory_toggled.connect(func(open: bool) -> void:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
		_update_input())
	hud.skill_tree_toggled.connect(func(open: bool) -> void:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
		_update_input())
	hud.loot_toggled.connect(func(open: bool) -> void:
		if not hud.inventory_open():
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
		_update_input())
	var path := _start_from_launch()
	if path == "":
		path = _pick_map()
	if path == "" or not load_map(path):
		var why := MapIO.last_error if MapIO.last_error != "" else "No map found. Make one with the World Editor first."
		hud.show_center("Can't play: %s" % why)
		push_error(why)
		await get_tree().create_timer(4.0).timeout
		leave()


## Loads (or switches to) a map. The GameSession and player carry over.
func load_map(path: String) -> bool:
	var map := MapIO.load_map(path)
	if map == null:
		return false
	if session:
		# Remember this map's changes for the next save (multi-map play-throughs), and autosave.
		game.map_snapshots[game.current_map_uid] = session.save_state()
		save_now("auto", true)
		session.detach()
		session = null
	if world:
		world.queue_free()
	world = WorldView.new()
	world.name = "World"
	add_child(world)
	move_child(world, 0)
	GraphicsSettings.current().apply_world(world)  # detail first: the terrain and city build with it
	hud.lod = world.lod
	world.entities.simulate_physics = true
	world.setup_terrain(map, player.cam.camera)
	MapIO.load_terrain(map, world.terrain)
	world.finish_terrain()
	# The game never edits the terrain, so it can use the faster shader (see optimize_shader).
	if world.terrain is Terrain3DBackend:
		(world.terrain as Terrain3DBackend).optimize_shader(true)
	GraphicsSettings.current().apply_world(world)  # the terrain's texturing extras need the terrain
	world.build_water()
	world.build_city()
	world.build_entities()
	_spawn = _spawn_point(map)
	player.global_position = _spawn
	player.reset_physics_interpolation()
	player.cam.yaw = 0.0
	player.cam.camera.current = true
	player.water_level_func = world.water_level_at
	world.terrain.set_focus(player)
	session = WorldSession.attach(world, game, player)
	session.teleport = _teleport
	player.queries = session.queries
	player.session = session
	session.loot_opened.connect(func(cid: String) -> void: hud.open_loot(session, cid))
	game.current_map_uid = map.map_uid
	game.known_maps[map.map_uid] = path
	var saved: Dictionary = game.map_snapshots.get(map.map_uid, game.loaded_maps.get(map.map_uid, {}))
	if not saved.is_empty():
		for w in session.apply_save(saved):
			game.notify("Save: " + w)
		game.map_snapshots.erase(map.map_uid)
		game.loaded_maps.erase(map.map_uid)
	if str(_loaded_player.get("map_uid", "")) == map.map_uid:
		var p: Array = _loaded_player.pos
		_teleport(Vector3(p[0], p[1], p[2]))
		player.cam.yaw = float(_loaded_player.get("yaw", 0.0))
		player.health = float(_loaded_player.get("health", 100.0))
		player.weapons.from_save(_loaded_player.get("weapons", {}))
		_loaded_player = {}
	get_window().title = "Lux's RPG — " + map.display_name()
	return true


func _teleport(p: Vector3) -> void:
	player.global_position = p
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()


func _pick_map() -> String:
	if MapIO.is_map_folder(GameLaunch.map_path):
		var once := GameLaunch.map_path
		GameLaunch.map_path = ""
		return once
	var args := OS.get_cmdline_user_args()
	var i := args.find("--map")
	if i >= 0 and i + 1 < args.size() and MapIO.is_map_folder(args[i + 1]):
		return args[i + 1]
	if MapIO.is_map_folder("res://maps/default.luxmap"):
		return "res://maps/default.luxmap"
	var cfg := ConfigFile.new()
	if cfg.load("user://editor.cfg") == OK:
		for p in cfg.get_value("recent", "maps", PackedStringArray()):
			if MapIO.is_map_folder(p):
				return p
	return ""


## The default player spawn entity if there is one (else the first), else the city plaza,
## else the map centre.
func _spawn_point(map: MapData) -> Vector3:
	var p := Vector3.INF
	for e: Dictionary in map.entities:
		if e.kind == "spawn_point" and (p == Vector3.INF or bool(e.props.get("is_default", false))):
			p = EntityKinds.position_of(e)
			if bool(e.props.get("is_default", false)):
				break
	if p == Vector3.INF:
		p = Vector3.ZERO
		if map.city.has("center"):
			var plaza: Array = map.city.get("plaza", map.city.center)
			p = Vector3(plaza[0], 0.0, plaza[1])
	p.y = world.terrain.get_height(p) + 0.5
	return p


func _on_died() -> void:
	await get_tree().create_timer(3.0).timeout
	player.revive(_spawn)


## Back to the main menu; the game is saved first (autosave slot).
func leave() -> void:
	if session:
		save_now("auto", true)
		session.detach()
		session = null
	get_tree().auto_accept_quit = true
	get_tree().physics_interpolation = false
	get_tree().change_scene_to_file("res://scenes/main_menu/MainMenu.tscn")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if session:
			save_now("auto", true)
		get_tree().quit()


# --- saving ---------------------------------------------------------------------------------

## The map named by GameLaunch's save (continue / load), or "" for a new game.
func _start_from_launch() -> String:
	var slot := GameLaunch.slot
	if GameLaunch.mode == "continue":
		var list := game.saves.list_slots()
		slot = str(list[0].slot) if not list.is_empty() else ""
	if GameLaunch.mode == "new" or slot == "":
		return ""
	var data := game.saves.load_save(slot)
	if data.is_empty():
		hud.push_message("Couldn't load '%s': %s" % [slot, game.saves.last_error])
		return ""
	game.apply_save(data.game)
	game.loaded_maps = data.get("maps", {})
	_loaded_player = data.game.get("player", {})
	var path := str(game.known_maps.get(game.current_map_uid, ""))
	if not MapIO.is_map_folder(path):
		hud.push_message("The saved map isn't at %s any more; starting on another map." % path)
		return ""
	hud.push_message("Loaded '%s'." % slot)
	return path


func _snapshot() -> Dictionary:
	var g := game.to_save()
	var p := player.global_position
	g.player = {"map_uid": game.current_map_uid, "pos": [p.x, p.y, p.z], "yaw": player.cam.yaw,
		"health": player.health, "weapons": player.weapons.to_save()}
	var maps := {}
	# Maps from the loaded save not entered yet, then maps visited earlier this session.
	for uid: String in game.loaded_maps:
		maps[uid] = game.loaded_maps[uid]
	for uid: String in game.map_snapshots:
		maps[uid] = game.map_snapshots[uid]
	maps[game.current_map_uid] = session.save_state()
	return {"game": g, "maps": maps.duplicate(true),
		"summary": {"map_name": session.map.display_name(), "play_time": game.clock.now, "level": game.progress.level()}}


func save_now(slot: String, sync := false) -> void:
	if session == null or game.ephemeral:
		return
	var snap := _snapshot()
	if sync:
		var err := game.saves.save_sync(slot, snap)
		if err != OK:
			push_error("save failed: " + game.saves.last_error)
	else:
		game.saves.save_async(slot, snap)  # "Saved" is reported when the write finishes


func _physics_process(delta: float) -> void:
	if session == null:
		return
	_autosave_t += delta
	if _autosave_t >= AUTOSAVE_SECONDS:
		_autosave_t = 0.0
		save_now("auto")


func _update_input() -> void:
	player.input_enabled = not game.console.is_open and not hud.inventory_open() and not hud.loot_open() and not hud.skill_tree_open() \
		and pause_menu == null


func _process(_delta: float) -> void:
	Perf.begin(&"hud")
	_process_body(_delta)
	Perf.end(&"hud")


func _process_body(_delta: float) -> void:
	if hud and session:
		hud.update_status()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and not game.console.is_open:
		var k := event as InputEventKey
		if hud.loot_open() and k.physical_keycode == KEY_E:
			hud.take_all()
			get_viewport().set_input_as_handled()
			return
		if event.is_action_pressed("skill_tree"):
			hud.toggle_skill_tree()
			get_viewport().set_input_as_handled()
			return
		if hud.skill_tree_open():
			pass  # the tree has the mouse; only K and Esc close it
		elif k.physical_keycode == KEY_TAB or k.physical_keycode == KEY_I:
			hud.toggle_inventory()
			get_viewport().set_input_as_handled()
			return
		if k.keycode == KEY_F5:
			save_now("quick")
			get_viewport().set_input_as_handled()
			return
		if k.keycode == KEY_F9:
			load_slot("quick")
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel") and not game.console.is_open:
		if hud.skill_tree_open():
			hud.toggle_skill_tree()
		elif hud.loot_open():
			hud.close_loot()
		elif hud.inventory_open():
			hud.toggle_inventory()
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			open_pause_menu()
			get_viewport().set_input_as_handled()


## Esc with the mouse free: the game pauses behind Resume / Settings / Main menu.
func open_pause_menu() -> void:
	if pause_menu:
		return
	pause_menu = PauseMenu.new()
	pause_menu.world = world
	pause_menu.resumed.connect(close_pause_menu)
	pause_menu.quit_to_menu.connect(func() -> void:
		close_pause_menu()
		leave())
	add_child(pause_menu)
	hud.crosshair.visible = false
	hud.prompt.text = ""
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_update_input()


func close_pause_menu() -> void:
	if pause_menu == null:
		return
	pause_menu.queue_free()
	pause_menu = null
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_input()


func load_slot(slot: String) -> bool:
	if not game.saves.has_save(slot):
		return false
	game.saves.wait()
	GameLaunch.load_slot(slot)
	if session:
		session.detach()
		session = null
	get_tree().reload_current_scene()
	return true


# --- console ----------------------------------------------------------------------------------

func _register_commands() -> void:
	var c := game.console
	var flag_hint := ConsoleParse.hints_of(["on", "off"])
	c.command("god", "The player takes no damage (bare: switches).", "/god [on|off]", _cmd_god, 0, 1, flag_hint, self)
	c.command("notarget", "Creatures do not notice the player (bare: switches).", "/notarget [on|off]", _cmd_notarget, 0, 1, flag_hint, self)
	c.command("noclip", "Fly through everything: WASD along the view, Space up, Ctrl down, Shift fast.", "/noclip [on|off]",
		_cmd_noclip, 0, 1, flag_hint, self)
	c.command("heal", "Sets the player's health (default full).", "/heal [hp]", _cmd_heal, 0, 1, Callable(), self)
	c.command("hurt", "Damages the player (dying works as usual).", "/hurt <hp>", _cmd_hurt, 1, 1, Callable(), self)
	c.command("weapon", "Equips a weapon.", "/weapon <id>", _cmd_weapon, 1, 1, ConsoleParse.hints_of(WeaponDefs.WEAPONS.keys()), self)
	c.verbs("ammo", "Ammunition.", self) \
		.verb("fill", "Fills every magazine and reserve.", _cmd_ammo_fill) \
		.verb("infinite", "Shots use no ammunition (bare: switches).", _cmd_ammo_infinite, 0, 1, "/ammo infinite [on|off]", flag_hint)
	c.command("save", "Saves the game (default slot: quick).", "/save [slot]", _cmd_save, 0, 1, ConsoleParse.hints_of(_slot_names), self)
	c.command("load", "Loads a save (default slot: quick); the game restarts on it.", "/load [slot]", _cmd_load, 0, 1,
		ConsoleParse.hints_of(_slot_names), self)
	c.verbs("saves", "Save slots.", self) \
		.verb("list", "Every slot, newest first.", _cmd_saves_list) \
		.verb("delete", "Deletes a slot and all its generations.", _cmd_saves_delete, 1, 1, "/saves delete <slot>", ConsoleParse.hints_of(_slot_names)) \
		.verb("dump", "What a save of this map would contain, and how big.", _cmd_saves_dump) \
		.verb("folder", "Where saves are on disk.", _cmd_saves_folder)
	c.verbs_of("skilltree").verb("open", "Opens or closes the skill tree screen (K).", func(_a: PackedStringArray) -> Variant:
		hud.toggle_skill_tree()
		return null, 0, 0, "", Callable(), self)
	c.command("menu", "Back to the main menu (the game is saved first).", "", func(_a: PackedStringArray) -> Variant:
		leave.call_deferred()
		return "Leaving to the menu.", 0, 0, Callable(), self)
	c.command("newgame", "Starts a new game on this map, or on another map folder.", "/newgame [map folder]", _cmd_newgame, 0, 1,
		ConsoleParse.hints_of(_map_folders), self)
	c.model.describe_key("game", "save", "F5", "Quick save", self)
	c.model.describe_key("game", "load", "F9", "Quick load", self)
	c.model.describe_key("game", "bag", "Tab or I", "Open or close the bag", self)
	c.model.describe_key("game", "skill tree", "K", "Open or close the skill tree (click a skill to learn it)", self)
	c.model.describe_key("game", "take all", "E (loot window open)", "Take everything from the corpse", self)
	c.model.describe_key("game", "weapons", "1 2 3 4, wheel", "Rifle, pistol, knife, sniper", self)
	c.model.describe_key("game", "reload", "R", "Reload", self)
	c.model.describe_key("game", "leave", "Esc (mouse free)", "Back to the main menu", self)
	c.monitors.add("player", "Player", "bottom_left", _panel_player, KeyCombo.make(KEY_4, false, true), self)


func _switch(a: PackedStringArray, current: bool) -> int:
	if a.is_empty():
		return 0 if current else 1
	return ConsoleParse.flag(a[0])


func _cmd_god(a: PackedStringArray) -> Variant:
	var f := _switch(a, player.invulnerable)
	if f < 0:
		return ConsoleResult.failure("'%s' is not on or off." % a[0])
	player.invulnerable = f == 1
	game.mark_dev()
	return "God mode is %s." % ("on" if player.invulnerable else "off")


func _cmd_notarget(a: PackedStringArray) -> Variant:
	var f := _switch(a, game.notarget)
	if f < 0:
		return ConsoleResult.failure("'%s' is not on or off." % a[0])
	game.notarget = f == 1
	game.mark_dev()
	return "Creatures %s the player." % ("ignore" if game.notarget else "notice")


func _cmd_noclip(a: PackedStringArray) -> Variant:
	var f := _switch(a, player.noclip)
	if f < 0:
		return ConsoleResult.failure("'%s' is not on or off." % a[0])
	player.noclip = f == 1
	game.mark_dev()
	return "Noclip is %s." % ("on" if player.noclip else "off")


func _cmd_heal(a: PackedStringArray) -> Variant:
	if player.health <= 0.0:
		return ConsoleResult.failure("The player is dead; they come back at the spawn point by themselves.")
	player.health = clampf(a[0].to_float() if not a.is_empty() and a[0].is_valid_float() else 100.0, 1.0, 100.0)
	return "Health %d." % int(player.health)


func _cmd_hurt(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float() or a[0].to_float() <= 0.0:
		return ConsoleResult.failure("'%s' is not an amount of damage." % a[0])
	player.apply_damage(DamageInfo.make(a[0].to_float(), "console", "console", player.global_position))
	return "Health %d." % int(player.health)


func _cmd_weapon(a: PackedStringArray) -> Variant:
	if not WeaponDefs.WEAPONS.has(a[0]):
		return ConsoleResult.failure("No weapon '%s'. Weapons: %s." % [a[0], ", ".join(PackedStringArray(WeaponDefs.WEAPONS.keys()))])
	player.weapons.equip(a[0])
	return "Holding the %s." % str(WeaponDefs.get_def(a[0]).name).to_lower()


func _cmd_ammo_fill(_a: PackedStringArray) -> Variant:
	for id: String in WeaponDefs.WEAPONS:
		var d := WeaponDefs.get_def(id)
		player.weapons.ammo[id] = [int(d.get("magazine", 0)), int(d.get("reserve", 0))]
	game.mark_dev()
	return "Every weapon is full."


func _cmd_ammo_infinite(a: PackedStringArray) -> Variant:
	var f := _switch(a, player.weapons.infinite_ammo)
	if f < 0:
		return ConsoleResult.failure("'%s' is not on or off." % a[0])
	player.weapons.infinite_ammo = f == 1
	game.mark_dev()
	return "Infinite ammunition is %s." % ("on" if f == 1 else "off")


func _slot_names() -> Array:
	return game.saves.list_slots().map(func(s: Dictionary) -> String: return str(s.slot))


func _map_folders() -> Array:
	var out: Array = []
	for root: String in ["res://maps", "user://maps"]:
		var d := DirAccess.open(root)
		if d:
			for f in d.get_directories():
				if f.ends_with(".luxmap"):
					out.append(root.path_join(f))
	return out


func _cmd_save(a: PackedStringArray) -> Variant:
	if session == null:
		return ConsoleResult.failure("No map is loaded.")
	if game.ephemeral:
		return ConsoleResult.failure("Simulate mode is never saved.")
	save_now(a[0] if not a.is_empty() else "quick")
	return null  # "Saved" lands when the write finishes (status bar and feed)


func _cmd_load(a: PackedStringArray) -> Variant:
	var slot := a[0] if not a.is_empty() else "quick"
	if not load_slot(slot):
		return ConsoleResult.failure("No save '%s' (%s)." % [slot, game.saves.last_error])
	return "Loading '%s'…" % slot


func _cmd_saves_list(_a: PackedStringArray) -> Variant:
	var rows: Array = [["slot", "map", "level", "saved at", "played"]]
	for s: Dictionary in game.saves.list_slots():
		rows.append([s.slot, s.map_name, s.level, str(s.saved_at).replace("T", " "), ConsoleBars.duration(float(s.play_time))])
	if rows.size() == 1:
		return "No saves yet."
	return ConsoleResult.rich_text(ConsoleTable.format(rows, "single", "single", game.console.model.columns))


func _cmd_saves_delete(a: PackedStringArray) -> Variant:
	if not game.saves.has_save(a[0]):
		return ConsoleResult.failure("No save '%s'." % a[0])
	game.saves.wait()
	SaveService._remove_tree(SaveService.slot_dir(a[0]))
	return "Deleted '%s'." % a[0]


func _cmd_saves_dump(_a: PackedStringArray) -> Variant:
	if session == null:
		return ConsoleResult.failure("No map is loaded.")
	var snap := _snapshot()
	var m: Dictionary = snap.maps[game.current_map_uid]
	var st: Dictionary = m.state
	var dyn_items := 0
	for r: String in m.dynamic:
		dyn_items += (m.dynamic[r].items as Array).size()
	var rows: Array = [["part", "bytes", "contents"],
		["game", var_to_bytes(snap.game).size(), "%d bag stacks, %d story flags" % [game.inventory.stacks.size(), game.story_state.flags.size()]],
		["map state", var_to_bytes(st).size(), "%d slots, %d removed, %d modified, %d unique NPCs, %d zone states" % [(st.slots as Dictionary).size(),
			(st.removed as Dictionary).size(), (st.modified as Dictionary).size(), (st.unique as Dictionary).size(), (st.zones as Dictionary).size()]],
		["dynamic", var_to_bytes(m.dynamic).size(), "%d regions, %d ground items" % [(m.dynamic as Dictionary).size(), dyn_items]]]
	return ConsoleResult.rich_text("Map %s.\n%s" % [ConsoleTheme.esc(game.current_map_uid), ConsoleTable.format(rows, "single", "single", game.console.model.columns)])


func _cmd_saves_folder(_a: PackedStringArray) -> Variant:
	return ProjectSettings.globalize_path(SaveService.ROOT)


func _cmd_newgame(a: PackedStringArray) -> Variant:
	var path := a[0] if not a.is_empty() else str(game.known_maps.get(game.current_map_uid, ""))
	if not MapIO.is_map_folder(path):
		return ConsoleResult.failure("'%s' is not a map folder." % path)
	if session:
		save_now("auto", true)
		session.detach()
		session = null
	GameLaunch.new_game()
	GameLaunch.map_path = path  # a fresh scene is a fresh play-through
	get_tree().reload_current_scene.call_deferred()
	return "Starting a new game on %s…" % path.get_file()


func _panel_player() -> String:
	var p := player.global_position
	return "pos   %7.1f %6.1f %7.1f\nspeed %5.1f m/s  %s\nhealth %3d  %s%s%s\n%s" % [p.x, p.y, p.z, player.horizontal_speed(),
		"noclip" if player.noclip else ("swimming" if player.swimming else ("ladder" if player.on_ladder else ("ground" if player.on_ground else "air"))),
		int(player.health), "god " if player.invulnerable else "", "notarget " if game.notarget else "", "∞ammo" if player.weapons.infinite_ammo else "",
		player.weapons.status_text()]
