## Developer console (port of Ares Last Light's): parsing, completion, verb tables, arity,
## suggestions, async jobs, history, tables, key combos, bindings, bars and the window.
extends TestCase

const Kind := ConsoleTheme.Kind


func _model() -> ConsoleModel:
	DebugZoom.persist = false
	return ConsoleModel.new()


func _texts(m: ConsoleModel, from := 0) -> PackedStringArray:
	var out := PackedStringArray()
	for b in m.blocks.slice(from):
		out.append(ConsoleTheme.strip(str(b.text)) if b.rich else str(b.text))
	return out


func test_parse() -> void:
	eq(ConsoleParse.parse("   ").kind, ConsoleParse.BLANK, "blank")
	var t := ConsoleParse.parse("  hello there ")
	check(t.kind == ConsoleParse.TEXT and t.value == "hello there", "plain text is text")
	var m := ConsoleParse.parse("/  ")
	check(m.kind == ConsoleParse.MALFORMED and str(m.error).begins_with("'/' introduces"), "bare slash")
	var i := ConsoleParse.parse("/give  \"wolf pelt\"  3")
	check(i.kind == ConsoleParse.INVOCATION and i.name == "give", "invocation")
	eq(Array(i.args), ["wolf pelt", "3"], "quoted args")
	eq(Array(ConsoleParse.parse("/x a\"b c\"d \"\"").args), ["ab cd", ""], "mid-token quotes, empty arg")
	eq(Array(ConsoleParse.parse("/exec C:\\scripts\\a.txt").args), ["C:\\scripts\\a.txt"], "backslash literal outside quotes")
	eq(Array(ConsoleParse.parse("/echo \"say \\\"hi\\\"\"").args), ["say \"hi\""], "escapes inside quotes")
	check(str(ConsoleParse.parse("/echo \"open").get("error", "")).begins_with("Unterminated quote"), "unterminated quote")
	eq(ConsoleParse.echo("bind", PackedStringArray(["/time set noon", "ctrl+n", ""])), "/bind \"/time set noon\" ctrl+n \"\"", "echo re-quotes")


func test_caret_context_and_suggestions() -> void:
	eq(ConsoleParse.caret_context("time").target, ConsoleParse.Target.NONE, "no slash, no completion")
	var n := ConsoleParse.caret_context("/ti")
	check(n.target == ConsoleParse.Target.NAME and n.partial == "ti" and n.partial_start == 1, "command name")
	var a := ConsoleParse.caret_context("/time set no")
	check(a.target == ConsoleParse.Target.ARGUMENT and a.name == "time" and Array(a.args) == ["set"] and a.partial == "no" and a.partial_start == 10, "argument partial")
	var e := ConsoleParse.caret_context("/time set ")
	check(e.partial == "" and Array(e.args) == ["set"] and e.partial_start == 10, "trailing space: empty partial")
	var q := ConsoleParse.caret_context("/bind \"/time s")
	check(q.partial == "/time s" and q.partial_start == 6, "open quote is one partial")
	eq(Array(ConsoleParse.suggestions(["save", "saves", "skip", "spawn", "time"], "sa")), ["save", "saves"], "prefix tier")
	eq(Array(ConsoleParse.suggestions(["save", "spawn", "time"], "pa")), ["spawn"], "contains tier")
	eq(Array(ConsoleParse.suggestions(["save", "spawn", "time"], "tmie")), ["time"], "edit-distance tier")
	eq(Array(ConsoleParse.matching(["noon", "Noon", "night"], "noon")), ["Noon"], "exact match dropped, case-differing kept")


func test_commands_arity_and_unknown() -> void:
	var m := _model()
	m.command("greet", "Says hi.", "/greet <name> [times]", func(a: PackedStringArray) -> Variant:
		return "hi %s" % a[0], 1, 2)
	eq(m.run("greet Lux"), "hi Lux", "run returns the reply")
	var before := m.blocks.size()
	m.execute("/greet")
	eq(Array(_texts(m, before)), ["/greet", "/greet takes 1 to 2 arguments, got 0.", "Usage: /greet <name> [times]"], "bad arity")
	check(m.run("gret").begins_with("Unknown command '/gret'. Did you mean /greet?"), "suggests by edit distance")
	check(m.run("zzzz").ends_with("Type /help for the list."), "no suggestion")
	before = m.blocks.size()
	m.execute("help")
	eq(_texts(m, before)[0], "help", "plain text echoed as info")
	eq(_texts(m, before)[1], "Commands start with a slash: /help", "hint for a bare command word")
	check(m.blocks[before].kind == Kind.INFO, "text is info, not input")
	eq(ConsoleCommand.new("a", "", "", Callable(), 1, 1).describe_arity(), "exactly 1 argument", "arity text")
	eq(ConsoleCommand.new("a", "", "", Callable(), 0, ConsoleCommand.VARIADIC).describe_arity(), "any number of arguments", "variadic")
	eq(ConsoleCommand.new("a", "", "", Callable(), 2, ConsoleCommand.VARIADIC).describe_arity(), "at least 2 arguments", "at least")
	check(not m.add(ConsoleCommand.new("Greet", "", "", Callable())), "duplicate names refused (any case)")
	var owner := RefCounted.new()
	m.command("mine", "", "", func(_a: PackedStringArray) -> Variant: return null, 0, 0, Callable(), owner)
	m.remove_owner(owner)
	check(m.find("mine") == null and m.find("greet") != null, "remove_owner")
	check(m.run("help").begins_with("%d commands." % m.commands().size()), "help index")
	check(m.run("help greet").contains("Takes 1 to 2 arguments."), "help detail")
	check(m.run("help gret").begins_with("No command named 'gret'. Did you mean /greet?"), "help unknown")


func test_verb_tables() -> void:
	var m := _model()
	var t := m.verbs("nav", "Navigation.")
	t.verb("status", "Tiles.", func(_a: PackedStringArray) -> Variant: return "ok") \
		.verb("bake", "Bakes.", func(a: PackedStringArray) -> Variant: return "baked " + a[0], 1, 1, "/nav bake <radius>",
			ConsoleParse.hints_of(["10", "100"]))
	check(m.run("nav").begins_with("/nav takes one of:\n  /nav status\n    Tiles."), "bare lists verbs")
	eq(m.run("nav fly"), "'fly' is not something /nav can do. Try: status, bake.", "unknown verb")
	eq(m.run("nav bake"), "Usage: /nav bake <radius>", "verb arity")
	eq(m.run("NAV Bake 5"), "baked 5", "case-insensitive")
	eq(m.find("nav").get_usage(), "/nav status  |  /nav bake <radius>", "usage joins verbs")
	eq(m.find("nav").minimum_for(PackedStringArray(["bake"])), 2, "minimum includes the verb's")
	eq(m.find("nav").minimum_for(PackedStringArray(["fly"])), 0, "unknown verb never holds a line back")
	eq(t.hints(PackedStringArray(), "b"), ["bake"], "verb hints")
	eq(t.hints(PackedStringArray(["bake"]), "1"), ["10", "100"], "forwarded to the verb")
	eq(t.hints(PackedStringArray(["bake", "10"]), ""), [], "nothing past the verb's max")
	var owner := RefCounted.new()
	t.verb("extra", "From elsewhere.", func(_a: PackedStringArray) -> Variant: return null, 0, 0, "", Callable(), owner)
	m.remove_owner(owner)
	check(t.find("extra") == null and t.find("bake") != null, "verbs of an owner go with it")


func test_completion() -> void:
	var m := _model()
	var t := m.verbs("time", "Clock.")
	t.verb("set", "Set.", func(a: PackedStringArray) -> Variant: return a[0], 1, 1, "/time set <when>", ConsoleParse.hints_of(["noon", "night", "dusk"])) \
		.verb("show", "Show.", func(_a: PackedStringArray) -> Variant: return "12:00")
	m.command("timescale", "", "", func(_a: PackedStringArray) -> Variant: return null)
	var c := ConsoleCompletion.new(m)
	c.refresh("/ti")
	eq(c.matches, ["time", "timescale"], "names by prefix")
	check(c.is_open() and c.ghost() == "me", "ghost suffix")
	eq(c.apply("/ti"), "/time ", "Tab adds a space when arguments follow")
	c.refresh("/time")
	check(c.is_open() and c.ghost() == "" and not c.completes_on_submit(), "exact match shows, but Return runs it")
	c.refresh("/time ")
	eq(c.matches, ["set", "show"], "verbs")
	c.refresh("/time s")
	c.move(1)
	eq(c.apply("/time s"), "/time show", "no trailing space after the last argument")
	c.refresh("/time se")
	eq(c.selected, 0, "selection falls back to the first")
	eq(c.apply("/time se"), "/time set ", "chainable")
	c.refresh("/time set n")
	eq(c.matches, ["noon", "night"], "argument hints")
	check(not c.can_step(-1) and c.can_step(1), "no wrap: top edge hands off to history")
	c.move(1)
	c.refresh("/time set ni")
	eq(c.matches[c.selected], "night", "selection survives refinement")
	c.dismiss()
	check(not c.is_open() and c.ghost() == "ght", "dismissed: list shut, ghost stays")
	c.refresh("/time set ")
	check(c.is_open(), "deleting back to an empty token re-arms")
	c.refresh("/time set noon ")
	check(c.matches.is_empty(), "nothing past max arguments")
	check(m.is_short_of_arguments("/time set") and not m.is_short_of_arguments("/time show") and not m.is_short_of_arguments("/time fly"), "short of arguments")
	c.max_visible = 2
	c.refresh("/time set ")
	c.move(1)
	c.move(1)
	eq(c.window(), Vector2i(1, 3), "the window slides with the selection")


func test_history() -> void:
	var h := ConsoleHistory.new()
	eq(h.up(), null, "empty")
	h.record("/a")
	h.record("/b")
	h.record("/b")
	h.record("  ")
	eq(Array(h.entries), ["/a", "/b"], "skips blanks and repeats of the newest")
	eq(h.up(), "/b", "newest first")
	eq(h.up(), "/a", "older")
	eq(h.up(), null, "stops at the oldest")
	eq(h.down(), "/b", "newer")
	eq(h.down(), "", "back to the bottom")
	eq(h.down(), null, "already there")
	for i in 200:
		h.record("/x%d" % i)
	eq(h.entries.size(), ConsoleHistory.CAPACITY, "bounded")


func test_async_jobs() -> void:
	var m := _model()
	var before := m.blocks.size()
	m.execute("/delay 0.05")
	m.execute("/delay 0.01")
	check(m.is_busy(), "running")
	check(_texts(m, before).has("/delay 0.01 is queued behind /delay 0.05."), "second one queues")
	check(m.bars.render(ConsoleBars.Slot.STATUS_LEFT).contains("/delay 0.05") and m.bars.render(ConsoleBars.Slot.STATUS_LEFT).contains("(1 queued)"), "activity bar")
	eq(m.run("echo still"), "still", "sync commands run while a job is in flight")
	var t0 := Time.get_ticks_msec()
	while m.is_busy() and Time.get_ticks_msec() - t0 < 3000:
		await Engine.get_main_loop().process_frame
		m.pump()
	var out := _texts(m, before)
	var waited := Array(out).filter(func(l: String) -> bool: return l.begins_with("Waited "))
	eq(waited.size(), 2, "both landed")
	check(not m.is_busy() and m.bars.render(ConsoleBars.Slot.STATUS_LEFT) == "", "idle again")
	check(m.run("delay x").begins_with("'x' is not a number of seconds."), "bad delay")
	check(m.run("delay 601").begins_with("Delay for 0 to 600 seconds"), "out of range")


func test_exec_file() -> void:
	var m := _model()
	var f := FileAccess.open("user://test_console_exec.txt", FileAccess.WRITE)
	f.store_string("# comment\n/echo one\n\necho two\n/delay 0\n/echo three\n")
	f.close()
	var before := m.blocks.size()
	m.execute("/exec test_console_exec.txt")
	var t0 := Time.get_ticks_msec()
	while m.is_busy() and Time.get_ticks_msec() - t0 < 3000:
		await Engine.get_main_loop().process_frame
		m.pump()
	var out := Array(_texts(m, before))
	check(out.has("one") and out.has("two") and out.has("three"), "runs every line")
	check(out.find("one") < out.find("three"), "in order (delay ran inline)")
	check(out.has("Ran 4 lines of user://test_console_exec.txt."), "summary")
	DirAccess.remove_absolute("user://test_console_exec.txt")


func test_output_levels_and_split() -> void:
	var m := _model()
	m.clear()
	m.log_line(Kind.DEBUG, "dbg")
	m.log_line(Kind.WARNING, "warn")
	m.print_line(Kind.INPUT, "/x")
	m.set_display_level(Kind.WARNING)
	eq(m.visible_count(), 2, "input is never filtered")
	check(m.run("log level").begins_with("Display level is warn"), "log level report")
	check(m.run("log level loud").begins_with("'loud' is not a level."), "bad level")
	var before := m.blocks.size()
	m.print_line(Kind.INFO, "\n".join(range(150).map(func(i: int) -> String: return str(i))))
	eq(m.blocks.size() - before, 3, "150 lines split into 64-line blocks")
	var bb := ConsoleModel.block_bbcode({"kind": Kind.ERROR, "text": "a [b]", "rich": false, "logged": true, "time": "01:02:03"})
	check(bb.contains("[lb]01:02:03]") and bb.contains("[lb]E]") and bb.contains("a [lb]b]") and bb.contains(ConsoleTheme.KIND_COLORS[Kind.ERROR]), "stamp, escape, colour")
	var big := ConsoleModel.new()
	for i in ConsoleModel.CAPACITY + 10:
		big.print_line(Kind.INFO, str(i))
	eq(big.blocks.size(), ConsoleModel.CAPACITY, "scrollback bounded")


func test_logger_bridge() -> void:
	var m := _model()
	var lg := ConsoleLogger.new(m)
	OS.add_logger(lg)
	print("console-bridge-probe")
	push_warning("console-bridge-warning")
	OS.remove_logger(lg)
	m.pump()
	var out := _texts(m)
	check(Array(out).has("console-bridge-probe"), "print lands as a line")
	var w := Array(out).filter(func(l: String) -> bool: return l.begins_with("console-bridge-warning"))
	check(w.size() == 1, "push_warning lands")
	check(m.blocks.any(func(b: Dictionary) -> bool: return b.kind == Kind.WARNING and str(b.text).begins_with("console-bridge-warning")), "as a warning")


func test_tables() -> void:
	var t := ConsoleTheme.strip(ConsoleTable.format([["name", "n", "ok"], ["wolf", 3, true], ["sheep", 12, false]]))
	eq(t, "┌───────┬────┬─────┐\n│ name  │ n  │ ok  │\n├───────┼────┼─────┤\n│ wolf  │  3 │ yes │\n│ sheep │ 12 │ no  │\n└───────┴────┴─────┘", "layout")
	var fit := ConsoleTheme.strip(ConsoleTable.format([["a very long cell indeed", "x"]], "ascii", "ascii", 20))
	check(fit.split("\n")[1].length() <= 20 and fit.contains("…"), "fits with an ellipsis")
	check(ConsoleTable.format([["[x]"]]).contains("[lb]x]"), "cells are escaped")
	check(ConsoleTheme.strip(ConsoleTable.format([["a"], ["b"]], "rounded")).begins_with("╭"), "rounded")


func test_key_combos_and_bindings() -> void:
	var k := KeyCombo.parse("Ctrl+Shift+F3")
	check(k != null and k.ctrl and k.shift and not k.alt and k.key == KEY_F3, "parse")
	eq(str(KeyCombo.parse("ctrl+`")), "Ctrl+`", "backquote alias")
	eq(KeyCombo.parse("ctrl+shift"), null, "only modifiers")
	check(KeyCombo.last_error.contains("only modifiers"), "message")
	KeyCombo.parse("a+b")
	check(KeyCombo.last_error.contains("more than one key"), "two keys")
	KeyCombo.parse("ctrl+")
	check(KeyCombo.last_error.contains("empty part"), "empty part")
	KeyCombo.parse("ctrl+blorp")
	eq(KeyCombo.last_error, "'blorp' is not a key name.", "unknown key")
	var e := InputEventKey.new()
	e.keycode = KEY_F3
	e.ctrl_pressed = true
	e.shift_pressed = true
	e.pressed = true
	check(k.matches(e), "matches exactly")
	e.alt_pressed = true
	check(not k.matches(e), "extra modifier: no match")
	var m := _model()
	eq(m.run("bind \"/echo bound!\" ctrl+shift+f3"), "Bound Ctrl+Shift+F3 to /echo bound!.", "bind")
	eq(m.run("bind \"echo again\" CTRL+SHIFT+F3"), "Rebound Ctrl+Shift+F3 to /echo again.", "rebind")
	check(m.run("bind").contains("Ctrl+Shift+F3  /echo again"), "list")
	e.alt_pressed = false
	var before := m.blocks.size()
	check(m.fire_binding(e), "fires")
	check(_texts(m, before).has("again"), "ran its line")
	check(m.run("bind \"\" f4").begins_with("A binding needs a command line"), "empty line")
	eq(m.run("unbind ctrl+shift+f3"), "Unbound Ctrl+Shift+F3.", "unbind")
	eq(m.run("unbind ctrl+shift+f3"), "Ctrl+Shift+F3 is not bound.", "not bound")


func test_bars_and_zoom() -> void:
	var b := ConsoleBars.new()
	b.add("b", ConsoleBars.Slot.STATUS_LEFT, func() -> String: return "B", 5)
	b.add("a", ConsoleBars.Slot.STATUS_LEFT, func() -> String: return "A", 1)
	b.add("empty", ConsoleBars.Slot.STATUS_LEFT, func() -> String: return "", 3)
	eq(b.render(ConsoleBars.Slot.STATUS_LEFT), "A  B", "ordered, empty sections leave no gap")
	eq(ConsoleBars.duration(0.042), "42ms", "ms")
	eq(ConsoleBars.duration(3.25), "3.2s", "s")
	eq(ConsoleBars.duration(125.0), "2m 05s", "m s")
	DebugZoom.persist = false
	DebugZoom.set_value(1.0)
	check(DebugZoom.step(1) and is_equal_approx(DebugZoom.get_value(), 1.25), "zoom up a rung")
	DebugZoom.set_value(1.1)
	DebugZoom.step(-1)
	check(is_equal_approx(DebugZoom.get_value(), 1.0), "off-rung snaps to the next rung down")
	DebugZoom.set_value(3.0)
	check(not DebugZoom.step(1), "top of the range")
	DebugZoom.set_value(1.0)


func test_window_keys() -> void:
	DevGate.force = true
	DebugZoom.persist = false
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var con := DebugConsole.new()
	root.add_child(con)
	await Engine.get_main_loop().process_frame
	var opened := [false]
	con.toggled.connect(func(o: bool) -> void: opened[0] = o)
	con.set_open(true)
	await Engine.get_main_loop().process_frame
	check(opened[0] and con.window and con.window.visible, "opens")
	var w := con.window
	w.set_line("/ech")
	check(w.completion.is_open() and w.completion.ghost() == "o", "suggests while typing")
	w.submit()
	eq(w.line(), "/echo ", "Return completes and keeps a line that is still short of arguments")
	w.set_line("/echo hi")
	var before := con.model.blocks.size()
	w.submit()
	check(w.line() == "" and _texts(con.model, before).has("hi"), "Return runs a complete line")
	w.recall(-1)
	eq(w.line(), "/echo hi", "Up recalls history")
	check(not w.completion.is_open(), "a recalled line withholds the list")
	w.set_line("/ech")
	w.escape()
	check(not w.completion.is_open() and w.line() == "/ech", "Esc 1: dismiss")
	w.escape()
	eq(w.line(), "", "Esc 2: clear")
	w.escape()
	check(not con.is_open and not opened[0], "Esc 3: close")
	con.queue_free()
	DevGate.force = false
