class_name VehicleView
extends Node3D
## Block C5 (PLAN.md): CDDA's vehicles (Snapshot.vehicles). Each vehicle is a node of its own (Car) holding one mesh
## built in the vehicle's own grid (slice 2: one body, hull_of: a floor under every cell, walls up to the sill where
## boards, doors and windows are, opaque panels or glass panes above, the roof; outer corners cut so it reads rounded;
## one paint, each cell worn as its part; the small parts baked in: wheels on the outside, seats, engine, lights,
## open doors, ... each kind (Kind) from the vpart's flags and location). The mesh is built again only when the
## vehicle's parts or the cutaway change; driving and turning move the node only (slice 3): its pose (pose_of: one
## rigid model turned by CDDA's own facing, face_deg, and fitted onto the parts' squares, since CDDA turns about a
## pivot; tilted to the ground under it on a ramp) glides from where it is drawn to the new one over about as long
## as the vehicle took between snapshots, so a driven car turns and moves smoothly; seat_transform carries what is
## on it (the eyes, the body, creatures) to its cell as drawn. CDDA lays a turned vehicle out stretched and sheared
## (vehicle::coord_translate); the model isn't, so off the axes a cell can be drawn up to most of a square off its part's square
## (more at a long vehicle's ends near 45 degrees). That is presentation only: what blocks walking (blocks), which
## part a ray meets at a height (part_at) and what items rest on (rest_at) stay per square, exactly CDDA's (shapes:
## the heights of each kind), for walking, LookRay and the item physics. CDDA's gap fillers
## (Snapshot.VPART_FILLER) only block. Real models and doors by hand are later slices.
## Interiors (CarInterior): seats with a back and headrest, a dashboard across the front row (baked); for vehicles
## near the camera the steering wheel, the instrument cluster (CarDash) and lids on the containers, lead-vr's anchors
## (interior()); only the vehicle the player is in comes alive (set_ride). C6 vehicle work: where a part is
## (part_anchor, work_pose: PartSpot) and a tint over the selected one (highlight).

## DASH: not a part's kind; the dashboard in front of a seat beside the controls.
enum Kind { NONE, FRAME, BOARD, HALF, DOOR, GLASS_DOOR, DOOR_OPEN, WINDOW, ROOF, WHEEL, SEAT, ENGINE, TANK, CARGO,
		LIGHT, ROOF_LIGHT, TURRET, CONTROLS, OTHER, DASH }
enum Look { SOLID, GLASS, WHEEL }

const DECK := 0.55     # metres above the square's floor: top of the frame, the floor inside
const TOP := 2.0       # top of the walls: taller than a real car, so the eyes (1.6 m) fit under the roof
const ROOF_T := 0.1
const SILL := 1.05     # glass starts here
const MAX_PER_LOOK := 1 << 17
const CLEAR := 0.25    # the body's underside above the ground
const CHAMFER := 0.3   # how much of a cell the cut at a body's outer corner takes
const WHEEL_OUT := 0.3 # a wheel on the body's side sits this far out from its cell's centre
const WHEEL_SIDES := 10
const MAX_HULL_VERTS := 1 << 20   # per vehicle and look (solid, glass)
const MAX_VERTS := 1 << 21        # all vehicles together: past it the rest aren't built (until there's room)
const GLIDE_MIN := 0.1  # s: the shortest and longest glide from one pose to the next
const GLIDE_MAX := 1.0
const GLIDE_FAR := 60.0 # m: a longer jump (a teleport, the map loaded again) is shown at once
const GLIDE_VIEW_M := 150.0   # m: a vehicle this far from the camera or further skips its glide (out of view)
const MAX_SLOPE := 1.0  # tan of the steepest tilt on a ramp (45 degrees)
## Marks (off_squares): where CDDA really has a turned vehicle that its rigid model doesn't line up with, a
## translucent yellow block per square, and a warning sign in those the drawn body leaves bare (shaders/vehicle_mark,
## warning_sign), so its real footprint shows against walls. Hidden for the vehicle the player sits in, in first
## person (hide_marks).
const MARK_TOL := 0.25    # m: a cell drawn this far or further off its part's square marks that square
const MARK_BODY := 0.5    # m: a square with a cell drawn closer to its middle is under the drawn body (no sign)
const MARK_H := 1.6       # m: a block's height above the ground
const MARK_SIGN := 0.45   # m across: the sign
const MARK_SIGN_UP := 0.9   # m: the sign's middle above the ground (in a bare square: no body around it)
const MAX_MARKS := 1024   # squares marked per vehicle
const MARK_SHADER := preload("res://shaders/vehicle_mark.gdshader")
const SIGN_SHADER := preload("res://shaders/warning_sign.gdshader")
## Kinds drawn as the body (hull), not as shapes of their own.
const HULL_KINDS := [Kind.FRAME, Kind.BOARD, Kind.HALF, Kind.DOOR, Kind.GLASS_DOOR, Kind.WINDOW, Kind.ROOF]
## A cell's corners (x ahead, y right, cell units from its centre), counterclockwise; edge j runs from corner j to
## j + 1 and borders the neighbouring cell at _EDGE_NEXT[j].
const _CORNERS := [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]
const _EDGE_NEXT := [Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0)]
## A unit cube's faces: outward normal, then its corners (±0.5).
const _BOX_FACES := [
	[Vector3.RIGHT, Vector3(0.5, -0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, -0.5, 0.5)],
	[Vector3.LEFT, Vector3(-0.5, -0.5, -0.5), Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, 0.5, 0.5), Vector3(-0.5, 0.5, -0.5)],
	[Vector3.UP, Vector3(-0.5, 0.5, -0.5), Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5)],
	[Vector3.DOWN, Vector3(-0.5, -0.5, -0.5), Vector3(0.5, -0.5, -0.5), Vector3(0.5, -0.5, 0.5), Vector3(-0.5, -0.5, 0.5)],
	[Vector3.BACK, Vector3(-0.5, -0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5)],
	[Vector3.FORWARD, Vector3(-0.5, -0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, -0.5, -0.5)],
]
const DEFAULT_COLOR := Color(0.55, 0.56, 0.58)
const TYRE := Color(0.1, 0.1, 0.11)
const GLASS := Color(0.62, 0.8, 0.9, 0.3)
const RUST := Color(0.45, 0.26, 0.14)
const CHAR := Color(0.12, 0.11, 0.1)
const LIT := Color(1.0, 0.95, 0.75)
const DASH_COLOR := Color(0.16, 0.16, 0.17)   # the dashboard (controls), whatever CDDA's colour
const HIGHLIGHT := Color(1.0, 0.78, 0.2, 0.3)  # C6: the tint over the part the work view has selected
const INTERIOR_NEAR := 20.0   # m: a vehicle this near the camera gets its interior (CarInterior)
const INTERIOR_FAR := 30.0    # and loses it this far
const INTERIOR_BUILDS := 2    # interiors built per frame at most
const MAX_NAME := 60
const LIGHT_FLAGS := ["CONE_LIGHT", "WIDE_CONE_LIGHT", "HALF_CIRCLE_LIGHT", "CIRCLE_LIGHT"]
## How high an item lies on a part of each kind that doesn't block (m above the floor); kinds not listed add nothing.
const REST := {Kind.FRAME: DECK, Kind.HALF: SILL, Kind.WHEEL: 0.8, Kind.TANK: 0.25, Kind.SEAT: DECK + 0.45,
		Kind.CARGO: DECK + 0.5, Kind.ENGINE: DECK + 0.6, Kind.OTHER: DECK + 0.5}


## One vehicle as drawn: its node (null while nothing of it is drawn), its mesh's data in its mount grid (a cell per
## square), and its glide from pose `from` to `to` (t 0..1 over dur seconds). A pose is [turn (a rotation: facing and
## lean), grid (the mount grid in the turned frame: one square per cell), origin]; `to` composed is `to_xf`.
class Car:
	var node: Node3D
	var veh: Snapshot.Vehicle  # the snapshot's, last applied
	var mid := Vector3.ZERO    # the middle of its cells (mount grid, on the floor)
	var key: Array = []      # what the mesh was built from
	var pose_key: Array = [] # what `to` was worked out from
	var local := {}          # Look (SOLID, GLASS) -> [vertices, normals, colours], the mount grid
	var small := {}          # Look -> [[Transform3D, Color], ...]: the small parts, the mount grid
	var from: Array = [Basis(), Basis(), Vector3.ZERO]
	var to: Array = [Basis(), Basis(), Vector3.ZERO]
	var to_xf := Transform3D()
	var t := 1.0
	var dur := GLIDE_MIN
	var moved_ms := 0
	var verts := 0           # vertices in its mesh
	var marked: Array = []   # off_squares at its pose (Vector3i)
	var signed: Array = []   # those the drawn body leaves bare: a sign in each
	var marks: Node3D        # their blocks and signs (two MultiMeshInstance3D); null while none
	var paint := DEFAULT_COLOR   # its body's colour
	var interior: CarInterior    # a child of node while near the camera (interiors()); null else
	var spots: Variant = null    # PartSpot.anchors of veh (mount grid), worked out when first asked; null: not yet
	var hidden: Array = []       # [mount, vpart] of the part a hand carries a copy of (hide_part): not drawn; []: none


var view_z_max := CddaCoords.Z_LIMIT   # levels above are hidden: WorldView.things_z_max() (main.gd, refresh)
var _world: WorldView = null   # the world last applied (refresh follows its cutaway)
var _cars := {}        # vehicle uid -> Car, the shown snapshot's vehicles in its order
var built := 0         # meshes built (not kept from the last snapshot), counted for tests
var max_verts := MAX_VERTS   # lowered by tests
var _marks_hidden := {}   # uid -> true: vehicles whose marks are hidden (hide_marks)
const MARK_HEAD_NEAR := 30.0   # m: hide_marks looks for the head in the models of vehicles this near it
static var _mark_mats := []    # [block, sign] ShaderMaterial, made once
var _snap: Snapshot = null     # the snapshot last applied
var _ride_uid := 0             # the vehicle the player is in (set_ride), 0 none
var _ride := {}                # its dash reading
var _highlight := []           # [uid, row] highlighted (C6, highlight()), [] none
var _lit: MeshInstance3D       # its tint, a child of that vehicle's node; null while none is drawn
static var _lit_material: Material
static var _shapes := {}       # Kind -> [[Look, AABB], ...], made once
static var _mats := {}         # Look -> Material


func _init() -> void:
	name = "Vehicles"


## Small parts drawn after the last apply: all of them, or one look's (SOLID, WHEEL).
func count(look := -1) -> int:
	var n := 0
	for car: Car in _cars.values():
		for k: int in car.small:
			n += (car.small[k] as Array).size() if look < 0 or k == look else 0
	return n


## The small parts of one look where the last snapshot puts them: [[transform, colour], ...], world space.
func instances(look: int) -> Array:
	var out := []
	for car: Car in _cars.values():
		for e: Array in car.small.get(look, []):
			out.append([car.to_xf * (e[0] as Transform3D), e[1]])
	return out


## The bodies of one look (SOLID, GLASS) where the last snapshot puts them: [vertices, normals, colours], three per
## triangle, world space (worked out when asked: for tests and checks).
func hull(look: int) -> Array:
	var v := PackedVector3Array()
	var nr := PackedVector3Array()
	var cl := PackedColorArray()
	for car: Car in _cars.values():
		var arrs: Array = car.local.get(look, [])
		if arrs.is_empty():
			continue
		var nb := car.to_xf.basis.inverse().transposed()   # normals under a sheared grid
		for p: Vector3 in arrs[0]:
			v.append(car.to_xf * p)
		for n: Vector3 in arrs[1]:
			nr.append((nb * n).normalized())
		cl.append_array(arrs[2])
	return [v, nr, cl]


## Where vehicle `uid` is drawn now (its node, mid-glide or not); null transform if it isn't drawn.
func drawn(uid: int) -> Variant:
	var car: Car = _cars.get(uid)
	return car.node.transform if car != null and car.node != null else null


## Where the snapshot puts vehicle `uid` (its pose once the glide has arrived); null transform if it isn't drawn.
func target_of(uid: int) -> Variant:
	var car: Car = _cars.get(uid)
	return car.to_xf if car != null and car.node != null else null


## seat_transform for the player's square: what the camera and the body add to ride along.
func ride_transform(snap: Snapshot) -> Transform3D:
	return seat_transform(snap, snap.player_pos) if snap != null else Transform3D()


## What carries something on square `sq` of a vehicle to where that vehicle is drawn now: from the square as the
## snapshot has it (its floor centre, ms_center_to_world) to the vehicle's cell on it as drawn, mid-glide or not,
## turned by the turn still to go (none once arrived). Identity where no vehicle is drawn on `sq`.
func seat_transform(snap: Snapshot, sq: Vector3i) -> Transform3D:
	if snap == null or _world == null or not is_instance_valid(_world):
		return Transform3D()
	var at := snap.vehicle_at(sq)
	var car: Car = _cars.get((at[0] as Snapshot.Vehicle).uid) if not at.is_empty() else null
	if car == null or car.node == null:
		return Transform3D()
	var veh: Snapshot.Vehicle = at[0]
	var idx: PackedInt32Array = at[1]
	var j := idx[0] * Snapshot.VPART_STRIDE
	for i: int in idx:   # a part of its own before a gap filler
		if veh.parts[i * Snapshot.VPART_STRIDE + 4] & Snapshot.VPART_FILLER == 0:
			j = i * Snapshot.VPART_STRIDE
			break
	var drawn := car.node.transform
	var cell := drawn * Vector3(veh.parts[j], 0.0, veh.parts[j + 1])
	var turn := drawn.basis.orthonormalized() * car.to_xf.basis.orthonormalized().inverse()
	var xf := Transform3D(turn, cell - turn * _world.coords.ms_center_to_world(sq))
	return xf if xf.is_finite() else Transform3D()


## The vehicle the player is on as drawn now, for a camera following it (ViewCamera's chase): its turn (x ahead) at
## the middle of its cells on its floor; null when the player isn't on a drawn vehicle.
func chase_target(snap: Snapshot) -> Variant:
	var at := snap.vehicle_at(snap.player_pos) if snap != null else []
	var car: Car = _cars.get((at[0] as Snapshot.Vehicle).uid) if not at.is_empty() else null
	if car == null or car.node == null:
		return null
	var xf := Transform3D(car.node.transform.basis.orthonormalized(), car.node.transform * car.mid)
	return xf if xf.is_finite() else null


## The middle of a vehicle's own cells (not its gap fillers), in its mount grid on the floor.
static func _mid(veh: Snapshot.Vehicle) -> Vector3:
	var sum := Vector2.ZERO
	var n := 0
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j + 4] & Snapshot.VPART_FILLER == 0:
			sum += Vector2(veh.parts[j], veh.parts[j + 1])
			n += 1
	return Vector3(sum.x / n, 0.0, sum.y / n) if n > 0 else Vector3.ZERO


## The square of vehicle `uid` whose cell, as drawn now, holds world point p (x and z; its mount rounded): a
## Vector3i, or null where none of its parts is or it isn't drawn.
func square_at(uid: int, p: Vector3) -> Variant:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or car.veh == null or not p.is_finite():
		return null
	var local := car.node.transform.affine_inverse() * p
	var m := Vector2i(roundi(local.x), roundi(local.z))
	var veh := car.veh
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j] == m.x and veh.parts[j + 1] == m.y and veh.parts[j + 4] & Snapshot.VPART_FILLER == 0:
			return veh.square(i)
	return null


func apply(snap: Snapshot, world: WorldView) -> void:
	_world = world
	_snap = snap
	var now := Time.get_ticks_msec()
	var cars := {}
	var total := 0   # vertices of the vehicles drawn so far
	if snap != null:
		for veh in snap.vehicles:
			var car: Car = _cars.get(veh.uid)
			var fresh := car == null
			if fresh:
				car = Car.new()
				car.moved_ms = now
			if not car.hidden.is_empty() and PartCopy.row_of(veh, car.hidden) < 0:
				car.hidden = []   # no longer on the vehicle (CDDA removed it): nothing left to hide
			var key := _key_of(veh, snap, world, car.hidden)
			if car.key == key and total >= max_verts:
				_drop(car)   # kept, but no room for it now: built again when there is
			if car.key != key and total < max_verts:
				var look := _vehicle(veh, snap, world, car.hidden)
				car.key = key
				car.local = look[0]
				car.small = look[1]
				car.paint = look[2]
				_mesh(car)
				built += 1
			total += car.verts if car.key == key else 0
			var pose_key := [veh.pos, veh.face_deg, veh.parts, world.coords.origin_ms]
			if fresh or car.pose_key != pose_key:
				car.pose_key = pose_key
				_move(car, pose_parts(veh, world), now, fresh)
				var body := {}
				car.marked = off_squares(veh, car.to_xf, world.coords, body)
				car.signed = car.marked.filter(func(sq: Vector3i) -> bool: return not body.has(sq))
				_mark(car, world)
			car.veh = veh
			car.spots = null
			car.mid = _mid(veh)
			cars[veh.uid] = car
			_show_marks(car)
			_check_interior(car, snap, world)
			_hide_inside(car)
	for uid: int in _cars:
		if not cars.has(uid):
			var gone: Car = _cars[uid]
			if gone.node != null:
				gone.node.free()
			if gone.marks != null:
				gone.marks.free()
	_cars = cars
	if not _highlight.is_empty() or _lit != null:
		_place_highlight()   # its vehicle may be built again, its parts moved or gone


## Frees what a vehicle draws and forgets what it was built from.
func _drop(car: Car) -> void:
	if car.node != null:
		car.node.free()
		car.node = null
	car.interior = null   # freed with its node
	car.key = []
	car.local = {}
	car.small = {}
	car.verts = 0


## The squares of `veh` where its model posed by `xf` (mount -> world) doesn't line up with CDDA: a square its own
## part's cell is drawn MARK_TOL or more off (level distance), or one no cell is drawn within MARK_TOL of (a gap
## filler's). None at right angles, where the model is on its squares. In part order, each once, at most MAX_MARKS.
## `body` gets the squares with a cell drawn within MARK_BODY of their middle (under the drawn body).
static func off_squares(veh: Snapshot.Vehicle, xf: Transform3D, coords: CddaCoords, body := {}) -> Array:
	var r := fposmod(veh.face_deg, 90.0) if is_finite(veh.face_deg) else 0.0
	if r < 0.01 or r > 89.99:
		return []
	var near := {}   # squares a cell is drawn within MARK_TOL of
	var off := {}    # squares whose own part's cell is drawn off them
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j + 4] & Snapshot.VPART_FILLER != 0:
			continue
		var sq := veh.square(i)
		var cell := xf * Vector3(veh.parts[j], 0.0, veh.parts[j + 1])
		if not cell.is_finite():
			continue
		var c := coords.ms_center_to_world(sq)
		if Vector2(cell.x - c.x, cell.z - c.z).length() >= MARK_TOL:
			off[sq] = true
		var under := coords.world_to_ms(Vector3(cell.x, 0.0, cell.z))
		under.z = sq.z
		var uc := coords.ms_center_to_world(under)
		var d := Vector2(cell.x - uc.x, cell.z - uc.z).length()
		if d < MARK_TOL:
			near[under] = true
		if d < MARK_BODY:
			body[under] = true
	var out := []
	var seen := {}
	for i in veh.part_count():
		var sq := veh.square(i)
		if seen.has(sq):
			continue
		seen[sq] = true
		if off.has(sq) or not near.has(sq):
			out.append(sq)
			if out.size() >= MAX_MARKS:
				break
	return out


## Draws car.marked: a block per square on the ground there, a sign in each of car.signed (none: its marks freed).
func _mark(car: Car, world: WorldView) -> void:
	if car.marked.is_empty():
		if car.marks != null:
			car.marks.free()
			car.marks = null
		return
	if car.marks == null:
		car.marks = Node3D.new()
		car.marks.name = "marks"
		add_child(car.marks)
		var box := BoxMesh.new()
		box.size = Vector3(0.96 * CddaCoords.TILE_M, MARK_H, 0.96 * CddaCoords.TILE_M)
		var quad := QuadMesh.new()
		quad.size = Vector2(MARK_SIGN, MARK_SIGN)
		var mats := _mark_materials()
		for e: Array in [[box, mats[0]], [quad, mats[1]]]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = e[0]
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.material_override = e[1]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			mi.extra_cull_margin = MARK_SIGN
			car.marks.add_child(mi)
	car.marks.position = Vector3.ZERO
	var blocks := (car.marks.get_child(0) as MultiMeshInstance3D).multimesh
	var signs := (car.marks.get_child(1) as MultiMeshInstance3D).multimesh
	blocks.instance_count = car.marked.size()
	signs.instance_count = car.signed.size()
	for i in car.marked.size():
		var at := mark_base(world, car.marked[i])
		blocks.set_instance_transform(i, Transform3D(Basis(), at + Vector3.UP * (0.02 + MARK_H * 0.5)))
	for i in car.signed.size():
		signs.set_instance_transform(i, Transform3D(Basis(), mark_base(world, car.signed[i]) + Vector3.UP * MARK_SIGN_UP))


## Where a mark on square `sq` stands: its middle on the ground there (the level's floor where there's none).
static func mark_base(world: WorldView, sq: Vector3i) -> Vector3:
	var c := world.coords.ms_center_to_world(sq)
	var g := world.ground_y(c, sq.z)
	return Vector3(c.x, g if is_finite(g) else c.y, c.z)


## The marks' materials (block, sign), made once; the sign drawn after the block.
static func _mark_materials() -> Array:
	if _mark_mats.is_empty():
		var block := ShaderMaterial.new()
		block.shader = MARK_SHADER
		block.set_shader_parameter("height", MARK_H)
		var sign := ShaderMaterial.new()
		sign.shader = SIGN_SHADER
		sign.render_priority = 1
		_mark_mats = [block, sign]
	return _mark_mats


## Hides the marks of vehicle `uid` (0: none) and of any vehicle whose drawn model holds point `head` (VR: the
## head may be away from the player's square; square_at), showing the others' again.
func hide_marks(uid: int, head := Vector3.INF) -> void:
	var hidden := {}
	if uid != 0:
		hidden[uid] = true
	if head.is_finite():
		for car: Car in _cars.values():
			if car.marks != null and car.node != null and car.veh != null 					and car.node.position.distance_to(head) < MARK_HEAD_NEAR and square_at(car.veh.uid, head) != null:
				hidden[car.veh.uid] = true
	if hidden == _marks_hidden:
		return
	_marks_hidden = hidden
	for car: Car in _cars.values():
		_show_marks(car)


func _show_marks(car: Car) -> void:
	if car.marks != null:
		car.marks.visible = car.node != null and car.veh != null and not _marks_hidden.has(car.veh.uid)


## VR: the marks' signs stand upright, turned by yaw only (flat: they also tilt toward the camera).
static func signs_upright(on: bool) -> void:
	(_mark_materials()[1] as ShaderMaterial).set_shader_parameter("upright", on)


## lead-vr's anchors in vehicle `uid` (CarInterior.anchors: "Wheel", "Dash", "Cargo_<part>" -> Node3D, children of
## its drawn model); {} while it has no interior (not drawn, or not near the camera).
func interior(uid: int) -> Dictionary:
	var car: Car = _cars.get(uid)
	return car.interior.anchors() if car != null and car.interior != null and is_instance_valid(car.interior) else {}


## The vehicle the player is in (0: none) and its dash reading (CarDash.reading_of; main.gd, each snapshot): only
## its dash and wheel come alive. The one before goes dark, its wheel straight.
func set_ride(uid: int, reading: Dictionary) -> void:
	var clean := CarDash.reading_of(reading) if uid != 0 else {}
	if uid == _ride_uid and clean == _ride:
		return
	if uid != _ride_uid:
		var old: Car = _cars.get(_ride_uid)
		if old != null and old.interior != null and is_instance_valid(old.interior):
			old.interior.set_reading({})
	_ride_uid = uid
	_ride = clean
	var car: Car = _cars.get(uid)
	if car != null and car.interior != null and is_instance_valid(car.interior):
		car.interior.set_reading(_ride)


## Opens or closes the lid over part `part` of vehicle `uid` (the one on its square; CarInterior.open_lid) on the
## client: false when none is drawn there.
func open_lid(uid: int, part: int, open: bool) -> bool:
	var car: Car = _cars.get(uid)
	if car == null or car.veh == null or car.interior == null or not is_instance_valid(car.interior) \
			or part < 0 or part >= car.veh.part_count():
		return false
	var j := part * Snapshot.VPART_STRIDE
	var lid: int = car.interior.lid_at.get(Vector2i(car.veh.parts[j], car.veh.parts[j + 1]), -1)
	return lid >= 0 and car.interior.open_lid(lid, open)


## C6 (lead-ui's work view): part `row` of vehicle `uid` as drawn now (PartSpot.anchor): {point, normal (unit),
## size (m)} in the world; {} when the vehicle isn't drawn or the row is no part of its own.
func part_anchor(uid: int, row: int) -> Dictionary:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or car.veh == null or _world == null or not is_instance_valid(_world):
		return {}
	var a: Dictionary = _spots(car).get(row, {})
	return _in_world(a, car.node.global_transform) if not a.is_empty() else {}


## part_anchor for every part of vehicle `uid`: {row: {point, normal, size}} in the world; {} when it isn't drawn.
## Worked out once per snapshot in its mount grid, only carried to where it is drawn now per call (VR hands, often).
func part_anchors(uid: int) -> Dictionary:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or car.veh == null or _world == null or not is_instance_valid(_world):
		return {}
	var xf := car.node.global_transform
	var out := {}
	var spots := _spots(car)
	for row: int in spots:
		out[row] = _in_world(spots[row], xf)
	return out


func _spots(car: Car) -> Dictionary:
	if car.spots == null:
		car.spots = PartSpot.anchors(car.veh, _snap, _world.tables)
	return car.spots


static func _in_world(a: Dictionary, xf: Transform3D) -> Dictionary:
	return {"point": xf * (a["point"] as Vector3), "normal": (xf.basis * (a["normal"] as Vector3)).normalized(),
			"size": a["size"]}


## Where the work camera (WorkCamera) stands for `what` ("part" with `row`, or one of PartSpot.VIEWS): [eye, at,
## exit] in vehicle `uid`'s mount grid (PartSpot.work_pose; drawn() carries it to the world); [] when it isn't drawn
## or there's nothing to see.
func work_pose(uid: int, what: String, row := -1) -> Array:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or _world == null or not is_instance_valid(_world):
		return []
	return PartSpot.work_pose(car.veh, _snap, _world.tables, what, row)


## work_pose for square `mount` of vehicle `uid` (C6 install mode; PartSpot.square_pose).
func work_square_pose(uid: int, mount: Vector2i) -> Array:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null:
		return []
	return PartSpot.square_pose(car.veh, mount)


## C6: shows part `row` of vehicle `uid` (a see-through tint over where it is drawn, seen through what is in front
## of it; it follows the vehicle and is placed again with each snapshot); -1: none. One highlight: this and
## highlight_square replace each other.
func highlight(uid: int, row: int) -> void:
	_highlight = [uid, row] if row >= 0 else []
	_place_highlight()


## C6 install mode: shows square `mount` of vehicle `uid` (its mount grid; it may hold no part yet, as beside the
## vehicle), from the floor to the roof line; with `vpart` (a vpart id-table index: the type about to be installed)
## that part's shapes on the square instead (PartCopy). Vector2i.MAX: none.
func highlight_square(uid: int, mount: Vector2i, vpart := -1) -> void:
	_highlight = [uid, mount, vpart] if mount != Vector2i.MAX and PartSpot.near_enough(mount) else []
	_place_highlight()


## C6: opens or closes the hood over vehicle `uid`'s engine bay (CarInterior.hood_of; the client's own); false when
## none is drawn (no open bay, or the vehicle is too far for its interior).
func open_hood(uid: int, open: bool) -> bool:
	var car: Car = _cars.get(uid)
	if car == null or car.interior == null or not is_instance_valid(car.interior):
		return false
	return car.interior.open_lid(CarInterior.HOOD, open)


## C6 (lead-vr's hands): a copy of part `row` of vehicle `uid` as drawn (PartCopy) to carry: a new node, not in the
## tree, its origin at the part's anchor point (part_anchors), placed where the part is in the world now (as a child
## of the root); the caller frees it. null when the vehicle isn't drawn or the row is no part of its own.
func part_copy(uid: int, row: int) -> Node3D:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or car.veh == null or _world == null or not is_instance_valid(_world):
		return null
	var a: Dictionary = _spots(car).get(row, {})
	if a.is_empty():
		return null
	var j := row * Snapshot.VPART_STRIDE
	var by_look := PartCopy.boxes(def_of(_world.tables, _snap, car.veh.parts[j + 2]), car.veh.parts[j + 3],
			car.veh.parts[j + 4], PartSpot.cells_of(car.veh), a["cell"])
	var n := PartCopy.node_of(by_look, a["point"])
	n.transform = car.node.global_transform * Transform3D(Basis(), a["point"])
	return n


## C6 (lead-vr, install mode): a copy of a part of type `vpart` (a vpart id-table index) on no vehicle, whole: a new
## node, not in the tree, its origin at its middle, facing as on a vehicle heading along +x; the caller frees it.
## null for a type the tables don't hold.
func part_copy_of(vpart: int) -> Node3D:
	if _world == null or not is_instance_valid(_world):
		return null
	var def := def_of(_world.tables, _snap, vpart)
	if def == null:
		return null
	var by_look := PartCopy.boxes(def, 255, 0, {}, Vector2i.ZERO)
	return PartCopy.node_of(by_look, PartCopy.bounds(by_look).get_center())


## C6 (lead-vr's hands): hides part `row` of vehicle `uid` where it is drawn (in its vehicle's mesh, and its node in
## the interior: a lid, the controls' wheel and dash) while a hand carries its copy (part_copy), or shows it again.
## One part a vehicle. Kept with each snapshot by its square and type (rows move) until a snapshot no longer has it
## (CDDA removed it) or the vehicle goes. Row -1 with `hidden` false shows whatever is hidden on it (a caller whose
## row has moved since). False when the vehicle isn't drawn or the row is no part of its own.
func hide_part(uid: int, row: int, hidden: bool) -> bool:
	var car: Car = _cars.get(uid)
	if car == null or car.veh == null or _snap == null or _world == null or not is_instance_valid(_world):
		return false
	var want: Array = []
	if row != -1 or hidden:
		if row < 0 or row >= car.veh.part_count():
			return false
		var j := row * Snapshot.VPART_STRIDE
		if car.veh.parts[j + 4] & Snapshot.VPART_FILLER != 0:
			return false
		var which := [Vector2i(car.veh.parts[j], car.veh.parts[j + 1]), car.veh.parts[j + 2]]
		want = which if hidden else ([] if car.hidden == which else car.hidden)
	if want != car.hidden:
		car.hidden = want
		var look := _vehicle(car.veh, _snap, _world, car.hidden)
		car.key = _key_of(car.veh, _snap, _world, car.hidden)
		car.local = look[0]
		car.small = look[1]
		car.paint = look[2]
		_mesh(car)
		_hide_inside(car)
	return true


## C6 (lead-vr, install mode): the square of vehicle `uid`'s mount grid under world point `p` (x and z rounded in its
## frame as drawn now), also beside it where no part is yet; Vector2i.MAX when it isn't drawn or the square is out of
## reach (PartSpot.near_enough).
func mount_at(uid: int, p: Vector3) -> Vector2i:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or not p.is_finite():
		return Vector2i.MAX
	var l := car.node.global_transform.affine_inverse() * p
	if not l.is_finite() or absf(l.x) > PartSpot.MAX_MOUNT + 1.0 or absf(l.z) > PartSpot.MAX_MOUNT + 1.0:
		return Vector2i.MAX
	var m := Vector2i(roundi(l.x), roundi(l.z))
	return m if PartSpot.near_enough(m) else Vector2i.MAX


## What a vehicle's mesh is built from: built again when it changes.
func _key_of(veh: Snapshot.Vehicle, snap: Snapshot, world: WorldView, hidden: Array) -> Array:
	return [veh.parts, veh.pos.z, view_z_max, world.tables, snap.ids_generation, hidden]


## The interior's nodes of the part a hand carries (hide_part) hidden, the rest shown.
func _hide_inside(car: Car) -> void:
	if car.interior == null or not is_instance_valid(car.interior) or car.veh == null:
		return
	var row := PartCopy.row_of(car.veh, car.hidden) if not car.hidden.is_empty() else -1
	for n: Variant in car.interior.anchors().values():
		if n is Node3D and (n as Node3D).has_meta("part"):
			(n as Node3D).visible = row < 0 or (n as Node3D).get_meta("part") != row


func _place_highlight() -> void:
	if is_instance_valid(_lit):
		if _lit.get_parent() != null:
			_lit.get_parent().remove_child(_lit)
		_lit.queue_free()
	_lit = null
	if _highlight.is_empty():
		return
	var car: Car = _cars.get(_highlight[0])
	if car == null or car.node == null or _world == null or not is_instance_valid(_world):
		return
	var mesh: Mesh = null
	var at := Vector3.ZERO
	var def: IdTables.Def = def_of(_world.tables, _snap, _highlight[2]) if _highlight.size() > 2 and _highlight[2] >= 0 \
			else null
	if def != null:   # the part about to be installed, on its square
		mesh = PartCopy.mesh_of(PartCopy.boxes(def, 255, 0, PartSpot.cells_of(car.veh), _highlight[1]), Vector3.ZERO,
				_highlight_material())
	else:
		var a := PartSpot.square_anchor(car.veh, _highlight[1]) if _highlight[1] is Vector2i \
				else PartSpot.anchor(car.veh, _snap, _world.tables, _highlight[1])
		if a.is_empty():
			return
		var box: AABB = (a["box"] as AABB).grow(0.03)
		var bm := BoxMesh.new()
		bm.size = box.size
		bm.material = _highlight_material()
		mesh = bm
		at = box.get_center()
	_lit = MeshInstance3D.new()
	_lit.name = "Highlight"
	_lit.mesh = mesh
	_lit.position = at
	_lit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	car.node.add_child(_lit)


static func _highlight_material() -> Material:
	if _lit_material == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = HIGHLIGHT
		m.no_depth_test = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.render_priority = 2
		_lit_material = m
	return _lit_material


## The client's rule for cargo (CDDA has none; the coordinator's): whether hands may reach into part `part` of vehicle
## `uid`: yes where no lid covers its square, else only while that lid is open CarInterior.LID_REACH degrees or more
## (closed while its interior isn't built). False for a vehicle not drawn or a part it hasn't.
func can_reach(uid: int, part: int) -> bool:
	var car: Car = _cars.get(uid)
	if car == null or car.node == null or car.veh == null or part < 0 or part >= car.veh.part_count():
		return false
	if car.interior != null and is_instance_valid(car.interior):
		var j := part * Snapshot.VPART_STRIDE
		var lid: int = car.interior.lid_at.get(Vector2i(car.veh.parts[j], car.veh.parts[j + 1]), -1)
		return lid < 0 or car.interior.lid_deg(lid) >= CarInterior.LID_REACH - 0.01
	if _snap == null or _world == null or not is_instance_valid(_world):
		return false
	return CarInterior.lid_over(car.veh, _snap, _world.tables, view_z_max, part) < 0


## Each frame: vehicles within INTERIOR_NEAR of the camera (`eye`, default: the viewport's; and the one the player is
## in) get their interior, INTERIOR_BUILDS a frame at most; past INTERIOR_FAR they lose it. Those with something on
## its way move `delta` seconds on (no others: a parked car's dash is still).
func interiors(delta: float, eye := Vector3.INF) -> void:
	if not eye.is_finite() and is_inside_tree() and get_viewport().get_camera_3d() != null:
		eye = get_viewport().get_camera_3d().global_position
	var builds := 0
	for car: Car in _cars.values():
		if car.interior != null and not is_instance_valid(car.interior):
			car.interior = null
		if car.node == null or car.veh == null:
			continue
		if eye.is_finite():
			var d := (car.node.transform * car.mid).distance_to(eye)
			var ride := car.veh.uid == _ride_uid
			if car.interior == null and (d < INTERIOR_NEAR or ride) and builds < INTERIOR_BUILDS and _snap != null \
					and _world != null and is_instance_valid(_world):
				car.interior = CarInterior.build(car.veh, _snap, _world.tables, view_z_max, car.mid, car.paint)
				car.node.add_child(car.interior)
				if ride:
					car.interior.set_reading(_ride)
				_hide_inside(car)
				builds += 1
			elif car.interior != null and d > INTERIOR_FAR and not ride:
				_free_interior(car)
		if car.interior != null and car.interior.moving:
			car.interior.moving = car.interior.step(delta)


## Keeps a vehicle's interior in step with its parts: dropped when they changed (built again by interiors()), else its
## lids follow CDDA's states.
func _check_interior(car: Car, snap: Snapshot, world: WorldView) -> void:
	if car.interior == null:
		return
	if car.node == null or not is_instance_valid(car.interior):
		_free_interior(car)
		return
	var seen := CarInterior.seen_key(car.veh, snap, world.tables, view_z_max)
	if seen != car.interior.seen:   # the layout is only worked out again when what it is made from changed
		if car.interior.key != CarInterior.layout_key(car.veh, snap, world.tables, view_z_max):
			_free_interior(car)
			return
		car.interior.seen = CarInterior.seen_key(car.veh, snap, world.tables, view_z_max, true)
	car.interior.set_states(car.veh)


func _free_interior(car: Car) -> void:
	if car.interior != null and is_instance_valid(car.interior):
		car.interior.free()
	car.interior = null


## Sets a vehicle's new pose: at once when it is new or jumped far, else a glide from where it is drawn now over
## about the time since it last moved (GLIDE_MIN..GLIDE_MAX).
func _move(car: Car, pose: Array, now: int, fresh: bool) -> void:
	var xf := compose(pose)
	if fresh or car.to_xf.origin.distance_to(xf.origin) > GLIDE_FAR:
		car.from = pose
		car.t = 1.0
	elif not car.to_xf.is_equal_approx(xf):
		car.from = blend(car.from, car.to, car.t)
		car.dur = clampf((now - car.moved_ms) / 1000.0, GLIDE_MIN, GLIDE_MAX)
		car.t = 0.0
		car.moved_ms = now
	car.to = pose
	car.to_xf = xf
	if car.node != null:
		car.node.transform = compose(blend(car.from, car.to, car.t))


## A pose [turn, grid, origin] as the transform it places the mount grid with.
static func compose(pose: Array) -> Transform3D:
	return Transform3D((pose[0] as Basis) * (pose[1] as Basis), pose[2])


## Pose `a` moved `t` (0..1) of the way to `b`: turned (slerp), the grid and origin blended straight.
static func blend(a: Array, b: Array, t: float) -> Array:
	if t >= 1.0:
		return b
	var ga: Basis = a[1]
	var gb: Basis = b[1]
	return [(a[0] as Basis).slerp(b[0], t), Basis(ga.x.lerp(gb.x, t), ga.y.lerp(gb.y, t), ga.z.lerp(gb.z, t)),
			(a[2] as Vector3).lerp(b[2], t)]


## Each frame: a cutaway change (WorldView.things_z_max) redraws at once; gliding vehicles move on.
func _process(delta: float) -> void:
	refresh()
	glide(delta)
	interiors(delta)


## Moves every gliding vehicle `delta` seconds on; one GLIDE_VIEW_M or more from the camera (`eye`, default: the
## viewport's) arrives at once.
func glide(delta: float, eye := Vector3.INF) -> void:
	if not eye.is_finite() and is_inside_tree() and get_viewport().get_camera_3d() != null:
		eye = get_viewport().get_camera_3d().global_position
	for car: Car in _cars.values():
		if car.t < 1.0:
			var far := eye.is_finite() and car.to_xf.origin.distance_to(eye) >= GLIDE_VIEW_M
			car.t = 1.0 if far else minf(1.0, car.t + delta / car.dur)
			if car.node != null:
				car.node.transform = compose(blend(car.from, car.to, car.t))


## Follows the cutaway of the world last applied: redraws its snapshot when things_z_max() moved.
func refresh() -> void:
	if _world == null or not is_instance_valid(_world) or _world.snapshot == null:
		return
	var z := _world.things_z_max()
	if z != view_z_max:
		view_z_max = z
		apply(_world.snapshot, _world)


## The map's origin moved by d: everything drawn moves with it (the next snapshot's poses already include it).
func shift(d: Vector3) -> void:
	for car: Car in _cars.values():
		car.from = [car.from[0], car.from[1], (car.from[2] as Vector3) + d]
		car.to = [car.to[0], car.to[1], (car.to[2] as Vector3) + d]
		car.to_xf.origin += d
		if car.node != null:
			car.node.position += d
		if car.marks != null:
			car.marks.position += d


## How a vehicle's model lies flat in the world: mount (x ahead, z to the right, a cell per square; y metres up from
## the floor of its level) to world: turned rigidly by CDDA's facing (face_deg, not its stepped layout),
## moved to fit its parts' squares best (least squares: the cells' middle on the squares' middle; CDDA turns a
## vehicle about a pivot, not mount 0, 0). On the axes every cell lands on its part's square.
static func frame_of(veh: Snapshot.Vehicle, coords: CddaCoords) -> Transform3D:
	var a := deg_to_rad(veh.face_deg) if is_finite(veh.face_deg) else 0.0
	var ahead := Vector2(cos(a), sin(a))     # squares (x east, y south) per step of mount x
	var right := Vector2(-sin(a), cos(a))    # and of mount y
	var sq := Vector2.ZERO
	var mt := Vector2.ZERO
	var n := 0
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if (veh.parts[j + 4] & Snapshot.VPART_FILLER) == 0:
			sq += Vector2(veh.parts[j + 5], veh.parts[j + 6])
			mt += Vector2(veh.parts[j], veh.parts[j + 1])
			n += 1
	var off := sq / n - (ahead * (mt.x / n) + right * (mt.y / n)) if n > 0 else Vector2.ZERO
	var o := coords.ms_center_to_world(veh.pos)
	var ex := coords.ms_center_to_world(veh.pos + Vector3i(1, 0, 0)) - o
	var ey := coords.ms_center_to_world(veh.pos + Vector3i(0, 1, 0)) - o
	return Transform3D(Basis(ex * ahead.x + ey * ahead.y, Vector3.UP, ex * right.x + ey * right.y), o + ex * off.x + ey * off.y)


## Where a vehicle's node goes: frame_of tilted to the ground under its cells
## (WorldView.ground_y on each part's own square and level: a plane fitted along and across the vehicle, at most
## MAX_SLOPE), so a car on a ramp leans with it; flat ground gives no tilt.
static func pose_of(veh: Snapshot.Vehicle, world: WorldView) -> Transform3D:
	return compose(pose_parts(veh, world))


## pose_of as a pose [turn, grid, origin]: frame_of split into its turn (facing, then the lean) and the grid in the
## turned frame.
static func pose_parts(veh: Snapshot.Vehicle, world: WorldView) -> Array:
	var f := frame_of(veh, world.coords)
	var x := Vector3(f.basis.x.x, 0.0, f.basis.x.z).normalized()
	var turn := Basis(x, Vector3.UP, x.cross(Vector3.UP).normalized())
	var grid := turn.transposed() * f.basis
	var origin := f.origin
	var pts := []   # Vector3(ahead m, height m, right m) per cell with a part, in the turned frame
	var seen := {}
	var sloped := false
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var m := Vector2i(veh.parts[j], veh.parts[j + 1])
		if (veh.parts[j + 4] & Snapshot.VPART_FILLER) != 0 or seen.has(m):
			continue
		seen[m] = true
		var sq := veh.square(i)
		var h := world.ground_y(world.coords.ms_center_to_world(sq), sq.z) - f.origin.y
		var at := grid * Vector3(m.x, 0.0, m.y)
		pts.append(Vector3(at.x, h if is_finite(h) else 0.0, at.z))
		sloped = sloped or absf(h) > 0.01
	if sloped:
		var t := tilt_of(pts)
		turn = turn * t.basis
		origin += t.origin
	return [turn.orthonormalized(), grid, origin]


## The lean of a vehicle on ground of heights `pts` (Vector3(ahead, height, right) per cell, metres, its own frame):
## a plane fitted along and across it (least squares, each way at most MAX_SLOPE) as a tilt about its origin and the
## plane's height there.
static func tilt_of(pts: Array) -> Transform3D:
	if pts.is_empty():
		return Transform3D()
	var mean := Vector3.ZERO
	for p: Vector3 in pts:
		mean += p
	mean /= pts.size()
	var su := 0.0
	var sv := 0.0
	var suh := 0.0
	var svh := 0.0
	for p: Vector3 in pts:
		var d: Vector3 = p - mean
		su += d.x * d.x
		sv += d.z * d.z
		suh += d.x * d.y
		svh += d.z * d.y
	var b := clampf(suh / su, -MAX_SLOPE, MAX_SLOPE) if su > 0.0 else 0.0
	var c := clampf(svh / sv, -MAX_SLOPE, MAX_SLOPE) if sv > 0.0 else 0.0
	return Transform3D(Basis(Vector3.BACK, atan(b)) * Basis(Vector3.RIGHT, -atan(c)),
			Vector3.UP * (mean.y - b * mean.x - c * mean.z))


## One vehicle's look in its mount grid (x ahead, y up, z right, a cell per square): [{Look -> body [vertices, normals,
## colours]}, {Look -> [[transform, colour], ...]} of the small parts, the body's colour]. Parts above the cutaway and
## gap fillers are left out. A seat in the controls' row (beside them) gets a dashboard in front of it.
func _vehicle(veh: Snapshot.Vehicle, snap: Snapshot, world: WorldView, hide: Array = []) -> Array:
	var cells := {}   # Vector3i(mount x, mount y, 0) -> {floor, low, high, glass, roof: [hp_frac, state], then Color}
	var small := []   # [kind, colour, cell, broken]
	var bases := {}   # CDDA colour of the body's parts -> votes
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var state := veh.parts[j + 4]
		if veh.pos.z + veh.parts[j + 7] > view_z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
		if not hide.is_empty() and veh.parts[j + 2] == hide[1] and Vector2i(veh.parts[j], veh.parts[j + 1]) == hide[0]:
			continue   # a hand carries its copy
		var def := def_of(world.tables, snap, veh.parts[j + 2])
		var kind := kind_of(def, state)
		if kind == Kind.NONE:
			continue
		var c := Vector3i(veh.parts[j], veh.parts[j + 1], 0)
		var cell: Dictionary = cells.get(c, {})
		cells[c] = cell
		var wear := [veh.parts[j + 3], state]
		if kind == Kind.FRAME or not cell.has("floor"):
			cell["floor"] = wear if kind == Kind.FRAME else [255, 0]
		if not (kind in HULL_KINDS):
			small.append([kind, color_of(kind, def, veh.parts[j + 3], state), c, (state & Snapshot.VPART_BROKEN) != 0])
			continue
		var base := CddaPalette.fg(def.color, DEFAULT_COLOR) if def != null else DEFAULT_COLOR
		bases[base] = bases.get(base, 0) + (1 if kind == Kind.FRAME else 10)   # the walls' paint before the frame's
		if (state & Snapshot.VPART_BROKEN) == 0:   # a broken wall doesn't block: not drawn either
			if kind != Kind.FRAME and kind != Kind.ROOF:
				cell["low"] = wear
			if kind == Kind.BOARD or kind == Kind.DOOR:
				cell["high"] = wear
			elif kind == Kind.WINDOW or kind == Kind.GLASS_DOOR:
				cell["glass"] = wear
			elif kind == Kind.ROOF:
				cell["roof"] = wear
	# one paint for the whole body (its parts' commonest colour), each cell worn as its own part is
	var body := DEFAULT_COLOR
	for b: Color in bases:
		if bases[b] > bases.get(body, 0):
			body = b
	for c: Vector3i in cells:
		for role: String in cells[c]:
			var w: Array = cells[c][role]
			cells[c][role] = GLASS if role == "glass" else damaged(body, w[0], w[1])
	var front := {}   # the controls' rows (mount x) and cells
	for e: Array in small:
		if e[0] == Kind.CONTROLS:
			front[(e[2] as Vector3i).x] = true
			front[e[2]] = true
	for e: Array in small.duplicate():
		if e[0] == Kind.SEAT and front.has((e[2] as Vector3i).x) and not front.has(e[2]):
			front[e[2]] = true   # one dashboard a cell
			small.append([Kind.DASH, damaged(DASH_COLOR, 255, 0), e[2], false])
	var by_look := {}
	for e: Array in small:
		var c: Vector3i = e[2]
		var at := Vector3(c.x, 0.0, c.y)
		if e[0] == Kind.WHEEL:   # on the body's side, half out of it
			var side := 1.0 if not cells.has(c + Vector3i(0, 1, 0)) else (-1.0 if not cells.has(c - Vector3i(0, 1, 0)) else 0.0)
			at += Vector3(0.0, 0.0, side * WHEEL_OUT)
		place(by_look, e[0], e[1], at, Basis(), e[3])
	return [hull_of(cells, Transform3D()), by_look, body]


## (Re)makes a vehicle's node and mesh from its body and small parts (baked in: one surface per look); no node while
## nothing of it is drawn.
func _mesh(car: Car) -> void:
	var tris := []   # the small parts' triangles: [a, b, c, normal, colour]
	for look: int in car.small:
		for e: Array in car.small[look]:
			if look == Look.WHEEL:
				_cylinder(tris, e[0], e[1])
			else:
				_box(tris, e[0], e[1])
	var mesh := ArrayMesh.new()
	car.verts = 0
	for look: int in [Look.SOLID, Look.GLASS]:
		var arrs: Array = car.local.get(look, [])
		# copies: the small parts are added to the mesh only, never to car.local
		var v := (arrs[0] as PackedVector3Array).duplicate() if not arrs.is_empty() else PackedVector3Array()
		var nr := (arrs[1] as PackedVector3Array).duplicate() if not arrs.is_empty() else PackedVector3Array()
		var cl := (arrs[2] as PackedColorArray).duplicate() if not arrs.is_empty() else PackedColorArray()
		if look == Look.SOLID:
			for t: Array in tris:
				v.append_array(PackedVector3Array([t[0], t[1], t[2]]))
				nr.append_array(PackedVector3Array([t[3], t[3], t[3]]))
				cl.append_array(PackedColorArray([t[4], t[4], t[4]]))
		if v.is_empty() or v.size() > MAX_HULL_VERTS:
			continue
		var data := []
		data.resize(Mesh.ARRAY_MAX)
		data[Mesh.ARRAY_VERTEX] = v
		data[Mesh.ARRAY_NORMAL] = nr
		data[Mesh.ARRAY_COLOR] = cl
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(look))
		car.verts += v.size()
	if mesh.get_surface_count() == 0:
		if car.node != null:
			car.node.free()
			car.node = null
		car.interior = null   # freed with its node
		return
	if car.node == null:
		var mi := MeshInstance3D.new()
		mi.name = "vehicle"
		add_child(mi)
		mi.transform = compose(blend(car.from, car.to, car.t))
		car.node = mi
	(car.node as MeshInstance3D).mesh = mesh


## A unit box (BoxMesh) placed by xf, as triangles.
static func _box(tris: Array, xf: Transform3D, col: Color) -> void:
	var nb := xf.basis.inverse().transposed()
	for f: Array in _BOX_FACES:
		var n: Vector3 = (nb * (f[0] as Vector3)).normalized()
		tris.append(_tri_n(xf * (f[1] as Vector3), xf * (f[2] as Vector3), xf * (f[3] as Vector3), n, col))
		tris.append(_tri_n(xf * (f[1] as Vector3), xf * (f[3] as Vector3), xf * (f[4] as Vector3), n, col))


## A unit cylinder (CylinderMesh: radius 0.5, height 1 along y) of WHEEL_SIDES sides placed by xf, as triangles.
static func _cylinder(tris: Array, xf: Transform3D, col: Color) -> void:
	var nb := xf.basis.inverse().transposed()
	var up := (nb * Vector3.UP).normalized()
	for s in WHEEL_SIDES:
		var a0 := TAU * s / WHEEL_SIDES
		var a1 := TAU * (s + 1) / WHEEL_SIDES
		var p0 := Vector3(0.5 * cos(a0), 0.0, 0.5 * sin(a0))
		var p1 := Vector3(0.5 * cos(a1), 0.0, 0.5 * sin(a1))
		var n := (nb * Vector3(cos(0.5 * (a0 + a1)), 0.0, sin(0.5 * (a0 + a1)))).normalized()
		var lo0 := xf * (p0 + Vector3.DOWN * 0.5)
		var lo1 := xf * (p1 + Vector3.DOWN * 0.5)
		var hi0 := xf * (p0 + Vector3.UP * 0.5)
		var hi1 := xf * (p1 + Vector3.UP * 0.5)
		tris.append(_tri_n(lo0, lo1, hi1, n, col))
		tris.append(_tri_n(lo0, hi1, hi0, n, col))
		tris.append(_tri_n(xf * (Vector3.UP * 0.5), hi0, hi1, up, col))
		tris.append(_tri_n(xf * (Vector3.DOWN * 0.5), lo0, lo1, -up, col))


## A vehicle's body from its cells (Vector3i(mount x, mount y, 0) -> {floor, low, high, glass, roof: Color}): a
## floor under all of them, walls from the deck to the sill, opaque panels or glass from there to the top, the roof
## above; each a prism whose sides show only where it ends, outer corners cut. {Look -> [vertices, normals, colours]}.
static func hull_of(cells: Dictionary, xf: Transform3D) -> Dictionary:
	var layer := {}   # "floor"... -> {cell -> Color}
	for key: String in ["floor", "low", "high", "glass", "roof"]:
		layer[key] = {}
	for c: Vector3i in cells:
		for key: String in cells[c]:
			layer[key][c] = cells[c][key]
	var upper: Dictionary = layer["high"].merged(layer["glass"])
	var out := {}
	prism(out, Look.SOLID, layer["floor"], layer["floor"], layer["floor"], CLEAR, DECK, xf)
	prism(out, Look.SOLID, layer["low"], layer["low"], layer["low"], DECK, SILL, xf)
	prism(out, Look.SOLID, layer["high"], layer["high"], upper, SILL, TOP, xf)
	prism(out, Look.GLASS, layer["glass"], upper, upper, SILL, TOP, xf, false)   # panes: no glass lid or floor
	prism(out, Look.SOLID, layer["roof"], layer["roof"], layer["roof"], TOP, TOP + ROOF_T, xf)
	return out


## Adds the prism of `region` (cell -> colour) between heights y0 and y1 (m, plus its cell's z levels) to out[look]:
## a face up and down per cell (unless not `caps`), a side where the neighbouring cell isn't in `sides`, a corner cut
## where neither cell beside it is in `cuts`. Faces are wound clockwise seen from outside (Godot's front faces).
static func prism(out: Dictionary, look: int, region: Dictionary, sides: Dictionary, cuts: Dictionary, y0: float,
		y1: float, xf: Transform3D, caps := true) -> void:
	if region.is_empty():
		return
	var tris := []   # [a, b, c, normal, colour]
	for c: Vector3i in region:
		var col: Color = region[c]
		var lo := y0 + c.z * CddaCoords.LEVEL_M
		var hi := y1 + c.z * CddaCoords.LEVEL_M
		var poly := _cell_poly(c, sides, cuts)
		var pts := []   # the outline at lo, then at hi
		for y: float in [lo, hi]:
			for e: Array in poly:
				var p: Vector2 = e[0]
				pts.append(xf * Vector3(c.x + p.x, y, c.y + p.y))
		var m := poly.size()
		for j in range(1, m - 1 if caps else 1):
			tris.append(_tri(xf, pts[m], pts[m + j], pts[m + j + 1], Vector3.UP, col))
			tris.append(_tri(xf, pts[0], pts[j], pts[j + 1], Vector3.DOWN, col))
		for j in m:
			if not poly[j][1]:
				continue
			var a: Vector2 = poly[j][0]
			var b: Vector2 = poly[(j + 1) % m][0]
			var n := Vector3(b.y - a.y, 0.0, a.x - b.x)   # outward: the outline runs counterclockwise
			var k := (j + 1) % m
			tris.append(_tri(xf, pts[j], pts[k], pts[m + k], n, col))
			tris.append(_tri(xf, pts[j], pts[m + k], pts[m + j], n, col))
	var v: PackedVector3Array = out[look][0] if out.has(look) else PackedVector3Array()
	var nr: PackedVector3Array = out[look][1] if out.has(look) else PackedVector3Array()
	var cl: PackedColorArray = out[look][2] if out.has(look) else PackedColorArray()
	for t: Array in tris:
		v.append_array(PackedVector3Array([t[0], t[1], t[2]]))
		nr.append_array(PackedVector3Array([t[3], t[3], t[3]]))
		cl.append_array(PackedColorArray([t[4], t[4], t[4]]))
	out[look] = [v, nr, cl]


## One cell's outline: [[corner, whether the edge from it to the next is a side], ...] counterclockwise; a corner
## whose two neighbouring cells aren't in `cuts` is cut off.
static func _cell_poly(c: Vector3i, sides: Dictionary, cuts: Dictionary) -> Array:
	var side := []
	var open := []
	for j in 4:
		side.append(not sides.has(c + _EDGE_NEXT[j]))
		open.append(not cuts.has(c + _EDGE_NEXT[j]))
	var poly := []
	for j in 4:
		var p: Vector2 = _CORNERS[j]
		if open[(j + 3) % 4] and open[j]:
			poly.append([p + (_CORNERS[(j + 3) % 4] - p) * CHAMFER, true])
			poly.append([p + (_CORNERS[(j + 1) % 4] - p) * CHAMFER, side[j]])
		else:
			poly.append([p, side[j]])
	return poly


## A triangle facing `n` (the frame xf's own) in colour col, wound clockwise seen from that side: [a, b, c, normal,
## colour].
static func _tri(xf: Transform3D, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> Array:
	return _tri_n(a, b, c, (xf.basis.inverse().transposed() * n).normalized(), col)


## A triangle facing `n` in colour col, wound clockwise seen from that side (Godot's front faces).
static func _tri_n(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> Array:
	return [a, c, b, n, col] if (b - a).cross(c - a).dot(n) > 0.0 else [a, b, c, n, col]


## Adds the boxes of one part of kind `kind` on the square whose floor centre is `at` (world), turned by `turn`, to
## by_look (Look -> [[transform, colour], ...], MAX_PER_LOOK per look at most). A box's transform scales a unit mesh
## to its size. Broken glass is left out.
static func place(by_look: Dictionary, kind: int, col: Color, at: Vector3, turn: Basis, broken := false) -> void:
	for sh: Array in shapes(kind):
		var look: int = sh[0]
		if look == Look.GLASS and broken:
			continue
		var list: Array = by_look.get(look, [])
		if list.size() >= MAX_PER_LOOK:
			continue
		var box: AABB = sh[1]
		var b := turn * Basis.from_scale(box.size)
		if look == Look.WHEEL:
			b = b * Basis(Vector3.RIGHT, PI / 2)   # the cylinder's axis across the vehicle
		list.append([Transform3D(b, at + turn * box.get_center()), GLASS if look == Look.GLASS else col])
		by_look[look] = list


## The boxes a kind of part is drawn with: [[Look, AABB], ...] in the part's own frame (x ahead, y up, z to the
## right, the square's floor centre at 0).
static func shapes(kind: int) -> Array:
	if _shapes.is_empty():
		var s := Look.SOLID
		var full := func(y0: float, y1: float) -> AABB: return AABB(Vector3(-0.5, y0, -0.5), Vector3(1.0, y1 - y0, 1.0))
		_shapes = {
			Kind.NONE: [],
			Kind.FRAME: [[s, full.call(0.25, DECK)]],
			Kind.BOARD: [[s, full.call(DECK, TOP)]],
			Kind.HALF: [[s, full.call(DECK, SILL)]],
			Kind.WINDOW: [[s, full.call(DECK, SILL)], [Look.GLASS, full.call(SILL, TOP)]],
			Kind.DOOR: [[s, AABB(Vector3(-0.45, DECK, -0.45), Vector3(0.9, TOP - DECK, 0.9))]],
			Kind.GLASS_DOOR: [[s, AABB(Vector3(-0.45, DECK, -0.45), Vector3(0.9, SILL - DECK, 0.9))],
					[Look.GLASS, AABB(Vector3(-0.45, SILL, -0.45), Vector3(0.9, TOP - SILL, 0.9))]],
			Kind.DOOR_OPEN: [[s, AABB(Vector3(-0.45, DECK, -0.5), Vector3(0.9, TOP - DECK, 0.08))]],
			Kind.ROOF: [[s, full.call(TOP, TOP + ROOF_T)]],
			Kind.WHEEL: [[Look.WHEEL, AABB(Vector3(-0.4, 0.0, -0.15), Vector3(0.8, 0.8, 0.3))]],
			Kind.SEAT: [[s, AABB(Vector3(-0.3, DECK, -0.35), Vector3(0.65, 0.45, 0.7))],
					[s, AABB(Vector3(-0.42, DECK, -0.35), Vector3(0.14, 0.95, 0.7))],
					[s, AABB(Vector3(-0.41, DECK + 0.98, -0.15), Vector3(0.11, 0.17, 0.3))]],   # headrest
			Kind.ENGINE: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.6, 0.8))]],
			Kind.TANK: [[s, AABB(Vector3(-0.35, 0.05, -0.35), Vector3(0.7, 0.2, 0.7))]],
			Kind.CARGO: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.5, 0.8))]],
			Kind.LIGHT: [[s, AABB(Vector3(0.35, 0.85, -0.1), Vector3(0.15, 0.2, 0.2))]],
			Kind.ROOF_LIGHT: [[s, AABB(Vector3(-0.15, TOP + ROOF_T, -0.15), Vector3(0.3, 0.2, 0.3))]],
			Kind.TURRET: [[s, AABB(Vector3(-0.25, TOP + ROOF_T, -0.25), Vector3(0.5, 0.3, 0.5))],
					[s, AABB(Vector3(0.25, TOP + ROOF_T + 0.1, -0.05), Vector3(0.6, 0.1, 0.1))]],
			# the dashboard's lower part across the cell's front, the steering column (the wheel and the cluster:
			# CarInterior, near the camera)
			Kind.CONTROLS: [[s, AABB(Vector3(0.38, 0.85, -0.5), Vector3(0.12, 0.45, 1.0))],
					[s, AABB(Vector3(0.3, 1.13, -0.03), Vector3(0.1, 0.06, 0.06))]],
			Kind.DASH: [[s, AABB(Vector3(0.38, 0.85, -0.5), Vector3(0.12, 0.45, 1.0))]],
			Kind.OTHER: [[s, AABB(Vector3(-0.25, DECK, -0.25), Vector3(0.5, 0.5, 0.5))]],
		}
	return _shapes.get(kind, [])


## The kind of a part from its definition and state (Snapshot.VPART_* bits): OTHER for a part the tables don't
## know, NONE for one not drawn (armour plating, seatbelts, locks, batteries and the like).
static func kind_of(def: IdTables.Def, state: int) -> int:
	if def == null:
		return Kind.OTHER
	var f := def.flags
	if f.has("WHEEL"):
		return Kind.WHEEL
	if f.has("DOOR") or (f.has("OPENABLE") and f.has("OBSTACLE")):
		if (state & Snapshot.VPART_OPEN) != 0:
			return Kind.DOOR_OPEN
		return Kind.GLASS_DOOR if f.has("WINDOW") and not f.has("OPAQUE") else Kind.DOOR
	if f.has("WINDOW"):
		return Kind.WINDOW
	if f.has("ROOF") or def.location == "roof":
		return Kind.ROOF
	if f.has("TURRET"):
		return Kind.TURRET
	if f.has("SEAT") or f.has("BED"):
		return Kind.SEAT
	if f.has("ENGINE"):
		return Kind.ENGINE
	if f.has("CONTROLS"):
		return Kind.CONTROLS
	if f.has("FULL_BOARD") or (f.has("OBSTACLE") and f.has("OPAQUE")):
		return Kind.BOARD
	if f.has("HALF_BOARD") or f.has("OBSTACLE"):
		return Kind.HALF
	for l: String in LIGHT_FLAGS:
		if f.has(l):
			return Kind.ROOF_LIGHT if def.location == "on_roof" else Kind.LIGHT
	if f.has("FLUIDTANK"):
		return Kind.TANK
	if f.has("CARGO") and def.location == "center":
		return Kind.CARGO
	if def.location == "structure":
		return Kind.FRAME
	return Kind.NONE


## A part's colour: its CDDA colour (CddaPalette), lights bright while on; then as damaged() shows it. Tyres stay
## black (rubber doesn't rust). Glass is always GLASS.
static func color_of(kind: int, def: IdTables.Def, hp: int, state: int) -> Color:
	var c := CddaPalette.fg(def.color, DEFAULT_COLOR) if def != null else DEFAULT_COLOR
	if kind == Kind.WHEEL:
		return TYRE
	elif kind == Kind.LIGHT or kind == Kind.ROOF_LIGHT:
		c = LIT if (state & Snapshot.VPART_ENABLED) != 0 else DEFAULT_COLOR
	elif kind == Kind.CONTROLS:
		c = DASH_COLOR
	return damaged(c, hp, state)


## `c` as a part with hp_frac `hp` (0..255) and state `state` shows it: rustier and darker the more it is damaged,
## charred when broken.
static func damaged(c: Color, hp: int, state: int) -> Color:
	var out: Color
	if (state & Snapshot.VPART_BROKEN) != 0:
		out = c.lerp(CHAR, 0.75)
	else:
		var dmg := 1.0 - clampf(hp / 255.0, 0.0, 1.0)
		out = c.lerp(RUST, 0.7 * dmg).darkened(0.35 * dmg)
	out.a = c.a
	return out


## The vpart definition of index `vpart`: null when the tables don't hold it or are of another generation than the
## snapshot's ids (the index means something else).
static func def_of(tables: IdTables, snap: Snapshot, vpart: int) -> IdTables.Def:
	if tables == null or (snap != null and snap.ids_generation >= 0 and snap.ids_generation != tables.generation):
		return null
	return tables.def_at("vpart", vpart)


## Whether a vehicle part keeps you from walking onto square p, as CDDA's vehicle::obstacle_at_part: the first part
## there that has OBSTACLE and isn't broken blocks, unless it opens and is open. Parts the tables don't know don't.
static func blocks(snap: Snapshot, tables: IdTables, p: Vector3i) -> bool:
	if snap == null:
		return false
	var at := snap.vehicle_at(p)
	if at.is_empty():
		return false
	var veh: Snapshot.Vehicle = at[0]
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		var def := def_of(tables, snap, veh.parts[k + 2])
		var state := veh.parts[k + 4]
		if def != null and def.flags.has("OBSTACLE") and (state & Snapshot.VPART_BROKEN) == 0:
			return not (def.flags.has("OPENABLE") and (state & Snapshot.VPART_OPEN) != 0)
	return false


## The heights (m above the floor) a kind of part is drawn between: Vector2(bottom, top); ZERO when not drawn.
static func span_of(kind: int) -> Vector2:
	var out := Vector2.ZERO
	for sh: Array in shapes(kind):
		var box: AABB = sh[1]
		out = Vector2(box.position.y, box.end.y) if out == Vector2.ZERO \
				else Vector2(minf(out.x, box.position.y), maxf(out.y, box.end.y))
	return out


## The vehicle part on square p that a look meets at height h (m above the square's floor): of the parts drawn there
## whose span holds h the narrowest (a seat before the wall around it), open doors left out (you look past them).
## [Vehicle, part index], or [] where none is.
static func part_at(snap: Snapshot, tables: IdTables, p: Vector3i, h: float) -> Array:
	if snap == null:
		return []
	var at := snap.vehicle_at(p)
	if at.is_empty():
		return []
	var veh: Snapshot.Vehicle = at[0]
	var best := -1
	var best_w := INF
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		var kind := kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4])
		if kind == Kind.DOOR_OPEN:
			continue
		var sp := span_of(kind)
		if sp != Vector2.ZERO and h >= sp.x and h <= sp.y and sp.y - sp.x < best_w:
			best = i
			best_w = sp.y - sp.x
	return [veh, best] if best >= 0 else []


## The top of what is drawn of a vehicle on square p (m above its floor), 0 where nothing is.
static func top_at(snap: Snapshot, tables: IdTables, p: Vector3i) -> float:
	var at := snap.vehicle_at(p) if snap != null else []
	if at.is_empty():
		return 0.0
	var veh: Snapshot.Vehicle = at[0]
	var top := 0.0
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		top = maxf(top, span_of(kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4])).y)
	return top


## How high an item dropped on square p lies on the vehicle there (m above the floor; 0 where none is): on top of
## the parts (top_at) where they block walking, else on the highest seat, cargo, engine, wheel or frame (REST): in
## the car, under its roof.
static func rest_at(snap: Snapshot, tables: IdTables, p: Vector3i) -> float:
	if blocks(snap, tables, p):
		return top_at(snap, tables, p)
	var at := snap.vehicle_at(p) if snap != null else []
	if at.is_empty():
		return 0.0
	var veh: Snapshot.Vehicle = at[0]
	var h := 0.0
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		h = maxf(h, REST.get(kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4]), 0.0))
	return h


## "<vehicle>: <part>" for look-at (part_label), "vehicle" for a vehicle with no name.
static func part_name(snap: Snapshot, tables: IdTables, veh: Snapshot.Vehicle, i: int) -> String:
	return "%s: %s" % [veh.name if not veh.name.is_empty() else "vehicle", part_label(snap, tables, veh, i)]


## Part i of a vehicle in words: its name as plain text (CddaText.plain), "part" when the tables don't know it,
## " (broken)" after it when broken.
static func part_label(snap: Snapshot, tables: IdTables, veh: Snapshot.Vehicle, i: int) -> String:
	var def := def_of(tables, snap, veh.parts[i * Snapshot.VPART_STRIDE + 2])
	var part := CddaText.plain(def.name if def != null and not def.name.is_empty() else "part").left(MAX_NAME)
	if (veh.parts[i * Snapshot.VPART_STRIDE + 4] & Snapshot.VPART_BROKEN) != 0:
		part += " (broken)"
	return part


static func _material(look: int) -> Material:
	var m: StandardMaterial3D = _mats.get(look)
	if m == null:
		m = StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.75 if look != Look.GLASS else 0.1
		if look == Look.GLASS:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.render_priority = WorldLighting.UNDER_PRIORITY   # darkened by the light pass with what is behind it
		_mats[look] = m
	return m
