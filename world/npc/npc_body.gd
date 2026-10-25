## The visible, hittable body of a nearby creature. One node type for every tier that has
## a node, pooled per creature type by NpcManager. Modes:
##   physics  — moved by move_and_slide (only where terrain collision exists)
##   snapped  — placed on the ground directly (anywhere; smoothed between updates)
## Never authoritative: health, AI state and position live in the NpcRecord.
class_name NpcBody
extends CharacterBody3D

var record_id := ""
var manager: Node            ## NpcManager
var archetype := ""
var height := 1.8
var visual: Node3D
var _legs: Array[Node3D] = []
var _phase := 0.0
var _shown_pos := Vector3.ZERO
var smooth_target := Vector3.INF  ## snapped mode: where to glide to
var speed := 0.0                  ## for the walk animation
var _fade := 0.0


func setup(def: Dictionary) -> void:
	archetype = str(def.id)
	var built := CreatureVisual.build(def)
	visual = built.visual
	visual.name = "Visual"
	add_child(visual)
	_legs = built.legs
	height = built.height
	var hit := Node3D.new()
	hit.name = "Hitboxes"
	add_child(hit)
	CreatureVisual.build_hitboxes(def, self, hit)
	collision_layer = PhysicsLayers.NPC
	collision_mask = PhysicsLayers.WORLD | PhysicsLayers.PROP | PhysicsLayers.DYNAMIC
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	var quad := str(def.get("body", "")) == "quadruped"
	cap.radius = clampf(height * (0.32 if quad else 0.2), 0.15, 0.8)
	cap.height = maxf(height * (0.7 if quad else 1.0), cap.radius * 2.0)
	cs.shape = cap
	cs.position.y = cap.height * 0.5
	add_child(cs)
	floor_snap_length = 0.6
	safe_margin = 0.02
	set_meta("surface", "flesh")
	for mi in visual.find_children("*", "MeshInstance3D", true, false):
		var gi := mi as GeometryInstance3D
		gi.visibility_range_end = 225.0       # fades in from 225 m to 200 m (see WorldSession.in_view)
		gi.visibility_range_end_margin = 25.0
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Fade in over 0.6 s (used when spawning where the player can see).
func fade_in() -> void:
	_fade = 0.6
	_set_transparency(1.0)


func place(pos: Vector3, yaw: float) -> void:
	global_position = pos
	_shown_pos = pos
	smooth_target = Vector3.INF
	rotation.y = yaw
	velocity = Vector3.ZERO


## Damage contract (hitboxes point here via meta "owner_node").
func apply_damage(info: DamageInfo) -> void:
	if manager:
		manager.damage(record_id, info)


func apply_hit(dmg: float, impulse: Vector3, at: Vector3, hitgroup := "") -> void:
	apply_damage(DamageInfo.make(dmg, "bullet", "player", at, impulse, hitgroup))


## Console `info` uses this.
func debug_info() -> String:
	return manager.describe(record_id) if manager else record_id


func _process(delta: float) -> void:
	if smooth_target != Vector3.INF:
		global_position = global_position.lerp(smooth_target, minf(1.0, delta * 6.0))
	if not _legs.is_empty():
		_phase += delta * speed * 4.0
		var swing := sin(_phase) * clampf(speed * 0.18, 0.0, 0.6)
		for i in _legs.size():
			_legs[i].rotation.x = swing * (1.0 if (i == 0 or i == 3) else -1.0)
	elif visual:
		visual.position.y = absf(sin(_phase)) * 0.04 * clampf(speed, 0.0, 3.0)
		_phase += delta * speed * 3.0
	if _fade > 0.0:
		_fade -= delta
		_set_transparency(clampf(_fade / 0.6, 0.0, 1.0))


func _set_transparency(t: float) -> void:
	for mi in visual.find_children("*", "MeshInstance3D", true, false):
		(mi as GeometryInstance3D).transparency = t
