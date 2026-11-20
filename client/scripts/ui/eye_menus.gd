class_name EyeMenus
extends Node
## Eye tracking 6 (user, 2026-11-19; flat screen): in a menu (the F1 menu, the Tab view, the character screen, a
## prompt or list, a wheel), the mouse pointer goes where the eyes rest, and the `gaze_click` key clicks there, so
## what you look at is pointed at and a key picks it. Nothing happens by gaze alone: a pointer over a button only
## shows it. The mouse wins: after the mouse moves, the eyes leave the pointer alone for MOUSE_QUIET_MS. Off (the
## switch, or no menu, or no tracked gaze): nothing changes. main adds it last, so its _input sees the key before
## the menus (Godot gives input to the last nodes first).

const DWELL_MS := 150          # the eyes rest this long (within STILL_PX) before the pointer goes there
const STILL_PX := 40.0
const MOUSE_QUIET_MS := 600    # after a real mouse move, the eyes wait this long
const NEAR_PX := 12.0          # the pointer this close already: no move

var gaze: GazeSource
## () -> bool: the switch is on and a menu is open (main).
var allowed := Callable()
var _fix: Variant = null       # where the eyes rest (Vector2), null while they move or aren't tracked
var _fix_ms := -1
var _mouse_ms := -1000000000   # the last real mouse move
var _warped: Variant = null    # the last point the pointer was sent to (its motion event isn't the user's)


func active() -> bool:
	return gaze != null and allowed.is_valid() and allowed.call() == true and gaze.tracked()


## The eyes' point now (checked against the viewport), null if none.
func point() -> Variant:
	if gaze == null or not is_inside_tree():
		return null
	return GazeSource.point_in(gaze.screen_point(), get_viewport().get_visible_rect().size)


## One step at `now_ms` with the pointer at `mouse`: where to move the pointer (the eyes rested elsewhere long enough
## and the mouse was quiet), or null.
func step(now_ms: int, p: Variant, mouse: Vector2, on: bool) -> Variant:
	if not on or not p is Vector2:
		_fix = null
		return null
	var v: Vector2 = p
	if not _fix is Vector2 or v.distance_to(_fix) > STILL_PX:
		_fix = v
		_fix_ms = now_ms
		return null
	if now_ms - _fix_ms < DWELL_MS or now_ms - _mouse_ms < MOUSE_QUIET_MS or mouse.distance_to(_fix) <= NEAR_PX:
		return null
	return _fix


## The press and release of a left click at `at` (viewport pixels).
static func click_events(at: Vector2) -> Array[InputEventMouseButton]:
	var out: Array[InputEventMouseButton] = []
	for down: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = at
		e.global_position = at
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		out.append(e)
	return out


func _process(_delta: float) -> void:
	var on := active()
	var to: Variant = step(Time.get_ticks_msec(), point() if on else null, get_viewport().get_mouse_position(), on)
	if to is Vector2:
		_warped = to
		get_viewport().warp_mouse(to)


func _input(event: InputEvent) -> void:
	var m := event as InputEventMouseMotion
	if m != null:
		if not (_warped is Vector2 and m.position.distance_to(_warped) < 2.0):
			_mouse_ms = Time.get_ticks_msec()   # the user's own move
		_warped = null
		return
	if not InputActions.pressed(event, &"gaze_click") or not active():
		return
	var at: Variant = point()
	if not at is Vector2:
		return
	get_viewport().set_input_as_handled()
	for e: InputEventMouseButton in click_events(at):
		get_viewport().push_input.call_deferred(e)   # after this event is done
