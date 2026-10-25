## The player model (assets/models/main-character/demo.glb) and its baked animations:
## every clip drives bones the model has, the retarget keeps the library's poses (T-pose
## arms level), the animator picks clips from the player's state, and guns sit in the
## right hand.
extends TestCase

const NEEDED := ["Idle", "Walk", "Jog_Fwd", "Sprint", "Jump", "Crouch_Idle", "Crouch_Fwd", "Swim_Idle", "Swim_Fwd",
	"Pistol_Idle", "Pistol_Shoot", "Sword_Idle", "Sword_Attack", "Hit_Chest", "Interact", "Death01", "Climb_Ladder", "Ladder_Idle"]


func _root() -> Window:
	return (Engine.get_main_loop() as SceneTree).root


func test_baked_clips_fit_the_model() -> void:
	var lib: AnimationLibrary = load("res://assets/models/main-character/player_animations.res")
	check(lib != null, "baked library exists (tools/rig/bake_player_animations.gd)")
	if lib == null:
		return
	for n: String in NEEDED:
		check(lib.has_animation(n), "clip %s" % n)
	var model: Node3D = Player.MODEL.instantiate()
	_root().add_child(model)
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	var bad := 0
	for n: StringName in lib.get_animation_list():
		var a := lib.get_animation(n)
		for i in a.get_track_count():
			var path := a.track_get_path(i)
			if model.get_node_or_null(NodePath(path.get_concatenated_names())) != sk or sk.find_bone(path.get_concatenated_subnames()) < 0:
				bad += 1
	eq(bad, 0, "every track points at a bone of the model")
	eq(lib.get_animation("Walk").loop_mode, Animation.LOOP_LINEAR, "loops loop")
	eq(lib.get_animation("Death01").loop_mode, Animation.LOOP_NONE, "death plays once")
	eq(lib.get_animation("Climb_Ladder").loop_mode, Animation.LOOP_LINEAR, "climbing loops")
	# The library's T-pose puts the model's hands level with its shoulders (the A-pose is undone).
	var t := lib.get_animation("A_TPose")
	for i in t.get_track_count():
		if t.track_get_type(i) == Animation.TYPE_ROTATION_3D:
			sk.set_bone_pose_rotation(sk.find_bone(t.track_get_path(i).get_concatenated_subnames()), t.rotation_track_interpolate(i, 0.0))
	for pair in [["bone_5", "bone_7"], ["bone_21", "bone_23"]]:
		var drop := sk.get_bone_global_pose(sk.find_bone(pair[0])).origin.y - sk.get_bone_global_pose(sk.find_bone(pair[1])).origin.y
		check(absf(drop) < 0.02, "T-pose arm %s level (drop %.3f)" % [pair[0], drop])
	model.queue_free()


func test_animator_follows_the_player() -> void:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(100, 1, 100)
	cs.shape = box
	floor.add_child(cs)
	floor.position.y = -0.5
	floor.collision_layer = PhysicsLayers.WORLD
	_root().add_child(floor)
	var p := Player.new()
	_root().add_child(p)
	p.global_position = Vector3(0, 0.05, 0)
	for i in 30:
		await Engine.get_main_loop().physics_frame
	var hand: BoneAttachment3D = p.find_child("RightHand", true, false)
	check(hand != null and hand.bone_name == Player.RIGHT_HAND and p.weapons.get_parent() == hand, "weapons in the right hand")
	var aabb := Player._aabb(p.visual)
	check(absf(aabb.size.y - Player.MODEL_HEIGHT) < 0.1 and absf(aabb.position.y) < 0.05, "model 1.8 m tall, feet on the ground (%s)" % aabb)
	p.weapons.equip("knife")
	p.animator._process(0.0)
	eq(p.animator.current, "Sword_Idle", "knife stance")
	p.weapons.equip("rifle")
	p.animator._process(0.0)
	eq(p.animator.current, "Pistol_Idle", "gun stance")
	var a := p.animator
	check(a.tree and a.tree.active and a.tree.tree_root is AnimationNodeBlendTree, "an AnimationTree drives the model")
	p.velocity = Vector3(0, 0, 6.3)
	eq(a.state()[1], "Sprint", "full run speed")
	p.velocity = Vector3(0, 0, 1.2)
	eq(a.state()[1], "Walk", "slow")
	p.on_ground = false
	eq(a.state()[0], "air", "in the air")
	p.on_ground = true
	p.on_ladder = true
	p.velocity = Vector3(0, 1.0, 0)
	check(a.state()[0] == "ladder" and a.state()[1] == "Climb_Ladder" and a.state()[2] > 0.0, "climbing up")
	p.velocity = Vector3(0, -1.0, 0)
	check(a.state()[2] < 0.0, "climbing down plays the loop backwards")
	p.velocity = Vector3.ZERO
	eq(a.state()[1], "Ladder_Idle", "holding on")
	p.on_ladder = false
	# Upper-body layers only touch the spine, arms and head: the legs keep walking.
	var stance: AnimationNodeBlend2 = (a.tree.tree_root as AnimationNodeBlendTree).get_node("stance")
	check(stance.filter_enabled and stance.is_path_filtered("Armature/Skeleton3D:bone_23") and not stance.is_path_filtered("Armature/Skeleton3D:bone_45"),
		"stance filter: arms yes, legs no")
	p.velocity = Vector3(0, 0, 3.0)
	a._process(0.0)
	a.on_fired("rifle")
	eq(a.current, "Pistol_Shoot", "firing on the run plays on the upper body")
	eq(a.state()[1], "Jog_Fwd", "while the legs keep running")
	p.velocity = Vector3.ZERO
	a.on_fired("knife")
	eq(a.current, "Sword_Attack", "attack plays once")
	check(a.springs is SecondaryMotion and SecondaryMotion.CHAINS.size() == 3 and SecondaryMotion.CHAINS[0].bones[0] == "bone_53", "tail and scarf are simulated chains")
	p.take_damage(500.0)
	eq(p.animator.current, "Death01", "dies with the death clip")
	p.revive(Vector3(0, 0.05, 0))
	p.animator._process(0.0)
	check(p.animator.current != "Death01", "revived")
	p.queue_free()
	floor.queue_free()


func _floor() -> StaticBody3D:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	cs.shape = box
	floor.add_child(cs)
	floor.position.y = -0.5
	floor.collision_layer = PhysicsLayers.WORLD
	_root().add_child(floor)
	return floor


static func _seg_dist(x: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((x - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return x.distance_to(a + ab * t)


## Regression: the base Transition starts with no state unless one is requested, which left
## the legs (and hips) in their rest pose while only the upper-body layers played.
func test_legs_move_when_walking() -> void:
	# Standing on the ground from the very first frame (no "air" state to switch from):
	# the tree must still be told which base state to play.
	var still := Player.new()
	_root().add_child(still)
	still.set_physics_process(false)
	still.on_ground = true
	for i in 3:
		await (Engine.get_main_loop() as SceneTree).process_frame
	eq(still.animator.tree.get("parameters/base/current_state"), "ground", "base state playing from the start")
	still.queue_free()
	var floor := _floor()
	var p := Player.new()
	_root().add_child(p)
	p.global_position = Vector3(0, 0.05, 0)
	var sk: Skeleton3D = p.find_children("*", "Skeleton3D", true, false)[0]
	var foot := sk.find_bone("bone_47")
	var seen: Array[Vector3] = []
	sk.skeleton_updated.connect(func() -> void: seen.append(sk.get_bone_global_pose(foot).origin))
	Input.action_press("move_forward")
	await (Engine.get_main_loop() as SceneTree).create_timer(1.2).timeout
	Input.action_release("move_forward")
	var span := 0.0
	for x in seen:
		span = maxf(span, x.distance_to(seen[0]))
	check(seen.size() > 10 and span > 0.1, "the foot swings while walking (moved %.2f in model units)" % span)
	p.queue_free()
	floor.queue_free()


## The tail and scarf never go into the body (beyond where they grow out of it) while
## standing, walking, running with sharp turns and crouching.
func test_tail_and_scarf_stay_out_of_the_body() -> void:
	var floor := _floor()
	var p := Player.new()
	_root().add_child(p)
	p.global_position = Vector3(0, 0.05, 0)
	var sk: Skeleton3D = p.find_children("*", "Skeleton3D", true, false)[0]
	var m := p.animator.springs
	var worst := [0.0, ""]
	var measure := func() -> void:
		var k := sk.global_transform.basis.get_scale().x
		for ci in SecondaryMotion.CHAINS.size():
			var def: Dictionary = SecondaryMotion.CHAINS[ci]
			var pts := PackedVector3Array()
			for b: String in def.bones:
				pts.append(sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b)).origin)
			pts.append(sk.global_transform * (sk.get_bone_global_pose(sk.find_bone(def.bones[-1])) * (m._chains[ci].tip_local as Vector3)))
			for bw: Array in m.body_world(sk, ci):
				if float(bw[2]) <= 0.0:
					continue
				for j in range(1, pts.size()):
					for f: float in [0.0, 0.5, 1.0]:
						if j == 1 and f < SecondaryMotion.ATTACHED:
							continue
						var r := lerpf(float(def.radii[j - 1]), float(def.radii[j]), f)
						var pen: float = (r + float(bw[2])) * k - _seg_dist(pts[j - 1].lerp(pts[j], f), bw[0], bw[1])
						if pen > float(worst[0]):
							worst[0] = pen
							worst[1] = "%s segment %d" % [def.name, j]
	sk.skeleton_updated.connect(measure)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.create_timer(0.5).timeout
	Input.action_press("move_forward")
	await tree.create_timer(0.8).timeout
	for i in 4:
		p.cam.yaw += 1.2 if i % 2 == 0 else -1.2
		await tree.create_timer(0.3).timeout
	Input.action_press("crouch")
	await tree.create_timer(0.6).timeout
	Input.action_release("crouch")
	Input.action_release("move_forward")
	await tree.create_timer(0.4).timeout
	sk.skeleton_updated.disconnect(measure)
	check(float(worst[0]) < 0.03, "deepest overlap %.3f m (%s)" % [worst[0], worst[1]])
	p.queue_free()
	floor.queue_free()


## Regression: the model is drawn where the camera thinks the player is (the interpolated
## body position) every frame. It used to sit at the raw 64 Hz physics position, which
## against a ~60 fps camera made a sawtooth that showed as stutter when strafing.
func test_model_follows_interpolated_body_when_strafing() -> void:
	var tree0 := Engine.get_main_loop() as SceneTree
	var was := tree0.physics_interpolation
	tree0.physics_interpolation = true  # as the game host runs it
	var floor := _floor()
	var p := Player.new()
	_root().add_child(p)
	p.global_position = Vector3(0, 0.05, 0)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.create_timer(0.3).timeout
	Input.action_press("move_left")
	await tree.create_timer(0.5).timeout
	var worst := 0.0
	for i in 30:
		await tree.process_frame
		p._process(0.0)  # place the model for this frame (process_frame fires before _process)
		var want := p.get_global_transform_interpolated().origin + Vector3.UP * p.visual_step_offset
		worst = maxf(worst, p.visual.global_position.distance_to(want))
	Input.action_release("move_left")
	check(Vector2(p.velocity.x, p.velocity.z).length() > 1.0, "actually strafing")
	check(worst < 0.001, "model on the interpolated body every frame (worst %.4f m)" % worst)
	p.queue_free()
	floor.queue_free()
	tree0.physics_interpolation = was


## RPG-style facing: steering left turns the model to run left (it no longer slides
## sideways facing the camera, even holding a gun); aiming or attacking turns it to the aim.
func test_model_turns_to_run_the_way_you_steer() -> void:
	var floor := _floor()
	var p := Player.new()
	_root().add_child(p)
	p.global_position = Vector3(0, 0.05, 0)
	p.weapons.equip("rifle")
	p.cam.yaw = 0.0  # camera looks along -Z; its left is -X
	var tree := Engine.get_main_loop() as SceneTree
	await tree.create_timer(0.3).timeout
	var facing := func() -> Vector3: return p.visual.global_basis.z  # the model faces +Z
	Input.action_press("move_left")
	await tree.create_timer(0.6).timeout
	check((facing.call() as Vector3).dot(Vector3.LEFT) > 0.95, "faces left while running left (%s)" % facing.call())
	check(not p.aiming, "not aiming")
	Input.action_press("aim")
	await tree.create_timer(0.4).timeout
	check((facing.call() as Vector3).dot(Vector3.FORWARD) > 0.95, "aiming faces the camera's aim (%s)" % facing.call())
	check(p.aiming, "aiming")
	Input.action_release("aim")
	Input.action_release("move_left")
	Input.action_press("move_back")
	await tree.create_timer(0.6).timeout
	check((facing.call() as Vector3).dot(Vector3.BACK) > 0.95, "S turns around toward the camera (%s)" % facing.call())
	Input.action_release("move_back")
	await tree.create_timer(0.3).timeout
	var still: Vector3 = facing.call()
	p.weapons.fired.emit("rifle")
	await tree.create_timer(0.3).timeout
	check(p.aiming and (facing.call() as Vector3).dot(Vector3.FORWARD) > 0.95, "a shot turns to the aim (was %s)" % still)
	await tree.create_timer(Player.AIM_HOLD).timeout
	check(not p.aiming, "and lets go after a moment")
	p.queue_free()
	floor.queue_free()
