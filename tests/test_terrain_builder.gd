extends TestCase

func _build(size_km: int, seed: String) -> TerrainBuilder.Result:
	var p := GenParams.new()
	p.seed = seed
	p.size_km = size_km
	var L := LayoutGenerator.new().generate(p, 512)
	var b := TerrainBuilder.new()
	var t := Time.get_ticks_msec()
	var r := b.build(L, p)
	print("    build %d km (%d²): %d ms" % [size_km, r.res, Time.get_ticks_msec() - t])
	return r

func test_build_2km() -> void:
	var r := _build(2, "42")
	eq(r.height.size(), r.res * r.res, "height size")
	eq(r.control.size(), r.res * r.res, "control size")
	var mn := INF
	var mx := -INF
	for h in r.height:
		mn = minf(mn, h)
		mx = maxf(mx, h)
	print("    height range %.1f .. %.1f m, rivers %d" % [mn, mx, r.rivers.size()])
	check(mx > 50.0 and mn < 0.0, "has mountains and sea")
	DirAccess.make_dir_recursive_absolute("user://test_out")
	var img := r.height_image()
	img.resize(512, 512)
	var hb := img.get_data().to_float32_array()
	var vis := PackedByteArray()
	vis.resize(512 * 512)
	for k in hb.size():
		vis[k] = clampi(int((hb[k] + 20.0) / 6.0), 0, 255)
	Image.create_from_data(512, 512, false, Image.FORMAT_L8, vis).save_png("user://test_out/height_2km.png")

func test_build_is_deterministic() -> void:
	var a := _build(2, "7")
	var b := _build(2, "7")
	eq(a.height.to_byte_array().get_string_from_ascii().length() >= 0, true)
	check(a.height == b.height, "same heights")
	check(a.control == b.control, "same control map")
