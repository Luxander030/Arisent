## Console line parsing (exact Ares rules): "/" introduces a command; quotes group words
## ("" is an empty argument, quotes may sit mid-token); a backslash escapes only inside
## quotes, so Windows paths work as typed. Also: re-quoting for echoes, the completion
## context of a line, and "did you mean" suggestions.
class_name ConsoleParse
extends RefCounted

enum { BLANK, TEXT, INVOCATION, MALFORMED }
enum Target { NONE, NAME, ARGUMENT }


## {kind, value (TEXT), name + args (INVOCATION), error (MALFORMED)}
static func parse(line: String) -> Dictionary:
	var t := line.strip_edges()
	if t == "":
		return {"kind": BLANK}
	if not t.begins_with("/"):
		return {"kind": TEXT, "value": t}
	var body := t.substr(1).strip_edges()
	if body == "":
		return {"kind": MALFORMED, "error": "'/' introduces a command, but none was given. Try /help."}
	var tk := tokenize(body)
	if tk.has("error"):
		return {"kind": MALFORMED, "error": tk.error}
	var toks: PackedStringArray = tk.tokens
	return {"kind": INVOCATION, "name": toks[0], "args": toks.slice(1)}


## {tokens: PackedStringArray, starts: PackedInt32Array, open: bool (ends inside a token
## or quote)} or {error}. `lenient` keeps an unterminated quote as the last token.
static func tokenize(body: String, lenient := false) -> Dictionary:
	var tokens := PackedStringArray()
	var starts := PackedInt32Array()
	var token := ""
	var in_token := false
	var in_quotes := false
	var i := 0
	var n := body.length()
	while i < n:
		var c := body[i]
		if in_quotes and c == "\\" and i + 1 < n:
			token += body[i + 1]
			i += 2
			continue
		if c == "\"":
			if not in_token:
				starts.append(i)
			in_quotes = not in_quotes
			in_token = true
			i += 1
			continue
		if not in_quotes and (c == " " or c == "\t" or c == "\n"):
			if in_token:
				tokens.append(token)
				token = ""
				in_token = false
			i += 1
			continue
		if not in_token:
			starts.append(i)
		token += c
		in_token = true
		i += 1
	if in_quotes and not lenient:
		return {"error": "Unterminated quote: an argument opened with '\"' was never closed."}
	if in_token:
		tokens.append(token)
	return {"tokens": tokens, "starts": starts, "open": in_token}


## An argument as it would have to be typed.
static func quote(arg: String) -> String:
	if arg == "":
		return "\"\""
	if arg.contains(" ") or arg.contains("\t") or arg.contains("\"") or arg.contains("\n"):
		return "\"%s\"" % arg.replace("\\", "\\\\").replace("\"", "\\\"")
	return arg


static func echo(name: String, args: PackedStringArray) -> String:
	var parts := PackedStringArray(["/" + name])
	for a in args:
		parts.append(quote(a))
	return " ".join(parts)


## What the end of an input line is completing:
## {target, name, args (finished), partial, partial_start}
static func caret_context(input: String) -> Dictionary:
	if input == "" or not input.begins_with("/"):
		return {"target": Target.NONE}
	var ws := -1
	for i in range(1, input.length()):
		var c := input[i]
		if c == " " or c == "\t":
			ws = i
			break
	if ws < 0:
		return {"target": Target.NAME, "name": "", "args": PackedStringArray(), "partial": input.substr(1), "partial_start": 1}
	var name := input.substr(1, ws - 1)
	var rest := input.substr(ws)
	var tk := tokenize(rest, true)
	var toks: PackedStringArray = tk.tokens
	var starts: PackedInt32Array = tk.starts
	var last := input[input.length() - 1]
	var ends_open: bool = tk.open and not (last == " " or last == "\t") or _ends_in_quote(rest)
	if ends_open and not toks.is_empty():
		return {"target": Target.ARGUMENT, "name": name, "args": toks.slice(0, toks.size() - 1),
			"partial": toks[toks.size() - 1], "partial_start": ws + starts[starts.size() - 1]}
	return {"target": Target.ARGUMENT, "name": name, "args": toks, "partial": "", "partial_start": input.length()}


static func _ends_in_quote(rest: String) -> bool:
	var tk := tokenize(rest)
	return tk.has("error")


## Candidates that start with `partial` (any case), except one exactly equal to it.
static func matching(candidates: Array, partial: String) -> Array:
	var out: Array = []
	var p := partial.to_lower()
	for c: Variant in candidates:
		var s := str(c)
		if s == "" or s == partial:
			continue
		if s.to_lower().begins_with(p):
			out.append(s)
	return out


## Up to 5 names like `input`: prefix matches, else substring, else edit distance ≤ 2.
static func suggestions(names: Array, input: String) -> PackedStringArray:
	var q := input.to_lower()
	var tiers: Array[Callable] = [
		func(n: String) -> bool: return n.to_lower().begins_with(q),
		func(n: String) -> bool: return n.to_lower().contains(q),
		func(n: String) -> bool: return absi(n.length() - q.length()) <= 2 and levenshtein(n.to_lower(), q) <= 2,
	]
	for t in tiers:
		var out := PackedStringArray()
		for n: String in names:
			if t.call(n):
				out.append(n)
				if out.size() == 5:
					break
		if not out.is_empty():
			return out
	return PackedStringArray()


static func levenshtein(a: String, b: String) -> int:
	var prev := PackedInt32Array()
	for j in b.length() + 1:
		prev.append(j)
	for i in a.length():
		var cur := PackedInt32Array([i + 1])
		for j in b.length():
			cur.append(mini(mini(cur[j] + 1, prev[j + 1] + 1), prev[j] + (0 if a[i] == b[j] else 1)))
		prev = cur
	return prev[b.length()]


# --- shared vocabularies ---------------------------------------------------------------

const FLAG_CHOICES := "on|off"
const LEVEL_NAMES := ["trace", "debug", "info", "warn", "error", "crit"]


## "on"/"off"/"true"/"false" → 1/0, anything else -1.
static func flag(s: String) -> int:
	match s.strip_edges().to_lower():
		"on", "true":
			return 1
		"off", "false":
			return 0
	return -1


## Level name → ConsoleTheme.Kind (TRACE..CRITICAL), or -1.
static func level(s: String) -> int:
	match s.strip_edges().to_lower():
		"trace":
			return ConsoleTheme.Kind.TRACE
		"debug":
			return ConsoleTheme.Kind.DEBUG
		"info":
			return ConsoleTheme.Kind.INFO
		"warn", "warning":
			return ConsoleTheme.Kind.WARNING
		"error":
			return ConsoleTheme.Kind.ERROR
		"crit", "critical":
			return ConsoleTheme.Kind.CRITICAL
	return -1


## Hints from a fixed list or a Callable() -> Array re-evaluated on every keystroke.
static func hints_of(source: Variant) -> Callable:
	return func(_args: PackedStringArray, partial: String) -> Array:
		var list: Array = source.call() if source is Callable else source
		return matching(list, partial)


## Hints per argument position: each entry a list or Callable() -> Array (null = none).
static func hints_by_position(per_arg: Array) -> Callable:
	return func(args: PackedStringArray, partial: String) -> Array:
		if args.size() >= per_arg.size() or per_arg[args.size()] == null:
			return []
		var src: Variant = per_arg[args.size()]
		var list: Array = src.call() if src is Callable else src
		return matching(list, partial)


## A number argument, or `fallback` when it is missing/not a number.
static func number(args: PackedStringArray, i: int, fallback: float) -> float:
	return args[i].to_float() if i < args.size() and args[i].is_valid_float() else fallback
