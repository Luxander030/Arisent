# Owner decisions — gameplay systems

Decisions taken by the project owner. They override defaults in [PLAN.md](PLAN.md).

| Date | Topic | Decision | Where it lives |
|---|---|---|---|
| 2026-10-22 | Format migrations | None during development. Maps (`schema_version` 2) and saves (`format_version` 1) of another version are refused with a clear message; old maps are re-created. | `MapIO.load_map`, `SaveService.load_save` |
| 2026-10-22 | Time while the game is closed | No time passes. Respawns, expiry and decay use play time (`SimClock`) only. | `world/session/sim_clock.gd` |
| 2026-10-22 | Items on the ground | Expire after **one hour** of play wherever they lie, so nothing piles up in memory or in saves. Spilled loot after 5 minutes; quest items never. | `ItemWorld.DROPPED_TTL` / `LOOT_TTL` |
| 2026-10-22 | Loot | **WoW-style: loot stays on the corpse.** "Loot" opens the corpse's loot window (Take / Take all, E takes all, money is always taken). Corpses decay after 5 minutes (2.5 once emptied); skinning only after looting. Corpses with loot are saved until they decay. | `NpcManager.take_loot`, `GameHud` loot window |
| 2026-10-22 | Experience | Total XP for level L = **`base · L · (L − 1) / 2`**, base 100 for the character, 50 for skills. | `PlayerProgress.xp_for` / `level_for` |
| 2026-10-22 | Death | **No death penalty for now**: the player respawns at the spawn point after 3 seconds with nothing lost. Revisit later. | `game/world_game.gd` `_on_died` |
| 2026-10-22 | Spawning and view | **Nothing ever spawns inside the player's field of view.** A spot is "in view" when it is inside the camera frustum and within 230 m (the distance creatures get a body and fade in). Spawn checks reach 300 m, so things farther out appear as data and fade in as you approach; nearer spots wait until you look away. Only the first population while a map loads is exempt. Applies to spawners, zones and ambient wildlife; the per-spawner "respawn visibility" option was removed. | `WorldSession.in_view`, `SpawnDirector._view_block` |
| 2026-10-22 | Day and night | The sun, sky, ambient light and fog follow the in-game clock, so night-only spawns happen in the dark. One day = 48 real minutes. The editor works at 10:00 except in Simulate. | `WorldView.set_time_of_day` |
| 2026-10-22 | Simulate pawn | Both: by default a stand-in pawn stands under the middle of the screen; **F6 (Play → Drive the pawn)** lets the designer drive it like the player (WASD, Space, Shift, Ctrl; the camera follows, right mouse turns it). The pawn can't be hurt. | `editor/simulate_mode.gd` |
| 2026-10-22 | Story graph | Keep the tavern example (`res://stories/example_story.tres`) as the project's story graph for now, as a demo; it will be replaced by the real story later. | Project Settings `lux/story/graph_path` |
| 2026-10-23 | Skill tree data | The project's skill tree is the file the owner added, `res://Arisent-DEMO.json` ("skill-tree" format, version 1; other versions are refused, no migrations). Its path is Project Settings `lux/skills/tree_path` (default that file); it is in the export include filters. | `SkillTree` |
| 2026-10-23 | Skill tree prerequisites | A skill reached from several skills needs **all** of them learned (e.g. Magical Reserves M-001 needs both Unbounded Counter ME-004-1 and Charged Spin Attack ME-004-2). A skill nothing leads to is free to learn first (in the demo only Strike). | `SkillTree.is_unlocked` / `missing` |
| 2026-10-23 | Skill tree saving | Learned skills are saved on the player **by node id, never by name**: `progress.tree = {id: rank}`. If a saved id is no longer in the tree (or a rank is above its max), it is dropped or clamped when the save loads and its points come back. | `PlayerProgress.tree_ranks`, `SkillTree.sanitize` |

## Skill tree — choices made while building it (open for the owner to change)

| Date | Topic | Choice | Where it lives |
|---|---|---|---|
| 2026-10-23 | Where points come from | **2 skill points per character level** after the first (level 5 → 8 points), plus points granted by the console or, later, quests. Free points are always computed (earned − spent), never stored. | `PlayerProgress.SKILL_POINTS_PER_LEVEL` |
| 2026-10-23 | Cost | `cost` is paid **per rank**; `maxRank` caps it. | `SkillTree.why_not` |
| 2026-10-23 | Refunds | No refunds in the screen (learning is permanent); `/skilltree reset` forgets everything for testing. A respec item or NPC can come later. | `PlayerProgress.reset_tree` |
| 2026-10-23 | Opening it | **K** (input action `skill_tree`) or `/skilltree open`; Esc or K closes. The game keeps running (like the bag) but the player stops; the mouse is freed. | `GameHud.toggle_skill_tree`, `SkillTreePanel` |
| 2026-10-23 | Effects | Learning a skill records its rank only; what each skill does in combat is not implemented yet. Gameplay code asks `game.progress.tree_rank("ME-002")`. | — |

## Developer console port — choices made during the port (open for the owner to change)

The Ares Last Light console was ported as faithfully as Godot allows (see
[ARCHITECTURE §15](../world-editor/ARCHITECTURE.md)). Where the port had to choose, it chose:

| Date | Topic | Choice | Where it lives |
|---|---|---|---|
| 2026-10-23 | Command prefix | Typed lines need `/` (as in Ares); plain text is echoed, with a hint when its first word is a command. Scripted `run()` (tests, bindings, `/exec`) also accepts the bare form. | `ConsoleModel.execute` / `run` |
| 2026-10-23 | Lux command set | Ares's game commands (worlds, servers, calendar, Mars clock, sprite sheets) were replaced by Lux's: time/day, story, bag, skills, loot, audio, content, creatures, spawners, navigation, zones, items, saves, player cheats (god, notarget, noclip, heal, ammo). Old names kept where they fit; actions with several modes became verb tables (`/time set`, `/saves dump`, `/camp make`, `/npcs stats`, `/spawner respawn`). | `GameCommands`, `WorldCommands`, `NpcManager`, `SpawnDirector`, `world_game` |
| 2026-10-23 | `/sleep` | Renamed `/delay <seconds>` (real seconds): in an RPG "sleep" should mean passing game time, which is `/skip`. | `ConsoleModel._cmd_delay` |
| 2026-10-23 | Bindings, history | Session only, as in Ares (not saved). | `ConsoleModel._bindings`, `ConsoleHistory` |
| 2026-10-23 | Window size and zoom | Saved in `user://settings.cfg [console]`. Text is 16 px (Ares: 26 px at its pixel scale); zoom 75 %–300 %. | `ConsoleWindow`, `DebugZoom` |
| 2026-10-23 | Input field | A Godot `TextEdit`, so selection, copy/paste and undo work (Ares has none of them); the log is selectable, and Cmd/Ctrl+C copies its selection. | `ConsoleWindow` |
| 2026-10-23 | Engine output | Godot's own `print`/warnings/errors appear in the console (as Ares does with Unity's log), timestamped. `/log level warn` hides the chatter. | `ConsoleLogger` |
| 2026-10-23 | Monitor panels | Render (Shift+1), World (Shift+2), System (Shift+3), Player (Shift+4); Shift+` toggles all. Ares's Network panel has no Lux equivalent. | `MonitorPanels`, `/monitor` |
| 2026-10-23 | Not ported | Exception reports ("… threw …": GDScript has none), Perfetto `/trace`, `/font`, `/netinfo`, `/haptics`, the per-cell pixel reveal (a fade and slide instead), inline sprite previews. | — |

## Ported enemies — choices made during the port (open for the owner to change)

See [ENEMIES.md](ENEMIES.md).

| Date | Topic | Choice | Where it lives |
|---|---|---|---|
| 2026-10-23 | Which 10 | Shadow Imp, Armored Beetle, Gloom Weaver, Elf, Stone Golem, Void Stalker, Iron Golem, Nightmare Shade, Drow Elf, Blood Bat: everything in the web game below level 12 that is not a mini-boss, elemental, boss or special encounter. | `tools/port/basic_enemies.py` |
| 2026-10-23 | Stat conversion | Each keeps its ratio to the Shadow Imp (power 0.6) on a Lux per-level baseline fitted to the wolf/bandit/dire wolf; no hit over 35. Copying the ratios 1:1 made golems 600 HP bullet sponges hitting for 90 against a 100 HP player. | `basic_enemies.py` `RATIO_POWER`, `baseline()`, `MAX_HIT` |
| 2026-10-23 | Where they appear | Not added to ambient (biome) spawning — that is one rule per biome and would replace the wildlife. They are available for spawners, zones and encounters in the editor, and `/spawn`. | — |
| 2026-10-23 | Sanity, elf/drow feud | Kept as data (`sanity_damage`, faction hostility) until Lux has a sanity system and creature-vs-creature fights. | creatures.json, factions.json |
| 2026-10-23 | Gems, Iron Bar | The source's gem drop uses Lux's ruby; refining Chunk of Iron into an Iron Bar (needs Fireball) is not ported. | loot_tables.json |
| 2026-10-23 | Looks | Placeholder bodies (humanoid or four-legged, size and colour per enemy); the Blood Bat is a tiny four-legged body until creatures can fly. | creatures.json |

## Player facing

| Date | Topic | Choice | Where it lives |
|---|---|---|---|
| 2026-10-24 | RPG-style facing | The model turns to run the way you steer (camera-relative WASD), with any weapon; it faces the camera's aim only while aim is held (right mouse / left trigger) or for 0.8 s after an attack. Holding a gun used to keep it facing the camera, so A/D slid it sideways playing the forward run, which looked broken. Movement physics (CS-style, air strafing) are unchanged; only the model's facing and the raised-gun pose (now only while aiming or standing) changed. | `Player._facing_target`, `TURN_RATE`, `AIM_HOLD`; `PlayerAnimator` stance; `InputSetup` "aim" |

## Performance pass (see ARCHITECTURE §18)

| Date | Topic | Choice | Where it lives |
|---|---|---|---|
| 2026-10-24 | Adaptive quality | The game's Adaptive mode now also lowers the 3D render resolution (FSR 1 upscaling, down to 60 %) and switches SSAO off before it shortens draw distances; with vsync it probes upward after calm stretches. On this M2 it settles at full detail with 80 % resolution. Fixed presets keep full resolution. | `LodController.LADDER` |
| 2026-10-24 | Terrain shader | The game uses a runtime-patched copy of Terrain3D's shader: material blending between the four nearest cells only within 40 m × detail (dithered single-cell pick beyond). The editor keeps Terrain3D's own shader. | `Terrain3DBackend.optimize_shader` |
| 2026-10-24 | City LOD1 | Per-building nodes instead of merged chunks (the chunks drew ~4 M hidden triangles); houses hidden behind other houses are culled (occluder boxes inside walls). Rare see-through-two-windows cases may hide what's behind a house. | `CityView` |
| 2026-10-24 | Not done | Terrain (hill) occluders: little gain in measured views, real CPU cost. Dual scaling and slope projection stay on (1.3–3.6 ms each) — they're visible quality; candidates for a lower preset. | — |
| 2026-10-24 | Graphics settings | Main menu Options and an in-game pause menu (Esc with the mouse free; it used to leave straight to the main menu). Quality Adaptive (default) / Ultra / High / Medium / Low, Adaptive's lowest resolution (default 60 %), presets' resolution, vsync, frame-rate cap, full screen, FPS counter. The game pauses while the menu is open. | `GraphicsSettings`, `SettingsPanel`, `PauseMenu` |
| 2026-10-24 | Medium / Low terrain | Owner left it to me: Medium and Low drop the terrain's dual-scale texturing and slope projection (1.3–3.6 ms each); Adaptive keeps them (switching recompiles the terrain shader, a visible hitch). | `GraphicsSettings.apply_world` |
