class_name HurtCue
extends ColorRect
## F3: the player's hurt at the edges of the view (the flat screen's; VR has its own view). Damage to the player
## (HitFeedback.player_hurt) raises it by the hit's size; a bleeding body part (Snapshot.player_parts) keeps a faint
## floor. A dark red tint on the edges only, the middle of the view stays clear. It rises over RISE_PER_S and fades
## over FADE_PER_S; it never flashes or pulses: hits coming fast hold it up instead of blinking. Off with `enabled`
## (it fades out). MoodCue draws the mood's tint the same way, under it.

const TINT := Color(0.45, 0.0, 0.0)
const MAX_ALPHA := 0.3        # the corners' opacity at full level
const BLEED_LEVEL := 0.25     # the level kept while a body part bleeds
const HIT_FULL := 20.0        # damage that raises it to full at once
const HIT_MIN := 0.3          # the least one hit raises it by
const RISE_PER_S := 6.0       # level a second going up (about 0.17 s to full)
const FADE_PER_S := 0.6       # and going down (about 1.7 s from full)

var world: WorldView          # the player's bleeding (snapshot); may be null
var enabled := true
## The level drawn now, 0..1, following target().
var shown := 0.0
## What the hits ask for, 0..1, fading.
var peak := 0.0


func _init() -> void:
	name = "HurtCue"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(0, 0, 0, 0)
	var sh := Shader.new()
	sh.code = MoodCue.SHADER   # the same edge-only tint
	var mat := ShaderMaterial.new()
	mat.shader = sh
	material = mat
	visible = false


func _process(delta: float) -> void:
	step(delta)


## The player took `amount` damage: the level asked for goes up by its share of HIT_FULL (at least HIT_MIN), at
## most to 1. Nothing while off or for no damage.
func hurt(amount: int) -> void:
	if not enabled or amount <= 0:
		return
	peak = minf(maxf(peak, shown) + maxf(HIT_MIN, float(amount) / HIT_FULL), 1.0)


## BLEED_LEVEL while one of the player's body parts bleeds, else 0.
func bleed_floor() -> float:
	if world == null or world.snapshot == null:
		return 0.0
	for b: Snapshot.BodyPart in world.snapshot.player_parts:
		if b.bleed > 0:
			return BLEED_LEVEL
	return 0.0


## The level to move toward: the hits' fading peak or the bleeding floor; 0 while off.
func target() -> float:
	if not enabled:
		return 0.0
	return clampf(maxf(peak, bleed_floor()), 0.0, 1.0)


## The tint for level `k`: TINT with the corners' opacity as alpha.
static func tint_for(k: float) -> Color:
	if not is_finite(k) or k <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(TINT, MAX_ALPHA * minf(k, 1.0))


## Moves the shown level toward the target for `delta` seconds (up fast, down slowly) and draws it (hidden at 0).
func step(delta: float) -> void:
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	peak = maxf(peak - FADE_PER_S * d, 0.0)
	if not enabled:
		peak = 0.0
	var t := target()
	shown = move_toward(shown, t, (RISE_PER_S if t > shown else FADE_PER_S) * d)
	var c := tint_for(shown)
	visible = c.a > 0.0
	(material as ShaderMaterial).set_shader_parameter("tint", c)
