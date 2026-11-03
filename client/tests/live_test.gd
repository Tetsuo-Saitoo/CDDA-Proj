extends SceneTree
## Headless check of the bridge (CddaSim): loads the extension, refuses bad input, boots a new CDDA game,
## reads a snapshot, the id tables and events, plays a turn through the action queue, stops. Needs the DLL
## (build target fp3d-cdda) and the game data in ../cdda. ~1 min. From the repo root:
##   godot --headless --path client --script res://tests/live_test.gd
## Exit code 0 = all passed.

const WORLD := "fp3d-live-test"
const BOOT_TIMEOUT_MS := 240000
const TURN_TIMEOUT_MS := 60000

var _failed := 0
var _sim: RefCounted
var _events := {}   # kind -> count


func _initialize() -> void:
	_run()


func _run() -> void:
	_check(ClassDB.class_exists("CddaSim"), "extension loaded (class CddaSim)")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := _repo("cdda")
	var user_dir := OS.get_user_data_dir().path_join("cdda-test")
	_check(not String(_sim.start("cdda", user_dir, WORLD)).is_empty(), "refuses a relative data dir")
	_check(not String(_sim.start(data_dir, user_dir, "../x")).is_empty(), "refuses a world name with a path")
	_check(not String(_sim.start(user_dir, user_dir, WORLD)).is_empty(), "refuses a data dir without data/json")
	_check(_sim.get_state() == "idle", "still idle after refusals")
	_check(not _sim.answer({}) and not _sim.answer({"id": "1"}) and not _sim.answer({"id": 1, "picks": [[1]]}),
			"rejects malformed answers")
	_check(not _sim.queue_action(""), "rejects an empty action")

	var why: String = _sim.start(data_dir, user_dir, WORLD)
	_check(why.is_empty(), "starts (%s)" % why)
	_check(not String(_sim.start(data_dir, user_dir, WORLD)).is_empty(), "refuses a second start")
	var req := await _main_loop_request(0, BOOT_TIMEOUT_MS)
	_check(not req.is_empty(), "reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	if req.is_empty():
		_finish()
		return
	_check(_sim.get_state() == "running", "state running")
	var turn0: int = req["turn"]

	var snap := Snapshot.parse_text(_sim.get_snapshot_json(1, 1))
	_check(snap.is_valid(), "live snapshot passes the client's checks (%s)" % snap.error)
	_check(snap.turn == turn0 and snap.seq == _sim.get_snapshot_seq(), "snapshot is the one before the request")
	_check(snap.submaps.size() == 11 * 11 * 3, "three levels of submaps (%d)" % snap.submaps.size())
	var ids: Variant = JSON.parse_string(_sim.get_id_tables_json())
	_check(ids is Dictionary and (ids["ter"] as Array).size() > 1000, "id tables parse, >1000 terrain")
	var clock: Dictionary = _sim.get_clock()
	_check(clock.get("real_time") == false and clock.get("paused") == false, "turn-based, not paused")

	# Safe mode refuses to wait while a hostile is in view; random starts can have one.
	var queued: bool = _sim.queue_action("safemode") and _sim.queue_action("pause") and _sim.queue_action("pause")
	_check(queued, "queues actions")
	req = await _main_loop_request(turn0, TURN_TIMEOUT_MS)
	_check(not req.is_empty() and int(req["turn"]) > turn0, "a turn passes (turn %s)" % req.get("turn", "?"))
	_check(_events.get("turn_end", 0) > 0, "turn_end events (%s)" % _events)
	_check(_sim.get_events_dropped() == 0, "no events dropped")

	var t0 := Time.get_ticks_msec()
	_sim.stop()
	_check(_sim.get_state() == "stopped", "stops (%d ms)" % (Time.get_ticks_msec() - t0))
	_finish()


## Waits for a main-loop (timed) request with a turn above `after_turn`, answering anything else the way a
## player would get out of it. {} on timeout or if the game stops.
func _main_loop_request(after_turn: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		for e: Dictionary in _sim.drain_events():
			_events[e["kind"]] = _events.get(e["kind"], 0) + 1
		var state: String = _sim.get_state()
		if state != "booting" and state != "running":
			return {}
		var req: Dictionary = _sim.get_request()
		if req.is_empty():
			continue
		if req["timed"]:
			if int(req["turn"]) > after_turn or after_turn == 0:
				return req
			continue
		var a := {"id": req["id"], "cancel": true}
		if req["context"] == "RAW_KEY":
			a = {"id": req["id"], "action": " "}
		elif req["kind"] == "popup" and not req["actions"].is_empty():
			a = {"id": req["id"], "action": req["actions"][0]}
		print("  answering %s %s (%s): %s" % [req["kind"], req["context"], req["title"], a])
		_sim.answer(a)
	return {}


func _finish() -> void:
	print("live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()
