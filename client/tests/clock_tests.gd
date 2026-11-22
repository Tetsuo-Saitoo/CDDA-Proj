extends RefCounted
## Real time or turns (lead-ui, 2026-11-20): HudSettings' [clock] switches, ClockControl, LiveSession.set_real_time,
## the F1 Time row, the HUD's time line and the two keys.

var _check: Callable


## A running game's clock as LiveSession shows it, with what the client sent.
class FakeLive extends RefCounted:
	var real_time := false
	var paused := false
	var reason := ""
	var auto := true
	var takes := true
	var sent: Array = []

	func clock() -> Dictionary:
		return {"real_time": real_time, "paused": paused, "pause_reason": reason}

	func set_real_time(on: bool) -> bool:
		sent.append(["real_time", on])
		if takes:
			real_time = on
		return takes

	func set_auto_pause(on: bool) -> bool:
		sent.append(["auto_pause", on])
		if takes:
			auto = on
		return takes

	func set_paused(on: bool) -> bool:
		sent.append(["paused", on])
		if takes:
			paused = on
		return takes


## The bridge side of LiveSession.set_real_time.
class ClockSim extends RefCounted:
	var calls: Array = []

	func set_real_time(on: bool) -> void:
		calls.append(on)


func run(_root: Node, check: Callable) -> void:
	_check = check
	print("clock")
	_test_settings()
	_test_apply()
	_test_pause_key()
	_test_text()
	_test_live()
	_test_menu_row()
	_test_keys()


func _test_settings() -> void:
	var s := HudSettings.new()
	var path: String = preload("res://tests/test_dir.gd").path("hud_clock.cfg")
	var defaults := not s.real_time and s.auto_pause
	s.real_time = true
	s.auto_pause = false
	var err := s.save_file(path)
	var back := HudSettings.new()
	back.load_file(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[clock]\nreal_time=\"yes\"\nauto_pause=0\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(defaults and err == OK and back.real_time and not back.auto_pause and not junk.real_time and junk.auto_pause,
			"clock: turns and auto-pause by default; [clock] saved and read back; junk leaves the defaults")


func _test_apply() -> void:
	var s := HudSettings.new()
	var flat := ClockControl.wanted(s, false)
	var vr := ClockControl.wanted(s, true)
	s.real_time = true
	s.auto_pause = false
	var on := ClockControl.wanted(s, false)
	_check.call(flat == {"real_time": false, "auto_pause": true} and vr["real_time"] == true
			and vr["auto_pause"] == true and on == {"real_time": true, "auto_pause": false},
			"clock: the flat screen follows the switch, VR always runs in real time (auto-pause as set)")
	var g := FakeLive.new()
	var took := ClockControl.apply(g, s, false)
	var first := g.real_time and not g.auto
	g.paused = true   # a hostile paused it, then the player goes back to turns
	s.real_time = false
	var back := ClockControl.apply(g, s, false)
	var refused := FakeLive.new()
	refused.takes = false
	_check.call(took and first and back and not g.real_time and not g.paused
			and not ClockControl.apply(refused, s, false) and not ClockControl.apply(null, s, false),
			"clock: applied to the game; back to turns lifts a pause (it would stop turns for good); refusals say so")


func _test_pause_key() -> void:
	var g := FakeLive.new()
	var turns := ClockControl.toggle_pause(g)
	g.real_time = true
	var pause := ClockControl.toggle_pause(g)
	var paused := g.paused
	var go := ClockControl.toggle_pause(g)
	_check.call(turns.begins_with("Turns") and g.sent == [["paused", true], ["paused", false]] and paused
			and not g.paused and pause.begins_with("Paused") and go == "Time runs again.",
			"clock: the pause key pauses and resumes real time (also after a hostile); in turns it does nothing")


func _test_text() -> void:
	var none := ClockControl.text({"real_time": true}, false)
	var turns := ClockControl.text({"real_time": false, "paused": false}, true)
	var rt := ClockControl.text({"real_time": true, "paused": false}, true)
	var hostile := ClockControl.text({"real_time": true, "paused": true, "pause_reason": "hostile spotted"}, true)
	var plain := ClockControl.text({"real_time": true, "paused": true, "pause_reason": "paused"}, true)
	var in_vr := ClockControl.text({"real_time": true, "paused": true, "pause_reason": "hostile spotted"}, true, true)
	var d := HudData.new()
	var seen: Array = []
	d.changed.connect(func(parts: PackedStringArray) -> void: seen.append(parts))
	d.set_clock(rt)
	d.set_clock(rt)
	d.set_clock("x".repeat(500))
	_check.call(none == "" and turns.contains("waits for you") and rt.contains("runs")
			and hostile.begins_with("TIME PAUSED: hostile spotted") and plain.begins_with("TIME PAUSED  (") and in_vr == "TIME PAUSED: hostile spotted"
			and seen.size() == 2 and d.clock.length() == 120,
			"clock: the HUD says whether time runs, waits for you or is paused (and why); changes only, capped")
	var v := HudView.new()
	v.data = d
	d.set_clock(hostile)
	d.set_cheats({"invincible": true})
	var shown: bool = v.clock_mark.text == hostile and v.cheat_mark.position.y > 8.0
	var below: bool = v.marks_bottom() >= v.cheat_mark.position.y + 20.0 and v.marks_bottom() <= 100.0
	d.set_clock("")
	shown = shown and v.clock_mark.text == "" and v.cheat_mark.position.y == 8.0
	d.set_cheats({})
	shown = shown and below and v.marks_bottom() == 0.0
	v.free()
	_check.call(shown, "clock: the HUD view shows the time line top right, the cheats marker under it, the hints below")
	_check.call(ClockControl.paused({"real_time": true, "paused": true}) and not ClockControl.paused({"paused": true})
			and not ClockControl.paused({"real_time": true, "paused": false}) and ClockControl.held_note().contains("go on"),
			"clock: actions are held back only while real time is paused, with a note how to go on")
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	_check.call(main_src.count("_held_by_pause()") >= 7,
			"clock: main drops walking, hand and key actions, stairs, use, doors and the peek while paused")


func _test_live() -> void:
	var ls := LiveSession.new()
	var none := ls.set_real_time(true)
	var sim := ClockSim.new()
	ls._sim = sim
	ls.state = "running"
	var sent := ls.set_real_time(true) and ls.set_real_time(false)
	ls.state = "stopped"
	ls._sim = null
	ls.free()
	_check.call(not none and sent and sim.calls == [true, false],
			"clock: LiveSession.set_real_time reaches a running game only")


func _test_menu_row() -> void:
	var s := HudSettings.new()
	var path: String = preload("res://tests/test_dir.gd").path("hud_clock_menu.cfg")
	var m := KeyMenu.new()
	m.add_hud_settings(s, path)
	var told := [0]
	m.hud_changed.connect(func() -> void: told[0] += 1)
	var off: bool = not m.real_time_check.button_pressed and m.auto_pause_check.button_pressed
	m.real_time_check.button_pressed = true
	m.auto_pause_check.button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	s.real_time = false
	m.show_clock()
	var shown: bool = not m.real_time_check.button_pressed and told[0] == 2
	m.free()
	_check.call(off and back.real_time and not back.auto_pause and shown,
			"clock: the F1 Time row: real time and auto-pause, saved; it follows the key's flips")


func _test_keys() -> void:
	InputActions.ensure(false)
	var rt := InputActions.slots(ClockControl.TOGGLE)
	var p := InputActions.slots(ClockControl.PAUSE)
	var alone := not rt.is_empty() and not p.is_empty() and InputActions.users_of(rt[0], ClockControl.TOGGLE).is_empty() \
			and InputActions.users_of(p[0], ClockControl.PAUSE).is_empty()
	_check.call(alone and InputActions.key_of(ClockControl.TOGGLE) == "F2"
			and InputActions.key_of(ClockControl.PAUSE) == "Backspace",
			"clock: F2 flips real time, Backspace pauses; no other action uses those keys")
