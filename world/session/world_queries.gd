## Spatial queries that respect the terrain everywhere. Terrain collision only exists near
## the collision focus (the player), so a plain physics ray beyond that passes through hills.
## trace() first clamps the segment at the terrain surface (Terrain3D's height-field march),
## then casts the physics ray. Used by weapons, line of sight, spawn visibility and
## interaction. The terrain march is skipped when the whole segment is inside the
## collision radius (physics already covers the terrain there).
class_name WorldQueries
extends RefCounted

var space: PhysicsDirectSpaceState3D
var terrain: TerrainBackend
var collision_focus: Node3D
var collision_radius := 64.0
## Optional: hits against simulated characters that have no node (far away).
## (from: Vector3, to: Vector3) -> Array of {position, normal, distance, apply: Callable(DamageInfo)}
var record_ray: Callable

var _los_cache := {}
var _los_frame := -1


static func for_space(s: PhysicsDirectSpaceState3D, t: TerrainBackend = null) -> WorldQueries:
	var q := WorldQueries.new()
	q.space = s
	q.terrain = t
	return q


## First hit along from->to: physics hits as Dictionaries from intersect_ray (plus
## "terrain": false), or {"position", "normal", "collider": null, "terrain": true}; {} if none.
func trace(from: Vector3, to: Vector3, mask: int, exclude: Array[RID] = [], areas := false) -> Dictionary:
	var end := to
	var terrain_hit := Vector3.INF
	if terrain and not _inside_collision(from, to):
		var d := to - from
		var length := d.length()
		if length > 0.001:
			var th := terrain.raycast(from, d / length)
			if th != Vector3.INF and from.distance_to(th) <= length:
				terrain_hit = th
				end = th
	if space:
		var q := PhysicsRayQueryParameters3D.create(from, end, mask, exclude)
		q.collide_with_areas = areas
		var res := space.intersect_ray(q)
		if not res.is_empty():
			res.terrain = false
			return res
	if terrain_hit != Vector3.INF:
		return {"position": terrain_hit, "normal": terrain.get_normal(terrain_hit), "collider": null, "terrain": true}
	return {}


## Unobstructed view between two points (world geometry and terrain only). Cached for
## 0.2 s per pair of rounded positions so many NPCs checking the player stay cheap.
func line_of_sight(a: Vector3, b: Vector3) -> bool:
	var frame := Engine.get_physics_frames()
	if frame - _los_frame > 12:  # ~0.2 s at 64 Hz
		_los_cache.clear()
		_los_frame = frame
	var key := [Vector3i(a.round()), Vector3i(b.round())]
	if _los_cache.has(key):
		return _los_cache[key]
	var clear := trace(a, b, PhysicsLayers.WORLD).is_empty()
	_los_cache[key] = clear
	return clear


func ground_height(pos: Vector3) -> float:
	return terrain.get_height(pos) if terrain else 0.0


func _inside_collision(a: Vector3, b: Vector3) -> bool:
	if collision_focus == null or not is_instance_valid(collision_focus):
		return terrain == null
	var f := collision_focus.global_position
	var r := collision_radius - 8.0
	return Vector2(a.x - f.x, a.z - f.z).length() < r and Vector2(b.x - f.x, b.z - f.z).length() < r
