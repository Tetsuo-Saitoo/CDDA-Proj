class_name RequestUI
extends Control
## Block E3: the generic renderer for CDDA's UI requests (contracts/ui_requests.md; fields in
## contracts/bridge_api.md). show_request() builds one widget for the request's kind (menu, item_select,
## item_multi, key: ListRequestWidget; popup and "press any key": PopupRequestWidget; string, number, direction,
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
const FIT_MARGIN := 48.0   # px kept clear above and below the panel's text when it has to scroll (and its border)
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
## How much larger everything is drawn (set_ui_scale); 1 = as on the screen.
var ui_scale := 1.0
var widget: RequestWidget
var request_id := 0
## Radial menus: until this time (Time.get_ticks_msec), the next request shows as a wheel if it can be one
## (RadialRequestWidget.fits); main sets it when E asks CDDA about an object (want_wheel). Any request ends it.
var wheel_until := -1
var wheel_hold := false
## Whether the button that asked for the wheel is still down (want_wheel's `down`: VR's trigger, which isn't an
## InputMap action); not valid: E's action (`use_held`). Anything but true counts as let go.
var wheel_down := Callable()
var wheel_pressed := -1   # when E went down (want_wheel): letting go within TAP_MS is a tap
var _panel: PanelContainer
## Holds the widget in the panel: a prompt taller than the window (character creation on a small one) scrolls
## (_fit_panel).
var _fit_box: ScrollContainer
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
	_fit_box = ScrollContainer.new()
	_fit_box.name = "FitBox"
	_fit_box.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_fit_box.follow_focus = true
	_panel.add_child(_fit_box)
	resized.connect(_fit_panel)
	_bottom = Control.new()
	_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_bottom)


## Draws everything `k` times larger (0.5..3; bad values: 1) while still filling the parent Control: the VR panel,
## where CDDA's 16 px text wants to be 20 px or more to read in the headset. Follows the parent's size.
func set_ui_scale(k: float) -> void:
	ui_scale = clampf(k, 0.5, 3.0) if is_finite(k) else 1.0
	var p := get_parent() as Control
	if p != null and not p.resized.is_connected(_fit):
		p.resized.connect(_fit)
	_fit()


func _fit() -> void:
	if is_equal_approx(ui_scale, 1.0):
		scale = Vector2.ONE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return
	var p := get_parent() as Control
	var area := p.size if p != null else get_parent_area_size()
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	scale = Vector2(ui_scale, ui_scale)
	position = Vector2.ZERO
	size = area / ui_scale


## Shows `req` (a request Dictionary from the bridge); false if it has no usable id or kind. Replaces any
## request still showing.
func show_request(req: Dictionary) -> bool:
	clear()
	var id: Variant = RequestWidget.id_value(req.get("id"))
	var kind: Variant = req.get("kind")
	if id == null or id <= 0 or not kind is String:
		return false
	request_id = id
	var wheel := wheel_until >= 0 and Time.get_ticks_msec() <= wheel_until and RadialRequestWidget.fits(req)
	wheel_until = -1
	var down := wheel_down
	wheel_down = Callable()   # this request's only: never a later one's
	if wheel:
		var r := RadialRequestWidget.new()
		# E already let go (a quick tap): its release won't come, so the wheel waits for a click
		var v: Variant = down.call() if down.is_valid() else null
		var held: bool = v is bool and v if down.is_valid() \
				else InputMap.has_action(r.release_action) and Input.is_action_pressed(r.release_action)
		r.hold = wheel_hold and held
		r.tap_until = wheel_pressed + RadialRequestWidget.TAP_MS if wheel_hold else -1
		widget = r
	else:
		widget = make_widget(kind, req)
	widget.direction_mapper = direction_mapper
	if widget is TargetRequestWidget:
		(widget as TargetRequestWidget).world_state = world_state
	if widget is StringRequestWidget:
		(widget as StringRequestWidget).show_keys = keyboard
	widget.answered.connect(_on_answered)
	_fit_box.add_child(widget)
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	widget.setup(req)
	widget.minimum_size_changed.connect(_fit_panel)
	_panel.custom_minimum_size.x = maxf(PANEL_WIDTH, widget.custom_minimum_size.x)
	var low: bool = kind in LOW_KINDS
	_bottom.size_flags_vertical = Control.SIZE_FILL if low else Control.SIZE_EXPAND_FILL
	_bottom.custom_minimum_size.y = 40.0 if low else 0.0
	_fit_panel()
	visible = true
	var rw := widget as RadialRequestWidget
	if rw != null and not rw.hold and Time.get_ticks_msec() <= rw.tap_until:
		rw.pick(rw.default_slot)   # E tapped and let go before the menu came: CDDA's default, no wheel to see
	return true


## The widget takes its own height, but at most the window's less FIT_MARGIN (and the bottom gap): taller, it
## scrolls.
func _fit_panel() -> void:
	if widget == null or not is_instance_valid(widget):
		return
	var cap := size.y - FIT_MARGIN - _bottom.custom_minimum_size.y
	if size.y > 0.0:
		widget.fit_height(maxf(cap, 80.0))   # its list or long text gets shorter first
	var want := widget.get_combined_minimum_size().y
	_fit_box.custom_minimum_size.y = minf(want, maxf(cap, 80.0)) if size.y > 0.0 else want


static func make_widget(kind: String, req: Dictionary) -> RequestWidget:
	match kind:
		"menu", "item_select", "item_multi":
			return ListRequestWidget.new()
		"key":
			return PopupRequestWidget.new() if RequestWidget.actions_of(req).is_empty() else ListRequestWidget.new()
		"string":
			return StringRequestWidget.new()
		"number":
			return NumberRequestWidget.new()
		"direction":
			return DirectionRequestWidget.new()
		"target":
			return TargetRequestWidget.new()
		"chargen":
			return ChargenRequestWidget.new()
		"world_setup":
			return WorldSetupRequestWidget.new()
	return PopupRequestWidget.new()   # popup; unknown kinds get their text and Cancel


## The next request within `wait_ms` shows as a wheel if it can be one; `hold`: letting go of E picks. `down`: () -> bool,
## whether the button that asked is still down (VR's trigger); not given: E's action.
func want_wheel(wait_ms: int, hold: bool, down := Callable()) -> void:
	wheel_pressed = Time.get_ticks_msec()
	wheel_until = wheel_pressed + clampi(wait_ms, 0, 10000)
	wheel_hold = hold
	wheel_down = down


## A wheel was asked for (want_wheel) and its time to come hasn't run out (Esc / Start cancels it: BackOut).
func wheel_waiting() -> bool:
	return wheel_until >= 0 and Time.get_ticks_msec() <= wheel_until


## The wheel asked for (want_wheel) is only for the request E itself causes: any other key, mouse or pad button
## pressed before that request comes (main: every event) cancels it, so a menu that key caused shows as usual and a
## quick tap of E never answers it unseen. Not cancelling: E (`use_held`) itself, releases, modifiers alone, the
## mouse wheel, motion.
func note_input(event: InputEvent) -> void:
	if wheel_until < 0 or not event.is_pressed() or event.is_echo() or InputActions.pressed(event, &"use_held"):
		return
	var k := event as InputEventKey
	var mods := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]
	if k != null and (k.keycode in mods or k.physical_keycode in mods):
		return
	var m := event as InputEventMouseButton
	if m != null and m.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT,
			MOUSE_BUTTON_WHEEL_RIGHT]:
		return
	if k != null or m != null or event is InputEventJoypadButton:
		cancel_wheel()


## No wheel for the next request (want_wheel undone).
func cancel_wheel() -> void:
	wheel_until = -1
	wheel_down = Callable()


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
	return is_showing() and event != null and (widget.handle_raw(event) or widget.handle_input(as_key(event)))


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
