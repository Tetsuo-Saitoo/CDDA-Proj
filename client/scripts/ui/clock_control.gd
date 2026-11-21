class_name ClockControl
extends RefCounted
## Real time or turns (user via the coordinator, 2026-11-20): what the client asks of the sim's clock and what the
## HUD says about it. The flat screen follows HudSettings.real_time (off: turns, the default until it has been
## played); VR always runs in real time (PLAN.md) and the toggle does nothing there. Auto-pause on a new hostile
## follows HudSettings.auto_pause (the bridge only acts on it in real time; only the client resumes, with the
## `time_pause` key). Only on / off reaches the bridge (LiveSession set_real_time, set_auto_pause, set_paused).

const TOGGLE := &"real_time_toggle"
const PAUSE := &"time_pause"


## The clock the game should have: {real_time, auto_pause}.
static func wanted(settings: HudSettings, vr: bool) -> Dictionary:
	return {"real_time": vr or settings.real_time, "auto_pause": settings.auto_pause}


## Puts `wanted` on a running game (live: LiveSession or a stand-in with set_real_time, set_auto_pause, set_paused
## and clock). Leaving real time also lifts a pause, which would otherwise stop turns for good. True when the game
## took it all.
static func apply(live: Object, settings: HudSettings, vr: bool) -> bool:
	if live == null:
		return false
	var w := wanted(settings, vr)
	var auto: bool = live.set_auto_pause(w["auto_pause"])
	var ok: bool = live.set_real_time(w["real_time"]) and auto
	if ok and not w["real_time"] and (live.clock() as Dictionary).get("paused") == true:
		ok = live.set_paused(false)
	return ok


## The `time_pause` key: pauses real time or resumes it (also after a hostile's auto-pause). In turns there is
## nothing to pause. Returns the note to show.
static func toggle_pause(live: Object) -> String:
	var c: Dictionary = live.clock() if live != null else {}
	if c.get("real_time") != true:
		return "Turns: the game already waits for you."
	var paused: bool = c.get("paused") == true
	if not live.set_paused(not paused):
		return "The game didn't take the pause."
	return "Time runs again." if paused else "Paused. %s: go on." % InputActions.prompt_of(PAUSE)


## The note when the toggle flips the flat screen's mode to `on`.
static func flip_note(on: bool) -> String:
	if on:
		return "Real time: the game runs on its own (%s: back to turns)." % InputActions.prompt_of(TOGGLE)
	return "Turns: the game waits for you (%s: real time)." % InputActions.prompt_of(TOGGLE)


## The HUD line for LiveSession.clock() while a game runs; "" otherwise. `vr`: no key named (VR goes on from its
## menu).
static func text(clock: Dictionary, running: bool, vr := false) -> String:
	if not running:
		return ""
	if clock.get("paused") == true:
		var why := str(clock.get("pause_reason", ""))
		if why == "paused":
			why = ""
		var head := "TIME PAUSED" + (": " + why if not why.is_empty() else "")
		return head if vr else "%s  (%s: go on)" % [head, InputActions.prompt_of(PAUSE)]
	if clock.get("real_time") == true:
		return "Time runs (real time)"
	return "Time waits for you (turns)"
