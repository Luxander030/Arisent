@tool
class_name StoryCell
extends Resource
## One story event ("cell"). What it does when entered depends on its type:
##   START      an entry point; continues to its first open output
##   DIALOGUE   shows `text` (said by `speaker`), waits for "continue", then takes the first open output
##   CHOICE     shows `text` as a prompt; each output is an option the player can pick
##   CONDITION  shows nothing; takes the first output whose condition passes (no condition = else)
##   ACTION     runs its actions and continues (any cell can have actions)
##   END        an ending; the story stops
## A cell can only be entered when its prerequisites pass (and, if not repeatable, it hasn't happened yet).

enum Type { START, DIALOGUE, CHOICE, CONDITION, ACTION, END }

const TYPE_NAMES := ["Start", "Dialogue", "Choice", "Condition", "Action", "End"]
const TYPE_COLORS := [Color(0.22, 0.6, 0.33), Color(0.26, 0.46, 0.78), Color(0.86, 0.53, 0.16),
	Color(0.57, 0.38, 0.8), Color(0.16, 0.6, 0.6), Color(0.78, 0.26, 0.28)]
const TYPE_HINTS := [
	"Entry point of the story. Continues to its first output.",
	"A line of dialogue or narration. Waits for the player, then continues.",
	"Asks the player to pick one of its options.",
	"Picks the first branch whose condition passes. A branch without a condition is the 'else'.",
	"Runs its actions and continues immediately.",
	"An ending. The story stops here.",
]

@export var id := ""
@export var title := ""
@export var type: Type = Type.DIALOGUE
@export var speaker := ""
@export_multiline var text := ""             ## dialogue line, choice prompt or ending text
@export_multiline var notes := ""            ## designer notes; never shown to players
@export var position := Vector2.ZERO          ## graph position (editor only)
@export var outputs: Array[StoryOutput] = []
@export var prerequisites: StoryCondition     ## null = always available
@export var actions: Array[StoryAction] = []  ## run when the cell is entered
@export var repeatable := true                ## false: can only happen once
@export var tags: PackedStringArray = []


static func create(type_: Type, id_: String, pos := Vector2.ZERO) -> StoryCell:
	var c := StoryCell.new()
	c.type = type_
	c.id = id_
	c.position = pos
	c.title = TYPE_NAMES[type_]
	match type_:
		Type.START, Type.DIALOGUE:
			c.outputs.append(StoryOutput.make())
		Type.ACTION:
			c.outputs.append(StoryOutput.make())
			c.actions.append(StoryAction.make(StoryAction.Kind.SET_FLAG, ""))
		Type.CHOICE:
			c.text = "What do you do?"
			c.outputs.append(StoryOutput.make("Option 1"))
			c.outputs.append(StoryOutput.make("Option 2"))
		Type.CONDITION:
			c.outputs.append(StoryOutput.make("If", "", StoryCondition.make(StoryCondition.Kind.FLAG_SET, "")))
			c.outputs.append(StoryOutput.make("Else"))
	if type_ == Type.START:
		c.repeatable = false
	return c


func has_input() -> bool:
	return type != Type.START


func allows_outputs() -> bool:
	return type != Type.END


func display_name() -> String:
	return title if title.strip_edges() != "" else id


func has_prerequisites() -> bool:
	return prerequisites != null and not prerequisites.is_trivial()


## Label shown next to output port i.
func output_caption(i: int) -> String:
	var o := outputs[i]
	var text_ := o.label
	if text_ == "":
		match type:
			Type.CONDITION:
				text_ = "Else" if not o.has_condition() else "Branch %d" % (i + 1)
			Type.CHOICE:
				text_ = "Option %d" % (i + 1)
			_:
				text_ = "Next" if outputs.size() == 1 else "Out %d" % (i + 1)
	if o.has_condition() and type != Type.CONDITION:
		text_ += "  [if %s]" % o.condition.describe()
	elif o.has_condition():
		text_ += ": " + o.condition.describe()
	return text_


func to_dict() -> Dictionary:
	var d := {
		"id": id, "title": title, "type": TYPE_NAMES[type].to_upper(), "position": [position.x, position.y],
		"outputs": outputs.map(func(o: StoryOutput) -> Dictionary: return o.to_dict()),
		"repeatable": repeatable,
	}
	if speaker != "":
		d.speaker = speaker
	if text != "":
		d.text = text
	if notes != "":
		d.notes = notes
	if has_prerequisites():
		d.prerequisites = prerequisites.to_dict()
	if not actions.is_empty():
		d.actions = actions.map(func(a: StoryAction) -> Dictionary: return a.to_dict())
	if not tags.is_empty():
		d.tags = Array(tags)
	return d


static func from_dict(d: Dictionary) -> StoryCell:
	var c := StoryCell.new()
	c.id = str(d.get("id", ""))
	c.title = str(d.get("title", ""))
	var t := str(d.get("type", "DIALOGUE")).to_upper()
	c.type = Type.get(t, Type.DIALOGUE) as Type
	c.speaker = str(d.get("speaker", ""))
	c.text = str(d.get("text", ""))
	c.notes = str(d.get("notes", ""))
	var p: Array = d.get("position", [0, 0])
	c.position = Vector2(float(p[0]), float(p[1]))
	for o: Variant in d.get("outputs", []):
		if o is Dictionary:
			c.outputs.append(StoryOutput.from_dict(o))
	var pre: Variant = d.get("prerequisites")
	if pre is Dictionary:
		c.prerequisites = StoryCondition.from_dict(pre)
	for a: Variant in d.get("actions", []):
		if a is Dictionary:
			c.actions.append(StoryAction.from_dict(a))
	c.repeatable = bool(d.get("repeatable", true))
	c.tags = PackedStringArray(d.get("tags", []))
	return c
