## Items lying on the ground. Each is a record {id, item, count, pos, policy, expires_at};
## a small visible node exists only within 60 m of the focus. Expiry is absolute play time,
## wherever the item lies, so nothing piles up in memory or in saves (owner decision):
##   loot            spilled loot (e.g. a full bag); expires after 5 minutes
##   player_dropped  put down by the player; expires after 1 hour (identical items stack)
##   quest           never expires and is never evicted
## (Creature loot stays on the corpse, WoW-style; see NpcManager.)
## Per-region caps: loot evicts its oldest; player drops beyond the cap are refused (with a
## message), never silently deleted. Coins lying around are picked up when walked over.
class_name ItemWorld
extends Node3D

signal picked_up(item_id: String, count: int)
signal message(text: String)

const LAYER := &"items"
const LOOT_TTL := 300.0
const DROPPED_TTL := 3600.0
const SWEEP := 2.0
const SIM_RANGE := 600.0
const NODE_RANGE := 60.0
const LOOT_CAP := 64
const DROP_CAP_REGION := 256
const DROP_CAP_MAP := 4096
const AUTO_PICKUP := 1.6
const TICK := 0.25

var session: WorldSession
var items := {}   ## id -> {id, item, count, pos: Vector3, policy, expires_at (-1 = never), born}
var _nodes := {}  ## id -> Node3D
var _timer := 0.0
var _sweep := 0.0


func _ready() -> void:
	name = "Items"


## Puts items on the ground. Returns the record id ("" if refused).
func drop(item_id: String, count: int, pos: Vector3, policy := "", spread := 0.6) -> String:
	if count <= 0 or not Defs.has("items", item_id):
		return ""
	var def := Defs.get_def("items", item_id)
	if policy == "":
		policy = "quest" if str(def.get("ground_policy", "")) == "quest" else "loot"
	elif str(def.get("ground_policy", "")) == "quest":
		policy = "quest"
	var region := WorldGrid.region_of(pos)
	if policy == "player_dropped":
		# Stack onto an identical player drop lying right here.
		for id in session.view.grid.query_radius(LAYER, pos, 1.5):
			var it: Dictionary = items[id]
			if it.item == item_id and it.policy == "player_dropped" and (it.pos as Vector3).distance_to(pos) < 1.5:
				it.count = int(it.count) + count
				return id
		if _count(policy, region) >= DROP_CAP_REGION or _count(policy) >= DROP_CAP_MAP:
			message.emit("Too many things lying around here; can't drop %s." % def.name)
			return ""
	elif policy == "loot":
		while _count("loot", region) >= LOOT_CAP:
			_remove(_oldest_loot(region), "evicted (loot cap)")
	var a := randf() * TAU
	var p := pos + Vector3(cos(a), 0.0, sin(a)) * randf() * spread
	p.y = session.queries.ground_height(p) + 0.05
	var id := session.game.new_runtime_id()
	var ttl := LOOT_TTL if policy == "loot" else (DROPPED_TTL if policy == "player_dropped" else -1.0)
	items[id] = {"id": id, "item": item_id, "count": count, "pos": p, "policy": policy,
		"expires_at": session.now() + ttl if ttl > 0.0 else -1.0, "born": session.now()}
	session.view.grid.put(LAYER, id, p)
	return id


func drop_loot(drops: Array, pos: Vector3) -> void:
	for d: Dictionary in drops:
		drop(str(d.item), int(d.count), pos, "", 1.2)


## Adds the item to the inventory; what doesn't fit stays on the ground.
func pickup(id: String, inv: Inventory) -> int:
	if not items.has(id):
		return 0
	var it: Dictionary = items[id]
	var n := inv.add(str(it.item), int(it.count))
	if n <= 0:
		message.emit("Your bag is full.")
		return 0
	picked_up.emit(str(it.item), n)
	if n >= int(it.count):
		_remove(id, "")
	else:
		it.count = int(it.count) - n
	return n


func nearby(pos: Vector3, radius: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in session.view.grid.query_radius(LAYER, pos, radius):
		var it: Dictionary = items[id]
		if (it.pos as Vector3).distance_to(pos) <= radius:
			out.append(it)
	return out


func label(it: Dictionary) -> String:
	var nm := str(Defs.get_def("items", str(it.item)).get("name", it.item))
	return nm if int(it.count) == 1 else "%s ×%d" % [nm, it.count]


func _physics_process(delta: float) -> void:
	Perf.begin(&"items")
	_physics_process_body(delta)
	Perf.end(&"items")


func _physics_process_body(delta: float) -> void:
	if session == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	var dt := TICK - _timer
	_timer = TICK
	var f := session.focus_position()
	_sweep -= dt
	if _sweep <= 0.0:
		_sweep = SWEEP
		sweep()
	for id in session.view.grid.query_radius(LAYER, f, NODE_RANGE):
		var it: Dictionary = items.get(id, {})
		if it.is_empty():
			continue
		var d := (it.pos as Vector3).distance_to(f)
		if str(it.item) == "coin" and it.policy != "player_dropped" and d <= AUTO_PICKUP and session.focus is PlayerController and (session.focus as PlayerController).health > 0.0:
			pickup(id, session.game.inventory)
			continue
		if d <= NODE_RANGE and not _nodes.has(id):
			_nodes[id] = _make_node(it)
	for id: String in _nodes.keys():
		if not items.has(id) or (items[id].pos as Vector3).distance_to(f) > NODE_RANGE + 20.0:
			(_nodes[id] as Node).queue_free()
			_nodes.erase(id)


## Removes everything whose time is up (anywhere on the map).
func sweep() -> void:
	var t := session.now()
	for id: String in items.keys():
		var e := float(items[id].expires_at)
		if e >= 0.0 and t >= e:
			_remove(id, "expired")


func _remove(id: String, _why: String) -> void:
	if id == "" or not items.has(id):
		return
	items.erase(id)
	session.view.grid.remove(LAYER, id)
	if _nodes.has(id):
		(_nodes[id] as Node).queue_free()
		_nodes.erase(id)


func _count(policy: String, region := Vector2i(1 << 30, 0)) -> int:
	var n := 0
	for it: Dictionary in items.values():
		if it.policy == policy and (region.x == 1 << 30 or WorldGrid.region_of(it.pos) == region):
			n += 1
	return n


func _oldest_loot(region: Vector2i) -> String:
	var best := ""
	var t := INF
	for it: Dictionary in items.values():
		if it.policy == "loot" and WorldGrid.region_of(it.pos) == region and float(it.born) < t:
			t = float(it.born)
			best = it.id
	return best


func _make_node(it: Dictionary) -> Node3D:
	var def := Defs.get_def("items", str(it.item))
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var size := float(def.get("size", 0.25))
	var mesh: Mesh
	if str(it.item) == "coin":
		var c := CylinderMesh.new()
		c.top_radius = size * 0.5
		c.bottom_radius = size * 0.5
		c.height = size * 0.25
		mesh = c
	else:
		var b := BoxMesh.new()
		b.size = Vector3.ONE * size
		mesh = b
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_string(str(def.get("color", "#cccccc")), Color.WHITE)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.35
	mat.metallic = 0.6 if str(it.item) == "coin" else 0.0
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.position.y = size * 0.5 + 0.05
	root.add_child(mi)
	root.set_meta("ground_item", it.id)
	add_child(root)
	root.global_position = it.pos
	var tw := root.create_tween().set_loops()
	tw.tween_property(mi, "rotation:y", TAU, 3.0).from(0.0)
	return root


func draw_debug(dd: DebugDraw) -> void:
	if not dd.is_on("items"):
		return
	var f := session.focus_position()
	for id in session.view.grid.query_radius(LAYER, f, 120.0):
		var it: Dictionary = items[id]
		var p: Vector3 = it.pos
		var col: Color = {"loot": Color(1, 0.9, 0.4), "player_dropped": Color(0.5, 1, 0.6), "quest": Color(0.8, 0.6, 1)}.get(it.policy, Color.WHITE)
		dd.line(p, p + Vector3.UP * 1.2, col)
		var ttl := "never expires" if float(it.expires_at) < 0.0 else "expires in %ds" % int(float(it.expires_at) - session.now())
		dd.text(p + Vector3.UP * 1.4, "%s  [%s, %s]" % [label(it), it.policy, ttl], col)


func to_save() -> Array:
	var out: Array = []
	for it: Dictionary in items.values():
		var p: Vector3 = it.pos
		out.append({"id": it.id, "item": it.item, "count": it.count, "pos": [p.x, p.y, p.z],
			"policy": it.policy, "expires_at": it.expires_at, "born": it.born})
	return out


func from_save(list: Array) -> void:
	for it: Dictionary in list:
		var p: Array = it.pos
		var rec := {"id": str(it.id), "item": str(it.item), "count": int(it.count), "pos": Vector3(p[0], p[1], p[2]),
			"policy": str(it.policy), "expires_at": float(it.get("expires_at", -1.0)), "born": float(it.get("born", 0.0))}
		if not Defs.has("items", rec.item):
			continue
		items[rec.id] = rec
		session.view.grid.put(LAYER, rec.id, rec.pos)
