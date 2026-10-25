## Asset catalog: stable ids -> models (assets/catalog.json). Maps store ids only, so a
## placeholder model can be swapped for the real one by editing one path.
class_name Catalog
extends RefCounted

const PATH := "res://assets/catalog.json"

static var _entries: Dictionary = {}
static var _instanced: Array[String] = []
static var _palette: Dictionary = {}
static var _recolored := false
static var _scenes: Dictionary = {}  ## keeps recoloured scenes alive in the resource cache


static func _ensure() -> void:
	if not _entries.is_empty():
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not d is Dictionary:
		push_error("catalog.json missing or invalid")
		return
	_palette = d.get("palette", {})
	for e: Dictionary in d.get("assets", []):
		_entries[e.id] = e
		if e.get("instanced", false):
			_instanced.append(e.id)


static func get_entry(id: String) -> Dictionary:
	_ensure()
	return _entries.get(id, {})


static func ids(category: String = "") -> Array[String]:
	_ensure()
	var out: Array[String] = []
	for id: String in _entries:
		if category == "" or _entries[id].category == category:
			out.append(id)
	out.sort()
	return out


## Assets drawn by the terrain instancer (vegetation, rocks). Index = instancer mesh id,
## in catalog.json order — only ever append new instanced assets to the file.
static func instanced_ids() -> Array[String]:
	_ensure()
	return _instanced


static func mesh_id(id: String) -> int:
	_ensure()
	return _instanced.find(id)


## Placeholder art uses a pastel palette; remap named materials to natural colours once.
## Materials are shared resources, so every use of the model picks this up.
static func apply_palette() -> void:
	_ensure()
	if _recolored:
		return
	_recolored = true
	for id: String in _entries:
		if not _entries[id].has("path"):
			continue
		var s: PackedScene = load(_entries[id].path)
		_scenes[id] = s
		var inst := s.instantiate()
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			for i in mesh.get_surface_count():
				var m := mesh.surface_get_material(i) as StandardMaterial3D
				if m and _palette.has(m.resource_name):
					var c: Array = _palette[m.resource_name]
					m.albedo_color = Color(c[0], c[1], c[2])
		inst.free()


static func scene(id: String) -> PackedScene:
	var e := get_entry(id)
	if e.is_empty():
		return null
	if e.has("procedural"):
		if not _scenes.has(id):
			_scenes[id] = PropLibrary.procedural_scene(e)
		return _scenes[id]
	return load(e.path)
