## One console command (or one verb of a ConsoleVerbs table). Arguments are always
## strings; handlers parse their own.
##   handler(args: PackedStringArray) -> String | ConsoleResult | ConsoleJob | null
##   hints(finished_args: PackedStringArray, partial: String) -> Array of candidates
##     (authoritative: completion shows exactly what it returns; see ConsoleParse.matching)
##   minimum_when(args) -> int: the minimum argument count for this particular line.
class_name ConsoleCommand
extends RefCounted

const VARIADIC := 1 << 30

var name: String
var description: String
var usage: String
var handler: Callable
var min_args := 0
var max_args := 0
var hints: Callable
var minimum_when: Callable
var verbs: ConsoleVerbs     ## set when the command is a verb table


func _init(n: String, desc: String, use: String, fn: Callable, lo := 0, hi := 0, hint := Callable(), min_when := Callable()) -> void:
	assert(n.strip_edges() != "" and not n.contains(" ") and not n.contains("\t") and not n.begins_with("/"), "bad command name '%s'" % n)
	assert(lo >= 0 and hi >= lo, "bad arity for '%s'" % n)
	name = n
	description = desc
	usage = use if use != "" else "/" + n
	handler = fn
	min_args = lo
	max_args = hi
	hints = hint
	minimum_when = min_when


## A command whose first argument picks a verb from `table`.
static func with_verbs(n: String, desc: String, table: ConsoleVerbs) -> ConsoleCommand:
	var c := ConsoleCommand.new(n, desc, "", table.dispatch, 0, VARIADIC, table.hints, table.minimum_for)
	c.verbs = table
	return c


func get_usage() -> String:
	return verbs.usage() if verbs else usage


func accepts_arguments() -> bool:
	return max_args > 0


func accepts(n: int) -> bool:
	return n >= min_args and n <= max_args


func minimum_for(args: PackedStringArray) -> int:
	return int(minimum_when.call(args)) if minimum_when.is_valid() else min_args


func has_hints() -> bool:
	return hints.is_valid()


func describe_arity() -> String:
	if max_args == 0:
		return "no arguments"
	if max_args >= VARIADIC:
		return "any number of arguments" if min_args == 0 else "at least %s" % _count(min_args)
	if min_args == max_args:
		return "exactly %s" % _count(min_args)
	return "%d to %d arguments" % [min_args, max_args]


static func _count(n: int) -> String:
	return "%d argument%s" % [n, "" if n == 1 else "s"]
