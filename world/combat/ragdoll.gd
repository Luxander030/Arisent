## Ragdoll from the box-man parts: one RigidBody3D per part, joined with cone-twist
## joints (neck, shoulders, hips, spine) and hinges (elbows, knees). Lives on the RAGDOLL
## layer (hits the world and props, never the player). Like CS: limited count, the oldest
## is removed; each one freezes once it has settled and fades out later.
class_name Ragdoll
extends Node3D

const MAX_ACTIVE := 8
const SETTLE_TIME := 6.0
const LIFETIME := 30.0

static var _active: Array[Ragdoll] = []

var bodies := {}  ## part name -> RigidBody3D
var _age := 0.0


## Spawns a ragdoll in the pose of `xf` (feet transform) moving with `velocity`; `hit_part`
## gets the killing `impulse` at `hit_point`.
static func spawn(parent: Node, xf: Transform3D, color: Color, velocity := Vector3.ZERO,
		hit_part := "", impulse := Vector3.ZERO, hit_point := Vector3.ZERO) -> Ragdoll:
	while _active.size() >= MAX_ACTIVE:
		var old: Ragdoll = _active.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var r := Ragdoll.new()
	r.name = "Ragdoll"
	parent.add_child(r)
	r._build(xf, color, velocity)
	if hit_part != "" and r.bodies.has(hit_part):
		var b: RigidBody3D = r.bodies[hit_part]
		b.apply_impulse(impulse, hit_point - b.global_position)
	_active.append(r)
	return r


func _build(xf: Transform3D, color: Color, vel: Vector3) -> void:
	for name: String in Boxman.PARTS:
		var p: Array = Boxman.PARTS[name]
		var b := RigidBody3D.new()
		b.name = name
		b.mass = p[5]
		b.collision_layer = PhysicsLayers.RAGDOLL
		b.collision_mask = PhysicsLayers.WORLD | PhysicsLayers.PROP | PhysicsLayers.DYNAMIC | PhysicsLayers.RAGDOLL
		b.physics_material_override = SurfaceProps.material("flesh")
		b.linear_damp = 0.1
		b.angular_damp = 0.8
		b.set_meta("surface", "flesh")
		var cs := CollisionShape3D.new()
		cs.shape = Boxman.part_shape(name)
		b.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = Boxman.part_mesh(name, color)
		b.add_child(mi)
		add_child(b)
		b.global_transform = xf * Transform3D(Boxman.part_basis(name), p[2])
		b.linear_velocity = vel
		bodies[name] = b
	for name: String in Boxman.PARTS:
		var parent_name: String = Boxman.PARTS[name][6]
		if parent_name == "":
			continue
		_joint(bodies[parent_name], bodies[name], name)


func _joint(a: RigidBody3D, b: RigidBody3D, child: String) -> void:
	a.add_collision_exception_with(b)
	# Joint sits where the child attaches (its top end).
	var p: Array = Boxman.PARTS[child]
	var top := b.global_transform * (Boxman.part_basis(child).inverse() * Vector3(0, p[1] * 0.5 + p[0] * 0.5, 0))
	var j: Joint3D
	var basis: Basis
	if child.begins_with("lower_arm") or child.begins_with("shin"):
		var h := HingeJoint3D.new()
		h.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
		# Knees bend backwards, elbows forwards.
		h.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-140.0 if child.begins_with("shin") else 0.0))
		h.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(0.0 if child.begins_with("shin") else 140.0))
		j = h
		basis = Basis(Vector3.UP, PI * 0.5)  # hinge axis = sideways
	else:
		var c := ConeTwistJoint3D.new()
		c.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, deg_to_rad(40.0 if child == "head" else 70.0))
		c.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, deg_to_rad(30.0))
		j = c
		basis = Basis(Vector3.FORWARD, PI * 0.5)  # cone axis along the limb
	add_child(j)
	j.global_transform = Transform3D(basis, top)
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b)


func _physics_process(dt: float) -> void:
	_age += dt
	if _age > SETTLE_TIME and _age - dt <= SETTLE_TIME:
		for b: RigidBody3D in bodies.values():
			if b.linear_velocity.length() < 0.3:
				b.freeze = true
	if _age > LIFETIME:
		_active.erase(self)
		queue_free()


func _exit_tree() -> void:
	_active.erase(self)
