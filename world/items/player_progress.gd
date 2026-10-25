## Experience, level and skills (hunting, skinning, farming, combat…). Total XP needed for
## a level (owner's formula):  base · L · (L − 1) / 2
## With base 100: level 2 at 100, 3 at 300, 5 at 1 000, 10 at 4 500. Skills use the same
## formula with their own base.
## Also the skill tree: ranks learned per tree node id (never by name), paid with skill
## points earned per character level. Free points are always counted (earned − spent), so
## nothing about them can drift out of step in a save.
class_name PlayerProgress
extends RefCounted

signal leveled(level: int)
signal skill_leveled(skill: String, level: int)
signal tree_changed

const SKILL_POINTS_PER_LEVEL := 2  ## skill-tree points for every character level after the first

const BASE_XP := 100        ## character levels
const SKILL_BASE_XP := 50   ## skills

var xp := 0
var skills := {}  ## skill -> xp
var tree_ranks := {}     ## skill-tree node id -> rank learned
var bonus_points := 0    ## skill points granted outside levelling (console, quests)


## Total XP needed to reach `level`.
static func xp_for(level: int, base := BASE_XP) -> int:
	return base * level * (level - 1) / 2


## Highest level whose requirement is met.
static func level_for(x: int, base := BASE_XP) -> int:
	# Solve base·L(L−1)/2 ≤ x, then correct for rounding.
	var l := maxi(1, int(floor((1.0 + sqrt(1.0 + 8.0 * maxf(0.0, float(x)) / base)) / 2.0)))
	while xp_for(l + 1, base) <= x:
		l += 1
	while l > 1 and xp_for(l, base) > x:
		l -= 1
	return l


func level() -> int:
	return level_for(xp)


func skill_level(skill: String) -> int:
	return level_for(int(skills.get(skill, 0)), SKILL_BASE_XP)


func add_xp(amount: int) -> void:
	var before := level()
	xp += maxi(0, amount)
	if level() > before:
		leveled.emit(level())


func add_skill_xp(skill: String, amount: int) -> void:
	var before := skill_level(skill)
	skills[skill] = int(skills.get(skill, 0)) + maxi(0, amount)
	if skill_level(skill) > before:
		skill_leveled.emit(skill, skill_level(skill))


# --- skill tree ------------------------------------------------------------------------

func points_earned() -> int:
	return (level() - 1) * SKILL_POINTS_PER_LEVEL + bonus_points


## Free skill points for this tree.
func skill_points(tree: SkillTree) -> int:
	return points_earned() - tree.spent(tree_ranks)


func tree_rank(id: String) -> int:
	return int(tree_ranks.get(id, 0))


## Learns one rank of node `id`. Returns "" or why it can't.
func learn(tree: SkillTree, id: String) -> String:
	var why := tree.why_not(tree_ranks, skill_points(tree), id)
	if why != "":
		return why
	tree_ranks[id] = tree_rank(id) + 1
	tree_changed.emit()
	return ""


## Forgets every rank (all points come back).
func reset_tree() -> void:
	tree_ranks.clear()
	tree_changed.emit()


func to_dict() -> Dictionary:
	return {"xp": xp, "skills": skills.duplicate(), "tree": tree_ranks.duplicate(), "bonus_points": bonus_points}


func from_dict(d: Dictionary) -> void:
	xp = int(d.get("xp", 0))
	skills = {}
	for k: Variant in d.get("skills", {}):
		skills[str(k)] = int(d.skills[k])
	tree_ranks = {}
	var t: Dictionary = d.get("tree", {})
	for k: Variant in t:
		tree_ranks[str(k)] = int(t[k])
	bonus_points = int(d.get("bonus_points", 0))
	tree_changed.emit()
