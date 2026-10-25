## A key plus exact modifiers, written like "ctrl+shift+f3" (for /bind). Matching is
## exact: Ctrl+S does not fire while Ctrl+Shift+S is held.
class_name KeyCombo
extends RefCounted

var key: Key = KEY_NONE
var ctrl := false
var shift := false
var alt := false
var cmd := false

const _ALIASES := {
	"esc": KEY_ESCAPE, "escape": KEY_ESCAPE, "del": KEY_DELETE, "delete": KEY_DELETE, "ins": KEY_INSERT,
	"insert": KEY_INSERT, "pgup": KEY_PAGEUP, "pageup": KEY_PAGEUP, "pgdn": KEY_PAGEDOWN, "pagedown": KEY_PAGEDOWN,
	"enter": KEY_ENTER, "return": KEY_ENTER, "up": KEY_UP, "down": KEY_DOWN, "left": KEY_LEFT, "right": KEY_RIGHT,
	"`": KEY_QUOTELEFT, "~": KEY_QUOTELEFT, "tilde": KEY_QUOTELEFT, "backtick": KEY_QUOTELEFT, "backquote": KEY_QUOTELEFT,
	"-": KEY_MINUS, "minus": KEY_MINUS, "=": KEY_EQUAL, "equals": KEY_EQUAL, "[": KEY_BRACKETLEFT, "]": KEY_BRACKETRIGHT,
	",": KEY_COMMA, ".": KEY_PERIOD, "/": KEY_SLASH, ";": KEY_SEMICOLON, "'": KEY_APOSTROPHE, "\\": KEY_BACKSLASH,
	"space": KEY_SPACE, "tab": KEY_TAB, "backspace": KEY_BACKSPACE, "home": KEY_HOME, "end": KEY_END,
}
const _NOT_BINDABLE := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META, KEY_CAPSLOCK, KEY_NUMLOCK, KEY_SCROLLLOCK, KEY_UNKNOWN, KEY_NONE]

static var last_error := ""


static func make(k: Key, c := false, s := false, a := false, m := false) -> KeyCombo:
	var kc := KeyCombo.new()
	kc.key = k
	kc.ctrl = c
	kc.shift = s
	kc.alt = a
	kc.cmd = m
	return kc


## The combo, or null with last_error set.
static func parse(text: String) -> KeyCombo:
	last_error = ""
	var t := text.strip_edges()
	if t == "":
		last_error = "A combo needs a key; write it like 'ctrl+c'."
		return null
	# "+" itself and "ctrl++" are not supported; a trailing "+" is an empty part.
	var parts := t.split("+")
	var kc := KeyCombo.new()
	var key_name := ""
	for raw in parts:
		var p := raw.strip_edges().to_lower()
		if p == "":
			last_error = "'%s' has an empty part; write it like 'ctrl+c'." % t
			return null
		var mod := ""
		match p:
			"ctrl", "ctl", "control":
				mod = "ctrl"
			"shift":
				mod = "shift"
			"alt", "opt", "option":
				mod = "alt"
			"cmd", "command", "win", "super", "meta":
				mod = "cmd"
		if mod != "":
			if kc.get(mod):
				last_error = "'%s' names %s twice." % [t, mod]
				return null
			kc.set(mod, true)
			continue
		var k := key_of(p)
		if k == KEY_NONE:
			last_error = "'%s' is not a key name." % raw.strip_edges()
			return null
		if kc.key != KEY_NONE:
			last_error = "'%s' names more than one key ('%s' and '%s'); a combo has one key plus modifiers." % [t, key_name, raw.strip_edges()]
			return null
		kc.key = k
		key_name = raw.strip_edges()
	if kc.key == KEY_NONE:
		last_error = "'%s' is only modifiers; it needs a key as well." % t
		return null
	return kc


static func key_of(name: String) -> Key:
	var n := name.to_lower()
	if _ALIASES.has(n):
		return _ALIASES[n]
	var k := OS.find_keycode_from_string(name)
	if k == KEY_NONE:
		k = OS.find_keycode_from_string(name.capitalize())
	if k in _NOT_BINDABLE or (k >= KEY_F25 and k <= KEY_F35):
		return KEY_NONE
	return k


static func cmd_name() -> String:
	return "Cmd" if OS.get_name() == "macOS" else "Win"


## The platform's "command" modifier for app shortcuts: Cmd on macOS, Ctrl elsewhere.
static func primary(k: Key) -> KeyCombo:
	return make(k, false, false, false, true) if OS.get_name() == "macOS" else make(k, true)


func matches(e: InputEventKey) -> bool:
	if e.ctrl_pressed != ctrl or e.shift_pressed != shift or e.alt_pressed != alt or e.meta_pressed != cmd:
		return false
	if key == KEY_QUOTELEFT:
		return e.physical_keycode == KEY_QUOTELEFT or e.keycode == KEY_QUOTELEFT
	return e.keycode == key or (e.keycode == KEY_NONE and e.physical_keycode == key)


func _to_string() -> String:
	var p := PackedStringArray()
	if ctrl:
		p.append("Ctrl")
	if shift:
		p.append("Shift")
	if alt:
		p.append("Alt")
	if cmd:
		p.append(cmd_name())
	p.append("`" if key == KEY_QUOTELEFT else OS.get_keycode_string(key))
	return "+".join(p)
