// C5: the warning sign inside each VehicleView mark: a rounded yellow triangle with a black rounded border and a
// black exclamation mark, drawn from distance fields on a quad that faces the camera; fades out with distance.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 yellow : source_color = vec3(1.0, 0.8, 0.05);
uniform vec3 ink : source_color = vec3(0.03, 0.03, 0.03);
uniform float opacity = 0.95;
uniform float fade_near = 30.0;
uniform float fade_far = 70.0;

const float R = 0.74;        // the triangle's half side (its middle at 0, 0)
const float ROUND = 0.16;    // corner rounding
const float BORDER = 0.11;   // the black edge's width
const float LIFT = 0.2135;   // moves the rounded triangle's middle to the quad's

void vertex() {
	// face the camera (keeps the instance's position; the quad's own size)
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

// Equilateral triangle of half side r, point up, middle at the origin (signed distance).
float triangle(vec2 p, float r) {
	const float k = 1.7320508;
	p.x = abs(p.x) - r;
	p.y = p.y + r / k;
	if (p.x + k * p.y > 0.0) {
		p = vec2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
	}
	p.x -= clamp(p.x, -2.0 * r, 0.0);
	return -length(p) * sign(p.y);
}

float segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

void fragment() {
	vec2 p = (UV - 0.5) * vec2(2.0, -2.0) + vec2(0.0, LIFT);   // -1..1 across, y up
	float edge = triangle(p, R) - ROUND;
	float aa = max(fwidth(edge), 1e-4);
	float shape = 1.0 - smoothstep(-aa, aa, edge);
	float inside = 1.0 - smoothstep(-aa, aa, edge + BORDER);
	float mark = min(segment(p, vec2(0.0, 0.05), vec2(0.0, 0.4)) - 0.07, length(p - vec2(0.0, -0.16)) - 0.075);
	float ink_mark = 1.0 - smoothstep(-aa, aa, mark);
	float fade = 1.0 - smoothstep(fade_near, fade_far, length(VERTEX));
	ALBEDO = mix(ink, yellow, inside * (1.0 - ink_mark));
	ALPHA = shape * opacity * fade;
}
