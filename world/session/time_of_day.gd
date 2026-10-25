## Hour of the in-game day (0..24), its own accumulator so the day length can change
## without moving any timers (those use SimClock). Default: one game day = 48 real minutes.
class_name TimeOfDay
extends RefCounted

var hours := 9.0
var day_minutes := 48.0   ## real minutes per in-game day
var day := 0              ## days passed


func advance(dt: float) -> void:
	add_hours(dt * 24.0 / (day_minutes * 60.0))


func add_hours(h: float) -> void:
	hours += h
	while hours >= 24.0:
		hours -= 24.0
		day += 1
	while hours < 0.0:
		hours += 24.0
		day -= 1


func set_hours(h: float) -> void:
	hours = fposmod(h, 24.0)


## True if the hour lies in [start, end) — windows may wrap past midnight (e.g. 20 → 6).
static func in_window(h: float, start: float, end: float) -> bool:
	if absf(end - start) >= 24.0 or is_equal_approx(start, end):
		return true  # 0 → 24, or an empty window meaning "always"
	if start <= end:
		return h >= start and h < end
	return h >= start or h < end


func label() -> String:
	return "day %d, %02d:%02d" % [day + 1, int(hours), int(fmod(hours, 1.0) * 60.0)]
