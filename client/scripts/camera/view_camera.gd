class_name ViewCamera
extends Camera3D
## Block C9: the over-the-shoulder and top-down views, options next to first person. The FirstPersonCamera stays
## the player's eyes (mouse look, walking, following the sim's square); this camera only follows it each frame
## from an offset and is the one shown. VR ignores it.
## - shoulder: behind, right of and a little above the eyes, looking where they look; the boom shortens when a
##   wall or ceiling is in the way (`blocked`).
## - top: high and back over the player, turning with the eyes' yaw, `top_dist` metres away (the wheel zooms).

const MODES := ["shoulder", "top"]
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


## The shoulder boom's share left free when `free_m` metres are clear from the eyes towards the full pose.
static func boom_for(free_m: float) -> float:
	var full := (Vector3.BACK * SHOULDER_BACK + Vector3.RIGHT * SHOULDER_RIGHT + Vector3.UP * SHOULDER_UP).length()
	if not free_m < INF:   # also NaN
		return 1.0
	return clampf((free_m - WALL_GAP) / full, MIN_BOOM / full, 1.0)


func _process(_delta: float) -> void:
	follow()


## Puts the camera where the eyes say (called each frame; tests call it directly).
func follow() -> void:
	if eyes == null:
		return
	var eye := eyes.global_position if eyes.is_inside_tree() else eyes.position
	var boom := 1.0
	if mode == "shoulder" and blocked.is_valid():
		var full := pose(mode, eye, eyes.yaw, eyes.pitch)
		var free: Variant = blocked.call(eye, full.origin)
		if free is float or free is int:
			boom = boom_for(float(free))
	var t := pose(mode, eye, eyes.yaw, eyes.pitch, top_dist, boom)
	if is_inside_tree():
		global_transform = t
	else:
		transform = t
