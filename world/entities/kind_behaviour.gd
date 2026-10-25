## What an entity kind does at runtime and in the editor's world view: builds its node
## (or none), declares how its state persists, and draws its debug gizmo. Runtime code
## only — the World Editor adds editor-only extras (handles, custom inspectors) on its own
## side, so game exports never reference editor scripts.
class_name KindBehaviour
extends RefCounted

## Persistence policies (see docs/gameplay-systems/PLAN.md D13).
const NONE := "none"            ## nothing to remember
const STATE := "state"          ## authored object with mutable state (chest opened…)
const TOMBSTONE := "tombstone"  ## authored object that can be removed for good


## The node for an entity, or null if the kind has no node (zones, paths, game-side markers).
## `layer.simulate_physics` is false in the editor and true in the game.
func build(_e: Dictionary, _layer: EntityLayer) -> Node3D:
	return null


## Moves an existing node after a transform-only edit.
func update_transform(node: Node3D, e: Dictionary) -> void:
	var xf := EntityKinds.transform_of(e)
	node.transform = Transform3D(xf.basis.orthonormalized(), xf.origin)


func persistence() -> String:
	return NONE


## Gizmo for one authored entity (both editor and in-game debug overlays).
func debug_draw(_e: Dictionary, _dd: DebugDraw, _view: WorldView) -> void:
	pass


## Shaped kinds are picked by their shape, not by physics.
func picks_by_shape() -> bool:
	return false
