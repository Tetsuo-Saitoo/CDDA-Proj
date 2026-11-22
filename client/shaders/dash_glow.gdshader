// C5 interiors: a vehicle's dial faces and needles (CarDash): coloured per vertex, with a soft backlight while the
// dash is lit (`glow` per instance: 0 dark, 1 lit), so one material serves every car.
shader_type spatial;
render_mode cull_back;

instance uniform float glow = 0.0;
uniform float backlight = 1.4;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.55;
	EMISSION = COLOR.rgb * glow * backlight;
}
