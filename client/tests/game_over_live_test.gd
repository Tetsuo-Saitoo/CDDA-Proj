extends SceneTree
## Headless live run of how games end in the client (main.gd _on_game_over): each ending hands over to a fresh Main
## on the main menu, and the next game starts in the same process. Through the menu, in order:
## 1. New game with "Create the character": cancelling the character creation brings the menu back.
## 2. The test range (when the bridge has it): monsters next to the character, AI on, turns passing until it dies:
##    the menu says "Your character died.".
## 3. New game with a random character (in the same world when step 1 left it): CDDA's "Abandon this character"
##    (SUICIDE, both confirms) ends it, the menu comes back and the character is gone from the Load page.
## 4. One more new game runs for a few seconds.
## Uses this run's own CDDA folder, never the player's saves. Needs the DLL (build target fp3d-cdda) and the game
## data (../cdda, or --cdda=<folder>). ~5 min. From the repo root:
##   godot --headless --path client --script res://tests/game_over_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const WORLD := "GameOverLive"
const LAST_WORLD := "GameOverLast"
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 60000
const DIE_TIMEOUT_MS := 240000
const KILLER := "mon_zombie_hulk"

var _failed := 0
var _main: Main
var _live: LiveSession
var _user_dir := ""
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0
var _replaced: Array = []   # fresh Mains handed over to, not yet taken


func _initialize() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_user_dir = TestDir.global("cdda-gameover")
	_run()


func _run() -> void:
	var m := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	m.cdda_user_dir = _user_dir
	root.add_child(m)
	await process_frame
	_adopt(m)
	_check(_main.main_menu != null, "the main menu shows")
	if _main.main_menu == null or not await _cancel_chargen():
		_finish()
		return
	if LiveSession.test_range_available():
		if not await _die_in_range():
			_finish()
			return
	else:
		print("  (this bridge has no test range: no death check)")
	if await _abandon():
		await _one_more_game()
	_finish()


## Step 1: character creation cancelled.
func _cancel_chargen() -> bool:
	var menu := _main.main_menu
	menu.show_page("new")
	menu._world_edit.text = WORLD
	menu._custom.button_pressed = true    # create the character
	menu._setup.button_pressed = false    # default world settings
	_find_button(menu, "Start").pressed.emit()
	_check(_main.main_menu == null, "Start with \"Create the character\" starts a game (%s)" % _live.error)
	var req: Variant = await _request("chargen", BOOT_TIMEOUT_MS)
	_check(req != null, "the character creation request comes (state %s %s)" % [_live.state, _live.error])
	if req == null:
		return false
	_check(_live.answer({"id": req["id"], "cancel": true}), "cancel answered")
	var said: Variant = await _back_on_menu("chargen cancelled")
	if said == null:
		return false
	var worlds := LiveSession.list_worlds(_user_dir)
	print("  after the cancel: worlds %s, saves in %s %s" % [worlds, WORLD, LiveSession.list_saves(_user_dir, WORLD)])
	_check(not (said as String).begins_with("The game failed"),
			"cancelling the character isn't shown as a failure (\"%s\")" % said)
	_check(not WORLD in worlds or not LiveSession.list_saves(_user_dir, WORLD).is_empty(),
			"no empty world is left behind (worlds %s)" % [worlds])
	return true


## Step 3: a random character, then CDDA's own "Abandon this character".
func _abandon() -> bool:
	var menu := _main.main_menu
	menu.show_page("new")
	if WORLD in menu.worlds:   # step 1 left it: the player can only add a character to it
		menu._use_existing.button_pressed = true
		_check(menu.select_world(WORLD), "the New game page lists %s to add a character to" % WORLD)
	else:
		menu._world_edit.text = WORLD
		menu._setup.button_pressed = false
	menu._custom.button_pressed = false   # a random character
	_find_button(menu, "Start").pressed.emit()
	_check(_main.main_menu == null, "Start starts a random character in %s (%s)" % [WORLD, menu.message])
	if not await _running("the random character's game"):
		return false
	var saved := [false]   # saved first, so the Load page has the character until it is abandoned
	_live.saved.connect(func(ok: bool) -> void: saved[0] = ok, CONNECT_ONE_SHOT)
	_check(_live.save() and await _until(func() -> bool: return saved[0], OP_TIMEOUT_MS), "saved")
	var saves_before := LiveSession.list_saves(_user_dir, WORLD)
	_check(saves_before.size() == 1, "the Load page has the character (%s)" % [saves_before])
	_check(_live.queue_action("SUICIDE"), "CDDA's \"Abandon this character\" queued")
	var said: Variant = await _back_on_menu("abandoned")
	if said == null:
		return false
	_check(said in ["The game ended.", "Your character died."], "the menu says the game ended (\"%s\")" % said)
	var saves := LiveSession.list_saves(_user_dir, WORLD)
	print("  saves in %s: before %s, after %s" % [WORLD, saves_before, saves])
	_check(saves.is_empty(), "the abandoned character isn't on the Load page (%s)" % [saves])
	return true


## Step 2: killed in the test range.
func _die_in_range() -> bool:
	var menu := _main.main_menu
	var r := _find_button(menu, "Test range")
	_check(r != null, "the menu has \"Test range\"")
	if r == null:
		return false
	r.pressed.emit()
	if not await _running("the test range"):
		return false
	var at: Vector3i = _main.world.snapshot.player_pos
	var spawned := 0
	for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(1, 1, 0), Vector3i(-1, 1, 0), Vector3i(1, -1, 0), Vector3i(-1, -1, 0)]:
		if spawned < 2 and (await _op(_live.range_spawn_monster(KILLER, at + d))).is_empty():   # hit points fall turn by turn
			spawned += 1
	_check(spawned > 0, "%d %s next to the character" % [spawned, KILLER])
	_check((await _op(_live.range_set_ai_frozen(false))).is_empty(), "AI on")
	var old_live := _live
	var t0 := Time.get_ticks_msec()
	var said_at := [0]
	var over := func() -> bool:   # turns pass ("pause") until the game is over
		if not _replaced.is_empty() or not is_instance_valid(old_live) or old_live.state != "running":
			return true
		if old_live.queued_actions() == 0:
			old_live.queue_action("pause")
		if Time.get_ticks_msec() - said_at[0] > 10000:   # how it goes, every 10 s
			said_at[0] = Time.get_ticks_msec()
			var snap: Snapshot = _main.world.snapshot
			var hp := []
			for p: Variant in snap.player_parts:
				hp.append(p.get("hp"))
			print("  turn %d, hit points %s, request %s" % [snap.turn, hp, old_live.request.get("context", "-")])
		return false
	var dead := await _until(over, DIE_TIMEOUT_MS, false)
	_check(dead, "the character dies (%.0f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if not dead:
		return false
	var said: Variant = await _back_on_menu("died")
	if said == null:
		return false
	_check(said == "Your character died.", "the menu says \"Your character died.\" (\"%s\")" % said)
	return true


## Step 4: the process still plays a new game after all that.
func _one_more_game() -> void:
	var menu := _main.main_menu
	menu.show_page("new")
	menu._world_edit.text = LAST_WORLD
	menu._custom.button_pressed = false
	menu._setup.button_pressed = false
	_find_button(menu, "Start").pressed.emit()
	if not await _running("one more game"):
		return
	var n := _replaced.size()
	var t1 := Time.get_ticks_msec()
	await _until(func() -> bool: return Time.get_ticks_msec() - t1 > 3000, 10000)
	_check(_live.state == "running" and _main.is_inside_tree() and _replaced.size() == n,
			"it keeps running (%s %s)" % [_live.state, _live.error])
	_live.stop()
	await _until(func() -> bool: return _live.state != "running", 30000, false)
	_main.queue_free()
	await process_frame


func _adopt(m: Main) -> void:
	_main = m
	_live = m.live
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	_main.replaced.connect(func(fresh: Node3D) -> void: _replaced.append(fresh))


func _running(what: String) -> bool:
	var t0 := Time.get_ticks_msec()
	var up := await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null,
			BOOT_TIMEOUT_MS)
	_check(up and _main.main_menu == null, "%s runs (%.0f s, state %s %s)"
			% [what, (Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	return up


## Waits for the ended game's Main to hand over to a fresh one on the menu; the menu's message, or null.
func _back_on_menu(what: String) -> Variant:
	var old_main: Node = _main
	var old_live: Node = _live
	var back := await _until(func() -> bool: return not _replaced.is_empty(), OP_TIMEOUT_MS, false)
	_check(back, "%s: the menu comes back (state %s, %s)" % [what,
			old_live.get("state") if is_instance_valid(old_live) else "freed",
			old_live.get("error") if is_instance_valid(old_live) else ""])
	if not back:
		return null
	_adopt(_replaced.pop_front() as Main)
	await process_frame
	await process_frame
	var menu := _main.main_menu
	_check(not is_instance_valid(old_main) and not is_instance_valid(old_live) and _main.get_parent() == root
			and menu != null and _live.state == "idle" and _main.world.snapshot == null and _replaced.is_empty(),
			"%s: the old Main is freed, the fresh one shows the menu with no game (%s)" % [what, _live.state])
	if menu == null:
		return null
	print("  %s: the menu says \"%s\"" % [what, menu.message])
	return menu.message


## Waits for a request of `kind`, answering the others like a player would; null on timeout or a stopped game.
func _request(kind: String, timeout_ms: int) -> Variant:
	var found := [null]
	var came := func() -> bool:
		if _live.request.get("kind", "") == kind:
			found[0] = _live.request
			return true
		return false
	await _until(came, timeout_ms)
	return found[0]


## Waits for range_done of op `id` (0 = refused before sending).
func _op(id: int) -> String:
	if id < 1:
		return "not sent"
	if not await _until(func() -> bool: return _done.has(id), OP_TIMEOUT_MS):
		return "no answer"
	return _done[id]


## Waits (playing on) until `cond` holds; false on timeout or, with `end_stops`, if the game stops.
func _until(cond: Callable, timeout_ms: int, end_stops := true) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if not is_instance_valid(_live):
			return false
		if end_stops and (_live.state == "ended" or _live.state == "failed"):
			return false
		_answer_prompt()
		await create_timer(0.05).timeout
	return false


## A prompt gets the answer a player would give (YES to confirmations, else cancel). Character creation and world
## setup are left to the step waiting for them.
func _answer_prompt() -> void:
	var req := _live.request
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY" \
			or req.get("kind", "") in ["chargen", "world_setup"]:
		return
	var id := int(req.get("id", 0))
	if id == _answered:
		return
	_answered = id
	var a := {"id": id, "cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		a = {"id": id, "action": "YES" if "YES" in acts else acts[0]}
	print("  answering %s %s %s \"%s\": %s" % [req.get("kind", "?"), req.get("context", ""), acts,
			str(req.get("text", req.get("title", ""))).left(80), a])
	_live.answer(a)


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
	print("game over live tests: %s" % ["all passed" if _failed == 0 else "%d FAILED" % _failed])
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
