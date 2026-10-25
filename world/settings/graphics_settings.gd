## The player's graphics settings: quality (Adaptive or a fixed preset), resolution,
## vsync, frame-rate cap, window mode, FPS counter. Saved in user://settings.cfg
## [graphics]; apply_window() sets up the window (menu and game), apply_world() a world.
class_name GraphicsSettings
extends RefCounted

const FILE := "user://settings.cfg"
const SECTION := "graphics"
## In the order the menu lists them.
const QUALITIES := ["Adaptive", "Ultra", "High", "Medium", "Low"]
const FPS_CAPS := [0, 30, 60, 120, 144]

## "Adaptive" holds the frame rate by itself (LodController); the others are fixed.
var quality := "Adaptive"
## Adaptive: the lowest share of the window's resolution it may render at (FSR 1 upscales).
var min_resolution := 0.6
## Fixed presets: the share of the window's resolution rendered.
var resolution := 1.0
var vsync := true
var max_fps := 0            ## 0 = no cap
var fullscreen := false
var show_fps := false

static var _current: GraphicsSettings


## The settings in use (read from disk the first time).
static func current() -> GraphicsSettings:
	if _current == null:
		_current = GraphicsSettings.new()
		_current.load_file()
	return _current


## Tests and benchmarks: the defaults, not the player's saved settings.
static func use_defaults() -> void:
	_current = GraphicsSettings.new()


func load_file(path := FILE) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	quality = str(cfg.get_value(SECTION, "quality", quality))
	if not quality in QUALITIES:
		quality = "Adaptive"
	min_resolution = clampf(float(cfg.get_value(SECTION, "min_resolution", min_resolution)), 0.5, 1.0)
	resolution = clampf(float(cfg.get_value(SECTION, "resolution", resolution)), 0.5, 1.0)
	vsync = bool(cfg.get_value(SECTION, "vsync", vsync))
	max_fps = maxi(0, int(cfg.get_value(SECTION, "max_fps", max_fps)))
	fullscreen = bool(cfg.get_value(SECTION, "fullscreen", fullscreen))
	show_fps = bool(cfg.get_value(SECTION, "show_fps", show_fps))


## Writes this section only (the file also holds the console's and dev settings).
func save_file(path := FILE) -> Error:
	var cfg := ConfigFile.new()
	cfg.load(path)
	for key in ["quality", "min_resolution", "resolution", "vsync", "max_fps", "fullscreen", "show_fps"]:
		cfg.set_value(SECTION, key, get(key))
	return cfg.save(path)


## The frame rate Adaptive aims for: 60, or the cap when that is lower.
func target_fps() -> float:
	return float(max_fps) if max_fps > 0 and max_fps < 60 else 60.0


func apply_window(window: Window) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = max_fps
	var want := Window.MODE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
	if window.mode != want and not (window.mode == Window.MODE_MAXIMIZED and not fullscreen):
		window.mode = want


func apply_world(world: WorldView) -> void:
	var lod := world.lod
	lod.target_fps = target_fps()
	lod.min_render_scale = min_resolution
	lod.fixed_render_scale = resolution
	if lod.mode != quality:
		lod.set_mode(quality)
	else:
		lod.refresh()
	# The terrain's dual-scale texturing and slope projection cost 1–4 ms each; the lower
	# presets go without them. (Adaptive keeps them: switching recompiles the terrain shader.)
	world.set_terrain_extras(not quality in ["Medium", "Low"])
