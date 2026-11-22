// C5: where CDDA really has a turned vehicle (VehicleView marks): a translucent yellow block per square the rigid
// model doesn't line up with, strongest at the ground and fading upward, fading out with distance and close to the
// camera (in VR the head is never inside a yellow volume). Drawn from both sides so its floor shows from above
// through the faint top.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 colour : source_color = vec3(1.0, 0.8, 0.08);
uniform float strength = 0.3;      // alpha at the ground
uniform float height = 1.6;        // the block's height (its mesh is centred: VERTEX.y is -height/2 .. height/2)
uniform float fade_near = 30.0;    // metres from the camera where it starts to fade
uniform float fade_far = 70.0;     // and is gone
uniform float close_gone = 1.0;    // metres from the block's middle to the camera (its centre): gone this close
uniform float close_full = 1.6;    // and whole from here
uniform float near_gone = 0.3;     // metres from the camera: a fragment this close is gone
uniform float near_full = 1.2;

varying float up;
varying float close;

void vertex() {
	up = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
	close = smoothstep(close_gone, close_full, distance(MODEL_MATRIX[3].xyz, MAIN_CAM_INV_VIEW_MATRIX[3].xyz));
}

void fragment() {
	float d = length(VERTEX);
	float fade = (1.0 - smoothstep(fade_near, fade_far, d)) * smoothstep(near_gone, near_full, d);
	ALBEDO = colour;
	ALPHA = strength * (1.0 - up) * (1.0 - up) * fade * close;
}
