## Immediate-mode debug drawing ("gizmos") shared by the World Editor and the game.
## Systems register a provider callable; every frame, if any channel is on, providers are
## called with this node and draw lines, circles, filled areas and labels for the channels
## that are enabled. Editor gizmos and in-game overlays use the same provider code, so
## they look the same by construction.
##
## Channels: zones, spawns, ai, cells, nav, physics, items, persistence.
## Defaults: everything off (the game); the editor turns on zones + spawns.
class_name DebugDraw
extends Node3D

signal channels_changed

const CHANNELS: Array[String] = ["zones", "spawns", "ai", "cells", "nav", "physics", "items", "persistence"]
const LABEL_RANGE := 150.0
const MAX_LABELS := 64

var terrain: TerrainBackend   ## for draping lines on the ground (optional)
var _on := {}
var _providers: Array[Callable] = []

var _lv := PackedVector3Array()   # depth-tested lines
var _lc := PackedColorArray()
var _xv := PackedVector3Array()   # always-on-top lines
var _xc := PackedColorArray()
var _tv := PackedVector3Array()   # translucent triangles
var _tc := PackedColorArray()
var _lines_mi: MeshInstance3D
var _xray_mi: MeshInstance3D
var _tris_mi: MeshInstance3D
var _labels: Array[Label3D] = []
var _labels_used := 0
var _cached := {}  ## key -> {mi, version, used}
var _cam_pos := Vector3.ZERO
var _cam: Camera3D
var _label_rects: Array[Rect2] = []


func _ready() -> void:
	_lines_mi = _make_mi(_material(false, false))
	_xray_mi = _make_mi(_material(true, false))
	_tris_mi = _make_mi(_material(false, true))
	set_process(any_on())


func _make_mi(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = ArrayMesh.new()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0
	add_child(mi)
	return mi


static func _material(xray: bool, fill: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.no_depth_test = xray
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if fill:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	if xray:
		m.render_priority = 10
	return m


# --- channels -------------------------------------------------------------------------

func set_channel(ch: String, enabled: bool) -> void:
	if bool(_on.get(ch, false)) == enabled:
		return
	_on[ch] = enabled
	if is_inside_tree():
		if any_on():
			set_process(true)
		else:
			_process(0.0)  # one last pass clears everything, then no work at all while off
			set_process(false)
	channels_changed.emit()


func is_on(ch: String) -> bool:
	return bool(_on.get(ch, false))


func any_on() -> bool:
	for ch: String in _on:
		if _on[ch]:
			return true
	return false


func enabled_channels() -> Array[String]:
	var out: Array[String] = []
	for ch in CHANNELS:
		if is_on(ch):
			out.append(ch)
	return out


func add_provider(c: Callable) -> void:
	if not _providers.has(c):
		_providers.append(c)


func remove_provider(c: Callable) -> void:
	_providers.erase(c)


# --- frame ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	_cam = cam
	_cam_pos = cam.global_position if cam else Vector3.ZERO
	_label_rects.clear()
	_lv.clear(); _lc.clear(); _xv.clear(); _xc.clear(); _tv.clear(); _tc.clear()
	_labels_used = 0
	for k: String in _cached:
		_cached[k].used = false
	if any_on():
		for p in _providers.duplicate():
			if p.is_valid():
				p.call(self)
	_flush(_lines_mi, Mesh.PRIMITIVE_LINES, _lv, _lc)
	_flush(_xray_mi, Mesh.PRIMITIVE_LINES, _xv, _xc)
	_flush(_tris_mi, Mesh.PRIMITIVE_TRIANGLES, _tv, _tc)
	for i in range(_labels_used, _labels.size()):
		_labels[i].visible = false
	for k: String in _cached.keys():
		var c: Dictionary = _cached[k]
		(c.mi as MeshInstance3D).visible = c.used


static func _flush(mi: MeshInstance3D, prim: Mesh.PrimitiveType, v: PackedVector3Array, c: PackedColorArray) -> void:
	var am := mi.mesh as ArrayMesh
	am.clear_surfaces()
	if v.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_COLOR] = c
	am.add_surface_from_arrays(prim, arrays)


func camera_position() -> Vector3:
	return _cam_pos


## Height of the ground at (x, z) (0 without terrain).
func ground(x: float, z: float) -> float:
	return terrain.get_height(Vector3(x, 0.0, z)) if terrain else 0.0


# --- primitives -----------------------------------------------------------------------

func line(a: Vector3, b: Vector3, color: Color, xray := false) -> void:
	if xray:
		_xv.append(a); _xv.append(b); _xc.append(color); _xc.append(color)
	else:
		_lv.append(a); _lv.append(b); _lc.append(color); _lc.append(color)


func polyline(points: PackedVector3Array, color: Color, closed := false, xray := false) -> void:
	var n := points.size()
	for i in (n if closed else n - 1):
		line(points[i], points[(i + 1) % n], color, xray)


## A line along the ground between two XZ points, sampled every `step` metres.
func ground_line(a: Vector2, b: Vector2, color: Color, lift := 0.3, step := 4.0, xray := false) -> void:
	var n := maxi(1, ceili(a.distance_to(b) / step))
	var prev := Vector3(a.x, ground(a.x, a.y) + lift, a.y)
	for i in range(1, n + 1):
		var q := a.lerp(b, float(i) / n)
		var cur := Vector3(q.x, ground(q.x, q.y) + lift, q.y)
		line(prev, cur, color, xray)
		prev = cur


## Outline of an XZ polygon/polyline draped on the ground.
func ground_outline(points: PackedVector2Array, color: Color, closed := true, lift := 0.3, xray := false) -> void:
	var n := points.size()
	for i in (n if closed else n - 1):
		ground_line(points[i], points[(i + 1) % n], color, lift, 4.0, xray)


func circle(center: Vector3, radius: float, color: Color, drape := true, segments := 32, xray := false) -> void:
	var prev := Vector3.ZERO
	for i in segments + 1:
		var a := TAU * i / segments
		var p := center + Vector3(cos(a) * radius, 0.0, sin(a) * radius)
		if drape:
			p.y = ground(p.x, p.z) + 0.3
		if i > 0:
			line(prev, p, color, xray)
		prev = p


func box(aabb: AABB, color: Color, xray := false) -> void:
	var p := aabb.position
	var s := aabb.size
	var c := [p, p + Vector3(s.x, 0, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, 0, s.z)]
	for i in 4:
		var a: Vector3 = c[i]
		var b: Vector3 = c[(i + 1) % 4]
		var up := Vector3(0, s.y, 0)
		line(a, b, color, xray)
		line(a + up, b + up, color, xray)
		line(a, a + up, color, xray)


func sphere(center: Vector3, radius: float, color: Color, xray := false) -> void:
	for axis in 3:
		var prev := Vector3.ZERO
		for i in 25:
			var a := TAU * i / 24.0
			var v := Vector3(cos(a), sin(a), 0.0) if axis == 0 else (Vector3(cos(a), 0.0, sin(a)) if axis == 1 else Vector3(0.0, cos(a), sin(a)))
			var q := center + v * radius
			if i > 0:
				line(prev, q, color, xray)
			prev = q


func arrow(a: Vector3, b: Vector3, color: Color, xray := false) -> void:
	line(a, b, color, xray)
	var d := b - a
	if d.length() < 0.01:
		return
	var side := d.cross(Vector3.UP).normalized() * minf(1.0, d.length() * 0.2)
	var back := -d.normalized() * minf(1.5, d.length() * 0.3)
	line(b, b + back + side, color, xray)
	line(b, b + back - side, color, xray)


func triangle(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	_tv.append(a); _tv.append(b); _tv.append(c)
	_tc.append(color); _tc.append(color); _tc.append(color)


## Floating text; only near the camera and up to MAX_LABELS per frame. A label that would
## cover one already drawn this frame moves up a line, so crowds stay readable.
func text(pos: Vector3, s: String, color := Color.WHITE, size := 48) -> void:
	if _labels_used >= MAX_LABELS or pos.distance_to(_cam_pos) > LABEL_RANGE:
		return
	if _cam and not _cam.is_position_behind(pos):
		var sp := _cam.unproject_position(pos)
		var h := float(size) * 0.42
		var rect := Rect2(sp.x - s.length() * h * 0.28, sp.y - h, s.length() * h * 0.56, h)
		var shift := 0.0
		var moved := true
		var guard := 0
		while moved and guard < 12:
			moved = false
			guard += 1
			for r in _label_rects:
				if r.intersects(rect):
					rect.position.y = r.position.y - h - 1.0
					shift += 1.0
					moved = true
		_label_rects.append(rect)
		if shift > 0.0:
			# Pixels -> metres at this distance.
			var vp_h := get_viewport().get_visible_rect().size.y
			var m_per_px := 2.0 * pos.distance_to(_cam_pos) * tan(deg_to_rad(_cam.fov * 0.5)) / maxf(vp_h, 1.0)
			pos += Vector3.UP * (sp.y - rect.end.y) * m_per_px
	if _labels_used >= _labels.size():
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0008
		l.outline_size = 10
		l.render_priority = 20
		l.outline_render_priority = 19
		add_child(l)
		_labels.append(l)
	var lab := _labels[_labels_used]
	_labels_used += 1
	lab.visible = true
	lab.global_position = pos
	lab.text = s
	lab.modulate = color
	lab.font_size = size


## A filled XZ polygon draped on the terrain, built once per (key, version) and reused.
func ground_fill(key: String, version: int, points: PackedVector2Array, color: Color, lift := 0.25) -> void:
	var c: Variant = _cached.get(key)
	if c == null or int(c.version) != version:
		if c != null:
			(c.mi as MeshInstance3D).queue_free()
		var mi := MeshInstance3D.new()
		mi.mesh = _drape_mesh(points, lift)
		mi.material_override = _material(false, true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		c = {"mi": mi, "version": version, "used": false}
		_cached[key] = c
	c.used = true
	var mat := (c.mi as MeshInstance3D).material_override as StandardMaterial3D
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = false


func forget(key: String) -> void:
	if _cached.has(key):
		(_cached[key].mi as MeshInstance3D).queue_free()
		_cached.erase(key)


## Delaunay over the outline plus an interior grid, keeping triangles inside the polygon,
## each vertex at ground height: follows hills instead of cutting through them.
func _drape_mesh(outline: PackedVector2Array, lift: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if outline.size() < 3:
		return mesh
	var rect := Rect2(outline[0], Vector2.ZERO)
	for p in outline:
		rect = rect.expand(p)
	var step := maxf(4.0, sqrt(rect.get_area() / 1500.0))
	var pts := PackedVector2Array()
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		var n := maxi(1, ceili(a.distance_to(b) / step))
		for k in n:
			pts.append(a.lerp(b, float(k) / n))
	var y := rect.position.y + step * 0.5
	while y < rect.end.y:
		var x := rect.position.x + step * 0.5
		while x < rect.end.x:
			var q := Vector2(x, y)
			if Geometry2D.is_point_in_polygon(q, outline):
				pts.append(q)
			x += step
		y += step
	var tri := Geometry2D.triangulate_delaunay(pts)
	var verts := PackedVector3Array()
	for i in range(0, tri.size(), 3):
		var a := pts[tri[i]]
		var b := pts[tri[i + 1]]
		var c := pts[tri[i + 2]]
		if not Geometry2D.is_point_in_polygon((a + b + c) / 3.0, outline):
			continue
		for q in [a, b, c]:
			verts.append(Vector3(q.x, ground(q.x, q.y) + lift, q.y))
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
