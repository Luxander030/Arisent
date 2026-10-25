## Rule-based vegetation & rock scattering. Works per terrain region so that the editor
## can re-scatter just the regions a brush touched. Every random choice is a hash of
## (seed, group, grid cell), so results never depend on processing order.
class_name Scatter
extends RefCounted

const B := GenParams.Biome
const T := TerrainBuilder.Tex

## Vegetation groups: grid spacing (m) for candidate points. Group ids are stored in
## paint layers — only append.
const GROUPS := {
	"trees": 7.0,
	"bushes": 4.5,
	"rocks": 16.0,
	"small": 3.0,
}
const GROUP_NAMES := ["trees", "bushes", "rocks", "small"]

## [group, biome, catalog id, weight (chance per candidate), max slope, scale min, scale max]
const RULES := [
	["trees", B.TEMPERATE_FOREST, "nature.tree_oak", 0.22, 0.6, 0.8, 1.3],
	["trees", B.TEMPERATE_FOREST, "nature.tree_default", 0.18, 0.6, 0.8, 1.3],
	["trees", B.TEMPERATE_FOREST, "nature.tree_detailed", 0.12, 0.6, 0.8, 1.2],
	["trees", B.TEMPERATE_FOREST, "nature.tree_fat", 0.1, 0.6, 0.8, 1.2],
	["trees", B.TEMPERATE_FOREST, "nature.tree_pineRoundA", 0.08, 0.7, 0.8, 1.2],
	["trees", B.GRASSLAND, "nature.tree_default", 0.025, 0.5, 0.9, 1.4],
	["trees", B.GRASSLAND, "nature.tree_oak", 0.02, 0.5, 1.0, 1.5],
	["trees", B.GRASSLAND, "nature.tree_plateau", 0.01, 0.5, 0.9, 1.3],
	["trees", B.TROPICAL, "nature.tree_palmTall", 0.2, 0.6, 0.8, 1.3],
	["trees", B.TROPICAL, "nature.tree_palmBend", 0.15, 0.6, 0.8, 1.3],
	["trees", B.TROPICAL, "nature.tree_palmDetailedTall", 0.12, 0.6, 0.8, 1.2],
	["trees", B.TROPICAL, "nature.tree_palmShort", 0.1, 0.6, 0.8, 1.2],
	["trees", B.FJORDS, "nature.tree_pineTallA", 0.12, 0.65, 0.8, 1.3],
	["trees", B.FJORDS, "nature.tree_pineSmallA", 0.1, 0.7, 0.7, 1.2],
	["trees", B.NORTH_MOUNTAINS, "nature.tree_pineTallB", 0.1, 0.6, 0.8, 1.2],
	["trees", B.NORTH_MOUNTAINS, "nature.tree_pineDefaultA", 0.08, 0.6, 0.8, 1.2],
	["trees", B.DESERT_HIGHLANDS, "nature.tree_thin_dark", 0.02, 0.6, 0.8, 1.2],
	["trees", B.DESERT, "nature.cactus_tall", 0.02, 0.5, 0.8, 1.4],
	["trees", B.DESERT, "nature.cactus_short", 0.02, 0.5, 0.8, 1.4],
	["trees", B.DESERT_HIGHLANDS, "nature.cactus_tall", 0.01, 0.5, 0.8, 1.2],
	["bushes", B.TEMPERATE_FOREST, "nature.plant_bushLarge", 0.12, 0.7, 0.8, 1.4],
	["bushes", B.TEMPERATE_FOREST, "nature.plant_bush", 0.1, 0.7, 0.8, 1.4],
	["bushes", B.GRASSLAND, "nature.plant_bushSmall", 0.06, 0.6, 0.8, 1.4],
	["bushes", B.GRASSLAND, "nature.plant_bush", 0.04, 0.6, 0.8, 1.4],
	["bushes", B.TROPICAL, "nature.plant_bushDetailed", 0.2, 0.7, 1.0, 1.8],
	["bushes", B.TROPICAL, "nature.plant_flatTall", 0.15, 0.7, 1.0, 1.8],
	["bushes", B.TROPICAL, "nature.plant_bushTriangle", 0.1, 0.7, 1.0, 1.6],
	["bushes", B.FJORDS, "nature.plant_bushSmall", 0.03, 0.6, 0.6, 1.0],
	["bushes", B.DESERT_HIGHLANDS, "nature.plant_bushSmall", 0.02, 0.6, 0.6, 1.0],
	["rocks", B.NORTH_MOUNTAINS, "nature.rock_largeB", 0.2, 1.4, 1.0, 2.5],
	["rocks", B.NORTH_MOUNTAINS, "nature.rock_tallA", 0.15, 1.4, 1.0, 2.5],
	["rocks", B.FJORDS, "nature.stone_largeA", 0.15, 1.4, 1.0, 2.5],
	["rocks", B.FJORDS, "nature.stone_tallB", 0.08, 1.4, 1.0, 2.0],
	["rocks", B.DESERT_HIGHLANDS, "nature.rock_largeD", 0.18, 1.4, 1.0, 3.0],
	["rocks", B.DESERT_HIGHLANDS, "nature.rock_tallE", 0.12, 1.4, 1.0, 2.5],
	["rocks", B.DESERT, "nature.rock_largeA", 0.05, 1.0, 1.0, 2.5],
	["rocks", B.TEMPERATE_FOREST, "nature.rock_largeA", 0.05, 1.0, 0.8, 1.8],
	["rocks", B.GRASSLAND, "nature.rock_smallA", 0.05, 1.0, 1.0, 2.0],
	["rocks", B.TROPICAL, "nature.stone_largeC", 0.04, 1.0, 0.8, 1.8],
	["small", B.GRASSLAND, "nature.flower_yellowA", 0.03, 0.5, 0.8, 1.4],
	["small", B.GRASSLAND, "nature.flower_redA", 0.02, 0.5, 0.8, 1.4],
	["small", B.GRASSLAND, "nature.grass_large", 0.06, 0.6, 1.0, 1.6],
	["small", B.TEMPERATE_FOREST, "nature.mushroom_redGroup", 0.015, 0.5, 0.8, 1.3],
	["small", B.TEMPERATE_FOREST, "nature.flower_purpleA", 0.02, 0.5, 0.8, 1.3],
	["small", B.TEMPERATE_FOREST, "nature.stump_round", 0.01, 0.5, 0.8, 1.3],
	["small", B.TROPICAL, "nature.grass_large", 0.08, 0.6, 1.2, 2.0],
	["small", B.TROPICAL, "nature.flower_redA", 0.04, 0.5, 1.0, 1.6],
]


class Context:
	var seed: int
	var density := 1.0          ## vegetation slider (0..1) mapped to a multiplier
	var map_m: float
	var spacing: float
	var R: int
	var n: int                  ## layout size
	var weights: Array          ## per biome PackedByteArray (0..255), layout res
	var water: PackedByteArray  ## layout res: 1 = ocean or lake
	var city_center := Vector2.ZERO
	var city_radius := 0.0
	var paint := {}             ## group -> Image (L8, 128 = no change)
	var _rules := {}            ## group -> biome -> [[mesh_id, cumulative weight, max slope, smin, smax, scale]]

	func prepare() -> void:
		for g in GROUP_NAMES:
			_rules[g] = {}
		for r in RULES:
			var id: String = r[2]
			var mid := Catalog.mesh_id(id)
			if mid < 0:
				continue
			var by_biome: Dictionary = _rules[r[0]]
			var list: Array = by_biome.get(r[1], [])
			var cum: float = (list[-1][1] if not list.is_empty() else 0.0) + float(r[3])
			list.append([mid, cum, r[4], r[5], r[6], float(Catalog.get_entry(id).get("scale", 1.0))])
			by_biome[r[1]] = list


## Scatter one pixel rectangle (normally a terrain region) for one group.
## H / ctrl cover the rect grown by one pixel ((w+2)*(h+2)), row-major.
## Returns {mesh_id: Array[Transform3D]}.
static func scatter_rect(ctx: Context, group: String, rect: Rect2i, H: PackedFloat32Array, ctrl: PackedInt32Array) -> Dictionary:
	var out := {}
	var grid: float = GROUPS[group]
	var gi := GROUP_NAMES.find(group)
	var half := ctx.map_m * 0.5
	var sp := ctx.spacing
	var x0 := rect.position.x * sp - half
	var z0 := rect.position.y * sp - half
	var x1 := rect.end.x * sp - half
	var z1 := rect.end.y * sp - half
	var by_biome: Dictionary = ctx._rules[group]
	var hw := rect.size.x + 2
	var paint: Image = ctx.paint.get(group)
	var cx0 := ceili(x0 / grid)
	var cz0 := ceili(z0 / grid)
	for cz in range(cz0, ceili(z1 / grid)):
		for cx in range(cx0, ceili(x1 / grid)):
			var h1 := Rng.hash3(cx, cz, gi, ctx.seed)
			var h2 := Rng.mix32(h1 ^ 0x9e3779b9)
			var h3 := Rng.mix32(h2 + 0x7f4a7c15)
			var px := (cx + (h1 & 0xFFFF) / 65536.0) * grid
			var pz := (cz + (h1 >> 16) / 65536.0) * grid
			if px < x0 or pz < z0 or px >= x1 or pz >= z1:
				continue
			if ctx.city_radius > 0.0 and Vector2(px, pz).distance_to(ctx.city_center) < ctx.city_radius * 1.05:
				continue
			# Layout cell -> water check and biome pick (weighted by biome weights).
			var li := clampi(floori((px + half) / ctx.map_m * ctx.n), 0, ctx.n - 1)
			var lj := clampi(floori((pz + half) / ctx.map_m * ctx.n), 0, ctx.n - 1)
			var lk := lj * ctx.n + li
			if ctx.water[lk] == 1:
				continue
			var u := (h2 & 0xFFFF) / 65536.0 * 255.0
			var biome := -1
			var acc := 0.0
			for b in GenParams.BIOME_COUNT:
				acc += ctx.weights[b][lk]
				if u < acc:
					biome = b
					break
			if biome < 0 or not by_biome.has(biome):
				continue
			var list: Array = by_biome[biome]
			var dens := ctx.density
			if paint:
				dens *= paint.get_pixel(clampi(int((px + half) / ctx.map_m * paint.get_width()), 0, paint.get_width() - 1),
					clampi(int((pz + half) / ctx.map_m * paint.get_height()), 0, paint.get_height() - 1)).r * 2.0
			var r := (h2 >> 16) / 65536.0 / maxf(dens, 0.0001)
			if r >= list[-1][1]:
				continue
			var pick: Array = list[0]
			for e in list:
				if r < e[1]:
					pick = e
					break
			# Terrain checks: height above water, slope, no river beds.
			var ix := clampi(floori((px + half) / sp) - rect.position.x, 0, rect.size.x - 1)
			var iz := clampi(floori((pz + half) / sp) - rect.position.y, 0, rect.size.y - 1)
			var k := (iz + 1) * hw + ix + 1
			var h := H[k]
			if h < 0.8:
				continue
			var gx := H[k + 1] - H[k - 1]
			var gz := H[k + hw] - H[k - hw]
			var slope := sqrt(gx * gx + gz * gz) / (2.0 * sp)
			if slope > pick[2]:
				continue
			var c := ctrl[k]
			if ((c >> 22) & 31) == T.GRAVEL and ((c >> 14) & 255) > 150:
				continue
			var s: float = pick[5] * lerpf(pick[3], pick[4], (h3 & 0xFFFF) / 65536.0)
			var yaw := (h3 >> 16) / 65536.0 * TAU
			var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), Vector3(px, h - 0.15 * s, pz))
			var arr: Array = out.get(pick[0], [])
			arr.append(xf)
			out[pick[0]] = arr
	return out
