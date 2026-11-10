extends SceneTree
## Main-thread cost of a snapshot: fetch (live only), parse, and the WorldView apply (first full build, then a
## typical turn). Prints milliseconds; no pass/fail. From the repo root:
##   godot --headless --path client --script res://tests/snapshot_bench.gd            (mock town)
##   godot --headless --path client --script res://tests/snapshot_bench.gd -- --live  (a new live game, ~1 min)

const WORLD := "fp3d-bench"


func _initialize() -> void:
	if "--live" in OS.get_cmdline_user_args():
		_live()
	else:
		_mock()


func _mock() -> void:
	var text := FileAccess.get_file_as_string(_repo("contracts/mock/snapshot_town.json"))
	var t0 := Time.get_ticks_usec()
	var snap := Snapshot.parse_text(text)
	var parse_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var view := WorldView.new()
	root.add_child(view)
	view.set_id_tables(IdTables.load_file(_repo("contracts/mock/id_tables.json")))
	t0 = Time.get_ticks_usec()
	view.apply_snapshot(snap)
	var full_ms := (Time.get_ticks_usec() - t0) / 1000.0
	# A turn: the player's submap changed (terrain and items).
	var again := Snapshot.parse_text(text)
	var sm: Snapshot.Submap = again.submaps[_player_sm(again)]
	sm.revision += 1
	sm.detail_revision += 1
	t0 = Time.get_ticks_usec()
	var n := view.apply_snapshot(again)
	var turn_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("mock (main thread): %d KB, parse %.1f ms, first apply %.1f ms, turn apply %.1f ms (%d submaps rebuilt)"
			% [text.length() / 1024, parse_ms, full_ms, turn_ms, n])
	# The async path: a fresh view meshes the whole town on a worker; the longest frame meanwhile.
	var v2 := WorldView.new()
	root.add_child(v2)
	v2.set_id_tables(view.tables)
	var done := [false]
	v2.applied.connect(func(_s: Snapshot, _n: int) -> void: done[0] = true)
	t0 = Time.get_ticks_usec()
	v2.submit(snap)
	var worst := 0.0
	var frames := 0
	while not done[0]:
		await process_frame
		frames += 1
		worst = maxf(worst, v2.process_us / 1000.0)
	print("mock (submit): applied after %.1f ms over %d frames, longest main-thread step %.1f ms"
			% [(Time.get_ticks_usec() - t0) / 1000.0, frames, worst])
	quit(0)


## The live game the way main.gd runs it: LiveSession (worker parse) -> WorldView.submit (worker meshing).
## Reports the longest main-thread time the snapshot path took in a frame once the first world is in, over a few turns.
func _live() -> void:
	var live := LiveSession.new()
	var view := WorldView.new()
	root.add_child(view)
	root.add_child(live)
	live.id_tables_ready.connect(view.set_id_tables)
	live.snapshot_ready.connect(view.submit)
	var shown := []
	view.applied.connect(func(s: Snapshot, n: int) -> void: shown.append([s.turn, n, Time.get_ticks_msec()]))
	if not live.start(_repo("cdda"), OS.get_user_data_dir().path_join("cdda-bench"), WORLD):
		print("start failed: " + live.error)
		quit(1)
		return
	var deadline := Time.get_ticks_msec() + 300000
	var worst_first := 0.0
	var worst := 0.0
	var turns := 0
	var last_req := 0
	while Time.get_ticks_msec() < deadline and turns < 6 and live.state != "failed" and live.state != "ended":
		await process_frame
		# Main-thread time of the snapshot path this frame: LiveSession and WorldView's _process plus the
		# applied signal's handlers (none here). Wall time is noisy headless: the game and workers share the CPU.
		var ms := (live.process_us + view.process_us) / 1000.0
		if ms > 5.0:
			print("  long frame %.1f ms (%d shown, state %s)" % [ms, shown.size(), live.state])
		if shown.size() <= 1:
			worst_first = maxf(worst_first, ms)
		else:
			worst = maxf(worst, ms)
		var r := live.request
		if r.is_empty() or r["id"] == last_req or view.busy():
			continue
		last_req = r["id"]
		if r["timed"]:
			turns += 1
			live.queue_action("pause")
		elif r["context"] == "RAW_KEY":
			live.answer({"id": r["id"], "action": " "})
		elif r["kind"] == "popup" and not r["actions"].is_empty():
			live.answer({"id": r["id"], "action": "YES" if "YES" in r["actions"] else r["actions"][0]})
		else:
			live.answer({"id": r["id"], "cancel": true})
	print("live (async): %d snapshots shown over %d turns; longest main-thread step up to the first world %.1f ms, after it %.1f ms"
			% [shown.size(), turns, worst_first, worst])
	live.stop()
	quit(0)


func _main_loop(sim: RefCounted, after: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 240000
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
		sim.drain_events()
		if sim.get_state() != "booting" and sim.get_state() != "running":
			return {}
		var r: Dictionary = sim.get_request()
		if r.is_empty():
			continue
		if r["timed"]:
			if int(r["turn"]) > after or after == 0:
				return r
			continue
		var a := {"id": r["id"], "cancel": true}
		if r["context"] == "RAW_KEY":
			a = {"id": r["id"], "action": " "}
		elif r["kind"] == "popup" and not r["actions"].is_empty():
			a = {"id": r["id"], "action": "YES" if "YES" in r["actions"] else r["actions"][0]}
		sim.answer(a)
	return {}


func _player_sm(s: Snapshot) -> Vector3i:
	for pos: Vector3i in s.submaps:
		if pos.z == s.player_pos.z:
			return pos
	return s.submaps.keys()[0]


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()
