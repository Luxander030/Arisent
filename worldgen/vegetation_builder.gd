## Fills terrain regions with vegetation using Scatter rules.
class_name VegetationBuilder
extends RefCounted

const STAGE_SCATTER := 60


static func make_context(map: MapData) -> Scatter.Context:
	var p := GenParams.new()
	p.from_dict(map.gen_params)
	var ctx := Scatter.Context.new()
	ctx.seed = Rng.derive(p.seed_int(), STAGE_SCATTER)
	ctx.density = p.vegetation * 2.0
	ctx.map_m = map.map_m
	ctx.spacing = map.spacing
	ctx.R = map.res()
	ctx.n = map.layout_n
	ctx.weights = map.layout_weights
	ctx.water = PackedByteArray()
	ctx.water.resize(map.layout_n * map.layout_n)
	if map.water_mask:
		for k in ctx.water.size():
			var c := map.water_mask.get_pixel(k % map.layout_n, k / map.layout_n)
			ctx.water[k] = 1 if c.r > 0.5 or c.b > 0.5 else 0
	var city: Dictionary = map.city
	if city.has("center"):
		ctx.city_center = Vector2(city.center[0], city.center[1])
		ctx.city_radius = float(city.radius)
	ctx.paint = map.scatter_paint
	ctx.prepare()
	return ctx


## Whole map from in-memory full-res arrays (generation time). Parallel over regions.
## Returns Array of [region_rect, {mesh_id: Array[Transform3D]}].
static func scatter_all(ctx: Scatter.Context, rects: Array[Rect2i], H: PackedFloat32Array, ctrl: PackedInt32Array) -> Array:
	var results := []
	results.resize(rects.size())
	var R := ctx.R
	var task := func(i: int) -> void:
		var rect: Rect2i = rects[i]
		var hg := TerrainBuilder.padded_rect(H, R, rect)
		var cg := _padded_ctrl(ctrl, R, rect)
		var merged := {}
		for g in Scatter.GROUP_NAMES:
			var part := Scatter.scatter_rect(ctx, g, rect, hg, cg)
			for mid in part:
				var arr: Array = merged.get(mid, [])
				arr.append_array(part[mid])
				merged[mid] = arr
		results[i] = [rect, merged]
	var id := WorkerThreadPool.add_group_task(task, rects.size(), -1, true, "scatter")
	WorkerThreadPool.wait_for_group_task_completion(id)
	return results


## One region (editor re-scatter), reading the current terrain.
static func scatter_region(ctx: Scatter.Context, terrain: TerrainBackend, rect: Rect2i) -> Dictionary:
	var R := terrain.full_res()
	var grown := rect.grow(1).intersection(Rect2i(0, 0, R, R))
	var hraw := terrain.read_heights(grown)
	var craw := terrain.read_control(grown)
	var H := PackedFloat32Array()
	var C := PackedInt32Array()
	for y in range(rect.position.y - 1, rect.end.y + 1):
		var yy := clampi(y, grown.position.y, grown.end.y - 1) - grown.position.y
		for x in range(rect.position.x - 1, rect.end.x + 1):
			var xx := clampi(x, grown.position.x, grown.end.x - 1) - grown.position.x
			H.append(hraw[yy * grown.size.x + xx])
			C.append(craw[yy * grown.size.x + xx])
	var merged := {}
	for g in Scatter.GROUP_NAMES:
		var part := Scatter.scatter_rect(ctx, g, rect, H, C)
		for mid in part:
			var arr: Array = merged.get(mid, [])
			arr.append_array(part[mid])
			merged[mid] = arr
	return merged


static func apply(terrain: TerrainBackend, rect: Rect2i, merged: Dictionary) -> void:
	for mid in Catalog.instanced_ids().size():
		var xf: Array[Transform3D] = []
		xf.assign(merged.get(mid, []))
		terrain.set_region_instances(rect, mid, xf)


static func _padded_ctrl(C: PackedInt32Array, R: int, rect: Rect2i) -> PackedInt32Array:
	var out := PackedInt32Array()
	for y in range(rect.position.y - 1, rect.end.y + 1):
		var yy := clampi(y, 0, R - 1)
		for x in range(rect.position.x - 1, rect.end.x + 1):
			out.append(C[yy * R + clampi(x, 0, R - 1)])
	return out
