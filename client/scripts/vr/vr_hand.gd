class_name VrHand
extends Node3D
## Block L2, first part: a low-poly hand with moving fingers. It is drawn from the 26 OpenXR hand joints
## (XRHandTracker order: palm, wrist, thumb 2-5, index 6-10, middle 11-15, ring 16-20, little 21-25) as joint
## balls, bone cylinders and a palm plate, in two multimeshes and one box (few draw calls).
## Pose sources, best first: the runtime's hand tracking (optical, or inferred from controllers such as Index
## knuckles: real finger tracking) via `pose_from_tracker`; else fingers curled from the controller's trigger,
## grip and thumb touches via `pose_from_controller`. The node sits in the rig's (XROrigin3D's) space.

const JOINTS := 26
const CHAINS := [[1, 2, 3, 4, 5], [1, 6, 7, 8, 9, 10], [1, 11, 12, 13, 14, 15], [1, 16, 17, 18, 19, 20],
		[1, 21, 22, 23, 24, 25]]
const FINGER_R := [0.0105, 0.0085, 0.009, 0.0085, 0.0075]   # thumb .. little, at the base; tips taper
const SKIN := Color(0.86, 0.69, 0.56)
## Right hand at rest, in hand space (palm at the origin, fingers along -Z, back of the hand +Y, thumb toward
## -X): [metacarpal base, knuckle, phalanx lengths, sideways splay] for index .. little.
const FINGERS := [
	[Vector3(-0.012, 0, 0.030), Vector3(-0.026, 0, -0.045), [0.040, 0.024, 0.020], -0.10],
	[Vector3(-0.003, 0, 0.030), Vector3(-0.006, 0, -0.049), [0.045, 0.028, 0.022], 0.0],
	[Vector3(0.006, 0, 0.030), Vector3(0.013, 0, -0.045), [0.042, 0.027, 0.021], 0.08],
	[Vector3(0.014, 0, 0.032), Vector3(0.030, 0, -0.038), [0.032, 0.020, 0.018], 0.18],
]
const BEND := [1.4, 1.6, 1.0]   # radians per joint at full curl (knuckle, middle, last)
## Hand space -> the controller's aim pose (right hand): back of the hand faces outward (+X), fingers forward
## around the grip, index on top. The left hand is the mirror image.
const GRIP := Transform3D(Basis(Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)), Vector3(0.03, -0.025, 0.09))

var left := false
var source := ""          # "tracked", "buttons" or "" (not posed yet)
var joints := PackedVector3Array()
var colour := SKIN       # skin, or the outermost glove's colour (VrRig.drive_body)
var _mat: StandardMaterial3D
var _balls: MultiMesh
var _bones: MultiMesh
var _palm: MeshInstance3D


func _init(is_left: bool) -> void:
	left = is_left
	name = "LeftHandModel" if is_left else "RightHandModel"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SKIN
	mat.roughness = 0.8
	_mat = mat
	var ball := SphereMesh.new()
	ball.radius = 1.0
	ball.height = 2.0
	ball.radial_segments = 8
	ball.rings = 4
	ball.material = mat
	var bone := CylinderMesh.new()
	bone.top_radius = 1.0
	bone.bottom_radius = 1.0
	bone.height = 1.0
	bone.radial_segments = 6
	bone.rings = 1
	bone.cap_top = false
	bone.cap_bottom = false
	bone.material = mat
	_balls = _multimesh(ball, JOINTS - 1)
	_bones = _multimesh(bone, 24)
	var plate := BoxMesh.new()
	plate.size = Vector3.ONE
	plate.material = mat
	_palm = MeshInstance3D.new()
	_palm.mesh = plate
	add_child(_palm)
	visible = false


func _multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	add_child(mi)
	return mm


## Skin or glove colour for the whole hand (one material).
func set_colour(c: Color) -> void:
	colour = c
	_mat.albedo_color = c


## The wrist (joint 1) in rig space, the point the body's arm reaches for.
func wrist() -> Vector3:
	return joints[1] if joints.size() == JOINTS else Vector3.ZERO


## Finger curls (thumb .. little, 0 = straight, 1 = fist) from controller inputs: the index follows the
## trigger (resting on it when touched), the other three the grip, the thumb whether it touches the
## stick or buttons. Fingers stay a little wrapped around the controller.
static func curls_from_buttons(trigger: float, trigger_touch: bool, grip: float, thumb_touch: bool) -> PackedFloat32Array:
	var index := maxf(clampf(trigger, 0.0, 1.0), 0.35 if trigger_touch else 0.1)
	var rest := 0.35 + 0.65 * clampf(grip, 0.0, 1.0)
	return PackedFloat32Array([0.65 if thumb_touch else 0.2, index, rest, rest, rest])


## The 26 joints of a right hand in hand space for the given curls.
static func rest_joints(curls: PackedFloat32Array) -> PackedVector3Array:
	var p := PackedVector3Array()
	p.resize(JOINTS)
	p[0] = Vector3.ZERO
	p[1] = Vector3(0, 0, 0.045)
	# Thumb: swings from pointing forward-out toward the middle of the palm.
	var c := curls[0]
	var out := Vector3(-0.45, -0.1, -1.0).normalized()
	var across := Vector3(0.55, -0.6, -0.58).normalized()
	p[2] = Vector3(-0.018, -0.008, 0.028)
	p[3] = Vector3(-0.040, -0.014, 0.0)
	p[4] = p[3] + out.slerp(across, c * 0.5) * 0.032
	p[5] = p[4] + out.slerp(across, c * 0.9) * 0.026
	for f in 4:
		var d: Array = FINGERS[f]
		var base := 6 + f * 5
		p[base] = d[0]
		p[base + 1] = d[1]
		var dir := Vector3(d[3], 0.0, -1.0).normalized()
		var angle := 0.0
		for k in 3:
			angle += curls[f + 1] * BEND[k]
			p[base + 2 + k] = p[base + 1 + k] + dir.rotated(Vector3.RIGHT, -angle) * d[2][k]
	return p


## Fingers from buttons, the hand around a controller at `aim` (the controller's transform in rig space).
func pose_from_controller(aim: Transform3D, curls: PackedFloat32Array) -> void:
	var p := rest_joints(curls)
	for i in JOINTS:
		var q := GRIP * p[i]
		if left:
			q.x = -q.x
		p[i] = aim * q
	source = "buttons"
	set_joints(p)


## Joints from the runtime's hand tracking; false (and nothing changes) when it has no full hand right now.
func pose_from_tracker(t: XRHandTracker) -> bool:
	if t == null or not t.has_tracking_data:
		return false
	var p := PackedVector3Array()
	p.resize(JOINTS)
	for i in JOINTS:
		if (t.get_hand_joint_flags(i) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
			return false
		p[i] = t.get_hand_joint_transform(i).origin
	source = "tracked"
	set_joints(p)
	return true


## Places the balls, bones and palm plate on 26 joint positions (rig space).
func set_joints(p: PackedVector3Array) -> void:
	if p.size() != JOINTS:
		return
	joints = p
	var bone := 0
	for f in CHAINS.size():
		var chain: Array = CHAINS[f]
		for k in range(1, chain.size()):
			var r: float = FINGER_R[f] * pow(0.88, k - 1)
			var a := p[chain[k - 1]]
			var b := p[chain[k]]
			_balls.set_instance_transform(chain[k] - 1, Transform3D(Basis.from_scale(Vector3.ONE * r), b))
			_bones.set_instance_transform(bone, _segment(a, b, r))
			bone += 1
	_balls.set_instance_transform(0, Transform3D(Basis.from_scale(Vector3.ONE * 0.012), p[1]))   # the wrist
	# Palm plate: across the knuckles (index to little), along wrist -> middle knuckle.
	var along := p[12] - p[1]
	var across := p[7] - p[22]
	var up := across.cross(along)
	if along.length() > 0.001 and up.length() > 0.000001:
		var y := up.normalized()
		var z := -along.normalized()
		var x := y.cross(z)
		var w := across.length() + 0.02
		_palm.transform = Transform3D(Basis(x * w, y * 0.022, z * (along.length() * 0.9)),
				(p[1] + p[7] + p[22]) / 3.0 + (p[12] - p[1]) * 0.1)
	visible = true


## A cylinder of radius r from a to b.
static func _segment(a: Vector3, b: Vector3, r: float) -> Transform3D:
	var d := b - a
	var l := d.length()
	if l < 0.0001:
		return Transform3D(Basis.from_scale(Vector3.ZERO), a)
	var y := d / l
	var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x * r, y * l, z * r), (a + b) * 0.5)
