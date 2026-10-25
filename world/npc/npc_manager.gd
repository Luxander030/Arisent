## All simulated creatures of a session: their records, distance tiers, bodies (pooled),
## movement, damage, death (XP, loot, corpses) and the "why" debugging.
##
## Movement mode depends on where terrain collision exists, not on the tier: a creature
## with a body inside the collision radius around the player moves with physics
## (move_and_slide); everywhere else it is placed on the ground (terrain height, avoiding
## water and steep slopes). ACTIVE creatures move every physics tick and think at 10 Hz;
## NEAR ones update round-robin at about 5 Hz (their bodies glide between updates); FAR
## ones every 2 s without perception; DORMANT ones not at all and catch up in one step when
## they wake (fast-forward).
class_name NpcManager
extends Node3D

signal died(rec: NpcRecord, killer_id: String)
signal despawned(rec: NpcRecord)
signal message(text: String)

const LAYER := &"npcs"
const CORPSE_LAYER := &"corpses"
const SCHED_INTERVAL := 0.25
const NEAR_HZ := 5.0
const FAR_INTERVAL := 2.0
const DESPAWN_RADIUS := 1000.0
const CORPSE_TIME := 300.0          ## WoW Corpse.Decay.Normal
const CORPSE_LOOTED_TIME := 150.0   ## decays faster once emptied (×0.5)
const POOL_PER_TYPE := 12
const GRAVITY := 20.32

var session: WorldSession
var brain := NpcBrain.new()
var scheduler := SimScheduler.new()
var records := {}        ## id -> NpcRecord
var corpses := {}        ## id -> {id, archetype, pos, yaw, expires_at, harvested, node, name, loot}
var frozen := false      ## console `ai freeze`
var _pool := {}          ## archetype -> Array[NpcBody]
var _sched_t := 0.0
var _active: Array[NpcRecord] = []
var _near: Array[NpcRecord] = []
var _far: Array[NpcRecord] = []
var _rr_near := 0
var _rr_far := 0
var _counter := 0
var _labels := {}        ## record id -> Label3D (yells)
var _awake := {}         ## ids of records that are not DORMANT
var _despawn_keys: Array = []
var _pass := 0
var _despawn_i := 0
## Cost counters: average µs per tick (AI + movement) and per scheduling pass since reset.
var stats := {"tick_us": 0.0, "sched_us": 0.0, "ticks": 0, "passes": 0, "max_sched_us": 0.0}


func reset_stats() -> void:
	stats = {"tick_us": 0.0, "sched_us": 0.0, "ticks": 0, "passes": 0, "max_sched_us": 0.0}


func avg_tick_ms() -> float:
	return float(stats.tick_us) / maxf(1.0, float(stats.ticks)) / 1000.0


func avg_sched_ms() -> float:
	return float(stats.sched_us) / maxf(1.0, float(stats.passes)) / 1000.0


func _ready() -> void:
	name = "Npcs"


## Pooled bodies are outside the tree; free them with the manager.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for list: Array in _pool.values():
			for b: Variant in list:
				if is_instance_valid(b):
					(b as Node).free()
		_pool.clear()


func now() -> float:
	return session.now()


# --- spawning --------------------------------------------------------------------------

## Creates a creature record. opts: id, slot_id, unique_id, name, wander_radius, movement,
## path (PackedVector3Array), path_mode, path_wait, level, yaw, fade (bool).
func spawn(archetype: String, pos: Vector3, opts := {}) -> NpcRecord:
	var def := Defs.get_def("creatures", archetype)
	if def.is_empty():
		return null
	var rec := NpcRecord.new()
	_counter += 1
	rec.id = str(opts.get("id", "npc:%d" % _counter))
	rec.archetype = str(def.id)
	rec.def = def
	rec.slot_id = str(opts.get("slot_id", ""))
	rec.unique_id = str(opts.get("unique_id", ""))
	rec.display_name = str(opts.get("name", "")) if str(opts.get("name", "")) != "" else str(def.name)
	rec.level = int(opts.get("level", 0)) if int(opts.get("level", 0)) > 0 else int(def.level)
	var scale := 1.0 + 0.15 * float(rec.level - int(def.level))
	rec.max_health = maxf(1.0, float(def.health) * scale)
	rec.health = rec.max_health
	rec.damage = float(def.attack.damage) * scale
	rec.home = pos
	rec.pos = Vector3(pos.x, ground_at(pos), pos.z)
	rec.yaw = float(opts.get("yaw", rec.rand() * TAU))
	rec.wander_radius = float(opts.get("wander_radius", 6.0))
	rec.movement = str(opts.get("movement", "wander"))
	rec.path = opts.get("path", PackedVector3Array())
	rec.path_mode = str(opts.get("path_mode", "loop"))
	rec.path_wait = float(opts.get("path_wait", 2.0))
	rec.fade_in = bool(opts.get("fade", false))
	rec.timer = rec.rand() * 3.0
	rec.last_tick = now()
	rec.state_since = now()
	rec.think_phase = _counter % 6
	rec.add_log(now(), "-", "IDLE", "spawned" + (" (slot %s)" % rec.slot_id if rec.slot_id != "" else ""))
	records[rec.id] = rec
	session.view.grid.put(LAYER, rec.id, rec.pos)
	_sched_t = 0.0
	return rec


func despawn(id: String, reason := "") -> void:
	var rec: NpcRecord = records.get(id)
	if rec == null:
		return
	rec.add_log(now(), NpcBrain.NAMES[rec.state], "-", "despawned: " + reason)
	_release_node(rec)
	session.view.grid.remove(LAYER, id)
	records.erase(id)
	_awake.erase(id)
	_active.erase(rec)
	_near.erase(rec)
	_far.erase(rec)
	despawned.emit(rec)


func ground_at(p: Vector3) -> float:
	return session.queries.ground_height(p)


# --- per tick ------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	Perf.begin(&"npcs")
	_physics_process_body(delta)
	Perf.end(&"npcs")


func _physics_process_body(delta: float) -> void:
	if session == null:
		return
	_sched_t -= delta
	if _sched_t <= 0.0:
		_sched_t = SCHED_INTERVAL
		var s0 := Time.get_ticks_usec()
		_schedule()
		_tick_corpses(SCHED_INTERVAL)
		var us := float(Time.get_ticks_usec() - s0)
		stats.sched_us = float(stats.sched_us) + us
		stats.passes = int(stats.passes) + 1
		stats.max_sched_us = maxf(float(stats.max_sched_us), us)
	if frozen or session.game.clock.paused:
		return
	var t0 := Time.get_ticks_usec()
	var dt := delta * session.game.clock.scale
	var t := now()
	var frame := Engine.get_physics_frames()
	for rec in _active:
		if not rec.alive:
			continue
		if (frame + rec.think_phase) % 6 == 0:
			brain.think(rec, self, t - rec.last_tick, true)
			rec.last_tick = t
		# Physics moves at 32 Hz (half the creatures each tick); interpolation keeps it smooth.
		if not rec.physics_mode or (frame + rec.think_phase) % 2 == 0:
			_move_active(rec, dt, 2.0 if rec.physics_mode else 1.0)
	_round_robin(_near, ceili(_near.size() * NEAR_HZ / Engine.physics_ticks_per_second), true)
	_round_robin(_far, ceili(_far.size() / (FAR_INTERVAL * Engine.physics_ticks_per_second)), false)
	stats.tick_us = float(stats.tick_us) + float(Time.get_ticks_usec() - t0)
	stats.ticks = int(stats.ticks) + 1


func _round_robin(list: Array[NpcRecord], count: int, near: bool) -> void:
	if list.is_empty():
		return
	var t := now()
	for i in mini(count, list.size()):
		var idx := (_rr_near if near else _rr_far) % list.size()
		if near:
			_rr_near = idx + 1
		else:
			_rr_far = idx + 1
		var rec := list[idx]
		if not rec.alive:
			continue
		var elapsed := minf(t - rec.last_tick, 5.0)
		rec.last_tick = t
		brain.think(rec, self, elapsed, near)
		_move_snapped(rec, elapsed)
		var body := _body(rec)
		if body:
			body.smooth_target = rec.pos
			body.rotation.y = lerp_angle(body.rotation.y, rec.yaw, 0.6)
			body.speed = rec.move_speed if rec.move_target != Vector3.INF else 0.0


## ACTIVE: physics where terrain collision exists, else snapped. `steps` = how many physics
## ticks this call stands for (physics movement runs every other tick).
func _move_active(rec: NpcRecord, dt: float, steps := 1.0) -> void:
	var body := _body(rec)
	if body == null:
		_move_snapped(rec, dt)
		return
	var cf := session.queries.collision_focus
	var r := session.queries.collision_radius - 8.0 + (4.0 if rec.physics_mode else -4.0)
	var want_physics := cf != null and is_instance_valid(cf) and Vector2(rec.pos.x - cf.global_position.x, rec.pos.z - cf.global_position.z).length() < r
	if want_physics != rec.physics_mode:
		rec.physics_mode = want_physics
		body.smooth_target = Vector3.INF
		if want_physics:
			body.global_position = Vector3(rec.pos.x, maxf(rec.pos.y, ground_at(rec.pos)) + 0.05, rec.pos.z)
			body.velocity = Vector3.ZERO
	if not rec.physics_mode:
		_move_snapped(rec, dt * steps)
		body.global_position = rec.pos
		body.rotation.y = lerp_angle(body.rotation.y, rec.yaw, minf(1.0, dt * 10.0))
		body.speed = rec.move_speed if rec.move_target != Vector3.INF else 0.0
		return
	var v := body.velocity
	var flat := Vector3.ZERO
	if rec.move_target != Vector3.INF:
		var goal := session.navigator.next_point(rec, body.global_position, rec.move_target)
		var d := goal - body.global_position
		d.y = 0.0
		if d.length() > 0.3:
			flat = d.normalized() * rec.move_speed
			rec.yaw = atan2(-d.x, -d.z)
	v.x = flat.x
	v.z = flat.z
	v.y = 0.0 if body.is_on_floor() else v.y - GRAVITY * dt * steps
	# move_and_slide integrates one tick; stretch the velocity over the ticks skipped.
	body.velocity = Vector3(v.x * steps, v.y * steps, v.z * steps)
	body.move_and_slide()
	body.velocity /= steps
	var p := body.global_position
	var g := ground_at(p)
	if p.y < g - 1.5:  # fell through (collision not loaded yet): put back on the ground
		p.y = g + 0.05
		body.global_position = p
		body.velocity = Vector3.ZERO
	rec.pos = p
	body.rotation.y = lerp_angle(body.rotation.y, rec.yaw, minf(1.0, dt * 10.0))
	body.speed = Vector2(v.x, v.z).length()
	_track_progress(rec)
	session.view.grid.put(LAYER, rec.id, rec.pos)


## Direct movement on the ground (no physics): any distance, any tier.
func _move_snapped(rec: NpcRecord, dt: float) -> void:
	if rec.move_target == Vector3.INF or dt <= 0.0:
		return
	var d := rec.move_target - rec.pos
	d.y = 0.0
	var dist := d.length()
	if dist < 0.05:
		return
	var step := minf(dist, rec.move_speed * dt)
	var next := rec.pos + d / dist * step
	if not walkable(next) and rec.state != NpcBrain.RETURN:
		rec.move_target = Vector3.INF
		return
	next.y = ground_at(next)
	rec.pos = next
	rec.yaw = atan2(-d.x, -d.z)
	_track_progress(rec)
	session.view.grid.put(LAYER, rec.id, rec.pos)


func _track_progress(rec: NpcRecord) -> void:
	if rec.move_target == Vector3.INF:
		return
	var d := Vector2(rec.pos.x - rec.move_target.x, rec.pos.z - rec.move_target.z).length()
	if d < rec.progress_d - 0.5:
		rec.progress_d = d
		rec.progress_t = now()


# --- tiers --------------------------------------------------------------------------------

## Re-tiers creatures near the focus. Every 4th pass (once a second) looks out to the FAR
## radius; the passes in between only re-score the NEAR range (FAR changes slowly).
func _schedule() -> void:
	var f := session.focus_position()
	var t := now()
	_pass += 1
	var full := _pass % 4 == 1
	var radius := (scheduler.r_far if full else scheduler.r_near) + scheduler.hysteresis + WorldGrid.CELL
	var cands: Array = []
	var current := {}
	var seen := {}
	for id in session.view.grid.query_radius(LAYER, f, radius):
		var rec: NpcRecord = records.get(id)
		if rec == null or not rec.alive:
			continue
		var d := Vector2(rec.pos.x - f.x, rec.pos.z - f.z).length()
		if not full and d > radius - WorldGrid.CELL and rec.tier >= SimScheduler.FAR:
			continue  # partial pass: leave far ones to the full pass
		seen[id] = true
		current[id] = rec.tier
		# Fighting creatures and unique NPCs get first claim on the detailed tiers.
		cands.append({"id": id, "dist": d, "combat": rec.in_combat(t) or rec.unique_id != ""})
	var tiers := scheduler.assign(cands, current)
	for id: String in _awake.keys():
		if seen.has(id):
			continue
		var rec: NpcRecord = records.get(id)
		if rec == null:
			_awake.erase(id)
		elif full or rec.tier <= SimScheduler.NEAR:
			# Out of the scored range: FAR if a partial pass dropped it, DORMANT on a full pass.
			var tier := SimScheduler.DORMANT if full else SimScheduler.FAR
			_set_tier(rec, tier)
			if tier == SimScheduler.DORMANT:
				_awake.erase(id)
	for id: String in seen:
		var rec: NpcRecord = records[id]
		var tier := int(tiers.get(id, SimScheduler.DORMANT))
		if tier != rec.tier:
			_set_tier(rec, tier)
		if tier == SimScheduler.DORMANT:
			_awake.erase(id)
		else:
			_awake[id] = true
	_active.clear()
	_near.clear()
	_far.clear()
	for id: String in _awake:
		var rec: NpcRecord = records[id]
		match rec.tier:
			SimScheduler.ACTIVE: _active.append(rec)
			SimScheduler.NEAR: _near.append(rec)
			SimScheduler.FAR: _far.append(rec)
	if full:
		_despawn_sweep(f)


## Ambient creatures far from the player go back to their slot (they respawn fresh when
## the player returns). Checked a few at a time.
func _despawn_sweep(f: Vector3) -> void:
	if _despawn_i >= _despawn_keys.size():
		_despawn_keys = records.keys()
		_despawn_i = 0
	var end := mini(_despawn_i + 64, _despawn_keys.size())
	for i in range(_despawn_i, end):
		var rec: NpcRecord = records.get(_despawn_keys[i])
		if rec and rec.tier == SimScheduler.DORMANT and rec.unique_id == "" and str(rec.def.despawn) == "ambient" \
				and rec.slot_id != "" and Vector2(rec.pos.x - f.x, rec.pos.z - f.z).length() > DESPAWN_RADIUS:
			despawn(rec.id, "far from the player")
	_despawn_i = end


func _set_tier(rec: NpcRecord, tier: int) -> void:
	if rec.tier == SimScheduler.DORMANT and tier != SimScheduler.DORMANT:
		_fast_forward(rec, now() - rec.last_tick)
	rec.tier = tier
	var needs_node := tier == SimScheduler.ACTIVE or tier == SimScheduler.NEAR
	if needs_node and rec.node_id == 0:
		_acquire_node(rec)
	elif not needs_node and rec.node_id != 0:
		_release_node(rec)
	if tier != SimScheduler.ACTIVE:
		rec.physics_mode = false


## Catch up after being dormant: settle at a plausible spot instead of simulating.
func _fast_forward(rec: NpcRecord, elapsed: float) -> void:
	rec.last_tick = now()
	if elapsed < 2.0:
		return
	if not rec.in_combat(now()):
		rec.health = rec.max_health
		rec.threat.clear()
		rec.target_id = ""
		rec.invulnerable = false
		if rec.state != NpcBrain.IDLE:
			brain.set_state(rec, self, NpcBrain.IDLE, "woke after %.0f s" % elapsed)
		if rec.movement == "patrol" and rec.path.size() >= 2:
			rec.path_index = int(elapsed * float(rec.def.walk_speed) / 20.0 + rec.path_index) % rec.path.size()
			rec.pos = rec.path[rec.path_index]
		elif rec.movement == "wander" and rec.wander_radius > 0.5:
			var a := rec.rand() * TAU
			var r := sqrt(rec.rand()) * rec.wander_radius
			var p := rec.home + Vector3(cos(a) * r, 0.0, sin(a) * r)
			if walkable(p):
				rec.pos = p
		rec.pos.y = ground_at(rec.pos)
		rec.move_target = Vector3.INF
		session.view.grid.put(LAYER, rec.id, rec.pos)


func _acquire_node(rec: NpcRecord) -> void:
	var list: Array = _pool.get(rec.archetype, [])
	var body: NpcBody
	if not list.is_empty():
		body = list.pop_back()
	else:
		body = NpcBody.new()
		body.manager = self
		body.setup(rec.def)
	body.record_id = rec.id
	body.name = rec.id.replace(":", "_")
	add_child(body)
	body.place(rec.pos, rec.yaw)
	if rec.fade_in:
		body.fade_in()
		rec.fade_in = false
	rec.node_id = body.get_instance_id()


func _release_node(rec: NpcRecord) -> void:
	var body := _body(rec)
	rec.node_id = 0
	rec.physics_mode = false
	if body == null:
		return
	body.record_id = ""
	remove_child(body)
	var list: Array = _pool.get(body.archetype, [])
	if list.size() < POOL_PER_TYPE:
		list.append(body)
		_pool[body.archetype] = list
	else:
		body.queue_free()
	if _labels.has(rec.id):
		(_labels[rec.id] as Node).queue_free()
		_labels.erase(rec.id)


func _body(rec: NpcRecord) -> NpcBody:
	if rec.node_id == 0:
		return null
	return instance_from_id(rec.node_id) as NpcBody


func count_by_tier() -> Array[int]:
	var c: Array[int] = [0, 0, 0, 0]
	for rec: NpcRecord in records.values():
		c[clampi(rec.tier, 0, 3)] += 1
	return c


# --- brain context ---------------------------------------------------------------------------

func player() -> PlayerController:
	return session.focus as PlayerController


func player_position() -> Vector3:
	var p := player()
	if p == null or p.health <= 0.0 or session.game.notarget:
		return Vector3.INF
	return p.global_position


func player_level() -> int:
	return session.game.progress.level()


func target_position(rec: NpcRecord) -> Vector3:
	if rec.target_id == "player":
		return player_position()
	var other: NpcRecord = records.get(rec.target_id)
	return other.pos if other and other.alive else Vector3.INF


func target_position_of(id: String) -> Vector3:
	if id == "player":
		return player_position()
	var other: NpcRecord = records.get(id)
	return other.pos if other and other.alive else Vector3.INF


func can_see(rec: NpcRecord, p: Vector3) -> bool:
	var eye := rec.pos + Vector3.UP * float(rec.def.height) * 0.9
	return session.queries.line_of_sight(eye, p + Vector3.UP * 1.5)


## Somewhere a creature may stand: on the map, not in water, not too steep.
func walkable(p: Vector3) -> bool:
	var m := session.map
	if m and (absf(p.x) > m.map_m * 0.5 - 4.0 or absf(p.z) > m.map_m * 0.5 - 4.0):
		return false
	var g := ground_at(p)
	if session.view.water_level_at(p) > g + 0.4:
		return false
	return session.view.terrain == null or session.view.terrain.get_normal(p).y >= 0.62


func attack(rec: NpcRecord) -> void:
	var p := player()
	if rec.target_id != "player" or p == null or p.health <= 0.0 or rec.damage <= 0.0:
		return
	if Vector2(rec.pos.x - p.global_position.x, rec.pos.z - p.global_position.z).length() > float(rec.def.attack.range) * 1.3:
		return
	var dir := (p.global_position - rec.pos).normalized()
	var ranged := float(rec.def.attack.range) > 3.0
	if ranged and not can_see(rec, p.global_position):
		return  # no shooting through walls
	p.apply_damage(DamageInfo.make(rec.damage, "magic" if ranged else "melee", rec.id, p.global_position + Vector3.UP, dir * 1.5))
	var body := _body(rec)
	if ranged:
		# Casters and archers: a bolt from the creature to the player instead of a lunge.
		var from := rec.pos + Vector3.UP * float(rec.def.height) * 0.8
		CombatFx.tracer(body.get_parent() if body else self, from, p.global_position + Vector3.UP * 1.2)
		SynthAudio.play_at(self, "impact", rec.pos, -4.0)
		return
	SynthAudio.play_at(self, "knife", rec.pos, -6.0)
	if body and body.visual:
		var tw := body.create_tween()
		tw.tween_property(body.visual, "position:z", -0.35, 0.08)
		tw.tween_property(body.visual, "position:z", 0.0, 0.15)


## Reactions (creature definition): yell, call_help, flee, set_flag — on aggro, damaged,
## health_below (fraction), death.
func react(rec: NpcRecord, event: String, value: float) -> void:
	var list: Array = rec.def.get("reactions", [])
	for i in list.size():
		var r: Dictionary = list[i]
		if str(r.get("event", "")) != event:
			continue
		if event == "health_below" and value > float(r.get("value", 0.0)):
			continue
		var key := "%d" % i
		var once := event != "damaged"
		if once and rec.reactions_done.has(key):
			continue
		if not once and now() - float(rec.reactions_done.get(key, -100.0)) < 5.0:
			continue
		if r.has("chance") and rec.rand() >= float(r.chance):
			continue
		if r.get("condition") is Dictionary and not StoryCondition.from_dict(r.condition).evaluate(session.game.story_state):
			continue
		rec.reactions_done[key] = now()
		match str(r.get("action", "")):
			"yell": say(rec, str(r.get("text", "!")))
			"call_help": call_help(rec, float(r.get("radius", 20.0)))
			"flee":
				rec.flee_from = player_position() if player_position() != Vector3.INF else rec.pos
				brain.set_state(rec, self, NpcBrain.FLEE, "reaction")
			"set_flag": session.game.story_state.set_flag(str(r.get("flag", "")))
		rec.add_log(now(), NpcBrain.NAMES[rec.state], NpcBrain.NAMES[rec.state], "reaction %s → %s" % [event, r.get("action", "")])


## Nearby creatures of the same faction join the fight.
func call_help(rec: NpcRecord, radius: float) -> void:
	if radius <= 0.0 or rec.target_id == "":
		return
	for id in session.view.grid.query_radius(LAYER, rec.pos, radius):
		var o: NpcRecord = records.get(id)
		if o == null or o == rec or not o.alive or str(o.def.faction) != str(rec.def.faction):
			continue
		if not str(o.def.behaviour) in ["aggressive", "defensive"]:
			continue
		if o.state in [NpcBrain.IDLE, NpcBrain.WANDER, NpcBrain.PATROL] and o.pos.distance_to(rec.pos) <= radius:
			o.target_id = rec.target_id
			o.important_until = now() + 15.0
			brain.set_state(o, self, NpcBrain.CHASE, "helping %s" % rec.display_name)


func say(rec: NpcRecord, text: String) -> void:
	var body := _body(rec)
	if body == null:
		return
	var l: Label3D = _labels.get(rec.id)
	if l == null:
		l = Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 40
		l.outline_size = 8
		l.pixel_size = 0.01
		body.add_child(l)
		_labels[rec.id] = l
	l.text = text
	l.position = Vector3.UP * (body.height + 0.6)
	l.visible = true
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if is_instance_valid(l):
			l.visible = false)


# --- damage and death --------------------------------------------------------------------------

func damage(id: String, info: DamageInfo) -> void:
	var rec: NpcRecord = records.get(id)
	if rec == null or not rec.alive:
		return
	if rec.invulnerable:
		rec.add_log(now(), NpcBrain.NAMES[rec.state], NpcBrain.NAMES[rec.state], "ignored a hit: evading (invulnerable while returning home)")
		return
	# "resist": {damage kind: fraction} — 0.4 takes 40 % less, -1.0 takes double (fire on a Blood Bat).
	var amount := info.amount * (1.0 - float((rec.def.get("resist", {}) as Dictionary).get(info.kind, 0.0)))
	rec.health -= amount
	rec.threat[info.source_id] = float(rec.threat.get(info.source_id, 0.0)) + amount
	rec.important_until = now() + 15.0
	_sched_t = 0.0
	var src: Vector3 = player_position() if info.source_id == "player" else (records[info.source_id].pos if records.has(info.source_id) else info.point)
	if rec.health <= 0.0:
		_kill(rec, info)
		return
	brain.on_damaged(rec, self, info.source_id, src if src != Vector3.INF else info.point)
	react(rec, "damaged", 0.0)
	react(rec, "health_below", rec.health / rec.max_health)


func _kill(rec: NpcRecord, info: DamageInfo) -> void:
	rec.alive = false
	rec.add_log(now(), NpcBrain.NAMES[rec.state], "DEAD", "killed by %s" % info.source_id)
	rec.state = NpcBrain.DEAD
	react(rec, "death", 0.0)
	var def := rec.def
	if info.source_id == "player":
		var xp := int(round(float(def.xp) * (1.0 + 0.1 * float(rec.level - int(def.level)))))
		session.game.progress.add_xp(xp)
		for s: Dictionary in def.get("skill_xp", []):
			session.game.progress.add_skill_xp(str(s.skill), int(s.amount))
		message.emit("%s killed  +%d XP" % [rec.display_name, xp])
	var loot: Array = []
	if str(def.loot_table) != "":
		var seed_value := Rng.hash2(hash(rec.id), int(now() * 10.0), 4441)
		loot = Loot.roll(str(def.loot_table), seed_value)
	var body := _body(rec)
	var corpse_node: Node3D = null
	if body and rec.physics_mode and str(def.body) == "humanoid":
		var color := Color.from_string(str(def.color), Color.GRAY)
		Ragdoll.spawn(self, body.global_transform, color, body.velocity,
			"head" if info.hitgroup == "head" else "chest", info.impulse * 3.0, info.point)
	elif body or session.focus_position().distance_to(rec.pos) < 220.0:
		corpse_node = _corpse_pose(def, rec)
	var cid := "corpse:" + rec.id
	corpses[cid] = {"id": cid, "archetype": rec.archetype, "pos": rec.pos, "yaw": rec.yaw,
		"expires_at": now() + CORPSE_TIME, "harvested": false, "node": corpse_node,
		"name": rec.display_name, "loot": loot}
	session.view.grid.put(CORPSE_LAYER, cid, rec.pos)
	_release_node(rec)
	session.view.grid.remove(LAYER, rec.id)
	records.erase(rec.id)
	_awake.erase(rec.id)
	_active.erase(rec)
	_near.erase(rec)
	_far.erase(rec)
	died.emit(rec, info.source_id)


## A lying copy of the creature (no physics) — used beyond terrain collision and for animals.
func _corpse_pose(def: Dictionary, rec: NpcRecord) -> Node3D:
	var built := CreatureVisual.build(def)
	var v: Node3D = built.visual
	var root := Node3D.new()
	root.add_child(v)
	add_child(root)
	root.global_position = rec.pos
	root.rotation.y = rec.yaw
	if str(def.body) == "quadruped":
		v.rotation.z = PI * 0.5
		v.position.y = float(def.height) * 0.3
	else:
		v.rotation.x = -PI * 0.5
		v.position.y = 0.2
	return root


## Corpses decay on the play clock, wherever they are.
func _tick_corpses(_dt: float) -> void:
	var t := now()
	for cid: String in corpses.keys():
		if t >= float(corpses[cid].expires_at):
			remove_corpse(cid)


## Takes loot from a corpse into the bag: one entry (index) or everything (-1). Coins are
## always taken (WoW auto-loots money). What doesn't fit stays. Returns items taken.
func take_loot(cid: String, index := -1) -> int:
	var c: Dictionary = corpses.get(cid, {})
	if c.is_empty():
		return 0
	var inv := session.game.inventory
	var taken := 0
	var keep: Array = []
	var loot: Array = c.loot
	for i in loot.size():
		var d: Dictionary = loot[i]
		if index >= 0 and i != index and str(d.item) != "coin":
			keep.append(d)
			continue
		var n := inv.add(str(d.item), int(d.count))
		if n > 0:
			taken += n
			session.game.notify("+%d %s" % [n, Defs.get_def("items", str(d.item)).get("name", d.item)])
		if n < int(d.count):
			keep.append({"item": d.item, "count": int(d.count) - n})
	c.loot = keep
	if keep.is_empty():
		c.expires_at = minf(float(c.expires_at), now() + CORPSE_LOOTED_TIME)
	elif taken == 0:
		session.game.notify("Your bag is full.")
	return taken


## After `skip`: whatever's time ran out goes now.
func age_corpses(_seconds: float) -> void:
	_tick_corpses(0.0)


## Corpses with loot or a harvest left are saved (dynamic objects with an expiry).
func corpses_to_save() -> Array:
	var out: Array = []
	for c: Dictionary in corpses.values():
		var p: Vector3 = c.pos
		out.append({"id": c.id, "archetype": c.archetype, "pos": [p.x, p.y, p.z], "yaw": float(c.get("yaw", 0.0)),
			"expires_at": c.expires_at, "harvested": c.harvested, "name": c.name, "loot": (c.loot as Array).duplicate(true)})
	return out


func corpses_from_save(list: Array) -> void:
	for c: Dictionary in list:
		var def := Defs.get_def("creatures", str(c.archetype))
		if def.is_empty() or float(c.expires_at) <= now():
			continue
		var p: Array = c.pos
		var rec := NpcRecord.new()
		rec.pos = Vector3(p[0], p[1], p[2])
		rec.yaw = float(c.get("yaw", 0.0))
		var loot: Array = []
		for d: Dictionary in c.get("loot", []):
			if Defs.has("items", str(d.item)):
				loot.append({"item": str(d.item), "count": int(d.count)})
		corpses[str(c.id)] = {"id": str(c.id), "archetype": str(c.archetype), "pos": rec.pos, "yaw": rec.yaw,
			"expires_at": float(c.expires_at), "harvested": bool(c.harvested), "node": _corpse_pose(def, rec),
			"name": str(c.name), "loot": loot}
		session.view.grid.put(CORPSE_LAYER, str(c.id), rec.pos)


func remove_corpse(cid: String) -> void:
	var c: Dictionary = corpses.get(cid, {})
	if c.is_empty():
		return
	if c.node and is_instance_valid(c.node):
		(c.node as Node).queue_free()
	session.view.grid.remove(CORPSE_LAYER, cid)
	corpses.erase(cid)


## Skinning, shearing…: the corpse's harvest table, once.
func harvest(cid: String) -> void:
	var c: Dictionary = corpses.get(cid, {})
	if c.is_empty() or c.harvested:
		return
	var h: Dictionary = Defs.get_def("creatures", str(c.archetype)).get("harvest", {})
	if h.is_empty():
		return
	c.harvested = true
	var drops := Loot.roll(str(h.loot_table), Rng.hash2(hash(cid), 77, 911))
	var inv := session.game.inventory
	for d: Dictionary in drops:
		var n := inv.add(str(d.item), int(d.count))
		if n < int(d.count):
			session.items.drop(str(d.item), int(d.count) - n, c.pos, "player_dropped")
	session.game.progress.add_skill_xp(str(h.get("skill", "skinning")), int(h.get("skill_xp", 5)))
	var names := PackedStringArray(drops.map(func(d: Dictionary) -> String:
		return "%s ×%d" % [Defs.get_def("items", str(d.item)).get("name", d.item), d.count]))
	message.emit("%s: %s  (+%d %s)" % [h.get("text", "Harvest"), ", ".join(names), int(h.get("skill_xp", 5)), h.get("skill", "skinning")])
	c.expires_at = minf(float(c.expires_at), now() + 20.0)


# --- far hits ------------------------------------------------------------------------------

## Hits against creatures without a body (far away), for Hitscan via WorldQueries.
func record_ray(from: Vector3, to: Vector3) -> Array:
	var out: Array = []
	var seg := to - from
	var len2 := seg.length_squared()
	if len2 < 0.0001:
		return out
	for id in session.view.grid.query_segment(LAYER, from, to, 2.0):
		var rec: NpcRecord = records.get(id)
		if rec == null or not rec.alive or rec.node_id != 0:
			continue
		var h := float(rec.def.height)
		var c := Vector3(rec.pos.x, ground_at(rec.pos) + h * 0.5, rec.pos.z)
		var t := clampf((c - from).dot(seg) / len2, 0.0, 1.0)
		var p := from + seg * t
		var radius := maxf(0.3, h * 0.35)
		if p.distance_to(c) <= radius:
			var rid := rec.id
			out.append({"position": p, "normal": (p - c).normalized(), "distance": from.distance_to(p),
				"apply": func(info: DamageInfo) -> void: damage(rid, info)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.distance) < float(b.distance))
	return out


# --- debugging -----------------------------------------------------------------------------------

func describe(id: String) -> String:
	var rec: NpcRecord = records.get(id)
	if rec == null:
		return "no creature '%s'" % id
	var f := session.focus_position()
	var lines: PackedStringArray = []
	lines.append("%s (%s) L%d  hp %.0f/%.0f  [%s]  %s%s" % [rec.display_name, rec.archetype, rec.level, rec.health,
		rec.max_health, NpcBrain.NAMES[rec.state], SimScheduler.NAMES[rec.tier], " physics" if rec.physics_mode else " snapped"])
	lines.append("id %s  slot %s  behaviour %s  %.0f m away, %.0f m from home  target %s" % [rec.id,
		rec.slot_id if rec.slot_id != "" else "-", rec.def.behaviour, rec.pos.distance_to(f),
		Vector2(rec.pos.x - rec.home.x, rec.pos.z - rec.home.z).length(), rec.target_id if rec.target_id != "" else "-"])
	for e: Array in rec.log.slice(maxi(0, rec.log.size() - 6)):
		lines.append("  t=%.1f  %s → %s  (%s)" % [e[0], e[1], e[2], e[3]])
	return "\n".join(lines)


func draw_debug(dd: DebugDraw) -> void:
	if not dd.is_on("ai"):
		return
	var f := session.focus_position()
	var pp := player_position()
	for id in session.view.grid.query_radius(LAYER, f, 160.0):
		var rec: NpcRecord = records.get(id)
		if rec == null:
			continue
		var col: Color = [Color(0.3, 1.0, 0.4), Color(0.4, 0.8, 1.0), Color(0.7, 0.7, 0.7), Color(0.4, 0.4, 0.4)][rec.tier]
		var top := rec.pos + Vector3.UP * (float(rec.def.height) + 0.5)
		dd.text(top, "%s L%d  %s  %s%s" % [rec.display_name, rec.level, NpcBrain.NAMES[rec.state],
			SimScheduler.NAMES[rec.tier], " ⚙" if rec.physics_mode else ""], col)
		if str(rec.def.behaviour) == "aggressive" and rec.state in [NpcBrain.IDLE, NpcBrain.WANDER, NpcBrain.PATROL]:
			dd.circle(rec.pos, clampf(float(rec.def.aggro_radius) + float(rec.level - player_level()), 5.0, 40.0), Color(1, 0.25, 0.2, 0.8), true, 32)
		if rec.state in [NpcBrain.CHASE, NpcBrain.ATTACK, NpcBrain.RETURN]:
			dd.circle(rec.home, float(rec.def.leash), Color(1.0, 0.6, 0.1, 0.8), true, 48)
			dd.line(rec.pos + Vector3.UP, rec.home + Vector3.UP, Color(1.0, 0.6, 0.1, 0.5))
		if rec.target_id == "player" and pp != Vector3.INF:
			dd.line(rec.pos + Vector3.UP, pp + Vector3.UP, Color(1, 0.2, 0.2), true)
		if rec.move_target != Vector3.INF:
			dd.line(rec.pos + Vector3.UP * 0.3, rec.move_target + Vector3.UP * 0.3, Color(0.3, 0.9, 1.0, 0.7))


func register_commands(c: DebugConsole) -> void:
	var archetypes := ConsoleParse.hints_of(func() -> Array: return Defs.ids("creatures"))
	c.verbs("npcs", "Creatures on this map.", self) \
		.verb("stats", "Counts per distance tier, corpses, pooled bodies and the AI's cost.", _cmd_npcs_stats) \
		.verb("list", "Creatures within a radius (default 60 m), nearest first.", _cmd_npcs_list, 0, 1, "/npcs list [radius]") \
		.verb("stress", "Spawns n random creatures in a ring 40-200 m around you (performance testing).", _cmd_npcs_stress, 1, 1, "/npcs stress <n>")
	c.command("spawn", "Spawns creatures in front of you (they fade in).", "/spawn <archetype> [count]", _cmd_spawn, 1, 2, archetypes, self)
	c.command("kill", "Kills creatures within a radius (default 30 m), or all of them (they drop loot).", "/kill [radius|all]", _cmd_kill, 0, 1,
		ConsoleParse.hints_of(["all", "10", "30", "100"]), self)
	c.command("despawn", "Removes creatures within a radius, or all of them, without corpses or loot.", "/despawn <radius|all>", _cmd_despawn, 1, 1,
		ConsoleParse.hints_of(["all", "30", "100"]), self)
	c.verbs("ai", "Creature AI.", self) \
		.verb("freeze", "Stops every creature where it stands.", _cmd_ai_freeze.bind(true)) \
		.verb("resume", "Lets them move again.", _cmd_ai_freeze.bind(false)) \
		.verb("timing", "What the AI costs per tick and per scheduling pass (and resets the averages).", _cmd_ai_timing)


func _cmd_npcs_stats(_a: PackedStringArray) -> Variant:
	var c := count_by_tier()
	return "%d creatures: %d active, %d near, %d far, %d dormant; %d corpses; %d pooled bodies.%s\nAI and movement %.2f ms per tick, scheduling %.2f ms per pass (every %.2f s)." % [
		records.size(), c[0], c[1], c[2], c[3], corpses.size(),
		_pool.values().reduce(func(acc: int, l: Array) -> int: return acc + l.size(), 0),
		"  AI is frozen." if frozen else "", avg_tick_ms(), avg_sched_ms(), SCHED_INTERVAL]


func _cmd_npcs_list(a: PackedStringArray) -> Variant:
	var r := ConsoleParse.number(a, 0, 60.0)
	var f := session.focus_position()
	var list: Array = []
	for id in session.view.grid.query_radius(LAYER, f, r):
		var rec: NpcRecord = records.get(id)
		if rec:
			list.append(rec)
	list.sort_custom(func(x: NpcRecord, y: NpcRecord) -> bool: return x.pos.distance_to(f) < y.pos.distance_to(f))
	if list.is_empty():
		return "No creature within %.0f m (%d on the map)." % [r, records.size()]
	var rows: Array = [["id", "creature", "level", "health", "state", "tier", "distance"]]
	for rec: NpcRecord in list:
		rows.append([rec.id, rec.display_name, rec.level, "%d/%d" % [int(rec.health), int(rec.max_health)], NpcBrain.NAMES[rec.state],
			SimScheduler.NAMES[rec.tier], "%.0f m" % rec.pos.distance_to(f)])
	return ConsoleResult.rich_text(ConsoleTable.format(rows, "single", "single", session.game.console.model.columns))


func _cmd_npcs_stress(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_int() or a[0].to_int() < 1:
		return ConsoleResult.failure("'%s' is not a number of creatures." % a[0])
	var n := mini(a[0].to_int(), 2000)
	var ids := Defs.ids("creatures")
	var f := session.focus_position()
	var made := 0
	for i in n:
		var ang := randf() * TAU
		var p := f + Vector3(cos(ang), 0.0, sin(ang)) * randf_range(40.0, 200.0)
		if walkable(p):
			spawn(ids[randi() % ids.size()], p, {"wander_radius": 12.0})
			made += 1
	session.game.mark_dev()
	return "Spawned %d of %d (the rest landed somewhere unwalkable). /npcs stats shows the cost." % [made, n]


func _cmd_spawn(a: PackedStringArray) -> Variant:
	if not Defs.has("creatures", a[0]):
		var s := ConsoleParse.suggestions(Array(Defs.ids("creatures")), a[0])
		return ConsoleResult.failure("No creature '%s'.%s" % [a[0], " Did you mean %s?" % ", ".join(s) if not s.is_empty() else " Try /content creatures."])
	var n := clampi(a[1].to_int() if a.size() > 1 else 1, 1, 50)
	var f := session.focus_position()
	var cam := get_viewport().get_camera_3d()
	var fwd := -cam.global_basis.z if cam else Vector3.FORWARD
	fwd.y = 0.0
	var at := f + fwd.normalized() * 10.0
	for i in n:
		spawn(a[0], at + Vector3(randf_range(-3, 3), 0, randf_range(-3, 3)), {"wander_radius": 8.0, "fade": true})
	session.game.mark_dev()
	return "Spawned %d %s." % [n, a[0]]


func _ids_within(a: PackedStringArray, fallback: float) -> Array:
	if not a.is_empty() and a[0] == "all":
		return records.keys()
	var r := ConsoleParse.number(a, 0, fallback)
	var f := session.focus_position()
	return session.view.grid.query_radius(LAYER, f, r).filter(func(id: String) -> bool:
		return records.has(id) and (records[id] as NpcRecord).pos.distance_to(f) <= r)


func _cmd_kill(a: PackedStringArray) -> Variant:
	if not a.is_empty() and a[0] != "all" and not a[0].is_valid_float():
		return ConsoleResult.failure("'%s' is not a radius or 'all'." % a[0])
	var n := 0
	for id: String in _ids_within(a, 30.0):
		var rec: NpcRecord = records.get(id)
		if rec and rec.alive:
			rec.invulnerable = false
			damage(id, DamageInfo.make(rec.health + 1.0, "console", "console", rec.pos))
			n += 1
	session.game.mark_dev()
	return "Killed %d." % n


func _cmd_despawn(a: PackedStringArray) -> Variant:
	if a[0] != "all" and not a[0].is_valid_float():
		return ConsoleResult.failure("'%s' is not a radius or 'all'." % a[0])
	var ids := _ids_within(a, 0.0)
	for id: String in ids:
		despawn(id, "console")
	session.game.mark_dev()
	return "Removed %d. Spawners bring theirs back by their own rules." % ids.size()


func _cmd_ai_freeze(_a: PackedStringArray, on: bool) -> Variant:
	frozen = on
	return "AI is frozen." if frozen else "AI is running."


func _cmd_ai_timing(_a: PackedStringArray) -> Variant:
	var out := "AI and movement %.2f ms per tick over %d ticks; scheduling %.2f ms per pass over %d passes (worst %.2f ms)." % [
		avg_tick_ms(), int(stats.ticks), avg_sched_ms(), int(stats.passes), float(stats.max_sched_us) / 1000.0]
	reset_stats()
	return out
