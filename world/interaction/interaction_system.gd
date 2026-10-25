## One place that decides what "use" (E) does. Gathers interactable things near the actor
## — items on the ground, corpses to harvest, chests, and whatever kinds register later
## (doors, levers, NPC talk…) — scores them by distance and how directly the actor faces
## them, and offers the best one with a prompt. Physics props held by the player's carrier
## stay the fallback (handled by the player).
##
## A source is a Callable(pos: Vector3, radius: float) -> Array of
##   {prompt: String, pos: Vector3, act: Callable(), priority: float}
class_name InteractionSystem
extends RefCounted

const RADIUS := 2.6

var session: WorldSession
var _sources: Array[Callable] = []


func _init(s: WorldSession) -> void:
	session = s
	add_source(_ground_items)
	add_source(_corpses)
	add_source(_chests)


func add_source(c: Callable) -> void:
	_sources.append(c)


## Best interaction for an actor at `pos` facing `forward`, or {}.
func best(pos: Vector3, forward: Vector3) -> Dictionary:
	var best_score := INF
	var out := {}
	var fwd := Vector3(forward.x, 0.0, forward.z).normalized()
	for src in _sources:
		for c: Dictionary in src.call(pos, RADIUS):
			var d := (c.pos as Vector3) - pos
			d.y = 0.0
			var dist := d.length()
			if dist > RADIUS:
				continue
			var facing := fwd.dot(d.normalized()) if dist > 0.3 else 1.0
			if facing < 0.2:
				continue
			var score := dist * (2.0 - facing) - float(c.get("priority", 0.0))
			if score < best_score:
				best_score = score
				out = c
	return out


func _ground_items(pos: Vector3, r: float) -> Array:
	var out: Array = []
	for it in session.items.nearby(pos, r):
		var id: String = it.id
		out.append({"prompt": "Pick up " + session.items.label(it), "pos": it.pos, "priority": 0.5,
			"act": func() -> void: session.items.pickup(id, session.game.inventory)})
	return out


func _corpses(pos: Vector3, r: float) -> Array:
	var out: Array = []
	for cid in session.view.grid.query_radius(NpcManager.CORPSE_LAYER, pos, r):
		var c: Dictionary = session.npcs.corpses.get(cid, {})
		if c.is_empty():
			continue
		var id := cid
		# WoW order: loot first, then skin.
		if not (c.loot as Array).is_empty():
			out.append({"prompt": "Loot %s" % c.name, "pos": c.pos, "priority": 0.3,
				"act": func() -> void: session.open_loot(id)})
			continue
		var h: Dictionary = Defs.get_def("creatures", str(c.archetype)).get("harvest", {})
		if h.is_empty() or c.harvested:
			continue
		out.append({"prompt": "%s %s" % [h.get("text", "Harvest"), c.name], "pos": c.pos, "priority": 0.0,
			"act": func() -> void: session.npcs.harvest(id)})
	return out


func _chests(pos: Vector3, r: float) -> Array:
	var out: Array = []
	for id in session.view.grid.query_radius(EntityLayer.GRID_LAYER, pos, r + 1.0):
		var e := session.view.entities.entity(id)
		if e.get("kind", "") != "chest":
			continue
		if session.state.is_opened(id, session.now(), float(e.props.get("restock_hours", 0.0))):
			continue
		var eid := id
		out.append({"prompt": "Open chest" + (" (locked)" if bool(e.props.get("locked", false)) else ""),
			"pos": EntityKinds.position_of(e), "priority": 0.2, "act": func() -> void: session.open_chest(eid)})
	return out
