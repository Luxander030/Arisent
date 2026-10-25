## Builds a WorldLayout from GenParams in fixed stages. Each stage only reads earlier
## stages and has its own sub-seed, so e.g. changing city size never moves the coast.
## Stage results are cached by the parameters they depend on: dragging the "Rivers"
## slider only reruns hydrology.
class_name LayoutGenerator
extends RefCounted

const B := GenParams.Biome

const STAGE_LAND := 1
const STAGE_CLIMATE := 2
const STAGE_RELIEF := 3
const STAGE_HYDRO := 4

## Parameters each stage depends on (plus everything its upstream stages depend on).
const KEYS_LAND := ["seed", "size_km", "land_water", "islands", "coast_rough", "city", "city_size", "biomes"]
const KEYS_CLIMATE := ["blend_width", "mountains"]
const KEYS_RELIEF := ["mountains", "hilliness", "rifts"]
const KEYS_HYDRO := ["rivers", "lakes"]

## Set from another thread to abandon a run early (checked between stages and rows).
var cancelled := false

var _cache := {}  # stage name -> {key, layout}


func generate(p: GenParams, size: int) -> WorldLayout:
	cancelled = false
	var k1 := "%d|%s" % [size, p.hash_keys(KEYS_LAND)]
	var k2 := k1 + "|" + p.hash_keys(KEYS_CLIMATE)
	var k3 := k2 + "|" + p.hash_keys(KEYS_RELIEF)
	var k4 := k3 + "|" + p.hash_keys(KEYS_HYDRO)
	var L: WorldLayout = _cached("hydro", k4)
	if L:
		return L
	L = _cached("relief", k3)
	if not L:
		L = _cached("climate", k2)
		if not L:
			L = _cached("land", k1)
			if not L:
				L = WorldLayout.new(size, p.map_size_m())
				_timed(L, "landmass", _stage_landmass.bind(L, p))
				if cancelled: return null
				_store("land", k1, L)
			L = L.copy()
			_timed(L, "climate", _stage_climate.bind(L, p))
			if cancelled: return null
			_store("climate", k2, L)
		L = L.copy()
		_timed(L, "relief", _stage_relief.bind(L, p))
		if cancelled: return null
		_store("relief", k3, L)
	L = L.copy()
	_timed(L, "hydrology", _stage_hydrology.bind(L, p))
	if cancelled: return null
	_store("hydro", k4, L)
	return L


func _cached(stage: String, key: String) -> WorldLayout:
	var c: Dictionary = _cache.get(stage, {})
	if c.get("key", "") == key:
		return c.layout
	return null


func _store(stage: String, key: String, L: WorldLayout) -> void:
	_cache[stage] = {"key": key, "layout": L}


func _timed(L: WorldLayout, name: String, f: Callable) -> void:
	var t := Time.get_ticks_usec()
	f.call()
	L.timings[name] = (Time.get_ticks_usec() - t) / 1000.0


static func make_noise(seed_value: int, wavelength_m: float, octaves: int,
		type := FastNoiseLite.TYPE_SIMPLEX_SMOOTH, fractal := FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var f := FastNoiseLite.new()
	f.seed = seed_value & 0x7FFFFFFF
	f.noise_type = type
	f.frequency = 1.0 / wavelength_m
	f.fractal_type = fractal
	f.fractal_octaves = octaves
	return f


static func smooth(e0: float, e1: float, x: float) -> float:
	var t := clampf((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# --- Stage 1: landmass, ocean edges, city reservation ------------------------

func _stage_landmass(L: WorldLayout, p: GenParams) -> void:
	var n := L.n
	var map := L.map_m
	var half := map * 0.5
	var seed := Rng.derive(p.seed_int(), STAGE_LAND)
	var rng := Rng.new(seed)
	var has_ocean := p.has_biome(B.OCEAN)

	# Which map edges face the ocean. Frozen fjords need a northern coast.
	L.ocean_edges.clear()
	if has_ocean:
		var order: Array = [0, 1, 2, 3]
		rng.shuffle(order)
		if p.has_biome(B.FJORDS):
			order.erase(0)
			order.push_front(0)
		var count := clampi(1 + roundi(p.land_water * 2.0 + rng.range_f(-0.6, 0.6)), 1, 3)
		for e in count:
			L.ocean_edges.append(order[e])
	var e_n := 0 in L.ocean_edges
	var e_e := 1 in L.ocean_edges
	var e_s := 2 in L.ocean_edges
	var e_w := 3 in L.ocean_edges

	var cont := make_noise(seed + 1, map * 0.45, 4)
	var warp := make_noise(seed + 2, map * 0.22, 3)
	var detail := make_noise(seed + 3, map * 0.035, 3)
	var isl := make_noise(seed + 4, map * 0.08, 3)
	var warp_amp := map * lerpf(0.015, 0.11, p.coast_rough)
	var detail_amp := lerpf(0.0, 0.14, p.coast_rough)
	var coast_depth := lerpf(0.16, 0.42, p.land_water)
	var threshold := lerpf(0.2, 0.5, p.land_water) if has_ocean else -1.0
	var isl_amt := p.islands * 1.8

	var cell := L.cell_m
	var band := func(j0: int, j1: int) -> Array:
		var out := PackedFloat32Array()
		out.resize((j1 - j0) * n)
		for j in range(j0, j1):
			var wz := -half + (j + 0.5) * cell
			for i in n:
				var wx := -half + (i + 0.5) * cell
				var dx := warp.get_noise_2d(wx, wz) * warp_amp
				var dz := warp.get_noise_2d(wx + 7919.0, wz - 6007.0) * warp_amp
				var su := (wx + dx) / map + 0.5
				var sv := (wz + dz) / map + 0.5
				var f := 1.0
				if e_n: f = minf(f, smooth(0.0, coast_depth, sv))
				if e_s: f = minf(f, smooth(0.0, coast_depth, 1.0 - sv))
				if e_w: f = minf(f, smooth(0.0, coast_depth, su))
				if e_e: f = minf(f, smooth(0.0, coast_depth, 1.0 - su))
				var c := cont.get_noise_2d(wx + dx, wz + dz)
				var e := (0.62 + 0.5 * c) * f + detail.get_noise_2d(wx + dx, wz + dz) * detail_amp
				if isl_amt > 0.0 and has_ocean:
					e += isl_amt * maxf(0.0, isl.get_noise_2d(wx, wz) - 0.12) * (1.0 - f)
				out[(j - j0) * n + i] = e - threshold
		return [out]
	L.land = Par.rows(n, band)[0]
	if cancelled: return

	_reserve_city(L, p, rng)

	# Ocean = water connected to the map border (inland low ground becomes lakes later).
	L.ocean = PackedByteArray()
	L.ocean.resize(n * n)
	if has_ocean:
		var queue := PackedInt32Array()
		for k in n:
			for c in [k, (n - 1) * n + k, k * n, k * n + n - 1]:
				if L.land[c] <= 0.0 and L.ocean[c] == 0:
					L.ocean[c] = 1
					queue.append(c)
		var low := PackedByteArray()
		low.resize(n * n)
		for k in n * n:
			low[k] = 1 if L.land[k] <= 0.0 else 0
		_flood(L.ocean, queue, n, low)
	_update_coast_dist(L)


func _reserve_city(L: WorldLayout, p: GenParams, rng: Rng) -> void:
	L.has_city = p.city and p.any_land_biome()
	if not L.has_city:
		return
	var n := L.n
	var map := L.map_m
	L.city_radius = 0.5 * lerpf(0.12, 0.35, p.city_size) * map
	var margin := 0.15 * map + L.city_radius
	var lim := map * 0.5 - margin
	var best := -INF
	for t in 40:
		var c := Vector2(rng.range_f(-lim, lim), rng.range_f(-lim, lim))
		var s := 0.0
		for k in 16:
			var a := TAU * k / 16.0
			for rr in [0.0, 0.5, 1.0]:
				var q: Vector2 = c + Vector2(cos(a), sin(a)) * L.city_radius * float(rr)
				s += clampf(L.sample(L.land, q), -0.3, 0.25)
		# Prefer temperate latitudes, avoid the far north.
		var v := c.y / map + 0.5
		s -= absf(v - 0.55) * 3.0
		if s > best:
			best = s
			L.city_center = c
	# Force solid land under and around the city.
	var r := L.city_radius
	var bb := city_cell_box(L, r * 1.8)
	for j in range(bb.position.y, bb.end.y):
		for i in range(bb.position.x, bb.end.x):
			var d := L.cell_center(i, j).distance_to(L.city_center)
			if d < r * 1.8:
				var w := 1.0 - smooth(r * 1.25, r * 1.8, d)
				var k := j * n + i
				L.land[k] = maxf(L.land[k], 0.22 * w)


## Breadth-first fill of mask from queue through cells where passable == 1.
static func _flood(mask: PackedByteArray, queue: PackedInt32Array, n: int, passable: PackedByteArray) -> void:
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var i := c % n
		if i > 0 and mask[c - 1] == 0 and passable[c - 1] == 1:
			mask[c - 1] = 1
			queue.append(c - 1)
		if i < n - 1 and mask[c + 1] == 0 and passable[c + 1] == 1:
			mask[c + 1] = 1
			queue.append(c + 1)
		if c >= n and mask[c - n] == 0 and passable[c - n] == 1:
			mask[c - n] = 1
			queue.append(c - n)
		if c < n * (n - 1) and mask[c + n] == 0 and passable[c + n] == 1:
			mask[c + n] = 1
			queue.append(c + n)


func _update_coast_dist(L: WorldLayout) -> void:
	var any := false
	for v in L.ocean:
		if v == 1:
			any = true
			break
	if not any:
		L.coast_dist = PackedFloat32Array()
		L.coast_dist.resize(L.n * L.n)
		L.coast_dist.fill(1.0e9)
		return
	L.coast_dist = WorldLayout.distance_field(L.ocean, L.n)
	for k in L.coast_dist.size():
		L.coast_dist[k] *= L.cell_m


# --- Stage 2: climate + biomes -----------------------------------------------

## Climate niche per biome: [temperature centre, moisture centre, temp spread, moisture spread]
const NICHE := {
	B.FJORDS: [0.03, 0.5, 0.13, 0.9],
	B.NORTH_MOUNTAINS: [0.14, 0.5, 0.12, 0.9],
	B.TEMPERATE_FOREST: [0.45, 0.68, 0.17, 0.25],
	B.GRASSLAND: [0.52, 0.32, 0.17, 0.25],
	B.TROPICAL: [0.9, 0.75, 0.15, 0.28],
	B.DESERT: [0.88, 0.12, 0.15, 0.22],
	B.DESERT_HIGHLANDS: [0.75, 0.25, 0.12, 0.2],  # only used when the desert itself is off
}

func _stage_climate(L: WorldLayout, p: GenParams) -> void:
	var n := L.n
	var map := L.map_m
	var half := map * 0.5
	var seed := Rng.derive(p.seed_int(), STAGE_CLIMATE)
	var tn := make_noise(seed + 1, map * 0.3, 3)
	var mn := make_noise(seed + 2, map * 0.25, 4)
	var has_ocean := not L.ocean_edges.is_empty()

	var cell := L.cell_m
	var coast := L.coast_dist
	var clim_band := func(j0: int, j1: int) -> Array:
		var t_out := PackedFloat32Array()
		var m_out := PackedFloat32Array()
		t_out.resize((j1 - j0) * n)
		m_out.resize((j1 - j0) * n)
		for j in range(j0, j1):
			var wz := -half + (j + 0.5) * cell
			var lat := (j + 0.5) / n
			for i in n:
				var wx := -half + (i + 0.5) * cell
				var o := (j - j0) * n + i
				t_out[o] = clampf(lat + tn.get_noise_2d(wx, wz) * 0.14, 0.0, 1.0)
				var m := 0.5 + 0.5 * mn.get_noise_2d(wx, wz)
				var prox := exp(-coast[j * n + i] / (0.22 * map)) if has_ocean else 0.35
				m_out[o] = 0.6 * m + 0.4 * prox
		return [t_out, m_out]
	var tm := Par.rows(n, clim_band)
	L.temp = tm[0]
	L.moist = tm[1]
	var mmin := INF
	var mmax := -INF
	for k in n * n:
		if L.ocean[k] == 0:
			mmin = minf(mmin, L.moist[k])
			mmax = maxf(mmax, L.moist[k])
	# Stretch moisture over land to 0..1 so every climate niche exists on every map.
	var span := maxf(mmax - mmin, 0.001)
	for k in n * n:
		L.moist[k] = clampf((L.moist[k] - mmin) / span, 0.0, 1.0)

	# Score each enabled land biome per cell; dominant = best score; weights = softmax.
	var cands: Array[int] = []
	for b in [B.FJORDS, B.NORTH_MOUNTAINS, B.TEMPERATE_FOREST, B.GRASSLAND, B.TROPICAL, B.DESERT]:
		if p.has_biome(b):
			cands.append(b)
	var highlands_scored := p.has_biome(B.DESERT_HIGHLANDS) and not p.has_biome(B.DESERT)
	if highlands_scored:
		cands.append(B.DESERT_HIGHLANDS)
	if cands.is_empty():
		cands.append(B.GRASSLAND)
	var bnoise := {}
	for b in cands:
		bnoise[b] = make_noise(seed + 10 + b, map * 0.18, 3)
	var sharp := lerpf(14.0, 2.5, p.blend_width)
	var mount_spread := 0.09 + 0.08 * p.mountains

	# Niche parameters flattened per candidate (no Variant lookups in the hot loop).
	var nc_t := PackedFloat32Array()
	var nc_m := PackedFloat32Array()
	var nc_st := PackedFloat32Array()
	var nc_sm := PackedFloat32Array()
	var noises: Array[FastNoiseLite] = []
	for b in cands:
		var nc: Array = NICHE[b]
		nc_t.append(nc[0])
		nc_m.append(nc[1])
		nc_st.append(mount_spread if b == B.NORTH_MOUNTAINS else float(nc[2]))
		nc_sm.append(nc[3])
		noises.append(bnoise[b])
	var nc_count := cands.size()
	var temp := L.temp
	var moist := L.moist
	var ocean := L.ocean
	var biome_band := func(j0: int, j1: int) -> Array:
		var cnt := (j1 - j0) * n
		var out := []
		for b in GenParams.BIOME_COUNT:
			var w := PackedFloat32Array()
			w.resize(cnt)
			out.append(w)
		var dom := PackedByteArray()
		dom.resize(cnt)
		var scores := PackedFloat32Array()
		scores.resize(nc_count)
		var w_ocean: PackedFloat32Array = out[B.OCEAN]
		for j in range(j0, j1):
			var wz := -half + (j + 0.5) * cell
			for i in n:
				var k := j * n + i
				var o := (j - j0) * n + i
				if ocean[k] == 1:
					w_ocean[o] = 1.0
					dom[o] = B.OCEAN
					continue
				var wx := -half + (i + 0.5) * cell
				var t := temp[k]
				var m := moist[k]
				var near := exp(-coast[k] / (0.07 * map)) if has_ocean else 0.0
				var best := -INF
				var best_ci := 0
				for ci in nc_count:
					var dt := (t - nc_t[ci]) / nc_st[ci]
					var dm := (m - nc_m[ci]) / nc_sm[ci]
					var s := -(dt * dt + dm * dm) + 1.1 * noises[ci].get_noise_2d(wx, wz)
					var b: int = cands[ci]
					if b == B.FJORDS: s += 1.6 * near - 0.5
					elif b == B.NORTH_MOUNTAINS or b == B.DESERT: s -= 0.8 * near
					elif b == B.TROPICAL: s += 0.5 * near
					scores[ci] = s
					if s > best:
						best = s
						best_ci = ci
				dom[o] = cands[best_ci]
				var total := 0.0
				for ci in nc_count:
					var w := exp(sharp * (scores[ci] - best))
					scores[ci] = w
					total += w
				for ci in nc_count:
					var wa: PackedFloat32Array = out[cands[ci]]
					wa[o] = scores[ci] / total
					out[cands[ci]] = wa
		w_ocean = out[B.OCEAN]
		out.append(dom)
		return out
	var res := Par.rows(n, biome_band)
	L.weights.clear()
	for b in GenParams.BIOME_COUNT:
		L.weights.append(res[b])
	L.biome = res[GenParams.BIOME_COUNT]
	if cancelled: return

	if p.has_biome(B.DESERT_HIGHLANDS) and p.has_biome(B.DESERT):
		_add_desert_highlands(L, p, Rng.new(seed + 99))


## Desert Highlands = a mountain wall around the desert, broken by 1-2 passes.
func _add_desert_highlands(L: WorldLayout, p: GenParams, rng: Rng) -> void:
	var n := L.n
	var desert := PackedByteArray()
	desert.resize(n * n)
	var cx := 0.0
	var cz := 0.0
	var count := 0
	for k in n * n:
		if L.biome[k] == B.DESERT:
			desert[k] = 1
			cx += k % n
			cz += k / n
			count += 1
	if count == 0:
		return
	cx /= count
	cz /= count
	var dist := WorldLayout.distance_field(desert, n)
	var band := maxf(0.12 * L.map_m, 300.0) / L.cell_m
	var gaps: Array[float] = []
	for g in rng.range_i(1, 2):
		gaps.append(rng.range_f(-PI, PI))
	for k in n * n:
		var d := dist[k]
		if d <= 0.0 or d >= band or L.ocean[k] == 1:
			continue
		var x := d / band
		var hw := 1.0 - (2.0 * x - 1.0) * (2.0 * x - 1.0)
		var a := atan2(k / n - cz, k % n - cx)
		for g in gaps:
			var da := absf(wrapf(a - g, -PI, PI))
			hw *= smooth(0.12, 0.3, da)
		if L.has_city:
			var cd := L.cell_center(k % n, k / n).distance_to(L.city_center)
			hw *= smooth(L.city_radius * 1.2, L.city_radius * 1.8, cd)
		if hw <= 0.0:
			continue
		for b in GenParams.BIOME_COUNT:
			L.weights[b][k] *= (1.0 - hw)
		L.weights[B.DESERT_HIGHLANDS][k] = hw
		if hw > 0.5:
			L.biome[k] = B.DESERT_HIGHLANDS


# --- Stage 3: relief (height in metres) --------------------------------------

func _stage_relief(L: WorldLayout, p: GenParams) -> void:
	var n := L.n
	var map := L.map_m
	var half := map * 0.5
	var seed := Rng.derive(p.seed_int(), STAGE_RELIEF)
	var hills := make_noise(seed + 1, 700.0, 4)
	var hills2 := make_noise(seed + 2, 1800.0, 3)
	var ridge := make_noise(seed + 3, 1600.0, 5, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, FastNoiseLite.FRACTAL_RIDGED)
	var dunes := make_noise(seed + 4, 260.0, 3)
	var mesa := make_noise(seed + 5, 1500.0, 2)
	var trough := make_noise(seed + 6, 1400.0, 3, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, FastNoiseLite.FRACTAL_RIDGED)
	var rift_n := make_noise(seed + 7, 1100.0, 3)
	var rift_mask := make_noise(seed + 8, 2200.0, 2)
	var rift_warp := make_noise(seed + 9, 600.0, 2)
	trough.domain_warp_enabled = false

	var hill_amp := 0.4 + 1.6 * p.hilliness
	# Relief scales with map size: a 2 km map can't hold 900 m peaks without walls.
	var hs := clampf(map / 4096.0, 0.5, 1.5)
	var mtn := p.mountains
	var rift_on := p.rifts > 0.01
	var rift_w := 0.02 + 0.03 * p.rifts
	var rift_cut := lerpf(0.55, -0.3, p.rifts)
	var rift_depth := 35.0 + 90.0 * p.rifts

	# Distance from land, for ocean depth.
	var landmask := PackedByteArray()
	landmask.resize(n * n)
	for k in n * n:
		landmask[k] = 0 if L.ocean[k] == 1 else 1
	var sea_dist := WorldLayout.distance_field(landmask, n)

	var w := L.weights
	var cell := L.cell_m
	var has_ocean := L.ocean.has(1)
	var slope_reach := 0.35 * map
	var ocean := L.ocean
	var coast := L.coast_dist
	var land := L.land
	var relief_band := func(j0: int, j1: int) -> Array:
		var cnt := (j1 - j0) * n
		var h_out := PackedFloat32Array()
		h_out.resize(cnt)
		var dry_out := PackedByteArray()
		dry_out.resize(cnt)
		var rift_out := PackedFloat32Array()
		rift_out.resize(cnt)
		for j in range(j0, j1):
			var wz := -half + (j + 0.5) * cell
			for i in n:
				var wx := -half + (i + 0.5) * cell
				var k := j * n + i
				if ocean[k] == 1:
					var depth := smooth(0.0, 0.18 * map, sea_dist[k] * cell)
					h_out[k - j0 * n] = -3.0 - 90.0 * depth + hills.get_noise_2d(wx, wz) * 6.0
					continue
				var cd := coast[k]
				var ramp := smooth(0.0, 90.0 + 0.035 * map, cd)
				var hn := hills.get_noise_2d(wx, wz)
				var hn2 := hills2.get_noise_2d(wx, wz)
				var r := (ridge.get_noise_2d(wx, wz) + 1.0) * 0.5
				# Continental slope: land rises gently away from the sea (or the map edge on
				# landlocked maps), so water drains instead of pooling in huge flat basins.
				var inland := minf(cd, slope_reach) if has_ocean else minf(float(mini(mini(i, n - 1 - i), mini(j, n - 1 - j))) * cell, slope_reach)
				var base := 2.0 + clampf(land[k], -0.4, 1.0) * 30.0 + inland * 0.022
				var h := 0.0
				var wb := w[B.GRASSLAND][k]
				if wb > 0.0:
					h += wb * (hn * 10.0 + hn2 * 8.0) * hill_amp
				wb = w[B.TEMPERATE_FOREST][k]
				if wb > 0.0:
					h += wb * ((hn * 22.0 + hn2 * 20.0) * hill_amp + maxf(0.0, r - 0.6) * mtn * 400.0 * hs)
				wb = w[B.TROPICAL][k]
				if wb > 0.0:
					h += wb * ((hn * 30.0 + maxf(0.0, hn2) * 70.0) * hill_amp + maxf(0.0, r - 0.65) * mtn * 320.0 * hs)
				wb = w[B.DESERT][k]
				if wb > 0.0:
					var dn := absf(dunes.get_noise_2d(wx, wz))
					# Mesas: broad flat-topped tables (wide enough to survive erosion).
					var me := smooth(0.18, 0.24, mesa.get_noise_2d(wx, wz)) * 32.0 * (0.5 + hill_amp * 0.3) * hs
					h += wb * (dn * 12.0 + me)
				wb = w[B.DESERT_HIGHLANDS][k]
				if wb > 0.0:
					var hh := 90.0 + r * (220.0 + 260.0 * mtn)
					var t := hh / 45.0
					var ft := floorf(t)
					hh = (ft + smooth(0.75, 1.0, t - ft)) * 45.0
					h += wb * hh
				wb = w[B.NORTH_MOUNTAINS][k]
				if wb > 0.0:
					h += wb * (80.0 + pow(r, 1.8) * (300.0 + 650.0 * mtn) + hn * 30.0) * hs
				wb = w[B.FJORDS][k]
				if wb > 0.0:
					var fh := (40.0 + pow(r, 1.5) * (180.0 + 300.0 * mtn)) * hs
					# Glacial troughs: deep U-valleys that dip below sea level toward the coast.
					var tr := smooth(0.72, 0.92, (trough.get_noise_2d(wx, wz) + 1.0) * 0.5)
					var coastal := exp(-cd / (0.12 * map))
					fh = lerpf(fh, -45.0 * coastal + 12.0 * (1.0 - coastal), tr)
					h += wb * fh
					ramp = maxf(ramp, 0.7 * wb)
				h = base + h * ramp
				# Rifts: narrow warped cracks on land, kept away from the coast.
				if rift_on and cd > 250.0:
					var rw := rift_warp.get_noise_2d(wx, wz) * 300.0
					var rv := absf(rift_n.get_noise_2d(wx + rw, wz - rw))
					var crack := 1.0 - smooth(0.0, rift_w, rv)
					var dm := smooth(rift_cut, rift_cut + 0.15, rift_mask.get_noise_2d(wx, wz))
					var s := crack * dm * smooth(250.0, 500.0, cd)
					if s > 0.0:
						h -= rift_depth * s * (0.6 + 0.4 * absf(hn2))
						rift_out[k - j0 * n] = s
						if s > 0.3:
							dry_out[k - j0 * n] = 1
				if w[B.DESERT][k] + w[B.DESERT_HIGHLANDS][k] > 0.5:
					dry_out[k - j0 * n] = 1
				h_out[k - j0 * n] = h
		return [h_out, dry_out, rift_out]
	var res := Par.rows(n, relief_band)
	L.height = res[0]
	L.dry = res[1]
	L.rift = res[2]
	if cancelled: return

	if L.has_city:
		_flatten_city(L)
	_thermal_erosion(L, 10)
	# Fjord troughs and coastal lowlands below sea level that touch the ocean become ocean.
	var queue := PackedInt32Array()
	for k in n * n:
		if L.ocean[k] == 1:
			queue.append(k)
	var below := PackedByteArray()
	below.resize(n * n)
	for k in n * n:
		below[k] = 1 if L.height[k] < 0.0 else 0
	_flood(L.ocean, queue, n, below)
	_update_coast_dist(L)
	for k in n * n:
		if L.ocean[k] == 1 and L.biome[k] != B.OCEAN:
			for b in GenParams.BIOME_COUNT:
				L.weights[b][k] = 0.0
			L.weights[B.OCEAN][k] = 1.0
			L.biome[k] = B.OCEAN


## Cell rectangle covering a disc of the given radius around the city centre.
static func city_cell_box(L: WorldLayout, radius: float) -> Rect2i:
	var a := L.world_to_cell(L.city_center - Vector2(radius, radius))
	var b := L.world_to_cell(L.city_center + Vector2(radius, radius))
	return Rect2i(a, b - a + Vector2i.ONE)


func _flatten_city(L: WorldLayout) -> void:
	var n := L.n
	var r := L.city_radius
	var total := 0.0
	var cnt := 0
	var bb := city_cell_box(L, r * 1.7)
	for j in range(bb.position.y, bb.end.y):
		for i in range(bb.position.x, bb.end.x):
			if L.cell_center(i, j).distance_to(L.city_center) < r:
				total += L.height[j * n + i]
				cnt += 1
	L.city_height = clampf(total / maxi(cnt, 1), 6.0, 140.0)
	for j in range(bb.position.y, bb.end.y):
		for i in range(bb.position.x, bb.end.x):
			var d := L.cell_center(i, j).distance_to(L.city_center)
			if d < r * 1.7:
				var k := j * n + i
				var w := 1.0 - smooth(r, r * 1.7, d)
				L.height[k] = lerpf(L.height[k], L.city_height, w)
				L.dry[k] = 1 if d < r else L.dry[k]


## Moves material down slopes steeper than the talus angle (removes impossible cliffs).
func _thermal_erosion(L: WorldLayout, iterations: int) -> void:
	var n := L.n
	var talus := tan(deg_to_rad(38.0)) * L.cell_m
	var h := L.height
	for it in iterations:
		for j in range(1, n - 1):
			for i in range(1, n - 1):
				var k := j * n + i
				var hk := h[k]
				var d := hk - h[k - 1]
				if d > talus:
					var m := (d - talus) * 0.25
					hk -= m
					h[k - 1] += m
				d = hk - h[k + 1]
				if d > talus:
					var m := (d - talus) * 0.25
					hk -= m
					h[k + 1] += m
				d = hk - h[k - n]
				if d > talus:
					var m := (d - talus) * 0.25
					hk -= m
					h[k - n] += m
				d = hk - h[k + n]
				if d > talus:
					var m := (d - talus) * 0.25
					hk -= m
					h[k + n] += m
				h[k] = hk


# --- Stage 4: hydrology ------------------------------------------------------

func _stage_hydrology(L: WorldLayout, p: GenParams) -> void:
	var n := L.n
	var nn := n * n
	var Q := 16.0  # height quantum: 1/16 m
	var hq := PackedInt32Array()
	hq.resize(nn)
	var lo := 1 << 30
	var hi := -(1 << 30)
	for k in nn:
		var v := roundi(L.height[k] * Q)
		hq[k] = v
		lo = mini(lo, v)
		hi = maxi(hi, v)
	var levels := hi - lo + 1

	# Priority-Flood with a monotone FIFO bucket queue (heights are integers), 8 neighbours.
	# receiver[] = the cell that reached this one: a drainage tree with no pits. FIFO order
	# makes flats drain outward from their outlet instead of in parallel stripes.
	var head := PackedInt32Array()
	head.resize(levels)
	head.fill(-1)
	var tail := PackedInt32Array()
	tail.resize(levels)
	tail.fill(-1)
	var nxt := PackedInt32Array()
	nxt.resize(nn)
	nxt.fill(-1)
	var fill := PackedInt32Array()
	fill.resize(nn)
	var seen := PackedByteArray()
	seen.resize(nn)
	var recv := PackedInt32Array()
	recv.resize(nn)
	recv.fill(-1)
	var order := PackedInt32Array()
	order.resize(nn)
	var oc := 0
	var any_ocean := L.ocean.has(1)
	for k in nn:
		var i := k % n
		var j := k / n
		# Outlets: the ocean, and every map border (water can always leave the map).
		var seed_cell := (any_ocean and L.ocean[k] == 1) or i == 0 or j == 0 or i == n - 1 or j == n - 1
		if seed_cell:
			seen[k] = 1
			fill[k] = hq[k]
			var lv := hq[k] - lo
			if tail[lv] == -1:
				head[lv] = k
			else:
				nxt[tail[lv]] = k
			tail[lv] = k
	var cur := 0
	var offs := PackedInt32Array([-1, 1, -n, n, -n - 1, -n + 1, n - 1, n + 1])
	while cur < levels:
		var c := head[cur]
		if c == -1:
			cur += 1
			continue
		head[cur] = nxt[c]
		if head[cur] == -1:
			tail[cur] = -1
		order[oc] = c
		oc += 1
		var ci := c % n
		var fc := fill[c]
		for o in 8:
			var nb := c + offs[o]
			if nb < 0 or nb >= nn or seen[nb] == 1 or absi(nb % n - ci) > 1:
				continue
			seen[nb] = 1
			recv[nb] = c
			var f := maxi(hq[nb], fc)
			fill[nb] = f
			var lv := f - lo
			nxt[nb] = -1
			if tail[lv] == -1:
				head[lv] = nb
			else:
				nxt[tail[lv]] = nb
			tail[lv] = nb
		if (oc & 65535) == 0 and cancelled:
			return
	L.receiver = recv

	# Flow accumulation: walk the flood order backwards (upstream before downstream).
	L.flow = PackedFloat32Array()
	L.flow.resize(nn)
	for k in nn:
		L.flow[k] = (0.25 + L.moist[k]) * (0.3 if L.dry[k] == 1 else 1.0)
	for idx in range(oc - 1, -1, -1):
		var c := order[idx]
		var r := recv[c]
		if r >= 0:
			L.flow[r] += L.flow[c]
	var river_thr := river_threshold(p, n)

	# Depressions -> lakes, dry basins (desert, rifts) or filled meadows.
	# A wet depression becomes a lake if it is big enough, or if a river runs into it.
	L.lake_id = PackedInt32Array()
	L.lake_id.resize(nn)
	L.lake_id.fill(-1)
	L.lakes.clear()
	var depression := PackedByteArray()
	depression.resize(nn)
	var min_area := lerpf(600000.0, 6000.0, p.lakes)
	var min_moist := lerpf(0.6, 0.2, p.lakes)
	var max_area := lerpf(0.004, 0.04, p.lakes) * L.map_m * L.map_m
	var visited := PackedByteArray()
	visited.resize(nn)
	for k in nn:
		if visited[k] == 1 or L.ocean[k] == 1 or fill[k] <= hq[k]:
			continue
		var comp := PackedInt32Array([k])
		visited[k] = 1
		var lvl := fill[k]
		var h_ := 0
		var moist_sum := 0.0
		var dry_cnt := 0
		var max_depth := 0
		var max_flow := 0.0
		var cx := 0.0
		var cz := 0.0
		while h_ < comp.size():
			var c := comp[h_]
			h_ += 1
			moist_sum += L.moist[c]
			dry_cnt += L.dry[c]
			max_depth = maxi(max_depth, lvl - hq[c])
			max_flow = maxf(max_flow, L.flow[c])
			cx += c % n
			cz += c / n
			var ci := c % n
			for o in 4:
				var nb := c + offs[o]
				if nb < 0 or nb >= nn or absi(nb % n - ci) > 1:
					continue
				if visited[nb] == 0 and L.ocean[nb] == 0 and fill[nb] == lvl and fill[nb] > hq[nb]:
					visited[nb] = 1
					comp.append(nb)
		var cnt := comp.size()
		var area := cnt * L.cell_m * L.cell_m
		var wet := dry_cnt * 2 < cnt
		var deep_enough := max_depth >= int(Q)
		var big := area >= min_area and moist_sum / cnt >= min_moist
		var fed := river_thr > 0.0 and max_flow >= river_thr
		var not_huge := area <= max_area
		if p.lakes > 0.02 and wet and deep_enough and not_huge and (big or fed):
			var id := L.lakes.size()
			var ctr := L.cell_center(roundi(cx / cnt), roundi(cz / cnt))
			var t := L.temp[comp[0]]
			L.lakes.append({"id": id, "level": lvl / Q, "cells": cnt, "frozen": t < 0.2, "center": ctr})
			for c in comp:
				L.lake_id[c] = id
		elif wet:
			# Wet hollow without a lake: fill it flat (a meadow) so nothing floods later.
			for c in comp:
				L.height[c] = lvl / Q
		else:
			for c in comp:
				depression[c] = 1

	_trace_rivers(L, p, river_thr, depression)

	L.sea_ice = PackedByteArray()
	L.sea_ice.resize(nn)
	for k in nn:
		if L.ocean[k] == 1 and L.temp[k] < 0.15:
			L.sea_ice[k] = 1


## Rain (in cells) that must drain through a cell before it carries a river; 0 = no rivers.
static func river_threshold(p: GenParams, n: int) -> float:
	if p.rivers < 0.02:
		return 0.0
	return lerpf(0.012, 0.0008, p.rivers) * n * n * 0.6


## Dry depressions are sinks: rivers that reach them end there.
func _trace_rivers(L: WorldLayout, p: GenParams, thr: float, depression: PackedByteArray) -> void:
	var n := L.n
	var nn := n * n
	L.river = PackedByteArray()
	L.river.resize(nn)
	L.rivers.clear()
	if thr <= 0.0:
		return
	for k in nn:
		if L.flow[k] >= thr and L.ocean[k] == 0 and L.lake_id[k] < 0 and depression[k] == 0:
			L.river[k] = 1
	var upstream := PackedInt32Array()
	upstream.resize(nn)
	for k in nn:
		if L.river[k] == 1 and L.receiver[k] >= 0 and L.river[L.receiver[k]] == 1:
			upstream[L.receiver[k]] += 1
	var done := PackedByteArray()
	done.resize(nn)
	for k in nn:
		if L.river[k] == 0 or upstream[k] != 0:
			continue
		var pts := PackedVector2Array()
		var widths := PackedFloat32Array()
		var beds := PackedFloat32Array()
		var c := k
		var bed := INF
		var frozen := L.temp[k] < 0.2
		while c >= 0:
			var ctr := L.cell_center(c % n, c / n)
			bed = minf(bed, L.height[c])
			pts.append(ctr)
			widths.append(clampf(3.0 + 5.0 * sqrt(L.flow[c] / thr), 4.0, 70.0))
			beds.append(bed)
			if done[c] == 1 or L.ocean[c] == 1 or L.lake_id[c] >= 0 or L.river[c] == 0:
				break
			done[c] = 1
			c = L.receiver[c]
			if c >= 0 and (L.ocean[c] == 1 or L.lake_id[c] >= 0):
				# Run one step into the sea/lake so the mouth is covered.
				pts.append(L.cell_center(c % n, c / n))
				widths.append(widths[widths.size() - 1])
				beds.append(minf(bed, L.height[c]))
				break
		if pts.size() >= 3:
			L.rivers.append({"points": pts, "widths": widths, "beds": beds, "frozen": frozen})
