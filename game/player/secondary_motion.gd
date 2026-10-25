## Tail and scarf motion for the player model, as a SkeletonModifier3D that runs after the
## animation each frame. Each chain is simulated in world space (so it lags, swings and
## settles as the character moves), pulled back towards its animated shape (stiffness),
## kept at its bone lengths, and pushed out of the body: every joint AND points along every
## segment are tested against capsules fitted to the body, so a long segment can't cut
## through a leg while its ends stay outside (Godot's SpringBoneSimulator3D only tests
## joints, which let the 4-bone tail pass through the robe).
## All sizes are in model units (the skeleton may be scaled; the simulation scales them).
class_name SecondaryMotion
extends SkeletonModifier3D

## Body volumes to stay out of: [bone, child bone, from, to, radius] — a capsule over the
## stretch from…to of the bone's axis (0 = the bone, 1 = its child; past 1 continues in the
## same direction). Measured from the mesh (90th percentile of each stretch's vertices); the
## robe's skirt is skinned to the thighs and widens below the knee, hence two per thigh.
const BODY := [
	["bone_0", "bone_1", -0.75, 1.0, 0.1],                                        # pelvis
	["bone_1", "bone_2", 0.0, 1.0, 0.085], ["bone_2", "bone_3", 0.0, 1.0, 0.11],  # spine, chest
	["bone_3", "bone_4", -0.2, 1.6, 0.075],                                       # neck, head
	["bone_45", "bone_46", 0.0, 1.0, 0.09], ["bone_45", "bone_46", 1.0, 2.1, 0.15],   # left thigh, skirt
	["bone_49", "bone_50", 0.0, 1.0, 0.09], ["bone_49", "bone_50", 1.0, 2.1, 0.15],   # right
	["bone_46", "bone_47", 0.0, 1.0, 0.07], ["bone_50", "bone_51", 0.0, 1.0, 0.07],   # shins
	["bone_5", "bone_6", 0.0, 1.0, 0.055], ["bone_6", "bone_7", 0.0, 1.0, 0.09],      # left arm, wide sleeve
	["bone_21", "bone_22", 0.0, 1.0, 0.055], ["bone_22", "bone_23", 0.0, 1.0, 0.09],  # right arm
]
## Chains: bones root → end (joint radii per joint incl. a virtual tip past the end bone),
## follow (how much of the attachment's own movement the chain is simply carried along by;
## only the rest becomes lag and sway), stiffness (pull back to the animated shape, per
## second), damping (velocity kept per 1/60 s), gravity (m/s²), tip length, and run_lift
## (degrees the target pose lifts up and back at running speed: a running fox carries its
## tail clear of its legs — hanging, the robe's swinging skirt swept into it every stride).
const CHAINS := [
	{"name": "tail", "bones": ["bone_53", "bone_54", "bone_55", "bone_56"], "radii": [0.06, 0.08, 0.1, 0.09, 0.05],
		"follow": 0.8, "stiffness": 9.0, "damping": 0.9, "gravity": 1.0, "tip": 0.08, "run_lift": 20.0},
	{"name": "scarf_left", "bones": ["bone_37", "bone_38", "bone_39", "bone_40"], "radii": [0.02, 0.03, 0.03, 0.03, 0.02],
		"follow": 0.9, "stiffness": 0.6, "damping": 0.85, "gravity": 20.0, "tip": 0.05},
	{"name": "scarf_right", "bones": ["bone_41", "bone_42", "bone_43", "bone_44"], "radii": [0.02, 0.03, 0.03, 0.03, 0.02],
		"follow": 0.9, "stiffness": 0.6, "damping": 0.85, "gravity": 20.0, "tip": 0.05},
]
const ITERATIONS := 6
const SEGMENT_SAMPLES := [0.25, 0.5, 0.75]
const TELEPORT := 3.0   ## m in one frame: start the chains over instead of whipping them
const ATTACHED := 0.3   ## the first 30% of a chain's first segment grows out of the body: never tested
const CLEARANCE := 0.005
const CUSHION := 0.04   ## model units outside each body shape where points are eased away
const SOFTNESS := 0.25  ## share of the cushion depth removed per solver pass

var wind := Vector3.ZERO      ## extra acceleration (m/s²), e.g. a breeze
var collisions := true        ## tests/tuning
var _chains: Array = []       ## per chain: {bones: PackedInt32Array, lengths, tip_local, p, prev, r}
var _body: Array = []         ## per BODY entry: [bone index, child index, from, to, radius]
var _ready_chains := false


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if not _ready_chains:
		_setup(sk)
	var xf := sk.global_transform
	var k := xf.basis.get_scale().x
	var dt := clampf(delta, 0.0, 1.0 / 20.0)
	var all_segs := _body_segments(sk, xf)
	for c: Dictionary in _chains:
		# Each chain sees the body shapes shrunk where its sculpted rest pose touches them.
		var segs: Array = []
		var shrink: PackedFloat32Array = c.shrink
		for i in all_segs.size():
			var sg: Array = all_segs[i]
			segs.append([sg[0], sg[1], float(sg[2]) - shrink[i]])
		_simulate(sk, xf, k, dt, c, segs)
		_write(sk, xf, c)


func _setup(sk: Skeleton3D) -> void:
	_ready_chains = true
	_body.clear()
	for b: Array in BODY:
		_body.append([sk.find_bone(b[0]), sk.find_bone(b[1]), b[2], b[3], b[4]])
	_chains.clear()
	for def: Dictionary in CHAINS:
		var bones := PackedInt32Array()
		for n: String in def.bones:
			bones.append(sk.find_bone(n))
		var lengths := PackedFloat32Array()
		for i in range(1, bones.size()):
			lengths.append((sk.get_bone_global_rest(bones[i]).origin - sk.get_bone_global_rest(bones[i - 1]).origin).length())
		var last := sk.get_bone_global_rest(bones[-1])
		var before := sk.get_bone_global_rest(bones[-2])
		var dir := (last.origin - before.origin).normalized()
		lengths.append(float(def.tip))
		_chains.append({"bones": bones, "lengths": lengths, "tip_local": last.basis.inverse() * (dir * float(def.tip)),
			"shrink": PackedFloat32Array(), "radii": def.radii, "stiffness": def.stiffness, "follow": def.follow, "anchor": Transform3D(), "run_lift": float(def.get("run_lift", 0.0)), "speed": 0.0, "damping": def.damping, "gravity": def.gravity,
			"p": PackedVector3Array(), "prev": PackedVector3Array()})
	_calibrate(sk)


## The model as sculpted (its rest pose) must never count as clipping: wherever a chain at
## rest overlaps a body shape (the shawl lies on the back, the tail grows from the hips),
## that shape is made smaller for that chain by exactly the overlap.
func _calibrate(sk: Skeleton3D) -> void:
	var body: Array = []
	for b: Array in _body:
		var a := sk.get_bone_global_rest(b[0]).origin
		var d := sk.get_bone_global_rest(b[1]).origin - a
		body.append([a + d * float(b[2]), a + d * float(b[3]), float(b[4])])
	for c: Dictionary in _chains:
		var bones: PackedInt32Array = c.bones
		var pts := PackedVector3Array()
		for bi in bones:
			pts.append(sk.get_bone_global_rest(bi).origin)
		pts.append(sk.get_bone_global_rest(bones[-1]) * (c.tip_local as Vector3))
		var radii: Array = c.radii
		var shrink := PackedFloat32Array()
		shrink.resize(body.size())
		for i in body.size():
			var sg: Array = body[i]
			var worst := 0.0
			for j in range(1, pts.size()):
				for s: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
					if j == 1 and s < ATTACHED:
						continue
					var x := pts[j - 1].lerp(pts[j], s)
					var r := lerpf(float(radii[j - 1]), float(radii[j]), s)
					worst = maxf(worst, r + float(sg[2]) - _seg_dist(x, sg[0], sg[1]))
			shrink[i] = minf(worst + CLEARANCE, float(sg[2])) if worst > 0.0 else 0.0
		c.shrink = shrink


static func _seg_dist(x: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((x - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
	return x.distance_to(a + ab * t)


## Where each joint would be if the chain were rigid (the animated pose), in world space.
func _targets(sk: Skeleton3D, xf: Transform3D, c: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var bones: PackedInt32Array = c.bones
	for b in bones:
		out.append(xf * sk.get_bone_global_pose(b).origin)
	out.append(xf * (sk.get_bone_global_pose(bones[-1]) * (c.tip_local as Vector3)))
	return out


func _body_segments(sk: Skeleton3D, xf: Transform3D) -> Array:
	var out: Array = []
	for b: Array in _body:
		var a := sk.get_bone_global_pose(b[0]).origin
		var d := sk.get_bone_global_pose(b[1]).origin - a
		out.append([xf * (a + d * float(b[2])), xf * (a + d * float(b[3])), float(b[4])])
	return out


func _simulate(sk: Skeleton3D, xf: Transform3D, k: float, dt: float, c: Dictionary, segs: Array) -> void:
	var t := _targets(sk, xf, c)
	var p: PackedVector3Array = c.p
	var prev: PackedVector3Array = c.prev
	var bones: PackedInt32Array = c.bones
	var parent := sk.get_bone_parent(bones[0])
	var anchor := xf * (sk.get_bone_global_pose(parent) if parent >= 0 else Transform3D())
	if p.size() != t.size() or p[0].distance_to(t[0]) > TELEPORT:
		p = t.duplicate()
		prev = t.duplicate()
		c.anchor = anchor
	if float(c.run_lift) > 0.0:
		# How fast the attachment travels (smoothed), and the target lifted that much.
		var moved_by := Vector2(anchor.origin.x - (c.anchor as Transform3D).origin.x, anchor.origin.z - (c.anchor as Transform3D).origin.z).length()
		var speed := moved_by / maxf(dt, 1e-4) if dt > 0.0 else float(c.speed)
		c.speed = lerpf(float(c.speed), speed, 1.0 - exp(-dt * 5.0))
		var lift := deg_to_rad(float(c.run_lift)) * clampf(float(c.speed) / 5.0, 0.0, 1.0)
		if lift > 0.001:
			var turn := Basis(xf.basis.x.normalized(), lift)
			for j in range(1, t.size()):
				t[j] = t[0] + turn * (t[j] - t[0])
	if p.size() == t.size() and not prev.is_empty():
		# Carried along by the attachment (chest, hips) for `follow` of its movement.
		var moved := anchor * (c.anchor as Transform3D).affine_inverse()
		var f := float(c.follow)
		for j in p.size():
			p[j] = p[j].lerp(moved * p[j], f)
			prev[j] = prev[j].lerp(moved * prev[j], f)
	c.anchor = anchor
	var keep := pow(float(c.damping), dt * 60.0)
	var pull := clampf(float(c.stiffness) * dt, 0.0, 1.0)
	var accel := (Vector3.DOWN * float(c.gravity) + wind) * dt * dt
	p[0] = t[0]
	prev[0] = t[0]
	for j in range(1, p.size()):
		var v := (p[j] - prev[j]) * keep
		prev[j] = p[j]
		p[j] += v + accel
		p[j] += (t[j] - p[j]) * pull
	var lengths: PackedFloat32Array = c.lengths
	var radii: Array = c.radii
	var pushed := PackedVector3Array()
	pushed.resize(p.size())
	for it in ITERATIONS:
		for j in range(1, p.size()):
			var d := p[j] - p[j - 1]
			p[j] = p[j - 1] + (d.normalized() if d.length() > 1e-6 else (t[j] - t[j - 1]).normalized()) * lengths[j - 1] * k
		if collisions:
			for j in range(1, p.size()):
				var before := p[j]
				p[j] = _push_out(p[j], float(radii[j]) * k, segs, k)
				# Points along the segment: push the moving end so the whole segment clears.
				for s: float in SEGMENT_SAMPLES:
					if j == 1 and s < ATTACHED:
						continue
					var x := p[j - 1].lerp(p[j], s)
					var r := lerpf(float(radii[j - 1]), float(radii[j]), s) * k
					var y := _push_out(x, r, segs, k)
					if y != x:
						p[j] += (y - x) / maxf(s, 0.25)
				pushed[j] += p[j] - before
	# End on the bone lengths: the skeleton can only turn its bones, so this is what shows.
	for j in range(1, p.size()):
		var d := p[j] - p[j - 1]
		if d.length() > 1e-6:
			p[j] = p[j - 1] + d.normalized() * lengths[j - 1] * k
	# Contact stops a joint, it must not launch it: in a Verlet step a moved position is
	# also a velocity, so each push flung the tail away from the legs and it popped back
	# on every stride. Joints that were pushed keep no velocity along the push.
	for j in range(1, p.size()):
		if pushed[j].length_squared() < 1e-10:
			continue
		var n := pushed[j].normalized()
		var v := p[j] - prev[j]
		var vn := v.dot(n)
		if vn > 0.0:
			prev[j] = p[j] - (v - n * vn)
	c.p = p
	c.prev = prev


## Out of every body capsule; within a thin cushion outside the surface the point is eased
## outward a little each pass (so an approaching leg nudges the tail before it touches)
## instead of being snapped at the surface.
static func _push_out(x: Vector3, r: float, segs: Array, k: float) -> Vector3:
	for sg: Array in segs:
		if float(sg[2]) <= 0.0:
			continue
		var a: Vector3 = sg[0]
		var b: Vector3 = sg[1]
		var ab := b - a
		var tt := clampf((x - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var q := a + ab * tt
		var d := x - q
		var need := r + float(sg[2]) * k
		var dist := d.length()
		var out := d / dist if dist > 1e-6 else Vector3.BACK
		if dist < need:
			x = q + out * need
		elif dist < need + CUSHION * k:
			x += out * (need + CUSHION * k - dist) * SOFTNESS
	return x


## Turns each chain bone so it points at the next simulated joint.
func _write(sk: Skeleton3D, xf: Transform3D, c: Dictionary) -> void:
	var inv := xf.affine_inverse()
	var p: PackedVector3Array = c.p
	var bones: PackedInt32Array = c.bones
	for j in bones.size():
		var bi := bones[j]
		var g := sk.get_bone_global_pose(bi)
		var cur: Vector3 = (sk.get_bone_global_pose(bones[j + 1]).origin if j + 1 < bones.size() else g * (c.tip_local as Vector3)) - g.origin
		var want := inv * p[j + 1] - g.origin
		if cur.length() < 1e-6 or want.length() < 1e-6:
			continue
		var turn := Quaternion(cur.normalized(), want.normalized())
		var parent := sk.get_bone_parent(bi)
		var parent_basis := sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis()
		var local := parent_basis.inverse() * (Basis(turn) * g.basis)
		sk.set_bone_pose_rotation(bi, local.get_rotation_quaternion())


## Joints of a chain in world space as last simulated (tests).
func joints(chain: int) -> PackedVector3Array:
	return _chains[chain].p if chain < _chains.size() else PackedVector3Array()


## Body capsules [a, b, radius in model units] for the current pose, world space, as chain
## `chain` sees them (tests).
func body_world(sk: Skeleton3D, chain := -1) -> Array:
	if not _ready_chains:
		_setup(sk)
	var out := _body_segments(sk, sk.global_transform)
	if chain >= 0:
		var shrink: PackedFloat32Array = _chains[chain].shrink
		for i in out.size():
			out[i][2] = float(out[i][2]) - shrink[i]
	return out
