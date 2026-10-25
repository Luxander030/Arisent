extends TestCase

func test_every_instanced_asset_has_a_lod_chain() -> void:
	for id in Catalog.instanced_ids():
		var scene := LodSettings.lod_scene(id)
		check(scene != null, "missing LOD scene for " + id + " (run tools/lod/build_lods.gd)")

func test_lod_levels_get_cheaper() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LodSettings.OUT_DIR + "manifest.json"))
	for id in manifest:
		var tris: Array = manifest[id].triangles
		for i in range(1, tris.size()):
			check(int(tris[i]) <= int(tris[i - 1]), "%s LOD%d has more triangles than LOD%d" % [id, i, i - 1])

func test_trees_have_impostors() -> void:
	for id in Catalog.ids("tree"):
		check(LodSettings.has_impostor(id), "no impostor for " + id)

func test_tiers_scale_and_increase() -> void:
	for cat in LodSettings.TIERS:
		var t := LodSettings.tiers(cat, 1.0)
		for i in range(1, t.size()):
			check(t[i] > t[i - 1], "tiers must increase for " + cat)
		eq(LodSettings.tiers(cat, 2.0)[0], t[0] * 2.0, "scaled tier " + cat)

## Under vsync the frame rate can't show headroom: missed frames lower quality (render
## resolution and SSAO along with detail), calm raises it one notch at a time, and a
## notch that brings misses back makes the next try wait twice as long.
func test_adaptive_governor_with_vsync() -> void:
	var c := LodController.new()
	var holder := Node.new()
	Engine.get_main_loop().root.add_child(holder)
	holder.add_child(c)
	c.target_fps = 60.0
	c.set_mode("Adaptive")
	eq(c.rung, LodController.LADDER_HIGH, "starts at High")
	check(c.render_scale == 1.0 and c.ssao, "full resolution and SSAO at High")
	for fps: float in [48.0, 50.0, 52.0, 54.0]:  # each step helps a little (else it would hold)
		c.step(fps, 0.1, true)
	check(c.rung > LodController.LADDER_HIGH + 2, "missed frames step down (rung %d)" % c.rung)
	check(c.render_scale < 1.0 and not c.ssao and c.scale < 1.0, "resolution, SSAO and detail all lowered")
	eq(c.get_viewport().scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR, "FSR upscales")
	var low := c.rung
	c._hold = 0.0
	c._calm = 1.0
	c.step(60.0, 0.0, true)
	eq(c.rung, low, "no headroom shown yet: stays")
	c._calm = c._calm_needed
	c.step(60.0, 0.0, true)
	eq(c.rung, low - 1, "after a calm stretch: one notch up")
	var waited := c._calm_needed
	c.step(58.0, 0.08, true)  # misses right after the raise
	eq(c.rung, low, "back down")
	check(c._calm_needed > waited, "and waits longer before the next try (%.0f s -> %.0f s)" % [waited, c._calm_needed])
	c.set_mode("Low")
	check(c.render_scale == 1.0 and c.ssao and is_equal_approx(c.scale, 0.5), "presets render at full resolution")
	c.get_viewport().scaling_3d_scale = 1.0
	c.get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	holder.queue_free()


func test_adaptive_controller_steps_and_holds() -> void:
	var c := LodController.new()
	var holder := Node.new()
	Engine.get_main_loop().root.add_child(holder)
	holder.add_child(c)
	c.mode = "Adaptive"
	c.target_fps = 60.0
	c.scale = 1.0
	c.step(40.0)
	check(c.rung > LodController.LADDER_HIGH and c.render_scale < 1.0, "slow frame rate lowers quality (resolution first)")
	var s1 := c.rung
	c.step(40.0)  # no improvement
	c.step(40.0)  # still none -> hold
	check(c.is_holding(), "stops lowering when it doesn't help")
	var s2 := c.rung
	c.step(40.0)
	eq(c.rung, s2, "no further reduction while holding")
	check(s2 >= s1, "quality never rises while slow")
	c._hold = 0.0
	c.step(90.0)
	check(c.rung < s2, "headroom raises quality")
	c.get_viewport().scaling_3d_scale = 1.0
	c.get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	holder.queue_free()
