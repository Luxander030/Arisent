## Procedural city on the plateau reserved by the layout: a walled medieval old town
## (plaza, keep, radial and ring streets, wall with gates and towers) surrounded by
## modern districts on street grids and medieval suburbs along the main roads.
## Output is plain data (saved in city.json); world/city_view.gd turns it into meshes.
## Every building has a stable key so edits/deletions survive regeneration.
class_name CityGen
extends RefCounted

const STAGE_CITY := 70
const ROAD_MAIN := 9.0
const ROAD_STREET := 6.0
const ROAD_MODERN := 12.0

var _rng: Rng
var _c := Vector2.ZERO
var _r := 0.0
var _r_old := 0.0
var _roads: Array = []          ## {points: PackedVector2Array, width, kind}
var _buildings: Array = []
var _occ := {}                  ## occupancy grid: cell -> Array of [center, radius]
var _road_grid := {}            ## 4 m cells covered by road surface
const OCC := 16.0
const RG := 4.0


func generate(L: WorldLayout, p: GenParams) -> Dictionary:
	if not L.has_city:
		return {}
	_rng = Rng.new(Rng.derive(p.seed_int(), STAGE_CITY))
	_c = L.city_center
	_r = L.city_radius
	_r_old = _r * lerpf(0.55, 0.35, p.city_modern) if p.city_modern < 0.99 else 0.0
	var plaza_r := maxf(18.0, _r * 0.06)

	# Main radial roads (some become gates through the wall).
	var k := _rng.range_i(6, 8)
	var angles: Array[float] = []
	var a0 := _rng.range_f(0.0, TAU)
	for i in k:
		angles.append(a0 + TAU * i / k + _rng.range_f(-0.15, 0.15))
	for a in angles:
		_add_road(_radial(a, plaza_r, _r * 1.02, 0.05), ROAD_MAIN, "main")
	# Ring streets in the old town.
	if _r_old > 0.0:
		_add_road(_ring(_r_old * 0.5, 0.04), ROAD_STREET, "street")
		_add_road(_ring(_r_old - 14.0, 0.02), ROAD_STREET, "street")
		# Short lanes between the main streets.
		for i in k:
			var mid := (angles[i] + angles[(i + 1) % k] + (TAU if i == k - 1 else 0.0)) * 0.5
			_add_road(_radial(mid, _r_old * 0.5, _r_old - 14.0, 0.08), ROAD_STREET * 0.8, "lane")
	_add_road(_ring(plaza_r, 0.0), ROAD_STREET, "plaza")

	# Districts outside the wall: modern (grid) or medieval suburbs, by sector.
	var sectors := []
	for i in k:
		sectors.append([angles[i], angles[(i + 1) % k] + (TAU if i == k - 1 else 0.0)])
	var modern_count := roundi(p.city_modern * k)
	var order := range(k)
	_rng.shuffle(order)
	var modern := {}
	for i in modern_count:
		modern[order[i]] = true
	for i in k:
		if modern.has(i):
			_modern_grid(sectors[i])
	if _r_old > 0.0:
		_add_road(_ring(_r * 0.78, 0.03), ROAD_STREET, "street")

	# Landmarks first (they claim space), then houses along every road.
	var keep_pos := _c + Vector2.from_angle(_rng.range_f(0, TAU)) * (_r_old * 0.28 if _r_old > 0.0 else plaza_r * 3.0)
	_place(keep_pos, 26.0, 26.0, _rng.range_f(0, TAU), 4, "keep", "keep")
	for i in k:
		if modern.has(i):
			_fill_modern(sectors[i])
	for road in _roads:
		if road.kind != "modern":
			_frontage(road)
	_infill()

	var wall := {}
	if _r_old > 0.0 and p.city_walls:
		wall = _wall(angles)
	return {
		"center": [_c.x, _c.y], "radius": _r, "height": L.city_height, "old_radius": _r_old,
		"plaza": [_c.x, _c.y, plaza_r], "roads": _roads_out(), "buildings": _buildings, "wall": wall,
	}


# --- roads ----------------------------------------------------------------------

func _radial(a: float, r0: float, r1: float, wobble: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := maxi(4, int((r1 - r0) / 30.0))
	var drift := 0.0
	for s in steps + 1:
		var t := float(s) / steps
		drift += _rng.range_f(-wobble, wobble) * 0.5
		pts.append(_c + Vector2.from_angle(a + drift * 0.3) * lerpf(r0, r1, t))
	return pts


func _ring(radius: float, wobble: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := maxi(16, int(TAU * radius / 25.0))
	for s in steps + 1:
		var a := TAU * s / steps
		pts.append(_c + Vector2.from_angle(a) * radius * (1.0 + sin(a * 3.0 + _r) * wobble))
	return pts


func _add_road(pts: PackedVector2Array, width: float, kind: String) -> void:
	_roads.append({"points": pts, "width": width, "kind": kind})
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var n := maxi(1, ceili(a.distance_to(b) / (RG * 0.5)))
		for s in n + 1:
			var q := a.lerp(b, float(s) / n)
			var rr := ceili(width * 0.5 / RG)
			var cq := Vector2i(floori(q.x / RG), floori(q.y / RG))
			for dy in range(-rr, rr + 1):
				for dx in range(-rr, rr + 1):
					var cell := cq + Vector2i(dx, dy)
					if (Vector2(cell) * RG + Vector2(RG, RG) * 0.5).distance_to(q) <= width * 0.5 + RG * 0.3:
						_road_grid[cell] = true


func _on_road(p: Vector2) -> bool:
	return _road_grid.has(Vector2i(floori(p.x / RG), floori(p.y / RG)))


## Grid streets for a modern sector, aligned to the sector's middle direction.
func _modern_grid(sector: Array) -> void:
	var mid: float = (sector[0] + sector[1]) * 0.5
	var u := Vector2.from_angle(mid)
	var v := Vector2(-u.y, u.x)
	var block := 70.0
	var r0 := _r_old + 30.0 if _r_old > 0.0 else _r * 0.15
	for i in range(-12, 13):
		var line := PackedVector2Array()
		for s in 25:
			var q := _c + u * (r0 + s * (_r - r0) / 24.0) + v * (i * block)
			if _in_sector(q, sector, r0, _r):
				line.append(q)
			elif line.size() > 1:
				break
		if line.size() > 1:
			_add_road(line, ROAD_MODERN, "modern")
	for j in range(0, int((_r - r0) / block) + 1):
		var line := PackedVector2Array()
		for s in range(-30, 31):
			var q := _c + u * (r0 + j * block) + v * (s * 10.0)
			if _in_sector(q, sector, r0, _r):
				line.append(q)
			elif line.size() > 1:
				break
		if line.size() > 1:
			_add_road(line, ROAD_MODERN, "modern")


func _in_sector(q: Vector2, sector: Array, r0: float, r1: float) -> bool:
	var d := q.distance_to(_c)
	if d < r0 or d > r1:
		return false
	var a := (q - _c).angle()
	var lo: float = sector[0]
	var hi: float = sector[1]
	var rel := fposmod(a - lo, TAU)
	return rel > 0.06 and rel < (hi - lo) - 0.06


func _roads_out() -> Array:
	var out := []
	for r in _roads:
		var pts := []
		for q: Vector2 in r.points:
			pts.append([snappedf(q.x, 0.01), snappedf(q.y, 0.01)])
		out.append({"points": pts, "width": r.width, "kind": r.kind})
	return out


# --- buildings ------------------------------------------------------------------

## Houses along both sides of a road, facing it.
func _frontage(road: Dictionary) -> void:
	var pts: PackedVector2Array = road.points
	var width: float = road.width
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		var len := seg.length()
		if len < 1.0:
			continue
		var dir := seg / len
		var nrm := Vector2(-dir.y, dir.x)
		var t := _rng.range_f(0.0, 4.0)
		while t < len:
			for side in [-1.0, 1.0]:
				var q := a + dir * t
				var dist_c := q.distance_to(_c)
				var inside_old := _r_old > 0.0 and dist_c < _r_old - 6.0
				var suburb := not inside_old and dist_c < _r * 0.98
				if not inside_old and not suburb:
					continue
				var w := _rng.range_f(7.0, 11.0)
				var d := _rng.range_f(8.0, 12.0)
				var center: Vector2 = q + nrm * side * (width * 0.5 + 1.5 + d * 0.5)
				if _r_old > 0.0 and absf(center.distance_to(_c) - _r_old) < d * 0.5 + 6.0:
					continue  # keep clear of the wall
				var floors := 1
				if inside_old:
					floors = _rng.range_i(2, 3) if dist_c < _r_old * 0.6 else _rng.range_i(1, 3)
				else:
					floors = _rng.range_i(1, 2)
				var rot := atan2(-nrm.x * side, -nrm.y * side)  # local +Z (door) faces the road
				_place(center, w, d, rot, floors, "medieval", "house")
			t += _rng.range_f(9.0, 13.0)


## Back-street houses filling the gaps between streets (denser in the old town).
func _infill() -> void:
	var step := 13.0
	var n := ceili(_r / step)
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var q := _c + Vector2(i * step + _rng.range_f(-4.0, 4.0), j * step + _rng.range_f(-4.0, 4.0))
			var dist := q.distance_to(_c)
			var inside_old := _r_old > 0.0 and dist < _r_old - 12.0
			var suburb := not inside_old and dist < _r * 0.9 and dist > _r_old + 12.0
			if not inside_old and not (suburb and _rng.chance(0.35)):
				continue
			if inside_old and dist < maxf(18.0, _r * 0.06) + 10.0:
				continue
			# Face the town centre, like streets radiating from the plaza.
			var rot := atan2(_c.x - q.x, _c.y - q.y)
			_place(q, _rng.range_f(7.0, 10.0), _rng.range_f(8.0, 11.0), rot, _rng.range_i(1, 3 if inside_old else 2), "medieval", "house")


func _fill_modern(sector: Array) -> void:
	var mid: float = (sector[0] + sector[1]) * 0.5
	var u := Vector2.from_angle(mid)
	var v := Vector2(-u.y, u.x)
	var r0 := _r_old + 30.0 if _r_old > 0.0 else _r * 0.15
	var step := 19.0
	for i in range(-40, 41):
		for j in range(0, int((_r - r0) / step) + 1):
			var q := _c + u * (r0 + 12.0 + j * step) + v * (i * step + 11.0)
			if not _in_sector(q, sector, r0 + 8.0, _r * 0.97):
				continue
			var dist := q.distance_to(_c)
			var tall := 1.0 - (dist - r0) / maxf(_r - r0, 1.0)
			var kind := "tower" if _rng.chance(0.15 + 0.35 * tall) else "block"
			var size := 16.0 if kind == "tower" else _rng.range_f(12.0, 18.0)
			_place(q, size, size, atan2(u.x, u.y), 0, "modern", kind)


## Places a building if its footprint is free of roads and other buildings.
func _place(center: Vector2, w: float, d: float, rot: float, floors: int, style: String, kind: String) -> bool:
	var rad := sqrt(w * w + d * d) * 0.5
	var basis_x := Vector2(cos(rot), -sin(rot))
	var basis_z := Vector2(sin(rot), cos(rot))
	for corner in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5), Vector2.ZERO]:
		var q: Vector2 = center + basis_x * corner.x * w + basis_z * corner.y * d
		if _on_road(q):
			return false
	var cell := Vector2i(floori(center.x / OCC), floori(center.y / OCC))
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			for other in _occ.get(cell + Vector2i(dx, dy), []):
				if center.distance_to(other[0]) < (rad + other[1]) * 0.78:
					return false
	var list: Array = _occ.get(cell, [])
	list.append([center, rad])
	_occ[cell] = list
	var variant := _rng.range_i(0, 1023)
	var key := "b%x" % Rng.hash2(roundi(center.x), roundi(center.y), 7177)
	_buildings.append({"key": key, "x": snappedf(center.x, 0.01), "z": snappedf(center.y, 0.01),
		"rot": snappedf(rot, 0.0001), "w": snappedf(w, 0.01), "d": snappedf(d, 0.01),
		"floors": floors, "style": style, "kind": kind, "variant": variant})
	return true


# --- wall ------------------------------------------------------------------------

func _wall(gate_angles: Array[float]) -> Dictionary:
	var pts := []
	var towers := []
	var gates := []
	for a in gate_angles:
		var g := _c + Vector2.from_angle(a) * _r_old
		gates.append([snappedf(g.x, 0.01), snappedf(g.y, 0.01), snappedf(a, 0.0001)])
	var steps := maxi(24, int(TAU * _r_old / 6.0))
	for s in steps + 1:
		var a := TAU * s / steps
		var q := _c + Vector2.from_angle(a) * _r_old
		pts.append([snappedf(q.x, 0.01), snappedf(q.y, 0.01)])
	var tower_every := maxi(4, int(48.0 / (TAU * _r_old / steps)))
	for s in range(0, steps, tower_every):
		var q := _c + Vector2.from_angle(TAU * s / steps) * _r_old
		towers.append([snappedf(q.x, 0.01), snappedf(q.y, 0.01)])
	return {"points": pts, "towers": towers, "gates": gates, "height": 9.0, "thickness": 3.0, "gate_width": 12.0}
