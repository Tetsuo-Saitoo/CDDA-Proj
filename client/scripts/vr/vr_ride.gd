class_name VrRide
extends RefCounted
## C5, VR: riding a vehicle (VrRig `riding`). The VR rig is a ghost that CDDA never moves, so while the head stands on
## the vehicle the player is on, the rig is carried by how that vehicle moves as drawn (VehicleView glides it from one
## snapshot's pose to the next): turned about the head by the vehicle's turn and moved by where the head's spot on the
## vehicle went. Only the turn about the vertical and the level move: the height stays the rig's own (follow_ground),
## so a vehicle leaning on a ramp never tilts the floor under the player.

var _uid := 0                  # the vehicle followed; 0: none (the next one starts afresh)
var _was := Transform3D()      # where it was drawn last frame (world)


## The rig's transform `rig` (head at `head`, world) carried by vehicle `uid` now drawn at `drawn` (Transform3D) since
## the last call; uid 0, or `drawn` not a finite transform: unchanged, and following stops. The first call for a
## vehicle only remembers where it is.
func carry(rig: Transform3D, head: Vector3, uid: int, drawn: Variant) -> Transform3D:
	if uid <= 0 or not drawn is Transform3D or not (drawn as Transform3D).is_finite() or not head.is_finite() \
			or not rig.is_finite():
		_uid = 0
		return rig
	var d: Transform3D = drawn
	if uid != _uid:
		_uid = uid
		_was = d
		return rig
	var moved := d * _was.affine_inverse()
	_was = d
	var to := moved * head
	var fwd := moved.basis * Vector3.FORWARD
	fwd.y = 0.0
	var yaw := Vector3.FORWARD.signed_angle_to(fwd, Vector3.UP) if fwd.length() > 0.001 else 0.0
	var out := VrWalk.turned(rig, head, yaw)
	out.origin += Vector3(to.x - head.x, 0.0, to.z - head.z)
	return out if out.is_finite() else rig


## The vehicle followed (0: none).
func following() -> int:
	return _uid


## The map's origin moved by d (VrRig.shift): what is remembered in world space moves with it, as VehicleView's do.
func shift(d: Vector3) -> void:
	if d.is_finite():
		_was.origin += d
