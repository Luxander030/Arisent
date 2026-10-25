## Instant-hit bullet traces like CS: damage falls off with distance, body parts multiply
## damage, and bullets punch through thin walls (wood, glass, sheet metal…) losing damage
## on the way — up to 4 surfaces. Traces go through WorldQueries, so terrain stops bullets
## at any range (not only where terrain collision exists), and far characters without a
## node are hit through the query's record test (body hits, merged by distance).
## Hits anything with apply_damage() / apply_hit() / take_damage(); pushes physics bodies.
class_name Hitscan
extends RefCounted

const MAX_PENETRATIONS := 4
const MIN_DAMAGE := 1.0


class Hit:
	var position: Vector3
	var normal: Vector3
	var collider: Object
	var damage: float
	var hitgroup := ""
	var penetrated := false
	var terrain := false


## Fires one bullet. Returns the list of Hits in order (for effects) and applies damage.
static func fire(q: WorldQueries, from: Vector3, dir: Vector3, weapon: Dictionary,
		exclude: Array[RID] = [], source_id := "player") -> Array[Hit]:
	var hits: Array[Hit] = []
	var damage: float = weapon.damage
	var power: float = weapon.get("penetration", 1.0)
	var max_range: float = weapon.get("range", 200.0)
	var range_mod: float = weapon.get("range_modifier", 1.0)
	var origin := from
	var travelled := 0.0
	var ignore := exclude.duplicate()
	for pen in MAX_PENETRATIONS + 1:
		var seg_end := origin + dir * (max_range - travelled)
		var res := q.trace(origin, seg_end, PhysicsLayers.TRACE_MASK, ignore, true)
		var res_dist := origin.distance_to(res.position) if not res.is_empty() else INF
		# A far character without a node, nearer than whatever the ray hit?
		if q.record_ray.is_valid():
			var rec_hits: Array = q.record_ray.call(origin, seg_end)
			if not rec_hits.is_empty() and float(rec_hits[0].distance) < res_dist:
				var rh: Dictionary = rec_hits[0]
				var h := Hit.new()
				h.position = rh.position
				h.normal = rh.normal
				travelled += float(rh.distance)
				h.damage = damage * pow(range_mod, (travelled / MovementSettings.U) / 500.0)
				h.hitgroup = "body"
				hits.append(h)
				(rh.apply as Callable).call(DamageInfo.make(h.damage, "bullet", source_id, h.position,
					dir * h.damage * WeaponDefs.IMPULSE_PER_DAMAGE))
				break
		if res.is_empty():
			break
		var h := Hit.new()
		h.position = res.position
		h.normal = res.normal
		h.collider = res.collider
		h.terrain = bool(res.get("terrain", false))
		travelled += res_dist
		# Range falloff: × range_modifier per 500 u.
		var dmg := damage * pow(range_mod, (travelled / MovementSettings.U) / 500.0)
		var target: Object = h.collider
		if h.collider is Area3D and (h.collider as Area3D).has_meta("hitgroup"):
			h.hitgroup = (h.collider as Area3D).get_meta("hitgroup")
			target = (h.collider as Area3D).get_meta("owner_node")
			dmg *= Boxman.HITGROUP_MULT.get(h.hitgroup, 1.0)
		h.damage = dmg
		hits.append(h)
		_apply(target, dmg, dir, h, source_id)
		if h.terrain or h.hitgroup != "" or not (h.collider is PhysicsBody3D):
			break  # bullets stop in characters and in the terrain
		# Penetration: find where the bullet would leave this object.
		var surface := SurfaceProps.of(target)
		var max_thick := power * 0.1 / SurfaceProps.bullet_resistance(surface)
		var exit_from := h.position + dir * (max_thick + 0.01)
		var back := PhysicsRayQueryParameters3D.create(exit_from, h.position, PhysicsLayers.TRACE_MASK)
		var exit_res := q.space.intersect_ray(back)
		if exit_res.is_empty() or exit_res.collider != h.collider:
			break  # thicker than we can punch through (or the far side is something else)
		var thickness := h.position.distance_to(exit_res.position)
		if thickness > max_thick:
			break
		h.penetrated = true
		damage *= (1.0 - thickness / max_thick) * 0.75
		power -= thickness / 0.1 * SurfaceProps.bullet_resistance(surface)
		if damage < MIN_DAMAGE or power <= 0.0:
			break
		origin = exit_res.position + dir * 0.01
		travelled += thickness
	return hits


static func _apply(target: Object, dmg: float, dir: Vector3, h: Hit, source_id: String) -> void:
	var impulse := dir * dmg * WeaponDefs.IMPULSE_PER_DAMAGE
	if target == null:
		return
	if target.has_method("apply_damage"):
		target.apply_damage(DamageInfo.make(dmg, "bullet", source_id, h.position, impulse, h.hitgroup))
	elif target.has_method("apply_hit"):
		target.apply_hit(dmg, impulse, h.position, h.hitgroup)
	elif target is PhysicsProp:
		(target as PhysicsProp).take_damage(dmg * 0.5, impulse, h.position)
	elif target is RigidBody3D:
		var rb := target as RigidBody3D
		if rb.freeze:
			return
		rb.apply_impulse(impulse, h.position - rb.global_position)
