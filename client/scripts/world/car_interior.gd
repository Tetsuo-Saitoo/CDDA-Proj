class_name CarInterior
extends Node3D
## C5 interiors: what a vehicle near the camera shows inside beyond its baked body (VehicleView builds one for each
## vehicle within INTERIOR_NEAR, a child of its node, so in its mount grid: x ahead, z to the right, a cell per square
## on its floor). From CDDA's own parts: at the first controls drawn, the steering wheel (turned by how far CDDA
## steers) and the instrument cluster (CarDash); on each lockable, covered container drawn as a box or a half board
## (has_lid: trunks, boxes, a bin), a hinged lid over a dark opening, hinged on the side toward the vehicle's middle;
## on a glovebox, a door in the dashboard behind its square (glove_doors); a hood over an open engine bay (hood_of,
## "Hood" with "Lid", the same meta; C6). No contents yet. lead-vr's anchors (anchors()): "Wheel" with "WheelSpin" (spins about its local z; meta radius_m,
## part), "Dash", "Cargo_<part>" with "Lid" (the pivot on the hinge; meta part, square, hinge_axis, open_deg, handle,
## cdda_open, opening: the space hands reach into, an AABB in the Cargo node's frame, opening_out: its open face's
## outward normal there). Nothing here moves a WheelSpin or Lid whose meta "held" is true (a VR hand has it). A lid of a part
## CDDA opens (cdda_open) follows its state (VPART_OPEN); CDDA 0.I opens no container, so the others open on the
## client only (open_lid) and stay where a hand leaves them. Moves only while something is on its way (step).

const WHEEL_AT := Vector3(0.3, 1.2, 0.0)   # the hub, from the controls' square (its floor centre)
const WHEEL_TILT := 25.0      # degrees the wheel leans back from upright
const WHEEL_R := 0.17         # m: the rim's middle from the hub
const WHEEL_TUBE := 0.014     # the rim's thickness (radius)
const WHEEL_RATIO := 6.0      # wheel degrees per degree CDDA steers off the facing
const WHEEL_MAX := 450.0
const WHEEL_RATE := 540.0     # degrees per second
const WHEEL_COLOR := Color(0.09, 0.09, 0.1)
const WHEEL_MARK := Color(0.5, 0.46, 0.38)   # a sleeve at the rim's top: how far it is turned shows
const DASH_AT := Vector3(0.44, 1.38, 0.0)   # about 24 degrees under the seated eyes, 0.5 m off: seen over the wheel
const DASH_TILT := 20.0
const LID_TOP := 1.05         # m: a container's top (a cargo box's, a half board's)
const LID_T := 0.03
const LID_HALF := {VehicleView.Kind.CARGO: 0.4, VehicleView.Kind.HALF: 0.46}   # half the lid's side, by the part's kind
const LID_OPEN := 80.0        # degrees
const LID_RATE := 160.0       # degrees per second
const LID_REACH := 45.0       # degrees a lid is open from which hands reach in (can_reach)
const MAX_LIDS := 64
const OPENING := Color(0.03, 0.03, 0.03)
const HANDLE := Color(0.25, 0.25, 0.27)
const VIEW_M := 30.0          # wheel and lids are drawn this near the camera
## The glovebox (lead-bridge's vpart, contracts/snapshot.md): on the windshield's square ahead of a front seat; its
## door is drawn in the dashboard in front of that seat, hinged at its bottom edge, the top opening toward the seat.
const GLOVEBOX := "fp3d_glovebox"
const DASH_FACE := 0.38       # m: the dashboard's back face ahead of a cell's middle (VehicleView.shapes: DASH, CONTROLS)
const GLOVE_W := 0.36         # m: the door across
const GLOVE_H := 0.17         # and up
const GLOVE_Y := 0.95         # its bottom edge (the hinge) above the floor
const GLOVE_T := 0.02         # its thickness
const GLOVE_OPEN := 80.0      # degrees: down to a shelf
## C6: the hood over an engine bay (CDDA 0.I has no hood part: the client's own, like the lids): a panel just over
## the engine's top across the bay, hinged on its edge toward the vehicle's middle. In `lids` under the key HOOD.
const HOOD := -1
const HOOD_UP := VehicleView.DECK + 0.62   # m: its underside, just over an engine's top
const HOOD_T := 0.03
const HOOD_OPEN := 70.0
const MAX_BAY := 64           # cells a bay reaches across its row at most

static var _wheel_mesh: ArrayMesh

var uid := 0
var key: Array = []           # layout_key it was built from
var wheel: Node3D             # "Wheel"; null with no controls drawn
var spin: Node3D              # its "WheelSpin"
var dash: CarDash
var lids := {}                # part index -> "Cargo_<part>"
var lid_at := {}              # Vector2i mount -> the part whose lid covers that square
var moving := false           # something is on its way: VehicleView steps it
var _lid_goal := {}           # part index -> degrees
var _lid_set := {}            # part index -> degrees it was last put at here (else a hand moved it)
var seen: Array = []          # the parts, z and tables last checked against key (VehicleView._check_interior)
var _cdda_open := {}          # part index -> the state last seen (lids CDDA opens)
var _spin_deg := 0.0          # where the wheel is turned (unwrapped)
var _spin_goal := 0.0


func _init() -> void:
	name = "Interior"


## The part whose lid covers the square of part `part` of `veh` (mount), -1 for none: lid_at in a built interior,
## else as build() would lay them out.
static func lid_over(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int, part: int) -> int:
	if part < 0 or part >= veh.part_count():
		return -1
	var j := part * Snapshot.VPART_STRIDE
	var m := Vector2i(veh.parts[j], veh.parts[j + 1])
	for e: Array in parts_of(veh, snap, tables, z_max)[1]:
		var k: int = e[0] * Snapshot.VPART_STRIDE
		if Vector2i(veh.parts[k], veh.parts[k + 1]) == m:
			return e[0]
	return -1


## Whether a part definition is a container with a lid: CDDA's lockable, covered cargo in the middle of a square
## (trunks, boxes, a bin), not a seat, bed, door, aisle or wall.
static func has_lid(def: IdTables.Def) -> bool:
	if def == null or def.location != "center":
		return false
	var f := def.flags
	if not (f.has("CARGO") and f.has("COVERED") and f.has("LOCKABLE_CARGO")):
		return false
	for no: String in ["SEAT", "BED", "DOOR", "AISLE", "FULL_BOARD"]:
		if f.has(no):
			return false
	return true


## The parts a vehicle's interior is built from: [the first controls drawn (part index, -1 none), [[lid part, kind],
## ...]]: each unbroken container with a lid drawn as a box or a half board, then each glovebox with a door
## (glove_doors; kind DASH), one per square, at most MAX_LIDS. Parts above `z_max` and gap fillers are left out.
static func parts_of(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int) -> Array:
	var controls := -1
	var out := []
	var seen := {}
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var state := veh.parts[j + 4]
		if veh.pos.z + veh.parts[j + 7] > z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
		var def := VehicleView.def_of(tables, snap, veh.parts[j + 2])
		var kind := VehicleView.kind_of(def, state)
		if kind == VehicleView.Kind.CONTROLS and controls < 0:
			controls = i
		var m := Vector2i(veh.parts[j], veh.parts[j + 1])
		if LID_HALF.has(kind) and has_lid(def) and (state & Snapshot.VPART_BROKEN) == 0 and not seen.has(m) \
				and out.size() < MAX_LIDS:
			seen[m] = true
			out.append([i, kind])
	for g: Array in glove_doors(veh, snap, tables, z_max):
		if not seen.has(g[1]) and out.size() < MAX_LIDS:
			seen[g[1]] = true
			out.append([g[0], VehicleView.Kind.DASH])
	return [controls, out]


## The gloveboxes of `veh` with a door drawn: [[part, mount], ...], at most MAX_LIDS: each unbroken GLOVEBOX part
## with a dashboard on the square behind it (the controls' or a seat's in their row, as VehicleView draws them).
## Parts above `z_max` and gap fillers are left out.
static func glove_doors(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int) -> Array:
	var rows := {}    # mount x of the controls
	var dash := {}    # mount -> true: a dashboard is drawn there
	var seats := []
	var gloves := []
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var state := veh.parts[j + 4]
		if veh.pos.z + veh.parts[j + 7] > z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
		var def := VehicleView.def_of(tables, snap, veh.parts[j + 2])
		var m := Vector2i(veh.parts[j], veh.parts[j + 1])
		if def != null and def.id == GLOVEBOX:
			if (state & Snapshot.VPART_BROKEN) == 0 and gloves.size() < MAX_LIDS:
				gloves.append([i, m])
			continue
		var kind := VehicleView.kind_of(def, state)
		if kind == VehicleView.Kind.CONTROLS:
			rows[m.x] = true
			dash[m] = true
		elif kind == VehicleView.Kind.SEAT:
			seats.append(m)
	if gloves.is_empty():
		return []
	for m: Vector2i in seats:
		if rows.has(m.x):
			dash[m] = true
	return gloves.filter(func(g: Array) -> bool: return dash.has((g[1] as Vector2i) - Vector2i(1, 0)))


## Where the door of a glovebox on mount `m` is drawn, closed, with the dashboard's depth behind it (mount grid: x
## ahead, z right, y up from the floor): what a look meets (LookRay).
static func glove_box(m: Vector2i) -> AABB:
	return AABB(Vector3(m.x - 1 + DASH_FACE - GLOVE_T, GLOVE_Y, m.y - 0.5 * GLOVE_W),
			Vector3(GLOVE_T + 0.5 - DASH_FACE, GLOVE_H, GLOVE_W))


## What an interior is built from: the parts (index, mount, vpart, kind) and the id tables. Their states (a lid
## opened) only move it.
static func layout_key(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int) -> Array:
	var p := parts_of(veh, snap, tables, z_max)
	var key := [tables, snap.ids_generation if snap != null else -1]
	var at := func(i: int) -> Array:
		var j := i * Snapshot.VPART_STRIDE
		return [i, veh.parts[j], veh.parts[j + 1], veh.parts[j + 2]]
	key.append(at.call(p[0]) if p[0] >= 0 else [])
	for e: Array in p[1]:
		key.append(at.call(e[0]) + [e[1]])
	key.append(hood_of(veh, snap, tables, z_max))
	return key


## The engine bay a hood covers (mount grid; its underside at HOOD_UP): the cells of engines no roof covers and the
## uncovered cells beside them across their row, as one box; AABB() when there is none. Parts above `z_max` and gap
## fillers are left out.
static func hood_of(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int) -> AABB:
	var cells := {}
	var roofed := {}
	var engines := []
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var state := veh.parts[j + 4]
		if veh.pos.z + veh.parts[j + 7] > z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
		var m := Vector2i(veh.parts[j], veh.parts[j + 1])
		cells[m] = true
		var kind := VehicleView.kind_of(VehicleView.def_of(tables, snap, veh.parts[j + 2]), state)
		if kind == VehicleView.Kind.ROOF:
			roofed[m] = true
		elif kind == VehicleView.Kind.ENGINE:
			engines.append(m)
	var lo := Vector2i.MAX
	var hi := Vector2i.MIN
	for e: Vector2i in engines:
		if roofed.has(e):
			continue
		for d: int in [1, -1]:   # the bay across the engine's row
			var n := 0
			var m := e
			while n < MAX_BAY and cells.has(m) and not roofed.has(m):
				lo = Vector2i(mini(lo.x, m.x), mini(lo.y, m.y))
				hi = Vector2i(maxi(hi.x, m.x), maxi(hi.y, m.y))
				m += Vector2i(0, d)
				n += 1
	if lo == Vector2i.MAX:
		return AABB()
	return AABB(Vector3(lo.x - 0.5, HOOD_UP, lo.y - 0.5), Vector3(hi.x - lo.x + 1, HOOD_T, hi.y - lo.y + 1))


## All layout_key reads from (cheap to compare): while it is the same, so is layout_key. `own`: with a copy of the
## parts (packed arrays are shared by reference), to keep.
static func seen_key(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int, own := false) -> Array:
	return [veh.parts.duplicate() if own else veh.parts, veh.pos.z, z_max, tables, snap.ids_generation if snap != null else -1]


## The interior of `veh` (in its mount grid; `mid` the middle of its cells, `paint` its body's colour), its lids
## where CDDA's states put them, dark.
static func build(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, z_max: int, mid: Vector3, paint: Color) -> CarInterior:
	var it := CarInterior.new()
	it.uid = veh.uid
	it.key = layout_key(veh, snap, tables, z_max)
	it.seen = seen_key(veh, snap, tables, z_max, true)
	var p := parts_of(veh, snap, tables, z_max)
	if p[0] >= 0:
		it._add_controls(veh, p[0])
	for e: Array in p[1]:
		var j: int = e[0] * Snapshot.VPART_STRIDE
		if e[1] == VehicleView.Kind.DASH:
			it._add_glovebox(veh, e[0], VehicleView.damaged(VehicleView.DASH_COLOR.lightened(0.12), veh.parts[j + 3], veh.parts[j + 4]))
			continue
		var def := VehicleView.def_of(tables, snap, veh.parts[j + 2])
		var col := paint if e[1] == VehicleView.Kind.HALF else VehicleView.color_of(e[1], def, veh.parts[j + 3], veh.parts[j + 4])
		it._add_lid(veh, e[0], e[1], def != null and def.flags.has("OPENABLE"), mid, col)
	var bay := hood_of(veh, snap, tables, z_max)
	if bay.size != Vector3.ZERO:
		it._add_hood(bay, mid, paint)
	it.set_states(veh, true)
	return it


## lead-vr's anchors: {"Wheel", "Dash", "Cargo_<part>" -> Node3D}, those built.
func anchors() -> Dictionary:
	var out := {}
	if wheel != null:
		out["Wheel"] = wheel
	if dash != null:
		out["Dash"] = dash
	for part: int in lids:
		out[String((lids[part] as Node3D).name)] = lids[part]
	return out


## Follows CDDA's states: each lid it opens goes to open or closed when its state changes (`now`: at once).
func set_states(veh: Snapshot.Vehicle, now := false) -> void:
	for part: int in lids:
		var c: Node3D = lids[part]
		if not c.get_meta("cdda_open", false) or part >= veh.part_count():
			continue
		var open := (veh.parts[part * Snapshot.VPART_STRIDE + 4] & Snapshot.VPART_OPEN) != 0
		if not now and _cdda_open.get(part) == open:
			continue   # unchanged: where a hand left it, it stays
		_cdda_open[part] = open
		_lid_goal[part] = c.get_meta("open_deg") if open else 0.0
		_lid_set[part] = lid_deg(part)
		var lid: Node3D = c.get_node("Lid")
		if now:
			lid.basis = Basis(c.get_meta("hinge_axis"), deg_to_rad(_lid_goal[part]))
			_lid_set[part] = _lid_goal[part]
		elif absf(lid_deg(part) - _lid_goal[part]) > 0.05 and not lid.get_meta("held", false):
			moving = true


## Opens or closes the lid of part `part` on the client (a part CDDA opens follows CDDA again at its next state);
## false when it has none.
func open_lid(part: int, open: bool) -> bool:
	if not lids.has(part):
		return false
	_lid_goal[part] = (lids[part] as Node3D).get_meta("open_deg") if open else 0.0
	_lid_set[part] = lid_deg(part)
	moving = true
	return true


## How far the lid of part `part` is open now (degrees about its hinge_axis), 0 when it has none.
func lid_deg(part: int) -> float:
	if not lids.has(part):
		return 0.0
	var c: Node3D = lids[part]
	return rad_to_deg(angle_about((c.get_node("Lid") as Node3D).basis, c.get_meta("hinge_axis")))


## The reading of the vehicle the player is in (CarDash.reading_of), or {} when it isn't this one any more (dark;
## the wheel straight): the dash shows it, the wheel turns to its steer.
func set_reading(r: Dictionary) -> void:
	var clean := CarDash.reading_of(r)
	if dash != null:
		dash.display(r)
	_spin_goal = clampf(-float(clean.steer) * WHEEL_RATIO, -WHEEL_MAX, WHEEL_MAX)
	moving = true


## How far the wheel is turned now (degrees about its z, positive to the left), as drawn.
func wheel_deg() -> float:
	return _spin_deg


## Moves what is on its way `delta` seconds on (the lids, the wheel, the needles), never what a hand holds; true while
## something still moves.
func step(delta: float) -> bool:
	var busy := false
	for part: int in lids:
		var c: Node3D = lids[part]
		var lid: Node3D = c.get_node("Lid")
		if lid.get_meta("held", false):
			continue
		var at := lid_deg(part)
		if absf(at - _lid_set.get(part, at)) > 0.05:
			_lid_goal[part] = at   # a hand moved it since: it stays there
		var goal: float = _lid_goal.get(part, 0.0)
		if absf(goal - at) > 0.05:
			at = move_toward(at, goal, LID_RATE * delta)
			lid.basis = Basis(c.get_meta("hinge_axis"), deg_to_rad(at))
			busy = busy or absf(goal - at) > 0.05
		_lid_set[part] = at
	if spin != null:
		if spin.get_meta("held", false):
			_spin_deg += wrapf(rad_to_deg(spin.rotation.z) - _spin_deg, -180.0, 180.0)   # where the hand left it
		elif _spin_deg != _spin_goal:
			_spin_deg = move_toward(_spin_deg, _spin_goal, WHEEL_RATE * delta)
			spin.rotation = Vector3(0.0, 0.0, deg_to_rad(_spin_deg))
			busy = busy or _spin_deg != _spin_goal
	if dash != null:
		busy = dash.step(delta) or busy
	return busy


## The signed angle (radians) basis `b`, a turn about `axis`, turns by.
static func angle_about(b: Basis, axis: Vector3) -> float:
	var a := axis.normalized()
	var u := a.cross(Vector3.UP) if absf(a.dot(Vector3.UP)) < 0.9 else a.cross(Vector3.RIGHT)
	u = u.normalized()
	var w := b * u
	return atan2(a.dot(u.cross(w)), u.dot(w))


## A frame leaning back `deg` from upright, facing the driver (behind it, -x): x to the right (+z), y up its face,
## z out of it toward the driver.
static func facing_driver(deg: float) -> Basis:
	var t := deg_to_rad(deg)
	return Basis(Vector3(0.0, 0.0, 1.0), Vector3(sin(t), cos(t), 0.0), Vector3(-cos(t), sin(t), 0.0))


func _add_controls(veh: Snapshot.Vehicle, part: int) -> void:
	var j := part * Snapshot.VPART_STRIDE
	var cell := Vector3(veh.parts[j], 0.0, veh.parts[j + 1])
	wheel = Node3D.new()
	wheel.name = "Wheel"
	wheel.transform = Transform3D(facing_driver(WHEEL_TILT), cell + WHEEL_AT)
	wheel.set_meta("radius_m", WHEEL_R)
	wheel.set_meta("part", part)
	spin = Node3D.new()
	spin.name = "WheelSpin"
	spin.set_meta("held", false)
	var mi := MeshInstance3D.new()
	mi.name = "wheel"
	mi.mesh = wheel_mesh()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = VIEW_M
	spin.add_child(mi)
	wheel.add_child(spin)
	add_child(wheel)
	dash = CarDash.new()
	dash.transform = Transform3D(facing_driver(DASH_TILT), cell + DASH_AT)
	dash.set_meta("part", part)
	add_child(dash)


## A lid on part `part` (a container of `kind`), hinged on the side toward the vehicle's middle `mid` (behind it: the
## lid's front edge; else its back edge).
func _add_lid(veh: Snapshot.Vehicle, part: int, kind: int, cdda_open: bool, mid: Vector3, col: Color) -> void:
	var j := part * Snapshot.VPART_STRIDE
	var h: float = LID_HALF[kind]
	var front := veh.parts[j] < mid.x   # behind the middle: hinged at its front
	var s := 1.0 if front else -1.0
	var c := Node3D.new()
	c.name = "Cargo_%d" % part
	c.position = Vector3(veh.parts[j], 0.0, veh.parts[j + 1])
	var axis := Vector3(0.0, 0.0, -s)
	c.set_meta("part", part)
	c.set_meta("square", veh.square(part))
	c.set_meta("hinge_axis", axis)
	c.set_meta("open_deg", LID_OPEN)
	c.set_meta("handle", Vector3(-s * (2.0 * h - 0.04), LID_T + 0.012, 0.0))   # in the Lid's frame
	c.set_meta("cdda_open", cdda_open)
	c.set_meta("opening", AABB(Vector3(-h, VehicleView.DECK, -h), Vector3(2.0 * h, LID_TOP - VehicleView.DECK, 2.0 * h)))
	c.set_meta("opening_out", Vector3.UP)
	var hole := []
	VehicleView._box(hole, Transform3D(Basis.from_scale(Vector3(2.0 * h - 0.08, 0.004, 2.0 * h - 0.08)),
			Vector3(0.0, LID_TOP + 0.002, 0.0)), OPENING)
	c.add_child(_mesh_node("opening", hole))
	var lid := Node3D.new()
	lid.name = "Lid"
	lid.position = Vector3(s * h, LID_TOP + 0.006, 0.0)
	lid.set_meta("held", false)
	var tris := []
	VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(2.0 * h, LID_T, 2.0 * h)),
			Vector3(-s * h, 0.5 * LID_T, 0.0)), col)
	VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(0.025, 0.018, 0.14)),
			Vector3(-s * (2.0 * h - 0.04), LID_T + 0.009, 0.0)), HANDLE)
	lid.add_child(_mesh_node("lid", tris))
	c.add_child(lid)
	add_child(c)
	lids[part] = c
	lid_at[Vector2i(veh.parts[j], veh.parts[j + 1])] = part
	_lid_goal[part] = 0.0
	_lid_set[part] = 0.0


## The door of glovebox part `part` (its "Cargo_<part>" on the dashboard's face behind the glovebox's square, at
## the floor): hinged at its bottom edge across the cell (hinge_axis +z), the top swinging toward the seat. CDDA
## doesn't open it (cdda_open false).
func _add_glovebox(veh: Snapshot.Vehicle, part: int, col: Color) -> void:
	var j := part * Snapshot.VPART_STRIDE
	var c := Node3D.new()
	c.name = "Cargo_%d" % part
	c.position = Vector3(veh.parts[j] - 1 + DASH_FACE, 0.0, veh.parts[j + 1])
	c.set_meta("part", part)
	c.set_meta("square", veh.square(part))
	c.set_meta("hinge_axis", Vector3(0.0, 0.0, 1.0))
	c.set_meta("open_deg", GLOVE_OPEN)
	c.set_meta("handle", Vector3(-0.012, GLOVE_H - 0.03, 0.0))   # in the Lid's frame
	c.set_meta("cdda_open", false)
	c.set_meta("opening", AABB(Vector3(0.0, GLOVE_Y, -0.5 * GLOVE_W), Vector3(0.5 - DASH_FACE, GLOVE_H, GLOVE_W)))
	c.set_meta("opening_out", Vector3(-1.0, 0.0, 0.0))
	var hole := []
	VehicleView._box(hole, Transform3D(Basis.from_scale(Vector3(0.004, GLOVE_H - 0.02, GLOVE_W - 0.02)),
			Vector3(-0.003, GLOVE_Y + 0.5 * GLOVE_H, 0.0)), OPENING)
	c.add_child(_mesh_node("opening", hole))
	var lid := Node3D.new()
	lid.name = "Lid"
	lid.position = Vector3(-GLOVE_T, GLOVE_Y, 0.0)
	lid.set_meta("held", false)
	var tris := []
	VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(GLOVE_T, GLOVE_H, GLOVE_W)),
			Vector3(0.5 * GLOVE_T, 0.5 * GLOVE_H, 0.0)), col)
	VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(0.012, 0.016, 0.1)),
			Vector3(-0.006, GLOVE_H - 0.03, 0.0)), HANDLE)
	lid.add_child(_mesh_node("lid", tris))
	c.add_child(lid)
	add_child(c)
	lids[part] = c
	lid_at[Vector2i(veh.parts[j], veh.parts[j + 1])] = part
	_lid_goal[part] = 0.0
	_lid_set[part] = 0.0


## The hood over engine bay `bay` (hood_of), in the body's paint: "Hood" (meta hinge_axis, open_deg, handle in the
## Lid's frame, cdda_open false) with its "Lid" on the hinge, the edge toward the middle `mid` (an engine ahead of
## the middle: its back edge, so the front lifts). Kept in `lids` under HOOD: open_lid / lid_deg / step move it.
func _add_hood(bay: AABB, mid: Vector3, col: Color) -> void:
	var c := bay.get_center()
	var s := 1.0 if c.x >= mid.x else -1.0
	var h := Node3D.new()
	h.name = "Hood"
	h.position = Vector3(c.x - s * 0.5 * bay.size.x, 0.0, c.z)   # the hinge line's middle, on the floor
	h.set_meta("hinge_axis", Vector3(0.0, 0.0, s))
	h.set_meta("open_deg", HOOD_OPEN)
	h.set_meta("handle", Vector3(s * (bay.size.x - 0.06), HOOD_T + 0.01, 0.0))
	h.set_meta("cdda_open", false)
	var lid := Node3D.new()
	lid.name = "Lid"
	lid.position = Vector3(0.0, bay.position.y, 0.0)
	lid.set_meta("held", false)
	var tris := []
	VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(bay.size.x - 0.04, HOOD_T, bay.size.z - 0.04)),
			Vector3(s * 0.5 * bay.size.x, 0.5 * HOOD_T, 0.0)), col)
	lid.add_child(_mesh_node("hood", tris))
	h.add_child(lid)
	add_child(h)
	lids[HOOD] = h
	_lid_goal[HOOD] = 0.0
	_lid_set[HOOD] = 0.0


static func _mesh_node(n: String, tris: Array) -> MeshInstance3D:
	var mesh := ArrayMesh.new()
	surface(mesh, tris, VehicleView._material(VehicleView.Look.SOLID))
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = VIEW_M
	return mi


## The steering wheel in its WheelSpin's frame (the rim round z, a hub, three spokes, a pale sleeve at the top),
## made once.
static func wheel_mesh() -> ArrayMesh:
	if _wheel_mesh == null:
		var tris := []
		torus(tris, Transform3D(), WHEEL_R, WHEEL_TUBE, 28, 8, WHEEL_COLOR)
		VehicleView._cylinder(tris, Transform3D(Basis(Vector3.RIGHT, PI / 2) * Basis.from_scale(Vector3(0.09, 0.035, 0.09)),
				Vector3(0.0, 0.0, -0.005)), WHEEL_COLOR)
		for deg: float in [0.0, 180.0, 270.0]:
			var a := deg_to_rad(deg)
			var mid := 0.5 * (0.04 + WHEEL_R)
			VehicleView._box(tris, Transform3D(Basis(Vector3.BACK, a) * Basis.from_scale(Vector3(WHEEL_R - 0.04, 0.028, 0.012)),
					Vector3(cos(a), sin(a), 0.0) * mid + Vector3(0.0, 0.0, -0.004)), WHEEL_COLOR)
		VehicleView._box(tris, Transform3D(Basis.from_scale(Vector3(0.035, 2.4 * WHEEL_TUBE, 2.4 * WHEEL_TUBE)),
				Vector3(0.0, WHEEL_R, 0.0)), WHEEL_MARK)
		_wheel_mesh = ArrayMesh.new()
		surface(_wheel_mesh, tris, VehicleView._material(VehicleView.Look.SOLID))
	return _wheel_mesh


## Adds triangles [a, b, c, normal, colour] (VehicleView._tri_n's) to `mesh` as one surface of material `mat`.
static func surface(mesh: ArrayMesh, tris: Array, mat: Material) -> void:
	if tris.is_empty():
		return
	var v := PackedVector3Array()
	var nr := PackedVector3Array()
	var cl := PackedColorArray()
	for t: Array in tris:
		v.append_array(PackedVector3Array([t[0], t[1], t[2]]))
		nr.append_array(PackedVector3Array([t[3], t[3], t[3]]))
		cl.append_array(PackedColorArray([t[4], t[4], t[4]]))
	var data := []
	data.resize(Mesh.ARRAY_MAX)
	data[Mesh.ARRAY_VERTEX] = v
	data[Mesh.ARRAY_NORMAL] = nr
	data[Mesh.ARRAY_COLOR] = cl
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
	if mat != null:
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


static func quad(tris: Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	tris.append(VehicleView._tri_n(a, b, c, n, col))
	tris.append(VehicleView._tri_n(a, c, d, n, col))


## A disc of radius r in xf's xy plane, facing its +z.
static func disk(tris: Array, xf: Transform3D, r: float, segs: int, col: Color) -> void:
	annulus(tris, xf, 0.0, r, 0.0, TAU, segs, col)


## A ring from radius r0 to r1 between angles a0 and a1 (radians, counterclockwise from x) in xf's xy plane, facing +z.
static func annulus(tris: Array, xf: Transform3D, r0: float, r1: float, a0: float, a1: float, segs: int, col: Color) -> void:
	var n := (xf.basis * Vector3.BACK).normalized()
	var k := maxi(1, ceili(segs * absf(a1 - a0) / TAU))
	for s in k:
		var b0 := lerpf(a0, a1, float(s) / k)
		var b1 := lerpf(a0, a1, float(s + 1) / k)
		var d0 := Vector3(cos(b0), sin(b0), 0.0)
		var d1 := Vector3(cos(b1), sin(b1), 0.0)
		if r0 <= 0.0:
			tris.append(VehicleView._tri_n(xf.origin, xf * (d0 * r1), xf * (d1 * r1), n, col))
		else:
			quad(tris, xf * (d0 * r0), xf * (d0 * r1), xf * (d1 * r1), xf * (d1 * r0), n, col)


## The side of a cylinder of radius r round xf's z, from z0 to z1, facing out (or in: `inward`).
static func tube(tris: Array, xf: Transform3D, r: float, z0: float, z1: float, segs: int, col: Color, inward: bool) -> void:
	for s in segs:
		var b0 := TAU * s / segs
		var b1 := TAU * (s + 1) / segs
		var d0 := Vector3(cos(b0), sin(b0), 0.0)
		var d1 := Vector3(cos(b1), sin(b1), 0.0)
		var mid := Vector3(cos(0.5 * (b0 + b1)), sin(0.5 * (b0 + b1)), 0.0)
		var n := (xf.basis * (-mid if inward else mid)).normalized()
		quad(tris, xf * (d0 * r + Vector3(0, 0, z0)), xf * (d1 * r + Vector3(0, 0, z0)), xf * (d1 * r + Vector3(0, 0, z1)),
				xf * (d0 * r + Vector3(0, 0, z1)), n, col)


## A ring of radius R and thickness r round xf's z (flat-shaded quads).
static func torus(tris: Array, xf: Transform3D, big: float, r: float, segs: int, sides: int, col: Color) -> void:
	for s in segs:
		var b0 := TAU * s / segs
		var b1 := TAU * (s + 1) / segs
		for t in sides:
			var c0 := TAU * t / sides
			var c1 := TAU * (t + 1) / sides
			var p := func(b: float, c: float) -> Vector3:
				var d := Vector3(cos(b), sin(b), 0.0)
				return xf * (d * (big + r * cos(c)) + Vector3(0.0, 0.0, r * sin(c)))
			var bm := 0.5 * (b0 + b1)
			var cm := 0.5 * (c0 + c1)
			var n := (xf.basis * (Vector3(cos(bm), sin(bm), 0.0) * cos(cm) + Vector3(0.0, 0.0, sin(cm)))).normalized()
			quad(tris, p.call(b0, c0), p.call(b1, c0), p.call(b1, c1), p.call(b0, c1), n, col)
