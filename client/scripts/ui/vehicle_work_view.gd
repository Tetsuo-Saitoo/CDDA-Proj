class_name VehicleWorkView
extends PanelContainer
## C6 vehicle work, flat screen (lead-ui, 2026-11-22): the work view beside a car (Shift+V, `vehicle_work`; again or
## Esc closes it). The car's parts as a list (by square, CDDA's names and condition), and for the selected part
## CDDA's commands, greyed with CDDA's reason when they can't be done, and CDDA's requirement lines (met green,
## not met red). Keys: Up/Down the part, CDDA's own i r o m f the command, 1 2 3 the camera (around, hood, under).
## It only shows: the read (VehicleWorkData) comes from main, choices go out as signals; CDDA decides everything.
## Docked on the right so the car stays in view on the left; fits 800x450.

signal opened
signal closed
## The player moved to another part (a row of the snapshot's vehicles[].parts).
signal part_selected(row: int)
## A command the read says can be done now, on part `row`.
signal command_chosen(cmd: String, row: int)
## The camera the player asked for: "around", "hood" or "under".
signal view_chosen(view: String)

const BACK := Color(0.05, 0.06, 0.07, 0.94)
const HEAD := Color(0.95, 0.85, 0.55)
const DIM := Color(0.7, 0.7, 0.7)
const GOOD := Color(0.55, 0.9, 0.55)
const WARN := Color(0.95, 0.8, 0.4)
const BAD := Color(0.95, 0.45, 0.4)
const ROW_H := 28.0
const MAX_W := 520.0
const MIN_W := 300.0
const KEYS := ["i", "r", "o", "m", "f"]   # the order of the command buttons
const VIEWS := {KEY_1: "around", KEY_2: "hood", KEY_3: "under"}

## The vehicle the view is open on (its snapshot uid); 0 when closed.
var uid := 0
## The part row selected, -1 none.
var selected := -1
## The last read shown (VehicleWorkData.clean's Dictionary).
var result := {}
## Whether a read is on its way (the note says so).
var waiting := false
## () -> bool: true while something else (a CDDA prompt) has the keys. Unset: never.
var blocked := Callable()
## (set_to: int) -> int: reads (-1) or sets the mouse mode; tests use a stand-in. Unset: Input.mouse_mode.
var mouse_hook := Callable()

var _title: Label
var _note: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _part_title: Label
var _cmd_box: HBoxContainer
var _buttons := {}      # cmd -> Button
var _why: Label
var _lines: VBoxContainer
var _hint: Label
var _order: Array[int] = []   # rows in list order
var _row_buttons := {}         # row -> Button
var _flash := ""
var _prev_mouse: int = Input.MOUSE_MODE_VISIBLE


func _init() -> void:
	name = "VehicleWorkView"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BACK
	sb.set_content_margin_all(10)
	sb.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	add_child(box)
	_title = _label("", HEAD, 20)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_title)
	_note = _label("", DIM)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_note)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_stretch_ratio = 1.0
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)
	box.add_child(HSeparator.new())
	_part_title = _label("", HEAD)
	_part_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_part_title)
	_cmd_box = HBoxContainer.new()
	box.add_child(_cmd_box)
	for k: String in KEYS:
		var b := Button.new()
		b.text = "%s %s" % [k, VehicleWorkData.COMMAND_NAMES[k]]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(choose.bind(k))
		_cmd_box.add_child(b)
		_buttons[k] = b
	_why = _label("", WARN)
	_why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_why)
	var lines_scroll := ScrollContainer.new()
	lines_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lines_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(lines_scroll)
	_lines = VBoxContainer.new()
	_lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines_scroll.add_child(_lines)
	_hint = _label("Up/Down: part   1 around  2 hood  3 under   Esc: close", DIM, 12)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_hint)


## Opens on vehicle `vehicle_uid` (named `veh_name` until the read comes) and waits for its read.
func open(vehicle_uid: int, veh_name := "") -> void:
	if not visible:
		_prev_mouse = _mouse()
		_mouse(Input.MOUSE_MODE_VISIBLE)
	uid = vehicle_uid
	selected = -1
	result = {}
	waiting = true
	_flash = ""
	_title.text = veh_name if not veh_name.is_empty() else "Vehicle"
	visible = true
	fit()
	_build_list()
	_show_part()
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	uid = 0
	result = {}
	_mouse(_prev_mouse)
	closed.emit()


## Size and place for the window: docked right, at most MAX_W wide and 45% of the window, full height less a margin.
func fit() -> void:
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	var w := clampf(vp.x * 0.45, MIN_W, MAX_W)
	offset_left = -w - 8.0
	offset_right = -8.0
	offset_top = 8.0
	offset_bottom = -8.0


## A read for this vehicle came (VehicleWorkData.clean's Dictionary): shown. One for another vehicle is ignored.
## False when it was ignored or it closes the view (the vehicle went or is out of reach: `ok` false with that
## error; main says why).
func set_result(r: Dictionary) -> bool:
	if not visible or r.get("vehicle") != uid:
		return false
	waiting = false
	if r.get("ok") != true:
		var e: String = r.get("error", "internal")
		if e in ["no such vehicle", "too far"]:
			close()
			return false
		_flash = "The game couldn't answer (%s)." % e
		_show_part()
		return true
	var old: Array = result.get("parts", [])
	result = r
	if not (r["name"] as String).is_empty():
		_title.text = r["name"]
	if old != r["parts"]:
		_build_list()
	if selected < 0 and not _order.is_empty():
		select(_order[0])
	elif selected >= 0 and VehicleWorkData.part_of(r, selected).is_empty():
		select(_order[0] if not _order.is_empty() else -1)
	_show_part()
	return true


## Selects part `row` (it must be listed; -1 none) and says so (part_selected), so main asks for its commands.
func select(row: int) -> void:
	if row == selected or (row >= 0 and not _row_buttons.has(row)):
		return
	selected = row
	_flash = ""
	waiting = row >= 0
	for r: int in _row_buttons:
		(_row_buttons[r] as Button).button_pressed = r == row
	if row >= 0:
		_scroll.ensure_control_visible(_row_buttons[row])
	_show_part()
	part_selected.emit(row)


## Moves the selection `delta` rows down the list (wraps).
func move(delta: int) -> void:
	if _order.is_empty():
		return
	var i := _order.find(selected)
	select(_order[posmod((i if i >= 0 else 0) + (delta if i >= 0 else 0), _order.size())])


## Command `cmd` on the selected part: chosen when the read for that part says it can be done now, else its
## reason is shown. True when chosen.
func choose(cmd: String) -> bool:
	if selected < 0:
		return false
	if cmd == "i":
		_flash = "Installing comes in a later step."
		_show_part()
		return false
	var c := _command(cmd)
	if c.is_empty() or not c["ok"]:
		_flash = VehicleWorkData.refusal(c) if not waiting else "Still asking the game."
		_show_part()
		return false
	command_chosen.emit(cmd, selected)
	return true


## The command `cmd` for the selected part from the last read, {} when the read isn't for that part.
func _command(cmd: String) -> Dictionary:
	var sel: Dictionary = result.get("selected", {})
	if sel.get("row", -1) != selected:
		return {}
	return VehicleWorkData.command_of(result, cmd)


## Keys while open (`vehicle_work` or Esc closes; blocked while a CDDA prompt has them). True when used.
func handle_key(event: InputEvent) -> bool:
	if not visible or (blocked.is_valid() and blocked.call() == true):
		return false
	if InputActions.pressed(event, &"vehicle_work"):
		close()
		return true
	var cancel := event is InputEventAction and event.is_pressed() and (event as InputEventAction).action == &"ui_cancel"
	var k := event as InputEventKey
	if cancel:
		close()
		return true
	if k == null or not k.pressed:
		return false
	match k.physical_keycode:
		KEY_ESCAPE:
			if not k.echo:
				close()
			return true
		KEY_UP:
			move(-1)
			return true
		KEY_DOWN:
			move(1)
			return true
		KEY_I, KEY_R, KEY_O, KEY_M, KEY_F:
			if not k.echo and not k.shift_pressed and not k.ctrl_pressed and not k.alt_pressed:
				choose(OS.get_keycode_string(k.physical_keycode).to_lower())
			return true
	if VIEWS.has(k.physical_keycode):
		if not k.echo:
			view_chosen.emit(VIEWS[k.physical_keycode])
		return true
	return false


func _input(event: InputEvent) -> void:
	if handle_key(event):
		get_viewport().set_input_as_handled()


## The list text of the view (tests): one line a row, "> " before the selected one.
func list_text() -> String:
	var out := PackedStringArray()
	for r in _order:
		out.append(("> " if r == selected else "  ") + (_row_buttons[r] as Button).text)
	return "\n".join(out)


## What the lower half says (tests): the part title, each command "key:on/off", the reason, the lines.
func detail_text() -> String:
	var cmds := PackedStringArray()
	for k: String in KEYS:
		cmds.append("%s:%s" % [k, "off" if (_buttons[k] as Button).disabled else "on"])
	var lines := PackedStringArray()
	for l: Node in _lines.get_children():
		lines.append((l as Label).text)
	return "%s | %s | %s | %s" % [_part_title.text, " ".join(cmds), _why.text, " / ".join(lines)]


func _build_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_order.clear()
	_row_buttons.clear()
	var parts: Array = result.get("parts", [])
	var idx: Array[int] = []
	for i in parts.size():
		idx.append(i)
	# by square, front to back, left to right; CDDA's order within a square
	idx.sort_custom(func(a: int, b: int) -> bool:
		var ma: Vector2i = parts[a]["mount"]
		var mb: Vector2i = parts[b]["mount"]
		return a < b if ma == mb else (ma.x > mb.x if ma.x != mb.x else ma.y < mb.y))
	var last := Vector2i.MAX
	for i in idx:
		var p: Dictionary = parts[i]
		var b := Button.new()
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size.y = ROW_H
		b.text = _row_text(p)
		b.add_theme_color_override("font_color", _row_color(p))
		b.button_pressed = p["row"] == selected
		b.pressed.connect(select.bind(p["row"]))
		if p["mount"] != last and last != Vector2i.MAX:
			_list.add_child(HSeparator.new())
		last = p["mount"]
		_list.add_child(b)
		_order.append(p["row"])
		_row_buttons[p["row"]] = b
	if int(result.get("parts_more", 0)) > 0:
		_list.add_child(_label("... and %d more parts" % result["parts_more"], DIM))


static func _row_text(p: Dictionary) -> String:
	var f: int = p["flags"]
	var s := "%s  %d%%" % [p["name"], p["hp"]]
	if (f & VehicleWorkData.BROKEN) != 0:
		s += "  broken"
	if not (p["faults"] as PackedStringArray).is_empty():
		s += "  (" + ", ".join(p["faults"]) + ")"
	return s


static func _row_color(p: Dictionary) -> Color:
	if (int(p["flags"]) & VehicleWorkData.BROKEN) != 0:
		return BAD
	return GOOD if p["hp"] >= 100 and (p["faults"] as PackedStringArray).is_empty() else WARN


func _show_part() -> void:
	var p := VehicleWorkData.part_of(result, selected)
	var stand_in: bool = result.get("stand_in", false)
	_note.text = "Asking the game..." if waiting else \
			("Stand-in: the game's own checks aren't connected yet." if stand_in else "")
	_note.visible = not _note.text.is_empty()
	_part_title.text = "" if p.is_empty() else "%s  %d%%%s" % [p["name"], p["hp"],
			("  [" + p["variant"] + "]") if not (p["variant"] as String).is_empty() else ""]
	for l in _lines.get_children():
		_lines.remove_child(l)
		l.queue_free()
	for k: String in KEYS:
		var c := _command(k) if k != "i" else {}
		var b: Button = _buttons[k]
		b.disabled = c.is_empty() or not c["ok"]
		b.tooltip_text = VehicleWorkData.refusal(c) if k != "i" else "Installing comes in a later step."
	_why.text = _flash
	_why.visible = not _why.text.is_empty()
	if p.is_empty():
		return
	# the lines of the first command that has any: repair, then remove (CDDA shows the one its cursor is on)
	for k: String in ["r", "o", "m", "f"]:
		var c := _command(k)
		if c.is_empty() or (c["lines"] as Array).is_empty():
			continue
		_lines.add_child(_label("%s:" % VehicleWorkData.COMMAND_NAMES[k], HEAD))
		for l: Dictionary in c["lines"]:
			var col: Color = GOOD if l["met"] == VehicleWorkData.MET else (BAD if l["met"] == VehicleWorkData.NOT_MET else DIM)
			var lab := _label(l["text"], col)
			lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_lines.add_child(lab)
		break


static func _label(t: String, col: Color, size := 0) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", col)
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	return l


func _mouse(set_to := -1) -> int:
	if mouse_hook.is_valid():
		var m: Variant = mouse_hook.call(set_to)
		return m if m is int else Input.MOUSE_MODE_VISIBLE
	if set_to >= 0:
		Input.mouse_mode = set_to as Input.MouseMode
	return Input.mouse_mode
