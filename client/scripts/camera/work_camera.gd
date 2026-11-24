class_name WorkCamera
extends Camera3D
## C6 vehicle work: the camera lead-ui's work view drives (main.work_cam). focus(uid, row) glides to a part of the
## vehicle (PartSpot: from its side, past the body; from above where nothing covers it), focus_square(uid, mount)
## to a square of it (install mode; also one beside it), view(uid, what) around it, over its engine ("hood") or low
## beside it looking under its body ("under"), leave() gives the view back to the camera it took over from. What it
## looks at sits at `frame_x` across the screen (left of the work view's panel); where a wall or anything else
## stands between the vehicle and its spot (`blocked`), it stands in front of that. Poses are kept in the vehicle's
## frame and follow it as drawn each frame. Flat screen only: in VR (the viewport draws for the headset) it does
## nothing.

const GLIDE := 6.0     # 1/s: how fast it closes on its pose
const NEAR := 0.05     # m: near enough to stand low beside a vehicle
const WALL_GAP := 0.2  # m: kept from what is in the way
const MIN_OUT := 0.3   # m: the least it stands out from the vehicle, even with something right there

var vehicles: VehicleView
var active := false
var uid := 0
## How far across the screen (0 left .. 1 right) what it looks at sits: lead-ui's panel covers the right 40%.
var frame_x := 0.3
## (from: Vector3, to: Vector3, vehicle uid) -> float: how far from `from` toward `to` the way is free (INF: all of
## it), not counting that vehicle (main.gd: LookRay). Unset: nothing is in the way.
var blocked := Callable()
var _local := Transform3D()   # its pose in the vehicle's frame
var _prev: Camera3D           # the camera it took over from


func _init(v: VehicleView) -> void:
	vehicles = v
	name = "WorkCamera"
	near = NEAR
	set_process(false)


## Glides to part `row` of vehicle `uid` (a vehicles[].parts row). Nothing for a part or vehicle not drawn.
func focus(vehicle: int, row: int) -> void:
	if is_instance_valid(vehicles):
		_go(vehicle, vehicles.work_pose(vehicle, "part", row))


## Glides to square `mount` of vehicle `uid` (its mount grid; C6 install mode). Nothing for one out of reach.
func focus_square(vehicle: int, mount: Vector2i) -> void:
	if is_instance_valid(vehicles):
		_go(vehicle, vehicles.work_square_pose(vehicle, mount))


## Glides to `what` of vehicle `uid`: one of PartSpot.VIEWS ("around", "hood", "under").
func view(vehicle: int, what: String) -> void:
	if what in PartSpot.VIEWS and is_instance_valid(vehicles):
		_go(vehicle, vehicles.work_pose(vehicle, what))


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


## The turn (radians, to the right) that puts what is straight ahead `frame_x` across a screen of `aspect`
## (width / height) with vertical field of view `fov_deg`.
static func frame_turn(fx: float, fov_deg: float, aspect: float) -> float:
	return atan((1.0 - 2.0 * clampf(fx, 0.05, 0.95)) * tan(deg_to_rad(clampf(fov_deg, 1.0, 179.0)) * 0.5) * aspect)


## Its eye from `pose` (eye, at, exit; mount grid) on a vehicle drawn at `xf` (world): in front of what `blocked`
## finds between the exit and the eye, at least MIN_OUT out.
func eye_clear(pose: Array, xf: Transform3D, vehicle: int) -> Vector3:
	var eye: Vector3 = pose[0]
	if not blocked.is_valid() or pose.size() < 3:
		return eye
	var exit: Vector3 = pose[2]
	var full := exit.distance_to(eye)
	if full < 0.01:
		return eye
	var free: Variant = blocked.call(xf * exit, xf * eye, vehicle)
	if not (free is float or free is int) or not float(free) < full:
		return eye
	return exit + (eye - exit) / full * clampf(float(free) - WALL_GAP, MIN_OUT, full)


func _go(vehicle: int, p: Array) -> void:
	if not is_inside_tree() or get_viewport().use_xr or not is_instance_valid(vehicles) or p.size() < 2:
		return
	var drawn: Variant = vehicles.drawn(vehicle)
	if drawn == null:
		return
	var xf: Transform3D = vehicles.global_transform * (drawn as Transform3D)
	var local: Variant = pose_of(eye_clear(p, xf, vehicle), p[1])
	if local == null:
		return
	var cur := get_viewport().get_camera_3d()
	if not active and cur != null and cur != self:
		fov = cur.fov   # the player's field of view
	var size := get_viewport().get_visible_rect().size
	var turn := frame_turn(frame_x, fov, size.x / size.y if size.y > 0.0 else 16.0 / 9.0)
	_local = Transform3D((local as Transform3D).basis * Basis(Vector3.UP, -turn), (local as Transform3D).origin)
	uid = vehicle
	if not active:
		_prev = cur if cur != self else null
		global_transform = _prev.global_transform if _prev != null else xf * _local   # glide from where the view is
		make_current()
		active = true
		set_process(true)


## How far from `from` toward `to` the way is free by `ray` (INF: all of it), going on past the parts of vehicle
## `vehicle` (its own body, met where it is drawn off its squares; 8 times at most, then as far as that got); 0
## for no vehicle to skip.
static func free_way(ray: LookRay, from: Vector3, to: Vector3, vehicle: int) -> float:
	var d := to - from
	var full := d.length()
	if full < 0.001 or ray == null:
		return INF
	var dir := d / full
	var at := 0.0
	for i in 8:
		var r := ray.cast(from + dir * at, dir, full - at, false, false)
		if not r.get("hit", false) or not r.get("point") is Vector3:
			return INF
		var t := from.distance_to(r["point"])
		if vehicle == 0 or r.get("vehicle", 0) != vehicle:
			return t
		at = t + 0.1
		if at >= full:
			return INF
	return at


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
