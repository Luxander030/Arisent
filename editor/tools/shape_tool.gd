## Shared editing of shaped entities (zones, patrol paths): draw a new shape, select one
## by clicking inside / on it, drag its handles. Every finished edit is one undo step
## (committed on mouse release). Subclasses choose the kind and the drawing modes.
##   Draw:   polygon/path — click points, Enter (or click the first point) finishes,
##           Backspace removes the last point, Esc cancels;
##           circle — drag from the centre; box — drag from corner to corner.
##   Edit:   drag a handle; Alt+click an edge inserts a point; right-click a point deletes it;
##           Delete removes the shape.
class_name ShapeTool
extends EditorTool

const HANDLE_PX := 12.0

var mode := 0                 ## index into modes()
var selected_id := ""
var _draft: Array[Vector3] = []
var _drag_from := Vector3.INF  ## circle/box drawing start
var _drag_handle := -1         ## handle index being dragged (-2 = circle radius)
var _drag_before := {}
var _gizmo: MeshInstance3D
var _info: VBoxContainer
var _preview_points := PackedVector3Array()


## Override: entity kind ("zone" / "path") and drawing modes.
func kind() -> String:
	return "zone"


func modes() -> Array[String]:
	return ["Polygon", "Circle", "Box"]


func new_entity_props() -> Dictionary:
	return {}


func activate() -> void:
	_gizmo = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 12
	_gizmo.material_override = mat
	_gizmo.mesh = ImmediateMesh.new()
	editor.world.add_child(_gizmo)
	editor.world.debug.add_provider(_draw_candidates)


func deactivate() -> void:
	if _gizmo:
		_gizmo.queue_free()
		_gizmo = null
	editor.world.debug.remove_provider(_draw_candidates)
	_draft.clear()
	_drag_from = Vector3.INF


func build_settings(box: VBoxContainer) -> void:
	add_option_buttons(box, modes(), mode, func(i: int) -> void:
		mode = i
		_draft.clear())
	_info = VBoxContainer.new()
	box.add_child(_info)
	_refresh_info()


func _entity() -> Dictionary:
	for e: Dictionary in editor.map.entities:
		if e.id == selected_id:
			return e
	return {}


func select(id: String) -> void:
	selected_id = id
	_refresh_preview()
	_refresh_info()


# --- input ------------------------------------------------------------------------------------

func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				if not _draft.is_empty():
					_finish_draft()
					return true
			KEY_BACKSPACE:
				if not _draft.is_empty():
					_draft.pop_back()
					return true
			KEY_ESCAPE:
				if not _draft.is_empty() or _drag_from != Vector3.INF:
					_draft.clear()
					_drag_from = Vector3.INF
					return true
			KEY_DELETE:
				if selected_id != "" and _draft.is_empty():
					editor.remove_entity(_entity())
					select("")
					return true
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and selected_id != "":
			var h := _handle_at(mb.position)
			if h >= 0:
				_delete_point(h)
				return true
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			return _press(mb, hit)
		return _release(hit)
	if event is InputEventMouseMotion and hit != Vector3.INF:
		if _drag_handle != -1:
			_move_handle(hit)
			return true
	return false


func _press(mb: InputEventMouseButton, hit: Vector3) -> bool:
	# Dragging a handle of the selected shape?
	if selected_id != "" and _draft.is_empty():
		var h := _handle_at(mb.position)
		if h != -1:
			_drag_handle = h
			_drag_before = _entity().duplicate(true)
			return true
		if mb.alt_pressed and hit != Vector3.INF and _insert_point(hit):
			return true
	if hit == Vector3.INF:
		return true
	var shape_type := _new_shape_type()
	if not _draft.is_empty() or shape_type == "polygon" or shape_type == "polyline":
		if _draft.is_empty():
			# Clicking an existing shape of this kind selects it instead of starting a new one.
			var picked := SelectTool.pick_shape(editor.world, hit)
			if picked != "" and editor.world.entities.entity(picked).kind == kind():
				select(picked)
				return true
		if _draft.size() >= 3 and shape_type == "polygon" and _screen_dist(_draft[0], mb.position) < HANDLE_PX:
			_finish_draft()
		else:
			_draft.append(hit)
		return true
	var picked := SelectTool.pick_shape(editor.world, hit)
	if picked != "" and editor.world.entities.entity(picked).kind == kind():
		select(picked)
		return true
	_drag_from = hit
	return true


func _release(hit: Vector3) -> bool:
	if hit == Vector3.INF and _drag_handle == -1:
		_drag_from = Vector3.INF  # released over the sky / UI: drop the half-made shape
	if _drag_handle != -1:
		_drag_handle = -1
		var e := _entity()
		if not e.is_empty() and e != _drag_before:
			editor.commit_entity_change(_drag_before, e.duplicate(true), "Edit " + kind())
		_refresh_preview()
		_refresh_info()
		return true
	if _drag_from != Vector3.INF and hit != Vector3.INF:
		var a := _drag_from
		_drag_from = Vector3.INF
		if Vector2(hit.x - a.x, hit.z - a.z).length() < 2.0:
			return true
		var e: Dictionary
		if _new_shape_type() == "circle":
			e = _make_entity(a)
			e.shape = {"type": "circle", "radius": Vector2(hit.x - a.x, hit.z - a.z).length()}
		else:
			var c := (a + hit) * 0.5
			e = _make_entity(c)
			e.shape = {"type": "box", "size": [absf(hit.x - a.x), absf(hit.z - a.z)]}
		editor.add_entity(e)
		select(e.id)
		return true
	return _drag_from != Vector3.INF


func _new_shape_type() -> String:
	if kind() == "path":
		return "polyline"
	return ["polygon", "circle", "box"][clampi(mode, 0, 2)]


func _make_entity(center: Vector3) -> Dictionary:
	var e := EntityKinds.make(editor.new_id(), "", kind(), center, 0.0, 1.0)
	e.props.merge(new_entity_props(), true)
	return e


func _finish_draft() -> void:
	var need := 2 if kind() == "path" else 3
	if _draft.size() < need:
		editor.toast("Need at least %d points." % need)
		return
	var c := Vector3.ZERO
	for p in _draft:
		c += p
	c /= _draft.size()
	if kind() == "path":
		c = _draft[0]
	c.y = editor.world.terrain.get_height(c)
	var e := _make_entity(c)
	var pts: Array = []
	for p in _draft:
		pts.append([p.x - c.x, p.z - c.z])
	e.shape = {"type": "polyline" if kind() == "path" else "polygon", "points": pts}
	if kind() == "path":
		e.shape.waits = []
	_draft.clear()
	editor.add_entity(e)
	select(e.id)


# --- handles ---------------------------------------------------------------------------------

## World positions of the selected shape's handles (points, or the circle's rim / box corners).
func _handles() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var e := _entity()
	if e.is_empty():
		return out
	var s: Dictionary = e.shape
	var t: TerrainBackend = editor.world.terrain
	match str(s.type):
		"circle":
			var p := EntityKinds.position_of(e) + Vector3(float(s.radius), 0, 0)
			out.append(Vector3(p.x, t.get_height(p), p.z))
		_:
			for q in ZoneShape.world_points(e):
				out.append(Vector3(q.x, t.get_height(Vector3(q.x, 0, q.y)), q.y))
	return out


func _handle_at(screen: Vector2) -> int:
	var hs := _handles()
	for i in hs.size():
		if _screen_dist(hs[i], screen) < HANDLE_PX:
			return -2 if str(_entity().shape.type) == "circle" else i
	return -1


func _screen_dist(p: Vector3, screen: Vector2) -> float:
	var cam: Camera3D = editor.camera
	if cam.is_position_behind(p):
		return INF
	return cam.unproject_position(p).distance_to(screen)


func _move_handle(hit: Vector3) -> void:
	var e := _entity()
	if e.is_empty():
		return
	var s: Dictionary = e.shape
	match str(s.type):
		"circle":
			s.radius = maxf(1.0, Vector2(hit.x - e.pos[0], hit.z - e.pos[2]).length())
		"box":
			var l := ZoneShape.to_local(e, Vector2(hit.x, hit.z))
			s.size = [maxf(1.0, absf(l.x) * 2.0), maxf(1.0, absf(l.y) * 2.0)]
		_:
			var l := ZoneShape.to_local(e, Vector2(hit.x, hit.z))
			(s.points as Array)[_drag_handle] = [l.x, l.y]
	editor.world.entities.update_entity(e)


func _insert_point(hit: Vector3) -> bool:
	var e := _entity()
	if e.is_empty() or not (e.shape.type == "polygon" or e.shape.type == "polyline"):
		return false
	var pts := ZoneShape.world_points(e)
	var p := Vector2(hit.x, hit.z)
	var closed: bool = e.shape.type == "polygon"
	var best := -1
	var best_d := 6.0
	for i in (pts.size() if closed else pts.size() - 1):
		var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[(i + 1) % pts.size()]))
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return false
	var before := e.duplicate(true)
	var l := ZoneShape.to_local(e, p)
	(e.shape.points as Array).insert(best + 1, [l.x, l.y])
	editor.world.entities.update_entity(e)
	editor.commit_entity_change(before, e.duplicate(true), "Insert point")
	return true


func _delete_point(i: int) -> void:
	var e := _entity()
	var pts: Array = e.shape.get("points", [])
	var minimum := 3 if e.shape.type == "polygon" else 2
	if i < 0 or pts.size() <= minimum:
		return
	var before := e.duplicate(true)
	pts.remove_at(i)
	editor.world.entities.update_entity(e)
	editor.commit_entity_change(before, e.duplicate(true), "Delete point")


# --- drawing ----------------------------------------------------------------------------------

func process(_delta: float, hit: Vector3) -> void:
	if _gizmo == null:
		return
	var im := _gizmo.mesh as ImmediateMesh
	im.clear_surfaces()
	var lines := PackedVector3Array()
	var colors := PackedColorArray()
	var t: TerrainBackend = editor.world.terrain
	var add := func(a: Vector3, b: Vector3, c: Color) -> void:
		lines.append(a + Vector3.UP * 0.4)
		lines.append(b + Vector3.UP * 0.4)
		colors.append(c)
		colors.append(c)
	# Draft being drawn.
	var draft_col := Color(1.0, 1.0, 0.4)
	for i in range(1, _draft.size()):
		add.call(_draft[i - 1], _draft[i], draft_col)
	if not _draft.is_empty() and hit != Vector3.INF:
		add.call(_draft[-1], hit, Color(draft_col, 0.6))
	if _drag_from != Vector3.INF and hit != Vector3.INF:
		if _new_shape_type() == "circle":
			var r := Vector2(hit.x - _drag_from.x, hit.z - _drag_from.z).length()
			var prev := Vector3.ZERO
			for k in 49:
				var a := TAU * k / 48.0
				var p := _drag_from + Vector3(cos(a) * r, 0, sin(a) * r)
				p.y = t.get_height(p)
				if k > 0:
					add.call(prev, p, draft_col)
				prev = p
		else:
			var a := _drag_from
			var corners := [a, Vector3(hit.x, 0, a.z), hit, Vector3(a.x, 0, hit.z)]
			for k in 4:
				var p: Vector3 = corners[k]
				var q: Vector3 = corners[(k + 1) % 4]
				add.call(Vector3(p.x, t.get_height(p), p.z), Vector3(q.x, t.get_height(q), q.z), draft_col)
	# Handles of the selected shape.
	for h in _handles():
		var s := 1.2
		add.call(h + Vector3(-s, 0, 0), h + Vector3(s, 0, 0), Color.WHITE)
		add.call(h + Vector3(0, 0, -s), h + Vector3(0, 0, s), Color.WHITE)
		add.call(h, h + Vector3.UP * 2.0, Color.WHITE)
	if lines.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in lines.size():
		im.surface_set_color(colors[i])
		im.surface_add_vertex(lines[i])
	im.surface_end()


## Where the selected spawn zone can put creatures (the baked candidate points).
func _refresh_preview() -> void:
	var e := _entity()
	_preview_points = ZoneCandidates.bake(e, editor.world) if not e.is_empty() and EntityKinds.has_role(e, "spawn") else PackedVector3Array()


func _draw_candidates(dd: DebugDraw) -> void:
	if not dd.is_on("spawns") or _preview_points.is_empty():
		return
	var step := maxi(1, _preview_points.size() / 400)
	for i in range(0, _preview_points.size(), step):
		var q := _preview_points[i]
		dd.line(q, q + Vector3.UP * 1.0, Color(1.0, 0.85, 0.3, 0.8))


# --- inspector ----------------------------------------------------------------------------------

func _refresh_info() -> void:
	if _info == null:
		return
	for c in _info.get_children():
		c.queue_free()
	var e := _entity()
	if e.is_empty():
		add_label(_info, tool_hint(), true)
		return
	add_label(_info, "%s  (%s)" % [EntityKinds.label(kind()), str(e.props.get("name", "")) if str(e.props.get("name", "")) != "" else str(e.id).right(6)])
	if ZoneShape.is_area(e):
		var area := ZoneShape.area(e)
		var line := "Area %.0f m²" % area
		if EntityKinds.has_role(e, "spawn"):
			var usable := ZoneCandidates.usable_fraction(e, _preview_points)
			var alive := int(e.props.get("max_alive", 1))
			line += "   usable for spawning %.0f %%   one creature per %.0f m²" % [usable * 100.0, area * usable / maxi(1, alive)]
		add_label(_info, line, true)
	else:
		var pts := ZoneShape.world_points(e)
		var length := 0.0
		for i in range(1, pts.size()):
			length += pts[i - 1].distance_to(pts[i])
		add_label(_info, "%d points, %.0f m long" % [pts.size(), length], true)
	PropEditors.build_all(_info, e, editor.world, _commit_prop)
	for issue: String in SpawnChecks.problems_for(e, editor.world):
		var l := add_label(_info, "⚠ " + issue)
		l.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	var del := Button.new()
	del.text = "Delete " + EntityKinds.label(kind()).to_lower()
	del.pressed.connect(func() -> void:
		editor.remove_entity(_entity())
		select(""))
	_info.add_child(del)


func _commit_prop(key: String, value: Variant, structural: bool) -> void:
	var e := _entity()
	if e.is_empty() or e.props.get(key) == value:
		return
	var before := e.duplicate(true)
	var after := e.duplicate(true)
	after.props[key] = value
	editor.commit_entity_change(before, after, "Change " + key.replace("_", " "))
	_refresh_preview()
	if structural:
		_refresh_info.call_deferred()
