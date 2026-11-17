shader_type spatial;
// Live item state on a 3D item (ItemLookView; values and colours from world/item_look.gd): frost when cold or
// frozen, a heat shimmer when hot, a spoilage tint, and the liquid in a see-through container up to its level.
// Drawn as a thin see-through shell over the item's own mesh (pushed out a little along its normals), before
// the light pass so it darkens with what is behind it.
render_mode blend_mix, depth_draw_never, cull_back, specular_disabled;

uniform float frost = 0.0;                       // 0 none, ItemLookView.COLD_FROST cold, 1 frozen
uniform float heat = 0.0;                        // 0 none, 1 hot
uniform vec4 tint = vec4(0.0);                   // spoilage: colour, and how much it covers (alpha)
uniform float level_y = -100000.0;               // world height of the liquid's surface (none: far below)
uniform vec4 liquid = vec4(0.5, 0.64, 0.82, 0.0); // its colour, and how much it shows through (alpha)
uniform vec3 frost_color : source_color = vec3(0.84, 0.93, 1.0);
uniform vec3 heat_color : source_color = vec3(1.0, 0.52, 0.18);
uniform float grow = 0.002;                      // m the shell stands off the surface

varying vec3 world_pos;

void vertex() {
	float scale = max(length(MODEL_MATRIX[0].xyz), 0.0001);
	float wobble = heat * 0.0015 * sin(TIME * 7.0 + VERTEX.y / scale * 60.0);   // the air above it quivers
	VERTEX += NORMAL * (grow + wobble) / scale;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// `rgb` with opacity `a` laid over `dst` (straight alpha).
vec4 over(vec4 dst, vec3 rgb, float a) {
	float oa = a + dst.a * (1.0 - a);
	return vec4((rgb * a + dst.rgb * dst.a * (1.0 - a)) / max(oa, 0.0001), oa);
}

void fragment() {
	float rim = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	vec4 c = vec4(0.0);
	if (world_pos.y < level_y) {
		c = vec4(liquid.rgb, liquid.a);
	}
	c = over(c, tint.rgb, tint.a);
	float sparkle = step(0.97, hash(floor(world_pos * 220.0)));
	c = over(c, frost_color, clamp(frost * (0.2 + 0.5 * rim * rim + 0.6 * sparkle), 0.0, 0.85));
	float band = 0.5 + 0.5 * sin(world_pos.y * 55.0 - TIME * 5.0 + 1.5 * sin(world_pos.x * 31.0 + world_pos.z * 23.0 + TIME * 2.0));
	float h = heat * (0.08 + 0.3 * band * (0.3 + rim));
	c = over(c, heat_color, h);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	EMISSION = heat_color * h * 0.4;
}
