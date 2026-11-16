class_name TextKeysDock
extends Control
## L4 / G1: the on-screen keyboard (TextKeys) for whichever text field has the keyboard focus: the main menu's
## world name, the character's name, a list's filter, the cheat page's ids. One dock serves them all; it sits at
## the bottom of its parent (at the top while the field is in the lower part), over everything else there.
## Opening it: a pad's Y while a text field has the focus; with `auto` (the VR panel: no keyboard in the headset)
## also a pointer click on the field, and a small "Keyboard" tab shows while a field has the focus and the keys
## are closed (a field that only took the focus by itself, like a list's filter, doesn't open them). Closing: B /
## ui_cancel, the Hide key, or the focus leaving the field. While open, the pad and the stick work the keys
## (TextKeys.handle_input; accept only once the cursor shows: after a direction, or when the pad opened them);
## Enter goes to the field as a real Enter key.
## Fields that carry their own keys (StringRequestWidget: meta OWN_KEYS) are left to them. The dock is hidden
## whenever it shows nothing, so the VR panel (shown while a child of its root is visible) can hide too.

## Meta on a LineEdit that has its own TextKeys.
const OWN_KEYS := &"text_keys"
const MARGIN := 12.0

## Open on a pointer click in a text field and show the tab (the VR panel).
var auto := false
## The keys are drawn this much larger (the VR panel).
var ui_scale := 1.0
var keys: TextKeys
var panel: PanelContainer
var tab: Button
var hide_button: Button
## The focused text field the keys type into, or null.
var target: LineEdit
var _open := false
var _click_at := Vector2.INF   # a left press since the last frame (viewport coordinates)


func _init() -> void:
	name = "TextKeysDock"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	panel = PanelContainer.new()
	panel.name = "Keys"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.96)
	style.border_color = Color(0.35, 0.35, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	keys = TextKeys.new()
	keys.enter.connect(send_enter)
	box.add_child(keys)
	hide_button = Button.new()
	hide_button.text = "Hide keyboard"
	hide_button.focus_mode = Control.FOCUS_NONE
	hide_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	hide_button.pressed.connect(close)
	box.add_child(hide_button)
	tab = Button.new()
	tab.name = "Tab"
	tab.text = "Keyboard"
	tab.focus_mode = Control.FOCUS_NONE
	tab.pressed.connect(open)
	add_child(tab)
	panel.visible = false
	tab.visible = false


func is_open() -> bool:
	return _open and target != null


## Shows the keys for the focused text field; false when there is none.
func open() -> bool:
	_retarget()
	_open = target != null
	_sync()
	return _open


func close() -> void:
	_open = false
	_sync()


## Enter on the keys: a real Enter key press and release into the viewport (the field submits, a prompt sends).
func send_enter() -> void:
	if not is_inside_tree():
		return
	for down: bool in [true, false]:
		var k := InputEventKey.new()
		k.keycode = KEY_ENTER
		k.physical_keycode = KEY_ENTER
		k.pressed = down
		get_viewport().push_input(k)


func _process(_delta: float) -> void:
	_retarget()
	if auto and target != null and _click_at.is_finite() and target.get_global_rect().has_point(_click_at):
		_open = true
	_click_at = Vector2.INF
	_sync()


func _input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_click_at = mb.position
		return
	if handle_input(event) and is_inside_tree():
		get_viewport().set_input_as_handled()


## A pad button or ui_* action for the dock; true if used. Tests call it directly.
func handle_input(event: InputEvent) -> bool:
	if event == null or not event.is_pressed() or not (event is InputEventAction or event is InputEventJoypadButton):
		return false
	_retarget()
	if target == null:
		return false
	var pad := event as InputEventJoypadButton
	if not _open:
		if pad != null and pad.button_index == JOY_BUTTON_Y:
			if not open():
				return false
			keys.show_cursor()   # opened by the pad: A types from here on
			return true
		return false
	if keys.handle_input(event):
		return true
	if (pad != null and pad.button_index == JOY_BUTTON_B) \
			or (event is InputEventAction and (event as InputEventAction).action == &"ui_cancel"):
		close()
		return true
	return false


## Follows the keyboard focus: an editable, visible LineEdit without its own keys, else none (and closed).
func _retarget() -> void:
	var f: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var le := f as LineEdit
	if le != null and (not le.editable or le.has_meta(OWN_KEYS) or not le.is_visible_in_tree()):
		le = null
	if le != target:
		target = le
		keys.target = le
		if le == null:
			_open = false


func _sync() -> void:
	var show_keys := _open and target != null
	var show_tab := auto and target != null and not _open
	var was := visible
	panel.visible = show_keys
	tab.visible = show_tab
	visible = show_keys or show_tab
	if not visible:
		return
	if not was and get_parent() != null:
		get_parent().move_child(self, -1)   # over everything, and first to get the pad
	var k := clampf(ui_scale, 0.5, 3.0) if is_finite(ui_scale) else 1.0
	var area := size
	if show_keys:
		panel.scale = Vector2(k, k)
		panel.reset_size()
		var sz := panel.get_combined_minimum_size() * k
		var low := target.get_global_rect().get_center().y - global_position.y > area.y * 0.55
		panel.position = Vector2((area.x - sz.x) / 2.0, MARGIN if low else area.y - sz.y - MARGIN)
	if show_tab:
		tab.scale = Vector2(k, k)
		tab.reset_size()
		var ts := tab.get_combined_minimum_size() * k
		tab.position = Vector2((area.x - ts.x) / 2.0, area.y - ts.y - MARGIN)
