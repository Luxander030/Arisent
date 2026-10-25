extends Control
## Main menu: New game (Start), Continue (the most recent save), Load (pick a save slot),
## Options, Quit. The game host reads the choice from GameLaunch.

var _saves := SaveService.new()


func _ready() -> void:
	GraphicsSettings.current().apply_window(get_window())
	var box := $CenterContainer/VBoxContainer as VBoxContainer
	var slots := _saves.list_slots()
	if not slots.is_empty():
		var latest: Dictionary = slots[0]
		var cont := Button.new()
		cont.text = "Continue  (%s, level %d)" % [latest.map_name, latest.level]
		cont.pressed.connect(func() -> void:
			GameLaunch.continue_latest()
			_play())
		box.add_child(cont)
		box.move_child(cont, 1)
		var load_btn := Button.new()
		load_btn.text = "Load game…"
		load_btn.pressed.connect(_show_loads.bind(slots))
		box.add_child(load_btn)
		box.move_child(load_btn, 3)
	($CenterContainer/VBoxContainer/PlayButton as Button).text = "New game"


func _play() -> void:
	get_tree().change_scene_to_file("res://game/world_game.tscn")


func _show_loads(slots: Array) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Load game"
	dlg.ok_button_text = "Cancel"
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(520, 260)
	for s: Dictionary in slots:
		var i := list.add_item("%s  —  %s, level %d, played %d min  (%s)" % [s.slot, s.map_name, s.level, int(s.play_time / 60.0), s.saved_at])
		list.set_item_metadata(i, s.slot)
	list.item_activated.connect(func(i: int) -> void:
		GameLaunch.load_slot(str(list.get_item_metadata(i)))
		_play())
	dlg.add_child(list)
	add_child(dlg)
	dlg.popup_centered()


# This function runs when the player clicks "Play Game"
func _on_play_button_pressed() -> void:
	GameLaunch.new_game()
	_play()

# This function runs when the player clicks "Options"
func _on_options_button_pressed() -> void:
	var box := $CenterContainer/VBoxContainer as VBoxContainer
	box.visible = false
	var panel := SettingsPanel.new()
	panel.closed.connect(func() -> void:
		panel.queue_free()
		box.visible = true)
	add_child(panel)

# This function runs when the player clicks "Quit"
func _on_quit_button_pressed() -> void:
	get_tree().quit()
