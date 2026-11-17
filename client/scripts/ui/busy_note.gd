class_name BusyNote
extends Label
## "Time passes..." under the crosshair while the game runs on by itself (a long wait, sleep, a long craft): the
## bridge asks nothing and sends no snapshot until the stretch is over, so without it the screen just stands still.
## Shown once the game has asked nothing for AFTER_MS while running; the dots move so it never looks hung; gone with
## the next request (main: on_request from LiveSession.request_changed, tick each frame).

const AFTER_MS := 800     # a normal turn's gap between requests is a few ms
const DOT_MS := 400
const TEXT := "Time passes"

var quiet_since := -1     # msec the game last went without a request, -1 while it asks something


func _init() -> void:
	name = "BusyNote"
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_top = 60
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_color_override("font_outline_color", Color.BLACK)
	add_theme_constant_override("outline_size", 4)


## The game's pending request changed: {} means it is working on its own.
func on_request(req: Dictionary, now_ms: int) -> void:
	if not req.is_empty():
		quiet_since = -1
	elif quiet_since < 0:
		quiet_since = now_ms


## Shows or hides the note for `now_ms`; `running`: a live game is running (not booting, ended or failed). Not
## running forgets the quiet: the next game shows nothing until its first request has come and gone.
func tick(now_ms: int, running: bool) -> void:
	if not running:
		quiet_since = -1
	var t := text_at(quiet_since, now_ms, running)
	visible = t != ""
	if visible and t != text:
		text = t


## The note for a game quiet since `since` (-1: asking something), "" when none shows.
static func text_at(since: int, now_ms: int, running: bool) -> String:
	if not running or since < 0 or now_ms - since < AFTER_MS:
		return ""
	return TEXT + ".".repeat(1 + ((now_ms - since - AFTER_MS) / DOT_MS) % 3)
