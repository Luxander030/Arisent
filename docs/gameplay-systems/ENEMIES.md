# Enemies ported from the web Lux's RPG

Source: `~/Projects/luxs-rpg-public/js/other/combat/enemies/*.js` (the turn-based web game).
The 10 most basic enemies (the "normal" file, the first three sanity enemies and the Blood
Bat — everything below level 12 that is not a mini-boss, elemental, boss or special) are
generated into Lux's data by **`tools/port/basic_enemies.py`** (re-runnable; it replaces only
its own entries in `assets/data/{creatures,items,loot_tables,factions}.json`).

| Enemy | Lv | Faction | HP | Hit / interval | XP | Special | Loot |
|---|---|---|---|---|---|---|---|
| Shadow Imp (`shadow_imp`) | 1 | monsters | 40 | 5.2 / 1.4 s | 8 | — | coins 1–3, black_shard 10%, gem_ruby 5.0% |
| Armored Beetle (`armored_beetle`) | 1 | monsters | 69 | 5.6 / 1.8 s | 11 | fire ×0.6 | coins 1–4, armored_carapace 10%, gem_ruby 5.0% |
| Gloom Weaver (`gloom_weaver`) | 1 | monsters | 44 | 9.1 / 2.2 s | 13 | ranged 12 m; yells “Nightmare may stalk you...” | coins 2–5, black_shard 10%, gem_ruby 7.0% |
| Elf (`elf`) | 5 | elves | 113 | 12.0 / 1.4 s | 38 | yells “We find Drow Elves goofy in a way that they fear a so called "god". He certainly can't be real... right?” | coins 5–17, elf_ear 10%, gem_ruby 5.0% |
| Stone Golem (`stone_golem`) | 5 | monsters | 200 | 26.8 / 2.6 s | 69 | fire ×0.4 | coins 5–19, rock 10%, gem_ruby 7.0% |
| Void Stalker (`void_stalker`) | 5 | monsters | 128 | 11.0 / 1.3 s | 52 | yells “...but Lux stalks us all.” | coins 4–14, black_shard 10%, gem_ruby 7.0% |
| Iron Golem (`iron_golem`) | 7 | monsters | 378 | 35.0 / 2.8 s | 142 | fire ×0.3 | coins 12–36, chunk_of_iron 10%, gem_ruby 7.0% |
| Nightmare Shade (`nightmare_shade`) | 8 | monsters | 199 | 23.1 / 2.0 s | 94 | ranged 10 m; yells “Your mind is a feast.” | coins 7–23, black_shard 10% |
| Drow Elf (`drow_elf`) | 10 | drow | 200 | 34.9 / 2.0 s | 107 | ranged 16 m; yells “We Drow Elves only bow to one god. That one being the creator of this realm.” | coins 15–45, drow_elf_ear 10%, gem_ruby 5.0% |
| Blood Bat (`blood_bat`) | 6 | monsters | 104 | 8.9 / 1.2 s | 41 | fire ×2.0; regen 6.1 HP/s | coins 3–11, blood_bat_eye 10%, gem_ruby 5.0% |

Every enemy keeps its source **lore** and **trait** in its definition (`/content show creatures <id>`)
and a `source` note. Spawn them with `/spawn <id>`, or put them on spawners and zone spawn
tables in the World Editor (they appear in the creature lists automatically).

## How the numbers were converted
- The source is turn-based with stats of the form `base + per_level × max(1, 2·LV/3)` and a
  player whose HP grows with level. Lux has real-time aimed combat and a flat 100 HP player.
- Each enemy keeps its **ratio to the Shadow Imp** at the level where it first appears (its
  character), softened by a power of 0.6, on top of a **Lux baseline per level** fitted to
  Lux's own creatures (grey wolf L3, bandit L4, dire wolf L8): HP 40 + 12·(L−1), damage per
  second 3.75 + 0.6·(L−1), XP 8 + 5·(L−1), coins (1 + (L−1)/3)–(3 + L−1).
- Damage per hit = baseline DPS × ratio × attack interval (golems hit rarely and hard), never
  more than 35 (35 % of the player).
- Lux level = the level it unlocks at in the source (Blood Bat, gated by a class spell there: 6).
- Drops as in the source: the enemy's item 10 %, a gem at its source gem chance (Lux's ruby),
  coins every kill. Item values = source sell price ÷ 2.5.

## Traits and what they became
- **Fire resistance / weakness** (`burnResist`, `burnVuln`): `resist: {"fire": …}` — damage of
  that kind is reduced (golems, beetle) or doubled (Blood Bat). Lux has no fire damage yet; it
  applies as soon as something deals `kind = "fire"`.
- **Regenerates HP per turn** (Blood Bat): `regen` HP per second while hurt.
- **"Never touches you" / archers** (Gloom Weaver, Nightmare Shade, Drow Elf): ranged attacks
  (a bolt, `kind = "magic"`), only with line of sight.
- **Slow Titan** (golems): slow, short leash, long attack interval with heavy hits.
- **Special messages** become aggro yells.
- **Elves vs Drow**: two factions hostile to each other (and to the player). Lux creatures do
  not fight each other yet, so for now this is data only.
- **Sanity drain** (the sanity enemies, a little on Drow, golem, bat): Lux has no sanity yet;
  the per-hit amount is kept as `sanity_damage` for when it does.
