class_name TextKeys
extends VBoxContainer
## An on-screen keyboard for a LineEdit (L4 / G1), worked by pointer (the VR panel's laser, or a mouse) or by a
## pad / the VR stick: digits, letters and a few signs, Shift for one capital, Space, Back and Enter. Each press
## types into `target` at its caret, replacing a selection; the LineEdit keeps its max_length. The keys take no
## focus, so the field keeps the keyboard (a real Enter still sends).
## Pad and stick (handle_input): the D-pad or ui_up / down / left / right move a cursor over the keys, A or
## ui_accept presses the key under it, X is Back, Y is Shift. Real keys are never taken: they type as usual.
## Until the cursor shows (a direction pressed, or show_cursor: the keys were opened by the pad), accept is left
## alone too, so it still does what it did without the keys (sends a prompt).
## StringRequestWidget shows it under its field; TextKeysDock brings it to any other text field.

## The Enter key was pressed (the owner sends or submits).
signal enter()

const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"]
const KEY_SIZE := Vector2(44, 40)
## Pad buttons -> what they do here (the ui_* names are also what InputEventActions carry).
const PAD := {
	JOY_BUTTON_DPAD_UP: &"ui_up", JOY_BUTTON_DPAD_DOWN: &"ui_down", JOY_BUTTON_DPAD_LEFT: &"ui_left",
	JOY_BUTTON_DPAD_RIGHT: &"ui_right", JOY_BUTTON_A: &"ui_accept", JOY_BUTTON_X: &"back", JOY_BUTTON_Y: &"shift",
}

var target: LineEdit
## The next letter is a capital (one letter, then off again).
var shift := false
var keys: Array[Button] = []   # the ROWS keys, in order
var shift_button: Button
var space_button: Button
var back_button: Button
var enter_button: Button
## The pad's key: (column, row) in grid(); shown once a pad or stick has moved or pressed it (cursor_on).
var cursor := Vector2i.ZERO
var cursor_on := false


func _init() -> void:
	name = "TextKeys"
	add_theme_constant_override("separation", 4)
	for row: String in ROWS:
		var line := _line()
		for i in row.length():
			var b := _key(row[i], line)
			b.pressed.connect(_typed.bind(b))
			keys.append(b)
	var last := _line()
	shift_button = _key("Shift", last)
	shift_button.custom_minimum_size.x = KEY_SIZE.x * 2
	shift_button.toggle_mode = true
	shift_button.pressed.connect(toggle_shift)
	space_button = _key("Space", last)
	space_button.custom_minimum_size.x = KEY_SIZE.x * 4
	space_button.pressed.connect(type.bind(" "))
	back_button = _key("Back", last)
	back_button.custom_minimum_size.x = KEY_SIZE.x * 2
	back_button.pressed.connect(backspace)
	enter_button = _key("Enter", last)
	enter_button.custom_minimum_size.x = KEY_SIZE.x * 2
	enter_button.pressed.connect(func() -> void: enter.emit())


## Types `s` at the target's caret (over its selection, if any). A letter typed with Shift on turns Shift off.
func type(s: String) -> void:
	if not _ready_target() or s.is_empty():
		return
	_cut_selection()
	target.insert_text_at_caret(s)
	if shift and s.to_lower() != s.to_upper():
		toggle_shift()


## Deletes the selection, else the character before the caret.
func backspace() -> void:
	if not _ready_target() or _cut_selection():
		return
	var c := target.caret_column
	if c > 0:
		target.delete_text(c - 1, c)
		target.caret_column = c - 1


func toggle_shift() -> void:
	shift = not shift
	for b in keys:
		b.text = b.text.to_upper() if shift else b.text.to_lower()
	shift_button.set_pressed_no_signal(shift)


## The keys as rows, top to bottom: the ROWS rows, then Shift, Space, Back, Enter.
func grid() -> Array:
	var out: Array = []
	var i := 0
	for row: String in ROWS:
		out.append(keys.slice(i, i + row.length()))
		i += row.length()
	out.append([shift_button, space_button, back_button, enter_button])
	return out


## The key under the pad's cursor.
func cursor_key() -> Button:
	var g := grid()
	var row: Array = g[clampi(cursor.y, 0, g.size() - 1)]
	return row[clampi(cursor.x, 0, row.size() - 1)]


## Shows the pad's cursor where it is (the keys were opened by the pad: its accept types from now on).
func show_cursor() -> void:
	move_cursor(Vector2i.ZERO)


## Moves the pad's cursor by `d` (one step along x or y), wrapping; between rows of different lengths it keeps
## its place across the keyboard.
func move_cursor(d: Vector2i) -> void:
	var g := grid()
	RequestWidget.mark(cursor_key(), false)
	if cursor_on:   # the first press only shows where it is
		var from: Array = g[cursor.y]
		if d.y != 0:
			var y := wrapi(cursor.y + signi(d.y), 0, g.size())
			var to: Array = g[y]
			cursor = Vector2i(clampi(int((cursor.x + 0.5) / from.size() * to.size()), 0, to.size() - 1), y)
		elif d.x != 0:
			cursor.x = wrapi(cursor.x + signi(d.x), 0, from.size())
	cursor_on = true
	RequestWidget.mark(cursor_key(), true)


## A pad button or a ui_* InputEventAction for the keyboard (see the top); true if used. Keys and the mouse are
## left alone.
func handle_input(event: InputEvent) -> bool:
	if event == null or not event.is_pressed():
		return false
	var act := &""
	if event is InputEventAction:
		act = (event as InputEventAction).action
	elif event is InputEventJoypadButton:
		act = PAD.get((event as InputEventJoypadButton).button_index, &"")
	match act:
		&"ui_up":
			move_cursor(Vector2i(0, -1))
		&"ui_down":
			move_cursor(Vector2i(0, 1))
		&"ui_left":
			move_cursor(Vector2i(-1, 0))
		&"ui_right":
			move_cursor(Vector2i(1, 0))
		&"ui_accept":
			if not cursor_on:
				return false   # the keys haven't been used by pad or stick: accept stays the owner's
			cursor_key().pressed.emit()
		&"back":
			if not (event is InputEventJoypadButton):
				return false
			backspace()
		&"shift":
			if not (event is InputEventJoypadButton):
				return false
			toggle_shift()
		_:
			return false
	return true


func _typed(b: Button) -> void:
	type(b.text)


## True and gone when the target had a selection.
func _cut_selection() -> bool:
	if not target.has_selection():
		return false
	var from := target.get_selection_from_column()
	var to := target.get_selection_to_column()
	target.deselect()
	target.delete_text(from, to)
	target.caret_column = from
	return true


func _ready_target() -> bool:
	return target != null and is_instance_valid(target) and target.editable


func _line() -> HBoxContainer:
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.add_theme_constant_override("separation", 4)
	add_child(line)
	return line


func _key(label: String, parent: Control) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = KEY_SIZE
	b.add_theme_font_size_override("font_size", 18)
	parent.add_child(b)
	return b
