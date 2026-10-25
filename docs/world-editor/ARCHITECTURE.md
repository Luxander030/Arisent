# Lux's RPG — World Editor: Architecture & Plan

Status: **v2, revised after adversarial review** (findings + resolutions in §10); **first slice built** (see §11).
Engine: Godot 4.7.2 (standard build, GDScript only). Targets: macOS (Apple Silicon) + Windows.

## 0. Decisions made with the owner

| Topic | Decision |
|---|---|
| Map size | User picks per map: 2, 4 or 8 km (16 km once terrain streaming exists) |
| Setting | Medieval fantasy with modern elements (modern day + magic woven into systems) |
| Art style (placeholders) | Stylized low-poly, CC0 (Kenney packs, ambientCG ground textures) |
| Biome layout | Climate logic + seeded randomness (cold north, hot south) |
| Platforms | Mac + Windows |
| Code | GDScript (+ shaders) only; heavy loops isolated so they can move to C++ later |
| Terrain | Terrain3D plugin (MIT) behind our own wrapper; our own terrain system later |
| Next step | After review, build the first slice directly |

## 1. Research summary — what we take from the big editors

- **Authored inputs vs. derived output** (Horizon Zero Dawn, Far Cry 5, Ghost Recon Wildlands): user edits live only in *inputs* (painted masks, splines, hand-placed objects, sculpt layers); procedural output is a cache that can always be rebuilt. Hand content feeds back as *exclusion* (a placed house clears trees under it). **This is the core data rule.**
- **Local stability** (HZD): randomness seeded by *position/cell*, so a change in one area never reshuffles the rest.
- **Fixed tool order** (FC5): landmass → climate/biomes → relief → city site → water → textures → vegetation.
- **Height layer stack** (Unreal edit layers; impossible to retrofit later): procedural height + user sculpt kept separate.
- **Stable IDs**, **one command per brush stroke for undo**, **schema version in every file**.
- **Transitions instead of tile maps**: each ground pixel stores *base texture + overlay texture + blend* (Terrain3D control map, 32 slots); biome borders become soft, noise-broken, dithered blends; slopes automatically get rock.
- **Measured speed on the M2**: `FastNoiseLite.get_noise_2d` = 512² × 5 octaves in 33 ms; a plain GDScript loop ≈ 25 ns/iteration; GDScript *function calls* are the expensive part (≈1 µs). ⇒ All generation runs on the **CPU**, inner loops written flat (no per-pixel function calls), full-resolution work split into row bands on `WorkerThreadPool`. No GPU compute in v1 → no GPU-vendor differences, and everything runs in headless tests.
- **Terrain3D smoke test passed on Metal** (M2): runtime import, sculpt stroke via `Terrain3DEditor`, undo/redo through our own plugin shim, save/load — all working in a runtime (non-editor) process.

## 2. High-level architecture

```
┌──────────── Godot project (one codebase) ─────────────┐
│  core/      deterministic RNG/hash, grids, geometry    │  shared
│  world/     MapData, file IO, catalog, terrain backend │  shared (game + editor)
│             water/foliage/entity runtime, WorldLoader  │  must never reference worldgen/ or editor/
│  worldgen/  procedural pipeline (stages)               │  editor only
│  editor/    editor app: UI, tools, commands            │  editor only
│  assets/    placeholder assets + catalog.json          │  shared
│  (root)     existing game scenes (player, menu, world) │  game
└────────────────────────────────────────────────────────┘
   preset "Game": main scene MainMenu, excludes editor/, worldgen/, tests/, tools/
   preset "World Editor": feature tag level_editor → main_scene.level_editor = res://editor/editor_main.tscn,
                          own config/name + custom user dir (the two apps never share user://)
```

- **Separate executable** = same project, second export preset. Dev run: `tools/run_editor.sh`.
- macOS export notes: de-quarantine Terrain3D binaries (`xattr -cr`), ad-hoc signing needs no hardened runtime or `disable-library-validation` to load the Terrain3D framework.

### 2.1 Terrain backend (Terrain3D, wrapped)

- Terrain3D **1.1.0-rc1** in `addons/terrain_3d/` (upgrade to 1.1.0 stable when out). Only `world/terrain/terrain3d_backend.gd` touches Terrain3D; everything else talks to `TerrainBackend` (`setup`, `import_maps`, `get_height`, `get_normal`, `raycast`, `begin/stroke/end`, `set_texture_slots`, instancer calls, `save/load`).
- Runtime editing: `Terrain3DEditor` + a plugin shim node providing a `ui` Node and `create_undo_action / add_undo_method / add_do_method / commit_action` forwarding to our `UndoRedo` (verified). Undo history capped (≈20 strokes) because each stroke snapshots whole regions.
- **Picking/raycasts never use physics**: `Terrain3D.get_intersection()` (height-field march) — collision only exists near the camera.
- Collision: `DYNAMIC_GAME`; game raises the radius as needed.
- Grid (region size 1024, set with `change_region_size`), always ≤ 4096² samples:

| Map | Vertex spacing | Samples | Regions |
|---|---|---|---|
| 2 km | 1 m | 2048² | 2×2 |
| 4 km | 1 m | 4096² | 4×4 |
| 8 km | 2 m | 4096² | 4×4 |

  Memory budget ≈ 600 MB in the editor (CPU + GPU copies of height/control/colour, procedural height layer, undo).
- Map centred on the origin; **north = −Z**, east = +X; heights −250 … +1200 m, sea level 0. All world→cell conversions use `floori` (never `int()`), same in shaders.
- Texture slots: packed offline (`tools/pack_terrain_textures.gd`: albedo+height, normal+roughness, 1024², same format) and committed as imported resources.

### 2.2 Height layers (fixes "edits wiped / applied twice")

```
final height = procedural height P  +  sculpt delta D
P = generated base  ∘  vector modifiers (city plateau, river beds, lakes, rifts, later roads)
```
- `P` is fully reproducible from seed + params + `modifiers.json`, and is cached in `layers/procedural_height.exr`.
- Brush sculpting writes into Terrain3D directly; **D is never stored per stroke** — it is recovered as `current − P` when needed (regenerate, re-applying a modifier). Because every vector tool (rift, river, lake, city) is part of `P`, nothing is counted twice and a moved city takes its old plateau with it.
- Adding/editing a modifier = rebuild `P` in the affected rectangle, write `P + D` back for that rectangle.

### 2.3 Map file format (`MyMap.luxmap/` folder)

```
map.json                 schema_version, generator_version, name, size_km, spacing,
                         seed (string), gen_params{...}, sea_level, texture_slots[], stage_hashes{}
terrain/                 Terrain3D region files (current height = P + D, control, colour, instancer)
layers/procedural_height.exr   P (R32F) — cache, rebuildable
layers/ocean_mask.png          derived: ocean-connected water, sea ice (R = ocean, G = ice)
layers/climate.exr             derived: temperature, moisture, biome weights (layout res)
layers/paint_lock.png          authored: pixels hand-painted (kept when textures are re-derived)
layers/scatter/<group>.exr     authored: density override per vegetation group (−1..+1)
modifiers.json           authored: rifts, user rivers/lakes, (later) roads — vector shapes with params
water.json               derived + authored: lakes [{id, level, frozen, origin}], rivers [splines], sea ice
city.json                derived: wall, gates, streets, wards, lots, buildings (stable lot keys)
overrides.json           authored: edits/tombstones for generated things, keyed by stable key
objects/cell_X_Y.json    authored: hand-placed entities, 256 m cells
```
- JSON for all our data; **typed loading**: every field is coerced through a schema (Godot's JSON turns ints into floats). Seeds are stored as strings. Hashes are computed from a canonical string form, never from raw Variants.
- `.res` only for Terrain3D region files.
- Every file has `schema_version`; loader migrates step by step.

### 2.4 Entities — the extension point for RPG features

```
Entity { id: GUID string, kind: "prop", asset: "nature.pine_tall_a",
         xform: {pos, rot_deg, scale}, props: {..}, layer: "default", nav_obstacle: bool }
```
- `world/entities/entity_kinds.gd` registry: kind → property schema (name, type, default, range) → inspector auto-generated. Spawn points, chests + loot tables, trigger zones, NPCs = new registry entries + runtime scenes, no format change.
- **Generated things are not entities in the authored store.** City buildings live in `city.json` (derived). Editing or deleting one writes an override/tombstone into `overrides.json` keyed by a *stable key* (`city:<quantized lot centroid hash>`). On regenerate, overrides whose key no longer exists are listed as "orphaned" in the UI (kept, not silently applied elsewhere). "Detach" turns a generated building into a normal hand-placed entity.
- Vegetation: derived from rules + `layers/scatter/*` + exclusion (roads, water, city, buildings) → baked into the Terrain3D instancer region by region. Trees get collision as streamed `PhysicsServer3D` shapes near the player (game) / camera (editor).
- Rendering of many repeated buildings: buildings are pre-merged meshes (one mesh per archetype) drawn with MultiMesh per archetype + visibility ranges.

### 2.5 Asset catalog

`assets/catalog.json`: `id → {path, category, biomes[], footprint_radius, collision, scale_range, align_to_slope}`; maps reference IDs only. Licences in `assets/LICENSES.md`.

## 3. Procedural generation

### 3.1 Parameters (New Map screen)

- Name, size (2/4/8 km), **seed** (text or number + dice).
- **Biomes** (up to 8 checkboxes): Frozen Fjords, Northern Mountains, Ocean, Temperate Forest, Grassland, Tropical Forest, Desert Highlands, Desert.
  - Ocean **off** = landlocked map: no sea edges; water comes from lakes and rivers only; fjords become frozen glacial lakes.
- **Sliders** (0–100 %): Land vs Water, Islands, Coastline Roughness, Mountains, Hilliness, Rivers, Lakes, Canyons & Rifts, Biome Blend Width, Vegetation Density.
- **City**: on/off, size (Town → Huge; diameter = 12–35 % of map width, e.g. "Large" ≈ 1.1 km on a 4 km map), walls on/off, modern-district share.
- Preview layers: Biomes / Height / Water / City.

`worldgen/gen_params.gd`: typed fields, `to_dict()/from_dict()` (schema-coerced), `canonical_string()` → hash.

### 3.2 Determinism contract (honest version)

1. Own RNG/hashes (`core/rng.gd`: SplitMix64, PCG32 with logical shifts, lowbias32 position hashes), verified against reference test vectors. No `randi()`, `hash()`, `shuffle()`.
2. Sub-seed per stage (`Rng.derive(seed, STAGE)`), so city settings never move the coastline.
3. Fixed iteration order, ties by index, no generation-relevant Dictionary iteration; threads only write disjoint row bands (no shared float accumulation).
4. Integer hashes in every decision; no `sin/pow/exp` in decision paths (only in smooth shaping that is not thresholded).
5. Heights quantized at stage boundaries before thresholds.
6. **The baked map is the truth.** Same seed + params on the same build/platform ⇒ bit-identical. Across Mac/Windows ⇒ same structure (coasts, biomes, rivers, city); tiny float differences are possible because FastNoiseLite is C++ float maths compiled differently per CPU. Golden hash tests run per platform.
7. `generator_version` stored; old maps still open (baked), regeneration warns if the version differs.

### 3.3 Pipeline

Stages: `id`, `deps`, `param_keys`, `run(ctx)`; outputs cached by (stage, params subset, upstream hash). Runs on a worker thread with cancel token.

**Layout grid** — fixed 512² for every map size. Live preview while dragging uses 256² with only the changed stages rerun; ~0.3 s after release it refines to 512² — that result is what commit uses.

| # | Stage | What it does |
|---|---|---|
| 1 | **Landmass + city reservation** | Continent mask (warped low-freq noise + falloff on 1–3 seeded ocean edges; north is coast when fjords + ocean are on). Land/Water slider = threshold; Islands = offshore blobs; Roughness = warp on the mask. **City site reserved here** (seeded candidate area ≥ 15 % of map from every border + city radius), forced to land with gentle relief, so it can never fail. Ocean = flood-fill from border. |
| 2 | **Climate** | Temperature = latitude + noise − altitude lapse; Moisture = noise + ocean proximity + rain shadow. |
| 3 | **Biomes** | Whittaker-style lookup restricted to enabled biomes with forced rules (fjords cold coast, northern mountains cold inland, desert hot+dry, tropical hot+wet, temperate/grass middle). Smooth weights (blend width slider). Desert Highlands = ring band around the desert with 1–2 passes. Grassland is the fallback. |
| 4 | **Relief** | Per-biome height recipes blended by weights (ridged mountains; fjord troughs below sea level; terraced highland wall; dunes + mesas; rolling tropical hills; gentle grassland). Rifts = warped ridged cracks, registered as **dry** areas. Thermal erosion pass. City plateau flattened **here** (before water). |
| 5 | **Hydrology** | Quantize (1/16 m) → Priority-Flood (binary heap, ties by index; ε-gradient on flats) → depressions become lakes only where moisture is high enough and outside dry areas (desert, rifts → dry basins / salt flats, or breached) → D8 flow + accumulation → rivers above threshold → splines (width ∝ √flow). Frozen flag where temperature < 0. Sea ice where ocean is cold. |

**Full resolution** (on commit, CPU, row bands in parallel):

| # | Stage | What it does |
|---|---|---|
| 6 | **Detail height** | Bicubic layout height + world-space detail noise; detail amplitude fades to 0 near coast, water and the city so it cannot move shorelines or create puddles. Inland land clamped ≥ +0.5 m outside water bodies; river/lake beds carved after detail; lake levels recomputed from final heights. Output `P`. |
| 7 | **Textures** | Control map from biome weights + slope/height rules (rock on steep, snow by altitude, sand at beaches, gravel in riverbeds, ice/snow on frozen shores); overlay chosen with dithering where 3 biomes meet; per-pixel UV rotation/scale for variety; colour map tints biomes (lush tropics, pale tundra). Same rule function re-runs on the dirty rectangle after every sculpt stroke, skipping `paint_lock` pixels. |
| 8 | **Ocean & ice masks** | Ocean-connected mask + sea-ice mask → textures sampled by the ocean shader (no ocean water in inland basins). |
| 9 | **City** | Voronoi wards on the reserved plateau: walled medieval old town (gates, keep, market square) + gridded modern districts outside; streets; lots by recursive splitting; building archetype per lot (by distance to centre). → `city.json`. |
| 10 | **Vegetation** | Per instancer cell (32 vertices): hashed jittered grid × density(rule, biome weights, slope, height, water/road/city exclusion, scatter paint). Runs region by region in the background after commit, nearest regions first; grass is particle-only (no stored data). |
| 11 | **Bake** | Write map folder, stage hashes. |

Targets (M2): preview tick ≤ 300 ms at 256², refine ≤ 2 s at 512², commit for 4096² ≤ 30 s (vegetation streams in afterwards). Timings measured in tests and printed.

## 4. Editor application

- **Layout**: menu bar · left tool palette · centre 3D viewport · right inspector · bottom asset browser · minimap (top-right) · status bar (position, height, biome, FPS).
- **Camera**: right mouse + WASD/QE fly, wheel = speed, F = focus, minimap click = teleport.
- **Brush UX**: on-ground circle; `[`/`]` size, `-`/`=` strength, Shift invert.
- **Undo/redo**: runtime `UndoRedo`; one command per stroke/action.

| Tool | Behaviour |
|---|---|
| Select / Move / Rotate / Scale | Pick entities; axis gizmo; snap to ground; Delete |
| Sculpt | Raise / Lower / Smooth / Flatten / Noise (Terrain3D runtime editor); textures re-derived under the stroke |
| Rift / Canyon | Drag a line → trench modifier (width, depth, roughness) → part of `P`, editable later |
| Paint Texture | Pick slot; paints; marks `paint_lock` |
| Paint Vegetation | Pick group → density up/down → affected cells re-scatter |
| Place Object | Catalog browser → ghost preview → click; random rotate/scale; align to slope |
| Water | Sea level; add lake (click basin → fills to spill level); draw river (spline modifier → bed carved into `P`, mesh built); frozen toggle (ice is walkable) |
| Holes | Holes in terrain (future caves) |

**Regenerate**: reopens the generator with the map's params; on commit `D = current − P_old` is preserved and added to `P_new`; hand-placed entities, painted textures, scatter paint and overrides kept; orphaned overrides listed.

## 5. Assets (placeholders, CC0, already downloaded)

- Ground: ambientCG 1K — Grass004, Ground037 (grassy dirt), Ground048 (forest floor), Ground054 (dry earth), Ground033 & Ground080 (sand), Gravel022, Rock030, Snow006, Ice002.
- Nature: Kenney Nature Kit (pines, oaks, palms, bushes, cacti, rocks, flowers, grass tufts).
- City: Kenney Fantasy Town Kit 2.0 (modular medieval pieces → merged into building archetype meshes in code) + Kenney City Kit Commercial (whole modern buildings).
- Water: our own shaders — ocean (Gerstner waves, depth colour, foam, sea-ice from mask), lake, river (flow along UV), ice material.
- Grass: Terrain3D 1.1 particle-grass example adapted (MIT), only on grass texture IDs.

## 6. Code layout

```
core/            rng.gd, grid.gd, geom.gd (polygons, splines), json_schema.gd
world/           map_data.gd, map_io.gd, catalog.gd, world_loader.gd
world/terrain/   terrain_backend.gd, terrain3d_backend.gd, terrain_plugin_shim.gd
world/water/     ocean.gdshader, river.gdshader, lake.gdshader, water_builder.gd
world/entities/  entity.gd, entity_kinds.gd, entity_layer.gd
worldgen/        gen_params.gd, pipeline.gd, stages/*.gd, texture_rules.gd, city_gen.gd, scatter.gd
editor/          editor_main.tscn/.gd, new_map_dialog.gd, tools/*.gd, ui/*.gd
assets/          textures/, models/, catalog.json, LICENSES.md
tests/           run_tests.gd + test_*.gd (headless), smoke_*.gd (windowed)
tools/           run_editor.sh, run_tests.sh, pack_terrain_textures.gd
```

## 7. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Foundations ✅ partly | Terrain3D verified on Metal at runtime (done); textures packed (done); RNG with test vectors; export presets; test runner |
| M1 | Generator + New Map screen | Layout pipeline with timings; sliders/biomes/seed with live preview; golden determinism tests |
| M2 | Commit → 3D world + game hookup | Full-res `P`, textures, ocean mask, city plateau; save/load; **game loads the map and spawns the player** |
| M3 | Editing | Fly camera, sculpt (+ texture re-derive), rift modifier, texture paint, undo/redo, minimap, regenerate-with-edits |
| M4 | Water | Ocean/lake/river shaders + meshes, sea ice, frozen lakes with collision, lake & river tools |
| M5 | Population | Vegetation scatter + paint, city buildings, object placement + select/move/delete |
| Later | — | Roads tool; 16 km + streaming; spawns/chests/items/NPCs; navmesh baking (control-map nav bit reserved); HLOD; better erosion (stream power, C++); world-map render; Windows golden-hash CI |

## 8. Testing

Headless runner (`tools/run_tests.sh`): RNG reference vectors; params JSON round-trip; same seed+params ⇒ identical stage hashes; different seeds differ; city inside border margin and on land; enabled biomes present where geography allows; no ocean pixels outside the ocean mask; save → load round-trip. Windowed smoke tests for Terrain3D and screenshots of the editor.

## 9. Open risks

1. Terrain3D is a release candidate → wrapped; smoke test in place.
2. Cross-platform float differences in FastNoiseLite → baked maps are the truth; structure protected by quantization; per-platform golden tests.
3. GDScript speed → measured per stage; heavy loops flat and threaded; candidates for C++ later.
4. Mixed asset styles → acceptable for placeholders.

## 10. Adversarial review — findings and resolutions

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Crit | `FastNoiseLite.get_image` is 8-bit and normalizes per image | Heights use `get_noise_2d` floats (measured 33 ms / 512² × 5 oct); `get_image` not used for heights |
| 2 | Crit | JSON turns ints into floats; 64-bit seed breaks | Seed stored as string; schema-typed loading; canonical-string hashing (§2.3, §3.1) |
| 3 | Crit | Sign-extending `>>` breaks SplitMix/PCG | Logical-shift helper `_lsr`; reference test vectors (§3.2) |
| 4 | Crit | One ocean plane floods inland basins | Ocean-connected mask sampled by ocean shader; inland land clamped ≥ +0.5 m (stage 6, 8) |
| 5 | Crit | Priority-Flood turns rifts/desert into lakes | Dry areas (desert, rifts) never become lakes; lakes need moisture (stage 5) |
| 6 | Major | Terrain3D plugin/undo requirements; undo memory | Shim with `ui` + 4 undo methods (verified on M2); undo capped (§2.1) |
| 7 | Major | `DYNAMIC_GAME` collision breaks far raycasts | Picking via `get_intersection`, never physics (§2.1) |
| 8 | Major | No per-cell instancer clear; cell = 32 vertices | Scatter per region + mesh (`update=false` then `update_mmis`); cells in vertex units (stage 10) |
| 9 | Major | Scatter too slow for the commit budget | Background, nearest-first, after commit; grass particle-only; streamed tree collision (stage 10, §2.4) |
| 10 | Major | Layout timing unmeasured | Timings measured per stage in M1 tests; partial reruns while dragging; heap Priority-Flood at 1/16 m |
| 11 | Major | Preview ≠ final (detail moves coasts, rivers) | Detail faded near water/coast/city; carve after detail; lake levels recomputed; promise = "same structure" |
| 12 | Major | Determinism overstated | Honest contract (§3.2): baked is truth; integer hashes; no GPU in v1; per-platform golden tests |
| 13 | Major | Vector edits double-applied via sculpt delta | Height layers `P` (base ∘ modifiers) + `D = current − P` (§2.2) |
| 14 | Major | Generated buildings in authored store; unstable IDs | City derived in `city.json`; overrides/tombstones by stable lot keys; orphans surfaced (§2.4) |
| 15 | Major | Textures stale after sculpting | Texture rules re-run on dirty rect, respecting `paint_lock` (stage 7) |
| 16 | Major | Frozen fjords not covered; ice not walkable | Sea-ice mask in ocean shader; ice collision for frozen water (stage 8, M4) |
| 17 | Major | City site can fail; flatten after water; "large" undefined; modular kit cost | Site reserved in stage 1; plateau in stage 4; size as % of map; merged archetype meshes + MultiMesh |
| 18 | Major | Headless tests can't use GPU | No GPU compute in v1; everything CPU and headless-testable |
| 19 | Minor | Ocean checkbox semantics; no exclusion layer; memory figure | Ocean-off = landlocked (§3.1); exclusion derived from roads/water/city/buildings (§2.4); budget 600 MB |
| 20 | Minor | 3-biome seams with base+overlay | Dithered overlay choice + UV rotation/scale variety (stage 7) |
| 21 | Minor | `int()` truncation around origin | `floori` everywhere (§2.1) |
| 22 | Minor | Texture packing | Packed offline into imported resources (done) |
| 23 | Minor | Export pitfalls | world/ never references worldgen/; separate user dirs; macOS signing notes (§2) |
| 24 | Minor | 16 km pointless at 4 m spacing; scatter paint format | 16 km removed until streaming; scatter paint one file per group (§2.3) |
| 25 | Minor | Navigation, LOD | Nav bit + `nav_obstacle` reserved; visibility ranges; navmesh baking later |
| 26 | Minor | Milestone order | Game hookup moved to M2; water split out (M4); regenerate-with-edits in M3 |

## 11. As built (first slice) — status, deviations, known gaps

**Built and tested** (19 headless tests + windowed end-to-end smoke tests on the M2):
New Map screen with live 128→256→512 preview · layout pipeline (landmass, climate, 8 biomes incl. the desert-highland wall, relief, hydrology with lakes/rivers, sea ice) · full-res terrain + textures with soft biome transitions · ocean / lakes / rivers / ice with collision · procedural city (walled old town, keep, plaza, radial/ring streets, modern grid districts, ~1,500 buildings on a 4 km map, street painting, chunked LOD) · vegetation (~100k instances on 4 km, palette remapped) + GPU grass · editor tools: Select, Sculpt, Paint, Vegetation, Rift, Water (lake/river), Place · undo/redo · save/open `.luxmap` · regenerate keeping edits · the game plays editor maps · export presets (Game / World Editor × macOS / Windows; macOS editor build launched successfully).

**Measured (M2, 4 km map):** preview 0.15 s (128²) / 0.65 s (256²) / 2.6 s (512²); generation ≈ 25 s total (terrain 11 s, vegetation 9 s); editor ≈ 45 fps at 1600×900 over the city.

**Deviations from the plan**
- No GPU compute at all (v1): `FastNoiseLite.get_noise_2d` measured fast enough; engine-object calls serialise across threads, so noise is sampled single-threaded and pure maths runs in parallel row bands (`core/par.gd`).
- Terrain3D region size is **256** (not 1024); everything else uses `TerrainBackend` so this is invisible to callers.
- A fresh `Terrain3DEditor` defaults to the Region tool, which draws the region grid — the backend resets it to "no tool".
- City buildings are assembled from Kenney Fantasy Town wall modules + generated roofs (`world/building_kit.gd`), merged per archetype, MultiMesh-instanced near and merged low-poly per 160 m chunk far away.
- Kenney colours are pastel; `catalog.json → palette` remaps leaf/bark/stone materials at load.

**Known gaps / next steps**
1. Hand-painted ground textures are not carried over by "Regenerate" (sculpt, modifiers, objects, overrides, vegetation paint, user water are).
2. Moving a city building is not supported yet (delete works; "detach to object" is the planned path).
3. Some rivers still run in short straight lines across filled meadows (flat depressions); a breach/carve pass would fix it.
4. Terrain3D's mesh instancer has no collision: trees are not solid in the game yet (planned: streamed collision shapes near the player).
5. Roads between settlements, road tool, spawn/chest/NPC placement UI (kinds already declared), navmesh baking, 16 km maps with streaming.
6. Windows builds export but were not run (no Windows machine here); cross-platform golden-hash test still to add.
7. Vegetation scattering in GDScript is the slowest generation step (9 s at 4 km) — first candidate for C++ later.

## 12. Level of detail (LOD)

Every object picks how detailed to draw itself from its own distance to the camera, and one
**detail scale** (`world/lod/lod_controller.gd`) stretches or shrinks all those distances at once.

**Offline LOD chains** — `tools/lod/build_lods.gd` (run after adding/changing models; ~10 s; needs a window):
- For every catalog model and city building piece: LOD0 = original, LOD1/LOD2 = simplified
  (Godot's simplifier, or vertex clustering for tiny meshes; each level must keep the outline and
  ≥ 60 % of the surface, and be ≥ 10 % cheaper than the previous level, else it's dropped).
- Trees and cacti also get an **impostor**: two crossed cards with front/side pictures of the model.
- Output: `assets/lod/<id>.scn` (children `LOD0..LODn`) + `assets/lod/manifest.json`.
  `tests/lod_sheet.gd` renders all levels side by side for checking.

**Distance tiers** (`world/lod/lod_settings.gd`, metres at detail ×1):

| Kind | LOD0 | LOD1 | LOD2 | far / impostor | disappears |
|---|---|---|---|---|---|
| tree | 60 | 170 | 420 | impostor cards | 2000 |
| plant / rock / small | 40–70 | 90–200 | 260–600 | — | |
| city (medieval) | 110 | 320 (full kit pieces again) | box + roof | — | 3200 |
| modern building | 140 | 420 | low-poly | — | 3200 |

**How each system switches**
- *Vegetation* (Terrain3D instancer): per 32 m cell. On a detail change the new ranges are set
  with Terrain3D's change notifications paused, then regions are rebuilt 4 per frame,
  nearest first (~1 s, no hitch; one full rebuild would freeze ~2–3 s).
- *Far trees*: `ImpostorLayer` — all species of a 256 m region in one MultiMesh with a shared
  atlas (one draw call per region). Cards hide themselves per instance in the shader where real
  trees are still drawn; their start follows the vegetation's actual scale so there's never a gap.
- *City*: LOD0 and LOD1 = one node per building (exact distance, view and occlusion culling;
  medieval houses use the same mesh for both, so one node covers both — see §18); LOD2 merged
  per 320 m chunk with each building's centre stored per vertex (CUSTOM0), so the shader
  (`lod_lit.gdshaderinc`) switches **per building** while a chunk costs a handful of draw calls.
  Shadows come only from the LOD2 box+roof (invisible shadow-only copy), inset 0.3 m inside
  the building so it never lies on the building's own walls and roof (that caused striped
  shadow acne). Roof colours: palette index per vertex (merged) or a shared pre-tinted
  material (single nodes).
- *Medieval houses* (`BuildingKit`): merged kit pieces keep the kit's own flat-shading
  normals (recomputing them smoothed every bevel into smeared gradients); only the shapes
  built in code (foundation, roofs, gables, distant boxes) get generated flat normals. Each
  floor uses one colour family of the kit — stone pieces are blue-grey plaster, wood pieces
  brown timber (the kit's `wall-wood-window-small` is plaster, so timber floors use
  `wall-wood-window-glass`). Their middle LOD uses the full pieces: the simplified pieces
  saved little and smeared the windows once the adaptive scale pulled them to ~40 m.
- *Placed objects*: their LOD chain as child nodes with Godot visibility ranges (cross-fade).
- *Ocean*: three tile resolutions by distance. *Terrain*: Terrain3D's own clipmap LOD.
- *Shadows*: sun shadow distance = 400 m × detail scale.

Shaders measure distance to the **main** camera (`MAIN_CAM_INV_VIEW_MATRIX`), also in shadow
passes, so shadows always match what is drawn. The global shader uniform `lod_scale` (project
settings → shader globals) carries the detail scale to every LOD shader.

**Detail levels**: Low ×0.5 · Medium ×0.75 · High ×1 · Ultra ×1.5 · **Adaptive** (holds 60 fps by
walking a ladder of detail, render resolution and SSAO — see §18) ·
**No LOD** (reference/debug: full detail to 20× the distances). The game uses Adaptive (60 fps).

**Measured** (4 km map, M2, 1600×900; same views as `tests/bench_lod.gd`; triangles/draw calls
are exact, FPS was taken while another game was running so treat it as relative):

| View | before LOD work | No LOD | High | Low |
|---|---|---|---|---|
| City street | 7.2 M tris · 4 480 calls | 6.7 M · 22 922 | 2.6 M · 658 | 2.0 M · 417 |
| City overview | 3.8 M · 685 | 9.2 M · 24 610 | 2.4 M · 489 | 2.0 M · 313 |
| Forest floor | 4.1 M · 7 669 | 8.4 M · 39 790 | 1.7 M · 3 028 | 1.3 M · 999 |
| Panorama | 3.0 M · 405 | 6.4 M · 46 551 | 0.34 M · 304 | 0.20 M · 149 |

"Before" drew trees only to 650 m and the city in two tiers; now forests are visible to 2 km and the
city has three tiers, with far less geometry. Same-run FPS: No LOD 4–18 → High 23–47.

Tests: `tests/test_lod.gd` (LOD chains present, levels get cheaper, trees have impostors, tiers,
adaptive controller), `tests/bench_lod.gd` (views × detail level), `tests/bench_adaptive.gd`.

## 13. Physics & movement (Counter-Strike / Source model)

**Player movement** — `world/physics/player_controller.gd` (CharacterBody3D) with the maths in
`source_movement.gd` and constants in `movement_settings.gd` (Source units, 1 u = 1 inch = 0.0254 m;
presets CS:GO (default), CS:S, CS 1.6). Written from Valve's published Source SDK 2013 behaviour
(gamemovement.cpp) and HL1 pm_shared.c — no leaked or GPL code was copied.

Per 64 Hz tick, in Source's order: duck → first half of gravity → jump (friction is skipped on
the jump tick → bunny hopping) → ground friction + acceleration or air acceleration (30 u/s air
cap → air strafing) → move_and_slide (slides along walls, snaps down slopes/stairs like
StayOnGround) → StepMove (if a wall stopped us: test up 18 u / forward / down, keep it if it gets
further and lands on walkable ground) → push props → ground check (normal.y ≥ 0.7 ≈ 45.6°,
rising faster than 140 u/s = airborne) → second half of gravity → landing (fall damage, stamina).

| | value | metres |
|---|---|---|
| run / walk (Shift) / crouch | 250 u/s, ×0.52, ×0.34 | 6.35 / 3.30 / 2.16 m/s |
| gravity | 800 u/s² | 20.32 m/s² (also the project gravity, so props match) |
| jump | 301.99 u/s → 57 u apex | 7.67 m/s → 1.45 m |
| friction / stopspeed / accel / airaccel | 5.2 / 80 / 5.5 / 12 (CS:GO) | |
| hull standing / crouched | 32×72 / 32×54 u | Ø0.81 × 1.83 / 1.37 m (cylinder) |
| step | 18 u | 0.46 m |
| bunny hop | speed capped to 1.1× run on each jump, jump must be re-pressed (CS:GO competitive); `bunnyhop_uncapped` / `auto_bunnyhop` switch it to classic | |
| stamina (CS:GO) | jump +24, landing +0.05×fall speed, max 80, recovers 60/s; slows you by (1−s/100)² | |
| fall damage | (v − 580) × 100 / 420 u/s | safe below ≈ 5.3 m, ~50 at 10 m |

Crouching on the ground shrinks the hull from the top; in the air it pulls the feet up
(duck-jump: +0.46 m reach). Standing up needs headroom. Swimming (waist deep in a lake or the
ocean, via `WorldView.water_level_at`) uses Source's WaterMove: 3D, slow sink, jump swims up.
Third-person: `game/player/player.gd` + `orbit_camera.gd` (mouse look; movement is camera-
relative, so air strafing = hold A/D and turn the mouse). Rendering is interpolated between
physics ticks.

**Physics props** (`world/physics/prop_library.gd`, `physics_prop.gd`) — Source `prop_physics` on
Jolt RigidBody3D: mass and surface material from the catalog (`"physics"` block; materials from
Source's surfaceproperties: friction / bounce / density in `surface_props.gd`). The player
(kinematic, like Source's 85 kg physics shadow) pushes props only when moving faster than
75 u/s, horizontally, weaker on heavier props, never the one it stands on; light props don't carry
you. Props under 5 kg are debris (collide with the world only). Optional health → breaks into
debris that fades. Flying props hurt the player per Source's impact table. Physics LOD: props
more than 90 m from the player freeze, and wake within 70 m. In the editor props are frozen
(placeable with Place → Physics props).

**Collision layers** (`physics_layers.gd`, names in project settings): 1 world, 2 player, 3 npc,
4 prop, 5 debris, 6 ragdoll, 7 dynamic, 8 pushaway, 9 projectile, 10 hitbox, 11 trigger,
20 editor picking.

**Tests**: `tests/test_movement.gd` — maths (acceleration, friction stop time, air strafing,
wall clip, fall damage) and a Jolt test course: run speed, stop, jump height, 18 u stairs vs a
too-tall step, 44° vs 47° ramps, crouch-jump onto a 1.7 m ledge, crouch / walk speeds, bunny-hop
cap, fall damage, light vs heavy crate pushing, swimming. `tests/smoke_game.gd` plays a real map.

**Gameplay layer (second pass, built 2026-10-21)** — placeholders throughout (box-man capsule
characters, box guns, synthesized sounds), meant to be swapped for real assets:

- *Ladders* (`world/physics/ladder.gd`): rails + rungs + solid back, and a TRIGGER `Area3D`
  (meta `ladder`, climbing side = local −Z) reaching 0.8 m above the top. Source LadderMove:
  walk into it to grab, forward climbs (down when looking down) at 200 u/s, strafe moves
  sideways, crouch/walk slows to ×0.34, jump pushes off at 200 u/s. You let go once your centre
  passes the rungs (climbing out over the top). Grabbing from the top is not supported yet.
- *+use pickup* (`prop_carrier.gd`, E): props ≤ 35 kg and ≤ 128 u across; held 1.6 m in front
  of the eyes, dropped when blocked > 2.5 m away; E again drops, fire throws.
- *Pushaway clutter* (PUSHAWAY layer: cans, bottles, buckets): the player walks through them;
  moving faster than 75 u/s nudges everything within 40 u away (Source obstacle_pushaway).
- *Moving platforms* (`moving_platform.gd`, AnimatableBody3D on DYNAMIC): ping-pong along
  `travel` at `speed`, pausing `wait` s at each end. Players ride them horizontally and as lifts.
- *Hitscan weapons* (`world/combat/`): knife / pistol / rifle / sniper from `weapon_defs.gd`
  (CS:GO-like damage, range modifier per 500 u, penetration power, spread, recoil, magazine,
  reload, move speed cap). Bullets go through up to 4 surfaces: max thickness =
  power × 0.1 m / surface resistance (`SurfaceProps`), damage drops with thickness; they stop in
  characters and terrain. Hitgroups ×4 head, ×1.25 stomach, ×1 chest/arm, ×0.75 leg. Hits push
  physics props and ragdolls.
- *Ragdolls* (`ragdoll.gd`): 11 capsules joined by hinges (elbows, knees) and cone-twists; the
  killing impulse goes into the part that was hit. At most 8 at once (oldest removed), they
  freeze after 6 s when still and vanish after 30 s. The player and training dummies use them.
- *Training dummy* (`training_dummy.gd`): box-man with hitboxes, 100 hp, ragdolls on death and
  stands up again after 6 s.
- *Editor*: Place → **Gameplay** (ladder, moving platform, training dummy, spawn point). Their
  settings (ladder height; platform travel/speed/wait; dummy health) are editable in the Select
  tool and undoable; changing one rebuilds that object. In the editor platforms and dummies are
  inert and spawn points show as markers; in the game spawn points are invisible.

Tests: `tests/test_gameplay.gd` (ladder climb + exit at the top, climb speed + jump-off, pickup
limits + throw, range falloff, wood vs concrete penetration, headshot ×4 kills a dummy and the
ragdoll settles, ragdoll cap, bullet pushes a crate, horizontal platform + elevator rides,
pushaway, editor/game entity dispatch). `smoke_game.gd` shoots a dummy on a real map.

**Not yet**: real weapon/character models, animations and sounds; grenades and
projectiles (layer reserved); doors; climbing onto a ladder from the top. (NPC AI: §14.)

## 14. Gameplay systems: spawning, creature AI, persistence, debug tooling (as built)

Design, research and review: [docs/gameplay-systems/](../gameplay-systems/PLAN.md) (PLAN v3,
RESEARCH, REVIEW, **DECISIONS** — owner rules that override the plan). Owner decision: **no format migrations** — maps (`schema_version` 2) and
saves (`format_version` 1) of another version are refused with a message and re-created.

**Layers.** `WorldView` (editor and game) owns the authored-data infrastructure: `WorldGrid`
(64 m cells / 256 m regions, layered string-id index), `ZoneIndex` (zones by priority, then
smaller area) and `DebugDraw` (channels: zones, spawns, ai, cells, nav, physics, items,
persistence). `WorldSession` (runtime of one map) attaches to a view — the game's, or the
editor's in Simulate mode — and owns `NpcManager`, `SpawnDirector`, `AmbientSpawner`,
`ItemWorld`, `InteractionSystem`, `NavMeshNavigator`, `WorldState`, `WorldQueries`. `GameSession`
(one play-through) owns `SimClock` (play seconds; all persisted timers), `TimeOfDay`,
inventory, progress (XP, skills), `StoryState`, `SaveService` and the `DebugConsole`; the game
host (`game/world_game.gd`) keeps it across map swaps.

**Entities.** Dispatch by kind through `KindRegistry` (runtime behaviours: build node or none,
persistence policy, gizmo) — kinds no longer need a catalog asset. Schema in `EntityKinds`
with prop types float/int/bool/string/color, `enum`, `ref:<registry>`, `entity_ref:<kind>`,
`table:<schema>`, `condition` (story condition), `roles`; `normalize()` restores types after
JSON. Shaped kinds (`zone`, `path`) store `shape` {polygon|circle|box|polyline}. New kinds:
`spawner`, `unique_npc`, `spawn_group`, `zone` (roles spawn / no_spawn / encounter / trigger),
`path`, `chest`. Data registries (`Defs`): `assets/data/{creatures,items,loot_tables,factions,
spawn_rules}.json` (exported by every preset).

**Spawning.** Slots `"<entity>#<i>"` (UNSPAWNED / ALIVE / DEAD(respawn_at) / GONE) with a
`block_reason`. **Nothing spawns inside the player's view** (frustum and ≤ 230 m, the body /
fade-in distance); slots are checked to 300 m so farther spawns appear as data and fade in;
only the first population while a map loads is exempt. Spawners (count, wander,
idle/wander/patrol path, respawn ± jitter, level, condition, group); groups (max
alive, weights, manual, leader); zones (weighted table rows with group sizes and levels,
max_alive, check interval, chance per check, initial full/trickle, min distance, slope /
altitude / water filters, hours, condition) picking points from a baked candidate set
(`ZoneCandidates`, stored in the map as `layers/zones_cache.bin`); encounter zones lock their
level on first use; ambient wildlife by biome in an 80–150 m ring (never in authored zones,
never saved).

**Creatures.** `NpcRecord` (data, authoritative) ↔ pooled `NpcBody` (one CharacterBody3D type).
`SimScheduler` tiers ACTIVE ≤60 m (24) / NEAR ≤220 m (64) / FAR ≤600 m / DORMANT, hysteresis,
combat bonus, packed-key sort; full pass every second, near pass 4×/s. Movement depends on
terrain collision, not tier: physics (`move_and_slide`, 32 Hz, navmesh paths) inside
collision radius − 8 m; snapped to the ground elsewhere (avoids water / steep slopes).
`NpcBrain` FSM IDLE/WANDER/PATROL/ALERT/CHASE/ATTACK/FLEE/RETURN/DEAD, profiles aggressive /
defensive / passive / skittish, aggro ± level, LOS through `WorldQueries`, leash + evade
(invulnerable, heals), assist by faction, data reactions (yell, call_help, flee, set_flag),
log ring buffer. Death: XP + skill XP (level L needs base·L·(L−1)/2), loot (WoW table semantics) **kept on
the corpse** — loot window, money auto-taken — ragdoll inside collision / lying corpse
elsewhere; corpses decay after 5 min (2.5 once emptied); harvest (skinning, shearing) after
looting. Day/night: `WorldView.set_time_of_day` from `TimeOfDay`. Far shots hit bodiless
records (`record_ray`), merged with physics hits by distance; `WorldQueries.trace` clamps rays
at the terrain everywhere (fixes shots through hills beyond 64 m).
Bench (M2, 1 040 creatures): AI+movement ≈1.2 ms/tick, scheduling ≈2.4 ms per pass (≈0.15 ms/frame).

**Persistence.** `user://saves/<slot>/manifest.bin` + `gen_<n>/{game.bin, maps/<uid>/state.bin,
maps/<uid>/dynamic/r_x_z.bin}`; complete generation per save, manifest swapped last (temp →
rename, `.bak`), checksum-verified with fallback to older generations, 3 kept, unloaded maps
byte-copied, worker-thread writes from deep copies, synchronous flush on quit / menu.
Saved: slots (dead/gone/life counts), unique NPCs (place, health), removed/modified ids
(opened chests, moved or broken props, felled vegetation as `veg:<asset>:<x>:<z>`), zone state
(level locks, fired triggers), runtime zones (camps), ground items and corpses with loot
(absolute expiry on the play clock: dropped items 1 h, spilled loot 5 min, corpses 5 min,
quest items never). Not saved: living ordinary creatures, AI, ambient wildlife, generated
vegetation/city.
Map identity: `map_uid` / `revision` / `lineage`; Save As asks same map / copy; entries whose
ids vanished from the map are dropped with a warning.

**Debug.** Same `DebugDraw` providers in editor and game; editor shows zones + spawns by
default (View → Debug overlays), the game shows nothing until the console (` / F1) turns
channels on (`/show <channel>`). The console itself is described in §15.

**Editor.** Zone tool (8) and Path tool (9) with handles, Alt-insert, right-click delete,
one undo step per drag; Place → Spawning; Select picks shaped entities by area; inspector
built from the schema (role sections, tables, refs, story conditions); spawning problems in
the inspector and Play → Check spawning problems; Play → Simulate here (F5).

Tests: `test_foundations` (14), `test_npc` (16), `test_persistence` (7), `test_world_features`
(6), `test_navigation` (1); windowed `smoke_editor` (zone tool via real input, gizmos without a
session, Simulate) and `smoke_game` (creatures, overlays, loot, save → fresh host → load).

## 15. Developer console (port of Ares Last Light's)

Ported from `~/Projects/areslastlight/Assets/Debugging/Console` (C#/Unity) to GDScript in
`world/debug/console/`; owner decisions in `docs/gameplay-systems/DECISIONS.md`.

**Layers.**
- `ConsoleModel` (RefCounted, headless): command registry, scrollback (4096 blocks, split
  every 64 lines), parser, async job runner, bars, key bindings, built-in commands.
  `execute(line)` echoes and prints; `run(line)` (tests, bindings, scripts) accepts the
  bare form too and returns the plain text printed.
- `DebugConsole` (CanvasLayer 128, `PROCESS_MODE_ALWAYS`, owned by `GameSession`): owns
  the model, a debug surface `Control` scaled by `DebugZoom`, the `ConsoleWindow` (built on
  first open) and `MonitorPanels`. It keeps the old contract: `is_open`, `toggled(open)`,
  `set_open`, `run`, gating by `DevGate`, and while open it swallows unhandled keys.
- `ConsoleLogger` (Godot `Logger`, `OS.add_logger`): `print` → debug lines,
  `push_warning` → warning, errors → error, all staged under a mutex and landed by `pump()`
  on the main thread (every frame, and before and after each command).

**Commands.** `ConsoleCommand(name, description, usage, handler, min, max, hints,
minimum_when)`. Handlers take `PackedStringArray` and return a `String` (plain success),
`ConsoleResult` (success/failure, plain or BBCode), `null`, or a `ConsoleJob` (async: a
body that may `await`; jobs run one at a time, FIFO, polled, "queued behind"). Verb tables
(`ConsoleVerbs`, `console.verbs(name, desc, owner).verb(...)`) give `/nav status`-style
commands: a bare call lists the verbs, unknown verbs say "Try: …", hints and minimum
argument counts forward to the verb. Systems register with an owner and
`console.remove_owner(owner)` removes their commands, the verbs they added to other tables
(e.g. `/content`), bar sections, panels and hotkey descriptions. Who registers what:
`GameCommands` (play-through: time, skip, timescale, story, flag, var, give, take, inv,
xp, level, skill, loot, audio, content verbs, title-bar game time, save indicator),
`WorldCommands` (per map: show, hide, where, info, tp, camp, ambient, fell, nav, zone,
items, fov, the World panel), `NpcManager` (npcs, spawn, kill, despawn, ai),
`SpawnDirector` (why, spawner), `world_game` (god, notarget, noclip, heal, hurt, weapon,
ammo, save, load, saves, menu, newgame, the Player panel, game key descriptions),
`DebugConsole` (monitor, zoom, Render/System panels) and the model's built-ins (clear,
close, echo, help, log, bind, unbind, hotkeys, delay, exec, quit, version, vsync, maxfps,
content).

**Parsing and completion** follow Ares exactly: `/` introduces a command; quotes group
words, mid-token quotes join, a backslash escapes only inside quotes. Completion reads the
whole line: command names, then the command's hint provider (authoritative). Dropdown of
5 rows that slides with the selection, typed prefix in amber, ghost suffix; Tab accepts
(adding a space when more arguments follow); Return completes and keeps a line that is
still short of arguments; Esc dismisses → clears → closes; Up/Down step suggestions then
history (128, session only; a recalled line withholds suggestions). Unknown names get "Did
you mean" from prefix → substring → edit distance ≤ 2.

**Window.** Built from code with Ares's theme colours: title bar (drag; double-click
maximises), log (`RichTextLabel`, BBCode, coloured by kind, `[HH:MM:SS] [L]` stamps on
system lines, display filter `/log level`), dropdown, input (`TextEdit` wrapping up to 6
rows, so selection, clipboard and undo come for free), status bar (job spinner, save
indicator; hidden when empty), resize grip, close box, shadow, fade/slide reveal. Font: a
monospaced `SystemFont` (Menlo / Consolas / DejaVu Sans Mono…) with box drawing for
`ConsoleTable` (single, rounded, double, heavy, ascii; fitted to the window's columns).
Zoom steps 75 %–300 % shared with the panels (Cmd/Ctrl + = − 0, `/zoom`); the zoom and the
window rectangle persist in `user://settings.cfg [console]`.

**Not ported:** exception reporting ("threw": GDScript has no exceptions), Perfetto
tracing, `/font`, `/netinfo`, `/haptics`, the per-cell pixel reveal, sprite blocks.

## 16. Skill tree

- **Data:** `world/skills/skill_tree.gd` (`SkillTree`) reads a "skill-tree" JSON (version 1)
  from `lux/skills/tree_path` (default `res://Arisent-DEMO.json`). Nodes carry id, name,
  description, x/y (canvas position, y up is negative), colour, shape (circle / square /
  diamond), icon (unused so far), cost per rank, maxRank, category and connections, where a
  connection means "this unlocks that". `parents` is derived. Bad entries are skipped and
  listed in `errors` (pushed as warnings once).
- **State:** `PlayerProgress.tree_ranks {id: rank}` plus `bonus_points`, saved in the
  progress dictionary. Free points = (level − 1) × `SKILL_POINTS_PER_LEVEL` + bonus − spent.
  `learn(tree, id)` checks `SkillTree.why_not` (unknown, mastered, locked, too expensive).
  `GameSession.apply_save` runs `SkillTree.sanitize` so ids no longer in the tree are refunded.
- **Screen:** `game/ui/skill_tree_panel.gd` (`SkillTreePanel`) in `GameHud`, toggled by the
  `skill_tree` action (K); custom-drawn nodes and connections, pan/zoom, tooltip, click to learn.
- **Console:** `/skilltree show|list|learn|set|points|reset|reload|open`.
- **Tests:** `tests/test_skill_tree.gd`; the game smoke opens the tree with K and learns by click.

## 17. Player model and animations

- **Model:** `assets/models/main-character/demo.glb` (owner-provided fox mage, auto-rigged:
  57 unnamed bones `bone_0…bone_56`, A-pose, faces +Z, left side +X). `Player` scales it
  to `MODEL_HEIGHT` (1.8 m) with its feet at the origin. (The old `playerModelPlaceholder.glb`
  is gone; the unused prototype `player.tscn` now shows this model too.)
- **Clips (all CC0):** Quaternius's Universal Animation Library (Standard, 45 clips,
  `assets/animations/universal_animation_library/`) and, for ladders only, "Climb Ladder"
  and "Ladder_Idle" from the afk-rig animation library, cut out of it by
  `tools/rig/extract_clips.py` into `assets/animations/ladder_climb/ladder_climb.glb`
  (rig + those two clips, 218 KB). `tools/rig/bake_player_animations.gd` bakes both
  sources onto the model's own bones (model-space retarget: the source bone's turn from
  rest × an A→T-pose alignment for the limbs × the target rest; the torso keeps the model's
  own posture and takes only the animation's movement; hips move scaled by hip height) into
  `assets/models/main-character/player_animations.res` (48 clips). Godot's import
  retargeting was tried first and turned the arms the wrong way on this rig. Rerun the
  tool after changing the model or a mapping.
- **AnimationTree** (`game/player/player_animator.gd`, built in code):
  `base` Transition (ground / crouch / air / swim / ladder / dead; ground and crouch are
  synced speed BlendSpace1Ds, ladder blends Ladder_Idle → Climb_Ladder by climb speed and
  plays backwards going down) → `speed` TimeScale → `stance` Blend2 (upper body:
  Pistol_Idle with a gun while aiming or standing, Sword_Idle with the knife when standing) → `action` OneShot
  (upper body: Pistol_Shoot, Sword_Attack, Hit_Chest, Interact). Upper body = bone_1…bone_35.
  The base Transition must be sent a state at start-up (a Transition plays nothing until
  one is requested — that once left the legs in their rest pose).
- **Tail and scarf:** `game/player/secondary_motion.gd` (`SecondaryMotion`, a
  `SkeletonModifier3D`) simulates three chains (tail bone_53…56, scarf ends bone_37…40 and
  bone_41…44) in world space: carried along by their attachment for `follow` of its
  movement (the rest is lag and sway), pulled back to the animated shape (stiffness),
  gravity, bone lengths kept, and pushed out of capsules fitted to the body (pelvis, spine,
  chest, neck/head, thighs, the robe's skirt below the knees, shins, upper arms, wide
  sleeves). Joints and points along each segment are tested; Godot's
  `SpringBoneSimulator3D` was tried first but tests joints only (its offsets also don't
  follow a scaled skeleton) and the long tail segments cut through the robe. Each chain's
  shapes are calibrated at start so the sculpted rest pose touches nothing. A faint varying
  wind keeps them moving. Contact never launches a joint (pushed joints lose their outward
  velocity) and a thin cushion eases points away before they touch. The tail's target lifts
  up to 20° up and back with running speed (`run_lift`): hanging, the robe's swinging skirt
  swept into it on every stride and the pushes showed as stutter.
- **Model placement:** `Player.visual` is top-level with physics interpolation off and is
  placed every frame at the body's interpolated position (a child turned in `_process`
  loses interpolation and drew at the raw 64 Hz position — sawtooth stutter when strafing). `tests/test_player_model.gd` runs the player and fails on any
  overlap deeper than 3 cm.
- **Facing (RPG-style):** `Player._facing_target()` turns the model toward the steering
  direction (camera-relative WASD), whatever the weapon, so A/D/S turn it and it runs that
  way instead of sliding sideways in the forward-run clip. It faces the camera's aim only
  while `aiming`: the "aim" action is held (right mouse / left trigger) or within
  `AIM_HOLD` (0.8 s) of an attack. On a ladder it faces the ladder; with no input it keeps
  its yaw (or follows a slide over 1 m/s). The raised-gun upper-body stance plays only while
  aiming or standing. Movement physics are unchanged (shots still go where the camera aims).
- **Weapons** hang from a `BoneAttachment3D` on the right hand (`bone_23`), barrel along the hand.
- **Tests:** `tests/test_player_model.gd`.

## 18. Performance (target: a steady 60 fps)

**Measuring** — `tests/bench_game.gd` runs the real game (player, creatures, spawning, HUD) on a
saved map at fixed views (plaza both ways, a street, forest, grassland, a high view) and on a run
through the city. Per view: missed frames (longer than 1.25 × 16.7 ms), FPS, 1 % lows,
frame-time percentiles, objects / draw calls / triangles, and the adaptive governor's state.
`godot --path . --resolution 1600x900 --script res://tests/bench_game.gd -- <map> <out.json> [detail] [views…]`;
environment switches: `BENCH_VSYNC=1` (as the game runs — the measure that matters is *missed*
frames), `BENCH_GPU=<view>` (frame time with each feature switched off: shadows, SSAO, terrain,
city levels, grass, water, terrain shader features, half resolution…; `BENCH_ONLY=a,b`,
`BENCH_SHOTS=<dir>` for screenshots), `BENCH_PERF=1` (main-thread time per game system per
frame, and which systems ran long in each slow frame — `world/debug/perf.gd`),
`BENCH_ABLATE`, `BENCH_SPIKES`, `BENCH_ARRIVE`, `BENCH_RENDER`, `BENCH_HOLD` (for macOS
`sample <pid>`), `BENCH_NO_OCC`, `BENCH_TICKS`, `BENCH_FREEZE_SKY`.
Pitfalls: macOS stops drawing a window that is covered or on another Space (the bench prints
NOT MEASURED; scripts that wait for a drawn frame hang — run windowed jobs with a shell
watchdog); Metal reports no GPU time to Godot (use the feature-off comparisons); Godot's
`TIME_PROCESS`/`TIME_PHYSICS_PROCESS` monitors are not per-frame times (ignore them); results
swing ±40 % with other apps' load, so compare back-to-back runs and the load-independent counts.

**What the time went to** (M2, 1600×900, 8 km map, High, before → after):
- *GPU-bound*: the main thread waited on the GPU for 57 % of each frame; game scripts are
  ~0.3 ms per frame in total.
- *City*: the middle level was merged into 192 m chunks of full kit houses, so every visible
  chunk sent all its houses (4.1 M triangles, 8.8 ms at the plaza) and the shader discarded most.
  Now each building is one node for both near levels (medieval houses use the same mesh for
  both), culled by distance, view and **occlusion** (`CityView`: a box inside each building's
  walls and each wall segment; `rendering/occlusion_culling/use_occlusion_culling`). Plaza:
  6.1 M → 3.0 M triangles, 24.5 → 17.4 ms; street: 4 031 → 1 453 objects; video memory 3.1 → 1.3 GB.
- *Terrain* (8–10 ms, the largest cost): Terrain3D blended the materials of the four nearest
  cells per pixel almost to the horizon (up to 24 texture reads). The game swaps in a patched
  copy of Terrain3D's generated shader (`Terrain3DBackend.optimize_shader`, made at runtime
  from the stock code; falls back to the stock shader if the code changes) that blends
  materials only within 40 m × detail scale and beyond picks one cell by its blend weight
  (a world-fixed hash dithers the borders); heights, normals and colours still blend.
  Saves 1 ms (plaza) to 4 ms (wide views); looks the same. The editor keeps the stock shader
  (brush overlays). Dual scaling (1.8–3.6 ms) and slope projection (1.3–3.4 ms) stay on.
- *Stutter*: ~2 missed frames per second everywhere, even with headroom: the navigation
  mesh tiles were prepared on the main thread (7–9 ms every 0.5 s while tiles baked: a scan
  of all ~7 000 city boxes plus Terrain3D's triangles). Now the city boxes are indexed by
  64 m cell and the terrain triangles are gathered on a worker thread (0.2–0.5 ms). Street
  and forest: 6 → 0 missed frames per 3 s.
- Tried and dropped: ground occluders from the terrain (hid ~5 % of objects in these views,
  cost CPU; at 16 m spacing they dropped views to 8 fps); cheaper shadow/SSAO quality settings,
  2 shadow splits, a 2048 shadow atlas, no anisotropic filtering (each < 0.4 ms); physics at
  60 Hz or 32 Hz (no effect on missed frames); freezing the day–night cycle (no effect).

**Adaptive governor** (`LodController`, the game's default): one quality ladder (`LADDER`)
from Ultra-like detail down to 60 % resolution — below High the 3D render resolution goes
first (FSR 1 upscaling; instant, and most GPU work here is per pixel), then SSAO, the detail
scale last (each detail change rebuilds vegetation for about a second). Steps down on
sustained misses (> 8 % of a second's frames, or > 3 % two seconds running — a single hitch
isn't a reason); steps up without vsync on headroom (> 72 fps), and with vsync (where the
frame rate can't show headroom) after a calm stretch (8 s, doubling up to 90 s each time a
step up brings misses back). Samples taken while the vegetation rebuilds aren't counted;
reductions that don't help put it on hold for 20 s. Fixed presets render at full resolution.
Result: settles at full detail, 80 % resolution, SSAO on; 0–2 missed frames per 180 in every
view and 1–2 per 360 on the city run — also with 6 CPU cores busy and a system load of ~16.
Limit: another program rendering flat out on the same GPU (e.g. a second uncapped 3D game)
takes about half of it; no setting then holds 60.

**Player settings** (`world/settings/graphics_settings.gd`, `user://settings.cfg [graphics]`):
quality (Adaptive or a fixed preset), Adaptive's lowest resolution (the ladder's render scale
is clamped to it), the presets' resolution, vsync, frame-rate cap (under 60 it becomes
Adaptive's target), full screen, FPS counter. Medium and Low also switch off the terrain's
dual-scale texturing and slope projection (`TerrainBackend.set_texture_extras`; Terrain3D
regenerates its shader and the speed patch is reapplied — not done in Adaptive, the shader
recompile would hitch). Screens: `SettingsPanel` (main menu Options; the game's `PauseMenu`,
which Esc opens once the mouse is free — the tree is paused meanwhile). Tests and benchmarks
call `GraphicsSettings.use_defaults()` so a player's saved settings can't change results.

Tests: `tests/test_lod.gd` (governor under vsync: misses lower quality, calm raises it one
notch, a failed raise doubles the wait; presets at full resolution), `tests/test_settings.gd`
(save/load, applying, the resolution floor, terrain extras, the shader patch on a stored copy of
Terrain3D 1.1's shader — `tests/fixtures/` —, settings screen, pause menu), `tests/test_city.gd`,
`tests/test_navigation.gd`. The game smoke test prints whether the live terrain patch applied.
