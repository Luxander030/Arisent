## Reads and writes `.luxmap` folders. Our own data is JSON / PNG / EXR (no executable
## content); only Terrain3D's region files are Godot resources.
class_name MapIO
extends RefCounted

const LAYOUT_FILE := "layers/layout.bin"

## Why the last load_map() returned null ("" if it didn't).
static var last_error := ""


static func save(map: MapData, terrain: TerrainBackend, dir: String) -> Error:
	var err := DirAccess.make_dir_recursive_absolute(dir.path_join("layers"))
	if err != OK:
		return err
	DirAccess.make_dir_recursive_absolute(dir.path_join("terrain"))
	map.path = dir
	if map.map_uid == "":
		map.map_uid = MapData.new_uid()
	map.revision += 1
	map.lineage.append([map.map_uid, map.revision])
	if map.lineage.size() > 32:
		map.lineage = map.lineage.slice(map.lineage.size() - 32)
	var meta := {
		"schema_version": MapData.SCHEMA_VERSION,
		"map_uid": map.map_uid,
		"revision": map.revision,
		"lineage": map.lineage,
		"name": map.name,
		"size_km": map.size_km,
		"map_m": map.map_m,
		"spacing": map.spacing,
		"generator_version": map.generator_version,
		"gen_params": map.gen_params,
		"stage_hashes": map.stage_hashes,
		"sea_level": map.sea_level,
		"saved_at": Time.get_datetime_string_from_system(true),
	}
	_write_json(dir.path_join("map.json"), meta)
	var v := MapData.SCHEMA_VERSION
	_write_json(dir.path_join("water.json"), {"schema_version": v} .merged(map.water))
	_write_json(dir.path_join("city.json"), {"schema_version": v, "city": map.city})
	_write_json(dir.path_join("overrides.json"), {"schema_version": v, "overrides": map.overrides})
	_write_json(dir.path_join("modifiers.json"), {"schema_version": v, "modifiers": map.modifiers})
	_write_json(dir.path_join("entities.json"), {"schema_version": v, "entities": map.entities})
	if map.water_mask:
		map.water_mask.save_png(dir.path_join("layers/water_mask.png"))
	if map.minimap:
		map.minimap.save_png(dir.path_join("layers/minimap.png"))
	if map.procedural_height:
		map.procedural_height.save_exr(dir.path_join("layers/procedural_height.exr"), true)
	if map.paint_lock:
		map.paint_lock.save_png(dir.path_join("layers/paint_lock.png"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("layers/scatter"))
	for g in map.scatter_paint:
		(map.scatter_paint[g] as Image).save_png(dir.path_join("layers/scatter/%s.png" % g))
	var zc := FileAccess.open(dir.path_join("layers/zones_cache.bin"), FileAccess.WRITE)
	if zc:
		zc.store_var(map.zone_cache, false)
		zc.close()
	var f := FileAccess.open(dir.path_join(LAYOUT_FILE), FileAccess.WRITE)
	if f:
		f.store_var({"n": map.layout_n, "biome": map.layout_biome, "temp": map.layout_temp, "weights": map.layout_weights}, false)
		f.close()
	if terrain:
		terrain.save_to(dir.path_join("terrain"))
	return OK


## Loads map data; terrain regions are loaded separately via load_terrain().
static func load_map(dir: String) -> MapData:
	last_error = ""
	var meta := _read_json(dir.path_join("map.json"))
	if meta.is_empty():
		last_error = "not a map folder"
		return null
	var version := int(meta.get("schema_version", 0))
	if version != MapData.SCHEMA_VERSION:
		# No migrations during development: old maps are re-created.
		last_error = "map format %d is not supported (this build reads format %d); re-create the map" % [version, MapData.SCHEMA_VERSION]
		push_warning("%s: %s" % [dir, last_error])
		return null
	var map := MapData.new()
	map.path = dir
	map.map_uid = str(meta.get("map_uid", ""))
	map.revision = int(meta.get("revision", 0))
	map.lineage = meta.get("lineage", [])
	map.name = str(meta.get("name", dir.get_file().get_basename()))
	map.size_km = int(meta.get("size_km", 4))
	map.map_m = float(meta.get("map_m", map.size_km * 1024.0))
	map.spacing = float(meta.get("spacing", 1.0))
	map.generator_version = int(meta.get("generator_version", 0))
	map.gen_params = meta.get("gen_params", {})
	map.stage_hashes = meta.get("stage_hashes", {})
	map.sea_level = float(meta.get("sea_level", 0.0))
	map.water = _read_json(dir.path_join("water.json"))
	map.city = _read_json(dir.path_join("city.json")).get("city", {})
	map.overrides = _read_json(dir.path_join("overrides.json")).get("overrides", {})
	map.modifiers = _read_json(dir.path_join("modifiers.json")).get("modifiers", [])
	map.entities = []
	for e: Variant in _read_json(dir.path_join("entities.json")).get("entities", []):
		if e is Dictionary:
			map.entities.append(EntityKinds.normalize(e))
	map.water_mask = _load_image(dir.path_join("layers/water_mask.png"))
	if map.water_mask:
		map.water_mask.convert(Image.FORMAT_RGB8)
	map.minimap = _load_image(dir.path_join("layers/minimap.png"))
	map.procedural_height = _load_image(dir.path_join("layers/procedural_height.exr"))
	if map.procedural_height:
		map.procedural_height.convert(Image.FORMAT_RF)  # EXR loads as RGB float
	map.paint_lock = _load_image(dir.path_join("layers/paint_lock.png"))
	if map.paint_lock:
		map.paint_lock.convert(Image.FORMAT_L8)
	var sdir := dir.path_join("layers/scatter")
	if DirAccess.dir_exists_absolute(sdir):
		for f in DirAccess.get_files_at(sdir):
			if f.ends_with(".png"):
				var img := _load_image(sdir.path_join(f))
				img.convert(Image.FORMAT_L8)
				map.scatter_paint[f.get_basename()] = img
	if FileAccess.file_exists(dir.path_join("layers/zones_cache.bin")):
		var zf := FileAccess.open(dir.path_join("layers/zones_cache.bin"), FileAccess.READ)
		var zd: Variant = zf.get_var(false)
		map.zone_cache = zd if zd is Dictionary else {}
	if FileAccess.file_exists(dir.path_join(LAYOUT_FILE)):
		var f := FileAccess.open(dir.path_join(LAYOUT_FILE), FileAccess.READ)
		var d: Variant = f.get_var(false)
		if d is Dictionary:
			map.layout_n = int(d.get("n", 0))
			map.layout_biome = d.get("biome", PackedByteArray())
			map.layout_temp = d.get("temp", PackedFloat32Array())
			map.layout_weights = d.get("weights", [])
	return map


static func load_terrain(map: MapData, terrain: TerrainBackend) -> void:
	terrain.load_from(map.path.path_join("terrain"))


static func is_map_folder(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join("map.json"))


static func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t", false))
		f.close()


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func _load_image(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(path)
