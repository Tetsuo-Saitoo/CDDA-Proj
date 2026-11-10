class_name KeyMenu
extends PanelContainer
## Key menu (F1): every action with two key slots and a pad slot. Click a key slot, then press a key or mouse
## button (modifiers count: Shift+E is its own key; a modifier alone binds when let go); click the pad slot,
## then press a pad button or push a stick / trigger one way. Esc cancels, Backspace clears the slot. Each change is saved at once (InputActions.save_bindings); a key that another action also uses is
## kept on both and named in the status line. While open the menu takes every key, so nothing reaches the game.
## With add_hud_settings() it also has the HUD row (compass opacity slider, the debug-cheats switch), saved in
## user://hud.cfg. With add_cheat_page() a "Cheats" button swaps the key list for the CheatPanel; it shows only
## while cheats are allowed (the debug switch, or cheats_forced by --test / --cheats).

signal closed
signal hud_changed   # a HudSettings value changed (and was saved)

const SLOTS := 2
const PAD_SLOT := SLOTS   # slot index of the pad column (one pad binding shown; more show as +N)
const WARN := Color(1.0, 0.75, 0.3)

var save_path := InputActions.FILE
var _buttons := {}            # action -> [key Button, key Button, pad Button]
var _status: Label
var _capture: Array = []      # [action, slot] while waiting for a key
var _pending_mod := KEY_NONE  # a modifier pressed while capturing, bound alone if let go first
var _box: VBoxContainer
var hud: HudSettings          # set by add_hud_settings
var hud_path := HudSettings.FILE
var compass_slider: HSlider
var _compass_value: Label
var debug_check: CheckBox
var cheat_page: CheatPanel    # set by add_cheat_page
var cheats_button: Button
## --test / --cheats: the Cheats page is there this session whatever the debug switch says.
var cheats_forced := false:
	set(v):
		cheats_forced = v
		if cheats_button != null:
			_update_cheats_button()
var _title: Label
var _scroll: ScrollContainer
const KEYS_TITLE := ("Keys: click a slot, then press a key or mouse button (pad column: a pad button or stick).  "
		+ "Esc cancels  Backspace clears  F1 / Esc closes")


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 60
	offset_top = 50
	offset_right = -60
	offset_bottom = -50
	visible = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.1, 0.96)
	bg.set_content_margin_all(12)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	_box = box
	add_child(box)
	var title := Label.new()
	title.text = KEYS_TITLE
	_title = title
	box.add_child(title)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2 + SLOTS
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	var group := ""
	for a: Array in InputActions.ACTIONS:
		if a[1] != group:
			group = a[1]
			for i in grid.columns:
				var h := Label.new()
				h.text = group if i == 0 else ("pad" if i == grid.columns - 1 else "")
				h.add_theme_color_override("font_color", WARN)
				grid.add_child(h)
		var l := Label.new()
		l.text = a[2]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
		var row: Array[Button] = []
		for s in SLOTS + 1:
			var b := Button.new()
			b.custom_minimum_size = Vector2(140, 0)
			b.focus_mode = Control.FOCUS_NONE
			b.pressed.connect(start_capture.bind(a[0], s))
			grid.add_child(b)
			row.append(b)
		_buttons[a[0]] = row
	var bar := HBoxContainer.new()
	box.add_child(bar)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar.add_child(_status)
	cheats_button = Button.new()
	cheats_button.text = "Cheats"
	cheats_button.focus_mode = Control.FOCUS_NONE
	cheats_button.visible = false
	cheats_button.pressed.connect(func() -> void: show_cheats(not showing_cheats()))
	bar.add_child(cheats_button)
	for t: String in ["Reset all", "Close"]:
		var b := Button.new()
		b.text = t
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(reset_all if t == "Reset all" else close)
		bar.add_child(b)


## Adds the HUD row under the title: compass opacity 0..100 %.
func add_hud_settings(settings: HudSettings, path := HudSettings.FILE) -> void:
	hud = settings
	hud_path = path
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = "HUD   compass opacity"
	row.add_child(l)
	compass_slider = HSlider.new()
	compass_slider.min_value = HudSettings.MIN_COMPASS_OPACITY
	compass_slider.max_value = 1.0
	compass_slider.step = 0.05
	compass_slider.custom_minimum_size = Vector2(220, 0)
	compass_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	compass_slider.focus_mode = Control.FOCUS_NONE   # keys stay with the menu
	compass_slider.value = settings.compass_opacity
	compass_slider.value_changed.connect(_on_compass_opacity)
	row.add_child(compass_slider)
	_compass_value = Label.new()
	row.add_child(_compass_value)
	debug_check = CheckBox.new()
	debug_check.text = "Debug: cheats page"
	debug_check.tooltip_text = "Shows the Cheats button here (testing only; off by default)."
	debug_check.focus_mode = Control.FOCUS_NONE
	debug_check.button_pressed = settings.debug_cheats
	debug_check.toggled.connect(_on_debug_cheats)
	row.add_child(debug_check)
	_box.add_child(row)
	_box.move_child(row, 1)
	_show_compass_value()


## Adds the Cheats page (in place of the key list while shown) and its button in the bottom bar.
func add_cheat_page(panel: CheatPanel) -> void:
	cheat_page = panel
	_box.add_child(panel)
	_box.move_child(panel, _scroll.get_index() + 1)
	panel.visible = false
	_update_cheats_button()


func cheats_allowed() -> bool:
	return cheat_page != null and (cheats_forced or (hud != null and hud.debug_cheats))


func showing_cheats() -> bool:
	return cheat_page != null and cheat_page.visible


## Swaps the key list for the Cheats page (on) or back. The page only opens while cheats are allowed.
func show_cheats(on: bool) -> void:
	on = on and cheats_allowed()
	_capture = []
	refresh()
	_scroll.visible = not on
	_title.text = "Cheats (testing).  F1 / Esc closes" if on else KEYS_TITLE
	if cheat_page != null:
		cheat_page.visible = on
		if on:
			cheat_page.refresh()
	if cheats_button != null:
		cheats_button.text = "Keys" if on else "Cheats"


func _update_cheats_button() -> void:
	cheats_button.visible = cheats_allowed()
	if not cheats_allowed() and showing_cheats():
		show_cheats(false)


func _on_debug_cheats(on: bool) -> void:
	hud.debug_cheats = on
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Debug setting not saved: %s" % error_string(err)
	_update_cheats_button()
	hud_changed.emit()


func _on_compass_opacity(v: float) -> void:
	hud.compass_opacity = HudSettings.clamp_opacity(v)
	_show_compass_value()
	var err := hud.save_file(hud_path)
	if err != OK:
		_status.text = "Compass opacity not saved: %s" % error_string(err)
	hud_changed.emit()


func _show_compass_value() -> void:
	_compass_value.text = "%d %%" % roundi(hud.compass_opacity * 100.0)


func open() -> void:
	visible = true
	if compass_slider != null:
		compass_slider.set_value_no_signal(hud.compass_opacity)
		_show_compass_value()
	if debug_check != null:
		debug_check.set_pressed_no_signal(hud.debug_cheats)
	if cheats_button != null:
		_update_cheats_button()
		show_cheats(false)
	_capture = []
	_status.text = "Saved in %s" % ProjectSettings.globalize_path(save_path)
	refresh()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_capture = []
	visible = false
	closed.emit()


func refresh() -> void:
	for a: StringName in _buttons:
		var keys := InputActions.slots(a)
		for s in SLOTS:
			var b: Button = _buttons[a][s]
			b.text = InputActions.event_label(keys[s]) if s < keys.size() else "-"
			if s == SLOTS - 1 and keys.size() > SLOTS:
				b.text += " +%d" % (keys.size() - SLOTS)
		var pads := InputActions.pad_slots(a)
		var p: Button = _buttons[a][PAD_SLOT]
		p.text = InputActions.event_label(pads[0]) if not pads.is_empty() else "-"
		if pads.size() > 1:
			p.text += " +%d" % (pads.size() - 1)


func start_capture(action: StringName, slot: int) -> void:
	if showing_cheats():
		return
	_capture = [action, slot]
	_pending_mod = KEY_NONE
	refresh()
	(_buttons[action][slot] as Button).text = "press a key..." if slot < SLOTS else "press a pad button..."
	_status.text = "Press %s for \"%s\". Esc cancels, Backspace clears." % [
			"a key or mouse button" if slot < SLOTS else "a pad button or push a stick", InputActions.info(action)[2]]


func reset_all() -> void:
	InputActions.reset_all()
	_save("All keys back to the defaults.")


func _input(event: InputEvent) -> void:
	if visible and (event is InputEventKey or (not _capture.is_empty() and (event is InputEventMouseButton
			or InputActions.is_pad(event)))):
		if _typing(event):
			return   # a text field on the cheats page gets its keys
		take(event)
		get_viewport().set_input_as_handled()


## A key for a focused text field on the cheats page (the range's item and monster ids); Esc and F1 still close.
func _typing(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if k == null or not _capture.is_empty() or cheat_page == null or not cheat_page.visible \
			or k.physical_keycode in [KEY_ESCAPE, InputActions.MENU_KEY]:
		return false
	var vp := get_viewport()
	var f: Control = vp.gui_get_focus_owner() if vp != null else null
	return f is LineEdit and cheat_page.is_ancestor_of(f)


## One input event while the menu is open (separate from _input so tests can feed it). True if it was used.
func take(event: InputEvent) -> bool:
	var k := event as InputEventKey
	if _capture.is_empty():
		if k != null and k.pressed and not k.echo and k.physical_keycode in [KEY_ESCAPE, InputActions.MENU_KEY]:
			close()
			return true
		return false
	var pad: bool = _capture[1] >= SLOTS
	if InputActions.is_pad(event):   # pad presses only go in the pad column
		return _bind(InputActions.pad_binding_from(event)) if pad else false
	if k != null and not k.pressed:
		if not pad and _pending_mod != KEY_NONE and k.physical_keycode == _pending_mod:
			return _bind(InputActions.binding_from(k))   # a modifier let go alone: bind it bare
		return false
	if k != null and k.echo:
		return false
	var mb := event as InputEventMouseButton
	if mb != null and not mb.pressed:
		return false
	if k != null:
		match k.physical_keycode:
			KEY_ESCAPE:
				_capture = []
				refresh()
				_status.text = "Cancelled."
				return true
			KEY_BACKSPACE, KEY_DELETE:
				return _set_slot(null)
			InputActions.MENU_KEY:
				_status.text = "F1 opens this menu and can't be bound."
				return true
			KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META:
				if not pad:
					_pending_mod = k.physical_keycode
					return true
	if pad:
		_status.text = "Press a pad button or push a stick or trigger. Esc cancels, Backspace clears."
		return true
	return _bind(InputActions.binding_from(event))


func _bind(e: InputEvent) -> bool:
	if e == null:
		return false
	return _set_slot(e)


## Puts `e` in the slot being captured (null clears it), saves, and names other actions on the same key.
func _set_slot(e: InputEvent) -> bool:
	var action: StringName = _capture[0]
	var slot: int = _capture[1]
	var pad := slot >= SLOTS
	if pad:
		slot -= SLOTS
	_capture = []
	_pending_mod = KEY_NONE
	var keys := InputActions.pad_slots(action) if pad else InputActions.slots(action)
	if e != null:
		for i in range(keys.size() - 1, -1, -1):   # the same key twice in one action: keep one
			if InputActions.event_text(keys[i]) == InputActions.event_text(e):
				keys.remove_at(i)
	if slot < keys.size():
		keys.remove_at(slot)
	if e != null:
		keys.insert(mini(slot, keys.size()), e)
	if pad:
		InputActions.set_pad_slots(action, keys)
	else:
		InputActions.set_slots(action, keys)
	var msg := "%s: %s" % [InputActions.info(action)[2], InputActions.event_label(e) if e != null else "cleared"]
	if e != null:
		var others := PackedStringArray()
		for o in InputActions.users_of(e, action):
			others.append(InputActions.info(o)[2])
		if not others.is_empty():
			msg += ". Also used by: " + ", ".join(others)
	_save(msg)
	return true


func _save(msg: String) -> void:
	var err := InputActions.save_bindings(save_path)
	refresh()
	_status.text = msg if err == "" else "%s. Not saved: %s" % [msg, err]
	_status.add_theme_color_override("font_color", WARN if err != "" or msg.contains("Also used") else Color.WHITE)
