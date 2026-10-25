## Console commands of one loaded map (registered on attach, removed on detach): debug
## overlays, where am I / what is that, teleport, camps, ambient wildlife, felling,
## navigation, zones, ground items, the camera, and the "world" monitor panel.
class_name WorldCommands
extends RefCounted

const R := preload("res://world/debug/console/console_result.gd")
const P := preload("res://world/debug/console/console_parse.gd")

var s: WorldSession


static func register(session: WorldSession) -> WorldCommands:
	var wc := WorldCommands.new()
	wc.s = session
	wc._register(session.game.console)
	return wc


func _register(c: DebugConsole) -> void:
	var o := s
	var channels := P.hints_of(func() -> Array: return Array(DebugDraw.CHANNELS) + ["all"])
	c.command("show", "Draws debug helpers on the map.", "/show <channel|all> [more…]", _show, 1, ConsoleCommand.VARIADIC, channels, o)
	c.command("hide", "Stops drawing them.", "/hide <channel|all> [more…]", _hide, 1, ConsoleCommand.VARIADIC, channels, o)
	c.command("where", "Position, cell, region, biome and zones here.", "", _where, 0, 0, Callable(), o)
	c.command("info", "What the crosshair points at (entity, creature, zone).", "", _info, 0, 0, Callable(), o)
	c.command("tp", "Teleports to x z, to a zone (by name or id), or to a creature.", "/tp <x> <z> | /tp <zone|creature>", _tp, 1, 2,
		P.hints_of(_tp_targets), o)
	c.verbs("camp", "No-spawn camps (saved with the game).", o) \
		.verb("make", "Makes a camp here: nothing spawns within the radius (5-100 m, default 25).", _camp_make, 0, 1, "/camp make [radius]") \
		.verb("remove", "Removes the camps you stand in.", _camp_remove) \
		.verb("list", "Every camp on this map.", _camp_list)
	c.command("ambient", "Ambient wildlife: status, or switch it.", "/ambient [on|off]", _ambient, 0, 1, P.hints_of(["on", "off"]), o)
	c.command("fell", "Removes the nearest scattered tree or rock (remembered by id in the save).", "", _fell, 0, 0, Callable(), o)
	c.verbs("nav", "Creature navigation (navmesh tiles baked around the player).", o) \
		.verb("status", "Tiles, polygons and paths.", _nav_status) \
		.verb("rebuild", "Drops every tile; they bake again around you.", _nav_rebuild)
	c.verbs("zone", "Zones of this map.", o) \
		.verb("list", "Every zone with its roles (optionally only those with a role).", _zone_list, 0, 1, "/zone list [role]") \
		.verb("here", "The zones at your position, highest priority first.", _zone_here)
	c.verbs("items", "Items lying on the ground.", o) \
		.verb("list", "Items within a radius (default 50 m) with when they expire.", _items_list, 0, 1, "/items list [radius]") \
		.verb("drop", "Drops items in front of you (not from your bag).", _items_drop, 1, 2, "/items drop <item> [count]",
			P.hints_of(func() -> Array: return Defs.ids("items"))) \
		.verb("clear", "Removes ground items within a radius, or all.", _items_clear, 1, 1, "/items clear <radius|all>")
	c.command("fov", "Shows or sets the camera's field of view.", "/fov [degrees]", _fov, 0, 1, P.hints_of(["60", "75", "90", "110"]), o)
	c.monitors.add("world", "World", "bottom_right", _panel, KeyCombo.make(KEY_2, false, true), o)


# --- overlays, where, info -------------------------------------------------------------------

func _show(a: PackedStringArray) -> Variant:
	return _set_channels(a, true)


func _hide(a: PackedStringArray) -> Variant:
	return _set_channels(a, false)


func _set_channels(a: PackedStringArray, on: bool) -> Variant:
	var list: Array = DebugDraw.CHANNELS if a.has("all") else Array(a)
	var bad := PackedStringArray()
	for ch: String in list:
		if DebugDraw.CHANNELS.has(ch):
			s.view.debug.set_channel(ch, on)
		else:
			bad.append(ch)
	var now := "Showing %s." % (", ".join(s.view.debug.enabled_channels()) if s.view.debug.any_on() else "nothing")
	if not bad.is_empty():
		return R.failure("No channel %s. Channels: %s. %s" % [", ".join(bad), ", ".join(DebugDraw.CHANNELS), now])
	return now


func _where(_a: PackedStringArray) -> Variant:
	var f := s.focus_position()
	var c := WorldGrid.cell_coords(f)
	var b := s.map.biome_at(f) if s.map else -1
	var zs := s.view.zones.zones_at(f).map(func(z: Dictionary) -> String:
		return "%s (%s)" % [z.props.get("name", z.id), ", ".join(PackedStringArray(z.props.get("roles", [])))])
	var ground := s.queries.ground_height(f)
	return "Position %.1f %.1f %.1f (%.1f m above ground), cell %d,%d, region %s, biome %s.\nZones: %s." % [f.x, f.y, f.z, f.y - ground,
		c.x, c.y, WorldGrid.region_name(WorldGrid.region_of(f)), MapData.BIOME_NAMES[b] if b >= 0 else "none",
		", ".join(PackedStringArray(zs)) if not zs.is_empty() else "none"]


## Ray from the screen centre; reports the entity hit and the zones at that point.
func _info(_a: PackedStringArray) -> Variant:
	var cam := s.view.get_viewport().get_camera_3d()
	if cam == null:
		return R.failure("No camera.")
	var from := cam.global_position
	var to := from - cam.global_basis.z * 600.0
	var hit := s.queries.trace(from, to, PhysicsLayers.TRACE_MASK | PhysicsLayers.NPC | PhysicsLayers.EDITOR_PICK | PhysicsLayers.PROP, [], true)
	if hit.is_empty():
		return "Nothing under the crosshair."
	var lines: PackedStringArray = []
	var col: Object = hit.get("collider")
	var node := col as Node
	if node and node.has_meta("owner_node"):
		node = node.get_meta("owner_node") as Node
	while node and not node.has_meta("entity_id") and not node.has_method("debug_info"):
		node = node.get_parent()
	if node and node.has_method("debug_info"):
		lines.append(str(node.call("debug_info")))
	elif node:
		var e := s.view.entities.entity(str(node.get_meta("entity_id")))
		lines.append("Entity %s, kind %s, asset %s\nprops %s" % [e.get("id"), e.get("kind"), e.get("asset"), JSON.stringify(e.get("props", {}))])
	else:
		lines.append("Terrain." if hit.get("terrain", false) or col == null else str(col))
	var p: Vector3 = hit.position
	lines.append("At %.1f %.1f %.1f, %.0f m away." % [p.x, p.y, p.z, from.distance_to(p)])
	for z in s.view.zones.zones_at(p):
		lines.append("In zone %s [%s]." % [z.props.get("name", z.id), ", ".join(PackedStringArray(z.props.get("roles", [])))])
	return "\n".join(lines)


func _tp_targets() -> Array:
	var out: Array = []
	for id: Variant in s.view.zones.ids():
		var z := s.view.zones.get_zone(str(id))
		var n := str(z.props.get("name", ""))
		out.append(n if n != "" and not n.contains(" ") else str(id))
	return out


func _tp(a: PackedStringArray) -> Variant:
	if not s.teleport.is_valid():
		return R.failure("Teleporting is not available here.")
	var target := Vector3.INF
	if a.size() == 2 and a[0].is_valid_float() and a[1].is_valid_float():
		target = Vector3(a[0].to_float(), 0.0, a[1].to_float())
	else:
		var q := " ".join(a).to_lower()
		var rec: NpcRecord = s.npcs.records.get(" ".join(a))
		if rec:
			target = rec.pos + Vector3(2, 0, 2)
		for id: Variant in s.view.zones.ids():
			var z := s.view.zones.get_zone(str(id))
			if target == Vector3.INF and (str(z.props.get("name", "")).to_lower() == q or str(id).to_lower() == q):
				var c := ZoneShape.aabb(z).get_center()
				target = Vector3(c.x, 0.0, c.y)
	if target == Vector3.INF:
		return R.failure("Nowhere called '%s'. Use x z, a zone name or id, or a creature id." % " ".join(a))
	target.y = s.queries.ground_height(target) + 1.0
	s.teleport.call(target)
	s.game.mark_dev()
	return "Teleported to %.0f %.0f." % [target.x, target.z]


# --- camps, ambient, felling ------------------------------------------------------------------

func _camp_make(a: PackedStringArray) -> Variant:
	var z := s.make_camp(P.number(a, 0, 25.0))
	return "A camp of %.0f m: nothing spawns here (saved with the game)." % float(z.shape.radius)


func _camp_remove(_a: PackedStringArray) -> Variant:
	var n := 0
	for z in s.view.zones.zones_at(s.focus_position()):
		if s.view.zones.is_runtime(z.id):
			s.view.zones.remove(z.id)
			n += 1
	return "Removed %d camp%s." % [n, "" if n == 1 else "s"] if n > 0 else "You are not in a camp."


func _camp_list(_a: PackedStringArray) -> Variant:
	var lines := PackedStringArray()
	for id: Variant in s.view.zones.ids():
		if s.view.zones.is_runtime(str(id)):
			var z := s.view.zones.get_zone(str(id))
			lines.append("  %s at %.0f %.0f, %.0f m" % [id, z.pos[0], z.pos[2], float(z.shape.get("radius", 0.0))])
	return "No camps." if lines.is_empty() else "%d camp%s:\n%s" % [lines.size(), "" if lines.size() == 1 else "s", "\n".join(lines)]


func _ambient(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		var f := P.flag(a[0])
		if f < 0:
			return R.failure("'%s' is not on or off." % a[0])
		s.ambient.enabled = f == 1
	return "Ambient wildlife is %s: %d around. Last check: %s." % ["on" if s.ambient.enabled else "off", s.ambient.count(),
		s.ambient.last_reason if s.ambient.last_reason != "" else "none yet"]


## Generated vegetation isn't saved; removing one remembers only its stable id.
func _fell(_a: PackedStringArray) -> Variant:
	if s.game.ephemeral:
		return R.failure("not while simulating in the editor (it would change the map)")
	if s.view.terrain == null:
		return R.failure("No terrain.")
	var f := s.focus_position()
	var best := {}
	var bd := 8.0
	for it: Dictionary in s.view.terrain.instances_near(f, 8.0):
		var d := Vector2((it.position as Vector3).x - f.x, (it.position as Vector3).z - f.z).length()
		if d < bd:
			bd = d
			best = it
	if best.is_empty():
		return R.failure("Nothing scattered within 8 m.")
	var asset: String = Catalog.instanced_ids()[int(best.mesh_id)]
	var id := VegetationIds.id_for(asset, best.position)
	if not VegetationIds.remove(s.view, id):
		return R.failure("Couldn't remove it.")
	s.state.remove(id, s.now())
	return "Removed %s (%s)." % [asset, id]


# --- navigation, zones, items, camera ---------------------------------------------------------

func _nav_status(_a: PackedStringArray) -> Variant:
	if not s.navigator is NavMeshNavigator:
		return "Creatures walk straight at their targets (no navmesh here)."
	var st := (s.navigator as NavMeshNavigator).status()
	return "%d tiles (%d ready%s), %d polygons, %d creature paths. Tiles are %d m; %d around you are kept." % [st.tiles, st.ready,
		", one baking" if st.baking else "", st.polys, st.paths, int(NavMeshNavigator.TILE), (NavMeshNavigator.RADIUS_TILES * 2 + 1) ** 2]


func _nav_rebuild(_a: PackedStringArray) -> Variant:
	if not s.navigator is NavMeshNavigator:
		return R.failure("There is no navmesh here.")
	return "Dropped %d tiles; they bake again around you." % (s.navigator as NavMeshNavigator).rebuild()


func _zone_list(a: PackedStringArray) -> Variant:
	var rows: Array = [["id", "name", "roles", "priority", "shape", "runtime"]]
	for id: Variant in s.view.zones.ids():
		var z := s.view.zones.get_zone(str(id))
		var roles: Array = z.props.get("roles", [])
		if not a.is_empty() and not roles.has(a[0]):
			continue
		rows.append([str(id), str(z.props.get("name", "")), ", ".join(PackedStringArray(roles)), int(z.props.get("priority", 0)),
			str(z.get("shape", {}).get("type", "")), s.view.zones.is_runtime(str(id))])
	if rows.size() == 1:
		return "No zones." if a.is_empty() else "No zone has the role '%s'." % a[0]
	return R.rich_text("%d zones.\n%s" % [rows.size() - 1, ConsoleTable.format(rows, "single", "single", s.game.console.model.columns)])


func _zone_here(_a: PackedStringArray) -> Variant:
	var zs := s.view.zones.zones_at(s.focus_position())
	if zs.is_empty():
		return "No zone here."
	return "\n".join(PackedStringArray(zs.map(func(z: Dictionary) -> String:
		return "%s  %s  [%s]  priority %d" % [z.id, z.props.get("name", ""), ", ".join(PackedStringArray(z.props.get("roles", []))), int(z.props.get("priority", 0))])))


func _items_list(a: PackedStringArray) -> Variant:
	var r := P.number(a, 0, 50.0)
	var f := s.focus_position()
	var rows: Array = [["id", "item", "count", "distance", "kind", "expires in"]]
	for it in s.items.nearby(f, r):
		var exp := float(it.expires_at)
		rows.append([it.id, it.item, int(it.count), "%.0f m" % (it.pos as Vector3).distance_to(f), str(it.policy),
			"never" if exp < 0.0 else ConsoleBars.duration(maxf(0.0, exp - s.now()))])
	if rows.size() == 1:
		return "Nothing lies within %.0f m (%d items on the map)." % [r, s.items.items.size()]
	return R.rich_text("%d items within %.0f m, %d on the map.\n%s" % [rows.size() - 1, r, s.items.items.size(),
		ConsoleTable.format(rows, "single", "single", s.game.console.model.columns)])


func _items_drop(a: PackedStringArray) -> Variant:
	if not Defs.has("items", a[0]):
		return R.failure("No item '%s'." % a[0])
	var n := clampi(a[1].to_int() if a.size() > 1 else 1, 1, 999)
	var cam := s.view.get_viewport().get_camera_3d()
	var fwd := -cam.global_basis.z if cam else Vector3.FORWARD
	fwd.y = 0.0
	var at := s.focus_position() + fwd.normalized() * 2.0
	if s.items.drop(a[0], n, at, "player_dropped", 0.3) == "":
		return R.failure("Couldn't drop it (the area is full of items).")
	s.game.mark_dev()
	return "Dropped %d %s." % [n, a[0]]


func _items_clear(a: PackedStringArray) -> Variant:
	var ids: Array = s.items.items.keys() if a[0] == "all" else s.items.nearby(s.focus_position(), P.number(a, 0, 0.0)).map(func(it: Dictionary) -> String: return str(it.id))
	if a[0] != "all" and not a[0].is_valid_float():
		return R.failure("'%s' is not a radius or 'all'." % a[0])
	for id: String in ids:
		s.items._remove(id, "console")
	return "Removed %d item%s." % [ids.size(), "" if ids.size() == 1 else "s"]


func _fov(a: PackedStringArray) -> Variant:
	var cam := s.view.get_viewport().get_camera_3d()
	if cam == null:
		return R.failure("No camera.")
	if not a.is_empty():
		if not a[0].is_valid_float():
			return R.failure("'%s' is not an angle." % a[0])
		cam.fov = clampf(a[0].to_float(), 20.0, 140.0)
	return "Field of view %.0f°." % cam.fov


func _panel() -> String:
	var n := s.npcs.count_by_tier()
	var f := s.focus_position()
	var nav := (s.navigator as NavMeshNavigator).status() if s.navigator is NavMeshNavigator else {"ready": 0, "tiles": 0}
	return "%s  %s\ncreatures %d: %d act %d near %d far\ncorpses %d   items %d\nambient %d   nav %d/%d tiles\ncell %s  %s" % [
		s.game.time_of_day.label(), GameCommands.phase(s.game.time_of_day.hours), s.npcs.records.size(), n[0], n[1], n[2],
		s.npcs.corpses.size(), s.items.items.size(), s.ambient.count(), nav.ready, nav.tiles,
		str(WorldGrid.cell_coords(f)), WorldGrid.region_name(WorldGrid.region_of(f))]
