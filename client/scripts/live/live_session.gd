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

## Levels sent around the player's z (the whole bubble is 21 levels, ~6 MB of JSON).
const Z_BELOW := 1
const Z_ABOVE := 1

var state := "idle"
var error := ""
var request := {}
var snapshot_seq := 0
var ids_generation := -1
var _sim: RefCounted


static func available() -> bool:
	return ClassDB.class_exists("CddaSim")


## Starts a new game in `world` (an existing world of that name is replaced). Paths must be absolute.
func start(data_dir: String, user_dir: String, world: String) -> bool:
	if not _make_sim():
		return false
	error = _sim.start(data_dir, user_dir, world)
	return error.is_empty()


## Loads the character `save` from the existing `world` under `user_dir` (names from list_saves). Deletes nothing.
func start_load(data_dir: String, user_dir: String, world: String, save: String) -> bool:
	if not _make_sim():
		return false
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


## CDDA's "save and quit" (it asks to confirm with a popup request). The game then ends with state "ended".
func save() -> bool:
	return queue_action("save")


func _make_sim() -> bool:
	if not available():
		error = "bridge not loaded: build fp3d-cdda (docs/BUILD.md)"
		return false
	_sim = ClassDB.instantiate("CddaSim")
	return true


func stop() -> void:
	if _sim != null:
		_sim.stop()


func answer(a: Dictionary) -> bool:
	return _sim != null and _sim.answer(a)


func queue_action(action: String) -> bool:
	return _sim != null and _sim.queue_action(action)


## Actions waiting in the bridge's queue (0 without a game).
func queued_actions() -> int:
	return _sim.get_queued_actions() if _sim != null else 0


func sim() -> RefCounted:
	return _sim


func _process(_delta: float) -> void:
	if _sim == null:
		return
	var s: String = _sim.get_state()
	if s != state:
		state = s
		if s == "ended" or s == "failed":
			error = _sim.get_error()
		state_changed.emit(s)
	var events: Array = _sim.drain_events()
	if not events.is_empty():
		events_arrived.emit(events)
	# The snapshot first: it is taken right before the request, so the world is current when the request shows.
	var seq: int = _sim.get_snapshot_seq()
	if seq != snapshot_seq:
		var snap := Snapshot.parse_text(_sim.get_snapshot_json(Z_BELOW, Z_ABOVE))
		snapshot_seq = seq
		if snap.is_valid() and snap.ids_generation != ids_generation:
			_fetch_id_tables(snap.ids_generation)
		if snap.is_valid():
			snapshot_ready.emit(snap)
		else:
			push_error("live snapshot rejected: " + snap.error)
	var r: Dictionary = _sim.get_request()
	if r.get("id", 0) != request.get("id", 0):
		request = r
		request_changed.emit(r)


## Asked once per generation: a failed or mismatched fetch leaves the world on the snapshot's names.
func _fetch_id_tables(generation: int) -> void:
	ids_generation = generation
	var t := IdTables.parse_text(_sim.get_id_tables_json())
	if not t.is_valid():
		push_error("live id tables rejected: " + t.error)
	elif t.generation != generation:
		push_warning("live id tables are generation %d, the snapshot wants %d" % [t.generation, generation])
	id_tables_ready.emit(t)


func _exit_tree() -> void:
	stop()
