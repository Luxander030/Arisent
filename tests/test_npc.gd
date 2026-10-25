extends TestCase
## NPC runtime (P1): spawners and slots, AI (wander, aggro, chase, attack, leash/evade,
## flee), kills (XP, loot, respawn), distance tiers and budgets, far hits, fast-forward,
## unique NPCs, spawn groups, zones, loot tables, ground items, interaction, "why".

var game: GameSession
var view: WorldView
var player: PlayerController
var s: WorldSession


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## A flat 2 km floor, a player at the origin, and a session with the given entities.
func _world(entities: Array = []) -> void:
	Defs.reload()
	game = GameSession.new()
	_tree().root.add_child(game)
	view = WorldView.new()
	_tree().root.add_child(view)
	view.entities.simulate_physics = true
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000, 1, 2000)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position.y = -0.5
	view.add_child(floor_body)
	for e: Dictionary in entities:
		view.entities.add_entity(EntityKinds.normalize(e))
	player = PlayerController.new()
	view.add_child(player)
	player.global_position = Vector3(0, 0.05, 0)
	s = WorldSession.attach(view, game, player)
	s.queries.collision_radius = 64.0


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


func _alive(arch := "") -> Array[NpcRecord]:
	var out: Array[NpcRecord] = []
	for r: NpcRecord in s.npcs.records.values():
		if r.alive and (arch == "" or r.archetype == arch):
			out.append(r)
	return out


# --- spawning and AI -----------------------------------------------------------------------

func test_spawner_spawns_count_and_wanders() -> void:
	_world([_spawner("sp", "boar", Vector3(20, 0, 0), {"count": 3, "wander_radius": 8.0})])
	await _ticks(8)
	var boars := _alive("boar")
	eq(boars.size(), 3, "three boars")
	eq(s.spawns.slot("sp#2").state, SpawnDirector.ALIVE, "slots alive")
	game.clock.scale = 4.0
	await _ticks(64 * 6)
	var outside := 0
	var moved := 0
	for b in boars:
		if Vector2(b.pos.x - 20.0, b.pos.z).length() > 8.0 + 3.0:
			outside += 1
		if b.log.size() > 1:
			moved += 1
	eq(outside, 0, "wander stays within the radius")
	check(moved >= 2, "they wander (%d with state changes)" % moved)
	await _done()


func test_aggro_chase_attack_leash_and_return() -> void:
	_world([_spawner("w", "wolf", Vector3(12, 0, 0), {"wander_radius": 0.0, "movement": "idle"})])
	await _ticks(10)
	var wolf: NpcRecord = _alive("wolf")[0]
	await _ticks(64 * 3)
	check(wolf.state == NpcBrain.CHASE or wolf.state == NpcBrain.ATTACK, "wolf noticed the player (%s)" % NpcBrain.NAMES[wolf.state])
	await _ticks(64 * 3)
	check(player.health < 100.0, "wolf bites (health %.0f)" % player.health)
	check(wolf.tier == SimScheduler.ACTIVE and wolf.physics_mode, "close fighting creature is ACTIVE with physics")
	# Run far away: past the leash, the wolf gives up and goes home.
	player.global_position = Vector3(-120, 0.05, 0)
	await _ticks(64 * 9)
	check(wolf.state == NpcBrain.RETURN or wolf.state == NpcBrain.IDLE, "wolf leashes (%s)" % NpcBrain.NAMES[wolf.state])
	var saw_return := wolf.log.any(func(e: Array) -> bool: return e[2] == "RETURN")
	check(saw_return, "log says why: %s" % str(wolf.log.slice(-3)))
	s.npcs.damage(wolf.id, DamageInfo.make(10, "bullet", "player"))
	if wolf.state == NpcBrain.RETURN:
		check(is_equal_approx(wolf.health, wolf.max_health) or wolf.health > wolf.max_health - 0.1, "invulnerable while evading")
	await _ticks(64 * 10)
	eq(wolf.state, NpcBrain.IDLE, "back home and idle")
	check(Vector2(wolf.pos.x - 12.0, wolf.pos.z).length() < 3.0, "at home")
	await _done()


func test_passive_animal_flees_when_hurt() -> void:
	_world([_spawner("c", "chicken", Vector3(6, 0, 0), {"wander_radius": 0.0, "movement": "idle"})])
	await _ticks(10)
	var hen: NpcRecord = _alive("chicken")[0]
	s.npcs.damage(hen.id, DamageInfo.make(2, "bullet", "player"))
	eq(hen.state, NpcBrain.FLEE, "flees when hurt")
	var d0 := hen.pos.distance_to(player.global_position)
	await _ticks(64 * 2)
	check(hen.pos.distance_to(player.global_position) > d0 + 3.0, "runs away from the player")
	await _done()


func test_kill_gives_xp_loot_and_respawns() -> void:
	_world([_spawner("w", "wolf", Vector3(30, 0, 0), {"respawn": 60.0, "respawn_jitter": 0.0, "movement": "idle"})])
	await _ticks(10)
	var wolf: NpcRecord = _alive("wolf")[0]
	s.npcs.damage(wolf.id, DamageInfo.make(1000, "bullet", "player"))
	check(not wolf.alive and not s.npcs.records.has(wolf.id), "dead and removed")
	check(game.progress.xp >= 18, "xp awarded (%d)" % game.progress.xp)
	check(int(game.progress.skills.get("hunting", 0)) > 0, "skill xp awarded")
	check(s.items.items.is_empty(), "nothing spills on the ground (WoW: loot stays on the corpse)")
	check(s.npcs.corpses.size() == 1 and not (s.npcs.corpses.values()[0].loot as Array).is_empty(), "a corpse with loot")
	var slot := s.spawns.slot("w#0")
	eq(slot.state, SpawnDirector.DEAD, "slot dead")
	check(absf(slot.respawn_at - (game.clock.now + 60.0)) < 1.0, "respawn in 60 s")
	await _ticks(16)
	eq(_alive("wolf").size(), 0, "not before its time")
	game.console.run("skip 0.02")  # 72 s
	await _ticks(16)
	eq(_alive("wolf").size(), 1, "respawned after the timer")
	eq(slot.life_count, 1, "second life")
	await _done()


func test_tiers_respect_budgets() -> void:
	_world()
	for i in 200:
		var a := float(i) * 0.7
		var r := 5.0 + float(i) * 4.0
		s.npcs.spawn("deer", Vector3(cos(a) * r, 0, sin(a) * r), {"movement": "idle"})
	await _ticks(20)
	var c := s.npcs.count_by_tier()
	check(c[0] <= 24 and c[0] > 0, "active within budget (%d)" % c[0])
	check(c[1] <= 64, "near within budget (%d)" % c[1])
	eq(c[0] + c[1] + c[2] + c[3], 200, "every record has a tier")
	var bodies := 0
	for n in s.npcs.get_children():
		if n is NpcBody:
			bodies += 1
	eq(bodies, c[0] + c[1], "bodies only for ACTIVE and NEAR")
	for r: NpcRecord in s.npcs.records.values():
		if r.pos.length() > 620.0:
			check(r.tier == SimScheduler.DORMANT, "beyond 600 m dormant")
			break
	await _done()


func test_far_creature_hit_without_body() -> void:
	_world()
	s.npcs.scheduler.max_near = 0
	s.npcs.scheduler.r_active = 10.0
	var deer := s.npcs.spawn("deer", Vector3(0, 0, -120), {"movement": "idle"})
	await _ticks(10)
	check(deer.node_id == 0 and deer.tier == SimScheduler.FAR, "no body at 120 m with NEAR budget 0")
	var hits := Hitscan.fire(s.queries, Vector3(0, 0.65, 0), Vector3.FORWARD, WeaponDefs.get_def("sniper"))
	check(hits.size() == 1 and hits[0].hitgroup == "body", "hit through the record test")
	check(not deer.alive or deer.health < deer.max_health, "took damage")
	await _done()


func test_dormant_fast_forward() -> void:
	_world()
	var boar := s.npcs.spawn("boar", Vector3(800, 0, 0), {"wander_radius": 10.0})
	boar.health = 5.0
	await _ticks(10)
	eq(boar.tier, SimScheduler.DORMANT, "dormant far away")
	game.clock.skip(600.0)
	player.global_position = Vector3(790, 0.05, 0)
	await _ticks(20)
	check(boar.tier != SimScheduler.DORMANT, "woke when the player came")
	check(is_equal_approx(boar.health, boar.max_health), "healed while away")
	check(Vector2(boar.pos.x - 800.0, boar.pos.z).length() <= 11.0, "somewhere in its area")
	await _done()


func test_unique_npc_killed_for_good() -> void:
	var u := EntityKinds.make("chief", "gameplay.unique_npc", "unique_npc", Vector3(15, 0, 0), 0.0, 1.0)
	u.props.archetype = "bandit_chief"
	u.props.name = "Rorik"
	_world([u])
	await _ticks(10)
	var r: NpcRecord = s.npcs.records.get("unique:chief")
	check(r != null and r.display_name == "Rorik", "unique NPC spawned with its name")
	s.npcs.damage(r.id, DamageInfo.make(5000, "bullet", "player"))
	eq(s.spawns.slot("chief#0").state, SpawnDirector.GONE, "gone for good")
	check(game.story_state.has_flag("bandit_chief_killed"), "death reaction set a story flag")
	game.clock.skip(100000.0)
	await _ticks(20)
	check(not s.npcs.records.has("unique:chief"), "never respawns")
	await _done()


func test_spawn_group_limits_and_weights() -> void:
	var g := EntityKinds.make("grp", "gameplay.spawn_group", "spawn_group", Vector3(30, 0, 0), 0.0, 1.0)
	g.props.max_alive = 1
	var ents: Array = [g]
	for i in 3:
		ents.append(_spawner("m%d" % i, "deer" if i < 2 else "dire_wolf", Vector3(30 + i * 10, 0, 0),
			{"group": "grp", "group_weight": 0.0 if i < 2 else 0.0, "respawn": 10.0, "respawn_jitter": 0.0, "movement": "idle"}))
	_world(ents)
	await _ticks(16)
	eq(_alive().size(), 1, "pick 1 of 3")
	var first: NpcRecord = _alive()[0]
	s.npcs.damage(first.id, DamageInfo.make(5000, "bullet", "player"))
	game.clock.skip(15.0)
	await _ticks(16)
	eq(_alive().size(), 1, "one respawned (maybe another member)")
	var reasons := s.spawns.slots.values().filter(func(x: SpawnDirector.Slot) -> bool: return x.state != SpawnDirector.ALIVE).map(func(x: SpawnDirector.Slot) -> String: return x.block_reason)
	check(reasons.any(func(r: String) -> bool: return r.begins_with("group limit")), "others wait: %s" % str(reasons))
	await _done()


func test_zone_spawning_respects_no_spawn() -> void:
	var z := EntityKinds.make("z", "", "zone", Vector3(100, 0, 0), 0.0, 1.0)
	z.shape = {"type": "circle", "radius": 40.0}
	z.props.max_alive = 6
	z.props.min_player_dist = 0.0
	z.props.spawn_table = [{"archetype": "deer", "weight": 1.0, "group_min": 2, "group_max": 2, "level_min": 0, "level_max": 0}]
	var ns := EntityKinds.make("ns", "", "zone", Vector3(100, 0, -20), 0.0, 1.0)
	ns.shape = {"type": "box", "size": [100.0, 40.0]}
	ns.props.roles = ["no_spawn"]
	_world([z, ns])
	await _ticks(16)
	var deer := _alive("deer")
	eq(deer.size(), 6, "zone filled (initial: full)")
	for d in deer:
		check(ZoneShape.contains(view.entities.entity("z"), d.home) and d.home.z > 0.0, "spawned inside the zone, outside no-spawn (%s)" % str(d.home))
	var pts := s.spawns.zone_points(view.entities.entity("z"))
	check(pts.size() > 10 and Array(pts).all(func(q: Vector3) -> bool: return q.z > 0.0), "candidates exclude the no-spawn area")
	await _done()


# --- loot, items, interaction, why ---------------------------------------------------------

func test_loot_table_semantics() -> void:
	Defs.reload()
	var dagger := 0
	var potion := 0
	for i in 400:
		var drops := Loot.roll("bandit", i)
		var items := drops.map(func(d: Dictionary) -> String: return d.item)
		check(items.has("coin"), "coins always drop")
		var g := (1 if items.has("rusty_dagger") else 0) + (1 if items.has("health_potion") and not items.has("leather_scraps") else 0)
		if items.has("rusty_dagger"):
			dagger += 1
		if items.has("health_potion"):
			potion += 1
	check(dagger > 10 and dagger < 70, "dagger ~8%% (%d/400)" % dagger)
	check(potion > 40, "potion from group and reference (%d/400)" % potion)
	eq(Loot.roll("wolf", 7), Loot.roll("wolf", 7), "deterministic per seed")


func test_ground_item_policies() -> void:
	_world()
	var loot := s.items.drop("wolf_fang", 2, Vector3(5, 0, 0))
	var mine := s.items.drop("wolf_fang", 1, Vector3(6, 0, 0), "player_dropped")
	var mine_far := s.items.drop("wolf_pelt", 1, Vector3(900, 0, 0), "player_dropped")
	var quest := s.items.drop("chief_signet", 1, Vector3(7, 0, 0))
	eq(s.items.items[quest].policy, "quest", "quest items keep their policy")
	game.console.run("skip 0.1")  # 6 minutes
	check(not s.items.items.has(loot), "spilled loot expired after 5 minutes")
	check(s.items.items.has(mine) and s.items.items.has(mine_far) and s.items.items.has(quest), "player drops and quest items still there")
	game.console.run("skip 1")
	check(not s.items.items.has(mine) and not s.items.items.has(mine_far), "player drops expire after an hour, near or far")
	check(s.items.items.has(quest), "quest items never expire")
	var coin := s.items.drop("coin", 5, Vector3(0.5, 0, 0), "", 0.0)
	await _ticks(30)
	check(not s.items.items.has(coin) and game.inventory.count_of("coin") == 5, "coins picked up when walked over")
	await _done()


func test_inventory_stacks() -> void:
	Defs.reload()
	var inv := Inventory.new()
	inv.capacity = 2
	eq(inv.add("wolf_pelt", 25), 25, "fits in two stacks of 20")
	eq(inv.add("wolf_pelt", 30), 15, "only 15 more fit")
	eq(inv.remove("wolf_pelt", 5), 5, "removed")
	eq(inv.count_of("wolf_pelt"), 35, "count")


func test_interaction_loots_corpse_then_skins() -> void:
	_world([_spawner("w", "wolf", Vector3(2, 0, 0), {"movement": "idle"})])
	await _ticks(4)
	var wolf: NpcRecord = _alive("wolf")[0]
	wolf.pos = Vector3(2, 0, 0)
	s.npcs.damage(wolf.id, DamageInfo.make(1000, "bullet", "player"))
	var corpse: Dictionary = s.npcs.corpses.values()[0]
	var expires: float = corpse.expires_at
	var best := s.interaction.best(player.global_position, Vector3.RIGHT)
	check(not best.is_empty() and str(best.prompt).begins_with("Loot"), "loot first: %s" % best.get("prompt", "none"))
	(best.act as Callable).call()  # no loot window here: takes everything
	check(game.inventory.count_of("coin") > 0, "coins and loot in the bag")
	check((corpse.loot as Array).is_empty() and float(corpse.expires_at) < expires, "emptied corpse decays sooner")
	best = s.interaction.best(player.global_position, Vector3.RIGHT)
	check(not best.is_empty() and str(best.prompt).begins_with("Skin"), "then skin the corpse: %s" % best.get("prompt", "none"))
	if not best.is_empty():
		(best.act as Callable).call()
	check(game.inventory.count_of("wolf_pelt") == 1 and int(game.progress.skills.get("skinning", 0)) > 0, "pelt + skinning xp")
	await _done()


func test_why_reports_block_reasons() -> void:
	_world([_spawner("a", "", Vector3(20, 0, 0)),
		_spawner("b", "wolf", Vector3(-20, 0, 0), {"condition": StoryCondition.make(StoryCondition.Kind.FLAG_SET, "wolves_awake").to_dict()})])
	await _ticks(10)
	check(s.spawns.slot("a#0").block_reason == "no archetype", "missing archetype")
	check(s.spawns.slot("b#0").block_reason.begins_with("condition not met"), "condition: " + s.spawns.slot("b#0").block_reason)
	check(game.console.run("why b#0").contains("flag wolves_awake"), "console why explains")
	game.story_state.set_flag("wolves_awake")
	await _ticks(20)
	eq(s.spawns.slot("b#0").state, SpawnDirector.ALIVE, "spawns once the flag is set")
	await _done()


func test_benchmark_1000_creatures() -> void:
	_world()
	for i in 1000:
		var x := (Rng.hash2f(i, 1, 5) - 0.5) * 3000.0
		var z := (Rng.hash2f(i, 2, 5) - 0.5) * 3000.0
		s.npcs.spawn(["deer", "boar", "wolf", "sheep"][i % 4], Vector3(x, 0, z), {"wander_radius": 10.0})
	for i in 40:
		s.npcs.spawn("deer", Vector3(randf_range(-50, 50), 0, randf_range(-50, 50)), {"wander_radius": 10.0})
	await _ticks(64)
	s.npcs.reset_stats()
	await _ticks(64 * 3)
	var tick_ms := s.npcs.avg_tick_ms()
	var sched_ms := s.npcs.avg_sched_ms()
	var c := s.npcs.count_by_tier()
	print("    1040 creatures: AI+movement %.2f ms/tick, scheduling %.2f ms/pass (max %.2f), tiers %s" % [tick_ms, sched_ms, float(s.npcs.stats.max_sched_us) / 1000.0, str(c)])
	check(tick_ms < 1.5, "ACTIVE AI within budget (%.2f ms)" % tick_ms)
	# Plan budget: scheduling ≤ 0.5 ms per frame on average (a pass runs every 16 frames),
	# and no pass long enough to be a visible hitch.
	check(sched_ms / 16.0 < 0.5, "scheduling within budget (%.2f ms per pass = %.2f ms/frame)" % [sched_ms, sched_ms / 16.0])
	check(float(s.npcs.stats.max_sched_us) / 1000.0 < 10.0, "no scheduling hitch (max %.2f ms)" % (float(s.npcs.stats.max_sched_us) / 1000.0))
	await _done()
