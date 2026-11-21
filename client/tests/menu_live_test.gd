extends SceneTree
## Headless live run of the main menu's character delete and the teleport cheat, through the client's own UI path.
## Run 1: the main menu's New game page starts a random character in a fresh world; with a game running, a delete
## is refused (here and by the bridge); with cheats allowed, LiveSession's teleport moves the character and the F1
## Cheats entry sends one too; with cheats off, nothing is sent and the entry is greyed out; then it saves and stops.
## Run 2 (`--delete`, started by run 1 in the same folder): the Load page's "Delete character..." button, its
## confirm naming the character, and "Delete" remove the character and its now empty world from the disk.
## Uses this run's own CDDA folder, never the player's saves. Needs the DLL (build target fp3d-cdda) and the game
## data (../cdda, or --cdda=<folder>). ~2 min. From the repo root:
##   godot --headless --path client --script res://tests/menu_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const WORLD := "MenuLive"
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 60000
const SHOW_TIMEOUT_MS := 20000

var _failed := 0
var _run_name := "menu live tests"
var _main: Main
var _live: LiveSession
var _user_dir := ""
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not "--live" in args:
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	if "--delete" in args:
		_run_name = "menu live tests (delete run)"
		_check(TestDir.use_parent(args), "run 1 named its folder (--test-run)")
		_user_dir = TestDir.global("cdda-menu")
		_run_delete()
	else:
		_user_dir = TestDir.global("cdda-menu")
		_run()


func _start_main() -> void:
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = _user_dir
	root.add_child(_main)
	await process_frame
	_live = _main.live
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)


## Run 1: a new game from the menu, delete refused while it runs, teleports, save, then run 2.
func _run() -> void:
	_check(LiveSession.delete_save_available() and ClassDB.class_has_method("CddaSim", "cheat_teleport"),
			"the bridge has delete_save and cheat_teleport")
	if _failed > 0:
		_finish()
		return
	await _start_main()
	var menu := _main.main_menu
	_check(menu != null, "the main menu shows")
	if menu == null:
		_finish()
		return
	menu.show_page("new")
	menu._world_edit.text = WORLD
	menu._custom.button_pressed = false   # a random character
	menu._setup.button_pressed = false    # default world settings
	var start := _find_button(menu, "Start")
	start.pressed.emit()
	_check(_main.main_menu == null, "Start starts a new game in %s (%s)" % [WORLD, _live.error])
	var t0 := Time.get_ticks_msec()
	var up := await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null, BOOT_TIMEOUT_MS)
	_check(up, "the game runs (%.0f s, state %s %s)" % [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if not up:
		_finish()
		return
	if _has_clock():   # lead-ui's real-time switch: a new game waits for the player
		var turn0: int = _main.world.snapshot.turn
		var t1 := Time.get_ticks_msec()
		await _until(func() -> bool: return Time.get_ticks_msec() - t1 > 2500, 10000)
		_check(_live.clock().get("real_time") == false and _main.world.snapshot.turn == turn0,
				"a new game is in turns: nothing passes in 2.5 s with no input (%d turns)" % (_main.world.snapshot.turn - turn0))

	_main.key_menu.cheats_forced = true
	_main._sync_cheats_allowed()
	_check(_live.can_teleport(), "cheats allowed: teleport can be asked for")
	var from: Vector3i = _main.world.snapshot.player_pos
	var moved := false
	for d: Vector3i in [Vector3i(4, 0, 0), Vector3i(0, 4, 0), Vector3i(-4, 0, 0), Vector3i(0, -4, 0)]:
		var err := await _op(_live.cheat_teleport(from + d))
		print("  teleport to %s -> %s" % [from + d, "done" if err.is_empty() else err])
		if err.is_empty():
			var there := func() -> bool: return _main.world.snapshot.player_pos != from
			moved = await _until(there, SHOW_TIMEOUT_MS)
			var at: Vector3i = _main.world.snapshot.player_pos
			var off := at - (from + d)
			_check(moved and at.z == from.z and maxi(absi(off.x), absi(off.y)) <= 10,
					"teleport: the character stands at or next to the square (%s, asked %s)" % [at, from + d])
			break
	_check(moved, "teleport: done for one of four squares 4 away")
	var cp := _main.cheat_panel
	cp.refresh()
	_check(not cp.teleport_button.disabled, "the F1 entry is enabled with cheats allowed")
	cp.teleport_here()
	var said := cp.status.text
	if said == "Teleport: asked for.":
		var answered := func() -> bool: return cp.status.text != said
		await _until(answered, OP_TIMEOUT_MS)
		said = cp.status.text
	print("  F1 teleport -> %s (status line: %s)" % [said, _main.status])
	_check(said == "Teleport: done." or said.begins_with("Teleport: not sent. Point") or
			(said.begins_with("Teleport: ") and not said.contains("needs") and not "\n" in said),
			"the F1 entry sends the screen centre's square, or says why not (%s)" % said)
	_live.set_cheats_allowed(false)   # (the player's own F1 debug switch may allow them in main)
	cp.refresh()
	var before := _done.size()
	_check(not _live.cheats_allowed and _live.cheat_teleport(from) == 0 and cp.teleport_button.disabled
			and _done.size() == before, "cheats off: nothing sent, the entry greyed out")

	var saved := [false]
	_live.saved.connect(func(ok: bool) -> void: saved[0] = ok, CONNECT_ONE_SHOT)
	_check(_live.save(), "save asked for")
	_check(await _until(func() -> bool: return saved[0], OP_TIMEOUT_MS), "saved")
	var saves := LiveSession.list_saves(_user_dir, WORLD)
	_check(saves.size() == 1, "the saved character is listed (%s)" % [saves])
	if saves.size() == 1:
		var here := _live.delete_save(_user_dir, WORLD, saves[0], true)
		var bridge: String = ClassDB.instantiate("CddaSim").delete_save(_user_dir, WORLD, saves[0], true)
		_check(here == "a game is running in this window" and not bridge.is_empty()
				and LiveSession.list_saves(_user_dir, WORLD) == saves,
				"while it runs, a delete is refused here (%s) and by the bridge (%s)" % [here, bridge])

	var second: Variant = await _second_game()
	if second != true:   # null: a script error stopped it half way
		_check(second == false and _failed > 0, "the second game's checks ran to the end")
		_finish()
		return
	await _stop()
	print("  second run: delete the character from the Load page")
	var out := []
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://tests/menu_live_test.gd", "--", "--live", "--delete", TestDir.child_arg()])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cdda="):
			args.append(a)
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	for chunk: String in out:
		print(chunk.strip_edges(false, true).indent("  | "))
	_check(code == 0, "second run deletes the character through the menu (exit %d)" % code)
	_finish()


## Two games in a row in one process: F1's "Save and quit to menu" ends the game through CDDA's own save and quit, a
## fresh Main takes over showing the menu with nothing of the first game left, and its Load page starts the same
## character again, standing where it was saved. With lead-ui's real-time switch: real time is turned on before the
## save, the loaded game runs in real time, and the key puts it back in turns. False when it can't go on.
func _second_game() -> bool:
	var pos1: Vector3i = _main.world.snapshot.player_pos
	var old_main: Node = _main
	var old_live: Node = _live
	var replaced := []
	_main.replaced.connect(func(m: Node3D) -> void: replaced.append(m))
	var qb := _main.key_menu.quit_button
	_check(qb != null and qb.visible, "F1 has \"Save and quit to menu\" in a live game")
	if qb == null:
		return false
	var real := func() -> bool: return _live.clock().get("real_time") == true
	if _has_clock():   # real time on before the save: the fresh Main must read it from this run's hud.cfg
		_check(_press(&"real_time_toggle") and await _until(real, SHOW_TIMEOUT_MS),
				"the real-time key turns real time on before the save")
	_main.key_menu.open()
	qb.pressed.emit()
	_check(not _main.key_menu.visible, "the button closes F1")
	var back := await _until(func() -> bool: return not replaced.is_empty(), OP_TIMEOUT_MS, false)
	_check(back, "after CDDA's \"Save and quit?\" the game ends and the menu comes back (%s)"
			% [old_live.get("state") if is_instance_valid(old_live) else "freed"])
	if not back:
		return false
	_main = replaced[0] as Main
	_live = _main.live
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	await process_frame
	await process_frame
	var menu := _main.main_menu
	_check(replaced.size() == 1 and not is_instance_valid(old_main) and not is_instance_valid(old_live)
			and _main.get_parent() == root,
			"the old Main and its LiveSession are freed, the fresh one is in their place (%d handovers)" % replaced.size())
	_check(menu != null and menu.message == "Game saved." and _live.state == "idle" and _main.world.snapshot == null
			and _main.hud_data.messages.is_empty() and _main.character_data.cards.is_empty()
			and not _main.key_menu.cheats_forced,
			"the fresh Main shows the menu saying \"Game saved.\", with no game, map, messages, sheet or cheats (%s, %s)"
			% [menu.message if menu != null else "no menu", _live.state])
	var saves := LiveSession.list_saves(_user_dir, WORLD)
	_check(saves.size() == 1, "the character is still listed after quitting (%s)" % [saves])
	if menu == null or saves.size() != 1:
		return false
	menu.show_page("load")
	_check(menu.select_world(WORLD), "the Load page has %s" % WORLD)
	var load_button := _find_button(menu, "Load")
	_check(load_button != null, "the Load page has the Load button")
	if load_button == null:
		return false
	load_button.pressed.emit()
	var t0 := Time.get_ticks_msec()
	var up := await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null,
			BOOT_TIMEOUT_MS)
	_check(up and _main.main_menu == null, "the second game runs (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if not up:
		return false
	var pos2: Vector3i = _main.world.snapshot.player_pos
	_check(pos2 == pos1, "the character stands where it was saved (%s, saved at %s)" % [pos2, pos1])
	_check(not _main.key_menu.cheats_forced and _live.cheats_allowed == _main.key_menu.cheats_allowed(),
			"cheats as the settings say, not as game 1 forced them (%s)" % _live.cheats_allowed)
	_check(replaced.size() == 1, "no second handover")
	if _has_clock():   # the loaded game follows the saved setting: real time, turns passing by themselves
		var turn1: int = _main.world.snapshot.turn
		var runs := func() -> bool:   # (a hostile in view may pause it: that is real time too)
			return real.call() and (_live.clock().get("paused") == true or _main.world.snapshot.turn >= turn1 + 2)
		_check(_main.hud_settings.get("real_time") == true and await _until(runs, SHOW_TIMEOUT_MS),
				"the loaded game is in real time, as this run's hud.cfg says: time runs by itself (%d turns; clock %s)"
				% [_main.world.snapshot.turn - turn1, _live.clock()])
		var turns := func() -> bool: return not real.call()
		_check(_press(&"real_time_toggle") and await _until(turns, SHOW_TIMEOUT_MS) and _main.hud_settings.get("real_time") == false,
				"the real-time key again: back in turns")
	var t1 := Time.get_ticks_msec()   # a few seconds of play: nothing of game 1 may fire into game 2
	await _until(func() -> bool: return Time.get_ticks_msec() - t1 > 3000, 10000)
	_check(_live.state == "running" and _main.is_inside_tree() and replaced.size() == 1,
			"the second game keeps running (%s %s)" % [_live.state, _live.error])
	return true


## Run 2: the Load page's Delete button and its confirm. No game is started.
func _run_delete() -> void:
	await _start_main()
	var menu := _main.main_menu
	var saves := LiveSession.list_saves(_user_dir, WORLD)
	_check(menu != null and menu.deleter.is_valid() and WORLD in menu.worlds and saves.size() == 1,
			"the menu lists %s with its character (%s) and can delete" % [WORLD, saves])
	if _failed > 0:
		_finish()
		return
	_check(_live.delete_save(_user_dir, WORLD, "nobody", true) == "no such character"
			and (ClassDB.instantiate("CddaSim").delete_save(_user_dir, "../" + WORLD, saves[0], true) as String) != ""
			and LiveSession.list_saves(_user_dir, WORLD) == saves, "a name not listed is refused, nothing deleted")
	menu.show_page("load")
	menu.select_world(WORLD)
	var del := _find_button(menu, "Delete character...")
	_check(del != null, "the Load page has the Delete button")
	if del == null:
		_finish()
		return
	del.pressed.emit()
	var confirm: Label = menu._box.get_node_or_null("Confirm")
	_check(menu.page == "delete" and confirm != null and confirm.text.contains(MainMenu.shown(saves[0]))
			and confirm.text.contains("last character in " + WORLD), "the confirm names the character and its world")
	var yes: Button = menu._box.get_node_or_null("DeleteButton")
	yes.pressed.emit()
	var gone := not DirAccess.dir_exists_absolute(_user_dir.path_join("save").path_join(WORLD))
	_check(menu.message == "Deleted %s, and the world %s with them." % [MainMenu.shown(saves[0]), WORLD]
			and not WORLD in LiveSession.list_worlds(_user_dir) and gone,
			"Delete removes the character and its empty world (%s; folder gone %s)" % [menu.message, gone])
	_main.queue_free()
	await process_frame
	_finish()


## Waits for range_done of op `id` (0 = refused before sending).
func _op(id: int) -> String:
	if id < 1:
		return "not sent"
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS):
		return "no answer"
	return _done[id]


## Waits (playing on) until `cond` holds; false on timeout or, with `end_stops`, if the game stops.
func _until(cond: Callable, timeout_ms: int, end_stops := true) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if end_stops and (_live.state == "ended" or _live.state == "failed"):
			return false
		_answer_prompt()
		await create_timer(0.05).timeout
	return false


## A prompt gets the answer a player would give (YES to confirmations, else cancel).
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


## Whether this client has lead-ui's real-time switch (the key and LiveSession.set_real_time).
func _has_clock() -> bool:
	return InputMap.has_action(&"real_time_toggle") and _live.has_method("set_real_time")


## Presses the first key bound to `action` (F1 defaults) in the window; false when it has none.
func _press(action: StringName) -> bool:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			root.push_input(k)
			return true
	return false


func _stop() -> void:
	_live.stop()
	await _until(func() -> bool: return _live.state != "running", 30000)
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
	if "--delete" in OS.get_cmdline_user_args():
		pass   # run 1 cleans the shared folder
	elif _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("%s: %s" % [_run_name, "all passed" if _failed == 0 else "%d FAILED" % _failed])
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
