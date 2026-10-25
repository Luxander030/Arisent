## Pick a model from the catalog and click to place it on the ground.
class_name PlaceTool
extends EditorTool

const CATEGORIES := [["Trees", "tree"], ["Plants", "plant"], ["Rocks", "rock"], ["Small", "small"], ["Props", "prop"],
	["Physics props", "physics"], ["Gameplay", "gameplay"], ["Spawning", "spawning"], ["Buildings", "building"]]

var category := 0
var asset := ""
var random_yaw := true
var scale_min := 0.9
var scale_max := 1.2
var _ghost: Node3D
var _list: ItemList
var _ghost_yaw := 0.0
var _ghost_scale := 1.0


func tool_name() -> String:
	return "Place"


func tool_hint() -> String:
	return "Click to place the selected model. , and . rotate the preview."


func build_settings(box: VBoxContainer) -> void:
	add_option_buttons(box, CATEGORIES.map(func(c: Array) -> String: return c[0]), category, func(i: int) -> void:
		category = i
		_fill_list())
	_list = ItemList.new()
	_list.custom_minimum_size.y = 260
	_list.item_selected.connect(func(i: int) -> void:
		asset = _list.get_item_metadata(i)
		_make_ghost())
	box.add_child(_list)
	_fill_list()
	var cb := CheckBox.new()
	cb.text = "Random rotation"
	cb.button_pressed = random_yaw
	cb.toggled.connect(func(on: bool) -> void: random_yaw = on)
	box.add_child(cb)
	add_slider(box, "Scale min", 0.2, 3.0, scale_min, func(v: float) -> void: scale_min = v, 0.05)
	add_slider(box, "Scale max", 0.2, 3.0, scale_max, func(v: float) -> void: scale_max = v, 0.05)


func _fill_list() -> void:
	if _list == null:
		return
	_list.clear()
	for id in Catalog.ids(CATEGORIES[category][1]):
		var i := _list.add_item(id.get_slice(".", 1).replace("_", " ").capitalize())
		_list.set_item_metadata(i, id)
		if id == asset:
			_list.select(i)
	if asset == "" and _list.item_count > 0:
		_list.select(0)
		asset = _list.get_item_metadata(0)
		_make_ghost()


func activate() -> void:
	_make_ghost()


func deactivate() -> void:
	if _ghost:
		_ghost.queue_free()
		_ghost = null


func _make_ghost() -> void:
	if _ghost:
		_ghost.queue_free()
		_ghost = null
	if asset == "" or editor.map == null:
		return
	var scene := Catalog.scene(asset)
	if scene == null:
		return
	_ghost = scene.instantiate()
	_roll()
	editor.world.add_child(_ghost)
	_ghost.visible = false


func _roll() -> void:
	_ghost_yaw = randf() * 360.0 if random_yaw else 0.0
	_ghost_scale = randf_range(scale_min, maxf(scale_min, scale_max))


func process(_delta: float, hit: Vector3) -> void:
	if _ghost == null:
		return
	_ghost.visible = hit != Vector3.INF
	if hit != Vector3.INF:
		var s := _ghost_scale * float(Catalog.get_entry(asset).get("scale", 1.0))
		_ghost.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(_ghost_yaw)).scaled(Vector3.ONE * s), hit)


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and hit != Vector3.INF and asset != "":
		var entry := Catalog.get_entry(asset)
		var kind := EntityKinds.kind_for_category(str(entry.get("category", "")), entry)
		editor.add_entity(EntityKinds.make(editor.new_id(), asset, kind, hit, _ghost_yaw, _ghost_scale))
		_roll()
		return true
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_COMMA:
				_ghost_yaw -= 15.0
				return true
			KEY_PERIOD:
				_ghost_yaw += 15.0
				return true
	return false
