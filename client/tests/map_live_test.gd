extends SceneTree
## G5 map slice 1 (lead-ui, 2026-11-26; docs/MAP.md) on the game's own read, through the client's own UI path: main
## in live mode starts the test range, M opens the map (MapView), and the pages come from the bridge's
## query_overmap: the player's cell is fully seen and named (and the line under the map names it), the player has
## no destination, a page far away reads as all unseen, PgUp shows the next level, and Esc closes the map and drops
## its pages. Slice 2: a note added next to the player reads back, is edited, capped, cleaned and deleted (skipped
## on a bridge without queue_overmap). Skips (passing) on a bridge without query_overmap. Uses this run's own CDDA
## folder.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda). ~1 min. From the repo root:
##   godot --headless --path client --script res://tests/map_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const READ_TIMEOUT_MS := 60000
const WRITE_TIMEOUT_MS := 15000
const FAR_CELLS := 4096   # well past what the range's world has generated

var _failed := 0
var _main: Main
var _live: LiveSession
var _answered := 0


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
	_main.cdda_user_dir = TestDir.global("cdda-map")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	var menu := _main.main_menu
	var button := _find_button(menu, "Test range") if menu != null else null
	_check(button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	var up := await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null,
			BOOT_TIMEOUT_MS)
	_check(up, "the range runs (state %s %s)" % [_live.state, _live.error])
	if not up:
		_finish()
		return
	if not _live.has_overmap():
		print("  skip  the bridge has no query_overmap yet: the map's live checks need lead-bridge's read")
		_stop()
		return
	await _map_checks()
	await _note_checks()
	_stop()


func _map_checks() -> void:
	root.size = Vector2i(1280, 720)   # (headless the window starts 64 x 64: the map's canvas would have no size)
	await _frames(2)
	var md := _main.map_data
	var mv := _main.map_view
	root.push_input(_key_of(&"map"))
	await _frames(2)
	_check(mv.visible and md.is_open(), "M opens the map")
	var me := md.player_cell
	var here := Vector2i(me.x, me.y)
	var named := func() -> bool: return md.info(here, me.z).has("name")
	var read := await _until(named, READ_TIMEOUT_MS)
	var i := md.info(here, me.z)
	_check(read and i.get("vision") == MapData.MAX_VISION and not (i.get("name", "") as String).is_empty()
			and md.note.is_empty(), "the player's cell %s is fully seen and named: %s (%s)" % [me, i, md.note])
	mv._hover = mv.canvas.to_px(Vector2(here) + Vector2(0.5, 0.5))
	_check(mv.info_text().contains("%s, %s." % [i.get("name"), MapData.VISION_WORDS[MapData.MAX_VISION]]),
			"the line under the map names it: " + mv.info_text())
	_check(md.path.is_empty() and md.destination == null, "no destination yet (%s)" % [md.destination])
	var far := MapData.page_origin(Vector3i(me.x + FAR_CELLS, me.y, me.z))
	mv.canvas.middle = Vector2(far.x + 16, far.y + 16)
	mv.canvas.pan_px(Vector2(0.5, 0))   # tells MapData what it shows now
	var came := await _until(func() -> bool: return md.page(far) != null, READ_TIMEOUT_MS)
	var pg := md.page(far)
	var unseen: bool = pg != null and Array(pg.vision).max() == 0
	_check(came and unseen, "a page %d cells away reads as all unseen (%s)" % [FAR_CELLS, md.note])
	var up := _key_of(&"cutaway_up")
	mv.canvas.center_on_player()
	root.push_input(up)
	await _frames(2)
	var above := MapData.page_origin(Vector3i(me.x, me.y, me.z + 1))
	var shown := await _until(func() -> bool: return md.page(above) != null, READ_TIMEOUT_MS)
	_check(mv.canvas.level == me.z + 1 and shown, "PgUp shows the level above, read from the game")
	root.push_input(_key_of(&"map"))
	await _frames(2)
	_check(not mv.visible and not md.is_open() and md.page(Vector3i(me.x - posmod(me.x, 32), me.y - posmod(me.y, 32),
			me.z)) == null, "M again closes it and drops its pages")


## Slice 2: a note written next to the player through MapData (the calls the dialog and VR's wheel make) reads back
## as CDDA keeps it; an edit replaces it; overlong text is capped; control characters and colour tags are gone; a
## delete removes it; a second delete is refused with CDDA's sentence.
func _note_checks() -> void:
	if not _live.can_map_notes():
		print("  skip  the bridge has no queue_overmap yet: the note checks need lead-bridge's writes")
		return
	var md := _main.map_data
	var mv := _main.map_view
	root.push_input(_key_of(&"map"))
	await _frames(2)
	var me := md.player_cell
	var cell := Vector3i(me.x + 1, me.y, me.z)
	var at := Vector2i(cell.x, cell.y)
	await _until(func() -> bool: return md.page(MapData.page_origin(cell)) != null, READ_TIMEOUT_MS)
	var said := []
	md.note_done.connect(func(tag: int, ok: bool, text: String) -> void: said.append([tag, ok, text]))
	var note_of := func() -> Dictionary: return md.info(at, cell.z).get("note", {})
	# add
	var tag := md.set_note(cell, "<color_red>Cache</color>" + char(7) + " here: north;side", "C", "R", true, 3)
	var done := await _until(func() -> bool: return said.size() == 1, WRITE_TIMEOUT_MS)
	var back := await _until(func() -> bool: return note_of.call().get("text") == "Cache here: north;side",
			READ_TIMEOUT_MS)
	var n: Dictionary = note_of.call()
	_check(tag > 0 and done and said[0][1] and back and n.get("symbol") == "C" and n.get("danger") == true
			and MapData.note_color_code(n.get("color", Color.BLACK)) == "R" and n.get("radius") == 3,
			"a note added at %s reads back as written (colour tags and control characters out): %s %s" % [cell, n, said])
	mv._hover = mv.canvas.to_px(Vector2(at) + Vector2(0.5, 0.5))
	_check(mv.info_text().contains("Note (danger): Cache here: north;side"), "the line under the map shows it: "
			+ mv.info_text())
	# edit
	tag = md.set_note(cell, "Cache moved", "!", "G", false, 0)
	done = await _until(func() -> bool: return said.size() == 2, WRITE_TIMEOUT_MS)
	back = await _until(func() -> bool: return note_of.call().get("text") == "Cache moved", READ_TIMEOUT_MS)
	n = note_of.call()
	_check(tag > 0 and done and said[1][1] and back and n.get("symbol") == "!" and n.get("danger") == false
			and MapData.note_color_code(n.get("color", Color.BLACK)) == "G", "the note edited reads back: %s" % [n])
	# overlong
	tag = md.set_note(cell, "x".repeat(MapData.MAX_NOTE + 150))
	done = await _until(func() -> bool: return said.size() == 3, WRITE_TIMEOUT_MS)
	back = await _until(func() -> bool: return (note_of.call().get("text", "") as String).begins_with("xxx"),
			READ_TIMEOUT_MS)
	_check(tag > 0 and done and back and (note_of.call().get("text", "") as String).length() == MapData.MAX_NOTE,
			"overlong text is capped at %d" % MapData.MAX_NOTE)
	# delete, then again
	tag = md.delete_note(cell)
	done = await _until(func() -> bool: return said.size() == 4, WRITE_TIMEOUT_MS)
	back = await _until(func() -> bool: return note_of.call().is_empty(), READ_TIMEOUT_MS)
	_check(tag > 0 and done and said[3][1] and back, "the note deleted is gone (%s)" % [said.back()])
	tag = md.delete_note(cell)
	done = await _until(func() -> bool: return said.size() == 5, WRITE_TIMEOUT_MS)
	_check(tag > 0 and done and not said[4][1] and not (said[4][2] as String).is_empty(),
			"deleting it again is refused with CDDA's sentence: %s" % [said.back()])
	root.push_input(_key_of(&"map"))
	await _frames(2)


func _stop() -> void:
	_live.stop()
	await _until(func() -> bool: return _live.state != "running", 30000)
	_finish()


## The key bound first to `action`, as a press.
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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


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
	print("map live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
