class_name VrWorkMenu
extends Node3D
## C6 vehicle work by hand, slice 1 (lead-vr): CDDA's commands on the part a hand picked (VrWork), as a four-way wheel
## where the trigger went down, facing the head: up repair, right remove, down mend, left refill (CDDA's r, o, m, f).
## Each is greyed with CDDA's reason from the session's read (VehicleWorkData.command_of / refusal). Over it a panel:
## the part (VehicleWorkData.row_text), then for the command pointed at CDDA's reason, or its requirement lines met
## (+) or not (-). The hand moved off the middle, or its stick, points. VrRig sends what the trigger lets go on
## (VehicleWorkSession.send) and closes it; CDDA checks it all again. Only the read is shown; nothing decides here.

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

var hand := -1                 # the hand whose trigger opened it; -1 closed
var armed := false             # its trigger is down: letting go picks (VrRig)
var uid := 0
var row := -1
var read := {}                 # the session's read for that part (VehicleWorkData.clean)
var pointed := ""              # the command pointed at; "" none
var center := Vector3.ZERO     # where it opened (world)
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


func close() -> void:
	hand = -1
	armed = false
	uid = 0
	row = -1
	read = {}
	pointed = ""
	visible = false


## The session's read (VehicleWorkSession.result): kept when it is for this vehicle and part, else ignored.
func set_read(r: Dictionary) -> void:
	if is_open() and is_for(r, uid, row):
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
	return not _ok(r) or (at is int and at == part_row)


## Points from the hand at world point `p` (its offset from the middle in the wheel's plane), or its stick `stick`.
func point(p: Vector3, stick := Vector2.ZERO) -> void:
	if not is_open():
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
	return _ok(VehicleWorkData.command_of(r, cmd)) if _ok(r) else false


static func _ok(d: Dictionary) -> bool:
	var ok: Variant = d.get("ok")
	return ok is bool and ok


## Why `cmd` can't go, in CDDA's words ("" when it can).
func why_not(cmd: String) -> String:
	return reason(read, cmd)


## Why read `r` doesn't let `cmd` go, in CDDA's words ("" when it does).
static func reason(r: Dictionary, cmd: String) -> String:
	if r.is_empty():
		return "Checking the part..."
	if not _ok(r):
		return str(r.get("text", r.get("error", "Not possible now.")))
	return VehicleWorkData.refusal(VehicleWorkData.command_of(r, cmd))


func panel_text() -> String:
	return _panel.text


func _paint() -> void:
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
