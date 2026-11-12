// Block C6: darkens what is drawn by CDDA's light (WorldLighting, LightMap). One full-screen pass, first in
// the transparent pass (render_priority), multiplying the colour buffer by the light of the tile each pixel
// shows: the world position comes back from the depth buffer, pushed half a metre along the surface normal
// so a wall face takes the tile it faces and a ceiling the room under it. Sky pixels get the sky multiplier.
// Works in multiview (VR): the depth and normal textures and INV_PROJECTION_MATRIX are per eye in Godot.
shader_type spatial;
render_mode unshaded, blend_mul, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest, repeat_disable;
// R8, 264 x 132 * levels: light at column x, vis at x + 132; level l at rows l * 132.
uniform sampler2D atlas : filter_nearest, repeat_disable;
// RGBA float, 256 x 4: the multiplier for (light, vis).
uniform sampler2D lut : filter_nearest, repeat_disable;
uniform vec3 origin = vec3(0.0);   // world position of bubble tile (0, 0) on level 0's floor
uniform int z_lo = 0;
uniform int levels = 0;
uniform vec3 outside_color = vec3(1.0);   // levels the atlas doesn't hold
uniform vec3 sky_color = vec3(1.0);
uniform float min_brightness = 0.0;
uniform float flash = 0.0;   // lightning: nothing, the sky included, is darker than this
// The scene's depth fog (WeatherView): where it covers the world, the pixel shows fog, which takes the sky's light,
// not the darkness of the tile behind it (an unseen square far off would be a black strip in the mist).
uniform float fog_begin = 0.0;
uniform float fog_end = 1.0;
uniform float fog_amount = 0.0;

const int SIZE = 132;
const float LEVEL_M = 3.0;
const float PUSH_M = 0.5;
const float EDGE = 0.3;   // half-width (tiles) of the blend at tile edges; inside it a tile has its own light

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

vec3 corner(float light, float vis) {
	return texelFetch(lut, ivec2(int(light * 255.0 + 0.5), int(vis * 255.0 + 0.5)), 0).rgb;
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec3 col = sky_color;
	if (depth > 1e-6) {   // reverse Z: the sky is at 0
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		view.xyz /= view.w;
		vec3 wp = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
		vec3 n = texture(normal_tex, SCREEN_UV).xyz * 2.0 - 1.0;
		if (dot(n, n) > 0.25) {
			wp += normalize((INV_VIEW_MATRIX * vec4(n, 0.0)).xyz) * PUSH_M;
		}
		vec3 p = wp - origin;
		int level = int(floor(p.y / LEVEL_M + 0.01)) - z_lo;
		if (level < 0 || level >= levels) {
			col = outside_color;
		} else {
			vec2 t = p.xz - 0.5;   // tile centres at whole numbers
			vec2 i = clamp(floor(t), vec2(0.0), vec2(float(SIZE - 2)));
			vec2 f = smoothstep(vec2(0.5 - EDGE), vec2(0.5 + EDGE), clamp(t - i, 0.0, 1.0));
			vec2 size = vec2(textureSize(atlas, 0));
			// The shared corner of texels i and i + 1: gather returns exactly those four, inside this level.
			vec2 uv = (i + 1.0 + vec2(0.0, float(level * SIZE))) / size;
			vec4 l = textureGather(atlas, uv, 0);
			vec4 v = textureGather(atlas, uv + vec2(float(SIZE) / size.x, 0.0), 0);
			// gather order: x (i0, j1), y (i1, j1), z (i1, j0), w (i0, j0)
			vec3 c00 = corner(l.w, v.w);
			vec3 c10 = corner(l.z, v.z);
			vec3 c01 = corner(l.x, v.x);
			vec3 c11 = corner(l.y, v.y);
			col = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
		}
		col = max(col, vec3(min_brightness));
		col = mix(col, sky_color, fog_amount * smoothstep(fog_begin, fog_end, length(view.xyz)));
	}
	ALBEDO = max(col, vec3(flash));
}
