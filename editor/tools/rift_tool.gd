## Drag a line to cut a rift / canyon. The rift is stored as a modifier (part of the
## procedural height layer), so it can be edited or survives regeneration.
class_name RiftTool
extends EditorTool

var width := 40.0
var depth := 30.0
var roughness := 0.5
var _start := Vector3.INF
var _end := Vector3.INF
var _preview: MeshInstance3D


func tool_name() -> String:
	return "Rift"


func tool_hint() -> String:
	return "Left-drag to draw the rift's centre line, release to carve it."


func build_settings(box: VBoxContainer) -> void:
	add_slider(box, "Width (m)", 6, 300, width, func(v: float) -> void: width = v)
	add_slider(box, "Depth (m)", 2, 200, depth, func(v: float) -> void: depth = v)
	add_slider(box, "Roughness", 0, 1, roughness, func(v: float) -> void: roughness = v, 0.05)


func activate() -> void:
	_preview = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.2, 0.6)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	_preview.material_override = mat
	editor.world.add_child(_preview)


func deactivate() -> void:
	if _preview:
		_preview.queue_free()
		_preview = null


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and hit != Vector3.INF:
			_start = hit
			_end = hit
			return true
		elif not mb.pressed and _start != Vector3.INF:
			if _start.distance_to(_end) > 4.0:
				var mod := {"type": "rift", "id": editor.new_id(),
					"a": [_start.x, _start.z], "b": [_end.x, _end.z],
					"width": width, "depth": depth, "roughness": roughness}
				editor.add_modifier(mod)
			_start = Vector3.INF
			_update_preview()
			return true
	elif event is InputEventMouseMotion and _start != Vector3.INF and hit != Vector3.INF:
		_end = hit
		_update_preview()
		return true
	return false


func _update_preview() -> void:
	if not _preview:
		return
	if _start == Vector3.INF:
		_preview.mesh = null
		return
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var dir := Vector3(_end.x - _start.x, 0, _end.z - _start.z).normalized()
	var side := Vector3(-dir.z, 0, dir.x) * width * 0.5
	var terrain: TerrainBackend = editor.world.terrain
	for i in 21:
		var p := _start.lerp(_end, i / 20.0)
		p.y = terrain.get_height(p) + 1.5
		im.surface_add_vertex(p - side)
		im.surface_add_vertex(p + side)
	im.surface_end()
	_preview.mesh = im
