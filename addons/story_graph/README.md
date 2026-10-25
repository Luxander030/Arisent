# Story Graph (Godot 4 editor plugin)

Design branching stories as a graph of **cells** (story events), check them for mistakes,
and play them through inside the editor. Stories are `StoryGraph` resources (`.tres`) that
your game loads and plays with `StoryRunner`; nothing at runtime depends on the editor.

## Setup

1. The plugin lives in `res://addons/story_graph/`. Enable it in **Project → Project Settings →
   Plugins → Story Graph** (it's already enabled in this project).
2. A **Story** tab appears next to 2D / 3D / Script.
3. Open the example: double-click `res://stories/example_story.tres` in the FileSystem dock,
   or use **Story → Open…**. **Story → New Story…** creates a new one (Start → Dialogue → End).

## Cell types

| Type | Colour | When entered |
|---|---|---|
| Start | green | Entry point (no input). Continues to its first open output. |
| Dialogue | blue | Shows its text (with speaker), waits for *Continue*, then takes the first open output. |
| Choice | orange | Shows its prompt; every output is an option the player can pick. |
| Condition | purple | Takes the first branch whose condition passes; a branch without a condition is the *Else*. |
| Action | teal | Runs its actions and continues immediately. |
| End | red | An ending: the story stops. |

Every cell has a unique **ID**, a **name**, text (dialogue / prompt / ending text), designer
**notes**, **tags**, **actions** that run when it is entered, optional **prerequisites**, and
a *Can happen more than once* switch.

An **output** is open when its own condition passes **and** the target cell can be entered
(its prerequisites pass and, if it's one-time, it hasn't happened yet). Closed choices are
hidden from players by your UI (the simulator shows them greyed out).

### Conditions and prerequisites

Conditions are trees of **All of (AND)**, **Any of (OR)** and **None of (NOT)** groups with:
*event completed*, *event not completed*, *flag is set / not set*, *variable compare*
(`== != < <= > >=`) and *Expression* — a Godot Expression such as
`gold >= 10 and done("intro") and not flag("betrayed")` (helpers: `done(id)`, `flag(name)`,
`times(id)`).

**Triggerable events**: a cell with prerequisites that nothing connects to is an event the
game starts itself (e.g. on entering a room) once its prerequisites pass —
`runner.get_available_events()` lists them and `runner.trigger(id)` starts one.

### Actions

Set / clear a flag, set a variable, add to a variable, mark an event done, reset an event,
and **Emit game event** (`runner.game_event(name, payload)`) to tell your game to give an
item, start a quest, play a cutscene…

Variables and flags are declared in **Story settings** (click empty graph space). Text can
include `{variable}`, replaced when played.

## Editing

- **Add cells**: *Add Cell* menu, right-click or double-click empty space, or drag a connection
  out of a port into empty space (the new cell gets connected).
- **Connect**: drag from an output port (right) to a cell's input (left). An output leads to one
  cell; connecting it again replaces the link. Drag a connection off an input to remove it.
- **Select / move**: click, Ctrl/Cmd-click, or drag a box; drag to move. The buttons at the top-left of
  the graph: zoom, grid snapping, minimap and *auto-arrange*.
- **Duplicate** Ctrl/Cmd+D · **Copy / Cut / Paste** Ctrl/Cmd+C / X / V · **Delete** Delete key.
  Duplicated cells keep connections among themselves.
- **Groups**: select cells → *Group Selected* (Ctrl/Cmd+G). Drag cells onto a group to add them.
  Select a group to rename / recolour it.
- **Find**: type in *Find cell* and press Enter (repeat for the next match).
- **Inspector** (right): everything about the selected cell, including outputs with targets and
  conditions, prerequisites and actions; renaming an ID updates every reference.
- **Undo / redo**: every change is in the editor's undo history (Ctrl/Cmd+Z).
- **Save**: Ctrl/Cmd+S (with the project) or *Story → Save*. Unsaved stories show *(unsaved)* in the
  Story toolbar, and the editor asks before closing. *Story → Export / Import JSON* for other tools.

## Problems

The **Problems** tab (bottom) re-checks the story after every edit; cells with errors get a red
outline, warnings orange. Click a problem to jump to the cell. It reports:
no Start / no End, no End reachable from a Start, duplicate or empty IDs, connections to missing
cells or into Start cells, End cells with outputs, dead ends and unconnected outputs, choices
without options or option text, conditions without an Else, disconnected cells, cells nothing
leads to, cells unreachable from any Start or event, prerequisites on missing events or on the
cell itself, circular prerequisites, prerequisites that can only be met by passing through the
cell itself, loops with no way out (or with no choice / condition / one-time cell to stop
them), undeclared flags and variables, invalid expressions and actions without a name.

## Simulator

**Play ▸** (toolbar), *Play from here* (inspector) or the **Simulator** tab plays the story:
transcript, choice buttons, Continue, **Step back**, triggerable events, and a live view of
completed events, flags and variables — tick flags or edit variables to test other paths.
The graph outlines visited cells in green and the current one in yellow.

## Using stories in the game

```gdscript
var runner := StoryRunner.new(load("res://stories/example_story.tres"))
runner.dialogue.connect(func(cell, speaker, text): $DialogueBox.show_line(speaker, text))
runner.choices_presented.connect(func(cell, choices):
	for c in choices:  # {index, label, target, open}
		if c.open:
			$DialogueBox.add_choice(c.label, func(): runner.choose(c.index)))
runner.game_event.connect(func(name, payload): print("story says: ", name, payload))
runner.story_ended.connect(func(cell, reason): $DialogueBox.close())
runner.start()             # first Start cell; or start("chapter_2", false) to keep state
# ... on "continue": runner.advance()

# Save games: runner.state.to_dict() / runner.state.from_dict(data)
```

## Files

```
plugin.cfg, plugin.gd          editor plugin ("Story" main screen)
core/                          runtime (no editor dependencies)
  story_graph.gd   StoryGraph  cells, groups, variables, flags; JSON import/export
  story_cell.gd    StoryCell   one event
  story_output.gd  StoryOutput link to another cell (+ optional condition)
  story_condition.gd StoryCondition  AND/OR/NOT tree + leaves
  story_action.gd  StoryAction
  story_frame.gd   StoryFrame  group (visual only)
  story_state.gd   StoryState  completed events, flags, variables
  story_runner.gd  StoryRunner plays a story
  story_validator.gd StoryValidator  the Problems checks
editor/                        editor UI (@tool, used only by the plugin)
examples/make_example_story.gd regenerates res://stories/example_story.tres
```

Tests: `tools/run_tests.sh story_graph` (headless; covers conditions, runner, validator,
save/load, and the editor panel).
