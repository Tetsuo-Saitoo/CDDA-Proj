extends RefCounted
## L4: the VR panel for CDDA's 2D menus and prompts (VrPanel, VrRig.panel / panel_button). A dialog of two Buttons
## under panel.root: the panel shows while it is visible, stands in front of the head, follows only after being out
## of view for AWAY_S; the main hand's laser hovers and clicks (press on the panel, release always, even off it);
## the sticks step the focus (with repeat) and the main stick's up / down turns the wheel under the laser; A is
## ui_accept, B ui_cancel; the settings menu takes the pointer over the panel; hiding lets go of a held button. No XR
## runtime: the test places the controllers and presses buttons. Run by run_tests.gd.

const DT := 0.05

var _check: Callable
var _world: WorldView
var _rig: VrRig
var _p: VrPanel
var _dialog: Control
var _a: Button
var _b: Button
var _pressed := {"a": 0, "b": 0}
var _got: Array[InputEvent] = []   # what reached B's gui_input
var _shown: Array[bool] = []


func run(root: Node, check: Callable, _data: Variant, _tables: IdTables) -> void:
	_check = check
	print("vr panel")
	_world = WorldView.new()
	root.add_child(_world)
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_p = _rig.panel
	_p.shown_changed.connect(func(on: bool) -> void: _shown.append(on))
	_build_dialog()
	_test_show()
	_test_laser()
	_test_release_off_panel()
	_test_buttons()
	_test_keys_and_pad(root)
	_test_sticks()
	_test_follow()
	_test_menu_over_panel()
	_test_hide_lets_go()
	_test_bad_poses()
	_rig.free()
	_world.free()


func _build_dialog() -> void:
	_dialog = Control.new()
	_dialog.visible = false
	_dialog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_p.root.add_child(_dialog)
	_a = _button("A", Vector2(100, 100))
	_b = _button("B", Vector2(100, 300))
	_a.pressed.connect(func() -> void: _pressed["a"] += 1)
	_b.pressed.connect(func() -> void: _pressed["b"] += 1)
	_b.gui_input.connect(func(e: InputEvent) -> void: _got.append(e))


func _button(t: String, at: Vector2) -> Button:
	var b := Button.new()
	b.text = t
	b.position = at
	b.size = Vector2(300, 100)
	_dialog.add_child(b)
	return b


func _frame(move := Vector2.ZERO, turn := Vector2.ZERO) -> void:
	_rig.panel.update(DT, _rig.camera.transform)
	_rig.step(DT, {"move": move, "turn": turn})
	_rig.update_pointer(true)


## Points the main controller from 0.6 m in front of the panel at logical pixel px (outside PX: off the panel).
func _aim_px(px: Vector2) -> void:
	var local := Vector3((px.x / VrPanel.PX.x - 0.5) * VrPanel.SIZE_M.x, (0.5 - px.y / VrPanel.PX.y) * VrPanel.SIZE_M.y, 0)
	var at := _p.global_transform * local
	var from := _p.global_transform * Vector3(0, 0, 0.6)
	_rig.main_ctrl().global_transform = Transform3D(Basis.looking_at(at - from, Vector3.UP), from)


func _mid(b: Button) -> Vector2:
	return b.position + b.size * 0.5


func _test_show() -> void:
	_frame()
	_check.call(not _p.shown and not _p.visible and _shown.is_empty() and not _rig.ui_open(),
			"vr panel: nothing under root: hidden")
	_check.call(_p.viewport.get_visible_rect().size == Vector2(VrPanel.PX) and _p.root.size == Vector2(VrPanel.PX),
			"vr panel: root lays out to the panel's logical pixels, not the window (%s, %s)"
			% [_p.viewport.get_visible_rect().size, _p.root.size])
	_dialog.visible = true
	_frame()
	var want := Vector3(0, 1.6 - VrPanel.DROP, -VrPanel.DIST)
	_check.call(_p.shown and _p.visible and _shown == [true] and _rig.ui_open()
			and _p.position.distance_to(want) < 0.001 and _p.basis.z.dot(Vector3.BACK) > 0.999
			and _p.viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
			"vr panel: a visible dialog shows it in front of the head, facing it, rendering")


func _test_laser() -> void:
	_aim_px(_mid(_b))
	_frame()
	var h: Variant = _p.hover
	_check.call(h is Vector2 and (h as Vector2).distance_to(_mid(_b)) < 1.0 and _rig.pointer.visible
			and _rig.pointer_dot.visible and _b.is_hovered(),
			"vr panel: the laser hovers the button it points at, dot on the panel")
	_rig.press(_rig.main_ctrl(), "trigger_click")
	_check.call(_b.is_pressed() and _pressed["b"] == 0, "vr panel: the main trigger presses the left button there")
	_rig.release(_rig.main_ctrl(), "trigger_click")
	_check.call(_pressed["b"] == 1 and not _b.is_pressed(), "vr panel: its release clicks the button")


func _test_release_off_panel() -> void:
	_aim_px(_mid(_a))
	_frame()
	_rig.press(_rig.main_ctrl(), "trigger_click")
	_aim_px(Vector2(-400, 1200))
	_frame()
	_check.call(_p.hover == null and _a.is_pressed(), "vr panel: dragged off the panel, the button is still held")
	_rig.release(_rig.main_ctrl(), "trigger_click")
	_check.call(not _a.is_pressed() and _pressed["a"] == 0,
			"vr panel: the release goes out off the panel too (held button let go, no click)")
	var sent := _p.events
	_rig.press(_rig.main_ctrl(), "trigger_click")
	_rig.release(_rig.main_ctrl(), "trigger_click")
	_check.call(_p.events == sent, "vr panel: a trigger off the panel sends nothing")


func _test_buttons() -> void:
	_b.grab_focus()
	_got.clear()
	_rig.press(_rig.right, "ax_button")
	_rig.release(_rig.right, "ax_button")
	_check.call(_pressed["b"] == 2, "vr panel: A is ui_accept on the focused button")
	_rig.press(_rig.off_ctrl(), "trigger_click")
	_rig.release(_rig.off_ctrl(), "trigger_click")
	_check.call(_pressed["b"] == 3, "vr panel: the off trigger is ui_accept too")
	_got.clear()
	_rig.press(_rig.left, "by_button")
	var cancel := false
	for e in _got:
		cancel = cancel or e.is_action_pressed(&"ui_cancel")
	_rig.release(_rig.left, "by_button")
	var up := false
	for e in _got:
		up = up or e.is_action_released(&"ui_cancel")
	_check.call(cancel and up, "vr panel: B / Y is ui_cancel, pressed and released")
	var sent := _p.events
	_rig.release(_rig.left, "by_button")
	_check.call(_p.events == sent, "vr panel: a release with nothing held sends nothing")


## A desk keyboard and a pad answer the panel while it shows (pushed in, handled in the window), not while hidden.
func _test_keys_and_pad(root: Node) -> void:
	var win := root.get_viewport()
	_a.grab_focus()
	_got.clear()
	var k := InputEventKey.new()   # the arrow down: the panel's focus moves A -> B and handles it
	k.keycode = KEY_DOWN
	k.physical_keycode = KEY_DOWN
	k.pressed = true
	win.push_input(k)
	var key_handled := win.is_input_handled()
	var got_k := _b.has_focus()
	var f1 := InputEventKey.new()
	f1.keycode = KEY_F1
	f1.physical_keycode = KEY_F1
	f1.pressed = true
	win.push_input(f1)
	var f1_free := not win.is_input_handled()
	var got_f1 := _got.any(func(e: InputEvent) -> bool: return e is InputEventKey and (e as InputEventKey).keycode == KEY_F1)
	f1.pressed = false
	win.push_input(f1)
	var j := InputEventJoypadButton.new()
	j.button_index = JOY_BUTTON_A
	j.pressed = true
	win.push_input(j)
	var m := InputEventJoypadMotion.new()
	m.axis = JOY_AXIS_LEFT_Y
	m.axis_value = 1.0
	win.push_input(m)
	var got_j := false
	var got_m := false
	for e in _got:
		got_j = got_j or (e is InputEventJoypadButton and (e as InputEventJoypadButton).button_index == JOY_BUTTON_A)
		got_m = got_m or e is InputEventJoypadMotion
	_check.call(got_k and got_j and got_m and key_handled,
			"vr panel: the window's keys and pad reach the panel (an arrow moves its focus, handled in the window) %s"
			% [[got_k, got_j, got_m, key_handled]])
	_check.call(got_f1 and f1_free, "vr panel: a key nothing in the panel uses (F1) still reaches the window %s"
			% [[got_f1, f1_free]])
	for e: InputEvent in [k, j, m]:   # let go again
		var r: InputEvent = e.duplicate()
		if r is InputEventJoypadMotion:
			(r as InputEventJoypadMotion).axis_value = 0.0
		else:
			r.set("pressed", false)
		win.push_input(r)
	_dialog.visible = false
	_frame()
	_got.clear()
	var sent := _p.events
	win.push_input(k)
	_check.call(_p.events == sent and _got.is_empty() and not win.is_input_handled(),
			"vr panel: hidden, it leaves the window's keys alone")
	k.pressed = false
	win.push_input(k)
	_dialog.visible = true
	_frame()


func _test_sticks() -> void:
	_a.grab_focus()
	_aim_px(Vector2(-400, 1200))   # the laser off the panel
	_frame()
	_frame(Vector2(0, -1))
	_check.call(_b.has_focus(), "vr panel: the move stick down steps the focus down")
	_frame(Vector2(0, 1))
	_check.call(_a.has_focus(), "vr panel: ... and up")
	var sent := _p.events
	_frame(Vector2(0, 0.5))
	_frame(Vector2(0, 1))
	_check.call(_p.events == sent, "vr panel: back between the thresholds only, no second step")
	sent = _p.events
	for i in int((VrPanel.REPEAT_DELAY_S + VrPanel.REPEAT_S * 4.0) / DT) + 1:
		_frame(Vector2(0, -1))
	_frame()
	_check.call(_p.events - sent >= 6, "vr panel: a stick held past ON repeats (%d events)" % (_p.events - sent))
	_a.grab_focus()
	_frame(Vector2.ZERO, Vector2(0, -1))
	_check.call(_b.has_focus(), "vr panel: the main stick steps too while the laser is off the panel")
	_frame()
	_aim_px(_mid(_b))
	_frame()
	_got.clear()
	_frame(Vector2.ZERO, Vector2(0, 1))
	var wheel := false
	for e in _got:
		wheel = wheel or (e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_WHEEL_UP)
	_check.call(wheel, "vr panel: the main stick up turns the wheel under the laser")
	_frame()


func _test_follow() -> void:
	var was := _p.position
	_rig.camera.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0, 1.6, 0))   # turned around
	for i in int(VrPanel.AWAY_S / DT) - 2:
		_frame()
	_check.call(_p.position.distance_to(was) < 0.001, "vr panel: turned away, it stays put for a while")
	for i in 4:
		_frame()
	_check.call(_p.position.distance_to(Vector3(0, 1.6 - VrPanel.DROP, VrPanel.DIST)) < 0.001,
			"vr panel: out of view for AWAY_S, it comes back in front of the head")
	_rig.camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	_p.place(_rig.camera.transform)


func _test_menu_over_panel() -> void:
	_aim_px(_mid(_b))
	_frame()
	_rig.press(_rig.left, "menu_button")
	_frame()
	_check.call(_rig.menu_open() and _p.hover == null and _rig.ui_open(), "vr panel: the settings menu takes the pointer")
	_rig.press(_rig.left, "menu_button")
	_frame()
	_check.call(not _rig.menu_open() and _p.hover != null, "vr panel: menu closed: the laser is on the panel again")


func _test_hide_lets_go() -> void:
	_aim_px(_mid(_b))
	_frame()
	_rig.press(_rig.main_ctrl(), "trigger_click")
	_rig.press(_rig.right, "ax_button")
	var b_was: int = _pressed["b"]
	_dialog.visible = false
	var b_hidden: int = _pressed["b"]   # Godot's own drop of the mouse focus on hide (not the panel's doing)
	print("  (vr panel: hiding a held button clicked it %d time(s) in Godot itself)" % (b_hidden - b_was))
	_frame()
	_check.call(not _p.shown and not _p.visible and _shown.back() == false and not _b.is_pressed()
			and _pressed["b"] == b_hidden and not _rig.pointer.visible
			and _p.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			"vr panel: the dialog hidden: the panel hides, lets go of the held button, the pointer goes %s"
			% [[_p.shown, _p.visible, _shown, _b.is_pressed(), _pressed["b"] - b_hidden, _rig.pointer.visible,
			_p.viewport.render_target_update_mode]])
	var sent := _p.events
	_rig.release(_rig.main_ctrl(), "trigger_click")
	_rig.release(_rig.right, "ax_button")
	_check.call(_p.events == sent, "vr panel: the late releases send nothing more")


func _test_bad_poses() -> void:
	_check.call(VrPanel.to_px(null) == null and VrPanel.to_px(Vector3(NAN, 0, 0)) == null
			and VrPanel.to_px(Vector3(1e9, 0, 0)) == null and not VrPanel.covers(Vector3(INF, 0, 0)),
			"vr panel: bad laser points are ignored")
	_dialog.visible = true
	_frame()
	var sent := _p.events
	_rig.main_ctrl().global_position = Vector3(NAN, NAN, NAN)
	_frame()
	_check.call(_p.events == sent and _p.hover == null, "vr panel: a lost controller pose sends nothing")
	_p.update(DT, Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0)))
	_check.call(_p.position.is_finite(), "vr panel: a bad head pose doesn't move it")
	_dialog.visible = false
	_frame()
