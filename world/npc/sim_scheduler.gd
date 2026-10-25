## Significance-based level of detail for simulated things (Unreal "significance manager"
## style). Each candidate gets a tier from its distance to the nearest focus and whether
## it is in combat, under budgets, with hysteresis so things near a boundary don't flicker:
##   ACTIVE   ≤ 60 m, or in combat within NEAR range   (budget 24)  full-rate brain
##   NEAR     ≤ 220 m (≥ the longest weapon range)     (budget 64)  5 Hz, cheap node
##   FAR      ≤ 600 m                                                0.5 Hz, data only
##   DORMANT  beyond                                                 frozen; fast-forward on wake
## The tier says how often and how carefully to think — not whether physics is used
## (that depends on where terrain collision exists; see NpcManager).
class_name SimScheduler
extends RefCounted

enum { ACTIVE, NEAR, FAR, DORMANT }
const NAMES := ["ACTIVE", "NEAR", "FAR", "DORMANT"]

var r_active := 60.0
var r_near := 220.0
var r_far := 600.0
var hysteresis := 10.0
var max_active := 24
var max_near := 64


## cands: Array of {id, dist, combat: bool}; current: id -> current tier.
## Returns id -> new tier for every candidate (callers treat absent ids as DORMANT).
## Only candidates that could be ACTIVE or NEAR are ordered (budgets apply there); the
## ordering uses packed integer keys (a native sort), not a script comparison.
func assign(cands: Array, current: Dictionary) -> Dictionary:
	var out := {}
	var keys := PackedInt64Array()
	for i in cands.size():
		var c: Dictionary = cands[i]
		var cur := int(current.get(c.id, DORMANT))
		var d := float(c.dist)
		var rn := r_near + (hysteresis if cur <= NEAR else 0.0)
		if d <= rn or c.combat:
			var score := d - (1000.0 if c.combat else 0.0) + 2000.0
			keys.append(int(score * 16.0) * 65536 + i)
		else:
			var rf := r_far + (hysteresis if cur <= FAR else 0.0)
			out[c.id] = FAR if d <= rf else DORMANT
	keys.sort()
	var n_active := 0
	var n_near := 0
	for k in keys:
		var c: Dictionary = cands[k & 0xFFFF]
		var cur := int(current.get(c.id, DORMANT))
		var d := float(c.dist)
		var ra := r_active + (hysteresis if cur == ACTIVE else 0.0)
		var rn := r_near + (hysteresis if cur <= NEAR else 0.0)
		var rf := r_far + (hysteresis if cur <= FAR else 0.0)
		var tier := DORMANT
		if (d <= ra or (c.combat and d <= rn)) and n_active < max_active:
			tier = ACTIVE
			n_active += 1
		elif d <= rn and n_near < max_near:
			tier = NEAR
			n_near += 1
		elif d <= rf:
			tier = FAR
		out[c.id] = tier
	return out
