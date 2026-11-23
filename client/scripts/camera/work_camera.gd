class_name WorkCamera
extends Camera3D
## C6 vehicle work: the camera lead-ui's work view drives (main.work_cam). focus(uid, row) glides to a part of the
## vehicle (PartSpot: from its side, past the body; from above where nothing covers it), view(uid, what) around
## it, over its engine ("hood") or low beside it looking under its body ("under"), leave() gives the view back to
## the camera it took over from. Poses are kept in the vehicle's frame and follow it as drawn each frame. Flat
## screen only: in VR (the viewport draws for the headset) it does nothing.

const GLIDE := 6.0     # 1/s: how fast it closes on its pose
const NEAR := 0.05     # m: near enough to stand low beside a vehicle

var vehicles: VehicleView
var active := false
var uid := 0
var _local := Transform3D()   # its pose in the vehicle's frame
var _prev: Camera3D           # the camera it took over from


func _init(v: VehicleView) -> void:
	vehicles = v
	name = "WorkCamera"
	near = NEAR
	set_process(false)


## Glides to part `row` of vehicle `uid` (a vehicles[].parts row). Nothing for a part or vehicle not drawn.
func focus(vehicle: int, row: int) -> void:
	_go(vehicle, "part", row)


## Glides to `what` of vehicle `uid`: one of PartSpot.VIEWS ("around", "hood", "under").
func view(vehicle: int, what: String) -> void:
	if what in PartSpot.VIEWS:
		_go(vehicle, what, -1)


## Back to the camera it took over from (the next one when that one is gone).
func leave() -> void:
	if not active:
		return
	active = false
	set_process(false)
	if is_instance_valid(_prev) and _prev.is_inside_tree():
		_prev.make_current()
	elif is_inside_tree():
		clear_current(true)
	_prev = null


## [eye, at] (mount grid) -> its pose there, looking from eye at `at`; null when they are the same point.
static func pose_of(eye: Vector3, at: Vector3) -> Variant:
	var d := at - eye
	if d.length() < 0.01 or not d.is_finite() or not eye.is_finite():
		return null
	if Vector2(d.x, d.z).length() < 0.001 * d.length():
		d.x += 0.01 * d.length()   # straight down or up: looking_at needs a side
	return Transform3D(Basis.looking_at(d, Vector3.UP), eye)


func _go(vehicle: int, what: String, row: int) -> void:
	if not is_inside_tree() or get_viewport().use_xr or vehicles == null or not is_instance_valid(vehicles):
		return
	var p := vehicles.work_pose(vehicle, what, row)
	var xf: Variant = vehicles.drawn(vehicle)
	var local: Variant = pose_of(p[0], p[1]) if p.size() == 2 else null
	if local == null or xf == null:
		return
	_local = local
	uid = vehicle
	if not active:
		var cur := get_viewport().get_camera_3d()
		_prev = cur if cur != self else null
		if _prev != null:   # glide from where the view is
			global_transform = _prev.global_transform
			fov = _prev.fov
		else:
			global_transform = vehicles.global_transform * (xf as Transform3D) * _local
		make_current()
		active = true
		set_process(true)


## The map's origin moved by d: it moves with everything drawn (no glide across the jump).
func shift(d: Vector3) -> void:
	position += d


func _process(delta: float) -> void:
	step(delta)


## Moves `delta` seconds on toward its pose on the vehicle as drawn now; leaves when that vehicle is gone.
func step(delta: float) -> void:
	var xf: Variant = vehicles.drawn(uid) if is_instance_valid(vehicles) else null
	if xf == null:
		leave()
		return
	var goal: Transform3D = vehicles.global_transform * (xf as Transform3D) * _local
	global_transform = global_transform.interpolate_with(goal, 1.0 - exp(-GLIDE * maxf(delta, 0.0)))
