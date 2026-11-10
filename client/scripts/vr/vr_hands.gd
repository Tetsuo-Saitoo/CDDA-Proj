class_name VrHands
extends RefCounted
## Drives the player body's arms and fingers in VR. With OpenXR hand tracking (XRHandTracker) the fingers
## follow the real joints; with controllers they curl from the trigger (index) and grip (other three), the
## thumb rests on the buttons when one is touched.

const TRACKERS := {"l": &"/user/hand_tracker/left", "r": &"/user/hand_tracker/right"}
## OpenXR joints per finger, knuckle to tip (thumb, index, middle, ring, little).
const JOINTS := [[2, 3, 4, 5], [7, 8, 9, 10], [12, 13, 14, 15], [17, 18, 19, 20], [22, 23, 24, 25]]
const PALM := 0


static func drive(body: PlayerBody, rig: VrRig) -> void:
	body.show_fingers = true
	hide_controller_boxes(rig)
	var targets := {}
	var tracked := {}
	for side: String in ["l", "r"]:
		var c: XRController3D = rig.left if side == "l" else rig.right
		var t := XRServer.get_tracker(TRACKERS[side]) as XRHandTracker
		if t != null and t.has_tracking_data:
			var o := rig.global_transform
			targets[side] = o * t.get_hand_joint_transform(PALM).origin
			var pts := []
			for f: Array in JOINTS:
				var row := []
				for j: int in f:
					row.append(body.to_local(o * t.get_hand_joint_transform(j).origin))
				pts.append(row)
			tracked[side] = pts
		elif c.get_is_active():
			targets[side] = c.global_position
		else:
			targets[side] = null
	body.reach(targets["l"], targets["r"])
	for side: String in ["l", "r"]:
		if tracked.has(side):
			body.pose_fingers(side, tracked[side])
			continue
		var c: XRController3D = rig.left if side == "l" else rig.right
		body.pose_fingers(side, body.curled_points(-1.0 if side == "l" else 1.0, curls_from(c)))


## Thumb, index, middle, ring, little: 0 open .. 1 fist.
static func curls_from(c: XRController3D) -> Array:
	if not c.get_is_active():
		return [0.2, 0.2, 0.2, 0.2, 0.2]
	var trig := c.get_float(&"trigger")
	var grip := c.get_float(&"grip")
	var thumb := 0.6 if (c.is_button_pressed(&"ax_touch") or c.is_button_pressed(&"by_touch")
			or c.is_button_pressed(&"primary_touch")) else 0.1
	return [thumb, trig, grip, grip, grip]


## The rig's coloured placeholder boxes: the body's hands replace them.
static func hide_controller_boxes(rig: VrRig) -> void:
	for c: XRController3D in [rig.left, rig.right]:
		for n in c.get_children():
			if n is MeshInstance3D:
				(n as MeshInstance3D).visible = false
