extends TestCase

func _city(seed: String, modern: float = 0.4) -> Dictionary:
	var p := GenParams.new()
	p.seed = seed
	p.city_modern = modern
	var L := LayoutGenerator.new().generate(p, 256)
	return CityGen.new().generate(L, p)

func test_city_is_deterministic_and_large() -> void:
	var a := _city("5")
	var b := _city("5")
	eq(JSON.stringify(a), JSON.stringify(b), "same seed, same city")
	check(a.buildings.size() > 300, "a large city has many buildings (%d)" % a.buildings.size())
	check(not a.wall.is_empty(), "old town has walls")

func test_building_keys_unique_and_stable() -> void:
	var a := _city("8")
	var keys := {}
	for b in a.buildings:
		check(not keys.has(b.key), "duplicate key " + b.key)
		keys[b.key] = true

func test_buildings_stay_inside_city() -> void:
	var a := _city("13", 0.8)
	var c := Vector2(a.center[0], a.center[1])
	for b in a.buildings:
		check(Vector2(b.x, b.z).distance_to(c) <= float(a.radius) + 20.0, "building outside city")
