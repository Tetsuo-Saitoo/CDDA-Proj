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
## G4: a character query (query_character) came back: CharacterData.parse_result's Dictionary, still game data
## (`ok` false: {error}; CharacterData.set_sheet reads it).
signal character_sheet(sheet: Dictionary)
## C6: a vehicle-work read (query_vehicle_work) came back: VehicleWorkData.clean's Dictionary (`ok` false: {vehicle,
## error}).
signal vehicle_work(result: Dictionary)
## G5: a map page (query_overmap) came back: MapData.parse_page's Dictionary.
signal overmap(result: Dictionary)
## K7 test range (CddaSim.get_range_info, RangeInfo.clean without `results`) changed: zones, the zone the
## character is in, AI frozen. {} when the game stops running.
signal range_changed(info: Dictionary)
## A range_* operation sent from here was done (error "") or refused (the game's reason; NO_ANSWER when its
## result didn't come within QUERY_TIMEOUT_MS: a prompt may hold the game up, and the op may still run).
signal range_done(op_id: int, error: String)

## Testing cheats the bridge knows (contracts/bridge_api.md, set_cheat); any other name is refused here.
const CHEATS: PackedStringArray = ["invincible", "no_needs", "no_weight_limit", "unlimited_ammo", "stamina",
		"no_temperature", "night_vision", "unstoppable"]

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
## The character query waiting for its result (0 none) and when it was asked (msec).
var _char_query := 0
var _char_asked := 0
var _work_query := 0
var _work_asked := 0
var _work_uid := 0   # the vehicle _work_query asked about
var _work_tag := 0   # the last vehicle_work action's tag (1..2^31-1, wraps)
var _map_query := 0          # G5: the map page waiting for its result (0 none), when asked, and its origin
var _map_asked := 0
var _map_tag := 0            # G5 slice 2: the last tag a map write carried
var _map_origin := Vector3i.ZERO
const MAX_QUERIES := 8          # the bridge refuses more pending ones
const MAX_PART_LEN := 32   # consume's body part id (the bridge's cap)
const MAX_ITEM_TAG := 2147483647   # place / spot ops carry a tag 1..this, given back in their item_result
const MAX_COOK_BATCH := 20         # L9: the bridge's cook `batch` range is 1..this
const MAX_RECIPE := 128            # L9: a recipe id's bytes
const MAX_KEPT_RESULTS := 32
const QUERY_TIMEOUT_MS := 30000   # forgotten if no answer comes (a long prompt holds the sim up)
## Test range: the last info (no results), its seq, ops sent and waiting for a result (id -> msec sent).
var _range := {}
var _range_seq := -1
var _range_ops := {}
var _range_poll_s := 0.0
## Waiting range ops at most: the bridge keeps 32 waiting but only the last 16 results, so more could lose theirs.
const MAX_RANGE_OPS := RangeInfo.MAX_RESULTS
## The weather cheat: at most this many types are looked at, each name cut to this length; wind in m/s.
const MAX_WEATHER_TYPES := 128
const MAX_WEATHER_NAME := 48
const MAX_WIND := 45.0
## cheat_set_weather's wind for "as the game decides".
const WIND_GAME := -1.0
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
## The last snapshot the delta call gave (it has key rows): the next fetch asks for what changed since it. Read by
## the worker while the world shows it, so nothing may change it or its Submaps (only mock mode edits Submaps).
var _base: Snapshot
## Deltas read, and deltas that didn't fit the snapshot held and were asked for again whole (logged now and then).
var deltas_read := 0
var delta_fallbacks := 0
var _fallback_logged_ms := -1
const FALLBACK_LOG_MS := 10000
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


## Real time (true: each turn lasts a second of wall time) or turns (false: the game waits for the player), the
## bridge's set_real_time. False without a game or a bridge that has it.
func set_real_time(on: bool) -> bool:
	if not _can("set_real_time"):
		return false
	_sim.set_real_time(on)
	return true


## Pauses or resumes turns (the bridge's set_paused; real time and turn-based alike). False without a game or a
## bridge that has it.
func set_paused(on: bool) -> bool:
	if not _can("set_paused"):
		return false
	_sim.set_paused(on)
	return true


## The sim's clock, checked: {real_time: bool, paused: bool, pause_reason: String (plain, capped)}; all false / ""
## without a game.
func clock() -> Dictionary:
	var c: Variant = _sim.get_clock() if _can("get_clock") else {}
	var d: Dictionary = c if c is Dictionary else {}
	return {"real_time": _true(d.get("real_time")), "paused": _true(d.get("paused")),
			"pause_reason": Snapshot.plain_text(d.get("pause_reason"), 64)}


static func _true(v: Variant) -> bool:
	return v is bool and v


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


## Cheat: teleport to square `pos` in the bubble (any game, cheats allowed; CddaSim.cheat_teleport, lead-bridge).
## Same op ids and range_done as the range ops; 0 when refused here (cheats not allowed, no game, bad square).
func cheat_teleport(pos: Vector3i) -> int:
	if not can_teleport() or not ItemActions.ok_square(pos):
		return 0
	return _range_op("cheat_teleport", [pos])


## The teleport cheat can be asked for now (the F1 entry is greyed out otherwise).
func can_teleport() -> bool:
	return cheats_allowed and _can("cheat_teleport")


## Cheat: every grab on the player (and their mount) lets go, with the unstoppable cheat on or off (any game, cheats
## allowed; CddaSim.cheat_break_grabs). Same op ids and range_done as the range ops; 0 when refused here.
func cheat_break_grabs() -> int:
	if not can_break_grabs():
		return 0
	return _range_op("cheat_break_grabs", [])


## "Break all grabs" can be asked for now (greyed out otherwise).
func can_break_grabs() -> bool:
	return cheats_allowed and _can("cheat_break_grabs")


## CDDA's weather types for the weather cheat (CddaSim.get_weather_types, lead-bridge), cleaned: [{id, name}] in
## the bridge's order; [] without a game, before its data is loaded, or with a bridge that hasn't got it.
func weather_types() -> Array:
	if not _can("get_weather_types"):
		return []
	return clean_weather_types(_sim.get_weather_types())


## get_weather_types' reply as hostile input: only the first MAX_WEATHER_TYPES entries are looked at; each must be
## a Dictionary whose id is a CDDA id (1..64 of letters, digits, _ and -, like a monster id) not seen before; its
## name becomes one plain line (no tags or control characters) of at most MAX_WEATHER_NAME, the id when empty.
static func clean_weather_types(v: Variant) -> Array:
	var out: Array = []
	if not v is Array:
		return out
	var seen := {}
	for e: Variant in (v as Array).slice(0, MAX_WEATHER_TYPES):
		if not e is Dictionary:
			continue
		var id: Variant = (e as Dictionary).get("id")
		if not id is String or not RangeInfo.monster_id_ok(id) or seen.has(id):
			continue
		seen[id] = true
		var n := Snapshot.plain_text((e as Dictionary).get("name"), MAX_WEATHER_NAME)
		out.append({"id": id, "name": n if not n.is_empty() else str(id)})
	return out


## The weather the cheat holds (get_cheats' "weather"): "" when the game decides, without a game, or for junk.
func cheat_weather() -> String:
	if not _can("get_cheats"):
		return ""
	var d: Variant = _sim.get_cheats()
	var w: Variant = (d as Dictionary).get("weather", "") if d is Dictionary else ""
	return str(w) if w is String and RangeInfo.monster_id_ok(w) else ""


## The wind the cheat holds (get_cheats' "wind", m/s 0..MAX_WIND): WIND_GAME when the game decides, without a game,
## or for junk (NaN, a string, out of range).
func cheat_wind() -> float:
	if not _can("get_cheats"):
		return WIND_GAME
	var d: Variant = _sim.get_cheats()
	var w: Variant = (d as Dictionary).get("wind", WIND_GAME) if d is Dictionary else WIND_GAME
	return float(w) if (w is float or w is int) and float(w) >= 0.0 and float(w) <= MAX_WIND else WIND_GAME


## Cheat: holds the weather at type `id` ("" hands it back to the game) with the wind at `wind` m/s (0..MAX_WIND;
## WIND_GAME leaves the wind to the game). CddaSim.cheat_set_weather (lead-bridge): any game, cheats allowed. Same
## op ids and range_done as the range ops; 0 when refused here (cheats not allowed, no game, a bad id or wind).
func cheat_set_weather(id: String, wind: float) -> int:
	if not can_set_weather() or not (id.is_empty() or RangeInfo.monster_id_ok(id)):
		return 0
	if wind != WIND_GAME and not (wind >= 0.0 and wind <= MAX_WIND):   # NaN fails both
		return 0
	return _range_op("cheat_set_weather", [id, wind])


## The weather cheat can be asked for now (the F1 row is greyed out otherwise).
func can_set_weather() -> bool:
	return cheats_allowed and _can("cheat_set_weather")


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


## G4: the character sheet (bridge query_character; read-only, the sim answers at its next request). Returns the
## query id, 0 when refused (no game, an older DLL, one still waiting: the bridge takes one at a time).
## character_sheet follows. A query unanswered for QUERY_TIMEOUT_MS may be replaced if the bridge takes a new one.
func query_character() -> int:
	if not _can("query_character") or (_char_query > 0 and Time.get_ticks_msec() - _char_asked < QUERY_TIMEOUT_MS):
		return 0
	var v: Variant = _sim.query_character()
	var id := int(v) if (v is int or v is float) and is_finite(float(v)) else 0
	if id < 1 or id > CharacterData.MAX_QUERY_ID:
		return 0
	_char_query = id
	_char_asked = Time.get_ticks_msec()
	return id


## C6: what can be done on vehicle `uid` (the snapshot's uid), and on its part row `part` (-1: none), by CDDA's own
## checks (contracts/vehicle_work.md; read-only, answered at the sim's next request). With `install` (a square of
## the vehicle by mount; `part` -1) the read lists what could be installed there instead, and `vpart` (> 0) the
## requirements for that type. Returns the query id, 0 when refused (no game, an older DLL, one still waiting:
## the bridge takes one at a time). vehicle_work follows.
func query_vehicle_work(uid: int, part := -1, install := Vector2i.MAX, vpart := 0) -> int:
	var at := install != Vector2i.MAX
	if not _can("query_vehicle_work") or uid < 1 or uid > VehicleWorkData.MAX_UID or part < -1 \
			or part > VehicleWorkData.MAX_ROW or (at and part >= 0) or vpart < 0 \
			or vpart > VehicleWorkData.MAX_ACTION_VPART or (vpart > 0 and not at) \
			or (at and (absi(install.x) > VehicleWorkData.MAX_ACTION_MOUNT
				or absi(install.y) > VehicleWorkData.MAX_ACTION_MOUNT)) \
			or (_work_query > 0 and Time.get_ticks_msec() - _work_asked < QUERY_TIMEOUT_MS):
		return 0
	var d := {"vehicle": uid}
	if part >= 0:
		d["part"] = part
	if at:
		d["install"] = [install.x, install.y]
		if vpart > 0:
			d["vpart"] = vpart
	var v: Variant = _sim.query_vehicle_work(d)
	var id := int(v) if (v is int or v is float) and is_finite(float(v)) else 0
	if id < 1 or id > VehicleWorkData.MAX_QUERY_ID:
		return 0
	_work_query = id
	_work_asked = Time.get_ticks_msec()
	_work_uid = uid
	return id


## C6: start `cmd` (VehicleWorkData.ACTION_CMDS: "r" repair, "o" remove, "m" mend, "f" refill) on part row `part` of vehicle `uid`,
## which holds part `vpart` at `mount` (the read's part entry: the sim refuses a row that moved, with
## VehicleWorkData.MOVED); or "i": install a part of type `vpart` on square `mount` (`part` -1, not sent). contracts/vehicle_work.md "The action"; the sim checks it all again. Returns the
## action's tag, answered by one `work_result` event (VehicleWorkData.work_result), or 0 when refused before it
## was queued.
func queue_vehicle_work(uid: int, part: int, vpart: int, mount: Vector2i, cmd: String) -> int:
	var install := cmd == "i"
	if not _can("queue_vehicle_work") or uid < 1 or uid > VehicleWorkData.MAX_UID \
			or (part != -1 if install else (part < 0 or part > VehicleWorkData.MAX_ROW)) \
			or not cmd in VehicleWorkData.ACTION_CMDS \
			or vpart < 1 or vpart > VehicleWorkData.MAX_ACTION_VPART \
			or absi(mount.x) > VehicleWorkData.MAX_ACTION_MOUNT or absi(mount.y) > VehicleWorkData.MAX_ACTION_MOUNT:
		return 0
	_work_tag = _work_tag % VehicleWorkData.MAX_TAG + 1
	var d := {"vehicle": uid, "vpart": vpart, "mount": [mount.x, mount.y], "cmd": cmd, "tag": _work_tag}
	if not install:
		d["part"] = part
	if _sim.queue_vehicle_work(d) != true:
		return 0
	return _work_tag


## Whether the bridge takes the vehicle_work action (an older DLL doesn't: the view says it isn't connected).
func can_vehicle_work() -> bool:
	return _can("queue_vehicle_work")


## Whether the bridge answers the vehicle-work read (an older DLL doesn't: the view uses its stand-in).
func has_vehicle_work() -> bool:
	return _can("query_vehicle_work")


func vehicle_work_pending() -> bool:
	return _work_query > 0


func _poll_vehicle_work() -> void:
	if _work_query < 1:
		return
	if state != "running" or not _sim.has_method("take_query_result"):
		_work_query = 0
		return
	var text: Variant = _sim.take_query_result(_work_query)
	if not text is String or (text as String).is_empty():
		if Time.get_ticks_msec() - _work_asked > QUERY_TIMEOUT_MS:
			_work_query = 0
		return
	var id := _work_query
	_work_query = 0
	var d := VehicleWorkData.parse_result(text, id)
	if not d.is_empty() and d["ok"] != true and d["vehicle"] == 0:
		d["vehicle"] = _work_uid   # the contract's error carries no vehicle: it is the one this query asked about
	if d.is_empty() or d["vehicle"] != _work_uid:
		push_warning("vehicle work query %d: unreadable result" % id)
		return
	vehicle_work.emit(d)


## G5: the map page of 32x32 cells (OMTs) whose corner is `origin` (absolute OMT; x and y multiples of
## MapData.PAGE, z a level): what CDDA's own map screen would show there (contracts/overmap.md; read-only, it never
## creates ground). With `with_path` the player's destination path comes too. Returns the query id, 0 when refused
## (no game, an older DLL, one still waiting: one at a time). overmap follows.
func query_overmap(origin: Vector3i, with_path := false) -> int:
	if not _can("query_overmap") or posmod(origin.x, MapData.PAGE) != 0 or posmod(origin.y, MapData.PAGE) != 0 \
			or absi(origin.x) > MapData.MAX_XY or absi(origin.y) > MapData.MAX_XY \
			or origin.z < MapData.Z_MIN or origin.z > MapData.Z_MAX \
			or (_map_query > 0 and Time.get_ticks_msec() - _map_asked < QUERY_TIMEOUT_MS):
		return 0
	var d := {"origin": [origin.x, origin.y, origin.z]}
	if with_path:
		d["path"] = true
	var v: Variant = _sim.query_overmap(d)
	var id := int(v) if (v is int or v is float) and is_finite(float(v)) else 0
	if id < 1 or id > MapData.MAX_QUERY_ID:
		return 0
	_map_query = id
	_map_asked = Time.get_ticks_msec()
	_map_origin = origin
	return id


## Whether the bridge answers the map read (an older DLL doesn't: the map says it isn't connected).
func has_overmap() -> bool:
	return _can("query_overmap")


## Map slice 2 (docs/MAP.md): writes or replaces CDDA's note on `cell` (absolute OMT): `text` as MapData.clean_note
## leaves it, `symbol` and `color` as MapData checks them, the danger mark and its radius (0 when not dangerous).
## CDDA answers with one `map_result` event carrying the tag returned; 0 when refused before it was queued.
func queue_map_note(cell: Vector3i, text: String, symbol: String, color: String, danger: bool, radius: int) -> int:
	if not MapData.ok_cell(cell) or text.is_empty() or text != MapData.clean_note(text) or not MapData.ok_symbol(symbol) \
			or MapData.note_color_index(color) < 0 or radius < 0 or radius > MapData.MAX_DANGER_RADIUS \
			or (radius > 0 and not danger):
		return 0
	return _queue_map({"cmd": "note", "omt": [cell.x, cell.y, cell.z], "text": text, "sym": symbol, "color": color,
			"danger": danger, "radius": radius})


## Deletes CDDA's note on `cell`; answered as queue_map_note is.
func queue_map_unnote(cell: Vector3i) -> int:
	if not MapData.ok_cell(cell):
		return 0
	return _queue_map({"cmd": "unnote", "omt": [cell.x, cell.y, cell.z]})


## Whether the bridge takes the map's writes (an older DLL doesn't).
func can_map_notes() -> bool:
	return _can("queue_overmap")


func _queue_map(d: Dictionary) -> int:
	if not _can("queue_overmap"):
		return 0
	_map_tag = _map_tag % MapData.MAX_TAG + 1
	d["tag"] = _map_tag
	if _sim.queue_overmap(d) != true:
		return 0
	return _map_tag


func overmap_pending() -> bool:
	return _map_query > 0


func _poll_overmap() -> void:
	if _map_query < 1:
		return
	if state != "running" or not _sim.has_method("take_query_result"):
		_map_query = 0
		return
	var text: Variant = _sim.take_query_result(_map_query)
	if not text is String or (text as String).is_empty():
		if Time.get_ticks_msec() - _map_asked > QUERY_TIMEOUT_MS:
			_map_query = 0
			overmap.emit({"ok": false, "origin": _map_origin, "error": "internal"})   # the asker may ask again
		return
	var id := _map_query
	_map_query = 0
	var d := MapData.parse_page(text, id, _map_origin)
	if d.is_empty():
		push_warning("map query %d: unreadable result" % id)
		d = {"ok": false, "origin": _map_origin, "error": "internal"}
	overmap.emit(d)


func character_pending() -> bool:
	return _char_query > 0


func _poll_character() -> void:
	if _char_query < 1:
		return
	if state != "running" or not _sim.has_method("take_query_result"):
		_char_query = 0
		return
	var text: Variant = _sim.take_query_result(_char_query)
	if not text is String or (text as String).is_empty():
		return
	var id := _char_query
	_char_query = 0
	var d := CharacterData.parse_result(text, id)
	if d.is_empty():
		push_warning("character query %d: unreadable result" % id)
		return
	character_sheet.emit(d)


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
	_base = null
	_char_query = 0
	_map_query = 0
	_push_cheats_allowed()
	return true


func stop() -> void:
	if _snap_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_snap_task)
		_snap_task = -1
		_snap_job = null
	_base = null
	if _sim != null:
		_sim.stop()


func answer(a: Dictionary) -> bool:
	return _sim != null and _sim.answer(a)


func queue_action(action: String) -> bool:
	return _sim != null and _sim.queue_action(action)


## A main-loop action for one square (CddaSim.queue_action_at, contracts/bridge_api.md): `square` is absolute (map
## squares, as the snapshot's positions). False when the bridge refuses it (out of range, a reserved action) or this
## DLL has no queue_action_at; an action CDDA doesn't allow at that square isn't a false but a message event.
func queue_action_at(action: String, square: Vector3i) -> bool:
	return _sim != null and _sim.has_method("queue_action_at") and _sim.queue_action_at(action, square)


## One item by its snapshot handle (uid + itype index), no menus; the sim checks it again and says why not in a
## message (contracts/bridge_api.md). JSON numbers arrive as floats: they are made ints here.
## Take from square `pos` into hand "pack", "main" or "off". L8: `container` + `container_type` (a handle_ok pair,
## not the item itself; both -1 = none, the request as before) name the lying container on `pos` that holds the
## item directly (one level). Only one of them, or a bad one: false, nothing sent.
func take_item(uid: float, type: float, pos: Vector3i, hand := "pack", container := -1.0,
		container_type := -1.0) -> bool:
	var a := {"op": "take", "item": int(uid), "type": int(type), "pos": pos, "hand": hand}
	if container != -1.0 or container_type != -1.0:
		if not handle_ok(container, container_type) or container == uid:
			return false
		a["container"] = int(container)
		a["container_type"] = int(container_type)
	return _sim != null and _sim.queue_item_action(a)


## Put a carried item into a container: a carried one (worn, held), else the one on square `pos`;
## `pocket` -1 = CDDA's choice, else an index as the snapshot's carried items give it.
func put_item(uid: float, type: float, container: float, container_type: float, pos: Vector3i,
		pocket := -1) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "put", "item": int(uid), "type": int(type),
			"container": int(container), "container_type": int(container_type), "pos": pos, "pocket": pocket})


## Drop a carried item on square `pos`; `spot` (each 0..1 across the square) places it there, (-1, -1) none.
## `shelf` (L8: 0..ItemActions.MAX_SHELF, -1 none) goes only with a spot; outside that range: false, nothing sent.
func drop_item(uid: float, type: float, pos: Vector3i, spot := Vector2(-1, -1), shelf := -1, cargo := false) -> bool:
	if shelf < -1 or shelf > ItemActions.MAX_SHELF or (cargo and (spot != Vector2(-1, -1) or shelf != -1)):
		return false
	var a := {"op": "drop", "item": int(uid), "type": int(type), "pos": pos}
	if cargo:   # into the vehicle cargo space on `pos` (contracts/bridge_api.md "Vehicle cargo by hand"), no spot
		a["cargo"] = true
	if spot.x >= 0.0 and spot.y >= 0.0:
		a["spot"] = spot
		if shelf >= 0:
			a["shelf"] = shelf
	return _sim != null and _sim.queue_item_action(a)


## Unload an item (carried, else the one on square `pos`): a gun's magazine whole, a magazine's rounds, to
## `hand` ("pack", "main", "off"). An older bridge refuses the op (false).
func unload_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
	return _sim != null and _sim.queue_item_action({"op": "unload", "item": int(uid), "type": int(type),
			"pos": pos, "hand": hand})


## Hold a carried item in hand "main" (CDDA's wield) or "off" (ItemActions.hold, for Hands.hand_over). CDDA never
## puts anything away for it: it refuses (an m_info message) a full hand, a worn or two-handed item, a sealed pocket
## or part of a gun or magazine, a liquid, and an open container with contents going from the main hand to the off
## hand. False when refused here (nothing sent): no game, an other hand, a uid or itype not a whole number in the
## snapshot's ranges.
func hold_item(uid: float, type: float, hand: String) -> bool:
	if _sim == null or not hand in ["main", "off"] or not handle_ok(uid, type):
		return false
	return bool(_sim.queue_item_action({"op": "hold", "item": int(uid), "type": int(type), "hand": hand}))


## Eat, drink or take carried (or held) `uid` with CDDA's consume rules and move costs, no menu: a container's
## contents. `tag` 1..MAX_ITEM_TAG (0: none) comes back in its `item_result` event (done once CDDA's activity has
## started; refused with CDDA's text, or "" when its message said why). False when refused here (nothing sent): no
## game, a bad handle or tag, or a bridge without the op (it refuses an unknown op), so callers can fall back to
## CDDA's eat menu. `part` ("" none): a main body part id for first aid (lead-vr; the bridge checks it is one of the
## character's), sent only when set; one that isn't a short plain id is refused here.
func consume_item(uid: float, type: float, tag := 0, part := "") -> bool:
	if _sim == null or not handle_ok(uid, type) or tag < 0 or tag > MAX_ITEM_TAG:
		return false
	if part != "" and (part.length() > MAX_PART_LEN or not part.is_valid_ascii_identifier()):
		return false
	var a := {"op": "consume", "item": int(uid), "type": int(type)}
	if tag > 0:
		a["tag"] = tag
	if part != "":
		a["part"] = part
	return bool(_sim.queue_item_action(a))


## Gun modification by hand: fit the carried gunmod `uid` onto the wielded gun `gun` (bridge op "mod_add"), or take the
## installed gunmod `uid` off it ("mod_remove"); `tag` 1..MAX_ITEM_TAG answers with an item_result (0: none). An older
## bridge refuses the op (false). mod_add's `vise` / `vise_type`: the bench vise the gun is clamped in (a handle; 0, 0
## none: the keys left out), checked here and by the sim (within reach, VISE 3).
func mod_add_item(uid: float, type: float, gun: float, gun_type: float, tag := 0, vise := 0.0,
		vise_type := 0.0) -> bool:
	if vise == 0.0 and vise_type == 0.0:
		return _mod_item("mod_add", uid, type, gun, gun_type, tag)
	if not handle_ok(vise, vise_type) or vise == uid or vise == gun:
		return false
	return _mod_item("mod_add", uid, type, gun, gun_type, tag, {"vise": int(vise), "vise_type": int(vise_type)})


func mod_remove_item(uid: float, type: float, gun: float, gun_type: float, tag := 0) -> bool:
	return _mod_item("mod_remove", uid, type, gun, gun_type, tag)


func _mod_item(op: String, uid: float, type: float, gun: float, gun_type: float, tag: int, extra := {}) -> bool:
	if _sim == null or not handle_ok(uid, type) or not handle_ok(gun, gun_type) or uid == gun or tag < 0 \
			or tag > MAX_ITEM_TAG:
		return false
	var a := {"op": op, "item": int(uid), "type": int(type), "container": int(gun), "container_type": int(gun_type)}
	if tag > 0:
		a["tag"] = tag
	a.merge(extra)
	return bool(_sim.queue_item_action(a))


## A snapshot item handle: uid 1..MAX_UID-1 and itype 1..MAX_ID, whole and finite.
static func handle_ok(uid: float, type: float) -> bool:
	return is_finite(uid) and is_finite(type) and uid == floorf(uid) and type == floorf(type) and uid >= 1.0 \
			and uid < float(Snapshot.MAX_UID) and type >= 1.0 and type <= float(Snapshot.MAX_ID)


## Reload a carried item with ammo or a magazine (carried, else the one on square `pos`), as much as fits.
func reload_item(uid: float, type: float, ammo: float, ammo_type: float, pos: Vector3i) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "reload", "item": int(uid), "type": int(type),
			"container": int(ammo), "container_type": int(ammo_type), "pos": pos})


## Clear the jam of the wielded gun `uid` (bridge op "clear", CDDA's mend). An older bridge refuses the op (false).
func clear_item(uid: float, type: float) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "clear", "item": int(uid), "type": int(type)})


## Throw a carried, unworn item at square `pos` (one you see, on your level, in throw range, not your own):
## CDDA's throw without its target menu, one unit of a stack. An older bridge refuses the op (false).
func throw_item(uid: float, type: float, pos: Vector3i) -> bool:
	return _sim != null and _sim.queue_item_action({"op": "throw", "item": int(uid), "type": int(type), "pos": pos})


## Pour the liquid out of `uid` (a container, carried or lying on your square or one next to it, e.g. a pot on its
## burner; or the carried liquid itself) onto square `pos`: yours or one next to it, all of it. False when refused
## here (nothing sent): no game, a bad handle or square.
func pour_item(uid: float, type: float, pos: Vector3i) -> bool:
	if _sim == null or not handle_ok(uid, type) or not ItemActions.ok_square(pos):
		return false
	return bool(_sim.queue_item_action({"op": "pour", "item": int(uid), "type": int(type), "pos": pos}))


## Pour the liquid out of `uid` (as for pour_item) into `container` (carried, or on or next to your square, e.g. a
## pot), as much as fits; `pocket` -1 = CDDA's pick. False when refused here (nothing sent): no game, a bad handle,
## pocket, or the container being the item itself.
func pour_into(uid: float, type: float, container: float, container_type: float, pocket := -1) -> bool:
	if _sim == null or not handle_ok(uid, type) or not handle_ok(container, container_type) or container == uid \
			or pocket < -1 or pocket > Snapshot.MAX_POCKET:
		return false
	return bool(_sim.queue_item_action({"op": "pour", "item": int(uid), "type": int(type),
			"container": int(container), "container_type": int(container_type), "pocket": pocket}))


## L9: cook `recipe` (an id match_recipes listed for this pot) from what pot `uid` lying on `pos` (your square or one
## next to it) holds, `batch` 1..MAX_COOK_BATCH; the same recipe again goes on with that pot's paused craft (batch
## unused). `tag` 1..MAX_ITEM_TAG (0: none) comes back in its `item_result` (done once the craft started or went on).
## False when refused here (nothing sent): no game, a bad handle, square, recipe id (recipe_ok), batch or tag.
func cook_item(uid: float, type: float, pos: Vector3i, recipe: String, batch := 1, tag := 0) -> bool:
	if _sim == null or not handle_ok(uid, type) or not ItemActions.ok_square(pos) or not recipe_ok(recipe) \
			or batch < 1 or batch > MAX_COOK_BATCH or tag < 0 or tag > MAX_ITEM_TAG:
		return false
	var a := {"op": "cook", "item": int(uid), "type": int(type), "pos": pos, "recipe": recipe, "batch": batch}
	if tag > 0:
		a["tag"] = tag
	return bool(_sim.queue_item_action(a))


## L9: light a fire on square `pos` next to you (never your own) with carried firestarter `uid` + `type`, or with
## both -1 the quickest carried one that works (CDDA's pick). CDDA's questions stay its popups; it needs fuel there.
## `tag` as for cook_item. False when refused here (nothing sent): no game, a bad or half handle, a square not next
## to `player` on its level, or a bad tag.
func light_fire(pos: Vector3i, player: Vector3i, uid := -1.0, type := -1.0, tag := 0) -> bool:
	if _sim == null or not ItemActions.ok_square(pos) or not ItemActions.ok_square(player) \
			or not GrabController.adjacent(pos - player) or tag < 0 or tag > MAX_ITEM_TAG:
		return false
	var a := {"op": "light", "pos": pos}
	if uid != -1.0 or type != -1.0:
		if not handle_ok(uid, type):
			return false
		a["item"] = int(uid)
		a["type"] = int(type)
	if tag > 0:
		a["tag"] = tag
	return bool(_sim.queue_item_action(a))


## L9: beat out the fire in the fire furniture (fireplace, stove, brazier ...) on `pos`, your square or one next to
## it (CDDA's "Extinguish fire", 200 moves). `tag` as for cook_item. False when refused here (nothing sent): no game,
## a square more than one step from `player` or on another level, a bad tag.
func extinguish_fire(pos: Vector3i, player: Vector3i, tag := 0) -> bool:
	if _sim == null or not ItemActions.ok_square(pos) or not ItemActions.ok_square(player) or pos.z != player.z \
			or maxi(absi(pos.x - player.x), absi(pos.y - player.y)) > 1 or tag < 0 or tag > MAX_ITEM_TAG:
		return false
	var a := {"op": "extinguish", "pos": pos}
	if tag > 0:
		a["tag"] = tag
	return bool(_sim.queue_item_action(a))


## A recipe id the bridge takes: 1..MAX_RECIPE characters of printable ASCII without spaces, quotes or backslashes.
static func recipe_ok(r: String) -> bool:
	if r.is_empty() or r.length() > MAX_RECIPE:
		return false
	for i in r.length():
		var c := r.unicode_at(i)
		if c <= 32 or c >= 127 or c == 34 or c == 39 or c == 92:
			return false
	return true


## L8: CDDA's own open (or close) of exactly the door, drawer or lid's furniture on `square`, one of the eight
## squares around `player` on its level (queue_action_at: CDDA never takes another square it would pick by itself;
## one it doesn't allow is CDDA's message, "There is nothing that can be opened nearby."). False when refused here
## (no game, a bad square, not next to the player) or when this DLL has no queue_action_at (see can_act_at).
func open_at(open: bool, square: Vector3i, player: Vector3i) -> bool:
	if not can_act_at() or not ItemActions.ok_square(square) or not ItemActions.ok_square(player) \
			or not GrabController.adjacent(square - player):
		return false
	return queue_action_at("open" if open else "close", square)


## The bridge takes actions for one square (CddaSim.queue_action_at; older DLLs don't).
func can_act_at() -> bool:
	return _sim != null and _sim.has_method("queue_action_at")


## E2 item physics (ItemPlacer): move item `uid` from square `pos` to the square next to it, `to` (same level; a
## square without a floor makes CDDA drop it). `spot` (each 0..1 across the square, clamped) with `yaw` (whole
## degrees 0..359, counter-clockwise from above, 0 = south) and `side` (lying on its side) is the pose it takes there;
## `spot` exactly (-1, -1) sends none (CDDA's own spot; a stored pose is cleared). `shelf` (L8: the furniture shelf
## it lies on, 0..ItemActions.MAX_SHELF, -1 none) goes only with a spot. CDDA answers with an `item_result` event
## whose detail is `tag` (1..MAX_ITEM_TAG). False when refused here (nothing sent): no game, a bad handle, square,
## spot, yaw, tag or shelf.
func place_item(uid: float, type: float, pos: Vector3i, to: Vector3i, spot: Vector2, yaw: int, side: bool,
		tag: int, shelf := -1) -> bool:
	if _sim == null or not _item_op_ok(uid, type, pos, yaw, tag) or not ItemActions.ok_square(to) or to.z != pos.z \
			or maxi(absi(to.x - pos.x), absi(to.y - pos.y)) != 1 or not spot.is_finite() or shelf < -1 \
			or shelf > ItemActions.MAX_SHELF:
		return false
	var a := {"op": "place", "item": int(uid), "type": int(type), "pos": pos, "to": to, "tag": tag}
	if spot != Vector2(-1, -1):
		if spot.x < 0.0 or spot.y < 0.0:
			return false   # half a spot: neither a pose nor none
		a["spot"] = _clamp_spot(spot)
		a["yaw"] = yaw
		a["side"] = side
		if shelf >= 0:
			a["shelf"] = shelf
	return _sim.queue_item_action(a)


## E2 item physics: item `uid` stays on square `pos` and takes this pose there (as place_item's, `shelf` too). False
## when refused here (nothing sent), as place_item, or without a spot.
func spot_item(uid: float, type: float, pos: Vector3i, spot: Vector2, yaw: int, side: bool, tag: int,
		shelf := -1) -> bool:
	if _sim == null or not _item_op_ok(uid, type, pos, yaw, tag) or not spot.is_finite() or spot.x < 0.0 \
			or spot.y < 0.0 or shelf < -1 or shelf > ItemActions.MAX_SHELF:
		return false
	var a := {"op": "spot", "item": int(uid), "type": int(type), "pos": pos, "spot": _clamp_spot(spot), "yaw": yaw,
			"side": side, "tag": tag}
	if shelf >= 0:
		a["shelf"] = shelf
	return _sim.queue_item_action(a)


## A snapshot item handle (handle_ok), a square snapshots allow, yaw 0..359, tag 1..MAX_ITEM_TAG.
static func _item_op_ok(uid: float, type: float, pos: Vector3i, yaw: int, tag: int) -> bool:
	return handle_ok(uid, type) and ItemActions.ok_square(pos) and yaw >= 0 and yaw < 360 and tag >= 1 \
			and tag <= MAX_ITEM_TAG


static func _clamp_spot(spot: Vector2) -> Vector2:
	return spot.clamp(Vector2.ZERO, Vector2(ItemActions.SPOT_MAX, ItemActions.SPOT_MAX))


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
	_poll_character()
	_poll_vehicle_work()
	_poll_overmap()
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
		# the next delta is built on this one only when it came from the delta call (key rows) and was read whole
		_base = snap if snap.is_valid() and not snap.submap_hash.is_empty() else null
		if snap.is_valid() and snap.base_seq >= 0:
			deltas_read += 1
		if not _snap_job.fallback_why.is_empty():
			_count_fallback(_snap_job.fallback_why)
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
	_snap_job = SnapJob.new(_sim, seq, ids_generation, _base)
	_snap_task = WorkerThreadPool.add_task(_snap_job.run, false, "snapshot parse")
	return false


## A delta that didn't fit was asked for again whole: counted, and logged at most once per FALLBACK_LOG_MS.
func _count_fallback(why: String) -> void:
	delta_fallbacks += 1
	var now := Time.get_ticks_msec()
	if _fallback_logged_ms < 0 or now - _fallback_logged_ms >= FALLBACK_LOG_MS:
		_fallback_logged_ms = now
		push_warning("live snapshot: %d deltas didn't fit and were fetched whole (last: %s)" % [delta_fallbacks,
				why.left(200)])


## One fetch and parse on a worker thread. The bridge hands out an immutable snapshot under a mutex, so the
## call is safe off the main thread; the job touches nothing else. `seq` is read before the fetch, so a newer
## snapshot taken meanwhile is fetched again next time (never skipped). A bridge with the delta call
## (contracts/snapshot.md "Deltas") is asked for what changed since `base`; a delta that doesn't fit it is
## dropped whole and the snapshot fetched again in full. `base` is only read.
class SnapJob:
	var sim: RefCounted
	var seq: int
	var known_generation: int
	var base: Snapshot     # the snapshot held, from the delta call; null: ask for a full one
	var snap: Snapshot
	var tables: IdTables   # fetched too when the snapshot wants a generation other than known_generation
	var fallback_why := "" # a delta that didn't fit: why (the snapshot was then fetched whole)

	func _init(s: RefCounted, q: int, generation: int, held: Snapshot = null) -> void:
		sim = s
		seq = q
		known_generation = generation
		base = held

	func run() -> void:
		if sim.has_method("get_snapshot_delta_json"):
			snap = Snapshot.parse_text(sim.get_snapshot_delta_json(Z_BELOW, Z_ABOVE, base.seq if base != null else 0),
					base)
			if not snap.is_valid() and base != null:
				fallback_why = snap.error
				snap = Snapshot.parse_text(sim.get_snapshot_delta_json(Z_BELOW, Z_ABOVE, 0))
		else:
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
