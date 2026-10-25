# Plan: spawn zones, NPC AI with distance LOD, world persistence, debug tooling

Status: **v3 — implemented (P0–P5), 2026-10-22.** As built: docs/world-editor/ARCHITECTURE.md §14.
Owner decisions after implementation (loot on corpses, 1 h item expiry, XP formula, never
spawn in view, day/night) are in [DECISIONS.md](DECISIONS.md) and take precedence.

> **Owner decision (2026-10-22): no format migrations.** Everything is in development; maps
> and saves with an older `schema_version`/`format_version` are rejected with a clear
> message and re-created. Wherever this plan says "migration", read "version check".

([REVIEW.md](REVIEW.md); finding ids `Fnn`/`Nn`/`Mn` cited where they changed a decision). Research: [RESEARCH.md](RESEARCH.md).
"Editor" = the project's **World Editor** app (`editor/`, feature `level_editor`), not the
Godot editor.

## 0. Goals and non-goals

Goals
1. **Authoring** in the World Editor: draw zones, place spawners, patrol paths and groups;
   configure what spawns, how many, how often, when and where; see it (gizmos, preview,
   live Simulate).
2. **Runtime**: enemies and farmable creatures spawn from that data, think at a cost that
   scales with distance, drop coins/items, give XP/skill XP, respawn by rule.
3. **Persistence** of meaningful state only (dead spawns + respawn time, dropped items,
   opened containers, removed/moved objects, unique NPCs, player/story); everything
   regenerable is not saved.
4. **Debug helpers** drawn by the same code in editor and game — on by default in the
   editor, off in the game, toggled from a **debug console** — that explain *why*.
5. Long-term extensibility: villagers with schedules, quests, factions, harvesting, doors,
   weather, interiors/dungeons (multiple maps), world streaming, and not blocking
   multiplayer.

Non-goals: multiplayer, streaming (designed for), long-range navmesh pathing (phase 5),
quest system (story_graph flags/events only), animation beyond the box-man.

## 1. Current state that constrains the design (verified against code)

- Whole map loads at once; no spatial index; flat `MapData.entities` and
  `EntityLayer._nodes`; `update_physics_lod` is O(N).
- `EntityLayer` dispatches on catalog keys (`physics`, `gameplay`), not `kind`; kinds
  `chest`, `npc_spawn` exist without runtime or asset; code assumes `e.asset`.
- Entities = one transform + flat typed props (float/int/bool/string editors only).
- `MapIO` writes but never reads `schema_version`; entity ints come back as floats; no
  map id or revision; game picks maps by path.
- **Terrain collision only within 64 m of the player** (`Terrain3DBackend.set_focus`);
  hitscan is a physics ray, so **beyond 64 m shots already pass through hills** (existing
  bug, F3). Trees and scattered rocks (Terrain3D-instanced) have no collision; only
  hand-placed props do (F27). No navmesh.
- Ragdoll: 11 bodies + 10 joints built per death, cap 8 (static), collide with WORLD only.
- No autoloads, save game, game clock, console, interaction system or debug-draw utility;
  editor gizmos are per-tool `ImmediateMesh`es.
- Player input is polled in `_physics_process`; E = PropCarrier; weapons use keys 1-4/R.
- Game exports exclude `editor/ worldgen/ tests/ tools/`; `include_filter` lists only
  `catalog.json` and `lod/manifest.json` (F8).
- Story graph (flags/variables/conditions/events) exists, unused by the game.
- Vegetation instances are baked into the map's Terrain3D region files at generation.

## 2. Architectural decisions

**D1 — Runtime world = immutable authored base + session state + saved delta.**
`MapData` (what the editor saves) is never written at runtime. Play state lives in
`WorldState`; the save stores a delta over the base keyed by stable ids.

**D2 — Three layers, no global autoloads.**
- `WorldView` (exists today; editor and game) additionally owns the **authored-data
  infrastructure**: `DebugDraw`, `WorldGrid` (authored entities) and the authored
  `ZoneIndex`, kept up to date incrementally on entity add/change/remove. The editor draws
  gizmos, picks zones and previews candidates with **no session running** (M1/N1).
- `WorldSession` (one per loaded map, runtime only): `SimScheduler`, `SpawnDirector`,
  `NpcManager`, `ItemWorld`, `InteractionSystem`, `WorldState`, runtime zones. It
  **attaches to** an existing WorldView (adds runtime entries to its grid/index/channels)
  and **detaches** cleanly (removes only runtime entries) — that is how Simulate reuses the
  editor's WorldView.
- `GameSession` (one per play-through): `SimClock`, `TimeOfDay`, player progress (XP,
  skills), inventory, `StoryState` (initialised from the project story graph), `SaveService`,
  `Console`, known maps. `world_game` becomes a **persistent host** that owns the
  GameSession and **swaps** WorldView + WorldSession on map change — never
  `change_scene` while playing; leaving to the main menu or quitting flushes the save
  first (M2/N2). Simulate creates an ephemeral GameSession.
- `WorldView.session` points at the attached WorldSession; `WorldSession.of(node)` walks up
  to the WorldView (F6). Per-world caps that are static today (`Ragdoll._active`) move into
  session services (F29); `Boxman`'s static mesh cache is keyed by def id and bounded (N8). Definition registries (Catalog, defs) stay static and immutable;
  hot reload swaps a table atomically between frames; records refer to defs by id.

**D3 — Uniform spatial grid in metres.**
`WorldGrid`: 64 m **cells** (spawn/sim/index granularity) and 256 m **regions** (4×4 cells;
chunking of dynamic-object saves and the future streaming unit). Independent of Terrain3D
region size (F26). Sparse per-cell index of entities, slots, records, ground items, zones
(by AABB). `cells_in_radius`, `cell_of`, `query_aabb`, `query_ray` (for nodeless hit tests).

**D4 — Records vs nodes.**
Simulated things are `RefCounted` records (`NpcRecord`, `ItemRecord`, `SlotRecord`) with an
optional node representation created/freed (pooled) by tier. Records are authoritative,
are what debug views inspect, and what is persisted. Records reference other records by
**id**, never directly (no RefCounted cycles); a node holds its record, the record holds the
node's instance id (F30).

**D5 — One significance scheduler.**
`SimScheduler` scores simulants against a **weighted focus set** (player; later escorts,
Simulate pawn) (F32) using XZ distance, on-screen (through a `VisibilityProvider`, faked in
tests — F46), combat/damaged, `important` flag; assigns tiers under budgets with ±10 m
hysteresis; re-scores every 0.25 s over grid cells within the largest radius.

| Tier | Default | Budget | Node | Update |
|---|---|---|---|---|
| ACTIVE | ≤ 60 m, or damaged/aggroed within NEAR range | 24 | yes | brain 10 Hz staggered, locomotion every tick |
| NEAR | ≤ 220 m (≥ max weapon range) | 64 | yes (pooled, cheap visual) | 5 Hz round-robin |
| FAR | ≤ 600 m | ∞ | no | 0.5 Hz, data only |
| DORMANT | beyond | ∞ | no | none; analytic fast-forward on wake |

Tier ≠ locomotion (see D10): ACTIVE means full-rate brain, not physics. Physics
locomotion applies only within `collision_radius − 8 m` of the collision focus, with ±4 m
hysteresis on the physics↔snapped switch (N4). Budget overflow demotes the least significant; the
on-screen swap uses visibility-range fade / dither, and **the budget wins over pop
avoidance** (F5). Physics props and moving platforms migrate onto the scheduler (also
fixes the 90 m freeze vs 64 m collision window, F44) and respect `simulate_physics=false`.
Budgets: scheduler + director ≤ 0.5 ms/frame, ACTIVE AI ≤ 1.5 ms/frame (benchmark gate,
F31).

**D6 — Spawning: spawner, zone, group; slots are the runtime unit.**
1. **Spawner** (point; WoW `creature` row): archetype or spawn table, count, wander radius,
   movement (idle / wander / patrol path), respawn time + jitter, group, condition,
   `respawn_visibility`.
2. **Spawn zone** (role on a zone entity, D7): spawn table rows `{archetype, weight,
   group_min, group_max, level_min, level_max}`; `max_alive`; **spawn chance per check**
   and **check interval** (frequency); **initial population** (`full` on first activation
   vs `trickle`); respawn delay; min distance from player (default 30 m); terrain filters
   (slope, altitude, water); time-of-day window; condition; `respawn_visibility`.
3. **Spawn group** (WoW pool): member spawners, `max_alive` (pick N of M), weights
   (explicit first, zero shares the rest), flags `MANUAL` (only scripts/story events spawn
   it), `LINKED_TO` (members wait while a leader is dead). Covers rare+placeholders and
   resource-node rotation.

Slots: id `"<entity_id>#<index>"`. Zone slots are fungible: lowering `max_alive` drops
indices ≥ n, raising adds new ones (tested). Slot state `UNSPAWNED | ALIVE | DEAD(
respawn_at)` plus `last_block_reason` (D15).
- `respawn_visibility`: `any` (spawn in view with fade-in; default for spawners/farms),
  `hidden` (only off-screen and beyond min distance), `hidden_or_timeout(s)` (default for
  zones, 60 s) — no starvation (F17).
- Zone positions come from a **baked candidate set** per zone: Poisson-disk points filtered
  by slope/water/altitude/no_spawn, computed on a worker thread from a height copy, cached
  per zone revision (**baked by the editor into the map** as `zones_cache.bin`; rebuilt at
  runtime only if missing, by the baker in `world/` limited to the zone's AABB height
  window); the inspector shows "usable area x %"; slots pick candidates by seeded
  RNG `Rng.hash3(world_seed, slot_hash, life_count)` (seed from `gen_params.seed` via
  `core/rng.gd`, F43), and back off with a reason when none fits (F18).
- Despawn policy per archetype (F33): `ambient` (records beyond `despawn_radius`, default
  1 km, return to UNSPAWNED and respawn fresh), `persistent` (never despawn). **Unique NPCs** use a
  `unique_npc` kind (stable id = entity id, respawn `never` or timed, STATE persistence)
  (F34). Ambient biome rules (no authored zone) come later as a synthetic zone.

**D7 — Zones are shaped entities with roles.**
Entities gain an optional `shape: {type: polygon|circle|box, points (local XZ), radius,
size, height_min, height_max}`. Kind `zone` carries a list of **roles**: `spawn`,
`no_spawn`, `encounter` (level band locked on first visit, reset policy), later `music`,
`weather`, `trigger` (enter/exit → story event), `name`, `safe`. `priority` and optional
`parent_zone` give a deterministic stack for overlaps (F37). `ZoneIndex` (grid by AABB +
point-in-shape) also accepts **runtime zones** (e.g. a player camp as `no_spawn`, persisted
as dynamic) (F38).

**D8 — Definitions as data registries.**
`assets/data/{creatures,items,loot_tables,factions}.json`, `{schema_version, entries}`,
loaded by `DefRegistry` (id index, validation, defaults, hot reload in the editor, id
aliases `renamed_from` for save compatibility). **Add `assets/data/*` to all four export
presets** and test it (F8). Creature defs: visual, size, health, speed, faction, behaviour
profile, perception/aggro/leash radii, attacks, level scaling, loot table, `xp`,
`skill_xp: [{skill, amount}]`, despawn policy, respawn default, corpse harvest table.

**D9 — AI = small FSM + data reactions, behind an interface.**
`NpcBrain` states `IDLE, WANDER, PATROL, ALERT, CHASE, ATTACK, FLEE, RETURN, DEAD`.
Perception (aggro radius ± level difference, LOS via `WorldQueries.trace`, hearing of shots)
runs at ACTIVE; **being damaged promotes at any tier**. Threat table by attacker id; leash
(distance from home or no progress 8 s) → RETURN (invulnerable, heal, clear threat).
Profiles: `aggressive`, `defensive`, `passive` (flee when hit — farm animals), `skittish`.
Optional `reactions: [{event, condition, chance, action, params}]` per archetype. The brain
only talks to an `NpcContext` (perception, locomotion target, attack, log) so BT/utility
brains can replace it per archetype.

**D10 — Locomotion by collision availability, one body type.**
One pooled `NpcBody` (`CharacterBody3D`) with modes (F24): **physics** (`move_and_slide`)
only while within `terrain.collision_radius − 8 m` of the collision focus; **snapped**
(direct position, Y = max(terrain height, top of static placed geometry from the grid),
water-aware via `water_level_at`) elsewhere; **asleep** when nodeless/hidden (F1, F42).
FAR/DORMANT records move analytically (wander target / patrol distance by elapsed sim
time). `Navigator.path(from, to)` returns a straight line now; per-cell runtime navmesh
later implements the same interface.

**D11 — Damage, traces, corpses.**
- `DamageInfo {amount, kind, impulse, point, hitgroup, source_id}`; `Damageable.apply_damage
  (info)` on NpcBody (→ record), TrainingDummy, PhysicsProp, Player; `apply_hit` kept as an
  adapter during migration. Health lives in the record.
- `WorldQueries.trace(from, to, mask)`: clamps the segment with the terrain intersection,
  then the physics ray; used by hitscan, LOS, spawn visibility, interaction (F3). The
  terrain march is **skipped when the whole segment lies inside the collision radius**
  (physics already covers terrain there); LOS results are cached per pair for 0.2 s; trace
  cost is part of the P1 benchmark (M3/N3). `Hitscan.fire` takes the `WorldSession`
  queries instead of a bare physics space (N9).
- Hitscan also tests **nodeless records** along the ray through `WorldGrid.query_ray`
  (capsule per record, Y snapped to ground at query time); results are **merged with
  physics hits by distance** (a wall in front wins); nodeless hits are body-only, no
  hitgroup multiplier (M4/F4).
- Ragdolls only inside collision range; beyond, a static corpse pose. Corpse lifetime
  (looting/harvest window, 5 min) is separate from ragdoll physics and counts on the same
  "region simulated" counter as loot TTL, so corpse and loot vanish together (F2, N5).

**D12 — Items, interaction, progression.**
- `Inventory` (stacks `{item_id, count}`), `PlayerProgress` (xp, level, `skills` dict); kills
  and harvesting grant `xp` and `skill_xp` from defs. Coins are an item (`coin`).
- Ground items (`ItemRecord` ↔ `WorldItem`) have a **ground policy** from the item def or the
  drop source (F12): `loot` (TTL 5 min, counted only while the region is **simulated** =
  within the FAR radius, 600 m), `player_dropped` (no expiry by default; identical items
  auto-stack; hard cap 256 per region / 4 096 per map with a console warning — beyond it the
  drop is refused with a message, never silently deleted), `quest` (never expires, never
  evicted). The per-region loot cap evicts oldest `loot` only (M6).
- `Interactable` contract (`prompt()`, `can_interact(actor)`, `interact(actor)`, `priority`,
  hold vs tap) + one `InteractionSystem` (focus ray/cone, prompt UI). PropCarrier,
  pickups, chests, corpses (loot/skin), later doors/levers/NPC talk all plug in (F21).

**D13 — Persistence: id-keyed deltas, generational saves, multi-map.**
Layout `user://saves/<slot>/gen_<n>/`:
- `game.bin` — `{format_version, created, sim_time, time_of_day, play_time,
  next_runtime_id, rng_state, dev_modified, player, inventory, progress, story_state,
  current_map_uid}`.
- `maps/<map_uid>/state.bin` — **id-keyed** tables for the whole map (F9): `slots
  {slot_id: {state, respawn_at, life_count}}`, `removed {stable_id: t}`, `modified
  {stable_id: {xform?, state…}}`, `unique {entity_id: {...}}`, `zones {zone_id: {cleared,
  last_visit, level_lock}}`, `map_revision`.
- `maps/<map_uid>/dynamic/r_<rx>_<rz>.bin` — runtime objects by position (ground items,
  runtime zones, player-placed): `{id, type, pos, data, policy, ttl_left}`.
- `manifest.bin` at the slot root, written **last** via temp file + rename, names the
  current and previous generations; if it is missing or corrupt, loading scans `gen_*` for
  the highest generation whose files all validate (each file carries its generation number
  and a checksum). Each save writes a **complete** new generation: loaded maps are
  serialised, maps not loaded this session are byte-copied from the previous generation.
  3 generations are kept; orphaned/incomplete generations from crashes are deleted on the
  next successful save (M5/F10).

Policies are declared per kind/def, never ad hoc: `NONE` (ambient alive NPCs, AI, corpses
after expiry, effects, vegetation, generated city), `STATE` (authored object with mutable
state; moved base physics props store `modified[id].xform`, F35), `TOMBSTONE` (removed base
objects), `DYNAMIC` (runtime-created, with ground policy/TTL/cap), `SLOT` (death +
respawn_at). Live ambient NPC position/health is **not** saved (WoW).

Stable ids: authored = entity id; city = `city:<key>`; vegetation (when harvesting arrives)
= `veg:<asset_id>:<qx>:<qz>` (quantized position) matched to the nearest instance within ε
(F16); runtime = `rt:<next_runtime_id>` (separate from RNG state, F36).

Writing: build a **deep** snapshot of primitives on the main thread (F11), serialise with
`var_to_bytes` (no objects) on one `WorkerThreadPool` task (queued, single writer), flush
synchronously on quit (`auto_accept_quit = false`). Autosave every 5 min, on map change,
on sleep. `SaveMigrations` chain per format version. Map revision changed: load, drop
deltas whose ids are missing (warning listed in the console); entity moved after save keeps
its state (id-keyed). Missing map: offer to load another save. Cheat commands set
`dev_modified`.

**D14 — Two clocks.**
`SimClock`: monotonic play seconds, only advances while playing (and on explicit skips);
all persisted timers (`respawn_at`, TTL counters, resets) use it. `TimeOfDay`: its **own
accumulator** (saved), advanced each frame by `dt × day_speed`, so changing the day length
never jumps the clock or touches timers. Commands: `time <hh:mm>` / `time +<h>` change only
the time of day; `skip <h>` (and sleeping/waiting) advances both clocks (F13). Fast-forward uses
`sim_time − last_tick`, capped and analytic.

**D15 — Debug drawing, "why" model and console — shared by editor and game.**
- `DebugDraw` (batched `ImmediateMesh` + pooled, distance-culled `Label3D` ≤ 64 within
  150 m): line, polyline, circle (draped), polygon fill (cached draped mesh keyed by entity
  revision, depth offset), sphere, box, arrow, text; per **channel**: `zones`, `spawns`,
  `ai`, `cells`, `nav`, `physics`, `items`, `persistence` (F39). Systems implement
  `debug_draw(dd, channel)`; editor gizmos call the same functions → identical visuals.
- **Why**: each slot keeps `last_block_reason` (`cap`, `visible`, `too_close`, `condition`,
  `terrain`, `time_window`, `group_limit`, `linked`); each brain keeps a ring buffer of
  `{t, from, to, reason}`; items record expiry reasons. The `spawns` channel colours slots
  by state/reason and shows respawn countdowns; `ai` shows tier, state, target line,
  aggro/leash rings (F19).
- `Console` (game + Simulate, F28): toggle on physical backquote and F1; opening releases
  the mouse and sets `Player.input_enabled = false` (gates polling) (F22). Commands are
  registered by services: `show/hide <channel|all>`, `info` (pick: node, or nodeless via
  grid), `why <id>`, `spawn <archetype> [n]`, `kill radius <m>`, `respawn [zone|all]`,
  `time +<h>`, `skip <h>`, `tp`, `save`, `load`, `save_dump`, `god`, `ai freeze`,
  `timescale`. Gating: `OS.is_debug_build()` or `OS.has_feature("level_editor")` (the editor
  export is a release build) always; game release builds only with `--dev` after the `--`
  user-args separator (`OS.get_cmdline_user_args()`) or a hidden settings toggle (N6). Overlays default: editor on (`zones`, `spawns`),
  game off.

**D16 — Editor Simulate mode.**
Toggle in the World Editor: ephemeral `GameSession` + `WorldSession` focused on the
**ground point under the camera** or a placeable test pawn (XZ distance), and Terrain3D's
collision focus is moved to that point (`set_focus`) for the duration (F20); runs clock,
spawning, NPCs; debug channels + console; editing is locked while simulating (or the
session restarts on change); nothing marks the map dirty; physics props stay frozen.
Stop tears everything down.

**D17 — Data-model and dispatch upgrades.**
- `map.json` gains `map_uid` (created by New Map; kept by Save; **Save As asks** "same
  map (keep id) / copy (new id)"), `revision` (increments per save) and `lineage` (recent
  `[uid, revision]` history). The game warns when a save's revision is newer than the
  map's or its lineage doesn't match; a duplicated uid (folder copied in Finder) is
  detected by the editor's recent list and the user is asked to re-id one (M7/F15). MapIO schema v2 with a real migration
  pipeline; ints coerced from the kind schema; every entity normalised to have `asset`
  (`""` allowed) (F23).
- Runtime `KindRegistry` in `world/`: kind → runtime builder, persistence policy,
  debug_draw, schema. `editor/` registers `KindEditorExt` (gizmo, inspector extras, tool
  hooks) at startup. Catalog `gameplay` entries map to kinds through an adapter (F7).
  **Headless test: all `world/ game/ core/ addons/` scripts compile with `editor/`
  and `worldgen/` hidden.**
- Prop types: `enum`, `ref` (registry picker) in P0; `table`, `entity_ref`, `condition`,
  `range`, `color` in P3 (F25). `condition` reuses the story_graph condition editor with
  event ids from a project-level story graph path setting (F41) — the same exported
  setting the GameSession uses to initialise `StoryState` defaults (N7).
- Select tool rotation/scale go through undo; drags commit once on release (F40).

## 3. Authoring UX (World Editor)

- **Zone tool**: polygon (click points, Enter closes, Backspace removes last — consumed by
  the tool before the select tool's delete, F45), circle, box; vertex/edge handles with
  Alt-click insert; one undo step per drag. Picking zones/paths is **non-physics**
  (terrain hit → point-in-shape, smallest area wins; screen-space handle picking) (F23).
  Fill draped on terrain, outline, name label, role colours; selected zone shows its
  candidate points, slot preview and "usable area / density".
- **Spawning** category in Place: spawner, unique NPC, group marker. Gizmos: wander circle,
  aggro/leash rings, lines to path and group members.
- **Path tool**: polylines with per-point wait, direction arrows.
- **Inspector**: typed editors (D17); spawn-table rows; condition editor; inline problems.
- **Validation** panel: missing defs/refs, spawners in `no_spawn`, empty tables, groups
  without members, broken paths, usable area 0 %, max_alive above density sanity.
- Tool palette goes beyond 9 hotkeys (F40). View menu: per-channel toggles. Simulate.

## 4. Runtime flow (game)

1. `world_game` creates `GameSession` (load or new save), `WorldView` + `WorldSession`,
   loads defs, the map, and `maps/<uid>/state` → `WorldState`. Player position from the
   save if present, else spawn point.
2. `SpawnDirector.build()` creates slot records from spawners/zones/groups and applies saved
   slot states; `EntityLayer` applies `removed`/`modified` while building.
3. Every 0.25 s: scheduler re-scores; director checks slots in cells ≤ 250 m on their
   interval: dead past `respawn_at` + rules pass → spawn (fade-in if visible); else record
   the block reason.
4. Death → record DEAD; ragdoll or corpse pose; xp/skill xp; loot roll → ground items
   (`loot` policy); slot `DEAD(respawn_at)`.
5. Ambient records beyond DORMANT range despawn to UNSPAWNED; persistent/unique records
   stay and fast-forward.
6. Save → deep snapshot → worker write → manifest.

## 5. Phases

| Phase | Content | Done when |
|---|---|---|
| **P0 Foundations** | MapIO v2 (migrations, int coercion, `map_uid`/revision/lineage, `asset` normalise); runtime KindRegistry + editor ext hook; WorldView-owned DebugDraw/WorldGrid/authored ZoneIndex; WorldSession attach/detach; GameSession + persistent `world_game` host (map swap, flush on exit); SimClock/TimeOfDay; `WorldQueries.trace` (hitscan switched to it); Console with input gating; DefRegistry + export filter; `enum`/`ref` props; undo fixes | 66 existing tests pass; migration tests; "no editor/" compile test; **editor gizmos drawn with no session**; console + overlay smoke shots; shots blocked by hills beyond 64 m |
| **P1 NPC runtime** | NpcRecord/NpcBody (pooled, modes)/NpcBrain/locomotion; SimScheduler (multi-focus, fades, budgets; props + platforms migrated); Damage contract + nodeless hit fallback; corpses; InteractionSystem; inventory, items on ground, xp + skill xp; point Spawner + slots + respawn policies; block reasons + brain log + `info/why` | test course: wander radius, aggro/chase/leash/return, passive flee, kill → loot/xp/respawn after `skip`; tier changes under budget; shots at 200 m blocked by hills; benchmarks: 1 000 records, ACTIVE AI ≤ 1.5 ms |
| **P1.5 Simulate** | editor Simulate mode (ground focus/test pawn, edit lock) | editor smoke: place spawner → simulate → see NPCs + gizmos |
| **P2 Persistence** | SaveService (generations, manifest, worker), WorldState tables, policies, dynamic regions, ground-item policies, unique NPC state, migrations, save UI (slots, continue), `save/load/save_dump` | round-trips: dead slot until respawn, player-dropped item stays, loot expires only while simulated, entity moved across regions after save, max_alive lowered/raised, crash mid-save falls back, map revision change |
| **P3 Zones** | zone kind + roles + tool, non-physics picking, candidate bake, zone spawning (frequency, initial population), groups/pools/linked, paths/patrols, `table/entity_ref/condition` editors, validation | editor: draw → preview → simulate; runtime: density, exclusion, rares via pools; P2 round-trips with zone slots |
| **P4 Ambient & content** | biome ambient rules, time-of-day windows, story conditions/events, reactions, threat/assist, corpse harvesting/skinning, runtime no_spawn zones, vegetation tombstones | scenario tests |
| **P5 Navigation** | per-cell runtime navmesh near the player behind `Navigator` | NPCs path around buildings |

Every phase: docs updated (ARCHITECTURE + USER_GUIDE), tests green, windowed smoke
screenshots inspected.

## 6. Budgets

≤ 2 000 NPC records per map; ≤ 24 ACTIVE / ≤ 64 NEAR nodes; scheduler + director
≤ 0.5 ms/frame; ACTIVE AI ≤ 1.5 ms/frame; debug off = zero ticking; save snapshot ≤ 50 ms
main thread, typical save ≤ 1 MB.

## 7. Risks and open questions

- Straight-line locomotion until P5: NPCs walk into buildings (mitigated by building-AABB
  avoidance in the grid) and through scattered rocks/trees (no collision there anyway).
- Snapped NPCs beyond 64 m can't use physics; acceptable because nothing physical happens
  out there (ragdolls become corpse poses).
- Vegetation harvesting depends on quantized-position ids surviving re-scatter; verify
  before P4.
- Defaults chosen without asking (changeable later): game time does not pass while the game
  is closed; ambient mobs respawn fresh after reload; player-dropped items never expire.
