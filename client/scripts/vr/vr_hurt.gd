class_name VrHurt
extends MeshInstance3D
## F3 in VR (VrRig `hurt`, on the XR camera): the player's hurt as a dark red edge in the headset. Its level is the
## flat view's HurtCue (`source`, main.gd): up fast on a hit, faint while a body part bleeds, a slow fade, never a
## flash or a pulse. Drawn on its own ring in front of the eyes, clear in the middle, at most MAX_ALPHA, under the
## tunnel vignette (farther from the eyes and a lower render priority, so the vignette always covers it). Hidden
## while the hurt tint is off (HurtCue.enabled, F1 "Hurt tint") and while the camera isn't the headset's view.
## A hit (HitFeedback.player_hurt, main.gd) buzzes both hands, short and gentle, at most once per BUZZ_GAP_S: a
## burst of hits never becomes one long buzz. The hurt tint off: no buzz either.

const MAX_ALPHA := 0.35
const DIST := 0.21           # m in front of the eyes (the tunnel vignette is at VrRig.VIGNETTE_DIST, 0.2)
const PRIORITY := 99         # under the tunnel vignette's 100
const HOLE := 0.15           # m: clear inside this radius at DIST (about 35 degrees off the view's middle) ...
const FULL := 2.0            # ... full from this many HOLEs on (about 55 degrees)
const OUTER := 40.0          # HOLEs: the ring's outer edge, far past any headset's view
const SEGMENTS := 48
const BUZZ_MIN := 0.3        # amplitude for the smallest hit ...
const BUZZ_MAX := 0.6        # ... and for a hit of HurtCue.HIT_FULL or more
const BUZZ_S := 0.1          # seconds a buzz lasts
const BUZZ_GAP_S := 0.5      # one buzz at most this often

var rig: VrRig               # the hands that buzz; null: no buzz
var source: HurtCue          # the flat view's cue: its level and its setting; null: hidden, no buzz
var assume_view := false     # tests: as if the headset's view were on
var level := 0.0             # the level drawn now, 0..1
var buzzes := 0              # buzzes given (tests)
var _gap := 0.0              # seconds before the next buzz may come
var _mat: StandardMaterial3D


func _init() -> void:
	name = "HurtEdge"
	_mat = VrRig._overlay_mat(Color(HurtCue.TINT, 0.0), PRIORITY)
	_mat.vertex_color_use_as_albedo = true   # the ring's alpha times the level's
	mesh = edge_ring(FULL, _mat)
	position = Vector3(0, 0, -DIST)
	scale = Vector3(HOLE, HOLE, 1.0)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## An edge ring in units of its hole (scale it by the hole's radius): clear inside 1, its vertex alpha rising to 1 at
## `full`, 1 out to OUTER; drawn with `mat` (VrMood's edge too).
static func edge_ring(full: float, mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring: Array in [[1.0, full, 0.0, 1.0], [full, OUTER, 1.0, 1.0]]:
		for i in SEGMENTS:
			var a0 := TAU * i / SEGMENTS
			var a1 := TAU * (i + 1) / SEGMENTS
			var p0 := Vector3(cos(a0), sin(a0), 0)
			var p1 := Vector3(cos(a1), sin(a1), 0)
			var quad := [[p0 * ring[0], ring[2]], [p1 * ring[0], ring[2]], [p1 * ring[1], ring[3]],
					[p0 * ring[0], ring[2]], [p1 * ring[1], ring[3]], [p0 * ring[1], ring[3]]]
			for v: Array in quad:
				st.set_color(Color(1, 1, 1, v[1]))
				st.add_vertex(v[0])
	st.set_material(mat)
	return st.commit()


func _process(delta: float) -> void:
	step(delta)


## The hurt tint is on (a source, enabled).
func on() -> bool:
	return source != null and source.enabled


## The camera it hangs on is the headset's view now (or assume_view).
func xr_view() -> bool:
	if assume_view:
		return true
	var cam := get_parent() as XRCamera3D
	return cam != null and cam.is_inside_tree() and cam.current and get_viewport() != null and get_viewport().use_xr


## Follows the source's level for `delta` seconds and draws it (hidden at 0, while off or out of the view).
func step(delta: float) -> void:
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	_gap = maxf(_gap - d, 0.0)
	level = clampf(source.shown, 0.0, 1.0) if on() and is_finite(source.shown) else 0.0
	visible = level > 0.0 and xr_view()
	_mat.albedo_color = Color(HurtCue.TINT, MAX_ALPHA * level)


## The edge's opacity now (at full ring alpha), 0..MAX_ALPHA.
func alpha() -> float:
	return _mat.albedo_color.a


## The player took `amount` damage: both hands buzz, by the hit's size (BUZZ_MIN..BUZZ_MAX), unless one did within
## BUZZ_GAP_S. Nothing while off or for no damage. True when it buzzed.
func hurt(amount: int) -> bool:
	if not on() or rig == null or amount <= 0 or _gap > 0.0:
		return false
	_gap = BUZZ_GAP_S
	buzzes += 1
	var amp := lerpf(BUZZ_MIN, BUZZ_MAX, clampf(float(amount) / HurtCue.HIT_FULL, 0.0, 1.0))
	rig.feel(rig.left, amp, BUZZ_S)
	rig.feel(rig.right, amp, BUZZ_S)
	return true
