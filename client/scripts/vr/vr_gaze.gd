class_name VrGaze
extends RefCounted
## Where the player looks (VrRig `gaze`): the gaze source the look-at code asks for a ray. Eyes first: `eyes` gives
## the eye gaze pose (VrRig: OpenXR's XR_EXT_eye_gaze_interaction, an XRController3D on /user/eyes_ext; later a desktop
## eye tracker can feed it a pose made from its screen point). With eye tracking off (`on`, HudSettings' "tracker"), no eye
## tracker, the pose not tracked, or a pose that isn't believable, the head gaze (the camera's forward) is used, as
## before eye tracking. A blink (the eyes lost for at most HOLD_S) keeps the last eye direction, turned with the head.
## The pose is hostile input: NaN or inf, an origin more than MAX_OFF_M from the head or a direction more than MAX_DEG
## off the head's forward is not believed.
## Privacy: gaze stays in memory, only for this frame's look; never logged, saved, sent or recorded (no history kept
## beyond the last eye direction for HOLD_S).

const MAX_OFF_M := 0.15      # the eyes' origin at most this far from the head's
const MAX_DEG := 60.0        # the eyes at most this far off the head's forward
const HOLD_S := 0.3          # the eyes lost this long (a blink) still look where they last did
const MIN_LEN := 0.5         # a pose basis whose forward is shorter than this is junk

## Eye tracking wanted (VrRig.eye_on "tracker"); off: always the head.
var on := true
## () -> Variant: the eyes' pose (Transform3D, world) this frame, or null when there is none or it isn't tracked.
var eyes := Callable()

var _dir_in_head := Vector3.ZERO   # the last believed eye direction, in head space (ZERO: none)
var _seen_s := -INF                # when it was seen


## The gaze this frame: {"from": Vector3, "dir": Vector3 (unit), "eyes": bool (false: the head's)}; {} when `head`
## (the camera's global transform) isn't finite. `now_s`: seconds, for the blink hold.
func ray(head: Transform3D, now_s: float) -> Dictionary:
	if not head.is_finite():
		return {}
	var fwd := -head.basis.z
	if fwd.length() < MIN_LEN:
		return {}
	fwd = fwd.normalized()
	var got := _eye_dir(head, fwd)
	if got != Vector3.ZERO:
		_dir_in_head = head.basis.inverse() * got
		_seen_s = now_s
		return {"from": head.origin, "dir": got, "eyes": true}
	if on and _dir_in_head != Vector3.ZERO and is_finite(now_s) and now_s - _seen_s >= 0.0 and now_s - _seen_s <= HOLD_S:
		var held := (head.basis * _dir_in_head).normalized()
		if held.is_finite() and held.length() > 0.5:
			return {"from": head.origin, "dir": held, "eyes": true}
	_dir_in_head = Vector3.ZERO
	return {"from": head.origin, "dir": fwd, "eyes": false}


## Whether the eyes drove the last ray (or would now, within the blink hold).
func eyes_live(now_s: float) -> bool:
	return on and _dir_in_head != Vector3.ZERO and now_s - _seen_s >= 0.0 and now_s - _seen_s <= HOLD_S


## Forgets the last eye direction (eye tracking turned off, the rig gone).
func forget() -> void:
	_dir_in_head = Vector3.ZERO
	_seen_s = -INF


## The eyes' direction (unit, world) when on, given and believable, else ZERO. Only the pose's origin and forward
## are looked at; its origin is not used for the ray (the head's is: the eyes sit in it).
func _eye_dir(head: Transform3D, fwd: Vector3) -> Vector3:
	if not on or not eyes.is_valid():
		return Vector3.ZERO
	var p: Variant = eyes.call()
	if not p is Transform3D:
		return Vector3.ZERO
	var t: Transform3D = p
	if not t.is_finite() or t.origin.distance_to(head.origin) > MAX_OFF_M:
		return Vector3.ZERO
	var d := -t.basis.z
	if d.length() < MIN_LEN:
		return Vector3.ZERO
	d = d.normalized()
	return d if d.angle_to(fwd) <= deg_to_rad(MAX_DEG) else Vector3.ZERO
