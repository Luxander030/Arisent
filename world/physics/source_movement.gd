## The Source/Quake movement maths as pure functions (velocities in m/s, Y up), so they
## can be unit-tested and reused for NPCs. Written from the published Source SDK 2013
## behaviour (CGameMovement::Friction / Accelerate / AirAccelerate / ClipVelocity).
class_name SourceMovement
extends RefCounted


## Ground friction. Below stop_speed it is a constant deceleration, above it exponential.
static func friction(vel: Vector3, s: MovementSettings, dt: float, surface_friction := 1.0) -> Vector3:
	var speed := vel.length()
	if speed < 0.1 * MovementSettings.U:
		return Vector3.ZERO
	var control := maxf(speed, s.m(s.stop_speed))
	var drop := control * s.friction * surface_friction * dt
	return vel * (maxf(speed - drop, 0.0) / speed)


## Ground acceleration toward wishdir. Uses the speed *along* wishdir, not the total speed.
static func accelerate(vel: Vector3, wishdir: Vector3, wishspeed: float, accel: float, dt: float, surface_friction := 1.0) -> Vector3:
	var current := vel.dot(wishdir)
	var add := wishspeed - current
	if add <= 0.0:
		return vel
	return vel + wishdir * minf(accel * dt * wishspeed * surface_friction, add)


## Air acceleration: the cap applies only to the projection on wishdir, so turning while
## strafing keeps adding sideways speed (air strafing / bunny hopping).
static func air_accelerate(vel: Vector3, wishdir: Vector3, wishspeed: float, s: MovementSettings, dt: float) -> Vector3:
	var capped := minf(wishspeed, s.m(s.air_speed_cap))
	var current := vel.dot(wishdir)
	var add := capped - current
	if add <= 0.0:
		return vel
	return vel + wishdir * minf(s.air_accelerate * wishspeed * dt, add)


## Removes the part of the velocity going into a surface (overbounce 1 = slide).
static func clip_velocity(vel: Vector3, normal: Vector3, overbounce := 1.0) -> Vector3:
	var backoff := vel.dot(normal) * overbounce
	var out := vel - normal * backoff
	var adjust := out.dot(normal)
	if adjust < 0.0:
		out -= normal * adjust
	return out


## Fall damage for a landing speed (m/s), CS formula.
static func fall_damage(fall_speed: float, s: MovementSettings) -> float:
	var v := fall_speed / MovementSettings.U
	if v <= s.fall_safe_speed:
		return 0.0
	return (v - s.fall_safe_speed) * 100.0 / (s.fall_fatal_speed - s.fall_safe_speed)


## CS:GO stamina speed factor.
static func stamina_factor(stamina: float) -> float:
	var f := clampf(1.0 - stamina / 100.0, 0.0, 1.0)
	return f * f


static func clamp_velocity(vel: Vector3, s: MovementSettings) -> Vector3:
	var lim := s.m(s.max_velocity)
	return Vector3(clampf(vel.x, -lim, lim), clampf(vel.y, -lim, lim), clampf(vel.z, -lim, lim))
