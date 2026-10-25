## Paints ground textures straight into the terrain's control map. Painted pixels are
## remembered (paint lock) so later automatic texture updates leave them alone.
class_name PaintTool
extends EditorTool

var slot := 0
var as_overlay := false
var _down := false
var _last := Vector3.INF
var _orig := {}    ## pixel index -> original control (first touch in this stroke)
var _orig_col := {}


func tool_name() -> String:
	return "Paint"


func tool_hint() -> String:
	return "Left-drag to paint the selected ground texture. Shift = erase back to automatic."


func uses_brush() -> bool:
	return true


func build_settings(box: VBoxContainer) -> void:
	add_label(box, "Texture")
	var grid := GridContainer.new()
	grid.columns = 3
	var group := ButtonGroup.new()
	for i in TerrainTextureSet.SLOTS.size():
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == slot
		b.icon = TerrainTextureSet.albedo(i)
		b.expand_icon = true
		b.custom_minimum_size = Vector2(64, 64)
		b.tooltip_text = TerrainTextureSet.SLOTS[i][1]
		b.pressed.connect(func() -> void: slot = i)
		grid.add_child(b)
	box.add_child(grid)
	add_option_buttons(box, ["Replace", "Blend on top"], 1 if as_overlay else 0,
		func(i: int) -> void: as_overlay = i == 1)
	add_slider(box, "Size (m)", 1, 200, size, func(v: float) -> void: size = v)
	add_slider(box, "Strength", 1, 100, strength, func(v: float) -> void: strength = v)


func on_input(event: InputEvent, hit: Vector3) -> bool:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and hit != Vector3.INF:
			_down = true
			_orig.clear()
			_orig_col.clear()
			_dab(hit, mb.shift_pressed)
			_last = hit
			return true
		elif not mb.pressed and _down:
			_down = false
			_commit()
			return true
	elif event is InputEventMouseMotion and _down and hit != Vector3.INF:
		if hit.distance_to(_last) > size * 0.2:
			_dab(hit, Input.is_key_pressed(KEY_SHIFT))
			_last = hit
		return true
	return false


func _dab(hit: Vector3, erase: bool) -> void:
	var terrain: TerrainBackend = editor.world.terrain
	var R := terrain.full_res()
	var sp: float = editor.map.spacing
	var c := terrain.world_to_pixel(hit)
	var r := ceili(size * 0.5 / sp)
	var rect := Rect2i(c - Vector2i(r, r), Vector2i(r * 2 + 1, r * 2 + 1)).intersection(Rect2i(0, 0, R, R))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var ctrl := terrain.read_control(rect)
	var lock: Image = editor.ensure_paint_lock()
	var amount := strength / 100.0
	for y in rect.size.y:
		for x in rect.size.x:
			var px := rect.position + Vector2i(x, y)
			var d := Vector2(px - c).length() / maxf(r, 1)
			if d > 1.0:
				continue
			var k := px.y * R + px.x
			var o := y * rect.size.x + x
			if not _orig.has(k):
				_orig[k] = ctrl[o]
			if erase:
				lock.set_pixel(px.x, px.y, Color(0, 0, 0))
				continue
			var fall := 1.0 - d * d
			var v := ctrl[o]
			if as_overlay:
				var cur_blend := (v >> 14) & 255
				var cur_over := (v >> 22) & 31
				var b := cur_blend if cur_over == slot else 0
				b = clampi(b + int(255.0 * amount * fall * 0.5), 0, 255)
				v = (v & ~((31 << 22) | (255 << 14))) | (slot << 22) | (b << 14)
			elif fall * amount > 0.25:
				v = (v & ~((31 << 27) | (255 << 14))) | (slot << 27)
			ctrl[o] = v
			lock.set_pixel(px.x, px.y, Color(1, 1, 1))
	terrain.write_control(rect, ctrl)
	if erase:
		var rr := Rect2(terrain.pixel_to_world(rect.position).x, terrain.pixel_to_world(rect.position).z, rect.size.x * sp, rect.size.y * sp)
		editor.refresh_ground(rr)


func _commit() -> void:
	if _orig.is_empty():
		return
	var terrain: TerrainBackend = editor.world.terrain
	var R := terrain.full_res()
	var keys := PackedInt32Array(_orig.keys())
	var before := PackedInt32Array()
	var after := PackedInt32Array()
	var bb := Rect2i(keys[0] % R, keys[0] / R, 1, 1)
	for k in keys:
		bb = bb.expand(Vector2i(k % R, k / R))
	bb.size += Vector2i.ONE
	var now := terrain.read_control(bb)
	for k in keys:
		before.append(_orig[k])
		after.append(now[(k / R - bb.position.y) * bb.size.x + (k % R - bb.position.x)])
	var ur: UndoRedo = editor.undo
	ur.create_action("Paint ground")
	ur.add_do_method(_apply.bind(keys, after, bb))
	ur.add_undo_method(_apply.bind(keys, before, bb))
	ur.commit_action(false)
	editor.mark_dirty()


func _apply(keys: PackedInt32Array, values: PackedInt32Array, bb: Rect2i) -> void:
	var terrain: TerrainBackend = editor.world.terrain
	var R := terrain.full_res()
	var ctrl := terrain.read_control(bb)
	for i in keys.size():
		var k := keys[i]
		ctrl[(k / R - bb.position.y) * bb.size.x + (k % R - bb.position.x)] = values[i]
	terrain.write_control(bb, ctrl)
