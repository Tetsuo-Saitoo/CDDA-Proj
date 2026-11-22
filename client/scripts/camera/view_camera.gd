class_name ViewCamera
extends Camera3D
## Block C9: the over-the-shoulder and top-down views, options next to first person. The FirstPersonCamera stays
## the player's eyes (mouse look, walking, following the sim's square); this camera only follows it each frame
## from an offset and is the one shown. VR ignores it.
## - shoulder: behind, right of and a little above the eyes, looking where they look; the boom shortens when a
##   wall or ceiling is in the way (`blocked`).
## - top: high and back over the player, turning with the eyes' yaw, `top_dist` metres away (the wheel zooms).
## - chase (driving): behind and above the vehicle the player is on (`car`), turning after its heading with a little
##   lag; the boom starts above the roof, so it never meets that vehicle, and pulls in (rising) when a wall or
##   anything else is in the way. Without a vehicle it follows the eyes the same way.

const MODES := ["shoulder", "top", "chase"]
const CHASE_BACK := 7.0        # metres behind the vehicle's middle
const CHASE_UP := 3.4          # metres above its floor
const CHASE_PIVOT_UP := 2.4    # the boom starts this high over the middle (above a roof, VehicleView.TOP)
const CHASE_LOOK_UP := 1.0     # and looks at this height over it
const CHASE_LAG := 3.0         # 1/s: the camera's heading eases toward the vehicle's
const CHASE_MIN_BOOM := 0.2    # share of the boom kept when something is right behind
const SHOULDER_BACK := 2.2
const SHOULDER_RIGHT := 0.45
const SHOULDER_UP := 0.25
const MIN_BOOM := 0.25         # metres the boom keeps when a wall is right behind
const WALL_GAP := 0.2          # metres kept in front of what blocks the boom
const TOP_PITCH := -1.0        # radians down (~57 degrees): never straight down, so "forward" stays defined
const TOP_DIST := 14.0
const TOP_MIN := 5.0
const TOP_MAX := 40.0
const ZOOM_STEP := 1.15

var mode := "shoulder"
var eyes: FirstPersonCamera
var top_dist := TOP_DIST
## (from: Vector3, to: Vector3) -> float: metres free from `from` towards `to` (INF or more = nothing in the
## way). Unset: nothing blocks.
var blocked := Callable()
## () -> Variant: the vehicle chase follows, as drawn now: a Transform3D (x ahead, origin the middle on its floor),
## or null (VehicleView.chase_target, set by main.gd).
var car := Callable()
var chase_heading := NAN       # the heading (radians, atan2 of x ahead in the level, z, x) the chase looks along


func _init(fp: FirstPersonCamera) -> void:
	eyes = fp
	name = "ViewCamera"
	near = 0.05
	far = 600.0


## Wheel steps: positive zooms out.
func zoom(steps: int) -> void:
	top_dist = clampf(top_dist * pow(ZOOM_STEP, steps), TOP_MIN, TOP_MAX)


## The camera's pose in `m` for eyes at `eye` looking along yaw / pitch: `dist` for top, `boom` (0..1 of the
## full shoulder offset) for shoulder.
static func pose(m: String, eye: Vector3, yaw: float, pitch: float, dist := TOP_DIST, boom := 1.0) -> Transform3D:
	if m == "top":
		var b := Basis.from_euler(Vector3(TOP_PITCH, yaw, 0.0))
		var at := eye - Vector3(0.0, FirstPersonCamera.EYE_H * 0.5, 0.0)   # the body's middle
		return Transform3D(b, at + b.z * clampf(dist, TOP_MIN, TOP_MAX))
	var look := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	var offset := look.z * SHOULDER_BACK + look.x * SHOULDER_RIGHT + Vector3.UP * SHOULDER_UP
	return Transform3D(look, eye + offset * clampf(boom, 0.0, 1.0))


## Where a pick ray from the camera (`o`, unit `d`) starts in view `m`, so it meets what is in front of the
## player, never the player or what lies between the camera and the eyes (`eye`, a Vector3; else `o` is kept).
## shoulder: where the ray passes closest to the eyes; top: where it comes down to the eyes' height (the levels
## above are cut away there). Never back towards the camera.
static func ray_start(m: String, o: Vector3, d: Vector3, eye: Variant) -> Vector3:
	if not eye is Vector3 or not (eye as Vector3).is_finite() or not o.is_finite() or not d.is_finite():
		return o
	var e := eye as Vector3
	if m == "top":
		return o + d * ((o.y - e.y) / -d.y) if d.y < -1e-3 and o.y > e.y else o
	if m == "shoulder" or m == "chase":
		return o + d * maxf((e - o).dot(d), 0.0)
	return o


## The eyes' level facing for yaw `yaw` (radians, 0 = -z): top-view aiming follows it.
static func facing(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## The shoulder boom's share left free when `free_m` metres are clear from the eyes towards the full pose.
static func boom_for(free_m: float) -> float:
	var full := (Vector3.BACK * SHOULDER_BACK + Vector3.RIGHT * SHOULDER_RIGHT + Vector3.UP * SHOULDER_UP).length()
	if not free_m < INF:   # also NaN
		return 1.0
	return clampf((free_m - WALL_GAP) / full, MIN_BOOM / full, 1.0)


## The chase camera's pose about `mid` (the vehicle's middle on its floor) looking along `heading` (radians in the
## level: atan2(z, x) of ahead), the boom `boom` (0..1) of its full length out: the camera rises as it pulls in.
static func chase_pose(mid: Vector3, heading: float, boom := 1.0) -> Transform3D:
	var b := clampf(boom, 0.0, 1.0)
	var ahead := Vector3(cos(heading), 0.0, sin(heading))
	var pivot := mid + Vector3.UP * CHASE_PIVOT_UP
	var at := pivot - ahead * CHASE_BACK * b + Vector3.UP * ((CHASE_UP - CHASE_PIVOT_UP) * b + 2.0 * (1.0 - b))
	var look := mid + Vector3.UP * CHASE_LOOK_UP
	if (look - at).length() < 0.01:
		look = at + ahead
	return Transform3D(Basis(), at).looking_at(look, Vector3.UP)


## The heading the chase eases to after `dt` seconds from `now` toward `goal` (radians; NaN now: at once).
static func chase_ease(now: float, goal: float, dt: float) -> float:
	if not is_finite(now) or not is_finite(dt):
		return goal
	return lerp_angle(now, goal, 1.0 - exp(-CHASE_LAG * clampf(dt, 0.0, 1.0)))


func _process(delta: float) -> void:
	follow(delta)


## Puts the camera where the eyes say (called each frame; tests call it directly); chase eases its heading over
## `delta` seconds (0: at once).
func follow(delta := 0.0) -> void:
	if eyes == null:
		return
	var eye := eyes.global_position if eyes.is_inside_tree() else eyes.position
	if mode == "chase":
		_follow_chase(eye, delta)
		return
	var boom := 1.0
	if mode == "shoulder" and blocked.is_valid():
		var full := pose(mode, eye, eyes.yaw, eyes.pitch)
		var free: Variant = blocked.call(eye, full.origin)
		if free is float or free is int:
			boom = boom_for(float(free))
	var t := pose(mode, eye, eyes.yaw, eyes.pitch, top_dist, boom)
	_put(t)


func _put(t: Transform3D) -> void:
	if not t.is_finite():
		return
	if is_inside_tree():
		global_transform = t
	else:
		transform = t


func _follow_chase(eye: Vector3, delta: float) -> void:
	var c: Variant = car.call() if car.is_valid() else null
	var mid := eye - Vector3(0.0, FirstPersonCamera.EYE_H, 0.0)
	var goal := atan2(facing(eyes.yaw).z, facing(eyes.yaw).x)
	if c is Transform3D and (c as Transform3D).is_finite():
		var x := (c as Transform3D).basis.x
		mid = (c as Transform3D).origin
		if Vector2(x.x, x.z).length() > 0.01:
			goal = atan2(x.z, x.x)
	chase_heading = chase_ease(chase_heading, goal, delta) if delta > 0.0 else goal
	var boom := 1.0
	if blocked.is_valid():
		var pivot := mid + Vector3.UP * CHASE_PIVOT_UP
		var full := chase_pose(mid, chase_heading)
		var free: Variant = blocked.call(pivot, full.origin)
		if (free is float or free is int) and float(free) < INF:
			var len := pivot.distance_to(full.origin)
			boom = clampf((float(free) - WALL_GAP) / len, CHASE_MIN_BOOM, 1.0) if len > 0.0 else 1.0
	_put(chase_pose(mid, chase_heading, boom))
