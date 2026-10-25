## Offline mesh simplification for LOD generation.
## 1) Godot's built-in simplifier (meshoptimizer via ImporterMesh) when it reaches the target;
## 2) otherwise vertex clustering (snap vertices to a grid, drop collapsed triangles),
##    which also works on tiny low-poly meshes that meshoptimizer refuses to touch.
class_name MeshSimplifier
extends RefCounted


static func triangle_count(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		n += idx.size() / 3 if not idx.is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## All MeshInstance3Ds of a scene merged into one mesh (transforms baked, one surface per material).
static func merged_from_scene(scene: PackedScene) -> ArrayMesh:
	var inst := scene.instantiate()
	var tools := {}
	_collect(inst, Transform3D(), tools)
	inst.free()
	var mesh := ArrayMesh.new()
	for mat in tools:
		var st: SurfaceTool = tools[mat]
		st.index()
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh


static func _collect(n: Node, parent: Transform3D, tools: Dictionary) -> void:
	var xf := parent
	if n is Node3D:
		xf = parent * (n as Node3D).transform
	if n is MeshInstance3D:
		var m: Mesh = (n as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var mat := (n as MeshInstance3D).get_active_material(s)
			if not tools.has(mat):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				tools[mat] = st
			(tools[mat] as SurfaceTool).append_from(m, s, xf)
	for c in n.get_children():
		_collect(c, xf, tools)


## A simplified copy with roughly `ratio` of the triangles, keeping the overall shape:
## if the result's bounding box shrinks too much, retry with a gentler reduction.
static func simplify(mesh: ArrayMesh, ratio: float) -> ArrayMesh:
	var r := ratio
	for attempt in 5:
		var m := _simplify_once(mesh, r)
		if keeps_shape(mesh, m):
			return m
		r = minf(1.0, r * 1.6)
	return mesh.duplicate() as ArrayMesh


## Same outline (bounding box) and most of the surface kept — rejects slivers.
static func keeps_shape(original: Mesh, simplified: Mesh) -> bool:
	if simplified == null or simplified.get_surface_count() == 0:
		return false
	var a := original.get_aabb().size
	var b := simplified.get_aabb().size
	for i in 3:
		if a[i] > 0.01 and b[i] < a[i] * 0.85:
			return false
	return surface_area(simplified) >= surface_area(original) * 0.6


static func surface_area(mesh: Mesh) -> float:
	var total := 0.0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := idx.size() if not idx.is_empty() else v.size()
		for t in range(0, count, 3):
			var p0 := v[idx[t] if not idx.is_empty() else t]
			var p1 := v[idx[t + 1] if not idx.is_empty() else t + 1]
			var p2 := v[idx[t + 2] if not idx.is_empty() else t + 2]
			total += (p1 - p0).cross(p2 - p0).length() * 0.5
	return total


static func _simplify_once(mesh: ArrayMesh, ratio: float) -> ArrayMesh:
	var src := triangle_count(mesh)
	var target := maxi(4, int(src * ratio))
	var best := _meshopt(mesh, target)
	if best == null or triangle_count(best) > target * 1.35:
		var clustered := _cluster_search(mesh, target)
		if best == null or absi(triangle_count(clustered) - target) < absi(triangle_count(best) - target):
			best = clustered
	return best


## Godot's built-in LOD generator; picks the LOD level closest to the target per surface.
static func _meshopt(mesh: ArrayMesh, target: int) -> ArrayMesh:
	var im := ImporterMesh.new()
	for s in mesh.get_surface_count():
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(s), [], {}, mesh.surface_get_material(s))
	im.generate_lods(60.0, 25.0, [])
	var ratio := float(target) / maxi(triangle_count(mesh), 1)
	var out := ArrayMesh.new()
	var any := false
	for s in im.get_surface_count():
		var arrays := im.get_surface_arrays(s)
		var full: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var want := int(full.size() / 3 * ratio)
		var pick := full
		for k in im.get_surface_lod_count(s):
			var idx := im.get_surface_lod_indices(s, k)
			if absi(idx.size() / 3 - want) < absi(pick.size() / 3 - want):
				pick = idx
				any = true
		arrays[Mesh.ARRAY_INDEX] = pick
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, im.get_surface_material(s))
	return out if any else null


## Binary-searches the clustering grid size to approach the target triangle count.
static func _cluster_search(mesh: ArrayMesh, target: int) -> ArrayMesh:
	var extent := mesh.get_aabb().size
	var size := maxf(extent.x, maxf(extent.y, extent.z))
	var lo := size * 0.002
	var hi := size * 0.6
	var best: ArrayMesh = cluster(mesh, lo)
	for it in 14:
		var mid := sqrt(lo * hi)
		var m := cluster(mesh, mid)
		var n := triangle_count(m)
		if absi(n - target) < absi(triangle_count(best) - target) and n > 0:
			best = m
		if n > target:
			lo = mid
		else:
			hi = mid
	return best


## Vertex clustering: vertices in the same grid cell merge to their average position;
## triangles that collapse are dropped. Each kept triangle keeps its source triangle's
## facing and authored normal (flat, low-poly look).
static func cluster(mesh: ArrayMesh, cell: float) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.is_empty():
			idx.resize(verts.size())
			for i in verts.size():
				idx[i] = i
		var key_of := {}
		var cluster_id := PackedInt32Array()
		cluster_id.resize(verts.size())
		var sums: Array[Vector3] = []
		var counts := PackedInt32Array()
		var first_uv: Array[Vector2] = []
		for i in verts.size():
			var key := Vector3i((verts[i] / cell).floor())
			var c: int = key_of.get(key, -1)
			if c < 0:
				c = sums.size()
				key_of[key] = c
				sums.append(Vector3.ZERO)
				counts.append(0)
				first_uv.append(uvs[i] if not uvs.is_empty() else Vector2.ZERO)
			sums[c] += verts[i]
			counts[c] += 1
			cluster_id[i] = c
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var seen := {}
		var added := 0
		for t in range(0, idx.size(), 3):
			var a := cluster_id[idx[t]]
			var b := cluster_id[idx[t + 1]]
			var c := cluster_id[idx[t + 2]]
			if a == b or b == c or a == c:
				continue
			var tri_key := Vector3i(a, b, c)
			if seen.has(tri_key):
				continue
			seen[tri_key] = true
			added += 1
			# Keep the original facing: collapsing can flip a triangle inside out.
			var orig_n := (verts[idx[t + 1]] - verts[idx[t]]).cross(verts[idx[t + 2]] - verts[idx[t]])
			var pa := sums[a] / counts[a]
			var pb := sums[b] / counts[b]
			var pc := sums[c] / counts[c]
			if (pb - pa).cross(pc - pa).dot(orig_n) < 0.0:
				var tmp := b
				b = c
				c = tmp
			# Flat shading with the authored normal of the source triangle.
			var face_n := orig_n.normalized()
			if not nrm.is_empty():
				var avg := nrm[idx[t]] + nrm[idx[t + 1]] + nrm[idx[t + 2]]
				if avg.length_squared() > 0.0001:
					face_n = avg.normalized()
			for v in [a, b, c]:
				st.set_normal(face_n)
				if not uvs.is_empty():
					st.set_uv(first_uv[v])
				st.add_vertex(sums[v] / counts[v])
		if added == 0:
			continue
		st.commit(out)
		out.surface_set_material(out.get_surface_count() - 1, mesh.surface_get_material(s))
	return out
