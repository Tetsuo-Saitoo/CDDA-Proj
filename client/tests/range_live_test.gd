extends SceneTree
## Headless smoke run of the test range through the client's own UI path: main in live mode shows the main menu,
## its "Test range" button starts the range (cheats allowed, the F1 Cheats page forced on), the Cheats page's
## range controls show the zones, and each control (heal, freeze, set time, wait an hour, spawn an item at the
## feet and a monster ahead, go to a zone) comes back done from the game and shows in the client's world. Uses
## this run's own CDDA folder, never the player's saves.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda, or --cdda=<folder>). ~3 min. From the repo
## root:
##   godot --headless --path client --script res://tests/range_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 90000
const SHOW_TIMEOUT_MS := 20000   # an op's effect reaching the client's world after the game says done
const HOUR_TURNS := 3600         # CDDA turns are seconds
const ITEM := "glock_19"
const MONSTER := "mon_zombie"

var _failed := 0
var _main: Main
var _live: LiveSession
var _cp: CheatPanel
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0    # the last prompt this script answered


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
	_main.cdda_user_dir = TestDir.global("cdda-range")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	_cp = _main.cheat_panel
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	var menu := _main.main_menu
	var button := _find_button(menu, "Test range") if menu != null else null
	_check(menu != null and menu.test_range and button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	_check(_main.main_menu == null and _live.cheats_allowed and _main.key_menu.cheats_allowed(),
			"the button starts the range with cheats allowed (%s)" % _live.error)
	var t0 := Time.get_ticks_msec()
	var shown := func() -> bool: return (_live.state == "running" and _main.world.snapshot != null
			and _cp.range_box.visible and _cp.tables != null)
	var up := await _until(shown, BOOT_TIMEOUT_MS)
	_check(up, "the range runs and the Cheats page shows its controls (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if not up:
		_finish()
		return
	var info := _live.range_info()
	var zones: Array = info.get("zones", [])
	_check(_live.in_range() and zones.size() > 1 and _cp.zone_pick.item_count == zones.size()
			and _cp.zone_pick.selected == info.get("zone", -1) and info.get("zone", -1) == 0,
			"zones listed, the hub picked (%d zones, at %d)" % [zones.size(), info.get("zone", -1)])
	_check(info.get("ai_frozen", false) and _cp.freeze.button_pressed, "monsters start frozen, and the switch says so")

	_check(await _op(_cp.heal, "Heal") == "", "Heal: done")
	var thawed := func() -> bool: return not _live.range_info().get("ai_frozen", true)
	var frozen := func() -> bool: return _live.range_info().get("ai_frozen", false) and _cp.freeze.button_pressed
	_cp.freeze.button_pressed = false   # as a click: toggled -> set_frozen
	var off := await _last_op("Monsters moving")
	_check(off == "" and await _until(thawed, OP_TIMEOUT_MS), "freeze switch off: monsters move (%s)" % off)
	_cp.freeze.button_pressed = true
	var on := await _last_op("Monsters frozen")
	_check(on == "" and await _until(frozen, OP_TIMEOUT_MS), "freeze switch on: frozen again (%s)" % on)
	var boot_turn := _main.world.snapshot.turn
	_cp.hour.value = 22
	var timed := await _op(_cp.set_time, "Time 22:00")
	var jumped := func() -> bool: return _main.world.snapshot.turn >= boot_turn + 11 * HOUR_TURNS
	var shown_time := await _until(jumped, SHOW_TIMEOUT_MS)
	_check(timed == "" and shown_time, "Set time 22:00 (from 10:00): done, the world shows it (turn %d -> %d, %s)"
			% [boot_turn, _main.world.snapshot.turn, timed])
	# before the monster: a hostile in view cuts a wait short
	var turn := _main.world.snapshot.turn
	var waited := await _op(_cp.wait_hour, "Wait 1 hour")
	var hour_on := func() -> bool: return _main.world.snapshot.turn >= turn + HOUR_TURNS - 60
	var later := await _until(hour_on, OP_TIMEOUT_MS)
	_check(waited == "" and later, "Wait 1 hour: done, an hour went by (turn %d -> %d, %s)"
			% [turn, _main.world.snapshot.turn, waited])
	var here := _main.world.snapshot.player_pos
	var t := _cp.tables.index_of("itype", ITEM)
	_cp.item_id.text = ITEM
	_cp.item_count.value = 2
	var spawned := await _op(_cp.spawn_item, "Spawn " + ITEM)
	var on_floor := func() -> bool: return _ground_count(t, here) >= 2
	var listed := await _until(on_floor, SHOW_TIMEOUT_MS)
	_check(spawned == "" and listed, "Spawn 2 %s at the feet: done, the Tab list shows %d there (%s)"
			% [ITEM, _ground_count(t, here), spawned])
	var ahead: Variant = _cp.ahead_square.call()
	_cp.monster_id.text = MONSTER
	var mon := await _op(_cp.spawn_monster, "Spawn " + MONSTER)
	var seen := func() -> bool: return ahead is Vector3i and _main.world.snapshot.creature_at(ahead) != null
	var stands := await _until(seen, SHOW_TIMEOUT_MS)
	_check(mon == "" and stands, "Spawn %s ahead: done, it stands at %s (%s)" % [MONSTER, ahead, mon])
	var pos := _main.world.snapshot.player_pos
	_cp.zone_pick.select(1)
	var went := await _op(_cp.go_zone, "Go to")
	var arrived := func() -> bool: return (_live.range_info().get("zone", -1) == 1
			and _main.world.snapshot.player_pos != pos)
	var moved := await _until(arrived, OP_TIMEOUT_MS)
	var zone_name: String = zones[1].get("name", "?")
	_check(went == "" and moved and _cp.zone_pick.selected == 1,
			"Go to %s: done, the player moved (%s -> %s)" % [zone_name, pos, _main.world.snapshot.player_pos])
	var built := func() -> bool: return _cp.zone_pick.get_item_text(1) == zone_name
	_check(await _until(built, SHOW_TIMEOUT_MS) and _cp.status.text == "Go to %s: done." % zone_name,
			"the zone reads built and the status line names it (%s / %s)" % [_cp.zone_pick.get_item_text(1), _cp.status.text])
	await _stop()
	_finish()


## Presses a range control and waits for the game's answer: "" done, else the error (or why it wasn't sent).
## `label` starts the status line the panel shows for it.
func _op(press: Callable, label: String) -> String:
	var before: Array = _cp._range_ops.keys()
	press.call()
	return await _wait_new(before, label)


## The op a control just sent by signal (the freeze switch): the newest one waiting.
func _last_op(label: String) -> String:
	var keys: Array = _cp._range_ops.keys()
	return await _wait_new(keys.slice(0, keys.size() - 1), label)


func _wait_new(before: Array, label: String) -> String:
	var sent: Array = _cp._range_ops.keys().filter(func(k: int) -> bool: return not k in before)
	if sent.is_empty():
		return "not sent: " + _cp.status.text
	var id: int = sent[0]
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS):
		return "no answer"
	var err: String = _done[id]
	var said := _cp.status.text
	if not said.begins_with(label) or said.ends_with("done.") != err.is_empty():
		return "status line says \"%s\" for \"%s\"" % [said, err]
	print("  %s -> %s" % [label, "done" if err.is_empty() else err])
	return err


## Waits (playing on) until `cond` holds; false on timeout or if the game stops.
func _until(cond: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
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
		var pick: String = "YES" if "YES" in acts else acts[0]
		if req.get("context", "") == "CANCEL_ACTIVITY_OR_IGNORE_QUERY":   # "Stop waiting?": keep on
			pick = "IGNORE" if "IGNORE" in acts else ("NO" if "NO" in acts else pick)
		a = {"id": id, "action": pick}
	print("  answering %s %s %s: %s" % [req.get("kind", "?"), req.get("context", ""), acts, a])
	_live.answer(a)


func _stop() -> void:
	_live.stop()
	var stopped := func() -> bool: return _live.state != "running"
	await _until(stopped, 30000)
	_main.queue_free()
	await process_frame


## Items of itype `t` lying on square `sq`, as the Tab inventory's "nearby" column lists them.
func _ground_count(t: int, sq: Vector3i) -> int:
	var n := 0
	for col: Dictionary in InventoryModel.columns(_main.hands.picker, _main.world.tables, _main.item_actions):
		if col["kind"] != "nearby":
			continue
		for g: Dictionary in col["groups"]:
			for row: Dictionary in g["rows"]:
				var r: ItemRef = row["item"]
				if r.type == t and r.square == sq:
					n += 1
	return n


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
	print("range live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
