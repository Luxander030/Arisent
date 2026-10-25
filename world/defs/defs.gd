## Data registries (assets/data/<name>.json): creatures, items, loot_tables, factions,
## spawn_rules. Each file is {"schema_version": 1, "entries": [{"id": ...}, ...]}.
## Read-only at runtime; the World Editor can reload() after editing the files. Entries get
## their defaults filled in here, so the rest of the code can index fields directly.
## An entry may list "renamed_from": ["old_id"] so saves that use the old id still resolve.
class_name Defs
extends RefCounted

const DIR := "res://assets/data"
const REGISTRIES: Array[String] = ["creatures", "items", "loot_tables", "factions", "spawn_rules"]

const CREATURE_DEFAULTS := {
	"name": "", "body": "humanoid", "height": 1.8, "color": "#a08060", "health": 50.0, "level": 1,
	"walk_speed": 1.6, "run_speed": 5.0, "faction": "monsters", "behaviour": "aggressive",
	"aggro_radius": 14.0, "assist_radius": 12.0, "leash": 45.0, "flee_radius": 0.0,
	"attack": {"damage": 8.0, "range": 1.8, "interval": 1.6},
	"xp": 10, "skill_xp": [], "loot_table": "", "harvest": {}, "despawn": "ambient",
	"respawn": 120.0, "reactions": [],
}
const ITEM_DEFAULTS := {"name": "", "stack": 20, "value": 1, "category": "misc", "color": "#c8c8c8",
	"ground_policy": "", "size": 0.25}

static var _data := {}     ## registry -> {id: entry}
static var _aliases := {}  ## registry -> {old_id: id}
static var errors: Array[String] = []


static func _ensure() -> void:
	if not _data.is_empty():
		return
	reload()


## (Re)reads every registry. Swaps the tables in one go (safe between frames).
static func reload() -> void:
	var data := {}
	var aliases := {}
	errors.clear()
	for reg in REGISTRIES:
		data[reg] = {}
		aliases[reg] = {}
		var path := DIR.path_join(reg + ".json")
		if not FileAccess.file_exists(path):
			continue
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not d is Dictionary:
			errors.append("%s: not valid JSON" % path)
			continue
		for e: Variant in (d as Dictionary).get("entries", []):
			if not e is Dictionary or str((e as Dictionary).get("id", "")) == "":
				errors.append("%s: entry without id" % path)
				continue
			var entry := _with_defaults(reg, e)
			data[reg][entry.id] = entry
			for old: Variant in entry.get("renamed_from", []):
				aliases[reg][str(old)] = entry.id
	_data = data
	_aliases = aliases


static func _with_defaults(reg: String, e: Dictionary) -> Dictionary:
	var base := {}
	match reg:
		"creatures": base = CREATURE_DEFAULTS.duplicate(true)
		"items": base = ITEM_DEFAULTS.duplicate(true)
	var out := base.merged(e, true)
	# Nested defaults (e.g. a creature that only overrides attack.damage) merge one level deep.
	for k: Variant in base:
		if base[k] is Dictionary and e.get(k) is Dictionary:
			out[k] = (base[k] as Dictionary).merged(e[k], true)
	out.id = str(out.id)
	if out.get("name", "") == "":
		out.name = out.id.capitalize()
	return out


static func get_def(registry: String, id: String) -> Dictionary:
	_ensure()
	var table: Dictionary = _data.get(registry, {})
	if table.has(id):
		return table[id]
	var alias: Variant = _aliases.get(registry, {}).get(id)
	return table.get(alias, {}) if alias != null else {}


static func has(registry: String, id: String) -> bool:
	return not get_def(registry, id).is_empty()


static func ids(registry: String) -> Array[String]:
	_ensure()
	var out: Array[String] = []
	for id: String in _data.get(registry, {}):
		out.append(id)
	out.sort()
	return out


static func all(registry: String) -> Array:
	_ensure()
	return (_data.get(registry, {}) as Dictionary).values()
