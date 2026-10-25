## Owns the global detail scale (multiplies every LOD distance), and in Adaptive mode the
## render resolution and screen effects too. Fixed presets, or Adaptive: a governor that
## holds the target frame rate by walking one quality ladder (LADDER) — draw distances,
## the share of pixels rendered (FSR 1 upscales the rest) and SSAO, the least visible
## savings first.
## It steps down when frames miss the target (or the frame rate is low without vsync) and
## up when there is headroom. With vsync on the frame rate can't show headroom, so after
## a calm stretch it tries one notch up; if that brings misses back it returns and waits
## twice as long before the next try. Changes are rate-limited, and the governor notices
## when lowering quality doesn't help (the slowdown is elsewhere — another app using the
## GPU, a CPU-bound moment…) and stops throwing quality away for a while.
class_name LodController
extends Node

signal scale_changed(scale: float)
## Adaptive mode switched SSAO (the world's environment applies it).
signal effects_changed(ssao: bool)

const MIN_SCALE := 0.35
const MAX_SCALE := 1.6
const SAMPLE_SECONDS := 1.0
const COOLDOWN := 2.0

## Rungs from best to cheapest: [detail scale, render scale, SSAO]. Rung LADDER_HIGH is the
## "High" preset; the governor starts there. Below it the render resolution goes first
## (instant, and most of the GPU's work here is per pixel), SSAO next, the detail scale
## last: every detail change rebuilds the vegetation over the following second, and
## the scale also sets how far trees, rocks and the city show.
const LADDER := [
	[1.6, 1.0, true], [1.35, 1.0, true], [1.15, 1.0, true],
	[1.0, 1.0, true],
	[1.0, 0.9, true], [1.0, 0.8, true], [1.0, 0.77, false], [0.85, 0.7, false],
	[0.7, 0.67, false], [0.5, 0.6, false],
]
const LADDER_HIGH := 3

var mode := "High"          ## a LodSettings.PRESETS key, "No LOD" or "Adaptive"
var target_fps := 60.0
var scale := 1.0
var render_scale := 1.0     ## share of the window's width/height rendered in 3D
var min_render_scale := 0.6  ## Adaptive never renders below this (the player's setting)
var fixed_render_scale := 1.0  ## presets render at this (the player's setting)
var ssao := true
var rung := LADDER_HIGH     ## Adaptive: current LADDER index
## True while the world is still applying the last change (vegetation rebuilding): frames
## then are slow because of the change itself and aren't counted. Set by the WorldView.
var busy := func() -> bool: return false

var _frames := 0
var _missed := 0            ## frames this sample that took over 1.25 × the target interval
var _time := 0.0
var _cooldown := 0.0
var _avg_fps := 0.0
var _miss_rate := 0.0
var _fps_before_step := 0.0  ## FPS measured just before the last reduction
var _useless_steps := 0      ## consecutive reductions that didn't raise FPS
var _hold := 0.0             ## seconds to wait before reducing again
var _calm := 0.0             ## seconds without misses (vsync: when to try a notch up)
var _calm_needed := CALM_START
var _since_raise := INF      ## seconds since the last step up
var _last_missed := 0.0      ## the previous sample's share of missed frames

const USELESS_GAIN := 1.03   ## a reduction must gain at least 3 % FPS to count
const HOLD_SECONDS := 20.0
const MISS_FACTOR := 1.25    ## a frame longer than this × the target interval is a miss
## Too slow: over MISS_LIMIT missed frames in one sample, or over MISS_SOFT in two in a
## row. A hitch (one or two long frames: streaming, a spawn) stays under both — lower
## quality wouldn't fix it — while an overloaded GPU misses frames every second.
const MISS_LIMIT := 0.08
const MISS_SOFT := 0.03
const CALM_START := 8.0
const CALM_MAX := 90.0
const RAISE_TRIAL := 5.0     ## misses this soon after a step up mean it was too much


func set_mode(m: String) -> void:
	mode = m
	if m == "Adaptive":
		rung = LADDER_HIGH
	refresh()
	_cooldown = 0.0
	_calm_needed = CALM_START


## Applies the current mode again (after the resolution settings changed).
func refresh() -> void:
	if LodSettings.PRESETS.has(mode):
		_apply(LodSettings.PRESETS[mode], fixed_render_scale, true)
	elif mode == "No LOD":
		_apply(LodSettings.NO_LOD_SCALE, 1.0, true)
	elif mode == "Adaptive":
		_set_rung(rung)


func average_fps() -> float:
	return _avg_fps


## Share of frames that missed the target in the last sample.
func miss_rate() -> float:
	return _miss_rate


func _process(delta: float) -> void:
	Perf.begin(&"lod")
	_process_body(delta)
	Perf.end(&"lod")


func _process_body(delta: float) -> void:
	if busy.call():
		_frames = 0
		_missed = 0
		_time = 0.0
		return
	_frames += 1
	if delta > MISS_FACTOR / target_fps:
		_missed += 1
	_time += delta
	_cooldown -= delta
	_hold -= delta
	_since_raise += delta
	if _time < SAMPLE_SECONDS:
		return
	_avg_fps = _frames / _time
	_miss_rate = float(_missed) / _frames
	var sample := _time
	_frames = 0
	_missed = 0
	_time = 0.0
	if mode != "Adaptive":
		return
	_calm = _calm + sample if _miss_rate == 0.0 else 0.0
	if _cooldown > 0.0:
		return
	step(_avg_fps, _miss_rate, DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED)


## One adaptive decision for a measured frame rate and share of missed frames (public so
## it can be tested).
func step(fps: float, missed := -1.0, vsync := false) -> void:
	# Did the previous reduction help?
	if _fps_before_step > 0.0:
		if fps < _fps_before_step * USELESS_GAIN and missed != 0.0:
			_useless_steps += 1
		else:
			_useless_steps = 0
		_fps_before_step = 0.0
		if _useless_steps >= 2:
			_hold = HOLD_SECONDS
			_useless_steps = 0
	var slow := missed > MISS_LIMIT or (missed > MISS_SOFT and _last_missed > MISS_SOFT)
	slow = slow or (missed > MISS_SOFT and _since_raise < RAISE_TRIAL)  # a trial notch up is judged strictly
	if not vsync:
		slow = slow or fps < target_fps * 0.9
	_last_missed = missed
	if slow:
		if _since_raise < RAISE_TRIAL:
			_calm_needed = minf(CALM_MAX, _calm_needed * 2.0)  # that notch up was one too many
		elif _hold > 0.0 or rung >= LADDER.size() - 1:
			return
		else:
			_fps_before_step = fps
		_set_rung(mini(LADDER.size() - 1, rung + (2 if fps < target_fps * 0.6 else 1)))
		_calm = 0.0
		return
	var headroom := fps > target_fps * 1.2 if not vsync else (missed == 0.0 and _calm >= _calm_needed)
	if missed < 0.0:
		headroom = fps > target_fps * 1.2
	if headroom and rung > 0:
		if _since_raise > RAISE_TRIAL * 4.0:
			_calm_needed = maxf(CALM_START, _calm_needed * 0.5)  # the last raise held
		_set_rung(rung - 1)
		_since_raise = 0.0
		_calm = 0.0


## True while adaptive mode has paused reductions because they weren't helping.
func is_holding() -> bool:
	return mode == "Adaptive" and _hold > 0.0


func _set_rung(r: int) -> void:
	rung = r
	var q: Array = LADDER[r]
	_apply(q[0], maxf(q[1], min_render_scale), q[2])


func _apply(s: float, render: float, with_ssao: bool) -> void:
	_cooldown = COOLDOWN
	if absf(render - render_scale) > 0.001:
		render_scale = render
		var vp := get_viewport()
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if render < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = render
	if with_ssao != ssao:
		ssao = with_ssao
		effects_changed.emit(ssao)
	if absf(s - scale) < 0.01:
		return
	scale = s
	# Godot's automatic mesh LOD (used by imported models) follows the same scale.
	get_viewport().mesh_lod_threshold = clampf(1.0 / s, 0.5, 4.0)
	# Per-object GPU LOD (lod_common.gdshaderinc) reads this global.
	RenderingServer.global_shader_parameter_set("lod_scale", s)
	scale_changed.emit(s)


## Distance the sun casts shadows to, for the current scale.
func shadow_distance() -> float:
	return clampf(LodSettings.SHADOW_DISTANCE * scale, 150.0, 800.0)
