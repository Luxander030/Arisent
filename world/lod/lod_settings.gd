## Distance tiers for level of detail, per kind of object. Each list is the distance (m)
## where that LOD stops being drawn: LOD0 up to [0], LOD1 up to [1], ... and the object
## disappears after the last value. All distances are multiplied by the current detail
## scale (LodController), so one number trades quality for speed everywhere at once.
class_name LodSettings
extends RefCounted

const OUT_DIR := "res://assets/lod/"

const TIERS := {
	"tree": [60.0, 170.0, 420.0, 2000.0],   # full, simplified, coarse, impostor cards
	"plant": [40.0, 110.0, 260.0],
	"rock": [70.0, 200.0, 600.0],
	"small": [35.0, 90.0],
	"prop": [80.0, 220.0, 700.0],
	"building": [140.0, 420.0, 3200.0],     # modern buildings
	"city_medieval": [110.0, 320.0, 3200.0], # kit house, simplified kit, box + roof
}

## Detail presets for the View menu / settings. "Adaptive" adjusts the scale at runtime.
const PRESETS := {"Low": 0.5, "Medium": 0.75, "High": 1.0, "Ultra": 1.5}
## Reference / debugging: every object at full detail out to 20× the normal distances.
const NO_LOD_SCALE := 20.0

## Sun shadow distance (m) at detail scale 1 — shadows are the costliest part of distant detail.
const SHADOW_DISTANCE := 400.0

## Shadows only from the first N levels (far shadows cost a lot and are barely visible).
const SHADOW_LODS := {"tree": 1, "rock": 1, "plant": 0, "building": 1, "prop": 1}


static func tiers(category: String, scale: float = 1.0) -> Array[float]:
	var out: Array[float] = []
	for d in TIERS.get(category, TIERS.prop):
		out.append(d * scale)
	return out


## Pre-built LOD scene for a catalog id (null if the LOD builder hasn't been run).
static func lod_scene(id: String) -> PackedScene:
	var p := OUT_DIR + id + ".scn"
	return load(p) if ResourceLoader.exists(p) else null


## The mesh of one level from a LOD scene (falls back to the nearest coarser/finer one).
static func lod_mesh(scene: PackedScene, level: int) -> Mesh:
	var inst := scene.instantiate()
	var mesh: Mesh = null
	for l in range(level, -1, -1):
		var n := inst.get_node_or_null("LOD%d" % l) as MeshInstance3D
		if n:
			mesh = n.mesh
			break
	inst.free()
	return mesh


static var _manifest: Dictionary = {}


## True if the LOD builder made far "impostor" cards as the last level of this model.
static func has_impostor(id: String) -> bool:
	if _manifest.is_empty() and FileAccess.file_exists(OUT_DIR + "manifest.json"):
		_manifest = JSON.parse_string(FileAccess.get_file_as_string(OUT_DIR + "manifest.json"))
	return bool(_manifest.get(id, {}).get("impostor", false))


static func lod_count(scene: PackedScene) -> int:
	var inst := scene.instantiate()
	var n := 0
	while inst.has_node("LOD%d" % n):
		n += 1
	inst.free()
	return n
