@tool
extends RefCounted
## The editor's display scale (EditorInterface.get_editor_scale()), set by the plugin.
## Hand-sized controls multiply by it so they match the rest of the editor on HiDPI screens.

static var value := 1.0


static func px(x: float) -> float:
	return x * value


static func font(x: int) -> int:
	return roundi(x * value)
