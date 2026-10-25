## How creatures find their way. The default walks straight toward the target (fine in the
## open, and the only option far from the player where nothing is baked). NavMeshNavigator
## bakes navigation tiles around the player and steers along real paths there. The brain
## never knows which one it has.
class_name Navigator
extends RefCounted


## The point to head for next on the way from `from` to `target`.
func next_point(_rec: NpcRecord, _from: Vector3, target: Vector3) -> Vector3:
	return target


func update(_focus: Vector3) -> void:
	pass


func debug_draw(_dd: DebugDraw, _focus: Vector3) -> void:
	pass


func free_all() -> void:
	pass


func forget(_rec_id: String) -> void:
	pass
