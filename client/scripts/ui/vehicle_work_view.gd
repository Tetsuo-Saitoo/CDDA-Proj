class_name VehicleWorkView
extends PanelContainer
## C6 vehicle work, flat screen (lead-ui, 2026-11-22): the work view beside a car (Shift+V, `vehicle_work`; again or
## Esc closes it). The car's parts as a list (by square, CDDA's names and condition), and for the selected part
## CDDA's commands, greyed with CDDA's reason when they can't be done, and CDDA's requirement lines (met green,
## not met red). Keys: Up/Down the part, CDDA's own i r o m f the command, 1 2 3 the camera (around, hood, under).
## i opens install mode on the selected part's square: the types CDDA would install there (those that fit; Tab all),
## Shift+arrows another square (an empty one next to the car too), i or Enter installs the picked type, Esc back.
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
## Install mode wants the read for square `mount` (its types), and for type `vpart` (> 0: its requirement lines).
signal install_asked(mount: Vector2i, vpart: int)
## The type the read says can be installed now on square `mount`.
signal install_chosen(vpart: int, mount: Vector2i)
## Install mode ended (Esc, or the install started): back on the parts list.
signal install_ended

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
## Shift+arrow -> the next square by mount (x forward, y right, as the list runs front to back).
const MOVES := {KEY_UP: Vector2i(1, 0), KEY_DOWN: Vector2i(-1, 0), KEY_LEFT: Vector2i(0, -1), KEY_RIGHT: Vector2i(0, 1)}
const HINT_PARTS := "Up/Down: part   i: install here   1 around  2 hood  3 under   Esc: close"
const HINT_INSTALL := "Up/Down: type   Shift+arrows: square   Tab: all types   i/Enter: install   Esc: back"

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
## Install mode: the list shows what could be installed on square `install_at` (a mount), `install_pick` the type
## picked (0 none), `show_all` also the types that don't fit there.
var installing := false
var install_at := Vector2i.ZERO
var install_pick := 0
var show_all := false
## (vpart: int) -> String: a part type's name (the id table's). Unset: "part #N".
var type_name := Callable()

var _title: Label
var _note: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _part_title: Label
var _cmd_box: HFlowContainer   # wraps on a narrow window (800x450: the five don't fit one row)
var _buttons := {}      # cmd -> Button
var _why: Label
var _lines: VBoxContainer
var _hint: Label
var _order: Array[int] = []   # rows in list order
var _row_buttons := {}         # row -> Button
var _inst := {}                # the read's install section for install_at
var _type_order: Array[int] = []   # install mode: types in list order
var _type_rows := {}               # vpart -> VehicleWorkData.install_rows entry
var _type_buttons := {}            # vpart -> Button
var _flash := ""
var _prev_mouse: int = Input.MOUSE_MODE_VISIBLE


func _init() -> void:
	name = "VehicleWorkView"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN   # never past the right edge, should content ask for more
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
	_cmd_box = HFlowContainer.new()
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
	_hint = _label(HINT_PARTS, DIM, 12)
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
	installing = false
	install_pick = 0
	_inst = {}
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
	installing = false
	_inst = {}
	_mouse(_prev_mouse)
	closed.emit()


## Size and place for the window: docked right, at most MAX_W wide and 45% of the window, full height less a margin.
func fit() -> void:
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	var w := width_for(vp.x)
	offset_left = -w - 8.0
	offset_right = -8.0
	offset_top = 8.0
	offset_bottom = -8.0


## The view's width in a window `window_w` wide.
static func width_for(window_w: float) -> float:
	return clampf(window_w * 0.45, MIN_W, MAX_W)


## The middle of the window left of the view, as a share of the window's width (where the work camera puts the
## part: lead-world's work_cam.frame_x).
static func free_center(window_w: float) -> float:
	if window_w <= 0.0:
		return 0.3
	return clampf((window_w - width_for(window_w) - 16.0) * 0.5 / window_w, 0.1, 0.5)


## A read for this vehicle came (VehicleWorkData.clean's Dictionary): shown. One for another vehicle is ignored.
## False when it was ignored or it closes the view (the vehicle went or is out of reach: `ok` false with that
## error; main says why). In install mode only its install section for install_at is new to the list.
func set_result(r: Dictionary) -> bool:
	if not visible or r.get("vehicle") != uid:
		return false
	if r.get("ok") != true:
		waiting = false
		var e: String = r.get("error", "internal")
		if e in ["no such vehicle", "too far", "an appliance"]:
			close()
			return false
		var said: String = r.get("text", "")   # CDDA's own sentence ("... while mounted.")
		_flash = said if not said.is_empty() else "The game couldn't answer (%s)." % e
		_show_part()
		return true
	var old: Array = result.get("parts", [])
	result = r
	if not (r["name"] as String).is_empty():
		_title.text = r["name"]
	if installing:
		var inst: Dictionary = r.get("install", {})
		if not inst.is_empty() and inst["mount"] == install_at:
			_inst = inst
			waiting = install_pick > 0 and _install_cmd().is_empty()
			_build_types()
		_show_part()
		return true
	waiting = false
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


## Shows `text` under the commands (an action's outcome, CDDA's reason) until the selection changes.
func say(text: String) -> void:
	_flash = text
	_show_part()


## Drops the selection without asking (a removal moves the rows after it up): the next read selects the first part.
func forget_selection() -> void:
	selected = -1


## Moves the selection `delta` rows down the list (wraps): a part, or in install mode a type.
func move(delta: int) -> void:
	var order := _type_order if installing else _order
	if order.is_empty():
		return
	var i := order.find(install_pick if installing else selected)
	var to := order[posmod((i if i >= 0 else 0) + (delta if i >= 0 else 0), order.size())]
	if installing:
		pick_type(to)
	else:
		select(to)


## Command `cmd` on the selected part: chosen when the read for that part says it can be done now, else its
## reason is shown. True when chosen. "i" opens install mode on its square, and there installs the picked type.
func choose(cmd: String) -> bool:
	if cmd == "i":
		return _choose_install()
	if installing or selected < 0:
		return false
	var c := _command(cmd)
	if c.is_empty() or not c["ok"]:
		_flash = VehicleWorkData.refusal(c) if not waiting else "Still asking the game."
		_show_part()
		return false
	command_chosen.emit(cmd, selected)
	return true


## Install mode on the vehicle's square `at` (a mount; it may hold no part yet): the list shows the types CDDA
## would install there, and main asks the read for them (install_asked).
func begin_install(at: Vector2i) -> void:
	if not visible:
		return
	installing = true
	install_at = at
	install_pick = 0
	_inst = {}
	_flash = ""
	waiting = true
	_build_list()
	_show_part()
	install_asked.emit(at, 0)


## Back to the parts list (Esc in install mode, or the install started); the selected part is asked again.
func end_install() -> void:
	if not installing:
		return
	installing = false
	install_pick = 0
	_inst = {}
	_flash = ""
	_build_list()
	var keep := selected
	selected = -1
	select(keep if _row_buttons.has(keep) else (_order[0] if not _order.is_empty() else -1))
	_show_part()
	install_ended.emit()


## Picks type `vpart` in install mode (it must be listed) and asks for its requirement lines.
func pick_type(vpart: int) -> void:
	if not installing or vpart == install_pick or not _type_buttons.has(vpart):
		return
	install_pick = vpart
	_flash = ""
	waiting = true
	for v: int in _type_buttons:
		(_type_buttons[v] as Button).button_pressed = v == vpart
	_scroll.ensure_control_visible(_type_buttons[vpart])
	_show_part()
	install_asked.emit(install_at, vpart)


## Install mode on the square `delta` from the one shown (mounts stay within the action's range).
func move_square(delta: Vector2i) -> void:
	var to := install_at + delta
	var lim := VehicleWorkData.MAX_ACTION_MOUNT
	if installing and absi(to.x) <= lim and absi(to.y) <= lim:
		begin_install(to)


## Install mode: also list the types that don't fit the square (CDDA's own list shows them all), or not.
func toggle_all() -> void:
	if not installing:
		return
	show_all = not show_all
	_build_types()
	_show_part()


func _choose_install() -> bool:
	if not installing:
		var p := VehicleWorkData.part_of(result, selected)
		begin_install(p["mount"] if not p.is_empty() else Vector2i.ZERO)
		return false
	var c := _install_cmd()
	if c.is_empty() or not c["ok"]:
		_flash = VehicleWorkData.refusal(c) if not c.is_empty() else \
				("Pick a part to install." if install_pick == 0 else "Still asking the game.")
		_show_part()
		return false
	install_chosen.emit(install_pick, install_at)
	return true


## The command `cmd` for the selected part from the last read, {} when the read isn't for that part.
func _command(cmd: String) -> Dictionary:
	var sel: Dictionary = result.get("selected", {})
	if sel.get("row", -1) != selected:
		return {}
	return VehicleWorkData.command_of(result, cmd)


## The install command for the picked type from the last read, {} when the read isn't for it.
func _install_cmd() -> Dictionary:
	var s: Dictionary = _inst.get("selected", {})
	return s if install_pick > 0 and s.get("vpart", 0) == install_pick else {}


## Keys while open (`vehicle_work` or Esc closes, Esc leaves install mode first; blocked while a CDDA prompt has
## them). True when used.
func handle_key(event: InputEvent) -> bool:
	if not visible or (blocked.is_valid() and blocked.call() == true):
		return false
	if InputActions.pressed(event, &"vehicle_work"):
		close()
		return true
	var cancel := event is InputEventAction and event.is_pressed() and (event as InputEventAction).action == &"ui_cancel"
	var k := event as InputEventKey
	if cancel or (k != null and k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE):
		if installing:
			end_install()
		else:
			close()
		return true
	if k == null or not k.pressed:
		return false
	if VIEWS.has(k.physical_keycode):
		if not k.echo:
			view_chosen.emit(VIEWS[k.physical_keycode])
		return true
	if installing:
		return _install_key(k)
	match k.physical_keycode:
		KEY_ESCAPE:
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
	return false


func _install_key(k: InputEventKey) -> bool:
	var code := k.physical_keycode
	if MOVES.has(code) and k.shift_pressed:
		if not k.echo:
			move_square(MOVES[code])
		return true
	match code:
		KEY_UP, KEY_DOWN:
			move(-1 if code == KEY_UP else 1)
		KEY_TAB:
			if not k.echo:
				toggle_all()
		KEY_I, KEY_ENTER, KEY_KP_ENTER:
			if not k.echo and not k.ctrl_pressed and not k.alt_pressed:
				choose("i")
		KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, KEY_R, KEY_O, KEY_M, KEY_F:
			pass
		_:
			return false
	return true


func _input(event: InputEvent) -> void:
	if handle_key(event):
		get_viewport().set_input_as_handled()


## The list text of the view (tests): one line a row (a part, or in install mode a type), "> " before the chosen one.
func list_text() -> String:
	var out := PackedStringArray()
	if installing:
		for v in _type_order:
			out.append(("> " if v == install_pick else "  ") + (_type_buttons[v] as Button).text)
	else:
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
	if installing:
		_build_types()
		return
	_clear_list()
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
		var b := _row_button(VehicleWorkData.row_text(p), _row_color(p), p["row"] == selected)
		b.pressed.connect(select.bind(p["row"]))
		if p["mount"] != last and last != Vector2i.MAX:
			_list.add_child(HSeparator.new())
		last = p["mount"]
		_list.add_child(b)
		_order.append(p["row"])
		_row_buttons[p["row"]] = b
	if int(result.get("parts_more", 0)) > 0:
		_list.add_child(_label("... and %d more parts" % result["parts_more"], DIM))


## Install mode's list: the read's types for install_at in CDDA's order (those that fit, unless show_all).
func _build_types() -> void:
	_clear_list()
	_type_order.clear()
	_type_rows.clear()
	_type_buttons.clear()
	if _inst.is_empty():
		_list.add_child(_label("Asking the game...", DIM))
		return
	for t: Dictionary in VehicleWorkData.install_rows(_inst, type_name, show_all):
		var b := _row_button(VehicleWorkData.type_text(t),GOOD if t["have"] and t["fits"] else DIM, t["vpart"] == install_pick)
		b.pressed.connect(pick_type.bind(t["vpart"]))
		_list.add_child(b)
		_type_order.append(t["vpart"])
		_type_rows[t["vpart"]] = t
		_type_buttons[t["vpart"]] = b
	if _type_order.is_empty():
		_list.add_child(_label("Nothing fits here now. Tab: all types." if not show_all else "Nothing to install.", DIM))
	if int(_inst.get("types_more", 0)) > 0:
		_list.add_child(_label("... and %d more types" % _inst["types_more"], DIM))


func _clear_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()


static func _row_button(text: String, col: Color, pressed: bool) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true   # a long name or fault list doesn't widen the view
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.tooltip_text = text
	b.custom_minimum_size.y = ROW_H
	b.text = text
	b.add_theme_color_override("font_color", col)
	b.button_pressed = pressed
	return b


static func _row_color(p: Dictionary) -> Color:
	if (int(p["flags"]) & VehicleWorkData.BROKEN) != 0:
		return BAD
	return GOOD if p["hp"] >= 100 and (p["faults"] as PackedStringArray).is_empty() else WARN


func _show_part() -> void:
	var stand_in: bool = result.get("stand_in", false)
	_note.text = "Asking the game..." if waiting else \
			("Stand-in: the game's own checks aren't connected yet." if stand_in else "")
	if result.get("owned", true) == false:   # CDDA asks before any work on it; owners who see it take it as theft
		_note.text = ("Not your vehicle: the game asks first. " + _note.text).strip_edges()
	_note.visible = not _note.text.is_empty()
	_hint.text = HINT_INSTALL if installing else HINT_PARTS
	for l in _lines.get_children():
		_lines.remove_child(l)
		l.queue_free()
	if installing:
		_show_install()
		return
	var p := VehicleWorkData.part_of(result, selected)
	_part_title.text = "" if p.is_empty() else "%s  %d%%%s" % [p["name"], p["hp"],
			("  [" + p["variant"] + "]") if not (p["variant"] as String).is_empty() else ""]
	for k: String in KEYS:
		var c := _command(k) if k != "i" else {}
		var b: Button = _buttons[k]
		b.disabled = (c.is_empty() or not c["ok"]) if k != "i" else p.is_empty()
		b.tooltip_text = VehicleWorkData.refusal(c) if k != "i" else "Install a part on this square"
	_why.text = _flash
	_why.visible = not _why.text.is_empty()
	if p.is_empty():
		return
	# the lines of the first command that has any: repair, then remove (CDDA shows the one its cursor is on)
	for k: String in ["r", "o", "m", "f"]:
		var c := _command(k)
		if c.is_empty() or (c["lines"] as Array).is_empty():
			continue
		_add_lines(VehicleWorkData.COMMAND_NAMES[k], c["lines"])
		break


func _show_install() -> void:
	var c := _install_cmd()
	var pick: Dictionary = _type_rows.get(install_pick, {})
	_part_title.text = VehicleWorkData.square_text(result, install_at) + ("\n> " + pick["name"] if not pick.is_empty() else "")
	for k: String in KEYS:
		var b: Button = _buttons[k]
		b.disabled = k != "i" or c.is_empty() or not c["ok"]
		b.tooltip_text = VehicleWorkData.refusal(c) if k == "i" else ""
	var why := _flash if not _flash.is_empty() else VehicleWorkData.install_refusal(_inst)
	_why.text = why
	_why.visible = not why.is_empty()
	if not c.is_empty():
		_add_lines(VehicleWorkData.COMMAND_NAMES["i"], c["lines"])


func _add_lines(head: String, lines: Array) -> void:
	_lines.add_child(_label("%s:" % head, HEAD))
	for l: Dictionary in lines:
		var col: Color = GOOD if l["met"] == VehicleWorkData.MET else (BAD if l["met"] == VehicleWorkData.NOT_MET else DIM)
		var lab := _label(l["text"], col)
		lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_lines.add_child(lab)


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
