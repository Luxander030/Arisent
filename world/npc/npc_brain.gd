## Creature AI: a small state machine (WoW-style mob behaviour) driven by data —
## behaviour profile, radii, speeds and reactions come from the creature definition.
##   IDLE → WANDER / PATROL → (sees the player) ALERT → CHASE → ATTACK
##   damaged → CHASE (aggressive/defensive) or FLEE (passive/skittish)
##   too far from home / stuck / target gone → RETURN (evade: invulnerable, heals at home)
## Stateless: all state lives in the NpcRecord; the brain talks to the world only through
## the context (NpcManager), so another brain (behaviour tree, utility AI) can replace it
## per creature type without touching anything else.
class_name NpcBrain
extends RefCounted

enum { IDLE, WANDER, PATROL, ALERT, CHASE, ATTACK, FLEE, RETURN, DEAD }
const NAMES := ["IDLE", "WANDER", "PATROL", "ALERT", "CHASE", "ATTACK", "FLEE", "RETURN", "DEAD"]

const STUCK_TIME := 8.0
const FLEE_TIME := 6.0
const ALERT_TIME := 0.4


## One decision step. `perceive` is false for far, data-only updates (no sight/hearing).
func think(rec: NpcRecord, ctx: Object, dt: float, perceive: bool) -> void:
	if not rec.alive:
		return
	var now: float = ctx.now()
	rec.timer -= dt
	# Creatures with "regen" (HP per second, e.g. the Blood Bat) heal while hurt.
	var regen := float(rec.def.get("regen", 0.0))
	if regen > 0.0 and rec.health < rec.max_health:
		rec.health = minf(rec.max_health, rec.health + regen * dt)
	var behaviour := str(rec.def.behaviour)
	if perceive and rec.state in [IDLE, WANDER, PATROL]:
		_perceive(rec, ctx, behaviour)
	match rec.state:
		IDLE:
			rec.move_target = Vector3.INF
			if rec.timer <= 0.0:
				if rec.movement == "patrol" and rec.path.size() >= 2:
					set_state(rec, ctx, PATROL, "patrol")
				elif rec.movement == "wander" and rec.wander_radius > 0.5:
					_pick_wander(rec, ctx)
					set_state(rec, ctx, WANDER, "wander")
				else:
					rec.timer = 3.0 + rec.rand() * 5.0
		WANDER:
			if rec.move_target == Vector3.INF or _flat(rec.pos, rec.move_target) < 0.8 or now - rec.progress_t > 6.0:
				rec.timer = 2.0 + rec.rand() * 6.0
				set_state(rec, ctx, IDLE, "arrived" if rec.move_target != Vector3.INF else "no target")
		PATROL:
			_patrol(rec, ctx)
		ALERT:
			rec.move_target = Vector3.INF
			if rec.timer <= 0.0:
				set_state(rec, ctx, CHASE, "engage")
		CHASE:
			var tp: Vector3 = ctx.target_position(rec)
			if tp == Vector3.INF:
				set_state(rec, ctx, RETURN, "target gone")
				return
			if _flat(rec.pos, rec.home) > float(rec.def.leash):
				set_state(rec, ctx, RETURN, "leash %.0f m" % rec.def.leash)
				return
			if now - rec.progress_t > STUCK_TIME:
				set_state(rec, ctx, RETURN, "stuck")
				return
			rec.move_target = tp
			rec.move_speed = float(rec.def.run_speed)
			if _flat(rec.pos, tp) <= float(rec.def.attack.range):
				set_state(rec, ctx, ATTACK, "in reach")
		ATTACK:
			var tp: Vector3 = ctx.target_position(rec)
			if tp == Vector3.INF:
				set_state(rec, ctx, RETURN, "target gone")
				return
			rec.move_target = Vector3.INF
			rec.yaw = _yaw_to(rec.pos, tp)
			if _flat(rec.pos, tp) > float(rec.def.attack.range) * 1.3:
				set_state(rec, ctx, CHASE, "target moved")
			elif rec.timer <= 0.0:
				rec.timer = float(rec.def.attack.interval)
				ctx.attack(rec)
		FLEE:
			var away := rec.pos - rec.flee_from
			away.y = 0.0
			if away.length() < 0.1:
				away = Vector3(rec.rand() - 0.5, 0.0, rec.rand() - 0.5)
			rec.move_target = rec.pos + away.normalized() * 12.0
			rec.move_speed = float(rec.def.run_speed)
			if now - rec.state_since > FLEE_TIME and _flat(rec.pos, rec.flee_from) > 25.0:
				rec.timer = 1.0 + rec.rand() * 3.0
				rec.threat.clear()
				rec.target_id = ""
				set_state(rec, ctx, IDLE, "safe")
		RETURN:
			rec.move_target = rec.home
			rec.move_speed = float(rec.def.run_speed)
			if _flat(rec.pos, rec.home) < 2.0 or now - rec.state_since > 30.0:
				rec.health = rec.max_health
				rec.invulnerable = false
				rec.threat.clear()
				rec.target_id = ""
				rec.timer = 1.0 + rec.rand() * 2.0
				set_state(rec, ctx, IDLE, "home")


## Damage response (called by the manager when hit, at any tier).
func on_damaged(rec: NpcRecord, ctx: Object, source_id: String, source_pos: Vector3) -> void:
	if not rec.alive or rec.state == RETURN:
		return
	match str(rec.def.behaviour):
		"aggressive", "defensive":
			if rec.state != CHASE and rec.state != ATTACK:
				rec.target_id = source_id
				set_state(rec, ctx, CHASE, "attacked by %s" % source_id)
			else:
				_retarget(rec, ctx)
		_:
			rec.flee_from = source_pos
			if rec.state != FLEE:
				set_state(rec, ctx, FLEE, "hurt by %s" % source_id)


## WoW threat rule: switch to whoever has more than 110 % of the current target's threat.
func _retarget(rec: NpcRecord, ctx: Object) -> void:
	var cur := float(rec.threat.get(rec.target_id, 0.0))
	for id: Variant in rec.threat:
		if str(id) != rec.target_id and float(rec.threat[id]) > cur * 1.1 and ctx.target_position_of(str(id)) != Vector3.INF:
			rec.add_log(ctx.now(), NAMES[rec.state], NAMES[rec.state], "switched target to %s (threat)" % id)
			rec.target_id = str(id)
			cur = float(rec.threat[id])


func set_state(rec: NpcRecord, ctx: Object, s: int, reason: String) -> void:
	if rec.state == s:
		return
	var now: float = ctx.now()
	rec.add_log(now, NAMES[rec.state], NAMES[s], reason)
	rec.state = s
	rec.state_since = now
	rec.progress_t = now
	rec.progress_d = INF
	rec.invulnerable = s == RETURN
	match s:
		WANDER, PATROL:
			rec.move_speed = float(rec.def.walk_speed)
		ALERT:
			rec.timer = ALERT_TIME
			ctx.react(rec, "aggro", 0.0)
		ATTACK:
			rec.timer = minf(rec.timer, 0.3)
	if s == CHASE:
		ctx.call_help(rec, float(rec.def.assist_radius))


func _perceive(rec: NpcRecord, ctx: Object, behaviour: String) -> void:
	var pp: Vector3 = ctx.player_position()
	if pp == Vector3.INF:
		return
	var d := _flat(rec.pos, pp)
	match behaviour:
		"aggressive":
			var radius := clampf(float(rec.def.aggro_radius) + float(rec.level - int(ctx.player_level())), 5.0, 40.0)
			if d <= radius and ctx.can_see(rec, pp):
				rec.target_id = "player"
				set_state(rec, ctx, ALERT, "saw the player at %.0f m" % d)
		"skittish":
			if d <= float(rec.def.flee_radius) and ctx.can_see(rec, pp):
				rec.flee_from = pp
				set_state(rec, ctx, FLEE, "spooked at %.0f m" % d)


func _pick_wander(rec: NpcRecord, ctx: Object) -> void:
	for attempt in 5:
		var a := rec.rand() * TAU
		var r := sqrt(rec.rand()) * rec.wander_radius
		var p := rec.home + Vector3(cos(a) * r, 0.0, sin(a) * r)
		if ctx.walkable(p):
			rec.move_target = p
			return
	rec.move_target = rec.home


func _patrol(rec: NpcRecord, ctx: Object) -> void:
	var target := rec.path[clampi(rec.path_index, 0, rec.path.size() - 1)]
	if _flat(rec.pos, target) > 1.0:
		rec.move_target = target
		rec.move_speed = float(rec.def.walk_speed)
		return
	rec.move_target = Vector3.INF
	if rec.timer > 0.0:
		return
	rec.timer = rec.path_wait
	var n := rec.path.size()
	match rec.path_mode:
		"pingpong":
			if rec.path_index + rec.path_dir >= n or rec.path_index + rec.path_dir < 0:
				rec.path_dir = -rec.path_dir
			rec.path_index += rec.path_dir
		"once":
			if rec.path_index < n - 1:
				rec.path_index += 1
			else:
				set_state(rec, ctx, IDLE, "path finished")
				rec.movement = "idle"
		_:
			rec.path_index = (rec.path_index + 1) % n


static func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func _yaw_to(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return atan2(-d.x, -d.z)
