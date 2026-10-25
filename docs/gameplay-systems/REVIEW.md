# Adversarial review log

## Round 1 — PLAN v1 (2026-10-22)

Reviewer: independent agent; read PLAN v1, RESEARCH, ARCHITECTURE and the code. Verdict:
*direction sound, not implementable as written* — 3 blockers, 26 major, 15 minor/nit.
Spot-checked by the author: export include filter (F8) and physics-only hitscan beyond the
64 m terrain-collision radius (F3) confirmed. **All findings accepted**; resolutions are in
PLAN v2 (decision numbers below refer to v2).

| id | sev | finding (short) | resolution in v2 |
|---|---|---|---|
| F1 | BLOCKER | ACTIVE/"in combat" NPCs beyond 64 m terrain collision fall through | D10: locomotion mode chosen by **collision availability**, tier only sets rate/fidelity; Y always clamped to ground |
| F7 | BLOCKER | KindRegistry with editor builders in `world/` breaks game export | D17: runtime `KindRegistry` + editor-side `KindEditorExt` registration; headless "no editor/" compile test |
| F8 | BLOCKER | `assets/data/*.json` not exported | D8: add to all 4 presets' include_filter; export test |
| F2 | MAJOR | ragdolls beyond collision fall through; no pool | D11: ragdoll only inside collision range, else static corpse pose; corpse ≠ ragdoll lifetime |
| F3 | MAJOR | hitscan/LOS/spawn-visibility ignore terrain beyond 64 m | D11: `WorldQueries.trace()` (terrain intersection + physics) used everywhere; fixes the existing hitscan bug too |
| F4 | MAJOR | NPCs without nodes can't be hit | D11: hitscan also tests nodeless records along the ray via the grid (capsule test) |
| F5 | MAJOR | "beyond fog" never true; pop rule vs budget | D5: visibility-range fade / dither; budget wins |
| F6 | MAJOR | `WorldSession.of()` can't reach session from WorldView children | D2: `WorldView.session`; `of()` walks up to the WorldView |
| F9 | MAJOR | region-of-position ownership loses state when entities move | D13: id-keyed state in one per-map table; only dynamic objects chunked by position |
| F10 | MAJOR | dirty-only writes vs rotation; non-atomic multi-file save | D13: generational save directories + manifest written last; full copy per generation |
| F11 | MAJOR | shallow snapshot races the writer thread | D13: deep snapshot of primitives; single writer, queued |
| F12 | MAJOR | 10-min TTL + cap contradicts "come back to pick it up" | D12/D13: ground-item policy classes (player-dropped persistent, loot TTL, quest never); cap evicts loot only |
| F13 | MAJOR | timers on a scalable game clock | D14: `SimClock` (monotonic, persisted timers) separate from `TimeOfDay` |
| F14 | MAJOR | one save = one map | D2/D13: `GameSession` (player, story, inventory) above per-map `WorldSession`; save layout `maps/<map_uid>/` |
| F15 | MAJOR | no map id / revision | D17: `map_uid` + `revision` in map.json (P0) |
| F16 | MAJOR | vegetation index ids unstable | D13: `veg:<asset>:<qx>:<qz>` with nearest-match tolerance; harvesting later |
| F17 | MAJOR | "not visible" respawn rule starves watched farms | D6: `respawn_visibility` policy (any+fade / hidden / hidden_or_timeout) |
| F18 | MAJOR | rejection sampling can fail forever, costly | D6: baked per-zone candidate points (threaded, cached), usable-area stat, back-off |
| F19 | MAJOR | no "why" debugging | D15: block reasons per slot, brain event ring buffer, `why`/`info` commands — in P1 |
| F20 | MAJOR | Simulate focus in the sky, editing during simulate, props unfreeze | D16: ground focus / test pawn, XZ distance, edit lock, never dirties map |
| F21 | MAJOR | E key conflicts; no interaction abstraction | D12: `Interactable` + `InteractionSystem` in P1 |
| F22 | MAJOR | console typing moves the player; keyboard layouts | D15: input gating flag, mouse release, physical keycode + F1 |
| F23 | MAJOR | zones/paths unpickable by physics; `e.asset` missing | D7/D17: non-physics shape picking + handle picking; `asset:""` normalised |
| F24 | MAJOR | per-tier node type swaps hitch | D10: one pooled `NpcBody` with modes |
| F25 | MAJOR | P0 too big | §6: P0 trimmed; table/condition/entity_ref editors in P3 |
| F26 | MINOR | grid "aligned with Terrain3D" false at 2 m spacing | D3: grid defined in metres, alignment claim dropped |
| F27 | MINOR | scattered rocks have no collision | §1 corrected |
| F28 | MINOR | console scope contradiction | D15: game + Simulate |
| F29 | MINOR | static per-world state | D2: caps move into session services; defs swapped atomically |
| F30 | MINOR | RefCounted cycles | D4: references by id; node↔record via instance id |
| F31 | MINOR | ACTIVE AI cost unbudgeted | D5/§7: perception 10 Hz staggered; ACTIVE budget ≤ 1.5 ms; benchmark gate |
| F32 | MINOR | single focus | D5: weighted focus set |
| F33 | MINOR | despawn-at-1 km rationale wrong | D6: per-archetype despawn policy |
| F34 | MINOR | unique NPCs/villagers not covered | D6/D13: `unique_npc` kind, STATE policy, respawn never |
| F35 | MINOR | moved physics prop duplicated as DYNAMIC | D13: base objects store `modified[id].xform` |
| F36 | MINOR | id counter mixed with RNG; JSON int→float | D13: `next_runtime_id`; binary `var_to_bytes` (no objects) |
| F37 | MINOR | overlapping zone precedence | D7: `priority`, `parent_zone`, sorted stack |
| F38 | MINOR | runtime no_spawn zones | D7: runtime zones in the same index |
| F39 | MINOR | draped fills / Label3D cost | D15: cached draped meshes, label culling |
| F40 | MINOR | hotkeys run out; vertex drag undo | §3: tool palette beyond 9; commit on release |
| F41 | MINOR | condition editor needs story ids | D17: project story-graph path setting |
| F42 | MINOR | Y snap ignores bridges/floors/water | D10: max(terrain, static tops), water filter |
| F43 | MINOR | world seed decoded in worldgen | D6: `core/` Rng on `gen_params.seed` |
| F44 | NIT | PhysicsProp 90 m vs 64 m collision | D5: migration fixes it (noted) |
| F45 | NIT | Backspace/Enter conflicts in zone tool | §3: tool-local consumption order |
| F46 | NIT | visibility untestable headless | D5: `VisibilityProvider` with test fake |

Also added from the coverage check: spawn chance per tick + initial population policy
("frequencies"), skill XP sources, save/load UI, behaviour for missing maps / incompatible
saves, export-build compile test.

## Round 2 — PLAN v2 (2026-10-22)

Same reviewer. **37/46 round-1 findings fully resolved, 9 partial; 9 new (2 major
topology, 1 major budget). Verdict: go for P0 after M1 and M2.** All accepted; PLAN v3
applies them:

| id | finding | resolution in v3 |
|---|---|---|
| M1 / N1 | DebugDraw, grid and zone index were session-only, but the editor needs them without Simulate | D2: authored infrastructure lives on WorldView; WorldSession attaches/detaches runtime entries |
| M2 / N2 | GameSession destroyed by `change_scene` on map change; menu exit skipped the save flush | D2: persistent `world_game` host swaps WorldView+WorldSession; flush on menu exit and quit |
| M3 / N3 | terrain march on every trace too costly | D11: skip the march inside the collision radius, LOS cache 0.2 s, trace in the P1 benchmark |
| M4 / F4 | nodeless hits could go through walls; stale FAR Y; hitgroups | D11: merge by distance, snap Y at query, body-only |
| M5 / F10 | manifest atomicity, unloaded maps lost, orphan generations | D13: temp+rename manifest, generation scan with checksums, byte-copy unloaded maps, cleanup |
| M6 / F12 | player-dropped items unbounded; "simulated" undefined | D12: auto-stack, hard caps with refusal + warning; simulated = within 600 m |
| M7 / F15 | Save As / Finder copies duplicate `map_uid` | D17: Save As asks keep/copy, lineage, duplicate-uid detection |
| F13 | TimeOfDay derived vs stored; `time` vs `skip` | D14: TimeOfDay is its own accumulator; commands defined |
| F18 | candidate cache location | D6: baked by the editor into the map; runtime rebuild from the `world/` baker if missing |
| F20 | Terrain3D collision focus in Simulate | D16: `set_focus` to the ground focus while simulating |
| F33 | no despawn radius | D6: `despawn_radius` (1 km) per policy |
| N4 | tier table read as "ACTIVE = physics" | D5: ACTIVE ≠ physics; ±4 m hysteresis on physics↔snapped |
| N5 | corpse and loot on different clocks | D11: same simulated-region counter |
| N6 | `--dev` args, editor feature check | D15: user args after `--`, `has_feature("level_editor")` |
| N7 | game needs the story graph for defaults | D17: one exported project setting |
| N8 | Boxman static cache unbounded | D2: keyed by def id, bounded |
| N9 | Hitscan signature | D11: takes session queries |

Status after round 2: no open BLOCKER/MAJOR items; P0 may start.

## Round 3 — implementation review (2026-10-22)

Independent agent reviewed the P0–P5 code. No blockers; 4 major, 12 minor, plus plan gaps.
Boundary clean (no editor/worldgen use from runtime), export filter fixed, save applied
before the first spawn tick. All accepted and fixed unless noted:

| id | finding | fix |
|---|---|---|
| M1 | maps not in a snapshot copied from the *target* slot's history; new games could inherit old maps; not-yet-entered maps of the loaded save omitted | `playthrough` id in game + manifest, carry-over only within the same play-through; snapshot includes `loaded_maps`; test |
| M2 | Simulate could change the map (`fell`, redo, live inspector) | `fell` refused when ephemeral; redo guarded; inspector replaced by a lock note; all overlay channels restored on stop; test |
| M3 | spawn groups scanned every slot per tick | group → member and source → slot indexes |
| M4 | zones with unspawned slots re-checked every 0.25 s with many LOS traces | initial pass throttled to ≤ 1/s; ≤ 4 groups per check |
| m1 | `game.bin` written first | written last (completion marker) |
| m2 | "Saved" shown before the write; errors invisible | results reported from the main thread after the write |
| m3 | dropped coins re-collected instantly | player-dropped coins are not auto-collected |
| m4 | weapon keys / mouse capture ignored the input gate | both check `input_enabled` |
| m5 | LOS cache key collisions | pair key |
| m6 | debug drawing ticked with everything off; per-vertex mesh building | processing off while all channels off; ArrayMesh in one call |
| m7 | `skip` aged loot but not corpses | corpses age too |
| m8 | shallow merge of creature defaults | nested defaults merge |
| m9 | navigator paths never pruned | forgotten on death/despawn |
| m10 | candidate bake excluded runtime camps permanently; overlay could trigger a bake | only authored no-spawn baked in; overlay never bakes |
| m11 | saved unique NPCs ignored their condition | checked on load |
| m12 | stale drag state after release over sky/UI | reset on release |
| gaps | encounter reset, persistence overlay, unique-NPC priority, threat switching, reaction chance/condition, autosave on map change, newer-map warning | implemented; encounter reset tested |

Deliberately left as documented deviations (no behaviour impact today): `Ragdoll._active`
stays static (one world at a time); block reasons are readable text, not codes; spawners use
one archetype (zones have tables); the runtime candidate bake is synchronous (the editor
bakes on save, so it only runs for stale caches); no on-screen term in the scheduler
(distance + combat + unique); runtime zones are stored in `state.bin`.
