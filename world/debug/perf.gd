## Main-thread time per game system, per frame — for finding what causes a slow frame.
## Systems wrap their per-frame work in Perf.begin(name) / Perf.end(name); while disabled
## (the default) that costs one check. tests/bench_game.gd (BENCH_PERF=1) reads it:
## take() returns the time each system used since the last call.
class_name Perf
extends RefCounted

static var enabled := false
static var _start := {}   ## name -> usec when it began
static var _frame := {}   ## name -> usec used since the last take()


static func begin(name: StringName) -> void:
	if enabled:
		_start[name] = Time.get_ticks_usec()


static func end(name: StringName) -> void:
	if enabled and _start.has(name):
		_frame[name] = int(_frame.get(name, 0)) + Time.get_ticks_usec() - int(_start[name])


## {name: microseconds} since the last call, and starts a new count.
static func take() -> Dictionary:
	var f := _frame
	_frame = {}
	return f
