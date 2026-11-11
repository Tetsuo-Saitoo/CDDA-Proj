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
## A recipe query (match_recipes) came back: RecipeMatches.parse's result for that container (`ok` false when the
## sim refused it: out of reach, not found, ...).
signal recipes_matched(container_uid: int, result: Dictionary)
## K7 test range (CddaSim.get_range_info, RangeInfo.clean without `results`) changed: zones, the zone the
## character is in, AI frozen. {} when the game stops running.
signal range_changed(info: Dictionary)
## A range_* operation sent from here was done (error "") or refused (the game's reason; NO_ANSWER when its
## result didn't come within QUERY_TIMEOUT_MS: a prompt may hold the game up, and the op may still run).
signal range_done(op_id: int, error: String)

## Testing cheats the bridge knows (contracts/bridge_api.md, set_cheat); any other name is refused here.
const CHEATS: PackedStringArray = ["invincible", "no_needs", "no_weight_limit", "unlimited_ammo", "stamina",
		"no_temperature", "night_vision"]

## Levels sent around the player's z (the whole bubble is 21 levels, ~6 MB of JSON).
const Z_BELOW := 1
const Z_ABOVE := 1
## Real seconds of play between autosaves (skipped while nothing happens).
const AUTOSAVE_S := 300.0
const MAX_BOOT_TEXT := 160            # characters of a boot phase or CDDA error shown
const MAX_BOOT_SECONDS := 1.0e7
const MAX_BOOT_ERRORS := 1 << 30
const MAX_ERROR_TEXT := 600           # characters of get_error() kept

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
## Recipe queries: query id -> [container uid, msec asked]; results kept per container uid (the last one).
var _queries := {}
var _recipe_results := {}
const MAX_QUERIES := 8          # the bridge refuses more pending ones
const MAX_KEPT_RESULTS := 32
const QUERY_TIMEOUT_MS := 30000   # forgotten if no answer comes (a long prompt holds the sim up)
## Test range: the last info (no results), its seq, ops sent and waiting for a result (id -> msec sent).
var _range := {}
var _range_seq := -1
var _range_ops := {}
var _range_poll_s := 0.0
## Waiting range ops at most: the bridge keeps 32 waiting but only the last 16 results, so more could lose theirs.
const MAX_RANGE_OPS := RangeInfo.MAX_RESULTS
const NO_ANSWER := "no answer yet (it may still run later)"
const RANGE_POLL_S := 1.0           # outside a range game, how often to look again
## The running game was started new (not loaded): --test gives its test kit only then.
var new_game := false
## Cheats and test kits work only while allowed (bridge set_cheats_allowed, off by default): the player's own
## debug switch, --test / --cheats, or a test-range game. Kept here and sent again when the game starts running.
var cheats_allowed := false
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


## The test range (PLAN.md K7, lead-qa): the bridge makes its world fp3d-range fresh and starts a new game there.
## The bridge call is lead-qa's proposal: until a bridge has it, this is false and the menu hides the entry.
static func test_range_available() -> bool:
	return available() and ClassDB.class_has_method("CddaSim", "start_test_range")


func start_test_range(data_dir: String, user_dir: String) -> bool:
	if not test_range_available():
		error = "this build of the bridge has no test range"
		return false
	if not _make_sim():
		return false
	new_game = true
	error = _sim.start_test_range(data_dir, user_dir)
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


## Deleting characters from the main menu (CddaSim.delete_save, lead-bridge); false until a bridge has it.
static func delete_save_available() -> bool:
	return available() and ClassDB.class_has_method("CddaSim", "delete_save")


## Deletes the character `save` from `world` under `user_dir`, and the world with it once no character is left
## when `delete_empty_world`. "" when done, else why (plain text). Only names list_worlds / list_saves give now,
## never while a game started in this window boots or runs; the bridge checks the names again and deletes only
## inside user_dir's save folder.
func delete_save(user_dir: String, world: String, save: String, delete_empty_world: bool) -> String:
	if not delete_save_available():
		return "this build of the bridge can't delete characters"
	if _sim != null and not state in ["failed", "ended"]:
		return "a game is running in this window"
	if not user_dir.is_absolute_path() or not world in list_worlds(user_dir) or not save in list_saves(user_dir, world):
		return "no such character"
	var r: Variant = ClassDB.instantiate("CddaSim").delete_save(user_dir, world, save, delete_empty_world)
	return delete_reply(r)


## The bridge's answer to delete_save as one plain line: "" only for an empty String (done), anything else a reason.
static func delete_reply(r: Variant) -> String:
	if not r is String:
		return "the bridge gave no answer"
	if (r as String).is_empty():
		return ""
	var s := Snapshot.plain_text(r, MAX_BOOT_TEXT)
	return s if not s.is_empty() else "the bridge refused"


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


func set_cheats_allowed(on: bool) -> void:
	cheats_allowed = on
	_push_cheats_allowed()


## Older bridges have no opt-in (their cheats always work).
func _push_cheats_allowed() -> void:
	if _sim != null and _sim.has_method("set_cheats_allowed"):
		_sim.set_cheats_allowed(cheats_allowed)


## Turns a testing cheat on or off (applied at the sim's next request; cheats_changed follows). False for a name
## not in CHEATS, without a running game, while cheats aren't allowed (the sim says) or with a bridge that can't.
## The first cheat or kit turns the game's achievements off for good (CDDA's "Achievements have been disabled.").
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


## The boot's progress (CddaSim.get_boot_info, any state), cleaned: {phase, seconds, phase_seconds, errors,
## last_error}; {} without a game or with an older bridge.
func boot_info() -> Dictionary:
	if _sim == null or not _sim.has_method("get_boot_info"):
		return {}
	return clean_boot_info(_sim.get_boot_info())


## get_boot_info's reply as plain one-line texts (capped) and clamped numbers; junk gives {}.
static func clean_boot_info(d: Variant) -> Dictionary:
	if not d is Dictionary:
		return {}
	var src: Dictionary = d
	var e: Variant = src.get("errors", 0)
	var errors := int(clampf(e, 0, MAX_BOOT_ERRORS)) if (e is int or e is float) and is_finite(float(e)) else 0
	return {"phase": Snapshot.plain_text(src.get("phase"), MAX_BOOT_TEXT), "seconds": _seconds(src.get("seconds")),
			"phase_seconds": _seconds(src.get("phase_seconds")), "errors": errors,
			"last_error": Snapshot.plain_text(src.get("last_error"), MAX_BOOT_TEXT)}


static func _seconds(v: Variant) -> float:
	if not (v is int or v is float) or not is_finite(float(v)):
		return 0.0
	return clampf(float(v), 0.0, MAX_BOOT_SECONDS)


## The status line while booting: "booting: Loading files (12 s; 3 CDDA errors)"; an older bridge gives no phase.
static func boot_text(info: Dictionary) -> String:
	var phase: String = info.get("phase", "")
	if phase.is_empty():
		return "game booting (~30 s)"
	var out := "booting: %s (%d s" % [phase, int(info.get("seconds", 0.0))]
	var n: int = info.get("errors", 0)
	if n > 0:
		out += "; %d CDDA error%s" % [n, "" if n == 1 else "s"]
	return out + ")"


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


## K7 test range: the last get_range_info (RangeInfo.clean, no results); {} outside a running game or without a
## bridge that has it.
func range_info() -> Dictionary:
	return _range.duplicate(true)


## A test-range game is running (its operations work).
func in_range() -> bool:
	return _range.get("range", false)


## Moves the character to zone index `zone` (range_info().zones), building it the first time. Each range_*
## call returns the operation id (range_done follows), 0 when refused here or by the bridge at once.
func range_teleport(zone: int) -> int:
	if zone < 0 or zone >= RangeInfo.MAX_ZONES:
		return 0
	return _range_op("range_teleport", [zone])


## Clears zone index `zone` and builds it again (same layout); the game refuses it while you are in it, ride or
## sit in a vehicle.
func range_rebuild_zone(zone: int) -> int:
	if zone < 0 or zone >= RangeInfo.MAX_ZONES:
		return 0
	return _range_op("range_rebuild_zone", [zone])


## Jumps forward to the next `minute` of the day (0..1439).
func range_set_time(minute: int) -> int:
	if minute < 0 or minute >= RangeInfo.MINUTES_PER_DAY:
		return 0
	return _range_op("range_set_time", [minute])


## Waits `minutes` (1..10080) as real turns; the main loop's next request is answered with "pause" so the wait
## isn't replaced by another action.
func range_advance(minutes: int) -> int:
	if minutes < 1 or minutes > RangeInfo.MAX_ADVANCE:
		return 0
	var id := _range_op("range_advance", [minutes])
	if id > 0:
		queue_action("pause")
	return id


func range_set_ai_frozen(on: bool) -> int:
	return _range_op("range_set_ai_frozen", [on])


## Full hit points, no pain or bad effects, fed, watered, rested, full stamina.
func range_heal() -> int:
	return _range_op("range_heal", [])


## `count` (1..1000) of item type index `itype` on square `pos` (in the reality bubble).
func range_spawn_item(itype: int, count: int, pos: Vector3i) -> int:
	if itype < 1 or itype > Snapshot.MAX_ID or count < 1 or count > RangeInfo.MAX_COUNT or not ItemActions.ok_square(pos):
		return 0
	return _range_op("range_spawn_item", [itype, count, pos])


## A monster by CDDA id on a passable, empty square `pos` in the bubble.
func range_spawn_monster(id: String, pos: Vector3i) -> int:
	if not RangeInfo.monster_id_ok(id) or not ItemActions.ok_square(pos):
		return 0
	return _range_op("range_spawn_monster", [id, pos])


func _range_op(method: String, args: Array) -> int:
	if not _can(method) or _range_ops.size() >= MAX_RANGE_OPS:
		return 0
	var v: Variant = _sim.callv(method, args)
	var id := int(v) if (v is int or v is float) and is_finite(float(v)) else 0
	if id < 1 or id > RangeInfo.MAX_OP_ID:
		return 0
	_range_ops[id] = Time.get_ticks_msec()
	_range_poll_s = RANGE_POLL_S   # look at the next frame
	return id


## L9: what a container's contents can become on the heat it stands on (bridge match_recipes; read-only, the sim
## answers at its next request). Returns the query id, 0 when refused (no game, a bad handle, too many pending).
## `avatar_square`: where the player stands, sent for a carried container (the bridge looks there).
## recipes_matched follows.
func match_recipes(container: ItemRef, avatar_square := Vector3i.ZERO) -> int:
	if container == null or container.uid < 1 or container.type < 1 or not _can("match_recipes") \
			or _queries.size() >= MAX_QUERIES:
		return 0
	var pos := avatar_square if container.carried else container.square
	var v: Variant = _sim.match_recipes({"uid": container.uid, "type": container.type, "pos": pos})
	var id := int(v) if v is int or v is float else 0
	if id < 1:
		return 0
	_queries[id] = [container.uid, Time.get_ticks_msec()]
	return id


## The last recipe result for container `uid` (as recipes_matched gave it), {} for none.
func recipe_matches(uid: int) -> Dictionary:
	return _recipe_results.get(uid, {})


func _poll_queries() -> void:
	if _queries.is_empty() or not _sim.has_method("take_query_result"):
		return
	var now := Time.get_ticks_msec()
	for id: int in _queries.keys():
		var text: Variant = _sim.take_query_result(id)
		var asked: Array = _queries[id]
		if not text is String or (text as String).is_empty():
			if now - int(asked[1]) > QUERY_TIMEOUT_MS:
				_queries.erase(id)
			continue
		_queries.erase(id)
		var r := RecipeMatches.parse(text)
		var uid: int = asked[0]
		if r.is_empty() or r["id"] != id or r["container"] != uid:
			push_warning("recipe query %d: unreadable result" % id)
			continue
		if not _recipe_results.has(uid) and _recipe_results.size() >= MAX_KEPT_RESULTS:
			_recipe_results.erase(_recipe_results.keys()[0])
		_recipe_results[uid] = r
		recipes_matched.emit(uid, r)


func _can(method: String) -> bool:
	return _sim != null and state == "running" and _sim.has_method(method)


func _make_sim() -> bool:
	if not available():
		error = "bridge not loaded: build fp3d-cdda (docs/BUILD.md)"
		return false
	_sim = ClassDB.instantiate("CddaSim")
	_push_cheats_allowed()
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


## Unload an item (carried, else the one on square `pos`): a gun's magazine whole, a magazine's rounds, to
## `hand` ("pack", "main", "off"). An older bridge refuses the op (false).
func unload_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
	return _sim != null and _sim.queue_item_action({"op": "unload", "item": int(uid), "type": int(type),
			"pos": pos, "hand": hand})


## Reload a carried item with ammo or a magazine (carried, else the one on square `pos`), as much as fits.
func reload_item(uid: float, type: float, ammo: float, ammo_type: float, pos: Vector3i) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "reload", "item": int(uid), "type": int(type),
			"container": int(ammo), "container_type": int(ammo_type), "pos": pos})


## Throw a carried, unworn item at square `pos` (one you see, on your level, in throw range, not your own):
## CDDA's throw without its target menu, one unit of a stack. An older bridge refuses the op (false).
func throw_item(uid: float, type: float, pos: Vector3i) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "throw", "item": int(uid), "type": int(type), "pos": pos})


## Pour the liquid out of carried `uid` (a container, or the liquid itself) onto square `pos`: yours or one next
## to it, all of it.
func pour_item(uid: float, type: float, pos: Vector3i) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "pour", "item": int(uid), "type": int(type), "pos": pos})


## Pour the liquid out of carried `uid` into `container` (carried, or on or next to your square), as much as
## fits; `pocket` -1 = CDDA's pick.
func pour_into(uid: float, type: float, container: float, container_type: float, pocket := -1) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "pour", "item": int(uid), "type": int(type),
			"container": int(container), "container_type": int(container_type), "pocket": pocket})


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
			error = Snapshot.plain_text(_sim.get_error(), MAX_ERROR_TEXT)
		if s == "running":
			_push_cheats_allowed()   # before state_changed: --test / --cheats are applied on it
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
	_poll_queries()
	_poll_range(delta)
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


## Test range: every frame in a range game or with ops waiting, else once a second (a normal game's answer is
## only `range` false). range_done once per result of an op sent from here; range_changed when the info
## (without results, whose changes don't bump seq) changed.
func _poll_range(delta: float) -> void:
	if state != "running" or not _sim.has_method("get_range_info"):
		if not _range.is_empty() or not _range_ops.is_empty():
			_range = {}
			_range_seq = -1
			_range_ops.clear()
			range_changed.emit({})
		return
	_range_poll_s += delta
	if _range_ops.is_empty() and _range_poll_s < RANGE_POLL_S and _range_seq >= 0:
		return
	_range_poll_s = 0.0
	var d: Variant = _sim.get_range_info()
	if not d is Dictionary:
		return
	if not _range_ops.is_empty():
		for r: Dictionary in RangeInfo.results(d):
			if _range_ops.erase(r["id"]):
				range_done.emit(r["id"], r["error"])
		var now := Time.get_ticks_msec()
		for id: int in _range_ops.keys():
			if now - int(_range_ops[id]) > QUERY_TIMEOUT_MS:   # the game held up (a prompt open), or pushed out
				_range_ops.erase(id)
				range_done.emit(id, NO_ANSWER)
	var seq: Variant = (d as Dictionary).get("seq", 0)
	if not (seq is int or seq is float) or int(seq) == _range_seq:
		return   # the zones only cleaned when something changed (~1 ms for 58 of them)
	var info := RangeInfo.clean(d)
	if info.is_empty():
		return
	_range_seq = int(seq)
	info.erase("results")
	if info != _range:
		_range = info
		range_changed.emit(info.duplicate(true))


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
