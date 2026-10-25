## Stable ids for generated vegetation, so removing a tree can be remembered without
## saving the forest: "veg:<asset id>:<x>:<z>" with the position rounded to 0.5 m (not an
## index, which shifts whenever the area is re-scattered). Loading a save removes the
## instance nearest to that spot again (within 0.75 m).
class_name VegetationIds
extends RefCounted

const QUANT := 2.0   ## steps per metre
const EPS := 0.75


static func id_for(asset_id: String, pos: Vector3) -> String:
	return "veg:%s:%d:%d" % [asset_id, roundi(pos.x * QUANT), roundi(pos.z * QUANT)]


## {asset, pos} for a vegetation id, or {} if it isn't one.
static func parse(id: String) -> Dictionary:
	var parts := id.split(":")
	if parts.size() != 4 or parts[0] != "veg":
		return {}
	return {"asset": parts[1], "pos": Vector3(parts[2].to_float() / QUANT, 0.0, parts[3].to_float() / QUANT)}


## Removes the instance a vegetation id stands for. True if one was found.
static func remove(view: WorldView, id: String) -> bool:
	var d := parse(id)
	if d.is_empty() or view.terrain == null:
		return false
	var mid := Catalog.mesh_id(str(d.asset))
	if mid < 0:
		return false
	var p: Vector3 = d.pos
	if not view.terrain.remove_instance_near(mid, p, EPS):
		return false
	view.refresh_impostors(Rect2(p.x - 2.0, p.z - 2.0, 4.0, 4.0))
	return true
