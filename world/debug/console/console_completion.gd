## Completion state for the input line: the dropdown's matches, selection, scrolling
## window, ghost suffix, and what Tab/Return turn the line into. Context is read from the
## whole line (always the last token).
class_name ConsoleCompletion
extends RefCounted

var model: ConsoleModel
var max_visible := 5
var matches: Array = []
var selected := -1
var window_start := 0
var dismissed := false
var withheld := false
var ctx := {"target": ConsoleParse.Target.NONE}


func _init(m: ConsoleModel) -> void:
	model = m


func refresh(input: String) -> void:
	withheld = false
	var prev: Variant = matches[selected] if selected >= 0 and selected < matches.size() else null
	ctx = ConsoleParse.caret_context(input)
	matches = []
	match int(ctx.target):
		ConsoleParse.Target.NONE:
			reset()
			return
		ConsoleParse.Target.NAME:
			var p := str(ctx.partial).to_lower()
			for n: String in model.command_names():
				if n.to_lower().begins_with(p):
					matches.append(n)
		ConsoleParse.Target.ARGUMENT:
			var c := model.find(str(ctx.name))
			var args: PackedStringArray = ctx.args
			if c and c.has_hints() and args.size() < c.max_args:
				for m: Variant in c.hints.call(args, str(ctx.partial)):
					if m != null and str(m) != "":
						matches.append(str(m))
	if str(ctx.partial) == "":
		dismissed = false
	selected = matches.find(prev) if prev != null else -1
	if selected < 0:
		selected = 0 if not matches.is_empty() else -1
	_slide()


func reset() -> void:
	matches = []
	selected = -1
	window_start = 0
	dismissed = false
	withheld = false
	ctx = {"target": ConsoleParse.Target.NONE}


func ghost() -> String:
	if selected < 0:
		return ""
	var m := str(matches[selected])
	var p := str(ctx.get("partial", ""))
	if m.to_lower().begins_with(p.to_lower()) and m.length() > p.length():
		return m.substr(p.length())
	return ""


func is_open() -> bool:
	return int(ctx.target) != ConsoleParse.Target.NONE and not dismissed and not withheld and not matches.is_empty()


func can_step(delta: int) -> bool:
	return is_open() and selected + delta >= 0 and selected + delta < matches.size()


func move(delta: int) -> void:
	var i := selected + delta
	if i >= 0 and i < matches.size():
		selected = i
		dismissed = false
		_slide()


func dismiss() -> void:
	dismissed = true


func withhold() -> void:
	withheld = true


func completes_on_submit() -> bool:
	return is_open() and ghost() != ""


## Visible rows: [start, end).
func window() -> Vector2i:
	return Vector2i(window_start, mini(matches.size(), window_start + max_visible))


func _slide() -> void:
	if selected < window_start:
		window_start = selected
	elif selected >= window_start + max_visible:
		window_start = selected - max_visible + 1
	window_start = clampi(window_start, 0, maxi(0, matches.size() - max_visible))


## The line after accepting the selection (Tab).
func apply(input: String) -> String:
	if selected < 0:
		return input
	var chosen := str(matches[selected])
	if int(ctx.target) == ConsoleParse.Target.NAME:
		var c := model.find(chosen)
		return "/" + chosen + (" " if c and c.accepts_arguments() else "")
	var c := model.find(str(ctx.name))
	var args: PackedStringArray = ctx.args
	var more := c != null and args.size() + 1 < _max_args(c, args, chosen)
	return input.substr(0, int(ctx.partial_start)) + ConsoleParse.quote(chosen) + (" " if more else "")


## The most arguments this line can take: a verb table's is its verb's plus one.
static func _max_args(c: ConsoleCommand, args: PackedStringArray, chosen: String) -> int:
	if c.verbs == null:
		return c.max_args
	var v := c.verbs.find(args[0] if not args.is_empty() else chosen)
	return 1 + v.max_args if v else c.max_args


## How a dropdown row reads, and how much of it (from the left) is what was typed.
func display(i: int) -> String:
	var m := str(matches[i])
	return "/" + m if int(ctx.target) == ConsoleParse.Target.NAME else m


func highlight_length() -> int:
	return str(ctx.get("partial", "")).length() + (1 if int(ctx.target) == ConsoleParse.Target.NAME else 0)
