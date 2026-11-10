extends SceneTree
## Headless check of character creation through the bridge: start_new_game with chargen, the `chargen`
## request's catalog read by the client's Chargen model, a bad answer re-asked with `status`, a good one
## reaching the main loop with that character; then a fresh start under the taken name (and in upper case),
## each in a child process, must fail without touching the world. Needs the DLL and ../cdda data. ~2 min.
## From the repo root:
##   godot --headless --path client --script res://tests/chargen_live_test.gd

const WORLD := "fp3d-chargen-test"
const TIMEOUT_MS := 240000
## The run's own scratch folder (shared user:// otherwise collides between parallel runs).
const TestDir := preload("res://tests/test_dir.gd")

var _failed := 0
var _sim: RefCounted


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--taken="):
			_run_taken(a.trim_prefix("--taken="))
			return
	_run()


func _run() -> void:
	_check(ClassDB.class_exists("CddaSim"), "extension loaded")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := ProjectSettings.globalize_path("res://").path_join("../cdda").simplify_path()
	var user_dir := TestDir.global("cdda-chargen-test")
	_check(not String(_sim.start_new_game(data_dir, user_dir, "no-such-world", false, true)).is_empty(),
			"refuses an existing-world start in a world that isn't there")
	var why: String = _sim.start_new_game(data_dir, user_dir, WORLD, true, true, true)
	_check(why.is_empty(), "starts (%s)" % why)
	var wreq := await _wait(func(r: Dictionary) -> bool: return r.get("kind") == "world_setup")
	_check(not wreq.is_empty(), "world_setup request arrives (%s %s)" % [_sim.get_state(), _sim.get_error()])
	if wreq.is_empty():
		_finish()
		return
	var ws := WorldSetup.parse(wreq["text"])
	_check(ws.ok and ws.sliders.size() >= 3 and ws.mods.size() > 5 and ws.problem().is_empty(),
			"client reads the world catalog (%s; %d sliders, %d mods, %s)" % [ws.error, ws.sliders.size(), ws.mods.size(), ws.problem()])
	_sim.answer({"id": wreq["id"], "text": "{\"mods\":[\"no_such_mod\"]}"})
	var wagain := await _wait(func(r: Dictionary) -> bool: return r.get("kind") == "world_setup" and r["id"] != wreq["id"])
	_check(not wagain.is_empty() and String(wagain["status"]) != "", "bad world answer re-asked (%s)"
			% wagain.get("status", ""))
	ws.set_level(ws.sliders[0]["id"], 0)
	_sim.answer({"id": wagain["id"], "text": ws.answer_json()})
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
	_check(FileAccess.file_exists(user_dir.path_join("save/%s/worldoptions.json" % WORLD)), "world saved with its settings")
	_sim.stop()
	# A fresh start under a taken name (also in other letter case) must fail and leave the world alone. CDDA
	# boots once per process, so each try is its own process (same scratch folder, --test-run).
	var world_dir := user_dir.path_join("save").path_join(WORLD)
	var before := _tree(world_dir)
	for name: String in [WORLD, WORLD.to_upper()]:
		var out := []
		var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
				"--script", "res://tests/chargen_live_test.gd", "--", "--taken=" + name, TestDir.child_arg()])
		var code := OS.execute(OS.get_executable_path(), args, out, true)
		for chunk: String in out:
			print(chunk.strip_edges(false, true).indent("  | "))
		_check(code == 0, "a fresh start as %s is refused (exit %d)" % [name, code])
	_check(not before.is_empty() and _tree(world_dir) == before,
			"the taken world's files are untouched (%d files)" % before.size())
	_finish()


## Child run (--taken=<name>): a fresh start_new_game as <name> in run 1's folder ends in `failed`, "exists".
func _run_taken(name: String) -> void:
	_check(TestDir.use_parent(OS.get_cmdline_user_args()), "run 1 named its folder (--test-run)")
	_check(ClassDB.class_exists("CddaSim"), "extension loaded")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := ProjectSettings.globalize_path("res://").path_join("../cdda").simplify_path()
	var user_dir := TestDir.global("cdda-chargen-test")
	var why: String = _sim.start_new_game(data_dir, user_dir, name, true, true, true)
	var deadline := Time.get_ticks_msec() + TIMEOUT_MS
	var req := {}
	while Time.get_ticks_msec() < deadline and req.is_empty() and _sim.get_state() in ["booting", "running"]:
		await create_timer(0.05).timeout
		_sim.drain_events()
		req = _sim.get_request()
	_check(why.is_empty() and req.is_empty() and _sim.get_state() == "failed"
			and String(_sim.get_error()).contains("exists"),
			"%s: refused before any request (%s, state %s, %s, request %s)"
			% [name, why, _sim.get_state(), _sim.get_error(), req.get("kind", "none")])
	_sim.stop()
	_finish(false)


## Every file under `path` (relative path -> [size, modified time]).
func _tree(path: String) -> Dictionary:
	var files := {}
	var todo := PackedStringArray([""])
	while not todo.is_empty():
		var rel := todo[todo.size() - 1]
		todo.remove_at(todo.size() - 1)
		var d := DirAccess.open(path.path_join(rel))
		if d == null:
			continue
		d.include_hidden = true
		for f in d.get_files():
			var p := path.path_join(rel).path_join(f)
			var fa := FileAccess.open(p, FileAccess.READ)
			files[rel.path_join(f)] = [fa.get_length() if fa != null else -1, FileAccess.get_modified_time(p)]
		for sub in d.get_directories():
			todo.append(rel.path_join(sub))
	return files


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
		if r["timed"] or r["kind"] == "chargen" or r["kind"] == "world_setup":
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


## `clean`: false in a child run, which shares run 1's folder.
func _finish(clean := true) -> void:
	if _failed == 0 and clean:
		TestDir.clean()   # a failed run keeps its files to look at; the next run's clean() removes them
	print("chargen live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
