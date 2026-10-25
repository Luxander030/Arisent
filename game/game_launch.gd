## How the next game starts (set by the main menu, read by the game host): a new game, the
## most recent save, or a named save slot.
class_name GameLaunch
extends RefCounted

static var mode := "new"   ## new | continue | load
static var slot := ""
static var map_path := ""   ## console /newgame: start on this map folder once


static func new_game() -> void:
	mode = "new"
	slot = ""


static func continue_latest() -> void:
	mode = "continue"
	slot = ""


static func load_slot(name: String) -> void:
	mode = "load"
	slot = name
