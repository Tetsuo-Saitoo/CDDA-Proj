class_name CharacterView
extends PanelContainer
## G4: the character screen (P, `character`; again or Esc closes it). Draws CharacterData's cards (stats, body,
## needs, mood, effects, skills, proficiencies, traits, bionics, speed) as panels that wrap across the screen,
## each row a name and a value in its level's colour, the game's description as the row's tooltip. The same view
## goes on the VR panel (main.gd menus_to_panel), so the headset gets it too. Rebuilt on CharacterData.changed
## only while shown. The mouse cursor comes on while it is open and its old mode comes back on close.

signal opened
signal closed

const CARD_WIDTH := 290.0
const BACK := Color(0.05, 0.06, 0.07, 0.94)
const CARD_BACK := Color(0.11, 0.12, 0.14, 1.0)
const HEAD := Color(0.95, 0.85, 0.55)
const DIM := Color(0.7, 0.7, 0.7)

var data: CharacterData:
	set(v):
		if data != null and data.changed.is_connected(_on_changed):
			data.changed.disconnect(_on_changed)
		data = v
		if data != null:
			data.changed.connect(_on_changed)
		_on_changed()
## (set_to: int) -> int: reads (set_to -1) or sets the mouse mode; tests use a stand-in. Unset: Input.mouse_mode.
var mouse_hook := Callable()

var _title: Label
var _subtitle: Label
var _note: Label
var _hint: Label
var _flow: HFlowContainer
var _prev_mouse: int = Input.MOUSE_MODE_VISIBLE


func _init() -> void:
	name = "CharacterView"
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		set("offset_" + side, 40.0 if side in ["left", "top"] else -40.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = BACK
	sb.set_content_margin_all(14)
	sb.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", HEAD)
	head.add_child(_title)
	_subtitle = Label.new()
	_subtitle.add_theme_color_override("font_color", DIM)
	_subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_subtitle.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	head.add_child(_subtitle)
	_hint = Label.new()
	_hint.add_theme_color_override("font_color", DIM)
	head.add_child(_hint)
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_color_override("font_color", DIM)
	box.add_child(_note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_flow = HFlowContainer.new()
	_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow.add_theme_constant_override("h_separation", 10)
	_flow.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_flow)


func open() -> void:
	if visible:
		return
	_prev_mouse = _mouse()
	_mouse(Input.MOUSE_MODE_VISIBLE)
	visible = true
	rebuild()
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	_mouse(_prev_mouse)
	closed.emit()


## P opens or closes it (`allowed`: whether it may open now); Esc or ui_cancel (the VR panel's B / Y) closes it.
## True when the event was used.
func handle_key(event: InputEvent, allowed := true) -> bool:
	if InputActions.pressed(event, &"character"):
		if visible:
			close()
			return true
		if allowed:
			open()
			return true
		return false
	var k := event as InputEventKey
	var esc := k != null and k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE
	var cancel := event is InputEventAction and event.is_pressed() and (event as InputEventAction).action == &"ui_cancel"
	if visible and (esc or cancel):
		close()
		return true
	return false


func _input(event: InputEvent) -> void:
	if visible and handle_key(event):
		get_viewport().set_input_as_handled()


func _on_changed() -> void:
	if visible:
		rebuild()


func rebuild() -> void:
	for c in _flow.get_children():
		_flow.remove_child(c)
		c.queue_free()
	_hint.text = "%s or Esc: close" % InputActions.key_of(&"character")
	if data == null:
		_title.text = "Character"
		_subtitle.text = ""
		_note.text = ""
		return
	_title.text = data.title
	_subtitle.text = ("   " + data.subtitle) if not data.subtitle.is_empty() else ""
	_note.text = data.note
	_note.visible = not data.note.is_empty()
	for c: Dictionary in data.cards:
		_flow.add_child(_card(c))


## What the cards show: per card a "[title]" line, then a "label: value" line per row (tests, logs).
func text() -> String:
	var out := PackedStringArray()
	for card: Node in _flow.get_children():
		if card.is_queued_for_deletion():
			continue
		var box := card.get_child(0)
		out.append("[%s]" % (box.get_child(0) as Label).text)
		var cells := box.get_child(1).get_children()
		for i in range(0, cells.size() - 1, 2):
			out.append("%s: %s" % [(cells[i] as Label).text, (cells[i + 1] as Label).text])
	return "\n".join(out)


func _card(c: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.name = "Card_" + str(c["id"])
	card.custom_minimum_size.x = CARD_WIDTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BACK
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(4)
	card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	card.add_child(box)
	var head := Label.new()
	head.text = c["title"]
	head.add_theme_color_override("font_color", HEAD)
	box.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	box.add_child(grid)
	for r: Dictionary in c["rows"]:
		var col := HudData.level_color(r["level"]) if r["level"] != HudData.UNKNOWN else Color(0.88, 0.88, 0.88)
		var name_l := _label(r["label"], r["tip"], Color(0.88, 0.88, 0.88))
		name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_l.custom_minimum_size.x = CARD_WIDTH * 0.55
		grid.add_child(name_l)
		var value_l := _label(r["value"], r["tip"], col)
		value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(value_l)
	return card


static func _label(t: String, tip: String, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", col)
	if not tip.is_empty():
		l.tooltip_text = tip
		l.mouse_filter = Control.MOUSE_FILTER_PASS   # Labels ignore the mouse by default: no tooltip without this
	return l


func _mouse(set_to := -1) -> int:
	if mouse_hook.is_valid():
		var m: Variant = mouse_hook.call(set_to)
		return m if m is int else Input.MOUSE_MODE_VISIBLE
	if set_to >= 0:
		Input.mouse_mode = set_to as Input.MouseMode
	return Input.mouse_mode
