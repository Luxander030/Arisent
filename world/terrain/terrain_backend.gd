## The terrain interface the rest of the project uses. Only terrain3d_backend.gd knows
## about Terrain3D; replacing the terrain system means writing another implementation.
class_name TerrainBackend
extends Node3D

enum Tool { RAISE, LOWER, SMOOTH, FLATTEN, PAINT, HOLES }

signal stroke_finished(rect: Rect2)  ## world-space XZ rectangle the stroke touched

var undo_redo: UndoRedo


## Create an empty terrain covering [-map_m/2, map_m/2]² with the given sample spacing.
func setup(_map_m: float, _spacing: float, _camera: Camera3D) -> void:
	push_error("not implemented")


## Images are full-res, origin = world position of pixel (0, 0).
func import_maps(_height: Image, _control: Image, _color: Image, _origin: Vector3) -> void:
	push_error("not implemented")


func get_height(_pos: Vector3) -> float:
	return 0.0


func get_normal(_pos: Vector3) -> Vector3:
	return Vector3.UP


## Returns the hit point, or Vector3.INF when nothing is hit.
func raycast(_from: Vector3, _dir: Vector3) -> Vector3:
	return Vector3.INF


func begin_stroke(_tool: Tool, _pos: Vector3, _brush: Dictionary) -> void:
	pass


func stroke(_pos: Vector3) -> void:
	pass


func end_stroke() -> void:
	pass


## Current heights for a pixel rectangle (row-major).
func read_heights(_rect: Rect2i) -> PackedFloat32Array:
	return PackedFloat32Array()


func write_heights(_rect: Rect2i, _heights: PackedFloat32Array) -> void:
	pass


func read_control(_rect: Rect2i) -> PackedInt32Array:
	return PackedInt32Array()


func write_control(_rect: Rect2i, _control: PackedInt32Array) -> void:
	pass


func read_color(_rect: Rect2i) -> PackedByteArray:
	return PackedByteArray()


func write_color(_rect: Rect2i, _rgba: PackedByteArray) -> void:
	pass


func full_res() -> int:
	return 0


func world_to_pixel(_pos: Vector3) -> Vector2i:
	return Vector2i.ZERO


func pixel_to_world(_px: Vector2i) -> Vector3:
	return Vector3.ZERO


func full_height_image() -> Image:
	return null


## Registers instanced meshes (vegetation, rocks). entries: catalog dictionaries, index = mesh id.
func setup_instancer(_entries: Array) -> void:
	pass


## Scales all vegetation LOD distances (see LodSettings / LodController).
func apply_lod_scale(_scale: float) -> void:
	pass


## Detail scale the vegetation is guaranteed to be drawn at right now (may lag behind
## apply_lod_scale while the change is applied gradually).
## Dual-scale texturing and slope projection (costly per pixel; off on lower presets).
func set_texture_extras(_on: bool) -> void:
	pass


## True while a detail change is still being applied (vegetation rebuilding).
func is_rebuilding() -> bool:
	return false


func vegetation_scale() -> float:
	return 1.0


## Replaces all instances of one mesh inside one region (region = pixel rect of the region).
func set_region_instances(_region_px: Rect2i, _mesh_id: int, _xforms: Array[Transform3D]) -> void:
	pass


## Pixel rectangles of all terrain regions (the unit of instance storage and re-scatter).
func region_rects() -> Array[Rect2i]:
	return []


func refresh_instances() -> void:
	pass


## World-space instance transforms of one region: {mesh_id: Array[Transform3D]}.
func region_instances(_region_px: Rect2i) -> Dictionary:
	return {}


## Re-seats instances on the ground after the terrain changed in a world rectangle.
## Ground triangles for navigation mesh baking inside an AABB (world space).
func nav_faces(_aabb: AABB) -> PackedVector3Array:
	return PackedVector3Array()


## Scattered instances (trees, rocks…) near a point: [{mesh_id, position}].
func instances_near(_pos: Vector3, _radius: float) -> Array:
	return []


## Removes the instance of mesh_id nearest to pos (within eps metres). True if removed.
func remove_instance_near(_mesh_id: int, _pos: Vector3, _eps: float) -> bool:
	return false


func snap_instances(_rect: Rect2) -> void:
	pass


## Short GPU grass around the camera, only on the given ground texture ids.
func enable_grass(_texture_id: int) -> void:
	pass


## The node terrain collision and detail follow (the player in the game).
## Terrain collision follows this node (radius in metres; 64 in the game).
func set_focus(_node: Node3D, _radius := 64.0) -> void:
	pass


func save_to(_dir: String) -> void:
	pass


func load_from(_dir: String) -> void:
	pass
