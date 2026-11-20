extends RefCounted
## Eye tracking (user, 2026-11-19), lead-ui's part: the settings group (HudSettings eye switches, the F1 row, the
## file read as hostile), the gaze sources (none: all off; SimGaze; points checked), the look-away pause (EyePause
## against a stand-in clock), menus by eye (EyeMenus' dwell and the mouse winning, the click it makes) and
## LiveSession's clock calls. Run by run_tests.gd.

var _check: Callable


## A stand-in for CddaSim's clock calls: a hostile get_clock, set_paused recorded.
class ClockSim extends RefCounted:
	var calls: Array = []
	var clock: Variant = {"real_time": "yes", "paused": true, "pause_reason": "x".repeat(500)}

	func get_clock() -> Variant:
		return clock

	func set_paused(on: bool) -> void:
		calls.append(on)


func run(_root: Node, check: Callable) -> void:
	_check = check
	print("eye tracking")
	_test_settings()
	_test_sources()
	_test_pause()
	_test_menus()
	_test_clock()


func _test_settings() -> void:
	var s := HudSettings.new()
	var defaults: bool = s.eye_on("tracker") and s.eye_on("zoom") and s.eye_on("away_pause") and s.eye_on("lean") \
			and not s.eye_on("light_adapt") and not s.eye_on("unease") and not s.eye_on("nope") \
			and HudSettings.EYE_FEATURES.size() == 10
	var unknown := s.set_eye("nope", true)
	s.set_eye("tracker", false)
	var master_off: bool = not s.eye_on("zoom") and not s.eye_on("menus") and s.eye_on("lean") \
			and s.eye_switch("zoom") and not s.eye_on("tracker")
	_check.call(defaults and not unknown and master_off and not s.eyes.has("nope"),
			"eyes: a switch per idea, atmosphere off; the master switch stops all but lean; unknown ids refused")
	var path: String = preload("res://tests/test_dir.gd").path("hud_eyes.cfg")
	var m := KeyMenu.new()
	m.add_hud_settings(s, path)
	var boxes: bool = m.eye_checks.size() == HudSettings.EYE_FEATURES.size() \
			and (m.eye_checks["zoom"] as CheckBox).disabled and not (m.eye_checks["lean"] as CheckBox).disabled \
			and not (m.eye_checks["tracker"] as CheckBox).disabled
	(m.eye_checks["tracker"] as CheckBox).button_pressed = true
	(m.eye_checks["unease"] as CheckBox).button_pressed = true
	(m.eye_checks["zoom"] as CheckBox).button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	_check.call(boxes and not (m.eye_checks["zoom"] as CheckBox).disabled and back.eyes_from_file and back.eye_on("unease")
			and not back.eye_on("zoom") and back.eye_on("tracker") and back.eye_on("menus"),
			"eyes: the F1 row has a box per idea (grey while the tracker is off, lean apart), saved and read back")
	m.free()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[eyes]\nzoom=\"no\"\nlean=0\nunease=true\nbogus=false\ntracker=false\n")
	f.close()
	var odd := HudSettings.new()
	odd.load_file(path)
	var none := HudSettings.new()
	none.load_file(preload("res://tests/test_dir.gd").path("hud_eyes_missing.cfg"))
	_check.call(odd.eye_switch("zoom") and odd.eye_switch("lean") and odd.eye_switch("unease")
			and not odd.eye_switch("tracker") and not odd.eyes.has("bogus") and not none.eyes_from_file,
			"eyes: the file's switches are read as hostile: only real bools of known ids")


func _test_sources() -> void:
	var g := GazeSource.new()
	var sim := SimGaze.new()
	var none_on: Variant = sim.on_screen()
	sim.point = Vector2(10, 20)
	var on: Variant = sim.on_screen()
	sim.present = false
	var off: Variant = sim.on_screen()
	var size := Vector2(100, 50)
	_check.call(not g.tracked() and g.screen_point() == null and g.on_screen() == null and g.ray(null).is_empty()
			and none_on == null and on == true and off == false and not sim.tracked() and sim.screen_point() == null
			and GazeSource.point_in(Vector2(10, 20), size) == Vector2(10, 20) and GazeSource.point_in(Vector2(100, 1), size) == null
			and GazeSource.point_in(Vector2(NAN, 1), size) == null and GazeSource.point_in(Vector2(-1, 1), size) == null
			and GazeSource.point_in("10,20", size) == null and GazeSource.point_in(Vector2(INF, 1), size) == null,
			"eyes: no device tracks nothing (every feature off); the simulated source; points checked against the screen")


func _test_pause() -> void:
	var p := EyePause.new()
	var rt := {"real_time": true, "paused": false, "pause_reason": ""}
	var ours := {"real_time": true, "paused": true, "pause_reason": "paused"}
	var turn := {"real_time": false, "paused": false, "pause_reason": ""}
	var r: Array = [p.step(true, false, turn, 0), p.step(true, false, rt, 1000), p.step(true, false, rt, 2000),
			p.step(true, false, rt, 2600), p.step(true, false, ours, 2900), p.step(true, false, ours, 9000),
			p.step(true, true, ours, 9100)]
	_check.call(r == ["", "", "", EyePause.PAUSE, "", "", EyePause.RESUME] and not p.paused_by_eyes,
			"eyes: looking away for 1.5 s pauses real time, once; looking back resumes it; turn-based is left alone (%s)" % [r])
	var hostile := {"real_time": true, "paused": true, "pause_reason": "hostile spotted"}
	var r2: Array = [p.step(true, false, rt, 10000), p.step(true, false, rt, 12000), p.step(true, false, ours, 12100),
			p.step(true, false, hostile, 13000), p.step(true, true, hostile, 13100)]
	var r3: Array = [p.step(true, false, rt, 20000), p.step(true, false, rt, 22000), p.step(false, false, ours, 22100)]
	var r4: Array = [p.step(true, false, rt, 30000), p.step(true, false, rt, 32000), p.step(true, null, rt, 32050)]
	var r5: Array = [p.step(true, false, hostile, 40000), p.step(true, false, hostile, 43000)]
	_check.call(r2 == ["", EyePause.PAUSE, "", "", ""] and r3 == ["", EyePause.PAUSE, EyePause.RESUME]
			and r4 == ["", EyePause.PAUSE, EyePause.RESUME] and r5 == ["", ""] and not p.paused_by_eyes,
			"eyes: another pause meanwhile stays; switching off or losing the tracker gives ours back; a paused game isn't paused again (%s %s %s %s)"
			% [r2, r3, r4, r5])


func _test_menus() -> void:
	var e := EyeMenus.new()
	var a := Vector2(100, 100)
	var r: Array = [e.step(0, a, Vector2.ZERO, false), e.step(0, a, Vector2.ZERO, true), e.step(100, a + Vector2(5, 0),
			Vector2.ZERO, true), e.step(200, a, Vector2.ZERO, true), e.step(300, a, a + Vector2(3, 3), true),
			e.step(400, Vector2(300, 100), Vector2.ZERO, true), e.step(560, Vector2(300, 100), Vector2.ZERO, true)]
	e._mouse_ms = 1000
	var quiet: Variant = e.step(1100, Vector2(300, 100), Vector2.ZERO, true)
	var later: Variant = e.step(1700, Vector2(300, 100), Vector2.ZERO, true)
	var c := EyeMenus.click_events(a)
	_check.call(r == [null, null, null, a, null, null, Vector2(300, 100)] and quiet == null and later == Vector2(300, 100)
			and c.size() == 2 and c[0].pressed and not c[1].pressed and c[0].button_index == MOUSE_BUTTON_LEFT
			and c[1].position == a and not e.active(),
			"eyes: menus: the pointer goes where the eyes rest, not while the mouse moves or already there; the key's click (%s)" % [r])
	e.free()


func _test_clock() -> void:
	var ls := LiveSession.new()
	var sim := ClockSim.new()
	var none := ls.clock()
	var no_pause := ls.set_paused(true)
	ls._sim = sim
	ls.state = "running"
	var c := ls.clock()
	var sent := ls.set_paused(true) and ls.set_paused(false)
	sim.clock = "junk"
	var junk := ls.clock()
	ls.state = "stopped"
	ls._sim = null
	ls.free()
	_check.call(none == {"real_time": false, "paused": false, "pause_reason": ""} and not no_pause
			and c["real_time"] == false and c["paused"] == true and str(c["pause_reason"]).length() <= 64 and sent
			and sim.calls == [true, false] and junk["paused"] == false,
			"eyes: LiveSession's clock is checked (only real bools, the reason capped); set_paused reaches the sim")
