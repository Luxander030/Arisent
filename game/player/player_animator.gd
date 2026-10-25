## Animates the player model (clips baked by tools/rig/bake_player_animations.gd) with an
## AnimationTree, and lets its tail and scarf swing (spring bones).
##
##   base (Transition: ground | crouch | air | swim | ladder | dead)
##     ground  BlendSpace1D by speed: Idle 0 · Walk 1.4 · Jog_Fwd 3.2 · Sprint 6 m/s (synced)
##     crouch  BlendSpace1D: Crouch_Idle 0 · Crouch_Fwd 1.2
##     air     Jump          swim  BlendSpace1D: Swim_Idle 0 · Swim_Fwd 1.6
##     ladder  BlendSpace1D: Ladder_Idle 0 · Climb_Ladder 1 (played backwards going down)
##     dead    Death01
##   → speed (TimeScale: faster than the fastest clip was authored for)
##   → stance (Blend2, upper body only): Pistol_Idle with a gun, Sword_Idle with the knife
##     when standing — so a gun stays raised while walking
##   → action (OneShot, upper body only): Pistol_Shoot · Sword_Attack · Hit_Chest · Interact
##     — so firing on the run doesn't stop the legs
## The tail (bone_53…56) and the two scarf ends (bone_37…40, bone_41…44) swing with
## SecondaryMotion, which keeps them out of the body; a faint breeze keeps them moving.
class_name PlayerAnimator
extends Node

const LIBRARY := preload("res://assets/models/main-character/player_animations.res")
const SKELETON := "Armature/Skeleton3D"
const BLEND := 0.18
const SPRINT_SPEED := 6.0
const CROUCH_SPEED := 1.2
const CLIMB_SPEED := 0.6        ## m/s the climb loop was authored at (roughly)
const UPPER_BODY_FIRST := 1     ## bone_1 (spine) … bone_35: spine, chest, neck, head, arms, fingers
const UPPER_BODY_LAST := 35
const ACTIONS := ["Pistol_Shoot", "Sword_Attack", "Hit_Chest", "Interact"]

var player: Player
var tree: AnimationTree
var springs: SecondaryMotion
var current := ""               ## the clip that dominates now (debugging, tests)
var _base := ""                 ## requested state of the base Transition ("" = none yet)
var _stance := 0.0
var _one_shot := ""
var _one_shot_left := 0.0
var _dead := false
var _t := 0.0


## `model` is the instantiated player model; the tree and the springs go under it.
func setup(p: Player, model: Node3D) -> void:
	player = p
	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	model.add_child(tree)
	tree.root_node = NodePath("..")
	tree.add_animation_library("", LIBRARY)
	tree.tree_root = _build_tree()
	tree.active = true
	_set_base("ground")  # a Transition outputs nothing until a state is requested
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	springs = _build_springs(sk)


# --- the tree ---------------------------------------------------------------------------------

static func _clip(name: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = name
	return a


static func _space(points: Array, max_value: float, sync := false) -> AnimationNodeBlendSpace1D:
	var s := AnimationNodeBlendSpace1D.new()
	s.min_space = 0.0
	s.max_space = max_value
	s.sync = sync
	for pt: Array in points:
		s.add_blend_point(_clip(pt[0]), pt[1], -1, pt[0])
	return s


static func _upper_body(n: AnimationNode) -> void:
	n.filter_enabled = true
	for i in range(UPPER_BODY_FIRST, UPPER_BODY_LAST + 1):
		n.set_filter_path(NodePath("%s:bone_%d" % [SKELETON, i]), true)


func _build_tree() -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	var base := AnimationNodeTransition.new()
	base.xfade_time = BLEND
	var states := {
		"ground": _space([["Idle", 0.0], ["Walk", 1.4], ["Jog_Fwd", 3.2], ["Sprint", SPRINT_SPEED]], SPRINT_SPEED, true),
		"crouch": _space([["Crouch_Idle", 0.0], ["Crouch_Fwd", CROUCH_SPEED]], CROUCH_SPEED, true),
		"air": _clip("Jump"),
		"swim": _space([["Swim_Idle", 0.0], ["Swim_Fwd", 1.6]], 1.6),
		"ladder": _space([["Ladder_Idle", 0.0], ["Climb_Ladder", 1.0]], 1.0),
		"dead": _clip("Death01"),
	}
	var i := 0
	for name: String in states:
		base.add_input(name)
		base.set_input_reset(i, name == "dead")  # dying always starts the fall from the top
		bt.add_node(name, states[name], Vector2(0, i * 120))
		i += 1
	bt.add_node("base", base, Vector2(300, 200))
	i = 0
	for name: String in states:
		bt.connect_node("base", i, name)
		i += 1
	var speed := AnimationNodeTimeScale.new()
	bt.add_node("speed", speed, Vector2(500, 200))
	bt.connect_node("speed", 0, "base")
	var stance_clip := AnimationNodeTransition.new()
	stance_clip.xfade_time = BLEND
	stance_clip.add_input("gun")
	stance_clip.add_input("knife")
	bt.add_node("gun", _clip("Pistol_Idle"), Vector2(500, 450))
	bt.add_node("knife", _clip("Sword_Idle"), Vector2(500, 570))
	bt.add_node("stance_clip", stance_clip, Vector2(700, 500))
	bt.connect_node("stance_clip", 0, "gun")
	bt.connect_node("stance_clip", 1, "knife")
	var stance := AnimationNodeBlend2.new()
	_upper_body(stance)
	bt.add_node("stance", stance, Vector2(900, 250))
	bt.connect_node("stance", 0, "speed")
	bt.connect_node("stance", 1, "stance_clip")
	var action_clip := AnimationNodeTransition.new()
	i = 0
	for a: String in ACTIONS:
		action_clip.add_input(a)
		bt.add_node(a, _clip(a), Vector2(900, 450 + i * 120))
		i += 1
	bt.add_node("action_clip", action_clip, Vector2(1100, 500))
	i = 0
	for a: String in ACTIONS:
		bt.connect_node("action_clip", i, a)
		i += 1
	var action := AnimationNodeOneShot.new()
	action.fadein_time = 0.08
	action.fadeout_time = 0.2
	_upper_body(action)
	bt.add_node("action", action, Vector2(1300, 250))
	bt.connect_node("action", 0, "stance")
	bt.connect_node("action", 1, "action_clip")
	bt.connect_node("output", 0, "action")
	return bt


# --- springs ----------------------------------------------------------------------------------

func _build_springs(sk: Skeleton3D) -> SecondaryMotion:
	var m := SecondaryMotion.new()
	m.name = "TailAndScarf"
	sk.add_child(m)
	return m


# --- every frame -----------------------------------------------------------------------------

func _process(dt: float) -> void:
	Perf.begin(&"animator")
	_process_body(dt)
	Perf.end(&"animator")


func _process_body(dt: float) -> void:
	if player == null or tree == null:
		return
	_t += dt
	if springs:  # a faint, slow breeze so the tail and scarf never freeze
		springs.wind = Vector3(sin(_t * 0.7) * 0.6, 0.0, sin(_t * 1.3 + 1.0) * 0.5)
	if _dead:
		return
	if _one_shot != "":
		_one_shot_left -= dt
		if _one_shot_left <= 0.0:
			_one_shot = ""
	var st := state()
	_set_base(st[0])
	tree.set("parameters/speed/scale", st[2])
	var p := player
	var speed := Vector2(p.velocity.x, p.velocity.z).length()
	tree.set("parameters/ground/blend_position", minf(speed, SPRINT_SPEED))
	tree.set("parameters/crouch/blend_position", minf(speed, CROUCH_SPEED))
	tree.set("parameters/swim/blend_position", minf(speed, 1.6))
	tree.set("parameters/ladder/blend_position", clampf(absf(p.velocity.y) / CLIMB_SPEED, 0.0, 1.0))
	var w := p.weapons.current if p.weapons else ""
	var want := 0.0
	if _base == "ground" or _base == "crouch":
		if w in ["pistol", "rifle", "sniper"] and (p.aiming or speed < 0.25):
			want = 1.0  # gun raised while aiming or standing; running, the arms swing
		elif w == "knife" and speed < 0.25:
			want = 1.0
	if w != "":
		tree.set("parameters/stance_clip/transition_request", "knife" if w == "knife" else "gun")
	_stance = move_toward(_stance, want, dt / BLEND)
	tree.set("parameters/stance/blend_amount", _stance)
	current = _one_shot if _one_shot != "" else st[1]


## [base state, the clip that dominates it, time scale] for what the player is doing.
func state() -> Array:
	var p := player
	var speed := Vector2(p.velocity.x, p.velocity.z).length()  # m/s
	var w := p.weapons.current if p.weapons else ""
	if p.noclip:
		return ["swim", "Swim_Idle" if speed < 0.5 else "Swim_Fwd", 1.0]
	if p.swimming:
		return ["swim", "Swim_Idle" if speed < 0.4 else "Swim_Fwd", clampf(maxf(1.0, speed / 1.6), 1.0, 1.6)]
	if p.on_ladder:
		var vy := p.velocity.y
		if absf(vy) < 0.1:
			return ["ladder", "Ladder_Idle", 1.0]
		return ["ladder", "Climb_Ladder", clampf(absf(vy) / CLIMB_SPEED, 0.5, 2.5) * signf(vy)]
	if not p.on_ground:
		return ["air", "Jump", 1.0]
	if p.ducked or p.duck_amount > 0.5:
		return ["crouch", "Crouch_Idle" if speed < 0.25 else "Crouch_Fwd", clampf(maxf(1.0, speed / CROUCH_SPEED), 1.0, 2.0)]
	var clip := "Idle"
	if speed >= 4.6:
		clip = "Sprint"
	elif speed >= 2.3:
		clip = "Jog_Fwd"
	elif speed >= 0.7:
		clip = "Walk"
	elif w == "knife":
		clip = "Sword_Idle"
	elif w in ["pistol", "rifle", "sniper"]:
		clip = "Pistol_Idle"
	return ["ground", clip, clampf(maxf(1.0, speed / SPRINT_SPEED), 1.0, 1.5)]


func _set_base(name: String) -> void:
	if name != _base:
		_base = name
		tree.set("parameters/base/transition_request", name)


## A clip that plays once on the upper body (attacks, hits, using things); the legs go on.
func play_once(clip: String) -> void:
	if _dead or not clip in ACTIONS:
		return
	_one_shot = clip
	_one_shot_left = LIBRARY.get_animation(clip).length
	current = clip
	tree.set("parameters/action_clip/transition_request", clip)
	tree.set("parameters/action/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func on_fired(weapon_id: String) -> void:
	play_once("Sword_Attack" if weapon_id == "knife" else "Pistol_Shoot")


func on_died() -> void:
	_dead = true
	_one_shot = ""
	current = "Death01"
	tree.set("parameters/action/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)
	tree.set("parameters/stance/blend_amount", 0.0)
	_stance = 0.0
	tree.set("parameters/speed/scale", 1.0)
	_base = "dead"
	tree.set("parameters/base/transition_request", "dead")


func on_revived() -> void:
	_dead = false
	_base = ""
	current = ""
