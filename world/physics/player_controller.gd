## Counter-Strike-style character movement (Source engine rules) on a CharacterBody3D.
## Per physics tick, in Source's order: duck -> first half of gravity -> jump -> ground
## friction (skipped on the jump tick, which is what makes bunny hopping possible) ->
## ground or air acceleration -> step-up -> move_and_slide (slides along walls, snaps to
## the ground like StayOnGround) -> push physics props -> ground check -> second half of
## gravity -> landing (fall damage, stamina). Swimming uses Source's WaterMove instead.
## Units: metres; constants live in MovementSettings (Source units, converted with U).
class_name PlayerController
extends CharacterBody3D

signal landed(fall_speed: float)
signal damaged(amount: float, cause: String)
signal died

## What the controller wants to do this tick. A player fills it from the keyboard and
## camera; tests and NPCs set it directly.
class MoveInput:
	var move := Vector2.ZERO     ## x = right, y = forward, length <= 1
	var yaw := 0.0               ## facing (radians, Godot convention: 0 = -Z)
	var pitch := 0.0             ## used when swimming
	var jump := false            ## held
	var crouch := false
	var walk := false

var settings := MovementSettings.new()
var input := MoveInput.new()
## Returns the water surface height at a position, or -INF where there is no water.
var water_level_func := func(_p: Vector3) -> float: return -INF

var health := 100.0
var stamina := 0.0
var on_ground := false
var ducked := false
var swimming := false
var on_ladder := false
var ladder_normal := Vector3.ZERO  ## points from the ladder toward the climber
## Weapon carried limits speed like in CS (knife 250, rifle 215, ...). 0 = no limit.
var weapon_max_speed := 0.0
## Bodies to ignore when pushing / standing (e.g. a prop being carried).
var carried_body: RigidBody3D
var duck_amount := 0.0          ## 0 standing .. 1 crouched (eye height / visual)
var visual_step_offset := 0.0   ## smooths the pop of step-ups for the camera and model

var _shape: CylinderShape3D
var _shape_node: CollisionShape3D
var _jump_held := false
var _fall_speed := 0.0
var _jumped_this_tick := false


func _ready() -> void:
	collision_layer = PhysicsLayers.PLAYER
	collision_mask = PhysicsLayers.PLAYER_MASK
	platform_floor_layers = PhysicsLayers.WORLD | PhysicsLayers.DYNAMIC  # light props never carry you
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = acos(settings.walkable_normal)
	floor_constant_speed = false
	floor_block_on_wall = true
	max_slides = 6
	safe_margin = 0.005
	_shape = CylinderShape3D.new()
	_shape.margin = 0.01
	_shape_node = CollisionShape3D.new()
	_shape_node.shape = _shape
	add_child(_shape_node)
	_set_hull(false)


# --- hull ---------------------------------------------------------------------------

func hull_height() -> float:
	return settings.m(settings.duck_height if ducked else settings.hull_height)


func eye_height() -> float:
	return lerpf(settings.m(settings.eye_height), settings.m(settings.duck_eye_height), duck_amount)


## Origin is at the feet; the cylinder sits on top of it.
func _set_hull(duck: bool) -> void:
	ducked = duck
	_shape.radius = settings.m(settings.hull_radius)
	_shape.height = hull_height()
	_shape_node.position = Vector3(0, _shape.height * 0.5, 0)


## Would the standing hull fit at this feet position?
func _fits_standing(feet: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var probe := CylinderShape3D.new()
	probe.radius = settings.m(settings.hull_radius) - 0.01
	probe.height = settings.m(settings.hull_height) - 0.02
	q.shape = probe
	q.transform = Transform3D(Basis(), feet + Vector3(0, probe.height * 0.5 + 0.01, 0))
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Crouching on the ground shrinks the hull from the top; in the air it pulls the feet up
## (Source's duck-jump: you clear higher ledges). Standing up needs headroom.
func _update_duck(dt: float) -> void:
	var delta := settings.m(settings.hull_height - settings.duck_height)
	if input.crouch and not ducked:
		_set_hull(true)
		if not on_ground and not swimming:
			global_position.y += delta
			visual_step_offset -= delta
	elif not input.crouch and ducked:
		var feet := global_position
		if not on_ground and not swimming:
			feet.y -= delta  # unduck in the air: feet come back down if there is room
			if not _fits_standing(feet):
				feet.y = global_position.y
		if _fits_standing(feet):
			visual_step_offset += global_position.y - feet.y
			global_position = feet
			_set_hull(false)
	var target := 1.0 if ducked else 0.0
	var rate := 1.0 / maxf(settings.duck_time if ducked else settings.unduck_time, 0.01)
	duck_amount = move_toward(duck_amount, target, rate * dt)


# --- main loop ------------------------------------------------------------------------

func _physics_process(dt: float) -> void:
	_jumped_this_tick = false
	var feet_level := water_level_func.call(global_position) as float
	swimming = global_position.y + settings.m(36.0) < feet_level  # waist deep
	_update_duck(dt)
	_check_ladder()
	if swimming:
		_water_move(dt, feet_level)
	elif on_ladder:
		_ladder_move(dt)
	else:
		_walk_move(dt)
	_pushaway(dt)
	stamina = maxf(0.0, stamina - settings.stamina_recovery * dt)
	visual_step_offset = move_toward(visual_step_offset, 0.0, maxf(absf(visual_step_offset) * 12.0, 0.5) * dt)
	_jump_held = input.jump


func current_max_speed() -> float:
	var sp := settings.m(settings.max_speed)
	if weapon_max_speed > 0.0:
		sp = minf(sp, settings.m(weapon_max_speed))
	if ducked:
		sp *= settings.duck_scale
	elif input.walk:
		sp *= settings.walk_scale
	if settings.stamina_max > 0.0:
		sp *= SourceMovement.stamina_factor(stamina)
	return sp


func _wish(three_d: bool) -> Array:
	var b := Basis(Vector3.UP, input.yaw)
	if three_d:
		b = b * Basis(Vector3.RIGHT, input.pitch)
	var fwd := -b.z
	var right := b.x
	if not three_d:
		fwd = Vector3(fwd.x, 0, fwd.z).normalized()
		right = Vector3(right.x, 0, right.z).normalized()
	var wish := fwd * input.move.y + right * input.move.x
	var amount := minf(wish.length(), 1.0)
	return [wish.normalized() if amount > 0.0 else Vector3.ZERO, amount * current_max_speed()]


func _walk_move(dt: float) -> void:
	var s := settings
	var g := s.m(s.gravity)
	var w := _wish(false)
	var wishdir: Vector3 = w[0]
	var wishspeed: float = w[1]
	if not on_ground:
		velocity.y -= g * 0.5 * dt  # StartGravity
	if on_ground and input.jump and (s.auto_bunnyhop or not _jump_held):
		_jump(g, dt)
	if on_ground:
		velocity.y = 0.0
		velocity = SourceMovement.friction(velocity, s, dt)
		velocity = SourceMovement.accelerate(velocity, wishdir, wishspeed, s.accelerate, dt)
		velocity.y = 0.0
	else:
		velocity = SourceMovement.air_accelerate(velocity, wishdir, wishspeed, s, dt)
	velocity = SourceMovement.clamp_velocity(velocity, s)
	# Jolt: don't creep down slopes while standing still.
	floor_stop_on_slope = wishspeed < 0.01
	floor_snap_length = s.m(s.step_size) if on_ground and not _jumped_this_tick else 0.0
	var pre := velocity
	var start := global_transform
	var was_ground := on_ground
	move_and_slide()
	if was_ground and not _jumped_this_tick:
		_step_move(start, pre, dt)
	_push_props(pre)
	on_ground = is_on_floor() and velocity.y <= s.m(s.non_jump_velocity) and not _jumped_this_tick
	if not on_ground:
		velocity.y -= g * 0.5 * dt  # FinishGravity
		_fall_speed = maxf(_fall_speed, -velocity.y)
	elif not was_ground:
		_land()
	if on_ground and is_zero_approx(velocity.y):
		velocity.y = 0.0


func _jump(g: float, dt: float) -> void:
	var s := settings
	if not s.bunnyhop_uncapped:
		# CS:S / CS:GO PreventBunnyJumping: horizontal speed capped to 1.1 × max on a jump.
		var cap := 1.1 * s.m(s.max_speed)
		var flat := Vector3(velocity.x, 0, velocity.z)
		if flat.length() > cap:
			flat = flat.normalized() * cap
			velocity.x = flat.x
			velocity.z = flat.z
	var factor := clampf(1.0 - stamina / 100.0, 0.0, 1.0) if s.stamina_max > 0.0 else 1.0
	velocity.y = s.m(s.jump_impulse) * factor
	velocity.y -= g * 0.5 * dt  # CheckJumpButton finishes the tick's gravity itself
	if s.stamina_max > 0.0:
		stamina = minf(s.stamina_max, stamina + s.stamina_jump_cost * s.jump_impulse)
	on_ground = false
	_jumped_this_tick = true
	_fall_speed = 0.0


func _land() -> void:
	var s := settings
	var fall := _fall_speed
	_fall_speed = 0.0
	if s.stamina_max > 0.0:
		stamina = minf(s.stamina_max, stamina + s.stamina_land_cost * fall / MovementSettings.U)
	var dmg := SourceMovement.fall_damage(fall, s)
	if dmg > 0.0:
		take_damage(dmg, "fall")
	landed.emit(fall)


## Source WaterMove: full 3D swimming toward where you look, slow sink when idle,
## jump swims up, no gravity.
func _water_move(dt: float, surface: float) -> void:
	var s := settings
	var w := _wish(true)
	var wish: Vector3 = (w[0] as Vector3) * (w[1] as float)
	if input.jump:
		wish.y += current_max_speed()
	elif input.move == Vector2.ZERO:
		wish.y -= s.m(s.water_sink_speed)
	var wishspeed := minf(wish.length(), current_max_speed()) * s.water_speed_scale
	var wishdir := wish.normalized() if wish.length() > 0.0 else Vector3.ZERO
	var speed := velocity.length()
	if speed > 0.0:
		velocity *= maxf(speed - dt * speed * s.friction, 0.0) / speed
	velocity = SourceMovement.accelerate(velocity, wishdir, wishspeed, s.accelerate, dt)
	# Hop out when pushing up at the surface.
	if input.jump and global_position.y + s.m(36.0) > surface - 0.15:
		velocity.y = maxf(velocity.y, s.m(s.water_jump_speed) * 2.0)
	floor_snap_length = 0.0
	var pre := velocity
	move_and_slide()
	_push_props(pre)
	on_ground = false
	_fall_speed = 0.0


# --- ladders --------------------------------------------------------------------------

var _ladder_cooldown := 0.0

## Ladders are Area3D volumes (TRIGGER layer, meta "ladder"; climbing side = the area's
## -Z). You grab one by
## being inside it and moving toward it (Source LadderMove); jumping pushes you off.
func _check_ladder() -> void:
	_ladder_cooldown -= get_physics_process_delta_time()
	var area := _touching_ladder()
	if area == null or _ladder_cooldown > 0.0 or swimming:
		on_ladder = false
		return
	var n := -area.global_basis.z
	n.y = 0.0
	n = n.normalized()
	if (global_position - area.global_position).dot(-n) > 0.0:
		on_ladder = false  # past the rungs: climbed out over the top
		return
	if on_ladder:
		ladder_normal = n
		return
	var wishdir: Vector3 = _wish(false)[0]
	if wishdir.dot(-n) > 0.3 or (not on_ground and velocity.dot(-n) > 0.0):
		on_ladder = true
		ladder_normal = n
		on_ground = false


func _touching_ladder() -> Area3D:
	var q := PhysicsShapeQueryParameters3D.new()
	var probe := CylinderShape3D.new()
	probe.radius = settings.m(settings.hull_radius) + 0.08
	probe.height = hull_height()
	q.shape = probe
	q.transform = Transform3D(Basis(), global_position + Vector3(0, probe.height * 0.5, 0))
	q.collision_mask = PhysicsLayers.TRIGGER
	q.collide_with_areas = true
	q.collide_with_bodies = false
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 4):
		var a := hit.collider as Area3D
		if a and a.has_meta("ladder"):
			return a
	return null


func _ladder_move(dt: float) -> void:
	var s := settings
	var speed := s.m(s.ladder_climb_speed)
	if ducked or input.walk:
		speed *= s.ladder_slow_scale
	if input.jump and not _jump_held:
		# Push off the ladder.
		velocity = ladder_normal * s.m(s.ladder_jump_off_speed) + Vector3.UP * s.m(60.0)
		on_ladder = false
		_ladder_cooldown = 0.3
		move_and_slide()
		return
	# Forward climbs up — or down when looking down (as in Source); strafe moves sideways.
	var forward := input.move.y * (-1.0 if input.pitch < -0.6 else 1.0)
	var side := ladder_normal.cross(Vector3.UP).normalized()
	var right := Basis(Vector3.UP, input.yaw).x
	var lateral := side * signf(side.dot(right)) * input.move.x * speed * 0.5
	velocity = Vector3.UP * forward * speed + lateral - ladder_normal * 0.3  # small pull keeps contact
	if on_ground_probe() and forward < 0.0:
		# Reached the bottom pressing down: step off backwards.
		velocity += ladder_normal * speed
	floor_snap_length = 0.0
	var pre := velocity
	move_and_slide()
	_push_props(pre)
	_fall_speed = 0.0


func on_ground_probe() -> bool:
	return test_move(global_transform, Vector3.DOWN * settings.m(2.0))


# --- pushaway clutter -----------------------------------------------------------------

## Source obstacle_pushaway: clutter on the PUSHAWAY layer doesn't block the player; when
## moving faster than a walk, nearby pieces get nudged away (stronger when closer).
func _pushaway(dt: float) -> void:
	var s := settings
	var flat := Vector3(velocity.x, 0, velocity.z)
	if flat.length() < s.m(s.push_min_speed):
		return
	var q := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = s.m(s.hull_radius + s.pushaway_radius)
	q.shape = sphere
	q.transform = Transform3D(Basis(), global_position + Vector3(0, sphere.radius * 0.6, 0))
	q.collision_mask = PhysicsLayers.PUSHAWAY
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 16):
		var body := hit.collider as RigidBody3D
		if body == null:
			continue
		var away := body.global_position - global_position
		away.y = 0.0
		var dist := maxf(away.length(), 0.05)
		var dir := away / dist if dist > 0.05 else flat.normalized()
		# Mostly ahead of us and away from our path.
		dir = (dir + flat.normalized() * 0.5).normalized()
		var push := minf(s.m(s.pushaway_force) / dist, s.m(s.pushaway_force) * 4.0)
		body.apply_central_impulse(dir * push * body.mass * dt + Vector3.UP * body.mass * 0.4 * dt)


# --- steps ----------------------------------------------------------------------------

## Source StepMove: after the normal move, if a wall stopped us, test the path
## "up step_size, forward, down" from where we started and keep it if it gets further
## and lands on walkable ground (never on props). Walkable slopes never take this path.
func _step_move(start: Transform3D, pre: Vector3, dt: float) -> void:
	var s := settings
	var want := Vector3(pre.x, 0, pre.z) * dt
	if want.length() < 0.0005:
		return
	var moved := global_position - start.origin
	var plain := Vector2(moved.x, moved.z).length()
	if plain >= want.length() * 0.95:
		return  # not blocked
	var blocked_by_wall := false
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if n.y < s.walkable_normal and n.y > -0.1:
			blocked_by_wall = true
	if not blocked_by_wall:
		return
	var p := PhysicsTestMotionParameters3D.new()
	p.margin = safe_margin
	var r := PhysicsTestMotionResult3D.new()
	var xf := start
	p.from = xf
	p.motion = Vector3.UP * s.m(s.step_size)
	PhysicsServer3D.body_test_motion(get_rid(), p, r)
	var climbed := r.get_travel().y
	if climbed < 0.01:
		return  # no headroom
	xf = xf.translated(r.get_travel())
	p.from = xf
	p.motion = want
	PhysicsServer3D.body_test_motion(get_rid(), p, r)
	xf = xf.translated(r.get_travel())
	p.from = xf
	p.motion = Vector3.DOWN * (climbed + 0.02)
	if not PhysicsServer3D.body_test_motion(get_rid(), p, r):
		return  # stepping off into nothing: let the plain move stand
	if r.get_collision_normal().y < s.walkable_normal or r.get_collider() is RigidBody3D:
		return
	xf = xf.translated(r.get_travel())
	var stepped := Vector2(xf.origin.x - start.origin.x, xf.origin.z - start.origin.z).length()
	var dy := xf.origin.y - global_position.y
	if stepped <= plain + 0.002 or dy > s.m(s.step_size) + 0.02:
		return
	global_transform = xf
	velocity.x = pre.x  # the step removed the wall that clipped our speed
	velocity.z = pre.z
	velocity.y = 0.0
	visual_step_offset -= dy
	apply_floor_snap()


# --- props ----------------------------------------------------------------------------

## The player is kinematic, so pushing is scripted (Source's 85 kg physics shadow):
## only when moving faster than walking-into-it speed, horizontal only, weaker on
## heavier props, never the prop you stand on.
func _push_props(pre_vel: Vector3) -> void:
	var s := settings
	var flat := Vector3(pre_vel.x, 0, pre_vel.z)
	if flat.length() < s.m(s.push_min_speed):
		return
	var floor_body: Object = null
	if is_on_floor():
		for i in get_slide_collision_count():
			var c := get_slide_collision(i)
			if c.get_normal().y >= s.walkable_normal:
				floor_body = c.get_collider()
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var body := c.get_collider() as RigidBody3D
		if body == null or body == floor_body or body.freeze or body == carried_body:
			continue
		var dir := -c.get_normal()
		dir.y = 0.0
		if dir.length() < 0.01:
			continue
		dir = dir.normalized()
		var dv := pre_vel.dot(dir) - body.linear_velocity.dot(dir)
		if dv <= 0.0:
			continue
		var share := minf(body.mass, s.player_mass) * 0.5
		body.apply_impulse(dir * dv * share, c.get_position() - body.global_position)


# --- health ---------------------------------------------------------------------------

## Console `god`: takes no damage.
var invulnerable := false


func take_damage(amount: float, cause := "") -> void:
	if health <= 0.0 or invulnerable:
		return
	health = maxf(0.0, health - amount)
	damaged.emit(amount, cause)
	if health <= 0.0:
		died.emit()


## Damage contract shared with NPCs and props (see DamageInfo).
func apply_damage(info: DamageInfo) -> void:
	velocity += info.impulse / maxf(settings.player_mass, 1.0)
	take_damage(info.amount, info.kind)


## Spatial queries for this character (the session sets terrain-aware ones; tests and
## stand-alone scenes get plain physics queries).
var queries: WorldQueries


func get_queries() -> WorldQueries:
	if queries == null:
		queries = WorldQueries.for_space(get_world_3d().direct_space_state)
	return queries


## Weapons and impacts: damage at a body part (hitgroup multipliers are applied by the
## caller); the impulse is ignored for the kinematic player except for a small shove.
func apply_hit(damage: float, impulse: Vector3, _at: Vector3, _hitgroup := "") -> void:
	velocity += impulse / maxf(settings.player_mass, 1.0)
	take_damage(damage, "hit")


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()
