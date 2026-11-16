extends RefCounted
## The F1 key menu with a pad only: the D-pad / left stick pick a slot (one step per push), A sets it (the
## press itself doesn't bind), B / Start close, and the menu keeps every pad event. Run by run_tests.gd.

var _check: Callable


func run(root: Node, check: Callable) -> void:
	_check = check
	print("key menu pad")
	var path: String = preload("res://tests/test_dir.gd").path("key_menu_pad.json")
	InputActions.reset_all()
	var menu := KeyMenu.new()
	menu.save_path = path
	root.add_child(menu)
	menu.open()
	_check.call(menu.cursor.x == -1, "key menu pad: nothing picked at first")
	menu.take(_button(JOY_BUTTON_A))
	_check.call(menu._capture.is_empty(), "key menu pad: A with nothing picked does nothing")
	menu.take(_button(JOY_BUTTON_DPAD_DOWN))
	_check.call(menu.cursor == Vector2i(0, KeyMenu.PAD_SLOT) and _picked(menu) == _slot(menu, 0, KeyMenu.PAD_SLOT),
			"key menu pad: the first push picks the first action's pad slot, highlighted")
	menu.take(_button(JOY_BUTTON_DPAD_DOWN))
	menu.take(_button(JOY_BUTTON_DPAD_DOWN, false))   # releases don't move
	menu.take(_button(JOY_BUTTON_DPAD_RIGHT))
	menu.take(_button(JOY_BUTTON_DPAD_RIGHT))          # already the last column
	menu.take(_button(JOY_BUTTON_DPAD_UP))
	menu.take(_button(JOY_BUTTON_DPAD_UP))             # already the first row
	_check.call(menu.cursor == Vector2i(0, KeyMenu.LAST_SLOT), "key menu pad: the pick stays inside the list (%s)" % [menu.cursor])
	menu.take(_stick(JOY_AXIS_LEFT_Y, 0.9))
	menu.take(_stick(JOY_AXIS_LEFT_Y, 0.95))   # still held: no second step
	menu.take(_stick(JOY_AXIS_LEFT_Y, 0.1))
	menu.take(_stick(JOY_AXIS_LEFT_Y, 0.9))
	menu.take(_stick(JOY_AXIS_LEFT_X, -0.9))
	menu.take(_stick(JOY_AXIS_LEFT_X, NAN))
	menu.take(_stick(JOY_AXIS_RIGHT_Y, 0.9))   # the right stick doesn't move the pick
	_check.call(menu.cursor == Vector2i(2, KeyMenu.PAD_SLOT), "key menu pad: the stick steps once per push (%s)" % [menu.cursor])
	var action: StringName = InputActions.ACTIONS[2][0]
	menu.take(_stick(JOY_AXIS_LEFT_X, 0.9))
	menu.take(_button(JOY_BUTTON_A))
	_check.call(menu._capture == [action, KeyMenu.PAD_SLOT + 1], "key menu pad: A starts setting the picked slot")
	menu.take(_button(JOY_BUTTON_A, false))   # A let go: not a binding
	_check.call(menu._capture == [action, KeyMenu.PAD_SLOT + 1], "key menu pad: letting go of A binds nothing")
	menu.take(_button(JOY_BUTTON_X))
	var texts: Array = InputActions.pad_slots(action).map(func(e: InputEvent) -> String: return InputActions.event_text(e))
	var shown := (menu._buttons[action][KeyMenu.PAD_SLOT + 1] as Button).text
	_check.call(menu._capture.is_empty() and texts.size() == 2 and texts[1] == "pad:%d" % JOY_BUTTON_X and shown == "Pad X",
			"key menu pad: the next pad button binds in the second pad column (%s, %s)" % [texts, shown])
	menu.start_capture(&"cdda_wield", 1)
	_check.call(menu.cursor == Vector2i(_row(&"cdda_wield"), 1), "key menu pad: a clicked slot becomes the pick")
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	menu.take(esc)
	_check.call(menu.take(_stick(JOY_AXIS_RIGHT_X, 0.2)) and menu.visible, "key menu pad: every pad event is kept by the open menu")
	menu.take(_button(JOY_BUTTON_B))
	_check.call(not menu.visible, "key menu pad: B closes")
	menu.open()
	menu.take(_button(JOY_BUTTON_START))
	_check.call(not menu.visible, "key menu pad: Start closes")
	menu.open()
	menu.cursor = Vector2i(0, 0)   # the D-pad reaches the key slots too
	menu.take(_button(JOY_BUTTON_A))
	var setting_key := menu._capture == [InputActions.ACTIONS[0][0], 0]
	menu.take(_button(JOY_BUTTON_X))
	var x_ignored := not menu._capture.is_empty()
	menu.take(_button(JOY_BUTTON_B))
	_check.call(setting_key and x_ignored and menu._capture.is_empty() and menu.visible,
			"key menu pad: a key slot set from the pad ignores pad buttons, B backs out of it")
	menu.close()
	# without keys (the VR panel): ui_cancel backs out of a capture, then closes; other actions pass
	menu.open()
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	var up := InputEventAction.new()
	up.action = &"ui_up"
	up.pressed = true
	var released := InputEventAction.new()
	released.action = &"ui_cancel"
	menu._capture = [&"cdda_examine", 0]
	var passed := not menu.take(up) and not menu.take(released)
	var backed := menu.take(cancel) and menu._capture.is_empty() and menu.visible
	_check.call(passed and backed and menu.take(cancel) and not menu.visible,
			"keys menu: ui_cancel backs out of a capture, then closes the menu")
	menu.free()
	InputActions.reset_all()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _button(i: JoyButton, pressed := true) -> InputEventJoypadButton:
	var b := InputEventJoypadButton.new()
	b.button_index = i
	b.pressed = pressed
	return b


func _stick(axis: JoyAxis, v: float) -> InputEventJoypadMotion:
	var m := InputEventJoypadMotion.new()
	m.axis = axis
	m.axis_value = v
	return m


func _slot(menu: KeyMenu, row: int, slot: int) -> Button:
	return (menu._buttons[InputActions.ACTIONS[row][0]] as Array)[slot]


func _picked(menu: KeyMenu) -> Button:
	for a: StringName in menu._buttons:
		for b: Button in menu._buttons[a]:
			if b.modulate == KeyMenu.PICKED:
				return b
	return null


func _row(action: StringName) -> int:
	for i in InputActions.ACTIONS.size():
		if InputActions.ACTIONS[i][0] == action:
			return i
	return -1
