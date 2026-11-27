class_name MapNoteDialog
extends PanelContainer
## G5 map slice 2 (lead-ui, 2026-11-26; docs/MAP.md): the flat note dialog over the screen map (MapView puts it on
## its canvas). It writes, edits or deletes CDDA's note on one cell through MapData (set_note / delete_note) and waits
## for CDDA's answer: done closes it, refused shows CDDA's sentence and keeps it open. VR's wheel uses the same MapData
## calls (lead-vr). Note text is shown and edited as plain text only.

signal closed

const BACK := Color(0.09, 0.1, 0.11, 0.98)
const EDGE := Color(0.4, 0.4, 0.4)
const SAY := Color(0.75, 0.75, 0.75)
const SAY_BAD := Color(1.0, 0.55, 0.45)
const WAITING := "Waiting for the game..."

var data: MapData:
	set(v):
		if data != null and data.note_done.is_connected(_on_done):
			data.note_done.disconnect(_on_done)
		data = v
		if data != null:
			data.note_done.connect(_on_done)
## The cell being noted (absolute OMT, z the level).
var cell := Vector3i.ZERO

var _title: Label
var _text: LineEdit
var _symbol: OptionButton
var _color: OptionButton
var _danger: CheckBox
var _radius: SpinBox
var _say: Label
var _save: Button
var _delete: Button
var _tag := 0   # the write out from here (0 none)


func _init() -> void:
	name = "MapNoteDialog"
	visible = false
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(460, 0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = BACK
	sb.border_color = EDGE
	sb.set_border_width_all(1)
	sb.set_content_margin_all(12)
	sb.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	box.add_child(_title)
	_text = LineEdit.new()
	_text.max_length = MapData.MAX_NOTE_TEXT
	_text.placeholder_text = "What is here"
	_text.text_submitted.connect(func(_t: String) -> void: save())
	box.add_child(_text)
	var look := HBoxContainer.new()
	box.add_child(look)
	look.add_child(_label("Symbol"))
	_symbol = OptionButton.new()
	for ch in MapData.NOTE_SYMBOLS:
		_symbol.add_item(ch)
	look.add_child(_symbol)
	look.add_child(_label("  Colour"))
	_color = OptionButton.new()
	for c: Array in MapData.NOTE_COLORS:
		_color.add_item(c[1])
	look.add_child(_color)
	var risk := HBoxContainer.new()
	box.add_child(risk)
	_danger = CheckBox.new()
	_danger.text = "Dangerous"
	risk.add_child(_danger)
	risk.add_child(_label("  radius (cells)"))
	_radius = SpinBox.new()
	_radius.min_value = 0
	_radius.max_value = MapData.MAX_DANGER_RADIUS
	_radius.rounded = true
	risk.add_child(_radius)
	_danger.toggled.connect(func(on: bool) -> void: _radius.editable = on)
	_say = Label.new()
	_say.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_say)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(buttons)
	_delete = _button("Delete note", remove, buttons)
	_button("Cancel", close, buttons)
	_save = _button("Save", save, buttons)


## Opens on `c` with its note, if it has one, filled in; `deleting`: asks whether to delete it, the Delete button
## focused.
func open_on(c: Vector3i, deleting := false) -> void:
	cell = c
	_tag = 0
	var n: Dictionary = {}
	if data != null:
		n = data.info(Vector2i(c.x, c.y), c.z).get("note", {})
	var had := not n.is_empty()
	_title.text = "%s at (%d, %d), level %d" % ["Note" if had else "New note", c.x, c.y, c.z]
	_text.text = n.get("text", "")
	_pick_symbol(n.get("symbol", "N"))
	_color.select(maxi(0, MapData.note_color_index(MapData.note_color_code(n.get("color", Color.BLACK)))) if had
			else 0)
	_danger.button_pressed = had and n.get("danger") == true
	_radius.value = int(n.get("radius", 0))
	_radius.editable = _danger.button_pressed
	_delete.visible = had
	_busy(false)
	_tell("Delete this note?" if deleting and had else "", false)
	visible = true
	if deleting and had:
		_delete.grab_focus()
	else:
		_text.grab_focus()
		_text.caret_column = _text.text.length()


func save() -> void:
	if _tag > 0 or data == null:
		return
	if MapData.clean_note(_text.text).is_empty():
		_tell("Write something for the note.", true)
		return
	_tag = data.set_note(cell, _text.text, _symbol.get_item_text(_symbol.selected),
			MapData.NOTE_COLORS[maxi(0, _color.selected)][0], _danger.button_pressed, int(_radius.value))
	_after_send()


func remove() -> void:
	if _tag > 0 or data == null:
		return
	_tag = data.delete_note(cell)
	_after_send()


## Closes it; a write still out lands all the same, its answer just isn't shown.
func close() -> void:
	if not visible:
		return
	visible = false
	_tag = 0
	closed.emit()


## The line under the buttons: what the game said, or why nothing went out.
func said() -> String:
	return _say.text


func _after_send() -> void:
	if _tag > 0:
		_busy(true)
		_tell(WAITING, false)
		return
	if data.live == null or not data.live.can_map_notes():
		_tell("Notes aren't connected to the game yet.", true)
	elif data.writing():
		_tell("Another note is still on its way to the game.", true)
	else:
		_tell("That note can't be sent.", true)


func _on_done(tag: int, ok: bool, text: String) -> void:
	if _tag == 0 or tag != _tag:
		return
	_tag = 0
	_busy(false)
	if ok:
		close()
	else:
		_tell(text, true)


func _pick_symbol(s: String) -> void:
	while _symbol.item_count > MapData.NOTE_SYMBOLS.length():   # the last note's own glyph goes
		_symbol.remove_item(_symbol.item_count - 1)
	if not MapData.ok_symbol(s):
		s = "N"
	for i in _symbol.item_count:
		if _symbol.get_item_text(i) == s:
			_symbol.select(i)
			return
	_symbol.add_item(s)   # a glyph the note already has, kept
	_symbol.select(_symbol.item_count - 1)


func _busy(on: bool) -> void:
	_save.disabled = on
	_delete.disabled = on
	_text.editable = not on


func _tell(s: String, bad: bool) -> void:
	_say.text = s
	_say.add_theme_color_override("font_color", SAY_BAD if bad else SAY)


func _label(s: String) -> Label:
	var l := Label.new()
	l.text = s
	return l


func _button(s: String, call: Callable, into: Container) -> Button:
	var b := Button.new()
	b.text = s
	b.pressed.connect(call)
	into.add_child(b)
	return b
