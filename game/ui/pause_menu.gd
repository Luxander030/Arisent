## The game's pause menu (Esc while the mouse is free): Resume, Settings, Main menu. The
## game is paused while it is open; this layer keeps running.
class_name PauseMenu
extends CanvasLayer

signal resumed
signal quit_to_menu

var world: WorldView
var _menu: VBoxContainer
var _settings: SettingsPanel


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 12)
	_menu.custom_minimum_size.x = 260
	center.add_child(_menu)
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	_menu.add_child(title)
	_button("Resume", func() -> void: resumed.emit())
	_button("Settings", open_settings)
	_button("Main menu", func() -> void: quit_to_menu.emit())


func _button(text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	_menu.add_child(b)


func open_settings() -> void:
	_menu.visible = false
	_settings = SettingsPanel.new()
	_settings.world = world
	_settings.closed.connect(close_settings)
	add_child(_settings)


func close_settings() -> void:
	if _settings:
		_settings.queue_free()
		_settings = null
	_menu.visible = true


func settings_open() -> bool:
	return _settings != null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _settings:
			close_settings()
		else:
			resumed.emit()
