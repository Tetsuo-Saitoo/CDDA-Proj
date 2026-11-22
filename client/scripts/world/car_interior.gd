class_name CarInterior
extends Node3D
## C5 interiors: what a vehicle near the camera shows inside beyond its baked body (VehicleView builds one for each
## vehicle within INTERIOR_NEAR, a child of its node, so in its mount grid: x ahead, z to the right, a cell per square
## on its floor). From CDDA's own parts: at the first controls drawn, the steering wheel (turned by how far CDDA
## steers) and the instrument cluster (CarDash); on each lockable, covered container drawn as a box or a half board
## (has_lid: trunks, boxes, a bin), a hinged lid over a dark opening, hinged on the side toward the vehicle's middle.
## No contents yet. lead-vr's anchors (anchors()): "Wheel" with "WheelSpin" (spins about its local z; meta radius_m,
## part), "Dash", "Cargo_<part>" with "Lid" (the pivot on the hinge; meta part, square, hinge_axis, open_deg, handle,
## cdda_open). Nothing here moves a WheelSpin or Lid whose meta "held" is true (a VR hand has it). A lid of a part
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
## ...]]: each unbroken container with a lid drawn as a box or a half board, one per square, at most MAX_LIDS.
## Parts above `z_max` and gap fillers are left out.
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
	return [controls, out]


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
	return key


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
		var def := VehicleView.def_of(tables, snap, veh.parts[j + 2])
		var col := paint if e[1] == VehicleView.Kind.HALF else VehicleView.color_of(e[1], def, veh.parts[j + 3], veh.parts[j + 4])
		it._add_lid(veh, e[0], e[1], def != null and def.flags.has("OPENABLE"), mid, col)
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
