## One scale for every debug window (console, monitor panels), persisted in
## user://settings.cfg [console] scale.
class_name DebugZoom
extends RefCounted

const STEPS := [0.75, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

static var value := -1.0
static var persist := true
static var listeners: Array[Callable] = []


static func get_value() -> float:
	if value < 0.0:
		value = 1.0
		var cfg := ConfigFile.new()
		if persist and cfg.load(DevGate.SETTINGS) == OK:
			value = clampf(float(cfg.get_value("console", "scale", 1.0)), STEPS[0], STEPS[-1])
	return value


static func set_value(v: float) -> void:
	value = clampf(v, STEPS[0], STEPS[-1])
	if persist:
		var cfg := ConfigFile.new()
		cfg.load(DevGate.SETTINGS)
		cfg.set_value("console", "scale", value)
		cfg.save(DevGate.SETTINGS)
	for l in listeners.duplicate():
		if l.is_valid():
			l.call()


## Next rung strictly above (dir > 0) or below; returns false at the end of the range.
static func step(dir: int) -> bool:
	var v := get_value()
	var steps: Array = STEPS.duplicate()
	if dir < 0:
		steps.reverse()
	for s: float in steps:
		if (dir > 0 and s > v + 0.001) or (dir < 0 and s < v - 0.001):
			set_value(s)
			return true
	return false


static func percent() -> String:
	return "%d%%" % roundi(get_value() * 100.0)
