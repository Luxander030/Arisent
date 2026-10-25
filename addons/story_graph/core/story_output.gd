@tool
class_name StoryOutput
extends Resource
## One way out of a cell: a choice option, a conditional branch or simply "next".
## The output is only usable when `condition` passes (null = always) and the target
## cell's prerequisites are met.

@export var label := ""
@export var target_id := ""
@export var condition: StoryCondition


static func make(label_ := "", target := "", cond: StoryCondition = null) -> StoryOutput:
	var o := StoryOutput.new()
	o.label = label_
	o.target_id = target
	o.condition = cond
	return o


func has_condition() -> bool:
	return condition != null and not condition.is_trivial()


func to_dict() -> Dictionary:
	var d := {"label": label, "target": target_id}
	if has_condition():
		d.condition = condition.to_dict()
	return d


static func from_dict(d: Dictionary) -> StoryOutput:
	var o := StoryOutput.new()
	o.label = str(d.get("label", ""))
	o.target_id = str(d.get("target", ""))
	var c: Variant = d.get("condition")
	if c is Dictionary:
		o.condition = StoryCondition.from_dict(c)
	return o
