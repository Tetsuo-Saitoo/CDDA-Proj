class_name VrLean
extends RefCounted
## VR leaning (VrRig `leaning`): tilting the head sideways past LEAN_DEG, as when leaning out around a corner, asks
## CDDA to peek that way (VrRig.on_lean -> main.gd's lean, which waits 250 ms before CDDA's peek, so a short tilt
## does nothing there); straightening up under BACK_DEG,
## tilting the other way or the switch going off ends it (on_unlean). The way is the head's level left or right,
## snapped to the 8 ways (CDDA dx, dy: world x is CDDA x, world z is CDDA y). Only the head's pose is read; the lean
## itself does nothing in CDDA but ask for the peek, which CDDA charges and judges.

const LEAN_DEG := 20.0
const BACK_DEG := 10.0
const HOLD_S := 0.0   # main.lean holds the lean itself (LeanPeek): a wait here would add to it

var enabled := true             # the feature's switch (eye_on "lean")
var side := Vector2i.ZERO       # the way peeked now, ZERO: none
var _want := Vector2i.ZERO      # the way leaned toward, not yet held HOLD_S
var _roll_sign := 0.0           # the lean's side: +1 left (the right ear up), -1 right
var _t := 0.0


## Per frame: `head` the camera's global transform. "lean" (side is set: ask for the peek), "unlean" (end it) or "".
func update(delta: float, head: Transform3D) -> String:
	if not enabled or not head.is_finite() or not is_finite(delta) or delta < 0.0:
		return stop()
	var r := head.basis.x
	if r.length() < 0.5:
		return stop()
	r = r.normalized()
	var roll := rad_to_deg(asin(clampf(r.y, -1.0, 1.0)))   # > 0: the right side up, leaning left
	if side != Vector2i.ZERO:
		return stop() if absf(roll) < BACK_DEG or signf(roll) != _roll_sign else ""
	if absf(roll) < LEAN_DEG:
		_want = Vector2i.ZERO
		_t = 0.0
		return ""
	var flat := Vector3(r.x, 0.0, r.z)
	if flat.length() < 0.3:
		return ""
	var d := way_of(flat * (-1.0 if roll > 0.0 else 1.0))
	if d != _want:
		_want = d
		_t = 0.0
	_t += delta
	if _t < HOLD_S or d == Vector2i.ZERO:
		return ""
	side = d
	_roll_sign = signf(roll)
	return "lean"


## Ends a peek: "unlean" when one was on, else "".
func stop() -> String:
	_want = Vector2i.ZERO
	_t = 0.0
	if side == Vector2i.ZERO:
		return ""
	side = Vector2i.ZERO
	_roll_sign = 0.0
	return "unlean"


## A level direction (world) snapped to the nearest of the 8 ways, as CDDA (dx, dy); ZERO for none.
static func way_of(v: Vector3) -> Vector2i:
	if not v.is_finite() or Vector2(v.x, v.z).length() < 0.001:
		return Vector2i.ZERO
	var a := snappedf(atan2(v.z, v.x), PI / 4.0)
	return Vector2i(roundi(cos(a)), roundi(sin(a)))
