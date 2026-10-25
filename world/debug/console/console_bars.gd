## Title and status bar sections. A section is a Callable() -> String rendered every frame;
## sections in one slot are joined by two spaces (empty ones leave no gap), ordered by
## `order`, then registration.
class_name ConsoleBars
extends RefCounted

enum Slot { TITLE_LEFT, TITLE_RIGHT, STATUS_LEFT, STATUS_RIGHT }

var _sections: Array[Dictionary] = []   ## {name, slot, fn, order, seq, owner}
var _seq := 0


func add(name: String, slot: Slot, fn: Callable, order := 0, owner: Object = null) -> void:
	remove(name)
	_seq += 1
	_sections.append({"name": name, "slot": slot, "fn": fn, "order": order, "seq": _seq, "owner": weakref(owner) if owner else null})
	_sections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.order < b.order if a.order != b.order else a.seq < b.seq)


func remove(name: String) -> bool:
	for i in _sections.size():
		if str(_sections[i].name).to_lower() == name.to_lower():
			_sections.remove_at(i)
			return true
	return false


func remove_owner(owner: Object) -> void:
	_sections = _sections.filter(func(s: Dictionary) -> bool:
		return s.owner == null or ((s.owner as WeakRef).get_ref() != owner and (s.owner as WeakRef).get_ref() != null))


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for s in _sections:
		out.append(s.name)
	return out


func render(slot: Slot) -> String:
	var out := ""
	for s in _sections:
		if int(s.slot) != slot or not (s.fn as Callable).is_valid():
			continue
		var t := str(s.fn.call())
		if t == "":
			continue
		out += ("  " if out != "" else "") + t
	return out


## "Nms", "N.Ns", "Mm SSs" (wall-clock durations in the bars and replies).
static func duration(seconds: float) -> String:
	if seconds < 0.1:
		return "%dms" % int(seconds * 1000.0)
	if seconds < 60.0:
		return "%.1fs" % seconds
	return "%dm %02ds" % [int(seconds / 60.0), int(seconds) % 60]


static func spinner() -> String:
	return ["|", "/", "-", "\\"][int(Time.get_ticks_msec() / 100.0) % 4]
