extends SceneTree
## Headless check of the bridge (CddaSim) in two Godot runs, since CDDA runs once per process.
## Run 1 loads the extension, refuses bad input, lists worlds and saves from a crafted folder, boots a new CDDA
## game, reads a snapshot, the id tables and events, plays a turn through the action queue, saves while paused
## (save_game) and plays on, stops a turn later, then starts run 2 (`-- --load`): it loads that save, checks the
## turn and position, and stops.
## Needs the DLL (build target fp3d-cdda) and the game data in ../cdda. ~2 min. From the repo root:
##   godot --headless --path client --script res://tests/live_test.gd
## Exit code 0 = all passed.

const WORLD := "fp3d-live-test"
const BOOT_TIMEOUT_MS := 240000
const TURN_TIMEOUT_MS := 60000
## What run 1 saved, for run 2 (in the test's user dir).
const EXPECT_FILE := "live_test_expect.json"
## The run's own scratch folder (shared user:// otherwise collides between parallel runs); run 2 uses run 1's.
const TestDir := preload("res://tests/test_dir.gd")

var _failed := 0
var _sim: RefCounted
var _events := {}   # kind -> count
var _messages: Array[String] = []
var _run_name := "live tests"
var _data_dir := ""
var _user_dir := ""


func _initialize() -> void:
	_data_dir = _repo("cdda")
	if "--load" in OS.get_cmdline_user_args():
		_run_name = "live tests (load run)"
		_check(TestDir.use_parent(OS.get_cmdline_user_args()), "run 1 named its folder (--test-run)")
		_user_dir = TestDir.global("cdda-test")
		_run_load()
	elif "--delete-locked" in OS.get_cmdline_user_args():
		_run_name = "live tests (delete from a world in use)"
		_check(TestDir.use_parent(OS.get_cmdline_user_args()), "run 1 named its folder (--test-run)")
		_user_dir = TestDir.global("cdda-test")
		_run_delete_locked()
	else:
		_user_dir = TestDir.global("cdda-test")
		_run()


func _run() -> void:
	_check(ClassDB.class_exists("CddaSim"), "extension loaded (class CddaSim)")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := _data_dir
	var user_dir := _user_dir
	_check(not String(_sim.start("cdda", user_dir, WORLD)).is_empty(), "refuses a relative data dir")
	_check(not String(_sim.start(data_dir, user_dir, "../x")).is_empty(), "refuses a world name with a path")
	_check(not String(_sim.start(user_dir, user_dir, WORLD)).is_empty(), "refuses a data dir without data/json")
	_check(not String(_sim.start_load(data_dir, user_dir, WORLD, "")).is_empty(), "start_load refuses no save")
	_check(not String(_sim.start_load(data_dir, user_dir, "../x", "A")).is_empty(),
			"start_load refuses a world name with a path")
	_check(not String(_sim.start_load(data_dir, user_dir, WORLD, "nobody here")).is_empty(),
			"start_load refuses a save that isn't there")
	_check(_sim.get_state() == "idle", "still idle after refusals")
	_check(not _sim.answer({}) and not _sim.answer({"id": "1"}) and not _sim.answer({"id": 1, "picks": [[1]]}),
			"rejects malformed answers")
	var shot := {"end": Vector3i(1, 2, 0), "hit_uid": 0, "part": "", "quality": 0.5}
	var many := []
	many.resize(33)
	many.fill({})
	var bad_pellets: Array = ["x", [1], [{"end": Vector3i.ZERO, "quality": NAN}], [{"hit_uid": 3}],
			[{"end": Vector3i.ZERO, "hit_uid": 1.5}], many]
	_check(bad_pellets.all(func(b: Variant) -> bool: return not _sim.answer({"id": 1, "shot": shot.merged({"pellets": b})})),
			"rejects malformed shot pellets")
	# well formed: taken (no request waits, so the sim drops it)
	_check(_sim.answer({"id": 1, "shot": shot.merged({"pellets": [{}, shot, shot]})}), "takes well-formed shot pellets")
	_check(not _sim.queue_action(""), "rejects an empty action")
	var take := {"op": "take", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0)}
	var bad_items: Array[Dictionary] = [{}, take.merged({"op": "eat"}, true), take.merged({"item": 5.0}, true),
			take.merged({"item": 0}, true), take.merged({"item": 1 << 53}, true), take.merged({"hand": "tail"}, true),
			take.merged({"pos": Vector3i(1 << 27, 0, 0)}, true), {"op": "take", "item": 5, "type": 3},
			{"op": "put", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0)},
			take.merged({"op": "put", "container": 6, "container_type": 3, "pocket": 256}, true),
			take.merged({"op": "drop", "spot": Vector2(1.5, 0)}, true),
			take.merged({"op": "drop", "spot": Vector2(NAN, 0)}, true)]
	# place, spot and hold (item physics): `to` only and always with place, a pose only with a spot, a hand for hold.
	var place := {"op": "place", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0), "to": Vector3i(2, 2, 0)}
	var spot := {"op": "spot", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0), "spot": Vector2(0.5, 0.5)}
	var hold := {"op": "hold", "item": 5, "type": 3, "hand": "main"}
	bad_items.append_array([{"op": "place", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0)},
			place.merged({"to": Vector3i(1 << 27, 0, 0)}, true), place.merged({"to": Vector3(2, 2, 0)}, true),
			{"op": "place", "item": 5, "type": 3, "to": Vector3i(2, 2, 0)}, take.merged({"to": Vector3i(2, 2, 0)}, true),
			place.merged({"yaw": 90}, true), place.merged({"side": true}, true),
			{"op": "spot", "item": 5, "type": 3, "pos": Vector3i(1, 2, 0)},
			spot.merged({"yaw": 360}, true), spot.merged({"yaw": -1}, true), spot.merged({"yaw": 1.5}, true),
			spot.merged({"side": 1}, true), take.merged({"spot": Vector2(0.5, 0.5), "yaw": 90}, true),
			{"op": "hold", "item": 5, "type": 3}, hold.merged({"hand": "pack"}, true),
			hold.merged({"hand": "tail"}, true), hold.merged({"tag": 0}, true), hold.merged({"tag": 1 << 31}, true),
			hold.merged({"tag": 1.0}, true), take.merged({"tag": -5}, true)])
	_check(bad_items.all(func(d: Dictionary) -> bool: return not _sim.queue_item_action(d)),
			"rejects malformed item actions")
	_check_listing()

	var why: String = _sim.start(data_dir, user_dir, WORLD)
	_check(why.is_empty(), "starts (%s)" % why)
	_check(not String(_sim.start(data_dir, user_dir, WORLD)).is_empty(), "refuses a second start")
	var req := await _main_loop_request(0, BOOT_TIMEOUT_MS)
	_check(not req.is_empty(), "reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	if req.is_empty():
		_finish()
		return
	_check(_sim.get_state() == "running", "state running")
	_check(_sim.delete_save(user_dir, WORLD, "Anyone", false) == "not while a game runs",
			"delete_save refused while a game runs")
	var turn0: int = req["turn"]

	var snap := Snapshot.parse_text(_sim.get_snapshot_json(1, 1))
	_check(snap.is_valid(), "live snapshot passes the client's checks (%s)" % snap.error)
	_check(snap.turn == turn0 and snap.seq == _sim.get_snapshot_seq(), "snapshot is the one before the request")
	_check(snap.submaps.size() == 11 * 11 * 3, "three levels of submaps (%d)" % snap.submaps.size())
	# A random character can start with nothing in container pockets, so the test kit (a worn giant backpack with
	# items in it, given at the next main-loop request, no turn passes) makes sure something is carried. Builds
	# with the cheat opt-in (fp3d-bridge f8326cc) refuse kits until the client allows cheats; the first kit also
	# turns this game's achievements off.
	if _sim.has_method("set_cheats_allowed"):
		_sim.set_cheats_allowed(true)
	_check(_sim.give_test_kit(), "test kit requested")
	var kit_req := await _main_loop_request(0, TURN_TIMEOUT_MS, int(req["id"]))
	var kits: int = int((_sim.get_cheats() as Dictionary).get("kits_given", 0))
	_check(not kit_req.is_empty() and kits >= 1, "test kit given (%d)" % kits)
	var kit_snap := Snapshot.parse_text(_sim.get_snapshot_json(1, 1))
	_check(kit_snap.is_valid() and kit_snap.carried.size() >= Snapshot.CARRIED_STRIDE,
			"carried items with handles (%d)" % (kit_snap.carried.size() / Snapshot.CARRIED_STRIDE))
	var ids: Variant = JSON.parse_string(_sim.get_id_tables_json())
	_check(ids is Dictionary and (ids["ter"] as Array).size() > 1000, "id tables parse, >1000 terrain")
	var clock: Dictionary = _sim.get_clock()
	_check(clock.get("real_time") == false and clock.get("paused") == false, "turn-based, not paused")

	# CDDA's safe mode would refuse to wait with a hostile in view (random starts can have one); FP3D games start
	# with it off, so waiting just works.
	# A well-formed item action with a tag is taken; nobody carries item 5, so its answer is a refusal.
	var queued: bool = (_sim.queue_item_action(hold.merged({"tag": 7}, true)) and _sim.queue_action("pause")
			and _sim.queue_action("pause"))
	_check(queued, "queues actions")
	req = await _main_loop_request(turn0, TURN_TIMEOUT_MS)
	_check(not req.is_empty() and int(req["turn"]) > turn0, "a turn passes (turn %s)" % req.get("turn", "?"))
	_check(_events.get("turn_end", 0) > 0, "turn_end events (%s)" % _events)
	_check(_events.get("item_result", 0) == 1, "one item_result event for the tagged item action (%s)" % _events)
	_check(_sim.get_events_dropped() == 0, "no events dropped")
	if req.is_empty():
		_finish()
		return

	# Save while paused and play on (save_game); an autosave with nothing new is skipped; one more turn, then stop
	# without saving: the second run must load the saved turn, not the later one.
	var saved_turn: int = req["turn"]
	snap = Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	var saved_pos := snap.player_pos
	_check(snap.is_valid() and snap.turn == saved_turn, "snapshot at the save turn")
	_check(_sim.list_saves(user_dir, WORLD).is_empty(), "no save before saving")
	_sim.set_paused(true)
	_check(_sim.save_game(), "asks for a save (paused)")
	var st := await _saves_done(1, TURN_TIMEOUT_MS)
	_check(st.get("ok", false) and not st.get("pending", true), "saves while paused (%s)" % st)
	_check(_messages.count("Game saved.") == 1, "the message log says so")
	_check(_sim.get_state() == "running", "plays on after saving")
	var saves: PackedStringArray = _sim.list_saves(user_dir, WORLD)
	_check(saves.size() == 1, "one save in the world (%s)" % saves)
	_check(WORLD in _sim.list_worlds(user_dir), "the world is listed")
	_check(_sim.save_game(true), "asks for an autosave")
	st = await _saves_done(2, TURN_TIMEOUT_MS)
	_check(st.get("ok", false), "an autosave with nothing new counts as done (%s)" % st)
	_check(_messages.count("Game saved.") == 1, "and writes nothing")
	_sim.set_paused(false)
	_check(_sim.queue_action("pause"), "queues a wait after saving")
	req = await _main_loop_request(saved_turn, TURN_TIMEOUT_MS)
	_check(not req.is_empty() and int(req["turn"]) > saved_turn,
			"a turn passes after the save (turn %s)" % req.get("turn", "?"))
	var t0 := Time.get_ticks_msec()
	_sim.stop()
	_check(_sim.get_state() == "stopped", "stops without saving (%d ms)" % (Time.get_ticks_msec() - t0))
	_check(not _sim.save_game(), "no save once stopped")
	if saves.size() != 1:
		_finish()
		return

	var expect := {"save": saves[0], "turn": saved_turn, "pos": [saved_pos.x, saved_pos.y, saved_pos.z]}
	var f := FileAccess.open(user_dir.path_join(EXPECT_FILE), FileAccess.WRITE)
	f.store_string(JSON.stringify(expect))
	f.close()
	print("  second run: load %s at turn %d, %s" % [saves[0], saved_turn, saved_pos])
	var out := []
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://tests/live_test.gd", "--", "--load", TestDir.child_arg()])
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	for chunk: String in out:
		print(chunk.strip_edges(false, true).indent("  | "))
	_check(code == 0, "second run loads the save and passes (exit %d)" % code)
	_finish()


## Run 2: loads what run 1 saved; the turn and position must match. Deletes nothing.
func _run_load() -> void:
	_check(ClassDB.class_exists("CddaSim"), "extension loaded (class CddaSim)")
	var expect: Variant = JSON.parse_string(FileAccess.get_file_as_string(_user_dir.path_join(EXPECT_FILE)))
	var ok: bool = (expect is Dictionary and expect.get("save") is String and expect.get("turn") is float
			and expect.get("pos") is Array and (expect["pos"] as Array).size() == 3)
	_check(ok, "reads what run 1 saved (%s)" % EXPECT_FILE)
	if _failed > 0:
		_finish()
		return
	var p: Array = expect["pos"]
	var saved_pos := Vector3i(int(p[0]), int(p[1]), int(p[2]))
	var saved_turn := int(expect["turn"])
	_sim = ClassDB.instantiate("CddaSim")
	_check(Array(_sim.list_saves(_user_dir, WORLD)) == [expect["save"]], "the save is listed")
	var why: String = _sim.start_load(_data_dir, _user_dir, WORLD, expect["save"])
	_check(why.is_empty(), "starts loading (%s)" % why)
	var req := await _main_loop_request(0, BOOT_TIMEOUT_MS)
	_check(not req.is_empty(), "reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	if req.is_empty():
		_finish()
		return
	var snap := Snapshot.parse_text(_sim.get_snapshot_json(1, 1))
	_check(snap.is_valid(), "loaded snapshot passes the client's checks (%s)" % snap.error)
	_check(int(req["turn"]) == saved_turn, "turn matches the save (%d, saved %d)" % [req["turn"], saved_turn])
	_check(snap.player_pos == saved_pos, "position matches the save (%s, saved %s)" % [snap.player_pos, saved_pos])
	_check(snap.submaps.size() == 11 * 11 * 3, "three levels of submaps (%d)" % snap.submaps.size())
	_check(snap.turn == saved_turn, "snapshot turn matches too (%d)" % snap.turn)
	_check(Array(_sim.list_saves(_user_dir, WORLD)) == [expect["save"]], "the save is still there")
	# Another process can't delete from the world this one plays (run 3 tries; it shares run 1's folder).
	var parent: String = Array(OS.get_cmdline_user_args()).filter(
			func(a: String) -> bool: return a.begins_with("--test-run="))[0]
	var out := []
	var code := OS.execute(OS.get_executable_path(), PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--script", "res://tests/live_test.gd", "--",
			"--delete-locked", parent]), out, true)
	for chunk: String in out:
		print(chunk.strip_edges(false, true).indent("  | "))
	_check(code == 0, "another process can't delete from this world while it plays (exit %d)" % code)
	_sim.stop()
	_check(_sim.get_state() == "stopped", "stops")
	# Once the game is done: the character and its now empty world go.
	why = _sim.delete_save(_user_dir, WORLD, expect["save"], true)
	_check(why.is_empty(), "delete_save deletes the character after its game (%s)" % why)
	_check(_sim.list_saves(_user_dir, WORLD).is_empty() and not (WORLD in _sim.list_worlds(_user_dir)),
			"and the world it leaves empty")
	_finish()


## Run 3, started by run 2 while its game holds the world: delete_save must refuse and touch nothing.
func _run_delete_locked() -> void:
	var sim: RefCounted = ClassDB.instantiate("CddaSim")
	var saves := Array(sim.list_saves(_user_dir, WORLD))
	_check(saves.size() == 1, "the save is listed (%s)" % [saves])
	if saves.size() == 1:
		var why: String = sim.delete_save(_user_dir, WORLD, saves[0], true)
		_check(why == "that world is in use by another game", "delete_save refused (%s)" % why)
		_check(Array(sim.list_saves(_user_dir, WORLD)) == saves, "the save is still there")
	_finish()


## list_worlds / list_saves on a crafted user dir: only real world folders with plain names, only save files
## whose names decode the way CDDA writes them.
func _check_listing() -> void:
	var root := TestDir.global("cdda-list-test")
	var w := root.path_join("save/listed")
	DirAccess.make_dir_recursive_absolute(w)
	_touch(w.path_join("worldoptions.json"))
	# Alice, Bob (compressed); a non-canonical Alice, no '#', bad digit, "##", control bytes, wrong suffix.
	for name: String in ["#QWxpY2U=.sav", "#Qm9i.sav.zzip", "#QWxpY2V=.sav", "plain.sav", "#bad!.sav",
			"#IyM=.sav", "#AAoA.sav", "#QWxpY2U=.sav.bak"]:
		_touch(w.path_join(name))
	DirAccess.make_dir_recursive_absolute(w.path_join("#Q2Fyb2w=.sav"))   # a folder, not a save
	DirAccess.make_dir_recursive_absolute(root.path_join("save/no-options"))
	DirAccess.make_dir_recursive_absolute(root.path_join("save/.hidden"))
	_touch(root.path_join("save/.hidden/worldoptions.json"))
	var sim: RefCounted = ClassDB.instantiate("CddaSim")
	var worlds := Array(sim.list_worlds(root))
	_check(worlds == ["listed"], "list_worlds: only world folders with plain names (%s)" % [worlds])
	var saves := Array(sim.list_saves(root, "listed"))
	_check(saves == ["Alice", "Bob"], "list_saves: decodes names, skips odd files (%s)" % [saves])
	_check(sim.list_saves(root, "../save/listed").is_empty() and sim.list_saves(root, "no-options").is_empty()
			and sim.list_saves("relative", "listed").is_empty(), "list_saves refuses paths and non-worlds")
	_check(sim.list_worlds(root.path_join("missing")).is_empty(), "no worlds in a missing user dir")

	# delete_save: everything named <Alice's base>.<anything> goes (folders too, links in them removed, not
	# followed), nothing else; the world stays while save files are left in it.
	for name: String in ["#QWxpY2U=.log", "#QWxpY2U=.apu.json", "#QWxpY2U=X.log"]:
		_touch(w.path_join(name))
	DirAccess.make_dir_recursive_absolute(w.path_join("#QWxpY2U=.mm1"))
	_touch(w.path_join("#QWxpY2U=.mm1/m.0.0.0"))
	var outside := root.path_join("outside")
	DirAccess.make_dir_recursive_absolute(outside)
	_touch(outside.path_join("keep.txt"))
	# Links need privileges on Windows: checked when one could be made.
	var linked := DirAccess.open(w).create_link(outside, w.path_join("#QWxpY2U=.mm1/link")) == OK
	_check(not String(sim.delete_save(root, "../save/listed", "Alice", false)).is_empty()
			and not String(sim.delete_save(root, "listed", "Carol", false)).is_empty()
			and not String(sim.delete_save(root, "no-options", "Alice", false)).is_empty()
			and String(sim.delete_save(root, "LISTED", "Alice", false)) == "no world LISTED"
			and not String(sim.delete_save("relative", "listed", "Alice", false)).is_empty(),
			"delete_save refuses paths, non-worlds and unlisted saves")
	var why: String = sim.delete_save(root, "listed", "Alice", true)
	_check(why.is_empty(), "delete_save deletes Alice (%s)" % why)
	var left := Array(DirAccess.get_files_at(w)) + Array(DirAccess.get_directories_at(w))
	var alice_left := left.filter(func(n: String) -> bool: return n.begins_with("#QWxpY2U=."))
	_check(alice_left.is_empty(), "all of Alice's files and folders are gone (%s)" % [alice_left])
	var kept := ["worldoptions.json", "#Qm9i.sav.zzip", "#QWxpY2V=.sav", "#QWxpY2U=X.log", "#Q2Fyb2w=.sav"]
	_check(kept.all(func(n: String) -> bool: return n in left), "everything else stays (%s)" % [left])
	_check(FileAccess.file_exists(outside.path_join("keep.txt")),
			"a link's target stays (link made: %s)" % linked)
	_check(Array(sim.list_saves(root, "listed")) == ["Bob"] and "listed" in Array(sim.list_worlds(root)),
			"Bob is left, and the world with save files in it")


func _touch(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.close()


## Waits for a main-loop (timed) request with a turn above `after_turn` (0: any turn) and an id other than
## `after_id`, answering anything else the way a player would get out of it (YES to confirmations). {} on timeout
## or if the game stops.
func _main_loop_request(after_turn: int, timeout_ms: int, after_id := -1) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_drain()
		var state: String = _sim.get_state()
		if state != "booting" and state != "running":
			return {}
		var req: Dictionary = _sim.get_request()
		if req.is_empty():
			continue
		if req["timed"]:
			if (int(req["turn"]) > after_turn or after_turn == 0) and int(req["id"]) != after_id:
				return req
			continue
		var a := {"id": req["id"], "cancel": true}
		if req["context"] == "RAW_KEY":
			a = {"id": req["id"], "action": " "}
		elif req["kind"] == "popup" and not req["actions"].is_empty():
			a = {"id": req["id"], "action": "YES" if "YES" in req["actions"] else req["actions"][0]}
		print("  answering %s %s (%s): %s" % [req["kind"], req["context"], req["title"], a])
		_sim.answer(a)
	return {}


## Waits until `n` saves have finished (get_save_status); {} on timeout or if the game stops.
func _saves_done(n: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_drain()
		var st: Dictionary = _sim.get_save_status()
		if int(st["done"]) >= n:
			return st
		if _sim.get_state() != "running":
			return {}
	return {}


func _drain() -> void:
	for e: Dictionary in _sim.drain_events():
		_events[e["kind"]] = _events.get(e["kind"], 0) + 1
		if e["kind"] == "message":
			_messages.append(e["text"])


func _finish() -> void:
	# Run 1 owns the folder (run 2 has finished by now). A failed run keeps it to look at; the next run's
	# clean() removes it.
	if not ("--load" in OS.get_cmdline_user_args() or "--delete-locked" in OS.get_cmdline_user_args()):
		if _failed == 0:
			TestDir.clean()
		else:
			print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print(_run_name + ": " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()
