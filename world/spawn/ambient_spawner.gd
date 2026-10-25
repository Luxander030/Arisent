## Ambient wildlife by biome (spawn_rules.json), Minecraft/Valheim style: no authored
## places, just rules evaluated in a ring around the player. Every few seconds, if fewer
## than the cap are around, a group spawns 80–150 m away, out of sight, on walkable ground
## of a matching biome, inside the rule's hours, and never inside authored spawn or
## no-spawn zones (authored content wins). Ambient creatures vanish again beyond 350 m
## and are never saved — the world doesn't remember wildlife, only what the player did.
class_name AmbientSpawner
extends Node

const INTERVAL := 5.0
const RING_MIN := 80.0
const RING_MAX := 150.0
const DESPAWN := 350.0
const BASE_CAP := 8

var session: WorldSession
var enabled := true
var last_reason := ""
var _t := 0.0
var _counter := 0
var _ids := {}    ## npc id -> true


func _ready() -> void:
	name = "Ambient"


func _physics_process(delta: float) -> void:
	Perf.begin(&"ambient")
	_physics_process_body(delta)
	Perf.end(&"ambient")


func _physics_process_body(delta: float) -> void:
	if session == null or session.npcs.frozen:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = INTERVAL
	var f := session.focus_position()
	# Forget dead ones, remove far ones.
	for id: String in _ids.keys():
		var rec: NpcRecord = session.npcs.records.get(id)
		if rec == null:
			_ids.erase(id)
		elif Vector2(rec.pos.x - f.x, rec.pos.z - f.z).length() > DESPAWN and rec.tier != SimScheduler.ACTIVE:
			session.npcs.despawn(id, "ambient, far from the player")
			_ids.erase(id)
	if not enabled:
		last_reason = "disabled"
		return
	if session.map == null or session.map.layout_n == 0:
		last_reason = "map has no biome data"
		return
	_try_spawn(f)


func _try_spawn(f: Vector3) -> void:
	var biome := session.map.biome_at(f)
	var rule := _rule_for(biome)
	if rule.is_empty():
		last_reason = "no rule for %s" % (MapData.BIOME_NAMES[biome] if biome >= 0 else "this biome")
		return
	var cap := int(round(BASE_CAP * float(rule.get("density", 1.0))))
	if _ids.size() >= cap:
		last_reason = "cap reached (%d)" % cap
		return
	if not TimeOfDay.in_window(session.game.time_of_day.hours, float(rule.get("tod_start", 0.0)), float(rule.get("tod_end", 24.0))):
		last_reason = "outside the rule's hours"
		return
	_counter += 1
	for attempt in 6:
		var a := Rng.hash3f(_counter, attempt, 1, 3131) * TAU
		var r := lerpf(RING_MIN, RING_MAX, Rng.hash3f(_counter, attempt, 2, 3131))
		var p := f + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if _rule_for(session.map.biome_at(p)) != rule:
			last_reason = "biome changes there"
			continue
		if not session.npcs.walkable(p):
			last_reason = "not walkable"
			continue
		var zs := session.view.zones.zones_at(p)
		if zs.any(func(z: Dictionary) -> bool: return EntityKinds.has_role(z, "spawn") or EntityKinds.has_role(z, "no_spawn")):
			last_reason = "inside an authored zone"
			continue
		p.y = session.queries.ground_height(p)
		if session.spawns.visibility.call(p):
			last_reason = "visible"
			continue
		var row := _pick(rule.rows, _counter)
		var n := int(row.get("group_min", 1)) + int(Rng.hash2f(_counter, 7, 11) * (int(row.get("group_max", 1)) - int(row.get("group_min", 1)) + 1))
		for k in mini(n, cap - _ids.size()):
			var at := p + Vector3(Rng.hash3f(_counter, k, 3, 5) - 0.5, 0.0, Rng.hash3f(_counter, k, 4, 5) - 0.5) * 8.0
			var rec := session.npcs.spawn(str(row.archetype), at, {"id": "ambient:%d:%d" % [_counter, k], "wander_radius": 20.0})
			if rec:
				_ids[rec.id] = true
		last_reason = "spawned %d %s" % [n, row.archetype]
		return


func _rule_for(biome: int) -> Dictionary:
	if biome < 0:
		return {}
	var name := MapData.BIOME_NAMES[biome]
	for r: Dictionary in Defs.all("spawn_rules"):
		if (r.get("biomes", []) as Array).has(name):
			return r
	return {}


static func _pick(rows: Array, salt: int) -> Dictionary:
	var total := 0.0
	for r: Dictionary in rows:
		total += float(r.get("weight", 1.0))
	var x := Rng.hash2f(salt, 99, 7) * total
	for r: Dictionary in rows:
		x -= float(r.get("weight", 1.0))
		if x < 0.0:
			return r
	return rows[-1]


func count() -> int:
	return _ids.size()
