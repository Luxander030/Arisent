## Picking up and carrying physics props (+use, like HL2/CS): props up to 35 kg and
## 128 u (3.25 m) in size. The carried prop floats in front of the view, follows it with a
## soft spring, can be thrown, and is dropped if it gets stuck too far away.
class_name PropCarrier
extends RefCounted

const MAX_MASS := 35.0
const MAX_SIZE := 128.0 * MovementSettings.U
const REACH := 2.4
const THROW_SPEED := 11.0
const DROP_DISTANCE := 2.5

var held: RigidBody3D
var _owner: CollisionObject3D


func _init(owner_body: CollisionObject3D) -> void:
	_owner = owner_body


static func can_carry(body: Object) -> bool:
	if not (body is RigidBody3D) or (body as RigidBody3D).freeze:
		return false
	var rb := body as RigidBody3D
	if rb.mass > MAX_MASS:
		return false
	for c in rb.get_children():
		if c is CollisionShape3D and c.shape:
			var size: Vector3 = (c.shape as Shape3D).get_debug_mesh().get_aabb().size
			if maxf(size.x, maxf(size.y, size.z)) > MAX_SIZE:
				return false
	return true


## Tries to pick up whatever is in front of the view. Returns true if something is held.
func try_pick(space: PhysicsDirectSpaceState3D, eye: Vector3, forward: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(eye, eye + forward * REACH,
		PhysicsLayers.PROP | PhysicsLayers.DEBRIS | PhysicsLayers.PUSHAWAY, [_owner.get_rid()])
	var res := space.intersect_ray(q)
	if res.is_empty() or not can_carry(res.collider):
		return false
	held = res.collider
	held.add_collision_exception_with(_owner)
	_owner.add_collision_exception_with(held)
	held.sleeping = false
	return true


func drop(throw_dir := Vector3.ZERO) -> void:
	if held == null:
		return
	if is_instance_valid(held):
		held.remove_collision_exception_with(_owner)
		_owner.remove_collision_exception_with(held)
		if throw_dir != Vector3.ZERO:
			held.linear_velocity = throw_dir * THROW_SPEED * clampf(15.0 / maxf(held.mass, 1.0), 0.35, 1.0)
	held = null


## Call every physics tick while holding.
func update(eye: Vector3, forward: Vector3, dt: float) -> void:
	if held == null:
		return
	if not is_instance_valid(held):
		held = null
		return
	var target := eye + forward * 1.6
	var offset := target - held.global_position
	if offset.length() > DROP_DISTANCE:
		drop()
		return
	held.linear_velocity = (offset / maxf(dt, 0.001)) * 0.25
	held.linear_velocity = held.linear_velocity.limit_length(20.0)
	held.angular_velocity *= 0.6
