shader_type spatial;
// Gun fouling on the first-person viewmodel (WeaponViewmodel). The part's own look is the StandardMaterial3D it
// replaces (albedo, metallic, roughness, specular: same render modes, same outputs); `grime` 0..1 is CDDA's item
// var `dirt` / 10000. Blotches come from value-noise fbm of the object-space position (no textures, no UVs), so
// they stay put on the part while it sways and kicks:
// - a darker, desaturated brown-grey film whose coverage grows with grime (rougher, less metallic, less shiny):
//   thin and patchy at 0.2, most of the surface at 0.4, all of it from 0.6;
// - from 0.5 up, sooty black build-up that starts along the part's edges and ends (distance to the edges of its
//   box, `half_extents`; a cylinder's rims and muzzle) and spreads into crusty patches toward 1.0.
// grime 0 skips all of it (a uniform branch): exactly the plain material. Cost: at most 4 value-noise lookups.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float grime : hint_range(0.0, 1.0) = 0.0;
uniform vec3 half_extents = vec3(0.05);   // the part's half size in its own space (m): box size / 2, cylinder (r, h/2, r)
uniform float blotch_scale = 45.0;        // noise cells per metre: blotches of about 2 cm

const vec3 FILM_TINT = vec3(0.05, 0.04, 0.028);   // linear: dusty brown-grey
const vec3 SOOT = vec3(0.012, 0.011, 0.01);        // linear: carbon black
const float SOOT_FROM = 0.5;

varying vec3 obj_pos;
varying vec3 obj_nrm;

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
}

float grime_hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float value_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(grime_hash(i), grime_hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(grime_hash(i + vec3(0.0, 1.0, 0.0)), grime_hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
			mix(mix(grime_hash(i + vec3(0.0, 0.0, 1.0)), grime_hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(grime_hash(i + vec3(0.0, 1.0, 1.0)), grime_hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

// Spreads a noise sum (bunched around 0.5) over 0..1.
float spread(float n, float k) {
	return clamp((n - 0.5) * k + 0.5, 0.0, 1.0);
}

void fragment() {
	vec3 col = albedo.rgb;
	float rough = roughness;
	float metal = metallic;
	float spec = specular;
	if (grime > 0.0) {
		vec3 p = obj_pos * blotch_scale;
		float o1 = value_noise(p);
		float o2 = value_noise(p * 2.03 + vec3(17.1, 3.7, 9.2));
		float o3 = value_noise(p * 4.07 + vec3(5.3, 31.7, 12.9));
		float n = spread((o1 * 0.5 + o2 * 0.25 + o3 * 0.125) / 0.875, 2.2);
		// The film: its threshold slides down through the noise as grime grows; its strength fades in from 0.
		float t = 1.0 - 1.5 * grime;
		float film = smoothstep(t - 0.2, t + 0.2, n) * min(grime * 2.0, 0.85);
		float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
		vec3 film_col = mix(vec3(lum), FILM_TINT, 0.5) * mix(0.45, 0.8, o2);
		col = mix(col, film_col, film);
		rough = mix(rough, 0.9, film);
		metal = mix(metal, 0.0, film);
		spec = mix(spec, 0.15, film);
		if (grime > SOOT_FROM) {
			float s = (grime - SOOT_FROM) / (1.0 - SOOT_FROM);   // 0 at 0.5, 1 at 1.0
			// Distance to the nearest edge: per axis, to the pair of faces; the face we're on (the normal's
			// axis) left out.
			vec3 d = half_extents - abs(obj_pos) + abs(normalize(obj_nrm)) * 10.0;
			float edge = 1.0 - smoothstep(0.0, 0.003 + 0.004 * o2, min(d.x, min(d.y, d.z)));
			// Patches the size of the blotches, ragged at their rims by a finer octave.
			float crust = spread(o1 * 0.45 + o2 * 0.3 + value_noise(p * 8.3 + vec3(2.9, 7.1, 23.3)) * 0.25, 2.2);
			float th = 1.2 - 0.9 * s;   // edges first, then crusty patches
			float soot = smoothstep(th - 0.1, th + 0.1, edge * 0.6 + crust * 0.7) * smoothstep(0.0, 0.15, s);
			col = mix(col, SOOT, soot);
			rough = mix(rough, 1.0, soot);
			metal = mix(metal, 0.0, soot);
			spec = mix(spec, 0.1, soot);
		}
	}
	ALBEDO = col;
	METALLIC = metal;
	ROUGHNESS = rough;
	SPECULAR = spec;
}
