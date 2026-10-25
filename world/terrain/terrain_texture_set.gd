## The terrain ground textures, in slot order. Slot ids are stored in every map's
## control map, so only ever append to this list.
class_name TerrainTextureSet
extends RefCounted

const DIR := "res://assets/textures/terrain/"

## [file id, display name, uv scale]
const SLOTS := [
	["grass004", "Grass", 0.12],
	["ground037", "Grassy Dirt", 0.12],
	["ground048", "Forest Floor", 0.12],
	["ground054", "Dry Earth", 0.1],
	["ground033", "Sand", 0.1],
	["ground080", "Dark Sand", 0.1],
	["gravel022", "Gravel", 0.15],
	["rock030", "Rock", 0.06],
	["snow006", "Snow", 0.08],
	["ice002", "Ice", 0.08],
]


static func slot_names() -> PackedStringArray:
	var out := PackedStringArray()
	for s in SLOTS:
		out.append(s[1])
	return out


static func albedo(slot: int) -> Texture2D:
	return load(DIR + SLOTS[slot][0] + "_ah.png")
