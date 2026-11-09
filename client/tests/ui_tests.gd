extends RefCounted
## Block E3 checks, run by run_tests.gd: fake requests (fields as in contracts/bridge_api.md) go into
## RequestUI, keys and clicks are simulated, and each answer must be the one the sim expects and pass the same
## type checks as CddaSim.answer() (bridge/src/cdda_sim.cpp).

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
	_test_direction()
	_test_target()
	_test_hostile()
	ui.free()
	_test_hands_panel(root)


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
				if not v is String or (v as String).to_utf8_buffer().size() > (64 if k == "action" else 1024):
					return false
			"entry":
				if not v is int:
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
	w.rows[1].pressed.emit()
	w.rows[1].mouse_entered.emit()
	w.count_spin.set_value_no_signal(5)
	w.count_spin.value_changed.emit(5.0)   # as when the player types in the box
	w.rows[0].pressed.emit()
	w.rows[0].pressed.emit()
	_key(KEY_ENTER)
	_expect({"id": 7, "picks": [[1, 5]]}, "click ticks, count box sets 5, second click unticks")
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


func _test_popup() -> void:
	print("ui: popup")
	var req := _req("popup", {"context": "YESNO", "text": "Really <color_red>eat</color> it?",
			"actions": PackedStringArray(["YES", "NO"])})
	_show(req)
	var w := ui.widget as PopupRequestWidget
	_check.call(w.buttons.size() == 2 and w.buttons[0].text.ends_with("Yes"), "one button per action")
	_key(KEY_N)
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
	_show(_req("number", {"title": "How many?"}))
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
