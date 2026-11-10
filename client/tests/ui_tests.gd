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
	_test_chargen()
	_test_main_menu()
	_test_world_setup()
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
				if not v is String or (v as String).to_utf8_buffer().size() > (64 if k == "action" else 16384):
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
	m.show_page("credits")
	_check.call(m.page == "credits" and m._box.get_child_count() >= 4, "menu: credits page")
	m.show_page("new")
	m._world_edit.text = "World"
	_check.call(not m.start_new() and got.is_empty(), "menu: won't replace an existing world")
	m._world_edit.text = "Fresh"
	_check.call(m.start_new() and got[-1] == ["new", "Fresh", true, true, true], "menu: new world with chargen and setup")
	m.show_page("load")
	_check.call(m.select_world("Other") and m.start_load() and got[-1] == ["load", "Other", "Ann"],
			"menu: load a save")
	_check.call(m.select_world("World") and not m.start_load(), "menu: world without saves can't load")
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
