class_name BusyNote
extends Label
## "Time passes..." under the crosshair while the game runs on by itself (a long wait, sleep, a long craft), so the
## screen never looks hung. Shown while the game asks nothing: at once (ACTIVITY_MS) with the snapshot's word for
## it, "Sleeping" (Snapshot.asleep) or CDDA's verb ("Waiting", Snapshot.activity_verb); with neither (an older
## bridge, which also sends no snapshot meanwhile) "Time passes" once it has asked nothing for AFTER_MS. The dots
## move; the next request hides it (main: on_request from LiveSession.request_changed, on_snapshot, tick each frame).

const AFTER_MS := 800     # a normal turn's gap between requests is a few ms
const ACTIVITY_MS := 250  # with an activity: soon, but not for a one-turn flicker
const DOT_MS := 400
const TEXT := "Time passes"
const SLEEPING := "Sleeping"

var quiet_since := -1     # msec the game last went without a request, -1 while it asks something
var word := ""            # the latest snapshot's word for what the character is doing, "" none


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


## A new snapshot: what the character is doing now.
func on_snapshot(snap: Snapshot) -> void:
	word = word_for(snap)


## Shows or hides the note for `now_ms`; `running`: a live game is running (not booting, ended or failed). Not
## running forgets the quiet and the word: the next game shows nothing until its first request has come and gone.
func tick(now_ms: int, running: bool) -> void:
	if not running:
		quiet_since = -1
		word = ""
	var t := text_at(quiet_since, now_ms, running, word)
	visible = t != ""
	if visible and t != text:
		text = t


## "Sleeping" when asleep, else the activity's verb with a capital ("Waiting"), "" for neither or no snapshot.
static func word_for(snap: Snapshot) -> String:
	if snap == null:
		return ""
	if snap.asleep:
		return SLEEPING
	return snap.activity_verb.left(1).to_upper() + snap.activity_verb.substr(1)


## The note for a game quiet since `since` (-1: asking something) doing `what` ("" unknown), "" when none shows.
static func text_at(since: int, now_ms: int, running: bool, what := "") -> String:
	var wait := ACTIVITY_MS if what != "" else AFTER_MS
	if not running or since < 0 or now_ms - since < wait:
		return ""
	return (what if what != "" else TEXT) + ".".repeat(1 + ((now_ms - since - wait) / DOT_MS) % 3)
