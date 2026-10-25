## The player's bag: stacks of {item, count} limited by each item's stack size and the
## number of slots. Plain data, saved with the game.
class_name Inventory
extends RefCounted

signal changed

var capacity := 40
var stacks: Array = []  ## [{item, count}]


## Adds as many as fit; returns how many were added.
func add(item_id: String, count: int) -> int:
	var max_stack := maxi(1, int(Defs.get_def("items", item_id).get("stack", 20)))
	var left := count
	for s: Dictionary in stacks:
		if left <= 0:
			break
		if s.item == item_id and int(s.count) < max_stack:
			var put := mini(left, max_stack - int(s.count))
			s.count = int(s.count) + put
			left -= put
	while left > 0 and stacks.size() < capacity:
		var put := mini(left, max_stack)
		stacks.append({"item": item_id, "count": put})
		left -= put
	if left != count:
		changed.emit()
	return count - left


## Removes up to `count`; returns how many were removed.
func remove(item_id: String, count: int) -> int:
	var left := count
	for i in range(stacks.size() - 1, -1, -1):
		if left <= 0:
			break
		var s: Dictionary = stacks[i]
		if s.item != item_id:
			continue
		var take := mini(left, int(s.count))
		s.count = int(s.count) - take
		left -= take
		if int(s.count) <= 0:
			stacks.remove_at(i)
	if left != count:
		changed.emit()
	return count - left


func count_of(item_id: String) -> int:
	var n := 0
	for s: Dictionary in stacks:
		if s.item == item_id:
			n += int(s.count)
	return n


## Totals per item, for display.
func totals() -> Dictionary:
	var out := {}
	for s: Dictionary in stacks:
		out[s.item] = int(out.get(s.item, 0)) + int(s.count)
	return out


func to_dict() -> Dictionary:
	return {"capacity": capacity, "stacks": stacks.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	capacity = int(d.get("capacity", 40))
	stacks = []
	for s: Variant in d.get("stacks", []):
		if s is Dictionary:
			stacks.append({"item": str(s.item), "count": int(s.count)})
	changed.emit()
