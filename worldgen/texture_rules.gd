## Ground texture rules: which texture goes where (biome, slope, altitude, shores, river
## beds) and the colour tint. Used for the whole map at generation time and again for
## small rectangles after sculpting, so a freshly raised cliff turns to rock.
class_name TextureRules
extends RefCounted

const B := GenParams.Biome
const T := TerrainBuilder.Tex

var R: int                 ## full-res samples per side
var spacing: float
var map_m: float
var seed: int
var jitter: float          ## biome border dithering, in layout cells
var n: int                 ## layout size
var biome: PackedByteArray
var temp: PackedFloat32Array
var water: PackedFloat32Array  ## layout: 1 = ocean or lake
var weights: Array             ## per biome PackedFloat32Array (0..1), layout res
var noise: FastNoiseLite       ## same field as TerrainBuilder detail noise

var _base := PackedInt32Array()
var _patch := PackedInt32Array()
var _tint := PackedColorArray()


func _init(res: int, spacing_m: float, map_size_m: float, world_seed: int, blend_width: float,
		layout_n: int, layout_biome: PackedByteArray, layout_temp: PackedFloat32Array, layout_water: PackedFloat32Array,
		layout_weights: Array) -> void:
	R = res
	spacing = spacing_m
	map_m = map_size_m
	seed = world_seed
	jitter = lerpf(0.6, 2.6, blend_width)
	n = layout_n
	biome = layout_biome
	temp = layout_temp
	water = layout_water
	weights = layout_weights
	noise = TerrainBuilder.detail_noise_source(world_seed)
	for b in GenParams.BIOME_COUNT:
		var g: Array = TerrainBuilder.BIOME_GROUND[b]
		_base.append(g[0])
		_patch.append(g[1])
		_tint.append(g[2])


## Rules for the pixel rectangle `rect`.
## H: heights for rect grown by 1 pixel on every side ((w+2)*(h+2), row-major).
## D: detail noise for rect (w*h) — pass an empty array to sample it here.
## river: 1 where a river bed is (w*h) — or empty to keep existing gravel beds from `old_ctrl`.
## lock: optional w*h mask; locked pixels keep `old_ctrl`.
## Returns [control PackedInt32Array, colour PackedByteArray RGBA8].
func compute(rect: Rect2i, H: PackedFloat32Array, D: PackedFloat32Array, river: PackedByteArray,
		old_ctrl: PackedInt32Array = PackedInt32Array(), lock: PackedByteArray = PackedByteArray()) -> Array:
	var w := rect.size.x
	var h := rect.size.y
	var hw := w + 2
	var half := map_m * 0.5
	var scale := float(n) / R
	if D.is_empty():
		D.resize(w * h)
		for y in h:
			var wz := -half + (rect.position.y + y) * spacing
			for x in w:
				D[y * w + x] = noise.get_noise_2d(-half + (rect.position.x + x) * spacing, wz)
	var ctrl := PackedInt32Array()
	ctrl.resize(w * h)
	var col := PackedByteArray()
	col.resize(w * h * 4)
	var use_old := old_ctrl.size() == w * h
	var use_lock := lock.size() == w * h
	var use_river := river.size() == w * h
	for y in h:
		var j := rect.position.y + y
		for x in w:
			var i := rect.position.x + x
			var o := y * w + x
			if use_lock and lock[o] != 0 and use_old:
				ctrl[o] = old_ctrl[o]
				col[o * 4] = 255
				col[o * 4 + 1] = 255
				col[o * 4 + 2] = 255
				col[o * 4 + 3] = 128
				continue
			var d := D[o]
			# Smoothly warped sample point, then a bilinear vote of the 4 surrounding
			# layout cells: main biome = base texture, runner-up = overlay (soft borders).
			var fx := clampf(i * scale - 0.5 + d * jitter * 3.0, 0.0, n - 1.001)
			var fz := clampf(j * scale - 0.5 - d * jitter * 3.0, 0.0, n - 1.001)
			var x0 := int(fx)
			var z0 := int(fz)
			var tx := fx - x0
			var tz := fz - z0
			var c00 := z0 * n + x0
			var b00 := biome[c00]
			var b10 := biome[c00 + 1]
			var b01 := biome[c00 + n]
			var b11 := biome[c00 + n + 1]
			var w00 := (1.0 - tx) * (1.0 - tz)
			var w10 := tx * (1.0 - tz)
			var w01 := (1.0 - tx) * tz
			var w11 := tx * tz
			# Total weight of b00's biome vs the strongest other biome.
			var b := b00
			var wb := w00 + (w10 if b10 == b00 else 0.0) + (w01 if b01 == b00 else 0.0) + (w11 if b11 == b00 else 0.0)
			# Strongest other biome among the remaining corners (unrolled: hot loop).
			var b2 := b00
			var wb2 := 0.0
			if b10 != b00:
				b2 = b10
				wb2 = w10 + (w01 if b01 == b10 else 0.0) + (w11 if b11 == b10 else 0.0)
			if b01 != b00 and b01 != b2:
				var cw := w01 + (w11 if b11 == b01 else 0.0)
				if cw > wb2:
					b2 = b01
					wb2 = cw
			if b11 != b00 and b11 != b2 and b11 != b01 and w11 > wb2:
				b2 = b11
				wb2 = w11
			if wb2 > wb:
				var tb := b
				b = b2
				b2 = tb
				var tw := wb
				wb = wb2
				wb2 = tw
			# Smooth mix using the real (soft) biome weights of the two chosen biomes.
			if b2 != b:
				var wa: PackedFloat32Array = weights[b]
				var wc: PackedFloat32Array = weights[b2]
				wb = lerpf(lerpf(wa[c00], wa[c00 + 1], tx), lerpf(wa[c00 + n], wa[c00 + n + 1], tx), tz)
				wb2 = lerpf(lerpf(wc[c00], wc[c00 + 1], tx), lerpf(wc[c00 + n], wc[c00 + n + 1], tx), tz)
			var t := lerpf(lerpf(temp[c00], temp[c00 + 1], tx), lerpf(temp[c00 + n], temp[c00 + n + 1], tx), tz)
			var wat := lerpf(lerpf(water[c00], water[c00 + 1], tx), lerpf(water[c00 + n], water[c00 + n + 1], tx), tz)
			var hk := (y + 1) * hw + x + 1
			var hh := H[hk]
			var gx := H[hk + 1] - H[hk - 1]
			var gz := H[hk + hw] - H[hk - hw]
			var slope := sqrt(gx * gx + gz * gz) / (2.0 * spacing)
			var base := _base[b]
			var overlay := _patch[b]
			var blend := clampf(d * 2.0 - 0.45, 0.0, 1.0) * 0.4
			if wb2 > 0.0 and _base[b2] != base:
				overlay = _base[b2]
				# At the midline both sides show 50/50, so the switch of base texture is seamless.
				blend = clampf(wb2 / maxf(wb + wb2, 0.001), 0.0, 0.5)
			var snowline := lerpf(40.0, 1100.0, t)
			var is_river := river[o] == 1 if use_river else (use_old and ((old_ctrl[o] >> 22) & 31) == T.GRAVEL and ((old_ctrl[o] >> 14) & 255) >= 200)
			if is_river:
				overlay = T.GRAVEL
				blend = 0.85
			elif slope > 0.55:
				overlay = T.ROCK
				blend = clampf((slope - 0.55) / 0.4, 0.0, 1.0)
			elif hh > snowline and base != T.SNOW:
				overlay = T.SNOW
				blend = clampf((hh - snowline) / 60.0, 0.0, 1.0)
			elif hh < 2.5 and wat > 0.02:
				overlay = T.SAND if t > 0.25 else T.GRAVEL
				blend = clampf((2.5 - hh) / 1.7, 0.0, 1.0)
			if wat > 0.5 and hh < 0.0:
				base = T.SAND_DARK if t > 0.2 else T.GRAVEL
			ctrl[o] = (base << 27) | (overlay << 22) | (clampi(int(blend * 255.0), 0, 255) << 14)
			var tint := _tint[b].lerp(_tint[b2], wb2 / maxf(wb + wb2, 0.001))
			var shade := 0.92 + 0.08 * d
			col[o * 4] = clampi(int(tint.r * shade * 255.0), 0, 255)
			col[o * 4 + 1] = clampi(int(tint.g * shade * 255.0), 0, 255)
			col[o * 4 + 2] = clampi(int(tint.b * shade * 255.0), 0, 255)
			col[o * 4 + 3] = 128
	return [ctrl, col]


## Layout water field (1 = ocean or lake) from layout arrays.
static func layout_water(ocean: PackedByteArray, lake_id: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(ocean.size())
	for k in ocean.size():
		out[k] = 1.0 if ocean[k] == 1 or lake_id[k] >= 0 else 0.0
	return out
