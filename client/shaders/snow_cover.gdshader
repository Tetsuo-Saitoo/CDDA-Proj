shader_type spatial;
// Snow lying on the open ground and roofs (TerrainMesher.snow_ground): a pass over the ground material, white on
// what faces up, in patches that grow with `cover` until they close. The patches are value noise over the map's own
// metres (`origin_m`: the bubble's origin, modulo PERIOD, which the noise repeats at), so they stay put when the
// bubble shifts. Drawn before the light pass (render_priority), so it is dark at night like the ground under it.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float cover : hint_range(0.0, 1.0) = 0.0;
uniform vec2 origin_m = vec2(0.0);
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.97);

const float PERIOD = 512.0;

varying vec3 world_pos;
varying float up;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
}

float hash(vec2 c) {
	return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise over cells of 1, repeating every `cells` cells.
float noise(vec2 p, float cells) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(mod(i, cells));
	float b = hash(mod(i + vec2(1.0, 0.0), cells));
	float c = hash(mod(i + vec2(0.0, 1.0), cells));
	float d = hash(mod(i + vec2(1.0, 1.0), cells));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	vec2 p = world_pos.xz + origin_m;
	float n = 0.7 * noise(p * 0.5, PERIOD * 0.5) + 0.3 * noise(p * 2.0, PERIOD * 2.0);
	// cover 0: nowhere; 1: everywhere (n is 0..1).
	float lying = smoothstep(n - 0.1, n + 0.1, cover * 1.2 - 0.1);
	ALBEDO = snow_color;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
	ALPHA = lying * smoothstep(0.5, 0.8, up);
}
