## Monotonic play time in seconds. Advances only while the game runs (not paused) and on
## explicit skips (sleeping, waiting, the `skip` console command). Every persisted timer
## (respawn_at, TTL counters, zone resets) is measured on this clock, so changing the
## length of a day never touches them.
class_name SimClock
extends RefCounted

var now := 0.0
var scale := 1.0      ## debug time scale (console `timescale`)
var paused := false


func advance(real_dt: float) -> float:
	if paused:
		return 0.0
	var dt := real_dt * scale
	now += dt
	return dt


func skip(seconds: float) -> void:
	now += maxf(0.0, seconds)
