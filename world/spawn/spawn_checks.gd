## Authoring checks for spawning data: missing creature/loot references, spawners in
## no-spawn zones or under water, empty spawn tables, groups without members, broken
## paths, unrealistic densities. Shown in the editor inspector and the Problems list,
## and by the console's `problems` command.
class_name SpawnChecks
extends RefCounted


static func problems_for(e: Dictionary, view: WorldView) -> Array[String]:
	var out: Array[String] = []
	var p: Dictionary = e.get("props", {})
	var pos := EntityKinds.position_of(e)
	match str(e.kind):
		"spawner", "unique_npc":
			var arch := str(p.get("archetype", ""))
			if arch == "":
				out.append("No archetype chosen: nothing will spawn.")
			elif not Defs.has("creatures", arch):
				out.append("Archetype '%s' does not exist in creatures.json." % arch)
			if str(p.get("movement", "")) == "patrol":
				var path_id := str(p.get("path", ""))
				if path_id == "":
					out.append("Movement is 'patrol' but no path is set.")
				elif not view.entities.has_entity(path_id):
					out.append("The patrol path no longer exists.")
			var g := str(p.get("group", ""))
			if g != "" and not view.entities.has_entity(g):
				out.append("Its spawn group no longer exists.")
			if view.zones.has_role_at(pos, "no_spawn"):
				out.append("It stands inside a no-spawn zone.")
			if view.terrain and view.water_level_at(pos) > view.terrain.get_height(pos) + 0.5:
				out.append("It stands in water.")
			elif view.terrain and view.terrain.get_normal(pos).y < cos(deg_to_rad(40.0)):
				out.append("The ground here is very steep.")
		"zone":
			if EntityKinds.has_role(e, "spawn"):
				var rows: Array = p.get("spawn_table", [])
				if rows.is_empty():
					out.append("The spawn table is empty: nothing will spawn.")
				for r: Dictionary in rows:
					if not Defs.has("creatures", str(r.get("archetype", ""))):
						out.append("Spawn table row uses unknown archetype '%s'." % r.get("archetype", ""))
				var area := ZoneShape.area(e)
				var alive := int(p.get("max_alive", 0))
				if area > 0.0 and alive > 0 and area / alive < 100.0:
					out.append("Very dense: %d alive in %.0f m² (one per %.0f m²)." % [alive, area, area / alive])
				if float(p.get("alt_min", -500.0)) > float(p.get("alt_max", 3000.0)):
					out.append("Altitude window is empty (min above max).")
			if ZoneShape.area(e) < 1.0:
				out.append("The zone has no area.")
			var parent := str(p.get("parent_zone", ""))
			if parent != "" and not view.entities.has_entity(parent):
				out.append("Its parent zone no longer exists.")
		"spawn_group":
			var members := 0
			for s in view.entities.entities_of_kind("spawner"):
				if str(s.props.get("group", "")) == e.id:
					members += 1
			if members == 0:
				out.append("No spawners belong to this group.")
			var leader := str(p.get("leader", ""))
			if leader != "" and not view.entities.has_entity(leader):
				out.append("The leader spawner no longer exists.")
		"path":
			if (e.get("shape", {}).get("points", []) as Array).size() < 2:
				out.append("A path needs at least two points.")
		"chest":
			if not Defs.has("loot_tables", str(p.get("loot_table", ""))):
				out.append("Loot table '%s' does not exist." % p.get("loot_table", ""))
	return out


## Every problem in the map: [[entity_id, message], ...].
static func all_problems(view: WorldView) -> Array:
	var out: Array = []
	for e: Dictionary in view.entities.all_entities():
		for msg in problems_for(e, view):
			out.append([e.id, msg])
	return out
