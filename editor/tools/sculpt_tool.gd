## Raise / lower / smooth / flatten / holes — uses the terrain backend's brushes.
## Ground textures are re-derived under the stroke afterwards (new cliffs become rock).
class_name SculptTool
extends EditorTool

const MODES := ["Raise", "Lower", "Smooth", "Flatten", "Holes"]
const MODE_TOOLS := [TerrainBackend.Tool.RAISE, TerrainBackend.Tool.LOWER, TerrainBackend.Tool.SMOOTH,
	TerrainBackend.Tool.FLATTEN, TerrainBackend.Tool.HOLES]

var mode := 0
var _down := false
var _last := Vector3.INF


func tool_name() -> String:
	return "Sculpt"


func tool_hint() -> String:
	return "Left-drag to sculpt. Shift = opposite (lower / erase hole). [ ] size, - = strength."


func uses_brush() -> bool:
	return true


func build_settings(box: VBoxContainer) -> void:
	add_option_buttons(box, MODES, mode, func(i: int) -> void: mode = i)
	add_slider(box, "Size (m)", 2, 300, size, func(v: float) -> void: size = v)
	add_slider(box, "Strength", 1, 100, strength, func(v: float) -> void: strength = v)
	add_label(box, "Flatten uses the height where the stroke starts.", true)


func on_input(event: InputEvent, hit: Vector3) -> bool:
	var terrain: TerrainBackend = editor.world.terrain
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and hit != Vector3.INF:
			var t: int = MODE_TOOLS[mode]
			var inverted := mb.shift_pressed
			if inverted and t == TerrainBackend.Tool.RAISE:
				t = TerrainBackend.Tool.LOWER
			elif inverted and t == TerrainBackend.Tool.LOWER:
				t = TerrainBackend.Tool.RAISE
			terrain.begin_stroke(t, hit, {"size": size, "strength": strength, "erase": inverted})
			_down = true
			_last = hit
			return true
		elif not mb.pressed and _down:
			_down = false
			terrain.end_stroke()
			editor.mark_dirty()
			return true
	elif event is InputEventMouseMotion and _down and hit != Vector3.INF:
		if hit.distance_to(_last) > size * 0.08:
			terrain.stroke(hit)
			_last = hit
		return true
	return false
