## Windowed: run the game scene on a map, walk forward, screenshot, check the player is grounded.
## Run: godot --path . --script res://tests/smoke_game.gd -- <out_dir> --map <map folder>
extends SceneTree

func _initialize() -> void:
	create_timer(260.0).timeout.connect(func() -> void: quit(2))
	_run.call_deferred()

func _run() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	GraphicsSettings.use_defaults()
	var game: Node = load("res://game/world_game.tscn").instantiate()
	root.add_child(game)
	for i in 90:
		await process_frame
	var player: Player = game.player
	var tmat: Terrain3DMaterial = (game.world.terrain as Terrain3DBackend).terrain.material
	print("terrain speed patch: %s" % (tmat.shader_override_enabled and (tmat.shader_override as Shader).code.contains("lux_full")))
	# Drop a few physics props in front of the player.
	var ahead := player.global_position + Vector3(0, 0.3, -4)
	for k in 3:
		var e := EntityKinds.make("smoke-%d" % k, ["props.crate_small", "props.barrel", "props.crate_large"][k], "physics_prop",
			ahead + Vector3(k * 1.2 - 1.2, 0, 0), 0.0, 1.0)
		game.world.entities.add_entity(e)
	var props_start: Array[Vector3] = []
	for k in 3:
		props_start.append(game.world.entities.node_for("smoke-%d" % k).global_position)
	var start := player.global_position
	Input.action_press("move_forward")
	for i in 180:
		await physics_frame
	Input.action_release("move_forward")
	var moved_props := 0
	for k in 3:
		var n: Node3D = game.world.entities.node_for("smoke-%d" % k)
		if n and n.global_position.distance_to(props_start[k]) > 0.3:
			moved_props += 1
	print("physics props pushed: %d of 3" % moved_props)
	Input.action_press("jump")
	for i in 20:
		await physics_frame
	Input.action_release("jump")
	print("jump: on ground after 20 ticks = %s, y above ground %.2f" % [player.on_ground, player.global_position.y - game.world.terrain.get_height(player.global_position)])
	for i in 60:
		await physics_frame
	for i in 30:
		await process_frame
	var p := player.global_position
	var ground: float = game.world.terrain.get_height(p)
	print("player moved %.1f m, height above ground %.2f m, on floor %s, health %d" % [Vector2(p.x - start.x, p.z - start.z).length(), p.y - ground, player.is_on_floor(), player.health])
	root.get_texture().get_image().save_png(out.path_join("game.png"))
	await _shoot_dummy(game, player, out)
	await _creatures(game, player, out)
	await _console(game, player, out)
	await _skill_tree(game, player, out)
	await _persistence(game, out)
	quit()


## Save through the console, drop an item, start a fresh game host loading that save, and
## check the world came back as it was (dead slots, dropped item, inventory, position).
func _persistence(game: Node, out: String) -> void:
	var con: DebugConsole = game.game.console
	var s: WorldSession = game.session
	var player: Player = game.player
	print(con.run("give wolf_pelt 3"))
	var dropped := s.items.drop("wolf_pelt", 1, player.global_position + Vector3(2, 0, 0), "player_dropped")
	game.game.inventory.remove("wolf_pelt", 1)
	var dead := s.spawns.slots.values().filter(func(x: SpawnDirector.Slot) -> bool: return x.state == SpawnDirector.DEAD).size()
	var pos: Vector3 = player.global_position
	# Fell the nearest scattered tree/rock somewhere near (walk there first if needed).
	var fell := con.run("fell")
	if fell.begins_with("nothing"):
		var here := player.global_position
		var near: Array = s.view.terrain.instances_near(here, 1000.0)
		near.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a.position as Vector3).distance_to(here) < (b.position as Vector3).distance_to(here))
		if not near.is_empty():
			game._teleport(near[0].position + Vector3(1, 1, 0))
			await physics_frame
			fell = con.run("fell")
	print(fell)
	var felled := s.state.removed.keys().filter(func(k: String) -> bool: return k.begins_with("veg:"))
	pos = player.global_position
	print(con.run("save smoke"))
	game.game.saves.wait()
	print(con.run("saves dump"))
	print("before reload: dead slots %d, pelts %d, items %d, pos %s" % [dead, game.game.inventory.count_of("wolf_pelt"), s.items.items.size(), pos])
	game.session.detach()
	game.queue_free()
	await process_frame
	GameLaunch.load_slot("smoke")
	var again: Node = load("res://game/world_game.tscn").instantiate()
	root.add_child(again)
	for i in 60:
		await process_frame
	var s2: WorldSession = again.session
	var dead2 := s2.spawns.slots.values().filter(func(x: SpawnDirector.Slot) -> bool: return x.state == SpawnDirector.DEAD).size()
	print("after reload: dead slots %d, pelts %d, dropped item back %s, player moved %.2f m" % [dead2,
		again.game.inventory.count_of("wolf_pelt"), s2.items.items.has(dropped), again.player.global_position.distance_to(pos)])
	for id: String in felled:
		var d := VegetationIds.parse(id)
		var still := s2.view.terrain.instances_near(d.pos, 0.75).filter(func(x: Dictionary) -> bool: return Catalog.instanced_ids()[int(x.mesh_id)] == d.asset)
		print("felled %s: remembered %s, instance back after load: %s" % [id, s2.state.removed.has(id), not still.is_empty()])
	root.get_texture().get_image().save_png(out.path_join("reloaded.png"))


## Creatures, debug overlays and loot: spawn wolves through the console, look at them with
## and without the AI/spawn overlays, kill them and check the loot on the ground.
func _creatures(game: Node, player: Player, out: String) -> void:
	var con: DebugConsole = game.game.console
	print(con.run("god"))
	player.cam.pitch = -0.25
	print(con.run("spawn wolf 3"))
	print(con.run("spawn sheep 4"))
	for i in 64 * 3:
		await physics_frame
	print(con.run("npcs stats"))
	root.get_texture().get_image().save_png(out.path_join("creatures.png"))
	print(con.run("show ai"))
	print(con.run("show spawns"))
	print(con.run("show items"))
	for i in 20:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("creatures_debug.png"))
	var wolves: Array = game.session.npcs.records.values().filter(func(r: NpcRecord) -> bool: return r.archetype == "wolf")
	print("wolves chasing: %d of %d" % [wolves.filter(func(r: NpcRecord) -> bool: return r.state in [NpcBrain.CHASE, NpcBrain.ATTACK]).size(), wolves.size()])
	if not wolves.is_empty():
		print(con.run("why " + (wolves[0] as NpcRecord).id))
	print(con.run("show nav"))
	for i in 64 * 2:
		await physics_frame
	root.get_texture().get_image().save_png(out.path_join("nav.png"))
	print("nav tiles ready: %d" % (game.session.navigator as NavMeshNavigator).ready_count())
	print(con.run("kill 40"))
	for i in 30:
		await physics_frame
	print("ground items: %d, xp %d, corpses %d" % [game.session.items.items.size(), game.game.progress.xp, game.session.npcs.corpses.size()])
	root.get_texture().get_image().save_png(out.path_join("loot.png"))
	print(con.run("hide all"))
	# Loot a corpse through the HUD loot window.
	var cids: Array = game.session.npcs.corpses.keys()
	cids.sort_custom(func(a: String, b: String) -> bool:
		return (game.session.npcs.corpses[a].pos as Vector3).distance_to(player.global_position) < (game.session.npcs.corpses[b].pos as Vector3).distance_to(player.global_position))
	if not cids.is_empty():
		var c: Dictionary = game.session.npcs.corpses[cids[0]]
		game._teleport(c.pos + Vector3(1.5, 0.5, 0))
		player.cam.yaw = PI * 0.5
		game.hud.open_loot(game.session, cids[0])
		for i in 10:
			await process_frame
		root.get_texture().get_image().save_png(out.path_join("loot_window.png"))
		var before: int = game.game.inventory.totals().size()
		game.hud.take_all()
		print("looted %s: bag kinds %d -> %d, corpse empty %s, window closes %s" % [c.name, before, game.game.inventory.totals().size(),
			(c.loot as Array).is_empty(), true])
		for i in 5:
			await process_frame
		print("loot window open after emptying: %s" % game.hud.loot_open())
	# Day and night.
	for t in ["19:30", "23:30"]:
		print(con.run("time set " + t))
		for i in 20:
			await process_frame
		root.get_texture().get_image().save_png(out.path_join("time_%s.png" % t.replace(":", "")))
	print(con.run("time set 10:00"))


## The developer console: open it with a real backquote press, type with suggestions,
## run commands with tables, monitor panels, noclip.
func _console(game: Node, player: Player, out: String) -> void:
	var con: DebugConsole = game.game.console
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_QUOTELEFT
	ev.keycode = KEY_QUOTELEFT
	ev.pressed = true
	Input.parse_input_event(ev)
	for i in 10:
		await process_frame
	print("console open after backquote: %s, player input %s" % [con.is_open, player.input_enabled])
	var w := con.window
	w.set_line("/ti")
	for i in 5:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("console_suggest.png"))
	w.set_line("/npcs list 300")
	w.submit()
	w.set_line("/inv list")
	w.submit()
	w.set_line("/time set n")
	for i in 30:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("console_tables.png"))
	w.set_line("")
	w.escape()
	print("console closed by Esc: %s" % (not con.is_open))
	print(con.run("monitor all on"))
	for i in 30:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("monitors.png"))
	print(con.run("monitor all off"))
	var y0 := player.global_position.y
	print(con.run("noclip on"))
	Input.action_press("jump")
	for i in 30:
		await physics_frame
	Input.action_release("jump")
	print("noclip rose %.1f m" % (player.global_position.y - y0))
	print(con.run("noclip off"))
	for i in 120:
		await physics_frame
	print("after noclip: on floor %s" % player.is_on_floor())


## The skill tree: K opens it, a click learns Strike, hover shows a tooltip, K closes it.
func _skill_tree(game: Node, player: Player, out: String) -> void:
	var con: DebugConsole = game.game.console
	print(con.run("skilltree points 6"))
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_K
	ev.pressed = true
	Input.parse_input_event(ev)
	for i in 10:
		await process_frame
	var panel: SkillTreePanel = game.hud.skill_tree
	print("skill tree open after K: %s, mouse %d, player input %s" % [panel.visible, Input.mouse_mode, player.input_enabled])
	var at := panel.to_screen(panel.tree.node("ME-001").pos)
	for pressed in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = pressed
		b.position = at
		b.global_position = at
		Input.parse_input_event(b)
		await process_frame
	print("Strike rank after a click: %d" % game.game.progress.tree_rank("ME-001"))
	print(con.run("skilltree learn ME-002 2"))
	var m := InputEventMouseMotion.new()
	m.position = panel.to_screen(panel.tree.node("ME-003-2").pos)
	m.global_position = m.position
	Input.parse_input_event(m)
	for i in 10:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("skill_tree.png"))
	panel.fit()
	for i in 5:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("skill_tree_all.png"))
	ev = InputEventKey.new()
	ev.physical_keycode = KEY_K
	ev.pressed = true
	Input.parse_input_event(ev)
	for i in 5:
		await process_frame
	print("skill tree closed by K: %s, player input %s" % [not panel.visible, player.input_enabled])


## Places a training dummy and a ladder, aims at the dummy's head with the rifle, fires,
## and screenshots the weapon and the ragdoll.
func _shoot_dummy(game: Node, player: Player, out: String) -> void:
	var fwd := -player.cam.camera.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var spot := player.global_position + fwd * 7.0
	spot.y = game.world.terrain.get_height(spot)
	var yaw := atan2(-fwd.x, -fwd.z) + PI
	game.world.entities.add_entity(EntityKinds.make("smoke-dummy", "gameplay.training_dummy", "npc_dummy", spot, rad_to_deg(yaw), 1.0))
	var side := fwd.cross(Vector3.UP) * 2.5
	var lspot := spot + side
	lspot.y = game.world.terrain.get_height(lspot)
	game.world.entities.add_entity(EntityKinds.make("smoke-ladder", "gameplay.ladder", "ladder", lspot, rad_to_deg(yaw), 1.0))
	var dummy: TrainingDummy = game.world.entities.node_for("smoke-dummy")
	player.weapons.equip("rifle")
	for i in 40:
		await process_frame
	var target := dummy.global_position + Vector3.UP * 1.66
	for k in 4:  # the orbit camera moves as it turns, so converge on the aim
		var dir := (target - player.cam.camera.global_position).normalized()
		player.cam.yaw = atan2(-dir.x, -dir.z)
		player.cam.pitch = asin(dir.y)
		for i in 3:
			await process_frame
	root.get_texture().get_image().save_png(out.path_join("weapon.png"))
	var shots := 0
	while dummy.health > 0.0 and shots < 6:
		player.weapons.fire()
		shots += 1
		for i in 8:
			await physics_frame
	print("dummy: health %.0f after %d shots" % [dummy.health, shots])
	player.cam.yaw += 0.35  # the player model would hide the body
	player.cam.pitch = -0.35
	for i in 90:
		await physics_frame
	var rags: Array = game.world.entities.get_children().filter(func(c: Node) -> bool: return c is Ragdoll)
	print("ragdolls: %d" % rags.size())
	# +use: pick up the small crate placed earlier, carry it, throw it.
	var crate: Node3D = game.world.entities.node_for("smoke-0")
	var view := crate.global_position
	var stand := crate.global_position + (player.global_position - crate.global_position).normalized() * 1.4
	player.global_position = Vector3(stand.x, game.world.terrain.get_height(stand) + 0.05, stand.z)
	await physics_frame
	var aim := (view + Vector3.UP * 0.2 - (player.global_position + Vector3.UP * player.eye_height())).normalized()
	player.cam.yaw = atan2(-aim.x, -aim.z)
	player.cam.pitch = asin(aim.y)
	for i in 4:
		await physics_frame
	Input.action_press("use")
	for i in 3:
		await physics_frame
	Input.action_release("use")
	for i in 40:
		await physics_frame
	print("picked up crate: %s" % (player.carrier.held == crate))
	root.get_texture().get_image().save_png(out.path_join("ragdoll.png"))
