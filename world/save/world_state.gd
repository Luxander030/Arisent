## What changed in a map while playing, keyed by stable ids (never by position, so moving
## an entity in the editor after a save doesn't lose its state):
##   removed   stable id -> time it was removed (destroyed props, harvested nodes…)
##   modified  stable id -> state dict (chest opened_at, moved physics prop xform…)
##   zones     zone id -> {level_lock, cleared, last_visit}
## Spawn slots and ground items live in their own systems and are saved alongside.
class_name WorldState
extends RefCounted

var removed := {}
var modified := {}
var zones := {}


func is_removed(id: String) -> bool:
	return removed.has(id)


func remove(id: String, t: float) -> void:
	removed[id] = t


func modify(id: String, patch: Dictionary) -> void:
	var cur: Dictionary = modified.get(id, {})
	cur.merge(patch, true)
	modified[id] = cur


func state_of(id: String) -> Dictionary:
	return modified.get(id, {})


## A container counts as opened until it restocks (0 hours = never).
func is_opened(id: String, now: float, restock_hours: float) -> bool:
	var st: Dictionary = modified.get(id, {})
	if not st.has("opened_at"):
		return false
	return restock_hours <= 0.0 or now - float(st.opened_at) < restock_hours * 3600.0


func zone(id: String) -> Dictionary:
	if not zones.has(id):
		zones[id] = {}
	return zones[id]


func to_dict() -> Dictionary:
	return {"removed": removed.duplicate(true), "modified": _plain(modified), "zones": zones.duplicate(true)}


func from_dict(d: Dictionary) -> void:
	removed = (d.get("removed", {}) as Dictionary).duplicate(true)
	modified = (d.get("modified", {}) as Dictionary).duplicate(true)
	zones = (d.get("zones", {}) as Dictionary).duplicate(true)


## Deep copy with Vector3/Transform3D turned into arrays (saves hold plain data only).
static func _plain(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k: Variant in v:
			out[k] = _plain(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(x: Variant) -> Variant: return _plain(x))
	if v is Vector3:
		return [v.x, v.y, v.z]
	return v
