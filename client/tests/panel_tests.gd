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
