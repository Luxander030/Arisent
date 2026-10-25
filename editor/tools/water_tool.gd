## Water bodies: click a hollow to fill it as a lake, or click points to draw a river
## (Enter finishes, Esc cancels). Rivers carve their bed into the terrain.
class_name WaterTool
extends EditorTool

const MODES := ["Lake", "River"]
const MAX_LAKE_PX := 1200

var mode := 0
var lake_depth := 3.0
var river_width := 10.0
var river_depth := 2.5
var frozen := false
var _points: Array[Vector3] = []
var _preview: MeshInstance3D


func tool_name() -> String:
	return "Water"


func tool_hint() -> String:
	return "Lake: click a hollow. River: click points downstream, Enter to finish, Esc to cancel."


func build_settings(box: VBoxContainer) -> void:
	add_option_buttons(box, MODES, mode, func(i: int) -> void:
		mode = i
		_points.clear()
		_update_preview())
	add_slider(box, "Lake depth", 0.5, 30, lake_depth, func(v: float) -> void: lake_depth = v, 0.5)
	add_slider(box, "River width", 3, 80, river_width, func(v: float) -> void: river_width = v)
	add_slider(box, "River depth", 0.5, 8, river_depth, func(v: float) -> void: river_depth = v, 0.5)
	var cb := CheckBox.new()
	cb.text = "Frozen (walkable ice)"
	cb.button_pressed = frozen
	cb.toggled.connect(func(on: bool) -> void: frozen = on)
	box.add_child(cb)
	add_label(box, "A lake fills the hollow you click up to (ground height + depth). Very large or open areas are refused.", true)


func activate() -> void:
	_preview = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.7, 1.0)
	mat.no_depth_test = true
	_preview.material_override = mat
	editor.world.add_child(_preview)


func deactivate() -> void:
	_points.clear()
	if _preview:
		_preview.queue_free()
		_preview = null


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and hit != Vector3.INF:
		if mode == 0:
			make_lake(hit)
		else:
			_points.append(hit)
			_update_preview()
		return true
	if event is InputEventKey and event.pressed and mode == 1:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if _points.size() >= 2:
				editor.add_river(_points.duplicate(), river_width, river_depth, frozen)
			_points.clear()
			_update_preview()
			return true
		if event.keycode == KEY_ESCAPE:
			_points.clear()
			_update_preview()
			return true
	return false


## Flood-fills the hollow around `hit` up to the water level (2 m sampling).
func make_lake(hit: Vector3) -> void:
	var terrain: TerrainBackend = editor.world.terrain
	var level := hit.y + lake_depth
	var R := terrain.full_res()
	var c := terrain.world_to_pixel(hit)
	var win := Rect2i(c - Vector2i(MAX_LAKE_PX, MAX_LAKE_PX) / 2, Vector2i(MAX_LAKE_PX, MAX_LAKE_PX)).intersection(Rect2i(0, 0, R, R))
	var step := 2
	var w := win.size.x / step
	var h := win.size.y / step
	var heights := terrain.read_heights(win)
	var seen := PackedByteArray()
	seen.resize(w * h)
	var start := Vector2i((c.x - win.position.x) / step, (c.y - win.position.y) / step)
	var queue: Array[Vector2i] = [start]
	seen[start.y * w + start.x] = 1
	var bb := Rect2i(start, Vector2i.ONE)
	var head := 0
	while head < queue.size():
		var p := queue[head]
		head += 1
		if p.x == 0 or p.y == 0 or p.x == w - 1 or p.y == h - 1:
			editor.toast("That area doesn't hold water at this depth (it spills out). Try a smaller depth or a deeper hollow.")
			return
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + o
			if seen[q.y * w + q.x] == 1:
				continue
			if heights[(q.y * step) * win.size.x + q.x * step] < level:
				seen[q.y * w + q.x] = 1
				queue.append(q)
				bb = bb.expand(q)
	var a := terrain.pixel_to_world(win.position + bb.position * step)
	var b := terrain.pixel_to_world(win.position + (bb.end + Vector2i.ONE) * step)
	var cells: Array[Vector2] = []
	for q in queue:
		var wp := terrain.pixel_to_world(win.position + q * step)
		cells.append(Vector2(wp.x, wp.z))
	editor.add_lake(level, Rect2(Vector2(a.x, a.z), Vector2(b.x - a.x, b.z - a.z)), cells, frozen)


func _update_preview() -> void:
	if _preview == null:
		return
	if _points.size() < 1:
		_preview.mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in _points:
		im.surface_add_vertex(p + Vector3.UP * 1.5)
	im.surface_end()
	_preview.mesh = im
