## Placeholder visual effects: bullet tracers, impact marks with a puff, muzzle flashes.
class_name CombatFx
extends RefCounted

static var _tracer_mat: StandardMaterial3D
static var _puff_mat: StandardMaterial3D


static func tracer(parent: Node, from: Vector3, to: Vector3) -> void:
	if _tracer_mat == null:
		_tracer_mat = StandardMaterial3D.new()
		_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_tracer_mat.albedo_color = Color(1.0, 0.9, 0.6)
		_tracer_mat.vertex_color_use_as_albedo = true
		_tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, _tracer_mat)
	im.surface_set_color(Color(1, 0.9, 0.6, 0.0))
	im.surface_add_vertex(from)
	im.surface_set_color(Color(1, 0.95, 0.7, 0.9))
	im.surface_add_vertex(to)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.get_tree().create_timer(0.06).timeout.connect(mi.queue_free)


static func impact(parent: Node, pos: Vector3, normal: Vector3, flesh := false) -> void:
	# Mark: a small dark quad on the surface (stays a while).
	var mark := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.08, 0.08)
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.5, 0.05, 0.05, 0.9) if flesh else Color(0.08, 0.08, 0.08, 0.85)
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	q.material = mm
	mark.mesh = q
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mark)
	mark.global_position = pos + normal * 0.01
	if absf(normal.dot(Vector3.UP)) < 0.99:
		mark.look_at(pos + normal, Vector3.UP)
	else:
		mark.look_at(pos + normal, Vector3.FORWARD)
	mark.rotate_object_local(Vector3.UP, PI)
	mark.get_tree().create_timer(12.0).timeout.connect(mark.queue_free)
	# Puff: a few short-lived particles.
	if _puff_mat == null:
		_puff_mat = StandardMaterial3D.new()
		_puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_puff_mat.vertex_color_use_as_albedo = true
		_puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 10
	p.lifetime = 0.35
	p.explosiveness = 1.0
	p.direction = normal
	p.spread = 35.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0, -8, 0)
	p.scale_amount_min = 0.03
	p.scale_amount_max = 0.07
	p.color = Color(0.6, 0.1, 0.1) if flesh else Color(0.7, 0.65, 0.55)
	var pm := QuadMesh.new()
	pm.size = Vector2.ONE
	pm.material = _puff_mat
	p.mesh = pm
	parent.add_child(p)
	p.global_position = pos + normal * 0.02
	p.emitting = true
	p.get_tree().create_timer(1.0).timeout.connect(p.queue_free)


static func muzzle_flash(parent: Node3D) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.8, 0.45)
	l.light_energy = 4.0
	l.omni_range = 4.0
	parent.add_child(l)
	l.get_tree().create_timer(0.05).timeout.connect(l.queue_free)
