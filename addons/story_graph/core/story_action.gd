@tool
class_name StoryAction
extends Resource
## Something that happens when a cell is entered: change a flag or variable, mark an
## event done or not done, or emit a named event for the game to react to.

enum Kind { SET_FLAG, CLEAR_FLAG, SET_VARIABLE, ADD_VARIABLE, MARK_COMPLETED, RESET_EVENT, EMIT_EVENT }

const KIND_NAMES := ["Set flag", "Clear flag", "Set variable", "Add to variable", "Mark event done",
	"Reset event", "Emit game event"]

@export var kind: Kind = Kind.SET_FLAG
@export var target := ""   ## flag, variable, event id, or game event name
@export var value := ""    ## SET_VARIABLE / ADD_VARIABLE amount / EMIT_EVENT payload


static func make(k: Kind, tgt: String, value_ := "") -> StoryAction:
	var a := StoryAction.new()
	a.kind = k
	a.target = tgt
	a.value = value_
	return a


func uses_value() -> bool:
	return kind == Kind.SET_VARIABLE or kind == Kind.ADD_VARIABLE or kind == Kind.EMIT_EVENT


## Applies the state change. EMIT_EVENT changes nothing here (StoryRunner emits it).
func apply(state: StoryState) -> void:
	match kind:
		Kind.SET_FLAG:
			state.set_flag(target, true)
		Kind.CLEAR_FLAG:
			state.set_flag(target, false)
		Kind.SET_VARIABLE:
			state.set_var(target, StoryCondition.parse_value(value))
		Kind.ADD_VARIABLE:
			var cur: Variant = state.get_var(target, 0)
			var add: Variant = StoryCondition.parse_value(value)
			var a := float(cur) if (cur is int or cur is float) else 0.0
			var b := float(add) if (add is int or add is float) else 0.0
			var both_int := (cur is int or cur == null) and add is int
			state.set_var(target, int(a + b) if both_int else a + b)
		Kind.MARK_COMPLETED:
			state.mark_completed(target)
		Kind.RESET_EVENT:
			state.completed.erase(target)


func describe() -> String:
	match kind:
		Kind.SET_FLAG: return "set %s" % target
		Kind.CLEAR_FLAG: return "clear %s" % target
		Kind.SET_VARIABLE: return "%s = %s" % [target, value]
		Kind.ADD_VARIABLE: return "%s += %s" % [target, value]
		Kind.MARK_COMPLETED: return "done(%s)" % target
		Kind.RESET_EVENT: return "reset(%s)" % target
		Kind.EMIT_EVENT: return "emit %s(%s)" % [target, value]
	return "?"


func to_dict() -> Dictionary:
	var d := {"kind": Kind.keys()[kind], "target": target}
	if uses_value():
		d.value = value
	return d


static func from_dict(d: Dictionary) -> StoryAction:
	var a := StoryAction.new()
	a.kind = Kind.get(str(d.get("kind", "SET_FLAG")), Kind.SET_FLAG) as Kind
	a.target = str(d.get("target", ""))
	a.value = str(d.get("value", ""))
	return a
