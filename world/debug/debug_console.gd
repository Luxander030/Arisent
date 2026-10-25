## The developer console (backquote or F1), ported from Ares Last Light: a ConsoleModel
## (commands, scrollback, jobs, bindings) shown in a ConsoleWindow on a debug surface that
## also carries the MonitorPanels; everything there scales with DebugZoom.
## Opening it frees the mouse and emits `toggled(true)` so the host can stop player input
## (movement is polled, so a focused text field alone would not stop it). It may open only
## where DevGate allows; commands run regardless (tests, bindings, scripts).
## Systems register commands with an owner and remove them with remove_owner(owner).
class_name DebugConsole
extends CanvasLayer

signal toggled(open: bool)

const Kind := ConsoleTheme.Kind

var model := ConsoleModel.new()
var is_open := false
var surface: Control
var window: ConsoleWindow
var monitors: MonitorPanels
var _logger: ConsoleLogger
var _mouse_before := Input.MOUSE_MODE_VISIBLE
var _zoom_cb: Callable


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	model.host = self
	model.close_requested.connect(set_open.bind(false))
	surface = Control.new()
	surface.name = "DebugSurface"
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(surface)
	monitors = MonitorPanels.new()
	monitors.name = "Monitors"
	surface.add_child(monitors)
	_zoom_cb = _apply_zoom
	DebugZoom.listeners.append(_zoom_cb)
	get_viewport().size_changed.connect(_apply_zoom)
	_apply_zoom()
	model.bars.add("scale", ConsoleBars.Slot.TITLE_RIGHT, _scale_text, 900)
	_register()
	_logger = ConsoleLogger.new(model)
	OS.add_logger(_logger)
	model.log_line(Kind.INFO, "Developer console. /help lists the commands; Tab completes.")


func _exit_tree() -> void:
	if _logger:
		OS.remove_logger(_logger)
		_logger = null
	DebugZoom.listeners.erase(_zoom_cb)


func _process(_dt: float) -> void:
	model.pump()


func _apply_zoom() -> void:
	var z := DebugZoom.get_value()
	surface.scale = Vector2(z, z)
	surface.size = get_viewport().get_visible_rect().size / z
	monitors.size = surface.size
	if window:
		window.fit()


func _scale_text() -> String:
	return "" if is_equal_approx(DebugZoom.get_value(), 1.0) else DebugZoom.percent()


# --- registry (forwarded to the model) ------------------------------------------------------

func add(cmd: ConsoleCommand, owner: Object = null) -> bool:
	return model.add(cmd, owner)


func command(name: String, desc: String, usage: String, fn: Callable, lo := 0, hi := 0, hints := Callable(), owner: Object = null) -> ConsoleCommand:
	return model.command(name, desc, usage, fn, lo, hi, hints, owner)


func verbs(name: String, desc: String, owner: Object = null) -> ConsoleVerbs:
	return model.verbs(name, desc, owner)


## The verb table of an existing command (to add verbs to it), or null.
func verbs_of(name: String) -> ConsoleVerbs:
	var c := model.find(name)
	return c.verbs if c else null


func remove_owner(owner: Object) -> void:
	model.remove_owner(owner)
	monitors.remove_owner(owner)


func has_command(name: String) -> bool:
	return model.find(name) != null


## Runs a line as if typed ("/" optional) and returns the plain text it printed.
func run(line: String) -> String:
	return model.run(line)


## A timestamped line from a system (messages, warnings).
func log_line(kind: int, text: String) -> void:
	model.log_line(kind, text)


# --- open / close and keys ----------------------------------------------------------------------

func set_open(open: bool) -> void:
	if open == is_open:
		return
	is_open = open
	if open:
		if window == null:
			window = ConsoleWindow.new(self)
			window.name = "ConsoleWindow"
			surface.add_child(window)
		window.visible = true
		window.opened()
		_mouse_before = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		if window:
			window.closed()
			window.visible = false
		Input.mouse_mode = _mouse_before
	toggled.emit(open)


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null:
		return
	if is_open:
		get_viewport().set_input_as_handled()  # the console holds the keyboard
		return
	if not k.pressed:
		return
	if handle_global_key(k) or (not k.echo and (monitors.handle_key(k) or model.fire_binding(k))):
		get_viewport().set_input_as_handled()


## Keys that work whether or not the console has focus: toggle, all panels, zoom.
func handle_global_key(k: InputEventKey) -> bool:
	if not k.pressed or k.echo:
		return false
	var mods := k.ctrl_pressed or k.alt_pressed or k.meta_pressed
	if (k.physical_keycode == KEY_QUOTELEFT and not mods and not k.shift_pressed) or (k.keycode == KEY_F1 and not mods):
		if DevGate.console_allowed():
			set_open(not is_open)
			return true
		return false
	if k.physical_keycode == KEY_QUOTELEFT and k.shift_pressed and not mods:
		if DevGate.console_allowed():
			monitors.toggle_all()
			return true
		return false
	if is_open or monitors.any_shown():
		for d: int in [1, -1]:
			if KeyCombo.primary(KEY_EQUAL if d > 0 else KEY_MINUS).matches(k) or (d > 0 and KeyCombo.primary(KEY_PLUS).matches(k)):
				_zoom(d)
				return true
		if KeyCombo.primary(KEY_0).matches(k):
			DebugZoom.set_value(1.0)
			return true
	return false


func _zoom(dir: int) -> void:
	if DebugZoom.step(dir):
		return
	var c := KeyCombo.cmd_name() if OS.get_name() == "macOS" else "Ctrl"
	if dir > 0:
		model.log_line(Kind.WARNING, "The debugging windows are already at their largest, %s. %s+Minus makes them smaller." % [DebugZoom.percent(), c])
	else:
		model.log_line(Kind.WARNING, "The debugging windows are already at their smallest, %s. %s+Equals makes them bigger." % [DebugZoom.percent(), c])


# --- console-level commands and panels -----------------------------------------------------------

func _register() -> void:
	var c := KeyCombo.cmd_name() if OS.get_name() == "macOS" else "Ctrl"
	model.describe_key("console", "toggle", "` or F1", "Open or close the console", self)
	model.describe_key("console", "panels", "Shift+`", "Show or hide every monitor panel", self)
	model.describe_key("console", "zoom", "%s+= / %s+- / %s+0" % [c, c, c], "Bigger / smaller / usual size (console or panels shown)", self)
	model.describe_key("console", "complete", "Tab, Return", "Accept the suggestion (Return also runs once the line is complete)", self)
	model.describe_key("console", "dismiss", "Esc", "Close suggestions, then clear the line, then close", self)
	model.describe_key("console", "history", "Up / Down", "Step suggestions, then earlier lines", self)
	model.command("monitor", "Shows, hides or pins the monitor panels. Bare: lists them.", "/monitor [<name>|all [on|off|pin]]",
		_cmd_monitor, 0, 2, _monitor_hints, self)
	model.command("zoom", "Shows or sets the size of the debugging windows.", "/zoom [percent|in|out|reset]", _cmd_zoom, 0, 1,
		ConsoleParse.hints_of(["in", "out", "reset", "75", "100", "125", "150", "200"]), self)
	monitors.add("render", "Render", "top_right", _panel_render, KeyCombo.make(KEY_1, false, true), self)
	monitors.add("system", "System", "top_right", _panel_system, KeyCombo.make(KEY_3, false, true), self)


func _monitor_hints(args: PackedStringArray, partial: String) -> Array:
	if args.is_empty():
		return ConsoleParse.matching(Array(monitors.names()) + ["all"], partial)
	return ConsoleParse.matching(["on", "off"] + ([] if args[0] == "all" else ["pin"]), partial)


func _cmd_monitor(a: PackedStringArray) -> Variant:
	if a.is_empty():
		var lines := PackedStringArray(["%d panels, Shift+` toggles them all:" % monitors.panels().size()])
		for p in monitors.panels():
			lines.append("  %s %-8s %-10s %-13s %s%s" % [ConsoleTheme.colored(ConsoleTheme.GREEN if p.visible else ConsoleTheme.STAMP_COLOR, "on " if p.visible else "off"),
				p.key_name, p.title, p.corner, str(p.key) if p.key else "", ("  (moved; /monitor %s pin puts it back)" % p.key_name) if p.moved else ""])
		lines.append(ConsoleTheme.esc("/monitor <name> toggles one; /monitor <name> on|off|pin; /monitor all [on|off|pin]."))
		return ConsoleResult.rich_text("\n".join(lines))
	var what := a[1].to_lower() if a.size() > 1 else ""
	if a[0] == "all":
		match what:
			"":
				return "%d panels shown." % monitors.panels().size() if monitors.toggle_all() else "Every panel hidden."
			"on", "off":
				for p in monitors.panels():
					monitors.show_panel(p.key_name, what == "on")
				return "%d panels shown." % monitors.panels().size() if what == "on" else "Every panel hidden."
			"pin":
				monitors.pin("all")
				return "Every panel is back in its corner."
		return ConsoleResult.failure("Usage: /monitor all [on|off|pin]")
	var p := monitors.find(a[0])
	if p == null:
		return ConsoleResult.failure("No panel '%s'. Panels: %s." % [a[0], ", ".join(monitors.names())])
	match what:
		"":
			monitors.show_panel(p.key_name, not p.visible)
		"on", "off":
			monitors.show_panel(p.key_name, what == "on")
		"pin":
			monitors.pin(p.key_name)
			monitors.show_panel(p.key_name, true)
		_:
			return ConsoleResult.failure("Usage: /monitor <name> [on|off|pin]")
	return "'%s' is shown, in its %s corner." % [p.key_name, p.corner.replace("_", " ")] if p.visible else "'%s' is hidden." % p.key_name


func _cmd_zoom(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		match a[0]:
			"in", "+":
				DebugZoom.step(1)
			"out", "-":
				DebugZoom.step(-1)
			"reset":
				DebugZoom.set_value(1.0)
			_:
				if not a[0].trim_suffix("%").is_valid_float():
					return ConsoleResult.failure("'%s' is not a size; use a percentage (75 to 300), in, out or reset." % a[0])
				DebugZoom.set_value(a[0].trim_suffix("%").to_float() / 100.0)
	return "The debugging windows are at %s." % DebugZoom.percent()


static func _panel_render() -> String:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	return "fps     %5.0f   frame %5.2f ms\nprocess %5.2f ms   physics %5.2f ms\ndraws   %6d   objects %6d\nprims   %7d   vram %5.0f MB" % [
		fps, 1000.0 / maxf(fps, 1.0), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0]


static func _panel_system() -> String:
	return "memory  %6.0f MB   objects %d\nnodes   %6d   orphans %d\nbodies  %6d active   islands %d\ntime ×%.2f   %s" % [
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)), int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)),
		Engine.time_scale, "%s %s" % [OS.get_name(), "debug" if OS.is_debug_build() else "release"]]
