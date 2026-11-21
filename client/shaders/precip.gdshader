shader_type spatial;
// Rain and snow particles (PrecipView). A quad per drop, turned by the emitter: rain's long side along its fall
// (TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY), snow facing the camera.
// - streak (rain): seen along its fall, a streak shortens to a drop and fades a little, so looking up into the rain
//   shows drops coming at you, not falling sticks; seen from above it shortens less.
// - Never thinner than min_px pixels on screen: a far drop is widened and made fainter by as much (the same ink, no
//   shimmer), so the rain doesn't end where its drops get thinner than a pixel.
// - Fades out on the last metres to the camera (a drop at the eye would cover half the view) and, past fade_from,
//   with the distance from fade_centre (the far layer's edge).
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, ambient_light_disabled;

uniform vec4 color : source_color = vec4(0.8, 0.85, 0.95, 0.3);
uniform bool streak = true;
uniform float end_on_length = 0.15;   // share of a streak's length left seen straight along its fall
uniform float end_on_alpha = 0.6;     // and of its alpha
uniform float min_px = 1.0;
uniform float near_gone = 0.7;
uniform float near_full = 2.5;
uniform vec3 fade_centre = vec3(0.0);  // world space
uniform float fade_from = 1.0e6;       // metres from fade_centre (level): full up to here
uniform float fade_to = 2.0e6;         // and gone from here on

varying float v_alpha;

void vertex() {
	vec3 centre = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 axis_x = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
	vec3 axis_y = (MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	vec3 to_eye = CAMERA_POSITION_WORLD - centre;
	float dist = max(length(to_eye), 1.0e-4);
	float a = 1.0;
	vec3 v = VERTEX;
	if (streak) {
		// > 0: the drop comes at the camera (looking up into the rain); < 0: falls away from it (looking down)
		float along = dot(axis_y / max(length(axis_y), 1.0e-6), to_eye / dist);
		float k = along > 0.0 ? smoothstep(0.5, 0.95, along) : smoothstep(0.85, 0.99, -along);
		v.y *= mix(1.0, end_on_length, k);
		a *= mix(1.0, end_on_alpha, k);
	}
	// metres one pixel covers at this distance (perspective; the projection may be flipped)
	float px_m = 2.0 * dist / (max(VIEWPORT_SIZE.y, 1.0) * max(abs(PROJECTION_MATRIX[1][1]), 1.0e-4));
	float width = abs(VERTEX.x) * 2.0 * length(axis_x);
	if (width > 0.0 && min_px * px_m > width) {
		float grow = min(min_px * px_m / width, 64.0);   // bounded, whatever the matrices say
		v.x *= grow;
		a /= grow;
		if (!streak) {   // a dot widens both ways
			v.y *= grow;
			a /= grow;
		}
	}
	a *= smoothstep(near_gone, near_full, dist);
	a *= 1.0 - smoothstep(fade_from, fade_to, length(centre.xz - fade_centre.xz));
	v_alpha = a;
	VERTEX = v;
}

void fragment() {
	float a = color.a * v_alpha;
	if (streak) {
		float t = abs(UV.y * 2.0 - 1.0);
		a *= 1.0 - t * t * t * t;   // soft ends
	} else {
		a *= 1.0 - smoothstep(0.35, 1.0, length(UV * 2.0 - 1.0));   // a soft round dot
	}
	ALBEDO = color.rgb;
	ALPHA = a;
}
