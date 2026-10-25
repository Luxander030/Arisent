## A verb table behind one command: `/nav status`, `/nav bake`… Verbs are ConsoleCommands
## (their name is the verb, their usage e.g. "/nav bake [radius]"). Open tables may start
## empty and gain verbs from other systems (with an owner, removed with remove_owner).
class_name ConsoleVerbs
extends RefCounted

var command_name: String
var _verbs: Array[ConsoleCommand] = []
var _owners := {}   ## verb -> owner Object


func _init(cmd_name: String, list: Array = []) -> void:
	command_name = cmd_name
	for v: ConsoleCommand in list:
		add(v)


## Shorthand for a verb: usage defaults to "/command verb".
func verb(v: String, desc: String, fn: Callable, lo := 0, hi := 0, use := "", hint := Callable(), owner: Object = null) -> ConsoleVerbs:
	add(ConsoleCommand.new(v, desc, use if use != "" else "/%s %s" % [command_name, v], fn, lo, hi, hint), owner)
	return self


func add(v: ConsoleCommand, owner: Object = null) -> void:
	assert(find(v.name) == null, "/%s already has a verb '%s'" % [command_name, v.name])
	_verbs.append(v)
	if owner:
		_owners[v.name.to_lower()] = weakref(owner)


func remove(v: String) -> bool:
	var c := find(v)
	if c == null:
		return false
	_verbs.erase(c)
	_owners.erase(v.to_lower())
	return true


func remove_owner(owner: Object) -> void:
	for k: String in _owners.keys():
		var w: WeakRef = _owners[k]
		if w.get_ref() == owner or w.get_ref() == null:
			remove(k)


func find(v: String) -> ConsoleCommand:
	var l := v.to_lower()
	for c in _verbs:
		if c.name.to_lower() == l:
			return c
	return null


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for c in _verbs:
		out.append(c.name)
	return out


func list() -> Array[ConsoleCommand]:
	return _verbs


func is_empty() -> bool:
	return _verbs.is_empty()


func usage() -> String:
	if _verbs.is_empty():
		return "/" + command_name
	var u := PackedStringArray()
	for c in _verbs:
		u.append(c.usage)
	return "  |  ".join(u)


func dispatch(args: PackedStringArray) -> Variant:
	if args.is_empty():
		var lines := PackedStringArray(["/%s takes one of:" % command_name])
		for c in _verbs:
			lines.append("  " + ConsoleTheme.green(c.usage))
			lines.append("    " + ConsoleTheme.esc(c.description))
		return ConsoleResult.rich_text("\n".join(lines))
	var c := find(args[0])
	if c == null:
		if _verbs.is_empty():
			return ConsoleResult.failure("'%s' is not something /%s can do. Nothing has registered a verb with /%s yet." % [args[0], command_name, command_name])
		return ConsoleResult.failure("'%s' is not something /%s can do. Try: %s." % [args[0], command_name, ", ".join(names())])
	var rest := args.slice(1)
	if not c.accepts(rest.size()):
		return ConsoleResult.failure("Usage: " + c.usage)
	return c.handler.call(rest)


func hints(args: PackedStringArray, partial: String) -> Array:
	if args.is_empty():
		return ConsoleParse.matching(Array(names()), partial)
	var c := find(args[0])
	var rest := args.slice(1)
	if c and c.has_hints() and rest.size() < c.max_args:
		return c.hints.call(rest, partial)
	return []


func minimum_for(args: PackedStringArray) -> int:
	if args.is_empty():
		return 0
	var c := find(args[0])
	return 0 if c == null else 1 + c.minimum_for(args.slice(1))
