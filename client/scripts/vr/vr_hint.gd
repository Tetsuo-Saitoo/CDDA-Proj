class_name VrHint
extends Label3D
## G6 in VR (VrRig `hint`): the one-time hint Hints shows now (`source.shown`) when it is a VR one (Hints.VR_TEXTS;
## a flat one queued before the headset started, in keyboard words, is not shown here), low in front of the eyes. It follows the head's turn lazily (FOLLOW), so it can be read while looking
## around a little, and starts straight ahead when a new hint comes. Timing, the on / off switch and "Show hints
## again" are the flat ones': one Hints for both (main.gd gives it). Placed in world space; billboarded.

const DIST := 1.0        # m ahead of the head, level ...
const DROP := 0.42       # ... and this far below the eyes (about 23 degrees; the busy note is above it)
const FOLLOW := 2.5      # 1/s: how fast it catches up with the head's turn
const PRIORITY := 106    # over the edges and the busy note (105), under the menu (110)
const MAX_CHARS := 120

var rig: VrRig           # its camera is the head
var source: Hints        # what shows; null: nothing
var _id := ""            # the hint shown, "" none


func _init() -> void:
	name = "Hint"
	top_level = true
	pixel_size = 0.0011
	font_size = 34
	outline_size = 12
	width = 760.0
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modulate = Color(1.0, 0.95, 0.82)
	no_depth_test = true
	render_priority = PRIORITY
	outline_render_priority = PRIORITY - 1
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	shaded = false
	visible = false


func _process(delta: float) -> void:
	step(delta)


## Where it rests now: DIST ahead of the head along its level forward (the last one while looking straight up or
## down), DROP below the eyes.
func target() -> Vector3:
	var cam := rig.camera
	var f := -cam.global_basis.z
	f.y = 0.0
	if f.length_squared() < 1e-4 or not f.is_finite():
		f = global_position - cam.global_position
		f.y = 0.0
	if f.length_squared() < 1e-4 or not f.is_finite():
		f = Vector3.FORWARD
	return cam.global_position + f.normalized() * DIST + Vector3.DOWN * DROP


## Shows the source's hint (its VR text, capped), moving toward target() for `delta` seconds; hidden with none or a
## flat one.
func step(delta: float) -> void:
	var id := source.shown if source != null and is_instance_valid(source) else ""
	var t: String = Hints.VR_TEXTS.get(id, "")
	visible = not t.is_empty() and rig != null and rig.camera != null
	if not visible:
		_id = ""
		return
	var to := target()
	if id != _id:
		_id = id
		text = t.left(MAX_CHARS)
		global_position = to
		return
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	global_position = global_position.lerp(to, 1.0 - exp(-FOLLOW * d))
