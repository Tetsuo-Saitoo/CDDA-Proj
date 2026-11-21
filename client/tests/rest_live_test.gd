extends SceneTree
## Headless live run of CDDA's wait and sleep through the client (the `wait` and `sleep` main-loop actions, as the
## Shift+. and Shift+S keys send them), in the test range, where nothing is hostile:
## 1. `wait`: CDDA's "Wait for how long?" menu comes as a request (after its alarm clock question); 30 minutes is
##    picked and the game passes those 1800 turns by itself. Then the same wait with real time on
##    (_real_time_wait): still fast-forwarded.
## 2. Three waits of 6 hours, so the character is tired: long stretches of turns the game passes by itself.
## 3. `sleep`: CDDA's questions are answered (yes, no alarm, keep trying and don't ask again); the character lies
##    down and time passes by itself, until an hour has passed or the character is up again. How long that takes
##    is CDDA's dice (the range's hub is lit, and "It's too bright to sleep." wakes a sleeper at any hour): printed
##    with what CDDA said, not checked.
## 4. stop() ends the game.
## While the game runs on by itself the client must still hear from it, or the screen stands still (clock, light,
## needs) and looks hung: the bridge has a newer snapshot at least every SILENT_MS of real time (its seq), and one
## with a new turn is shown at least every SHOWN_MS (reading a snapshot of some 900 KB takes a busy machine a while,
## so the screen gets more time than the bridge).
## It prints how long a turn takes then, and what a night's sleep comes to at that rate.
## Uses this run's own CDDA folder. Needs the DLL (build target fp3d-cdda) and the game data. ~3 min. From the
## repo root:
##   godot --headless --path client --script res://tests/rest_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const ASK_TIMEOUT_MS := 30000
const WAIT_TIMEOUT_MS := 300000
const SLEEP_LIMIT_MS := 300000
const SILENT_MS := 2000             # the longest the bridge may go without a newer snapshot
const SHOWN_MS := 5000              # the longest the screen may go without showing one with a new turn
const STALL_MS := 60000             # no new turn for this long: a watch gives up
const NIGHT_TURNS := 8 * 3600
const SAID_MAX := 12

var _failed := 0
var _main: Main
var _live: LiveSession
var _answered := 0
var _hold := false        # true: requests are left to the step waiting for them
var _said: Array[String] = []   # CDDA's latest messages (the bridge's message events), at most SAID_MAX


func _initialize() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_run()


func _run() -> void:
	if not LiveSession.test_range_available():
		_check(false, "the bridge has the test range")
		_finish()
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-rest")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	_live.events_arrived.connect(_on_events)
	var r := _find_button(_main.main_menu, "Test range") if _main.main_menu != null else null
	_check(r != null, "the menu has \"Test range\"")
	if r == null:
		_finish()
		return
	r.pressed.emit()
	var t0 := Time.get_ticks_msec()
	var up := await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null, BOOT_TIMEOUT_MS)
	_check(up, "the test range runs (%.0f s, state %s %s)" % [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if up and await _wait(4, "30 minutes", 1800) and await _real_time_wait():
		var tired := true
		for i in 3:
			tired = tired and await _wait(8, "6 hours", 6 * 3600)
		if tired:
			await _sleep()
	await _stop()
	_finish()


## CDDA's wait for the menu entry `id` (or one whose label has `label`), `turns` long. False when it didn't pass.
func _wait(id: int, label: String, turns: int) -> bool:
	var turn0: int = await _settled()
	_hold = true
	_check(_live.queue_action("wait"), "CDDA's \"wait\" queued (%s)" % label)
	var menu: Variant = await _request_of("menu", ASK_TIMEOUT_MS)
	# With an alarm clock CDDA asks first whether to wait or set an alarm.
	var first: Variant = _entry(menu, func(_i: int, l: String) -> bool: return l.begins_with("Wait a while"))
	if first != null:
		_reply(menu, {"entry": first})
		menu = await _request_of("menu", ASK_TIMEOUT_MS, int(menu["id"]))
	var entry: Variant = _entry(menu, func(i: int, l: String) -> bool: return i == id and l.contains(label))
	if entry == null:
		entry = _entry(menu, func(_i: int, l: String) -> bool: return l.contains(label))
	_check(entry != null, "\"Wait for how long?\" comes as a menu with \"%s\" (%s)" % [label, _labels(menu)])
	if entry == null:
		if menu != null:
			_reply(menu, {"cancel": true})
		_hold = false
		return false
	_reply(menu, {"entry": entry})
	_hold = false
	var w: Dictionary = await _watch(turn0, turns - 10, WAIT_TIMEOUT_MS)
	print("  wait %s: %d turns in %.1f s (%.2f ms a turn), %d snapshot(s) with a new turn, longest silence %.1f s; the bridge had %d, longest gap %.1f s"
			% [label, w["turns"], w["ms"] / 1000.0, w["rate"], w["seen"], w["silent"] / 1000.0, w["sent"], w["quiet"] / 1000.0])
	_check(w["done"], "%s pass by themselves (%d of %d turns in %.0f s)" % [label, w["turns"], turns, w["ms"] / 1000.0])
	_check(w["quiet"] <= SILENT_MS, "the game has a newer snapshot while it waits %s (longest gap %.1f s, limit %.1f)"
			% [label, w["quiet"] / 1000.0, SILENT_MS / 1000.0])
	_check(w["silent"] <= SHOWN_MS, "the screen follows while it waits %s (longest silence %.1f s, limit %.1f)"
			% [label, w["silent"] / 1000.0, SHOWN_MS / 1000.0])
	if w["ms"] > 3000 and _main.get("busy_note") != null:   # a stretch long enough for the note (BusyNote, lead-ui)
		_check(w["noted"] != "", "the screen says that time passes while it waits %s (\"%s\")" % [label, w["noted"]])
	return w["done"]


## CDDA's sleep, with a tired character.
func _sleep() -> void:
	var turn0: int = await _settled()
	_said.clear()
	_hold = true   # the questions are this step's: _sleep_reply
	_check(_live.queue_action("sleep"), "CDDA's \"sleep\" queued")
	var asked := PackedStringArray()
	var slept := [false]
	var look := func() -> void:
		_sleep_reply(asked)
		slept[0] = slept[0] or _asleep()
	var up := func() -> bool:   # the questions answered, time has passed, and the main loop asks for the next action
		var req := _live.request
		return not asked.is_empty() and _main.world.snapshot.turn > turn0 and req.get("kind", "") == "key" \
				and req.get("context", "") == "DEFAULTMODE"
	var w: Dictionary = await _watch(turn0, 3600, SLEEP_LIMIT_MS, look, up)
	_hold = false
	await _settled()
	var passed: int = _main.world.snapshot.turn - turn0
	print("  sleep: asked %s" % [asked])
	print("  sleep: seen asleep in a snapshot: %s" % ["yes" if slept[0] or _asleep() else "no"])
	print("  sleep: CDDA said %s" % [_said])
	if not w["done"] and not w["ended"]:   # what the game waits for, when the turns stopped
		var req := _live.request
		print("  sleep: the game now asks: %s %s timed %s \"%s\" %s" % [req.get("kind", "nothing"), req.get("context", ""),
				req.get("timed", false), str(req.get("text", req.get("title", ""))).left(80), _labels(req)])
	print("  sleep: %d turns (%.1f h of game time) in %.1f s (%.2f ms a turn), %d snapshot(s) with a new turn, longest silence %.1f s; the bridge had %d, longest gap %.1f s"
			% [passed, passed / 3600.0, w["ms"] / 1000.0, w["rate"], w["seen"], w["silent"] / 1000.0, w["sent"], w["quiet"] / 1000.0])
	print("  at that rate a night (%d turns) takes %.0f s of real time" % [NIGHT_TURNS, NIGHT_TURNS * w["rate"] / 1000.0])
	_check(w["done"] or (w["ended"] and passed > 0), "the character lies down to sleep and time passes by itself (%.0f min in %.1f s, %s)"
			% [passed / 60.0, w["ms"] / 1000.0, "and it goes on" if w["done"] else ("then up again" if w["ended"] else "then nothing")])
	_check(w["quiet"] <= SILENT_MS, "the game has a newer snapshot while the character sleeps (longest gap %.1f s, limit %.1f)"
			% [w["quiet"] / 1000.0, SILENT_MS / 1000.0])
	_check(w["silent"] <= SHOWN_MS, "the screen follows while the character sleeps (longest silence %.1f s, limit %.1f)"
			% [w["silent"] / 1000.0, SHOWN_MS / 1000.0])
	if w["ms"] > 3000 and _main.get("busy_note") != null:
		_check(w["noted"] != "", "the screen says that time passes while the character sleeps (\"%s\")" % w["noted"])


## Watches the game run on by itself from turn `turn0` until `turns` have passed (or `timeout_ms`, or `until`
## says so), calling `each` on every look. {done (the turns passed), ended (`until` said so first), turns, ms, rate
## (ms a turn), seen (shown snapshots with a new turn), silent (the longest time without one, ms), sent (newer
## snapshots the bridge had, by its seq), quiet (the longest time without one, ms), noted (what main's busy note
## said meanwhile, "Time passes" or CDDA's word, without its dots; "" when it never showed)}.
func _watch(turn0: int, turns: int, timeout_ms: int, each := Callable(), until := Callable()) -> Dictionary:
	var noted := ""
	var ended := false
	var seen := 0
	var last_turn := turn0
	var t0 := Time.get_ticks_msec()
	var last_ms := t0
	var silent := 0
	var sent := 0
	var last_seq := _bridge_seq()
	var last_seq_ms := t0
	var quiet := 0
	var done := false
	while Time.get_ticks_msec() - t0 < timeout_ms and _live.state == "running":
		if each.is_valid():
			each.call()
		elif not _hold:
			_answer(_live.request)
		var now := Time.get_ticks_msec()
		var note: Variant = _main.get("busy_note")
		if note is Label and (note as Label).visible and not (note as Label).text.rstrip(".").is_empty():
			noted = (note as Label).text.rstrip(".")
		var seq := _bridge_seq()
		if seq != last_seq:
			sent += 1
			quiet = maxi(quiet, now - last_seq_ms)
			last_seq = seq
			last_seq_ms = now
		var t: int = _main.world.snapshot.turn
		if t != last_turn:
			seen += 1
			silent = maxi(silent, now - last_ms)
			last_turn = t
			last_ms = now
		if t >= turn0 + turns:
			done = true
			break
		if until.is_valid() and until.call():
			ended = true
			break
		if now - last_ms > STALL_MS:
			break   # nothing new for a long while: the game stopped passing turns
		await create_timer(0.05).timeout
	var ms := Time.get_ticks_msec() - t0
	if not done and not ended:
		silent = maxi(silent, Time.get_ticks_msec() - last_ms)
		quiet = maxi(quiet, Time.get_ticks_msec() - last_seq_ms)
	var passed := last_turn - turn0
	return {"done": done, "ended": ended, "turns": passed, "ms": ms, "rate": float(ms) / maxi(passed, 1), "seen": seen,
			"silent": silent, "sent": sent, "quiet": quiet, "noted": noted}


## The same 30-minute wait with real time on (lead-ui's real-time key; skipped, said so, on a client without it):
## the game still passes those turns by itself, far faster than a turn a second, real time is still on afterwards,
## and the key again puts the game back in turns for the rest of this run. False when it can't go on.
func _real_time_wait() -> bool:
	if not InputMap.has_action(&"real_time_toggle") or not _live.has_method("set_real_time"):
		print("  (no real-time switch in this client: a wait in real time not checked)")
		return true
	var real := func() -> bool: return _live.clock().get("real_time") == true
	var on := _press(&"real_time_toggle") and await _until(real, ASK_TIMEOUT_MS)
	_check(on, "the real-time key turns real time on")
	var t0 := Time.get_ticks_msec()
	var passed := on and await _wait(4, "30 minutes", 1800)
	var s := (Time.get_ticks_msec() - t0) / 1000.0
	_check(passed and s < 120.0 and real.call(),
			"in real time a 30-minute wait is still fast-forwarded (1800 turns in %.0f s, not half an hour), and real time stays on (%s)"
			% [s, real.call()])
	var turns := func() -> bool: return not real.call()
	var off := _press(&"real_time_toggle") and await _until(turns, ASK_TIMEOUT_MS)
	_check(off, "the real-time key again: back in turns")
	return passed and off


## Presses the first key bound to `action` (F1 defaults) in the window; false when it has none.
func _press(action: StringName) -> bool:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			root.push_input(k)
			return true
	return false


## The seq of the bridge's newest snapshot (CddaSim.get_snapshot_seq), whether the client has read it yet or not;
## -1 without a bridge.
func _bridge_seq() -> int:
	var s: Object = _live.sim() if _live != null else null
	return int(s.call("get_snapshot_seq")) if s != null and s.has_method("get_snapshot_seq") else -1


## Waits until the game is back at rest (the snapshot's turn unchanged for a while, nothing queued); the turn.
func _settled() -> int:
	var turn: int = _main.world.snapshot.turn
	var since := Time.get_ticks_msec()
	var t0 := since
	while Time.get_ticks_msec() - t0 < 15000:
		if not _hold:
			_answer(_live.request)
		var t: int = _main.world.snapshot.turn
		if t != turn or _live.queued_actions() > 0:
			turn = t
			since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - since >= 700:
			break
		await create_timer(0.05).timeout
	return turn


## stop() ends the game.
func _stop() -> void:
	if _live == null or _live.state != "running":
		return
	var t0 := Time.get_ticks_msec()
	_live.stop()
	var stopped := await _until(func() -> bool: return _live.state != "running", 30000, false)
	_check(stopped, "stop() ends the game (%.1f s, state %s)" % [(Time.get_ticks_msec() - t0) / 1000.0, _live.state])
	_main.queue_free()
	await process_frame


## The bridge's events: CDDA's messages are kept (the latest SAID_MAX), to print what it said about the sleep.
func _on_events(events: Array) -> void:
	for ev: Variant in events:
		if ev is Dictionary and (ev as Dictionary).get("kind") is String and ev["kind"] == "message":
			_said.append(str((ev as Dictionary).get("text", "")).left(100))
	while _said.size() > SAID_MAX:
		_said.pop_front()


## The latest snapshot has the character asleep (CDDA's sleep effect; player.asleep on a client that reads it).
func _asleep() -> bool:
	var snap: Snapshot = _main.world.snapshot
	if snap.get("asleep") == true:
		return true
	for e: Dictionary in snap.player_effects:
		if str(e.get("id", "")) == "sleep":
			return true
	return false


## Answers a pending question the way a player who wants to sleep does: "Yes." to "are you sure", no to an alarm,
## and to "You have trouble sleeping, keep trying?" its "Continue trying ... and don't ask again." (cancelling
## that one gets the character up).
func _sleep_reply(asked: PackedStringArray) -> void:
	var req := _live.request
	var id := int(req.get("id", 0))
	if req.is_empty() or req.get("timed", false) or id == _answered:
		return
	var text := (str(req.get("title", "")) + " " + str(req.get("text", ""))).strip_edges()
	var acts: Array = req.get("actions", [])
	var want_no := text.to_lower().contains("alarm")
	var a := {"cancel": true}
	if req.get("kind", "") == "menu":
		var go_on := func(_i: int, l: String) -> bool:
			return l.to_lower().begins_with("continue") and l.to_lower().contains("ask again")
		var go_on_once := func(_i: int, l: String) -> bool: return l.to_lower().begins_with("continue")
		var yes_no := func(_i: int, l: String) -> bool: return l.to_lower().begins_with("no" if want_no else "yes")
		var pick: Variant = _entry(req, go_on)
		if pick == null:
			pick = _entry(req, go_on_once)
		if pick == null:
			pick = _entry(req, yes_no)
		if pick != null:
			a = {"entry": pick}
	elif req.get("kind", "") == "popup" and not acts.is_empty():
		a = {"action": "NO" if want_no and "NO" in acts else ("YES" if "YES" in acts else acts[0])}
	asked.append("%s \"%s\" %s -> %s" % [req.get("kind", "?"), text.left(50), _labels(req), a])
	_reply(req, a)


## Sends answer `a` to request `req` (once: the generic answerer leaves it alone after).
func _reply(req: Dictionary, a: Dictionary) -> void:
	_answered = int(req.get("id", 0))
	var out := a.duplicate()
	out["id"] = _answered
	_live.answer(out)


## The id of the first enabled entry of menu request `req` that `pick` (id, label) takes; null for none.
func _entry(req: Variant, pick: Callable) -> Variant:
	if not req is Dictionary or not (req as Dictionary).get("entries") is Array:
		return null
	for e: Variant in req["entries"]:
		if e is Dictionary and e.get("enabled", true) and (e.get("id") is int or e.get("id") is float) \
				and pick.call(int(e["id"]), str(e.get("label", e.get("text", "")))):
			return int(e["id"])
	return null


func _labels(req: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if req is Dictionary and (req as Dictionary).get("entries") is Array:
		for e: Variant in req["entries"]:
			if e is Dictionary:
				out.append("%s: %s" % [e.get("id"), str(e.get("label", e.get("text", ""))).left(24)])
	return out


## Waits for a request of `kind` other than request `after` (the others get a player's usual answer); null on
## timeout or a stopped game.
func _request_of(kind: String, timeout_ms: int, after := 0) -> Variant:
	var found := [null]
	var came := func() -> bool:
		var req := _live.request
		if req.is_empty() or int(req.get("id", 0)) == after:
			return false
		if req.get("kind", "") == kind:
			found[0] = req
			return true
		_answer(req)
		return false
	await _until(came, timeout_ms)
	return found[0]


## Waits (playing on) until `cond` holds; false on timeout or, with `end_stops`, if the game stops.
func _until(cond: Callable, timeout_ms: int, end_stops := true) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if not is_instance_valid(_live):
			return false
		if end_stops and (_live.state == "ended" or _live.state == "failed"):
			return false
		if not _hold:
			_answer(_live.request)
		await create_timer(0.05).timeout
	return false


## A prompt gets the answer a player who wants to go on resting would give: no to CDDA's "Stop waiting?" (something
## caught its attention), YES to other confirmations, else cancel.
func _answer(req: Dictionary) -> void:
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY":
		return
	var id := int(req.get("id", 0))
	if id == _answered:
		return
	var a := {"cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		var stop := str(req.get("text", "")).contains("Stop ") and "NO" in acts
		a = {"action": "NO" if stop else ("YES" if "YES" in acts else acts[0])}
	print("  answering %s %s \"%s\": %s" % [req.get("kind", "?"), acts, str(req.get("text", req.get("title", ""))).left(60), a])
	_reply(req, a)


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("rest live tests: %s" % ["all passed" if _failed == 0 else "%d FAILED" % _failed])
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
