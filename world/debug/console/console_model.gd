## The developer console without a window: command registry, bounded scrollback, parser,
## async job runner, bars, key bindings and the built-in commands. Works headless (tests,
## no view); DebugConsole adds the window. Ported from Ares Last Light's DevConsole.
##
## Lines typed into the console start with "/" ("/time set noon"); plain text is echoed.
## run() is the scripted entry (tests, bindings) and accepts the bare form too.
class_name ConsoleModel
extends RefCounted

signal block_appended(block: Dictionary)
signal cleared
signal display_level_changed
signal close_requested
signal status_changed

const TITLE := "Developer Console"
const CAPACITY := 4096
const SPLIT_LINES := 64
const Kind := ConsoleTheme.Kind

var blocks: Array[Dictionary] = []   ## {kind, text, rich, logged, time, seq}; 0 = oldest
var total_appended := 0
var display_level: int = Kind.TRACE
var columns := 80                    ## characters across the log (tables fit to it)
var bars := ConsoleBars.new()
var content := ConsoleVerbs.new("content")
var host: Object                     ## DebugConsole (window, monitors), or null headless
var last_outcome := {}               ## {line, elapsed, ok}
var status_version := 0

var _commands: Array[ConsoleCommand] = []
var _owners := {}                    ## lower name -> WeakRef
var _staged: Array = []
var _stage_lock := Mutex.new()
var _main_thread := OS.get_main_thread_id()
var _running := {}                   ## {job, line}
var _queue: Array[Dictionary] = []
var _bindings := {}                  ## combo text -> {combo: KeyCombo, line}
var _hotkeys: Array[Dictionary] = [] ## {group, action, keys, description, owner}
var _capture := false                ## run(): collecting output
var _captured := PackedStringArray()


func _init() -> void:
	_register_builtins()
	bars.add("console", ConsoleBars.Slot.TITLE_LEFT, func() -> String: return TITLE, -1000)
	bars.add("clock", ConsoleBars.Slot.TITLE_RIGHT, func() -> String: return Time.get_time_string_from_system(), 1000)
	bars.add("activity", ConsoleBars.Slot.STATUS_LEFT, _activity, 0)


# --- registry ------------------------------------------------------------------------------

## Adds a command; `owner` lets a system take its commands away again (remove_owner).
## A duplicate name is refused (error) and returns false.
func add(cmd: ConsoleCommand, owner: Object = null) -> bool:
	if find(cmd.name) != null:
		push_error("console: /%s is already registered" % cmd.name)
		return false
	_commands.append(cmd)
	_commands.sort_custom(func(a: ConsoleCommand, b: ConsoleCommand) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)
	if owner:
		_owners[cmd.name.to_lower()] = weakref(owner)
	return true


## Shorthand: add(ConsoleCommand.new(...)).
func command(name: String, desc: String, usage: String, fn: Callable, lo := 0, hi := 0, hints := Callable(), owner: Object = null) -> ConsoleCommand:
	var c := ConsoleCommand.new(name, desc, usage, fn, lo, hi, hints)
	add(c, owner)
	return c


## Shorthand for a verb-table command; returns the table to add verbs to.
func verbs(name: String, desc: String, owner: Object = null) -> ConsoleVerbs:
	var t := ConsoleVerbs.new(name)
	add(ConsoleCommand.with_verbs(name, desc, t), owner)
	return t


func remove(name: String) -> bool:
	var c := find(name)
	if c == null:
		return false
	_commands.erase(c)
	_owners.erase(name.to_lower())
	return true


## Removes everything `owner` registered: commands, verbs it added to other commands'
## tables, bar sections and hotkey descriptions.
func remove_owner(owner: Object) -> void:
	for n: String in _owners.keys():
		var r: Object = (_owners[n] as WeakRef).get_ref()
		if r == owner or r == null:
			remove(n)
	for c in _commands:
		if c.verbs:
			c.verbs.remove_owner(owner)
	bars.remove_owner(owner)
	_hotkeys = _hotkeys.filter(func(h: Dictionary) -> bool:
		var r: Object = (h.owner as WeakRef).get_ref() if h.owner else self
		return r != owner and r != null)


func find(name: String) -> ConsoleCommand:
	var l := name.to_lower().trim_prefix("/")
	for c in _commands:
		if c.name.to_lower() == l:
			return c
	return null


func command_names() -> Array:
	return _commands.map(func(c: ConsoleCommand) -> String: return c.name)


func commands() -> Array[ConsoleCommand]:
	return _commands


## Documents keys handled elsewhere (for /hotkeys).
func describe_key(group: String, action: String, keys: String, desc: String, owner: Object = null) -> void:
	_hotkeys.append({"group": group, "action": action, "keys": keys, "description": desc, "owner": weakref(owner) if owner else null})


# --- output --------------------------------------------------------------------------------

## A timestamped line (system output).
func log_line(kind: int, text: String, rich := false) -> void:
	append({"kind": kind, "text": text, "rich": rich, "logged": true, "time": Time.get_time_string_from_system()})


## An unstamped line (command replies).
func print_line(kind: int, text: String, rich := false) -> void:
	append({"kind": kind, "text": text, "rich": rich, "logged": false, "time": Time.get_time_string_from_system()})


func append(b: Dictionary) -> void:
	if OS.get_thread_caller_id() != _main_thread:
		stage(int(b.kind), str(b.text))
		return
	_drain()
	_land(b)


## Thread-safe: queued for the next pump.
func stage(kind: int, text: String) -> void:
	_stage_lock.lock()
	_staged.append({"kind": kind, "text": text, "rich": false, "logged": true, "engine": true, "time": Time.get_time_string_from_system()})
	if _staged.size() > CAPACITY:
		_staged.pop_front()
	_stage_lock.unlock()


func _drain() -> void:
	if _staged.is_empty():
		return
	_stage_lock.lock()
	var take := _staged
	_staged = []
	_stage_lock.unlock()
	for b: Dictionary in take:
		_land(b)


func _land(b: Dictionary) -> void:
	var text := str(b.text)
	if text.count("\n") >= SPLIT_LINES:
		var lines := text.split("\n")
		for i in range(0, lines.size(), SPLIT_LINES):
			var part := b.duplicate()
			part.text = "\n".join(lines.slice(i, i + SPLIT_LINES))
			_land_one(part)
	else:
		_land_one(b)


func _land_one(b: Dictionary) -> void:
	b.seq = total_appended
	blocks.append(b)
	if blocks.size() > CAPACITY:
		blocks.pop_front()
	total_appended += 1
	if _capture and int(b.kind) != Kind.INPUT and not b.get("engine", false):
		_captured.append(ConsoleTheme.strip(str(b.text)) if b.rich else str(b.text))
	block_appended.emit(b)


func clear() -> void:
	_stage_lock.lock()
	_staged.clear()
	_stage_lock.unlock()
	blocks.clear()
	total_appended += 1
	cleared.emit()


func is_visible(b: Dictionary) -> bool:
	return int(b.kind) == Kind.INPUT or int(b.kind) >= display_level


func visible_count() -> int:
	return blocks.filter(is_visible).size()


func set_display_level(k: int) -> void:
	display_level = k
	display_level_changed.emit()


## One block as BBCode for the log.
static func block_bbcode(b: Dictionary) -> String:
	var k := int(b.kind)
	var body := str(b.text) if b.rich else ConsoleTheme.esc(str(b.text))
	var stamp := ""
	if b.logged:
		stamp = "[color=%s]%s %s [/color]" % [ConsoleTheme.STAMP_COLOR, ConsoleTheme.esc("[" + str(b.time) + "]"), ConsoleTheme.esc("[" + ConsoleTheme.KIND_LETTERS[k] + "]")]
	return stamp + "[color=%s]%s[/color]" % [ConsoleTheme.KIND_COLORS[k], body]


# --- execution -----------------------------------------------------------------------------

## Runs a typed line: echoes it and prints what the command replied.
func execute(line: String) -> void:
	pump()
	var p := ConsoleParse.parse(line)
	match int(p.kind):
		ConsoleParse.BLANK:
			return
		ConsoleParse.TEXT:
			print_line(Kind.INFO, str(p.value))
			var first := str(p.value).get_slice(" ", 0)
			if find(first):
				print_line(Kind.DEBUG, "Commands start with a slash: /%s" % str(p.value))
		ConsoleParse.MALFORMED:
			print_line(Kind.INPUT, line.strip_edges())
			print_line(Kind.ERROR, str(p.error))
		ConsoleParse.INVOCATION:
			var args: PackedStringArray = p.args
			print_line(Kind.INPUT, ConsoleParse.echo(str(p.name), args))
			_run(str(p.name), args)


## Scripted entry (tests, bindings, exec): executes `line` (the leading "/" is optional)
## and returns the plain text it printed (not the echo). Async replies land later.
func run(line: String) -> String:
	var l := line.strip_edges()
	if l != "" and not l.begins_with("/"):
		l = "/" + l
	var was := _capture
	var before := _captured.size()
	_capture = true
	execute(l)
	_capture = was
	var out := "\n".join(_captured.slice(before))
	if not was:
		_captured.clear()
	return out


func _run(name: String, args: PackedStringArray) -> void:
	var c := find(name)
	var line := ConsoleParse.echo(name, args)
	if c == null:
		var s := ConsoleParse.suggestions(command_names(), name)
		if s.is_empty():
			print_line(Kind.ERROR, "Unknown command '/%s'. Type /help for the list." % name)
		else:
			print_line(Kind.ERROR, "Unknown command '/%s'. Did you mean %s?" % [name, ", ".join(Array(s).map(func(x: String) -> String: return "/" + x))])
		return
	if not c.accepts(args.size()):
		print_line(Kind.ERROR, "/%s takes %s, got %d." % [c.name, c.describe_arity(), args.size()])
		print_line(Kind.ERROR, "Usage: " + c.get_usage())
		return
	var t0 := Time.get_ticks_usec()
	var v: Variant = c.handler.call(args)
	_drain()  # engine output the command produced lands above its reply
	if v is ConsoleJob:
		if not _running.is_empty():
			_queue.append({"job": v, "line": line})
			print_line(Kind.INFO, "%s is queued behind %s." % [line, _running.line])
			_bump()
			return
		_start(v, line)
		pump()
		return
	_report(ConsoleResult.from(v), line, (Time.get_ticks_usec() - t0) / 1e6)


func _report(r: ConsoleResult, line: String, elapsed: float) -> void:
	last_outcome = {"line": line, "elapsed": elapsed, "ok": r.ok}
	if r.has_message():
		print_line(Kind.INFO if r.ok else Kind.ERROR, r.message, r.rich)
	_bump()


func _start(job: ConsoleJob, line: String) -> void:
	_running = {"job": job, "line": line}
	job.start()
	_bump()


## Lands staged engine output and finished jobs; starts the next queued job. Every frame.
func pump() -> void:
	_drain()
	while not _running.is_empty() and (_running.job as ConsoleJob).is_done():
		var job: ConsoleJob = _running.job
		var line: String = _running.line
		_running = {}
		_report(job.result, line, job.elapsed())
		if not _queue.is_empty():
			var nxt: Dictionary = _queue.pop_front()
			_start(nxt.job, nxt.line)


func is_busy() -> bool:
	return not _running.is_empty()


## True when `line` is a known command still short of the arguments it needs (Return
## then keeps the line instead of running it).
func is_short_of_arguments(line: String) -> bool:
	var p := ConsoleParse.parse(line)
	if int(p.kind) != ConsoleParse.INVOCATION:
		return false
	var c := find(str(p.name))
	var args: PackedStringArray = p.args
	return c != null and args.size() < c.minimum_for(args)


func _bump() -> void:
	status_version += 1
	status_changed.emit()


func _activity() -> String:
	if _running.is_empty():
		return ""
	var s := "%s %s  %s" % [ConsoleBars.spinner(), _running.line, ConsoleBars.duration((_running.job as ConsoleJob).elapsed())]
	if not _queue.is_empty():
		s += "  (%d queued)" % _queue.size()
	return s


# --- bindings ------------------------------------------------------------------------------

## Fires the binding for a key press (console closed). True if one ran.
func fire_binding(e: InputEventKey) -> bool:
	for k: String in _bindings:
		var b: Dictionary = _bindings[k]
		if (b.combo as KeyCombo).matches(e):
			execute("/" + str(b.line))
			return true
	return false


func bindings() -> Dictionary:
	return _bindings


# --- built-in commands ---------------------------------------------------------------------

func _register_builtins() -> void:
	command("clear", "Clears the console.", "", _cmd_clear)
	command("close", "Closes the console window.", "", _cmd_close)
	command("echo", "Prints its arguments.", "/echo <text...>", _cmd_echo, 1, ConsoleCommand.VARIADIC)
	command("help", "Lists the commands, or explains one.", "/help [command]", _cmd_help, 0, 1,
		ConsoleParse.hints_of(command_names))
	var log := verbs("log", "Controls what the console shows.")
	log.verb("level", "Shows or sets the lowest kind of line shown (nothing is thrown away).", _cmd_log_level, 0, 1,
		"/log level [trace|debug|info|warn|error|crit]", ConsoleParse.hints_of(ConsoleParse.LEVEL_NAMES))
	log.verb("save", "Writes the whole scrollback to a text file (default user://console.log).", _cmd_log_save, 0, 1, "/log save [file]")
	command("bind", "Binds a key to a command line, for this session. Bare: lists bindings.", "/bind \"<command>\" <combo>",
		_cmd_bind, 0, 2, ConsoleParse.hints_by_position([_slashed_names, null]))
	command("unbind", "Removes a key binding.", "/unbind <combo>", _cmd_unbind, 1, 1,
		ConsoleParse.hints_of(_bound_combos))
	command("hotkeys", "Lists every key the game and the console react to.", "", _cmd_hotkeys)
	command("delay", "Waits real seconds without blocking the game (for bindings and /exec).", "/delay <seconds>", _cmd_delay, 1, 1)
	command("exec", "Runs a file of console lines (user:// or res://; # starts a comment).", "/exec <file>", _cmd_exec, 1, 1,
		ConsoleParse.hints_of(_exec_files))
	command("quit", "Quits the game (saving first, like closing the window).", "", _cmd_quit)
	command("version", "Game, engine and data format versions.", "", _cmd_version)
	command("vsync", "Shows or switches vertical sync.", "/vsync [on|off]", _cmd_vsync, 0, 1, ConsoleParse.hints_of(["on", "off"]))
	command("maxfps", "Shows or sets the frame-rate cap (0 = none).", "/maxfps [fps]", _cmd_maxfps, 0, 1, ConsoleParse.hints_of(["0", "30", "60", "120", "144"]))
	add(ConsoleCommand.with_verbs("content", "Inspects the game's data: what exists and what is in it.", content))


func _cmd_clear(_a: PackedStringArray) -> Variant:
	clear()
	return null


func _cmd_close(_a: PackedStringArray) -> Variant:
	if host == null:
		return ConsoleResult.failure("No console window is attached.")
	close_requested.emit()
	return null


func _cmd_echo(a: PackedStringArray) -> Variant:
	return " ".join(a)


func _slashed_names() -> Array:
	return command_names().map(func(n: String) -> String: return "/" + n)


func _bound_combos() -> Array:
	return _bindings.keys()


func _cmd_help(a: PackedStringArray) -> Variant:
	if a.is_empty():
		var rows: Array = []
		var widest := 0
		for c in _commands:
			var u := _index_usage(c)
			widest = maxi(widest, mini(u.length(), 34))
			rows.append([u, c.description])
		var lines := PackedStringArray(["%d commands. /help <command> for detail." % _commands.size()])
		for r: Array in rows:
			var u: String = r[0]
			if u.length() > 34:
				lines.append("  " + ConsoleTheme.green(u))
				lines.append("  " + " ".repeat(widest + 2) + ConsoleTheme.esc(r[1]))
			else:
				lines.append("  " + ConsoleTheme.green(u) + " ".repeat(widest - u.length() + 2) + ConsoleTheme.esc(r[1]))
		return ConsoleResult.rich_text("\n".join(lines))
	var c := find(a[0])
	if c == null:
		var s := ConsoleParse.suggestions(command_names(), a[0].trim_prefix("/"))
		return ConsoleResult.failure("No command named '%s'.%s" % [a[0], "" if s.is_empty() else " Did you mean %s?" % ", ".join(Array(s).map(func(x: String) -> String: return "/" + x))])
	var lines := PackedStringArray()
	if c.verbs:
		lines.append(ConsoleTheme.green(_index_usage(c)))
		lines.append("  " + ConsoleTheme.esc(c.description))
		for v in c.verbs.list():
			lines.append("  " + ConsoleTheme.green(v.usage))
			lines.append("      " + ConsoleTheme.esc(v.description))
	else:
		lines.append(ConsoleTheme.green(c.usage))
		lines.append("  " + ConsoleTheme.esc(c.description))
		lines.append("  Takes %s." % c.describe_arity())
	if c.has_hints():
		lines.append("  Tab suggests its arguments.")
	return ConsoleResult.rich_text("\n".join(lines))


static func _index_usage(c: ConsoleCommand) -> String:
	if c.verbs:
		return "/%s %s" % [c.name, "|".join(c.verbs.names())] if not c.verbs.is_empty() else "/" + c.name
	return c.usage


func _cmd_log_level(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		var k := ConsoleParse.level(a[0])
		if k < 0:
			return ConsoleResult.failure("'%s' is not a level. Use one of: %s." % [a[0], "|".join(ConsoleParse.LEVEL_NAMES)])
		set_display_level(k)
	return "Display level is %s (%d of %d lines shown)." % [ConsoleParse.LEVEL_NAMES[display_level], visible_count(), blocks.size()]


func _cmd_log_save(a: PackedStringArray) -> Variant:
	var path := a[0] if not a.is_empty() else "user://console.log"
	if not path.contains("://"):
		path = "user://" + path
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ConsoleResult.failure("Couldn't write %s (%s)." % [path, error_string(FileAccess.get_open_error())])
	for b in blocks:
		var t := ConsoleTheme.strip(str(b.text)) if b.rich else str(b.text)
		f.store_line(("[%s] [%s] " % [b.time, ConsoleTheme.KIND_LETTERS[int(b.kind)]] if b.logged else "") + t)
	return "Wrote %d blocks to %s (%s)." % [blocks.size(), path, ProjectSettings.globalize_path(path)]


func _cmd_bind(a: PackedStringArray) -> Variant:
	if a.is_empty():
		if _bindings.is_empty():
			return "Nothing is bound. /bind \"<command>\" <combo> to add one; bindings last for this session only."
		var keys: Array = _bindings.keys()
		keys.sort()
		var w := 0
		for k: String in keys:
			w = maxi(w, k.length())
		var lines := PackedStringArray(["%d binding%s. They last for this session only." % [keys.size(), "" if keys.size() == 1 else "s"]])
		for k: String in keys:
			lines.append("  %s%s%s" % [ConsoleTheme.esc(k), " ".repeat(w - k.length() + 2), ConsoleTheme.green("/" + str(_bindings[k].line))])
		return ConsoleResult.rich_text("\n".join(lines))
	if a.size() < 2:
		return ConsoleResult.failure("Usage: /bind \"<command>\" <combo>  (for example /bind \"/time set noon\" ctrl+n)")
	var line := a[0].strip_edges().trim_prefix("/").strip_edges()
	if line == "":
		return ConsoleResult.failure("A binding needs a command line to run.")
	var combo := KeyCombo.parse(a[1])
	if combo == null:
		return ConsoleResult.failure(KeyCombo.last_error)
	var key := str(combo)
	var again := _bindings.has(key)
	_bindings[key] = {"combo": combo, "line": line}
	return ConsoleResult.rich_text("%s %s to %s." % ["Rebound" if again else "Bound", ConsoleTheme.esc(key), ConsoleTheme.green("/" + line)])


func _cmd_unbind(a: PackedStringArray) -> Variant:
	var combo := KeyCombo.parse(a[0])
	var key := str(combo) if combo else a[0]
	if not _bindings.has(key):
		return ConsoleResult.failure("%s is not bound." % key)
	_bindings.erase(key)
	return "Unbound %s." % key


func _cmd_hotkeys(_a: PackedStringArray) -> Variant:
	var rows: Array = [["group", "action", "keys", "description"]]
	var groups := {}
	for h in _hotkeys:
		rows.append([h.group, h.action, h.keys, h.description])
		groups[h.group] = true
	for k: String in _bindings:
		rows.append(["bindings", "/" + str(_bindings[k].line), k, "/bind (this session)"])
		groups["bindings"] = true
	for action: StringName in InputMap.get_actions():
		if str(action).begins_with("ui_") or str(action).begins_with("spatial_editor"):
			continue
		var keys := PackedStringArray()
		for e in InputMap.action_get_events(action):
			keys.append(e.as_text().replace(" - Physical", "").replace(" (Physical)", ""))
		rows.append(["actions", str(action), ", ".join(keys), "input map (Project Settings)"])
		groups["actions"] = true
	if rows.size() == 1:
		return "No hotkey groups are loaded."
	var head := "%d group%s, %d binding%s." % [groups.size(), "" if groups.size() == 1 else "s", rows.size() - 1, "" if rows.size() == 2 else "s"]
	if host and host.get("is_open"):
		head += " The console holds the keyboard while it is open, so the rest wait until it closes."
	return ConsoleResult.rich_text(ConsoleTheme.esc(head) + "\n" + ConsoleTable.format(rows, "rounded", "single", columns))


func _cmd_delay(a: PackedStringArray) -> Variant:
	if not a[0].is_valid_float():
		return ConsoleResult.failure("'%s' is not a number of seconds." % a[0])
	var s := a[0].to_float()
	if s < 0.0 or s > 600.0:
		return ConsoleResult.failure("Delay for 0 to 600 seconds, not %s." % a[0])
	return ConsoleJob.new(func(job: ConsoleJob) -> String:
		await ConsoleJob.wait(s)
		return "Waited %.3fs." % job.elapsed())


func _exec_files() -> Array:
	var out: Array = []
	for dir: String in ["user://", "user://scripts/"]:
		var d := DirAccess.open(dir)
		if d:
			for f in d.get_files():
				if f.ends_with(".cfg") and f != "settings.cfg" or f.ends_with(".txt") or f.ends_with(".con"):
					out.append(f if dir == "user://" else "scripts/" + f)
	return out


func _cmd_exec(a: PackedStringArray) -> Variant:
	var path := a[0]
	if not path.contains("://"):
		path = "user://" + path
	if not FileAccess.file_exists(path):
		return ConsoleResult.failure("No file %s." % path)
	var lines := FileAccess.get_file_as_string(path).split("\n")
	return ConsoleJob.new(func(_job: ConsoleJob) -> String:
		var n := 0
		for raw in lines:
			var l := raw.strip_edges()
			if l == "" or l.begins_with("#"):
				continue
			if not l.begins_with("/"):
				l = "/" + l
			n += 1
			await _exec_line(l)
		return "Ran %d line%s of %s." % [n, "" if n == 1 else "s", path])


## Runs one line inside a job: async commands run inline (not queued behind the job).
func _exec_line(l: String) -> void:
	var p := ConsoleParse.parse(l)
	if int(p.kind) != ConsoleParse.INVOCATION:
		execute(l)
		return
	var c := find(str(p.name))
	var args: PackedStringArray = p.args
	if c == null or not c.accepts(args.size()):
		execute(l)
		return
	print_line(Kind.INPUT, ConsoleParse.echo(str(p.name), args))
	var v: Variant = c.handler.call(args)
	if v is ConsoleJob:
		var job: ConsoleJob = v
		job.start()
		while not job.is_done():
			await ConsoleJob.frame()
		v = job.result
	_report(ConsoleResult.from(v), l, 0.0)


func _cmd_quit(_a: PackedStringArray) -> Variant:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return ConsoleResult.failure("No game to quit.")
	tree.root.propagate_notification.call_deferred(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	if tree.auto_accept_quit:
		tree.quit.call_deferred()
	return "Quitting."


func _cmd_version(_a: PackedStringArray) -> Variant:
	var v := Engine.get_version_info()
	var rows := [
		["Game", str(ProjectSettings.get_setting("application/config/name", "?"))],
		["Version", str(ProjectSettings.get_setting("application/config/version", "(not set)"))],
		["Godot", "%s (%s)" % [v.string, v.get("hash", "").substr(0, 9)]],
		["Platform", "%s %s" % [OS.get_name(), Engine.get_architecture_name()]],
		["Build", "debug" if OS.is_debug_build() else "release"],
		["Renderer", "%s, %s" % [RenderingServer.get_current_rendering_method(), RenderingServer.get_video_adapter_name()]],
		["Map format", "schema %d" % MapData.SCHEMA_VERSION],
		["Save format", "version %d" % SaveService.FORMAT_VERSION],
	]
	return "\n".join(rows.map(func(r: Array) -> String: return "%-12s%s" % r))


func _cmd_vsync(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		var f := ConsoleParse.flag(a[0])
		if f < 0:
			return ConsoleResult.failure("'%s' is not a state. Vertical sync is one of: on, off, true, false." % a[0])
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if f == 1 else DisplayServer.VSYNC_DISABLED)
	var cap := Engine.max_fps
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		return "Vertical sync is on: a frame every refresh." + (" The cap of %d is ignored while it is on." % cap if cap > 0 else "")
	return "Vertical sync is off. " + ("Frames are capped at %d instead." % cap if cap > 0 else "Nothing caps the frame rate.")


func _cmd_maxfps(a: PackedStringArray) -> Variant:
	if not a.is_empty():
		if not a[0].is_valid_int() or a[0].to_int() < 0:
			return ConsoleResult.failure("'%s' is not a frame rate; use a whole number, 0 for no cap." % a[0])
		Engine.max_fps = a[0].to_int()
	return "Frame-rate cap: %s." % (str(Engine.max_fps) if Engine.max_fps > 0 else "none")
