class_name VrMood
extends MeshInstance3D
## Player mood in VR (VrRig `mood`, on the XR camera): HudData.mood's cue (-1..1, 0 while calm) as a soft edge in the
## headset, as the flat view's MoodCue does on screen: low mood darkens the edges with a cold tint, high mood warms
## them faintly; the middle of the view stays clear. It fades toward the cue (a full change over about two seconds),
## never pulses or flashes. Its own ring, behind the hurt edge and the tunnel vignette (farther from the eyes and a
## lower render priority, so both cover it). Off with the VR setting `mood_cues` (VrRig.place_hud), hidden while the
## camera isn't the headset's view. It reads the wrist HUD's HudData (VrRig.hud.data): the snapshot isn't read again.

const ALPHA_SCALE := 0.75    # MoodCue's opacities a little lighter in the headset: at most 0.3 low, 0.09 high
const DIST := 0.22           # m in front of the eyes (VrHurt at 0.21, the tunnel vignette at VrRig.VIGNETTE_DIST, 0.2)
const PRIORITY := 98         # under VrHurt's 99 and the vignette's 100
const HOLE := 0.17           # m: clear inside this radius at DIST (about 38 degrees off the view's middle) ...
const FULL := 2.2            # ... full from this many HOLEs on

var rig: VrRig               # its hud's HudData is the source; null: nothing shown
var enabled := true          # VrSettings `mood_cues` (VrRig.place_hud)
var assume_view := false     # tests: as if the headset's view were on
var shown := 0.0             # the cue drawn now, following the mood's
var _mat: StandardMaterial3D


func _init() -> void:
	name = "MoodEdge"
	_mat = VrRig._overlay_mat(Color(0, 0, 0, 0), PRIORITY)
	_mat.vertex_color_use_as_albedo = true   # the ring's alpha times the tint's
	mesh = VrHurt.edge_ring(FULL, _mat)
	position = Vector3(0, 0, -DIST)
	scale = Vector3(HOLE, HOLE, 1.0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


func _process(delta: float) -> void:
	step(delta)


## The HudData it follows: the wrist HUD's; null without one.
func data() -> HudData:
	return rig.hud.data if rig != null and rig.hud != null else null


## The cue to fade toward: the mood's, 0 when off, unknown or not a number.
func target() -> float:
	var d := data()
	if not enabled or d == null or d.mood.is_empty():
		return 0.0
	var c: Variant = d.mood.get("cue")
	return clampf(c, -1.0, 1.0) if c is float and is_finite(c) else 0.0


## The camera it hangs on is the headset's view now (or assume_view).
func xr_view() -> bool:
	if assume_view:
		return true
	var cam := get_parent() as XRCamera3D
	return cam != null and cam.is_inside_tree() and cam.current and get_viewport() != null and get_viewport().use_xr


## Moves the shown cue toward the target for `delta` seconds and draws it (hidden at 0 or out of the view).
func step(delta: float) -> void:
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	shown = move_toward(shown, target(), MoodCue.FADE_PER_S * d)
	var t := MoodCue.tint_for(shown)
	t.a *= ALPHA_SCALE
	_mat.albedo_color = t
	visible = t.a > 0.0 and xr_view()


## The edge's opacity now (at full ring alpha).
func alpha() -> float:
	return _mat.albedo_color.a
