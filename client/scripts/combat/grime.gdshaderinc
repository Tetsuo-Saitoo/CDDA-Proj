// Gun fouling coverage, shared by grime.gdshader (a part's own material) and grime_overlay.gdshader (over any
// model's materials), so both look the same. `g` 0..1 is CDDA's item var `dirt` / 10000 (GunGrime.grime_for).
// Blotches come from value-noise fbm of the object-space position (no textures, no UVs), so they stay put while
// the gun moves:
// - a darker, desaturated brown-grey film whose coverage grows with grime: thin and patchy at 0.2, most of the
//   surface at 0.4, all of it from 0.6;
// - from 0.5 up, sooty black build-up that starts along the edges of the part's box (`half`: its half size around
//   the object-space origin; a cylinder's rims and muzzle) and spreads into crusty patches toward 1.0.
// Cost: at most 4 value-noise lookups.

const vec3 GRIME_FILM_TINT = vec3(0.05, 0.04, 0.028);   // linear: dusty brown-grey
const vec3 GRIME_SOOT = vec3(0.012, 0.011, 0.01);        // linear: carbon black
const float GRIME_SOOT_FROM = 0.5;

float grime_hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float grime_value_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(grime_hash(i), grime_hash(i + vec3(1.0, 0.0, 0.0)), f.x),
			mix(grime_hash(i + vec3(0.0, 1.0, 0.0)), grime_hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
			mix(mix(grime_hash(i + vec3(0.0, 0.0, 1.0)), grime_hash(i + vec3(1.0, 0.0, 1.0)), f.x),
			mix(grime_hash(i + vec3(0.0, 1.0, 1.0)), grime_hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

// Spreads a noise sum (bunched around 0.5) over 0..1.
float grime_spread(float n, float k) {
	return clamp((n - 0.5) * k + 0.5, 0.0, 1.0);
}

// The film's and the soot's coverage (0..1) at object-space point `pos` with normal `nrm`, for grime `g` > 0 and
// `scale` noise cells per metre; `shade` (0..1, a middle octave) darkens the film in places.
void grime_cover(vec3 pos, vec3 nrm, vec3 half, float g, float scale, out float film, out float soot,
		out float shade) {
	vec3 p = pos * scale;
	float o1 = grime_value_noise(p);
	float o2 = grime_value_noise(p * 2.03 + vec3(17.1, 3.7, 9.2));
	float o3 = grime_value_noise(p * 4.07 + vec3(5.3, 31.7, 12.9));
	float n = grime_spread((o1 * 0.5 + o2 * 0.25 + o3 * 0.125) / 0.875, 2.2);
	// The film: its threshold slides down through the noise as grime grows; its strength fades in from 0.
	float t = 1.0 - 1.5 * g;
	film = smoothstep(t - 0.2, t + 0.2, n) * min(g * 2.0, 0.85);
	shade = o2;
	soot = 0.0;
	if (g > GRIME_SOOT_FROM) {
		float s = (g - GRIME_SOOT_FROM) / (1.0 - GRIME_SOOT_FROM);   // 0 at 0.5, 1 at 1.0
		// Distance to the nearest edge: per axis, to the pair of faces; the face we're on (the normal's axis) left
		// out.
		vec3 d = half - abs(pos) + abs(normalize(nrm)) * 10.0;
		float edge = 1.0 - smoothstep(0.0, 0.003 + 0.004 * o2, min(d.x, min(d.y, d.z)));
		// Patches the size of the blotches, ragged at their rims by a finer octave.
		float crust = grime_spread(o1 * 0.45 + o2 * 0.3 + grime_value_noise(p * 8.3 + vec3(2.9, 7.1, 23.3)) * 0.25,
				2.2);
		float th = 1.2 - 0.9 * s;   // edges first, then crusty patches
		soot = smoothstep(th - 0.1, th + 0.1, edge * 0.6 + crust * 0.7) * smoothstep(0.0, 0.15, s);
	}
}

// The film's colour over a surface of this linear colour.
vec3 grime_film_colour(vec3 under, float shade) {
	float lum = dot(under, vec3(0.2126, 0.7152, 0.0722));
	return mix(vec3(lum), GRIME_FILM_TINT, 0.5) * mix(0.45, 0.8, shade);
}
