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
const VIEWS := ["first", "outside"]

var world: WorldView
var walk: VrWalk
var z := 0
var follow := false
var yaw := 0.0
var pitch := 0.0
var sensitivity := 0.003
var target := Vector3.ZERO   # follow: where the eyes are headed
var _has_target := false


func _init(w: WorldView) -> void:
	world = w
	walk = VrWalk.new(w)
	name = "FirstPersonCamera"
	near = 0.05
	far = 600.0


## The start view from the command line: --view=first|outside. Without it the view is first person, except
## that --camera= (a fly-camera pose for screenshots) means outside.
static func view_from_args(args: Dictionary) -> String:
	var v := String(args.get("view", ""))
	if v in VIEWS:
		return v
	return "outside" if args.has("camera") else "first"


func set_look(new_yaw: float, new_pitch: float) -> void:
	yaw = wrapf(new_yaw, -PI, PI)
	pitch = clampf(new_pitch, -PITCH_MAX, PITCH_MAX)
	rotation = Vector3(pitch, yaw, 0.0)


## Mouse motion in pixels.
func look(rel: Vector2) -> void:
	set_look(yaw - rel.x * sensitivity, pitch - rel.y * sensitivity)


## Forward and right along the ground for the current yaw.
func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


## Free walk: stands on the centre of CDDA square sq.
func go_to_square(sq: Vector3i) -> void:
	z = sq.z
	position = world.coords.ms_center_to_world(sq) + Vector3(0.0, EYE_H, 0.0)
	target = position


## Free walk: up (+1) or down (-1) a level to the nearest standable square; false when there is none.
func change_level(dz: int) -> bool:
	var to: Variant = walk.nearest_standable(walk.square_at(position, z + dz))
	if to == null:
		return false
	go_to_square(to)
	return true


## Live: the CDDA player's square. The camera glides there (jumps the first time and when far).
func follow_square(sq: Vector3i) -> void:
	follow = true
	z = sq.z
	target = world.coords.ms_center_to_world(sq) + Vector3(0.0, EYE_H, 0.0)
	if not _has_target or position.distance_to(target) > SNAP_DIST:
		position = target
	_has_target = true


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


## One frame: `move` and `look` are Vector2 with x right and y forward / down, -1..1; `fast` a bool.
func step(delta: float, inp: Dictionary) -> void:
	delta = minf(delta, 0.1)
	var lk: Vector2 = inp.get("look", Vector2.ZERO)
	if lk != Vector2.ZERO:
		set_look(yaw - lk.x * STICK_LOOK * delta, pitch - lk.y * STICK_LOOK * delta)
	if follow:
		position = position.lerp(target, 1.0 - exp(-FOLLOW_RATE * delta))
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
