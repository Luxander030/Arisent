## Save games: user://saves/<slot>/
##   manifest.bin              which generation is current (+ the previous ones), written last
##   gen_<n>/game.bin          player, inventory, progress, story, clocks, counters
##   gen_<n>/maps/<map uid>/state.bin           id-keyed world changes of that map
##   gen_<n>/maps/<map uid>/dynamic/r_<x>_<z>.bin  runtime objects by 256 m region
## Every save writes a complete new generation (maps not loaded this session are copied
## from the previous one), then swaps the manifest (temp file + rename). If the manifest is
## missing or damaged, loading scans the generations for the newest complete one, so a
## crash mid-save loses at most that save. Three generations are kept.
## Files hold plain data only (var_to_bytes without objects). Older formats are refused
## (development phase: no migrations).
class_name SaveService
extends RefCounted

const ROOT := "user://saves"
const FORMAT_VERSION := 1
const KEEP_GENERATIONS := 3

var last_error := ""
var _task := -1
var _pending: Array = []   ## [slot, snapshot] waiting for the writer
var _results: Array = []   ## [slot, Error, message] finished by the writer
var _mutex := Mutex.new()


static func slot_dir(slot: String) -> String:
	return ROOT.path_join(slot.validate_filename())


# --- writing ------------------------------------------------------------------------------

## Starts writing a snapshot in the background (one writer at a time; later saves queue).
## snapshot = {game: {...}, maps: {uid: {state: {...}, dynamic: {region: {...}}}}}
func save_async(slot: String, snapshot: Dictionary) -> void:
	_mutex.lock()
	_pending.append([slot, snapshot])
	_mutex.unlock()
	if _task < 0 or WorkerThreadPool.is_task_completed(_task):
		if _task >= 0:
			WorkerThreadPool.wait_for_task_completion(_task)
		_task = WorkerThreadPool.add_task(_drain)


## Writes now (used when quitting): waits for any background save first.
func save_sync(slot: String, snapshot: Dictionary) -> Error:
	wait()
	return _write(slot, snapshot)


func wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_drain()


## Call regularly (GameSession does): starts the writer if a queued save is waiting.
func poll() -> void:
	if busy():
		return
	_mutex.lock()
	var waiting := not _pending.is_empty()
	_mutex.unlock()
	if waiting:
		if _task >= 0:
			WorkerThreadPool.wait_for_task_completion(_task)
		_task = WorkerThreadPool.add_task(_drain)


func busy() -> bool:
	return _task >= 0 and not WorkerThreadPool.is_task_completed(_task)


func _drain() -> void:
	while true:
		_mutex.lock()
		if _pending.is_empty():
			_mutex.unlock()
			return
		var job: Array = _pending.pop_front()
		_mutex.unlock()
		var err := _write(str(job[0]), job[1])
		_mutex.lock()
		_results.append([str(job[0]), err, last_error])
		_mutex.unlock()


## Finished background saves since the last call: [[slot, Error, message], ...] (main thread).
func take_results() -> Array:
	_mutex.lock()
	var out := _results.duplicate()
	_results.clear()
	_mutex.unlock()
	return out


func _write(slot: String, snapshot: Dictionary) -> Error:
	var dir := slot_dir(slot)
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest := _read_manifest(dir)
	var prev := int(manifest.get("current", 0))
	var gen := maxi(prev, _highest_gen(dir)) + 1
	var gdir := dir.path_join("gen_%d" % gen)
	DirAccess.make_dir_recursive_absolute(gdir)
	var game: Dictionary = snapshot.get("game", {})
	game.format_version = FORMAT_VERSION
	game.generation = gen
	game.saved_at = Time.get_datetime_string_from_system()
	var playthrough := str(game.get("playthrough", ""))
	var files := {}
	var err := OK
	var maps: Dictionary = snapshot.get("maps", {})
	for uid: String in maps:
		var m: Dictionary = maps[uid]
		err = maxi(err, _put(gdir, "maps/%s/state.bin" % uid, m.get("state", {}), files)) as Error
		var dyn: Dictionary = m.get("dynamic", {})
		for region: String in dyn:
			err = maxi(err, _put(gdir, "maps/%s/dynamic/%s.bin" % [uid, region], dyn[region], files)) as Error
	# Maps not in this snapshot carry over byte for byte from the previous generation — but
	# only from the same play-through (a new game never inherits another game's world).
	if prev > 0 and str(manifest.get("playthrough", "")) == playthrough and playthrough != "":
		var pdir := dir.path_join("gen_%d" % prev)
		var pfiles: Dictionary = manifest.get("files", {})
		for rel: String in pfiles:
			var parts := rel.split("/")
			if parts.size() >= 2 and parts[0] == "maps" and not maps.has(parts[1]):
				var bytes := FileAccess.get_file_as_bytes(pdir.path_join(rel))
				if bytes.is_empty() and not FileAccess.file_exists(pdir.path_join(rel)):
					continue
				err = maxi(err, _put_bytes(gdir, rel, bytes, files)) as Error
	# game.bin last: its presence marks a complete generation (fallback loading relies on it).
	err = maxi(err, _put(gdir, "game.bin", game, files)) as Error
	if err != OK:
		last_error = "writing %s failed: %s" % [gdir, error_string(err)]
		return err
	var gens: Array = manifest.get("generations", []) if str(manifest.get("playthrough", "")) == playthrough else []
	gens.append(gen)
	var keep := gens.slice(maxi(0, gens.size() - KEEP_GENERATIONS))
	var new_manifest := {"format_version": FORMAT_VERSION, "current": gen, "generations": keep, "files": files,
		"saved_at": game.saved_at, "summary": snapshot.get("summary", {}), "playthrough": playthrough}
	err = _swap_manifest(dir, new_manifest)
	if err != OK:
		last_error = "manifest: " + error_string(err)
		return err
	_cleanup(dir, keep)
	return OK


func _put(gdir: String, rel: String, data: Dictionary, files: Dictionary) -> Error:
	return _put_bytes(gdir, rel, var_to_bytes(data), files)


func _put_bytes(gdir: String, rel: String, bytes: PackedByteArray, files: Dictionary) -> Error:
	var path := gdir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	files[rel] = hash(bytes)
	return OK


## Writes manifest.tmp, keeps the old one as manifest.bak, then moves the new one in place.
static func _swap_manifest(dir: String, m: Dictionary) -> Error:
	var tmp := dir.path_join("manifest.tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(var_to_bytes(m))
	f.close()
	var cur := dir.path_join("manifest.bin")
	var bak := dir.path_join("manifest.bak")
	if FileAccess.file_exists(cur):
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(cur, bak)
	return DirAccess.rename_absolute(tmp, cur)


static func _cleanup(dir: String, keep: Array) -> void:
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with("gen_") and not keep.has(d.trim_prefix("gen_").to_int()):
			_remove_tree(dir.path_join(d))


static func _remove_tree(path: String) -> void:
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)


static func _highest_gen(dir: String) -> int:
	var hi := 0
	if DirAccess.dir_exists_absolute(dir):
		for d in DirAccess.get_directories_at(dir):
			if d.begins_with("gen_"):
				hi = maxi(hi, d.trim_prefix("gen_").to_int())
	return hi


# --- reading -------------------------------------------------------------------------------

static func _read_bin(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	return bytes_to_var(bytes)  # no objects: plain data only


static func _read_manifest(dir: String) -> Dictionary:
	for name in ["manifest.bin", "manifest.bak"]:
		var m: Variant = _read_bin(dir.path_join(name))
		if m is Dictionary and int((m as Dictionary).get("format_version", 0)) == FORMAT_VERSION:
			return m
	return {}


func has_save(slot: String) -> bool:
	return not load_save(slot, true).is_empty()


## Reads the current generation of a slot (falls back to older complete generations).
## Returns {game, maps: {uid: {state, dynamic: {region: data}}}, generation} or {}.
## header_only: only game.bin (for menus).
func load_save(slot: String, header_only := false) -> Dictionary:
	last_error = ""
	var dir := slot_dir(slot)
	if not DirAccess.dir_exists_absolute(dir):
		last_error = "no save named '%s'" % slot
		return {}
	var manifest := _read_manifest(dir)
	var candidates: Array = []
	if not manifest.is_empty():
		candidates.append([int(manifest.current), manifest.get("files", {})])
		var gens: Array = manifest.get("generations", [])
		for i in range(gens.size() - 2, -1, -1):
			candidates.append([int(gens[i]), {}])
	# Without a usable manifest: every generation on disk, newest first.
	var on_disk: Array = []
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with("gen_"):
			on_disk.append(d.trim_prefix("gen_").to_int())
	on_disk.sort()
	on_disk.reverse()
	for g: int in on_disk:
		candidates.append([g, {}])
	for c: Array in candidates:
		var out := _load_gen(dir.path_join("gen_%d" % int(c[0])), c[1], header_only)
		if not out.is_empty():
			out.generation = int(c[0])
			return out
	if last_error == "":
		last_error = "save '%s' is damaged (no complete generation)" % slot
	return {}


func _load_gen(gdir: String, expected: Dictionary, header_only: bool) -> Dictionary:
	var game: Variant = _read_bin(gdir.path_join("game.bin"))
	if not game is Dictionary:
		return {}
	var v := int((game as Dictionary).get("format_version", 0))
	if v != FORMAT_VERSION:
		last_error = "save format %d is not supported (this build reads %d)" % [v, FORMAT_VERSION]
		return {}
	if header_only:
		return {"game": game}
	# Verify against the manifest's checksums when we have them.
	for rel: String in expected:
		if not FileAccess.file_exists(gdir.path_join(rel)) or hash(FileAccess.get_file_as_bytes(gdir.path_join(rel))) != int(expected[rel]):
			last_error = "save file %s is damaged" % rel
			return {}
	var maps := {}
	var mdir := gdir.path_join("maps")
	if DirAccess.dir_exists_absolute(mdir):
		for uid in DirAccess.get_directories_at(mdir):
			var st: Variant = _read_bin(mdir.path_join(uid).path_join("state.bin"))
			var dyn := {}
			var ddir := mdir.path_join(uid).path_join("dynamic")
			if DirAccess.dir_exists_absolute(ddir):
				for f in DirAccess.get_files_at(ddir):
					var d: Variant = _read_bin(ddir.path_join(f))
					if d is Dictionary:
						dyn[f.get_basename()] = d
			maps[uid] = {"state": st if st is Dictionary else {}, "dynamic": dyn}
	return {"game": game, "maps": maps}


## [{slot, saved_at, map_name, play_time, level}] newest first.
func list_slots() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(ROOT):
		return out
	for slot in DirAccess.get_directories_at(ROOT):
		var m := _read_manifest(ROOT.path_join(slot))
		if m.is_empty():
			continue
		var s: Dictionary = m.get("summary", {})
		out.append({"slot": slot, "saved_at": str(m.get("saved_at", "")), "map_name": str(s.get("map_name", "")),
			"play_time": float(s.get("play_time", 0.0)), "level": int(s.get("level", 1))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.saved_at > b.saved_at)
	return out
