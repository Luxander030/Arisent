## A skill tree read from a "skill-tree" JSON file (format version 1), e.g. the project's
## res://Arisent-DEMO.json. Nodes have an id (what saves store), a name, a cost per rank,
## a max rank and connections to the nodes they unlock. A node can be learned when it has
## no prerequisites (a root) or when every node connecting to it has a rank (a skill
## reached from two branches needs both).
## The tree is static data; what the player learned lives in PlayerProgress.tree_ranks.
class_name SkillTree
extends RefCounted

const FORMAT := "skill-tree"
const VERSION := 1
const SETTING := "lux/skills/tree_path"
const DEFAULT_PATH := "res://Arisent-DEMO.json"
const SHAPES := ["circle", "square", "diamond"]

var name := ""
var path := ""
var nodes := {}                  ## id -> {id, name, description, pos, color, shape, icon, cost, max_rank, category, connections}
var order: Array[String] = []    ## ids in file order
var parents := {}                ## id -> Array[String] of nodes that connect to it
var errors: Array[String] = []   ## problems found while reading (bad entries are skipped)

static var _project: SkillTree


## The game's skill tree (Project Settings → lux/skills/tree_path), read once. Never null:
## a missing or broken file gives an empty tree with errors.
static func project() -> SkillTree:
	if _project == null:
		_project = load_file(str(ProjectSettings.get_setting(SETTING, DEFAULT_PATH)))
		for e in _project.errors:
			push_warning("skill tree %s: %s" % [_project.path, e])
	return _project


static func reload_project() -> SkillTree:
	_project = null
	return project()


static func load_file(p: String) -> SkillTree:
	if not FileAccess.file_exists(p):
		var t := SkillTree.new()
		t.path = p
		t.errors.append("file not found")
		return t
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	var t := from_dict(d if d is Dictionary else {})
	t.path = p
	if not d is Dictionary:
		t.errors.append("not valid JSON")
	return t


static func from_dict(d: Dictionary) -> SkillTree:
	var t := SkillTree.new()
	if d.is_empty():
		return t
	if str(d.get("format", "")) != FORMAT:
		t.errors.append("not a skill tree (format '%s')" % str(d.get("format", "")))
		return t
	if int(d.get("version", 0)) != VERSION:
		t.errors.append("version %s is not supported (this game reads version %d)" % [str(d.get("version", "?")), VERSION])
		return t
	t.name = str(d.get("name", "Skills"))
	for raw: Variant in d.get("nodes", []):
		if not raw is Dictionary:
			t.errors.append("a node that is not an object was skipped")
			continue
		var n: Dictionary = raw
		var id := str(n.get("id", "")).strip_edges()
		if id == "":
			t.errors.append("a node without an id was skipped ('%s')" % str(n.get("name", "")))
			continue
		if t.nodes.has(id):
			t.errors.append("duplicate id %s: the second one was skipped" % id)
			continue
		var shape := str(n.get("shape", "circle"))
		t.nodes[id] = {
			"id": id,
			"name": str(n.get("name", id)),
			"description": str(n.get("description", "")),
			"pos": Vector2(float(n.get("x", 0.0)), float(n.get("y", 0.0))),
			"color": Color.from_string(str(n.get("color", "#9c9c9c")), Color(0.6, 0.6, 0.6)),
			"shape": shape if shape in SHAPES else "circle",
			"icon": str(n.get("icon", "")),
			"cost": maxi(0, int(n.get("cost", 1))),
			"max_rank": maxi(1, int(n.get("maxRank", 1))),
			"category": str(n.get("category", "")),
			"connections": PackedStringArray(),
		}
		t.order.append(id)
		var conns := PackedStringArray()  # built locally: appending through the dictionary would change a copy
		for c: Variant in n.get("connections", []):
			conns.append(str(c))
		t.nodes[id].connections = conns
	for id in t.order:
		t.parents[id] = []
	for id in t.order:
		for c in (t.nodes[id].connections as PackedStringArray):
			if not t.nodes.has(c):
				t.errors.append("%s connects to %s, which does not exist" % [id, c])
				continue
			if not (t.parents[c] as Array).has(id):
				(t.parents[c] as Array).append(id)
	if not t.order.is_empty() and t.roots().is_empty():
		t.errors.append("no node is free to learn first (every node has a prerequisite)")
	return t


func has(id: String) -> bool:
	return nodes.has(id)


func node(id: String) -> Dictionary:
	return nodes.get(id, {})


func is_root(id: String) -> bool:
	return (parents.get(id, []) as Array).is_empty()


func roots() -> Array[String]:
	var out: Array[String] = []
	for id in order:
		if is_root(id):
			out.append(id)
	return out


func categories() -> PackedStringArray:
	var seen := PackedStringArray()
	for id in order:
		var c: String = nodes[id].category
		if c != "" and not seen.has(c):
			seen.append(c)
	return seen


func bounds() -> Rect2:
	var r := Rect2()
	var first := true
	for id in order:
		var p: Vector2 = nodes[id].pos
		r = Rect2(p, Vector2.ZERO) if first else r.expand(p)
		first = false
	return r


## Points the given ranks cost (ids not in this tree cost nothing).
func spent(ranks: Dictionary) -> int:
	var total := 0
	for id: String in ranks:
		if nodes.has(id):
			total += int(nodes[id].cost) * mini(int(ranks[id]), int(nodes[id].max_rank))
	return total


## Points to learn every rank of every node.
func total_cost() -> int:
	return spent(_all_maxed())


func _all_maxed() -> Dictionary:
	var out := {}
	for id in order:
		out[id] = nodes[id].max_rank
	return out


## A root, or a node all of whose prerequisites have a rank.
func is_unlocked(ranks: Dictionary, id: String) -> bool:
	return missing(ranks, id).is_empty()


## The prerequisites of `id` not learned yet (none for a root).
func missing(ranks: Dictionary, id: String) -> Array[String]:
	var out: Array[String] = []
	for p: String in parents.get(id, []):
		if int(ranks.get(p, 0)) <= 0:
			out.append(p)
	return out


## Why the next rank of `id` can't be learned with `points` free ("" if it can).
func why_not(ranks: Dictionary, points: int, id: String) -> String:
	if not nodes.has(id):
		return "There is no skill '%s'." % id
	var n: Dictionary = nodes[id]
	if int(ranks.get(id, 0)) >= int(n.max_rank):
		return "%s is mastered (rank %d of %d)." % [n.name, n.max_rank, n.max_rank]
	var need := missing(ranks, id)
	if not need.is_empty():
		var names := PackedStringArray()
		for p in need:
			names.append(str(nodes[p].name))
		var list := names[0] if names.size() == 1 else ", ".join(names.slice(0, names.size() - 1)) + " and " + names[-1]
		return "Learn %s first." % list
	if points < int(n.cost):
		return "%s needs %d skill point%s (you have %d)." % [n.name, n.cost, "" if int(n.cost) == 1 else "s", points]
	return ""


## Ranks with the ids this tree doesn't know dropped and ranks clamped to each node's max.
## Returns the ids dropped or changed (their points come back, since points are counted).
func sanitize(ranks: Dictionary) -> PackedStringArray:
	var changed := PackedStringArray()
	for id: String in ranks.keys():
		var r := int(ranks[id])
		if not nodes.has(id) or r <= 0:
			ranks.erase(id)
			changed.append(id)
		elif r > int(nodes[id].max_rank):
			ranks[id] = nodes[id].max_rank
			changed.append(id)
	return changed
