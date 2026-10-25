## Which zones cover a point. Holds authored zone entities (kept in sync by EntityLayer)
## and runtime zones (e.g. a player camp acting as a no-spawn area). Overlaps resolve by
## `priority` (higher first), then by smaller area (the more specific zone first).
class_name ZoneIndex
extends RefCounted

const LAYER := &"zones"

var grid: WorldGrid
var _zones := {}    ## id -> entity dictionary (normalized)
var _runtime := {}  ## id -> true for runtime zones


func _init(g: WorldGrid) -> void:
	grid = g


func set_zone(e: Dictionary, runtime := false) -> void:
	if not ZoneShape.is_area(e):
		remove(str(e.id))
		return
	_zones[e.id] = e
	if runtime:
		_runtime[e.id] = true
	grid.put_rect(LAYER, e.id, ZoneShape.aabb(e))


func remove(id: String) -> void:
	_zones.erase(id)
	_runtime.erase(id)
	grid.remove(LAYER, id)


func clear_runtime() -> void:
	for id: String in _runtime.keys():
		remove(id)


func get_zone(id: String) -> Dictionary:
	return _zones.get(id, {})


func is_runtime(id: String) -> bool:
	return _runtime.has(id)


func ids() -> Array:
	return _zones.keys()


## Zones containing pos, most specific/important first.
func zones_at(pos: Vector3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in grid.query_rect(LAYER, Rect2(pos.x, pos.z, 0.0, 0.0)):
		var z: Dictionary = _zones[id]
		if ZoneShape.contains(z, pos):
			out.append(z)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := int(a.props.get("priority", 0))
		var pb := int(b.props.get("priority", 0))
		return pa > pb if pa != pb else ZoneShape.area(a) < ZoneShape.area(b))
	return out


func has_role_at(pos: Vector3, role: String) -> bool:
	for z in zones_at(pos):
		if EntityKinds.has_role(z, role):
			return true
	return false


## First (most specific) zone with a role at pos, or {}.
func zone_with_role(pos: Vector3, role: String) -> Dictionary:
	for z in zones_at(pos):
		if EntityKinds.has_role(z, role):
			return z
	return {}


func zones_in_rect(rect: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in grid.query_rect(LAYER, rect):
		out.append(_zones[id])
	return out
