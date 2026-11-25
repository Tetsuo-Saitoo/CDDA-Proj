class_name VrWorkMenu
extends Node3D
## C6 vehicle work by hand, slice 1 (lead-vr): CDDA's commands on the part a hand picked (VrWork), as a four-way wheel
## where the trigger went down, facing the head: up repair, right remove, down mend, left refill (CDDA's r, o, m, f).
## Each is greyed with CDDA's reason from the session's read (VehicleWorkData.command_of / refusal). Over it a panel:
## the part (VehicleWorkData.row_text), then for the command pointed at CDDA's reason, or its requirement lines met
## (+) or not (-). The hand moved off the middle, or its stick, points. VrRig sends what the trigger lets go on
## (VehicleWorkSession.send) and closes it; CDDA checks it all again. Only the read is shown; nothing decides here.
## List mode (open_list; install by hand, VrInstall): CDDA's types for a square in rows over the hand instead of the
## wheel; the hand moved down a row (ROW_M), or the stick, picks one; the trigger let go on it installs it (VrRig).

const CMDS: Array[String] = ["r", "o", "m", "f"]   # up, right, down, left
const DIRS: Array[Vector2] = [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]
const RADIUS_M := 0.11         # the commands this far from the middle
const INNER_M := 0.035         # the hand this near the middle points at nothing
const STICK_ON := 0.5          # a stick past this points
const AWAY_M := 0.6            # the hand this far from where it opened closes it (VrRig)
const MAX_LINES := 8           # requirement lines shown
const MAX_PANEL := 600         # characters
const PANEL_UP := 0.2          # m: the panel's middle over the wheel's
const OK_COLOR := Color(1.0, 1.0, 1.0)
const OFF_COLOR := Color(0.5, 0.5, 0.5)
const POINTED := Color(1.0, 0.85, 0.3)
const ROW_M := 0.03            # list mode: the hand this much lower picks the next row

var hand := -1                 # the hand whose trigger opened it; -1 closed
var armed := false             # its trigger is down: letting go picks (VrRig)
var uid := 0
var row := -1
var read := {}                 # the session's read for that part (VehicleWorkData.clean)
var pointed := ""              # the command pointed at; "" none
var center := Vector3.ZERO     # where it opened (world)
var items: Array = []          # list mode: [{text, value}]; [] the wheel
var title := ""                # list mode: the line over the rows
var choice := -1               # list mode: the row picked
var _hand_k := -1              # ... the row the hand was on last
var _stick_held := false       # ... the stick past STICK_ON (one row a push)
var _labels := {}              # cmd -> Label3D
var _panel: Label3D


func _init() -> void:
	name = "VrWorkMenu"
	visible = false
	for k in CMDS.size():
		var l := _label(32)
		l.position = Vector3(DIRS[k].x, DIRS[k].y, 0.0) * RADIUS_M
		_labels[CMDS[k]] = l
		add_child(l)
	_panel = _label(22)
	_panel.position = Vector3(0.0, PANEL_UP, 0.0)
	_panel.width = 520.0
	_panel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(_panel)


func is_open() -> bool:
	return hand >= 0


## Opens for hand `i` at world point `at` facing head pose `head`, on part `part_row` of vehicle `vehicle`; `r` the
## session's last read (shown when it is that part's).
func open(i: int, at: Vector3, head: Transform3D, vehicle: int, part_row: int, r := {}) -> void:
	if i < 0 or i > 1 or not at.is_finite() or not head.is_finite():
		return
	hand = i
	armed = true
	uid = vehicle
	row = part_row
	read = {}
	pointed = ""
	center = at
	items = []
	choice = -1
	for l: Label3D in _labels.values():
		l.visible = true
	var to_head := head.origin - at
	to_head.y = 0.0
	var b := Basis.looking_at(-to_head.normalized(), Vector3.UP) if to_head.length() > 0.01 else Basis()
	if is_inside_tree():
		global_transform = Transform3D(b, at)
	else:
		transform = Transform3D(b, at)
	visible = true
	_paint()
	set_read(r)


## Opens in list mode for hand `i` at `at` facing `head`, on vehicle `vehicle`: rows `list` ([{text, value}], at most
## VrInstall.MAX_LIST) under `heading`, the first picked; not armed (the trigger that asked is up by now).
func open_list(i: int, at: Vector3, head: Transform3D, vehicle: int, list: Array, heading: String) -> void:
	if list.is_empty():
		return
	open(i, at, head, vehicle, -1)
	if not is_open():
		return
	armed = false
	items = list.slice(0, VrInstall.MAX_LIST)
	title = heading.left(MAX_PANEL)
	choice = 0
	_hand_k = 0
	_stick_held = false
	for l: Label3D in _labels.values():
		l.visible = false
	_paint()


## The picked row's value (list mode), else null.
func choice_value() -> Variant:
	return items[choice].get("value") if choice >= 0 and choice < items.size() and items[choice] is Dictionary else null


func close() -> void:
	hand = -1
	armed = false
	uid = 0
	row = -1
	read = {}
	pointed = ""
	items = []
	choice = -1
	visible = false


## The session's read (VehicleWorkSession.result): kept when it is for this vehicle and part, else ignored.
func set_read(r: Dictionary) -> void:
	if is_open() and items.is_empty() and is_for(r, uid, row):
		read = r
		_paint()


## Whether read `r` is for part `part_row` of vehicle `vehicle`: that part's read, or a refusal for that vehicle (the
## list's read, another part's, another vehicle's or junk: not).
static func is_for(r: Dictionary, vehicle: int, part_row: int) -> bool:
	var v: Variant = r.get("vehicle")
	if not v is int or v != vehicle:
		return false
	var sel: Variant = r.get("selected")
	var at: Variant = (sel as Dictionary).get("row") if sel is Dictionary else null
	return not is_ok(r) or (at is int and at == part_row)


## Points from the hand at world point `p` (its offset from the middle in the wheel's plane), or its stick `stick`.
func point(p: Vector3, stick := Vector2.ZERO) -> void:
	if not is_open():
		return
	if not items.is_empty():
		_point_list(p, stick)
		return
	var v := Vector2.ZERO
	if stick.is_finite() and stick.length() > STICK_ON:
		v = stick
	elif p.is_finite():
		var l := to_local(p) if is_inside_tree() else transform.affine_inverse() * p
		v = Vector2(l.x, l.y)
		if v.length() < INNER_M:
			v = Vector2.ZERO
	var best := ""
	var best_dot := 0.5
	if v != Vector2.ZERO:
		for k in CMDS.size():
			var d := DIRS[k].dot(v.normalized())
			if d > best_dot:
				best_dot = d
				best = CMDS[k]
	if best != pointed:
		pointed = best
		_paint()


## Whether the read lets command `cmd` go (CDDA's checks run again when it does).
func allowed(cmd: String) -> bool:
	return lets(read, cmd)


## Whether read `r` lets command `cmd` go.
static func lets(r: Dictionary, cmd: String) -> bool:
	return is_ok(VehicleWorkData.command_of(r, cmd)) if is_ok(r) else false


## Whether a read or command `d` says ok (a bool true; anything else: no).
static func is_ok(d: Dictionary) -> bool:
	var ok: Variant = d.get("ok")
	return ok is bool and ok


## Why `cmd` can't go, in CDDA's words ("" when it can).
func why_not(cmd: String) -> String:
	return reason(read, cmd)


## Why read `r` doesn't let `cmd` go, in CDDA's words ("" when it does).
static func reason(r: Dictionary, cmd: String) -> String:
	if r.is_empty():
		return "Checking the part..."
	if not is_ok(r):   # CDDA's sentence, else the bridge's word as the flat view says it
		var t: Variant = r.get("text")
		var e: Variant = r.get("error")
		if t is String and not (t as String).is_empty():
			return (t as String).left(MAX_PANEL)
		return "The game couldn't answer (%s)." % (e as String).left(80) if e is String and not (e as String).is_empty() \
				else "Not possible now."
	return VehicleWorkData.refusal(VehicleWorkData.command_of(r, cmd))


func panel_text() -> String:
	return _panel.text


## List mode: the hand's row below the middle when it changes rows, else a stick push one row up or down.
func _point_list(p: Vector3, stick: Vector2) -> void:
	var k := choice
	if stick.is_finite() and absf(stick.y) > STICK_ON:
		if not _stick_held:
			k += -1 if stick.y > 0.0 else 1
		_stick_held = true
	else:
		_stick_held = false
	if p.is_finite():
		var l := to_local(p) if is_inside_tree() else transform.affine_inverse() * p
		var hk := clampi(roundi(-l.y / ROW_M), 0, items.size() - 1)
		if hk != _hand_k:
			_hand_k = hk
			k = hk
	k = clampi(k, 0, items.size() - 1)
	if k != choice:
		choice = k
		_paint()


func _paint() -> void:
	if not items.is_empty():
		var rows := PackedStringArray([title])
		for k in items.size():
			var t: Variant = (items[k] as Dictionary).get("text") if items[k] is Dictionary else ""
			rows.append(("> " if k == choice else "  ") + str(t).left(VehicleWorkData.MAX_NAME + 40))
		_panel.text = "\n".join(rows).left(MAX_PANEL)
		return
	for cmd: String in CMDS:
		var l: Label3D = _labels[cmd]
		l.text = VehicleWorkData.COMMAND_NAMES[cmd]
		l.modulate = POINTED if cmd == pointed else (OK_COLOR if allowed(cmd) else OFF_COLOR)
		l.outline_size = 12 if cmd == pointed else 4
	var lines := PackedStringArray()
	var p := VehicleWorkData.part_of(read, row)
	lines.append(VehicleWorkData.row_text(p) if not p.is_empty() else "Checking the part...")
	if not pointed.is_empty():
		var c := VehicleWorkData.command_of(read, pointed)
		if allowed(pointed):
			lines.append("%s:" % VehicleWorkData.COMMAND_NAMES[pointed])
			var n := 0
			for l: Dictionary in c.get("lines", []):
				n += 1
				if n > MAX_LINES:
					break
				var met: int = l.get("met", 0)
				lines.append(("+ " if met == VehicleWorkData.MET else ("- " if met == VehicleWorkData.NOT_MET else "  ")) + str(l.get("text", "")))
		else:
			lines.append("%s: %s" % [VehicleWorkData.COMMAND_NAMES[pointed], why_not(pointed)])
	_panel.text = "\n".join(lines).left(MAX_PANEL)


static func _label(px: int) -> Label3D:
	var l := Label3D.new()
	l.pixel_size = 0.0006
	l.font_size = px
	l.outline_size = 4
	l.no_depth_test = true
	l.fixed_size = false
	l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	l.render_priority = 2
	return l
