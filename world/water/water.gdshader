// Stylized water for ocean, lakes and rivers.
// - Ocean: gentle Gerstner waves, hidden outside the ocean mask (no ocean in inland basins).
// - Lakes: flat, hidden outside the (dilated) lake mask.
// - Rivers: UV.y runs downstream, normals scroll along it.
// Frozen water uses the separate ice material (ice.tres).
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

uniform int mode = 0; // 0 ocean, 1 lake, 2 river
uniform sampler2D water_mask : filter_linear, repeat_disable; // R ocean, G sea ice, B lake
uniform vec2 map_origin = vec2(-2048.0);
uniform float map_size = 4096.0;
uniform vec3 shallow_color : source_color = vec3(0.16, 0.58, 0.62);
uniform vec3 deep_color : source_color = vec3(0.02, 0.13, 0.27);
uniform vec3 foam_color : source_color = vec3(0.92, 0.97, 1.0);
uniform float depth_range = 14.0;
uniform float foam_width = 1.4;
uniform float wave_height = 0.5;
uniform float flow_speed = 0.6;
uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying vec3 wpos;

vec3 gerstner(vec2 p, vec2 dir, float steep, float wl, float t, inout vec3 tangent, inout vec3 binormal) {
	float k = 6.28318 / wl;
	float c = sqrt(9.8 / k);
	vec2 d = normalize(dir);
	float f = k * (dot(d, p) - c * t);
	float a = steep / k;
	tangent += vec3(-d.x * d.x * steep * sin(f), d.x * steep * cos(f), -d.x * d.y * steep * sin(f));
	binormal += vec3(-d.x * d.y * steep * sin(f), d.y * steep * cos(f), -d.y * d.y * steep * sin(f));
	return vec3(d.x * a * cos(f), a * sin(f), d.y * a * cos(f));
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (mode == 0) {
		vec2 uv = (wpos.xz - map_origin) / map_size;
		float ice = textureLod(water_mask, uv, 0.0).g;
		vec3 tng = vec3(1.0, 0.0, 0.0);
		vec3 bin = vec3(0.0, 0.0, 1.0);
		vec3 off = vec3(0.0);
		float s = wave_height * (1.0 - ice);
		off += gerstner(wpos.xz, vec2(1.0, 0.6), 0.10 * s, 38.0, TIME, tng, bin);
		off += gerstner(wpos.xz, vec2(-0.4, 1.0), 0.08 * s, 21.0, TIME, tng, bin);
		off += gerstner(wpos.xz, vec2(0.7, -0.9), 0.06 * s, 13.0, TIME, tng, bin);
		VERTEX += off;
		NORMAL = normalize(cross(bin, tng));
	}
}

void fragment() {
	vec2 uv = (wpos.xz - map_origin) / map_size;
	vec3 m = texture(water_mask, uv).rgb;
	if (mode == 0 && m.r < 0.5) discard;
	if (mode == 1 && m.b < 0.35) discard;

	// Scrolling detail normals (rivers scroll downstream along UV.y).
	vec2 p1, p2;
	if (mode == 2) {
		p1 = vec2(UV.x * 0.5, UV.y * 0.08 - TIME * flow_speed * 0.1);
		p2 = vec2(UV.x * 0.35 + 0.37, UV.y * 0.05 - TIME * flow_speed * 0.07);
	} else {
		p1 = wpos.xz * 0.045 + vec2(TIME * 0.012, TIME * 0.008);
		p2 = wpos.xz * 0.021 - vec2(TIME * 0.007, -TIME * 0.011);
	}
	vec3 n1 = texture(normal_a, p1).rgb;
	vec3 n2 = texture(normal_b, p2).rgb;
	NORMAL_MAP = normalize(mix(n1, n2, 0.5));
	NORMAL_MAP_DEPTH = 0.6;

	// Water depth below the surface from the depth buffer.
	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 world_floor = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * ndc;
	world_floor.xyz /= world_floor.w;
	float water_depth = max(wpos.y - world_floor.y, 0.0);
	float t = clamp(water_depth / depth_range, 0.0, 1.0);
	vec3 col = mix(shallow_color, deep_color, sqrt(t));
	float foam = 1.0 - smoothstep(0.0, foam_width, water_depth);
	foam *= 0.55 + 0.45 * sin(wpos.x * 0.35 + wpos.z * 0.27 + TIME * 1.3);
	vec3 refr = texture(screen_tex, SCREEN_UV + NORMAL_MAP.xy * 0.01).rgb;
	float clear = (1.0 - t) * 0.45;
	ALBEDO = mix(mix(col, refr * col * 1.6, clear), foam_color, clamp(foam, 0.0, 1.0) * 0.8);
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = clamp(0.75 + t * 0.25 + foam * 0.2, 0.0, 1.0);
	// Sea ice (ocean only): opaque, pale, with soft cracks.
	if (mode == 0 && m.g > 0.5) {
		float crack = smoothstep(0.92, 1.0, abs(n1.x - n2.y) * 2.2);
		ALBEDO = mix(vec3(0.86, 0.93, 0.98), vec3(0.62, 0.78, 0.9), crack * 0.7 + t * 0.15);
		ROUGHNESS = 0.35;
		NORMAL_MAP_DEPTH = 0.2;
		ALPHA = 1.0;
	}
}
