## Packs ambientCG source maps (assets/textures/terrain_src, ignored by Godot) into the
## two images Terrain3D expects per texture slot:
##   <name>_ah.png = albedo RGB + height A,  <name>_nr.png = normal RGB (OpenGL) + roughness A
## Run: godot --headless --path . --script res://tools/pack_terrain_textures.gd
extends SceneTree

const SRC := "res://assets/textures/terrain_src"
const DST := "res://assets/textures/terrain"
const SIZE := 1024

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DST))
	for id in DirAccess.get_directories_at(ProjectSettings.globalize_path(SRC)):
		var base := ProjectSettings.globalize_path(SRC).path_join(id).path_join(id + "_1K-JPG_")
		var col := _load(base + "Color.jpg")
		var disp := _load(base + "Displacement.jpg")
		var nrm := _load(base + "NormalGL.jpg")
		var rough := _load(base + "Roughness.jpg")
		var ah := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		var nr := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
		for y in SIZE:
			for x in SIZE:
				var c := col.get_pixel(x, y)
				c.a = disp.get_pixel(x, y).r
				ah.set_pixel(x, y, c)
				var n := nrm.get_pixel(x, y)
				n.a = rough.get_pixel(x, y).r
				nr.set_pixel(x, y, n)
		ah.save_png(ProjectSettings.globalize_path(DST).path_join(id.to_lower() + "_ah.png"))
		nr.save_png(ProjectSettings.globalize_path(DST).path_join(id.to_lower() + "_nr.png"))
		print("packed ", id)
	quit()

func _load(path: String) -> Image:
	var img := Image.load_from_file(path)
	img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != SIZE:
		img.resize(SIZE, SIZE, Image.INTERPOLATE_LANCZOS)
	return img
