## Turns a WorldLayout into full-resolution terrain: heights (procedural height P),
## Terrain3D control map (ground textures + transitions), colour map, and water data.
## Runs on the CPU: engine C++ for noise/resampling, parallel row bands for the rest.
class_name TerrainBuilder
extends RefCounted

const B := GenParams.Biome

## Terrain texture slots (order = Terrain3D texture ids; see assets/terrain_textures.gd).
enum Tex { GRASS, GRASS_DIRT, FOREST_FLOOR, DRY_EARTH, SAND, SAND_DARK, GRAVEL, ROCK, SNOW, ICE }

## Per biome: [base texture, patch texture, tint]
const BIOME_GROUND := {
	B.FJORDS: [Tex.SNOW, Tex.ROCK, Color(1.0, 1.0, 1.0)],
	B.NORTH_MOUNTAINS: [Tex.ROCK, Tex.GRAVEL, Color(0.95, 0.95, 1.0)],
	B.OCEAN: [Tex.SAND, Tex.SAND_DARK, Color(1.0, 1.0, 1.0)],
	B.TEMPERATE_FOREST: [Tex.GRASS, Tex.FOREST_FLOOR, Color(0.86, 0.95, 0.86)],
	B.GRASSLAND: [Tex.GRASS, Tex.GRASS_DIRT, Color(1.0, 1.0, 0.9)],
	B.TROPICAL: [Tex.GRASS_DIRT, Tex.GRASS, Color(0.72, 1.0, 0.68)],
	B.DESERT_HIGHLANDS: [Tex.DRY_EARTH, Tex.SAND_DARK, Color(1.0, 0.9, 0.82)],
	B.DESERT: [Tex.SAND, Tex.SAND_DARK, Color(1.0, 0.97, 0.9)],
}

var cancelled := false
var progress := 0.0
var status := ""


class Result:
	var res: int            ## samples per side
	var spacing: float      ## metres between samples
	var map_m: float
	var height: PackedFloat32Array
	var control: PackedInt32Array
	var color: PackedByteArray  ## RGBA8
	var rivers: Array[Dictionary] = []  ## smoothed: {points: PackedVector3Array (x, water level, z), widths, frozen}
	var lakes: Array[Dictionary] = []
	var water_mask: Image   ## layout-res: R = ocean, G = sea ice, B = lake
	var lock: PackedByteArray  ## 255 where texture is authored (city streets): auto-texturing skips it
	var build_ms := {}

	func origin() -> Vector3:
		return Vector3(-map_m * 0.5, 0.0, -map_m * 0.5)

	func height_image() -> Image:
		return Image.create_from_data(res, res, false, Image.FORMAT_RF, height.to_byte_array())

	func control_image() -> Image:
		return Image.create_from_data(res, res, false, Image.FORMAT_RF, control.to_byte_array())

	func color_image() -> Image:
		return Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, color)


static func spacing_for(size_km: int) -> float:
	return 2.0 if size_km >= 8 else 1.0


func build(L: WorldLayout, p: GenParams, city: Dictionary = {}) -> Result:
	cancelled = false
	var r := Result.new()
	r.map_m = L.map_m
	r.spacing = spacing_for(p.size_km)
	r.res = roundi(L.map_m / r.spacing)
	r.lakes = L.lakes.duplicate(true)
	var seed := Rng.derive(p.seed_int(), 50)

	_step(r, 0.02, "Upsampling layout", func() -> void: pass)
	var R := r.res
	var amp_l := _detail_amplitude(L, p)
	var H := _upsample(L.height, L.n, R, Image.INTERPOLATE_CUBIC)
	var AMP := _upsample(amp_l, L.n, R, Image.INTERPOLATE_BILINEAR)
	var water_l := PackedFloat32Array()
	water_l.resize(L.n * L.n)
	for k in L.n * L.n:
		water_l[k] = 1.0 if L.ocean[k] == 1 or L.lake_id[k] >= 0 else 0.0
	var WATER := _upsample(water_l, L.n, R, Image.INTERPOLATE_BILINEAR)
	if cancelled: return null

	_step(r, 0.15, "Detail noise", func() -> void: pass)
	var D := _detail_noise(R, r.spacing, r.map_m, seed)
	if cancelled: return null

	_step(r, 0.35, "Combining height", func() -> void: pass)
	r.height = _combine(H, D, AMP, WATER, R)
	H = PackedFloat32Array()

	_step(r, 0.45, "Carving rivers", func() -> void: pass)
	r.rivers = _smooth_rivers(L)
	var river_mask := _carve_rivers(r, R)
	if cancelled: return null

	_step(r, 0.6, "Painting ground", func() -> void: pass)
	var tex := _textures(r, L, p, D, river_mask, seed)
	r.control = tex[0]
	r.color = tex[1]
	if cancelled: return null

	_step(r, 0.9, "Paving streets", func() -> void: pass)
	r.lock = _paint_roads(r, city)

	_step(r, 0.95, "Water masks", func() -> void: pass)
	r.water_mask = _water_mask(L)
	progress = 1.0
	status = "Done"
	return r


func _step(r: Result, prog: float, what: String, _f: Callable) -> void:
	progress = prog
	status = what


## Layout-res amplitude of full-res detail noise: by biome, faded to 0 near water and city.
func _detail_amplitude(L: WorldLayout, p: GenParams) -> PackedFloat32Array:
	var n := L.n
	var near_water := PackedByteArray()
	near_water.resize(n * n)
	for k in n * n:
		near_water[k] = 1 if L.ocean[k] == 1 or L.lake_id[k] >= 0 or L.river[k] == 1 else 0
	var wd := WorldLayout.distance_field(near_water, n)
	var amp := PackedFloat32Array()
	amp.resize(n * n)
	var hill := 0.5 + p.hilliness
	for k in n * n:
		var w := L.weights
		var a := 1.2 * w[B.GRASSLAND][k] + 2.5 * w[B.TEMPERATE_FOREST][k] + 3.0 * w[B.TROPICAL][k] \
			+ 1.2 * w[B.DESERT][k] + 5.0 * w[B.DESERT_HIGHLANDS][k] + 9.0 * w[B.NORTH_MOUNTAINS][k] + 7.0 * w[B.FJORDS][k]
		var fade := LayoutGenerator.smooth(0.5, 3.0, wd[k] * L.cell_m / maxf(L.cell_m, 8.0))
		amp[k] = a * hill * fade
	if L.has_city:
		var bb := LayoutGenerator.city_cell_box(L, L.city_radius * 1.4)
		for j in range(bb.position.y, bb.end.y):
			for i in range(bb.position.x, bb.end.x):
				var d := L.cell_center(i, j).distance_to(L.city_center)
				amp[j * n + i] *= LayoutGenerator.smooth(L.city_radius * 0.9, L.city_radius * 1.4, d)
	return amp


static func _upsample(src: PackedFloat32Array, n: int, R: int, interp: int) -> PackedFloat32Array:
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RF, src.to_byte_array())
	img.resize(R, R, interp)
	return img.get_data().to_float32_array()


## World-space detail noise (single thread: engine noise calls don't parallelize).
func _detail_noise(R: int, spacing: float, map_m: float, seed: int) -> PackedFloat32Array:
	var f := detail_noise_source(seed)
	var half := map_m * 0.5
	var D := PackedFloat32Array()
	D.resize(R * R)
	var k := 0
	for j in R:
		var wz := -half + j * spacing
		for i in R:
			D[k] = f.get_noise_2d(-half + i * spacing, wz)
			k += 1
		if (j & 63) == 0:
			progress = 0.15 + 0.2 * j / R
			if cancelled: return D
	return D


func _combine(H: PackedFloat32Array, D: PackedFloat32Array, AMP: PackedFloat32Array, WATER: PackedFloat32Array, R: int) -> PackedFloat32Array:
	var band := func(j0: int, j1: int) -> Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * R)
		for k in range(j0 * R, j1 * R):
			var h := H[k] + D[k] * AMP[k]
			# Dry land never dips below sea level (no stray ocean puddles inland).
			if WATER[k] < 0.3 and h < 0.4:
				h = 0.4 + (0.4 - h) * 0.05
			out[k - j0 * R] = h
		return [out]
	return Par.rows(R, band, 32)[0]


## Chaikin-smoothed river polylines in world space; water level falls monotonically.
func _smooth_rivers(L: WorldLayout) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for rv in L.rivers:
		var pts: PackedVector2Array = rv.points
		var ws: PackedFloat32Array = rv.widths
		var bs: PackedFloat32Array = rv.beds
		for it in 2:
			var np := PackedVector2Array([pts[0]])
			var nw := PackedFloat32Array([ws[0]])
			var nb := PackedFloat32Array([bs[0]])
			for i in pts.size() - 1:
				np.append(pts[i].lerp(pts[i + 1], 0.25))
				np.append(pts[i].lerp(pts[i + 1], 0.75))
				nw.append(lerpf(ws[i], ws[i + 1], 0.25))
				nw.append(lerpf(ws[i], ws[i + 1], 0.75))
				nb.append(lerpf(bs[i], bs[i + 1], 0.25))
				nb.append(lerpf(bs[i], bs[i + 1], 0.75))
			np.append(pts[pts.size() - 1])
			nw.append(ws[ws.size() - 1])
			nb.append(bs[bs.size() - 1])
			pts = np
			ws = nw
			bs = nb
		var p3 := PackedVector3Array()
		var level := INF
		for i in pts.size():
			level = minf(level, bs[i] - 0.3)
			p3.append(Vector3(pts[i].x, level, pts[i].y))
		out.append({"points": p3, "widths": ws, "frozen": rv.frozen})
	return out


## Lowers terrain into river beds. Each band handles the segments crossing its rows,
## and carving only ever lowers (min), so the result does not depend on order.
func _carve_rivers(r: Result, R: int) -> PackedByteArray:
	var segs := []  # [ax, az, bx, bz, wa, wb, la, lb] in pixel units / metres
	var half := r.map_m * 0.5
	var sp := r.spacing
	for rv in r.rivers:
		var pts: PackedVector3Array = rv.points
		var ws: PackedFloat32Array = rv.widths
		for i in pts.size() - 1:
			segs.append(PackedFloat32Array([(pts[i].x + half) / sp, (pts[i].z + half) / sp,
				(pts[i + 1].x + half) / sp, (pts[i + 1].z + half) / sp,
				ws[i], ws[i + 1], pts[i].y, pts[i + 1].y]))
	var height := r.height
	var band := func(j0: int, j1: int) -> Array:
		var mask := PackedByteArray()
		mask.resize((j1 - j0) * R)
		var hb := height.slice(j0 * R, j1 * R)
		for s: PackedFloat32Array in segs:
			var reach := (maxf(s[4], s[5]) * 0.5 + maxf(8.0, maxf(s[4], s[5]))) / sp
			var z0 := maxi(j0, floori(minf(s[1], s[3]) - reach))
			var z1 := mini(j1 - 1, ceili(maxf(s[1], s[3]) + reach))
			if z0 > z1:
				continue
			var x0 := maxi(0, floori(minf(s[0], s[2]) - reach))
			var x1 := mini(R - 1, ceili(maxf(s[0], s[2]) + reach))
			var dx := s[2] - s[0]
			var dz := s[3] - s[1]
			var len2 := maxf(dx * dx + dz * dz, 0.0001)
			for z in range(z0, z1 + 1):
				for x in range(x0, x1 + 1):
					var t := clampf(((x - s[0]) * dx + (z - s[1]) * dz) / len2, 0.0, 1.0)
					var px := s[0] + dx * t - x
					var pz := s[1] + dz * t - z
					var d := sqrt(px * px + pz * pz) * sp
					var w := lerpf(s[4], s[5], t)
					var hw := w * 0.5
					var bank := maxf(8.0, w)
					if d > hw + bank:
						continue
					var lvl := lerpf(s[6], s[7], t)
					var target: float
					if d < hw:
						var q := d / hw
						target = lvl - clampf(0.8 + w * 0.05, 1.0, 4.0) * (1.0 - q * q)
					else:
						target = lvl + 0.15 + (d - hw) * 0.35
					var o := (z - j0) * R + x
					if target < hb[o]:
						hb[o] = target
					if d < hw + 2.0:
						mask[o] = 1
		return [hb, mask]
	var res := Par.rows(R, band, 32)
	r.height = res[0]
	return res[1]


## Control map + colour map via TextureRules, in parallel row bands.
func _textures(r: Result, L: WorldLayout, p: GenParams, D: PackedFloat32Array, river_mask: PackedByteArray, seed: int) -> Array:
	var R := r.res
	var rules := TextureRules.new(R, r.spacing, r.map_m, seed, p.blend_width, L.n, L.biome, L.temp,
		TextureRules.layout_water(L.ocean, L.lake_id), L.weights)
	var H := r.height
	var band := func(j0: int, j1: int) -> Array:
		var rect := Rect2i(0, j0, R, j1 - j0)
		return rules.compute(rect, padded_rows(H, R, j0 - 1, j1 + 1), D.slice(j0 * R, j1 * R), river_mask.slice(j0 * R, j1 * R))
	return Par.rows(R, band, 32)


## Rows [r0, r1) of an R×R grid with one extra column on each side (edges clamped).
static func padded_rows(H: PackedFloat32Array, R: int, r0: int, r1: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for row in range(r0, r1):
		var rr := clampi(row, 0, R - 1)
		out.append(H[rr * R])
		out.append_array(H.slice(rr * R, rr * R + R))
		out.append(H[rr * R + R - 1])
	return out


## Pixel rect of an R×R grid grown by one pixel on every side (edges clamped).
static func padded_rect(H: PackedFloat32Array, R: int, rect: Rect2i) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var x0 := rect.position.x
	var x1 := rect.end.x
	for y in range(rect.position.y - 1, rect.end.y + 1):
		var yy := clampi(y, 0, R - 1) * R
		out.append(H[yy + clampi(x0 - 1, 0, R - 1)])
		out.append_array(H.slice(yy + x0, yy + x1))
		out.append(H[yy + clampi(x1, 0, R - 1)])
	return out


static func detail_noise_source(seed: int) -> FastNoiseLite:
	return LayoutGenerator.make_noise(seed, 140.0, 4)


## Streets of the city: gravel/cobble in the old town and suburbs, dark stone in modern
## districts. Painted pixels are locked so later automatic re-texturing keeps them.
func _paint_roads(r: Result, city: Dictionary) -> PackedByteArray:
	var R := r.res
	var lock := PackedByteArray()
	lock.resize(R * R)
	if city.is_empty():
		return lock
	var half := r.map_m * 0.5
	var sp := r.spacing
	var segs := []
	for road in city.get("roads", []):
		var pts: Array = road.points
		var tex: int = Tex.ROCK if road.kind == "modern" else Tex.GRAVEL
		for i in pts.size() - 1:
			segs.append([(pts[i][0] + half) / sp, (pts[i][1] + half) / sp, (pts[i + 1][0] + half) / sp,
				(pts[i + 1][1] + half) / sp, float(road.width) * 0.5 / sp, tex])
	var plaza: Array = city.get("plaza", [])
	var control := r.control
	var color := r.color
	var band := func(j0: int, j1: int) -> Array:
		var c := control.slice(j0 * R, j1 * R)
		var col := color.slice(j0 * R * 4, j1 * R * 4)
		var lk := PackedByteArray()
		lk.resize((j1 - j0) * R)
		for s in segs:
			var hw: float = s[4]
			var z0 := maxi(j0, floori(minf(s[1], s[3]) - hw - 1))
			var z1 := mini(j1 - 1, ceili(maxf(s[1], s[3]) + hw + 1))
			if z0 > z1:
				continue
			var x0 := maxi(0, floori(minf(s[0], s[2]) - hw - 1))
			var x1 := mini(R - 1, ceili(maxf(s[0], s[2]) + hw + 1))
			var dx: float = s[2] - s[0]
			var dz: float = s[3] - s[1]
			var len2 := maxf(dx * dx + dz * dz, 0.0001)
			for z in range(z0, z1 + 1):
				for x in range(x0, x1 + 1):
					var t := clampf(((x - s[0]) * dx + (z - s[1]) * dz) / len2, 0.0, 1.0)
					var px: float = s[0] + dx * t - x
					var pz: float = s[1] + dz * t - z
					if px * px + pz * pz > hw * hw:
						continue
					var o := (z - j0) * R + x
					c[o] = int(s[5]) << 27
					lk[o] = 255
					if s[5] == Tex.ROCK:
						col[o * 4] = 150
						col[o * 4 + 1] = 150
						col[o * 4 + 2] = 155
		if plaza.size() == 3:
			var pc := Vector2((plaza[0] + half) / sp, (plaza[1] + half) / sp)
			var pr: float = plaza[2] / sp
			for z in range(maxi(j0, floori(pc.y - pr)), mini(j1, ceili(pc.y + pr))):
				for x in range(maxi(0, floori(pc.x - pr)), mini(R, ceili(pc.x + pr))):
					if Vector2(x, z).distance_to(pc) <= pr:
						var o := (z - j0) * R + x
						c[o] = Tex.GRAVEL << 27
						lk[o] = 255
		return [c, col, lk]
	var res := Par.rows(R, band, 32)
	r.control = res[0]
	r.color = res[1]
	return res[2]


func _water_mask(L: WorldLayout) -> Image:
	var n := L.n
	var data := PackedByteArray()
	data.resize(n * n * 3)
	for k in n * n:
		data[k * 3] = 255 if L.ocean[k] == 1 else 0
		data[k * 3 + 1] = 255 if L.sea_ice[k] == 1 else 0
		data[k * 3 + 2] = 255 if L.lake_id[k] >= 0 else 0
	return Image.create_from_data(n, n, false, Image.FORMAT_RGB8, data)
