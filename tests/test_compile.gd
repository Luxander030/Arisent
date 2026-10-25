extends TestCase
## Every script in the project folders must compile (catches parse errors early).

func test_all_scripts_compile() -> void:
	for dir in ["res://core", "res://world", "res://worldgen", "res://editor", "res://game", "res://addons/story_graph"]:
		_check_dir(dir)

func _check_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			var s: GDScript = load(dir.path_join(f))
			check(s != null and s.can_instantiate(), "does not compile: " + dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_check_dir(dir.path_join(d))
