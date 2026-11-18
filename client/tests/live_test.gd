extends SceneTree
## Headless check of the bridge (CddaSim) in two Godot runs.
## Run 1 loads the extension, refuses bad input, lists worlds and saves from a crafted folder, boots a new CDDA
## game, reads a snapshot, the id tables and events, plays a turn through the action queue, saves while paused
## (save_game) and plays on, stops a turn later, loads that save as a second game in the same process (other
## folders refused, nothing of the first game shown), then starts run 2 (`-- --load`): it loads that save in a
## fresh process, checks the turn and position, stops, deletes it and plays the test range as its second game.
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
const SnapSame := preload("res://tests/snapshot_same.gd")

var _failed := 0
var _sim: RefCounted
var _events := {}   # kind -> count
var _messages: Array[String] = []
var _item_results: Array[Dictionary] = []   # item_result events since the last clear
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
	# place, spot and hold (item physics): `to` only and always with place, a pose or shelf only with a spot, a hand
	# for hold.
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
			hold.merged({"tag": 1.0}, true), take.merged({"tag": -5}, true),
			place.merged({"shelf": 2}, true), spot.merged({"shelf": 16}, true), spot.merged({"shelf": -1}, true),
			spot.merged({"shelf": 1.0}, true), take.merged({"spot": Vector2(0.5, 0.5), "shelf": 2}, true),
			{"op": "consume", "item": 0, "type": 3}, {"op": "consume", "item": 5},
			{"op": "consume", "item": 5, "type": 3, "to": Vector3i(2, 2, 0)},
			{"op": "consume", "item": 5, "type": 3, "pos": Vector3(1, 2, 0)},
			{"op": "consume", "item": 5, "type": 3, "part": ""}, {"op": "consume", "item": 5, "type": 3, "part": 3},
			{"op": "consume", "item": 5, "type": 3, "part": "arm l"},
			{"op": "consume", "item": 5, "type": 3, "part": "a".repeat(33)}, take.merged({"part": "arm_l"}, true),
			take.merged({"container": 7}, true), take.merged({"container_type": 3}, true),
			take.merged({"container": 7, "container_type": 0}, true),
			take.merged({"container": 0, "container_type": 3}, true)])
	_check(bad_items.all(func(d: Dictionary) -> bool: return not _sim.queue_item_action(d)),
			"rejects malformed item actions")
	_check(_sim.query_character() == 0, "query_character: nothing while no game runs")
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
	# The delta call (snapshot.md "Deltas"). Nothing held, or a seq the bridge never handed out: a full snapshot
	# with a key row for every submap. Holding the one it just gave: a delta with only the player's surroundings.
	var per_range: int = 11 * 11 * 3
	var whole: Dictionary = _delta_json(0)
	_check(not whole.has("base") and (whole.get("submap_keys", []) as Array).size() == per_range
			and (whole.get("submaps", []) as Array).size() == per_range and int(whole.get("seq", 0)) == snap.seq,
			"delta call, nothing held: a full snapshot with key rows")
	var part: Dictionary = _delta_json(snap.seq)
	var part_bodies: int = (part.get("submaps", []) as Array).size()
	_check(int(part.get("base", 0)) == snap.seq and (part.get("submap_keys", []) as Array).size() == per_range
			and part_bodies >= 1 and part_bodies <= 4,
			"delta call, that snapshot held: only the player's surroundings (%d submaps)" % part_bodies)
	var unknown_full: bool = true
	for since: int in [-5, snap.seq + 1000, 1 << 62]:
		var d: Dictionary = _delta_json(since)
		unknown_full = unknown_full and not d.has("base") and (d.get("submaps", []) as Array).size() == per_range
	_check(unknown_full, "delta call, a seq the bridge never gave: a full snapshot")
	# The weather the client shows (WeatherState) comes from the env's weather fields: the bridge sends them
	# (wind_at_player is -1 when it doesn't), and they give a weather that can be shown.
	var ws := WeatherState.from_snapshot(snap)
	_check(snap.wind_at_player >= 0.0 and snap.weather > 0 and snap.weather_sight >= 1.0 and snap.weather_sun >= 0.0
			and ws.sight_m >= WeatherState.SIGHT_MIN_M and ws.cloud >= 0.0 and ws.cloud <= 1.0,
			"the env's weather fields arrive (weather %d, precip %d kind %d, sight %.2f, light %d, sun %.2f, sound %d, wind %.1f m/s at the player %.1f, sheltered %s; cloud %.2f, fog %.2f)"
			% [snap.weather, snap.weather_precip, snap.weather_kind, snap.weather_sight, snap.weather_light,
			snap.weather_sun, snap.weather_sound, snap.wind_speed, snap.wind_at_player, snap.weather_sheltered, ws.cloud,
			ws.fog])
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
	# The weather cheat's picker list, and the bridge's own refusals (the game's come as range results).
	var weathers: Array = _sim.get_weather_types()
	_check(weathers.size() > 3 and weathers.size() <= 128
			and weathers.any(func(w: Dictionary) -> bool: return w.get("id") == "lightning"),
			"weather types listed (%d)" % weathers.size())
	_check(_sim.cheat_set_weather("light ning", -1.0) == 0 and _sim.cheat_set_weather("a".repeat(65), -1.0) == 0
			and _sim.cheat_set_weather("lightning", NAN) == 0 and _sim.cheat_set_weather("lightning", INF) == 0,
			"weather cheat: malformed calls refused")
	# An action for one square: the bridge refuses an empty name and squares out of range (the fork checks the rest).
	var queued_before: int = _sim.get_queued_actions()
	_check(not _sim.queue_action_at("", Vector3i.ZERO) and not _sim.queue_action_at("open", Vector3i(1 << 30, 0, 0))
			and not _sim.queue_action_at("open", Vector3i(0, 0, 1000)) and _sim.get_queued_actions() == queued_before,
			"queue_action_at: malformed calls refused")
	# G4: the character sheet, answered by the main loop while it waits.
	var cq: int = _sim.query_character()
	var sheet: Variant = null
	var cq_until := Time.get_ticks_msec() + TURN_TIMEOUT_MS
	while cq > 0 and Time.get_ticks_msec() < cq_until:
		var cq_text: String = _sim.take_query_result(cq)
		if not cq_text.is_empty():
			sheet = JSON.parse_string(cq_text)
			break
		await create_timer(0.05).timeout
	_check(cq > 0 and sheet is Dictionary and sheet.get("ok") == true and int(sheet.get("id", 0)) == cq
			and sheet.get("kind") == "character" and (sheet.get("stats", []) as Array).size() == 4
			and (sheet.get("skills", []) as Array).size() > 0,
			"query_character: the sheet arrives (query %d)" % cq)
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

	req = await _check_item_physics(req)
	if req.is_empty():
		_finish()
		return
	req = await _check_deltas(req)
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
	await _second_game(saves[0], saved_turn, saved_pos)

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
	# A new game after a loaded one, in the same process: the test range.
	why = _sim.start_test_range(_data_dir, _user_dir)
	_check(why.is_empty(), "the test range starts as a second game (%s)" % why)
	req = await _main_loop_request(0, BOOT_TIMEOUT_MS)
	_check(not req.is_empty(), "and reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	_check(_sim.get_range_info().get("range", false), "as a range game")
	snap = Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	_check(snap.is_valid() and snap.player_pos != saved_pos, "with its own snapshot (%s)" % snap.player_pos)
	_sim.stop()
	_check(_sim.get_state() == "stopped", "the range stops")
	_finish()


## Run 1, once its first game stopped: a second game in the same process loads that game's save.
func _second_game(save: String, saved_turn: int, saved_pos: Vector3i) -> void:
	var last_seq: int = _sim.get_snapshot_seq()
	var other := _user_dir + "-other"
	DirAccess.make_dir_recursive_absolute(other)
	var why: String = _sim.start(_data_dir, other, WORLD + "-other")
	_check(why.contains("other folders"), "a second game refuses other folders (%s)" % why)
	why = _sim.start_load(_data_dir, _user_dir, WORLD, save)
	_check(why.is_empty(), "a second game starts in the same process (%s)" % why)
	_check(_sim.get_snapshot_seq() == 0 and String(_sim.get_id_tables_json()).is_empty()
			and int(_sim.get_held().get("turn", -1)) == 0 and not _sim.get_range_info().get("range", true),
			"nothing of the first game shows while it boots")
	_check(not String(_sim.start_load(_data_dir, _user_dir, WORLD, save)).is_empty(), "refuses a start while it boots")
	var req := await _main_loop_request(0, BOOT_TIMEOUT_MS)
	_check(not req.is_empty(), "the second game reaches the main loop (state %s %s)" % [_sim.get_state(),
			_sim.get_error()])
	if req.is_empty():
		return
	var snap := Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	_check(snap.is_valid() and int(req["turn"]) == saved_turn and snap.player_pos == saved_pos,
			"it loads the save: turn %d (saved %d), %s (saved %s)" % [req["turn"], saved_turn, snap.player_pos,
			saved_pos])
	_check(_sim.get_snapshot_seq() > last_seq, "snapshot seqs keep counting (%d after %d)" % [
			_sim.get_snapshot_seq(), last_seq])
	_check(not String(_sim.get_id_tables_json()).is_empty(), "with id tables")
	_sim.stop()
	_check(_sim.get_state() == "stopped", "the second game stops")


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
		elif e["kind"] == "item_result":
			_item_results.append(e)


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


## E2 item physics end to end, through LiveSession (the calls the client's ItemPlacer makes): a carried item is
## dropped on the player's square, placed onto a square next to it with a pose (tried all 8 ways in one turn: a
## random start may have walls around; exactly one place may go through, as an item moves once a turn), its pose
## changed in place (spot), then refusals: a place from 3 squares out (by CDDA: a reason, never a log message) and
## places LiveSession refuses itself (nothing sent). A dropped item CDDA won't move by hand at all (a drink's liquid,
## taken out of its bottle: every way refused for the same reason) stays where it fell, and the next carried item is
## tried. Returns the main-loop request it ends on ({} if the game stopped).
func _check_item_physics(req: Dictionary) -> Dictionary:
	var live := LiveSession.new()
	live._sim = _sim   # only its item calls are used; outside the tree it drains nothing, so _drain() still sees all
	var snap := Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	var me := snap.player_pos
	var ways: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(1, 1, 0), Vector3i(-1, -1, 0), Vector3i(1, -1, 0), Vector3i(-1, 1, 0)]
	var uid := 0
	var type := 0
	var drops := 0
	var sent := 0
	var waited := false
	var done: Array[int] = []
	var refused_ok := false
	var log_before := 0
	var passed_over: Array[String] = []   # items no way took: "itype: reason"
	# 1. Drop the first loose carried item (in a pocket, not worn or held, holding nothing) CDDA lets go of; 2. place
	# it onto a next square with a pose: one of the 8 goes through, the rest are refused (it has moved on).
	for c in _loose_carried(snap).slice(0, 6):
		_item_results.clear()
		if not (_sim.queue_item_action({"op": "drop", "item": c[0], "type": c[1], "pos": me, "tag": 101})
				and _sim.queue_action("pause")):
			break
		req = await _main_loop_request(int(req["turn"]), TURN_TIMEOUT_MS)
		if req.is_empty():
			live.free()
			return req
		var dropped := {}
		if _result(101).get("amount", 0) == 1:
			dropped = _handle(Snapshot.parse_text(_sim.get_snapshot_json(0, 0)), c[0], c[1], me)
		if dropped.is_empty():
			continue
		drops += 1
		uid = dropped["uid"]
		type = dropped["type"]
		_item_results.clear()
		log_before = _messages.size()
		sent = 0
		for i in ways.size():
			sent += int(live.place_item(float(uid), float(type), me, me + ways[i], Vector2(0.3, 0.6), 90, true, 11 + i))
		waited = _sim.queue_action("pause")
		if not waited:
			break
		req = await _main_loop_request(int(req["turn"]), TURN_TIMEOUT_MS)
		if req.is_empty():
			live.free()
			return req
		done.clear()
		refused_ok = true
		var reasons := {}
		for i in ways.size():
			var r := _result(11 + i)
			if r.get("amount", -1) == 1:
				done.append(i)
			elif r.get("amount", -1) != 0 or str(r.get("text", "")).is_empty() or int(r.get("uid", 0)) != uid:
				refused_ok = false
			else:
				reasons[str(r["text"])] = true
		if not done.is_empty() or reasons.size() != 1 or sent != ways.size() or not refused_ok:
			break
		passed_over.append("%d: %s" % [type, reasons.keys()[0]])
	_check(drops > 0, "item physics: a carried item dropped on the player's square (%d dropped)" % drops)
	if drops == 0:
		live.free()
		return req
	_check(sent == ways.size(), "item physics: LiveSession.place_item sends a place each way (%d)" % sent)
	_check(waited, "item physics: a wait queued after the places")
	_check(_item_results.size() == ways.size() and done.size() == 1 and refused_ok,
			("item physics: one item_result per place, exactly one done, the others refused with a reason "
			+ "(%s; passed over %s)") % [_item_results, passed_over])
	if done.size() != 1:
		live.free()
		return req
	var to := me + ways[done[0]]
	snap = Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	var moved := _handle(snap, uid, type, to)
	var left := _handle(snap, uid, type, me)
	_check(not moved.is_empty() and absi(moved["spot"].x - 300) <= 1 and absi(moved["spot"].y - 600) <= 1
			and (left.is_empty() or left["uid"] != uid),
			"item physics: the snapshot has the item on the square it was placed on, at spot (300, 600) (%s)" % moved)
	_check(_pose(uid) == [90, 1], "item physics: its submap's poses give [uid, 90, 1] (%s)" % [_pose(uid)])
	_check(_messages.size() == log_before or _messages.slice(log_before).all(
			func(m: String) -> bool: return not _item_results.any(func(r: Dictionary) -> bool: return r["text"] == m)),
			"item physics: no refusal of a place reaches the message log (%s)" % [_messages.slice(log_before)])
	# 3. Spot: the pose changes where it lies.
	_item_results.clear()
	_check(live.spot_item(float(uid), float(type), to, Vector2(0.5, 0.5), 180, false, 21)
			and _sim.queue_action("pause"), "item physics: LiveSession.spot_item sends a spot")
	req = await _main_loop_request(int(req["turn"]), TURN_TIMEOUT_MS)
	if req.is_empty():
		live.free()
		return req
	snap = Snapshot.parse_text(_sim.get_snapshot_json(0, 0))
	var rested := _handle(snap, uid, type, to)
	_check(_result(21).get("amount", 0) == 1 and _pose(uid) == [180, 0] and not rested.is_empty()
			and absi(rested["spot"].x - 500) <= 1 and absi(rested["spot"].y - 500) <= 1,
			"item physics: a spot is done and the pose and spot follow (%s, %s, %s)" % [_result(21), _pose(uid), rested])
	# 4. A place from 3 squares out: CDDA refuses it with a reason, and logs nothing.
	_item_results.clear()
	log_before = _messages.size()
	var far := me + Vector3i(3, 0, 0)
	_check(live.place_item(float(uid), float(type), far, far + Vector3i(1, 0, 0), Vector2(-1, -1), 0, false, 13)
			and _sim.queue_action("pause"), "item physics: a place 3 squares out is sent")
	req = await _main_loop_request(int(req["turn"]), TURN_TIMEOUT_MS)
	var far_r := _result(13)
	_check(far_r.get("amount", -1) == 0 and not str(far_r.get("text", "")).is_empty()
			and not str(far_r.get("text", "")) in _messages.slice(log_before),
			"item physics: CDDA refuses it with a reason that isn't in the message log (%s)" % far_r)
	# 5. LiveSession refuses what can't be a place before anything is sent.
	var queued: int = _sim.get_queued_actions()
	_check(not live.place_item(float(uid), float(type), to, to, Vector2(-1, -1), 0, false, 14)
			and not live.place_item(float(uid), float(type), to, to + Vector3i(2, 0, 0), Vector2(-1, -1), 0, false, 15)
			and not live.place_item(float(uid), float(type), to, to + Vector3i(1, 0, 1), Vector2(-1, -1), 0, false, 16)
			and _sim.get_queued_actions() == queued,
			"item physics: a place onto its own square, 2 squares on or another level is refused, nothing sent")
	live.free()
	return req


## Loose carried items, [uid, itype] each: in a pocket (parent set), not worn or held, holding nothing.
static func _loose_carried(snap: Snapshot) -> Array:
	var c := snap.carried
	var parents := {}
	for i in range(0, c.size(), Snapshot.CARRIED_STRIDE):
		parents[c[i + 2]] = true
	var out := []
	for i in range(0, c.size(), Snapshot.CARRIED_STRIDE):
		if c[i + 2] != 0 and c[i + 4] == 0 and not parents.has(c[i]):
			out.append([int(c[i]), int(c[i + 1])])
	return out


## The handle `uid` (or, if a stack merged it, one of type `type`) lying on square `p`: {uid, type, spot}; {} none.
static func _handle(snap: Snapshot, uid: int, type: int, p: Vector3i) -> Dictionary:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p)) if snap.is_valid() else null
	if sm == null:
		return {}
	var l := CddaCoords.ms_to_local(p)
	var tile := l.y * CddaCoords.SEEX + l.x
	var hs := sm.handles
	var by_type := {}
	for k in range(0, hs.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if hs[k] != tile:
			continue
		var h := {"uid": int(hs[k + 1]), "type": int(hs[k + 2]), "spot": Vector2i(int(hs[k + 3]), int(hs[k + 4]))}
		if h["uid"] == uid:
			return h
		if h["type"] == type and by_type.is_empty():
			by_type = h
	return by_type


## get_snapshot_delta_json for the three levels around the player, for a client holding snapshot `since`; {} when
## the bridge lacks the call or gives no JSON object.
func _delta_json(since: int) -> Dictionary:
	if not _sim.has_method("get_snapshot_delta_json"):
		return {}
	var d: Variant = JSON.parse_string(_sim.get_snapshot_delta_json(1, 1, since))
	return d if d is Dictionary else {}


## [yaw, side] the snapshot's `poses` give item `uid`, [] when none.
func _pose(uid: int) -> Array:
	var d: Variant = JSON.parse_string(_sim.get_snapshot_json(0, 0))
	if not d is Dictionary or not (d as Dictionary).get("submaps") is Array:
		return []
	for s: Variant in d["submaps"]:
		if not s is Dictionary or not (s as Dictionary).get("poses") is Array:
			continue
		for p: Variant in s["poses"]:
			if p is Array and (p as Array).size() == 3 and int(p[0]) == uid:
				return [int(p[1]), int(p[2])]
	return []


## The item_result event with this tag since _item_results was cleared: {uid, amount, text, ...}; {} none.
func _result(tag: int) -> Dictionary:
	for r: Dictionary in _item_results:
		if int(r.get("detail", -1)) == tag:
			return r
	return {}


## The bridge's delta call read by the client's parser (Snapshot.parse_text with the snapshot held): a full answer
## first, then after each of a few waited turns a delta on the one held, which must come out the same as the plain
## snapshot of that moment (SnapSame.diff). Then a delta the held snapshot doesn't fit must fail and leave the held
## one alone. Skipped, said so, on a bridge without the call or a client without the parser. Returns the main loop's
## request to go on with ({} when the game stopped).
func _check_deltas(req: Dictionary) -> Dictionary:
	if not _sim.has_method("get_snapshot_delta_json") or Snapshot.new().get("base_seq") == null:
		print("  (no delta call in this bridge, or no delta parser in this client: deltas not checked)")
		return req
	var held := Snapshot.parse_text(_sim.get_snapshot_delta_json(1, 1, 0))
	_check(held.is_valid() and held.base_seq == -1 and held.submaps.size() == 11 * 11 * 3
			and held.submap_hash.size() == held.submaps.size(),
			"deltas: nothing held, the parser takes the full answer with its key rows (%s)" % held.error)
	if not held.is_valid():
		return req
	var first := held
	var diffs := PackedStringArray()
	var reused := []
	var sizes := []
	for i in 3:
		if not _sim.queue_action("pause"):
			diffs.append("turn %d: the wait wasn't queued" % i)
			break
		req = await _main_loop_request(int(req["turn"]), TURN_TIMEOUT_MS)
		if req.is_empty():
			_check(false, "deltas: a turn passes (%s)" % _sim.get_state())
			return {}
		var text: String = _sim.get_snapshot_delta_json(1, 1, held.seq)
		var next := Snapshot.parse_text(text, held)
		var plain := Snapshot.parse_text(_sim.get_snapshot_json(1, 1))
		if not next.is_valid() or not plain.is_valid():
			diffs.append("turn %d: %s%s" % [i, next.error, plain.error])
			break
		if next.base_seq != held.seq:
			diffs.append("turn %d: built on %d, %d was held" % [i, next.base_seq, held.seq])
		var d := SnapSame.diff(next, plain)
		if not d.is_empty():
			diffs.append("turn %d: %s" % [i, d])
		reused.append(next.reused_submaps)
		sizes.append(text.length() / 1024)
		held = next
	_check(diffs.is_empty() and reused.size() == 3, "deltas: three turns, each delta read on the one held is the plain snapshot "
			+ "(%s submaps reused, %s KB) %s" % [reused, sizes, diffs])
	# a delta on the newest read against an older snapshot: it must fail, and the older one stays whole
	var before := first.submaps.size()
	var wrong := Snapshot.parse_text(_sim.get_snapshot_delta_json(1, 1, held.seq), first)
	_check((not wrong.is_valid() or first.seq == held.seq) and first.is_valid() and first.submaps.size() == before,
			"deltas: a delta read against another snapshot than its base fails and leaves that one whole (%s)" % wrong.error)
	return req
