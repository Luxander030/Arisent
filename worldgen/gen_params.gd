## Everything the user chooses on the New Map screen. Saved verbatim in map.json.
## Loading always goes through SCHEMA, so JSON's "every number is a float" never leaks in.
class_name GenParams
extends RefCounted

## Biome ids are indices into per-cell weight arrays and saved in files: never reorder.
enum Biome { FJORDS, NORTH_MOUNTAINS, OCEAN, TEMPERATE_FOREST, GRASSLAND, TROPICAL, DESERT_HIGHLANDS, DESERT }
const BIOME_COUNT := 8
const BIOME_KEYS: Array[String] = ["fjords", "north_mountains", "ocean", "temperate_forest", "grassland", "tropical", "desert_highlands", "desert"]
const BIOME_NAMES := MapData.BIOME_NAMES

const SIZES_KM: Array[int] = [2, 4, 8]
const GENERATOR_VERSION := 1

## [key, type, default, min, max]
const SCHEMA := [
	["name", TYPE_STRING, "New Map"],
	["seed", TYPE_STRING, "1"],
	["size_km", TYPE_INT, 4, 2, 8],
	["land_water", TYPE_FLOAT, 0.35, 0.0, 1.0],
	["islands", TYPE_FLOAT, 0.3, 0.0, 1.0],
	["coast_rough", TYPE_FLOAT, 0.5, 0.0, 1.0],
	["mountains", TYPE_FLOAT, 0.5, 0.0, 1.0],
	["hilliness", TYPE_FLOAT, 0.5, 0.0, 1.0],
	["rivers", TYPE_FLOAT, 0.5, 0.0, 1.0],
	["lakes", TYPE_FLOAT, 0.4, 0.0, 1.0],
	["rifts", TYPE_FLOAT, 0.25, 0.0, 1.0],
	["blend_width", TYPE_FLOAT, 0.5, 0.0, 1.0],
	["vegetation", TYPE_FLOAT, 0.6, 0.0, 1.0],
	["city", TYPE_BOOL, true],
	["city_size", TYPE_FLOAT, 0.65, 0.0, 1.0],
	["city_walls", TYPE_BOOL, true],
	["city_modern", TYPE_FLOAT, 0.4, 0.0, 1.0],
]

var name := "New Map"
var seed := "1"
var size_km := 4
var land_water := 0.35
var islands := 0.3
var coast_rough := 0.5
var mountains := 0.5
var hilliness := 0.5
var rivers := 0.5
var lakes := 0.4
var rifts := 0.25
var blend_width := 0.5
var vegetation := 0.6
var city := true
var city_size := 0.65
var city_walls := true
var city_modern := 0.4
## Enabled biomes, indexed by Biome.
var biomes: Array[bool] = [true, true, true, true, true, true, true, true]


func seed_int() -> int:
	return Rng.seed_from_text(seed)


## A "km" here is 1024 m so every map is a whole number of 1024-sample terrain regions.
func map_size_m() -> float:
	return size_km * 1024.0


func has_biome(b: int) -> bool:
	return biomes[b]


## True if at least one land biome is on (ocean alone is not a world).
func any_land_biome() -> bool:
	for b in BIOME_COUNT:
		if b != Biome.OCEAN and biomes[b]:
			return true
	return false


func duplicate_params() -> GenParams:
	var p := GenParams.new()
	p.from_dict(to_dict())
	return p


func to_dict() -> Dictionary:
	var d := {}
	for f in SCHEMA:
		d[f[0]] = get(f[0])
	var b := {}
	for i in BIOME_COUNT:
		b[BIOME_KEYS[i]] = biomes[i]
	d["biomes"] = b
	d["generator_version"] = GENERATOR_VERSION
	return d


func from_dict(d: Dictionary) -> void:
	for f in SCHEMA:
		if not d.has(f[0]):
			set(f[0], f[2])
			continue
		set(f[0], coerce(d[f[0]], f))
	if size_km not in SIZES_KM:
		size_km = 4
	var b: Dictionary = d.get("biomes", {})
	for i in BIOME_COUNT:
		biomes[i] = bool(b.get(BIOME_KEYS[i], true))


static func coerce(v: Variant, field: Array) -> Variant:
	match field[1]:
		TYPE_STRING:
			if v is float and v == floorf(v):
				return str(int(v))
			return str(v)
		TYPE_INT:
			return clampi(int(round(float(v))), field[3], field[4])
		TYPE_FLOAT:
			return clampf(float(v), field[3], field[4])
		TYPE_BOOL:
			return bool(v)
	return v


## Canonical text form: fixed key order, fixed float precision. Hash this, never Variants.
func canonical_string(keys: Array = []) -> String:
	var parts := PackedStringArray()
	for f in SCHEMA:
		if not keys.is_empty() and f[0] not in keys:
			continue
		var v: Variant = get(f[0])
		match f[1]:
			TYPE_FLOAT:
				parts.append("%s=%d" % [f[0], int(round(v * 10000.0))])
			TYPE_BOOL:
				parts.append("%s=%d" % [f[0], 1 if v else 0])
			_:
				parts.append("%s=%s" % [f[0], str(v)])
	if keys.is_empty() or "biomes" in keys:
		var bits := ""
		for i in BIOME_COUNT:
			bits += "1" if biomes[i] else "0"
		parts.append("biomes=" + bits)
	parts.append("v=%d" % GENERATOR_VERSION)
	return ";".join(parts)


func hash_keys(keys: Array = []) -> String:
	return canonical_string(keys).sha256_text().substr(0, 16)
