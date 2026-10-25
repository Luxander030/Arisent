## The 3D world for a map: sky, sun, terrain, water (and later vegetation and entities).
## Used by both the editor and the game.
class_name WorldView
extends Node3D

var terrain: TerrainBackend
var water: WaterView
var city: CityView
var entities: EntityLayer
var lod: LodController
var impostors: ImpostorLayer
var _instanced_entries := []
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var environment: WorldEnvironment
var _sky_mat: ProceduralSkyMaterial
var _hours := -1.0
var map: MapData
## Authored-data infrastructure (editor and game, with or without a running session):
var grid := WorldGrid.new()
var zones: ZoneIndex
var debug: DebugDraw
## The runtime session attached to this view (null in the editor unless simulating).
var session: Node


func _ready() -> void:
	_build_environment()
	water = WaterView.new()
	water.name = "Water"
	add_child(water)
	city = CityView.new()
	city.name = "City"
	add_child(city)
	zones = ZoneIndex.new(grid)
	entities = EntityLayer.new()
	entities.name = "Entities"
	entities.grid = grid
	entities.zones = zones
	add_child(entities)
	debug = DebugDraw.new()
	debug.name = "DebugDraw"
	add_child(debug)
	debug.add_provider(entities.draw_debug)
	impostors = ImpostorLayer.new()
	impostors.name = "Impostors"
	add_child(impostors)
	lod = LodController.new()
	lod.name = "LodController"
	add_child(lod)
	lod.scale_changed.connect(_on_lod_scale)
	lod.busy = func() -> bool: return terrain != null and terrain.is_rebuilding()
	lod.effects_changed.connect(func(on: bool) -> void: environment.environment.ssao_enabled = on)


## One detail scale for vegetation, city and placed objects (see LodController).
func _on_lod_scale(scale: float) -> void:
	sun.directional_shadow_max_distance = lod.shadow_distance()
	var t0 := Time.get_ticks_usec()
	if terrain:
		terrain.apply_lod_scale(scale)
	var t1 := Time.get_ticks_usec()
	city.apply_lod_scale(scale)
	var t2 := Time.get_ticks_usec()
	entities.apply_lod_scale(scale)
	impostors.apply_lod_scale(scale)
	var t3 := Time.get_ticks_usec()
	if OS.has_environment("LOD_TIMING"):
		print("lod scale %.2f: terrain %d ms, city %d ms, other %d ms" % [scale, (t1 - t0) / 1000, (t2 - t1) / 1000, (t3 - t2) / 1000])


## Where physics props stay awake (the player in the game).
var physics_focus: Node3D
var _lod_timer := 0.0


func _process(delta: float) -> void:
	Perf.begin(&"world_view")
	_process_body(delta)
	Perf.end(&"world_view")


func _process_body(delta: float) -> void:
	if terrain:
		impostors.set_vegetation_scale(terrain.vegetation_scale())
	_lod_timer -= delta
	if physics_focus and session == null and _lod_timer <= 0.0:
		_lod_timer = 0.5
		entities.update_physics_lod(physics_focus.global_position)


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	_sky_mat = sky_mat
	sky_mat.sky_top_color = Color(0.32, 0.52, 0.82)
	sky_mat.sky_horizon_color = Color(0.72, 0.8, 0.9)
	sky_mat.ground_horizon_color = Color(0.72, 0.8, 0.9)
	sky_mat.ground_bottom_color = Color(0.3, 0.35, 0.4)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.78, 0.88)
	env.fog_density = 0.00012
	env.fog_aerial_perspective = 0.5
	env.fog_sky_affect = 0.3
	env.glow_enabled = true
	environment = WorldEnvironment.new()
	environment.environment = env
	add_child(environment)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = LodSettings.SHADOW_DISTANCE
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = Color(0.55, 0.65, 0.9)
	moon.shadow_enabled = false
	moon.light_energy = 0.0
	add_child(moon)
	set_time_of_day(10.0)


const DAY_SKY := [Color(0.32, 0.52, 0.82), Color(0.72, 0.8, 0.9), Color(0.7, 0.78, 0.88)]
const DUSK_SKY := [Color(0.25, 0.3, 0.55), Color(0.95, 0.55, 0.35), Color(0.75, 0.5, 0.4)]
const NIGHT_SKY := [Color(0.01, 0.015, 0.04), Color(0.04, 0.05, 0.1), Color(0.03, 0.04, 0.08)]


## Day/night cycle: the sun rises in the east at 6, is highest at 12 and sets at 18; light,
## shadows, sky, ambient light and fog follow it; a dim moonlight takes over at night.
## The game drives this from TimeOfDay (so night-time spawns happen in the dark).
func set_time_of_day(hours: float) -> void:
	if absf(hours - _hours) < 0.005:
		return
	_hours = hours
	var elevation := 62.0 * sin((hours - 6.0) / 12.0 * PI)   # degrees above the horizon
	var azimuth := -90.0 - (hours - 6.0) / 12.0 * 180.0       # east -> south -> west
	sun.rotation_degrees = Vector3(-maxf(elevation, -10.0), azimuth, 0.0)
	var day := clampf(elevation / 18.0, 0.0, 1.0)          # 0 at sunset, 1 when the sun is well up
	var dusk := clampf(1.0 - absf(elevation) / 12.0, 0.0, 1.0)  # near the horizon
	sun.light_energy = 1.15 * day
	sun.light_color = Color(1.0, 0.85, 0.7).lerp(Color.WHITE, day)
	sun.shadow_enabled = day > 0.05
	sun.visible = elevation > -6.0
	moon.light_energy = 0.14 * clampf(-elevation / 15.0, 0.0, 1.0)
	moon.rotation_degrees = Vector3(-50.0, azimuth + 180.0, 0.0)
	moon.visible = moon.light_energy > 0.001
	var night := clampf(-elevation / 12.0, 0.0, 1.0)
	var cols: Array = []
	for i in 3:
		var c: Color = (DAY_SKY[i] as Color).lerp(DUSK_SKY[i], dusk * (1.0 - night))
		cols.append(c.lerp(NIGHT_SKY[i], night))
	_sky_mat.sky_top_color = cols[0]
	_sky_mat.sky_horizon_color = cols[1]
	_sky_mat.ground_horizon_color = cols[1]
	_sky_mat.ground_bottom_color = (cols[0] as Color).darkened(0.5)
	var env := environment.environment
	env.fog_light_color = cols[2]
	env.ambient_light_energy = lerpf(0.25, 1.0, maxf(day, 0.15 * (1.0 - night)))
	env.background_energy_multiplier = lerpf(0.35, 1.0, maxf(day, 1.0 - night))


## Creates the terrain node for a map (empty until maps are imported or loaded).
func setup_terrain(m: MapData, camera: Camera3D, undo: UndoRedo = null) -> void:
	map = m
	if terrain:
		terrain.queue_free()
	var t := Terrain3DBackend.new()
	t.name = "Terrain"
	add_child(t)
	t.set_undo_redo(undo)
	t.setup(m.map_m, m.spacing, camera)
	Catalog.apply_palette()
	var entries := []
	for id in Catalog.instanced_ids():
		entries.append(Catalog.get_entry(id))
	t.setup_instancer(entries)
	t.apply_lod_scale(lod.scale)
	terrain = t
	debug.terrain = t
	_instanced_entries = entries


## Terrain texturing extras (see TerrainBackend.set_texture_extras).
func set_terrain_extras(on: bool) -> void:
	if terrain:
		terrain.set_texture_extras(on)


## Call after terrain data is in place (imported or loaded).
func finish_terrain() -> void:
	terrain.refresh_instances()
	terrain.enable_grass(0)
	for c in impostors.get_children():
		c.queue_free()
	impostors.setup(_instanced_entries)
	impostors.apply_lod_scale(lod.scale)
	refresh_impostors(Rect2(-map.map_m, -map.map_m, map.map_m * 2.0, map.map_m * 2.0))



## Rebuilds far-tree cards for every region touching a world rectangle.
func refresh_impostors(rect: Rect2) -> void:
	if not impostors.has_species():
		return
	for reg in terrain.region_rects():
		var a := terrain.pixel_to_world(reg.position)
		var b := terrain.pixel_to_world(reg.end)
		if Rect2(a.x, a.z, b.x - a.x, b.z - a.z).intersects(rect):
			impostors.set_region(reg, terrain.region_instances(reg))


func build_entities() -> void:
	if map:
		entities._lod_scale = lod.scale
		entities.build(map.entities)


func build_city() -> void:
	if map:
		city._lod_scale = lod.scale
		city.build(map.city, map.overrides, terrain)


## Height of the water surface at a world position, or -INF if there is no water there
## (ocean at sea level where the water mask says ocean; lakes inside their mask area).
func water_level_at(pos: Vector3) -> float:
	if map == null or map.water_mask == null:
		return -INF
	var mask := map.water_mask
	var n := mask.get_width()
	var i := clampi(floori((pos.x / map.map_m + 0.5) * n), 0, n - 1)
	var j := clampi(floori((pos.z / map.map_m + 0.5) * n), 0, n - 1)
	var c := mask.get_pixel(i, j)
	var level := -INF
	if c.r > 0.5 and c.g < 0.5:  # open ocean (sea ice is solid)
		level = float(map.water.get("sea_level", 0.0))
	if c.b > 0.5:
		for lake: Dictionary in map.water.get("lakes", []):
			var r: Array = lake.rect
			if not lake.get("frozen", false) and pos.x >= r[0] and pos.x <= r[2] and pos.z >= r[1] and pos.z <= r[3]:
				level = maxf(level, float(lake.level))
	return level


func build_water() -> void:
	if map and map.water_mask:
		water.build(map.water, map.water_mask, map.map_m)
