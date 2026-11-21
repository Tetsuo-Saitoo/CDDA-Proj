extends SceneTree
## Headless run of CDDA's action keys in the test range, through main's own input path: each key's first binding
## is pushed into the window as a key press, the menu or prompt CDDA answers with must show in RequestUI with the
## widget for its kind, and Esc must cancel it back to the main loop with the game still running. The lists get
## things to list first: the test kit and a few items at the feet. A key whose action finds nothing to work on may
## answer with a message instead (CDDA's "nothing to ..."): that is reported, not failed, except for the keys whose
## list or direction prompt is sure (KEYS). Last, F1 in the game: a free key goes in inventory's next key slot by
## the slot's button (saved in this run's folder, never the player's keys file), Esc closes the menu, and the new
## key opens the inventory. Before that the Tab view's numbers from the live snapshot (a stack's count, a bottle
## with water, nothing counted twice). Then the screen HUD: body bars, needs, move line and message feed from the
## live game.
## Then the off hand: H holds a kit item (water when it pours, else a knife), holding E pours a liquid out, Shift+H
## puts it away. Then F3's classic view of the map around the player. Near the end, first aid on a named body part
## (_first_aid_live). Last, real time and turns (_real_time_live) and the screen in a small window
## (_small_window_live). Uses this run's own CDDA folder, never the player's saves.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda, or --cdda=<folder>). ~3 min. From the repo
## root:
##   godot --headless --path client --script res://tests/actions_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 90000
const ASK_TIMEOUT_MS := 15000    # a key's prompt or message showing up
const SETTLE_MS := 1500          # after a message: a prompt may still follow
const MAX_ESC := 4               # Esc presses to get back to the main loop (chained prompts)
const LIST_KINDS := ["menu", "item_select", "item_multi"]
## [action, what CDDA must answer with: "list", "direction", or "" for either a prompt or a message]
const KEYS := [
	[&"cdda_inventory", "list"], [&"cdda_eat", "list"], [&"cdda_wear", "list"], [&"cdda_wield", "list"],
	[&"cdda_drop", "list"], [&"cdda_throw", "list"], [&"cdda_read", ""], [&"cdda_apply", ""],
	[&"cdda_take_off", ""], [&"cdda_unload", ""], [&"cdda_pickup", ""], [&"cdda_butcher", ""],
	[&"cdda_smash", "direction"], [&"cdda_open", ""], [&"cdda_close", ""], [&"cdda_examine", ""],
	[&"cdda_grab", ""],
]
## Laid at the feet for the lists: the first id of each the game knows (something to wear, read and eat).
const GUN := "glock_19"              # the test kit's pistol
const GUN_MOD := "rail_laser_sight"  # goes on its rail with no tools (lead-bridge's sim scene)
const VISE := "bench_vise"           # CDDA's bench vise (Vise.ITEM)
const AID := "bandages"              # CDDA's bandages: an item with its heal use
const AT_FEET := [["tshirt", "jeans"], ["novel_mystery", "mag_guns", "textbook_firearms", "news_regional"],
		["apple", "can_beans"]]

var _failed := 0
var _main: Main
var _live: LiveSession
var _cp: CheatPanel
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0    # the last prompt this script answered (setup only)
var _messages: PackedStringArray = []
var _seen: Array[String] = []   # one line per key, printed at the end


func _initialize() -> void:
	_run()


func _run() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_check(LiveSession.test_range_available(), "the bridge has the test range")
	if _failed > 0:
		_finish()
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-actions")
	_bind_debug_key(TestDir.path("cdda-actions"))
	root.add_child(_main)
	await process_frame
	_main.key_menu.save_path = TestDir.path("keys.json")   # a key set in F1 here never reaches the player's file
	_live = _main.live
	_cp = _main.cheat_panel
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	_live.events_arrived.connect(_on_events)
	var menu := _main.main_menu
	var button := _find_button(menu, "Test range") if menu != null else null
	_check(menu != null and button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	var t0 := Time.get_ticks_msec()
	var up := func() -> bool: return (_live.state == "running" and _main.world.snapshot != null
			and _cp.tables != null)
	_check(await _until(up, BOOT_TIMEOUT_MS, true), "the range runs (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if _live.state != "running":
		_finish()
		return
	var kits := _live.kits_given()
	_check(_live.give_test_kit(), "test kit asked for")
	_live.queue_action("pause")
	var kit_in := func() -> bool: return _live.kits_given() > kits
	_check(await _until(kit_in, OP_TIMEOUT_MS, true), "the test kit arrived")
	for ids: Array in AT_FEET:
		var id := ""
		for c: String in ids:
			if _cp.tables.index_of("itype", c) >= 0:
				id = c
				break
		if id.is_empty():
			print("  (none of %s in this game's data)" % [ids])
			continue
		_cp.item_id.text = id
		_cp.item_count.value = 1
		_check(await _op(_cp.spawn_item, "Spawn " + id) == "", "spawned a %s at the feet" % id)
	# the spawn pickers find types by name in this game's own tables
	var zs := SpawnSearch.find(_cp.tables, "mtype", "zombie").map(func(f: Dictionary) -> String: return f["id"])
	var gs := SpawnSearch.find(_cp.tables, "itype", "glock 19").map(func(f: Dictionary) -> String: return f["id"])
	_check(zs.size() > 1 and zs[0] == "mon_zombie" and not gs.is_empty() and gs[0] == "glock_19",
			"spawn search: \"zombie\" finds %d monster types, mon_zombie first; \"glock 19\" finds glock_19 first" % zs.size())
	print("    zombie: %s; glock 19: %s" % [zs.slice(0, 6), gs.slice(0, 4)])
	if _main.key_menu.visible:
		_main.key_menu.close()
	for k: Array in KEYS:
		await _try_key(k[0], k[1])
		if _live.state != "running":
			_check(false, "the game stopped after %s (%s %s)" % [k[0], _live.state, _live.error])
			break
	if _live.state == "running":
		await _counts_live()   # before anything is poured out or eaten
		await _rebind_live(&"cdda_inventory")
		await _eyes_live()
		await _lean_live()
		_hud_live()
		await _hands_live()
		await _consume_live()
		_classic_live()
		await _character_live()
		await _compass_live()
		await _number_live()
		await _gun_mods_live()
		await _vise_live()
		await _first_aid_live()
		await _esc_live()
		await _real_time_live()
		await _small_window_live()
	print("  what each key did:")
	for line in _seen:
		print("    " + line)
	await _stop()
	_finish()


## F1 in the game, then a free key put in `action`'s next key slot by its button in the menu (saved to this run's
## folder), Esc closes the menu, and the new key does the action in the game.
func _rebind_live(action: StringName) -> void:
	var km := _main.key_menu
	var key: InputEventKey = null
	for code: Key in [KEY_SEMICOLON, KEY_APOSTROPHE, KEY_F8, KEY_F9, KEY_K]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = true
		if InputActions.users_of(InputActions.binding_from(k)).is_empty():
			key = k
			break
	if key == null:
		_check(false, "F1: a free key to bind")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	var old := InputActions.slots(action)
	var f1 := InputEventKey.new()
	f1.keycode = InputActions.MENU_KEY
	f1.physical_keycode = InputActions.MENU_KEY
	f1.pressed = true
	root.push_input(f1)
	_check(km.visible, "F1 opens the key menu in the live game")
	(km._buttons[action][mini(old.size(), KeyMenu.SLOTS - 1)] as Button).pressed.emit()
	root.push_input(key)
	var t := InputActions.event_text(InputActions.binding_from(key))
	var bound := false
	for e in InputActions.slots(action):
		bound = bound or InputActions.event_text(e) == t
	_check(bound and FileAccess.file_exists(km.save_path) and km._status.text.begins_with(InputActions.info(action)[2] + ": "),
			"F1: %s bound to %s, saved in this run's folder (%s)" % [action, t, km._status.text])
	root.push_input(_esc_key())
	_check(not km.visible, "Esc closes the key menu")
	await _try_key(action, "list", key)
	InputActions.set_slots(action, old)


## The F1 menu's Eye tracking row in a running game (eye tracking, part 1; skipped, said so, on a client without
## it): a box per switch; a click on one is saved under [eyes] in this run's own hud.cfg, then put back. With no
## tracker the game is as before: nothing is tracked, the eyes paused nothing, and a turn passes once the menu is
## closed.
func _eyes_live() -> void:
	var km := _main.key_menu
	var checks: Variant = km.get("eye_checks")
	if not checks is Dictionary or not (checks as Dictionary).has("away_pause") or not _live.has_method("clock"):
		print("  (no Eye tracking row in this client's F1 menu: not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	var f1 := InputEventKey.new()
	f1.keycode = InputActions.MENU_KEY
	f1.physical_keycode = InputActions.MENU_KEY
	f1.pressed = true
	root.push_input(f1)
	var box: CheckBox = checks["away_pause"]
	var was := box.button_pressed
	var shown: bool = km.visible and box.is_visible_in_tree()
	var path: String = UserFiles.at(km.hud_path)
	box.button_pressed = not was   # as a click: toggled -> saved
	var cfg := ConfigFile.new()
	var saved: Variant = cfg.get_value("eyes", "away_pause", null) if cfg.load(path) == OK else null
	var set_now: bool = _main.hud_settings.eye_switch("away_pause")
	box.button_pressed = was
	var cfg2 := ConfigFile.new()
	var back: Variant = cfg2.get_value("eyes", "away_pause", null) if cfg2.load(path) == OK else null
	_check(shown and saved is bool and saved == (not was) and set_now == (not was) and back is bool and back == was
			and path.contains("test-runs"),
			"F1: the Eye tracking row shows %d boxes; a click on \"%s\" is saved under [eyes] in this run's hud.cfg and put back (%s -> %s -> %s; %s)"
			% [(checks as Dictionary).size(), box.text, was, saved, back, path])
	root.push_input(_esc_key())
	var gaze: Variant = _main.get("gaze")
	var tracked: bool = gaze != null and gaze.tracked()
	var pause: Variant = _main.get("eye_pause")
	var by_eyes: bool = pause != null and pause.paused_by_eyes
	var clock: Dictionary = _live.call("clock")
	var turn := _main.world.snapshot.turn
	_live.queue_action("pause")
	var later := func() -> bool: return _main.world.snapshot.turn > turn
	_check(not km.visible and not tracked and not by_eyes and clock.get("paused") == false
			and await _until(later, OP_TIMEOUT_MS, true),
			"eye tracking: with no tracker nothing is tracked, the eyes paused nothing, and a turn passes as before (clock %s)" % clock)


## Leaning to peek in a running game (the flat lean keys; skipped, said so, on a client without them), first person.
## With the lean-right key held, CDDA's peek opens on the square to the right of where the player faces: its request
## is held with no prompt shown and the snapshot is seen from that square (peeking_from, on a bridge that sends it,
## is the body's square). Letting go closes it: back on the body's square a turn or two later. With Alt held a move
## key never steps, though the same key without Alt does. Leaning toward a square a car blocks opens no peek, takes
## no turn and asks the game once only.
func _lean_live() -> void:
	var lp: Variant = _main.get("lean_peek")
	if lp == null or not InputMap.has_action(&"lean_right") or not _main._fp_active() or _main.view_mode != "first":
		print("  (no lean keys in this client, or not in first person: leaning not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var home: Vector3i = _main.world.snapshot.player_pos
	var turn0: int = _main.world.snapshot.turn
	var way: Vector2i = lp.WAYS[_main._octant(Vector2(1, 0))]
	var side := home + Vector3i(way.x, way.y, 0)
	Input.action_press(&"lean_right")
	var open := func() -> bool: return lp.peeking()
	var opened := await _until(open, OP_TIMEOUT_MS, false)
	var req := _live.request
	var from_there := func() -> bool: return _main.world.snapshot.player_pos == side and not _main.world.busy()
	var looked := opened and await _until(from_there, OP_TIMEOUT_MS, false)
	var body: Variant = _peeking_from()
	_check(opened and looked and req.get("kind") == "target" and req.get("mode") == "peek"
			and not _main.request_ui.is_showing() and (body == null or body == home),
			"lean: the lean-right key held opens CDDA's peek on the square to the right (%s from %s): no prompt shows, the view is from there (request %s %s; peeking_from %s; opened %s, seen from there %s, prompt showing %s)"
			% [side, home, req.get("kind", "none"), req.get("mode", ""), body, opened, looked, _main.request_ui.is_showing()])
	var draws_body: bool = "player_peeking_from" in _main.world.snapshot   # the client knows where the body is
	if opened and looked and draws_body:
		var side_w: Vector3 = _main.world.coords.ms_center_to_world(side)
		var home_w: Vector3 = _main.world.coords.ms_center_to_world(home)
		var over := func() -> bool: return _flat(_main.fp.base_position()).distance_to(_flat(side_w)) < 0.3
		var eyes_there := await _until(over, ASK_TIMEOUT_MS, false)
		var at: Vector3 = _main.player_body.position
		_check(eyes_there and _main.world.snapshot.get("player_peeking_from") == home
				and _flat(at).distance_to(_flat(home_w)) < 0.3 and _main.player_body.visible and _main.player_body.show_head,
				"lean: during the peek the body stands on its own square, head shown, and the eyes are over the peeked square (body %s, eyes %s, own square %s)"
				% [at, _main.fp.base_position(), home_w])
	Input.action_release(&"lean_right")
	var closed := func() -> bool: return not lp.peeking() and _main.world.snapshot.player_pos == home and in_loop.call()
	var back := await _until(closed, ASK_TIMEOUT_MS, false)
	if draws_body:
		var under := func() -> bool:
			return _flat(_main.player_body.position).distance_to(_flat(_main.fp.base_position())) < 0.3 \
					and not _main.player_body.show_head
		_check(back and await _until(under, ASK_TIMEOUT_MS, false),
				"lean: after the peek the body is back under the eyes, head hidden (body %s, eyes %s)"
				% [_main.player_body.position, _main.fp.base_position()])
	var took: int = _main.world.snapshot.turn - turn0
	_check(back and took >= 1 and took <= 3 and _peeking_from() == null,
			"lean: letting go closes the peek: back on %s, %d turns later (key down %s, leaning %s, peeking %s, request %s %s timed %s, peeking_from %s)"
			% [_main.world.snapshot.player_pos, took, Input.is_action_pressed(&"lean_right", true), lp.leaning(), lp.peeking(),
			_live.request.get("kind", "none"), _live.request.get("mode", ""), _live.request.get("timed", false), _peeking_from()])
	# Alt with a move key: no step; the same key alone: a step
	var alt := InputEventKey.new()
	alt.keycode = KEY_ALT
	alt.physical_keycode = KEY_ALT
	alt.pressed = true
	Input.parse_input_event(alt)
	Input.flush_buffered_events()
	var turn1: int = _main.world.snapshot.turn
	Input.action_press(&"move_right")
	await create_timer(0.8).timeout
	var stayed: bool = _main.world.snapshot.player_pos == home and _main.world.snapshot.turn == turn1 \
			and _live.queued_actions() == 0
	alt = alt.duplicate()
	alt.pressed = false
	Input.parse_input_event(alt)
	Input.flush_buffered_events()
	var moved := func() -> bool: return _main.world.snapshot.player_pos != home
	var stepped := await _until(moved, OP_TIMEOUT_MS, false)
	Input.action_release(&"move_right")
	_check(stayed and stepped, "lean: with Alt held a move key never steps (stayed: %s); the same key alone does (%s)"
			% [stayed, _main.world.snapshot.player_pos])
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	_live.cheat_teleport(home)
	await _until(func() -> bool: return _main.world.snapshot.player_pos == home and in_loop.call(), OP_TIMEOUT_MS, true)
	await _lean_blocked_live(lp, home)


## A lean toward a square a car blocks (the range's vehicle spawn; skipped, said so, without it): a car is spawned
## near `home`, the player is put on a free square beside one of its squares that block walking and turned so that
## square is on the right; with the lean-right key held 1.5 s no peek opens, no turn passes and the main loop asks at
## most once more (the refused peek isn't sent again). Then back to `home`.
func _lean_blocked_live(lp: Variant, home: Vector3i) -> void:
	if not _live.sim().has_method("range_spawn_vehicle"):
		print("  (no vehicle spawn in this bridge: a lean into something that blocks not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var before := {}
	for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
		before[veh.uid] = true
	var placed := false
	for d: Vector3i in [Vector3i(-18, 18, 0), Vector3i(22, 0, 0), Vector3i(0, 22, 0), Vector3i(-22, 0, 0), Vector3i(0, -22, 0)]:
		if placed:
			break
		var id: int = _live._range_op("range_spawn_vehicle", ["car", home + d, 0])
		var answered := func() -> bool: return _done.has(id)
		placed = id > 0 and await _until(answered, OP_TIMEOUT_MS, true) and _done[id] == ""
	var car_of := func() -> Snapshot.Vehicle:
		for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
			if not before.has(veh.uid):
				return veh
		return null
	var listed := func() -> bool: return car_of.call() != null and not _main.world.busy()
	if not placed or not await _until(listed, OP_TIMEOUT_MS, true):
		_check(false, "lean: a car to lean against is spawned near the player")
		return
	var car: Snapshot.Vehicle = car_of.call()
	var snap: Snapshot = _main.world.snapshot
	# a square of the car that blocks walking, a free square beside it, and the look that puts it on the right
	var stand := Vector3i.MAX
	var wall := Vector3i.MAX
	for i in car.part_count():
		var sq := car.square(i)
		if stand != Vector3i.MAX or not VehicleView.blocks(snap, _main.world.tables, sq):
			continue
		for d: Vector3i in [Vector3i(0, -2, 0), Vector3i(0, 2, 0), Vector3i(-2, 0, 0), Vector3i(2, 0, 0)]:
			var beside: Vector3i = sq + d / 2
			if stand == Vector3i.MAX and snap.vehicle_at(beside).is_empty() and snap.vehicle_at(sq + d).is_empty():
				stand = beside
				wall = sq
	var there := func() -> bool: return _main.world.snapshot.player_pos == stand and in_loop.call()
	var on_spot: bool = stand != Vector3i.MAX and _live.cheat_teleport(stand) > 0 and await _until(there, OP_TIMEOUT_MS, true)
	var faced := false
	for yaw: float in [0.0, PI / 2.0, PI, -PI / 2.0]:
		if on_spot and not faced:
			_main.fp.set_look(yaw, 0.0)
			var w: Vector2i = lp.WAYS[_main._octant(Vector2(1, 0))]
			faced = Vector3i(w.x, w.y, 0) == wall - stand
	if not on_spot or not faced:
		_check(false, "lean: the player stands beside a blocking square of the car, facing along it (stand %s, the car's square %s, player %s)"
				% [stand, wall, _main.world.snapshot.player_pos])
	else:
		await _until(in_loop, ASK_TIMEOUT_MS, true)
		var turn: int = _main.world.snapshot.turn
		var asked := {}
		var peeked := false
		Input.action_press(&"lean_right")
		var until := Time.get_ticks_msec() + 1500
		while Time.get_ticks_msec() < until:
			peeked = peeked or lp.peeking()
			if _live.request.get("timed", false):
				asked[int(_live.request.get("id", 0))] = true
			await create_timer(0.05).timeout
		Input.action_release(&"lean_right")
		_check(not peeked and _main.world.snapshot.turn == turn and asked.size() <= 2 and _main.world.snapshot.player_pos == stand,
				"lean: toward a square the car blocks no peek opens, no turn passes and the game is asked once more at most (%d main-loop requests in 1.5 s)"
				% asked.size())
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	_live.cheat_teleport(home)
	await _until(func() -> bool: return _main.world.snapshot.player_pos == home and in_loop.call(), OP_TIMEOUT_MS, true)


## Real time or turns in the running game (lead-ui's switch: the real-time key, the pause key, the F1 Time row and
## the HUD's time line; skipped, said so, on a client without them), with the monsters frozen. The game is in turns:
## nothing passes while the player does nothing. The real-time key turns real time on (saved in this run's hud.cfg,
## the F1 box follows): turns pass by themselves, about one a second, and in first person a step and a lean's peek
## still work. A new hostile in view pauses it: the HUD says so with the reason and the key, nothing passes, and the
## pause key goes on. With the F1 row's auto-pause off the next hostile pauses nothing. Then the player's own pause
## and the real-time key again: back in turns with the pause lifted, and a queued action takes its turn as before.
func _real_time_live() -> void:
	var km := _main.key_menu
	if not InputMap.has_action(&"real_time_toggle") or not InputMap.has_action(&"time_pause") \
			or not _live.has_method("set_real_time") or not "clock" in _main.hud_data \
			or not km.get("auto_pause_check") is CheckBox or not km.get("real_time_check") is CheckBox:
		print("  (no real-time switch in this client: not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var hud_line := func() -> String: return str(_main.hud_data.get("clock"))
	var turn_now := func() -> int: return _main.world.snapshot.turn
	var path: String = UserFiles.at(km.hud_path)
	var box := km.get("real_time_check") as CheckBox
	var ap := km.get("auto_pause_check") as CheckBox
	var toggle_key := InputActions.prompt_of(&"real_time_toggle")
	var pause_key := InputActions.prompt_of(&"time_pause")
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	if not _live.range_info().get("ai_frozen", false):
		_check(await _op(func() -> void: _cp.set_frozen(true), "Freeze") == "", "monsters frozen")
	var home: Vector3i = _main.world.snapshot.player_pos
	# turns first
	var t0: int = turn_now.call()
	await create_timer(2.5).timeout
	var waits := func() -> bool: return hud_line.call().contains("waits")
	_check(_live.clock().get("real_time") == false and _main.hud_settings.get("real_time") == false
			and turn_now.call() == t0 and await _until(waits, 3000, false),
			"time: the game is in turns: nothing passes in 2.5 s with no input, and the HUD says \"%s\"" % hud_line.call())
	# the real-time key
	root.push_input(_key_of(&"real_time_toggle"))
	var real := func() -> bool: return _live.clock().get("real_time") == true
	var on := await _until(real, ASK_TIMEOUT_MS, false)
	var t1: int = turn_now.call()
	var ms1 := Time.get_ticks_msec()
	var four := func() -> bool: return turn_now.call() >= t1 + 4
	var ran := await _until(four, 20000, false)
	var rate: float = (turn_now.call() - t1) * 1000.0 / maxf(Time.get_ticks_msec() - ms1, 1.0)
	var runs := func() -> bool: return hud_line.call().contains("runs")
	_check(on and _clock_saved(path, "real_time", true) and path.contains("test-runs") and box.button_pressed
			and ran and rate > 0.4 and rate < 2.5 and await _until(runs, 3000, false),
			"time: %s turns real time on: saved under [clock] in this run's hud.cfg, the F1 box ticked, turns pass by themselves (%.2f a second) and the HUD says \"%s\" (on %s, box %s; %s)"
			% [toggle_key, rate, hud_line.call(), on, box.button_pressed, path])
	# a step and a lean's peek while time runs
	var lp: Variant = _main.get("lean_peek")
	if lp == null or not InputMap.has_action(&"lean_right") or not _main._fp_active() or _main.view_mode != "first":
		print("  (no lean keys in this client, or not in first person: a step and a lean in real time not checked)")
	else:
		var stepped := false
		for act: StringName in [&"move_back", &"move_left", &"move_right"]:
			if stepped:
				break
			Input.action_press(act)
			var moved := func() -> bool: return _main.world.snapshot.player_pos != home
			stepped = await _until(moved, 4000, false)
			Input.action_release(act)
		await _until(in_loop, ASK_TIMEOUT_MS, true)
		_live.cheat_teleport(home)
		var at_home := func() -> bool: return _main.world.snapshot.player_pos == home and in_loop.call()
		await _until(at_home, OP_TIMEOUT_MS, true)
		var yaw0: float = _main.fp.yaw
		var pitch0: float = _main.fp.pitch
		var peeked := false
		var closed := false
		for yaw: float in [yaw0, yaw0 + PI / 2.0, yaw0 + PI, yaw0 - PI / 2.0]:   # a side that is free to peek from
			if peeked:
				break
			_main.fp.set_look(yaw, pitch0)
			await process_frame
			Input.action_press(&"lean_right")
			var open := func() -> bool: return lp.peeking()
			var away := func() -> bool: return _main.world.snapshot.player_pos != home and not _main.world.busy()
			peeked = await _until(open, 4000, false) and await _until(away, OP_TIMEOUT_MS, false)
			Input.action_release(&"lean_right")
			var shut := func() -> bool: return not lp.peeking() and at_home.call()
			closed = await _until(shut, ASK_TIMEOUT_MS, false)
		_main.fp.set_look(yaw0, pitch0)
		_check(stepped and peeked and closed and real.call(),
				"time: in real time a move key still steps and the lean key still opens CDDA's peek and closes it (stepped %s, peeked %s, closed %s; now %s)"
				% [stepped, peeked, closed, _main.world.snapshot.player_pos])
	# a new hostile in view pauses real time
	var spawned := await _spawn_hostile()
	var is_paused := func() -> bool: return _live.clock().get("paused") == true
	var stopped := spawned and await _until(is_paused, 15000, false)
	var why := str(_live.clock().get("pause_reason"))
	var says := func() -> bool: return hud_line.call().contains("PAUSED")
	var said := await _until(says, 3000, false)
	var line: String = hud_line.call()
	await create_timer(1.0).timeout
	var t2: int = turn_now.call()
	var queued := _live.queued_actions()
	Input.action_press(&"move_back")   # a step key during the pause (judged below, on a client that holds it back)
	await create_timer(0.3).timeout
	Input.action_release(&"move_back")
	queued = _live.queued_actions() - queued
	var pause_note := str(_main.grab.get("_flash"))
	await create_timer(2.2).timeout
	_check(ap.button_pressed and stopped and why == "hostile spotted" and said and line.contains(why)
			and line.contains(pause_key) and turn_now.call() == t2,
			"time: a zombie spawned in view pauses real time (\"%s\"): the HUD says \"%s\" and nothing passes in 2.5 s (spawned %s, paused %s)"
			% [why, line, spawned, stopped])
	var before_go: Vector3i = _main.world.snapshot.player_pos
	root.push_input(_key_of(&"time_pause"))
	var free := func() -> bool: return _live.clock().get("paused") == false
	var went := await _until(free, ASK_TIMEOUT_MS, false)
	var t3: int = turn_now.call()
	var two := func() -> bool: return turn_now.call() >= t3 + 2
	_check(went and await _until(two, 10000, false) and await _until(runs, 3000, false),
			"time: %s goes on: turns pass again and the HUD says \"%s\"" % [pause_key, hud_line.call()])
	if _main.has_method("_held_by_pause") and _main._fp_active():
		_check(queued == 0 and pause_note.contains("paused") and _main.world.snapshot.player_pos == before_go,
				"time: a move key tapped during the pause queues nothing (%d) and the screen says \"%s\"; after going on the player hasn't moved (%s, was on %s)"
				% [queued, pause_note, _main.world.snapshot.player_pos, before_go])
	else:
		print("    (a step key pressed during the pause: %d queued; after going on the player is on %s, was on %s)"
				% [queued, _main.world.snapshot.player_pos, before_go])
	# the F1 Time row: auto-pause off, and the next hostile pauses nothing
	var f1 := InputEventKey.new()
	f1.keycode = InputActions.MENU_KEY
	f1.physical_keycode = InputActions.MENU_KEY
	f1.pressed = true
	root.push_input(f1)
	var shown: bool = km.visible and ap.is_visible_in_tree() and box.is_visible_in_tree()
	ap.button_pressed = false   # as a click: toggled -> saved -> on the game
	var off_saved := _clock_saved(path, "auto_pause", false)
	root.push_input(_esc_key())
	var unarmed := func() -> bool: return not _live.auto_pause()
	var off := await _until(unarmed, ASK_TIMEOUT_MS, false)
	var more := await _spawn_hostile()
	var t4: int = turn_now.call()
	var four_more := func() -> bool: return turn_now.call() >= t4 + 4
	var on_past := more and await _until(four_more, 20000, false)
	_check(shown and off_saved and off and on_past and not is_paused.call(),
			"time: F1's Time row shows both boxes; with \"%s\" off (saved) another zombie in view pauses nothing: %d turns on (shown %s, spawned %s, paused %s)"
			% [ap.text, turn_now.call() - t4, shown, more, is_paused.call()])
	ap.button_pressed = true
	var armed := func() -> bool: return _live.auto_pause()
	_check(_clock_saved(path, "auto_pause", true) and await _until(armed, ASK_TIMEOUT_MS, false),
			"time: the box ticked again: auto-pause is back on (saved)")
	# the player's own pause, then back to turns
	root.push_input(_key_of(&"time_pause"))
	var own := await _until(is_paused, ASK_TIMEOUT_MS, false) and await _until(says, 3000, false)
	var own_line: String = hud_line.call()
	root.push_input(_key_of(&"real_time_toggle"))
	var turns_again := func() -> bool: return not real.call() and not is_paused.call()
	var back := await _until(turns_again, ASK_TIMEOUT_MS, false)
	await create_timer(1.0).timeout
	var t5: int = turn_now.call()
	await create_timer(2.5).timeout
	var still: bool = turn_now.call() == t5
	_live.queue_action("pause")
	var later := func() -> bool: return turn_now.call() > t5
	_check(own and back and _clock_saved(path, "real_time", false) and not box.button_pressed and still
			and await _until(later, OP_TIMEOUT_MS, true) and await _until(waits, 3000, false),
			"time: paused with %s (\"%s\"), then %s again: back in turns with the pause lifted (saved, the F1 box cleared); nothing passes by itself, a queued action takes its turn, and the HUD says \"%s\" (paused %s, back %s, still %s)"
			% [pause_key, own_line, toggle_key, hud_line.call(), own, back, still])
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	_live.cheat_teleport(home)
	await _until(func() -> bool: return _main.world.snapshot.player_pos == home and in_loop.call(), OP_TIMEOUT_MS, true)


## Small windows (lead-ui's layout; skipped, said so, on a client without it). The game's window is made 1280x720,
## then 800x450, and each time: the HUD's text along the top stays in the window and ends above the body bars and
## the feed (which stay in the window too), and a warning (put into HudData by hand: only its place is checked) sits
## under the text, in the window; the F1 menu fits the window, and its
## settings rows and its key list scroll to their last row; with Key help off (saved in this run's hud.cfg) the text
## is shorter and has the one short line; the Cheats page fits and scrolls to its last row; the inventory's list
## fits and its picked last row is in sight. Then the window is as it was.
func _small_window_live() -> void:
	var km := _main.key_menu
	var lt: Variant = load("res://tests/layout_tests.gd") if ResourceLoader.exists("res://tests/layout_tests.gd") else null
	var kh := km.get("key_help_check") as CheckBox
	var ss := km.get("_settings_scroll") as ScrollContainer
	var fit := _main.request_ui.get("_fit_box") as ScrollContainer
	if lt == null or kh == null or ss == null or fit == null or not "key_help" in _main.hud_settings:
		print("  (no small-window layout in this client: not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var hud: Label = _main.hud
	var hv := _main.hud_view
	var was: Vector2i = root.size
	var path: String = UserFiles.at(km.hud_path)
	var short := str((Main as Script).get_script_constant_map().get("KEY_HELP_SHORT", "?"))
	var f1 := InputEventKey.new()
	f1.keycode = InputActions.MENU_KEY
	f1.physical_keycode = InputActions.MENU_KEY
	f1.pressed = true
	for s: Vector2i in [Vector2i(1280, 720), Vector2i(800, 450)]:
		var tag := "%dx%d" % [s.x, s.y]
		root.size = s
		await _frames(4)
		await create_timer(0.6).timeout   # (a client may pick the text that fits only a few times a second)
		var win := Rect2(Vector2.ZERO, Vector2(s))
		if Vector2i(_main.get_viewport().get_visible_rect().size) != s:
			_check(false, "layout %s: the window takes that size (it is %s)" % [tag, _main.get_viewport().get_visible_rect().size])
			break
		# the text along the top, and a warning under it
		var lines := hud.get_line_count()
		var text_lines := hud.text.count("\n") + 1
		var r := hud.get_global_rect()
		var body := hv.get("_body") as Control
		var bars_y: float = body.global_position.y if body != null else -1.0
		var feed_y: float = hv.feed.global_position.y
		_check(win.grow(1.0).encloses(r) and lines >= text_lines and r.end.y <= minf(bars_y, feed_y) + 0.5
				and feed_y + 18.0 <= s.y,
				"layout %s: the HUD's text stays in the window and ends above the body bars and the feed, which stay in the window (%d lines on screen for %d of text, down to y %.0f; the bars from y %.0f, the feed from y %.0f)"
				% [tag, lines, text_lines, r.end.y, bars_y, feed_y])
		var keep: Array[Dictionary] = _main.hud_data.warnings
		var fake: Array[Dictionary] = [{"id": "layout", "text": "Layout check", "level": HudData.BAD}]
		_main.hud_data.warnings = fake
		_main.hud_data.changed.emit(PackedStringArray(["warnings"]))
		await _frames(3)
		var wy: float = hv.warn.global_position.y
		_check(hv.warn.text.contains("Layout check") and wy >= hud.get_global_rect().end.y and wy + 20.0 <= s.y,
				"layout %s: a warning sits under the wrapped text, in the window (the warning at y %.0f, the text down to y %.0f)"
				% [tag, wy, hud.get_global_rect().end.y])
		_main.hud_data.warnings = keep
		_main.hud_data.changed.emit(PackedStringArray(["warnings"]))
		# F1: the menu fits; its settings rows and its key list scroll to their ends
		root.push_input(f1)
		await _frames(4)
		var off: PackedStringArray = lt.outside(km, win)
		var rows_box := ss.get_child(0) as Control
		var last_row := rows_box.get_child(rows_box.get_child_count() - 1) as Control
		var last_key: Button = (km._buttons[InputActions.ACTIONS[-1][0]] as Array)[0]
		ss.scroll_vertical = int(rows_box.size.y)
		km._scroll.ensure_control_visible(last_key)
		await _frames(3)
		var row_seen: bool = ss.get_global_rect().grow(1.0).encloses(
				Rect2(last_row.global_position + Vector2(0.0, last_row.size.y - 4.0), Vector2(4.0, 4.0)))
		var key_seen: bool = km._scroll.get_global_rect().grow(1.0).encloses(last_key.get_global_rect())
		_check(km.visible and off.is_empty() and ss.size.y >= 60.0 and km._scroll.size.y >= 60.0 and row_seen and key_seen,
				"layout %s: F1 fits the window; its settings (%.0f px shown of %.0f) scroll to their last row and its keys (%.0f px shown) to the last key (outside the window: %s; row %s, key %s)"
				% [tag, ss.size.y, rows_box.size.y, km._scroll.size.y, off.slice(0, 3), row_seen, key_seen])
		# Key help off: one short line
		kh.button_pressed = false   # as a click: saved, and the text follows
		var off_saved := _cfg_bool(path, "hud", "key_help", false)
		root.push_input(_esc_key())
		await create_timer(0.6).timeout
		var short_lines := hud.get_line_count()
		var short_end := hud.get_global_rect().end.y
		var short_ok: bool = hud.text.contains(short) and short_lines <= lines and win.grow(1.0).encloses(hud.get_global_rect())
		kh.button_pressed = true
		await create_timer(0.6).timeout   # (a client may pick the text that fits a few times a second)
		_check(not km.visible and off_saved and short_ok and _cfg_bool(path, "hud", "key_help", true)
				and hud.get_line_count() >= short_lines,
				"layout %s: Key help off (saved under [hud]) leaves the one short line: %d lines down to y %.0f, %d with it on; on again (saved): as before (%d lines)"
				% [tag, short_lines, short_end, lines, hud.get_line_count()])
		# the Cheats page
		root.push_input(f1)
		await _frames(2)
		km.show_cheats(true)
		await _frames(4)
		var off2: PackedStringArray = lt.outside(km, win)
		km.cheat_scroll.ensure_control_visible(_cp.monster_id)
		await _frames(3)
		var cheat_seen: bool = km.cheat_scroll.get_global_rect().grow(1.0).encloses(_cp.monster_id.get_global_rect())
		_check(km.showing_cheats() and off2.is_empty() and km.cheat_scroll.size.y >= 60.0 and cheat_seen,
				"layout %s: the Cheats page fits the window and scrolls to its last row (%.0f px shown; outside the window: %s; row %s)"
				% [tag, km.cheat_scroll.size.y, off2.slice(0, 3), cheat_seen])
		km.show_cheats(false)
		root.push_input(_esc_key())
		await _frames(2)
		if km.visible:
			km.close()
		# a long list prompt: the picked row stays in sight
		await _until(in_loop, ASK_TIMEOUT_MS, true)
		root.push_input(_key_of(&"cdda_inventory"))
		var listed := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
		if await _until(listed, ASK_TIMEOUT_MS, false):
			var w := _main.request_ui.widget as ListRequestWidget
			w.select(w.rows.size() - 1)
			await _frames(4)
			var pr: Rect2 = w.rows[w.selected].get_global_rect() if w.selected >= 0 else Rect2()
			var inner := w.get("_scroll") as ScrollContainer
			var off3: PackedStringArray = lt.outside(_main.request_ui, win)
			var in_sight: bool = pr.has_area() and win.encloses(pr) and fit.get_global_rect().grow(1.0).encloses(pr) \
					and (inner == null or inner.get_global_rect().grow(1.0).encloses(pr))
			_check(off3.is_empty() and in_sight,
					"layout %s: the inventory's list (%d rows) fits the window and its picked last row is in sight (the row %s, the panel's box %s; outside the window: %s)"
					% [tag, w.rows.size(), pr, fit.get_global_rect(), off3.slice(0, 3)])
		else:
			_check(false, "layout %s: the inventory opens as a list" % tag)
		var esc := 0
		while not in_loop.call() and esc < MAX_ESC:
			root.push_input(_esc_key())
			esc += 1
			await _until(in_loop, 3000, false)
	root.size = was
	await _frames(4)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Whether the settings file at `path` has [section] `key` saved as the bool `want`.
func _cfg_bool(path: String, section: String, key: String, want: bool) -> bool:
	var cfg := ConfigFile.new()
	var v: Variant = cfg.get_value(section, key, null) if cfg.load(path) == OK else null
	return v is bool and v == want


## A zombie on a free square three squares from the player; false when none of eight squares took one.
func _spawn_hostile() -> bool:
	var here: Vector3i = _main.world.snapshot.player_pos
	for d: Vector3i in [Vector3i(3, 0, 0), Vector3i(-3, 0, 0), Vector3i(0, 3, 0), Vector3i(0, -3, 0), Vector3i(3, 3, 0),
			Vector3i(-3, -3, 0), Vector3i(3, -3, 0), Vector3i(-3, 3, 0)]:
		var id := _live.range_spawn_monster("mon_zombie", here + d)
		var answered := func() -> bool: return _done.has(id)
		if id > 0 and await _until(answered, OP_TIMEOUT_MS, true) and _done[id] == "":
			return true
	return false


## Whether the HUD settings file at `path` has [clock] `key` saved as the bool `want`.
func _clock_saved(path: String, key: String, want: bool) -> bool:
	var cfg := ConfigFile.new()
	var v: Variant = cfg.get_value("clock", key, null) if cfg.load(path) == OK else null
	return v is bool and v == want


## A world position seen from above (x, z).
func _flat(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## `player.peeking_from` of the bridge's newest snapshot (the body's square during CDDA's peek), null when it isn't
## there.
func _peeking_from() -> Variant:
	var d: Variant = JSON.parse_string(_live.sim().get_snapshot_json(0, 0))
	var p: Variant = (d as Dictionary).get("player") if d is Dictionary else null
	var v: Variant = (p as Dictionary).get("peeking_from") if p is Dictionary else null
	return Vector3i(int(v[0]), int(v[1]), int(v[2])) if v is Array and (v as Array).size() == 3 else null


## The screen HUD (main's HudView) in the live game: body bars, needs and the move line from CDDA's snapshot, and
## the message feed from its events (the keys above made CDDA say "nothing ... nearby").
func _hud_live() -> void:
	var v := _main.hud_view
	var rows := v.body_rows()
	var fracs := not rows.is_empty()
	for r: Array in rows:
		fracs = fracs and float(r[1]) >= 0.0 and float(r[1]) <= 1.0
	_check(rows.size() >= 6 and fracs, "HUD: %d body bars from the live game (%s ...)" % [rows.size(), rows.slice(0, 2)])
	_check(not v.need_lines().is_empty() and not v.move_line().is_empty(),
			"HUD: needs and the move line (%s; %s)" % [", ".join(v.need_lines()), v.move_line()])
	var said := false
	for m: Dictionary in _main.hud_data.messages:
		said = said or str(m["text"]).contains("nothing that can be examined")
	var feed := v.feed.text.split("\n")
	var last: String = _main.hud_data.messages.back()["text"] if not _main.hud_data.messages.is_empty() else ""
	_check(said and not last.is_empty() and feed[feed.size() - 1] == last,
			"HUD: CDDA's messages reach the feed, newest last (\"%s\")" % last)


## F3 in the live game: the classic view shows CDDA's symbols around the player, @ in the middle; F3 hides it.
func _classic_live() -> void:
	var v := _main.classic
	root.push_input(_key_of(&"classic_view"))
	var lines := v.text().split("\n")
	var mid := lines[ClassicView.RY].substr(ClassicView.RX, 1) if lines.size() > ClassicView.RY else ""
	var drawn := 0
	for l in lines:
		drawn += l.length() - l.count(" ")
	_check(v.visible and mid == "@" and drawn > 100, "F3: CDDA's classic view, @ in the middle, %d squares drawn" % drawn)
	print("    " + "\n    ".join(lines.slice(ClassicView.RY - 4, ClassicView.RY + 5)))
	root.push_input(_key_of(&"classic_view"))
	_check(not v.visible, "F3 again hides it")


## The compass in the live game: a zombie spawned two squares ahead (by name, through the Cheats page's picker; at
## noon, monsters frozen) shows as a hostile marker near the middle of the strip, close by.
func _compass_live() -> void:
	var c := _main.compass
	if not _live.range_info().get("ai_frozen", false):
		_check(await _op(func() -> void: _cp.set_frozen(true), "Freeze") == "", "monsters frozen")
	_cp.hour.value = 12
	_check(await _op(_cp.set_time, "Time 12:00") == "", "time set to noon")
	var hostiles := func() -> int: return c.blips.filter(func(b: Vector3) -> bool: return int(b.z) == Snapshot.Creature.HOSTILE).size()
	var before: int = hostiles.call()
	_cp.monster_id.text = "zombie"
	_check(await _op(_cp.spawn_monster, "Spawn mon_zombie") == "", "a zombie spawned ahead (picked: %s)"
			% (_cp.monster_pick.get_item_text(_cp.monster_pick.selected) if _cp.monster_pick.selected >= 0 else "none"))
	var more := func() -> bool: return hostiles.call() > before
	var seen := await _until(more, OP_TIMEOUT_MS, true)
	var b: Vector3 = c.blips[0] if not c.blips.is_empty() else Vector3(0, INF, -1)   # hostiles come first, nearest first
	var at := Compass.strip_pos(b.x, c.heading_deg)
	_check(seen and int(b.z) == Snapshot.Creature.HOSTILE and absf(at) < 0.3 and b.y < 4.0,
			"compass: the zombie ahead is a hostile marker near the strip's middle (%.2f of half the strip, %.1f m away, heading %.0f)"
			% [at, b.y, c.heading_deg])
	if not _main.first_person:
		print("  (compass turn not tried: not in first person)")
		return
	var fp := _main.fp
	var yaw0 := fp.yaw
	var h0 := c.heading_deg
	fp.set_look(yaw0 - PI / 2.0, fp.pitch)   # a quarter turn right: the zombie is now to the left
	await process_frame
	await process_frame
	var b2: Vector3 = c.blips[0] if not c.blips.is_empty() else Vector3(0, INF, -1)
	var at2 := Compass.strip_pos(b2.x, c.heading_deg)
	_check(absf(wrapf(c.heading_deg - h0, -180.0, 180.0) - 90.0) < 1.0 and absf(at2 - (at - 1.0)) < 0.05,
			"compass: a quarter turn right turns the heading 90 and moves the zombie to the strip's left end (%.2f)" % at2)
	fp.set_look(yaw0, fp.pitch)


## Gun mods by hand in the running game, through ItemActions and the bridge's mod_add / mod_remove: the kit's
## pistol goes into the main hand, a GUN_MOD spawned at the feet is taken and the snapshot judges it
## (wielded_gun.fits). When it fits it is fitted (wielded_gun.mods lists it) and taken off again (back among the
## carried items); when it doesn't (the range's character has no gun skills), mod_add is refused in CDDA's words and
## the mod stays carried. Skipped, said so, on a client or a bridge without them.
func _gun_mods_live() -> void:
	var acts: ItemActions = _main.item_actions
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	if not acts.has_method("mod_add") or not _live.has_method("mod_add_item"):
		print("  (no gun mod actions in this client: not checked)")
		return
	var gun_t := _cp.tables.index_of("itype", GUN)
	var mod_t := _cp.tables.index_of("itype", GUN_MOD)
	var gun := _carried(gun_t)
	if gun_t < 0 or mod_t < 0 or gun == null:
		_check(false, "gun mods: the kit's %s is carried and %s is an item type (%d, %d)" % [GUN, GUN_MOD, gun_t, mod_t])
		return
	if not gun.is_wielded():
		acts.hold(gun, "main")
	var in_hand := func() -> bool:
		var g := _carried(gun_t)
		return g != null and g.is_wielded() and acts.pending(g.uid) == ""
	_check(await _until(in_hand, OP_TIMEOUT_MS, true), "gun mods: the %s is in the main hand" % GUN)
	if not in_hand.call():
		return
	if not _main.world.snapshot.player_gun.has("fits"):
		print("  (this bridge sends no wielded_gun.fits: gun mods not checked)")
		return
	_cp.item_id.text = GUN_MOD
	_cp.item_count.value = 1
	var spawned := await _op(_cp.spawn_item, "Spawn " + GUN_MOD)
	var lies := func() -> bool: return _lying(mod_t) != null
	_check(spawned == "" and await _until(lies, OP_TIMEOUT_MS, true), "gun mods: a %s lies at the feet (%s)" % [GUN_MOD, spawned])
	if _lying(mod_t) == null:
		return
	acts.take(_lying(mod_t), "pack")
	var taken := func() -> bool:
		var m := _carried(mod_t)
		return m != null and acts.pending(m.uid) == "" and not _fit_of(m.uid).is_empty()
	var has := await _until(taken, OP_TIMEOUT_MS, true)
	var mod := _carried(mod_t)
	var fit := _fit_of(mod.uid) if mod != null else {}
	_check(has and fit.get("ok") is bool, "gun mods: taken, and the snapshot judges it against the %s (%s)" % [GUN, fit])
	if not has or not fit.get("ok") is bool:
		return
	if fit["ok"] != true:   # the range's character lacks the skills: CDDA's refusal, through the client
		var said := []
		var on_refused := func(item: ItemRef, op: String, reason: String) -> void:
			if item != null and item.uid == mod.uid:
				said.append([op, reason])
		acts.refused.connect(on_refused)
		var asked := acts.mod_add(mod, _carried(gun_t))
		var answered := func() -> bool: return not said.is_empty()
		var refused: bool = asked and await _until(answered, OP_TIMEOUT_MS, true)
		acts.refused.disconnect(on_refused)
		var why: String = str(said[0][1]) if refused else ""
		_check(refused and said[0][0] == "mod_add" and why.contains(str(fit.get("reason", "?")))
				and _carried(mod_t) != null and ItemActions.gun_has_mod(_main.world.snapshot, mod.uid) == false,
				"gun mods: one that doesn't fit is refused in CDDA's words and stays carried (\"%s\")" % why)
		await _fit_key_live(mod_t, str(fit.get("reason", "")))
		print("  (the %s doesn't fit here, so fitting and taking off weren't tried)" % GUN_MOD)
		return
	if int(fit.get("chance", 0)) < 100:   # CDDA would ask for tools: a menu this check doesn't answer
		print("  (the %s goes on with %d%% only: fitting not tried)" % [GUN_MOD, fit.get("chance", 0)])
		return
	var turn0: int = _main.world.snapshot.turn
	var sent := acts.mod_add(mod, _carried(gun_t))
	var on := func() -> bool:
		return ItemActions.gun_has_mod(_main.world.snapshot, mod.uid) == true and acts.pending(mod.uid) == ""
	var fitted := sent and await _until(on, OP_TIMEOUT_MS, true)
	_check(fitted, "gun mods: mod_add fits it: the gun's mods list it (%d turns; %s)" % [_main.world.snapshot.turn - turn0,
			_main.world.snapshot.player_gun.get("mods")])
	if not fitted:
		return
	turn0 = _main.world.snapshot.turn
	sent = acts.mod_remove(mod.uid, mod.type, _carried(gun_t))
	var off := func() -> bool:
		var m := _carried(mod_t)
		return ItemActions.gun_has_mod(_main.world.snapshot, mod.uid) == false and acts.pending(mod.uid) == "" \
				and m != null and m.uid == mod.uid
	_check(sent and await _until(off, OP_TIMEOUT_MS, true),
			"gun mods: mod_remove takes it off: carried again with its handle (%d turns)" % [_main.world.snapshot.turn - turn0])


## The flat screen's key for it (lead-ui's F1; skipped on a client without main._fit_held_mod): with the gun in the
## main hand and the gunmod of itype `mod_t` in the off hand, the crosshair line offers to fit it, and E on one the
## snapshot says doesn't fit shows CDDA's `reason` by the crosshair and sends nothing.
func _fit_key_live(mod_t: int, reason: String) -> void:
	if not _main.has_method("_fit_held_mod"):
		print("  (no key for fitting a gun mod in this client: not checked)")
		return
	var acts: ItemActions = _main.item_actions
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var mod := _carried(mod_t)
	if mod == null or not acts.hold(mod, "off"):
		_check(false, "gun mods: the gunmod goes into the off hand (%s)" % ["sent" if mod != null else "not carried"])
		return
	var in_off := func() -> bool:
		var h: Variant = _main.hud_data.held.get("off")
		return h is ItemRef and (h as ItemRef).type == mod_t and acts.pending((h as ItemRef).uid) == "" and in_loop.call()
	var held := await _until(in_off, OP_TIMEOUT_MS, true)
	var line: String = _main._context_line()
	_check(held and line.contains("fit the"), "gun mods: gun and gunmod in hand, the crosshair line offers to fit it (\"%s\")" % line)
	if not held:
		return
	_main.grab._flash = ""
	root.push_input(_key_of(&"use_held"))
	await create_timer(0.3).timeout
	var said: String = _main.grab._flash
	var uid: int = (_main.hud_data.held.get("off") as ItemRef).uid
	_check(not reason.is_empty() and said.contains(reason) and acts.pending(uid) == "" and _carried(mod_t) != null,
			"gun mods: E on one that doesn't fit says why by the crosshair and sends nothing (\"%s\")" % said)
	root.push_input(_key_of(&"stow_off"))   # the hands as they were
	await _until(func() -> bool: return _main.hud_data.held.get("off") == null and in_loop.call(), OP_TIMEOUT_MS, true)


## A bench vise on the flat screen in the running game (lead-ui's ViseBench, main.vise_bench; skipped on a client
## without it): with the gun wielded and a bench_vise spawned at the feet, the pointer on the vise offers to clamp
## the gun, E does it (the panel lists the carried gunmods CDDA judged), Esc takes the gun back, E clamps and E on
## the vise again releases, and stepping away (the teleport cheat) releases it with a line. The pointer is put on the
## vise by setting the hover the frame would find (aiming the camera isn't this check's subject).
func _vise_live() -> void:
	var bench: Variant = _main.get("vise_bench")
	if bench == null:
		print("  (no bench vise panel in this client: not checked)")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var gun_t := _cp.tables.index_of("itype", GUN)
	var vise_t := _cp.tables.index_of("itype", VISE)
	var gun := _carried(gun_t)
	if gun == null or not gun.is_wielded() or vise_t <= 0:
		print("  (no wielded %s, or no %s in the game data: the vise not checked)" % [GUN, VISE])
		return
	_cp.item_id.text = VISE
	_cp.item_count.value = 1
	var spawned := await _op(_cp.spawn_item, "Spawn " + VISE)
	var lies := func() -> bool:
		var v := _lying(vise_t)
		return v != null and v.uid in Vise.near(_main.world.snapshot, _main.world.tables) and in_loop.call()
	_check(spawned == "" and await _until(lies, OP_TIMEOUT_MS, true), "vise: a %s lies in reach (%s)" % [VISE, spawned])
	if not lies.call():
		return
	var hover := {"kind": "item", "item": _lying(vise_t)}
	_main.grab.item_hover = hover
	var line: String = _main._context_line()
	_main.grab.item_hover = hover
	root.push_input(_key_of(&"use_held"))
	var shown: bool = bench.clamped() and bench.visible
	var fits: Array = bench.entries(_main.world.snapshot, _main.world.tables, _main.item_actions, _carried(gun_t)).get("fits", []) \
			if shown else []
	_check(line.contains("clamp the gun") and shown and not fits.is_empty(),
			"vise: the pointer on it offers \"%s\"; E clamps the gun and the panel lists %d carried gunmod(s) (drawn in the jaws: %s)"
			% [line, fits.size(), bench.model != null])
	if not shown:
		return
	await _vise_fit_live(bench, gun_t, vise_t)
	root.push_input(_esc_key())
	await create_timer(0.1).timeout
	_check(not bench.clamped() and not _main.key_menu.visible, "vise: Esc takes the gun back, no menu")
	_main.grab.item_hover = hover
	root.push_input(_key_of(&"use_held"))
	var again: bool = bench.clamped()
	_main.grab.item_hover = hover
	var line2: String = _main._context_line()
	_main.grab.item_hover = hover
	root.push_input(_key_of(&"use_held"))
	_check(again and line2.contains("take the gun back") and not bench.clamped(),
			"vise: E clamps again, the line then offers \"%s\", and E on the vise takes the gun back" % line2)
	_main.grab.item_hover = hover
	root.push_input(_key_of(&"use_held"))
	var here: Vector3i = _main.world.snapshot.player_pos
	_main.grab._flash = ""
	var away: int = _live.cheat_teleport(here + Vector3i(4, 0, 0)) if bench.clamped() else 0
	var gone := func() -> bool: return not bench.clamped()
	var left: bool = away > 0 and await _until(gone, OP_TIMEOUT_MS, true)
	_check(left and str(_main.grab._flash).contains("vise"),
			"vise: stepping away takes the gun back with a line (\"%s\")" % _main.grab._flash)
	_live.cheat_teleport(here)
	await _until(func() -> bool: return _main.world.snapshot.player_pos == here and in_loop.call(), OP_TIMEOUT_MS, true)


## A fit with the gun clamped in the vise `bench` holds (V3: mod_add names the vise; skipped, said so, where
## ItemActions.mod_add takes none or no gunmod is carried). The range's character lacks the skills for every mod the
## gun takes, so: Fit on the panel says CDDA's reason and sends nothing; the action itself with the vise named is
## taken by the bridge and refused by CDDA in the same words; half a vise handle, or the mod as the vise, is refused
## in the client. A mod that fits here isn't tried.
func _vise_fit_live(bench: Variant, gun_t: int, vise_t: int) -> void:
	var acts: ItemActions = _main.item_actions
	var takes_vise := false
	for m: Dictionary in acts.get_method_list():
		if m["name"] == "mod_add":
			takes_vise = (m["args"] as Array).size() >= 4
	var mod := _carried(_cp.tables.index_of("itype", GUN_MOD))
	var gun := _carried(gun_t)
	if not takes_vise or mod == null or gun == null:
		print("  (mod_add takes no vise in this client, or no %s is carried: a fit in the vise not checked)" % GUN_MOD)
		return
	var fit := _fit_of(mod.uid)
	if fit.get("ok") != false:
		print("  (the %s fits here: a fit in the vise not tried; %s)" % [GUN_MOD, fit])
		return
	var reason := str(fit.get("reason", "?"))
	var before := acts.pending_count()
	bench.fit_mod(mod.uid)   # the panel's Fit
	_check(str(bench.status).contains(reason) and acts.pending_count() == before,
			"vise: Fit on the panel says why the mod doesn't fit and sends nothing (\"%s\")" % bench.status)
	var heard := []
	var on_refused := func(item: ItemRef, op: String, why: String) -> void:
		if item != null and item.uid == mod.uid:
			heard.append([op, why])
	acts.refused.connect(on_refused)
	var sent: bool = acts.call("mod_add", mod, gun, int(bench.vise_uid), vise_t) == true
	var answered := func() -> bool: return not heard.is_empty()
	var got: bool = sent and await _until(answered, OP_TIMEOUT_MS, true)
	acts.refused.disconnect(on_refused)
	var half: bool = acts.call("mod_add", mod, gun, int(bench.vise_uid), 0) == false \
			and acts.call("mod_add", mod, gun, mod.uid, vise_t) == false
	_check(got and heard[0][0] == "mod_add" and str(heard[0][1]).contains(reason) and half and bench.clamped(),
			"vise: mod_add naming the vise is taken by the bridge and judged by CDDA (\"%s\"; sent %s); half a handle or the mod as the vise isn't sent (%s)"
			% [heard[0][1] if got else "", sent, half])
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)


## First aid on a named body part through the client (the bridge's consume `part`, ItemActions.consume(item, part));
## skipped, said so, on a client without it or a bridge that sends no `heal` bits. A bandage is spawned and taken.
## The range's character is unhurt, so with a part named CDDA refuses in its own words and asks nothing; with none
## CDDA's own menu comes as a request, as before (cancelled here); a part that isn't one is refused in the client.
func _first_aid_live() -> void:
	var acts: ItemActions = _main.item_actions
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var parts: Variant = (ItemActions as Script).get_script_constant_map().get("PARTS")
	var t := _cp.tables.index_of("itype", AID)
	var def: IdTables.Def = _cp.tables.def_at("itype", t) if t >= 0 else null
	var heal: Variant = def.get("heal") if def != null else null
	if not parts is Array or not "arm_l" in parts or not heal is int or int(heal) == 0:
		print("  (no first aid on a body part in this client, or no heal bits from this bridge: not checked; parts %s, heal %s)"
				% [parts, heal])
		return
	_cp.item_id.text = AID
	_cp.item_count.value = 1
	var spawned := await _op(_cp.spawn_item, "Spawn " + AID)
	var lies := func() -> bool: return _lying(t) != null
	if spawned != "" or not await _until(lies, OP_TIMEOUT_MS, true):
		_check(false, "first aid: %s lie at the feet (%s)" % [AID, spawned])
		return
	acts.take(_lying(t), "pack")
	var taken := func() -> bool:
		var b := _carried(t)
		return b != null and acts.pending(b.uid) == "" and in_loop.call()
	var has := await _until(taken, OP_TIMEOUT_MS, true)
	var aid := _carried(t)
	_check(has and aid != null, "first aid: %s taken; the id tables say what they treat (heal bits %d)" % [AID, heal])
	if aid == null:
		return
	var said := []    # [what, op, reason]: how each consume of the bandage ended
	var on_done := func(it: ItemRef, op: String) -> void:
		if it != null and it.uid == aid.uid:
			said.append(["finished", op, ""])
	var on_refused := func(it: ItemRef, op: String, why: String) -> void:
		if it != null and it.uid == aid.uid:
			said.append(["refused", op, why])
	acts.finished.connect(on_done)
	acts.refused.connect(on_refused)
	# a part named: no question from the game, its refusal in its own words
	var asked := []   # ids of what the game asked meanwhile (not the main loop's request)
	var ended := func() -> bool:
		var r := _live.request
		if not r.is_empty() and not r.get("timed", false) and not int(r.get("id", 0)) in asked:
			asked.append(int(r.get("id", 0)))
		return not said.is_empty() or not asked.is_empty()
	var sent: bool = acts.call("consume", aid, "arm_l") == true
	var got: bool = sent and await _until(ended, OP_TIMEOUT_MS, false) and not said.is_empty()
	var why: String = said[0][2] if got else ""
	_check(got and said[0][0] == "refused" and said[0][1] == "consume" and why.contains("expect any effect")
			and asked.is_empty() and _carried(t) != null,
			"first aid: a bandage on the unhurt left arm is refused in CDDA's words, and the game asks nothing (\"%s\"; sent %s, %d questions, %s)"
			% [why, sent, asked.size(), said])
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	# no part named: CDDA's own body part menu, as before
	said.clear()
	var menu := func() -> bool: return not _live.request.is_empty() and not _live.request.get("timed", false)
	var came: bool = acts.consume(aid) and await _until(menu, OP_TIMEOUT_MS, false)
	var req := _live.request
	var text := (str(req.get("title", "")) + " " + str(req.get("text", ""))).strip_edges().left(80).replace("\n", " ")
	_check(came, "first aid: with no part named CDDA's own menu comes (%s \"%s\")" % [req.get("kind", "none"), text])
	if came:
		_answered = int(req.get("id", 0))
		_live.answer({"id": _answered, "cancel": true})
	var over := func() -> bool: return acts.pending(aid.uid) == "" and in_loop.call()
	_check(await _until(over, OP_TIMEOUT_MS, true) and _carried(t) != null,
			"first aid: the menu cancelled, the bandage is still carried (%s)" % [said])
	# a part that isn't one: refused here, nothing sent
	var before := acts.pending_count()
	_check(acts.call("consume", aid, "tail") == false and acts.call("consume", aid, "arm l") == false
			and acts.pending_count() == before, "first aid: a part that isn't one is refused in the client, nothing sent")
	acts.finished.disconnect(on_done)
	acts.refused.disconnect(on_refused)


## The first carried item of itype `t`, null for none.
func _carried(t: int) -> ItemRef:
	for r in _main.hands.picker.carried():
		if r.type == t:
			return r
	return null


## An item of itype `t` lying in reach, as the Tab view's "nearby" column lists it; null for none.
func _lying(t: int) -> ItemRef:
	for col: Dictionary in InventoryModel.columns(_main.hands.picker, _main.world.tables, _main.item_actions):
		if col["kind"] != "nearby":
			continue
		for g: Dictionary in col["groups"]:
			for row: Dictionary in g["rows"]:
				if (row["item"] as ItemRef).type == t:
					return row["item"]
	return null


## The snapshot's verdict on carried gunmod `uid` against the wielded gun (wielded_gun.fits), {} when not listed.
func _fit_of(uid: int) -> Dictionary:
	var fits: Variant = _main.world.snapshot.player_gun.get("fits")
	if fits is Array:
		for f: Variant in fits:
			if f is Dictionary and (f as Dictionary).get("uid") == uid:
				return f
	return {}


## Esc in the running game (main.back_out, lead-ui's BackOut): with a look showing and the Tab view over it, each
## press backs out of the topmost thing only; the F1 menu opens once nothing is left and Esc closes it again; the
## game is in its main loop after it all. Skipped on a client without back_out.
func _esc_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	var bo: Variant = _main.get("back_out")
	if bo == null:
		print("  (no contextual Esc in this client: its steps not checked)")
		return
	if _main.key_menu.visible:
		_main.key_menu.close()
	var look := _key_of(&"look_at")
	if look != null:
		root.push_input(look)
	root.push_input(_key_of(&"inspect"))
	var up: PackedStringArray = bo.open_now()
	_check(up.has("inventory"), "Esc: the Tab view is up%s (open: %s)" % [" over a look" if up.has("look") else "", up])
	var went := []          # what was open before each press
	var in_order := true    # each press took the topmost thing (or a part of it), nothing under it
	var menu_early := false
	for i in 8:
		var before: PackedStringArray = bo.open_now()
		if before.is_empty():
			break
		went.append(before)
		root.push_input(_esc_key())
		await create_timer(0.1).timeout
		var after: PackedStringArray = bo.open_now()
		in_order = in_order and (after == before or after == before.slice(1))
		menu_early = menu_early or _main.key_menu.visible
	_check((bo.open_now() as PackedStringArray).is_empty() and in_order and not menu_early,
			"Esc: one thing backed out per press, topmost first, no menu meanwhile (%s)" % [went])
	root.push_input(_esc_key())
	await create_timer(0.1).timeout
	var menu_up: bool = _main.key_menu.visible
	root.push_input(_esc_key())
	await create_timer(0.1).timeout
	_check(menu_up and not _main.key_menu.visible, "Esc with nothing open shows the F1 menu; Esc again closes it")
	_check(await _until(in_loop, ASK_TIMEOUT_MS, true) and _live.state == "running",
			"Esc: the game is still running, in its main loop (%s)" % _live.state)


## G4: P shows the character screen with the live game's body and needs; Esc closes it.
func _character_live() -> void:
	var v := _main.character
	root.push_input(_key_of(&"character"))
	var t := v.text()
	var body: Dictionary = _main.character_data.card("body")
	_check(v.visible and t.find("[Body]") >= 0 and t.find("[Needs]") >= 0 and (body.get("rows", []) as Array).size() >= 6,
			"P: the character screen, %d body parts" % (body.get("rows", []) as Array).size())
	var worn: Array = _main.character_data.card("worn").get("rows", [])
	var parts: Array = _main.character_data.card("worn_parts").get("rows", [])
	var covered := parts.filter(func(r: Dictionary) -> bool: return r["value"] != "bare").size()
	_check(worn.size() >= 1 and parts.size() >= 6 and covered >= 3 and t.find("[Worn]") >= 0 and t.find("[Worn by body part]") >= 0,
			"P: what the character wears (%d items) and the layers on %d body parts, %d covered" % [worn.size(), parts.size(), covered])
	print("    " + "\n    ".join(t.split("\n").slice(0, 12)))
	var at := t.find("[Worn]")
	print("    " + "\n    ".join(t.substr(at if at >= 0 else 0).split("\n").slice(0, 14)))
	# G4: the game's character sheet (bridge query_character), asked when the screen opens
	if _live._sim.has_method("query_character"):
		var cd := _main.character_data
		var came: bool = await _until(func() -> bool: return cd.has_sheet(), ASK_TIMEOUT_MS, false)
		var stats: Array = cd.card("stats").get("rows", [])
		var skills: Array = cd.card("skills").get("rows", [])
		_check(came and stats.size() == 5 and skills.size() >= 10 and cd.title != "Character" and not cd.subtitle.is_empty()
				and cd.note.is_empty() and v.text().find("[Skills]") >= 0,
				"P: the game's sheet: %s (%s), %d stats, %d skills, %d traits" % [cd.title, cd.subtitle, stats.size(),
				skills.size(), (cd.card("traits").get("rows", []) as Array).size()])
		var carry := cd.carry
		_check(carry["weight_g"] >= 0 and carry["weight_max_g"] > 0 and carry["volume_ml"] >= 0
				and carry["volume_max_ml"] > 0 and v.text().find("[Carrying]") >= 0,
				"P: what the character carries and can carry, from the sheet (%s)" % [carry])
		print("    " + "\n    ".join(v.text().substr(maxi(0, v.text().find("[Stats]"))).split("\n").slice(0, 8)))
	else:
		print("    (this DLL has no query_character: the sheet's cards not checked)")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	_check(not v.visible, "Esc closes it")
	if _main.character_data.carry["weight_max_g"] > 0:   # G2: the Tab view's top line shows the same numbers
		root.push_input(_key_of(&"inspect"))
		var box := _main.inspect.find_child("Carry", true, false) as Control
		_check(_main.inspect.visible and box != null and box.visible and box.get_child_count() == 2,
				"Tab: carried weight and volume bars in the top line")
		root.push_input(esc)
		_check(not _main.inspect.visible, "Esc closes the Tab view")


## The off hand in the live game: H asks which item to hold and one is picked as a player would (typed into the
## list's filter, Enter): water when the kit's pours (else a knife), poured out by holding E; Shift+H puts it away.
## The hands (HudData.held, from the bridge's held state) follow each step.
func _hands_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"hold_off"))
	var asked := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if not await _until(asked, ASK_TIMEOUT_MS, false):
		_check(false, "H: CDDA asks which item to hold (%s)" % [_live.request])
		return
	var w := _main.request_ui.widget as ListRequestWidget
	var pick := ""   # a liquid that pours (the kit's water may be frozen or sealed), else a knife
	for want: String in ["water", "knife"]:
		for it: Dictionary in w.items:
			var n := str(it.get("plain", ""))
			var ok: bool = it.get("enabled", false) and not n.contains("frozen") and not n.contains("sealed")
			if pick.is_empty() and ok and n.to_lower().contains(want):
				pick = n
	_check(not pick.is_empty(), "H: the hold list has something to hold (%d entries)" % w.items.size())
	if pick.is_empty():
		root.push_input(_esc_key())
		return
	w.set_filter(pick)   # typed into the list's filter, as a player would
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	root.push_input(enter)
	var in_off := func() -> bool: return _main.hud_data.held.get("off") is ItemRef
	_check(await _until(in_off, OP_TIMEOUT_MS, false), "H: \"%s\" held in the off hand" % pick)
	if not in_off.call():
		return
	if str(_main.hud_data.held.get("off_liquid", "")).is_empty():
		print("  (pour not tried: no liquid that pours in the kit; held %s)" % pick)
	else:
		await _pour_live()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"stow_off"))
	var empty := func() -> bool: return _main.hud_data.held.get("off") == null
	_check(await _until(empty, OP_TIMEOUT_MS, false), "Shift+H puts it away: the off hand is empty (%s)"
			% [_main.hud_data.held.get("off")])


## H, then the first enabled entry whose name has `want` (not frozen or sealed), typed into the list's filter and
## Enter, as a player would; the off hand's ItemRef once it holds it, else null (the list closed).
func _hold_off(want: String) -> ItemRef:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"hold_off"))
	var asked := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if not await _until(asked, ASK_TIMEOUT_MS, false):
		return null
	var w := _main.request_ui.widget as ListRequestWidget
	var pick := ""
	for it: Dictionary in w.items:
		var n := str(it.get("plain", ""))
		var ok: bool = it.get("enabled", false) and not n.contains("frozen") and not n.contains("sealed")
		if pick.is_empty() and ok and n.to_lower().contains(want):
			pick = n
	if pick.is_empty():
		root.push_input(_esc_key())
		return null
	w.set_filter(pick)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	root.push_input(enter)
	var in_off := func() -> bool: return _main.hud_data.held.get("off") is ItemRef
	await _until(in_off, OP_TIMEOUT_MS, false)
	return _main.hud_data.held.get("off") as ItemRef


## Shift+E with water in the off hand drinks it with CDDA's consume rules, no menu (its own questions answered as a
## player would); a held knife sent to consume anyway is refused with CDDA's words, and the player sees them.
func _consume_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var seen: Array = []
	var on_done := func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op, ""])
	var on_refused := func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why])
	_main.item_actions.finished.connect(on_done)
	_main.item_actions.refused.connect(on_refused)
	var water := await _hold_off("water")
	var food := _main._held_consumable()
	_check(water != null and food != null and food.uid == water.uid, "Shift+E: held water counts as something to drink (%s)"
			% [_main.hud_data.held.get("off")])
	if food != null:
		var msgs := _messages.size()
		root.push_input(_key_of(&"cdda_eat"))
		var over := func() -> bool: return not seen.is_empty() and _main._in_main_loop()
		await _until(over, OP_TIMEOUT_MS, true)   # CDDA's own questions (not thirsty ...) answered YES
		var said := " / ".join(_messages.slice(msgs)).left(200)
		_check(not seen.is_empty() and seen[0][0] == "finished" and seen[0][2] == "consume",
				"Shift+E drinks the held water, no menu (%s; said %s)" % [seen, said])
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"stow_off"))
	await _until(func() -> bool: return _main.hud_data.held.get("off") == null, OP_TIMEOUT_MS, false)
	var knife := await _hold_off("knife")
	if knife == null:
		_check(false, "consume refusal: a knife held in the off hand")
	else:
		seen.clear()
		var msgs := _messages.size()
		var feed := _main.hud_data.messages.size()
		var sent := _main.item_actions.consume(knife)
		await _until(func() -> bool: return not seen.is_empty(), OP_TIMEOUT_MS, true)
		var why: String = seen[0][3] if not seen.is_empty() else ""
		var shown := _main.hud_data.messages.slice(feed).any(func(m: Dictionary) -> bool: return m["text"] == why)
		_check(sent and not seen.is_empty() and seen[0][0] == "refused" and not why.is_empty() and shown,
				"consume refusal: a knife is refused with CDDA's words, in the feed (%s; said %s)"
				% [seen, " / ".join(_messages.slice(msgs)).left(160)])
		await _until(in_loop, ASK_TIMEOUT_MS, false)
		root.push_input(_key_of(&"stow_off"))
		await _until(func() -> bool: return _main.hud_data.held.get("off") == null, OP_TIMEOUT_MS, false)
	_main.item_actions.finished.disconnect(on_done)
	_main.item_actions.refused.disconnect(on_refused)


## Holding E with a liquid in the off hand pours it out on the square you face.
func _pour_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var hint := _main.pour.hint(_main.world.tables)
	_check(hint.contains("pour"), "the HUD's hint says how to pour (%s)" % hint)
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	var msgs := _messages.size()
	var e_key := _key_of(&"use_held")
	root.push_input(e_key)
	await create_timer(PourHold.HOLD_MS / 1000.0 + 0.3).timeout
	var up := e_key.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)
	var poured := func() -> bool: return str(_main.hud_data.held.get("off_liquid", "?")).is_empty()
	_check(await _until(poured, OP_TIMEOUT_MS, false), "holding E pours the water out on the square you face (%s)"
			% " / ".join(_messages.slice(msgs)).left(160))


## Presses `action`'s key (`ev`, else its first binding) in the main loop; CDDA's answer must show (and be the
## `want` kind, when set), and Esc must bring the game back to its main loop.
## The Tab view's numbers in the live game (InventoryModel over the live snapshot, the bridge's item_amounts), with
## the test kit carried: a stack lists its count as CDDA writes it, a bottle with water has CDDA's own weight and
## volume, and what lies inside an item with CDDA's totals isn't added to its column a second time. The numbers
## are printed.
func _counts_live() -> void:
	var got := {}
	var look := func() -> bool:
		got.clear()
		got.merge(_tab_numbers())
		return got.has("bottle") and got.has("stack")
	if not await _until(look, ASK_TIMEOUT_MS, true):
		_check(false, "Tab: a carried stack and a bottle with water are listed with CDDA's numbers (columns %s, stack %s, bottle %s)"
				% [got.get("ids", []), got.has("stack"), got.has("bottle")])
		return
	var tables: IdTables = _main.world.tables
	var stack: Dictionary = got["stack"]
	var bottle: Dictionary = got["bottle"]
	var water: Dictionary = got["water"]
	var col: Dictionary = got["column"]
	var listed := InventoryModel.row_name(stack)
	_check(listed == "%s (%d)" % [stack["name"], stack["count"]], "Tab: a carried stack lists CDDA's count: \"%s\" (%d g, %d ml)"
			% [listed, stack["weight_g"], stack["volume_ml"]])
	var b: ItemRef = bottle["item"]
	print("    bottle \"%s\": %d g, %d ml with what is in it (its type alone: %d g, %d ml); in it \"%s\": %d g, %d ml"
			% [InventoryModel.row_name(bottle), bottle["weight_g"], bottle["volume_ml"], b.weight_g(tables), b.volume_ml(tables),
			InventoryModel.row_name(water), water["weight_g"], water["volume_ml"]])
	# (a gram of rounding between the three numbers is fine)
	_check(int(water["weight_g"]) > 0 and int(bottle["weight_g"]) >= b.weight_g(tables) + int(water["weight_g"]) - 1
			and int(bottle["volume_ml"]) > 0, "Tab: the bottle's weight is CDDA's, with the water in it (%d g; the water %d g)"
			% [bottle["weight_g"], water["weight_g"]])
	var sums := _column_sums(col)
	var once: Vector2i = sums[0]
	var all: Vector2i = sums[1]
	_check(int(col["cut"]) == 0 and int(col["weight_g"]) == once.x and int(col["volume_ml"]) == once.y and all.x > once.x,
			"Tab: what is inside isn't counted twice: column \"%s\" %d g, %d ml = its rows counted once (%d g, %d ml; %d g with the insides again)"
			% [col["id"], col["weight_g"], col["volume_ml"], once.x, once.y, all.x])


## InventoryModel's columns over the live snapshot, the ground left out: {ids (the columns), bottle + water + column
## (a carried container with CDDA's totals, the water right inside it, their column), stack (a carried row with
## CDDA's count over 1, not the water)}.
func _tab_numbers() -> Dictionary:
	var out := {"ids": []}
	if _main.hands == null or _main.world.snapshot == null:
		return out
	for col: Dictionary in InventoryModel.columns(_main.hands.picker, _main.world.tables, null):
		(out["ids"] as Array).append(col["id"])
		if col["kind"] == "nearby":
			continue
		for g: Dictionary in col["groups"]:
			var rows: Array = g["rows"]
			for k in rows.size():
				var row: Dictionary = rows[k]
				var wet := str(row["name"]).to_lower().contains("water")
				var next: Dictionary = rows[k + 1] if k + 1 < rows.size() else {}
				if not out.has("bottle") and row["exact"] and row["is_container"] and not next.is_empty() and next["exact"] \
						and int(next["depth"]) == int(row["depth"]) + 1 and str(next["name"]).to_lower().contains("water"):
					out["bottle"] = row
					out["water"] = next
					out["column"] = col
				elif not out.has("stack") and row["exact"] and int(row["count"]) > 1 and not wet:
					out["stack"] = row
	return out


## The weight (x, g) and volume (y, ml) of a column's rows: [counted once (the rows inside a row with CDDA's totals
## left out), every row].
func _column_sums(col: Dictionary) -> Array:
	var once := Vector2i.ZERO
	var all := Vector2i.ZERO
	for g: Dictionary in col["groups"]:
		var exact_at: Array = []   # exact_at[d]: the row above at depth d has CDDA's totals
		for row: Dictionary in g["rows"]:
			var d := int(row["depth"])
			exact_at.resize(mini(d, exact_at.size()))
			while exact_at.size() < d:
				exact_at.append(false)
			var w := Vector2i(int(row["weight_g"]), int(row["volume_ml"]))
			all += w
			if not exact_at.has(true):
				once += w
			exact_at.append(row["exact"])
	return [once, all]


## A number prompt in the live game, through the request UI: the debug menu's "Set hunger to?" (lead-bridge's path:
## Player..., Edit player/NPC, You, Set needs, Hunger). The field holds a number; a text that isn't one isn't sent;
## 100 typed and Enter sets it, and the snapshot's hunger follows. Skipped on a bridge without `number` requests.
func _number_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, true)
	if not _live.queue_action("debug"):
		print("    (the debug action was refused: number prompt not checked)")
		return
	for want: String in ["Player", "Edit player/NPC", "You", "Set needs", "Hunger"]:
		var entry := [-1]
		var offered := func() -> bool:
			var r := _live.request   # CDDA may first ask whether to go on (achievements get disabled): yes
			if r.get("kind", "") == "popup" and "YES" in r.get("actions", []) and int(r.get("id", 0)) != _answered:
				_answered = int(r["id"])
				_live.answer({"id": _answered, "action": "YES"})
			entry[0] = _entry_starting(want)
			return entry[0] >= 0
		if not await _until(offered, ASK_TIMEOUT_MS, false):
			var labels := (_live.request.get("entries", []) as Array).map(func(e: Variant) -> String:
				return "%s%s" % [str(e.get("label", "")) if e is Dictionary else "?",
						"" if e is Dictionary and e.get("enabled", false) else " (off)"])
			_check(false, "debug menu: \"%s...\" offered (now: %s %s %s)" % [want, _live.request.get("kind", "none"),
					_live.request.get("title", ""), labels])
			await _until(in_loop, OP_TIMEOUT_MS, true)
			return
		_live.answer({"id": int(_live.request["id"]), "entry": entry[0]})
	var asked := func() -> bool: return _live.request.get("kind", "") in ["number", "string"]
	if not await _until(asked, ASK_TIMEOUT_MS, false) or _live.request["kind"] == "string":
		print("    (no number request: this bridge has none; prompt was %s)" % _live.request.get("kind", "none"))
		await _until(in_loop, OP_TIMEOUT_MS, true)
		return
	var shown := func() -> bool: return _main.request_ui.widget is NumberRequestWidget
	await _until(shown, ASK_TIMEOUT_MS, false)
	var w := _main.request_ui.widget as NumberRequestWidget
	var id := int(_live.request["id"])
	_check(w != null and NumberRequestWidget.parse(w.edit.text, w.lo, w.hi) != null,
			"debug \"Set hunger to?\": a number field holding CDDA's value (%s, %d..%d)"
			% [w.edit.text if w != null else "-", w.lo if w != null else 0, w.hi if w != null else 0])
	if w == null:
		return
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	w.edit.text = "lots"
	root.push_input(enter)
	await process_frame
	_check(int(_live.request.get("id", 0)) == id and w.problem.visible and not w.done,
			"a text that isn't a number isn't sent (%s)" % w.problem.text)
	w.edit.text = "100"
	root.push_input(enter)
	var gone := func() -> bool: return int(_live.request.get("id", 0)) != id
	_check(await _until(gone, OP_TIMEOUT_MS, false), "100 typed and Enter: the number request is answered")
	var set_to := func() -> bool:
		return in_loop.call() and int(_main.hud_data.needs["hunger"].get("value", -1)) == 100
	var ok := await _until(set_to, OP_TIMEOUT_MS, true)
	_check(ok, "100 typed and Enter: CDDA sets hunger to it (now %s)" % _main.hud_data.needs["hunger"].get("value"))
	await _until(in_loop, OP_TIMEOUT_MS, true)


## The id of the shown menu's first enabled entry whose label starts with `prefix`, -1 when none.
func _entry_starting(prefix: String) -> int:
	var req := _live.request
	if req.get("kind", "") != "menu":
		return -1
	for e: Variant in req.get("entries", []):
		if e is Dictionary and e.get("enabled", false) and CddaText.plain(str(e.get("label", ""))).strip_edges() \
				.begins_with(prefix):
			return int(e.get("id", -1))
	return -1


## CDDA lists its whole debug menu only when the "debug" action has a key (it has none by default): binds one in
## this run's own CDDA user folder (config/keybindings.json), never the player's.
func _bind_debug_key(user_path: String) -> void:
	var config := user_path.path_join("config")
	DirAccess.make_dir_recursive_absolute(config)
	var f := FileAccess.open(config.path_join("keybindings.json"), FileAccess.WRITE)
	if f == null:
		_check(false, "can write the test's CDDA keybindings")
		return
	f.store_string(JSON.stringify([{"type": "keybinding", "id": "debug", "category": "DEFAULTMODE", "version": 2,
			"bindings": [{"input_method": "keyboard_char", "key": "~"}]}]))
	f.close()


func _try_key(action: StringName, want: String, ev: InputEventKey = null) -> void:
	if ev == null:
		ev = _key_of(action)
	var label := "%s (%s)" % [action, ev.as_text() if ev != null else "no key"]
	if ev == null:
		_check(false, label + ": has a key")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	if not await _until(in_loop, ASK_TIMEOUT_MS, false):
		_check(false, label + ": the game is in its main loop first (%s)" % [_live.request])
		return
	var msgs := _messages.size()
	root.push_input(ev)
	var asked := func() -> bool: return not _main._in_main_loop() or _messages.size() > msgs
	await _until(asked, ASK_TIMEOUT_MS, false)
	if _main._in_main_loop() and _messages.size() > msgs:   # a message first: a prompt may still follow
		var prompt := func() -> bool: return not _main._in_main_loop()
		await _until(prompt, SETTLE_MS, false)
	if _main._in_main_loop():
		var said := " / ".join(_messages.slice(msgs)) if _messages.size() > msgs else "nothing"
		_seen.append("%s: no prompt; said %s" % [label, said.left(160)])
		_check(want.is_empty(), label + ": %s (said %s)" % ["no prompt is fine" if want.is_empty()
				else "should ask with a " + want, said.left(160)])
		return
	var req := _live.request
	var kind := str(req.get("kind", ""))
	var id := int(req.get("id", 0))
	var drawn := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.request_id == id
	var shown := await _until(drawn, ASK_TIMEOUT_MS, false)
	var w := _main.request_ui.widget
	var fits := ((kind in LIST_KINDS and w is ListRequestWidget) or (kind == "direction" and w is DirectionRequestWidget)
			or not (kind in LIST_KINDS or kind == "direction"))
	var title := (str(req.get("context", "")) + " " + str(req.get("text", ""))).strip_edges().left(80).replace("\n", " ")
	_check(shown and fits, label + ": CDDA asks (%s \"%s\"), RequestUI shows it with %s" % [kind, title,
			"nothing" if w == null else String((w.get_script() as Script).get_global_name())])
	var wanted := (want == "list" and kind in LIST_KINDS) or (want == "direction" and kind == "direction") or want.is_empty()
	_check(wanted, label + ": asks with a %s" % (want if not want.is_empty() else "prompt"))
	var esc := 0
	while not _main._in_main_loop() and esc < MAX_ESC:
		var now := int(_live.request.get("id", 0))
		var on_screen := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.request_id == now
		await _until(on_screen, ASK_TIMEOUT_MS, false)
		root.push_input(_esc_key())
		esc += 1
		var gone := func() -> bool: return _main._in_main_loop() or int(_live.request.get("id", 0)) != now
		if not await _until(gone, ASK_TIMEOUT_MS, false):
			break
	var back := _main._in_main_loop() and _live.state == "running"
	_seen.append("%s: %s \"%s\", %d Esc back to the game%s" % [label, kind, title, esc, "" if back else " (NOT back)"])
	_check(back, label + ": Esc goes back to the game (%d Esc; now %s)" % [esc, _live.request])


## The key bound first to `action` (F1 defaults), as a press; null if it has none.
func _key_of(action: StringName) -> InputEventKey:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			return k
	return null


func _esc_key() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.physical_keycode = KEY_ESCAPE
	k.pressed = true
	return k


func _on_events(events: Array) -> void:
	for e: Variant in events:
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "message":
			_messages.append(CddaText.plain(str((e as Dictionary).get("text", ""))).left(200))


## Presses a range control and waits for the game's answer: "" done, else the error (or why it wasn't sent).
func _op(press: Callable, label: String) -> String:
	var before: Array = _cp._range_ops.keys()
	press.call()
	var sent: Array = _cp._range_ops.keys().filter(func(k: int) -> bool: return not k in before)
	if sent.is_empty():
		return "not sent: " + _cp.status.text
	var id: int = sent[0]
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS, true):
		return "no answer"
	print("  %s -> %s" % [label, "done" if str(_done[id]).is_empty() else _done[id]])
	return _done[id]


## Waits (playing on) until `cond` holds; false on timeout or if the game stops. `answer`: prompts get the answer
## a player would give meanwhile (setup only; the keys' own prompts are this test's to answer).
func _until(cond: Callable, timeout_ms: int, answer: bool) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
		if answer:
			_answer_prompt()
		await create_timer(0.05).timeout
	return false


## A prompt main would show the player gets the answer a player would give (YES to confirmations, else cancel);
## main answers raw-key screens and shots itself.
func _answer_prompt() -> void:
	var req := _live.request
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY":
		return
	var id := int(req.get("id", 0))
	if id == _answered:
		return
	_answered = id
	var a := {"id": id, "cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		a = {"id": id, "action": "YES" if "YES" in acts else acts[0]}
	print("  answering %s %s %s: %s" % [req.get("kind", "?"), req.get("context", ""), acts, a])
	_live.answer(a)


func _stop() -> void:
	_live.stop()
	var stopped := func() -> bool: return _live.state != "running"
	await _until(stopped, 30000, false)
	_main.queue_free()
	await process_frame


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("actions live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
