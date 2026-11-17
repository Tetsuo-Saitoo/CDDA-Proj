shader_type spatial;
// Gun fouling on the procedural viewmodel's parts (WeaponViewmodel, VrGun). The part's own look is the
// StandardMaterial3D it replaces (albedo, metallic, roughness, specular: same render modes, same outputs); `grime`
// 0..1 is GunGrime.grime_for(CDDA's `dirt`). The film and soot are grime.gdshaderinc's (the same as
// grime_overlay.gdshader over any model): the film rougher, less metallic and less shiny, the soot more so.
// grime 0 skips all of it (a uniform branch): exactly the plain material.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://scripts/combat/grime.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float grime : hint_range(0.0, 1.0) = 0.0;
uniform vec3 half_extents = vec3(0.05);   // the part's half size in its own space (m): box size / 2, cylinder (r, h/2, r)
uniform float blotch_scale = 45.0;        // noise cells per metre: blotches of about 2 cm

varying vec3 obj_pos;
varying vec3 obj_nrm;

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
}

void fragment() {
	vec3 col = albedo.rgb;
	float rough = roughness;
	float metal = metallic;
	float spec = specular;
	if (grime > 0.0) {
		float film;
		float soot;
		float shade;
		grime_cover(obj_pos, obj_nrm, half_extents, grime, blotch_scale, film, soot, shade);
		col = mix(col, grime_film_colour(col, shade), film);
		rough = mix(rough, 0.9, film);
		metal = mix(metal, 0.0, film);
		spec = mix(spec, 0.15, film);
		col = mix(col, GRIME_SOOT, soot);
		rough = mix(rough, 1.0, soot);
		metal = mix(metal, 0.0, soot);
		spec = mix(spec, 0.1, soot);
	}
	ALBEDO = col;
	METALLIC = metal;
	ROUGHNESS = rough;
	SPECULAR = spec;
}
