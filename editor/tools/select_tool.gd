## Select placed objects, zones, paths or city buildings. Drag to move along the ground,
## , . to rotate, Delete to remove. Objects with a body are picked by physics; zones and
## paths (no body) by their shape under the mouse (smallest zone wins, outlines within a
## few metres). City buildings can be deleted (kept as an override, so they stay deleted
## if the city is regenerated).
class_name SelectTool
extends EditorTool

const OUTLINE_PICK := 4.0

var selected_id := ""        ## entity id
var selected_city_key := ""  ## city building key
var _box: MeshInstance3D
var _dragging := false
var _drag_start := {}
var _drag_offset := Vector3.ZERO
var _info: VBoxContainer


func tool_name() -> String:
	return "Select"


func tool_hint() -> String:
	return "Click an object, zone or path. Drag to move, , . rotate, Delete removes."


func build_settings(box: VBoxContainer) -> void:
	_info = VBoxContainer.new()
	box.add_child(_info)
	_refresh_info()


func activate() -> void:
	_box = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.75, 0.2)
	mat.no_depth_test = true
	_box.material_override = mat
	editor.world.add_child(_box)
	_update_box()


func deactivate() -> void:
	if _box:
		_box.queue_free()
		_box = null


## Selects an entity from outside (other tools, the problems list).
func select_entity(id: String) -> void:
	selected_id = id
	selected_city_key = ""
	_update_box()
	_refresh_info()


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pick(event.position, hit)
			if selected_id != "" and hit != Vector3.INF:
				_dragging = true
				_drag_start = _entity().duplicate(true)
				_drag_offset = EntityKinds.position_of(_drag_start) - hit
			return true
		elif _dragging:
			_dragging = false
			var e := _entity()
			if not e.is_empty() and e.pos != _drag_start.pos:
				editor.commit_entity_change(_drag_start, e.duplicate(true), "Move object")
			return true
	elif event is InputEventMouseMotion and _dragging and hit != Vector3.INF:
		var e := _entity()
		var target := hit + Vector3(_drag_offset.x, 0.0, _drag_offset.z)
		target.y = hit.y if not ZoneShape.is_area(e) and e.get("shape", {}).get("type", "") != "polyline" else editor.world.terrain.get_height(target)
		e.pos = [target.x, target.y, target.z]
		editor.world.entities.update_entity(e)
		_update_box()
		return true
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_DELETE, KEY_BACKSPACE:
				_delete()
				return true
			KEY_COMMA, KEY_PERIOD:
				var e := _entity()
				if not e.is_empty():
					var before := e.duplicate(true)
					var after := e.duplicate(true)
					after.rot[1] = float(after.rot[1]) + (-15.0 if event.keycode == KEY_COMMA else 15.0)
					editor.commit_entity_change(before, after, "Rotate object")
					_update_box()
				return true
	return false


func _pick(screen: Vector2, hit: Vector3) -> void:
	var cam: Camera3D = editor.camera
	var q := PhysicsRayQueryParameters3D.create(cam.project_ray_origin(screen), cam.project_ray_origin(screen) + cam.project_ray_normal(screen) * 6000.0,
		PhysicsLayers.WORLD | PhysicsLayers.PROP | PhysicsLayers.DEBRIS | PhysicsLayers.EDITOR_PICK)
	var res := cam.get_world_3d().direct_space_state.intersect_ray(q)
	selected_id = ""
	selected_city_key = ""
	if not res.is_empty():
		var col: Object = res.collider
		if col.has_meta("entity_id"):
			selected_id = col.get_meta("entity_id")
		else:
			var owner_id: int = (col as CollisionObject3D).shape_find_owner(res.shape)
			var shape_node := (col as CollisionObject3D).shape_owner_get_owner(owner_id) as Node
			if shape_node and shape_node.has_meta("city_key"):
				selected_city_key = shape_node.get_meta("city_key")
	if selected_id == "" and hit != Vector3.INF:
		selected_id = pick_shape(editor.world, hit)
		if selected_id != "":
			selected_city_key = ""
	_update_box()
	_refresh_info()


## Shaped entities under a ground point: paths whose line is within a few metres first,
## then the smallest zone containing the point.
static func pick_shape(world: WorldView, hit: Vector3) -> String:
	var best := ""
	var best_d := OUTLINE_PICK
	for id in world.grid.query_radius(EntityLayer.GRID_LAYER, hit, 600.0):
		var e := world.entities.entity(id)
		if e.get("shape", {}).get("type", "") == "polyline":
			var d := ZoneShape.distance_to_outline(e, hit)
			if d < best_d:
				best_d = d
				best = id
	if best != "":
		return best
	var zs := world.zones.zones_at(hit)
	var smallest := INF
	for z in zs:
		var a := ZoneShape.area(z)
		if a < smallest and not world.zones.is_runtime(z.id):
			smallest = a
			best = z.id
	return best


func _entity() -> Dictionary:
	for e: Dictionary in editor.map.entities:
		if e.id == selected_id:
			return e
	return {}


func _delete() -> void:
	if selected_id != "":
		editor.remove_entity(_entity())
	elif selected_city_key != "":
		editor.delete_city_building(selected_city_key)
	selected_id = ""
	selected_city_key = ""
	_update_box()
	_refresh_info()


func _update_box() -> void:
	if _box == null:
		return
	var ok := false
	if selected_id != "":
		var e := _entity()
		var n: Node3D = editor.world.entities.node_for(selected_id)
		if n:
			_box.mesh = _wire_box((n.global_transform * EntityLayer._aabb(n)).grow(0.3))
			ok = true
		elif e.has("shape"):
			_box.mesh = _outline(editor.world, e)
			ok = true
	elif selected_city_key != "":
		var cs: CollisionShape3D = editor.world.city.shape_for(selected_city_key)
		if cs:
			var size: Vector3 = (cs.shape as BoxShape3D).size
			_box.mesh = _wire_box((cs.global_transform * AABB(-size * 0.5, size)).grow(0.3))
			ok = true
	_box.visible = ok


func _refresh_info() -> void:
	if _info == null:
		return
	for c in _info.get_children():
		c.queue_free()
	if selected_id != "":
		var e := _entity()
		if e.is_empty():
			add_label(_info, "Nothing selected.", true)
			return
		add_label(_info, "%s" % EntityKinds.label(str(e.kind)))
		if str(e.asset) != "":
			add_label(_info, "Model: " + str(e.asset), true)
		add_label(_info, "Id: " + str(e.id), true)
		if not ZoneShape.is_area(e):
			_transform_slider("Rotation", -180.0, 180.0, float(e.rot[1]), 1.0, func(x: Dictionary, v: float) -> void: x.rot[1] = v)
		if not e.has("shape") and not EntityKinds.is_marker(str(e.kind)):
			_transform_slider("Scale", 0.1, 5.0, float(e.scale), 0.05, func(x: Dictionary, v: float) -> void: x.scale = v)
		if e.has("shape"):
			add_label(_info, "Edit the outline with the %s tool." % ("Path" if e.shape.type == "polyline" else "Zone"), true)
		PropEditors.build_all(_info, e, editor.world, _commit_prop)
		for issue: String in SpawnChecks.problems_for(e, editor.world):
			var l := add_label(_info, "⚠ " + issue)
			l.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	elif selected_city_key != "":
		add_label(_info, "City building " + selected_city_key)
		add_label(_info, "Press Delete to remove it. The removal is remembered even if the city is regenerated.", true)
	else:
		add_label(_info, "Nothing selected.", true)
	if selected_id != "" or selected_city_key != "":
		var del := Button.new()
		del.text = "Delete"
		del.pressed.connect(_delete)
		_info.add_child(del)


## A slider that previews live and records one undo step when the drag ends.
func _transform_slider(label: String, lo: float, hi: float, value: float, step: float, apply: Callable) -> void:
	var start := {}
	var preview := func(v: float) -> void:
		var e := _entity()
		if e.is_empty():
			return
		if start.is_empty():
			start.merge(e.duplicate(true))
		apply.call(e, v)
		editor.world.entities.update_entity(e)
		_update_box()
	var s := add_slider(_info, label, lo, hi, value, preview, step)
	s.drag_ended.connect(func(_changed: bool) -> void:
		var e := _entity()
		if not start.is_empty() and not e.is_empty():
			editor.commit_entity_change(start.duplicate(true), e.duplicate(true), label)
		start.clear())


## Always reads the current entity (commit_entity_change replaces the dictionary).
func _commit_prop(key: String, value: Variant, structural: bool) -> void:
	var e := _entity()
	if e.is_empty():
		return
	var before := e.duplicate(true)
	var after := e.duplicate(true)
	after.props[key] = value
	if before.props.get(key) == value:
		return
	editor.commit_entity_change(before, after, "Change " + key.replace("_", " "))
	if structural:
		_refresh_info.call_deferred()


static func _wire_box(a: AABB) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var c := [a.position, a.position + Vector3(a.size.x, 0, 0), a.position + Vector3(a.size.x, 0, a.size.z), a.position + Vector3(0, 0, a.size.z)]
	for i in 4:
		var p: Vector3 = c[i]
		var q: Vector3 = c[(i + 1) % 4]
		var up := Vector3(0, a.size.y, 0)
		for seg in [[p, q], [p + up, q + up], [p, p + up]]:
			im.surface_add_vertex(seg[0])
			im.surface_add_vertex(seg[1])
	im.surface_end()
	return im


## Outline of a shaped entity, draped on the terrain, lifted a little.
static func _outline(world: WorldView, e: Dictionary) -> ImmediateMesh:
	var im := ImmediateMesh.new()
	var pts := ZoneShape.world_points(e)
	if pts.size() < 2:
		return im
	var closed: bool = e.shape.type != "polyline"
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var n := pts.size()
	for i in (n if closed else n - 1):
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var steps := maxi(1, ceili(a.distance_to(b) / 4.0))
		for k in steps:
			var p := a.lerp(b, float(k) / steps)
			var q := a.lerp(b, float(k + 1) / steps)
			im.surface_add_vertex(Vector3(p.x, world.terrain.get_height(Vector3(p.x, 0, p.y)) + 0.8, p.y))
			im.surface_add_vertex(Vector3(q.x, world.terrain.get_height(Vector3(q.x, 0, q.y)) + 0.8, q.y))
	im.surface_end()
	return im
