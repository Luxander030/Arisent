## Submitted lines, newest last (128, in memory only). The cursor is -1 at the bottom
## (the line being typed).
class_name ConsoleHistory
extends RefCounted

const CAPACITY := 128

var entries: PackedStringArray = []
var cursor := -1


func record(line: String) -> void:
	if line.strip_edges() == "":
		return
	if entries.is_empty() or entries[entries.size() - 1] != line:
		entries.append(line)
		if entries.size() > CAPACITY:
			entries.remove_at(0)
	cursor = -1


func to_bottom() -> void:
	cursor = -1


## Older entry, or null when there is none.
func up() -> Variant:
	if entries.is_empty():
		return null
	if cursor == -1:
		cursor = entries.size() - 1
	elif cursor > 0:
		cursor -= 1
	else:
		return null
	return entries[cursor]


## Newer entry; "" when stepping back to the bottom; null when already there.
func down() -> Variant:
	if cursor == -1:
		return null
	if cursor < entries.size() - 1:
		cursor += 1
		return entries[cursor]
	cursor = -1
	return ""
