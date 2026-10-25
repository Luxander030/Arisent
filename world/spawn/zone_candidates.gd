## Where a spawn zone may put creatures: a jittered grid of points inside the zone,
## filtered by the zone's terrain rules (slope, altitude window, water) and by no-spawn
## zones. Computed once per zone revision and reused (spawning then just picks points),
## so a zone on steep or wet ground can never make spawning search forever: an empty
## result is reported as "usable area 0 %".
class_name ZoneCandidates
extends RefCounted

const MAX_POINTS := 1500


## Cache key: changes whenever the zone's shape, place or filters change.
static func key_of(e: Dictionary) -> int:
	var p: Dictionary = e.props
	return hash([e.get("shape"), e.pos, e.rot, p.get("slope_max"), p.get("alt_min"), p.get("alt_max"), p.get("allow_water")])


static func bake(e: Dictionary, view: WorldView) -> PackedVector3Array:
	var out := PackedVector3Array()
	var rect := ZoneShape.aabb(e)
	var area := ZoneShape.area(e)
	if area <= 0.0:
		return out
	var step := maxf(4.0, sqrt(area / MAX_POINTS))
	var p: Dictionary = e.props
	var min_ny := cos(deg_to_rad(float(p.get("slope_max", 35.0))))
	var alt_min := float(p.get("alt_min", -500.0))
	var alt_max := float(p.get("alt_max", 3000.0))
	var allow_water := bool(p.get("allow_water", false))
	var seed_value := hash(str(e.id))
	var iz := 0
	var z := rect.position.y + step * 0.5
	while z < rect.end.y:
		var ix := 0
		var x := rect.position.x + step * 0.5
		while x < rect.end.x:
			var jx := (Rng.hash3f(ix, iz, 1, seed_value) - 0.5) * step * 0.8
			var jz := (Rng.hash3f(ix, iz, 2, seed_value) - 0.5) * step * 0.8
			var q := Vector3(x + jx, 0.0, z + jz)
			ix += 1
			x += step
			if not ZoneShape.contains(e, q):
				continue
			var h := view.terrain.get_height(q) if view.terrain else 0.0
			q.y = h
			if h < alt_min or h > alt_max:
				continue
			if view.terrain and view.terrain.get_normal(q).y < min_ny:
				continue
			if not allow_water and view.water_level_at(q) > h + 0.3:
				continue
			# Only authored no-spawn zones are baked in; runtime ones (camps) come and go and
			# are checked when a spot is picked.
			if view.zones.zones_at(q).any(func(z: Dictionary) -> bool: return EntityKinds.has_role(z, "no_spawn") and not view.zones.is_runtime(z.id)):
				continue
			out.append(q)
		iz += 1
		z += step
	return out


## Fraction of the zone that can host spawns (for the inspector).
static func usable_fraction(e: Dictionary, points: PackedVector3Array) -> float:
	var area := ZoneShape.area(e)
	if area <= 0.0:
		return 0.0
	var step := maxf(4.0, sqrt(area / MAX_POINTS))
	return clampf(points.size() * step * step / area, 0.0, 1.0)
