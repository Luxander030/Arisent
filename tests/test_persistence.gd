extends TestCase
## Persistence (P2): generational saves (atomic manifest, fallback, byte-copied maps, format
## check), game state round trip, and world state: dead slots, unique NPCs, ground items and
## their policies, opened chests, moved props — and what happens when the map was edited
## after the save.

var game: GameSession
var view: WorldView
var player: PlayerController
var s: WorldSession


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _clean(slot: String) -> void:
	var d := SaveService.slot_dir(slot)
	if DirAccess.dir_exists_absolute(d):
		SaveService._remove_tree(d)


func _world(entities: Array, map_rev := 1) -> void:
	Defs.reload()
	game = GameSession.new()
	_tree().root.add_child(game)
	view = WorldView.new()
	view.map = MapData.new()
	view.map.map_uid = "testmap"
	view.map.revision = map_rev
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


func _spawner(id: String, arch: String, pos: Vector3, props := {}) -> Dictionary:
	var e := EntityKinds.make(id, "gameplay.spawner", "spawner", pos, 0.0, 1.0)
	e.props.archetype = arch
	e.props.merge(props, true)
	return e


# --- save files ---------------------------------------------------------------------------

func test_generations_roundtrip_and_cleanup() -> void:
	_clean("t_gen")
	var sv := SaveService.new()
	for i in 4:
		eq(sv.save_sync("t_gen", {"game": {"n": i}, "maps": {"A": {"state": {"x": i}, "dynamic": {"r_0_0": {"items": [i]}}}}}), OK, "save %d" % i)
	var d := sv.load_save("t_gen")
	eq(int(d.game.n), 3, "latest generation loaded")
	eq(int(d.maps.A.state.x), 3, "map state")
	eq(int(d.maps.A.dynamic.r_0_0.items[0]), 3, "dynamic region")
	var gens := Array(DirAccess.get_directories_at(SaveService.slot_dir("t_gen"))).filter(func(x: String) -> bool: return x.begins_with("gen_"))
	eq(gens.size(), SaveService.KEEP_GENERATIONS, "old generations removed")
	_clean("t_gen")


func test_unloaded_maps_carry_over() -> void:
	_clean("t_multi")
	var sv := SaveService.new()
	sv.save_sync("t_multi", {"game": {"playthrough": "p1"}, "maps": {"A": {"state": {"a": 1}}, "B": {"state": {"b": 2}, "dynamic": {"r_1_1": {"items": [7]}}}}})
	sv.save_sync("t_multi", {"game": {"playthrough": "p1"}, "maps": {"A": {"state": {"a": 5}}}})
	var d := sv.load_save("t_multi")
	eq(int(d.maps.A.state.a), 5, "loaded map updated")
	check(d.maps.has("B") and int(d.maps.B.state.b) == 2, "map not in this save copied from the previous generation")
	check(int(d.maps.B.dynamic.r_1_1.items[0]) == 7, "including its dynamic files")
	# A different play-through (new game) saving into the same slot inherits nothing.
	sv.save_sync("t_multi", {"game": {"playthrough": "p2"}, "maps": {"A": {"state": {"a": 9}}}})
	check(not sv.load_save("t_multi").maps.has("B"), "a new game doesn't inherit another game's maps")
	_clean("t_multi")


func test_crash_and_corruption_fall_back() -> void:
	_clean("t_crash")
	var sv := SaveService.new()
	sv.save_sync("t_crash", {"game": {"n": 1}, "maps": {}})
	sv.save_sync("t_crash", {"game": {"n": 2}, "maps": {}})
	var dir := SaveService.slot_dir("t_crash")
	# A crash while writing gen 3: its folder exists but the manifest still points at gen 2.
	DirAccess.make_dir_recursive_absolute(dir.path_join("gen_3"))
	eq(int(sv.load_save("t_crash").game.n), 2, "half-written generation ignored")
	# Damaged current game.bin: checksum mismatch -> previous generation.
	var f := FileAccess.open(dir.path_join("gen_2/game.bin"), FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	eq(int(sv.load_save("t_crash").game.n), 1, "damaged generation skipped")
	# Lost manifest: scan generations.
	DirAccess.remove_absolute(dir.path_join("manifest.bin"))
	DirAccess.remove_absolute(dir.path_join("manifest.bak"))
	eq(int(sv.load_save("t_crash").game.n), 1, "works without a manifest")
	sv.save_sync("t_crash", {"game": {"n": 9}, "maps": {}})
	eq(int(sv.load_save("t_crash").game.n), 9, "saving again recovers")
	check(not DirAccess.dir_exists_absolute(dir.path_join("gen_3")) or sv.load_save("t_crash").generation > 3, "orphaned generation cleaned or superseded")
	_clean("t_crash")


func test_old_format_refused_and_async() -> void:
	_clean("t_fmt")
	var sv := SaveService.new()
	sv.save_async("t_fmt", {"game": {"n": 4}, "maps": {}})
	sv.wait()
	eq(int(sv.load_save("t_fmt").game.n), 4, "background save completed")
	var g := SaveService.slot_dir("t_fmt").path_join("gen_%d/game.bin" % sv.load_save("t_fmt").generation)
	var f := FileAccess.open(g, FileAccess.WRITE)
	f.store_buffer(var_to_bytes({"format_version": 0}))
	f.close()
	DirAccess.remove_absolute(SaveService.slot_dir("t_fmt").path_join("manifest.bin"))
	DirAccess.remove_absolute(SaveService.slot_dir("t_fmt").path_join("manifest.bak"))
	check(sv.load_save("t_fmt").is_empty() and sv.last_error.contains("not supported"), "old format refused: " + sv.last_error)
	check(sv.list_slots().all(func(x: Dictionary) -> bool: return x.slot != "t_fmt"), "and not listed")
	_clean("t_fmt")


# --- game and world state --------------------------------------------------------------------

func test_game_state_roundtrip() -> void:
	Defs.reload()
	var a := GameSession.new()
	_tree().root.add_child(a)
	a.inventory.add("wolf_pelt", 3)
	a.progress.add_xp(120)
	a.progress.add_skill_xp("skinning", 40)
	a.story_state.set_flag("met_guard")
	a.clock.now = 1234.0
	a.time_of_day.set_hours(21.5)
	var data := bytes_to_var(var_to_bytes(a.to_save())) as Dictionary
	var b := GameSession.new()
	_tree().root.add_child(b)
	b.apply_save(data)
	check(b.inventory.count_of("wolf_pelt") == 3 and b.progress.xp == 120 and int(b.progress.skills.skinning) == 40, "bag and progress")
	check(b.story_state.has_flag("met_guard") and is_equal_approx(b.clock.now, 1234.0) and is_equal_approx(b.time_of_day.hours, 21.5), "story and clocks")
	a.queue_free()
	b.queue_free()
	await _tree().process_frame


func test_world_state_survives_save_and_load() -> void:
	var u := EntityKinds.make("chief", "gameplay.unique_npc", "unique_npc", Vector3(-40, 0, 0), 0.0, 1.0)
	u.props.archetype = "bandit_chief"
	u.props.respawn = 0.0
	var u2 := EntityKinds.make("hermit", "gameplay.unique_npc", "unique_npc", Vector3(40, 0, 30), 0.0, 1.0)
	u2.props.archetype = "boar"
	var chest := EntityKinds.make("box", "gameplay.chest", "chest", Vector3(2, 0, 0), 0.0, 1.0)
	var crate := EntityKinds.make("crate", "props.crate_small", "physics_prop", Vector3(0, 0, -4), 0.0, 1.0)
	var ents := [_spawner("w", "wolf", Vector3(30, 0, 0), {"respawn": 600.0, "respawn_jitter": 0.0, "movement": "idle"}), u, u2, chest, crate]
	_world(ents)
	await _ticks(10)
	var wolf: NpcRecord = s.npcs.records.values().filter(func(r: NpcRecord) -> bool: return r.archetype == "wolf")[0]
	s.npcs.damage(wolf.id, DamageInfo.make(5000, "bullet", "player"))
	s.npcs.damage("unique:chief", DamageInfo.make(5000, "bullet", "player"))
	var hermit: NpcRecord = s.npcs.records["unique:hermit"]
	hermit.pos = Vector3(44, 0, 33)
	hermit.health = 20.0
	var mine := s.items.drop("wolf_pelt", 2, Vector3(5, 0, 5), "player_dropped")
	var loot := s.items.drop("wolf_fang", 1, Vector3(6, 0, 6))
	s.items.items[loot].expires_at = game.clock.now + 150.0
	s.open_chest("box")
	var crate_node := view.entities.node_for("crate") as PhysicsProp
	crate_node.global_position = Vector3(10, 0.3, 10)
	crate_node.freeze = true
	game.clock.now += 50.0
	var respawn_at := s.spawns.slot("w#0").respawn_at
	var saved := bytes_to_var(var_to_bytes(s.save_state())) as Dictionary
	var game_saved := bytes_to_var(var_to_bytes(game.to_save())) as Dictionary
	await _done()
	# New session from the same map, then apply the save.
	_world(ents)
	game.apply_save(game_saved)
	var warnings := s.apply_save(saved)
	eq(warnings.size(), 0, "no warnings: %s" % str(warnings))
	await _ticks(10)
	var sl := s.spawns.slot("w#0")
	check(sl.state == SpawnDirector.DEAD and is_equal_approx(sl.respawn_at, respawn_at), "dead wolf stays dead until its respawn time")
	eq(s.npcs.records.values().filter(func(r: NpcRecord) -> bool: return r.archetype == "wolf").size(), 0, "no wolf yet")
	eq(s.spawns.slot("chief#0").state, SpawnDirector.GONE, "unique killed for good stays gone")
	var h: NpcRecord = s.npcs.records.get("unique:hermit")
	check(h != null and h.pos.distance_to(Vector3(44, 0, 33)) < 0.5 and is_equal_approx(h.health, 20.0), "unique NPC keeps place and health")
	check(s.items.items.has(mine) and s.items.items[mine].policy == "player_dropped", "dropped item still there")
	check(s.items.items.has(loot) and absf(float(s.items.items[loot].expires_at) - (game.clock.now + 100.0)) < 1.0, "item keeps its expiry time")
	var corpse_loot := s.npcs.corpses.values().filter(func(c: Dictionary) -> bool: return c.archetype == "wolf")
	check(corpse_loot.size() == 1 and not (corpse_loot[0].loot as Array).is_empty(), "the wolf's corpse and its loot are still there")
	check(s.state.is_opened("box", game.clock.now, 0.0), "chest stays opened")
	check(s.interaction.best(Vector3(2, 0, -1), Vector3.BACK).get("prompt", "") != "Open chest", "and can't be opened again")
	var c := view.entities.node_for("crate")
	check(c and Vector2(c.global_position.x - 10.0, c.global_position.z - 10.0).length() < 0.2, "pushed crate stays where it was pushed")
	await _done()


func test_map_edited_after_save() -> void:
	var z := EntityKinds.make("z", "", "zone", Vector3(200, 0, 0), 0.0, 1.0)
	z.shape = {"type": "circle", "radius": 30.0}
	z.props.max_alive = 4
	z.props.min_player_dist = 0.0
	z.props.respawn = 900.0
	z.props.spawn_table = [{"archetype": "deer", "weight": 1.0, "group_min": 1, "group_max": 1, "level_min": 0, "level_max": 0}]
	var sp := _spawner("sp", "boar", Vector3(20, 0, 0), {"respawn": 900.0, "movement": "idle"})
	_world([z, sp])
	player.global_position = Vector3(150, 0.05, 0)
	await _ticks(12)
	for r: NpcRecord in s.npcs.records.values():
		s.npcs.damage(r.id, DamageInfo.make(5000, "bullet", "player"))
	var saved := bytes_to_var(var_to_bytes(s.save_state())) as Dictionary
	await _done()
	# The designer moves the spawner across a region border, lowers the zone to 2 slots,
	# and saves the map (revision 2).
	sp.pos = [700.0, 0.0, 300.0]
	z.props.max_alive = 2
	_world([z, sp], 2)
	var warnings := s.apply_save(saved)
	check(warnings.size() == 2, "warns about the revision and dropped slots: %s" % str(warnings))
	eq(s.spawns.slot("sp#0").state, SpawnDirector.DEAD, "moved spawner keeps its state (keyed by id, not position)")
	check(s.spawns.slot("z#1").state == SpawnDirector.DEAD and s.spawns.slot("z#2") == null, "zone slots beyond the new max dropped")
	await _done()
	z.props.max_alive = 5
	_world([z, sp], 3)
	s.apply_save(saved)
	eq(s.spawns.slot("z#4").state, SpawnDirector.UNSPAWNED, "raised max_alive adds fresh slots")
	eq(s.spawns.slot("z#0").state, SpawnDirector.DEAD, "old ones keep their state")
	await _done()
