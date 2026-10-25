## Headless test runner. Run: tools/run_tests.sh [filter]
## Every tests/test_*.gd extends TestCase; each method named test_* is a test.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	GraphicsSettings.use_defaults()  # not the player's saved settings
	var filter := ""
	if OS.get_cmdline_user_args().size() > 0:
		filter = OS.get_cmdline_user_args()[0]
	var files := Array(DirAccess.get_files_at("res://tests"))
	files.sort()
	var passed := 0
	var failed := 0
	for f in files:
		if not (f.begins_with("test_") and f.ends_with(".gd")):
			continue
		var script: GDScript = load("res://tests/" + f)
		if script == null or not script.can_instantiate():
			failed += 1
			print("  FAIL %s: script failed to compile" % f)
			continue
		var inst: TestCase = script.new()
		for m in script.get_script_method_list():
			var name: String = m.name
			if not name.begins_with("test_") or (filter != "" and not (f + ":" + name).contains(filter)):
				continue
			inst.failures.clear()
			var t0 := Time.get_ticks_msec()
			await inst.call(name)
			var ms := Time.get_ticks_msec() - t0
			if inst.failures.is_empty():
				passed += 1
				print("  PASS %s:%s (%d ms)" % [f, name, ms])
			else:
				failed += 1
				print("  FAIL %s:%s" % [f, name])
				for msg in inst.failures:
					print("       ", msg)
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
