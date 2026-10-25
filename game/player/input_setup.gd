## Registers the movement actions at startup (WASD/arrows, Space, Ctrl/C, Shift, E use, K skill
## tree, left mouse fire, right mouse aim), so they
## exist in every build without hand-editing the input map.
class_name InputSetup
extends RefCounted

const ACTIONS := {
	"move_forward": [KEY_W, KEY_UP],
	"move_back": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"jump": [KEY_SPACE],
	"crouch": [KEY_CTRL, KEY_C],
	"walk": [KEY_SHIFT],
	"use": [KEY_E],
	"skill_tree": [KEY_K],
}


static func ensure() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.2)
		for key: int in ACTIONS[action]:
			var e := InputEventKey.new()
			e.physical_keycode = key
			InputMap.action_add_event(action, e)
	if not InputMap.has_action("fire"):
		InputMap.add_action("fire")
		var lmb := InputEventMouseButton.new()
		lmb.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("fire", lmb)
		var rt := InputEventJoypadMotion.new()
		rt.axis = JOY_AXIS_TRIGGER_RIGHT
		rt.axis_value = 1.0
		InputMap.action_add_event("fire", rt)
	if not InputMap.has_action("aim"):
		InputMap.add_action("aim")
		var rmb := InputEventMouseButton.new()
		rmb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("aim", rmb)
		var lt := InputEventJoypadMotion.new()
		lt.axis = JOY_AXIS_TRIGGER_LEFT
		lt.axis_value = 1.0
		InputMap.action_add_event("aim", lt)
	# Gamepad: left stick moves, A jumps, B crouches.
	_pad("move_left", JOY_AXIS_LEFT_X, -1.0)
	_pad("move_right", JOY_AXIS_LEFT_X, 1.0)
	_pad("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_pad("move_back", JOY_AXIS_LEFT_Y, 1.0)
	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	InputMap.action_add_event("jump", a)
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_B
	InputMap.action_add_event("crouch", b)


static func _pad(action: String, axis: int, value: float) -> void:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	InputMap.action_add_event(action, e)
