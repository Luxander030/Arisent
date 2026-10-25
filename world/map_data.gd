## Everything a map consists of, in memory. Saved/loaded by MapIO as a `.luxmap` folder.
## Lives in world/ (shared with the game), so it never references worldgen/ or editor/.
class_name MapData
extends RefCounted

## Version 2 added map identity (uid/revision/lineage), entity shapes and typed props.
## Older maps are not migrated (development phase): they are rejected and re-created.
const SCHEMA_VERSION := 2
const EXTENSION := ".luxmap"
## Biome index -> name (layout_biome stores the index). Shared by worldgen and the game.
const BIOME_NAMES: Array[String] = ["Frozen Fjords", "Northern Mountains", "Ocean", "Temperate Forest", "Grassland", "Tropical Forest", "Desert Highlands", "Desert"]

var path := ""                 ## folder on disk ("" = never saved)
var name := "New Map"
var map_uid := ""              ## identity for save games; new for every New Map / "Save as copy"
var revision := 0              ## +1 on every save (save games remember which revision they saw)
var lineage: Array = []        ## recent [uid, revision] pairs, newest last
var size_km := 4
var map_m := 4096.0
var spacing := 1.0
var generator_version := 0
var gen_params := {}           ## GenParams.to_dict() — kept verbatim for "Regenerate"
var stage_hashes := {}
var sea_level := 0.0

var water := {}                ## {"ocean": bool, "lakes": [...], "rivers": [...]}
var water_mask: Image          ## layout-res RGB: R ocean, G sea ice, B lake
var city := {}                 ## derived city layout (see worldgen/city_gen.gd)
var overrides := {}            ## stable key -> {"deleted": bool} | {"xform": ...}
var modifiers: Array = []      ## authored vector edits (rifts, user rivers/lakes)
var entities: Array = []       ## hand-placed entities (Entity dictionaries)
## Spawn zones' usable points, baked by the editor on save: zone id -> {key, points}
## (key changes when the zone or its terrain filters change; the game re-bakes stale ones).
var zone_cache := {}

## Layout data needed after generation (texture rules after sculpting, minimap).
var layout_n := 0
var layout_biome := PackedByteArray()
var layout_temp := PackedFloat32Array()
var layout_weights: Array = []  ## per biome PackedByteArray (0..255)
var scatter_paint := {}         ## vegetation group -> Image (L8, 128 = unchanged density)
var minimap: Image

## Height layers (see docs: final = P + D).
var procedural_height: Image   ## P, full res, FORMAT_RF
var paint_lock: Image          ## full res L8: 255 = hand-painted ground texture


## A fresh random identity (16 hex chars).
static func new_uid() -> String:
	return Crypto.new().generate_random_bytes(8).hex_encode()


## Biome index at a world position (from the layout grid), or -1 without layout data.
func biome_at(pos: Vector3) -> int:
	if layout_n == 0:
		return -1
	var i := clampi(floori((pos.x / map_m + 0.5) * layout_n), 0, layout_n - 1)
	var j := clampi(floori((pos.z / map_m + 0.5) * layout_n), 0, layout_n - 1)
	return layout_biome[j * layout_n + i]


func res() -> int:
	return roundi(map_m / spacing)


func display_name() -> String:
	return name if name != "" else path.get_file().get_basename()
