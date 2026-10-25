@tool
extends EditorPlugin
## Adds the "Story" main-screen tab. StoryGraph resources open in it (double-click a
## .tres in the FileSystem dock); edits go into the editor's undo history and are saved
## with the rest of the project (Ctrl+S) or from the tab's Story menu.

const StoryEditor := preload("editor/story_editor.gd")
const Ed := preload("editor/edscale.gd")

var panel: StoryEditor


func _enter_tree() -> void:
	Ed.value = EditorInterface.get_editor_scale()
	panel = StoryEditor.new()
	panel.name = "StoryEditor"
	panel.in_editor = true
	panel.editor_undo = get_undo_redo()
	panel.story_saved.connect(_on_story_saved)
	EditorInterface.get_editor_main_screen().add_child(panel)
	_make_visible(false)


func _exit_tree() -> void:
	if is_instance_valid(panel):
		panel.queue_free()
	panel = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if panel:
		panel.visible = visible


func _get_plugin_name() -> String:
	return "Story"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("GraphEdit", "EditorIcons")


func _handles(object: Object) -> bool:
	return object is StoryGraph


func _edit(object: Object) -> void:
	if object is StoryGraph and object != panel.graph:
		panel.edit_graph(object)
		EditorInterface.set_main_screen_editor("Story")


func _save_external_data() -> void:
	if panel and panel.has_unsaved() and panel.graph.resource_path.begins_with("res://"):
		panel.save_story()


func _get_unsaved_status(for_scene: String) -> String:
	if for_scene == "" and panel and panel.has_unsaved():
		return "Save changes to the story \"%s\" before closing?" % panel.graph.title
	return ""


func _on_story_saved(path: String) -> void:
	EditorInterface.get_resource_filesystem().update_file(path)
