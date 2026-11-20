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
	_test_lean()
	_test_view()


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
	var r6: Array = [p.step(true, true, rt, 49000), p.step(true, false, rt, 50000), p.step(true, false, rt, 52000), p.step(true, false, ours, 52100)]
	p.forget()   # the player paused by hand meanwhile (same reason text)
	r6.append(p.step(true, true, ours, 52200))
	_check.call(r6 == ["", "", EyePause.PAUSE, "", ""] and not p.paused_by_eyes,
			"eyes: a pause the player took over by hand isn't resumed by looking back (%s)" % [r6])


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


static func _near(a: Array[float], b: Array) -> bool:
	return a.size() == b.size() and range(a.size()).all(func(i: int) -> bool: return is_equal_approx(a[i], b[i]))


static func _same(a: Variant, b: Dictionary) -> bool:
	return a is Dictionary and (a as Dictionary).recursive_equal(b, 2)


## 9: a lean held 250 ms queues one peek toward its square (main loop only); the peek's request is held with no UI
## and cancelled when the lean ends; a refused peek waits for the next lean; only the 8 ways.
func _test_lean() -> void:
	var l := LeanPeek.new()
	var p := Vector3i(10, 20, 0)
	var ok := not l.lean(Vector2i(2, 0), 0) and not l.lean(Vector2i.ZERO, 0) and not l.leaning()
	ok = ok and l.lean(Vector2i(-1, 0), 1000) and l.peek_square(1100, true, p) == null
	ok = ok and l.peek_square(1300, false, p) == null   # a prompt is open
	var sq: Variant = l.peek_square(1300, true, p)
	ok = ok and sq == Vector3i(9, 20, 0) and l.peek_square(1400, true, p) == null   # once
	l.sent(true)
	ok = ok and l.on_request({"id": 5, "kind": "query", "text": "?"}) == null
	var held: Variant = l.on_request({"id": 7.0, "kind": "target", "mode": "peek"})
	ok = ok and _same(held, {}) and l.peeking()
	l.request_seen({"id": 7, "kind": "target", "mode": "peek"})
	ok = ok and l.peeking() and _same(l.unlean(), {"id": 7, "cancel": true}) and not l.peeking() and not l.leaning()
	_check.call(ok and l.unlean().is_empty(),
			"eyes: lean: held 250 ms, one peek toward that side; its request held with no UI, cancelled when it ends")
	l.lean(Vector2i(1, 1), 0)
	l.peek_square(300, true, p)
	l.sent(true)
	var refused: Variant = l.on_request({"id": 9, "timed": true})
	var again: Variant = l.peek_square(900, true, p)
	l.unlean()
	l.lean(Vector2i(1, 1), 1000)
	var next: Variant = l.peek_square(1300, true, p)
	l.sent(true)
	l.unlean()   # let go before the request came
	var late: Variant = l.on_request({"id": 11, "kind": "target", "mode": "peek"})
	var other: Variant = l.on_request({"id": 12, "kind": "target", "mode": "peek"})   # not a lean's: shown as usual
	l.lean(Vector2i(0, -1), 0)
	l.peek_square(300, true, p)
	l.sent(false)   # the bridge didn't queue it
	var unqueued: Variant = l.on_request({"id": 13, "kind": "target", "mode": "peek"})
	l.unlean()
	l.lean(Vector2i(0, 1), 0)
	l.peek_square(300, true, p)
	l.sent(true)
	l.on_request({"id": 14, "kind": "target", "mode": "peek"})
	l.request_seen({"id": 15, "timed": true})   # the game moved on by itself
	var gone := not l.peeking() and l.unlean().is_empty()
	_check.call(refused == null and again == null and next == Vector3i(11, 21, 0) and _same(late, {"id": 11, "cancel": true})
			and other == null and unqueued == null and gone,
			"eyes: lean: a refused peek isn't sent again until the next lean; a late one is cancelled; others are left alone")


## 1, 2 and the lean's tilt as one view offset: zoom toward where you looked as the key went down, the screen edge
## turns the view a little, the lean tilts and shifts (not while the peek already stands there); no eyes, no zoom.
func _test_view() -> void:
	var v := EyeView.new()
	var none := FirstPersonCamera.OFFSET_NONE
	var ok := v.step(null, null, false, 0, false) == none and v.step(null, null, true, 0, false) == none
	ok = ok and v.step(null, Vector2(0.5, -0.5), false, 0, false) == none
	var right := v.step(null, Vector2(1.0, 0.0), false, 0, false)
	var top := v.step(null, Vector2(0.0, -1.0), false, 0, false)
	var half := v.step(null, Vector2(0.925, 0.0), false, 0, false)
	ok = ok and is_equal_approx(right[0], -8.0) and right[1] == 0.0 and is_equal_approx(top[1], 8.0)
	ok = ok and is_equal_approx(half[0], -4.0)
	var z := v.step(Vector2(20.0, -10.0), Vector2(1.0, 1.0), true, 0, false)
	var z2 := v.step(Vector2(0.0, 0.0), null, true, 0, false)   # the eyes move on: the aim stays
	ok = ok and _near(z, [10.0, -5.0, 0.0, 0.0, 0.5]) and z2 == z and v.zooming()
	ok = ok and v.step(Vector2(5.0, 5.0), null, false, 0, false) == none and not v.zooming()
	var lean := v.step(null, null, false, -1, false)
	var peek := v.step(null, null, false, 1, true)
	ok = ok and _near(lean, [0.0, 0.0, 10.0, -0.25, 1.0]) and _near(peek, [0.0, 0.0, -10.0, 0.0, 1.0])
	_check.call(ok, "eyes: view: zoom where you looked (no eyes, no zoom), the screen edge turns a little, the lean tilts")
	var a: Variant = EyeView.angles(Basis(), Vector3(-1, 0, -1))
	var b: Variant = EyeView.angles(Basis(Vector3.UP, PI / 2), Vector3(-1, 1, 0))   # facing west, up and ahead
	ok = a is Vector2 and (a as Vector2).is_equal_approx(Vector2(45, 0)) and b is Vector2
	ok = ok and (b as Vector2).is_equal_approx(Vector2(0, 45)) and EyeView.angles(Basis(), Vector3(0, 0, 1)) == null
	ok = ok and EyeView.angles(Basis(), Vector3(NAN, 0, -1)) == null
	ok = ok and EyeView.on_screen(Vector2(0, 0), Vector2(100, 50)) == Vector2(-1, -1)
	ok = ok and EyeView.on_screen(Vector2(75, 25), Vector2(100, 50)) == Vector2(0.5, 0)
	ok = ok and EyeView.on_screen(Vector2(100, 25), Vector2(100, 50)) == null and EyeView.on_screen("x", Vector2(9, 9)) == null
	_check.call(ok, "eyes: view: the eyes as angles from the look and as a place on the screen; junk is none")
