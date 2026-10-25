extends TestCase
## Renders a contact sheet of several seeds/settings for eyeballing variety.

func test_gallery() -> void:
	var cfgs := [
		{"seed": "1"}, {"seed": "2", "land_water": 0.8, "islands": 0.9},
		{"seed": "3", "mountains": 0.9, "rifts": 0.8}, {"seed": "4", "land_water": 0.05, "rivers": 0.9, "lakes": 0.8},
		{"seed": "5", "biomes_off": [GenParams.Biome.OCEAN]}, {"seed": "6", "biomes_off": [GenParams.Biome.DESERT, GenParams.Biome.DESERT_HIGHLANDS], "coast_rough": 1.0},
	]
	var size := 256
	var sheet := Image.create(size * 3, size * 2, false, Image.FORMAT_RGB8)
	for idx in cfgs.size():
		var p := GenParams.new()
		var c: Dictionary = cfgs[idx]
		for key in c:
			if key == "biomes_off":
				for b in c[key]:
					p.biomes[b] = false
			else:
				p.set(key, c[key])
		var L := LayoutGenerator.new().generate(p, size)
		sheet.blit_rect(PreviewPainter.paint(L), Rect2i(0, 0, size, size), Vector2i((idx % 3) * size, (idx / 3) * size))
		print("    cfg %d: rivers %d lakes %d" % [idx, L.rivers.size(), L.lakes.size()])
	DirAccess.make_dir_recursive_absolute("user://test_out")
	sheet.save_png("user://test_out/gallery.png")
