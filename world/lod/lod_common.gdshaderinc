// Per-object level of detail on the GPU. Every object (MultiMesh instance, or a building
// inside a merged mesh via CUSTOM0) measures its own distance to the *main* camera — also
// in shadow passes — and collapses to a point outside its band [lod_begin, lod_end).
// Bands are in metres at detail scale 1; the global `lod_scale` (LodController) scales them.
global uniform float lod_scale;
uniform float lod_begin = 0.0;
uniform float lod_end = 100000.0;
uniform bool center_from_custom0 = false;
uniform float lod_begin_abs = -1.0;  // if >= 0: begin in metres, not scaled (see ImpostorLayer)

bool lod_hidden(vec3 center, mat4 main_cam_inv_view) {
	float d = distance(center, main_cam_inv_view[3].xyz);
	float begin = lod_begin_abs >= 0.0 ? lod_begin_abs : lod_begin * lod_scale;
	return d < begin || d >= lod_end * lod_scale;
}
