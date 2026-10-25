## Draw and edit patrol paths: creatures whose spawner has movement "patrol" walk them
## (loop, back and forth, or once), waiting at each point.
class_name PathTool
extends ShapeTool


func tool_name() -> String:
	return "Path"


func tool_hint() -> String:
	return "Click points along the route, Enter finishes. Click a path to edit; drag its points, Alt+click a segment adds a point, right-click a point deletes it."


func kind() -> String:
	return "path"


func modes() -> Array[String]:
	return ["Path"]
