extends TestCase

const OUT := "user://test_out"

func _params(seed: String = "42") -> GenParams:
	var p := GenParams.new()
	p.seed = seed
	return p

func test_layout_timings_and_preview() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	for size in [256, 512]:
		var g := LayoutGenerator.new()
		var t := Time.get_ticks_msec()
		var L := g.generate(_params(), size)
		print("    layout %d²: %d ms %s" % [size, Time.get_ticks_msec() - t, L.timings])
		PreviewPainter.paint(L).save_png(OUT + "/preview_%d.png" % size)
		check(L.rivers.size() > 0, "rivers exist")
		check(L.has_city, "city exists")

func test_same_seed_same_layout() -> void:
	var a := LayoutGenerator.new().generate(_params("777"), 256)
	var b := LayoutGenerator.new().generate(_params("777"), 256)
	eq(a.digest(), b.digest(), "same seed")
	var c := LayoutGenerator.new().generate(_params("778"), 256)
	check(a.digest() != c.digest(), "different seed differs")

func test_params_json_round_trip() -> void:
	var p := _params("98765432109876543")
	p.size_km = 8
	p.biomes[GenParams.Biome.DESERT] = false
	var q := GenParams.new()
	q.from_dict(JSON.parse_string(JSON.stringify(p.to_dict())))
	eq(q.canonical_string(), p.canonical_string(), "canonical after JSON")
	eq(q.seed_int(), p.seed_int(), "seed after JSON")
	eq(typeof(q.size_km), TYPE_INT)

func test_city_inside_border_margin_and_on_land() -> void:
	for s in ["1", "2", "3", "4", "5", "6"]:
		var p := _params(s)
		p.land_water = 0.9
		p.islands = 1.0
		var L := LayoutGenerator.new().generate(p, 256)
		check(L.has_city, "city for seed " + s)
		var lim := L.map_m * 0.5 - (0.15 * L.map_m + L.city_radius)
		check(absf(L.city_center.x) <= lim + 0.01 and absf(L.city_center.y) <= lim + 0.01, "city margin seed " + s)
		var c := L.world_to_cell(L.city_center)
		eq(L.ocean[c.y * L.n + c.x], 0, "city on land seed " + s)

func test_slider_change_keeps_coast() -> void:
	var g := LayoutGenerator.new()
	var p := _params("31")
	var a := g.generate(p, 256)
	var ocean_a := a.ocean
	var q := p.duplicate_params()
	q.rivers = 0.9
	var b := g.generate(q, 256)
	eq(b.ocean, ocean_a, "rivers slider must not move the coast")
	check(b.timings.size() == a.timings.size(), "timings present")

func test_no_rifts_or_desert_lakes() -> void:
	var p := _params("9")
	p.rifts = 1.0
	p.lakes = 1.0
	var L := LayoutGenerator.new().generate(p, 256)
	var dry_cells := {}
	for k in L.n * L.n:
		if L.lake_id[k] >= 0 and L.dry[k] == 1:
			dry_cells[L.lake_id[k]] = dry_cells.get(L.lake_id[k], 0) + 1
	for id in dry_cells:
		check(dry_cells[id] * 2 < L.lakes[id].cells, "lake %d is mostly on dry ground" % id)
