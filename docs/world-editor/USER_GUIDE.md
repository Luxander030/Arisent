# World Editor — User Guide

## Running it

| What | How |
|---|---|
| Editor (development) | `tools/run_editor.sh` (or open the project in Godot and run `res://editor/editor_main.tscn`) |
| Game on your latest map | Run the project normally → **Start**. It plays the map passed with `-- --map <folder>`, else `res://maps/default.luxmap`, else the editor's most recent map |
| Tests | `tools/run_tests.sh` (headless; add a filter word, e.g. `tools/run_tests.sh city`) |
| Visual smoke tests | `godot --path . --script res://tests/smoke_editor.gd -- <out_dir> [size_km]` (also `smoke_world.gd`, `smoke_game.gd`, `smoke_terrain3d.gd`) |
| Separate executables | Project → Export: presets **Game** and **World Editor** for macOS and Windows. The editor preset adds the `level_editor` feature, which switches the main scene and app name |

macOS: unsigned builds are blocked by Gatekeeper the first time — right-click → Open, or run `xattr -cr "Lux's RPG World Editor.app"`.

## Making a map

1. **New Map…** (start screen or File menu, ⌘N).
2. Set a name, size (2 / 4 / 8 km) and a **seed** — any word or number. The same seed with the same settings always gives the same map.
3. Tick the biomes you want and move the sliders. The preview on the right updates within a fraction of a second, then sharpens. North is up; the orange ring is the city and the dark ring inside it the old town wall.
4. **Generate map**. A 4 km map takes ~25 s on an M2 (terrain, textures, water, city, ~100k plants).

## Detail level (performance)

**View → Detail level**: Low / Medium / High / Ultra, **Adaptive** (lowers or raises detail to keep
the frame rate up; the status bar shows the current detail ×, and says when it's holding because
lowering detail wasn't helping) or **No LOD** (everything at full detail — for comparison only).
Objects switch between a full model, simplified models and — for trees — flat "impostor" cards as
they get further away; the detail level stretches or shrinks all those distances.

After adding or changing a model, rebuild its detail levels:
`godot --path . --script res://tools/lod/build_lods.gd` (≈10 s, opens a small window).
Check them with `godot --path . --script res://tests/lod_sheet.gd -- sheet.png`.

## Moving around

- Hold **right mouse** + **WASD** to fly, **Q/E** down/up, **Shift** fast, mouse wheel (while holding right mouse) changes speed.
- Mouse wheel without right mouse: move forward/back.
- Click the **minimap** (top right) to fly there.

## Tools (number keys 1–9)

| # | Tool | Use |
|---|---|---|
| 1 | Select | Click an object or city building. Drag to move, `,` `.` rotate, Delete removes. Deleted city buildings stay deleted even after regenerating |
| 2 | Sculpt | Raise / Lower / Smooth / Flatten / Holes. Shift = opposite. `[` `]` brush size, `-` `=` strength. Ground textures update automatically (steep → rock) |
| 3 | Paint | Paint a ground texture (Replace or Blend on top). Painted spots are remembered and never overwritten automatically. Shift erases back to automatic |
| 4 | Vegetation | Paint More / Less / Remove / Reset for trees, bushes, rocks or small plants. Plants regrow from the biome rules inside the painted area |
| 5 | Rift | Drag a line to cut a canyon (width, depth, roughness) |
| 6 | Water | **Lake**: click a hollow — it fills to ground height + depth (refused if water would spill out). **River**: click points from upstream to downstream, Enter to finish, Esc to cancel; the bed is carved automatically. "Frozen" makes walkable ice |
| 7 | Place | Pick a model by category and click to place it; random rotation/scale, `,` `.` rotate the preview. **Spawning** has spawners, unique NPCs and spawn groups |
| 8 | Zone | Draw areas: **Polygon** (click points, Enter or click the first point), **Circle** / **Box** (drag). Click a zone to edit: drag its handles, Alt+click an edge adds a point, right-click a point deletes it. Give it roles in the inspector |
| 9 | Path | Click points for a patrol route, Enter finishes. Spawners with movement "patrol" walk it |

Undo / redo: ⌘Z / ⇧⌘Z (every stroke or placement is one step).

## Spawning creatures

- **Spawner** (Place → Spawning): pick a creature, how many, how far they wander, idle /
  wander / patrol (choose a path) and respawn time (seconds of play). Nothing ever appears
  where the player is looking: spots in view wait until they look away.
- **Spawn group**: put several spawners in a group (their *Group* setting) to keep only some
  alive at once — e.g. a rare creature that sometimes appears instead of the normal ones
  (weights decide how often). *Manual* groups only appear when the story asks; a *leader*
  makes the others wait while it is dead.
- **Zone** with the *spawn* role: a table of creatures (weight, group size, level), how many at
  most, how often it checks and with what chance, where (slope, height, water), at what
  hours, and only after a story condition. The yellow ticks show where it can put creatures;
  the inspector says how much of the zone is usable.
- **No-spawn** zones keep areas (towns, camps) free; **encounter** zones fix the level of
  what spawns there the first time you arrive; **trigger** zones set a story flag or start a
  story event when the player walks in.
- **Unique NPC**: one named creature; if killed with respawn 0 it is gone for good.
- Problems (missing creature, spawner in water, empty table…) show in the inspector and in
  **Play → Check spawning problems**.
- **Play → Simulate here (F5)** runs creatures and spawning around the middle of the screen
  without starting the game; nothing on the map changes. A blue stand-in figure (it can't be
  hurt) stands on the ground under the middle of the screen so creatures have someone to
  notice. **F6 (Play → Drive the pawn)** lets you walk it yourself: WASD, Space jump, Shift
  walk, Ctrl crouch; the camera follows, right mouse turns it, the wheel zooms. F6 again
  hands it back to the screen centre. ` opens the debug console.

Creature types, items and loot tables live in `assets/data/*.json`.

## Saving, opening, regenerating

- **Save** (⌘S) writes a `.luxmap` folder (see ARCHITECTURE.md §2.3). **Open Map…** opens one; recent maps are on the start screen.
- **Generate → Regenerate with these settings…** reopens the New Map screen with the map's settings. Change anything and generate: your sculpting, rifts, river cuts, your own lakes and rivers, placed objects, deleted buildings and vegetation paint are carried over to the new terrain. (Hand-painted ground textures are not carried over yet.)

## Playing (Counter-Strike-style movement)

WASD move (relative to the camera) · mouse looks around · Space jump · Ctrl or C crouch · Shift walk ·
Esc frees the mouse; Esc again pauses the game (Resume, Settings, Main menu — leaving saves). Hold crouch while jumping to reach higher ledges.
Air strafing works like CS: in the air, hold A or D and turn the mouse the same way.
The HUD shows health and speed in CS units (250 u/s = running). Place pushable crates, barrels,
logs and carts in the editor with **Place → Physics props**.

**Graphics settings** (main menu → Options, or Esc Esc → Settings; saved for next time):
*Quality* — **Adaptive** (recommended) keeps 60 fps by itself: when the computer is busy it
renders fewer pixels (FSR upscaling, down to *Lowest resolution*), then drops ambient occlusion,
then draw distance, and brings them back when it can; or a fixed **Ultra / High / Medium / Low**
at a chosen *Resolution* (Medium and Low also simplify the ground textures). Also vertical sync,
a frame-rate cap (a cap under 60 becomes Adaptive's target), full screen, and a frame-rate counter
(bottom left, with the current resolution and detail).

**Weapons**: 1 rifle · 2 pistol · 3 knife · 4 sniper (or mouse wheel) · left click fire · right click aim · R reload.
The character turns and runs the way you steer (A, D and S turn it rather than sliding it sideways);
while you hold right click (gamepad: left trigger), and for a moment after each attack, it faces
where the camera aims instead.
Moving and jumping make shots spread (stand still for accuracy). Headshots do ×4 damage. Bullets
go through thin wood, glass and sheet metal, but not thick concrete or the ground. Heavier guns
slow you down a little.

**E** picks up a prop you look at (up to 35 kg); E again drops it, left click throws it.
Walk into a **ladder** to climb it: W climbs (down when you look down), Space jumps off.
Stand on **moving platforms** to ride them. Cans, bottles and buckets get kicked aside as you walk.

In the editor, **Place → Gameplay** has ladders, moving platforms, training dummies and the
spawn point. Select one to change its settings (ladder height, platform travel and speed, dummy
health). Training dummies fall over when killed and get back up after a few seconds.
All gun models, characters and sounds are placeholders.

## Playing: creatures, loot and saves

**E** uses whatever the prompt says: **loot** a corpse (a loot window: Take, Take all — or E
again; money is taken automatically), then skin or shear it, pick up items, open a chest
(otherwise it picks up physics props as before). **Tab** opens your bag (drop items there —
they stay for an hour of play). Corpses disappear after 5 minutes (sooner once emptied). Kills
give XP and skill XP (hunting, skinning, farming, combat). There is no death penalty yet.
Day turns to night over 48 minutes; some creatures only come out at night.

Saves: autosave every 5 minutes and when you leave or quit; **F5** quick-saves, **F9** loads the
quick-save; the main menu has **Continue** and **Load game**. What a save remembers: what
you killed (until it respawns), what you dropped, opened chests, moved or broken props,
felled trees, unique NPCs, your bag, level and story — not every animal's position.

**Skill tree** (K). Every character level after the first gives 2 skill points. Click a
skill to learn its next rank: it costs the points shown in its tooltip, and it can only be
learned once every skill leading to it has been learned — a skill where two branches meet
needs both (Strike, at the bottom, is free to start with). Gold lines show your learned path; bright pulsing rims are what you can learn
now; grey skills are still locked. Drag to move, wheel to zoom, Home to see the whole tree,
K or Esc to close. The tree comes from `Arisent-DEMO.json` in the project folder; skills are
saved by their id, so names and descriptions can change freely, but changing an id
refunds the points spent on it.

**Developer console** (` or F1, available in development builds). Commands start with
`/`: `/help` lists them, `/help <command>` explains one, and Tab completes names and
arguments as you type (the amber part is what you typed; Return also completes, and runs
once the line is complete). Esc closes suggestions, then clears the line, then closes the
console; ↑/↓ walk earlier lines. Commands with several actions list them when typed bare
(`/time`, `/nav`, `/saves`…). Useful ones:
- Overlays and questions: `/show ai spawns zones items nav cells physics`, `/hide all`,
  `/why` (what you look at), `/info`, `/where`, `/npcs list`, `/zone here`, `/items list`.
- Time: `/time show`, `/time set dusk`, `/skip 2` (hours pass), `/timescale world 10`.
- Cheats (they mark the save as modified): `/god`, `/notarget`, `/noclip`, `/heal`,
  `/give coin 100`, `/give #weapon`, `/take all`, `/level 5`, `/skill set skinning 3`,
  `/spawn wolf 3`, `/kill all`, `/ammo infinite`, `/tp <x> <z>` or `/tp <zone name>`.
- Saves: `/save [slot]`, `/load [slot]`, `/saves list`, `/saves dump`, `/menu`, `/newgame`.
- Skill tree: `/skilltree show`, `/skilltree list fire`, `/skilltree points 20`,
  `/skilltree learn ME-002 3`, `/skilltree set F-007-U 5`, `/skilltree reset`, `/skilltree reload`.
- Data: `/content items`, `/content creatures`, `/loot roll wolf 1000`, `/story list`.
- Console: `/bind "/time set noon" ctrl+n` (this session), `/hotkeys`, `/exec file.txt`
  (lines from `user://`), `/log level warn`, `/monitor` (Shift+` shows the Render, World,
  System and Player panels; Shift+1-4 one each), Cmd/Ctrl + = − 0 resize the console.

## Where things are

- Asset list (models, scale, collision, colour remap): `assets/catalog.json`. Swap a placeholder by changing its `path` — maps only store the id.
- Vegetation rules (what grows where): `worldgen/scatter.gd` → `RULES`.
- Ground texture rules: `worldgen/texture_rules.gd`; texture slots: `world/terrain/terrain_texture_set.gd`.
- Entity kinds for RPG content (spawn points, chests, NPC spawns are already declared): `world/entities/entity_kinds.gd`.
- Licences of the placeholder assets: `assets/LICENSES.md`.
