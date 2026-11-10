extends SceneTree
## Performance budget (PLAN.md K3): the snapshot path's main-thread cost (fetch in live, parse, WorldView apply),
## CPU frame time, and in a live game the turn time. Prints milliseconds, checks each against BUDGET_MS and exits
## with 1 when one is over. From the repo root:
##   godot --headless --path client --script res://tests/snapshot_bench.gd            (mock town, ~15 s)
##   godot --headless --path client --script res://tests/snapshot_bench.gd -- --live  (a new live game, ~1-2 min)
## Options: --budget-scale=<f> multiplies every budget (CI's shared runners use 3), --no-budget only prints.
## The budgets fit this project's dev PC (16 threads) with headroom. Headless has no GPU, so frame times are CPU
## only: the 90 fps VR target leaves 11.1 ms per frame for the CPU and the GPU together.

const WORLD := "fp3d-bench"
const FRAME_MS := 1000.0 / 90.0
## Milliseconds. "step" = the longest main-thread time the snapshot path took in one frame.
const BUDGET_MS := {
	"mock parse": 400.0,          # 0.9 MB of JSON; a worker does it in live play
	"mock first apply": 2500.0,   # the whole town on the main thread (mock mode and tests only)
	"mock turn apply": 60.0,      # one changed submap and its neighbours, main thread
	"mock async total": 2500.0,   # the whole town meshed on a worker until shown
	"mock async step": 8.0,       # WorldView aims at 4 ms; must leave room in a 90 fps frame
	"mock frame avg": 6.0,        # main.tscn, first person, idle; CPU only
	"mock frame p99": FRAME_MS,
	"live step": 8.0,             # after the first world is in
	"live turn median": 400.0,    # from queuing a wait to the next turn's request (CDDA's turn + snapshot capture)
	"live turn max": 1500.0,
}

var _scale := 1.0
var _check_budget := true
var _results := {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--budget-scale="):
			_scale = maxf(0.1, a.get_slice("=", 1).to_float())
		elif a == "--no-budget":
			_check_budget = false
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
	_record("mock parse", parse_ms)
	_record("mock first apply", full_ms)
	_record("mock turn apply", turn_ms)
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
	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("mock (submit): applied after %.1f ms over %d frames, longest main-thread step %.1f ms" % [total_ms, frames, worst])
	_record("mock async total", total_ms)
	_record("mock async step", worst)
	view.free()
	v2.free()
	await _mock_frames()
	_finish()


## CPU frame time of the real scene (mock town, first person, nothing moving): what's left of a VR frame for
## everything else. Wall time between frames; headless draws nothing.
func _mock_frames() -> void:
	# Headless Godot sleeps ~6.9 ms a frame (low processor mode): measure the work, not the sleep.
	OS.low_processor_usage_mode = false
	Engine.max_fps = 0
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 30:   # warm-up: first frames compile shaders and fill caches
		await process_frame
	var times := PackedFloat64Array()
	var last := Time.get_ticks_usec()
	for i in 300:
		await process_frame
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
	times.sort()
	var avg := 0.0
	for t in times:
		avg += t
	avg /= times.size()
	var p99 := times[int(times.size() * 0.99) - 1]
	print("mock frames (main.tscn, CPU): avg %.2f ms, p99 %.2f ms, worst %.2f ms over %d frames"
			% [avg, p99, times[-1], times.size()])
	_record("mock frame avg", avg)
	_record("mock frame p99", p99)
	main.queue_free()
	await process_frame


## The live game the way main.gd runs it: LiveSession (worker parse) -> WorldView.submit (worker meshing).
## Reports the longest main-thread time the snapshot path took in a frame once the first world is in, over a
## few turns, and each turn's time from queuing a wait to the next turn's request.
func _live() -> void:
	var live := LiveSession.new()
	var view := WorldView.new()
	root.add_child(view)
	root.add_child(live)
	live.id_tables_ready.connect(view.set_id_tables)
	live.snapshot_ready.connect(view.submit)
	var shown := []
	view.applied.connect(func(s: Snapshot, n: int) -> void: shown.append([s.turn, n, Time.get_ticks_msec()]))
	if not live.start(_repo("cdda"), preload("res://tests/test_dir.gd").global("cdda-bench"), WORLD):
		print("start failed: " + live.error)
		quit(1)
		return
	var t_start := Time.get_ticks_msec()
	var t_world := -1
	var deadline := t_start + 300000
	var worst_first := 0.0
	var worst := 0.0
	var turns := 0
	var last_req := 0
	var seen_req := 0
	var queued_at := -1
	var turn_ms := PackedFloat64Array()
	while Time.get_ticks_msec() < deadline and turns < 12 and live.state != "failed" and live.state != "ended":
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
		if t_world < 0 and not shown.is_empty():
			t_world = Time.get_ticks_msec()
		var r := live.request
		if r.is_empty():
			continue
		if r["id"] != seen_req:
			# A new request: the turn's time ends when it shows up, not when the view is ready for it.
			seen_req = r["id"]
			if r["timed"] and queued_at >= 0:
				turn_ms.append(Time.get_ticks_msec() - queued_at)
				queued_at = -1
		if r["id"] == last_req or view.busy():
			continue
		last_req = r["id"]
		if r["timed"]:
			turns += 1
			live.queue_action("pause")
			# The first turns after boot load and settle the world: only steady turns count.
			queued_at = Time.get_ticks_msec() if turns > 2 else -1
		elif r["context"] == "RAW_KEY":
			live.answer({"id": r["id"], "action": " "})
		elif r["kind"] == "popup" and not r["actions"].is_empty():
			live.answer({"id": r["id"], "action": "YES" if "YES" in r["actions"] else r["actions"][0]})
		else:
			live.answer({"id": r["id"], "cancel": true})
	print("live (async): %d snapshots shown over %d turns, first world after %.1f s; longest main-thread step up to the first world %.1f ms, after it %.1f ms"
			% [shown.size(), turns, (t_world - t_start) / 1000.0 if t_world >= 0 else -1.0, worst_first, worst])
	if turn_ms.is_empty():
		print("live: no turn timed (state %s)" % live.state)
		_record("live turn median", INF)
	else:
		var sorted := turn_ms.duplicate()
		sorted.sort()
		print("live turns: median %.0f ms, max %.0f ms over %d turns %s" % [sorted[sorted.size() / 2], sorted[-1], sorted.size(), turn_ms])
		_record("live turn median", sorted[sorted.size() / 2])
		_record("live turn max", sorted[-1])
	_record("live step", worst)
	live.stop()
	_finish()


func _record(what: String, ms: float) -> void:
	_results[what] = ms


## Prints every measure against its budget; exit code 1 when one is over (unless --no-budget).
func _finish() -> void:
	preload("res://tests/test_dir.gd").clean()   # the live game's own folder (tests/test_dir.gd)
	var over := 0
	for what: String in _results:
		var limit: float = BUDGET_MS[what] * _scale
		var ok: bool = _results[what] <= limit
		over += 0 if ok else 1
		print("  %s  %-18s %8.2f ms  (budget %.1f)" % ["ok  " if ok else "OVER", what, _results[what], limit])
	if not _check_budget:
		print("budget: not checked (--no-budget)")
		quit(0)
	elif over > 0:
		printerr("budget: %d OVER (scale %.1f)" % [over, _scale])
		quit(1)
	else:
		print("budget: all within (scale %.1f)" % _scale)
		quit(0)


func _player_sm(s: Snapshot) -> Vector3i:
	for pos: Vector3i in s.submaps:
		if pos.z == s.player_pos.z:
			return pos
	return s.submaps.keys()[0]


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()
