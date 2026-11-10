class_name LiveSession
extends Node
## Runs CDDA through the bridge (class CddaSim from bin/fp3d_cdda.gdextension, contracts/bridge_api.md) and
## each frame hands out what changed: a new snapshot, the pending request, events. Scripts never name
## CddaSim as a type, so the client still loads when the DLL isn't built.

signal state_changed(state: String)
## New id tables (contracts/id_tables.md), emitted before the first snapshot of their generation.
signal id_tables_ready(tables: IdTables)
signal snapshot_ready(snap: Snapshot)
## {} when nothing is pending. Timed requests (the main game loop) come through here too.
signal request_changed(request: Dictionary)
signal events_arrived(events: Array)
## A save finished (save(), autosave): ok or not. Skipped autosaves (nothing changed) count as ok.
signal saved(ok: bool)
## What the hands hold (CddaSim.get_held): {seq, turn, main, off, activity}; on every change, also each turn
## while a fill runs.
signal held_changed(held: Dictionary)
## The character's testing cheats changed (CddaSim.get_cheats): {name: bool} for every name in CHEATS.
signal cheats_changed(cheats: Dictionary)

## Testing cheats the bridge knows (contracts/bridge_api.md, set_cheat); any other name is refused here.
const CHEATS: PackedStringArray = ["invincible", "no_needs", "no_weight_limit", "unlimited_ammo", "stamina",
		"no_temperature", "night_vision"]

## Levels sent around the player's z (the whole bubble is 21 levels, ~6 MB of JSON).
const Z_BELOW := 1
const Z_ABOVE := 1
## Real seconds of play between autosaves (skipped while nothing happens).
const AUTOSAVE_S := 300.0

var state := "idle"
var error := ""
var request := {}
var snapshot_seq := 0
var ids_generation := -1
var _sim: RefCounted
var _saves_done := 0
var _since_save := 0.0
var _held_seq := 0
var _cheats_seq := -1
var _cheats := {}
## The running game was started new (not loaded): --test gives its test kit only then.
var new_game := false
## Snapshot fetch and parse run on a WorkerThreadPool task (~0.85 MB of JSON, ~125 ms): -1 when none runs.
var _snap_task := -1
var _snap_job: SnapJob
## () -> bool: the world is still putting the last snapshot on screen (WorldView.busy); no new fetch meanwhile.
var busy := Callable()


static func available() -> bool:
	return ClassDB.class_exists("CddaSim")


## Starts a new game in `world` (an existing world of that name is replaced). Paths must be absolute.
func start(data_dir: String, user_dir: String, world: String) -> bool:
	if not _make_sim():
		return false
	new_game = true
	error = _sim.start(data_dir, user_dir, world)
	return error.is_empty()


## A new game: `fresh_world` makes world `world` (it must not exist: the bridge would replace it), otherwise
## the character joins that existing world; `chargen` asks for the character with a `chargen` request
## (character creation) instead of a random one.
## `world_setup` (fresh worlds) asks for the world's settings and mods first (a `world_setup` request).
func start_new_game(data_dir: String, user_dir: String, world: String, fresh_world: bool, chargen: bool,
		world_setup := false) -> bool:
	if not _make_sim():
		return false
	new_game = true
	error = _sim.start_new_game(data_dir, user_dir, world, fresh_world, chargen, world_setup)
	return error.is_empty()


## Loads the character `save` from the existing `world` under `user_dir` (names from list_saves). Deletes nothing.
func start_load(data_dir: String, user_dir: String, world: String, save: String) -> bool:
	if not _make_sim():
		return false
	new_game = false
	error = _sim.start_load(data_dir, user_dir, world, save)
	return error.is_empty()


## Worlds under `user_dir`/save, sorted; [] without the bridge. Works before a game starts.
static func list_worlds(user_dir: String) -> PackedStringArray:
	if not available():
		return PackedStringArray()
	return ClassDB.instantiate("CddaSim").list_worlds(user_dir)


## Characters saved in `world`, sorted; [] without the bridge or if there are none.
static func list_saves(user_dir: String, world: String) -> PackedStringArray:
	if not available():
		return PackedStringArray()
	return ClassDB.instantiate("CddaSim").list_saves(user_dir, world)


## Saves the game where it stands and plays on; `saved` follows. The sim saves at the main loop's next
## request (also while paused), so a prompt or a long activity holds it up. False without a running game or
## with a bridge that can't (older than this client).
func save(only_if_changed := false) -> bool:
	if _sim == null or state != "running" or not _sim.has_method("save_game"):
		return false
	_since_save = 0.0
	return _sim.save_game(only_if_changed)


## A save asked for and not finished.
func save_pending() -> bool:
	return _sim != null and _sim.has_method("get_save_status") and _sim.get_save_status().get("pending", false)


## Turns a testing cheat on or off (applied at the sim's next request; cheats_changed follows). False for a name
## not in CHEATS, without a running game or with a bridge that can't.
func set_cheat(cheat: String, on: bool) -> bool:
	if not cheat in CHEATS or not _can("set_cheat"):
		return false
	return bool(_sim.set_cheat(cheat, on))


## The cheats as the sim has them now ({name: bool} for each of CHEATS; {} without a game). Asked each time, never
## kept: the save and other callers change them.
func cheats() -> Dictionary:
	if not _can("get_cheats"):
		return {}
	return clean_cheats(_sim.get_cheats())


## Only known names, only bools: the reply is the sim's, but a wrong one must not reach the UI as anything else.
static func clean_cheats(d: Variant) -> Dictionary:
	var out := {}
	if not d is Dictionary or not d.get("cheats") is Dictionary:
		return out
	var c: Dictionary = d["cheats"]
	for n in CHEATS:
		var v: Variant = c.get(n, false)
		out[n] = v if v is bool else false
	return out


## Test kits handed out since the sim started (0 without a game).
func kits_given() -> int:
	if not _can("get_cheats"):
		return 0
	var v: Variant = _sim.get_cheats().get("kits_given", 0)
	return clampi(int(v), 0, 1 << 30) if (v is int or v is float) else 0


## The test loadout (bridge give_test_kit) at the sim's next request. One per call: callers decide how often.
func give_test_kit() -> bool:
	return _can("give_test_kit") and bool(_sim.give_test_kit())


## Real time pauses itself when a new hostile comes into view (on by default).
func set_auto_pause(on: bool) -> bool:
	if not _can("set_auto_pause"):
		return false
	_sim.set_auto_pause(on)
	return true


func auto_pause() -> bool:
	if not _can("get_clock"):
		return false
	var v: Variant = _sim.get_clock().get("auto_pause", false)
	return v if v is bool else false


func _can(method: String) -> bool:
	return _sim != null and state == "running" and _sim.has_method(method)


func _make_sim() -> bool:
	if not available():
		error = "bridge not loaded: build fp3d-cdda (docs/BUILD.md)"
		return false
	_sim = ClassDB.instantiate("CddaSim")
	return true


func stop() -> void:
	if _snap_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_snap_task)
		_snap_task = -1
		_snap_job = null
	if _sim != null:
		_sim.stop()


func answer(a: Dictionary) -> bool:
	return _sim != null and _sim.answer(a)


func queue_action(action: String) -> bool:
	return _sim != null and _sim.queue_action(action)


## One item by its snapshot handle (uid + itype index), no menus; the sim checks it again and says why not in a
## message (contracts/bridge_api.md). JSON numbers arrive as floats: they are made ints here.
## Take from square `pos` into hand "pack", "main" or "off".
func take_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
	return _sim != null and _sim.queue_item_action({"op": "take", "item": int(uid), "type": int(type),
			"pos": pos, "hand": hand})


## Put a carried item into a container: a carried one (worn, held), else the one on square `pos`;
## `pocket` -1 = CDDA's choice, else an index as the snapshot's carried items give it.
func put_item(uid: float, type: float, container: float, container_type: float, pos: Vector3i,
		pocket := -1) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "put", "item": int(uid), "type": int(type),
			"container": int(container), "container_type": int(container_type), "pos": pos, "pocket": pocket})


## Drop a carried item on square `pos`; `spot` (each 0..1 across the square) places it there, (-1, -1) none.
func drop_item(uid: float, type: float, pos: Vector3i, spot := Vector2(-1, -1)) -> bool:
	var a := {"op": "drop", "item": int(uid), "type": int(type), "pos": pos}
	if spot.x >= 0.0 and spot.y >= 0.0:
		a["spot"] = spot
	return _sim != null and _sim.queue_item_action(a)


## Actions waiting in the bridge's queue (0 without a game).
func queued_actions() -> int:
	return _sim.get_queued_actions() if _sim != null else 0


func sim() -> RefCounted:
	return _sim


## Main-thread microseconds the last _process took (for the bench and a HUD).
var process_us := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_poll(delta)
	process_us = Time.get_ticks_usec() - t0


func _poll(delta: float) -> void:
	if _sim == null:
		return
	var s: String = _sim.get_state()
	if s != state:
		state = s
		if s == "ended" or s == "failed":
			error = _sim.get_error()
		state_changed.emit(s)
	if state == "running" and _sim.has_method("get_save_status"):
		var st: Dictionary = _sim.get_save_status()
		var done: int = st.get("done", 0)
		if done != _saves_done:
			_saves_done = done
			saved.emit(bool(st.get("ok", false)))
		_since_save += delta
		if _since_save >= AUTOSAVE_S:
			save(true)
	if _sim.has_method("get_held"):
		var held: Dictionary = _sim.get_held()
		var hs: int = held.get("seq", 0)
		if hs != _held_seq:
			_held_seq = hs
			held_changed.emit(held)
	_poll_cheats()
	var events: Array = _sim.drain_events()
	if not events.is_empty():
		events_arrived.emit(events)
	# The snapshot first: it is taken right before the request, so the world is current when the request shows.
	# Fetching and parsing happen on a worker; a new request waits until the snapshot before it is out.
	if not _poll_snapshot():
		return
	var r: Dictionary = _sim.get_request()
	if r.get("id", 0) != request.get("id", 0):
		request = r
		request_changed.emit(r)


## get_cheats' seq bumps every turn: cheats_changed only goes out when a value changed.
func _poll_cheats() -> void:
	if state != "running" or not _sim.has_method("get_cheats"):
		if not _cheats.is_empty():   # the game ended: no cheats on screen any more
			_cheats = {}
			_cheats_seq = -1
			cheats_changed.emit({})
		return
	var d: Variant = _sim.get_cheats()
	if not d is Dictionary:
		return
	var seq: Variant = d.get("seq", 0)
	if not (seq is int or seq is float) or int(seq) == _cheats_seq:
		return
	_cheats_seq = int(seq)
	var c := clean_cheats(d)
	if c != _cheats:
		_cheats = c
		cheats_changed.emit(c.duplicate())


## Starts or finishes the snapshot worker; true when no snapshot newer than the one shown is waiting.
func _poll_snapshot() -> bool:
	if _snap_task >= 0:
		if not WorkerThreadPool.is_task_completed(_snap_task):
			return false
		WorkerThreadPool.wait_for_task_completion(_snap_task)
		_snap_task = -1
		var snap := _snap_job.snap
		# the fetch may have got a newer snapshot than the seq read before it: count that one as shown, so it
		# isn't fetched and shown a second time
		snapshot_seq = maxi(_snap_job.seq, snap.seq) if snap.is_valid() else _snap_job.seq
		if snap.is_valid() and snap.ids_generation != ids_generation:
			_use_id_tables(snap.ids_generation, _snap_job.tables)
		if snap.is_valid():
			snapshot_ready.emit(snap)
		else:
			push_error("live snapshot rejected: " + snap.error)
		_snap_job = null
	var seq: int = _sim.get_snapshot_seq()
	if seq == snapshot_seq:
		return true
	if busy.is_valid() and busy.call():
		return false   # the world still shows the last one: fetch the newest when it is done, not each in between
	_snap_job = SnapJob.new(_sim, seq, ids_generation)
	_snap_task = WorkerThreadPool.add_task(_snap_job.run, false, "snapshot parse")
	return false


## One fetch and parse on a worker thread. The bridge hands out an immutable snapshot under a mutex, so the
## call is safe off the main thread; the job touches nothing else. `seq` is read before the fetch, so a newer
## snapshot taken meanwhile is fetched again next time (never skipped).
class SnapJob:
	var sim: RefCounted
	var seq: int
	var known_generation: int
	var snap: Snapshot
	var tables: IdTables   # fetched too when the snapshot wants a generation other than known_generation

	func _init(s: RefCounted, q: int, generation: int) -> void:
		sim = s
		seq = q
		known_generation = generation

	func run() -> void:
		snap = Snapshot.parse_text(sim.get_snapshot_json(Z_BELOW, Z_ABOVE))
		if snap.is_valid() and snap.ids_generation != known_generation:
			tables = IdTables.parse_text(sim.get_id_tables_json())


## Asked once per generation (fetched by the worker): a failed or mismatched fetch leaves the world on the
## snapshot's names.
func _use_id_tables(generation: int, t: IdTables) -> void:
	ids_generation = generation
	if t == null:
		t = IdTables.parse_text(_sim.get_id_tables_json())
	if not t.is_valid():
		push_error("live id tables rejected: " + t.error)
	elif t.generation != generation:
		push_warning("live id tables are generation %d, the snapshot wants %d" % [t.generation, generation])
	id_tables_ready.emit(t)


func _exit_tree() -> void:
	stop()
