## Loot tables with World of Warcraft semantics (loot_tables.json):
##   rows without "group" roll independently (chance %, min..max count);
##   rows sharing a group drop exactly one of the group or nothing — explicit chances first,
##   rows with chance 0 share whatever chance is left equally;
##   {"ref": "<table>", "chance": n} rolls another table (shared "world drop" tables).
## Deterministic for a given seed (the killed creature's id and life count).
class_name Loot
extends RefCounted

const MAX_DEPTH := 4


## Returns [{item, count}, ...] with equal items merged.
static func roll(table_id: String, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := {}
	_roll(table_id, rng, out, 0)
	var list: Array = []
	for item: String in out:
		list.append({"item": item, "count": out[item]})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.item < b.item)
	return list


static func _roll(table_id: String, rng: RandomNumberGenerator, out: Dictionary, depth: int) -> void:
	if depth > MAX_DEPTH:
		return
	var table := Defs.get_def("loot_tables", table_id)
	var groups := {}
	for r: Dictionary in table.get("rows", []):
		if r.has("group"):
			var g := int(r.group)
			if not groups.has(g):
				groups[g] = []
			(groups[g] as Array).append(r)
		elif rng.randf() * 100.0 < float(r.get("chance", 100.0)):
			_give(r, rng, out, depth)
	for g: int in groups:
		var rows: Array = groups[g]
		var explicit := 0.0
		var zero: Array = []
		for r: Dictionary in rows:
			if float(r.get("chance", 0.0)) > 0.0:
				explicit += float(r.chance)
			else:
				zero.append(r)
		var x := rng.randf() * 100.0
		var acc := 0.0
		var picked: Dictionary = {}
		for r: Dictionary in rows:
			if float(r.get("chance", 0.0)) > 0.0:
				acc += float(r.chance)
				if x < acc:
					picked = r
					break
		if picked.is_empty() and not zero.is_empty() and explicit < 100.0:
			var share := (100.0 - explicit) / zero.size()
			for r: Dictionary in zero:
				acc += share
				if x < acc:
					picked = r
					break
		if not picked.is_empty():
			_give(picked, rng, out, depth)


static func _give(r: Dictionary, rng: RandomNumberGenerator, out: Dictionary, depth: int) -> void:
	if r.has("ref"):
		_roll(str(r.ref), rng, out, depth + 1)
		return
	var item := str(r.get("item", ""))
	if item == "":
		return
	var n := rng.randi_range(int(r.get("min", 1)), maxi(int(r.get("min", 1)), int(r.get("max", r.get("min", 1)))))
	out[item] = int(out.get(item, 0)) + n
