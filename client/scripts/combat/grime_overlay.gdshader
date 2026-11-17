shader_type spatial;
// Gun fouling over any model (GunGrime.apply): a shell over a mesh (the same mesh, pushed out by `push` along its
// normals so it never fights the surface's depth), leaving the model's own materials and material_overlay alone, so a
// .glb gun, a prop placeholder or a grabbed item's outline all keep working. Same film and soot as grime.gdshader
// (grime.gdshaderinc), composited over the surface: the film's colour is taken over a mid grey (the shell can't read
// the surface under it). `grime` 0..1 is GunGrime.grime_for(CDDA's `dirt`); the noise and the soot's edges are in
// the mesh's own space, around the centre of its box (`box_centre`, `half_extents`: GunGrime sets them from the
// mesh's AABB). GunGrime removes the shell at grime 0, so a clean gun costs nothing.
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://scripts/combat/grime.gdshaderinc"

uniform float grime : hint_range(0.0, 1.0) = 0.0;
uniform vec3 box_centre = vec3(0.0);
uniform vec3 half_extents = vec3(0.05);
uniform float blotch_scale = 45.0;        // noise cells per metre: blotches of about 2 cm
uniform float push = 0.0004;              // m out along the normals: 0.4 mm

const vec3 UNDER = vec3(0.1);             // linear mid grey, for the film's colour

varying vec3 obj_pos;
varying vec3 obj_nrm;

void vertex() {
	obj_pos = VERTEX - box_centre;
	obj_nrm = NORMAL;
	VERTEX += NORMAL * push;
}

void fragment() {
	float film = 0.0;
	float soot = 0.0;
	float shade = 0.5;
	if (grime > 0.0) {
		grime_cover(obj_pos, obj_nrm, half_extents, grime, blotch_scale, film, soot, shade);
	}
	// The film, then the soot over it, as one layer: what mix(mix(under, film_col, film), soot_col, soot) adds.
	float a = 1.0 - (1.0 - film) * (1.0 - soot);
	if (a <= 0.002) {
		discard;
	}
	vec3 film_col = grime_film_colour(UNDER, shade);
	ALBEDO = (film_col * film * (1.0 - soot) + GRIME_SOOT * soot) / a;
	ALPHA = a;
	float sooty = soot / a;
	METALLIC = 0.0;
	ROUGHNESS = mix(0.9, 1.0, sooty);
	SPECULAR = mix(0.15, 0.1, sooty);
}
