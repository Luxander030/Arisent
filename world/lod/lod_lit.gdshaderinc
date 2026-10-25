// Lit body shared by lod_lit.gdshader (one-sided) and lod_lit_2s.gdshader (two-sided).
#include "res://world/lod/lod_common.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_texture = false;
uniform bool use_instance_color = false;  // roofs: colour per building
uniform vec3 tint_palette[8];             // merged meshes: CUSTOM0.w = palette index (-1 = none)
varying vec3 tint;
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

void vertex() {
	vec3 center = center_from_custom0 ? CUSTOM0.xyz : MODEL_MATRIX[3].xyz;
	tint = COLOR.rgb;  // MultiMesh instance colour
	if (center_from_custom0) {
		int k = int(round(CUSTOM0.w));
		tint = k >= 0 ? tint_palette[clamp(k, 0, 7)] : vec3(1.0);
	}
	if (lod_hidden(center, MAIN_CAM_INV_VIEW_MATRIX)) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec4 c = albedo;
	if (use_texture) {
		c *= texture(albedo_texture, UV);
	}
	if (use_instance_color) {
		c.rgb *= tint;
	}
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
