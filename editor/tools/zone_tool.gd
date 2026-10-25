## Draw and edit zones: areas with roles — spawn (creatures by table, frequency, density),
## no-spawn (towns, camps), encounter (level band), trigger (story flag/event on enter).
class_name ZoneTool
extends ShapeTool


func tool_name() -> String:
	return "Zone"


func tool_hint() -> String:
	return "Polygon: click points, Enter or click the first point to close. Circle/Box: drag. Click a zone to edit; drag its handles, Alt+click an edge adds a point, right-click a point deletes it."


func kind() -> String:
	return "zone"


func new_entity_props() -> Dictionary:
	return {"name": "Zone %d" % (editor.world.entities.entities_of_kind("zone").size() + 1)}
