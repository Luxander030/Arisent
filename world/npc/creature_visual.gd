## Placeholder models for creatures, built from their definition: humanoids are the
## box-man (scaled to height); four-legged animals are a capsule body, head and legs on
## hip pivots (so they can swing). Both come with CS-style hitboxes (Area3D on the HITBOX
## layer, meta "hitgroup" + "owner_node"). Meshes are cached per creature id.
class_name CreatureVisual
extends RefCounted

static var _meshes := {}  ## "<creature id>:<part>" -> Mesh


## Returns {visual: Node3D, legs: Array[Node3D] (pivots), height}.
static func build(def: Dictionary) -> Dictionary:
	var color := Color.from_string(str(def.get("color", "#a08060")), Color(0.6, 0.5, 0.4))
	var h := float(def.get("height", 1.8))
	if str(def.get("body", "humanoid")) == "quadruped":
		return _quadruped(str(def.get("id", "")), color, h)
	var v := Boxman.build_visual(color)
	v.scale = Vector3.ONE * (h / 1.8)
	var legs: Array[Node3D] = []
	return {"visual": v, "legs": legs, "height": h}


## Hitboxes for the same body (owner_node receives the damage).
static func build_hitboxes(def: Dictionary, owner_node: Node, parent: Node3D) -> void:
	var h := float(def.get("height", 1.8))
	if str(def.get("body", "humanoid")) == "quadruped":
		for part: Array in _quad_parts(h):
			var a := Area3D.new()
			a.collision_layer = PhysicsLayers.HITBOX
			a.collision_mask = 0
			a.monitoring = false
			a.set_meta("hitgroup", part[4])
			a.set_meta("owner_node", owner_node)
			var cs := CollisionShape3D.new()
			var cap := CapsuleShape3D.new()
			cap.radius = part[1]
			cap.height = maxf(part[2], part[1] * 2.0)
			cs.shape = cap
			a.add_child(cs)
			a.transform = Transform3D(part[3], part[0])
			parent.add_child(a)
		return
	var holder := Node3D.new()
	holder.scale = Vector3.ONE * (h / 1.8)
	parent.add_child(holder)
	Boxman.build_hitboxes(owner_node, holder)


## [centre, radius, length, basis, hitgroup] for a four-legged body of height h.
static func _quad_parts(h: float) -> Array:
	var length := h * 1.1
	var along_z := Basis(Vector3.RIGHT, PI * 0.5)
	var parts := [
		[Vector3(0, h * 0.62, 0), h * 0.24, length, along_z, "chest"],
		[Vector3(0, h * 0.82, -length * 0.62), h * 0.16, h * 0.34, along_z, "head"],
	]
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			parts.append([Vector3(sx * h * 0.15, h * 0.26, sz * length * 0.34), h * 0.07, h * 0.5, Basis(), "leg"])
	return parts


static func _quadruped(id: String, color: Color, h: float) -> Dictionary:
	var root := Node3D.new()
	var legs: Array[Node3D] = []
	var parts := _quad_parts(h)
	for i in parts.size():
		var p: Array = parts[i]
		var key := "%s:%d:%.2f" % [id, i, h]
		var mesh: Mesh = _meshes.get(key)
		if mesh == null:
			var cm := CapsuleMesh.new()
			cm.radius = p[1]
			cm.height = maxf(p[2], p[1] * 2.0)
			cm.radial_segments = 10
			cm.rings = 3
			var mat := StandardMaterial3D.new()
			mat.albedo_color = color.darkened(0.25) if p[4] == "leg" else (color.darkened(0.1) if p[4] == "head" else color)
			mat.roughness = 0.85
			cm.material = mat
			mesh = cm
			_meshes[key] = mesh
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		if p[4] == "leg":
			# Pivot at the hip so the leg swings from the top.
			var hip := Node3D.new()
			hip.position = Vector3(p[0].x, h * 0.5, p[0].z)
			mi.position = Vector3(0, p[0].y - h * 0.5, 0)
			hip.add_child(mi)
			root.add_child(hip)
			legs.append(hip)
		else:
			mi.transform = Transform3D(p[3], p[0])
			root.add_child(mi)
	return {"visual": root, "legs": legs, "height": h}
