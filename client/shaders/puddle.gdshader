shader_type spatial;
// Puddles on the open ground (TerrainMesher._puddle, puddle_ground). Each is a flat disc. Its vertices carry their
// offset from its centre (UV) and the level it starts to fill at (COLOR.a; COLOR.r is 0 at the centre, 1 at the
// rim). `level` is the weather's (0 none .. 1 full): a puddle grows from nothing at its own level to its full size
// at 1; below that its disc shrinks to a point and draws nothing. Still water with a soft rim that mirrors the
// grey sky, more of it toward the horizon (a cheap stand-in for a reflection; lit like the ground): paler than
// dark asphalt, darker than pale paving.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float level : hint_range(0.0, 1.0) = 0.0;
uniform vec3 water_color : source_color = vec3(0.05, 0.06, 0.07);
uniform vec3 sky_tint : source_color = vec3(0.62, 0.66, 0.72);
uniform float opacity : hint_range(0.0, 1.0) = 0.85;

varying float rim;

void vertex() {
	float start = COLOR.a;
	float grown = clamp((level - start) / max(1.0 - start, 0.05), 0.0, 1.0);
	VERTEX.xz -= UV * (1.0 - sqrt(grown));   // the area grows with the level
	rim = COLOR.r;
}

void fragment() {
	float mirror = mix(0.45, 1.0, pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0));
	ALBEDO = mix(water_color, sky_tint, mirror);
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
	ALPHA = opacity * (1.0 - smoothstep(0.7, 1.0, rim));
}
