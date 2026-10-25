## Paints a WorldLayout into a small map image for the New Map screen and the minimap.
class_name PreviewPainter
extends RefCounted

enum Mode { BIOMES, HEIGHT, WATER }

const BIOME_COLORS: Array[Color] = [
	Color(0.86, 0.9, 0.95),   # fjords
	Color(0.52, 0.52, 0.58),  # northern mountains
	Color(0.12, 0.3, 0.55),   # ocean
	Color(0.2, 0.45, 0.22),   # temperate forest
	Color(0.56, 0.7, 0.34),   # grassland
	Color(0.07, 0.55, 0.32),  # tropical
	Color(0.66, 0.44, 0.28),  # desert highlands
	Color(0.92, 0.81, 0.55),  # desert
]


static func paint(L: WorldLayout, mode: int = Mode.BIOMES) -> Image:
	var n := L.n
	var data := PackedByteArray()
	data.resize(n * n * 3)
	var light := Vector3(-0.6, 0.75, -0.4).normalized()
	var zscale := 2.0 / L.cell_m
	for j in n:
		for i in n:
			var k := j * n + i
			var h := L.height[k]
			var col: Color
			if L.ocean[k] == 1:
				var d := clampf(-h / 90.0, 0.0, 1.0)
				col = Color(0.2, 0.45, 0.7).lerp(Color(0.06, 0.16, 0.38), d)
				if L.sea_ice.size() > 0 and L.sea_ice[k] == 1:
					col = col.lerp(Color(0.85, 0.93, 1.0), 0.75)
			else:
				match mode:
					Mode.HEIGHT:
						col = _height_color(h)
					Mode.WATER:
						col = Color(0.75, 0.75, 0.72)
					_:
						col = Color(0, 0, 0)
						for b in GenParams.BIOME_COUNT:
							var w := L.weights[b][k]
							if w > 0.0:
								col += BIOME_COLORS[b] * w
				# Hill shading.
				var hx := L.height[k + 1] - L.height[k - 1] if i > 0 and i < n - 1 else 0.0
				var hz := L.height[k + n] - L.height[k - n] if j > 0 and j < n - 1 else 0.0
				var nrm := Vector3(-hx * zscale * 0.5, 1.0, -hz * zscale * 0.5).normalized()
				var shade := clampf(nrm.dot(light) * 1.1 + 0.15, 0.35, 1.25)
				col = col * shade
				if L.rift.size() > 0 and L.rift[k] > 0.3:
					col = col.lerp(Color(0.35, 0.2, 0.15), 0.5)
				if L.lake_id.size() > 0 and L.lake_id[k] >= 0:
					var lake: Dictionary = L.lakes[L.lake_id[k]]
					col = Color(0.8, 0.9, 0.98) if lake.frozen else Color(0.22, 0.5, 0.78)
				elif L.river.size() > 0 and L.river[k] == 1:
					col = Color(0.75, 0.88, 0.97) if L.temp[k] < 0.2 else Color(0.2, 0.5, 0.85)
			var o := k * 3
			data[o] = clampi(int(col.r * 255.0), 0, 255)
			data[o + 1] = clampi(int(col.g * 255.0), 0, 255)
			data[o + 2] = clampi(int(col.b * 255.0), 0, 255)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGB8, data)
	if L.has_city:
		_draw_city(img, L)
	return img


static func _height_color(h: float) -> Color:
	if h < 30.0:
		return Color(0.3, 0.55, 0.3).lerp(Color(0.6, 0.65, 0.4), h / 30.0)
	if h < 200.0:
		return Color(0.6, 0.65, 0.4).lerp(Color(0.55, 0.42, 0.3), (h - 30.0) / 170.0)
	if h < 600.0:
		return Color(0.55, 0.42, 0.3).lerp(Color(0.5, 0.5, 0.52), (h - 200.0) / 400.0)
	return Color(0.5, 0.5, 0.52).lerp(Color(0.97, 0.97, 1.0), clampf((h - 600.0) / 500.0, 0.0, 1.0))


static func _draw_city(img: Image, L: WorldLayout) -> void:
	var n := L.n
	var c := L.city_center
	var r := L.city_radius
	for j in n:
		for i in n:
			var d := L.cell_center(i, j).distance_to(c)
			if d < r:
				var px := img.get_pixel(i, j)
				var wall := absf(d - r * 0.45) < L.cell_m * 0.8
				if wall:
					img.set_pixel(i, j, Color(0.35, 0.3, 0.3))
				elif absf(d - r) < L.cell_m * 0.8:
					img.set_pixel(i, j, Color(0.9, 0.35, 0.2))
				else:
					var core := d < r * 0.45
					img.set_pixel(i, j, px.lerp(Color(0.75, 0.55, 0.45) if core else Color(0.62, 0.62, 0.66), 0.55))
