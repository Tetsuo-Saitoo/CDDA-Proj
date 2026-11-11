extends SceneTree
## Headless check of the K7 test range through the bridge (CddaSim.start_test_range and the range_* ops), one
## Godot run: the range boots in its own world with the AI frozen and the hub built; bad arguments are refused
## before queueing; spawn an item and a monster next to the player, set the time, freeze and thaw the AI, heal,
## wait a minute, and visit the first zone of every kind (each is built on the first visit and the player lands
## inside it). Ops run at the main loop's next request, so each step waits for a new one.
## Then it thaws the AI, saves and starts run 2 (`-- --load`): a loaded range save is a range game again (the
## user's call, PLAN.md K7): same zones and built flags, the AI as saved, nothing moved, and the ops work.
## Needs the DLL (build target fp3d-cdda) and the game data in ../cdda. From the repo root:
##   godot --headless --path client --script res://tests/range_live_test.gd
## Exit code 0 = all passed.

const WORLD := "fp3d-range"
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 120000
## What run 1 saved, for run 2 (in the test's folder).
const EXPECT_FILE := "range_expect.json"
const TestDir := preload("res://tests/test_dir.gd")

var _failed := 0
var _sim: RefCounted
var _req := {}   # the last main-loop request seen
var _run_name := "range live tests"


func _initialize() -> void:
	if "--load" in OS.get_cmdline_user_args():
		_run_name = "range live tests (load run)"
		_check(TestDir.use_parent(OS.get_cmdline_user_args()), "run 1 named its folder (--test-run)")
		_run_load()
	else:
		_run()


func _run() -> void:
	_check(ClassDB.class_exists("CddaSim") and ClassDB.class_has_method("CddaSim", "start_test_range"),
			"extension loaded with the test range (CddaSim.start_test_range)")
	if _failed > 0:
		_finish()
		return
	_sim = ClassDB.instantiate("CddaSim")
	var data_dir := _repo("cdda")
	var user_dir := TestDir.global("cdda-range-test")
	_check(int(_sim.range_heal()) == 0, "an op before any game is refused at once")
	var why: String = _sim.start_test_range(data_dir, user_dir)
	_check(why.is_empty(), "the range starts (%s)" % why)
	_check(not String(_sim.start_test_range(data_dir, user_dir)).is_empty(), "a second start is refused")
	_req = await _next_request(BOOT_TIMEOUT_MS)
	_check(not _req.is_empty(), "reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	if _req.is_empty():
		_finish()
		return

	var info: Dictionary = _sim.get_range_info()
	var zones: Array = info.get("zones", [])
	_check(info.get("range") == true and info.get("ai_frozen") == true and info.get("zone") == 0,
			"a range game, AI frozen, the player in zone 0 (%s, %s, %s)"
			% [info.get("range"), info.get("ai_frozen"), info.get("zone")])
	var ids := {}
	for z: Dictionary in zones:
		ids[String(z.get("id", ""))] = true
	_check(zones.size() >= 10 and zones[0].get("kind") == "hub" and zones[0].get("built") == true
			and ids.size() == zones.size(), "%d zones with unique ids, the hub first and built" % zones.size())
	var snap := _snapshot()
	_check(snap.is_valid(), "range snapshot passes the client's checks (%s)" % snap.error)
	if not snap.is_valid():
		_finish()
		return
	var home := snap.player_pos
	var tables := IdTables.parse_text(_sim.get_id_tables_json())

	# refused before queueing: a bad item index, a monster id over 64 characters; characters that can't be in an
	# id are refused by the game (the bridge only checks the length)
	_check(int(_sim.range_spawn_item(0, 1, home + Vector3i(1, 0, 0))) == 0
			and int(_sim.range_spawn_monster("mon_" + "z".repeat(80), home + Vector3i(0, 2, 0))) == 0,
			"a bad item index and a too-long monster id are refused at once")
	var e := await _op(_sim.range_spawn_monster("../mon_zombie", home + Vector3i(0, 2, 0)))
	_check(e != "" and e != "no answer", "a monster id with a path in it is refused (%s)" % e)

	var rock := tables.index_of("itype", "rock")
	e = await _op(_sim.range_spawn_item(rock, 3, home + Vector3i(1, 0, 0)))
	_check(e == "", "spawn 3 rocks next to the player (%s)" % e)
	e = await _op(_sim.range_spawn_item(rock, 1, home + Vector3i(1 << 20, 0, 0)))
	_check(e != "" and e != "no answer", "spawn far outside the bubble is refused (%s)" % e)
	var mon_before := _monsters(_snapshot())
	e = await _op(_sim.range_spawn_monster("mon_zombie", home + Vector3i(0, 2, 0)))
	_check(e == "", "spawn a zombie two squares away (%s)" % e)
	var mon_after := _monsters(_snapshot())
	_check(mon_after.size() == mon_before.size() + 1 and home + Vector3i(0, 2, 0) in mon_after,
			"the zombie is in the snapshot where it was put (%d -> %d)" % [mon_before.size(), mon_after.size()])
	e = await _op(_sim.range_spawn_monster("mon_zombie", home + Vector3i(0, 2, 0)))
	_check(e != "" and e != "no answer", "a second monster on the same square is refused (%s)" % e)
	e = await _op(_sim.range_spawn_monster("mon_no_such_thing", home + Vector3i(0, 3, 0)))
	_check(e != "" and e != "no answer", "an unknown monster id is refused (%s)" % e)

	var turn0 := int(_req["turn"])
	e = await _op(_sim.range_set_time(20 * 60))
	var turn1 := int(_req["turn"])
	_check(e == "" and turn1 > turn0, "set the time to 20:00 (%s; turn %d -> %d)" % [e, turn0, turn1])
	e = await _op(_sim.range_set_time(20 * 60))
	_check(e == "" and int(_req["turn"]) == turn1, "setting the same minute again leaves the clock (%s)" % e)
	e = await _op(_sim.range_set_time(1440))
	_check(e != "" and e != "no answer", "minute 1440 is refused (%s)" % e)

	e = await _op(_sim.range_set_ai_frozen(false))
	_check(e == "" and (_sim.get_range_info() as Dictionary).get("ai_frozen") == false, "AI thawed (%s)" % e)
	e = await _op(_sim.range_set_ai_frozen(true))
	_check(e == "" and (_sim.get_range_info() as Dictionary).get("ai_frozen") == true, "AI frozen again (%s)" % e)
	e = await _op(_sim.range_heal())
	_check(e == "", "heal (%s)" % e)

	var before_wait := int(_req["turn"])
	var wait_id := int(_sim.range_advance(1))
	_check(wait_id > 0 and _sim.queue_action("pause"), "wait 1 minute queued, with a pause to answer the loop")
	e = await _result(wait_id, OP_TIMEOUT_MS)
	_req = await _next_request(OP_TIMEOUT_MS, int(_req.get("turn", 0)) + 59)
	_check(e == "" and not _req.is_empty() and int(_req["turn"]) >= before_wait + 60,
			"a minute passed (%s; turn %d -> %s)" % [e, before_wait, _req.get("turn", "?")])
	if _req.is_empty():
		_finish()
		return

	# the first zone of every kind: built on the first visit, the player lands inside it on a free square
	var seen := {}
	for i in zones.size():
		var kind := String(zones[i].get("kind", ""))
		if i == 0 or seen.has(kind):
			continue
		seen[kind] = true
		var t0 := Time.get_ticks_msec()
		e = await _op(_sim.range_teleport(i))
		var ms := Time.get_ticks_msec() - t0
		info = _sim.get_range_info()
		snap = _snapshot()
		var here: Dictionary = (info.get("zones", []) as Array)[i] if i < (info.get("zones", []) as Array).size() else {}
		_check(e == "" and info.get("zone") == i and here.get("built") == true and snap.is_valid()
				and snap.player_pos.distance_to(home) > 100.0 and not (snap.player_pos in _monsters(snap)),
				"teleport to %s (%s): built, the player in it on a free square (%s, %d ms)"
				% [kind, zones[i].get("id"), e, ms])
	e = await _op(_sim.range_teleport(0))
	_check(e == "" and (_sim.get_range_info() as Dictionary).get("zone") == 0, "back to the hub (%s)" % e)
	e = await _op(_sim.range_teleport(zones.size()))
	_check(e != "" and e != "no answer", "a zone past the end is refused (%s)" % e)
	_check(_sim.get_events_dropped() == 0, "no events dropped")

	# Thaw the AI (not the default, so run 2 shows it comes from the save) and save without a turn passing, so
	# nothing moves before the save; run 2 loads it.
	e = await _op(_sim.range_set_ai_frozen(false))
	_check(e == "", "AI thawed before saving (%s)" % e)
	info = _sim.get_range_info()
	snap = _snapshot()
	var saved_turn := int(_req.get("turn", -1))
	_sim.set_paused(true)
	_check(_sim.save_game(), "asks for a save (paused)")
	var st := await _saves_done(1, OP_TIMEOUT_MS)
	_check(st.get("ok", false), "the range game saves (%s)" % st)
	var saves: PackedStringArray = _sim.list_saves(user_dir, WORLD)
	_check(saves.size() == 1 and WORLD in _sim.list_worlds(user_dir), "one save in world %s (%s)" % [WORLD, saves])
	_sim.stop()
	if _failed > 0 or saves.size() != 1 or not snap.is_valid():
		_finish()
		return
	var expect := {"save": saves[0], "turn": saved_turn, "zone": info.get("zone"),
			"zones": _zone_keys(info), "player": str(snap.player_pos), "monsters": _places(snap)}
	var f := FileAccess.open(TestDir.path(EXPECT_FILE), FileAccess.WRITE)
	f.store_string(JSON.stringify(expect))
	f.close()
	print("  second run: load %s at turn %d" % [saves[0], saved_turn])
	var out := []
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://tests/range_live_test.gd", "--", "--load", TestDir.child_arg()])
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	for chunk: String in out:
		print(chunk.strip_edges(false, true).indent("  | "))
	_check(code == 0, "second run loads the range save and passes (exit %d)" % code)
	_finish()


## Run 2: loads what run 1 saved. It must be a range game again with the cheat opt-in on (the bridge turns it on
## for a loaded range save), the same zones and built flags, the AI thawed as saved, the player and monsters
## where they were (nothing rebuilt), and the ops must work. Deletes nothing.
func _run_load() -> void:
	_check(ClassDB.class_exists("CddaSim") and ClassDB.class_has_method("CddaSim", "get_range_info"),
			"extension loaded with the test range")
	var expect: Variant = JSON.parse_string(FileAccess.get_file_as_string(TestDir.path(EXPECT_FILE)))
	_check(expect is Dictionary and expect.get("save") is String and expect.get("zones") is Array
			and expect.get("player") is String and expect.get("monsters") is Array,
			"reads what run 1 saved (%s)" % EXPECT_FILE)
	if _failed > 0:
		_finish()
		return
	var user_dir := TestDir.global("cdda-range-test")
	_sim = ClassDB.instantiate("CddaSim")
	_check(Array(_sim.list_saves(user_dir, WORLD)) == [expect["save"]], "the save is listed")
	var why: String = _sim.start_load(_repo("cdda"), user_dir, WORLD, expect["save"])
	_check(why.is_empty(), "starts loading (%s)" % why)
	_req = await _next_request(BOOT_TIMEOUT_MS)
	_check(not _req.is_empty(), "reaches the main loop (state %s %s)" % [_sim.get_state(), _sim.get_error()])
	if _req.is_empty():
		_finish()
		return
	_check(int(_req["turn"]) == int(expect["turn"]), "turn matches the save (%s, saved %s)"
			% [_req["turn"], expect["turn"]])
	var info: Dictionary = _sim.get_range_info()
	_check(info.get("range") == true, "a range game again (range %s)" % info.get("range"))
	_check(info.get("ai_frozen") == false, "the AI thawed as saved (ai_frozen %s)" % info.get("ai_frozen"))
	_check(_zone_keys(info) == expect["zones"], "the same zones with the same built flags")
	_check(int(info.get("zone", -1)) == int(expect.get("zone", -2)), "in the same zone (%s)" % info.get("zone"))
	var snap := _snapshot()
	_check(snap.is_valid(), "loaded snapshot passes the client's checks (%s)" % snap.error)
	var mons := _places(snap)
	_check(str(snap.player_pos) == expect["player"] and mons == expect["monsters"],
			"the player and %d monster(s) where they were saved: nothing rebuilt (%s %s)"
			% [mons.size(), snap.player_pos, mons])

	# The ops work: the bridge turned the cheat opt-in on for the loaded range
	var e := await _op(_sim.range_heal())
	_check(e == "", "heal (%s)" % e)
	e = await _op(_sim.range_set_ai_frozen(true))
	_check(e == "" and (_sim.get_range_info() as Dictionary).get("ai_frozen") == true, "AI frozen again (%s)" % e)
	var zones: Array = info.get("zones", [])
	var target := -1
	for i in range(1, zones.size()):
		if zones[i].get("built") == true:
			target = i
			break
	e = "no built zone"
	if target > 0:
		e = await _op(_sim.range_teleport(target))
	var after: Dictionary = _sim.get_range_info()
	_check(e == "" and after.get("zone") == target, "teleport to built zone %d (%s)" % [target, e])
	_check(_zone_keys(after) == expect["zones"], "a built zone isn't built again, the others stay unbuilt")
	_check(_sim.get_events_dropped() == 0, "no events dropped")
	_sim.stop()
	_finish()


func _saves_done(n: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_sim.drain_events()
		_answer_prompts()
		var st: Dictionary = _sim.get_save_status()
		if int(st["done"]) >= n:
			return st
		if _sim.get_state() != "running":
			return {}
	return {}


## Zone id + built flag per zone, to compare across the save.
static func _zone_keys(info: Dictionary) -> Array:
	var out := []
	for z: Dictionary in info.get("zones", []):
		out.append("%s:%s" % [z.get("id", ""), z.get("built") == true])
	return out


## The monsters' squares as sorted strings (JSON keeps them as they are).
static func _places(snap: Snapshot) -> Array:
	var out := []
	for p in _monsters(snap):
		out.append(str(p))
	out.sort()
	return out


## Waits for operation `id`'s result, then for the main loop's next request after it; the error ("" = done),
## "refused" when the bridge refused it at once (id 0), "no answer" on timeout.
func _op(id: Variant) -> String:
	if int(id) <= 0:
		return "refused"
	var e := await _result(int(id), OP_TIMEOUT_MS)
	var next := await _next_request(OP_TIMEOUT_MS)
	if not next.is_empty():
		_req = next
	return e


func _result(id: int, timeout_ms: int) -> String:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_sim.drain_events()
		for r: Dictionary in (_sim.get_range_info() as Dictionary).get("results", []):
			if int(r.get("id", 0)) == id:
				return String(r.get("error", ""))
		_answer_prompts()
		if _sim.get_state() != "running":
			return "no answer"
	return "no answer"


## The main loop's next timed request (another one than the last seen, at a turn >= min_turn); {} on timeout or
## if the game stops. Prompts on the way are cancelled.
func _next_request(timeout_ms: int, min_turn := 0) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var last := int(_req.get("id", -1))
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		_sim.drain_events()
		var state: String = _sim.get_state()
		if state != "booting" and state != "running":
			return {}
		var req: Dictionary = _sim.get_request()
		if req.is_empty():
			continue
		if req["timed"]:
			if int(req["id"]) != last and int(req["turn"]) >= min_turn:
				return req
			continue
		_answer(req)
	return {}


func _answer_prompts() -> void:
	var req: Dictionary = _sim.get_request()
	if not req.is_empty() and not req["timed"]:
		_answer(req)


func _answer(req: Dictionary) -> void:
	var a := {"id": req["id"], "cancel": true}
	var acts: Array = req.get("actions", [])
	if req["context"] == "CANCEL_ACTIVITY_OR_IGNORE_QUERY":
		# "Stop waiting?" for the (frozen) zombie in view: keep waiting
		a = {"id": req["id"], "action": "IGNORE" if "IGNORE" in acts else ("NO" if "NO" in acts else " ")}
	elif req["context"] == "RAW_KEY":
		a = {"id": req["id"], "action": " "}
	elif req["kind"] == "popup" and not req["actions"].is_empty():
		a = {"id": req["id"], "action": "YES" if "YES" in req["actions"] else req["actions"][0]}
	print("  answering %s %s (%s): %s" % [req["kind"], req["context"], req["title"], a])
	_sim.answer(a)


func _snapshot() -> Snapshot:
	return Snapshot.parse_text(_sim.get_snapshot_json(1, 1))


static func _monsters(snap: Snapshot) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for c in snap.creatures:
		if c.kind == Snapshot.Creature.MONSTER:
			out.append(c.pos)
	return out


func _finish() -> void:
	# Run 1 owns the folder (run 2 has finished by now); a failed run keeps it to look at.
	if not "--load" in OS.get_cmdline_user_args():
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
