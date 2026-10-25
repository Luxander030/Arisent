## Turns authored spawning data into creatures, by rule. Every spawner, unique NPC and spawn
## zone becomes a set of *slots* (spawner of count 3 = 3 slots, zone with max_alive 12 =
## 12 slots) with stable ids "<entity id>#<index>". A slot is UNSPAWNED, ALIVE, DEAD (with
## respawn_at on the play clock) or GONE (a unique NPC killed for good), and always records
## the last reason it could not spawn — that is what the `why` command and the spawns
## overlay show.
##
## Spawners in a spawn group are handled by the group: at most max_alive members alive,
## the next one picked by weight (explicit weights first, weight 0 shares the rest), manual
## groups only on request, members of a group with a leader wait while the leader is dead.
## Zones pick a table row by weight, a group size, and a point from the zone's baked
## candidates that passes the distance / view / no-spawn rules.
##
## Nothing ever spawns inside the player's view (owner rule): a spot is "in view" when it
## is inside the camera's field of view and within 230 m — the distance creatures have
## bodies at. Slots are checked out to 300 m, so creatures beyond that distance appear as
## data and fade in as the player approaches; nearer spots wait until the player looks
## away. Only the very first population when a map loads is exempt (nothing was on screen).
class_name SpawnDirector
extends Node

signal spawned(slot_id: String, npc_id: String)

enum { UNSPAWNED, ALIVE, DEAD, GONE }
const STATE_NAMES := ["UNSPAWNED", "ALIVE", "DEAD", "GONE"]
const LAYER := &"slots"
const ACTIVE_RADIUS := 300.0
const TICK := 0.25
const STARTUP := 1.5   ## seconds after the session starts in which the world fills up
const SPAWNER_MIN_DIST := 20.0


class Slot:
	var id := ""
	var source := ""          ## entity id
	var kind := ""            ## spawner | unique | zone
	var index := 0
	var state := 0
	var respawn_at := 0.0
	var life_count := 0
	var npc_id := ""
	var home := Vector3.INF   ## spawners: fixed point; zones: chosen per life
	var block_reason := ""



var session: WorldSession
var slots := {}              ## id -> Slot
var visibility: Callable     ## (Vector3) -> bool: can the player see this spot?
var zone_reasons := {}       ## zone id -> last reason the zone didn't spawn
var _zone_points := {}       ## zone id -> {key, points}
var _zone_next := {}         ## zone id -> sim time of the next check
var _conditions := {}        ## source id -> StoryCondition
var _by_source := {}         ## entity id -> Array of its slots
var _group_members := {}     ## group id -> Array of member spawner slots
var _timer := 0.0
var _started_at := -1.0


func _ready() -> void:
	name = "Spawns"
	if not visibility.is_valid():
		visibility = session.in_view
	session.npcs.died.connect(_on_died)
	session.npcs.despawned.connect(_on_despawned)


## Creates slots for every spawning entity of the map.
func build() -> void:
	for e: Dictionary in session.view.entities.all_entities():
		add_source(e)


func add_source(e: Dictionary) -> void:
	var p: Dictionary = e.props
	match str(e.kind):
		"spawner":
			var n := int(p.get("count", 1))
			var g := str(p.get("group", ""))
			var base := EntityKinds.position_of(e)
			for i in n:
				var home := base
				if i > 0:
					var a := Rng.hash2f(hash(e.id), i, 31) * TAU
					home += Vector3(cos(a), 0.0, sin(a)) * minf(2.5, maxf(1.0, float(p.get("wander_radius", 2.0))))
				var sl := _add_slot(e.id, "spawner", i, home)
				if g != "":
					if not _group_members.has(g):
						_group_members[g] = []
					(_group_members[g] as Array).append(sl)
		"unique_npc":
			_add_slot(e.id, "unique", 0, EntityKinds.position_of(e))
		"zone":
			if EntityKinds.has_role(e, "spawn"):
				var c := ZoneShape.aabb(e).get_center()
				for i in int(p.get("max_alive", 1)):
					_add_slot(e.id, "zone", i, Vector3(c.x, 0.0, c.y))
	if p.has("condition") and p.condition is Dictionary and not (p.condition as Dictionary).is_empty():
		_conditions[e.id] = StoryCondition.from_dict(p.condition)


func _add_slot(source: String, kind: String, index: int, home: Vector3) -> Slot:
	var s := Slot.new()
	s.id = "%s#%d" % [source, index]
	s.source = source
	s.kind = kind
	s.index = index
	s.home = home
	slots[s.id] = s
	if not _by_source.has(source):
		_by_source[source] = []
	(_by_source[source] as Array).append(s)
	session.view.grid.put(LAYER, s.id, home)
	return s


func slot(id: String) -> Slot:
	return slots.get(id)


# --- tick ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	Perf.begin(&"spawns")
	_physics_process_body(delta)
	Perf.end(&"spawns")


func _physics_process_body(delta: float) -> void:
	if session == null or session.npcs.frozen:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = TICK
	var f := session.focus_position()
	var groups := {}
	var zones := {}
	for id in session.view.grid.query_radius(LAYER, f, ACTIVE_RADIUS):
		var s: Slot = slots.get(id)
		if s == null:
			continue
		if s.kind == "zone":
			zones[s.source] = true
			continue
		var e := session.view.entities.entity(s.source)
		var g := str(e.get("props", {}).get("group", ""))
		if g != "" and session.view.entities.has_entity(g):
			groups[g] = true
			continue
		_tick_single(s, e, f)
	# Zones are found by area too (a big zone's slots may sit far from its edge).
	for z in session.view.zones.zones_in_rect(Rect2(f.x - ACTIVE_RADIUS, f.z - ACTIVE_RADIUS, ACTIVE_RADIUS * 2.0, ACTIVE_RADIUS * 2.0)):
		if EntityKinds.has_role(z, "spawn") and slots.has("%s#0" % z.id):
			zones[z.id] = true
	for g: String in groups:
		_tick_group(g, f)
	for z: String in zones:
		_tick_zone(z, f)


func _tick_single(s: Slot, e: Dictionary, f: Vector3) -> void:
	if not _check_alive(s) or s.state == GONE or s.state == ALIVE:
		return
	if e.is_empty():
		s.block_reason = "its spawner was removed"
		return
	var reason := _blocked(s, e, s.home, f)
	s.block_reason = reason
	if reason == "":
		_spawn_slot(s, e, s.home)


## A group decides which members spawn: max_alive, weights, manual, leader.
func _tick_group(gid: String, f: Vector3) -> void:
	var g := session.view.entities.entity(gid)
	var gp: Dictionary = g.props
	var members: Array[Slot] = []
	var alive := 0
	for s: Slot in _group_members.get(gid, []):
		_check_alive(s)
		members.append(s)
		if s.state == ALIVE:
			alive += 1
	var reason := ""
	if bool(gp.get("manual", false)):
		reason = "manual group (only scripts / the 'group_spawn' command spawn it)"
	var leader := str(gp.get("leader", ""))
	if reason == "" and leader != "":
		for s: Slot in _by_source.get(leader, []):
			if s.state == DEAD or s.state == GONE:
				reason = "waiting for the group leader to respawn"
				break
	var room := int(gp.get("max_alive", 1)) - alive
	if reason == "" and room <= 0:
		reason = "group limit (%d alive)" % alive
	var ready: Array[Slot] = []
	for s in members:
		if s.state == ALIVE or s.state == GONE:
			continue
		var e := session.view.entities.entity(s.source)
		var why := reason if reason != "" else _blocked(s, e, s.home, f)
		s.block_reason = why
		if why == "":
			ready.append(s)
	for k in mini(room, ready.size()):
		var pick := _weighted_pick(ready, gid, alive + k)
		ready.erase(pick)
		_spawn_slot(pick, session.view.entities.entity(pick.source), pick.home)
		for other in ready:
			other.block_reason = "group limit"


## Weighted choice among member slots: explicit group_weight first, 0 = share the rest.
func _weighted_pick(cands: Array[Slot], gid: String, salt: int) -> Slot:
	var explicit := 0.0
	var zeros := 0
	var weights: Array[float] = []
	for s in cands:
		var w := float(session.view.entities.entity(s.source).props.get("group_weight", 0.0))
		weights.append(w)
		if w > 0.0:
			explicit += w
		else:
			zeros += 1
	var total := maxf(explicit, 100.0) if zeros > 0 else explicit
	var share := (total - explicit) / zeros if zeros > 0 else 0.0
	var x := Rng.hash3f(hash(gid), salt, int(session.now()), 515) * total
	var acc := 0.0
	for i in cands.size():
		acc += weights[i] if weights[i] > 0.0 else share
		if x < acc:
			return cands[i]
	return cands[-1]


func _tick_zone(zid: String, f: Vector3) -> void:
	var z := session.view.entities.entity(zid)
	if z.is_empty():
		return
	var p: Dictionary = z.props
	var t := session.now()
	var zone_slots: Array[Slot] = []
	var alive := 0
	for i in int(p.get("max_alive", 1)):
		var s: Slot = slots.get("%s#%d" % [zid, i])
		if s:
			_check_alive(s)
			zone_slots.append(s)
			if s.state == ALIVE:
				alive += 1
	# Initial population: "full" fills the zone at once, "trickle" staggers it.
	var initial := false
	for s in zone_slots:
		if s.state == UNSPAWNED and s.life_count == 0:
			initial = true
			if str(p.get("initial", "full")) == "trickle":
				s.state = DEAD
				s.respawn_at = t + Rng.hash2f(hash(s.id), 1, 77) * float(p.get("respawn", 180.0))
	# Initial population skips the chance roll but is still throttled (≤ once a second).
	if t < float(_zone_next.get(zid, 0.0)):
		return
	_zone_next[zid] = t + (minf(1.0, float(p.get("check_interval", 10.0))) if initial else float(p.get("check_interval", 10.0)))
	var reason := _zone_blocked(z)
	if reason == "" and not initial and Rng.hash3f(hash(zid), int(t), 3, 99) >= float(p.get("spawn_chance", 1.0)):
		reason = "spawn chance roll failed (%.0f%%)" % (float(p.spawn_chance) * 100.0)
	var ready: Array[Slot] = []
	for s in zone_slots:
		if s.state == ALIVE or s.state == GONE:
			continue
		if reason != "":
			s.block_reason = reason
		elif s.state == DEAD and t < s.respawn_at:
			s.block_reason = "respawns in %ds" % int(s.respawn_at - t)
		else:
			ready.append(s)
	zone_reasons[zid] = reason if reason != "" else ("full (%d alive)" % alive if ready.is_empty() and alive >= zone_slots.size() else "")
	if ready.is_empty():
		return
	var pts := zone_points(z)
	if pts.is_empty():
		for s in ready:
			s.block_reason = "no usable ground in the zone (slope / water / altitude / no-spawn)"
		return
	var rows: Array = p.get("spawn_table", [])
	if rows.is_empty():
		for s in ready:
			s.block_reason = "empty spawn table"
		return
	var groups_left := 4  # bounded work per check (each group may try up to 8 spots)
	while not ready.is_empty() and groups_left > 0:
		groups_left -= 1
		var s: Slot = ready[0]
		var row := _pick_row(rows, hash(s.id) ^ s.life_count)
		var gmin := int(row.get("group_min", 1))
		var gsize := gmin + int(Rng.hash2f(hash(s.id), s.life_count, 5) * (int(row.get("group_max", gmin)) - gmin + 1))
		var spot := _zone_spot(z, s, pts, f)
		if spot == Vector3.INF:
			ready.pop_front()
			continue
		for k in mini(gsize, ready.size()):
			var member: Slot = ready.pop_front()
			var a := Rng.hash2f(hash(member.id), member.life_count, 9) * TAU
			var at := spot + (Vector3(cos(a), 0.0, sin(a)) * 3.0 if k > 0 else Vector3.ZERO)
			if k > 0 and (not ZoneShape.contains(z, at) or session.view.zones.has_role_at(at, "no_spawn") or not session.npcs.walkable(at)):
				at = spot  # pack members together rather than leave the allowed area
			_spawn_slot(member, z, at, str(row.get("archetype", "")), _row_level(z, row))


## A candidate point for this slot (seeded by slot and life) that passes the rules.
func _zone_spot(z: Dictionary, s: Slot, pts: PackedVector3Array, f: Vector3) -> Vector3:
	var p: Dictionary = z.props
	var min_d := float(p.get("min_player_dist", 30.0))
	var starting := _starting() and s.life_count == 0
	var last := ""
	for attempt in 8:
		var i := int(Rng.hash3f(hash(s.id), s.life_count, attempt, 4242) * pts.size()) % pts.size()
		var q := pts[i]
		if Vector2(q.x - f.x, q.z - f.z).length() < min_d:
			last = "too close to the player (< %.0f m)" % min_d
			continue
		if session.view.zones.has_role_at(q, "no_spawn"):
			last = "inside a no-spawn zone"
			continue
		var vis_reason := "" if starting else _view_block(q)
		if vis_reason != "":
			last = vis_reason
			continue
		return q
	s.block_reason = last
	return Vector3.INF


func _pick_row(rows: Array, salt: int) -> Dictionary:
	var total := 0.0
	for r: Dictionary in rows:
		total += maxf(0.0, float(r.get("weight", 1.0)))
	var x := Rng.hash2f(salt, int(session.now()), 17) * total
	for r: Dictionary in rows:
		x -= maxf(0.0, float(r.get("weight", 1.0)))
		if x < 0.0:
			return r
	return rows[-1]


## Level from the row, else the encounter zone's level (locked on first visit), else 0.
func _row_level(z: Dictionary, row: Dictionary) -> int:
	var lo := int(row.get("level_min", 0))
	var hi := int(row.get("level_max", 0))
	if lo > 0:
		return lo + int(Rng.hash2f(hash(z.id), int(session.now()), 3) * (maxi(lo, hi) - lo + 1))
	var c := ZoneShape.aabb(z).get_center()
	var enc := session.view.zones.zone_with_role(Vector3(c.x, 0.0, c.y), "encounter")
	return session.encounter_level(enc) if not enc.is_empty() else 0


func zone_points(z: Dictionary) -> PackedVector3Array:
	var key := ZoneCandidates.key_of(z)
	var cached: Dictionary = _zone_points.get(z.id, {})
	if cached.is_empty() and session.map and session.map.zone_cache.has(z.id):
		cached = session.map.zone_cache[z.id]  # baked by the editor when the map was saved
	if cached.is_empty() or int(cached.key) != key:
		cached = {"key": key, "points": ZoneCandidates.bake(z, session.view)}
		_zone_points[z.id] = cached
	return cached.points


# --- rules -----------------------------------------------------------------------------------

## Why a spawner/unique slot can't spawn now ("" = it can).
func _blocked(s: Slot, e: Dictionary, at: Vector3, f: Vector3) -> String:
	var t := session.now()
	var p: Dictionary = e.props
	var arch := str(p.get("archetype", ""))
	if not Defs.has("creatures", arch):
		return "no archetype" if arch == "" else "unknown archetype '%s'" % arch
	if _conditions.has(s.source) and not (_conditions[s.source] as StoryCondition).evaluate(session.game.story_state):
		return "condition not met: " + (_conditions[s.source] as StoryCondition).describe()
	if s.state == DEAD and t < s.respawn_at:
		return "respawns in %ds" % int(s.respawn_at - t)
	if _starting() and s.state == UNSPAWNED and s.life_count == 0:
		return ""  # the map is loading: fill the world before anything is on screen
	if Vector2(at.x - f.x, at.z - f.z).length() < SPAWNER_MIN_DIST:
		return "too close to the player"
	return _view_block(at)


## Never inside the player's view.
func _view_block(at: Vector3) -> String:
	return "in the player's view (spawns when they look away)" if visibility.call(at) else ""


func _starting() -> bool:
	if _started_at < 0.0:
		_started_at = Time.get_ticks_msec() / 1000.0
	return Time.get_ticks_msec() / 1000.0 - _started_at < STARTUP


func _zone_blocked(z: Dictionary) -> String:
	var p: Dictionary = z.props
	var tod := session.game.time_of_day.hours
	if not TimeOfDay.in_window(tod, float(p.get("tod_start", 0.0)), float(p.get("tod_end", 24.0))):
		return "outside its hours (%02d–%02d)" % [int(p.tod_start), int(p.tod_end)]
	if _conditions.has(z.id) and not (_conditions[z.id] as StoryCondition).evaluate(session.game.story_state):
		return "condition not met: " + (_conditions[z.id] as StoryCondition).describe()
	return ""


## True if the slot's creature still exists (despawned/removed ones become UNSPAWNED).
func _check_alive(s: Slot) -> bool:
	if s.state == ALIVE and not session.npcs.records.has(s.npc_id):
		s.state = UNSPAWNED
		s.npc_id = ""
	return true


# --- spawning and deaths ------------------------------------------------------------------------

func _spawn_slot(s: Slot, e: Dictionary, at: Vector3, archetype := "", level := 0) -> void:
	var p: Dictionary = e.props
	var arch := archetype if archetype != "" else str(p.get("archetype", ""))
	var opts := {
		"slot_id": s.id, "level": level if level > 0 else int(p.get("level", 0)),
		"wander_radius": float(p.get("wander_radius", 6.0)),
		"movement": str(p.get("movement", "wander")),
		"fade": s.life_count > 0,
	}
	if s.kind == "unique":
		opts.unique_id = e.id
		opts.name = str(p.get("name", ""))
		opts.id = "unique:" + str(e.id)
	var path_id := str(p.get("path", ""))
	if opts.movement == "patrol" and path_id != "" and session.view.entities.has_entity(path_id):
		var path_e := session.view.entities.entity(path_id)
		var pts := PackedVector3Array()
		for q in ZoneShape.world_points(path_e):
			pts.append(Vector3(q.x, session.queries.ground_height(Vector3(q.x, 0, q.y)), q.y))
		opts.path = pts
		opts.path_mode = str(path_e.props.get("mode", "loop"))
		opts.path_wait = float(path_e.props.get("wait", 2.0))
	var rec := session.npcs.spawn(arch, at, opts)
	if rec == null:
		s.block_reason = "spawn failed (archetype '%s')" % arch
		return
	s.state = ALIVE
	s.npc_id = rec.id
	s.block_reason = ""
	if s.kind == "zone":
		s.home = at
		session.view.grid.put(LAYER, s.id, at)
	spawned.emit(s.id, rec.id)


func _on_died(rec: NpcRecord, _killer: String) -> void:
	var s: Slot = slots.get(rec.slot_id)
	if s == null:
		return
	var e := session.view.entities.entity(s.source)
	var p: Dictionary = e.get("props", {})
	s.life_count += 1
	s.npc_id = ""
	var respawn := float(p.get("respawn", rec.def.get("respawn", 120.0)))
	if s.kind == "unique" and respawn <= 0.0:
		s.state = GONE
		s.block_reason = "killed for good (unique)"
		return
	var jitter := float(p.get("respawn_jitter", 0.2))
	var k := 1.0 + jitter * (Rng.hash2f(hash(s.id), s.life_count, 13) * 2.0 - 1.0)
	s.state = DEAD
	s.respawn_at = session.now() + respawn * k
	if s.kind == "zone":
		s.home = Vector3(s.home.x, s.home.y, s.home.z)


func _on_despawned(rec: NpcRecord) -> void:
	var s: Slot = slots.get(rec.slot_id)
	if s and s.npc_id == rec.id and s.state == ALIVE:
		s.state = UNSPAWNED
		s.npc_id = ""
		s.block_reason = "despawned (player far away); comes back fresh"


## Manual groups and scripts: spawn now, regardless of limits.
func spawn_group(gid: String) -> int:
	var n := 0
	for s: Slot in _group_members.get(gid, []):
		if s.state != ALIVE and s.state != GONE:
			_spawn_slot(s, session.view.entities.entity(s.source), s.home)
			n += 1
	return n


## Respawn now (console): every dead slot, or those of one source.
func respawn_now(source := "") -> int:
	var n := 0
	for s: Slot in slots.values():
		if (source == "" or s.source == source) and s.state == DEAD:
			s.respawn_at = session.now()
			n += 1
	_zone_next.clear()
	return n


func describe_slot(id: String) -> String:
	var s: Slot = slots.get(id)
	if s == null:
		return "no slot '%s'" % id
	var e := session.view.entities.entity(s.source)
	var t := session.now()
	var lines: PackedStringArray = []
	lines.append("slot %s  (%s %s)  %s  lives %d" % [s.id, EntityKinds.label(s.kind if s.kind != "unique" else "unique_npc"),
		str(e.get("props", {}).get("name", "")), STATE_NAMES[s.state], s.life_count])
	if s.state == DEAD:
		lines.append("respawn at t=%.0f (in %.0f s)" % [s.respawn_at, maxf(0.0, s.respawn_at - t)])
	if s.state == ALIVE:
		lines.append(session.npcs.describe(s.npc_id))
	elif s.block_reason != "":
		lines.append("not spawning because: " + s.block_reason)
	if s.kind == "zone" and str(zone_reasons.get(s.source, "")) != "":
		lines.append("zone: " + str(zone_reasons[s.source]))
	return "\n".join(lines)


# --- debug ----------------------------------------------------------------------------------------

func draw_debug(dd: DebugDraw) -> void:
	if not dd.is_on("spawns"):
		return
	var f := session.focus_position()
	var t := session.now()
	var zones_drawn := {}
	for id in session.view.grid.query_radius(LAYER, f, 200.0):
		var s: Slot = slots.get(id)
		if s == null:
			continue
		if s.kind == "zone":
			zones_drawn[s.source] = true
			if s.state != ALIVE:
				continue
		var col: Color = [Color(0.6, 0.6, 0.6), Color(0.3, 1.0, 0.4), Color(1.0, 0.3, 0.25), Color(0.3, 0.3, 0.3)][s.state]
		var p := s.home if s.home != Vector3.INF else Vector3.ZERO
		p.y = dd.ground(p.x, p.z)
		dd.line(p, p + Vector3.UP * 2.5, col)
		var text: String = STATE_NAMES[s.state]
		if s.state == DEAD:
			text = "respawn %ds" % int(maxf(0.0, s.respawn_at - t))
		if s.state != ALIVE and s.block_reason != "" and s.state != DEAD:
			text += ": " + s.block_reason
			col = Color(1.0, 0.65, 0.2)
		elif s.state == DEAD and s.block_reason != "" and not s.block_reason.begins_with("respawns"):
			text += "  (" + s.block_reason + ")"
		dd.text(p + Vector3.UP * 2.8, text, col, 36)
	for zid: String in zones_drawn:
		var z := session.view.entities.entity(zid)
		if z.is_empty():
			continue
		var alive := 0
		var dead := 0
		for i in int(z.props.get("max_alive", 1)):
			var s: Slot = slots.get("%s#%d" % [zid, i])
			if s and s.state == ALIVE:
				alive += 1
			elif s and s.state == DEAD:
				dead += 1
		var c := ZoneShape.aabb(z).get_center()
		var reason := str(zone_reasons.get(zid, ""))
		dd.text(Vector3(c.x, dd.ground(c.x, c.y) + 6.0, c.y), "%d/%d alive, %d waiting%s  next check %ds" % [alive, int(z.props.max_alive), dead,
			("  — " + reason) if reason != "" else "", int(maxf(0.0, float(_zone_next.get(zid, 0.0)) - t))], Color(1.0, 0.85, 0.5))
		var cached: Dictionary = _zone_points.get(zid, {})
		var pts: PackedVector3Array = cached.get("points", PackedVector3Array())  # never bakes while drawing
		var step := maxi(1, pts.size() / 150)
		for i in range(0, pts.size(), step):
			var q := pts[i]
			if q.distance_to(f) < 160.0:
				dd.line(q, q + Vector3.UP * 0.6, Color(1.0, 0.85, 0.4, 0.6))


func register_commands(c: DebugConsole) -> void:
	c.command("why", "Why a spawn spot or creature does what it does (default: what you look at).", "/why [slot id|creature id]", _cmd_why, 0, 1,
		ConsoleParse.hints_of(_near_ids), self)
	c.verbs("spawner", "Spawn slots: who spawns where, and when.", self) \
		.verb("slots", "How many slots are unspawned, alive, dead and gone.", _cmd_slots) \
		.verb("respawn", "Dead slots respawn now (their rules still apply), all or one spawner's.", _cmd_respawn, 0, 1, "/spawner respawn [entity id]",
			ConsoleParse.hints_of(_source_ids)) \
		.verb("group", "Spawns a (manual) spawn group now.", _cmd_group_spawn, 1, 1, "/spawner group <group entity id>", ConsoleParse.hints_of(_group_ids)) \
		.verb("problems", "Authoring problems in this map's spawning data.", _cmd_problems)


func _near_ids() -> Array:
	var f := session.focus_position()
	var out: Array = session.view.grid.query_radius(NpcManager.LAYER, f, 60.0)
	out.append_array(session.view.grid.query_radius(LAYER, f, 60.0))
	return out.slice(0, 40)


func _source_ids() -> Array:
	var seen := {}
	for sl: Slot in slots.values():
		seen[sl.source] = true
	return seen.keys()


func _group_ids() -> Array:
	return _group_members.keys()


func _cmd_why(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		if slots.has(a[0]):
			return describe_slot(a[0])
		if session.npcs.records.has(a[0]):
			return session.npcs.describe(a[0])
		return "no slot or creature '%s'" % a[0]
	# What the crosshair points at: a creature body, else the nearest slot to that point.
	var cam := session.view.get_viewport().get_camera_3d()
	if cam == null:
		return "no camera"
	var hit := session.queries.trace(cam.global_position, cam.global_position - cam.global_basis.z * 400.0,
		PhysicsLayers.TRACE_MASK | PhysicsLayers.NPC, [], true)
	if hit.is_empty():
		return "look at a creature or a spawn spot"
	var col: Object = hit.get("collider")
	var owner: Object = (col as Node).get_meta("owner_node") if col is Area3D and (col as Node).has_meta("owner_node") else col
	if owner is NpcBody:
		var rec: NpcRecord = session.npcs.records.get((owner as NpcBody).record_id)
		var out := session.npcs.describe((owner as NpcBody).record_id)
		if rec and rec.slot_id != "":
			out += "\n" + describe_slot(rec.slot_id).get_slice("\n", 0)
		return out
	var best := ""
	var bd := 25.0
	for id in session.view.grid.query_radius(LAYER, hit.position, 25.0):
		var s: Slot = slots[id]
		if s.home != Vector3.INF and s.home.distance_to(hit.position) < bd:
			bd = s.home.distance_to(hit.position)
			best = id
	return describe_slot(best) if best != "" else "no spawn slot within 25 m of that spot"


func _cmd_respawn(a: PackedStringArray) -> Variant:
	session.game.mark_dev()
	return "%d slots will respawn now" % respawn_now(a[0] if not a.is_empty() else "")


func _cmd_slots(_a: PackedStringArray) -> Variant:
	var counts := [0, 0, 0, 0]
	for s: Slot in slots.values():
		counts[s.state] += 1
	return "%d slots: %d unspawned, %d alive, %d dead, %d gone" % [slots.size(), counts[0], counts[1], counts[2], counts[3]]


func _cmd_group_spawn(a: PackedStringArray) -> Variant:
	if not _group_members.has(a[0]):
		return ConsoleResult.failure("No spawn group '%s'." % a[0])
	session.game.mark_dev()
	return "spawned %d" % spawn_group(a[0])


func _cmd_problems(_a: PackedStringArray) -> Variant:
	var list := SpawnChecks.all_problems(session.view)
	if list.is_empty():
		return "No problems."
	return "\n".join(PackedStringArray(list.map(func(x: Array) -> String: return "%s: %s" % [x[0], x[1]])))
