## Bakes the player's animations onto the player model's own skeleton and saves them as
## one AnimationLibrary the game plays directly. Sources (both CC0):
##   the Universal Animation Library (Quaternius): every clip
##   assets/animations/ladder_climb/ladder_climb.glb: the ladder clips from the afk-rig
##     animation library (kept alone by tools/rig/extract_clips.py), on an Unreal-style rig
## Run: godot --headless --path . --script res://tools/rig/bake_player_animations.gd
##
## Why baked, not Godot's import retargeting: the player model is auto-rigged (bones
## bone_0…bone_56, A-pose, unusual bone axes) and the importer's rest fixer turned its arms
## the wrong way. Here every frame is retargeted in model space instead:
##   for each mapped bone  D = how far the source bone turned from its rest (model space)
##                         A = rotation taking the player bone's rest direction onto the
##                             source bone's rest direction (A-pose → the source's T-pose)
##                         player global rotation = D · A · player rest
## then converted back to local rotations. The hips also move, scaled by hip height.
## Unmapped bones (scarf ends, tail) keep their rest pose.
## The model faces +Z with its left side on +X, like the library.
extends SceneTree

const TARGET := "res://assets/models/main-character/demo.glb"
const OUT := "res://assets/models/main-character/player_animations.res"
const FPS := 30.0
const SKELETON_PATH := "Armature/Skeleton3D"   ## track paths, relative to the model's root

## player bone -> Universal Animation Library bone. The player has no shoulders or upper chest: its chest takes
## the library's upper chest and its upper arms the whole shoulder + upper arm turn (model
## space deltas carry everything above them).
const UAL_MAP := {
	"bone_0": "DEF-hips", "bone_1": "DEF-spine.001", "bone_2": "DEF-spine.003", "bone_3": "DEF-neck", "bone_4": "DEF-head",
	"bone_5": "DEF-upper_arm.L", "bone_6": "DEF-forearm.L", "bone_7": "DEF-hand.L",
	"bone_8": "DEF-f_middle.01.L", "bone_9": "DEF-f_middle.02.L", "bone_10": "DEF-f_middle.03.L",
	"bone_11": "DEF-f_index.01.L", "bone_12": "DEF-f_index.02.L", "bone_13": "DEF-f_index.03.L",
	"bone_14": "DEF-f_ring.01.L", "bone_15": "DEF-f_ring.02.L", "bone_16": "DEF-f_ring.03.L",
	"bone_17": "DEF-thumb.01.L", "bone_18": "DEF-thumb.02.L", "bone_19": "DEF-thumb.03.L",
	"bone_21": "DEF-upper_arm.R", "bone_22": "DEF-forearm.R", "bone_23": "DEF-hand.R",
	"bone_24": "DEF-f_middle.01.R", "bone_25": "DEF-f_middle.02.R", "bone_26": "DEF-f_middle.03.R",
	"bone_27": "DEF-f_index.01.R", "bone_28": "DEF-f_index.02.R", "bone_29": "DEF-f_index.03.R",
	"bone_30": "DEF-f_ring.01.R", "bone_31": "DEF-f_ring.02.R", "bone_32": "DEF-f_ring.03.R",
	"bone_33": "DEF-thumb.01.R", "bone_34": "DEF-thumb.02.R", "bone_35": "DEF-thumb.03.R",
	"bone_45": "DEF-thigh.L", "bone_46": "DEF-shin.L", "bone_47": "DEF-foot.L", "bone_48": "DEF-toe.L",
	"bone_49": "DEF-thigh.R", "bone_50": "DEF-shin.R", "bone_51": "DEF-foot.R", "bone_52": "DEF-toe.R",
}
## player bone -> afk-rig human bone (Unreal mannequin names).
const AFK_MAP := {
	"bone_0": "pelvis", "bone_1": "spine_01", "bone_2": "spine_03", "bone_3": "neck_01", "bone_4": "head",
	"bone_5": "upperarm_l", "bone_6": "lowerarm_l", "bone_7": "hand_l",
	"bone_8": "middle_01_l", "bone_9": "middle_02_l", "bone_10": "middle_03_l",
	"bone_11": "index_01_l", "bone_12": "index_02_l", "bone_13": "index_03_l",
	"bone_14": "ring_01_l", "bone_15": "ring_02_l", "bone_16": "ring_03_l",
	"bone_17": "thumb_01_l", "bone_18": "thumb_02_l", "bone_19": "thumb_03_l",
	"bone_21": "upperarm_r", "bone_22": "lowerarm_r", "bone_23": "hand_r",
	"bone_24": "middle_01_r", "bone_25": "middle_02_r", "bone_26": "middle_03_r",
	"bone_27": "index_01_r", "bone_28": "index_02_r", "bone_29": "index_03_r",
	"bone_30": "ring_01_r", "bone_31": "ring_02_r", "bone_32": "ring_03_r",
	"bone_33": "thumb_01_r", "bone_34": "thumb_02_r", "bone_35": "thumb_03_r",
	"bone_45": "thigh_l", "bone_46": "calf_l", "bone_47": "foot_l", "bone_48": "ball_l",
	"bone_49": "thigh_r", "bone_50": "calf_r", "bone_51": "foot_r", "bone_52": "ball_r",
}
## [scene, bone map, hips bone, {source clip: [baked name, loop?]} or {} for every clip as is]
const SOURCES := [
	["res://assets/animations/universal_animation_library/AnimationLibrary_Godot_Standard.glb", UAL_MAP, "DEF-hips", {}],
	["res://assets/animations/ladder_climb/ladder_climb.glb", AFK_MAP, "pelvis",
		{"Climb Ladder": ["Climb_Ladder", true], "Ladder_Idle": ["Ladder_Idle", true]}],
]

## Which child gives a bone its direction (for the A-pose → T-pose alignment). Limbs only:
## the torso (hips, spine, chest, neck, head) keeps the model's own sculpted posture and
## takes just the animation's movement — aligning it to the mannequin's upright spine
## pitched the chest ~17° and swung the shawl (skinned to bones on the chest) off the back.
const AIM := {
	"bone_5": "bone_6", "bone_6": "bone_7", "bone_7": "bone_8", "bone_8": "bone_9", "bone_9": "bone_10",
	"bone_11": "bone_12", "bone_12": "bone_13", "bone_14": "bone_15", "bone_15": "bone_16", "bone_17": "bone_18", "bone_18": "bone_19",
	"bone_21": "bone_22", "bone_22": "bone_23", "bone_23": "bone_24", "bone_24": "bone_25", "bone_25": "bone_26",
	"bone_27": "bone_28", "bone_28": "bone_29", "bone_30": "bone_31", "bone_31": "bone_32", "bone_33": "bone_34", "bone_34": "bone_35",
	"bone_45": "bone_46", "bone_46": "bone_47", "bone_47": "bone_48", "bone_49": "bone_50", "bone_50": "bone_51", "bone_51": "bone_52",
}

const TORSO := ["bone_0", "bone_1", "bone_2", "bone_3", "bone_4"]

var src: Skeleton3D
var dst: Skeleton3D
var _align := {}        ## player bone index -> Quaternion (model space)
var _src_rest := {}     ## library bone index -> global rest Quaternion
var _dst_rest := {}     ## player bone index -> global rest Quaternion
var _pairs: Array = []  ## [player bone index, library bone index]
var _map := {}
var _src_hips := ""


func _init() -> void:
	_run.call_deferred()  # the skeletons must be inside the tree to pose


func _run() -> void:
	var t: Node = (load(TARGET) as PackedScene).instantiate()
	root.add_child(t)
	dst = t.find_children("*", "Skeleton3D", true, false)[0]
	assert(str(t.get_path_to(dst)) == SKELETON_PATH, "player skeleton moved: %s" % t.get_path_to(dst))
	var lib := AnimationLibrary.new()
	for source: Array in SOURCES:
		var s: Node = (load(source[0]) as PackedScene).instantiate()
		root.add_child(s)
		src = s.find_children("*", "Skeleton3D", true, false)[0]
		assert(src.global_transform.basis.is_equal_approx(Basis()) and dst.global_transform.basis.is_equal_approx(Basis()), "skeleton nodes must not be rotated")
		_map = source[1]
		_src_hips = source[2]
		_prepare()
		var ap: AnimationPlayer = s.find_children("*", "AnimationPlayer", true, false)[0]
		var pick: Dictionary = source[3]
		for name: StringName in ap.get_animation_list():
			if name == &"RESET" or (not pick.is_empty() and not pick.has(str(name))):
				continue
			var baked := _bake(ap.get_animation(name))
			var out_name := str(name)
			if pick.has(str(name)):
				out_name = pick[str(name)][0]
				if pick[str(name)][1]:
					baked.loop_mode = Animation.LOOP_LINEAR
			lib.add_animation(out_name, baked)
		s.queue_free()
	print("baked %d animations -> %s: %s" % [lib.get_animation_list().size(), OUT, error_string(ResourceSaver.save(lib, OUT))])
	_check(lib)
	quit()


func _prepare() -> void:
	_src_rest.clear()
	_dst_rest.clear()
	_align.clear()
	_pairs.clear()
	for b in src.get_bone_count():
		_src_rest[b] = src.get_bone_global_rest(b).basis.get_rotation_quaternion()
	for b in dst.get_bone_count():
		_dst_rest[b] = dst.get_bone_global_rest(b).basis.get_rotation_quaternion()
	for d: String in _map:
		var di := dst.find_bone(d)
		var si := src.find_bone(_map[d])
		assert(di >= 0 and si >= 0, "missing bone %s / %s" % [d, _map[d]])
		_pairs.append([di, si])
	# Parents first, so a child without an aim can inherit its parent's alignment.
	_pairs.sort_custom(func(a: Array, b: Array) -> bool: return _depth(dst, a[0]) < _depth(dst, b[0]))
	for pr: Array in _pairs:
		var di: int = pr[0]
		var si: int = pr[1]
		var d_name := dst.get_bone_name(di)
		if AIM.has(d_name):
			var dc := dst.find_bone(AIM[d_name])
			var sc := src.find_bone(_map[AIM[d_name]])
			var dv := dst.get_bone_global_rest(dc).origin - dst.get_bone_global_rest(di).origin
			var sv := src.get_bone_global_rest(sc).origin - src.get_bone_global_rest(si).origin
			_align[di] = _arc(dv.normalized(), sv.normalized())
		elif d_name in TORSO:
			_align[di] = Quaternion()
		else:
			var p := dst.get_bone_parent(di)
			_align[di] = _align.get(p, Quaternion())


static func _depth(sk: Skeleton3D, b: int) -> int:
	var n := 0
	while sk.get_bone_parent(b) >= 0:
		b = sk.get_bone_parent(b)
		n += 1
	return n


static func _arc(from: Vector3, to: Vector3) -> Quaternion:
	if from.dot(to) > 0.99999:
		return Quaternion()
	if from.dot(to) < -0.99999:
		return Quaternion(from.cross(Vector3.UP if absf(from.y) < 0.9 else Vector3.RIGHT).normalized(), PI)
	return Quaternion(from, to)


func _bake(a: Animation) -> Animation:
	var out := Animation.new()
	out.length = a.length
	out.loop_mode = a.loop_mode
	out.step = 1.0 / FPS
	var tracks := {}
	for pr: Array in _pairs:
		var i := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(i, "%s:%s" % [SKELETON_PATH, dst.get_bone_name(pr[0])])
		tracks[pr[0]] = i
	var hips := dst.find_bone("bone_0")
	var src_hips := src.find_bone(_src_hips)
	var hips_track := out.add_track(Animation.TYPE_POSITION_3D)
	out.track_set_path(hips_track, "%s:%s" % [SKELETON_PATH, "bone_0"])
	var scale := _hip_height(dst, hips, true) / _hip_height(src, src_hips, false)
	var frames := maxi(1, ceili(a.length * FPS))
	for f in frames + 1:
		var t := minf(f / FPS, a.length)
		_pose_source(a, t)
		var global := {}
		for pr: Array in _pairs:
			var di: int = pr[0]
			var si: int = pr[1]
			var delta: Quaternion = src.get_bone_global_pose(si).basis.get_rotation_quaternion() * (_src_rest[si] as Quaternion).inverse()
			global[di] = delta * (_align[di] as Quaternion) * (_dst_rest[di] as Quaternion)
		for pr: Array in _pairs:
			var di: int = pr[0]
			var parent_global := _global_of(dst.get_bone_parent(di), global)
			out.rotation_track_insert_key(tracks[di], t, (parent_global.inverse() * (global[di] as Quaternion)).normalized())
		var moved := src.get_bone_global_pose(src_hips).origin - src.get_bone_global_rest(src_hips).origin
		out.position_track_insert_key(hips_track, t, dst.get_bone_rest(hips).origin + moved * scale)
	return out


## Global rotation of a player bone in the pose being built (unmapped bones: their rest).
func _global_of(b: int, global: Dictionary) -> Quaternion:
	if b < 0:
		return Quaternion()
	if global.has(b):
		return global[b]
	return _global_of(dst.get_bone_parent(b), global) * dst.get_bone_rest(b).basis.get_rotation_quaternion()


## Hip height above the soles: the player model's origin is at its middle, the library's at its feet.
func _hip_height(sk: Skeleton3D, hips: int, mesh_floor: bool) -> float:
	var floor_y := 0.0
	if mesh_floor:
		var mi: MeshInstance3D = sk.find_children("*", "MeshInstance3D", true, false)[0] if not sk.find_children("*", "MeshInstance3D", true, false).is_empty() else null
		floor_y = mi.get_aabb().position.y if mi else 0.0
	return sk.get_bone_global_rest(hips).origin.y - floor_y


func _pose_source(a: Animation, t: float) -> void:
	src.reset_bone_poses()
	for i in a.get_track_count():
		var bone := src.find_bone(str(a.track_get_path(i).get_concatenated_subnames()))
		if bone < 0:
			continue
		match a.track_get_type(i):
			Animation.TYPE_ROTATION_3D:
				src.set_bone_pose_rotation(bone, a.rotation_track_interpolate(i, t))
			Animation.TYPE_POSITION_3D:
				src.set_bone_pose_position(bone, a.position_track_interpolate(i, t))


## Sanity: in the library's T-pose the player's hands are level with the shoulders.
func _check(lib: AnimationLibrary) -> void:
	var a := lib.get_animation(&"A_TPose")
	if a == null:
		return
	dst.reset_bone_poses()
	for i in a.get_track_count():
		var b := dst.find_bone(str(a.track_get_path(i).get_concatenated_subnames()))
		if a.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			dst.set_bone_pose_rotation(b, a.rotation_track_interpolate(i, 0.0))
	for side: Array in [["left", "bone_5", "bone_7"], ["right", "bone_21", "bone_23"]]:
		var s := dst.get_bone_global_pose(dst.find_bone(side[1])).origin
		var h := dst.get_bone_global_pose(dst.find_bone(side[2])).origin
		print("T-pose %s arm: shoulder %s hand %s (drop %.3f)" % [side[0], s, h, s.y - h.y])
