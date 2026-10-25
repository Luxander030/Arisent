@tool
class_name StoryCondition
extends Resource
## A requirement that is true or false for a StoryState. Groups (ALL = AND, ANY = OR,
## NOT = none of) hold child conditions; leaves test completed events, flags, variables or
## a Godot Expression. Used for cell prerequisites and for conditional outputs.

enum Kind { ALL, ANY, NOT, COMPLETED, NOT_COMPLETED, FLAG_SET, FLAG_NOT_SET, VARIABLE, EXPRESSION }

const KIND_NAMES := ["All of (AND)", "Any of (OR)", "None of (NOT)", "Event completed",
	"Event not completed", "Flag is set", "Flag is not set", "Variable compare", "Expression"]
const OPS := ["==", "!=", "<", "<=", ">", ">="]

@export var kind: Kind = Kind.ALL
@export var children: Array[StoryCondition] = []
@export var target := ""        ## event id, flag name or variable name
@export var op := "=="          ## VARIABLE only
@export var value := ""         ## VARIABLE only; parsed with parse_value()
@export var expression := ""    ## EXPRESSION only


static func make(k: Kind, tgt := "", op_ := "==", value_ := "") -> StoryCondition:
	var c := StoryCondition.new()
	c.kind = k
	c.target = tgt
	c.op = op_
	c.value = value_
	return c


static func group(k: Kind, items: Array[StoryCondition]) -> StoryCondition:
	var c := StoryCondition.new()
	c.kind = k
	c.children = items
	return c


func is_group() -> bool:
	return kind == Kind.ALL or kind == Kind.ANY or kind == Kind.NOT


## An empty AND group: always true, means "no requirement".
func is_trivial() -> bool:
	return kind == Kind.ALL and children.is_empty()


func evaluate(state: StoryState) -> bool:
	match kind:
		Kind.ALL:
			for c in children:
				if c and not c.evaluate(state):
					return false
			return true
		Kind.ANY:
			if children.is_empty():
				return true
			for c in children:
				if c and c.evaluate(state):
					return true
			return false
		Kind.NOT:
			for c in children:
				if c and c.evaluate(state):
					return false
			return true
		Kind.COMPLETED:
			return state.is_completed(target)
		Kind.NOT_COMPLETED:
			return not state.is_completed(target)
		Kind.FLAG_SET:
			return state.has_flag(target)
		Kind.FLAG_NOT_SET:
			return not state.has_flag(target)
		Kind.VARIABLE:
			return compare(state.get_var(target), op, parse_value(value))
		Kind.EXPRESSION:
			var result: Variant = state.evaluate_expression(expression)
			return result is bool and result
	return false


## Short readable text, e.g. "(done(intro) AND gold >= 10)".
func describe() -> String:
	match kind:
		Kind.ALL, Kind.ANY, Kind.NOT:
			var parts: PackedStringArray = []
			for c in children:
				if c:
					parts.append(c.describe())
			if parts.is_empty():
				return "always" if kind != Kind.ANY else "always"
			if kind == Kind.NOT:
				return "NOT (%s)" % " OR ".join(parts)
			var joined := (" AND " if kind == Kind.ALL else " OR ").join(parts)
			return joined if parts.size() == 1 else "(%s)" % joined
		Kind.COMPLETED:
			return "done(%s)" % target
		Kind.NOT_COMPLETED:
			return "not done(%s)" % target
		Kind.FLAG_SET:
			return "flag %s" % target
		Kind.FLAG_NOT_SET:
			return "no flag %s" % target
		Kind.VARIABLE:
			return "%s %s %s" % [target, op, value]
		Kind.EXPRESSION:
			return "{%s}" % expression
	return "?"


## Collects referenced names into out = {"events": {}, "flags": {}, "variables": {}, "expressions": []}.
func collect_refs(out: Dictionary) -> void:
	match kind:
		Kind.ALL, Kind.ANY, Kind.NOT:
			for c in children:
				if c:
					c.collect_refs(out)
		Kind.COMPLETED, Kind.NOT_COMPLETED:
			(out.events as Dictionary)[target] = true
		Kind.FLAG_SET, Kind.FLAG_NOT_SET:
			(out.flags as Dictionary)[target] = true
		Kind.VARIABLE:
			(out.variables as Dictionary)[target] = true
		Kind.EXPRESSION:
			(out.expressions as Array).append(expression)


## Event ids that must be completed for this to pass no matter which branch is taken
## (COMPLETED leaves reached only through AND groups).
func required_events() -> PackedStringArray:
	var out: PackedStringArray = []
	if kind == Kind.COMPLETED:
		out.append(target)
	elif kind == Kind.ALL or (kind == Kind.ANY and children.size() == 1):
		for c in children:
			if c:
				out.append_array(c.required_events())
	return out


## Renames an event id everywhere inside this condition.
func rename_event(old_id: String, new_id: String) -> void:
	if (kind == Kind.COMPLETED or kind == Kind.NOT_COMPLETED) and target == old_id:
		target = new_id
	for c in children:
		if c:
			c.rename_event(old_id, new_id)


func to_dict() -> Dictionary:
	var d := {"kind": Kind.keys()[kind]}
	if is_group():
		d.children = children.filter(func(c: StoryCondition) -> bool: return c != null).map(
			func(c: StoryCondition) -> Dictionary: return c.to_dict())
	elif kind == Kind.EXPRESSION:
		d.expression = expression
	else:
		d.target = target
		if kind == Kind.VARIABLE:
			d.op = op
			d.value = value
	return d


static func from_dict(d: Dictionary) -> StoryCondition:
	var c := StoryCondition.new()
	var k: String = str(d.get("kind", "ALL"))
	c.kind = Kind.get(k, Kind.ALL) as Kind
	c.target = str(d.get("target", ""))
	c.op = str(d.get("op", "=="))
	c.value = str(d.get("value", ""))
	c.expression = str(d.get("expression", ""))
	for child: Variant in d.get("children", []):
		if child is Dictionary:
			c.children.append(StoryCondition.from_dict(child))
	return c


## "true"/"false" -> bool, numbers -> int/float, "quoted" -> String, anything else -> String.
static func parse_value(text: String) -> Variant:
	var t := text.strip_edges()
	if t == "true":
		return true
	if t == "false":
		return false
	if t.is_valid_int():
		return t.to_int()
	if t.is_valid_float():
		return t.to_float()
	if t.length() >= 2 and ((t.begins_with("\"") and t.ends_with("\"")) or (t.begins_with("'") and t.ends_with("'"))):
		return t.substr(1, t.length() - 2)
	return t


static func compare(a: Variant, operator: String, b: Variant) -> bool:
	var numeric := (a is int or a is float or a is bool or a == null) and (b is int or b is float or b is bool)
	if numeric:
		var x := float(a) if a != null else 0.0
		var y := float(b)
		match operator:
			"==": return is_equal_approx(x, y)
			"!=": return not is_equal_approx(x, y)
			"<": return x < y
			"<=": return x <= y
			">": return x > y
			">=": return x >= y
		return false
	var sa := "" if a == null else str(a)
	var sb := str(b)
	match operator:
		"==": return sa == sb
		"!=": return sa != sb
		"<": return sa < sb
		"<=": return sa <= sb
		">": return sa > sb
		">=": return sa >= sb
	return false
