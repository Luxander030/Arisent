## Game performance benchmark: the real game (player, creatures, spawning, HUD) on a saved
## map, at fixed views and on a run through the city. Per view: average and 1 %-low FPS,
## frame-time percentiles, where the time goes (scripts, physics, render CPU, GPU) and what
## is drawn (objects, draw calls, triangles).
## Run: godot --path . --resolution 1600x900 --script res://tests/bench_game.gd -- <map folder> <out json> [detail] [view…]
## detail: Adaptive (as the game runs), Low, Medium, High (default), Ultra.
extends SceneTree

const SECONDS := 3.0

var game: Node
var vp: RID


func _initialize() -> void:
	create_timer(600.0).timeout.connect(func() -> void: quit(2))
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var detail := args[2] if args.size() > 2 else "High"
	var only := args.slice(3)
	GraphicsSettings.use_defaults()
	game = load("res://game/world_game.tscn").instantiate()
	# The game picks its map from "--map <folder>".
	if not "--map" in args:
		GameLaunch.map_path = args[0]
	root.add_child(game)
	for i in 30:
		await process_frame
	if not OS.has_environment("BENCH_VSYNC"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# macOS stops drawing windows that are covered or on another Space; keep this one in front.
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	DisplayServer.window_move_to_foreground()
	Engine.max_fps = 0
	vp = root.get_viewport_rid()
	if OS.has_environment("BENCH_TICKS"):
		Engine.physics_ticks_per_second = int(OS.get_environment("BENCH_TICKS"))
	if OS.has_environment("BENCH_NO_OCC"):
		root.use_occlusion_culling = false
	RenderingServer.viewport_set_measure_render_time(vp, true)
	if OS.has_environment("BENCH_FREEZE_SKY"):
		game.game.time_of_day.day_minutes = 1e9  # the sun stands still
	var world: WorldView = game.world
	if world == null or world.map == null:
		print("the map did not load")
		quit(1)
		return
	var player: Player = game.player
	game.game.notarget = true
	player.invulnerable = true
	world.lod.set_mode(detail)
	if OS.has_environment("BENCH_RENDER"):  # a fixed render scale (FSR 1)
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		root.scaling_3d_scale = float(OS.get_environment("BENCH_RENDER"))
		world.lod.render_scale = root.scaling_3d_scale
	print("viewport %s, window %s, screen scale %.1f" % [root.size, DisplayServer.window_get_size(), DisplayServer.screen_get_scale()])
	print("map %s, detail %s, nodes %d, video memory %.0f MB" % [args[0], detail,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0])
	var map: MapData = world.map
	var city := Vector3(map.city.plaza[0], 0, map.city.plaza[1]) if map.city.has("plaza") else Vector3.ZERO
	var forest := _find_biome(world, GenParams.Biome.TEMPERATE_FOREST)
	var grass := _find_biome(world, GenParams.Biome.GRASSLAND)
	var high := _highest_near(world, city, 1500.0)
	# name: [player position, camera yaw (0 = looking along -Z), camera pitch]
	var views := {
		"plaza_n": [city, 0.0, -0.15],
		"plaza_s": [city, PI, -0.15],
		"street": [city + Vector3(120, 0, 160), atan2(120, 160), -0.1],
		"forest": [forest, 0.8, -0.1],
		"grassland": [grass, 2.0, -0.05],
		"hilltop": [high, atan2(high.x - city.x, high.z - city.z), -0.25],
	}
	var results := {}
	for name: String in views:
		if not only.is_empty() and not name in only:
			continue
		var v: Array = views[name]
		_place(world, player, v[0], v[1], v[2])
		await _settle()
		results[name] = await _measure(name)
		root.get_texture().get_image().save_png(args[1].get_base_dir().path_join("bench_game_%s.png" % name))
	if OS.has_environment("BENCH_HOLD"):
		# Stay on the last view (for an external profiler such as macOS `sample`).
		print("holding")
		await _measure("hold", float(OS.get_environment("BENCH_HOLD")))
	if OS.has_environment("BENCH_GPU"):
		await _gpu_ablate(world, player, views[OS.get_environment("BENCH_GPU")])
	if OS.has_environment("BENCH_ARRIVE"):
		# Physics and process time per second after teleporting to a view (streaming cost).
		var v: Array = views[OS.get_environment("BENCH_ARRIVE")]
		_place(world, player, v[0] + Vector3(400, 0, 0), v[1], v[2])
		await _settle()
		_place(world, player, v[0], v[1], v[2])
		for sec in 12:
			await _measure("arrive+%ds" % sec, 1.0)
	if OS.has_environment("BENCH_SPIKES"):
		await _spikes(float(OS.get_environment("BENCH_SPIKES")))
	if OS.has_environment("BENCH_NODES"):
		_count_processing()
	if OS.has_environment("BENCH_ABLATE"):
		await _ablate(world, player, views[OS.get_environment("BENCH_ABLATE")])
	if only.is_empty() or "run" in only:
		# Run through the city (streaming, LOD switches, creatures): hitches show here.
		_place(world, player, city + Vector3(-150, 0, 0), -PI / 2.0, -0.1)
		await _settle()
		Input.action_press("move_forward")
		results["run"] = await _measure("run", 6.0)
		Input.action_release("move_forward")
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	f.store_string(JSON.stringify(results, "\t"))
	quit()


func _place(world: WorldView, player: Player, at: Vector3, yaw: float, pitch: float) -> void:
	at.y = world.terrain.get_height(at) + 0.5
	player.global_position = at
	player.velocity = Vector3.ZERO
	player.reset_physics_interpolation()
	player.cam.yaw = yaw
	player.cam.pitch = pitch


func _settle() -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2500:
		await process_frame


func _measure(name: String, seconds := SECONDS) -> Dictionary:
	var frames: Array[float] = []
	var sums := {"process": 0.0, "physics": 0.0, "nav": 0.0, "render_cpu": 0.0, "gpu": 0.0,
		"objects": 0.0, "draws": 0.0, "prims": 0.0}
	var t0 := Time.get_ticks_usec()
	var last := t0
	var drawn0 := Engine.get_frames_drawn()
	Perf.enabled = OS.has_environment("BENCH_PERF")
	Perf.take()
	var per_sys := {}
	var slow_lines: Array[String] = []
	while Time.get_ticks_usec() - t0 < int(seconds * 1e6):
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		if Perf.enabled:
			var f := Perf.take()
			var keys := f.keys()
			for k: StringName in keys:
				per_sys[k] = int(per_sys.get(k, 0)) + int(f[k])
			if frames[-1] > 1000.0 / 60.0 * 1.25 and slow_lines.size() < 12:
				keys.sort_custom(func(a: StringName, b: StringName) -> bool: return f[a] > f[b])
				var parts := PackedStringArray()
				var total := 0
				for k: StringName in keys:
					total += int(f[k])
				for k: StringName in keys.slice(0, 4):
					parts.append("%s %.1f" % [k, f[k] / 1000.0])
				slow_lines.append("      slow frame %.1f ms: scripts %.1f ms (%s)" % [frames[-1], total / 1000.0, ", ".join(parts)])
		sums.process += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		sums.physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		sums.nav += Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
		sums.render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		sums.gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		sums.objects += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		sums.draws += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		sums.prims += RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var n := float(frames.size())
	if Engine.get_frames_drawn() - drawn0 < frames.size() / 2:
		print("%-10s NOT MEASURED: the window stopped drawing (covered, on another Space, or the screen is off)" % name)
		return {"error": "window not drawing"}
	var sorted := frames.duplicate()
	sorted.sort()
	var avg := 0.0
	for f in frames:
		avg += f
	avg /= n
	var worst1 := 0.0  # average of the slowest 1 % of frames
	var k := maxi(1, int(n * 0.01))
	for i in k:
		worst1 += sorted[sorted.size() - 1 - i]
	worst1 /= k
	var r := {"fps": snappedf(1000.0 / avg, 0.1), "low1_fps": snappedf(1000.0 / worst1, 0.1),
		"ms_avg": snappedf(avg, 0.01), "ms_p50": snappedf(sorted[int(n * 0.5)], 0.01),
		"ms_p99": snappedf(sorted[mini(int(n * 0.99), sorted.size() - 1)], 0.01), "ms_max": snappedf(sorted[-1], 0.01),
		"frames": int(n), "missed": frames.filter(func(f: float) -> bool: return f > 1000.0 / 60.0 * 1.25).size(), "spikes": sorted.filter(func(f: float) -> bool: return f > sorted[int(n * 0.5)] * 1.6).size()}
	for key: String in sums:
		r[key] = snappedf(sums[key] / n, 0.01)
	var lod: LodController = game.world.lod
	print("[detail %.2f render %.2f ssao %s] " % [lod.scale, lod.render_scale, lod.ssao] + "%-10s missed %3d of %4d | fps %6.1f (1%% low %5.1f)  ms p50 %5.2f p99 %6.2f max %6.2f | process %5.2f physics %5.2f render-cpu %5.2f gpu %5.2f | objects %5d draws %5d tris %8d" % [
		name, r.missed, r.frames, r.fps, r.low1_fps, r.ms_p50, r.ms_p99, r.ms_max, r.process, r.physics, r.render_cpu, r.gpu,
		int(r.objects), int(r.draws), int(r.prims)])
	if Perf.enabled:
		var keys := per_sys.keys()
		keys.sort_custom(func(a: StringName, b: StringName) -> bool: return per_sys[a] > per_sys[b])
		var parts := PackedStringArray()
		for sys: StringName in keys:
			parts.append("%s %.2f" % [sys, per_sys[sys] / 1000.0 / n])
		print("      per frame (ms): " + ", ".join(parts))
		for l in slow_lines:
			print(l)
	return r


func _find_biome(world: WorldView, b: int) -> Vector3:
	var map: MapData = world.map
	var n := map.layout_n
	var best := Vector3.ZERO
	var best_d := INF
	for k in n * n:
		if map.layout_biome[k] == b and map.layout_weights[b][k] > 230:
			var p := Vector3((float(k % n) + 0.5) / n * map.map_m - map.map_m * 0.5, 0, (float(k / n) + 0.5) / n * map.map_m - map.map_m * 0.5)
			var d := p.length()
			if d < best_d:
				best_d = d
				best = p
	return best


## The highest ground within `radius` of `c` (a view over the land).
func _highest_near(world: WorldView, c: Vector3, radius: float) -> Vector3:
	var best := c
	var best_h := -INF
	for i in 400:
		var a := i * 2.39996
		var r := radius * sqrt((i + 0.5) / 400.0)
		var p := c + Vector3(cos(a) * r, 0, sin(a) * r)
		var h := world.terrain.get_height(p)
		if h > best_h:
			best_h = h
			best = p
	return best


## Which nodes run every frame / tick (per class or script), to find the per-frame costs.
func _count_processing() -> void:
	var counts := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children(true))
		var flags := ""
		if n.is_processing() or n.is_processing_internal():
			flags += "P"
		if n.is_physics_processing() or n.is_physics_processing_internal():
			flags += "F"
		if flags == "":
			continue
		var scr: Script = n.get_script()
		var key := "%s %s" % [flags, scr.resource_path.get_file() if scr else n.get_class()]
		counts[key] = int(counts.get(key, 0)) + 1
	var keys := counts.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return counts[a] > counts[b])
	for k: String in keys:
		print("  %5d  %s" % [counts[k], k])


## Main-thread time with each subsystem switched off in turn, at one view.
func _ablate(world: WorldView, player: Player, v: Array) -> void:
	_place(world, player, v[0], v[1], v[2])
	await _settle()
	var base := await _measure("ablate:all", 3.0)
	var parts := {
		"terrain3d": (world.terrain as Terrain3DBackend).terrain,
		"terrain_backend": world.terrain,
		"city": world.city, "impostors": world.impostors, "water": world.water, "entities": world.entities,
		"session": game.session, "npcs": game.session.npcs, "spawns": game.session.spawns,
		"hud": game.hud, "console": game.game.console, "game_session": game.game,
		"player_anim": player.animator, "lod": world.lod, "world_view": world,
	}
	for pname: String in parts:
		var node: Node = parts[pname]
		if node == null:
			continue
		var was := node.process_mode
		node.process_mode = Node.PROCESS_MODE_DISABLED
		await _settle_short()
		var r := await _measure("  -" + pname, 3.0)
		node.process_mode = was
		await _settle_short()
		if not r.has("error"):
			print("    %-16s p50 %6.2f ms  p99 %6.2f ms  spikes/s %5.1f   (all: p50 %.2f p99 %.2f spikes/s %.1f)" % [pname, r.ms_p50, r.ms_p99, r.spikes / 3.0, base.ms_p50, base.ms_p99, base.spikes / 3.0])


func _settle_short() -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 500:
		await process_frame


## Frame time with each visual feature switched off in turn, at one view. The game is
## GPU-bound and Metal reports no GPU timings, so the frame time is the GPU cost.
func _gpu_ablate(world: WorldView, player: Player, v: Array) -> void:
	_place(world, player, v[0], v[1], v[2])
	await _settle()
	var base := await _measure("gpu:all", 2.0)
	if OS.has_environment("BENCH_SHOTS"):
		root.get_texture().get_image().save_png(OS.get_environment("BENCH_SHOTS").path_join("gpu_all.png"))
	var env: Environment = world.environment.environment
	var t3d: Terrain3D = (world.terrain as Terrain3DBackend).terrain
	var grass: Node3D = world.terrain.get_node_or_null("Grass")
	var toggles := {
		# (the session's time of day would switch the sun's shadows back on)
		"shadows": func(on: bool) -> void:
			game.session.set_process(on)
			world.sun.shadow_enabled = on,
		"shadow_150m": func(on: bool) -> void: world.sun.directional_shadow_max_distance = LodSettings.SHADOW_DISTANCE if on else 150.0,
		"t_shadows": func(on: bool) -> void: t3d.cast_shadows = RenderingServer.SHADOW_CASTING_SETTING_ON if on else RenderingServer.SHADOW_CASTING_SETTING_OFF,
		# (inverted: "off" = the speed patch on)
		"t_patch": func(on: bool) -> void: (world.terrain as Terrain3DBackend).optimize_shader(not on),
		"shadow_hard": func(on: bool) -> void: RenderingServer.directional_soft_shadow_filter_set_quality(
			RenderingServer.SHADOW_QUALITY_SOFT_LOW if on else RenderingServer.SHADOW_QUALITY_HARD),
		"shadow_2split": func(on: bool) -> void: world.sun.directional_shadow_mode = (
			DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if on else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS),
		"shadow_atlas2k": func(on: bool) -> void: RenderingServer.directional_shadow_atlas_set_size(4096 if on else 2048, true),
		"ssao_low": func(on: bool) -> void: RenderingServer.environment_set_ssao_quality(
			RenderingServer.ENV_SSAO_QUALITY_MEDIUM if on else RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, true, 0.5, 2, 50.0, 300.0),
		"aniso_off": func(on: bool) -> void: root.anisotropic_filtering_level = Viewport.ANISOTROPY_4X if on else Viewport.ANISOTROPY_DISABLED,
		"t_flat": func(on: bool) -> void: _terrain_flat(world, not on),
		"t_lods5": func(on: bool) -> void: t3d.mesh_lods = 7 if on else 5,
		"t_mesh32": func(on: bool) -> void: t3d.mesh_size = 48 if on else 32,
		"t_projection": func(on: bool) -> void: t3d.material.projection_enabled = on,
		"t_dual_scale": func(on: bool) -> void: t3d.material.dual_scaling_enabled = on,
		"t_macro": func(on: bool) -> void: t3d.material.macro_variation_enabled = on,
		"t_aniso": func(on: bool) -> void: t3d.material.texture_filtering = Terrain3DMaterial.LINEAR_ANISOTROPIC if on else Terrain3DMaterial.LINEAR,
		"vegetation": func(on: bool) -> void: t3d.instancer.set("visible", on) if false else _set_mmi_visible(t3d, on),
		"ssao": func(on: bool) -> void: env.ssao_enabled = on,
		"glow": func(on: bool) -> void: env.glow_enabled = on,
		"fog": func(on: bool) -> void: env.fog_enabled = on,
		"grass": func(on: bool) -> void: if grass: grass.visible = on,
		"terrain": func(on: bool) -> void: t3d.visible = on,
		"city": func(on: bool) -> void: world.city.visible = on,
		"city_lod0": func(on: bool) -> void: _city_level(world, 0, on),
		"city_lod1": func(on: bool) -> void: _city_level(world, 1, on),
		"city_lod2": func(on: bool) -> void: _city_level(world, 2, on),
		"city_shadow": func(on: bool) -> void: _city_level(world, CityView.SHADOW_PROXY, on),
		"impostors": func(on: bool) -> void: world.impostors.visible = on,
		"water": func(on: bool) -> void: world.water.visible = on,
		"entities": func(on: bool) -> void: world.entities.visible = on,
		"player": func(on: bool) -> void: player.visual.visible = on,
		"half_res": func(on: bool) -> void: root.scaling_3d_scale = 1.0 if on else 0.5,
	}
	var pick := OS.get_environment("BENCH_ONLY").split(",", false)
	for pname: String in toggles:
		if not pick.is_empty() and not pname in pick:
			continue
		var f: Callable = toggles[pname]
		f.call(false)
		await _settle_short()
		var r := await _measure("  -" + pname, 1.5)
		if OS.has_environment("BENCH_SHOTS"):
			root.get_texture().get_image().save_png(OS.get_environment("BENCH_SHOTS").path_join("gpu_off_%s.png" % pname))
		f.call(true)
		await _settle_short()
		if not r.has("error"):
			print("    %-10s frame p50 %+7.2f ms  (%.2f -> %.2f)  draws %+5d  tris %+9d" % [pname, r.ms_p50 - base.ms_p50, base.ms_p50, r.ms_p50,
				int(r.draws - base.draws), int(r.prims - base.prims)])


## Terrain3D's instancer draws through MultiMeshInstance3D nodes under the terrain.
func _set_mmi_visible(t3d: Terrain3D, on: bool) -> void:
	for n in t3d.find_children("*", "MultiMeshInstance3D", true, false):
		(n as Node3D).visible = on


func _city_level(world: WorldView, level: int, on: bool) -> void:
	for c in world.city.get_children():
		if c is GeometryInstance3D and c.has_meta("lod_level") and int(c.get_meta("lod_level")) == level:
			(c as Node3D).visible = on


## Terrain with all texturing skipped (same geometry and lighting): what the material costs.
func _terrain_flat(world: WorldView, flat: bool) -> void:
	var tb := world.terrain as Terrain3DBackend
	tb.optimize_shader(false)
	if not flat:
		return
	var code := Terrain3DBackend.patched_shader(RenderingServer.shader_get_code(tb.terrain.material.get_shader_rid()), 40.0)
	# fragment() is the last function: wrap its body in a branch that never runs.
	code = code.replace("void fragment() {", "uniform bool lux_never = false;\nvoid fragment() {\n ALBEDO = vec3(0.35, 0.33, 0.3);\n if (lux_never) {")
	code = code.strip_edges() + "\n}\n"
	var sh := Shader.new()
	sh.code = code
	tb.terrain.material.shader_override = sh
	tb.terrain.material.shader_override_enabled = true


## When the slow frames happen (ms since start, and the gap to the previous one): their
## rhythm points at the system behind them.
func _spikes(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	var last := t0
	var times: Array[float] = []
	var frames: Array[float] = []
	while Time.get_ticks_usec() - t0 < int(seconds * 1e6):
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		times.append((now - t0) / 1000.0)
		last = now
	var sorted := frames.duplicate()
	sorted.sort()
	var med: float = sorted[sorted.size() / 2]
	var prev := 0.0
	var line := "spikes (> 1.6 x median %.1f ms): " % med
	for i in frames.size():
		if frames[i] > med * 1.6:
			line += "%.0f(+%.0f)=%.1f " % [times[i], times[i] - prev, frames[i]]
			prev = times[i]
	print(line)
