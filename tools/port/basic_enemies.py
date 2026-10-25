#!/usr/bin/env python3
"""Ports the 10 most basic enemies of the web Lux's RPG (~/Projects/luxs-rpg-public,
js/other/combat/enemies/*.js) into Lux's data files: creatures, their drop items, loot
tables and factions. Re-running it replaces the same entries; nothing else is touched.

  python3 tools/port/basic_enemies.py [path to luxs-rpg-public]

Conversion (see docs/gameplay-systems/ENEMIES.md):
- The source is turn-based with big numbers that scale with the player's level
  (stat = base + per_level * max(1, 2*LV/3)), and its player's HP grows with level; Lux's
  player has a flat 100 HP and real-time aimed combat. So each enemy keeps its *ratio* to
  the Shadow Imp at the level it first appears (its character: beetle tanky, drow deadly),
  softened by a power of RATIO_POWER, on top of a Lux baseline per level fitted to Lux's
  existing creatures (grey wolf L3, bandit L4, dire wolf L8).
- Damage per hit = baseline DPS x ratio x attack interval (slow hitters hit harder, same
  DPS), capped at MAX_HIT of the player's 100 HP.
- Drops: coins always (gold), the enemy's item 10 % (as in the source), a gem at the
  source's per-enemy gem chance (Lux's ruby). Item values: source sell price / 2.5.
"""
import json, os, re, sys

SRC = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Projects/luxs-rpg-public")
ENEMIES = os.path.join(SRC, "js/other/combat/enemies")
ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
DATA = os.path.join(ROOT, "assets/data")

RATIO_POWER = 0.6   # real-time combat: a 7x tankier turn-based enemy would be a bullet sponge
MAX_HIT = 35.0      # no single hit takes more than 35 % of the player's 100 HP
BASE_INTERVAL = 1.6


def baseline(level):
    """A plain level-L Lux enemy (the Shadow Imp at L1), fitted to Lux's own creatures."""
    return {"hp": 40.0 + 12.0 * (level - 1), "dps": 3.75 + 0.6 * (level - 1), "xp": 8.0 + 5.0 * (level - 1),
            "coins": (1 + (level - 1) // 3, 3 + (level - 1))}
ITEM_DROP = 10      # % — source: enemyItemDrop() rolls Math.random() < 0.1
GEM_ITEM = "gem_ruby"

# Lux-side design per enemy (bodies are the placeholder humanoid / four-legged visuals).
# level = where it first appears in the source; ranged = attacks from a distance.
DESIGN = {
    "Shadow Imp":      dict(id="shadow_imp", level=1, body="humanoid", height=1.1, color="#2c2240", walk=1.8, run=6.2,
                            faction="monsters", interval=1.4, range=1.6, aggro=14),
    "Armored Beetle":  dict(id="armored_beetle", level=1, body="quadruped", height=0.7, color="#3f5236", walk=1.0, run=3.2,
                            faction="monsters", interval=1.8, range=1.8, aggro=9),
    "Gloom Weaver":    dict(id="gloom_weaver", level=1, body="humanoid", height=1.7, color="#3d2f55", walk=1.4, run=4.4,
                            faction="monsters", interval=2.2, range=12.0, aggro=18, ranged=True),
    "Elf":             dict(id="elf", level=5, body="humanoid", height=1.85, color="#5f9e4f", walk=1.7, run=6.0,
                            faction="elves", interval=1.4, range=2.0, aggro=16),
    "Stone Golem":     dict(id="stone_golem", level=5, body="humanoid", height=2.6, color="#8a857e", walk=1.0, run=2.6,
                            faction="monsters", interval=2.6, range=2.8, aggro=12, leash=30),
    "Void Stalker":    dict(id="void_stalker", level=5, body="humanoid", height=1.9, color="#1b1630", walk=1.8, run=7.0,
                            faction="monsters", interval=1.3, range=1.9, aggro=20),
    "Iron Golem":      dict(id="iron_golem", level=7, body="humanoid", height=2.9, color="#686c74", walk=0.9, run=2.4,
                            faction="monsters", interval=2.8, range=3.0, aggro=12, leash=30),
    "Nightmare Shade": dict(id="nightmare_shade", level=8, body="humanoid", height=2.0, color="#120c1e", walk=1.5, run=5.0,
                            faction="monsters", interval=2.0, range=10.0, aggro=20, ranged=True),
    "Drow Elf":        dict(id="drow_elf", level=10, body="humanoid", height=1.8, color="#43385f", walk=1.7, run=6.0,
                            faction="drow", interval=2.0, range=16.0, aggro=24, ranged=True),
    "Blood Bat":       dict(id="blood_bat", level=6, body="quadruped", height=0.45, color="#6a1622", walk=2.0, run=7.5,
                            faction="monsters", interval=1.2, range=1.6, aggro=16),
}

# Source items → Lux items (sell value = source g per level / 2.5).
ITEMS = {
    "Black Shard":      dict(id="black_shard", value=4, category="trophy", color="#1a1a22", desc="A black, sharp shard. Seems like it could sell for a bit of money."),
    "Armored Carapace": dict(id="armored_carapace", value=10, category="trophy", color="#4b5a3c", desc="A very solid piece of carapace. It could probably be sold for a good amount."),
    "Elf Ear":          dict(id="elf_ear", value=20, category="trophy", color="#d9b38c", desc="A rare ear of an Elf. Could sell for a good amount."),
    "Drow Elf Ear":     dict(id="drow_elf_ear", value=16, category="trophy", color="#6c5f8f", desc="The ear of a Drow Elf. Seems as if it could stabilize your mind."),
    "Rock":             dict(id="rock", value=0, category="junk", color="#8a857e", desc="A rock. Literally, just a rock."),
    "Chunk of Iron":    dict(id="chunk_of_iron", value=20, category="crafting", color="#7a7d84", desc="A chunk of raw iron. Worth more once refined."),
    "Blood Bat Eye":    dict(id="blood_bat_eye", value=30, category="trophy", color="#b0182a", desc="The eye of a blood bat. Quite valuable to certain people."),
}


def scaled_lv(level):
    return max(1, (level * 2) // 3)


def parse_enemies():
    """name -> {stat: (base, per_level)} plus lore, trait, specialMsg, drop, burnResist, burnVuln."""
    out = {}
    for fn in sorted(os.listdir(ENEMIES)):
        s = open(os.path.join(ENEMIES, fn), encoding="utf-8").read()
        for m in re.finditer(r'\{\s*name:\s*"([^"]+)"(.*?)\n    \},', s, re.S):
            name, body = m.group(1), m.group(2)
            if name not in DESIGN:
                continue
            e = {"file": fn}
            for stat in ["mhp", "atk", "san", "exp", "gold", "lifesteal"]:
                mm = re.search(r'get ' + stat + r'\(\)\s*\{(.*?)\n        \}', body, re.S)
                if mm:
                    r = re.search(r'return\s+(\d+)n(?:\s*\+\s*\(scaledLV\s*\*\s*(\d+)n\))?', mm.group(1))
                    e[stat] = (int(r.group(1)), int(r.group(2) or 0)) if r else (0, 0)
                else:
                    r = re.search(stat + r':\s*(\d+)n', body)
                    e[stat] = (int(r.group(1)), 0) if r else (0, 0)
            for key in ["lore", "trait", "specialMsg"]:
                mm = re.search(key + r':\s*[`"](.*?)[`"],\n', body, re.S)
                e[key] = mm.group(1) if mm else ""
            mm = re.search(r'drop:\s*\(\)\s*=>\s*"([^"]+)"', body)
            e["drop"] = mm.group(1) if mm else ""
            for key in ["burnResist", "burnVuln"]:
                mm = re.search(key + r':\s*([\d.]+)', body)
                e[key] = float(mm.group(1)) if mm else None
            out[name] = e
    missing = set(DESIGN) - set(out)
    assert not missing, f"not found in the source: {missing}"
    return out


def gem_chances():
    s = open(os.path.join(SRC, "js/other/combat/sub-Combat1.js"), encoding="utf-8").read()
    return {n: float(c) for n, c in re.findall(r'"([^"]+)":\s*([\d.]+)', s.split("gemChances")[1].split("};")[0])}


def at(e, stat, level):
    base, per = e[stat]
    return base + per * scaled_lv(level)


def build(enemies, gems):
    imp = enemies["Shadow Imp"]
    creatures, tables = [], []
    for name, d in DESIGN.items():
        e = enemies[name]
        L = d["level"]
        b = baseline(L)
        ratio = lambda stat: (at(e, stat, L) / max(1, at(imp, stat, L))) ** RATIO_POWER
        hp = round(b["hp"] * ratio("mhp"))
        dmg = round(min(MAX_HIT, b["dps"] * ratio("atk") * d["interval"]), 1)
        xp = round(b["xp"] * ratio("exp"))
        g = ratio("gold")
        coins = (max(1, round(b["coins"][0] * g)), max(1, round(b["coins"][1] * g)))
        c = {
            "id": d["id"], "name": name, "body": d["body"], "height": d["height"], "color": d["color"],
            "health": hp, "level": L, "walk_speed": d["walk"], "run_speed": d["run"], "faction": d["faction"],
            "behaviour": "aggressive", "aggro_radius": d["aggro"], "leash": d.get("leash", 45),
            "attack": {"damage": dmg, "range": d["range"], "interval": d["interval"]},
            "xp": xp, "skill_xp": [{"skill": "combat", "amount": max(2, xp // 3)}],
            "loot_table": d["id"], "respawn": 180, "lore": e["lore"], "trait": e["trait"],
            "source": "luxs-rpg-public %s (%s)" % (e["file"], name),
        }
        if at(e, "san", L) > 0:
            # No sanity system in Lux yet: kept for when there is one (per hit, Lux-scaled).
            c["sanity_damage"] = round(dmg * at(e, "san", L) / max(1, at(e, "atk", L)), 1)
        resist = {}
        if e["burnResist"] is not None:
            resist["fire"] = e["burnResist"]
        if e["burnVuln"] is not None:
            resist["fire"] = round(1.0 - e["burnVuln"], 2)   # 2x damage → -1.0
        if resist:
            c["resist"] = resist
        if at(e, "lifesteal", L) > 0:
            # "Regenerates … HP per turn": the source heals `lifesteal` each turn.
            per_turn = at(e, "lifesteal", L) / at(e, "mhp", L)
            c["regen"] = round(per_turn * hp / BASE_INTERVAL, 1)
        if e["specialMsg"]:
            text = e["specialMsg"].split(":", 1)[1].strip() if ":" in e["specialMsg"] else e["specialMsg"]
            c["reactions"] = [{"event": "aggro", "action": "yell", "text": text}]
        creatures.append(c)
        rows = [{"item": "coin", "chance": 100, "min": coins[0], "max": coins[1]}]
        if e["drop"]:
            rows.append({"item": ITEMS[e["drop"]]["id"], "chance": ITEM_DROP})
        if gems.get(name, 0) > 0:
            rows.append({"item": GEM_ITEM, "chance": round(gems[name] * 100, 1)})
        tables.append({"id": d["id"], "rows": rows})
    items = [{"id": v["id"], "name": k, "value": v["value"], "category": v["category"], "color": v["color"],
              "description": v["desc"], "stack": 20} for k, v in ITEMS.items()]
    return creatures, items, tables


def merge(path, entries):
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
    ids = {e["id"] for e in entries}
    d["entries"] = [e for e in d["entries"] if e["id"] not in ids] + entries
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=1, ensure_ascii=False)
        f.write("\n")


def main():
    enemies = parse_enemies()
    creatures, items, tables = build(enemies, gem_chances())
    merge(os.path.join(DATA, "creatures.json"), creatures)
    merge(os.path.join(DATA, "items.json"), items)
    merge(os.path.join(DATA, "loot_tables.json"), tables)
    # Elves and Drow hate each other (and, like every enemy, the player).
    merge(os.path.join(DATA, "factions.json"), [
        {"id": "elves", "hostile_to": ["player", "drow"]},
        {"id": "drow", "hostile_to": ["player", "elves"]},
    ])
    with open(os.path.join(DATA, "factions.json"), encoding="utf-8") as f:
        fac = json.load(f)
    for e in fac["entries"]:
        if e["id"] == "player":
            for h in ["elves", "drow"]:
                if h not in e["hostile_to"]:
                    e["hostile_to"].append(h)
    with open(os.path.join(DATA, "factions.json"), "w", encoding="utf-8") as f:
        json.dump(fac, f, indent=1, ensure_ascii=False)
        f.write("\n")
    for c in creatures:
        print("%-16s L%-2d hp %4d  dmg %5.1f/%.1fs  range %4.1f  xp %3d  %s%s%s" % (c["id"], c["level"], c["health"],
              c["attack"]["damage"], c["attack"]["interval"], c["attack"]["range"], c["xp"],
              "resist %s " % c["resist"] if "resist" in c else "", "regen %s/s " % c["regen"] if "regen" in c else "",
              "sanity %s" % c["sanity_damage"] if "sanity_damage" in c else ""))
    for t in tables:
        print("  loot %-16s %s" % (t["id"], ", ".join("%s %s%%%s" % (r["item"], r["chance"], " %d-%d" % (r["min"], r["max"]) if "min" in r else "") for r in t["rows"])))


main()
