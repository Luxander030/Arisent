## The map's "big picture" on a fixed-size grid (512² for every map size, 256² while
## the user drags a slider). Everything structural is decided here: coasts, biomes,
## mountains, lakes, rivers, the city site. Full-resolution terrain is derived from it.
class_name WorldLayout
extends RefCounted

var n: int
var map_m: float
var cell_m: float

var land: PackedFloat32Array        ## > 0 = land (stage 1 mask value)
var ocean: PackedByteArray          ## 1 = ocean-connected water
var coast_dist: PackedFloat32Array  ## metres to the nearest ocean cell (1e9 if no ocean)
var temp: PackedFloat32Array        ## 0 = coldest (north) .. 1 = hottest (south)
var moist: PackedFloat32Array       ## 0 = dry .. 1 = wet
var weights: Array[PackedFloat32Array] = []  ## per biome (GenParams.Biome), sums to 1
var biome: PackedByteArray          ## dominant biome per cell
var height: PackedFloat32Array      ## metres, sea level = 0
var dry: PackedByteArray            ## 1 = never holds standing water (desert, rifts)
var rift: PackedFloat32Array        ## 0..1 rift strength (for textures)

var lake_id: PackedInt32Array       ## -1 = no lake
var lakes: Array[Dictionary] = []   ## {id, level, cells, frozen, center: Vector2}
var flow: PackedFloat32Array        ## accumulated rain flowing through each cell
var receiver: PackedInt32Array      ## downstream cell (-1 = outlet)
var river: PackedByteArray          ## 1 = river cell
var rivers: Array[Dictionary] = []  ## {points: PackedVector2Array (world xz), widths, beds, frozen}
var sea_ice: PackedByteArray

var ocean_edges: Array[int] = []    ## 0 N, 1 E, 2 S, 3 W
var has_city := false
var city_center := Vector2.ZERO    ## world xz
var city_radius := 0.0
var city_height := 0.0

var timings := {}
var stage_keys := {}


func _init(size: int = 0, map_size_m: float = 0.0) -> void:
	n = size
	map_m = map_size_m
	if n > 0:
		cell_m = map_m / n


func copy() -> WorldLayout:
	var c := WorldLayout.new(n, map_m)
	# Packed arrays are shared by reference: deep-copy so later stages never
	# modify the cached output of earlier ones.
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v: Variant = get(p.name)
			if typeof(v) >= TYPE_PACKED_BYTE_ARRAY:
				v = v.duplicate()
			c.set(p.name, v)
	var ws: Array[PackedFloat32Array] = []
	for w in weights:
		ws.append(w.duplicate())
	c.weights = ws
	c.lakes = lakes.duplicate()
	c.rivers = rivers.duplicate()
	c.ocean_edges = ocean_edges.duplicate()
	c.timings = timings.duplicate()
	c.stage_keys = stage_keys.duplicate()
	return c


func cell_center(i: int, j: int) -> Vector2:
	return Vector2(-map_m * 0.5 + (i + 0.5) * cell_m, -map_m * 0.5 + (j + 0.5) * cell_m)


func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(floori((p.x + map_m * 0.5) / cell_m), 0, n - 1),
		clampi(floori((p.y + map_m * 0.5) / cell_m), 0, n - 1))


## Bilinear sample of a per-cell float array at a world position.
func sample(arr: PackedFloat32Array, p: Vector2) -> float:
	var fx := (p.x + map_m * 0.5) / cell_m - 0.5
	var fz := (p.y + map_m * 0.5) / cell_m - 0.5
	var x0 := clampi(floori(fx), 0, n - 1)
	var z0 := clampi(floori(fz), 0, n - 1)
	var x1 := mini(x0 + 1, n - 1)
	var z1 := mini(z0 + 1, n - 1)
	var tx := clampf(fx - x0, 0.0, 1.0)
	var tz := clampf(fz - z0, 0.0, 1.0)
	var a := lerpf(arr[z0 * n + x0], arr[z0 * n + x1], tx)
	var b := lerpf(arr[z1 * n + x0], arr[z1 * n + x1], tx)
	return lerpf(a, b, tz)


## Stable digest of the structural result (golden tests, cache keys).
func digest() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var q := PackedInt32Array()
	q.resize(height.size())
	for i in height.size():
		q[i] = roundi(height[i] * 4.0)
	ctx.update(q.to_byte_array())
	ctx.update(biome)
	ctx.update(ocean)
	ctx.update(river)
	ctx.update(lake_id.to_byte_array())
	ctx.update(("%d,%d,%d" % [roundi(city_center.x), roundi(city_center.y), roundi(city_radius)]).to_utf8_buffer())
	return ctx.finish().hex_encode().substr(0, 16)


# --- grid helpers ------------------------------------------------------------

## Approximate Euclidean distance (in cells) to the nearest cell where mask == 1.
## Two-pass 3-4 chamfer transform: fast, deterministic, order-fixed.
static func distance_field(mask: PackedByteArray, size: int) -> PackedFloat32Array:
	var big := 1.0e9
	var d := PackedFloat32Array()
	d.resize(size * size)
	for i in size * size:
		d[i] = 0.0 if mask[i] == 1 else big
	for j in size:
		for i in size:
			var k := j * size + i
			var v := d[k]
			if v == 0.0:
				continue
			if i > 0:
				v = minf(v, d[k - 1] + 1.0)
			if j > 0:
				v = minf(v, d[k - size] + 1.0)
				if i > 0:
					v = minf(v, d[k - size - 1] + 1.4142)
				if i < size - 1:
					v = minf(v, d[k - size + 1] + 1.4142)
			d[k] = v
	for j in range(size - 1, -1, -1):
		for i in range(size - 1, -1, -1):
			var k := j * size + i
			var v := d[k]
			if v == 0.0:
				continue
			if i < size - 1:
				v = minf(v, d[k + 1] + 1.0)
			if j < size - 1:
				v = minf(v, d[k + size] + 1.0)
				if i < size - 1:
					v = minf(v, d[k + size + 1] + 1.4142)
				if i > 0:
					v = minf(v, d[k + size - 1] + 1.4142)
			d[k] = v
	return d
