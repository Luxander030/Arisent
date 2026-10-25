## Stands in for Terrain3D's EditorPlugin so its editing tools work in our own app.
## Terrain3D reads `ui` (must be a Node) and calls the four undo methods.
class_name TerrainPluginShim
extends Node

var ui: Node = Node.new()
var undo_redo: UndoRedo
var _pending: Array = []


func create_undo_action(action_name: String) -> void:
	if undo_redo:
		undo_redo.create_action(action_name)


func add_undo_method(c: Callable) -> void:
	if undo_redo:
		undo_redo.add_undo_method(c)


func add_do_method(c: Callable) -> void:
	if undo_redo:
		undo_redo.add_do_method(c)


func commit_action(execute: bool) -> void:
	if undo_redo:
		undo_redo.commit_action(execute)
