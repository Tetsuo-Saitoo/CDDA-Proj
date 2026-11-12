class_name TextKeys
extends VBoxContainer
## An on-screen keyboard for a LineEdit, worked by pointer alone (the VR panel's laser, or a mouse; L4 / G1):
## digits, letters and a few signs, Shift for one capital, Space and Back. Each press types into `target` at its
## caret, replacing a selection; the LineEdit keeps its max_length. The keys take no focus, so the field keeps the
## keyboard (Enter still sends). StringRequestWidget shows it under its field.

const ROWS := ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,.-"]
const KEY_SIZE := Vector2(44, 40)

var target: LineEdit
## The next letter is a capital (one letter, then off again).
var shift := false
var keys: Array[Button] = []   # the ROWS keys, in order
var shift_button: Button
var space_button: Button
var back_button: Button


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
	shift_button.pressed.connect(toggle_shift)
	space_button = _key("Space", last)
	space_button.custom_minimum_size.x = KEY_SIZE.x * 5
	space_button.pressed.connect(type.bind(" "))
	back_button = _key("Back", last)
	back_button.custom_minimum_size.x = KEY_SIZE.x * 2
	back_button.pressed.connect(backspace)


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
	RequestWidget.mark(shift_button, shift)


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
