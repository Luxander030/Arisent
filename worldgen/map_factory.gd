## Turns generator output (params + layout + full-res terrain) into a MapData.
class_name MapFactory
extends RefCounted


static func create(p: GenParams, L: WorldLayout, r: TerrainBuilder.Result, city: Dictionary = {}) -> MapData:
	var map := MapData.new()
	map.name = p.name
	map.size_km = p.size_km
	map.map_m = r.map_m
	map.spacing = r.spacing
	map.generator_version = GenParams.GENERATOR_VERSION
	map.gen_params = p.to_dict()
	map.stage_hashes = {"layout": L.digest()}
	map.water = water_dict(L, r)
	map.water_mask = r.water_mask
	map.layout_n = L.n
	map.layout_biome = L.biome
	map.layout_temp = L.temp
	map.layout_weights = []
	for w in L.weights:
		var q := PackedByteArray()
		q.resize(w.size())
		for k in w.size():
			q[k] = clampi(roundi(w[k] * 255.0), 0, 255)
		map.layout_weights.append(q)
	if not city.is_empty():
		map.city = city
	elif L.has_city:
		map.city = {"center": [L.city_center.x, L.city_center.y], "radius": L.city_radius, "height": L.city_height}
	if r.lock.size() == r.res * r.res:
		map.paint_lock = Image.create_from_data(r.res, r.res, false, Image.FORMAT_L8, r.lock)
	map.minimap = PreviewPainter.paint(L)
	map.procedural_height = r.height_image()
	return map


static func water_dict(L: WorldLayout, r: TerrainBuilder.Result) -> Dictionary:
	var lakes := []
	var boxes := {}
	for k in L.n * L.n:
		var id := L.lake_id[k]
		if id < 0:
			continue
		var c := L.cell_center(k % L.n, k / L.n)
		var bx: Rect2 = boxes.get(id, Rect2(c, Vector2.ZERO))
		boxes[id] = bx.expand(c)
	for lake in L.lakes:
		var bx: Rect2 = boxes.get(lake.id, Rect2()).grow(L.cell_m)
		lakes.append({"id": lake.id, "level": lake.level, "frozen": lake.frozen,
			"rect": [bx.position.x, bx.position.y, bx.end.x, bx.end.y], "origin": "generated"})
	var rivers := []
	for rv in r.rivers:
		var pts := []
		for q: Vector3 in rv.points:
			pts.append([snappedf(q.x, 0.01), snappedf(q.y, 0.01), snappedf(q.z, 0.01)])
		var ws := []
		for w in rv.widths:
			ws.append(snappedf(w, 0.01))
		rivers.append({"points": pts, "widths": ws, "frozen": rv.frozen, "origin": "generated"})
	return {"ocean": L.ocean.has(1), "sea_level": 0.0, "lakes": lakes, "rivers": rivers}
