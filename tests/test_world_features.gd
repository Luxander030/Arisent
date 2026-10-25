extends TestCase
## P4: ambient wildlife by biome, trigger zones (story flags / events), runtime no-spawn
## camps, vegetation ids, story-graph conditions and reactions working with spawning.

var game: GameSession
var view: WorldView
var player: PlayerController
var s: WorldSession


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _world(entities: Array = [], biome := 3) -> void:
	Defs.reload()
	game = GameSession.new()
	_tree().root.add_child(game)
	view = WorldView.new()
	view.map = MapData.new()
	view.map.map_m = 4096.0
	view.map.layout_n = 1
	view.map.layout_biome = PackedByteArray([biome])
	_tree().root.add_child(view)
	view.entities.simulate_physics = true
	var fb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000, 1, 2000)
	cs.shape = box
	fb.add_child(cs)
	fb.position.y = -0.5
	view.add_child(fb)
	for e: Dictionary in entities:
		view.entities.add_entity(EntityKinds.normalize(e))
	player = PlayerController.new()
	view.add_child(player)
	player.global_position = Vector3(0, 0.05, 0)
	s = WorldSession.attach(view, game, player)


func _done() -> void:
	s.detach()
	view.queue_free()
	game.queue_free()
	await _tree().process_frame


func _ticks(n: int) -> void:
	for i in n:
		await _tree().physics_frame


func test_ambient_wildlife_by_biome() -> void:
	_world([], 3)  # Temperate Forest everywhere
	s.ambient._t = 0.0
	await _ticks(4)
	check(s.ambient.count() > 0, "forest wildlife appeared: %s" % s.ambient.last_reason)
	for id: String in s.ambient._ids:
		var r: NpcRecord = s.npcs.records[id]
		var d := Vector2(r.home.x, r.home.z).length()
		check(d >= 70.0 and d <= 160.0, "spawned in the ring (%.0f m)" % d)
		check(r.archetype in ["deer", "boar", "wolf"], "forest creatures only")
	player.global_position = Vector3(800, 0.05, 0)
	s.ambient._t = 0.0
	await _ticks(4)
	check(s.npcs.records.keys().filter(func(k: String) -> bool: return k.begins_with("ambient:") and (s.npcs.records[k] as NpcRecord).home.x < 300.0).is_empty(), "left-behind ambient creatures removed")
	var saved: Dictionary = s.save_state()
	check((saved.state.slots as Dictionary).is_empty() and (saved.state.unique as Dictionary).is_empty(), "ambient wildlife is never saved")
	await _done()
	_world([], 7)  # Desert: no rule
	s.ambient._t = 0.0
	await _ticks(4)
	check(s.ambient.count() == 0 and s.ambient.last_reason.begins_with("no rule"), "no wildlife without a rule: " + s.ambient.last_reason)
	await _done()


func test_ambient_respects_authored_zones() -> void:
	var z := EntityKinds.make("ns", "", "zone", Vector3.ZERO, 0.0, 1.0)
	z.shape = {"type": "circle", "radius": 400.0}
	z.props.roles = ["no_spawn"]
	_world([z], 3)
	for i in 3:
		s.ambient._t = 0.0
		await _ticks(2)
	eq(s.ambient.count(), 0, "nothing ambient inside an authored no-spawn area")
	eq(s.ambient.last_reason, "inside an authored zone", "and says why")
	await _done()


func test_trigger_zone_sets_flag_once() -> void:
	var t := EntityKinds.make("gate", "", "zone", Vector3(20, 0, 0), 0.0, 1.0)
	t.shape = {"type": "circle", "radius": 5.0}
	t.props.roles = ["trigger"]
	t.props.on_enter_flag = "entered_gate"
	var sp := EntityKinds.make("sp", "gameplay.spawner", "spawner", Vector3(-30, 0, 0), 0.0, 1.0)
	sp.props.archetype = "wolf"
	sp.props.condition = StoryCondition.make(StoryCondition.Kind.FLAG_SET, "entered_gate").to_dict()
	_world([t, sp], 7)  # desert: no ambient wildlife to confuse the counts
	await _ticks(20)
	eq(s.npcs.records.size(), 0, "conditional spawner waits")
	player.global_position = Vector3(20, 0.05, 0)
	await _ticks(40)
	check(game.story_state.has_flag("entered_gate"), "entering the trigger set the flag")
	check(s.npcs.records.values().any(func(r: NpcRecord) -> bool: return r.archetype == "wolf"), "and the conditional spawner reacted")
	check(bool(s.state.zone("gate").get("fired", false)), "remembered as fired (saved with the map state)")
	await _done()


func test_story_event_from_trigger() -> void:
	_world()
	var lines: Array[String] = []
	game.notified.connect(func(t: String) -> void: lines.append(t))
	game.story_event("start")
	check(lines.any(func(l: String) -> bool: return l.contains("Innkeeper")), "story dialogue reaches the feed: %s" % str(lines))
	await _done()


func test_camp_blocks_zone_spawning_and_is_saved() -> void:
	var z := EntityKinds.make("z", "", "zone", Vector3(60, 0, 0), 0.0, 1.0)
	z.shape = {"type": "circle", "radius": 15.0}
	z.props.min_player_dist = 0.0
	z.props.max_alive = 3
	z.props.spawn_table = [{"archetype": "deer", "weight": 1.0, "group_min": 1, "group_max": 1, "level_min": 0, "level_max": 0}]
	_world([z], 7)
	player.global_position = Vector3(60, 0.05, 0)
	game.console.run("camp make 40")
	await _ticks(20)
	eq(s.npcs.records.size(), 0, "camp keeps the zone empty")
	check(str(s.spawns.slot("z#0").block_reason).contains("no usable ground") or str(s.spawns.slot("z#0").block_reason).contains("no-spawn"), "reason: " + s.spawns.slot("z#0").block_reason)
	var saved: Dictionary = s.save_state()
	eq((saved.state.runtime_zones as Array).size(), 1, "camp saved")
	await _done()


func test_vegetation_ids() -> void:
	var id := VegetationIds.id_for("nature.tree_oak", Vector3(12.26, 5.0, -3.74))
	eq(id, "veg:nature.tree_oak:25:-7", "position rounded to 0.5 m")
	var d := VegetationIds.parse(id)
	check(d.asset == "nature.tree_oak" and (d.pos as Vector3).is_equal_approx(Vector3(12.5, 0, -3.5)), "parses back")
	check(VegetationIds.parse("entity-123").is_empty(), "other ids are not vegetation")


func test_encounter_zone_resets_after_absence() -> void:
	var enc := EntityKinds.make("enc", "", "zone", Vector3(0, 0, 0), 0.0, 1.0)
	enc.shape = {"type": "circle", "radius": 80.0}
	enc.props.roles = ["encounter"]
	enc.props.reset_hours = 2.0
	var sp := EntityKinds.make("sp", "gameplay.spawner", "spawner", Vector3(20, 0, 0), 0.0, 1.0)
	sp.props.archetype = "boar"
	sp.props.respawn = 7200.0
	sp.props.movement = "idle"
	_world([enc, sp], 7)
	await _ticks(20)
	var boar: NpcRecord = s.npcs.records.values()[0]
	s.npcs.damage(boar.id, DamageInfo.make(999, "bullet", "player"))
	check(s.state.zone("enc").has("last_visit"), "visit recorded")
	player.global_position = Vector3(500, 0.05, 0)  # leave
	await _ticks(20)
	game.clock.skip(3.0 * 3600.0)
	player.global_position = Vector3(0, 0.05, 0)    # come back after 3 h (reset after 2 h)
	await _ticks(40)
	check(s.npcs.records.values().any(func(r: NpcRecord) -> bool: return r.archetype == "boar"), "dead boar came back early: the area was repopulated")
	await _done()


func test_simulate_never_changes_the_map() -> void:
	_world([], 7)
	game.ephemeral = true
	check(game.console.run("fell").begins_with("not while simulating"), "fell refused in Simulate")
	await _done()

func test_xp_formula() -> void:
	# Owner's formula: XP for level L = base · L · (L − 1) / 2 (base 100).
	eq(PlayerProgress.xp_for(1), 0, "level 1 needs nothing")
	eq(PlayerProgress.xp_for(2), 100, "level 2")
	eq(PlayerProgress.xp_for(5), 1000, "level 5")
	eq(PlayerProgress.xp_for(10), 4500, "level 10")
	eq(PlayerProgress.level_for(99), 1, "99 xp: level 1")
	eq(PlayerProgress.level_for(100), 2, "100 xp: level 2")
	eq(PlayerProgress.level_for(4499), 9, "just below level 10")
	eq(PlayerProgress.level_for(4500), 10, "level 10")
	eq(PlayerProgress.xp_for(3, PlayerProgress.SKILL_BASE_XP), 150, "skills use the same formula with their base")


func test_never_spawns_in_view() -> void:
	var sp := EntityKinds.make("sp", "gameplay.spawner", "spawner", Vector3(40, 0, 0), 0.0, 1.0)
	sp.props.archetype = "boar"
	sp.props.respawn = 10.0
	sp.props.respawn_jitter = 0.0
	sp.props.movement = "idle"
	_world([sp], 7)
	var looking := {"at": true}
	s.spawns.visibility = func(_p: Vector3) -> bool: return looking.at
	await _ticks(10)
	eq(s.npcs.records.size(), 1, "the world fills up while the map loads (nothing was on screen yet)")
	var boar: NpcRecord = s.npcs.records.values()[0]
	s.npcs.damage(boar.id, DamageInfo.make(999, "bullet", "player"))
	game.clock.skip(600.0)
	await _ticks(40)
	eq(s.npcs.records.size(), 0, "never respawns while the player looks at the spot")
	check(s.spawns.slot("sp#0").block_reason.begins_with("in the player's view"), "why: " + s.spawns.slot("sp#0").block_reason)
	looking.at = false
	await _ticks(20)
	eq(s.npcs.records.size(), 1, "respawns once the player looks away")
	await _done()


func test_day_night_lighting() -> void:
	var v := WorldView.new()
	_tree().root.add_child(v)
	v.set_time_of_day(12.0)
	check(v.sun.light_energy > 1.0 and v.sun.shadow_enabled and v.moon.light_energy < 0.01, "noon: bright sun with shadows")
	var noon_sky: Color = v._sky_mat.sky_top_color
	v.set_time_of_day(0.0)
	check(v.sun.light_energy < 0.01 and not v.sun.shadow_enabled and v.moon.light_energy > 0.05, "midnight: no sun, moonlight")
	check(v._sky_mat.sky_top_color.get_luminance() < noon_sky.get_luminance() * 0.3, "dark sky at night")
	v.set_time_of_day(6.5)
	check(v.sun.light_energy > 0.0 and v.sun.light_energy < 1.0, "dawn: rising sun")
	v.queue_free()
	await _tree().process_frame
