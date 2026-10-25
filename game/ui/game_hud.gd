## In-game HUD: status line (health, level, XP, coins, weapon, time), crosshair, the "use"
## prompt, a feed of recent messages (kills, loot, level ups), and the inventory panel
## (Tab / I) where items can be dropped on the ground.
class_name GameHud
extends CanvasLayer

signal inventory_toggled(open: bool)
signal loot_toggled(open: bool)
signal skill_tree_toggled(open: bool)

const FEED_TIME := 6.0
const FEED_LINES := 6

var game: GameSession
var player: Player
var status: Label
var crosshair: Label
var prompt: Label
var center_message: Label
var _feed: VBoxContainer
var _inv_panel: PanelContainer
var _inv_list: VBoxContainer
var _inv_title: Label
var _loot_panel: PanelContainer
var _loot_list: VBoxContainer
var _loot_title: Label
var _loot_session: WorldSession
var _loot_id := ""
var skill_tree: SkillTreePanel
var fps_label: Label   ## Settings → Frame-rate counter
var lod: LodController  ## for the counter's resolution note (set by the game host)


func _ready() -> void:
	status = _label(18)
	status.position = Vector2(16, 12)
	crosshair = _label(22)
	crosshair.text = "+"
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt = _label(20)
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	prompt.position.y += 60
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center_message = _label(22)
	center_message.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	center_message.position.y -= 80
	center_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_message.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center_message.visible = false
	_feed = VBoxContainer.new()
	_feed.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_feed.position = Vector2(-420, 12)
	_feed.custom_minimum_size.x = 400
	_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_feed)
	fps_label = _label(16)
	fps_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	fps_label.position = Vector2(16, -36)
	_build_inventory()
	_build_loot()
	skill_tree = SkillTreePanel.new()
	skill_tree.name = "SkillTree"
	skill_tree.progress = game.progress if game else null
	add_child(skill_tree)
	if game:
		game.notified.connect(push_message)
		game.inventory.changed.connect(_refresh_inventory)


func _label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	add_child(l)
	return l


func push_message(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	_feed.add_child(l)
	while _feed.get_child_count() > FEED_LINES:
		_feed.get_child(0).free()
	var tw := l.create_tween()
	tw.tween_interval(FEED_TIME)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func show_center(text: String) -> void:
	center_message.text = text
	center_message.visible = text != ""


func update_status() -> void:
	if player == null or game == null:
		return
	var u := player.horizontal_speed() / MovementSettings.U
	var st := "   swimming" if player.swimming else ("   on ladder" if player.on_ladder else "")
	var lvl := game.progress.level()
	var pts := game.progress.skill_points(SkillTree.project())
	status.text = "Health %d   Level %d (%d / %d XP)%s   Coins %d   %s%s   %s\nSpeed %d u/s%s   ·   WASD move · Space jump · E use · LMB fire · RMB aim · R reload · 1-4 weapons · Tab bag · K skills · ` console" % [
		player.health, lvl, game.progress.xp, PlayerProgress.xp_for(lvl + 1), "   Skill points %d" % pts if pts > 0 else "", game.inventory.count_of("coin"),
		player.weapons.status_text(), "   carrying" if player.carrier.held else "", game.time_of_day.label(), u, st]
	crosshair.visible = player.health > 0.0 and not _inv_panel.visible and not _loot_panel.visible and not skill_tree.visible
	if _loot_panel.visible:
		var c: Dictionary = _loot_session.npcs.corpses.get(_loot_id, {}) if _loot_session else {}
		if c.is_empty() or (c.loot as Array).is_empty() or (c.pos as Vector3).distance_to(player.global_position) > 4.0:
			close_loot()
	var t := player.use_target
	prompt.text = "E — %s" % t.prompt if not t.is_empty() and not skill_tree.visible else ""
	status.visible = not skill_tree.visible
	_feed.visible = not skill_tree.visible
	fps_label.visible = GraphicsSettings.current().show_fps
	if fps_label.visible:
		fps_label.text = "%d fps" % Engine.get_frames_per_second()
		if lod and is_instance_valid(lod):
			fps_label.text += "  ·  %d %% resolution  ·  detail ×%.2f" % [roundi(lod.render_scale * 100.0), lod.scale]


# --- inventory -------------------------------------------------------------------------

func _build_inventory() -> void:
	_inv_panel = PanelContainer.new()
	_inv_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_inv_panel.custom_minimum_size = Vector2(460, 420)
	_inv_panel.position = Vector2(-230, -210)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.11, 0.92)
	sb.set_content_margin_all(12)
	sb.set_corner_radius_all(6)
	_inv_panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	_inv_panel.add_child(v)
	_inv_title = Label.new()
	_inv_title.add_theme_font_size_override("font_size", 20)
	v.add_child(_inv_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	_inv_list = VBoxContainer.new()
	_inv_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inv_list)
	var hint := Label.new()
	hint.text = "Dropped items stay where you leave them. Tab closes."
	hint.modulate = Color(1, 1, 1, 0.6)
	v.add_child(hint)
	_inv_panel.visible = false
	add_child(_inv_panel)


func toggle_inventory() -> void:
	_inv_panel.visible = not _inv_panel.visible
	if _inv_panel.visible:
		_refresh_inventory()
	inventory_toggled.emit(_inv_panel.visible)


func inventory_open() -> bool:
	return _inv_panel.visible


func _refresh_inventory() -> void:
	if not _inv_panel.visible or game == null:
		return
	for c in _inv_list.get_children():
		c.queue_free()
	var p := game.progress
	var skills := PackedStringArray()
	for k: String in p.skills:
		skills.append("%s %d" % [k.capitalize(), p.skill_level(k)])
	_inv_title.text = "Bag  (%d / %d slots)   Level %d   %s" % [game.inventory.stacks.size(), game.inventory.capacity, p.level(),
		"  ".join(skills)]
	var totals := game.inventory.totals()
	if totals.is_empty():
		var l := Label.new()
		l.text = "Empty."
		_inv_list.add_child(l)
	for item: String in totals:
		var row := HBoxContainer.new()
		var def := Defs.get_def("items", item)
		var sw := ColorRect.new()
		sw.color = Color.from_string(str(def.get("color", "#cccccc")), Color.WHITE)
		sw.custom_minimum_size = Vector2(14, 14)
		row.add_child(sw)
		var l := Label.new()
		l.text = "%s ×%d   (%s, worth %d)" % [def.get("name", item), totals[item], def.get("category", ""), int(def.get("value", 0))]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		for amount in [1, -1]:
			var b := Button.new()
			b.text = "Drop 1" if amount == 1 else "Drop all"
			b.pressed.connect(_drop.bind(item, amount))
			row.add_child(b)
		_inv_list.add_child(row)


func _drop(item: String, amount: int) -> void:
	if game.world == null or player == null:
		return
	var n := game.inventory.count_of(item) if amount < 0 else 1
	var fwd := -player.cam.camera.global_basis.z
	fwd.y = 0.0
	var at := player.global_position + fwd.normalized() * 1.2
	if game.world.items.drop(item, n, at, "player_dropped", 0.2) != "":
		game.inventory.remove(item, n)


# --- skill tree --------------------------------------------------------------------------

func toggle_skill_tree() -> void:
	if skill_tree.visible:
		skill_tree.close()
	else:
		if _inv_panel.visible:
			toggle_inventory()
		close_loot()
		skill_tree.open()
	skill_tree_toggled.emit(skill_tree.visible)


func skill_tree_open() -> bool:
	return skill_tree.visible


# --- corpse loot (WoW-style window) ------------------------------------------------------

func _build_loot() -> void:
	_loot_panel = PanelContainer.new()
	_loot_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	_loot_panel.custom_minimum_size = Vector2(320, 0)
	_loot_panel.position = Vector2(40, -120)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.08, 0.05, 0.94)
	sb.border_color = Color(0.8, 0.65, 0.3)
	sb.set_border_width_all(2)
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	_loot_panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	_loot_panel.add_child(v)
	_loot_title = Label.new()
	_loot_title.add_theme_font_size_override("font_size", 19)
	v.add_child(_loot_title)
	_loot_list = VBoxContainer.new()
	v.add_child(_loot_list)
	var row := HBoxContainer.new()
	var all := Button.new()
	all.text = "Take all (E)"
	all.pressed.connect(take_all)
	row.add_child(all)
	var close := Button.new()
	close.text = "Close (Esc)"
	close.pressed.connect(close_loot)
	row.add_child(close)
	v.add_child(row)
	_loot_panel.visible = false
	add_child(_loot_panel)


func open_loot(s: WorldSession, cid: String) -> void:
	_loot_session = s
	_loot_id = cid
	_loot_panel.visible = true
	_refresh_loot()
	loot_toggled.emit(true)


func loot_open() -> bool:
	return _loot_panel.visible


func close_loot() -> void:
	if not _loot_panel.visible:
		return
	_loot_panel.visible = false
	_loot_id = ""
	loot_toggled.emit(false)


func take_all() -> void:
	if _loot_session and _loot_id != "":
		_loot_session.npcs.take_loot(_loot_id)
	_refresh_loot()


func _refresh_loot() -> void:
	for c in _loot_list.get_children():
		c.queue_free()
	var c: Dictionary = _loot_session.npcs.corpses.get(_loot_id, {}) if _loot_session else {}
	if c.is_empty():
		return
	_loot_title.text = str(c.name)
	var loot: Array = c.loot
	for i in loot.size():
		var d: Dictionary = loot[i]
		var def := Defs.get_def("items", str(d.item))
		var r := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = Color.from_string(str(def.get("color", "#cccccc")), Color.WHITE)
		sw.custom_minimum_size = Vector2(14, 14)
		r.add_child(sw)
		var l := Label.new()
		l.text = "%s ×%d" % [def.get("name", d.item), d.count]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.add_child(l)
		var b := Button.new()
		b.text = "Take"
		var idx := i
		b.pressed.connect(func() -> void:
			_loot_session.npcs.take_loot(_loot_id, idx)
			_refresh_loot())
		r.add_child(b)
		_loot_list.add_child(r)
