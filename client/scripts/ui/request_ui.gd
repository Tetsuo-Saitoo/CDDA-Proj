class_name RequestUI
extends Control
## Block E3: the generic renderer for CDDA's UI requests (contracts/ui_requests.md; fields in
## contracts/bridge_api.md). show_request() builds one widget for the request's kind (menu, item_select,
## item_multi, key: ListRequestWidget; popup and "press any key": PopupRequestWidget; string, direction,
## target) and emits `answered` once with an answer Dictionary for LiveSession.answer(). Mouse and keyboard:
## keys reach the widget in _input, before the game's own keys (main.gd's _unhandled_input); keys a widget
## doesn't use fall through (WASD still flies the camera). Native UIs (block G) can later take over kinds.

signal answered(answer: Dictionary)
## Main-loop actions to queue once the answer has gone (e.g. quick reload: reload_weapon, then fire again).
signal queue_after(actions: PackedStringArray)

const PANEL_WIDTH := 580.0
## Kinds shown low on the screen, so the world they point into stays visible.
const LOW_KINDS := ["direction", "target"]

## (right, forward) on screen -> CDDA step (x east, y south); main.gd makes it camera-relative.
var direction_mapper := Callable()
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


## A key or mouse event for the widget; true if used. _input calls it; tests call it directly.
func handle_input(event: InputEvent) -> bool:
	return is_showing() and widget.handle_input(event)


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
	if visible and handle_input(event):
		get_viewport().set_input_as_handled()


func _on_answered(a: Dictionary) -> void:
	clear()
	var then: Variant = a.get("then")
	a.erase("then")
	answered.emit(a)
	if then is PackedStringArray and not (then as PackedStringArray).is_empty():
		queue_after.emit(then)
