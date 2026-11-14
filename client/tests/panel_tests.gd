extends RefCounted
## L4 / G1: CDDA's prompts (RequestUI) inside a SubViewport, as the VR panel hosts them: laid out to the viewport's
## size, answered by pointer clicks pushed into the viewport (motion, press, release) and by ui_* actions (what the
## panel's stick and buttons push; a pad's D-pad / A / B on screen). Needs frames (layout, GUI input): run_tests
## awaits run().

var _check: Callable
var _tree: SceneTree
var _vp: SubViewport
var ui: RequestUI
var answers: Array = []


func run(root: Node, check: Callable) -> void:
	_check = check
	_tree = root.get_tree()
	print("panel")
	_vp = SubViewport.new()
	_vp.size = Vector2i(1280, 800)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED   # nothing to draw in the tests
	root.add_child(_vp)
	ui = RequestUI.new()
	ui.answered.connect(func(a: Dictionary) -> void: answers.append(a))
	_vp.add_child(ui)
	await _test_layout_and_click()
	await _test_actions()
	await _test_direction()
	_test_pad()
	_test_panel_root()
	await _test_held_then_hidden()
	await _test_scaled()
	_test_keys_pad()
	await _test_fit()
	await _test_dock()
	await _test_string_pad()
	_vp.free()
	ui = null


func _test_layout_and_click() -> void:
	_show(_req("menu", {"title": "Wait for how long?", "entries": _entries(["5 minutes", "30 minutes", "Sleep"], 10)}))
	await _frames()
	var w := ui.widget as ListRequestWidget
	var panel := ui._panel.get_global_rect()
	_check.call(ui.size == Vector2(_vp.size) and Rect2(Vector2.ZERO, Vector2(_vp.size)).encloses(panel)
			and absf(panel.get_center().x - _vp.size.x / 2.0) < 1.0 and w != null and w.rows.size() == 3,
			"panel: a prompt lays out to its SubViewport (%s in %s)" % [panel, _vp.size])
	if w == null or w.rows.size() < 3:
		return
	_click(w.rows[2].get_global_rect().get_center())
	_check.call(answers == [{"id": 7, "entry": 12}], "panel: a click pushed into the viewport picks a row (%s)" % [answers])
	_show(_req("popup", {"context": "YESNO", "text": "Really eat it?", "actions": PackedStringArray(["YES", "NO"])}))
	await _frames()
	var p := ui.widget as PopupRequestWidget
	if p != null and p.buttons.size() >= 2:
		_click(p.buttons[1].get_global_rect().get_center())
	_check.call(answers == [{"id": 7, "action": "NO"}], "panel: a click on a popup's button answers it (%s)" % [answers])


func _test_actions() -> void:
	_show(_req("menu", {"entries": _entries(["5 minutes", "30 minutes", "Sleep"], 10)}))
	await _frames()
	_action(&"ui_down")
	_action(&"ui_down", false)   # a release does nothing
	_action(&"ui_accept")
	_check.call(answers == [{"id": 7, "entry": 11}], "panel: ui_down, ui_accept pick the next row (%s)" % [answers])
	_show(_req("popup", {"context": "YESNO", "text": "Really eat it?", "actions": PackedStringArray(["YES", "NO"])}))
	await _frames()
	_action(&"ui_right")
	_action(&"ui_accept")
	_check.call(answers == [{"id": 7, "action": "NO"}], "panel: ui_right, ui_accept on a popup (%s)" % [answers])
	_show(_req("menu", {"entries": _entries(["5 minutes"], 10)}))
	await _frames()
	_action(&"ui_cancel")
	_check.call(answers == [{"id": 7, "cancel": true}] and not ui.visible, "panel: ui_cancel cancels (%s)" % [answers])
	_show(_req("popup", {"text": "Press any key.", "actions": PackedStringArray(["CONFIRM"]), "allow_cancel": false}))
	_action(&"ui_text_completion_accept")   # not one of ours: left alone
	var none := answers.is_empty()
	_action(&"ui_accept")
	_check.call(none and answers == [{"id": 7, "action": "CONFIRM"}], "panel: other actions are left alone (%s)" % [answers])


func _test_direction() -> void:
	_show(_req("direction", {"text": "Open where?"}))
	await _frames()
	var d := ui.widget as DirectionRequestWidget
	if d != null and d.pad.size() == 9:
		_click(d.pad[5].get_global_rect().get_center())   # "→"
	_check.call(answers == [{"id": 7, "pos": Vector3i(1, 0, 0)}], "panel: a direction by clicking its arrow (%s)" % [answers])


## A pad on screen: D-pad down and A through the same path; stick motion and keys as before.
func _test_pad() -> void:
	_show(_req("menu", {"entries": _entries(["5 minutes", "30 minutes"], 10)}))
	var stick := InputEventJoypadMotion.new()
	stick.axis = JOY_AXIS_LEFT_Y
	stick.axis_value = 1.0
	var used_stick := ui.handle_input(stick)
	var down := InputEventJoypadButton.new()
	down.button_index = JOY_BUTTON_DPAD_DOWN
	down.pressed = true
	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	a.pressed = true
	var used := ui.handle_input(down)
	ui.handle_input(a)
	_check.call(not used_stick and used and answers == [{"id": 7, "entry": 11}],
			"panel: a pad's D-pad and A answer a menu, the stick is left alone (%s)" % [answers])
	var k := RequestUI.as_key(down) as InputEventKey
	var key := InputEventKey.new()
	key.keycode = KEY_DOWN
	key.pressed = true
	_check.call(k != null and k.keycode == KEY_DOWN and k.pressed and RequestUI.as_key(key) == key
			and RequestUI.as_key(stick) == stick, "panel: as_key: a pad button as its key, keys and the stick as they are")


## The laser holds a row down while the request goes (answered elsewhere, or replaced): Godot's release on hiding
## clicks that row, which must answer nothing, nor touch the request shown next.
func _test_held_then_hidden() -> void:
	_show(_req("menu", {"entries": _entries(["5 minutes", "30 minutes", "Sleep"], 10)}))
	await _frames()
	var w := ui.widget as ListRequestWidget
	var at := w.rows[1].get_global_rect().get_center() if w != null and w.rows.size() > 1 else Vector2.ZERO
	_mouse(at, true)
	ui.clear()
	await _frames()
	var gone := answers.is_empty()
	_show(_req("menu", {"entries": _entries(["Yes", "No"], 20)}, 8))
	await _frames()
	_mouse(at, true)
	ui.show_request(_req("menu", {"entries": _entries(["Later"], 30)}, 9))
	await _frames()
	_mouse(at, false)
	await _frames()
	_check.call(gone and answers.is_empty() and ui.is_showing() and ui.request_id == 9,
			"panel: a row held while its request goes answers nothing (%s)" % [answers])
	ui.clear()


## RequestUI.set_ui_scale (the VR panel): drawn larger, still within the viewport, and a click still lands on the
## row under it.
func _test_scaled() -> void:
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(host)
	ui.reparent(host, false)
	ui.set_ui_scale(1.35)
	_show(_req("menu", {"entries": _entries(["5 minutes", "30 minutes", "Sleep"], 10)}))
	await _frames()
	var w := ui.widget as ListRequestWidget
	var panel := ui._panel.get_global_rect()
	var row := w.rows[2].get_global_rect() if w != null and w.rows.size() > 2 else Rect2()
	var fits := Rect2(Vector2.ZERO, Vector2(_vp.size)).encloses(panel) and absf(panel.get_center().x - _vp.size.x / 2.0) < 2.0
	_check.call(fits and is_equal_approx(row.size.y, w.rows[2].size.y * 1.35) and ui.get_global_rect().size.is_equal_approx(Vector2(_vp.size)),
			"panel: scaled 1.35, it still fills the viewport and the prompt fits (%s)" % [panel])
	_click(row.get_center())
	_check.call(answers == [{"id": 7, "entry": 12}], "panel: a click on a scaled row picks it (%s)" % [answers])
	ui.set_ui_scale(NAN)
	_check.call(ui.ui_scale == 1.0 and ui.scale == Vector2.ONE, "panel: a bad scale is 1")


## TextKeys by pad and stick: the D-pad / ui_* actions move a cursor over the keys (wrapping, keeping its place
## between rows of different lengths), A / ui_accept presses, X is Back, Y is Shift; real keys, the mouse and
## releases are left alone.
func _test_keys_pad() -> void:
	var le := LineEdit.new()
	_vp.add_child(le)
	var k := TextKeys.new()
	_vp.add_child(k)
	k.target = le
	var entered := [0]
	k.enter.connect(func() -> void: entered[0] += 1)
	var untouched := not k.handle_input(_pad(JOY_BUTTON_A)) and not k.handle_input(_act(&"ui_accept")) and le.text == "" \
			and not k.cursor_on
	var first := untouched and k.handle_input(_pad(JOY_BUTTON_DPAD_RIGHT)) and k.cursor_on and k.cursor == Vector2i.ZERO
	k.handle_input(_act(&"ui_right"))
	k.handle_input(_pad(JOY_BUTTON_A))
	k.handle_input(_pad(JOY_BUTTON_DPAD_DOWN))
	k.handle_input(_pad(JOY_BUTTON_Y))
	k.handle_input(_act(&"ui_accept"))
	var typed := le.text
	k.handle_input(_pad(JOY_BUTTON_X))
	_check.call(first and typed == "2W" and le.text == "2" and not k.shift and k.cursor == Vector2i(1, 1),
			"keys pad: accept is left alone until the cursor shows; the first direction shows it; then A types, Y shifts, X deletes (%s)" % typed)
	k.handle_input(_pad(JOY_BUTTON_DPAD_LEFT))
	k.handle_input(_pad(JOY_BUTTON_DPAD_LEFT))
	var wrapped := k.cursor
	for i in 3:
		k.handle_input(_act(&"ui_down"))
	var bottom := k.cursor_key()
	k.handle_input(_pad(JOY_BUTTON_A))
	k.handle_input(_act(&"ui_up"))
	var up := k.cursor_key().text
	k.handle_input(_act(&"ui_down"))
	k.handle_input(_act(&"ui_down"))
	_check.call(wrapped == Vector2i(9, 1) and bottom == k.enter_button and entered[0] == 1 and up == "." and k.cursor.y == 0
			and le.text == "2", "keys pad: it wraps, keeps its place across rows, and Enter is a key (%s, %s)" % [wrapped, up])
	var key := InputEventKey.new()
	key.keycode = KEY_DOWN
	key.pressed = true
	var released := _pad(JOY_BUTTON_A)
	released.pressed = false
	var at := k.cursor
	_check.call(not k.handle_input(key) and not k.handle_input(released) and not k.handle_input(InputEventMouseMotion.new())
			and not k.handle_input(_act(&"ui_cancel")) and not k.handle_input(_pad(JOY_BUTTON_B)) and not k.handle_input(null)
			and k.cursor == at and le.text == "2", "keys pad: real keys, the mouse, releases, cancel and B are left alone")
	k.free()
	le.free()


## PanelFit: a full-rect menu drawn larger still fills its parent, keeps the margins it had, and follows the
## parent's size; main.menus_to_panel moves menus under the panel's root that way. Not full-rect: left alone.
func _test_fit() -> void:
	var Main := load("res://scripts/main.gd")
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(root)
	var old := Control.new()
	_vp.add_child(old)
	var full := Control.new()
	full.set_anchors_preset(Control.PRESET_FULL_RECT)
	var inset := Control.new()   # like the F1 menu: margins of its own
	inset.set_anchors_preset(Control.PRESET_FULL_RECT)
	inset.offset_left = 60
	inset.offset_top = 50
	inset.offset_right = -60
	inset.offset_bottom = -50
	old.add_child(full)
	old.add_child(inset)
	Main.menus_to_panel(root, [full, null, inset, "junk"], 1.35)
	await _frames()
	var fr := full.get_global_rect()
	var ir := inset.get_global_rect()
	var area := Vector2(_vp.size)
	_check.call(full.get_parent() == root and inset.get_parent() == root and inset.get_index() > full.get_index()
			and fr.position.is_equal_approx(Vector2.ZERO) and fr.size.is_equal_approx(area)
			and full.size.is_equal_approx(area / 1.35) and full.scale == Vector2(1.35, 1.35)
			and ir.position.is_equal_approx(Vector2(60, 50)) and ir.end.is_equal_approx(area - Vector2(60, 50)),
			"fit: menus moved to the panel fill it drawn 1.35x, margins kept (%s, %s)" % [fr, ir])
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root.size = Vector2(640, 400)
	await _frames()
	_check.call(full.get_global_rect().size.is_equal_approx(Vector2(640, 400))
			and inset.get_global_rect().end.is_equal_approx(Vector2(580, 350)), "fit: it follows the parent's size")
	var corner := Control.new()
	corner.size = Vector2(100, 40)
	root.add_child(corner)
	var again := PanelFit.apply(inset, NAN)
	_check.call(not PanelFit.apply(corner, 1.35) and corner.scale == Vector2.ONE and not PanelFit.apply(null, 2.0)
			and again and inset.scale == Vector2.ONE and inset.anchor_right == 1.0 and inset.offset_right == -60.0
			and not inset.has_meta(PanelFit.META) and PanelFit.apply(full, 99.0) and full.scale == Vector2(3, 3),
			"fit: not full-rect or freed: left alone; a bad scale is 1 and puts the anchors back; capped at 3")
	root.free()
	old.free()


## TextKeysDock: the keyboard for whichever text field has the focus. A pad's Y opens it; with `auto` (the VR panel)
## a click on the field opens it and a tab shows otherwise; B, Hide or the focus leaving closes it; it sits at the
## bottom, or at the top while the field is low; a field with its own keys is left alone; hidden when not needed.
func _test_dock() -> void:
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vp.add_child(host)
	var le := LineEdit.new()
	le.position = Vector2(100, 100)
	le.size = Vector2(300, 30)
	host.add_child(le)
	var other := Button.new()   # something later in the tree: the dock goes over it when it opens
	host.add_child(other)
	var dock := TextKeysDock.new()
	host.add_child(dock)
	host.move_child(dock, 0)
	var sent := [0]
	le.text_submitted.connect(func(_t: String) -> void: sent[0] += 1)
	await _frames()
	_check.call(not dock.visible and dock.target == null and not dock.handle_input(_pad(JOY_BUTTON_Y)),
			"dock: hidden with no text field focused; Y does nothing")
	le.grab_focus()
	await _frames()
	var quiet := dock.target == le and not dock.visible and not dock.is_open()
	_vp.push_input(_pad(JOY_BUTTON_Y), true)
	var opened := dock.is_open() and dock.visible and dock.panel.visible and dock.get_index() == host.get_child_count() - 1
	var at_bottom := dock.panel.position.y > host.size.y / 2.0 \
			and absf(dock.panel.position.x + dock.panel.get_combined_minimum_size().x / 2.0 - host.size.x / 2.0) < 1.0
	_vp.push_input(_pad(JOY_BUTTON_A), true)
	_vp.push_input(_act(&"ui_right"), true)
	_vp.push_input(_act(&"ui_accept"), true)
	_check.call(quiet and opened and at_bottom and le.text == "12",
			"dock: a focused field alone shows nothing; a pad's Y opens the keys at the bottom, over the rest; the pad types (%s)" % le.text)
	dock.keys.enter_button.pressed.emit()
	_vp.push_input(_pad(JOY_BUTTON_B), true)
	_check.call(sent[0] == 1 and not dock.is_open() and not dock.visible and le.has_focus(),
			"dock: Enter reaches the field as a real Enter; B closes the keys, the field keeps the focus")
	dock.auto = true
	await _frames()
	var tab := dock.visible and dock.tab.visible and not dock.panel.visible
	_mouse(le.get_global_rect().get_center(), true)
	_mouse(le.get_global_rect().get_center(), false)
	await _frames()
	var by_click := dock.is_open() and dock.panel.visible and not dock.tab.visible
	dock.hide_button.pressed.emit()
	_mouse(Vector2(900, 400), true)   # a click elsewhere doesn't open them
	_mouse(Vector2(900, 400), false)
	await _frames()
	var stays := not dock.is_open() and dock.tab.visible
	dock.tab.pressed.emit()
	_check.call(tab and by_click and stays and dock.is_open(),
			"dock auto: a tab while a field has the focus; a click on the field or the tab opens the keys, Hide closes them")
	le.position.y = 600
	dock.ui_scale = 1.35
	dock.close()
	dock.open()
	_check.call(is_equal_approx(dock.panel.position.y, TextKeysDock.MARGIN) and dock.panel.scale == Vector2(1.35, 1.35)
			and dock.panel.position.x >= 0.0, "dock: over a field low on the page the keys sit at the top; drawn larger with ui_scale")
	le.release_focus()
	await _frames()
	var left := not dock.visible and dock.target == null and not dock.is_open()
	le.set_meta(TextKeysDock.OWN_KEYS, true)
	le.grab_focus()
	await _frames()
	var own := dock.target == null and not dock.visible
	le.remove_meta(TextKeysDock.OWN_KEYS)
	le.editable = false
	await _frames()
	_check.call(left and own and dock.target == null and not dock.open(),
			"dock: it closes when the focus leaves; fields with their own keys or not editable are left alone")
	host.free()


## A text prompt by pad alone: Y opens its keys, the D-pad and A type, the keys' Enter sends the answer.
func _test_string_pad() -> void:
	ui.keyboard = false
	_show(_req("string", {"title": "Name", "max_len": 8, "entries": [{"id": 0, "label": "", "enabled": true, "description": ""}]}))
	await _frames()
	var w := ui.widget as StringRequestWidget
	var hidden := w != null and not w.keys.visible and w.edit.has_meta(TextKeysDock.OWN_KEYS)
	_vp.push_input(_pad(JOY_BUTTON_Y), true)
	var shown := w != null and w.keys.visible
	_vp.push_input(_pad(JOY_BUTTON_A), true)
	_vp.push_input(_pad(JOY_BUTTON_DPAD_DOWN), true)
	_vp.push_input(_act(&"ui_accept"), true)
	var text := w.edit.text if w != null else ""
	if w != null:
		w.keys.enter_button.pressed.emit()
	_check.call(hidden and shown and text == "1q" and answers == [{"id": 7, "text": "1q"}],
			"panel: a text prompt by pad: Y opens the keys, the D-pad and A type, Enter sends (%s, %s)" % [text, answers])
	# on the VR panel the keys show from the start: accept still sends the prompt as it stands (it types nothing)
	# until a direction has put the cursor on the keys
	ui.keyboard = true
	_show(_req("string", {"title": "How many?", "entries": [{"id": 0, "label": "5", "enabled": true, "description": ""}]}))
	await _frames()
	w = ui.widget as StringRequestWidget
	var from_start := w != null and w.keys.visible and not w.keys.cursor_on
	_vp.push_input(_act(&"ui_accept"), true)
	var sent_as_is := answers == [{"id": 7, "text": "5"}]
	_show(_req("string", {"title": "How many?", "entries": [{"id": 0, "label": "5", "enabled": true, "description": ""}]}))
	await _frames()
	w = ui.widget as StringRequestWidget
	if w != null:
		w.edit.deselect()
		w.edit.caret_column = 1
	_vp.push_input(_act(&"ui_down"), true)
	_vp.push_input(_act(&"ui_accept"), true)
	var typed := w.edit.text if w != null else ""
	_check.call(from_start and sent_as_is and typed == "51" and answers.is_empty(),
			"panel: keys shown from the start: accept sends the prompt as it stands; after a direction it types (%s)" % typed)
	ui.keyboard = false
	ui.clear()
	_show(_req("string", {"entries": [{"id": 0, "label": "x", "enabled": true, "description": ""}]}))
	await _frames()
	_vp.push_input(_pad(JOY_BUTTON_Y), true)
	_vp.push_input(_pad(JOY_BUTTON_B), true)
	_check.call(answers == [{"id": 7, "cancel": true}], "panel: B still cancels a text prompt while its keys show (%s)" % [answers])


func _pad(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	return e


func _act(a: StringName) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = true
	return e


## main.gd finds the VR panel's root by name (VrPanel.root) and only when it is a Control.
func _test_panel_root() -> void:
	var Main := load("res://scripts/main.gd")
	var rig := FakeRig.new()
	var none: Variant = Main.panel_root(rig)
	rig.panel = FakeRig.new()   # an object without `root`
	var no_root: Variant = Main.panel_root(rig)
	var r := Control.new()
	rig.panel = FakePanel.new(r)
	var found: Variant = Main.panel_root(rig)
	rig.panel = FakePanel.new(Node.new())
	var not_control: Variant = Main.panel_root(rig)
	(rig.panel as FakePanel).root.free()
	_check.call(none == null and no_root == null and found == r and not_control == null and Main.panel_root(null) == null,
			"panel: main finds VrPanel.root by name, only a Control")
	r.free()


class FakeRig:
	extends RefCounted
	var panel: Variant


class FakePanel:
	extends RefCounted
	var root: Variant

	func _init(r: Variant) -> void:
		root = r


func _show(req: Dictionary) -> void:
	answers.clear()
	ui.show_request(req)


func _frames() -> void:
	await _tree.process_frame
	await _tree.process_frame


func _click(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	_vp.push_input(m, true)
	for down: bool in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = down
		b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		b.position = at
		b.global_position = at
		_vp.push_input(b, true)


## A left button press or release at `at` (with the motion there first).
func _mouse(at: Vector2, down: bool) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_vp.push_input(m, true)
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = down
	b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	b.position = at
	b.global_position = at
	_vp.push_input(b, true)


func _action(a: StringName, pressed := true) -> void:
	var e := InputEventAction.new()
	e.action = a
	e.pressed = pressed
	_vp.push_input(e, true)


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
