extends RefCounted
## Block E3 checks, run by run_tests.gd: fake requests (fields as in contracts/bridge_api.md) go into
## RequestUI, keys and clicks are simulated, and each answer must be the one the sim expects and pass the same
## type checks as CddaSim.answer() (bridge/src/cdda_sim.cpp).

const Main := preload("res://scripts/main.gd")

var _check: Callable
var ui: RequestUI
var answers: Array = []


func run(root: Node, check: Callable) -> void:
	_check = check
	ui = RequestUI.new()
	root.add_child(ui)
	ui.answered.connect(func(a: Dictionary) -> void: answers.append(a))
	_test_text()
	_test_menu()
	_test_long_menu()
	_test_key_and_items()
	_test_item_multi()
	_test_popup()
	_test_string()
	_test_number()
	_test_direction()
	_test_target()
	_test_hostile()
	_test_chargen()
	_test_main_menu()
	_test_world_setup()
	_test_game_over(root)
	_test_options()
	_test_hints()
	_test_wheel()
	_test_main_hand(root)
	ui.free()
	_test_hands_panel(root)
	_test_item_tile()
	_test_slosh()


func _req(kind: String, fields: Dictionary, id := 7) -> Dictionary:
	var r := {"id": id, "kind": kind, "context": "", "title": "", "text": "", "entries": [],
			"actions": PackedStringArray(), "allow_cancel": true, "max_len": 0, "mode": "", "status": "",
			"origin": Vector3i.ZERO, "cursor": Vector3i.ZERO, "range": 0, "allow_vertical": false,
			"candidates": [], "timed": false, "turn": 1, "paused": false, "pause_reason": ""}
	r.merge(fields, true)
	return r


func _entries(labels: Array, first_id := 0) -> Array:
	var out := []
	for i in labels.size():
		out.append({"id": first_id + i, "label": labels[i], "enabled": true, "description": ""})
	return out


func _show(req: Dictionary) -> bool:
	answers.clear()
	return ui.show_request(req)


func _key(code: Key, shift := false, unicode := 0) -> bool:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	e.shift_pressed = shift
	e.unicode = unicode
	return ui.handle_input(e)


func _expect(expect: Dictionary, what: String) -> void:
	var ok: bool = answers.size() == 1 and answers[0] == expect and well_formed(answers[0])
	_check.call(ok, "%s -> %s" % [what, answers])


func _expect_none(what: String) -> void:
	_check.call(answers.is_empty(), "%s: no answer (%s)" % [what, answers])


## The checks CddaSim.answer() makes before it sends anything.
static func well_formed(a: Dictionary) -> bool:
	if not (a.get("id") is int and a["id"] >= 1):
		return false
	for k: Variant in a:
		var v: Variant = a[k]
		match k:
			"id":
				pass
			"cancel":
				if not v is bool:
					return false
			"action", "text":
				if not v is String or (v as String).to_utf8_buffer().size() > (64 if k == "action" else 16384):
					return false
			"entry":
				if not v is int:
					return false
			"number":   # contracts/ui_requests.md: an int, never beyond the doubles' whole numbers
				if not v is int or absi(v) > (1 << 53) - 1:
					return false
			"picks":
				if not v is Array or (v as Array).size() > 4096:
					return false
				for p: Variant in v:
					if not (p is Array and p.size() == 2 and p[0] is int and p[1] is int and p[1] >= 0):
						return false
			"pos":
				if not v is Vector3i:
					return false
			_:
				return false
	return true


func _test_text() -> void:
	print("ui: colour tags")
	_check.call(CddaText.to_bbcode("<color_red>hot</color> tea") == "[color=#ff0000]hot[/color] tea", "red tag")
	_check.call(CddaText.to_bbcode("<color_c_light_green>ok</color>") == "[color=#00ff00]ok[/color]", "c_ prefix, light_")
	_check.call(CddaText.to_bbcode("<color_ltred>x") == "[color=#ff9696]x[/color]", "short name, closed at end")
	_check.call(CddaText.to_bbcode("<color_white_red>x</color>") == "[color=#ffffff][bgcolor=#ff0000]x[/bgcolor][/color]", "fg_bg")
	_check.call(CddaText.to_bbcode("<good>+1</good> <bad>-1</bad>") == "[color=#006e00]+1[/color] [color=#ff0000]-1[/color]", "info tags")
	_check.call(CddaText.to_bbcode("[img]x[/img]</color>") == "[lb]img]x[lb]/img]", "BBCode escaped, stray close dropped")
	_check.call(CddaText.to_bbcode("<color_nonsense>a</color> <3 <num>") == "<color_nonsense>a <3 <num>", "unknown tags stay text")
	_check.call(CddaText.plain("<color_i_red>a</color><info>b</info>[c]") == "ab[c]", "plain drops tags only")
	_check.call(CddaText.to_bbcode("<color_red>".repeat(100)).count("[/color]") == CddaText.MAX_DEPTH, "nesting capped")
	_check.call(CddaText.to_bbcode("<".repeat(50000)).length() == CddaText.MAX_CHARS, "length capped")


func _test_menu() -> void:
	print("ui: menu")
	var entries := _entries(["<color_yellow>Wait 5 minutes</color>", "Wait 30 minutes", "Sleep"], 10)
	entries[1]["enabled"] = false
	entries[2]["description"] = "Go to <good>sleep</good>."
	var req := _req("menu", {"title": "Wait for how long?", "entries": entries})
	_check.call(_show(req) and ui.visible and ui.widget is ListRequestWidget, "menu shows a list")
	var w := ui.widget as ListRequestWidget
	_check.call(w.rows.size() == 3 and w.filter_edit == null, "3 rows, no filter for a short menu")
	_key(KEY_DOWN)
	_key(KEY_ENTER)
	_expect_none("Enter on a disabled entry")
	_key(KEY_DOWN)
	_check.call(w._desc != null and w._desc.text.contains("sleep"), "description of the current entry shows")
	_key(KEY_ENTER)
	_expect({"id": 7, "entry": 12}, "Down Down Enter")
	_check.call(not ui.visible and not ui.is_showing(), "hidden after the answer")
	_check.call(not _key(KEY_ENTER) and answers.size() == 1, "nothing more after answering")

	_show(req)
	_key(KEY_2)
	_expect_none("number key on a disabled entry")
	_key(KEY_1)
	_expect({"id": 7, "entry": 10}, "number key 1")
	_show(req)
	(ui.widget as ListRequestWidget).rows[2].pressed.emit()
	_expect({"id": 7, "entry": 12}, "click on the third row")
	_show(req)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "Esc cancels")
	req["allow_cancel"] = false
	_show(req)
	_key(KEY_ESCAPE)
	_expect_none("Esc when the menu can't be cancelled")
	_check.call(ui.is_showing(), "still showing")


func _test_long_menu() -> void:
	print("ui: long menu with filter")
	var labels := []
	for i in 300:
		labels.append("item %d %s" % [i, ["apple", "<color_red>rock</color>", "pipe"][i % 3]])
	_show(_req("menu", {"entries": _entries(labels, 100), "id": 9}))
	var w := ui.widget as ListRequestWidget
	_check.call(w.filter_edit != null, "filter shows for 300 entries")
	_check.call(w.rows.size() == ListRequestWidget.MAX_ROWS and w._more.visible, "rows capped at %d, '... more' shown" % w.rows.size())
	w.set_filter("ROCK")
	_check.call(w.rows.size() == 100, "filter (any case, tags ignored) leaves 100 rows")
	_key(KEY_PAGEDOWN)
	_key(KEY_DOWN)
	_check.call(w.selected == 11, "PgDn + Down moves 11 rows (%d)" % w.selected)
	_key(KEY_1)
	_expect_none("number keys type into the filter of a long menu")
	_key(KEY_ENTER)
	_expect({"id": 9, "entry": 100 + 34}, "Enter picks the filtered entry's own id")
	_show(_req("menu", {"entries": _entries(labels, 100), "id": 9}))
	w = ui.widget as ListRequestWidget
	w.set_filter("zzz")
	_check.call(w.rows.is_empty() and w._more.text == "(no match)", "no match shows a note")
	_key(KEY_ENTER)
	_expect_none("Enter with nothing shown")
	_key(KEY_ESCAPE)
	_check.call(answers.is_empty() and w.filter_edit.text.is_empty() and w.rows.size() == 200, "first Esc clears the filter")
	_key(KEY_ESCAPE)
	_expect({"id": 9, "cancel": true}, "second Esc cancels")


func _test_key_and_items() -> void:
	print("ui: key, item_select")
	_show(_req("key", {"context": "LOOK", "actions": PackedStringArray(["CONFIRM", "QUIT", "LIST_ITEMS"])}))
	_check.call(ui.widget is ListRequestWidget and (ui.widget as ListRequestWidget).rows.size() == 3, "key lists its actions")
	_key(KEY_DOWN)
	_key(KEY_DOWN)
	_key(KEY_ENTER)
	_expect({"id": 7, "action": "LIST_ITEMS"}, "key answers the action id")
	_show(_req("key", {"context": "RAW_KEY"}))
	_check.call(ui.widget is PopupRequestWidget, "key without actions is 'press any key'")
	_key(KEY_A)
	_expect({"id": 7, "action": " "}, "any key answers a space")
	_show(_req("item_select", {"title": "Eat what?", "entries": _entries(["apple", "bread"])}))
	_key(KEY_DOWN)
	_key(KEY_KP_ENTER)
	_expect({"id": 7, "entry": 1}, "item_select answers the entry")


func _test_item_multi() -> void:
	print("ui: item_multi")
	var req := _req("item_multi", {"title": "Pick up", "entries": _entries(["apple", "rock (12)", "pipe"])})
	_show(req)
	var w := ui.widget as ListRequestWidget
	_check.call(w.count_spin != null, "count box shows")
	_key(KEY_SPACE)
	_key(KEY_DOWN)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	_check.call(w.count_spin.value == 2.0, "count box follows the current entry")
	_key(KEY_RIGHT, true)
	_key(KEY_LEFT)
	_key(KEY_ENTER)
	_expect({"id": 7, "picks": [[0, 0], [1, 11]]}, "Space ticks (all), Right x2 + Shift+Right - Left = 11")
	_show(req)
	_key(KEY_DOWN)
	_key(KEY_DOWN)
	_key(KEY_ENTER)
	_expect({"id": 7, "picks": [[2, 0]]}, "Enter with nothing ticked takes the current entry")
	_show(req)
	w = ui.widget as ListRequestWidget
	_click(w, 1)
	w.rows[1].mouse_entered.emit()
	w.count_spin.set_value_no_signal(5)
	w.count_spin.value_changed.emit(5.0)   # as when the player types in the box
	_click(w, 0)
	_click(w, 0)
	_key(KEY_ENTER)
	_expect({"id": 7, "picks": [[1, 5]]}, "click ticks, count box sets 5, second click unticks")
	_test_multi_drag()
	_show(req)
	w = ui.widget as ListRequestWidget
	w.toggle_all()
	w.confirm()
	_expect({"id": 7, "picks": [[0, 0], [1, 0], [2, 0]]}, "All ticks everything")
	_show(req)
	_key(KEY_LEFT)
	_key(KEY_TAB)
	_key(KEY_TAB)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "Tab toggles, Esc cancels")


## A left click on list row `row` as Godot gives it to the row: press, then release.
func _click(w: ListRequestWidget, row: int, shift := false) -> void:
	for down: bool in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.shift_pressed = shift
		w.rows[row].gui_input.emit(e)


## Mouse motion with the left button down, at `y` relative to the row pressed (`row`), as Godot sends it there.
func _drag(w: ListRequestWidget, row: int, y: float, held := true) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(10, y)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	w.rows[row].gui_input.emit(e)


func _ticked(w: ListRequestWidget) -> Array:
	var out := []
	for id: Variant in w.picks:
		out.append(id)
	out.sort()
	return out


func _test_multi_drag() -> void:
	var req := _req("item_multi", {"title": "Drop", "entries": _entries(["a", "b", "c", "d", "e", "f", "g"])})
	_show(req)
	var w := ui.widget as ListRequestWidget
	for r in w.rows.size():   # laid out as the list would be (no layout pass in a test)
		w.rows[r].position = Vector2(0, r * 40.0)
		w.rows[r].size = Vector2(200, 32)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	w.rows[1].gui_input.emit(down)
	_drag(w, 1, 75.0)   # 30 + 75 = row 3: rows 1..3 ticked, none skipped
	_check.call(_ticked(w) == [1, 2, 3] and w.selected == 3, "drag: a press and a drag over rows tick them all (%s)"
			% [_ticked(w)])
	_drag(w, 1, -100.0)   # above the list: up to the first row
	_check.call(_ticked(w) == [0, 1, 2, 3], "drag: past the top ticks up to the first row (%s)" % [_ticked(w)])
	_drag(w, 1, 500.0, false)   # the button was let go somewhere else: the drag is over
	_drag(w, 1, 150.0)
	_check.call(_ticked(w) == [0, 1, 2, 3], "drag: motion without the button ends it (%s)" % [_ticked(w)])
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	w.rows[1].gui_input.emit(up)
	w.rows[2].gui_input.emit(down)   # a press on a ticked row: the drag unticks
	_drag(w, 2, 40.0)
	w.rows[2].gui_input.emit(up)
	_check.call(_ticked(w) == [0, 1], "drag from a ticked row unticks the rows passed (%s)" % [_ticked(w)])
	_click(w, 5, true)   # Shift+click: rows 2..5 as row 2 is (unticked)
	_check.call(_ticked(w) == [0, 1], "Shift+click sets the run as the last clicked row is (%s)" % [_ticked(w)])
	_click(w, 4)
	_click(w, 6, true)
	_check.call(_ticked(w) == [0, 1, 4, 5, 6], "Shift+click after a tick ticks the run (%s)" % [_ticked(w)])
	answers.clear()
	_key(KEY_ENTER)
	_expect({"id": 7, "picks": [[0, 0], [1, 0], [4, 0], [5, 0], [6, 0]]}, "the ticked rows are taken")
	_show(req)
	w = ui.widget as ListRequestWidget
	_key(KEY_DOWN, true)
	_key(KEY_DOWN, true)
	_check.call(_ticked(w) == [0, 1, 2] and w.selected == 2, "Shift+Down ticks the rows moved over (%s)"
			% [_ticked(w)])
	var dis := _entries(["x", "y", "z"])
	dis[1]["enabled"] = false
	_show(_req("item_multi", {"entries": dis}))
	w = ui.widget as ListRequestWidget
	_click(w, 0)
	_click(w, 2, true)
	_click(w, 1)
	_check.call(_ticked(w) == [0, 2], "a disabled row is never ticked, a click on it does nothing (%s)"
			% [_ticked(w)])
	var dis4 := _entries(["x", "y", "z", "v"])
	dis4[1]["enabled"] = false
	_show(_req("item_multi", {"entries": dis4}))
	w = ui.widget as ListRequestWidget
	_click(w, 0)
	_key(KEY_DOWN, true)   # onto the disabled row: it stays unticked and isn't the anchor
	_click(w, 3, true)
	_check.call(_ticked(w) == [0, 2, 3], "Shift+click after Shift+Down onto a disabled row ticks from the last ticked one (%s)"
			% [_ticked(w)])
	_show(_req("item_select", {"entries": _entries(["p", "q"])}))
	w = ui.widget as ListRequestWidget
	w.press_row(0, true)
	w.set_rows(0, 1, true)
	_check.call(w.picks.is_empty() and answers.is_empty(), "item_select: nothing is ticked by a press or a run")
	w.rows[1].pressed.emit()
	_expect({"id": 7, "entry": 1}, "item_select: a click still picks")


func _test_popup() -> void:
	print("ui: popup")
	var req := _req("popup", {"context": "YESNO", "text": "Really <color_red>eat</color> it?",
			"actions": PackedStringArray(["YES", "NO"])})
	_show(req)
	var w := ui.widget as PopupRequestWidget
	_check.call(w.buttons.size() == 2 and w.buttons[0].text.ends_with("Yes"), "one button per action")
	var n := InputEventKey.new()
	n.keycode = KEY_N
	n.physical_keycode = KEY_N
	n.pressed = true
	var menu_open := [true]   # lambdas capture locals by value: an array they share
	ui.held = func() -> bool: return menu_open[0]
	ui._input(n)   # typing "n" in the F1 menu's item field
	_check.call(answers.is_empty() and ui.visible, "a key while the F1 menu holds the keys doesn't answer the prompt")
	menu_open[0] = false
	ui._input(n)
	ui.held = Callable()
	_expect({"id": 7, "action": "NO"}, "N answers NO")
	_show(req)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	_key(KEY_ENTER)
	_expect({"id": 7, "action": "YES"}, "Right wraps around, Enter presses")
	_show(req)
	(ui.widget as PopupRequestWidget).buttons[1].pressed.emit()
	_expect({"id": 7, "action": "NO"}, "click")
	_show(req)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "Esc cancels")
	req["allow_cancel"] = false
	_show(req)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "action": "NO"}, "Esc answers NO when the popup can't be cancelled")
	_show(_req("popup", {"text": "You feel hungry.", "actions": PackedStringArray(["CONFIRM"]), "allow_cancel": false}))
	_key(KEY_SPACE)
	_expect({"id": 7, "action": "CONFIRM"}, "message popup: Space confirms")
	_show(_req("not_a_kind", {"title": "How many?"}))
	_check.call(ui.widget is PopupRequestWidget and (ui.widget as PopupRequestWidget).actions.is_empty(), "unknown kind: text only")
	_key(KEY_ENTER)
	_expect_none("unknown kind: Enter")
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "unknown kind: Esc cancels")


func _test_string() -> void:
	print("ui: string")
	var req := _req("string", {"title": "Name", "text": "Name your <info>character</info>", "max_len": 10,
			"entries": [{"id": 0, "label": "Bob", "enabled": true, "description": "default"}]})
	_show(req)
	var w := ui.widget as StringRequestWidget
	_check.call(w.edit.text == "Bob" and w.edit.max_length == 10, "default text, max_len")
	_check.call(not _key(KEY_A), "letters go to the text field")
	_key(KEY_ENTER)
	_expect({"id": 7, "text": "Bob"}, "Enter sends the text")
	_show(req)
	w = ui.widget as StringRequestWidget
	w.edit.text = "A\tB\u0001C\u0085D"
	_key(KEY_ENTER)
	_expect({"id": 7, "text": "ABCD"}, "control characters stripped")
	_show(req)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "Esc cancels")
	_show(_req("string", {"max_len": 0}))
	w = ui.widget as StringRequestWidget
	w.edit.max_length = 0
	w.edit.text = "é".repeat(900)
	w.submit()
	_check.call(answers.size() == 1 and well_formed(answers[0]) and (answers[0]["text"] as String).length() == 512,
			"multi-byte text cut to 1024 bytes")
	_test_text_keys()


## `number` requests: the default in the field, Enter sends it as an int, Esc cancels; Up / Down and -1 / +1 step
## within the range; a text that isn't a whole number in the range isn't sent and the line under the field says
## so; the bridge's re-ask status is shown cleaned; a broken range is taken the right way round.
func _test_number() -> void:
	print("ui: number")
	var req := _req("number", {"title": "How many?", "text": "Drop how many?", "min": 1, "max": 20, "default": 5})
	_show(req)
	var w := ui.widget as NumberRequestWidget
	_check.call(w != null and w.edit.text == "5" and w.lo == 1 and w.hi == 20 and not w.problem.visible
			and w.show_keys == ui.keyboard, "number: a NumberRequestWidget with the default and the range")
	_key(KEY_UP)
	_key(KEY_UP)
	_key(KEY_DOWN)
	_check.call(w.edit.text == "6" and answers.is_empty(), "number: Up / Down step it (%s)" % w.edit.text)
	_key(KEY_ENTER)
	_expect({"id": 7, "number": 6}, "number: Enter sends it as an int")
	_show(req)
	w = ui.widget as NumberRequestWidget
	for bad: String in ["21", "0", "abc", "1.5", "", "- 3", "1e3", "12345678901234567"]:
		w.edit.text = bad
		_key(KEY_ENTER)
	_check.call(answers.is_empty() and w.problem.visible and w.problem.text == "Enter a whole number from 1 to 20.",
			"number: out of range or not a whole number isn't sent; it says why (%s)" % w.problem.text)
	w.edit.text = " +20 "
	_key(KEY_ENTER)
	_expect({"id": 7, "number": 20}, "number: a sign and spaces around are fine")
	_show(req)
	w = ui.widget as NumberRequestWidget
	w.edit.text = "x"
	w.step(1)
	w.step(100)
	_check.call(w.edit.text == "20" and not w.problem.visible, "number: +1 from no number starts at the range, "
			+ "stepping stops at max (%s)" % w.edit.text)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "number: Esc cancels")
	_show(_req("number", {"min": 50, "max": -50, "default": 9.5, "status": "<color_red>enter a whole</color>" + char(7) + " number"}))
	w = ui.widget as NumberRequestWidget
	_check.call(w.lo == -50 and w.hi == 50 and w.edit.text == "0" and w.problem.visible
			and w.problem.text == "enter a whole number", "number: a broken range turned round, a non-whole default "
			+ "dropped, the status cleaned (%s)" % w.problem.text)
	_show(_req("number", {"min": -1e300, "max": INF, "default": -(1 << 60)}))
	w = ui.widget as NumberRequestWidget
	_check.call(w.lo == -NumberRequestWidget.LIMIT and w.hi == NumberRequestWidget.LIMIT
			and w.edit.text == str(-NumberRequestWidget.LIMIT)
			and NumberRequestWidget.range_text(-(1 << 31), (1 << 31) - 1) == "A whole number."
			and NumberRequestWidget.range_text(1, 20) == "A whole number from 1 to 20.",
			"number: huge or infinite limits held to the doubles' whole numbers; the range in words")
	w.edit.text = str(NumberRequestWidget.LIMIT)
	_key(KEY_ENTER)
	_check.call(answers.size() == 1 and well_formed(answers[0]) and answers[0]["number"] == NumberRequestWidget.LIMIT,
			"number: the largest whole number goes through")


## The on-screen keyboard under a text prompt: hidden on screen until the Keyboard button, shown from the start
## with RequestUI.keyboard (the VR panel); Shift gives one capital, Back deletes, typing replaces a selection,
## max_len holds, and the answer is the text typed.
func _test_text_keys() -> void:
	var req := _req("string", {"title": "Name", "max_len": 6,
			"entries": [{"id": 0, "label": "Bob", "enabled": true, "description": "default"}]})
	_show(req)
	var w := ui.widget as StringRequestWidget
	_check.call(w.keys != null and not w.keys.visible and w.keys.keys.size() == 40, "keys: hidden on screen at first")
	w.keys_button.pressed.emit()
	var k := w.keys
	_check.call(k.visible and k.target == w.edit, "keys: the Keyboard button shows them")
	w.edit.select_all()
	k.shift_button.pressed.emit()
	_press(k, "A")
	_press(k, "n")
	_press(k, "x")
	k.back_button.pressed.emit()
	_press(k, "n")
	k.space_button.pressed.emit()
	for c in "123":
		_press(k, c)
	_check.call(w.edit.text == "Ann 12" and not k.shift and k.keys[10].text == "q",
			"keys: Shift for one capital, Back deletes, the selection is replaced, max_len holds (%s)" % w.edit.text)
	w.submit()
	_expect({"id": 7, "text": "Ann 12"}, "keys: the typed text is sent")
	ui.keyboard = true
	_show(req)
	w = ui.widget as StringRequestWidget
	_check.call(w.keys.visible, "keys: shown from the start on the VR panel")
	w.edit.caret_column = 0
	w.keys.back_button.pressed.emit()
	w.keys.target = null
	_press(w.keys, "z")
	_check.call(w.edit.text == "Bob", "keys: Back at the start and no target do nothing")
	ui.keyboard = false
	ui.clear()


## Presses the key labelled `label` on `k`.
func _press(k: TextKeys, label: String) -> void:
	for b in k.keys:
		if b.text == label:
			b.pressed.emit()
			return


func _test_direction() -> void:
	print("ui: direction")
	var req := _req("direction", {"text": "Open where?", "origin": Vector3i(5, 6, 0)})
	_show(req)
	_check.call(ui.widget is DirectionRequestWidget and (ui.widget as DirectionRequestWidget).pad.size() == 9, "3x3 pad")
	_key(KEY_UP)
	_expect({"id": 7, "pos": Vector3i(0, -1, 0)}, "Up = north by default")
	_show(req)
	_key(KEY_KP_3)
	_expect({"id": 7, "pos": Vector3i(1, 1, 0)}, "KP3 = south-east")
	_show(req)
	_key(KEY_PERIOD, false, ord("."))
	_expect({"id": 7, "pos": Vector3i.ZERO}, ". = here")
	_show(req)
	_key(KEY_COMMA, true, ord("<"))
	_expect_none("< without allow_vertical")
	(ui.widget as DirectionRequestWidget).pad[4].pressed.emit()
	_expect({"id": 7, "pos": Vector3i.ZERO}, "click Here")
	req["allow_vertical"] = true
	_show(req)
	_key(KEY_PERIOD, true, ord(">"))
	_expect({"id": 7, "pos": Vector3i(0, 0, -1)}, "> = down with allow_vertical")
	# A camera looking east: ahead is +x, right is +y (south).
	ui.direction_mapper = func(v: Vector2) -> Vector2i: return Vector2i(roundi(v.y), roundi(v.x))
	_show(req)
	_key(KEY_UP)
	_expect({"id": 7, "pos": Vector3i(1, 0, 0)}, "mapper: Up = ahead = east")
	_show(req)
	(ui.widget as DirectionRequestWidget).pad[5].pressed.emit()
	_expect({"id": 7, "pos": Vector3i(0, 1, 0)}, "mapper: click right = south")
	ui.direction_mapper = func(_v: Vector2) -> Vector2i: return Vector2i(5, 0)
	_show(req)
	_key(KEY_LEFT)
	_expect({"id": 7, "pos": Vector3i(-1, 0, 0)}, "a bad mapper result falls back to north-up")
	ui.direction_mapper = Callable()
	_show(req)
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "Esc cancels")


func _test_target() -> void:
	print("ui: target")
	var o := Vector3i(100, 200, 0)
	var req := _req("target", {"mode": "fire", "origin": o, "cursor": o, "range": 5, "status": "out_of_range",
			"candidates": [o + Vector3i(4, -2, 0), o + Vector3i(1, 0, 0), o + Vector3i(500, 0, 0), "junk"],
			"actions": PackedStringArray(["AIM", "FIRE", "SWITCH_MODE"])})
	_show(req)
	var w := ui.widget as TargetRequestWidget
	_check.call(w.candidates == [o + Vector3i(1, 0, 0), o + Vector3i(4, -2, 0)], "candidates: nearest first, junk and far ones dropped")
	_check.call(w.action_buttons.size() == 3, "a button per action")
	_key(KEY_TAB)
	_check.call(w.cursor == o + Vector3i(1, 0, 0), "Tab goes to the nearest")
	_key(KEY_TAB)
	_key(KEY_ENTER)
	_expect({"id": 7, "pos": o + Vector3i(4, -2, 0), "action": "FIRE"}, "Tab Tab Enter fires at the second")
	_show(req)
	_key(KEY_RIGHT)
	_key(KEY_RIGHT)
	_key(KEY_UP)
	_key(KEY_COMMA, true, ord("<"))
	_key(KEY_SPACE)
	_expect({"id": 7, "pos": o + Vector3i(2, -1, 1)}, "arrows and < move the cursor, Space checks the square")
	_show(req)
	_key(KEY_TAB, true)
	_key(KEY_1)
	_expect({"id": 7, "pos": o + Vector3i(4, -2, 0), "action": "AIM"}, "Shift+Tab wraps to the last, 1 presses AIM")
	_show(req)
	w = ui.widget as TargetRequestWidget
	_check.call(ui.set_target_cursor(o + Vector3i(0, 9999, -50)), "set_target_cursor works on a target request")
	_check.call(w.cursor == Vector3i(o.x, o.y + TargetRequestWidget.REACH, -10), "cursor clamped near the origin")
	w.candidate_buttons[0].pressed.emit()
	w.action_buttons[2].pressed.emit()
	_expect({"id": 7, "pos": o + Vector3i(1, 0, 0), "action": "SWITCH_MODE"}, "click a creature, click an action")
	_show(_req("target", {"mode": "look", "origin": o, "cursor": o}))
	_key(KEY_ENTER)
	_expect({"id": 7, "pos": o}, "no actions: Enter checks the square")
	_check.call(not ui.set_target_cursor(o), "set_target_cursor needs a target request")
	_test_target_names(o)


## Candidates named from the snapshot and id tables (main.gd's world_state); names are plain text.
func _test_target_names(o: Vector3i) -> void:
	var tables := IdTables.from_data({"ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [], "itype": [],
			"mtype": [{"id": "mon_null"}, {"id": "mon_zombie", "name": "zombie"},
			{"id": "mon_odd", "name": "[b]odd[/b]\nthing" + "x".repeat(100)}]})
	_check.call(tables.is_valid(), "target names: test tables (%s)" % tables.error)
	var mon := Snapshot.Creature.MONSTER
	var snap := Snapshot.new()
	for r: Array in [[mon, 1, Vector3i(1, 0, 0), 255, Snapshot.Creature.UNKNOWN],
			[Snapshot.Creature.NPC, 0, Vector3i(4, -2, 0), 100, Snapshot.Creature.FRIENDLY],
			[mon, 2, Vector3i(2, 2, 0), 10, Snapshot.Creature.NEUTRAL], [mon, 99, Vector3i(-5, 0, 0), 0, Snapshot.Creature.HOSTILE]]:
		var c := Snapshot.Creature.new()
		c.kind = r[0]
		c.type = r[1]
		c.pos = o + (r[2] as Vector3i)
		c.hp_frac = r[3]
		c.attitude = r[4]
		snap.creatures.append(c)
	snap.creatures_moved()
	ui.world_state = func() -> Array: return [snap, tables]
	var req := _req("target", {"mode": "fire", "origin": o, "cursor": o, "actions": PackedStringArray(["FIRE"]),
			"candidates": [o + Vector3i(1, 0, 0), o + Vector3i(4, -2, 0), o + Vector3i(2, 2, 0), o + Vector3i(3, 0, 0),
			o + Vector3i(-5, 0, 0)]})
	_show(req)
	var w := ui.widget as TargetRequestWidget
	var texts := []
	for b in w.candidate_buttons:
		texts.append(b.text)
	var odd := "[b]odd[/b] thing" + "x".repeat(TargetRequestWidget.MAX_NAME_CHARS - 16)
	_check.call(texts == ["zombie (hostile, uninjured)   1 E   (1)", odd + " (neutral, nearly dead)   2 S, 2 E   (2)",
			"3 E   (3)", "someone (friendly, heavily injured)   2 N, 4 E   (4)", "creature (hostile, nearly dead)   5 W   (5)"],
			"target names: name, attitude and health per creature; NPCs someone, unknown types creature %s" % [texts])
	var cols := []
	for b in w.candidate_buttons:
		cols.append(b.get_theme_color("font_color") if b.has_theme_color_override("font_color") else null)
	_check.call(cols == [TargetRequestWidget.HOSTILE_TEXT, null, null, TargetRequestWidget.FRIENDLY_TEXT,
			TargetRequestWidget.HOSTILE_TEXT], "target names: hostile red, friendly green, others plain")
	_check.call(TargetRequestWidget.health_words(204) == "lightly injured" and TargetRequestWidget.health_words(-3) == "nearly dead",
			"target names: health in words")
	for bad: Callable in [func() -> Variant: return ["x", 5], func() -> Variant: return null,
			func() -> Variant: return [tables, snap], Callable()]:
		ui.world_state = bad
		_show(req)
		w = ui.widget as TargetRequestWidget
		_check.call(w.candidate_buttons[0].text == "1 E   (1)", "target names: a bad world state names nothing")
	ui.world_state = Callable()
	ui.clear()


func _test_hostile() -> void:
	print("ui: malformed requests")
	_check.call(not _show({}), "empty request refused")
	_check.call(not _show(_req("menu", {"id": "7"})), "string id refused")
	_check.call(not _show(_req("menu", {"id": 0})), "id 0 refused")
	_check.call(not _show(_req("menu", {"kind": 5})), "kind not a string refused")
	_check.call(_show(_req("menu", {"id": 3.0, "entries": _entries(["a"])})), "integral float id accepted")
	_key(KEY_ENTER)
	_expect({"id": 3, "entry": 0}, "and answered as int")
	var junk := [5, "x", {"id": "1", "label": "bad id"}, {"id": 1.5, "label": "fraction"},
			{"id": 4, "label": 42, "enabled": "yes"}, {"label": "no id"}]
	_show(_req("item_select", {"entries": junk, "title": 12, "text": null}))
	var w := ui.widget as ListRequestWidget
	_check.call(w.items.size() == 1 and w.items[0]["id"] == 4 and w.items[0]["label"] == "" and w.items[0]["enabled"],
			"bad entries skipped, bad fields defaulted")
	_show(_req("key", {"actions": ["OK", "", 7, "X".repeat(65)]}))
	_check.call((ui.widget as ListRequestWidget).items.size() == 1, "empty, non-string and over-long actions dropped")
	_show(_req("menu", {"entries": _entries(["x".repeat(5000)])}))
	_check.call(((ui.widget as ListRequestWidget).items[0]["label"] as String).length() == RequestWidget.MAX_LABEL, "labels capped")
	_show(_req("menu", {"entries": _entries(["a", "b"]), "allow_cancel": "no"}))
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "allow_cancel of the wrong type counts as allowed")
	var many := []
	for i in 5000:
		many.append({"id": i, "label": "x", "enabled": true, "description": ""})
	_show(_req("item_multi", {"entries": many}))
	w = ui.widget as ListRequestWidget
	_check.call(w.items.size() == RequestWidget.MAX_ENTRIES, "entries capped at %d" % RequestWidget.MAX_ENTRIES)
	for it: Dictionary in w.items:
		w.picks[it["id"]] = 0
	w.confirm()
	_check.call(answers.size() == 1 and well_formed(answers[0]) and (answers[0]["picks"] as Array).size() == 4096,
			"picks capped at 4096")
	_show(_req("menu", {"entries": _entries(["a"])}))
	_show(_req("popup", {"actions": PackedStringArray(["CONFIRM"]), "id": 8}))
	_key(KEY_ENTER)
	_expect({"id": 8, "action": "CONFIRM"}, "a new request replaces the old one")
	ui.clear()
	_check.call(not ui.visible and not _key(KEY_ENTER), "clear hides and ignores keys")


## The live hands panel: text and level from get_held() data, junk clamped.
func _test_hands_panel(root: Node) -> void:
	var can := {"id": "jerrycan", "name": "plastic jerrycan", "liquid": "gasoline", "ml": 1300, "capacity_ml": 10000}
	_check.call(HandsPanel.hand_text("Left", can) == "Left: plastic jerrycan - gasoline 1.3 / 10.0 L",
			"hands: container text (%s)" % HandsPanel.hand_text("Left", can))
	_check.call(HandsPanel.hand_text("Right", {"name": "rubber hose", "ml": 0, "capacity_ml": 0}) == "Right: rubber hose",
			"hands: plain item")
	_check.call(HandsPanel.hand_text("Left", {}) == "Left: -", "hands: empty hand")
	_check.call(is_equal_approx(HandsPanel.fill_ratio(can), 0.13), "hands: fill ratio")
	_check.call(HandsPanel.fill_ratio({"name": "x", "ml": 99999, "capacity_ml": 10}) == 1.0
			and HandsPanel.fill_ratio({"name": "x", "ml": -5, "capacity_ml": 10}) == 0.0
			and HandsPanel.fill_ratio({"name": "x", "ml": "lots", "capacity_ml": [1]}) == -1.0, "hands: junk clamped")
	var panel := HandsPanel.new()
	root.add_child(panel)
	panel.show_held({"seq": 3, "main": {"name": "rubber hose"}, "off": can, "activity": "ACT_FILL_LIQUID"})
	_check.call(panel.visible, "hands: panel shows while something is held")
	panel.show_held({"seq": 4, "main": {}, "off": "junk", "activity": 5})
	_check.call(not panel.visible, "hands: hidden with empty hands (junk off hand ignored)")
	panel.free()
	# VR: the same data on a controller, label plus a level gauge.
	var vh := VrHeld.new("Left")
	root.add_child(vh)
	vh.show_hand(can, true)
	_check.call(vh.visible and is_equal_approx(vh.ratio, 0.13), "hands: VR gauge at the can's level")
	vh.show_hand({"name": "rubber hose"}, false)
	_check.call(vh.visible and vh.ratio == -1.0, "hands: VR plain item, no gauge")
	vh.show_hand({}, false)
	_check.call(not vh.visible, "hands: VR empty hand hidden")
	vh.free()


## Live item tiles, slice 1: ItemTile from a state [temp, rot, fill, fill_type, see_through, fill_ml, dirt] (values
## and colours as ItemLook / GunGrime say); a missing or hostile state shows nothing; ItemTileView takes no mouse.
func _test_item_tile() -> void:
	var t := IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "juice", "name": "orange <color_red>juice</color>", "color": "c_yellow"},
			{"id": "odd"}]})
	_check.call(t.is_valid(), "tile: test tables load (%s)" % t.error)
	var jug := ItemTile.of(PackedInt32Array([ItemLook.Temp.COLD, -1, 250, 1, 1, 250, -1]), t)
	var cold: Color = jug["temp_color"]
	_check.call(is_equal_approx(jug["level"], 0.25) and jug["amount"] == "250 ml" and jug["see_through"]
			and jug["liquid"] == CddaPalette.NAMED["yellow"] and jug["contents"] == "orange juice"
			and jug["temp"] == ItemLook.Temp.COLD and Color(cold, 1.0) == Color(ItemLook.COLD_TINT, 1.0) and cold.a > 0.0
			and jug["rot"] == -1 and (jug["rot_color"] as Color).a == 0.0 and jug["grime"] == -1.0 and ItemTile.shows(jug),
			"tile: a cold jug a quarter full of juice, 250 ml, in the juice's colour (%s)" % [jug])
	_check.call(ItemTile.words(jug) == "Cold\n250 ml orange juice, 25% full", "tile: in words (%s)" % ItemTile.words(jug).replace("\n", " | "))
	var big := ItemTile.of(PackedInt32Array([0, -1, 1000, 2, 0, 1500, -1]), t)
	var plain := ItemTile.of([0, -1, 600, 1, 0, 600, -1], null)
	_check.call(big["level"] == 1.0 and big["amount"] == "1.5 L" and not big["see_through"]
			and big["liquid"] == ItemLook.LIQUID_DEFAULT and big["contents"] == "odd" and big["temp"] == ItemLook.Temp.NORMAL
			and (big["temp_color"] as Color).a == 0.0 and plain["liquid"] == ItemLook.LIQUID_DEFAULT
			and plain["contents"] == "" and plain["amount"] == "600 ml",
			"tile: full, litres; no colour or no tables: the default liquid colour (%s)" % [big])
	var texts := [0, -5, 1, 999, 1000, 1049, 1050, 1949, 10000, 123456, ItemLook.ML_MAX, ItemLook.ML_MAX + 1].map(
			func(ml: int) -> String: return ItemTile.amount_text(ml))
	_check.call(texts == ["", "", "1 ml", "999 ml", "1 L", "1 L", "1.1 L", "1.9 L", "10 L", "123.5 L", "100000 L", ""],
			"tile: amount text in ml below a litre, then to a tenth of a litre %s" % [texts])
	var frozen := ItemTile.of(PackedInt32Array([ItemLook.Temp.FROZEN, 0, -1, 0, 0, -1, -1]), t)
	var hot := ItemTile.of(PackedInt32Array([ItemLook.Temp.HOT, -1, -1, 0, 0, -1, -1]), t)
	_check.call(frozen["temp"] == ItemLook.Temp.FROZEN and Color(frozen["temp_color"], 1.0) == Color(ItemLook.FROST, 1.0)
			and hot["temp"] == ItemLook.Temp.HOT and Color(hot["temp_color"], 1.0) == Color(ItemLook.HEAT, 1.0)
			and (frozen["temp_color"] as Color).a > cold.a and frozen["level"] == -1.0 and frozen["amount"] == ""
			and ItemTile.words(hot) == "Hot", "tile: frozen and hot edges in ItemLook's colours, frozen the strongest")
	var old := ItemTile.of(PackedInt32Array([0, 950, -1, 0, 0, -1, -1]), t)
	_check.call(frozen["rot"] == 0 and frozen["rot_color"] == ItemLook.FRESH_COLOR and old["rot"] == 950
			and old["rot_color"] == ItemLook.rot_color(950) and ItemTile.shows(old)
			and ItemTile.words(old) == "Spoilage 95% (old)" and ItemTile.words(frozen) == "Frozen\nSpoilage 0% (fresh)",
			"tile: spoilage in rot_color for things that rot (%s)" % ItemTile.words(old))
	var gun := ItemTile.of(PackedInt32Array([0, -1, -1, 0, 0, -1, 4000]), t)
	var clean := ItemTile.of(PackedInt32Array([0, -1, -1, 0, 0, -1, 0]), t)
	_check.call(is_equal_approx(gun["grime"], GunGrime.grime_for(4000)) and is_equal_approx(gun["grime"], 0.4)
			and ItemTile.shows(gun) and ItemTile.words(gun) == "Fouling 40%" and clean["grime"] == 0.0
			and not ItemTile.shows(clean), "tile: a fouled gun's grime as its model shows it; a clean one shows nothing")
	var none := ItemTile.of(null, null)
	var empty_pack := ItemTile.of(PackedInt32Array([0, -1, 0, 0, 0, 0, -1]), t)
	var missing := [ItemTile.of(PackedInt32Array(), t), ItemTile.of({}, t), ItemTile.of("x", t),
			ItemTile.of(PackedInt32Array([1, 2, 3]), t), ItemTile.of([0, -1, 500, 1, 1, 500, -1, 9], t)]
	_check.call(none["level"] == -1.0 and none["amount"] == "" and none["rot"] == -1 and none["grime"] == -1.0
			and none["temp"] == ItemLook.Temp.NORMAL and not ItemTile.shows(none) and ItemTile.words(none) == ""
			and missing.all(func(m: Dictionary) -> bool: return m == none)
			and empty_pack["level"] == 0.0 and empty_pack["amount"] == "" and not ItemTile.shows(empty_pack),
			"tile: no state, or the wrong size: nothing; an empty container: level 0, no amount, nothing drawn")
	var out_of_range := ItemTile.of(PackedInt32Array([9, 5000, 1500, 0x7fffffff, 3, 250, 20000]), t)
	var bad_type := ItemTile.of([0, -1, 500, -4, 0, ItemLook.ML_MAX + 1, -1], t)
	var junk := ItemTile.of(["hot", 1.5, "250", [1], {}, INF, NAN], t)
	var floats := ItemTile.of([1.0, 100.0, 500.0, 1.0, 1.0, 500.0, -1.0], t)
	_check.call(out_of_range == none and junk == none and bad_type["level"] == 0.5 and bad_type["amount"] == ""
			and bad_type["liquid"] == ItemLook.LIQUID_DEFAULT and bad_type["contents"] == ""
			and floats["temp"] == ItemLook.Temp.HOT and floats["rot"] == 100 and floats["level"] == 0.5
			and floats["amount"] == "500 ml" and floats["see_through"] and floats["contents"] == "orange juice",
			"tile: out of range or wrong types show nothing; whole floats count (%s, %s)" % [out_of_range, junk])
	var tv := ItemTileView.new(gun, -INF)
	_check.call(tv.mouse_filter == Control.MOUSE_FILTER_IGNORE and tv.focus_mode == Control.FOCUS_NONE and tv.inset == 0.0,
			"tile: the view takes no mouse input or focus")
	tv.free()


## Live item tiles, slice 2: Slosh is a damped spring back to level; a liquid's tile (drawn "~") sloshes from
## stir() and kick(), anything else doesn't; stirs while hidden aren't saved up; a surface still moving when its
## row goes carries on in the item's next row (soon after only).
func _test_slosh() -> void:
	var s := Slosh.new()
	s.push(NAN)
	s.push(INF)
	_check.call(not s.moving() and s.tilt == 0.0 and s.vel == 0.0, "slosh: still at first; NaN or infinite shoves ignored")
	s.push(3.0)
	var peak := 0.0
	var frames := 0
	while s.step(1.0 / 60.0) and frames < 600:
		peak = maxf(peak, absf(s.tilt))
		frames += 1
	_check.call(peak > 0.1 and peak <= 1.0 and s.tilt == 0.0 and s.vel == 0.0 and frames < 600,
			"slosh: a shove tilts it, then it settles back to level (%d frames, peak %.2f)" % [frames, peak])
	s.push(1000.0)
	_check.call(s.vel == Slosh.MAX_VEL, "slosh: speed capped")
	var a := Slosh.new()
	var b := Slosh.new()
	a.push(3.0)
	b.push(3.0)
	a.step(10.0)
	b.step(Slosh.MAX_DT)
	var held := a.tilt
	a.step(NAN)
	a.step(-1.0)
	_check.call(a.tilt == b.tilt and a.tilt != 0.0 and a.tilt == held, "slosh: a long frame counts as MAX_DT; NaN or negative steps do nothing")
	var t := IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "juice", "symbol": "~", "category": "drinks"}, {"id": "water", "symbol": "!",
			"category": "food", "phase": "liquid"}, {"id": "flour", "symbol": "%", "category": "food"},
			{"id": "wax", "symbol": "~", "phase": "solid"}]})
	var juice := ItemTile.of(PackedInt32Array([0, -1, 500, 1, 1, 250, -1]), t)
	var water := ItemTile.of(PackedInt32Array([0, -1, 500, 2, 0, 250, -1]), t)
	var flour := ItemTile.of(PackedInt32Array([0, -1, 500, 3, 0, 250, -1]), t)
	var dry := ItemTile.of(PackedInt32Array([0, -1, 0, 1, 1, 0, -1]), t)
	var wax := ItemTile.of(PackedInt32Array([0, -1, 500, 4, 0, 250, -1]), t)
	var ice := ItemTile.of(PackedInt32Array([ItemLook.Temp.FROZEN, -1, 500, 2, 0, 250, -1]), t)
	_check.call(juice["sloshes"] and water["sloshes"] and not flour["sloshes"] and not dry["sloshes"] and not wax["sloshes"]
			and not ice["sloshes"] and not ItemTile.of(null, t)["sloshes"],
			"slosh: liquids by phase (no phase: drawn \"~\") slosh, whatever the category; a solid \"~\", frozen water, "
			+ "flour, an empty jug or no state don't")
	var jv := ItemTileView.new(juice)
	var fv := ItemTileView.new(flour)
	var full_but_flagged := ItemTileView.new({"sloshes": true, "level": 0.0})
	_check.call(jv.slosh != null and fv.slosh == null and full_but_flagged.slosh == null,
			"slosh: only a liquid with something in it gets a surface")
	var before := ItemTileView.stirred
	ItemTileView.stir(NAN)
	ItemTileView.stir(1000.0)
	_check.call(ItemTileView.stirred == before + ItemTileView.STIR_MAX, "slosh: a stir is capped; NaN ignored")
	jv.tick(1.0 / 60.0)
	fv.tick(1.0 / 60.0)
	_check.call(jv.slosh.moving() and absf(jv.slosh.tilt) > 0.0, "slosh: a stir moves a liquid's surface")
	var hidden := ItemTileView.new(juice)
	ItemTileView.stir(2.0)
	hidden._process(1.0 / 60.0)   # not in the tree: hidden
	hidden.tick(1.0 / 60.0)
	_check.call(not hidden.slosh.moving(), "slosh: stirs while hidden are not saved up")
	hidden.kick(NAN)
	_check.call(not hidden.slosh.moving(), "slosh: a NaN kick does nothing")
	hidden.kick()
	fv.kick()
	_check.call(hidden.slosh.moving() and fv.slosh == null, "slosh: a kick shoves that tile alone; nothing for one that doesn't slosh")
	ItemTileView._carried.clear()
	var moving := ItemTileView.new(juice, 0.0, 7)
	moving.kick()
	moving._exit_tree()   # its row went (a rebuild)
	var again := ItemTileView.new(juice, 0.0, 7)
	var other := ItemTileView.new(juice, 0.0, 8)
	_check.call(again.slosh == moving.slosh and other.slosh != moving.slosh and not other.slosh.moving()
			and not ItemTileView._carried.has(7), "slosh: a moving surface carries on in its item's next row, once")
	var still := ItemTileView.new(juice, 0.0, 9)
	still._exit_tree()
	ItemTileView._carried[10] = [moving.slosh, Time.get_ticks_msec() - ItemTileView.CARRY_MS - 1]
	var late := ItemTileView.new(juice, 0.0, 10)
	_check.call(not ItemTileView._carried.has(9) and late.slosh != moving.slosh and not ItemTileView._carried.has(10),
			"slosh: a still surface isn't kept; a stale one isn't picked up")
	for i in ItemTileView.MAX_CARRIED:
		ItemTileView._carried[100 + i] = [Slosh.new(), 0]
	moving._exit_tree()
	_check.call(ItemTileView._carried.size() == 1, "slosh: the carried surfaces are bounded")
	ItemTileView._carried.clear()
	for v: ItemTileView in [jv, fv, full_but_flagged, hidden, moving, again, other, still, late]:
		v.free()


# --- Character creation and main menu ------------------------------------------------------------------

const CATALOG := {
	"version": 1, "pool": "multi_pool", "enforce_points": true, "stat_pool": 38, "trait_pool": 0,
	"skill_pool": 2, "max_trait_points": 12, "min_stat": 4, "max_stat": 14, "high_stat": 12, "max_skill": 10,
	"skill_costs": [0, 1, 1, 2, 4, 6, 9, 12, 16, 20, 25], "min_age": 16, "max_age": 55, "min_height": 145,
	"max_height": 200, "max_name": 64, "default_scenario": "evacuee", "templates": ["Old hero", "../evil"],
	"template_choices": {"Old hero": {"scenario": "evacuee", "profession": "cop", "backgrounds": ["hobby_x"],
			"str": 12, "dex": 8, "int": 8, "per": 8, "traits": ["FAST", "SLOW", "NOPE"], "skills": {"gun": 3},
			"name": "Hero", "male": false, "age": 40, "height": 160}},
	"scenarios": [
		{"id": "evacuee", "name": "Evacuee", "description": "You <color_red>ran</color>.", "points": 0,
			"start_name": "Shelter", "default_background": true, "professions": ["unemployed", "cop"],
			"backgrounds": ["adult_basic_background", "hobby_x"], "extra_traits": [],
			"forbidden_traits": ["SLOW"], "locked_traits": []},
		{"id": "lab", "name": "Lab", "description": "", "points": -1, "start_name": "Lab",
			"default_background": false, "professions": ["cop"], "backgrounds": [],
			"extra_traits": ["MUTANT"], "forbidden_traits": [], "locked_traits": ["SCIENCE"]},
	],
	"professions": [
		{"id": "unemployed", "name": "Unemployed", "name_female": "Unemployed", "description": "", "points": 0,
			"locked_traits": [], "skills": {}},
		{"id": "cop", "name": "Policeman", "name_female": "Policewoman", "description": "", "points": 2,
			"locked_traits": ["TOUGH"], "skills": {"gun": 2}},
	],
	"backgrounds": [
		{"id": "adult_basic_background", "name": "Basic", "name_female": "", "description": "", "points": 0,
			"locked_traits": [], "skills": {}},
		{"id": "hobby_x", "name": "Hobby", "name_female": "", "description": "", "points": 1,
			"locked_traits": [], "skills": {}},
	],
	"traits": [
		{"id": "FAST", "name": "Fast", "description": "", "points": 2, "starting": true, "cancels": ["SLOW"],
			"types": []},
		{"id": "SLOW", "name": "Slow", "description": "", "points": -2, "starting": true, "cancels": ["FAST"],
			"types": []},
		{"id": "TOUGH", "name": "Tough", "description": "", "points": 3, "starting": true, "cancels": [],
			"types": []},
		{"id": "MUTANT", "name": "Mutant", "description": "", "points": 1, "starting": false, "cancels": [],
			"types": []},
		{"id": "SCIENCE", "name": "Science", "description": "", "points": 0, "starting": false, "cancels": [],
			"types": []},
		"junk", {"id": 5}, {"id": ""},
	],
	"skills": [{"id": "gun", "name": "Gun", "description": ""}, {"id": "melee", "name": "Melee",
			"description": ""}],
}


func _test_chargen() -> void:
	var c := Chargen.parse(JSON.stringify(CATALOG))
	_check.call(c.ok, "chargen: catalog parses")
	_check.call(c.scenario == "evacuee" and c.profession == "unemployed",
			"chargen: default scenario and its cheapest profession")
	_check.call(c.picked_backgrounds == (["adult_basic_background"] as Array[String]), "chargen: default background")
	_check.call(c.traits.size() == 5, "chargen: bad trait entries skipped")
	_check.call(c.listed_traits().size() == 3, "chargen: only starting traits outside the lab")
	_check.call(not c.trait_blocker("SLOW").is_empty(), "chargen: forbidden trait blocked")
	_check.call(c.toggle_trait("FAST") and c.trait_points_used() == 2, "chargen: trait costs points")
	_check.call(c.points_left() == 38 + 2 - 32 - 2, "chargen: points left")
	_check.call(not c.set_profession("nobody") and c.set_profession("cop"), "chargen: profession checked")
	_check.call(c.locked_traits() == (["TOUGH"] as Array[String]) and c.trait_points_used() == 2,
			"chargen: profession trait locked and free")
	_check.call(not c.set_stat("str", 15) and c.set_stat("str", 14), "chargen: stat range")
	_check.call(c.stat_points_used() == 14 + 2 + 24, "chargen: high stats cost double")
	_check.call(c.problem() == "not enough points", "chargen: overspending caught")
	c.set_stat("str", 8)
	_check.call(c.set_skill("melee", 1) and not c.set_skill("nope", 1) and not c.set_skill("gun", 11),
			"chargen: skills checked")
	_check.call(c.problem().is_empty(), "chargen: valid now: " + c.problem())
	c.set_name("  Ann  ")
	var a: Variant = JSON.parse_string(c.answer_json())
	_check.call(a is Dictionary and a["scenario"] == "evacuee" and a["profession"] == "cop"
			and a["traits"] == ["FAST"] and int(a["skills"]["melee"]) == 1 and a["name"] == "Ann",
			"chargen: answer JSON %s" % a)
	_check.call(c.set_scenario("lab") and c.profession == "cop" and c.picked_backgrounds.is_empty()
			and c.picked_traits.is_empty(), "chargen: scenario change resets")
	_check.call(c.listed_traits().size() == 4 and c.locked_traits().has("SCIENCE"),
			"chargen: scenario extra and locked traits")
	_check.call(c.templates == (["Old hero"] as Array[String]), "chargen: bad template names dropped")
	var ta: Variant = JSON.parse_string(c.template_answer("Old hero"))
	_check.call(ta is Dictionary and ta["template"] == "Old hero" and c.template_answer("../evil") == "",
			"chargen: template answer")
	var c2 := Chargen.parse(JSON.stringify(CATALOG))
	var skipped := c2.load_template_choices("Old hero")
	_check.call(c2.profession == "cop" and c2.stats["str"] == 12 and c2.picked_traits == (["FAST"] as Array[String])
			and c2.skill_levels.get("gun") == 3 and c2.char_name == "Hero" and not c2.male and c2.age == 40
			and c2.picked_backgrounds == (["hobby_x"] as Array[String]),
			"chargen: template opened for editing")
	_check.call(skipped.size() == 2, "chargen: template's forbidden and unknown traits reported (%s)" % skipped)
	_check.call(c2.load_template_choices("../evil").size() == 1, "chargen: unlisted template not opened")
	var da: Variant = JSON.parse_string(c2.delete_answer("Old hero"))
	_check.call(da is Dictionary and da["delete_template"] == "Old hero" and c2.delete_answer("x") == "",
			"chargen: delete answer")
	c.save_template = "bad/name"
	_check.call(not c.problem().is_empty(), "chargen: bad save-template name caught")
	c.save_template = "My char"
	_check.call(c.problem().is_empty() and JSON.parse_string(c.answer_json())["save_template"] == "My char",
			"chargen: save_template sent")
	_check.call(not Chargen.parse("[1]").ok and not Chargen.parse("{}").ok, "chargen: bad catalogs refused")

	# The widget, through RequestUI.
	_check.call(_show(_req("chargen", {"text": JSON.stringify(CATALOG), "status": "bad name"})),
			"chargen widget: shows")
	var w := ui.widget as ChargenRequestWidget
	_check.call(w != null and w.status_label.text.contains("bad name"), "chargen widget: sim status shown")
	_check.call(w.pick("Profession", 1) and w.model.profession == "cop", "chargen widget: pick profession")
	_check.call(not w.pick("Traits", 99), "chargen widget: bad index ignored")
	w.change_stat("int", 1)
	_check.call(w.model.stats["int"] == 9, "chargen widget: stat button")
	w.model.char_name = "[img]res://x.tres[/img][font=x]"
	w.refresh_points()
	_check.call(not w._summary.text.contains("[img]") and not w._summary.text.contains("[font")
			and w._summary.text.contains("[lb]img]"), "chargen widget: names are text, not markup")
	var e := InputEventKey.new()
	e.keycode = KEY_ENTER
	e.pressed = true
	e.ctrl_pressed = true
	ui.handle_input(e)
	_check.call(answers.size() == 1 and well_formed(answers[0]) and answers[0]["text"].contains("\"cop\""),
			"chargen widget: Ctrl+Enter sends %s" % [answers])
	_show(_req("chargen", {"text": JSON.stringify(CATALOG)}))
	w = ui.widget as ChargenRequestWidget
	_check.call(w.edit_template(0) and w.model.profession == "cop" and answers.is_empty(),
			"chargen widget: edit a template sends nothing")
	_check.call(not w.delete_template(0) and answers.is_empty(), "chargen widget: first Delete only asks")
	_check.call(w.delete_template(0) and answers.size() == 1 and answers[0]["text"].contains("delete_template"),
			"chargen widget: second Delete sends")
	_show(_req("chargen", {"text": JSON.stringify(CATALOG)}))
	w = ui.widget as ChargenRequestWidget
	_check.call(w.start_template(0) and answers.size() == 1 and answers[0]["text"].contains("Old hero"),
			"chargen widget: start from template")
	_show(_req("chargen", {"text": "not json"}))
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "chargen widget: bad catalog can still cancel")


func _test_main_menu() -> void:
	var m := MainMenu.new()
	ui.add_child(m)
	var got := []
	m.new_game.connect(func(w: String, f: bool, c: bool, ws: bool) -> void: got.append(["new", w, f, c, ws]))
	m.load_game.connect(func(w: String, s: String) -> void: got.append(["load", w, s]))
	m.setup(PackedStringArray(["World", "bad/name", "Other"]),
			func(w: String) -> PackedStringArray: return PackedStringArray(["Ann"]) if w == "Other" else PackedStringArray())
	_check.call(m.worlds == PackedStringArray(["World", "Other"]), "menu: path-like world names dropped")
	_check.call(m.suggested_world() == "World2", "menu: suggests a free world name")
	_check.call(MainMenu.world_name_ok("a_b-1") and not MainMenu.world_name_ok("../x")
			and not MainMenu.world_name_ok(""), "menu: world name rule")
	var opts := [0]
	m.options_requested.connect(func() -> void: opts[0] += 1)
	m.show_page("main")
	for b: Node in m._box.get_children():
		if b is Button and (b as Button).text == "Options (F1)":
			(b as Button).pressed.emit()
	_check.call(opts[0] == 1, "menu: the Options (F1) button asks for the F1 menu")
	m.show_page("credits")
	_check.call(m.page == "credits" and m._box.get_child_count() >= 4, "menu: credits page")
	m.show_page("new")
	m._world_edit.text = "World"
	_check.call(not m.start_new() and got.is_empty(), "menu: won't replace an existing world")
	m._world_edit.text = "wORLD"
	_check.call(not m.start_new() and got.is_empty(), "menu: nor one whose name differs only in case")
	m._world_edit.text = "FP3D-mine"
	_check.call(not m.start_new() and got.is_empty() and MainMenu.world_reserved("fp3d-live") and not MainMenu.world_reserved("fp3dx"),
			"menu: no new world named fp3d-... (kept for quick starts and tests)")
	var sv := func(w: String) -> PackedStringArray:
		return PackedStringArray(["Ann"]) if w in ["fp3d-live-3", "fp3d-live-10"] else PackedStringArray(["Bob"])
	var ws := PackedStringArray(["fp3d-live", "fp3d-live-10", "fp3d-live-3", "fp3d-live--3", "fp3d-live-x", "Other"])
	_check.call(Main.world_for_save(ws, "Ann", sv) == "fp3d-live-3" and Main.world_for_save(ws, "Bob", sv) == "fp3d-live"
			and Main.world_for_save(ws, "Cid", sv) == "fp3d-live" and Main.world_for_save(ws, "", sv) == "fp3d-live"
			and Main.world_for_save(PackedStringArray(["fp3d-live-2"]), "Bob", sv) == "fp3d-live-2",
			"menu: --save alone finds the save in fp3d-live, then -2, -3 ... in number order")
	var many := PackedStringArray()
	for i in MainMenu.MAX_LISTED + 5:
		many.append("w%d" % i)
	m.setup(many, func(_w: String) -> PackedStringArray: return PackedStringArray())
	m.show_page("new")
	m._world_edit.text = "W%d" % (MainMenu.MAX_LISTED + 2)
	_check.call(m.worlds.size() == MainMenu.MAX_LISTED and not m.start_new() and got.is_empty(),
			"menu: nor one past the listed worlds")
	m.setup(PackedStringArray(["World", "bad/name", "Other"]),
			func(w: String) -> PackedStringArray: return PackedStringArray(["Ann"]) if w == "Other" else PackedStringArray())
	m.show_page("new")
	m._world_edit.text = "Fresh"
	_check.call(m.start_new() and got[-1] == ["new", "Fresh", true, true, true], "menu: new world with chargen and setup")
	m.show_page("load")
	_check.call(m.select_world("Other") and m.start_load() and got[-1] == ["load", "Other", "Ann"],
			"menu: load a save")
	_check.call(m.select_world("World") and not m.start_load(), "menu: world without saves can't load")
	_check.call(not _has_button(m, "Delete character...") and not m.ask_delete(), "menu: no deleter, no Delete button")
	m.free()
	_test_menu_delete()


func _has_button(m: MainMenu, text: String) -> bool:
	return m._box.get_children().any(func(c: Node) -> bool: return c is Button and (c as Button).text == text)


## Deleting a character from the Load page: a confirm that names it (and the world when it is the last one), only
## listed names reach the deleter, a failed delete says why, the lists come back from disk afterwards.
func _test_menu_delete() -> void:
	var disk := {"World": PackedStringArray(["Ann", "Bob"]), "Other": PackedStringArray(["Cid" + String.chr(0x202E) + "\nx"])}
	var calls := []
	var answer := [""]
	var m := MainMenu.new()
	ui.add_child(m)
	m.deleter = func(w: String, s: String) -> Variant:
		calls.append([w, s])
		if answer[0] is String and (answer[0] as String).is_empty():
			var left: PackedStringArray = disk[w]
			left.remove_at(left.find(s))
			disk[w] = left
			if left.is_empty():
				disk.erase(w)
		return answer[0]
	m.relist = func() -> PackedStringArray:
		var k := PackedStringArray(disk.keys())
		k.sort()
		return k
	m.setup(m.relist.call(), func(w: String) -> PackedStringArray: return disk.get(w, PackedStringArray()))
	m.show_page("load")
	_check.call(_has_button(m, "Delete character...") and m.select_world("World"), "menu delete: a Delete button on the Load page")
	m._save_list.select(1)
	_check.call(m.ask_delete() and m.page == "delete" and calls.is_empty() and m.pending_delete == {"world": "World", "save": "Bob", "last": false}
			and m._box.get_node("Confirm").text.contains("Bob") and m._box.get_node("Confirm").text.contains("World")
			and not m._box.get_node("Confirm").text.contains("last") and m._box.get_node("DeleteButton").text == "Delete Bob",
			"menu delete: the confirm names the character and its world; nothing deleted yet")
	m.cancel_delete()
	_check.call(calls.is_empty() and m.page == "load" and m.pending_delete.is_empty() and disk["World"].size() == 2,
			"menu delete: Keep it deletes nothing")
	m._save_list.select(1)
	m.ask_delete()
	_check.call(m.confirm_delete() and calls == [["World", "Bob"]] and disk["World"] == PackedStringArray(["Ann"])
			and m.page == "load" and m.message == "Deleted Bob." and m._save_list.item_count == 1,
			"menu delete: Delete deletes that one character; the list shows what is left")
	answer[0] = "the save folder is read-only\n<b>x</b>"
	m.select_world("World")
	m.ask_delete()
	_check.call(m.pending_delete["last"] and m._box.get_node("Confirm").text.contains("last character in World"),
			"menu delete: the last character warns that the world goes too")
	_check.call(not m.confirm_delete() and calls.size() == 2 and disk.has("World")
			and m.message.begins_with("Couldn't delete Ann: the save folder is read-only") and not "\n" in m.message,
			"menu delete: a failed delete says why on one line and keeps the lists (%s)" % m.message)
	answer[0] = 5
	m.ask_delete()
	_check.call(not m.confirm_delete() and m.message.ends_with("the bridge gave no answer"), "menu delete: a non-text reply is a failure")
	answer[0] = ""
	m.ask_delete()
	disk["World"] = PackedStringArray(["Zed"])   # changed on disk while the confirm was open
	_check.call(not m.confirm_delete() and calls.size() == 3 and m.message.contains("no longer"),
			"menu delete: a character gone from the list since the confirm isn't sent")
	disk["World"] = PackedStringArray(["Ann"])
	m.select_world("World")
	m.ask_delete()
	_check.call(m.confirm_delete() and calls[-1] == ["World", "Ann"] and m.worlds == PackedStringArray(["Other"])
			and not m.world_taken("World") and m.message == "Deleted Ann, and the world World with them." and m.page == "load",
			"menu delete: the last character takes its world along; its name is free again")
	m.select_world("Other")
	m.ask_delete()
	var confirm: String = m._box.get_node("Confirm").text
	_check.call(not confirm.contains(String.chr(0x202E)) and confirm.contains("Cidx") and m.confirm_delete()
			and calls[-1] == ["Other", "Cid" + String.chr(0x202E) + "\nx"] and m.worlds.is_empty() and m.page == "main",
			"menu delete: the confirm shows the name plainly, the deleter gets the listed name; no world left: main page")
	var s := LiveSession.new()
	s.state = "running"
	_check.call(LiveSession.delete_reply("") == "" and LiveSession.delete_reply(null) != "" and LiveSession.delete_reply("\n") != ""
			and s.delete_save(preload("res://tests/test_dir.gd").global("nowhere"), "World", "Ann", true) != ""
			and s.delete_save("rel", "World", "Ann", true) != "",
			"live session: delete refused without a bridge or a name it lists")
	s.free()
	m.free()


const WORLD_CATALOG := {
	"version": 1,
	"sliders": [{"id": "city", "name": "Cities", "default": 1, "levels": [{"name": "Few", "description": "a"},
			{"name": "Some", "description": "b"}, {"name": "Many", "description": "c"}]}, {"id": "bad"}],
	"options": [
		{"id": "B", "name": "Bool", "group": "", "tooltip": "", "type": "bool", "value": false},
		{"id": "I", "name": "Int", "group": "", "tooltip": "", "type": "int", "value": 5, "min": 1, "max": 10},
		{"id": "S", "name": "Sel", "group": "", "tooltip": "", "type": "string_select", "value": "a",
			"choices": [["a", "A"], ["b", "B"]]},
		{"id": "M", "name": "Map", "group": "", "tooltip": "", "type": "int_map", "value": 2,
			"choices": [[1, "one"], [2, "two"]]},
		{"id": "X", "type": "weird"}, "junk",
	],
	"mods": [
		{"id": "dda", "name": "Dark Days Ahead", "description": "", "category": "core", "core": true,
			"dependencies": [], "conflicts": []},
		{"id": "aftershock", "name": "Aftershock", "description": "", "category": "total", "core": true,
			"dependencies": [], "conflicts": []},
		{"id": "base", "name": "Base", "description": "", "category": "c", "core": false, "dependencies": ["dda"],
			"conflicts": []},
		{"id": "addon", "name": "Addon", "description": "", "category": "c", "core": false,
			"dependencies": ["base"], "conflicts": ["rival"]},
		{"id": "rival", "name": "Rival", "description": "", "category": "c", "core": false,
			"dependencies": ["dda"], "conflicts": []},
	],
	"default_mods": ["dda"],
}


## Back to the main menu after a game: what the menu says, and F1's "Save and quit to menu".
## G7 options in HudSettings and the F1 menu: defaults, the controls save them, the file is clamped / ignored.
func _test_options() -> void:
	var path := preload("res://tests/test_dir.gd").path("hud_options.cfg")
	var hs := HudSettings.new()
	_check.call(hs.look_speed == 1.0 and hs.fov == HudSettings.DEFAULT_FOV and hs.render_scale == 1.0
			and not hs.fullscreen and hs.vsync and not hs.invert_y and hs.ui_scale == 1.0
			and hs.weather_quality == WeatherView.HIGH and hs.volume == 1.0 and hs.ambience_volume == 1.0,
			"options: defaults (x1 look, 75 degrees, full resolution, windowed, vsync)")
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	var seen := [0]
	menu.hud_changed.connect(func() -> void: seen[0] += 1)
	for sv: Array in [[menu.fov_slider, 90.0], [menu.look_slider, 2.0], [menu.scale_slider, 0.75],
			[menu.ui_slider, 1.5], [menu.volume_slider, 0.5], [menu.ambience_slider, 0.25]]:
		var s := sv[0] as HSlider
		s.value = sv[1]
		s.value_changed.emit(s.value)   # a slider outside the tree doesn't emit it itself
	menu.fullscreen_check.button_pressed = true
	menu.vsync_check.button_pressed = false
	menu.invert_check.button_pressed = true
	menu.weather_pick.select(WeatherView.LOW)
	menu.weather_pick.item_selected.emit(WeatherView.LOW)   # select() alone doesn't emit it
	var back := HudSettings.new()
	var why := back.load_file(path)
	_check.call(why == "" and back.fov == 90.0 and back.look_speed == 2.0 and back.render_scale == 0.75
			and back.fullscreen and not back.vsync and back.invert_y and back.ui_scale == 1.5
			and back.weather_quality == WeatherView.LOW and back.volume == 0.5 and back.ambience_volume == 0.25
			and seen[0] == 10,
			("options: the F1 controls set and save each (%s, %s, %s, %s, %s, %s, %s, weather %s, volume %s / %s; "
			+ "%d changes)") % [back.fov, back.look_speed, back.render_scale, back.fullscreen, back.vsync,
			back.invert_y, back.ui_scale, back.weather_quality, back.volume, back.ambience_volume, seen[0]])
	_check.call(menu.weather_pick.item_count == 3 and menu.weather_pick.get_item_text(WeatherView.HIGH) == "High",
			"options: the weather picker lists WeatherView's qualities by index")
	var shown := [(menu._option_values[&"fov"] as Label).text, (menu._option_values[&"render_scale"] as Label).text]
	_check.call(shown == ["90%s" % char(0xb0), "75 %"], "options: the values show next to the sliders (%s)" % [shown])
	menu.set_option(&"debug_cheats", true)
	_check.call(not hs.debug_cheats and seen[0] == 10, "options: set_option takes only the option fields")
	var bi := HudSettings.ensure_ambience_bus()
	var buses := AudioServer.bus_count
	HudSettings.set_bus_loudness(bi, 0.5)
	var half_db := AudioServer.get_bus_volume_db(bi)
	HudSettings.set_bus_loudness(bi, 0.0)
	var muted := AudioServer.is_bus_mute(bi)
	HudSettings.set_bus_loudness(bi, 1.0)
	HudSettings.set_bus_loudness(99, 0.0)   # no such bus: nothing
	_check.call(bi > 0 and HudSettings.ensure_ambience_bus() == bi and AudioServer.bus_count == buses
			and AudioServer.get_bus_send(bi) == &"Master" and absf(half_db - linear_to_db(0.5)) < 0.01 and muted
			and not AudioServer.is_bus_mute(bi) and absf(AudioServer.get_bus_volume_db(bi)) < 0.01,
			"options: the Ambience bus is made once, sends to Master; 0 mutes it, 0.5 is %.1f dB" % half_db)
	hs.fov = 300.0   # out of range in memory: saved clamped
	hs.save_file(path)
	back = HudSettings.new()
	back.load_file(path)
	_check.call(back.fov == HudSettings.FOVS.y, "options: an out-of-range value is saved clamped (%s)" % back.fov)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[compass]\nopacity=0.5\n[look]\nspeed=99\ninvert=2\nfov=nan\n[display]\nscale=-3\n"
			+ "fullscreen=1\nvsync=\"no\"\nui_scale=9\n[weather]\nquality=-5\n[sound]\nvolume=-1\nambience=\"loud\"\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(junk.look_speed == HudSettings.LOOK_SPEEDS.y and junk.fov == HudSettings.DEFAULT_FOV
			and junk.render_scale == HudSettings.RENDER_SCALES.x and not junk.fullscreen and junk.vsync
			and not junk.invert_y and junk.ui_scale == HudSettings.UI_SCALES.y
			and junk.weather_quality == WeatherView.MINIMAL and junk.volume == 0.0 and junk.ambience_volume == 1.0,
			"options: the file's numbers are clamped, NaN and non-bools leave the defaults (%s, %s, %s, %s, %s)"
			% [junk.look_speed, junk.fov, junk.render_scale, junk.fullscreen, junk.vsync])
	menu.free()


func _test_hints() -> void:
	var dir := preload("res://tests/test_dir.gd")
	var path: String = dir.path("hints.cfg")
	var names := InputActions.names()
	var unknown: Array[String] = []
	var re := RegEx.create_from_string("\\{(\\w+)\\}")
	for id: String in Hints.TEXTS:
		for m in re.search_all(Hints.TEXTS[id]):
			if not names.has(StringName(m.get_string(1))):
				unknown.append(m.get_string(1))
	_check.call(unknown.is_empty(), "hints: every {action} in the texts is a key action (unknown: %s)" % [unknown])
	InputMap.add_action(&"hints_test_act")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_Q
	InputMap.action_add_event(&"hints_test_act", ev)
	var key := InputActions.key_of(&"hints_test_act")
	var filled := Hints.fill("press {hints_test_act} or {no_such_action}, {open")
	InputMap.erase_action(&"hints_test_act")
	_check.call(key != "-" and filled == "press %s or no_such_action, {open" % key,
			"hints: {action} becomes its key, an unknown name stays bare, an open brace stays (%s)" % filled)
	var snap := Snapshot.new()
	var hud := HudData.new()
	var calm := Hints.due(snap, hud)
	var friend := Snapshot.Creature.new()
	friend.kind = Snapshot.Creature.NPC
	friend.attitude = Snapshot.Creature.FRIENDLY
	snap.creatures.append(friend)
	var with_friend := Hints.due(snap, hud)
	snap.creatures.append(Snapshot.Creature.new())   # a monster the bridge gives no attitude: hostile
	snap.player_effects.append({"id": "hunger_engorged"})
	var engorged := Hints.due(snap, hud)
	snap.player_effects.append({"id": "hunger_hungry"})
	hud.body.append({"part": "arm_l", "bleed": 1})
	var every := Hints.due(snap, hud)
	hud.needs["thirst"] = {"value": 50, "word": "Thirsty", "level": HudData.HURT}
	var thirsty := Hints.due(Snapshot.new(), hud)
	_check.call(calm.is_empty() and with_friend.is_empty() and engorged == (["hostile"] as Array[String])
			and every == (["hostile", "eat", "bleed"] as Array[String])
			and thirsty == (["eat", "bleed"] as Array[String]) and Hints.due(null, null).is_empty(),
			"hints: due() finds a hostile (not a friend), hunger (not engorged) or thirst, bleeding (%s, %s, %s)"
			% [engorged, every, thirsty])
	var h := Hints.new()
	h.path = path
	var fresh := h.load_file() == "" and h.enabled and h.seen.is_empty() and not h.visible
	var first := h.trigger("start")
	var twice := h.trigger("start")
	var queued := h.trigger("prompt")
	var odd := h.trigger("nope")
	_check.call(fresh and first and not twice and queued and not odd and h.shown == "start" and h.visible
			and h.queue.size() == 1 and h.queue[0] == "prompt" and not h._label.text.contains("{"),
			"hints: each id once, the next waits, unknown ids refused (showing %s)" % h.shown)
	h.tick(Hints.SHOW_S - 1.0)
	var still := h.shown
	h.tick(1.5)
	var next := h.shown
	h.dismiss()
	_check.call(still == "start" and next == "prompt" and h.shown == "" and not h.visible,
			"hints: one shows for SHOW_S seconds, then the next; dismiss hides the last")
	var back := Hints.new()
	back.path = path
	_check.call(back.load_file() == "" and back.enabled and back.seen.has("start") and back.seen.has("prompt")
			and not back.seen.has("inspect"), "hints: seen ids are saved (%s)" % [back.seen.keys()])
	back.free()
	var menu := KeyMenu.new()
	menu.add_hints(h)
	menu.hints_check.button_pressed = false
	var off_refused := not h.trigger("inspect")
	var off := Hints.new()
	off.path = path
	off.load_file()
	_check.call(not h.enabled and off_refused and not h.seen.has("inspect") and not off.enabled,
			"hints: the F1 Hints box off stops them and is saved")
	off.free()
	menu.hints_check.button_pressed = true
	var on_shows := h.trigger("inspect") and h.shown == "inspect"
	menu.hints_again.pressed.emit()
	_check.call(on_shows and h.seen.is_empty() and h.trigger("start") and menu._status.text.contains("once more"),
			"hints: on again shows; \"Show hints again\" lets each show once more")
	menu.free()
	h.free()
	var t := Hints.new()
	t.path = dir.path("hints_not_kept.cfg")
	t.persist = false
	_check.call(t.trigger("start") and not FileAccess.file_exists(t.path), "hints: persist off writes nothing")
	t.free()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hints]\nenabled=2\nseen=[\"start\", \"nope\", 5, \"start\"]\n")
	f.close()
	var junk := Hints.new()
	junk.path = path
	_check.call(junk.load_file() == "" and junk.enabled and junk.seen.keys() == ["start"],
			"hints: a non-bool leaves them on; only known ids are read (%s)" % [junk.seen.keys()])
	junk.free()
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hints]\nenabled=false\nseen=[Object(Node,\"name\":\"x\")]\n")
	f.close()
	var evil := Hints.new()
	evil.path = path
	var why := evil.load_file()
	_check.call(why.contains("Object(") and evil.enabled and evil.seen.is_empty(),
			"hints: a file with Object( is ignored (%s)" % why)
	evil.free()
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("#".repeat(Hints.MAX_FILE_BYTES + 1))
	f.close()
	var big := Hints.new()
	big.path = path
	_check.call(big.load_file().contains("over"), "hints: an oversized file is ignored")
	big.free()


func _test_wheel() -> void:
	var sink := [{"id": 10, "label": "Wash your hands"}, {"id": 11, "label": "Drink from the sink"},
			{"id": 12, "label": "<color_red>Empty</color> it", "enabled": false}, {"id": 13, "label": "Fill a container"},
			{"id": 14, "label": "Admire the plumbing"}]
	var placed := RadialRequestWidget.layout(RequestWidget.entries_of({"entries": sink}))
	var ids := placed.map(func(e: Variant) -> Variant: return null if e == null else e["id"])
	_check.call(ids == [11, 14, 13, null, 12, null, 10, null],
			"wheel: drink at the top, fill right, empty below, wash left, the rest in the first free slot (%s)" % [ids])
	var dirs := [Vector2(0, -90), Vector2(70, -70), Vector2(90, 0), Vector2(0, 90), Vector2(-90, 0), Vector2(5, 5),
			Vector2(INF, 0)].map(func(v: Vector2) -> int: return RadialRequestWidget.slot_at(v))
	_check.call(dirs == [0, 1, 2, 4, 6, -1, -1], "wheel: slot by direction, none at the centre (%s)" % [dirs])
	var nine := []
	for i in 9:
		nine.append({"id": i, "label": "x%d" % i})
	_check.call(RadialRequestWidget.fits(_req("menu", {"entries": sink}))
			and not RadialRequestWidget.fits(_req("menu", {"entries": nine}))
			and not RadialRequestWidget.fits(_req("menu", {"entries": []}))
			and not RadialRequestWidget.fits(_req("menu", {"entries": sink, "actions": PackedStringArray(["HELP"])}))
			and not RadialRequestWidget.fits(_req("popup", {"entries": sink})),
			"wheel: only a menu of 1 to 8 entries without extra actions")
	_show(_req("menu", {"entries": sink}))
	var plain := ui.widget is ListRequestWidget
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink, "title": "Sink"}))
	var w := ui.widget as RadialRequestWidget
	_check.call(plain and w != null and not w.hold and ui.wheel_until == -1,
			"wheel: a menu is a list unless E asked for a wheel; the wheel is used once")
	w.aim(Vector2(0, -100))
	var top := w.hovered
	_key(KEY_ENTER)
	_check.call(top == 0, "wheel: pointing up highlights the top slot")
	_expect({"id": 7, "entry": 11}, "wheel: Enter picks it")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink}))
	w = ui.widget as RadialRequestWidget
	_key(KEY_5)   # slot 5 (index 4): Empty, disabled
	var refused := answers.is_empty()
	_key(KEY_DOWN)
	_key(KEY_LEFT)
	_key(KEY_ENTER)
	_check.call(refused and w.hovered == 6, "wheel: a greyed entry can't be picked; the arrows move to a slot")
	_expect({"id": 7, "entry": 10}, "wheel: Left then Enter picks wash")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink}))
	w = ui.widget as RadialRequestWidget
	w.hold = true
	var kept := not w.release() and not w.done and not w.hold
	w.hold = true
	w.aim(Vector2(100, 0))
	_check.call(kept and w.release(), "wheel: letting go at the centre keeps it open; pointing right, it picks")
	_expect({"id": 7, "entry": 13}, "wheel: letting go of E picks fill")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink}))
	_key(KEY_3)
	_expect({"id": 7, "entry": 13}, "wheel: 3 picks the third slot")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink}))
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "wheel: Esc cancels")
	var picks := [RadialRequestWidget.default_id(_req("menu", {"entries": sink, "selected": 1})),
			RadialRequestWidget.default_id(_req("menu", {"entries": sink})),
			RadialRequestWidget.default_id(_req("menu", {"entries": sink, "selected": 99})),
			RadialRequestWidget.default_id(_req("menu", {"entries": sink, "selected": "1"}))]
	_check.call(picks == [11, null, null, null], "wheel: `selected` names an entry by index; missing or bad: none (%s)"
			% [picks])
	ui.want_wheel(5000, true)   # E let go already (no key is down in the tests): a tap
	_show(_req("menu", {"entries": sink, "selected": 1}))
	_expect({"id": 7, "entry": 11}, "wheel: a tap of E picks CDDA's default without showing the wheel")
	ui.want_wheel(5000, true)
	_show(_req("menu", {"entries": sink, "selected": 2}))   # the default is greyed (hostile): no pick
	w = ui.widget as RadialRequestWidget
	_check.call(answers.is_empty() and w != null and w.default_slot == -1 and not w.done,
			"wheel: a greyed or missing default leaves the wheel up for a click")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink, "selected": 3}))
	w = ui.widget as RadialRequestWidget
	w.hold = true
	w.tap_until = Time.get_ticks_msec() + 10000
	_check.call(w.default_slot == 2 and w.release(), "wheel: letting go at the centre soon after E picks the default")
	_expect({"id": 7, "entry": 13}, "wheel: the tap's default is fill")
	ui.want_wheel(5000, false)
	_show(_req("menu", {"entries": sink}))
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_X
	stick.axis_value = -1.0
	ui.handle_input(stick)
	var pad_a := InputEventJoypadButton.new()
	pad_a.button_index = JOY_BUTTON_A
	pad_a.pressed = true
	ui.handle_input(pad_a)
	_expect({"id": 7, "entry": 10}, "wheel: a pad's stick points left, A picks wash")
	_check.call(InputActions.defaults(&"use_held").any(func(e: InputEvent) -> bool:
			return e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == JOY_BUTTON_A),
			"wheel: a pad's A is E by default")
	InputMap.add_action(&"prompt_test_act")
	var qk := InputEventKey.new()
	qk.physical_keycode = KEY_Q
	var pb := InputEventJoypadButton.new()
	pb.button_index = JOY_BUTTON_X
	InputMap.action_add_event(&"prompt_test_act", qk)
	InputMap.action_add_event(&"prompt_test_act", pb)
	var was := InputActions.pad_last
	var press := InputEventJoypadButton.new()
	press.button_index = JOY_BUTTON_B
	press.pressed = true
	InputActions.note_device(press)
	var on_pad := InputActions.prompt_of(&"prompt_test_act")
	var small := InputEventMouseMotion.new()
	small.relative = Vector2(1, 0)   # a jiggle: still the pad
	InputActions.note_device(small)
	var still_pad := InputActions.pad_last
	var typed := InputEventKey.new()
	typed.physical_keycode = KEY_W
	typed.pressed = true
	InputActions.note_device(typed)
	var on_keys := InputActions.prompt_of(&"prompt_test_act")
	InputMap.erase_action(&"prompt_test_act")
	InputActions.pad_last = was
	_check.call(on_pad == "X" and still_pad and on_keys == InputActions.event_label(qk),
			"prompts: after a pad button they name the pad's (%s), after a key the key (%s)" % [on_pad, on_keys])
	ui.wheel_until = 0   # long past: a later menu is a list again
	_show(_req("menu", {"entries": sink}))
	_check.call(ui.widget is ListRequestWidget, "wheel: an old E press doesn't make a later menu a wheel")
	ui.clear()
	var path: String = preload("res://tests/test_dir.gd").path("hud_wheel.cfg")
	var hs := HudSettings.new()
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	menu.set_option(&"context_menu", 7)
	var refused_bad := hs.context_menu == HudSettings.MENU_HOLD
	menu.menu_pick.select(HudSettings.MENU_LIST)
	menu.menu_pick.item_selected.emit(HudSettings.MENU_LIST)
	var back := HudSettings.new()
	back.load_file(path)
	_check.call(refused_bad and hs.context_menu == HudSettings.MENU_LIST and back.context_menu == HudSettings.MENU_LIST,
			"wheel: the F1 option is checked, set and saved (%s)" % back.context_menu)
	menu.free()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[controls]\ncontext_menu=\"wheel\"\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[controls]\ncontext_menu=9\n")
	f.close()
	var high := HudSettings.new()
	high.load_file(path)
	_check.call(junk.context_menu == HudSettings.MENU_HOLD and high.context_menu == HudSettings.MENU_LIST,
			"wheel: a non-number in the file leaves hold, too high is clamped")

## Handedness (HudSettings.main_hand, flat screen): the F1 picker sets and saves it, a bad value is ignored there and
## in the file; keys 1 / 2 strike with the left / right hand whichever is main; the hands panel puts the main hand on
## the left for a left-hander.
func _test_main_hand(root: Node) -> void:
	var path := preload("res://tests/test_dir.gd").path("hud_hands.cfg")
	var hs := HudSettings.new()
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	var right_first := hs.main_hand == "right" and not hs.left_handed() and menu.main_pick.selected == 0 \
			and menu.main_pick.item_count == 2 and menu.main_pick.get_item_text(1) == "Left-handed"
	menu.main_pick.select(1)
	menu.main_pick.item_selected.emit(1)
	menu.main_pick.item_selected.emit(7)
	menu.set_option(&"main_hand", "both")
	menu.set_option(&"main_hand", 1)
	hs.main_hand = "LEFT"
	var back := HudSettings.new()
	back.load_file(path)
	_check.call(right_first and hs.main_hand == "left" and back.main_hand == "left" and back.left_handed(),
			"main hand: right unless picked; the F1 picker sets and saves left, bad values are ignored")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hands]\nmain=\"middle\"\n")
	f.close()
	var junk := HudSettings.new()
	junk.main_hand = "left"
	junk.load_file(path)
	_check.call(junk.main_hand == "right", "main hand: anything else in the file is right")
	_check.call(HudSettings.hand_for("left", false) == "off" and HudSettings.hand_for("right", false) == "main"
			and HudSettings.hand_for("left", true) == "main" and HudSettings.hand_for("right", true) == "off",
			"main hand: the left key strikes with the off hand, or the main one when left-handed")
	var panel := HandsPanel.new()
	root.add_child(panel)
	panel.show_held({"seq": 1, "main": {"name": "knife"}, "off": {"name": "torch"}})
	var right_rows: Array = [(panel._rows[0]["label"] as Label).text, (panel._rows[1]["label"] as Label).text]
	panel.left_handed = true
	var left_rows: Array = [(panel._rows[0]["label"] as Label).text, (panel._rows[1]["label"] as Label).text]
	_check.call(right_rows == ["Left: torch", "Right: knife"] and left_rows == ["Left: knife", "Right: torch"],
			"main hand: the hands panel shows a left-hander's main hand on the left (%s %s)" % [right_rows, left_rows])
	panel.free()
	menu.free()


func _test_game_over(root: Node) -> void:
	var said := [Main.game_over_text("ended", "saved and quit"), Main.game_over_text("ended", "the character died"),
			Main.game_over_text("ended", "the game ended"), Main.game_over_text("ended", ""),
			Main.game_over_text("failed", "boom"), Main.game_over_text("ended", "odd"),
			Main.game_over_text("ended", "cancelled"), Main.game_over_text("failed", "character creation cancelled")]
	_check.call(said == [["Game saved.", true], ["Your character died.", false], ["The game ended.", false],
			["The game ended.", false], ["The game failed: boom", false], ["The game ended: odd", false],
			["", false], ["", false]],
			"game over: the menu's message per reason -> %s" % [said])
	var long_text: String = Main.game_over_text("failed", "x".repeat(5000))[0]
	_check.call(long_text.length() < 400, "game over: a long failure is cut (%d chars)" % long_text.length())
	var m := KeyMenu.new()
	root.add_child(m)
	var fired := [0]
	m.quit_to_menu.connect(func() -> void: fired[0] += 1)
	var hidden_at_first := not m.quit_button.visible
	m.show_quit_to_menu(true)
	m.visible = true
	m.quit_button.pressed.emit()
	_check.call(hidden_at_first and m.quit_button.visible and fired[0] == 1 and not m.visible,
			"F1: \"Save and quit to menu\" shows only for a live game, closes the menu and asks once (fired %d)"
			% fired[0])
	m.free()


func _test_world_setup() -> void:
	var w := WorldSetup.parse(JSON.stringify(WORLD_CATALOG))
	_check.call(w.ok and w.sliders.size() == 1 and w.options.size() == 4 and w.mods.size() == 5,
			"world: catalog parses, bad entries dropped")
	_check.call(w.picked_mods == (["dda"] as Array[String]) and w.problem().is_empty(), "world: default mods")
	_check.call(w.set_level("city", 2) and not w.set_level("city", 3) and not w.set_level("nope", 0),
			"world: slider levels checked")
	_check.call(w.set_value("I", 7) and not w.set_value("I", 11) and not w.set_value("I", "x")
			and w.set_value("B", true) and not w.set_value("S", "z") and w.set_value("S", "b")
			and w.set_value("M", 1) and not w.set_value("M", 3) and not w.set_value("nope", 1),
			"world: settings checked by type and range")
	_check.call(w.toggle_mod("addon") and w.picked_mods == (["dda", "base", "addon"] as Array[String]),
			"world: ticking adds dependencies")
	_check.call(not w.toggle_mod("rival") and w.conflict_of("rival") == "addon", "world: conflict blocks")
	_check.call(w.toggle_mod("base") and w.picked_mods == (["dda"] as Array[String]),
			"world: unticking drops dependents")
	_check.call(w.toggle_mod("aftershock") and w.picked_mods == (["aftershock"] as Array[String]),
			"world: one core mod at a time")
	w.toggle_mod("aftershock")
	_check.call(not w.problem().is_empty(), "world: no core mod caught")
	w.toggle_mod("dda")
	var a: Variant = JSON.parse_string(w.answer_json())
	_check.call(a is Dictionary and a["sliders"]["city"] == 2 and a["options"]["I"] == 7 and a["options"]["S"] == "b"
			and a["mods"] == ["dda"], "world: answer JSON %s" % a)
	_check.call(_show(_req("world_setup", {"text": JSON.stringify(WORLD_CATALOG), "title": "New world: X",
			"status": "bad slider"})), "world widget: shows")
	var wd := ui.widget as WorldSetupRequestWidget
	_check.call(wd != null and wd.status_label.text.contains("bad slider"), "world widget: sim status shown")
	_check.call(wd.set_option("I", 3) and not wd.set_option("I", 99), "world widget: setting")
	var row := wd._mod_ids.find("addon")
	_check.call(wd.pick_mod(row) and wd.model.picked_mods.has("base"), "world widget: tick a mod")
	wd.model.mods["base"]["name"] = "[img]res://x.tres[/img]"
	wd._show_mod(row)
	_check.call(not wd._mod_detail.text.contains("[img]") and wd._mod_detail.text.contains("Needs: [lb]img]"),
			"world widget: names in Needs are text, not markup")
	var e := InputEventKey.new()
	e.keycode = KEY_ENTER
	e.pressed = true
	e.ctrl_pressed = true
	ui.handle_input(e)
	_check.call(answers.size() == 1 and well_formed(answers[0]) and answers[0]["text"].contains("addon"),
			"world widget: Ctrl+Enter creates")
	_show(_req("world_setup", {"text": "nope"}))
	_key(KEY_ESCAPE)
	_expect({"id": 7, "cancel": true}, "world widget: bad catalog can still cancel")
