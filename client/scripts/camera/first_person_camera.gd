class_name FirstPersonCamera
extends Camera3D
## Block C9: the first-person view, the default on a flat screen. The eyes sit EYE_H above the floor of level
## `z`. Two modes:
## - follow (live game): the camera stands on the CDDA player's square and glides after it as the sim moves
##   the player. The body only moves through the sim's action queue (main.gd queues steps where you look).
## - free walk (mock snapshot): WASD / left stick walk the snapshot with VrWalk's collisions (walls stop you,
##   doors don't); `change_level` goes up or down like the VR rig.
## Input comes only through the action map (InputActions): look with the mouse while `look` (RMB) is held, or
## with the right stick. The camera is separate from the player's body (VR-ready rule): nothing here talks to
## the sim. Tests drive `step()` directly.

const EYE_H := 1.6
const WALK_SPEED := 3.0      # m/s, free walk
const FAST := 2.5            # speed factor while move_fast is held
const MAX_STEP := 0.25       # m per collision check (a frame hitch must not jump a wall)
const FOLLOW_RATE := 12.0    # 1/s: how fast the camera catches up with the player's square
const SNAP_DIST := 4.0       # further than this, jump instead of gliding (first world, long moves)
const PITCH_MAX := 1.5
const STICK_LOOK := 2.5      # rad/s at full right stick
const VIEWS := ["first", "shoulder", "top", "outside"]   # C9: ViewCamera draws shoulder and top

var world: WorldView
var walk: VrWalk
var z := 0
var follow := false
var yaw := 0.0
var pitch := 0.0
## Mouse look: `sensitivity` in radians per pixel, `invert_y` turns the up-down motion the other way; with `fov`
## (Camera3D's) they are the G7 options main sets from hud.cfg (HudSettings).
var sensitivity := 0.003
var invert_y := false
var target := Vector3.ZERO   # follow: where the eyes are headed
## () -> Transform3D: while the player is on a vehicle still gliding to where the snapshot puts it, the eyes ride
## with it (VehicleView.ride_transform, set by main.gd); identity otherwise.
var ride := Callable()
## C5 recentre (flat screen, driving in first person): () -> Variant, the yaw to ease the look back to (the
## vehicle's heading, as `yaw`) or null for none (main.gd: driving, first person, the F1 switch). It pulls only
## after RECENTRE_AFTER seconds without look input (mouse or stick); any look input starts the wait again.
var recentre := Callable()
const RECENTRE_AFTER := 1.5   # s without look input
const RECENTRE_RATE := 1.5    # 1/s: how fast the look eases back
var look_idle := 0.0          # seconds since the last look input
var _has_target := false
## The view offset (eye tracking, lead-ui 2026-11-19; flat screen only: VR has its own camera): a small turn, tilt,
## side shift and zoom on top of the look, for zooming where you look (1), seeing past a screen edge (2) and leaning
## (9). `yaw`, `pitch` and `target` never include it (steps, facing and anything saved read those); the drawn
## rotation, `position` (side shift) and `fov` do, so LookRay, aim and screen casts, which go through this camera,
## pick what the offset view shows. Set by set_view_offset, eased (OFFSET_RATE), clamped, back to exactly none.
const OFFSET_RATE := 8.0                 # 1/s
const OFFSET_TURN_DEG := 10.0            # yaw and pitch, each way
const OFFSET_ROLL_DEG := 15.0
const OFFSET_SIDE_M := 0.4
const OFFSET_FOV := Vector2(0.3, 1.0)    # fov scale
const OFFSET_NONE: Array[float] = [0.0, 0.0, 0.0, 0.0, 1.0]   # yaw, pitch, roll (rad), side (m), fov scale
var _off_to: Array[float] = OFFSET_NONE.duplicate()
var _off: Array[float] = OFFSET_NONE.duplicate()
var _side := Vector3.ZERO                # the side shift and the bend's in `position` now (slid against walls)
## Looking down bends the body at the hips (PlayerBody.bend_for: radians, 0 upright) and the eyes move forward and down
## with the head (PlayerBody.eye_shift, slid against walls like the side shift); none while riding a vehicle. main.gd
## bends the drawn body as much.
var bend := 0.0
## The field of view without the offset's zoom (main's G7 option); `fov` is this times the zoom.
var base_fov := 75.0:
	set(v):
		base_fov = v if is_finite(v) else 75.0
		fov = base_fov * _off[4]


func _init(w: WorldView) -> void:
	world = w
	walk = VrWalk.new(w)
	name = "FirstPersonCamera"
	near = 0.05
	far = 600.0


## The start view from the command line: --view=first|shoulder|top|outside. Without it the view is first
## person, except that --camera= (a fly-camera pose for screenshots) means outside.
static func view_from_args(args: Dictionary) -> String:
	var v := String(args.get("view", ""))
	if v in VIEWS:
		return v
	return "outside" if args.has("camera") else "first"


func set_look(new_yaw: float, new_pitch: float) -> void:
	yaw = wrapf(new_yaw, -PI, PI)
	pitch = clampf(new_pitch, -PITCH_MAX, PITCH_MAX)
	rotation = Vector3(clampf(pitch + _off[1], -PITCH_MAX, PITCH_MAX), yaw + _off[0], _off[2])


## The view offset to ease toward: turn `yaw_deg` (left +) and `pitch_deg` (up +), roll `roll_deg` (left +), shift
## `side_m` to the right (+) and zoom by `fov_scale` (1 none). Clamped; a non-finite value counts as none. All none
## eases back to exactly no offset.
func set_view_offset(yaw_deg: float, pitch_deg: float, roll_deg: float, side_m: float, fov_scale := 1.0) -> void:
	_off_to = [deg_to_rad(_fin(yaw_deg, 0.0, OFFSET_TURN_DEG)), deg_to_rad(_fin(pitch_deg, 0.0, OFFSET_TURN_DEG)),
			deg_to_rad(_fin(roll_deg, 0.0, OFFSET_ROLL_DEG)), _fin(side_m, 0.0, OFFSET_SIDE_M),
			clampf(fov_scale, OFFSET_FOV.x, OFFSET_FOV.y) if is_finite(fov_scale) else 1.0]


## The offset now: [yaw, pitch, roll (rad), side (m, as wished; the shift in `position` may be shorter at a wall),
## fov scale] (tests).
func view_offset() -> Array[float]:
	return _off.duplicate()


static func _fin(v: float, none: float, limit: float) -> float:
	return clampf(v, -limit, limit) if is_finite(v) else none


## Eases the offset one frame and puts it on the camera: rotation, the side shift and the bend's (slid like walking,
## so they stop at a wall) and the fov.
func _ease_offset(delta: float) -> void:
	var k := 1.0 - exp(-OFFSET_RATE * delta)
	for i in _off.size():
		_off[i] = lerpf(_off[i], _off_to[i], k)
		if absf(_off[i] - _off_to[i]) < 0.0005:
			_off[i] = _off_to[i]   # arrives exactly (none is exactly none)
	set_look(yaw, pitch)
	bend = PlayerBody.bend_for(pitch) if _ride() == Transform3D() else 0.0
	var lean := Basis(Vector3.UP, yaw) * PlayerBody.eye_shift(bend)
	var base := base_position()
	var want := right() * _off[3] + Vector3(lean.x, 0.0, lean.z)
	var to := base
	if want.length() > 0.0005 and world.snapshot != null:
		var n := maxi(ceili(want.length() / MAX_STEP), 1)
		for i in n:
			to = walk.slide(to, want / n, z)
	to.y = base.y + lean.y
	_side = to - base
	position = to
	fov = base_fov * _off[4]


## Where the eyes are without the offset's side shift: the body stands under this, and squares are read from it.
func base_position() -> Vector3:
	return position - _side


## Mouse motion in pixels.
func look(rel: Vector2) -> void:
	look_idle = 0.0
	set_look(yaw - rel.x * sensitivity, pitch - rel.y * sensitivity * (-1.0 if invert_y else 1.0))


## The look [yaw, pitch] eased `dt` seconds toward yaw `goal` and level, once `idle` seconds passed without look
## input (RECENTRE_AFTER); unchanged before, or when goal isn't finite.
static func recentred(y: float, p: float, goal: float, idle: float, dt: float) -> Vector2:
	if idle < RECENTRE_AFTER or not is_finite(goal) or not is_finite(dt):
		return Vector2(y, p)
	var k := 1.0 - exp(-RECENTRE_RATE * clampf(dt, 0.0, 1.0))
	return Vector2(lerp_angle(y, goal, k), lerpf(p, 0.0, k))


## Forward and right along the ground for the current yaw.
func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


## Free walk: stands on the centre of CDDA square sq.
func go_to_square(sq: Vector3i) -> void:
	z = sq.z
	position = _eye(world.coords.ms_center_to_world(sq))
	_side = Vector3.ZERO   # the next frame shifts it again from here
	target = position


## Free walk: up (+1) or down (-1) a level to the nearest standable square; false when there is none.
func change_level(dz: int) -> bool:
	var to: Variant = walk.nearest_standable(walk.square_at(position, z + dz))
	if to == null:
		return false
	go_to_square(to)
	return true


## Free walk: takes stair s (StairUse.find) to the nearest standable square where it leads; false when none.
func use_stair(s: Dictionary) -> bool:
	var to: Variant = walk.nearest_standable(s["to"]) if not s.is_empty() else null
	if to == null:
		return false
	go_to_square(to)
	return true


## Live: the CDDA player's square. The camera glides there (jumps the first time and when far).
func follow_square(sq: Vector3i) -> void:
	follow = true
	z = sq.z
	target = _eye(world.coords.ms_center_to_world(sq))
	var r := _ride()
	if r != Transform3D():
		position = r * target   # seated in the vehicle where it is drawn, not where the snapshot jumped
		_side = Vector3.ZERO
	elif not _has_target or base_position().distance_to(target) > SNAP_DIST:
		position = target
		_side = Vector3.ZERO
	_has_target = true


func _ride() -> Transform3D:
	var r: Variant = ride.call() if ride.is_valid() else null
	return r if r is Transform3D and (r as Transform3D).is_finite() else Transform3D()


## The Godot origin moved (map shift): keep standing on the same square.
func shift(d: Vector3) -> void:
	position += d
	target += d


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action("look"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.is_pressed() else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look((event as InputEventMouseMotion).relative)


func _process(delta: float) -> void:
	step(delta, {"move": Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward"),
			"fast": Input.is_action_pressed(&"move_fast"),
			"look": Input.get_vector(&"look_left", &"look_right", &"look_up", &"look_down")})


## One frame: `move` and `look` are Vector2 with x right and y forward / down, -1..1; `fast` a bool. Moves the eyes
## without the side shift, then eases the view offset on top.
func step(delta: float, inp: Dictionary) -> void:
	delta = minf(delta, 0.1)
	position = base_position()
	_side = Vector3.ZERO
	_move(delta, inp)
	_recentre(delta)
	_ease_offset(delta)


func _recentre(delta: float) -> void:
	look_idle += delta
	var g: Variant = recentre.call() if recentre.is_valid() else null
	if (g is float or g is int) and look_idle >= RECENTRE_AFTER:
		var to := recentred(yaw, pitch, float(g), look_idle, delta)
		set_look(to.x, to.y)


func _move(delta: float, inp: Dictionary) -> void:
	var lk: Vector2 = inp.get("look", Vector2.ZERO)
	if lk != Vector2.ZERO:
		look_idle = 0.0
		set_look(yaw - lk.x * STICK_LOOK * delta, pitch - lk.y * STICK_LOOK * delta)
	if follow:
		var r := _ride()
		position = r * target if r != Transform3D() else position.lerp(target, 1.0 - exp(-FOLLOW_RATE * delta))
		return
	var mv: Vector2 = inp.get("move", Vector2.ZERO)
	if mv == Vector2.ZERO or world.snapshot == null:
		return
	if mv.length() > 1.0:
		mv = mv.normalized()
	var speed := WALK_SPEED * (FAST if inp.get("fast", false) else 1.0)
	var d := (right() * mv.x + forward() * mv.y) * speed * delta
	var n := maxi(ceili(d.length() / MAX_STEP), 1)
	for i in n:
		position = walk.slide(position, d / n, z)
	position = _eye(position)


## Eyes EYE_H above what one stands on at p on level z: the floor, or the stair flight or ramp drawn there.
func _eye(p: Vector3) -> Vector3:
	return Vector3(p.x, world.ground_y(p, z) + EYE_H, p.z)
