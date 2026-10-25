## Builds hand-placed entities (map.entities) through KindRegistry and keeps the world's
## spatial grid and zone index in sync with them. Each node remembers its entity id (meta
## "entity_id") for picking. Kinds without a node (zones, paths, game-side markers) are
## still known here as data.
class_name EntityLayer
extends Node3D

const GRID_LAYER := &"entities"
const DEBUG_RANGE := 600.0

var _nodes := {}     ## id -> Node3D
var _entities := {}  ## id -> entity dictionary (the same objects as map.entities)
var _lod_scale := 1.0
## Game: physics props simulate, gameplay objects work. Editor: everything stays put.
var simulate_physics := false
var grid: WorldGrid        ## set by WorldView
var zones: ZoneIndex       ## set by WorldView


func build(entities: Array) -> void:
	for c in get_children():
		c.queue_free()
	_nodes.clear()
	for id: String in _entities.keys():
		_forget(id)
	_entities.clear()
	for e: Dictionary in entities:
		add_entity(e)


func add_entity(e: Dictionary) -> Node3D:
	_entities[e.id] = e
	if grid:
		grid.put(GRID_LAYER, e.id, EntityKinds.position_of(e))
	if zones and e.has("shape"):
		zones.set_zone(e)
	var node := KindRegistry.of(str(e.kind)).build(e, self)
	if node == null:
		return null
	node.name = "E_" + str(e.id).replace("-", "_").replace(":", "_")
	node.set_meta("entity_id", e.id)
	add_child(node)
	_nodes[e.id] = node
	return node


func remove_entity(id: String) -> void:
	if _nodes.has(id):
		(_nodes[id] as Node).queue_free()
		_nodes.erase(id)
	_forget(id)
	_entities.erase(id)


func _forget(id: String) -> void:
	if grid:
		grid.remove(GRID_LAYER, id)
	if zones:
		zones.remove(id)


## Rebuilds an entity after its settings changed (cheap: one node).
func rebuild_entity(e: Dictionary) -> void:
	remove_entity(e.id)
	add_entity(e)


func update_entity(e: Dictionary) -> void:
	_entities[e.id] = e
	if grid:
		grid.put(GRID_LAYER, e.id, EntityKinds.position_of(e))
	if zones and e.has("shape"):
		zones.set_zone(e)
	if _nodes.has(e.id):
		KindRegistry.of(str(e.kind)).update_transform(_nodes[e.id] as Node3D, e)


func node_for(id: String) -> Node3D:
	return _nodes.get(id)


func has_entity(id: String) -> bool:
	return _entities.has(id)


func entity(id: String) -> Dictionary:
	return _entities.get(id, {})


func entities_of_kind(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _entities.values():
		if e.kind == kind:
			out.append(e)
	return out


func all_entities() -> Array:
	return _entities.values()


## Gizmos for authored entities near the camera (registered with DebugDraw by WorldView).
func draw_debug(dd: DebugDraw) -> void:
	if grid == null:
		return
	var cam := dd.camera_position()
	var view := get_parent() as WorldView
	var drawn := {}
	for id in grid.query_radius(GRID_LAYER, cam, DEBUG_RANGE):
		var e: Dictionary = _entities.get(id, {})
		if not e.is_empty():
			drawn[id] = true
			KindRegistry.of(str(e.kind)).debug_draw(e, dd, view)
	# Large shapes whose position is far but whose area is near.
	if zones:
		for z in zones.zones_in_rect(Rect2(cam.x - DEBUG_RANGE, cam.z - DEBUG_RANGE, DEBUG_RANGE * 2.0, DEBUG_RANGE * 2.0)):
			if not drawn.has(z.id) and not zones.is_runtime(z.id):
				KindRegistry.of("zone").debug_draw(z, dd, view)


## Physics LOD: freeze props far from the focus, wake them when close (used by the
## session's scheduler; nothing calls this in the editor).
func update_physics_lod(focus: Vector3, near_ids: Array[String] = []) -> void:
	var ids: Array = near_ids if not near_ids.is_empty() else _nodes.keys()
	for id: String in ids:
		var n: Node3D = _nodes.get(id)
		if n is PhysicsProp:
			(n as PhysicsProp).update_lod(n.global_position.distance_to(focus))


func apply_lod_scale(scale: float) -> void:
	_lod_scale = scale
	for n: Node3D in _nodes.values():
		var vis := n.get_node_or_null("Visual")
		if vis:
			_apply_tiers(vis, scale)


## Each LODn child is visible only in its distance band (nothing to do for plain models).
static func _apply_tiers(vis: Node, scale: float) -> void:
	var tiers := LodSettings.tiers(str(vis.get_meta("lod_category", "prop")), scale)
	var l := 0
	while vis.has_node("LOD%d" % l):
		var gi := vis.get_node("LOD%d" % l) as GeometryInstance3D
		var last := not vis.has_node("LOD%d" % (l + 1))
		gi.visibility_range_begin = 0.0 if l == 0 else tiers[mini(l - 1, tiers.size() - 1)]
		gi.visibility_range_end = tiers[-1] if last else tiers[mini(l, tiers.size() - 1)]
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		gi.visibility_range_begin_margin = 0.0 if l == 0 else gi.visibility_range_begin * 0.08
		gi.visibility_range_end_margin = 0.0 if last else gi.visibility_range_end * 0.08
		l += 1


static func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var a: AABB = (mi as MeshInstance3D).transform * (mi as MeshInstance3D).mesh.get_aabb()
		out = a if first else out.merge(a)
		first = false
	return out
