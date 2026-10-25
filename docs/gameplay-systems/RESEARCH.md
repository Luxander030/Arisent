# Research: spawning, distance-adaptive NPC AI and world persistence

How World of Warcraft (and comparable games) do it. Gathered 2026-10-22 as input to
[PLAN.md](PLAN.md). Confidence tags: **[doc]** = emulator source/docs, official docs or
wikis describing observed behaviour; **[recall]** = well-known but not re-fetched;
**[spec]** = inference. WoW server internals are known through reverse-engineered emulators
(TrinityCore, AzerothCore, CMaNGOS), not Blizzard's code.

---

## 1. Zoning and spawning

### WoW: space
- Each continent (map) is a 64×64 array of **grids** of 533.33 yd, each 8×8 **cells** of
  ≈66.7 yd (TrinityCore `GridDefines.h`) [doc]. Terrain tiles (ADT) use the same grid; every
  ≈33 yd terrain chunk stores an **AreaTable id** [recall]. "Which subzone am I in" is a
  per-chunk lookup, not a polygon test. `AreaTable` rows have a ParentAreaID (subzone → zone).
- Grids **load when a player (or an "active" creature) comes near** and unload after
  `GridCleanUpDelay` = 5 min without players; `MapUpdateInterval` 10 ms; visibility 100 yd on
  continents [doc: worldserver.conf.dist]. Making NPCs "active" keeps grids loaded forever —
  reserved for escorts.

### WoW: spawn records (emulator DB schema)
| Table | Role |
|---|---|
| `creature_template` | archetype: name, level range, faction, rank (normal/elite/rare/boss), AI name, loot ids, gold range |
| `creature` | one placed spawn: template, position, phase, `spawntimesecs` (default 120), `wander_distance` (default 5), `MovementType` 0 idle / 1 random / 2 waypoints [doc] |
| `creature_addon` | per-spawn path id, mount, emote, auras |
| `waypoint_data` | path points with delay, walk/run, action |
| `creature_formations` | leader + member (distance, angle), assist flags |
| `linked_respawn` | "doesn't respawn while X is dead" (boss trash) |
| `pool_template` / `pool_creature` / `pool_pool` | **pick N of M**: `max_limit` alive members, per-member chance; nested pools; explicit chances first, zero-chance members share the rest [doc] |
| `spawn_group_template` | flags: MANUAL_SPAWN (scripted waves), DYNAMIC_SPAWN_RATE, ESCORT, DESPAWN_ON_CONDITION_FAILURE [doc] |
| `game_event_*` | spawns tied to timed/holiday events (negative id = despawn during event) |

- A WoW "spawn area" is just **point + wander radius**. Pools give variety: herb/ore nodes
  (many points, few alive), **rares sharing a pool with placeholders** (kill placeholder →
  pool re-rolls).
- **Dynamic respawn** (TrinityCore, off by default): respawn shortened by players in zone
  (≈ `respawn × rate / players`, floor 10 s) [doc-ish]. Retail adds sharding/CRZ; Classic
  used whole-realm **layering** [doc].
- Phasing: conditions (quest state, area) select which spawns a player sees.
- **Authoring**: Blizzard's internal "WoWEdit" is not public. Emulators author spawns
  **in-game with GM commands** that write straight to the DB: `.npc add/move/delete`,
  `.npc set wanderdistance/spawntime/movetype`, `.npc info`, `.wp add/show` (waypoints shown
  as visible markers), `.gobject add`, `.debug boundary`, `.mmap path` [recall]. Debug views
  are ordinary entities made visible.

### Other games
- **Minecraft**: no authored spawns; rules evaluated in a ring around the player — no spawns
  within 24 blocks, despawn beyond 128, random despawn beyond 32; category caps (monsters 70
  per 17×17 chunks) [doc].
- **Valheim**: 64 m zones; each zone's `SpawnSystem` ticks every 4 s with ordered checks —
  biome, interval, chance, global progression key, weather, day/night, max spawned, random
  point near a player within altitude/tilt/ocean-depth/forest limits, min distance from
  player, **not inside a player base**; group size min..max. Plus authored `CreatureSpawner`s
  in locations and destructible `SpawnArea`s (nests) [doc]. A clean three-way split.
- **Bethesda Creation Kit**: leveled actor markers using **leveled lists**; **Encounter
  Zones** (min/max level, "Never Resets") lock their level on first visit [doc/recall].
- **Source**: `npc_template_maker` (max count, frequency, max live, "don't spawn while
  visible", radius) [recall].
- **GW2 / FFXIV**: dynamic events / FATEs are state machines that own their spawns (like
  MANUAL_SPAWN groups) [recall].
- **OSRS** item spawns respawn on timers, halved on full worlds [doc].

## 2. NPC AI that adapts to distance ("AI LOD")

### WoW
- Coarse LOD = grid loaded or not. Three effective tiers: not loaded (doesn't exist),
  loaded but unobserved (timers only), within a player's visibility (full AI) [doc].
- **Aggro** ≈ 20 yd base, ±1 yd per level difference, clamped 5–45 yd [recall]; assist
  radius; **threat table** (switch target at 110 % melee / 130 % ranged of current threat).
- **Leash / evade**: target unreachable, too far from home, or no progress → run home,
  immune, full heal, threat cleared [recall]. Retail leash ≈ 40–60 yd [spec].
- Movement: idle / random within wander radius / waypoint path; formations follow a leader.
- **SmartAI**: a data table of `event → action` rows (timers in/out of combat, health %,
  aggro, death, evade, waypoint reached…; cast, talk, summon, move, flee…) with phase masks
  — a data-authored FSM. Bosses use code with an EventMap timer queue [recall].
- Corpse lifecycle: corpse 300 s (×0.5 once looted) → despawn → respawn timer (saved) →
  respawn at spawn point (pool re-rolls) [doc].
- **Loot** (`*_loot_template`): ungrouped rows roll independently; **groups drop exactly one
  row**; **reference** tables share pools ("level 30–35 world drops"); quest-only rows;
  min/max counts; gold from template. Skinning = second table on the corpse; herbs/ore are
  game objects with pooled spawns. Loot tagging by first attacker [doc].

### AI LOD literature
- **Unreal Significance Manager**: per-object significance function (distance, visibility…)
  + budgets ("N AIs at high detail"); each system downgrades itself [doc]. Mass Entity LOD
  processors (High/Medium/Low/Off) and representation LOD (actor ↔ instanced mesh) [recall].
- **Assassin's Creed Unity**: ~10 000 crowd agents with ~40 full AIs and ~120 high-res
  models, swapping representations unnoticed [doc: GDC].
- **Kingdom Come: Deliverance 2**: ~2 400 scheduled NPCs at 60 fps; behaviour scripts are
  unaware of the LOD system [doc: GDC].
- **Source**: efficiency levels (normal → dormant) and sleep states ("waiting for PVS")
  stretch think intervals [recall].
- **Bethesda**: loaded 5×5 cells run full AI ("high process"); unloaded actors are
  re-positioned by schedule when their cell loads [recall].

Consensus tiers:

| Tier | When | Update | Runs |
|---|---|---|---|
| Full | < ~40–60 m, on screen or in combat | every tick | perception, decisions, steering, physics, animation |
| Reduced | ~60–150 m | 2–10 Hz round-robin | decisions at low rate, simple movement |
| Abstract | loaded, far | 0.1–1 Hz | position along schedule/path only; no physics/animation/node |
| Dormant | unloaded | none | serialized state + timestamp; **fast-forward analytically on wake** |

Avoid pop-in: change tiers out of view, **hysteresis** (10–20 %) between promote/demote,
never spawn within view or a minimum distance. For WoW-style mobs a **small FSM**
(idle/wander/patrol → combat → evade → dead) plus an event→action table is the best fit;
behaviour trees for bosses/companions; utility AI for needs-driven villagers; GOAP only for
a few high-value agents.

## 3. Persistence: what to remember, what to regenerate

- **WoW**: persists characters, corpses, instance lockouts, world/event states, and
  **respawn timestamps** (`creature_respawn` / `respawn`: spawn id, respawn time). Live mob
  position, health, threat and corpse loot are **memory-only**; after a restart every spawn
  without a pending respawn appears fresh. Runtime-summoned GUIDs run out
  (`Respawn.GuidAlertLevel`) — **authored spawns need stable ids, runtime objects separate
  ids** [doc].
- **Bethesda**: the save stores *change forms* (deltas) over immutable plugin data. Cells
  reset after 10 game days (30 when cleared); the timer restarts on each visit; "Never
  Resets" zones and homes don't. Resets restore actors, containers, clutter, harvestables —
  **but items the player dropped are never cleaned**, so every dropped or physics-pushed item
  becomes a permanent record → **save bloat** [doc: UESP].
- **OSRS ground items**: private 60 s, then public 120 s, then gone; untradeables 180 s
  (paused while logged out) — dropped items are **TTL objects with visibility phases** [doc].
- **Minecraft**: generated chunks saved in full once generated; entities in separate region
  files; every record has a `DataVersion` and is migrated on load; items despawn after 5 min
  of *loaded* time; only "persistent" mobs survive [recall/doc].
- **Valheim ZDOs**: per-object key/value records separate from scene objects; zones are
  generated once and their objects stored → world files grow; mods exist to reset/regrow
  zones [doc/recall].
- **No Man's Sky**: everything from a seed; player edits stored as a (capped) delta list
  replayed over generation [doc/spec].

**The general pattern** — base + delta:
1. Base = authored data + deterministic generation (seed, coordinates, generator version);
   never saved.
2. Delta = sparse `stable_id → change`. Authored objects: editor id. Generated objects:
   hash(seed, cell, generator, index). Runtime objects: a new id from a saved counter.
3. **Tombstones** for removed base objects so regeneration doesn't resurrect them.
4. Dynamic objects (dropped items, placed objects) get full records.
5. **Chunked saves** (per cell/region), dirty flags, write-behind, autosave on an interval
   and key events, atomic temp-file + rename.
6. **Versioning**: format version on the save, migrations on load.
7. **TTL / GC** for transient-but-saved objects (dropped junk, corpses), cell reset bands.
8. Caps per cell against bloat; save physics-moved objects only when settled and only on
   unload/save, never per frame.

## 4. Editor vs runtime, and debug views in shipped games

- WoW: GM commands on the server, permission-gated; debug views are entities made visible.
- Bethesda: PC console — `tcl`, `tai`, `tdetect`, `tm`, `tfc`, `ResetInterior`, `pcb`.
- Unreal: `show` flags, Gameplay Debugger, Visual Logger (scrub recorded shapes over time);
  stripped from Shipping builds.
- Source: `developer` cvar, `ai_show_*`, `sv_cheats`-gated commands.
- Minecraft: F3 screen, F3+B hitboxes, F3+G chunk borders; commands need cheats/operator.

Takeaways: **one data model for editor and runtime**; the **same gizmo code draws in both**;
debug overlays off by default in the game, toggled from a console; inspection commands
modelled on GM commands (`info`, `spawn`, `respawn`, `time +Nd`, `save_dump`).

## Sources (selection)
- TrinityCore: [GridDefines.h](https://trinitycore.net/d7/d34/griddefines_8h_source),
  [map.cpp](https://trinitycore.net/d3/d92/map_8cpp_source),
  [worldserver.conf.dist](https://raw.githubusercontent.com/TrinityCore/TrinityCore/master/src/server/worldserver/worldserver.conf.dist),
  [spawn_group_template](https://trinitycore.info/database/master/world/spawn_group_template),
  [respawn](https://trinitycore.atlassian.net/wiki/spaces/tc/pages/1151238145/respawn)
- AzerothCore wiki: [creature](https://azerothcore.org/wiki/creature),
  [pool_template](https://www.azerothcore.org/wiki/pool_template),
  [pool_pool](https://www.azerothcore.org/wiki/pool_pool),
  [loot_template](https://www.azerothcore.org/wiki/loot_template)
- [Minecraft wiki: Mob spawning](https://minecraft.wiki/w/Mob_spawning);
  [Valheim modding wiki: Spawning](https://github-wiki-see.page/m/Valheim-Modding/Wiki/wiki/Spawning);
  [Valheim Zones](https://valheim.fandom.com/wiki/Zones)
- [UESP: Skyrim Respawning](https://en.uesp.net/wiki/Skyrim:Respawning);
  [Dynamic items and savegame bloating](https://cs.uesp.net/wiki/User:QQuix/On_Dynamic_Items_and_Savegame_Bloating)
- [OSRS wiki: Drop](https://oldschool.runescape.wiki/w/Drop),
  [Item spawn](https://oldschool.runescape.wiki/w/Item_spawn)
- [Unreal Significance Manager](https://dev.epicgames.com/documentation/en-us/unreal-engine/significance-manager-in-unreal-engine);
  [Massive Crowd on Assassin's Creed Unity (GDC)](https://gdcvault.com/play/1022141/Massive-Crowd-on-Assassin-s);
  [Thousands of NPCs in Kingdom Come: Deliverance (GDC)](https://schedule.gdconf.com/session/supporting-thousands-of-npcs-in-kingdom-come-deliverance-kingdom-come-deliverance-ii/915120);
  [Brom et al. 2007, simulation LOD](https://artemis.ms.mff.cuni.cz/main/papers/IVE_IVA07.pdf)
- [Blizzard: Classic layering](https://www.wowhead.com/news=294589/blizzard-clears-up-layering-tech-misconceptions-in-classic-wow)

Known gaps: Blizzard's own code/editor, exact retail leash distances and patch history of
dynamic respawn are not public; Bethesda/Valheim/NMS save internals come from community
reverse engineering.
