## kind -> KindBehaviour. EntityLayer asks this registry how to build every entity, so a
## kind no longer needs a catalog asset (zones, paths) and new kinds are one registration.
## The schema (editable props) lives in EntityKinds.
class_name KindRegistry
extends RefCounted

static var _kinds := {}
static var _default: KindBehaviour


static func _ensure() -> void:
	if not _kinds.is_empty():
		return
	_default = PropKind.new()
	_kinds = {
		"prop": _default, "building": _default, "physics_prop": _default,
		"ladder": LadderKind.new(), "moving_platform": PlatformKind.new(), "npc_dummy": DummyKind.new(),
		"spawn_point": MarkerKind.new(), "spawner": SpawnerKind.new(), "unique_npc": UniqueKind.new(),
		"spawn_group": GroupKind.new(), "chest": ChestKind.new(),
		"zone": ZoneKind.new(), "path": PathKind.new(),
	}


static func register(kind: String, behaviour: KindBehaviour) -> void:
	_ensure()
	_kinds[kind] = behaviour


static func of(kind: String) -> KindBehaviour:
	_ensure()
	return _kinds.get(kind, _default)


static func kinds() -> Array:
	_ensure()
	return _kinds.keys()


# --- behaviours -------------------------------------------------------------------------

## Catalog models: static bodies with an LOD chain, or rigid bodies for physics props.
class PropKind extends KindBehaviour:
	func build(e: Dictionary, layer: EntityLayer) -> Node3D:
		var entry := Catalog.get_entry(str(e.asset))
		if entry.has("physics"):
			return _physics(e, entry, layer)
		var root := StaticBody3D.new()
		root.collision_layer = PhysicsLayers.WORLD | PhysicsLayers.EDITOR_PICK
		var lod_scene := LodSettings.lod_scene(str(e.asset))
		var scene := lod_scene if lod_scene else Catalog.scene(str(e.asset))
		if scene:
			var vis := scene.instantiate()
			vis.name = "Visual"
			vis.set_meta("lod_category", str(entry.get("category", "prop")))
			root.add_child(vis)
			EntityLayer._apply_tiers(vis, layer._lod_scale)
			var lod0 := vis.get_node_or_null("LOD0")
			var aabb := EntityLayer._aabb(lod0 if lod0 else vis)
			var cs := CollisionShape3D.new()
			match str(entry.get("collision", "box")):
				"none":
					root.collision_layer = PhysicsLayers.EDITOR_PICK  # still pickable in the editor
					var box := BoxShape3D.new()
					box.size = aabb.size
					cs.shape = box
				"cylinder":
					var cyl := CylinderShape3D.new()
					cyl.radius = maxf(float(entry.get("radius", 0.1)), 0.05)
					cyl.height = aabb.size.y
					cs.shape = cyl
				_:
					var box := BoxShape3D.new()
					box.size = aabb.size
					cs.shape = box
			cs.position = aabb.get_center()
			root.add_child(cs)
		root.transform = EntityKinds.transform_of(e)
		return root

	## Rigid body (frozen in the editor); the catalog scale goes on the model, never the body.
	func _physics(e: Dictionary, entry: Dictionary, layer: EntityLayer) -> Node3D:
		var vis: Node3D = Catalog.scene(str(e.asset)).instantiate()
		vis.name = "Visual"
		vis.scale = Vector3.ONE * float(e.get("scale", 1.0)) * float(entry.get("scale", 1.0))
		var body := PropLibrary.make_body(entry, vis, layer.simulate_physics)
		var xf := EntityKinds.transform_of(e)
		body.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return body

	func update_transform(node: Node3D, e: Dictionary) -> void:
		var xf := EntityKinds.transform_of(e)
		if node is RigidBody3D:
			node.global_transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
			var vis := node.get_node_or_null("Visual") as Node3D
			if vis:
				vis.scale = Vector3.ONE * float(e.get("scale", 1.0)) * float(Catalog.get_entry(str(e.asset)).get("scale", 1.0))
		else:
			node.transform = xf

	func persistence() -> String:
		return STATE  # physics props remember where they were pushed (only when moved)


class LadderKind extends KindBehaviour:
	func build(e: Dictionary, _layer: EntityLayer) -> Node3D:
		var l := Ladder.new()
		l.height = float(e.props.get("height", 4.0))
		var xf := EntityKinds.transform_of(e)
		l.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return l


class PlatformKind extends KindBehaviour:
	func build(e: Dictionary, layer: EntityLayer) -> Node3D:
		var p := MovingPlatform.new()
		var pr: Dictionary = e.props
		p.travel = Vector3(float(pr.get("travel_x", 0.0)), float(pr.get("travel_y", 4.0)), float(pr.get("travel_z", 0.0)))
		p.speed = float(pr.get("speed", 2.0))
		p.wait = float(pr.get("wait", 1.5))
		p.active = layer.simulate_physics
		var xf := EntityKinds.transform_of(e)
		p.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return p


class DummyKind extends KindBehaviour:
	func build(e: Dictionary, layer: EntityLayer) -> Node3D:
		var d := TrainingDummy.new()
		d.max_health = float(e.props.get("health", 100.0))
		d.active = layer.simulate_physics
		var xf := EntityKinds.transform_of(e)
		d.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return d


## Editor-only markers (player spawn, spawners, groups): a pickable pole in the editor,
## nothing in the game (the game reads them as data).
class MarkerKind extends KindBehaviour:
	func build(e: Dictionary, layer: EntityLayer) -> Node3D:
		if layer.simulate_physics:
			return null
		var marker := StaticBody3D.new()
		marker.collision_layer = PhysicsLayers.EDITOR_PICK
		var scene := Catalog.scene(str(e.asset))
		if scene:
			marker.add_child(scene.instantiate())
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.8, 2.2, 0.8)
		cs.shape = box
		cs.position.y = 1.1
		marker.add_child(cs)
		var xf := EntityKinds.transform_of(e)
		marker.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return marker

	func debug_draw(e: Dictionary, dd: DebugDraw, _view: WorldView) -> void:
		if e.kind == "spawn_point" and dd.is_on("spawns"):
			dd.text(EntityKinds.position_of(e) + Vector3.UP * 2.6, "Player spawn", Color(0.5, 0.85, 1.0))


class SpawnerKind extends MarkerKind:
	func debug_draw(e: Dictionary, dd: DebugDraw, view: WorldView) -> void:
		if not dd.is_on("spawns"):
			return
		var p := EntityKinds.position_of(e)
		var pr: Dictionary = e.props
		var col := Color(1.0, 0.6, 0.2)
		dd.circle(p, maxf(0.5, float(pr.get("wander_radius", 0.0))), col)
		var arch := str(pr.get("archetype", ""))
		var name := str(Defs.get_def("creatures", arch).get("name", arch if arch != "" else "(no archetype)"))
		dd.text(p + Vector3.UP * 2.6, "%s ×%d" % [name, int(pr.get("count", 1))], col)
		var path_id := str(pr.get("path", ""))
		if path_id != "" and view.entities.has_entity(path_id):
			var path_e := view.entities.entity(path_id)
			var pts := ZoneShape.world_points(path_e)
			if not pts.is_empty():
				dd.ground_line(Vector2(p.x, p.z), pts[0], Color(1.0, 0.6, 0.2, 0.6))


class UniqueKind extends MarkerKind:
	func debug_draw(e: Dictionary, dd: DebugDraw, _view: WorldView) -> void:
		if not dd.is_on("spawns"):
			return
		var p := EntityKinds.position_of(e)
		var col := Color(0.8, 0.5, 1.0)
		dd.circle(p, maxf(0.5, float(e.props.get("wander_radius", 0.0))), col)
		var nm := str(e.props.get("name", ""))
		dd.text(p + Vector3.UP * 2.6, nm if nm != "" else str(e.props.get("archetype", "unique NPC")), col)


class GroupKind extends MarkerKind:
	func debug_draw(e: Dictionary, dd: DebugDraw, view: WorldView) -> void:
		if not dd.is_on("spawns"):
			return
		var p := EntityKinds.position_of(e)
		var col := Color(1.0, 0.9, 0.25)
		var members := 0
		for m: Dictionary in view.entities.entities_of_kind("spawner"):
			if str(m.props.get("group", "")) == e.id:
				var q := EntityKinds.position_of(m)
				dd.line(p + Vector3.UP * 1.0, q + Vector3.UP * 2.2, col)
				members += 1
		var nm := str(e.props.get("name", ""))
		dd.text(p + Vector3.UP * 1.6, "%s  (up to %d of %d spawners alive)" % [nm if nm != "" else "Group", int(e.props.get("max_alive", 1)), members], col)


## A container with a loot table; opened state persists.
class ChestKind extends KindBehaviour:
	func build(e: Dictionary, _layer: EntityLayer) -> Node3D:
		var body := StaticBody3D.new()
		body.collision_layer = PhysicsLayers.WORLD | PhysicsLayers.EDITOR_PICK
		var scene := Catalog.scene(str(e.asset)) if str(e.asset) != "" else Catalog.scene("gameplay.chest")
		if scene:
			var vis := scene.instantiate()
			vis.name = "Visual"
			body.add_child(vis)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1.0, 0.7, 0.6)
		cs.shape = box
		cs.position.y = 0.35
		body.add_child(cs)
		body.set_meta("interactable_kind", "chest")
		var xf := EntityKinds.transform_of(e)
		body.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)
		return body

	func persistence() -> String:
		return STATE


## Zones have no node; they live in the zone index and draw as draped areas.
class ZoneKind extends KindBehaviour:
	func picks_by_shape() -> bool:
		return true

	func debug_draw(e: Dictionary, dd: DebugDraw, _view: WorldView) -> void:
		if not dd.is_on("zones"):
			return
		var col := Color.from_string(str(e.props.get("color", "#e0803a80")), Color(0.9, 0.5, 0.2, 0.5))
		var roles: Array = e.props.get("roles", [])
		if roles.has("no_spawn") and not roles.has("spawn"):
			col = Color(0.4, 0.4, 0.45, 0.45)
		var pts := ZoneShape.world_points(e)
		dd.ground_fill("zone:" + str(e.id), hash(e.get("shape")) ^ hash(e.pos) ^ hash(e.rot), pts, Color(col, col.a * 0.35))
		dd.ground_outline(pts, Color(col, 1.0))
		var c := ZoneShape.aabb(e).get_center()
		var nm := str(e.props.get("name", ""))
		dd.text(Vector3(c.x, dd.ground(c.x, c.y) + 4.0, c.y), "%s  [%s]" % [nm if nm != "" else "Zone", ", ".join(PackedStringArray(roles))], Color(col, 1.0))


## Patrol paths: a polyline on the ground with direction arrows.
class PathKind extends KindBehaviour:
	func picks_by_shape() -> bool:
		return true

	func debug_draw(e: Dictionary, dd: DebugDraw, _view: WorldView) -> void:
		if not dd.is_on("spawns") and not dd.is_on("zones"):
			return
		var col := Color(0.35, 0.9, 1.0)
		var pts := ZoneShape.world_points(e)
		var closed := str(e.props.get("mode", "loop")) == "loop"
		dd.ground_outline(pts, col, closed)
		for i in pts.size():
			var a := pts[i]
			var p := Vector3(a.x, dd.ground(a.x, a.y), a.y)
			dd.line(p, p + Vector3.UP * 1.5, col)
			if i + 1 < pts.size() or closed:
				var b := pts[(i + 1) % pts.size()]
				var mid := a.lerp(b, 0.5)
				var dir := (b - a).normalized() * 1.5
				var m3 := Vector3(mid.x, dd.ground(mid.x, mid.y) + 0.6, mid.y)
				dd.arrow(m3 - Vector3(dir.x, 0, dir.y), m3 + Vector3(dir.x, 0, dir.y), col)
