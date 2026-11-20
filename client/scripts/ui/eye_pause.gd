class_name EyePause
extends RefCounted
## Eye tracking 7 (user, 2026-11-19): real time pauses while the player looks away from the screen (the gaze source
## says so for AWAY_MS) and plays on when they look back, unless something else paused it meanwhile (a hostile in
## view, the player). Turn-based play is left alone (the sim waits for the player anyway). Only "pause" / "resume"
## reach the bridge; the gaze doesn't. main asks `step` a few times a second and does what it returns.

const AWAY_MS := 1500   # looking away this long pauses
const PAUSE := "pause"
const RESUME := "resume"

var paused_by_eyes := false   # the pause is ours (resume it when the eyes come back)
var _away_ms := -1            # since when the eyes are off the screen, -1 while on it
var _reason: Variant = null   # the clock's pause_reason once ours took hold; another reason: not ours to undo


## One check: `on` the switch (HudSettings.eye_on("away_pause")), `look` the gaze source's on_screen() (true, false,
## null: can't tell), `clock` LiveSession.clock(), `now_ms` the time. Returns PAUSE, RESUME or "" (nothing to do).
func step(on: bool, look: Variant, clock: Dictionary, now_ms: int) -> String:
	var p: Variant = clock.get("paused")
	var rt: Variant = clock.get("real_time")
	var paused: bool = p is bool and p
	var reason: String = str(clock.get("pause_reason", ""))
	if paused_by_eyes and paused and _reason == null:
		_reason = reason
	if not on or not look is bool or not (rt is bool and rt):
		_away_ms = -1
		return _give_back(paused, reason)   # switched off, tracker lost, turn-based: never leave our pause behind
	if look:
		_away_ms = -1
		return _give_back(paused, reason)
	if _away_ms < 0:
		_away_ms = now_ms
	if paused_by_eyes or paused or now_ms - _away_ms < AWAY_MS:
		return ""
	paused_by_eyes = true
	_reason = null
	return PAUSE


## Ends our pause: RESUME, unless the clock is paused for another reason now (that pause stays). Also when the clock
## doesn't show our pause yet: a resume of an unpaused clock does nothing, a pause left behind would.
func _give_back(paused: bool, reason: String) -> String:
	if not paused_by_eyes:
		return ""
	paused_by_eyes = false
	var ours: bool = _reason == null or reason == _reason
	_reason = null
	return "" if paused and not ours else RESUME
