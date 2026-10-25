## Paints vegetation density (more / less / none) for one group — trees, bushes, rocks,
## small plants. The paint is a saved layer; affected regions are re-scattered from the
## rules, so painting never conflicts with regeneration.
class_name VegetationTool
extends EditorTool

const MODES := ["More", "Less", "Remove", "Reset"]
const PAINT_RES_M := 4.0  ## metres per paint pixel

var group := 0
var mode := 0
var _down := false
var _last := Vector3.INF
var _stroke_rect := Rect2()
var _before := {}  ## group -> Image copy at stroke start
var _pending := 0.0


func tool_name() -> String:
	return "Vegetation"


func tool_hint() -> String:
	return "Left-drag to paint vegetation density. Plants regrow from the rules in painted areas."


func uses_brush() -> bool:
	return true


func build_settings(box: VBoxContainer) -> void:
	add_label(box, "Group")
	add_option_buttons(box, ["Trees", "Bushes", "Rocks", "Small plants"], group, func(i: int) -> void: group = i)
	add_label(box, "Mode")
	add_option_buttons(box, MODES, mode, func(i: int) -> void: mode = i)
	add_slider(box, "Size (m)", 5, 300, size, func(v: float) -> void: size = v)
	add_slider(box, "Strength", 1, 100, strength, func(v: float) -> void: strength = v)
	add_label(box, "Grass follows the grass ground texture — use Paint to add or remove it.", true)


func _image() -> Image:
	var key: String = Scatter.GROUP_NAMES[group]
	var map: MapData = editor.map
	if not map.scatter_paint.has(key):
		var n := roundi(map.map_m / PAINT_RES_M)
		var img := Image.create_empty(n, n, false, Image.FORMAT_L8)
		img.fill(Color(128.0 / 255.0, 0, 0))
		map.scatter_paint[key] = img
		editor.invalidate_scatter()
	return map.scatter_paint[key]


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and hit != Vector3.INF:
			_down = true
			_before = {group: _image().duplicate()}
			_stroke_rect = Rect2(Vector2(hit.x, hit.z), Vector2.ZERO)
			_dab(hit)
			_last = hit
			return true
		elif not event.pressed and _down:
			_down = false
			_finish()
			return true
	elif event is InputEventMouseMotion and _down and hit != Vector3.INF:
		if hit.distance_to(_last) > size * 0.15:
			_dab(hit)
			_last = hit
		return true
	return false


func _dab(hit: Vector3) -> void:
	var img := _image()
	var map: MapData = editor.map
	var n := img.get_width()
	var c := Vector2((hit.x / map.map_m + 0.5) * n, (hit.z / map.map_m + 0.5) * n)
	var r := size * 0.5 / PAINT_RES_M
	var amount := strength / 100.0
	for y in range(maxi(0, floori(c.y - r)), mini(n, ceili(c.y + r))):
		for x in range(maxi(0, floori(c.x - r)), mini(n, ceili(c.x + r))):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / r
			if d > 1.0:
				continue
			var f := (1.0 - d * d) * amount
			var v := img.get_pixel(x, y).r
			match mode:
				0: v = minf(1.0, v + f * 0.25)
				1: v = maxf(0.0, v - f * 0.25)
				2: v = lerpf(v, 0.0, minf(1.0, f * 2.0))
				3: v = lerpf(v, 128.0 / 255.0, minf(1.0, f * 2.0))
			img.set_pixel(x, y, Color(v, 0, 0))
	_stroke_rect = _stroke_rect.expand(Vector2(hit.x, hit.z) - Vector2(size, size) * 0.5).expand(Vector2(hit.x, hit.z) + Vector2(size, size) * 0.5)


func _finish() -> void:
	var g := group
	var before: Image = _before[g]
	var after := _image().duplicate() as Image
	var rect := _stroke_rect
	var ur: UndoRedo = editor.undo
	ur.create_action("Paint vegetation")
	ur.add_do_method(_set_paint.bind(g, after, rect))
	ur.add_undo_method(_set_paint.bind(g, before, rect))
	ur.commit_action(true)


func _set_paint(g: int, img: Image, rect: Rect2) -> void:
	(editor.map.scatter_paint[Scatter.GROUP_NAMES[g]] as Image).copy_from(img)
	editor.rescatter(rect)
	editor.mark_dirty()
