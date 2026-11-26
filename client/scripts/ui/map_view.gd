class_name MapView
extends PanelContainer
## G5 map (lead-ui, 2026-11-26; docs/MAP.md slice 1): the screen map, read-only. M (`map`, CDDA's key) opens it
## over the game; again or Esc closes it. A MapCanvas fills it; under it a line names the cell under the mouse
## (CDDA's name for what the player has seen there, how well, and its note). Drag with the left or middle button to
## move, the wheel to zoom, PgUp / PgDn for the level, Home back to the player, the arrows move a few cells. The
## mouse cursor comes on while it is open and its old mode comes back on close. VR has its own view of the same
## canvas (lead-vr's vr_map.gd).

signal opened
signal closed

const BACK := Color(0.05, 0.06, 0.07, 0.96)
const HEAD := Color(0.95, 0.85, 0.55)
const DIM := Color(0.7, 0.7, 0.7)
const ARROW_CELLS := 4
const HINT := "drag: move   wheel: zoom   PgUp/PgDn: level   Home: you   M / Esc: close"

var data: MapData:
	set(v):
		if data != null and data.changed.is_connected(_on_data):
			data.changed.disconnect(_on_data)
		data = v
		canvas.data = v
		if data != null:
			data.changed.connect(_on_data)
## (set_to: int) -> int: reads (set_to -1) or sets the mouse mode; tests use a stand-in. Unset: Input.mouse_mode.
var mouse_hook := Callable()
## () -> bool: true while something else takes the keys first (main: CDDA's prompt over the map).
var blocked := Callable()
var canvas := MapCanvas.new()

var _title: Label
var _level: Label
var _info: Label
var _prev_mouse: int = Input.MOUSE_MODE_VISIBLE
var _dragging := false
var _hover := Vector2(-1, -1)   # the mouse on the canvas (local px), -1 when not over it


func _init() -> void:
	name = "MapView"
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		set("offset_" + side, 24.0 if side in ["left", "top"] else -24.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = BACK
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(head)
	_title = Label.new()
	_title.text = "Map"
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", HEAD)
	head.add_child(_title)
	_level = Label.new()
	_level.add_theme_color_override("font_color", DIM)
	_level.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	head.add_child(_level)
	var hint := Label.new()
	hint.text = HINT
	hint.add_theme_color_override("font_color", DIM)
	head.add_child(hint)
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.view_moved.connect(_show_info)
	box.add_child(canvas)
	_info = Label.new()
	_info.add_theme_color_override("font_color", DIM)
	_info.max_lines_visible = 1
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_info)


func open() -> void:
	if visible:
		return
	_prev_mouse = _mouse()
	_mouse(Input.MOUSE_MODE_VISIBLE)
	visible = true
	_dragging = false
	_hover = Vector2(-1, -1)
	if data != null:
		data.open()
	canvas.center_on_player()
	canvas.refresh()
	_show_info()
	opened.emit()


func close() -> void:
	if not visible:
		return
	canvas.release()
	visible = false
	_dragging = false
	if data != null:
		data.close()
	_mouse(_prev_mouse)
	closed.emit()


## M opens or closes it (`allowed`: whether it may open now); Esc or ui_cancel closes it; while open, PgUp / PgDn,
## Home and the arrows move the view. True when the event was used.
func handle_key(event: InputEvent, allowed := true) -> bool:
	if InputActions.pressed(event, &"map"):
		if visible:
			close()
			return true
		if allowed:
			open()
			return true
		return false
	if not visible:
		return false
	var k := event as InputEventKey
	var esc := k != null and k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE
	var cancel := event is InputEventAction and event.is_pressed() and (event as InputEventAction).action == &"ui_cancel"
	if esc or cancel:
		close()
		return true
	if InputActions.pressed(event, &"cutaway_up"):
		canvas.change_level(1)
		return true
	if InputActions.pressed(event, &"cutaway_down"):
		canvas.change_level(-1)
		return true
	if InputActions.pressed(event, &"frame_player"):
		canvas.center_on_player()
		return true
	if k != null and k.pressed:
		var step := {KEY_LEFT: Vector2.LEFT, KEY_RIGHT: Vector2.RIGHT, KEY_UP: Vector2.UP, KEY_DOWN: Vector2.DOWN}
		if step.has(k.physical_keycode):
			canvas.pan_px(-(step[k.physical_keycode] as Vector2) * canvas.cell_px * ARROW_CELLS)
			return true
	return false


func _input(event: InputEvent) -> void:
	if visible and not (blocked.is_valid() and blocked.call()) and handle_key(event):
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	var at := _on_canvas(event)
	var b := event as InputEventMouseButton
	if b != null:
		if b.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			_dragging = b.pressed
		elif b.pressed and b.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and at.x >= 0:
			canvas.zoom_at(at, 1 if b.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
		accept_event()
		return
	var m := event as InputEventMouseMotion
	if m != null:
		if _dragging:
			canvas.pan_px(m.relative)
		_hover = at
		_show_info()
		accept_event()


## The event's position on the canvas (local px), (-1, -1) when it isn't over it.
func _on_canvas(event: InputEvent) -> Vector2:
	var me := event as InputEventMouse
	if me == null:
		return Vector2(-1, -1)
	var p := me.global_position - canvas.global_position
	return p if Rect2(Vector2.ZERO, canvas.size).has_point(p) else Vector2(-1, -1)


func _on_data() -> void:
	if visible:
		_show_info()


func _show_info() -> void:
	if not visible:
		return
	_level.text = "   level %d%s" % [canvas.level, "  (you are here)" if data != null and data.has_player
			and data.player_cell.z == canvas.level else ""]
	_info.text = info_text()


## The line under the map: why it is empty, or the cell under the mouse.
func info_text() -> String:
	if data == null:
		return ""
	if data.note == MapData.NO_BRIDGE:
		return data.note
	if _hover.x < 0:
		return data.note if not data.note.is_empty() else ("Reading the map..." if data.reading() else "")
	var c := canvas.cell_at(_hover)
	var where := "(%d, %d)" % [c.x, c.y]
	var i := data.info(c, canvas.level)
	if data.page(MapData.page_origin(Vector3i(c.x, c.y, canvas.level))) == null:
		return "%s  Not read yet." % where
	var parts := PackedStringArray([where])
	if i.has("name"):
		var what: String = i["name"] if not String(i["name"]).is_empty() else "Something"
		parts.append("%s, %s." % [what, MapData.VISION_WORDS[i["vision"]]])
	else:
		parts.append("Not seen.")
	if i.has("note"):
		var n: Dictionary = i["note"]
		parts.append("Note%s: %s" % [" (danger)" if n["danger"] else "", n["text"]])
	if not data.note.is_empty():
		parts.append("(%s)" % data.note)   # a page that couldn't be read
	return "  ".join(parts)


func _mouse(set_to := -1) -> int:
	if mouse_hook.is_valid():
		return mouse_hook.call(set_to)
	if set_to >= 0:
		Input.mouse_mode = set_to as Input.MouseMode
	return Input.mouse_mode
