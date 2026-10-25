extends TestCase
## The basic enemies ported from the web Lux's RPG (tools/port/basic_enemies.py): data
## complete and consistent, their special traits work (fire resistance / weakness,
## regeneration, ranged attacks with line of sight), and they fight and drop loot.

const PORTED := ["shadow_imp", "armored_beetle", "gloom_weaver", "elf", "stone_golem", "void_stalker",
	"iron_golem", "nightmare_shade", "drow_elf", "blood_bat"]

var game: GameSession
var view: WorldView
var player: PlayerController
var s: WorldSession


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _world() -> void:
	Defs.reload()
	game = GameSession.new()
	_tree().root.add_child(game)
	view = WorldView.new()
	_tree().root.add_child(view)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position.y = -0.5
	view.add_child(floor_body)
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


func test_data_is_complete() -> void:
	Defs.reload()
	eq(Defs.errors, [] as Array[String], "data files read cleanly")
	for id: String in PORTED:
		var d := Defs.get_def("creatures", id)
		check(not d.is_empty(), "%s exists" % id)
		if d.is_empty():
			continue
		check(float(d.health) > 0.0 and float(d.attack.damage) > 0.0 and int(d.level) >= 1, "%s has stats" % id)
		check(float(d.attack.damage) <= 35.0, "%s: no hit over 35 %% of the player's health" % id)
		check(str(d.get("lore", "")) != "", "%s keeps its lore" % id)
		check(Defs.has("factions", str(d.faction)), "%s: faction %s exists" % [id, d.faction])
		var table := Defs.get_def("loot_tables", str(d.loot_table))
		check(not table.is_empty(), "%s has a loot table" % id)
		for r: Dictionary in table.get("rows", []):
			check(Defs.has("items", str(r.item)), "%s drops a known item (%s)" % [id, r.item])
	var elves: Array = Defs.get_def("factions", "elves").hostile_to
	var drow: Array = Defs.get_def("factions", "drow").hostile_to
	check(elves.has("drow") and drow.has("elves") and elves.has("player"), "elves and drow hate each other (and the player)")
	check(Defs.get_def("factions", "player").hostile_to.has("drow"), "the player fights both")
	# The source's ordering survives: tanky beetle, fragile imp, heavy golems, deadly drow.
	var hp := func(id: String) -> float: return float(Defs.get_def("creatures", id).health)
	check(hp.call("armored_beetle") > hp.call("shadow_imp") and hp.call("iron_golem") > hp.call("stone_golem"), "toughness ordering kept")
	check(float(Defs.get_def("creatures", "armored_beetle").attack.damage) < 8.0, "the beetle barely hurts")


func test_resistance_and_weakness() -> void:
	_world()
	var golem := s.npcs.spawn("stone_golem", Vector3(30, 0, 0))
	var bat := s.npcs.spawn("blood_bat", Vector3(-30, 0, 0))
	var g0 := golem.health
	s.npcs.damage(golem.id, DamageInfo.make(50.0, "fire", "player", golem.pos))
	check(is_equal_approx(g0 - golem.health, 20.0), "stone resists 60 %% of fire (took %.1f)" % (g0 - golem.health))
	var g1 := golem.health
	s.npcs.damage(golem.id, DamageInfo.make(50.0, "bullet", "player", golem.pos))
	check(is_equal_approx(g1 - golem.health, 50.0), "but not bullets")
	var b0 := bat.health
	s.npcs.damage(bat.id, DamageInfo.make(20.0, "fire", "player", bat.pos))
	check(is_equal_approx(b0 - bat.health, 40.0), "the Blood Bat burns like paper (double)")
	await _done()


func test_blood_bat_regenerates() -> void:
	_world()
	var bat := s.npcs.spawn("blood_bat", Vector3(10, 0, 0))
	bat.health = bat.max_health * 0.5
	var h := bat.health
	s.npcs.brain.think(bat, s.npcs, 2.0, false)
	check(bat.health > h and bat.health <= bat.max_health, "heals over time (%.1f → %.1f)" % [h, bat.health])
	var imp := s.npcs.spawn("shadow_imp", Vector3(-10, 0, 0))
	imp.health = imp.max_health * 0.5
	var ih := imp.health
	s.npcs.brain.think(imp, s.npcs, 2.0, false)
	eq(imp.health, ih, "others don't")
	await _done()


func test_ranged_attacker_hits_from_afar_and_needs_sight() -> void:
	_world()
	s.npcs.frozen = true  # only the attack itself is under test, not where the AI walks
	var weaver := s.npcs.spawn("gloom_weaver", Vector3(9, 0, 0))
	weaver.target_id = "player"
	var hp := player.health
	s.npcs.attack(weaver)
	check(player.health < hp, "the Gloom Weaver hurts the player from 9 m (melee range would be ~2 m)")
	# A wall between them: no bolt.
	var wall := StaticBody3D.new()
	wall.collision_layer = PhysicsLayers.WORLD
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 10, 30)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(4.5, 3, 0)
	view.add_child(wall)
	for i in 16:  # past WorldQueries' line-of-sight cache (~0.2 s)
		await _tree().physics_frame
	hp = player.health
	s.npcs.attack(weaver)
	eq(player.health, hp, "not through a wall")
	await _done()


func test_they_chase_fight_and_drop_loot() -> void:
	_world()
	var imp := s.npcs.spawn("shadow_imp", Vector3(8, 0, 0))
	for i in 60:
		await _tree().physics_frame
	check(imp.target_id == "player", "the imp notices the player")
	s.npcs.damage(imp.id, DamageInfo.make(1000.0, "bullet", "player", imp.pos))
	check(not imp.alive, "dies")
	var corpse: Dictionary = {}
	for c: Dictionary in s.npcs.corpses.values():
		corpse = c
	var coins := 0
	for d: Dictionary in corpse.get("loot", []):
		if d.item == "coin":
			coins += int(d.count)
	check(coins >= 1 and coins <= 3, "drops 1-3 coins (%d)" % coins)
	check(game.progress.xp >= 8, "gives XP (%d)" % game.progress.xp)
	await _done()
