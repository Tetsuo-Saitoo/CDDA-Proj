class_name MoodCue
extends ColorRect
## G1: a subtle screen cue of the player's mood (HudData.mood["cue"], -1..1; 0 while the mood is calm). Low mood
## darkens the edges of the view with a cold tint, high mood warms them faintly; the middle of the view stays
## clear. It fades toward the mood's cue, never pulses or flashes, and is off with `enabled` (HudSettings.mood_cues,
## the F1 menu). It draws nothing but the tint: the mood's words are HudView's line.

const LOW_TINT := Color(0.04, 0.06, 0.12)
const HIGH_TINT := Color(1.0, 0.86, 0.55)
## The tint's opacity at the corners at the lowest / highest mood.
const LOW_ALPHA := 0.4
const HIGH_ALPHA := 0.12
## Cue units a second: a full change fades over two seconds.
const FADE_PER_S := 0.5
const SHADER := "shader_type canvas_item;
uniform vec4 tint : source_color = vec4(0.0);
void fragment() {
	float d = distance(UV, vec2(0.5)) / 0.7071;
	COLOR = vec4(tint.rgb, tint.a * smoothstep(0.55, 1.0, d));
}
"

var data: HudData
var enabled := true
## The cue drawn now, following the mood's.
var shown := 0.0


func _init() -> void:
	name = "MoodCue"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 0)
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	material = mat
	visible = false


func _process(delta: float) -> void:
	step(delta)


## The cue to fade toward: the mood's, 0 when off, unknown or not a number.
func target() -> float:
	if not enabled or data == null or data.mood.is_empty():
		return 0.0
	var c: Variant = data.mood.get("cue")
	return clampf(c, -1.0, 1.0) if c is float and is_finite(c) else 0.0


## The tint for cue `c`: its colour, with the opacity at the screen's corners as alpha.
static func tint_for(c: float) -> Color:
	if not is_finite(c) or is_zero_approx(c):
		return Color(0, 0, 0, 0)
	var k := clampf(absf(c), 0.0, 1.0)
	return Color(LOW_TINT, LOW_ALPHA * k) if c < 0.0 else Color(HIGH_TINT, HIGH_ALPHA * k)


## Moves the shown cue toward the target for `delta` seconds and draws it (hidden at 0).
func step(delta: float) -> void:
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	shown = move_toward(shown, target(), FADE_PER_S * d)
	var t := tint_for(shown)
	visible = t.a > 0.0
	(material as ShaderMaterial).set_shader_parameter("tint", t)
