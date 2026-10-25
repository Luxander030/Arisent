## Registry of entity kinds and their editable properties (the schema). The editor builds
## its inspector from these rows; the game looks up behaviour in KindRegistry by the same
## kind. Adding a kind = adding an entry here (+ a behaviour in KindRegistry); no format
## change.
##
## A prop row is [name, type, default, a, b, opts]:
##   TYPE_FLOAT / TYPE_INT   a, b = min, max
##   TYPE_BOOL, TYPE_STRING, TYPE_COLOR (saved as "#rrggbbaa")
##   "enum"                  a = Array of option strings
##   "ref:<registry>"        id from a data registry (Defs), e.g. "ref:creatures"
##   "entity_ref:<kind>"     id of another entity of that kind ("" = none)
##   "table:<schema>"        Array of row dictionaries, columns from TABLES[schema]
##   "condition"             story condition dictionary (StoryCondition.to_dict()), {} = always
##   "roles"                 Array of role names, options in a
## opts (optional Dictionary): {"role": <zone role this prop belongs to>, "hint": "..."}.
class_name EntityKinds
extends RefCounted

const ZONE_ROLES := ["spawn", "no_spawn", "encounter", "trigger"]

## Column schemas for "table:<schema>" props.
const TABLES := {
	"spawn_rows": [["archetype", "ref:creatures", ""], ["weight", TYPE_FLOAT, 1.0, 0.0, 100.0],
		["group_min", TYPE_INT, 1, 1, 10], ["group_max", TYPE_INT, 1, 1, 10],
		["level_min", TYPE_INT, 0, 0, 60], ["level_max", TYPE_INT, 0, 0, 60]],
}

## kind -> {label, props, shape?: default shape type, marker?: true for editor-only markers}
const KINDS := {
	"prop": {"label": "Prop", "props": []},
	"building": {"label": "Building", "props": [["name", TYPE_STRING, ""]]},
	"physics_prop": {"label": "Physics prop", "props": []},
	"ladder": {"label": "Ladder", "props": [["height", TYPE_FLOAT, 4.0, 1.0, 20.0]]},
	"moving_platform": {"label": "Moving platform", "props": [["travel_x", TYPE_FLOAT, 0.0, -50.0, 50.0],
		["travel_y", TYPE_FLOAT, 4.0, -50.0, 50.0], ["travel_z", TYPE_FLOAT, 0.0, -50.0, 50.0],
		["speed", TYPE_FLOAT, 2.0, 0.2, 15.0], ["wait", TYPE_FLOAT, 1.5, 0.0, 10.0]]},
	"npc_dummy": {"label": "Training dummy", "props": [["health", TYPE_FLOAT, 100.0, 1.0, 1000.0]]},
	"spawn_point": {"label": "Player spawn", "marker": true, "props": [["is_default", TYPE_BOOL, false]]},
	"chest": {"label": "Chest", "props": [["loot_table", "ref:loot_tables", "chest_common"],
		["locked", TYPE_BOOL, false], ["restock_hours", TYPE_FLOAT, 0.0, 0.0, 720.0, {"hint": "0 = never refills"}]]},
	"spawner": {"label": "Spawner", "marker": true, "props": [
		["archetype", "ref:creatures", ""],
		["count", TYPE_INT, 1, 1, 20],
		["wander_radius", TYPE_FLOAT, 8.0, 0.0, 80.0],
		["movement", "enum", "wander", ["idle", "wander", "patrol"]],
		["path", "entity_ref:path", ""],
		["respawn", TYPE_FLOAT, 120.0, 5.0, 7200.0, {"hint": "seconds of play time"}],
		["respawn_jitter", TYPE_FLOAT, 0.2, 0.0, 1.0],
		["level", TYPE_INT, 0, 0, 60, {"hint": "0 = archetype default"}],
		["group", "entity_ref:spawn_group", ""],
		["group_weight", TYPE_FLOAT, 0.0, 0.0, 100.0, {"hint": "0 = share what the others leave"}],
		["condition", "condition", {}]]},
	"unique_npc": {"label": "Unique NPC", "marker": true, "props": [
		["archetype", "ref:creatures", ""],
		["name", TYPE_STRING, ""],
		["wander_radius", TYPE_FLOAT, 4.0, 0.0, 80.0],
		["movement", "enum", "idle", ["idle", "wander", "patrol"]],
		["path", "entity_ref:path", ""],
		["respawn", TYPE_FLOAT, 0.0, 0.0, 7200.0, {"hint": "0 = never comes back once killed"}],
		["level", TYPE_INT, 0, 0, 60],
		["condition", "condition", {}]]},
	"spawn_group": {"label": "Spawn group", "marker": true, "props": [
		["name", TYPE_STRING, ""],
		["max_alive", TYPE_INT, 1, 1, 50, {"hint": "how many members may be alive at once"}],
		["manual", TYPE_BOOL, false, {"hint": "only scripts / story events spawn it"}],
		["leader", "entity_ref:spawner", "", {"hint": "members wait while the leader is dead"}]]},
	"path": {"label": "Patrol path", "shape": "polyline", "props": [
		["mode", "enum", "loop", ["loop", "pingpong", "once"]],
		["wait", TYPE_FLOAT, 2.0, 0.0, 30.0, {"hint": "seconds at each point"}]]},
	"zone": {"label": "Zone", "shape": "polygon", "props": [
		["name", TYPE_STRING, ""],
		["roles", "roles", ["spawn"], ZONE_ROLES],
		["color", TYPE_COLOR, "#e0803a80"],
		["priority", TYPE_INT, 0, -10, 10],
		["parent_zone", "entity_ref:zone", ""],
		["spawn_table", "table:spawn_rows", [], null, null, {"role": "spawn"}],
		["max_alive", TYPE_INT, 8, 1, 200, {"role": "spawn"}],
		["check_interval", TYPE_FLOAT, 10.0, 1.0, 120.0, {"role": "spawn", "hint": "seconds between spawn checks"}],
		["spawn_chance", TYPE_FLOAT, 1.0, 0.0, 1.0, {"role": "spawn", "hint": "chance per check"}],
		["initial", "enum", "full", ["full", "trickle"], null, {"role": "spawn"}],
		["respawn", TYPE_FLOAT, 180.0, 5.0, 7200.0, {"role": "spawn"}],
		["respawn_jitter", TYPE_FLOAT, 0.3, 0.0, 1.0, {"role": "spawn"}],
		["wander_radius", TYPE_FLOAT, 12.0, 0.0, 80.0, {"role": "spawn"}],
		["min_player_dist", TYPE_FLOAT, 30.0, 0.0, 200.0, {"role": "spawn"}],
		["slope_max", TYPE_FLOAT, 35.0, 0.0, 80.0, {"role": "spawn", "hint": "degrees"}],
		["alt_min", TYPE_FLOAT, -500.0, -500.0, 3000.0, {"role": "spawn"}],
		["alt_max", TYPE_FLOAT, 3000.0, -500.0, 3000.0, {"role": "spawn"}],
		["allow_water", TYPE_BOOL, false, {"role": "spawn"}],
		["tod_start", TYPE_FLOAT, 0.0, 0.0, 24.0, {"role": "spawn", "hint": "hour the window opens"}],
		["tod_end", TYPE_FLOAT, 24.0, 0.0, 24.0, {"role": "spawn"}],
		["condition", "condition", {}, null, null, {"role": "spawn"}],
		["level_min", TYPE_INT, 1, 1, 60, {"role": "encounter"}],
		["level_max", TYPE_INT, 60, 1, 60, {"role": "encounter"}],
		["reset_hours", TYPE_FLOAT, 0.0, 0.0, 720.0, {"role": "encounter", "hint": "play hours until a cleared zone resets; 0 = never"}],
		["on_enter_flag", TYPE_STRING, "", null, null, {"role": "trigger"}],
		["on_enter_event", TYPE_STRING, "", null, null, {"role": "trigger", "hint": "story cell id to trigger"}],
		["once", TYPE_BOOL, true, {"role": "trigger"}]]},
}


## Options dictionary of a prop row (rows may omit it; bool/string rows put it at index 3).
static func row_opts(row: Array) -> Dictionary:
	for i in range(3, row.size()):
		if row[i] is Dictionary:
			return row[i]
	return {}


static func defaults(kind: String) -> Dictionary:
	var out := {}
	for p: Array in KINDS.get(kind, {}).get("props", []):
		out[p[0]] = p[2].duplicate(true) if p[2] is Array or p[2] is Dictionary else p[2]
	return out


static func label(kind: String) -> String:
	return str(KINDS.get(kind, {}).get("label", kind))


static func is_marker(kind: String) -> bool:
	return bool(KINDS.get(kind, {}).get("marker", false))


static func kind_for_category(category: String, entry := {}) -> String:
	match category:
		"building": return "building"
		"physics": return "physics_prop"
		"gameplay", "spawning":
			var g := str(entry.get("gameplay", ""))
			return {"ladder": "ladder", "platform": "moving_platform", "dummy": "npc_dummy",
				"spawn": "spawn_point", "spawner": "spawner", "unique_npc": "unique_npc",
				"spawn_group": "spawn_group", "chest": "chest"}.get(g, "prop")
	return "prop"


## New entity dictionary (the saved form). Shaped kinds get a default shape.
static func make(id: String, asset: String, kind: String, pos: Vector3, yaw_deg: float, scale: float) -> Dictionary:
	var e := {"id": id, "kind": kind, "asset": asset, "pos": [pos.x, pos.y, pos.z], "rot": [0.0, yaw_deg, 0.0],
		"scale": scale, "props": defaults(kind), "layer": "default"}
	var shape := str(KINDS.get(kind, {}).get("shape", ""))
	if shape != "":
		e.shape = ZoneShape.default_shape(shape)
	return e


## Fills missing fields and restores types lost in JSON (ints come back as floats).
static func normalize(e: Dictionary) -> Dictionary:
	var out := e.duplicate(true)
	out.id = str(out.get("id", ""))
	out.kind = str(out.get("kind", "prop"))
	out.asset = str(out.get("asset", ""))
	out.pos = _floats(out.get("pos", [0, 0, 0]), 3)
	out.rot = _floats(out.get("rot", [0, 0, 0]), 3)
	out.scale = float(out.get("scale", 1.0))
	out.layer = str(out.get("layer", "default"))
	var props: Dictionary = out.get("props", {}) if out.get("props") is Dictionary else {}
	var schema: Array = KINDS.get(out.kind, {}).get("props", [])
	var fixed := defaults(out.kind)
	for row: Array in schema:
		if props.has(row[0]):
			fixed[row[0]] = coerce(row, props[row[0]])
	for k: String in props:
		if not fixed.has(k):
			fixed[k] = props[k]  # unknown props are kept (forward compatible)
	out.props = fixed
	if out.has("shape") and out.shape is Dictionary:
		out.shape = ZoneShape.normalize(out.shape)
	elif KINDS.get(out.kind, {}).has("shape"):
		out.shape = ZoneShape.default_shape(str(KINDS[out.kind].shape))
	return out


## Converts a stored value to the row's type.
static func coerce(row: Array, v: Variant) -> Variant:
	var t: Variant = row[1]
	if t is int:
		match int(t):
			TYPE_INT: return int(v) if (v is float or v is int or v is bool) else int(str(v).to_int())
			TYPE_FLOAT: return float(v) if (v is float or v is int) else str(v).to_float()
			TYPE_BOOL: return bool(v)
			TYPE_STRING, TYPE_COLOR: return str(v)
		return v
	var ts := str(t)
	if ts.begins_with("table:"):
		var cols: Array = TABLES.get(ts.trim_prefix("table:"), [])
		var rows: Array = []
		for r: Variant in (v if v is Array else []):
			if not r is Dictionary:
				continue
			var row_out := {}
			for c: Array in cols:
				row_out[c[0]] = coerce(c, (r as Dictionary).get(c[0], c[2]))
			rows.append(row_out)
		return rows
	if ts == "roles":
		var roles: Array = []
		for x: Variant in (v if v is Array else []):
			roles.append(str(x))
		return roles
	if ts == "condition":
		return v if v is Dictionary else {}
	return str(v)


static func _floats(a: Variant, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(float(a[i]) if a is Array and i < (a as Array).size() else 0.0)
	return out


static func transform_of(e: Dictionary) -> Transform3D:
	var p: Array = e.pos
	var r: Array = e.get("rot", [0, 0, 0])
	var s := float(e.get("scale", 1.0)) * float(Catalog.get_entry(str(e.get("asset", ""))).get("scale", 1.0))
	var b := Basis.from_euler(Vector3(deg_to_rad(r[0]), deg_to_rad(r[1]), deg_to_rad(r[2])), EULER_ORDER_YXZ)
	return Transform3D(b.scaled(Vector3.ONE * s), Vector3(p[0], p[1], p[2]))


static func position_of(e: Dictionary) -> Vector3:
	var p: Array = e.pos
	return Vector3(p[0], p[1], p[2])


static func has_role(e: Dictionary, role: String) -> bool:
	return (e.get("props", {}).get("roles", []) as Array).has(role)
