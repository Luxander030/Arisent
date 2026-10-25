## Physics props (Source prop_physics): procedural placeholder models (crates, barrels)
## and the RigidBody3D setup for any catalog entry with a "physics" block:
##   {"mass": kg, "material": surfaceprop, "shape": "box"|"cylinder"|"convex", "health": hp}
## In the editor props are frozen (placeable, selectable); in the game they simulate.
class_name PropLibrary
extends RefCounted

static var _meshes := {}


## Visual mesh for a procedural prop entry ({"procedural": "crate"|"barrel", "size": [x, y, z]}).
static func procedural_mesh(entry: Dictionary) -> Mesh:
	var key := "%s_%s" % [entry.get("procedural", ""), str(entry.get("size", []))]
	if _meshes.has(key):
		return _meshes[key]
	var size: Array = entry.get("size", [1, 1, 1])
	var mesh: Mesh
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.9
	match str(entry.get("procedural", "")):
		"can", "bottle":
			var c := CylinderMesh.new()
			c.top_radius = float(size[0]) * (0.25 if entry.procedural == "bottle" else 0.5)
			c.bottom_radius = float(size[0]) * 0.5
			c.height = float(size[1])
			c.radial_segments = 8
			c.rings = 1
			mat.albedo_color = Color(0.75, 0.2, 0.15) if entry.procedural == "can" else Color(0.25, 0.55, 0.35)
			c.material = mat
			mesh = c
		"ladder", "platform", "dummy", "spawn":
			var b := BoxMesh.new()
			b.size = Vector3(size[0], size[1], size[2])
			mat.albedo_color = Color(0.3, 0.7, 1.0, 0.6)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			b.material = mat
			mesh = b
		"spawner", "unique", "group":
			# Editor markers: a pole with a coloured head (never shown in the game).
			var c := CylinderMesh.new()
			c.top_radius = 0.0
			c.bottom_radius = float(size[0]) * 0.5
			c.height = float(size[1])
			c.radial_segments = 6
			c.rings = 1
			mat.albedo_color = {"spawner": Color(1.0, 0.55, 0.15, 0.75), "unique": Color(0.75, 0.4, 1.0, 0.75),
				"group": Color(1.0, 0.9, 0.2, 0.75)}[entry.procedural]
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			c.material = mat
			mesh = c
		"chest":
			var b := BoxMesh.new()
			b.size = Vector3(size[0], size[1], size[2])
			mat.albedo_color = Color(0.45, 0.28, 0.12)
			b.material = mat
			mesh = b
		"barrel":
			var c := CylinderMesh.new()
			c.top_radius = float(size[0]) * 0.5
			c.bottom_radius = float(size[0]) * 0.5
			c.height = float(size[1])
			c.radial_segments = 12
			c.rings = 1
			mat.albedo_color = Color(0.36, 0.42, 0.5)
			mat.metallic = 0.4
			c.material = mat
			mesh = c
		_:
			var b := BoxMesh.new()
			b.size = Vector3(size[0], size[1], size[2])
			mat.albedo_color = Color(0.62, 0.45, 0.26) if str(entry.get("material", "")) == "wood" else Color(0.7, 0.62, 0.5)
			b.material = mat
			mesh = b
	_meshes[key] = mesh
	return mesh


## A packed scene for a procedural prop (used for the Place tool preview).
static func procedural_scene(entry: Dictionary) -> PackedScene:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = procedural_mesh(entry)
	mi.position.y = float((entry.get("size", [1, 1, 1]) as Array)[1]) * 0.5
	root.add_child(mi)
	mi.owner = root
	var ps := PackedScene.new()
	ps.pack(root)
	root.free()
	return ps


## A RigidBody3D for a catalog entry. `visual` is the model node (already scaled).
static func make_body(entry: Dictionary, visual: Node3D, simulate: bool) -> RigidBody3D:
	var phys: Dictionary = entry.get("physics", {})
	var body := PhysicsProp.new()
	body.mass = float(phys.get("mass", 20.0))
	body.health = float(phys.get("health", 0.0))
	var mat_name := str(phys.get("material", "default"))
	body.physics_material_override = SurfaceProps.material(mat_name)
	body.surface = mat_name
	var light := body.mass < 5.0
	if phys.get("pushaway", false):
		# Source pushaway clutter: the player walks through it and nudges it aside.
		body.collision_layer = PhysicsLayers.PUSHAWAY | PhysicsLayers.EDITOR_PICK
		body.collision_mask = PhysicsLayers.PUSHAWAY_MASK
	else:
		body.collision_layer = (PhysicsLayers.DEBRIS if light else PhysicsLayers.PROP) | PhysicsLayers.EDITOR_PICK
		body.collision_mask = PhysicsLayers.DEBRIS_MASK if light else PhysicsLayers.PROP_MASK
	body.continuous_cd = light
	body.can_sleep = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	body.freeze = not simulate
	body.add_child(visual)
	var aabb := _bounds(visual)
	var cs := CollisionShape3D.new()
	match str(phys.get("shape", "box")):
		"cylinder":
			var c := CylinderShape3D.new()
			c.radius = maxf(aabb.size.x, aabb.size.z) * 0.5
			c.height = aabb.size.y
			cs.shape = c
		"convex":
			var mesh := _first_mesh(visual)
			cs.shape = mesh.create_convex_shape(true, true) if mesh else null
		_:
			var b := BoxShape3D.new()
			b.size = aabb.size
			cs.shape = b
	if cs.shape == null:
		var b := BoxShape3D.new()
		b.size = aabb.size
		cs.shape = b
	if not cs.shape is ConvexPolygonShape3D:
		cs.position = aabb.get_center()
	body.add_child(cs)
	return body


static func _bounds(n: Node3D) -> AABB:
	var acc: Array[AABB] = []
	_collect(n, n.transform, acc)
	if acc.is_empty():
		return AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
	var out := acc[0]
	for a in acc:
		out = out.merge(a)
	return out


static func _collect(n: Node, xf: Transform3D, acc: Array[AABB]) -> void:
	if n is MeshInstance3D:
		acc.append(xf * (n as MeshInstance3D).mesh.get_aabb())
	for c in n.get_children():
		if c is Node3D:
			_collect(c, xf * (c as Node3D).transform, acc)


static func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var m := _first_mesh(c)
		if m:
			return m
	return null
