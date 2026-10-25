// Far-distance tree cards. One MultiMesh holds every species of a region; each instance's
// INSTANCE_CUSTOM is its species' rectangle in the shared impostor atlas.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert;
#include "res://world/lod/lod_common.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform float alpha_cut = 0.45;
varying vec4 cell;

void vertex() {
	cell = INSTANCE_CUSTOM;
	if (lod_hidden(MODEL_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX)) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec4 c = texture(atlas, cell.xy + UV * cell.zw);
	ALBEDO = c.rgb * tint.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	ROUGHNESS = 1.0;
	SPECULAR = 0.1;
}
