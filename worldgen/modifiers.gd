## Authored vector modifiers (rifts now; roads, user rivers and lakes later). Each one
## turns into a height change over a pixel rectangle, added to the procedural layer P.
class_name Modifiers
extends RefCounted


## World XZ bounds a modifier affects.
static func bounds(mod: Dictionary) -> Rect2:
	match str(mod.get("type", "")):
		"rift":
			var a := Vector2(mod.a[0], mod.a[1])
			var b := Vector2(mod.b[0], mod.b[1])
			var r: float = float(mod.width) * 0.75 + 4.0
			return Rect2(a, Vector2.ZERO).expand(b).grow(r)
		"river":
			var pts: Array = mod.points
			var box := Rect2(Vector2(pts[0][0], pts[0][2]), Vector2.ZERO)
			for q in pts:
				box = box.expand(Vector2(q[0], q[2]))
			return box.grow(float(mod.width) * 0.5 + maxf(8.0, float(mod.width)) + 2.0)
	return Rect2()


## Height delta (metres, usually negative) for every pixel of `rect`.
## `heights` (current heights of rect) is needed by modifiers that cut down to a level.
static func delta(mod: Dictionary, rect: Rect2i, spacing: float, map_m: float, heights := PackedFloat32Array()) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(rect.size.x * rect.size.y)
	match str(mod.get("type", "")):
		"rift":
			_rift(mod, rect, spacing, map_m, out)
		"river":
			_river(mod, rect, spacing, map_m, heights, out)
	return out


## River bed: a U-shaped channel cut below the water level with sloped banks.
static func _river(mod: Dictionary, rect: Rect2i, spacing: float, map_m: float, heights: PackedFloat32Array, out: PackedFloat32Array) -> void:
	var pts: Array = mod.points  # [x, water level, z]
	var w: float = mod.width
	var depth: float = mod.depth
	var half := map_m * 0.5
	var hw := w * 0.5
	var bank := maxf(8.0, w)
	var reach := (hw + bank) / spacing
	# Each segment rasterises its own bounding box; carving keeps the deepest value.
	for i in pts.size() - 1:
		var a := Vector2(pts[i][0], pts[i][2])
		var b := Vector2(pts[i + 1][0], pts[i + 1][2])
		var ab := b - a
		var len2 := maxf(ab.length_squared(), 0.0001)
		var pa := Vector2((a.x + half) / spacing, (a.y + half) / spacing) - Vector2(rect.position)
		var pb := Vector2((b.x + half) / spacing, (b.y + half) / spacing) - Vector2(rect.position)
		var x0 := maxi(0, floori(minf(pa.x, pb.x) - reach))
		var x1 := mini(rect.size.x - 1, ceili(maxf(pa.x, pb.x) + reach))
		var y0 := maxi(0, floori(minf(pa.y, pb.y) - reach))
		var y1 := mini(rect.size.y - 1, ceili(maxf(pa.y, pb.y) + reach))
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var p := Vector2((rect.position.x + x) * spacing - half, (rect.position.y + y) * spacing - half)
				var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
				var d := p.distance_to(a + ab * t)
				if d > hw + bank:
					continue
				var lvl := lerpf(pts[i][1], pts[i + 1][1], t)
				var target: float
				if d < hw:
					var q := d / hw
					target = lvl - depth * (1.0 - q * q)
				else:
					target = lvl + 0.15 + (d - hw) * 0.35
				var k := y * rect.size.x + x
				out[k] = minf(out[k], target - heights[k])


## A V-to-U shaped trench with ragged walls along a line segment.
static func _rift(mod: Dictionary, rect: Rect2i, spacing: float, map_m: float, out: PackedFloat32Array) -> void:
	var a := Vector2(mod.a[0], mod.a[1])
	var b := Vector2(mod.b[0], mod.b[1])
	var half_w: float = float(mod.width) * 0.5
	var depth: float = float(mod.depth)
	var rough: float = float(mod.get("roughness", 0.5))
	var noise := LayoutGenerator.make_noise(Rng.seed_from_text(str(mod.get("id", "rift"))), 35.0, 3)
	var ab := b - a
	var len2 := maxf(ab.length_squared(), 0.0001)
	var half := map_m * 0.5
	for y in rect.size.y:
		for x in rect.size.x:
			var p := Vector2((rect.position.x + x) * spacing - half, (rect.position.y + y) * spacing - half)
			var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
			var n := noise.get_noise_2d(p.x, p.y)
			var d := p.distance_to(a + ab * t) / (half_w * (1.0 + n * 0.35 * rough))
			if d >= 1.0:
				continue
			# Taper at both ends, flatter floor, steep ragged walls.
			var ends := minf(t, 1.0 - t) * ab.length() / maxf(half_w, 1.0)
			var taper := clampf(ends * 1.5, 0.0, 1.0)
			var profile := 1.0 - pow(d, 3.0)
			out[y * rect.size.x + x] = -depth * profile * taper * (1.0 + n * 0.25 * rough)
