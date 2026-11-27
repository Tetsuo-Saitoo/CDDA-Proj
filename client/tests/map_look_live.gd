extends SceneTree
## G5 map on a real screen (lead-ui, 2026-11-27): not a test, a look. Main in live mode starts the test range in its
## own CDDA folder (never the player's saves), writes three notes next to the player when the bridge takes notes (a
## green one, a red danger note with radius 2, one whose text starts like CDDA's prefix), opens the map and keeps
## it open for --secs (default 120, 5..1800) so someone can look at it: symbols, roads, fog, notes, the cursor and
## the note dialog. Then it stops the game and quits (exit 0; 1 when the range didn't start). Needs a window (no
## --headless), the DLL and the game data. From the repo root:
##   godot --path client --script res://tests/map_look_live.gd -- --live [--secs=120] [--cdda=<data folder>]

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const WRITE_TIMEOUT_MS := 15000

var _main: Main
var _live: LiveSession
var _answered := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var secs := 120
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--secs="):
			secs = clampi(a.substr(7).to_int(), 5, 1800)
	root.size = Vector2i(1280, 720)
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-map-look")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	var button := _find_button(_main.main_menu, "Test range") if _main.main_menu != null else null
	if button == null:
		print("map look: no Test range button (run with -- --live)")
		quit(1)
		return
	button.pressed.emit()
	if not await _until(func() -> bool: return _live.state == "running" and _main.world.snapshot != null,
			BOOT_TIMEOUT_MS):
		print("map look: the range didn't start: %s %s" % [_live.state, _live.error])
		quit(1)
		return
	var md := _main.map_data
	if _live.can_map_notes():
		var me := md.player_cell
		for n: Array in [[Vector3i(me.x + 1, me.y, me.z), "Cache here", "C", "G", false, 0],
				[Vector3i(me.x + 3, me.y - 2, me.z), "Bandits", "!", "R", true, 2],
				[Vector3i(me.x - 2, me.y + 1, me.z), "R;x: starts like a prefix", "N", "Y", false, 0]]:
			var tag := md.set_note(n[0], n[1], n[2], n[3], n[4], n[5])
			await _until(func() -> bool: return not md.writing(), WRITE_TIMEOUT_MS)
			print("map look: note %s at %s: tag %d" % [n[1], n[0], tag])
	else:
		print("map look: this bridge takes no notes")
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	root.push_input(m)
	print("map look: the map is open for %d s" % secs)
	await _until(func() -> bool: return false, secs * 1000)
	_live.stop()
	await _until(func() -> bool: return _live.state != "running", 30000)
	TestDir.clean()
	quit(0)


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
