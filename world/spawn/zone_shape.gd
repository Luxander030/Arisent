## Geometry of shaped entities (zones, patrol paths). A shape is stored on the entity as
## {type: "polygon"|"circle"|"box"|"polyline", points: [[x, z], ...] (local), radius,
## size: [w, d], waits: [...] (polyline)}. Local points are offsets from the entity
## position, rotated by its yaw. Everything here works in the XZ plane (metres).
class_name ZoneShape
extends RefCounted


static func default_shape(type: String) -> Dictionary:
	match type:
		"circle": return {"type": "circle", "radius": 20.0}
		"box": return {"type": "box", "size": [40.0, 30.0]}
		"polyline": return {"type": "polyline", "points": [[0.0, 0.0], [20.0, 0.0]], "waits": []}
	return {"type": "polygon", "points": [[-20.0, -20.0], [20.0, -20.0], [20.0, 20.0], [-20.0, 20.0]]}


static func normalize(s: Dictionary) -> Dictionary:
	var out := {"type": str(s.get("type", "polygon"))}
	match out.type:
		"circle":
			out.radius = maxf(0.5, float(s.get("radius", 20.0)))
		"box":
			var sz: Array = s.get("size", [40.0, 30.0])
			out.size = [maxf(0.5, float(sz[0])), maxf(0.5, float(sz[1]))]
		_:
			var pts: Array = []
			for p: Variant in s.get("points", []):
				if p is Array and (p as Array).size() >= 2:
					pts.append([float(p[0]), float(p[1])])
			out.points = pts
			if out.type == "polyline":
				var waits: Array = []
				for w: Variant in s.get("waits", []):
					waits.append(float(w))
				out.waits = waits
	return out


static func _yaw(e: Dictionary) -> float:
	return deg_to_rad(float((e.get("rot", [0, 0, 0]) as Array)[1]))


static func _origin(e: Dictionary) -> Vector2:
	var p: Array = e.pos
	return Vector2(p[0], p[2])


## Local (x, z) -> world (x, z) for an entity.
static func to_world(e: Dictionary, local: Vector2) -> Vector2:
	var v := Basis(Vector3.UP, _yaw(e)) * Vector3(local.x, 0.0, local.y)
	return _origin(e) + Vector2(v.x, v.z)


## World (x, z) -> local (x, z).
static func to_local(e: Dictionary, world: Vector2) -> Vector2:
	var d := world - _origin(e)
	var v := Basis(Vector3.UP, -_yaw(e)) * Vector3(d.x, 0.0, d.y)
	return Vector2(v.x, v.z)


## Outline in world XZ (polygon, box corners, polyline points; circles are approximated).
static func world_points(e: Dictionary, circle_segments := 48) -> PackedVector2Array:
	var s: Dictionary = e.get("shape", {})
	var out := PackedVector2Array()
	match str(s.get("type", "")):
		"circle":
			var r := float(s.radius)
			for i in circle_segments:
				var a := TAU * i / circle_segments
				out.append(_origin(e) + Vector2(cos(a), sin(a)) * r)
		"box":
			var hw := float(s.size[0]) * 0.5
			var hd := float(s.size[1]) * 0.5
			for c in [Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd), Vector2(-hw, hd)]:
				out.append(to_world(e, c))
		"polygon", "polyline":
			for p: Array in s.get("points", []):
				out.append(to_world(e, Vector2(p[0], p[1])))
	return out


static func is_area(e: Dictionary) -> bool:
	var t := str(e.get("shape", {}).get("type", ""))
	return t == "polygon" or t == "circle" or t == "box"


static func contains(e: Dictionary, pos: Vector3) -> bool:
	var s: Dictionary = e.get("shape", {})
	var p := Vector2(pos.x, pos.z)
	match str(s.get("type", "")):
		"circle":
			return p.distance_to(_origin(e)) <= float(s.radius)
		"box":
			var l := to_local(e, p)
			return absf(l.x) <= float(s.size[0]) * 0.5 and absf(l.y) <= float(s.size[1]) * 0.5
		"polygon":
			var pts := world_points(e)
			return pts.size() >= 3 and Geometry2D.is_point_in_polygon(p, pts)
	return false


## XZ bounding rectangle in world space.
static func aabb(e: Dictionary) -> Rect2:
	var s: Dictionary = e.get("shape", {})
	if str(s.get("type", "")) == "circle":
		var r := float(s.radius)
		return Rect2(_origin(e) - Vector2(r, r), Vector2(r, r) * 2.0)
	var pts := world_points(e)
	if pts.is_empty():
		return Rect2(_origin(e), Vector2.ZERO)
	var rect := Rect2(pts[0], Vector2.ZERO)
	for q in pts:
		rect = rect.expand(q)
	return rect


static func area(e: Dictionary) -> float:
	var s: Dictionary = e.get("shape", {})
	match str(s.get("type", "")):
		"circle": return PI * pow(float(s.radius), 2)
		"box": return float(s.size[0]) * float(s.size[1])
		"polygon":
			var pts := world_points(e)
			var a := 0.0
			for i in pts.size():
				var q := pts[(i + 1) % pts.size()]
				a += pts[i].x * q.y - q.x * pts[i].y
			return absf(a) * 0.5
	return 0.0


## Distance from a point to the shape outline/polyline (XZ), for picking.
static func distance_to_outline(e: Dictionary, pos: Vector3) -> float:
	var pts := world_points(e)
	var p := Vector2(pos.x, pos.z)
	var closed := str(e.get("shape", {}).get("type", "")) != "polyline"
	var best := INF
	var n := pts.size()
	for i in (n if closed else n - 1):
		var a := pts[i]
		var b := pts[(i + 1) % n]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best
