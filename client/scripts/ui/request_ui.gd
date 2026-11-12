class_name RequestUI
extends Control
## Block E3: the generic renderer for CDDA's UI requests (contracts/ui_requests.md; fields in
## contracts/bridge_api.md). show_request() builds one widget for the request's kind (menu, item_select,
## item_multi, key: ListRequestWidget; popup and "press any key": PopupRequestWidget; string, direction,
## target) and emits `answered` once with an answer Dictionary for LiveSession.answer(). Mouse and keyboard:
## keys reach the widget in _input, before the game's own keys (main.gd's _unhandled_input); keys a widget
## doesn't use fall through (WASD still flies the camera). Native UIs (block G) can later take over kinds.
## A pad's D-pad / A / B / shoulders and ui_* InputEventActions (what the VR panel pushes, L4) count as the arrow keys, Enter
## and Esc (as_key). It lays out to its parent viewport, so it also works inside the VR panel's SubViewport,
## answered by pointer clicks pushed into that viewport.

signal answered(answer: Dictionary)
## Main-loop actions to queue once the answer has gone (e.g. quick reload: reload_weapon, then fire again).
signal queue_after(actions: PackedStringArray)

const PANEL_WIDTH := 580.0
## Kinds shown low on the screen, so the world they point into stays visible.
const LOW_KINDS := ["direction", "target"]
## ui_* actions -> the key each stands for in the widgets (as_key).
const ACTION_KEYS := {
	&"ui_up": KEY_UP, &"ui_down": KEY_DOWN, &"ui_left": KEY_LEFT, &"ui_right": KEY_RIGHT,
	&"ui_page_up": KEY_PAGEUP, &"ui_page_down": KEY_PAGEDOWN, &"ui_accept": KEY_ENTER, &"ui_cancel": KEY_ESCAPE,
}
## A pad's buttons -> keys (as_key): the D-pad, A accepts, B cancels, the shoulders page (as in the F1 menu).
const PAD_KEYS := {
	JOY_BUTTON_DPAD_UP: KEY_UP, JOY_BUTTON_DPAD_DOWN: KEY_DOWN, JOY_BUTTON_DPAD_LEFT: KEY_LEFT,
	JOY_BUTTON_DPAD_RIGHT: KEY_RIGHT, JOY_BUTTON_LEFT_SHOULDER: KEY_PAGEUP, JOY_BUTTON_RIGHT_SHOULDER: KEY_PAGEDOWN,
	JOY_BUTTON_A: KEY_ENTER, JOY_BUTTON_B: KEY_ESCAPE,
}

## (right, forward) on screen -> CDDA step (x east, y south); main.gd makes it camera-relative.
var direction_mapper := Callable()
## Returns [Snapshot, IdTables] now (either may be null); target lists name their creatures with it.
var world_state := Callable()
## () -> bool: another menu has the keys now (the F1 menu: its text fields take typing), so input is left to it.
var held := Callable()
## Text prompts open with the on-screen keyboard showing (TextKeys): set while hosted on the VR panel (main.gd).
var keyboard := false
var widget: RequestWidget
var request_id := 0
var _panel: PanelContainer
var _bottom: Control


func _init() -> void:
	name = "RequestUI"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)
	var top := Control.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(top)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size.x = PANEL_WIDTH
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.93)
	style.border_color = Color(0.35, 0.35, 0.4)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(14)
	_panel.add_theme_stylebox_override("panel", style)
	column.add_child(_panel)
	_bottom = Control.new()
	_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_bottom)


## Shows `req` (a request Dictionary from the bridge); false if it has no usable id or kind. Replaces any
## request still showing.
func show_request(req: Dictionary) -> bool:
	clear()
	var id: Variant = RequestWidget.id_value(req.get("id"))
	var kind: Variant = req.get("kind")
	if id == null or id <= 0 or not kind is String:
		return false
	request_id = id
	widget = make_widget(kind, req)
	widget.direction_mapper = direction_mapper
	if widget is TargetRequestWidget:
		(widget as TargetRequestWidget).world_state = world_state
	if widget is StringRequestWidget:
		(widget as StringRequestWidget).show_keys = keyboard
	widget.answered.connect(_on_answered)
	_panel.add_child(widget)
	widget.setup(req)
	_panel.custom_minimum_size.x = maxf(PANEL_WIDTH, widget.custom_minimum_size.x)
	var low: bool = kind in LOW_KINDS
	_bottom.size_flags_vertical = Control.SIZE_FILL if low else Control.SIZE_EXPAND_FILL
	_bottom.custom_minimum_size.y = 40.0 if low else 0.0
	visible = true
	return true


static func make_widget(kind: String, req: Dictionary) -> RequestWidget:
	match kind:
		"menu", "item_select", "item_multi":
			return ListRequestWidget.new()
		"key":
			return PopupRequestWidget.new() if RequestWidget.actions_of(req).is_empty() else ListRequestWidget.new()
		"string":
			return StringRequestWidget.new()
		"direction":
			return DirectionRequestWidget.new()
		"target":
			return TargetRequestWidget.new()
		"chargen":
			return ChargenRequestWidget.new()
		"world_setup":
			return WorldSetupRequestWidget.new()
	return PopupRequestWidget.new()   # popup; unknown kinds get their text and Cancel


## Hides the request; its widget answers nothing more.
func clear() -> void:
	if widget != null:
		widget.done = true
		widget.hide()
		widget.queue_free()
		widget = null
	request_id = 0
	visible = false


func is_showing() -> bool:
	return widget != null and not widget.done


## A key or mouse event for the widget (a pad button or ui_* action as its key, as_key); true if used. _input
## calls it; tests call it directly.
func handle_input(event: InputEvent) -> bool:
	return is_showing() and event != null and widget.handle_input(as_key(event))


## `event` as the widgets read it: a pressed ui_* InputEventAction (ACTION_KEYS) or pad button (PAD_KEYS)
## becomes that key (no echo, no modifiers); keys, the mouse, stick motion (it repeats while held), other
## actions and buttons, and releases stay as they are.
static func as_key(event: InputEvent) -> InputEvent:
	var code: int = KEY_NONE
	if event is InputEventAction and event.is_pressed():
		code = ACTION_KEYS.get((event as InputEventAction).action, KEY_NONE)
	elif event is InputEventJoypadButton and event.is_pressed():
		code = PAD_KEYS.get((event as InputEventJoypadButton).button_index, KEY_NONE)
	if code == KEY_NONE:
		return event
	var k := InputEventKey.new()
	k.keycode = code as Key
	k.physical_keycode = code as Key
	k.pressed = true
	return k


## True while a text field has the keyboard (main.gd then stops the fly camera's WASD).
func wants_text_input() -> bool:
	return visible and is_inside_tree() and get_viewport().gui_get_focus_owner() is LineEdit


## Moves a target request's cursor (e.g. a square picked in the 3D view); false if none is showing.
func set_target_cursor(pos: Vector3i) -> bool:
	var t := widget as TargetRequestWidget
	if t == null or t.done:
		return false
	t.set_cursor(pos)
	return true


## The showing target request's widget, or null.
func target_widget() -> TargetRequestWidget:
	var t := widget as TargetRequestWidget
	return t if t != null and not t.done else null


func _input(event: InputEvent) -> void:
	if visible and not is_held() and handle_input(event) and get_viewport() != null:
		get_viewport().set_input_as_handled()


## True while `held` says another menu has the keys.
func is_held() -> bool:
	return held.is_valid() and held.call() == true


func _on_answered(a: Dictionary) -> void:
	clear()
	var then: Variant = a.get("then")
	a.erase("then")
	answered.emit(a)
	if then is PackedStringArray and not (then as PackedStringArray).is_empty():
		queue_after.emit(then)
