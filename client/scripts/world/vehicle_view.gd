class_name VehicleView
extends Node3D
## Block C5 (PLAN.md): CDDA's vehicles (Snapshot.vehicles). Each vehicle is a node of its own (Car) holding one mesh
## built in the vehicle's own grid (slice 2: one body, hull_of: a floor under every cell, walls up to the sill where
## boards, doors and windows are, opaque panels or glass panes above, the roof; outer corners cut so it reads rounded;
## one paint, each cell worn as its part; the small parts baked in: wheels on the outside, seats, engine, lights,
## open doors, ... each kind (Kind) from the vpart's flags and location). The mesh is built again only when the
## vehicle's parts, the cutaway or its stretch change; driving and turning move the node only (slice 3): its pose
## (pose_of: turned smoothly by the facing, fitted onto the parts' squares since CDDA turns about a pivot, tilted to
## the ground under it on a ramp) glides from where it is drawn to the new one over about as long as the vehicle took
## between snapshots, so a driven car moves smoothly; ride_transform lets the camera ride along. Off the axes the
## mesh is stretched as CDDA's tile rays step (stretch_of). CDDA's gap fillers (Snapshot.VPART_FILLER) only block:
## the stretched body covers their squares. What blocks walking (blocks), which part a ray meets at a height
## (part_at) and what items rest on (rest_at) stay per square, exactly CDDA's (shapes: the heights of each kind),
## for walking, LookRay and the item physics. Real models and doors by hand are later slices.

enum Kind { NONE, FRAME, BOARD, HALF, DOOR, GLASS_DOOR, DOOR_OPEN, WINDOW, ROOF, WHEEL, SEAT, ENGINE, TANK, CARGO,
		LIGHT, ROOF_LIGHT, TURRET, CONTROLS, OTHER }
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
const MAX_SLOPE := 1.0  # tan of the steepest tilt on a ramp (45 degrees)
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
const MAX_NAME := 60
const LIGHT_FLAGS := ["CONE_LIGHT", "WIDE_CONE_LIGHT", "HALF_CIRCLE_LIGHT", "CIRCLE_LIGHT"]
## How high an item lies on a part of each kind that doesn't block (m above the floor); kinds not listed add nothing.
const REST := {Kind.FRAME: DECK, Kind.HALF: SILL, Kind.WHEEL: 0.8, Kind.TANK: 0.25, Kind.SEAT: DECK + 0.45,
		Kind.CARGO: DECK + 0.5, Kind.ENGINE: DECK + 0.6, Kind.OTHER: DECK + 0.5}


## One vehicle as drawn: its node (null while nothing of it is drawn), its mesh's data in its own frame, and its
## glide from `from` to `to` (t 0..1 over dur seconds).
class Car:
	var node: Node3D
	var key: Array = []      # what the mesh was built from
	var pose_key: Array = [] # what `to` was worked out from
	var local := {}          # Look (SOLID, GLASS) -> [vertices, normals, colours], the vehicle's frame
	var small := {}          # Look -> [[Transform3D, Color], ...]: the small parts, the vehicle's frame
	var from := Transform3D()
	var to := Transform3D()
	var t := 1.0
	var dur := GLIDE_MIN
	var moved_ms := 0
	var verts := 0           # vertices in its mesh


var view_z_max := CddaCoords.Z_LIMIT   # levels above are hidden: WorldView.things_z_max() (main.gd, refresh)
var _world: WorldView = null   # the world last applied (refresh follows its cutaway)
var _cars := {}        # vehicle uid -> Car, the shown snapshot's vehicles in its order
var built := 0         # meshes built (not kept from the last snapshot), counted for tests
var max_verts := MAX_VERTS   # lowered by tests
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
			out.append([car.to * (e[0] as Transform3D), e[1]])
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
		var b := car.to.basis
		for p: Vector3 in arrs[0]:
			v.append(car.to * p)
		for n: Vector3 in arrs[1]:
			nr.append((b * n).normalized())
		cl.append_array(arrs[2])
	return [v, nr, cl]


## Where vehicle `uid` is drawn now (its node, mid-glide or not); null transform if it isn't drawn.
func drawn(uid: int) -> Variant:
	var car: Car = _cars.get(uid)
	return car.node.transform if car != null and car.node != null else null


## What the camera adds to ride along with a gliding vehicle the player is on: the drawn pose of the vehicle on the
## player's square times the inverse of where the snapshot puts it (identity when the player isn't on one or it
## has arrived). Applied to the eyes the snapshot gives, it seats them where the drawn vehicle is.
func ride_transform(snap: Snapshot) -> Transform3D:
	if snap == null:
		return Transform3D()
	var at := snap.vehicle_at(snap.player_pos)
	var car: Car = _cars.get((at[0] as Snapshot.Vehicle).uid) if not at.is_empty() else null
	if car == null or car.node == null or car.t >= 1.0:
		return Transform3D()
	return car.node.transform * car.to.affine_inverse()


func apply(snap: Snapshot, world: WorldView) -> void:
	_world = world
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
			var k := stretch_of(veh.face_deg)
			var key := [veh.parts, veh.pos.z, view_z_max, world.tables, snap.ids_generation, k]
			if car.key == key and total + car.verts > max_verts:
				_drop(car)   # kept, but no room for it now: built again when there is
			if car.key != key and total < max_verts:
				var look := _vehicle(veh, snap, world, k)
				car.key = key
				car.local = look[0]
				car.small = look[1]
				_mesh(car)
				built += 1
			total += car.verts if car.key == key else 0
			var pose_key := [veh.pos, veh.face_deg, veh.parts, world.coords.origin_ms]
			if fresh or car.pose_key != pose_key:
				car.pose_key = pose_key
				_move(car, pose_of(veh, world), now, fresh)
			cars[veh.uid] = car
	for uid: int in _cars:
		if not cars.has(uid) and (_cars[uid] as Car).node != null:
			(_cars[uid] as Car).node.free()
	_cars = cars


## Frees what a vehicle draws and forgets what it was built from.
func _drop(car: Car) -> void:
	if car.node != null:
		car.node.free()
		car.node = null
	car.key = []
	car.local = {}
	car.small = {}
	car.verts = 0


## Sets a vehicle's new pose: at once when it is new or jumped far, else a glide from where it is drawn now over
## about the time since it last moved (GLIDE_MIN..GLIDE_MAX).
func _move(car: Car, pose: Transform3D, now: int, fresh: bool) -> void:
	if fresh or car.to.origin.distance_to(pose.origin) > GLIDE_FAR:
		car.from = pose
		car.t = 1.0
	elif not car.to.is_equal_approx(pose):
		car.from = car.node.transform if car.node != null else car.to
		car.dur = clampf((now - car.moved_ms) / 1000.0, GLIDE_MIN, GLIDE_MAX)
		car.t = 0.0
		car.moved_ms = now
	car.to = pose
	if car.node != null:
		car.node.transform = car.from.interpolate_with(car.to, car.t)


## Each frame: a cutaway change (WorldView.things_z_max) redraws at once; gliding vehicles move on.
func _process(delta: float) -> void:
	refresh()
	glide(delta)


## Moves every gliding vehicle `delta` seconds on.
func glide(delta: float) -> void:
	for car: Car in _cars.values():
		if car.t < 1.0:
			car.t = minf(1.0, car.t + delta / car.dur)
			if car.node != null:
				car.node.transform = car.from.interpolate_with(car.to, car.t)


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
		car.from.origin += d
		car.to.origin += d
		if car.node != null:
			car.node.position += d


## How much a vehicle facing `face_deg` is stretched in its grid: 1 / max(|cos|, |sin|), as CDDA's tile rays step
## (a vehicle at 45 degrees covers squares 1.4 m apart).
static func stretch_of(face_deg: float) -> float:
	var a := deg_to_rad(face_deg)
	return 1.0 / maxf(absf(cos(a)), absf(sin(a)))


## How a vehicle's grid lies flat in the world: mount (x ahead, z to the right, a cell per square; y metres up from
## the floor of its level) to world. Turned smoothly by face_deg; stretched by stretch_of; moved to fit its parts'
## squares best (CDDA turns a vehicle about a pivot, not mount 0, 0). At right angles every cell lands on its
## part's square.
static func frame_of(veh: Snapshot.Vehicle, coords: CddaCoords) -> Transform3D:
	var a := deg_to_rad(veh.face_deg)
	var k := stretch_of(veh.face_deg)
	var ahead := Vector2(cos(a), sin(a)) * k
	var right := Vector2(-sin(a), cos(a)) * k
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


## Where a vehicle's node goes: frame_of without the stretch (the mesh has it), tilted to the ground under its cells
## (WorldView.ground_y on each part's own square and level: a plane fitted along and across the vehicle, at most
## MAX_SLOPE), so a car on a ramp leans with it; flat ground gives no tilt.
static func pose_of(veh: Snapshot.Vehicle, world: WorldView) -> Transform3D:
	var f := frame_of(veh, world.coords)
	var k := stretch_of(veh.face_deg)
	var pose := Transform3D(f.basis * Basis.from_scale(Vector3(1.0 / k, 1.0, 1.0 / k)), f.origin)
	var pts := []   # Vector3(ahead m, height m, right m) per cell with a part
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
		pts.append(Vector3(m.x * k, h if is_finite(h) else 0.0, m.y * k))
		sloped = sloped or absf(h) > 0.01
	if sloped:
		var t := tilt_of(pts)
		pose.basis = pose.basis * t.basis
		pose.origin += t.origin
	return pose


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


## One vehicle's look in its own frame (x ahead, y up, z right; stretched by k): [{Look -> body [vertices, normals,
## colours]}, {Look -> [[transform, colour], ...]} of the small parts]. Parts above the cutaway and gap fillers are
## left out.
func _vehicle(veh: Snapshot.Vehicle, snap: Snapshot, world: WorldView, k: float) -> Array:
	var cells := {}   # Vector3i(mount x, mount y, 0) -> {floor, low, high, glass, roof: [hp_frac, state], then Color}
	var small := []   # [kind, colour, cell, broken]
	var bases := {}   # CDDA colour of the body's parts -> votes
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		var state := veh.parts[j + 4]
		if veh.pos.z + veh.parts[j + 7] > view_z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
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
	var by_look := {}
	for e: Array in small:
		var c: Vector3i = e[2]
		var at := Vector3(c.x * k, 0.0, c.y * k)
		if e[0] == Kind.WHEEL:   # on the body's side, half out of it
			var side := 1.0 if not cells.has(c + Vector3i(0, 1, 0)) else (-1.0 if not cells.has(c - Vector3i(0, 1, 0)) else 0.0)
			at += Vector3(0.0, 0.0, side * WHEEL_OUT)
		place(by_look, e[0], e[1], at, Basis(), e[3])
	return [hull_of(cells, Transform3D(Basis.from_scale(Vector3(k, 1.0, k)), Vector3.ZERO)), by_look]


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
		return
	if car.node == null:
		var mi := MeshInstance3D.new()
		mi.name = "vehicle"
		add_child(mi)
		mi.transform = car.from.interpolate_with(car.to, car.t)
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
					[s, AABB(Vector3(-0.42, DECK, -0.35), Vector3(0.14, 1.1, 0.7))]],
			Kind.ENGINE: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.6, 0.8))]],
			Kind.TANK: [[s, AABB(Vector3(-0.35, 0.05, -0.35), Vector3(0.7, 0.2, 0.7))]],
			Kind.CARGO: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.5, 0.8))]],
			Kind.LIGHT: [[s, AABB(Vector3(0.35, 0.85, -0.1), Vector3(0.15, 0.2, 0.2))]],
			Kind.ROOF_LIGHT: [[s, AABB(Vector3(-0.15, TOP + ROOF_T, -0.15), Vector3(0.3, 0.2, 0.3))]],
			Kind.TURRET: [[s, AABB(Vector3(-0.25, TOP + ROOF_T, -0.25), Vector3(0.5, 0.3, 0.5))],
					[s, AABB(Vector3(0.25, TOP + ROOF_T + 0.1, -0.05), Vector3(0.6, 0.1, 0.1))]],
			Kind.CONTROLS: [[s, AABB(Vector3(0.1, 1.0, -0.2), Vector3(0.3, 0.25, 0.4))]],
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
