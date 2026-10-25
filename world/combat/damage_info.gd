## One hit of damage. Anything that can be hurt implements `apply_damage(info: DamageInfo)`
## (NPC bodies, the player, physics props, training dummies); weapons build these.
class_name DamageInfo
extends RefCounted

var amount := 0.0
var kind := "bullet"         ## bullet, melee, fall, bite, …
var impulse := Vector3.ZERO
var point := Vector3.ZERO
var hitgroup := ""           ## "" for body-only hits
var source_id := ""          ## "player", an NPC record id, …


static func make(amount_: float, kind_: String, source := "", point_ := Vector3.ZERO, impulse_ := Vector3.ZERO, hitgroup_ := "") -> DamageInfo:
	var d := DamageInfo.new()
	d.amount = amount_
	d.kind = kind_
	d.source_id = source
	d.point = point_
	d.impulse = impulse_
	d.hitgroup = hitgroup_
	return d
