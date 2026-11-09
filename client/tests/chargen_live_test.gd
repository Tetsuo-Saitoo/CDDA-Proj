extends SceneTree
## Headless check of character creation through the bridge: start_new_game with chargen, the `chargen`
## request's catalog read by the client's Chargen model, a bad answer re-asked with `status`, a good one
## reaching the main loop with that character. Needs the DLL and ../cdda data. ~1 min. From the repo root:
##   godot --headless --path client --script res://tests/chargen_live_test.gd

const WORLD := "fp3d-chargen-test"
const TIMEOUT_MS := 240000

var _failed := 0
var _sim: RefCounted


func _initialize() -> void:
	_run()


func _run() -> void:
	_check(ClassDB.class_exists("CddaSim"), "extension loaded")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := ProjectSettings.globalize_path("res://").path_join("../cdda").simplify_path()
	var user_dir := OS.get_user_data_dir().path_join("cdda-chargen-test")
	_check(not String(_sim.start_new_game(data_dir, user_dir, "no-such-world", false, true)).is_empty(),
			"refuses an existing-world start in a world that isn't there")
	var why: String = _sim.start_new_game(data_dir, user_dir, WORLD, true, true)
	_check(why.is_empty(), "starts (%s)" % why)
	var req := await _wait(func(r: Dictionary) -> bool: return r.get("kind") == "chargen")
	_check(not req.is_empty(), "chargen request arrives (%s %s)" % [_sim.get_state(), _sim.get_error()])
	if req.is_empty():
		_finish()
		return
	var c := Chargen.parse(req["text"])
	_check(c.ok and c.scenarios.size() > 5 and c.professions.size() > 20, "client reads the catalog (%s)" % c.error)
	_sim.answer({"id": req["id"], "text": "{\"scenario\":\"nope\"}"})
	var again := await _wait(func(r: Dictionary) -> bool: return r.get("kind") == "chargen" and r["id"] != req["id"])
	_check(not again.is_empty() and String(again["status"]) != "", "bad answer re-asked with status (%s)"
			% again.get("status", ""))
	c.set_name("Chargen Tester")
	c.set_stat("str", 10)
	_sim.answer({"id": again["id"], "text": c.answer_json()})
	var main := await _wait(func(r: Dictionary) -> bool: return r.get("timed", false))
	_check(not main.is_empty() and _sim.get_state() == "running", "reaches the main loop (%s %s)"
			% [_sim.get_state(), _sim.get_error()])
	var snap := Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	_check(snap.is_valid(), "snapshot valid")
	_sim.stop()
	_finish()


## Waits for a request matching `want`, answering others like live_test (YES / any key / cancel).
func _wait(want: Callable) -> Dictionary:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	var answered := 0
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_sim.drain_events()
		var state: String = _sim.get_state()
		if state != "booting" and state != "running":
			return {}
		var r: Dictionary = _sim.get_request()
		if r.is_empty() or r["id"] == answered:
			continue
		if want.call(r):
			return r
		if r["timed"] or r["kind"] == "chargen":
			continue
		var a := {"id": r["id"], "cancel": true}
		if r["context"] == "RAW_KEY":
			a = {"id": r["id"], "action": " "}
		elif r["kind"] == "popup" and not r["actions"].is_empty():
			a = {"id": r["id"], "action": "YES" if "YES" in r["actions"] else r["actions"][0]}
		print("  answering %s %s: %s" % [r["kind"], r["context"], a])
		answered = r["id"]
		_sim.answer(a)
	return {}


func _finish() -> void:
	print("chargen live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
