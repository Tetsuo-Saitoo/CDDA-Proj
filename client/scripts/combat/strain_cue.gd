class_name StrainCue
extends ColorRect
## F3: the player's pain and lack of stamina at the edges of the view (the flat screen's; VR has its own view), from
## HudData's needs (the snapshot's `player_needs.pain`, CDDA's perceived pain, and stamina as a percentage of its
## maximum). Pain greys and softly blurs the edges, from PAIN_FROM (CDDA's "mild pain") to full at PAIN_FULL ("severe
## pain"); stamina under STAMINA_FROM percent darkens them, fully at 0. The middle of the view stays clear. Both fade
## at FADE_PER_S, never flash or pulse. Off with `enabled` (HudSettings.hurt_cues, with the hurt tint): they fade out.
## Drawn between MoodCue and HurtCue.

const PAIN_FROM := 10         # perceived pain where the cue starts
const PAIN_FULL := 60         # and where it is full
const STAMINA_FROM := 25      # stamina percent under which the edges darken
const GREY_MAX := 0.75        # how grey the corners get at full pain (0 = colour, 1 = grey)
const BLUR_PX := 3.0          # the corners' blur radius at full pain, in screen pixels
const DARK_ALPHA := 0.45      # the corners' darkening at no stamina
const FADE_PER_S := 0.5       # level a second, either way (two seconds from nothing to full)
const SHADER := "shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float pain = 0.0;
uniform float tired = 0.0;
uniform float grey_max = 0.75;
uniform float blur_px = 3.0;
uniform float dark_alpha = 0.45;
void fragment() {
	float edge = smoothstep(0.45, 1.0, distance(UV, vec2(0.5)) / 0.7071);
	vec2 r = SCREEN_PIXEL_SIZE * blur_px * pain * edge;
	vec3 c = texture(screen_tex, SCREEN_UV).rgb * 0.4;
	c += texture(screen_tex, SCREEN_UV + vec2(r.x, r.y)).rgb * 0.15;
	c += texture(screen_tex, SCREEN_UV + vec2(-r.x, r.y)).rgb * 0.15;
	c += texture(screen_tex, SCREEN_UV + vec2(r.x, -r.y)).rgb * 0.15;
	c += texture(screen_tex, SCREEN_UV + vec2(-r.x, -r.y)).rgb * 0.15;
	float g = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(g), grey_max * pain * edge);
	c *= 1.0 - dark_alpha * tired * edge;
	COLOR = vec4(c, 1.0);
}
"

var data: HudData             # the needs (pain, stamina); may be null
var enabled := true
## The levels drawn now, 0..1, following pain_level() / tired_level().
var pain_shown := 0.0
var tired_shown := 0.0


func _init() -> void:
	name = "StrainCue"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 0)
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("grey_max", GREY_MAX)
	mat.set_shader_parameter("blur_px", BLUR_PX)
	mat.set_shader_parameter("dark_alpha", DARK_ALPHA)
	material = mat
	visible = false


func _process(delta: float) -> void:
	step(delta)


## Perceived pain `pain` as the cue's level: 0 up to PAIN_FROM, 1 from PAIN_FULL; 0 for junk.
static func pain_for(pain: Variant) -> float:
	if not (pain is int or (pain is float and is_finite(pain))):
		return 0.0
	return clampf((float(pain) - PAIN_FROM) / (PAIN_FULL - PAIN_FROM), 0.0, 1.0)


## Stamina `pct` (percent of the maximum) as the cue's level: 0 from STAMINA_FROM, 1 at 0; 0 for junk.
static func tired_for(pct: Variant) -> float:
	if not (pct is int or (pct is float and is_finite(pct))):
		return 0.0
	return clampf((STAMINA_FROM - float(pct)) / STAMINA_FROM, 0.0, 1.0)


## The pain level to fade toward: 0 when off, unknown or not sent.
func pain_level() -> float:
	return pain_for(_need("pain")) if enabled else 0.0


## The stamina level to fade toward: 0 when off, unknown or not sent.
func tired_level() -> float:
	return tired_for(_need("stamina")) if enabled else 0.0


func _need(key: String) -> Variant:
	if data == null:
		return null
	var n: Variant = data.needs.get(key)
	if not n is Dictionary or (n as Dictionary).get("level", HudData.UNKNOWN) == HudData.UNKNOWN:
		return null
	return (n as Dictionary).get("value")


## Moves both shown levels toward theirs for `delta` seconds and draws them (hidden while both are 0).
func step(delta: float) -> void:
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	pain_shown = move_toward(pain_shown, pain_level(), FADE_PER_S * d)
	tired_shown = move_toward(tired_shown, tired_level(), FADE_PER_S * d)
	visible = pain_shown > 0.0 or tired_shown > 0.0
	var m := material as ShaderMaterial
	m.set_shader_parameter("pain", pain_shown)
	m.set_shader_parameter("tired", tired_shown)
