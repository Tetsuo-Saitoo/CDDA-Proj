extends RefCounted
## G5 map slice 2 (lead-ui, 2026-11-26; docs/MAP.md): notes. MapData.set_note / delete_note through
## LiveSession.queue_map_note / queue_map_unnote with a stand-in bridge, the map_result answer (done re-reads the page,
## refused gives CDDA's sentence, none gives up after a while), and MapView's note dialog (N, D, a double click). Run
## by run_tests.gd.

const MapTests := preload("res://tests/map_tests.gd")

var _check: Callable


## The map read's stand-in, which also takes the map's writes.
class NoteSim extends MapTests.MapSim:
	var writes: Array = []
	var accept := true

	func queue_overmap(d: Dictionary) -> bool:
		writes.append(d.duplicate())
		return accept


func run(root: Node, check: Callable) -> void:
	_check = check
	_test_rules()
	_test_writes()
	_test_dialog(root)


func _session() -> Array:
	var sim := NoteSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	return [sim, ls]


static func _result(tag: int, ok: bool, text := "") -> Dictionary:
	return {"kind": "map_result", "detail": tag, "amount": 1 if ok else 0, "text": text, "type": 1}


## CDDA's get_note_display_info (overmap_ui.cpp), ported: [symbol, colour code, text] of a stored note; "N" and "Y"
## when the note doesn't set them.
static func _cdda_note(note: String) -> Array:
	var out := ["N", "Y", 0]
	var set_symbol := false
	var set_color := false
	var pos := 0
	for i in 2:
		while pos < note.length() and note[pos] in [" ", ":", ";"]:
			pos += 1
		if pos >= note.length():
			break
		var end := pos
		while end < note.length() and not note[end] in [" ", ":", ";"]:
			end += 1
		if end >= note.length():
			break
		if not set_symbol and note[end] == ":":
			out[0] = note[end - 1]
			out[2] = end + 1
			set_symbol = true
		elif not set_color and note[end] == ";":
			out[1] = note.substr(pos, end - pos)
			out[2] = end + 1
			set_color = true
		pos = end + 1
	return [out[0], out[1], note.substr(out[2])]


func _test_rules() -> void:
	var symbols: bool = MapData.ok_symbol("N") and MapData.ok_symbol("!") and MapData.ok_symbol("~") \
			and not MapData.ok_symbol(":") and not MapData.ok_symbol(";") and not MapData.ok_symbol(" ") \
			and not MapData.ok_symbol("") and not MapData.ok_symbol("NN") and not MapData.ok_symbol("é") \
			and not MapData.ok_symbol(char(0x7F)) and not MapData.ok_symbol("─")
	for ch in MapData.NOTE_SYMBOLS:
		symbols = symbols and MapData.ok_symbol(ch)
	var colors: bool = MapData.NOTE_COLORS.size() == 15 and MapData.note_color_index("Y") == 0 \
			and MapData.note_color_index("lg") > 0 and MapData.note_color_index("x") == -1 \
			and MapData.note_color_index("") == -1 and MapData.note_color_code(Color("#ff0000")) == "R" \
			and MapData.note_color_code(Color(0.3, 0.2, 0.1)) == "Y"
	for e: Array in MapData.NOTE_COLORS:   # the read's colour (CDDA's name) maps back to the code sent
		colors = colors and MapData.note_color_code(MapData._color("c_" + (e[1] as String).replace(" ", "_"))) == e[0]
	var dirty := "  <color_red>Cache</color>" + char(7) + " here:" + char(10) + "north;side" + char(0x2028) + "  "
	var clean := MapData.clean_note(dirty)
	var text: bool = clean == "Cache here: north;side" \
			and MapData.clean_note("x".repeat(600)).length() == MapData.MAX_NOTE_TEXT \
			and MapData.clean_note(" " + char(9) + char(13)).is_empty()
	# CDDA's prefix always goes first, so text that starts like one stays text, read back as CDDA's map reads it
	var prefixed := true
	for case: Array in [["R;x: loot", "N", "Y"], ["x:R;bandits", "!", "R"], [": ; :", "C", "lg"], ["B:Base", "~", "br"]]:
		var stored: String = MapData.note_prefix(case[1], case[2]) + MapData.clean_note(case[0])
		prefixed = prefixed and _cdda_note(stored) == [case[1], case[2], case[0]]
	var longest: bool = (MapData.note_prefix("x", "lg") + "y".repeat(MapData.MAX_NOTE_TEXT)).length() == MapData.MAX_NOTE
	text = text and prefixed and longest
	_check.call(symbols and colors and text, "map notes: a symbol is one printable ASCII character but : and ;, the 15 "
			+ "CDDA note colours and their codes, note text plain on one line and capped (%s, %s)"
			% [[symbols, colors, text], clean])


func _test_writes() -> void:
	var s := _session()
	var sim: NoteSim = s[0]
	var ls: LiveSession = s[1]
	var md := MapData.new()
	var cell := Vector3i(3, 4, 0)
	var unwired: bool = md.set_note(cell, "a") == 0 and md.delete_note(cell) == 0 and not md.can_write()
	md.live = ls
	var done := []
	md.note_done.connect(func(tag: int, ok: bool, text: String) -> void: done.append([tag, ok, text]))
	var refused: bool = md.set_note(cell, "") == 0 and md.set_note(cell, "  ") == 0 \
			and md.set_note(cell, "a", ":") == 0 and md.set_note(cell, "a", "N", "x") == 0 \
			and md.set_note(cell, "a", "N", "Y", true, 21) == 0 and md.set_note(cell, "a", "N", "Y", true, -1) == 0 \
			and md.set_note(Vector3i(1 << 25, 0, 0), "a") == 0 and md.set_note(Vector3i(0, 0, 11), "a") == 0 \
			and ls.queue_map_note(cell, "a" + char(10) + "b", "N", "Y", false, 0) == 0 \
			and ls.queue_map_note(cell, "a", "N", "Y", false, 4) == 0 and sim.writes.is_empty()
	var tag := md.set_note(cell, "Cache <color_red>here</color>", "C", "R", true, 3)
	var sent: bool = tag > 0 and md.writing() and sim.writes.size() == 1 and sim.writes[0] == {"cmd": "note",
			"omt": [3, 4, 0], "text": "C:R;Cache here", "danger": true, "radius": 3, "tag": tag}
	var one_out: bool = md.set_note(cell, "b") == 0 and md.delete_note(cell) == 0 and sim.writes.size() == 1
	md.on_events([_result(tag + 1, true), {"kind": "message", "text": "x"}, "junk"])
	var others: bool = md.writing() and done.is_empty()
	md.on_events([{"kind": "map_result", "detail": tag, "amount": 0, "text": "<color_red>No</color> map" + char(7)
			+ " here."}])
	var said: bool = not md.writing() and done == [[tag, false, "No map here."]]
	var safe := md.set_note(cell, "Quiet", "N", "Y", false, 9)   # no danger: no radius sent
	var calm: bool = safe > 0 and not sim.writes[-1].has("radius") and sim.writes[-1]["danger"] == false \
			and sim.writes[-1]["text"] == "N:Y;Quiet"
	md.on_events([{"kind": "map_result", "detail": safe, "amount": 0, "text": ""}])
	var plain_no: bool = done[-1] == [safe, false, MapData.REFUSED]
	# done: the page holding the cell is read again
	ls.overmap.connect(md.on_page)
	md.player_cell = Vector3i(100, 0, 0)
	md.has_player = true
	md.open()   # the player's page first, then the one shown
	sim.results[sim.next] = JSON.stringify(MapTests._page(sim.next, [96, 0, 0]))
	ls._poll_overmap()
	md.want(Rect2i(0, 0, 10, 10), 0)
	sim.results[sim.next] = JSON.stringify(MapTests._page(sim.next, [0, 0, 0]))
	ls._poll_overmap()
	var before := sim.asked.size()
	var del := md.delete_note(cell)
	var unnote: bool = del > 0 and sim.writes[-1] == {"cmd": "unnote", "omt": [3, 4, 0], "tag": del}
	md.on_events([_result(del, true)])
	var reread: bool = done[-1] == [del, true, ""] and sim.asked.size() == before + 1 \
			and sim.asked[-1] == {"origin": [0, 0, 0]}
	# no answer: given up on the next snapshot after the wait
	var lost := md.set_note(cell, "Lost")
	md._write_at -= MapData.WRITE_TIMEOUT_MS + 1
	md.follow(Snapshot.new())
	var gave_up: bool = lost > 0 and not md.writing() and done[-1] == [lost, false, MapData.NO_ANSWER]
	var late := md.set_note(cell, "Late")
	md.reset()
	var reset_drops: bool = late > 0 and not md.writing() and done[-1] == [late, false, MapData.NO_ANSWER]
	sim.accept = false
	var bridge_no: bool = md.set_note(cell, "a") == 0 and not md.writing()
	md.close()
	_check.call(unwired and refused and sent and one_out and others and said and calm and plain_no and unnote
			and reread and gave_up and reset_drops and bridge_no,
			"map notes: set_note / delete_note send CDDA's note (text cleaned, the danger radius only when dangerous), "
			+ "one at a time, bad input refused here; refused gives CDDA's sentence, done reads the page again, no "
			+ "answer gives up (%s)" % [[unwired, refused, sent, one_out, others, said, calm, plain_no, unnote, reread,
			gave_up, reset_drops, bridge_no]])


func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = true
	return k


func _test_dialog(root: Node) -> void:
	var v := MapView.new()
	v.mouse_hook = func(_set_to: int) -> int: return Input.MOUSE_MODE_VISIBLE
	var md := MapData.new()
	md.player_cell = Vector3i(-31, 2, 0)
	md.has_player = true
	var s := _session()
	var sim: NoteSim = s[0]
	var ls: LiveSession = s[1]
	md.live = ls
	ls.overmap.connect(md.on_page)
	v.data = md
	root.add_child(v)
	v.canvas.size = Vector2(400, 300)
	v.open()
	sim.results[sim.next] = JSON.stringify(MapTests._page(sim.next, [-32, 0, 0]))   # the note "Cache here!" at (-27, 6)
	ls._poll_overmap()
	var picked: bool = v.canvas.has_cursor and v.canvas.cursor == Vector2i(-31, 2)
	# a click picks a cell; a drag doesn't
	var c := v.canvas
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = c.global_position + c.to_px(Vector2(-27.5, 6.5))
	v._gui_input(press)
	press.pressed = false
	v._gui_input(press)
	var clicked: bool = c.cursor == Vector2i(-28, 6)
	press.pressed = true
	press.global_position = c.global_position + c.to_px(Vector2(-26.5, 6.5))
	v._gui_input(press)
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(30, 0)
	drag.global_position = press.global_position + drag.relative
	v._gui_input(drag)
	press.pressed = false
	press.global_position = drag.global_position
	v._gui_input(press)
	var not_dragged: bool = c.cursor == Vector2i(-28, 6)
	c.center_on_player()
	# D on a cell with no note: says so
	c.pick(Vector2i(-20, 3))
	v._hover = Vector2(-1, -1)
	v.handle_key(_key(KEY_D))
	var none: bool = not v.notes.visible and v.info_text() == "(-20, 3)  No note there to delete."
	# N on the noted cell: its note filled in
	c.pick(Vector2i(-27, 6))
	var n_key: bool = v.handle_key(_key(KEY_N)) and v.notes.visible
	var d := v.notes
	var filled: bool = d._text.text == "Cache here!" and d._symbol.get_item_text(d._symbol.selected) == "C" \
			and MapData.NOTE_COLORS[d._color.selected][0] == "Y" and d._danger.button_pressed and d._radius.value == 2 \
			and d._delete.visible and d.cell == Vector3i(-27, 6, 0)
	# while it is open the map's keys are the dialog's: M doesn't close the map, Esc closes only the dialog
	var m := _key(KEY_M)
	v._input(m)
	var kept: bool = v.visible and d.visible and v.handle_key(m) and v.visible
	d._text.text = "Moved <color_red>north</color>"
	d._danger.button_pressed = false
	d.save()
	var w: Dictionary = sim.writes[-1] if not sim.writes.is_empty() else {}
	var saved: bool = w.get("cmd") == "note" and w.get("text") == "C:Y;Moved north" and not w.has("sym") \
			and not w.has("color") and w.get("danger") == false and not w.has("radius") and d._save.disabled \
			and d.said() == MapNoteDialog.WAITING
	md.on_events([_result(w.get("tag", 0), false, "You can't note that.")])
	var refusal: bool = d.visible and d.said() == "You can't note that." and not d._save.disabled
	d.save()
	md.on_events([_result(sim.writes[-1]["tag"], true)])
	var closed_ok: bool = not d.visible and v.visible and md._stale.has(Vector3i(-32, 0, 0))
	# D on the noted cell: asks, then deletes
	v.handle_key(_key(KEY_D))
	var asks: bool = d.visible and d.said() == "Delete this note?"
	d.remove()
	var unnoted: bool = sim.writes[-1].get("cmd") == "unnote" and sim.writes[-1].get("omt") == [-27, 6, 0]
	md.on_events([_result(sim.writes[-1]["tag"], true)])
	# a new note on an empty cell; Esc closes the dialog, the map stays
	c.pick(Vector2i(-25, 4))
	v.handle_key(_key(KEY_N))
	var fresh: bool = d.visible and d._text.text == "" and not d._delete.visible and d.said() == ""
	d.save()
	var empty_no: bool = d.said() == "Write something for the note." and sim.writes[-1].get("cmd") == "unnote"
	v._input(_key(KEY_ESCAPE))
	var esc: bool = not d.visible and v.visible
	# a double click opens it on that cell
	press.pressed = true
	press.double_click = true
	press.global_position = c.global_position + c.to_px(Vector2(-23.5, 5.5))
	v._gui_input(press)
	var double: bool = d.visible and d.cell == Vector3i(-24, 5, 0)
	d._pick_symbol("Z")   # a note's own glyph is offered while it is open, then dropped
	d._pick_symbol("N")
	var glyphs: bool = d._symbol.item_count == MapData.NOTE_SYMBOLS.length()
	v.close()
	var with_map: bool = not d.visible and not v.visible and glyphs
	_check.call(picked and clicked and not_dragged and none and n_key and filled and kept and saved and refusal
			and closed_ok and asks and unnoted and fresh and empty_no and esc and double and with_map,
			"map note dialog: a click picks a cell, a drag doesn't; N fills in the cell's note, M and Esc are the "
			+ "dialog's while it is open, Save sends plain text, a refusal shows CDDA's sentence, done closes it; D "
			+ "asks first, says when there is no note; a double click opens it (%s)" % [[picked, clicked, not_dragged,
			none, n_key, filled, kept, saved, refusal, closed_ok, asks, unnoted, fresh, empty_no, esc, double,
			with_map]])
	root.remove_child(v)
	v.free()
