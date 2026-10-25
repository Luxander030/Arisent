## Uniform spatial index in metres: 64 m cells (simulation, spawning, queries) grouped into
## 256 m regions (chunks of dynamic-object saves; the future streaming unit). Independent
## of the terrain's own region size. Things are stored per *layer* ("entities", "zones",
## "npcs", "items", "slots", ...) by string id; a thing can be point-like (one cell) or
## span a rectangle (zones).
class_name WorldGrid
extends RefCounted

const CELL := 64.0
const REGION_CELLS := 4  ## 256 m regions
const _OFFSET := 32768   ## cell coordinates are packed as (cx + O) << 16 | (cz + O)

## layer -> {cell_key: {id: true}}
var _cells := {}
## layer -> {id: Array[int] of cell keys}
var _where := {}


static func cell_key(cx: int, cz: int) -> int:
	return ((cx + _OFFSET) << 16) | (cz + _OFFSET)


static func cell_coords(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / CELL), floori(pos.z / CELL))


static func region_of(pos: Vector3) -> Vector2i:
	var c := cell_coords(pos)
	return Vector2i(floori(float(c.x) / REGION_CELLS), floori(float(c.y) / REGION_CELLS))


static func region_name(r: Vector2i) -> String:
	return "r_%d_%d" % [r.x, r.y]


## Inserts or moves a point-like thing.
func put(layer: StringName, id: String, pos: Vector3) -> void:
	var c := cell_coords(pos)
	var k := cell_key(c.x, c.y)
	var where: Dictionary = _layer_where(layer)
	var old: Variant = where.get(id)
	if old is Array and (old as Array).size() == 1 and int(old[0]) == k:
		return
	remove(layer, id)
	_add(layer, id, k)
	where[id] = [k]


## Inserts or moves a thing covering an XZ rectangle.
func put_rect(layer: StringName, id: String, rect: Rect2) -> void:
	remove(layer, id)
	var keys: Array = []
	var a := Vector2i(floori(rect.position.x / CELL), floori(rect.position.y / CELL))
	var b := Vector2i(floori(rect.end.x / CELL), floori(rect.end.y / CELL))
	for cz in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			var k := cell_key(cx, cz)
			_add(layer, id, k)
			keys.append(k)
	_layer_where(layer)[id] = keys


func remove(layer: StringName, id: String) -> void:
	var where: Dictionary = _layer_where(layer)
	if not where.has(id):
		return
	var cells: Dictionary = _cells[layer]
	for k: int in where[id]:
		var bucket: Dictionary = cells.get(k, {})
		bucket.erase(id)
		if bucket.is_empty():
			cells.erase(k)
	where.erase(id)


func has(layer: StringName, id: String) -> bool:
	return _layer_where(layer).has(id)


func clear_layer(layer: StringName) -> void:
	_cells.erase(layer)
	_where.erase(layer)


func count(layer: StringName) -> int:
	return _layer_where(layer).size()


## Ids whose cells intersect a circle (coarse: callers filter by exact distance).
func query_radius(layer: StringName, pos: Vector3, radius: float) -> Array[String]:
	return query_rect(layer, Rect2(pos.x - radius, pos.z - radius, radius * 2.0, radius * 2.0))


func query_rect(layer: StringName, rect: Rect2) -> Array[String]:
	var out: Array[String] = []
	if not _cells.has(layer):
		return out
	var cells: Dictionary = _cells[layer]
	var seen := {}
	var a := Vector2i(floori(rect.position.x / CELL), floori(rect.position.y / CELL))
	var b := Vector2i(floori(rect.end.x / CELL), floori(rect.end.y / CELL))
	for cz in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			var bucket: Variant = cells.get(cell_key(cx, cz))
			if bucket == null:
				continue
			for id: String in bucket:
				if not seen.has(id):
					seen[id] = true
					out.append(id)
	return out


## Ids in the cells a segment passes through (2D DDA over XZ), widened by `pad` metres.
func query_segment(layer: StringName, from: Vector3, to: Vector3, pad := 2.0) -> Array[String]:
	var out: Array[String] = []
	if not _cells.has(layer):
		return out
	var cells: Dictionary = _cells[layer]
	var seen := {}
	var length := Vector2(to.x - from.x, to.z - from.z).length()
	var steps := maxi(1, ceili(length / (CELL * 0.5)))
	for i in steps + 1:
		var p := from.lerp(to, float(i) / steps)
		var a := Vector2i(floori((p.x - pad) / CELL), floori((p.z - pad) / CELL))
		var b := Vector2i(floori((p.x + pad) / CELL), floori((p.z + pad) / CELL))
		for cz in range(a.y, b.y + 1):
			for cx in range(a.x, b.x + 1):
				var bucket: Variant = cells.get(cell_key(cx, cz))
				if bucket == null:
					continue
				for id: String in bucket:
					if not seen.has(id):
						seen[id] = true
						out.append(id)
	return out


func _add(layer: StringName, id: String, k: int) -> void:
	if not _cells.has(layer):
		_cells[layer] = {}
	var cells: Dictionary = _cells[layer]
	if not cells.has(k):
		cells[k] = {}
	(cells[k] as Dictionary)[id] = true


func _layer_where(layer: StringName) -> Dictionary:
	if not _where.has(layer):
		_where[layer] = {}
	return _where[layer]
