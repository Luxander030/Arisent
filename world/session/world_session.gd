## Runtime of one loaded map: everything that happens while playing (simulation, spawning,
## items, interaction, world state). Attaches to an existing WorldView — the game's, or the
## World Editor's for Simulate mode — adding runtime entries to the view's grid, zone index
## and debug drawing, and removes exactly those again on detach.
## Find it from any node under the view with WorldSession.of(node).
class_name WorldSession
extends Node

## A corpse's loot window should open (the game host shows it; without a listener the
## loot is simply taken).
signal loot_opened(corpse_id: String)

const PROP_LOD_INTERVAL := 0.5

var game: GameSession
var view: WorldView
var map: MapData
var focus: Node3D               ## what the simulation centres on (player, editor test focus)
var queries: WorldQueries
var teleport: Callable          ## host-provided: (Vector3) -> void
var state := WorldState.new()
var npcs: NpcManager
var items: ItemWorld
var spawns: SpawnDirector
var ambient: AmbientSpawner
var interaction: InteractionSystem
var navigator: Navigator
var commands: WorldCommands
var _nav_timer := 0.0
var _inside_triggers := {}

var _prop_timer := 0.0
var _props_awake := {}


static func attach(v: WorldView, g: GameSession, focus_node: Node3D) -> WorldSession:
	var s := WorldSession.new()
	s.name = "Session"
	s.view = v
	s.game = g
	s.map = v.map
	s.focus = focus_node
	s.queries = WorldQueries.new()
	s.queries.terrain = v.terrain
	s.queries.collision_focus = focus_node
	v.session = s
	g.world = s
	v.add_child(s)
	return s


## Removes the session and every runtime entry it added.
func detach() -> void:
	if game and game.console:
		game.console.remove_owner(self)
		game.console.remove_owner(npcs)
		game.console.remove_owner(spawns)
	if view:
		view.debug.remove_provider(_draw_debug)
		view.debug.remove_provider(_draw_nav)
		view.debug.remove_provider(npcs.draw_debug)
		navigator.free_all()
		view.debug.remove_provider(items.draw_debug)
		view.debug.remove_provider(spawns.draw_debug)
		for layer in [NpcManager.LAYER, NpcManager.CORPSE_LAYER, ItemWorld.LAYER, SpawnDirector.LAYER]:
			view.grid.clear_layer(layer)
		view.zones.clear_runtime()
		if view.session == self:
			view.session = null
	if game and game.world == self:
		game.world = null
	queue_free()


func _exit_tree() -> void:
	if navigator:
		navigator.free_all()


static func of(node: Node) -> WorldSession:
	var n := node
	while n:
		if n is WorldView:
			return (n as WorldView).session as WorldSession
		n = n.get_parent()
	return null


func _ready() -> void:
	queries.space = view.get_world_3d().direct_space_state
	npcs = NpcManager.new()
	npcs.session = self
	add_child(npcs)
	items = ItemWorld.new()
	items.session = self
	add_child(items)
	queries.record_ray = npcs.record_ray
	spawns = SpawnDirector.new()
	spawns.session = self
	add_child(spawns)
	ambient = AmbientSpawner.new()
	ambient.session = self
	add_child(ambient)
	interaction = InteractionSystem.new(self)
	var nav := NavMeshNavigator.new(self)
	if view.terrain == null:
		nav.parse_root = view  # no terrain (tests): bake from static colliders
	navigator = nav
	spawns.build()
	view.debug.add_provider(_draw_debug)
	view.debug.add_provider(_draw_nav)
	view.debug.add_provider(npcs.draw_debug)
	view.debug.add_provider(items.draw_debug)
	view.debug.add_provider(spawns.draw_debug)
	if game.console:
		commands = WorldCommands.register(self)
		npcs.register_commands(game.console)
		spawns.register_commands(game.console)
	npcs.message.connect(game.notify)
	npcs.died.connect(func(rec: NpcRecord, _k: String) -> void: navigator.forget(rec.id))
	npcs.despawned.connect(func(rec: NpcRecord) -> void: navigator.forget(rec.id))
	for e: Dictionary in view.entities.all_entities():
		var n := view.entities.node_for(e.id)
		if n is PhysicsProp:
			var eid: String = e.id
			(n as PhysicsProp).broken.connect(func() -> void: state.remove(eid, now()))
	items.message.connect(game.notify)
	items.picked_up.connect(func(item: String, n: int) -> void:
		game.notify("+%d %s" % [n, Defs.get_def("items", item).get("name", item)]))


func now() -> float:
	return game.clock.now


## Distance within which a spot counts as visible: creatures have bodies (and fade in) up
## to here; beyond it nothing is drawn, so things may appear there.
const VIEW_RANGE := 230.0


## Is this spot inside the player's field of view (and near enough to see a creature)?
## Spawning never happens where this is true.
func in_view(at: Vector3) -> bool:
	if not view.is_inside_tree():
		return false
	var cam := view.get_viewport().get_camera_3d()
	if cam == null:
		return false
	var top := at + Vector3.UP * 1.0
	return cam.global_position.distance_to(top) <= VIEW_RANGE and cam.is_position_in_frustum(top)


func focus_position() -> Vector3:
	return focus.global_position if focus and is_instance_valid(focus) else Vector3.ZERO


func _process(_delta: float) -> void:
	Perf.begin(&"session")
	_process_body(_delta)
	Perf.end(&"session")


func _process_body(_delta: float) -> void:
	view.set_time_of_day(game.time_of_day.hours)


func _physics_process(delta: float) -> void:
	Perf.begin(&"session_tick")
	_physics_process_body(delta)
	Perf.end(&"session_tick")


func _physics_process_body(delta: float) -> void:
	_rescue_focus()
	_prop_timer -= delta
	if _prop_timer <= 0.0:
		_prop_timer = PROP_LOD_INTERVAL
		_update_props()
		_update_triggers()
	_nav_timer -= delta
	if _nav_timer <= 0.0:
		_nav_timer = 0.5
		var cf := queries.collision_focus
		navigator.update(cf.global_position if cf and is_instance_valid(cf) else focus_position())


## Trigger zones: entering one sets its story flag and/or fires its story event.
func _update_triggers() -> void:
	var f := focus_position()
	var now_inside := {}
	for z in view.zones.zones_at(f):
		if EntityKinds.has_role(z, "encounter"):
			_visit_encounter(z)
		if not EntityKinds.has_role(z, "trigger"):
			continue
		now_inside[z.id] = true
		if _inside_triggers.has(z.id):
			continue
		var st := state.zone(str(z.id))
		if bool(z.props.get("once", true)) and bool(st.get("fired", false)):
			continue
		st.fired = true
		var flag := str(z.props.get("on_enter_flag", ""))
		if flag != "":
			game.story_state.set_flag(flag)
		var ev := str(z.props.get("on_enter_event", ""))
		if ev != "":
			game.story_event(ev)
	_inside_triggers = now_inside


## Never under the ground: if the player (or the editor's pawn) ends up more than 2 m below
## the terrain — teleported before collision was built there, or tunnelled — put it back.
func _rescue_focus() -> void:
	var p := focus as CharacterBody3D
	if p == null or view.terrain == null or p.get("noclip") == true:
		return
	var g := view.terrain.get_height(p.global_position)
	if p.global_position.y < g - 2.0:
		p.global_position.y = g + 0.1
		p.velocity = Vector3.ZERO
		p.reset_physics_interpolation()


## Physics props: awake only where terrain collision exists (near the focus), frozen beyond.
func _update_props() -> void:
	if not view.entities.simulate_physics:
		return
	var f := focus_position()
	var near := view.grid.query_radius(EntityLayer.GRID_LAYER, f, PhysicsProp.FREEZE_DISTANCE + 32.0)
	for id: String in _props_awake.keys():
		if not near.has(id):
			near.append(id)
	_props_awake.clear()
	for id in near:
		var n := view.entities.node_for(id)
		if n is PhysicsProp:
			var p := n as PhysicsProp
			p.update_lod(p.global_position.distance_to(f))
			if not p.lod_frozen:
				_props_awake[id] = true


## Called after `skip`: time passed everywhere near (loot ages; respawns use the clock).
func after_skip() -> void:
	items.sweep()
	npcs.age_corpses(game.last_skip)


func open_loot(cid: String) -> void:
	if loot_opened.get_connections().is_empty():
		npcs.take_loot(cid)
	else:
		loot_opened.emit(cid)


## Level of an encounter zone: locked the first time it is used (Bethesda-style), from the
## player's level clamped to the zone's band.
## Encounter zones reset after `reset_hours` of play without a visit (Bethesda-style): the
## level lock is released and whatever died inside comes back at once.
func _visit_encounter(z: Dictionary) -> void:
	var st := state.zone(str(z.id))
	var reset_h := float(z.props.get("reset_hours", 0.0))
	if reset_h > 0.0 and st.has("last_visit") and now() - float(st.last_visit) > reset_h * 3600.0:
		st.erase("level_lock")
		var n := 0
		for e: Dictionary in view.entities.all_entities():
			if e.kind in ["spawner", "zone"] and e.id != z.id and ZoneShape.contains(z, EntityKinds.position_of(e)):
				n += spawns.respawn_now(e.id)
		game.notify("%s has been repopulated." % z.props.get("name", "This area"))
	st.last_visit = now()


func encounter_level(z: Dictionary) -> int:
	var st := state.zone(str(z.id))
	if not st.has("level_lock"):
		st.level_lock = clampi(game.progress.level(), int(z.props.get("level_min", 1)), int(z.props.get("level_max", 60)))
	return int(st.level_lock)


func open_chest(id: String) -> void:
	var e := view.entities.entity(id)
	if e.is_empty() or state.is_opened(id, now(), float(e.props.get("restock_hours", 0.0))):
		return
	if bool(e.props.get("locked", false)):
		game.notify("It's locked.")
		return
	var drops := Loot.roll(str(e.props.get("loot_table", "")), Rng.hash2(hash(id), int(now()), 3))
	var got: PackedStringArray = []
	for d: Dictionary in drops:
		var n := game.inventory.add(str(d.item), int(d.count))
		if n < int(d.count):
			items.drop(str(d.item), int(d.count) - n, EntityKinds.position_of(e) + Vector3.UP * 0.5, "player_dropped")
		got.append("%s ×%d" % [Defs.get_def("items", str(d.item)).get("name", d.item), d.count])
	state.modify(id, {"opened_at": now()})
	game.notify("Chest: " + (", ".join(got) if not got.is_empty() else "empty"))


# --- debug ----------------------------------------------------------------------------

## What a save would remember around here: removed things (red X), changed ones (blue),
## dead spawns waiting to respawn (red, with time), runtime zones (cyan, drawn by zones).
func _draw_persistence(dd: DebugDraw, f: Vector3) -> void:
	var red := Color(1.0, 0.3, 0.3)
	var blue := Color(0.4, 0.7, 1.0)
	for id: String in state.removed:
		var p := Vector3.INF
		if id.begins_with("veg:"):
			p = VegetationIds.parse(id).pos
		elif map:
			for e: Dictionary in map.entities:
				if e.id == id:
					p = EntityKinds.position_of(e)
					break
		if p != Vector3.INF and p.distance_to(f) < 150.0:
			p.y = dd.ground(p.x, p.z)
			dd.line(p + Vector3(-1, 0.2, -1), p + Vector3(1, 0.2, 1), red)
			dd.line(p + Vector3(-1, 0.2, 1), p + Vector3(1, 0.2, -1), red)
			dd.text(p + Vector3.UP * 1.5, "removed: " + id.left(28), red, 32)
	for id: String in state.modified:
		var n := view.entities.node_for(id)
		if n and n.global_position.distance_to(f) < 150.0:
			dd.box(AABB(n.global_position - Vector3(0.6, 0, 0.6), Vector3(1.2, 1.2, 1.2)), blue)
			dd.text(n.global_position + Vector3.UP * 1.8, "changed: " + ", ".join(PackedStringArray((state.modified[id] as Dictionary).keys())), blue, 32)
	for sl: SpawnDirector.Slot in spawns.slots.values():
		if (sl.state == SpawnDirector.DEAD or sl.state == SpawnDirector.GONE) and sl.home.distance_to(f) < 150.0:
			var p := Vector3(sl.home.x, dd.ground(sl.home.x, sl.home.z), sl.home.z)
			dd.text(p + Vector3.UP * 1.0, "saved: %s%s" % [SpawnDirector.STATE_NAMES[sl.state], " (%ds)" % int(maxf(0.0, sl.respawn_at - now())) if sl.state == SpawnDirector.DEAD else ""], red, 32)


func _draw_nav(dd: DebugDraw) -> void:
	navigator.debug_draw(dd, focus_position())


func _draw_debug(dd: DebugDraw) -> void:
	var f := focus_position()
	if dd.is_on("zones"):
		for id: Variant in view.zones.ids():
			if view.zones.is_runtime(str(id)):
				var z := view.zones.get_zone(str(id))
				var pts := ZoneShape.world_points(z)
				dd.ground_outline(pts, Color(0.5, 0.9, 1.0))
				var c := ZoneShape.aabb(z).get_center()
				dd.text(Vector3(c.x, dd.ground(c.x, c.y) + 3.0, c.y), "%s (runtime, no spawn)" % z.props.get("name", "Camp"), Color(0.5, 0.9, 1.0))
	if dd.is_on("persistence"):
		_draw_persistence(dd, f)
	if dd.is_on("cells"):
		var c := WorldGrid.cell_coords(f)
		var cell := WorldGrid.CELL
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				var x0 := (c.x + dx) * cell
				var z0 := (c.y + dz) * cell
				var region_edge_x := posmod(c.x + dx, WorldGrid.REGION_CELLS) == 0
				var region_edge_z := posmod(c.y + dz, WorldGrid.REGION_CELLS) == 0
				dd.ground_line(Vector2(x0, z0), Vector2(x0 + cell, z0), Color(1, 1, 0.3, 0.9) if region_edge_z else Color(1, 1, 1, 0.35))
				dd.ground_line(Vector2(x0, z0), Vector2(x0, z0 + cell), Color(1, 1, 0.3, 0.9) if region_edge_x else Color(1, 1, 1, 0.35))
		var r := WorldGrid.region_of(f)
		dd.text(f + Vector3.UP * 3.0, "cell %d,%d  region %s" % [c.x, c.y, WorldGrid.region_name(r)], Color(1, 1, 0.5))
	if dd.is_on("physics"):
		for id: String in view.grid.query_radius(EntityLayer.GRID_LAYER, f, 120.0):
			var n := view.entities.node_for(id)
			if n is PhysicsProp:
				var p := n as PhysicsProp
				var col := Color(1, 0.3, 0.3) if p.lod_frozen else (Color(0.4, 1, 0.4) if not p.sleeping else Color(0.4, 0.6, 1))
				dd.box(AABB(p.global_position - Vector3(0.4, 0.0, 0.4), Vector3(0.8, 1.0, 0.8)), col)
		dd.circle(f, queries.collision_radius, Color(0.3, 0.8, 1.0), true, 64)


# --- saving -------------------------------------------------------------------------------

## This map's changes as plain data: {state: id-keyed tables, dynamic: {region: objects}}.
## Living ordinary creatures are not saved (they respawn fresh, like WoW); dead ones keep
## their respawn time; unique NPCs keep where they are and their health.
func save_state() -> Dictionary:
	_record_moved_props()
	var slots := {}
	for sl: SpawnDirector.Slot in spawns.slots.values():
		var st := sl.state
		if st == SpawnDirector.ALIVE and sl.kind != "unique":
			st = SpawnDirector.UNSPAWNED
		if st == SpawnDirector.UNSPAWNED and sl.life_count == 0:
			continue
		slots[sl.id] = {"state": st, "respawn_at": sl.respawn_at, "life_count": sl.life_count}
	var unique := {}
	for rec: NpcRecord in npcs.records.values():
		if rec.unique_id != "" and rec.alive:
			unique[rec.unique_id] = {"pos": [rec.pos.x, rec.pos.y, rec.pos.z], "health": rec.health, "yaw": rec.yaw}
	var st := state.to_dict()
	st.slots = slots
	st.unique = unique
	st.map_revision = map.revision if map else 0
	var dynamic := {}
	for it: Dictionary in items.to_save():
		var region := WorldGrid.region_name(WorldGrid.region_of(Vector3(it.pos[0], 0, it.pos[2])))
		if not dynamic.has(region):
			dynamic[region] = {"items": [], "corpses": []}
		(dynamic[region].items as Array).append(it)
	for c: Dictionary in npcs.corpses_to_save():
		var region := WorldGrid.region_name(WorldGrid.region_of(Vector3(c.pos[0], 0, c.pos[2])))
		if not dynamic.has(region):
			dynamic[region] = {"items": [], "corpses": []}
		(dynamic[region].corpses as Array).append(c)
	var rz: Array = []
	for id: Variant in view.zones.ids():
		if view.zones.is_runtime(str(id)):
			rz.append(view.zones.get_zone(str(id)).duplicate(true))
	if not rz.is_empty():
		st.runtime_zones = rz
	return {"state": st, "dynamic": dynamic}


## Physics props pushed away from where the map put them remember their new place.
func _record_moved_props() -> void:
	for e: Dictionary in view.entities.all_entities():
		var n := view.entities.node_for(e.id)
		if n is PhysicsProp and n.global_position.distance_to(EntityKinds.position_of(e)) > 1.0:
			var p := n as PhysicsProp
			if p.sleeping or p.freeze:
				var xf := p.global_transform
				state.modify(e.id, {"xform": [xf.origin.x, xf.origin.y, xf.origin.z, xf.basis.get_euler().x, xf.basis.get_euler().y, xf.basis.get_euler().z]})


## Applies a saved state of this map. Returns warnings for things that no longer match the
## map (ids removed in the editor since the save); those parts are dropped.
func apply_save(m: Dictionary) -> Array[String]:
	var warnings: Array[String] = []
	var st: Dictionary = m.get("state", {})
	var rev := int(st.get("map_revision", 0))
	if map and rev > map.revision:
		warnings.append("this save was made with a NEWER version of the map (revision %d, this map is %d) — some things may be missing" % [rev, map.revision])
	elif map and rev != map.revision:
		warnings.append("the map changed since this save (revision %d → %d)" % [rev, map.revision])
	state.from_dict(st)
	var dropped := 0
	for id: String in state.removed.keys():
		if id.begins_with("veg:"):
			if not VegetationIds.remove(view, id):
				state.removed.erase(id)  # re-scattered since: nothing there any more
				dropped += 1
		elif view.entities.has_entity(id):
			view.entities.remove_entity(id)
		else:
			state.removed.erase(id)
			dropped += 1
	for id: String in state.modified.keys():
		if not view.entities.has_entity(id):
			state.modified.erase(id)
			dropped += 1
			continue
		var x: Variant = state.modified[id].get("xform")
		var n := view.entities.node_for(id)
		if x is Array and n:
			n.global_transform = Transform3D(Basis.from_euler(Vector3(x[3], x[4], x[5])), Vector3(x[0], x[1], x[2]))
	for sid: String in st.get("slots", {}):
		var sl: SpawnDirector.Slot = spawns.slots.get(sid)
		if sl == null:
			dropped += 1  # spawner removed, or a zone's max_alive lowered
			continue
		var d: Dictionary = st.slots[sid]
		sl.state = int(d.state)
		sl.respawn_at = float(d.respawn_at)
		sl.life_count = int(d.life_count)
		if sl.state == SpawnDirector.ALIVE:
			sl.state = SpawnDirector.UNSPAWNED
	for uid: String in st.get("unique", {}):
		var sl: SpawnDirector.Slot = spawns.slots.get(uid + "#0")
		if sl == null:
			dropped += 1
			continue
		var u: Dictionary = st.unique[uid]
		var e := view.entities.entity(uid)
		if spawns._conditions.has(uid) and not (spawns._conditions[uid] as StoryCondition).evaluate(game.story_state):
			continue  # its condition no longer holds: the director decides when it appears
		var p: Array = u.pos
		spawns._spawn_slot(sl, e, Vector3(p[0], p[1], p[2]))
		var rec: NpcRecord = npcs.records.get(sl.npc_id)
		if rec:
			rec.health = float(u.health)
			rec.yaw = float(u.yaw)
	for z: Variant in st.get("runtime_zones", []):
		if z is Dictionary:
			view.zones.set_zone(z, true)
	for region: String in m.get("dynamic", {}):
		items.from_save(m.dynamic[region].get("items", []))
		npcs.corpses_from_save(m.dynamic[region].get("corpses", []))
	if dropped > 0:
		warnings.append("%d saved entries no longer match the map and were dropped" % dropped)
	return warnings


## A no-spawn camp of `radius` m around the focus (saved with the game).
func make_camp(radius: float) -> Dictionary:
	var f := focus_position()
	var z := {"id": game.new_runtime_id(), "kind": "zone", "pos": [f.x, f.y, f.z], "rot": [0.0, 0.0, 0.0],
		"props": {"name": "Camp", "roles": ["no_spawn"], "priority": 5}, "shape": {"type": "circle", "radius": clampf(radius, 5.0, 100.0)}}
	view.zones.set_zone(z, true)
	return z
