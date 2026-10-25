## Generates LOD chains for every catalog model and the city building pieces.
## Output: res://assets/lod/<id>.scn — a scene with MeshInstance3D children LOD0..LODn
## (the naming Terrain3D's instancer and our city/entity code look for) — plus
## res://assets/lod/manifest.json with triangle counts per level.
## Run (needs a window for impostor rendering):
##   godot --path . --script res://tools/lod/build_lods.gd
extends SceneTree

const OUT := "res://assets/lod/"

## Triangle ratios for LOD1, LOD2, ... by category; "impostor" adds a card LOD at the end.
const PLAN := {
	"tree": {"ratios": [0.55, 0.25], "impostor": true},
	"plant": {"ratios": [0.5, 0.2], "impostor": false},
	"rock": {"ratios": [0.5, 0.2], "impostor": false},
	"small": {"ratios": [0.4], "impostor": false},
	"prop": {"ratios": [0.5, 0.2], "impostor": false},
	"building": {"ratios": [0.35, 0.12], "impostor": false},
	"piece": {"ratios": [0.3], "impostor": false},
}
## Cacti are "plant" in the catalog but tall enough to deserve impostors.
const IMPOSTOR_IDS := ["nature.cactus_tall", "nature.cactus_short"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	Catalog.apply_palette()  # impostors must use the final colours
	var jobs := []
	for id in Catalog.ids():
		var e := Catalog.get_entry(id)
		if e.has("path") and str(e.category) != "physics":
			jobs.append([id, str(e.path), str(e.category)])
	for f in DirAccess.get_files_at("res://assets/models/town"):
		if f.ends_with(".glb") and (f.begins_with("wall") or f == "roof-high-point.glb"):
			jobs.append(["town." + f.get_basename(), "res://assets/models/town/" + f, "piece"])
	var manifest := {}
	var t0 := Time.get_ticks_msec()
	for job in jobs:
		var id: String = job[0]
		var plan: Dictionary = PLAN.get(job[2], PLAN.prop)
		var lod0 := MeshSimplifier.merged_from_scene(load(job[1]))
		# Each level is simplified from the previous one and must be clearly cheaper
		# (the shape check can force a gentler reduction; then the level is dropped).
		var lods: Array[ArrayMesh] = [lod0]
		var prev_ratio := 1.0
		for r: float in plan.ratios:
			var prev := lods[-1]
			var m := MeshSimplifier.simplify(prev, r / prev_ratio)
			if MeshSimplifier.triangle_count(m) <= MeshSimplifier.triangle_count(prev) * 0.9:
				lods.append(m)
				prev_ratio = r
		if plan.impostor or id in IMPOSTOR_IDS:
			lods.append(await ImpostorBaker.bake(self, lod0))
		var root := Node3D.new()
		root.name = id.replace(".", "_")
		var counts := []
		for i in lods.size():
			var mi := MeshInstance3D.new()
			mi.name = "LOD%d" % i
			mi.mesh = lods[i]
			root.add_child(mi)
			mi.owner = root
			counts.append(MeshSimplifier.triangle_count(lods[i]))
		var ps := PackedScene.new()
		ps.pack(root)
		var err := ResourceSaver.save(ps, OUT + id + ".scn", ResourceSaver.FLAG_COMPRESS)
		root.free()
		manifest[id] = {"triangles": counts, "impostor": plan.impostor or id in IMPOSTOR_IDS}
		print("%-34s %s%s" % [id, str(counts), "" if err == OK else "  SAVE FAILED " + error_string(err)])
	var f := FileAccess.open(OUT + "manifest.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, "\t"))
	print("built %d LOD sets in %d ms" % [jobs.size(), Time.get_ticks_msec() - t0])
	quit()
