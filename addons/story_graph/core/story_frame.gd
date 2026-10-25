@tool
class_name StoryFrame
extends Resource
## A named, coloured box grouping cells on the graph (for organising large stories).
## Purely visual: it has no effect on how the story runs.

@export var id := ""
@export var title := "Group"
@export var position := Vector2.ZERO
@export var size := Vector2(400, 300)
@export var color := Color(0.3, 0.45, 0.7, 0.6)
@export var cell_ids: PackedStringArray = []


func to_dict() -> Dictionary:
	return {"id": id, "title": title, "position": [position.x, position.y], "size": [size.x, size.y],
		"color": color.to_html(), "cells": Array(cell_ids)}


static func from_dict(d: Dictionary) -> StoryFrame:
	var f := StoryFrame.new()
	f.id = str(d.get("id", ""))
	f.title = str(d.get("title", "Group"))
	var p: Array = d.get("position", [0, 0])
	var s: Array = d.get("size", [400, 300])
	f.position = Vector2(float(p[0]), float(p[1]))
	f.size = Vector2(float(s[0]), float(s[1]))
	f.color = Color.from_string(str(d.get("color", "")), f.color)
	f.cell_ids = PackedStringArray(d.get("cells", []))
	return f
