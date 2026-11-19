class_name VehicleView
extends Node3D
## Block C5 (PLAN.md): CDDA's vehicles (Snapshot.vehicles). Slice 2, the look: each vehicle is drawn in its own
## mount grid (frame_of: turned smoothly by its facing, stretched off the axes as CDDA's tile rays step, placed on its
## parts' squares) as one body (hull: a floor under every cell, walls up to the sill where boards, doors and windows
## are, opaque panels or glass above, the roof; outer corners cut so it reads rounded, no seams between squares) with
## the other parts as shapes on their cells (wheels on the outside, seats, engine, lights, open doors, ...), each kind
## (Kind) from the vpart's flags and location, in the part's CDDA colour; damaged parts go rusty and dark, broken ones
## charred, broken walls and glass are gone. CDDA's gap fillers (Snapshot.VPART_FILLER) only block: the stretched
## body covers their squares. Bodies are kept per vehicle until it moves, turns or changes; small parts are one
## MultiMesh per look. What blocks walking (blocks), which part a ray meets at a height (part_at) and what items rest
## on (rest_at) stay per square, exactly CDDA's (shapes: the heights of each kind), for walking, LookRay and the item
## physics. Real models, smooth turning between snapshots and doors by hand are later slices.

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
const MAX_HULL_VERTS := 1 << 20   # per look (solid, glass), all vehicles
## Kinds drawn as the body (hull), not as shapes of their own.
const HULL_KINDS := [Kind.FRAME, Kind.BOARD, Kind.HALF, Kind.DOOR, Kind.GLASS_DOOR, Kind.WINDOW, Kind.ROOF]
## A cell's corners (x ahead, y right, cell units from its centre), counterclockwise; edge j runs from corner j to
## j + 1 and borders the neighbouring cell at _EDGE_NEXT[j].
const _CORNERS := [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]
const _EDGE_NEXT := [Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0)]
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

var view_z_max := CddaCoords.Z_LIMIT   # levels above are hidden: WorldView.things_z_max() (main.gd, refresh)
var _world: WorldView = null   # the world last applied (refresh follows its cutaway)
var _layers := {}      # Look -> MultiMeshInstance3D
var _counts := {}      # Look -> instances drawn by the last apply
var _drawn := {}       # Look -> [[Transform3D, Color], ...] drawn by the last apply (what the MultiMeshes hold)
var _hulls := {}       # Look (SOLID, GLASS) -> MeshInstance3D of all bodies
var _hull_arrays := {} # Look -> [vertices, normals, colours] the last apply drew (headless runs can't read a mesh)
var _cache := {}       # vehicle uid -> [key, {Look -> [vertices, normals, colours]}, {Look -> [[transform, colour], ...]}]
var built := 0         # vehicles drawn afresh (not from _cache), counted for tests
static var _shapes := {}       # Kind -> [[Look, AABB], ...], made once
static var _mats := {}         # Look -> Material


func _init() -> void:
	name = "Vehicles"


## Instances drawn after the last apply: all of them, or one look's.
func count(look := -1) -> int:
	if look >= 0:
		return _counts.get(look, 0)
	var n := 0
	for k: int in _counts:
		n += _counts[k]
	return n


## What the last apply drew of one look: [[transform, colour], ...], as its MultiMesh holds them (headless runs
## can't read a MultiMesh back).
func instances(look: int) -> Array:
	return _drawn.get(look, [])


## What the last apply drew of the bodies of one look (SOLID, GLASS): [vertices, normals, colours], three per
## triangle, world space.
func hull(look: int) -> Array:
	return _hull_arrays.get(look, [PackedVector3Array(), PackedVector3Array(), PackedColorArray()])


func apply(snap: Snapshot, world: WorldView) -> void:
	_world = world
	var by_look := {}   # Look -> [[Transform3D, Color], ...]
	var cache := {}
	var fresh := false
	if snap != null:
		for veh in snap.vehicles:
			var key := [veh.pos, veh.face_deg, veh.parts, view_z_max, world.coords.origin_ms, world.tables, snap.ids_generation]
			var got: Array = _cache.get(veh.uid, [])
			if got.is_empty() or got[0] != key:
				got = [key] + _vehicle(veh, snap, world)
				built += 1
				fresh = true
			cache[veh.uid] = got
			for look: int in got[2]:
				var list: Array = by_look.get(look, [])
				list.append_array((got[2][look] as Array).slice(0, maxi(0, MAX_PER_LOOK - list.size())))
				by_look[look] = list
	if fresh or cache.keys() != _cache.keys() or _hull_arrays.is_empty() != cache.is_empty():
		var hulls := {}
		for look: int in [Look.SOLID, Look.GLASS]:
			var v := PackedVector3Array()
			var nr := PackedVector3Array()
			var cl := PackedColorArray()
			for got: Array in cache.values():
				var add: Array = got[1].get(look, [])
				if not add.is_empty() and v.size() + (add[0] as PackedVector3Array).size() <= MAX_HULL_VERTS:
					v.append_array(add[0])
					nr.append_array(add[1])
					cl.append_array(add[2])
			if not v.is_empty():
				hulls[look] = [v, nr, cl]
		_hull_arrays = hulls
		_draw_hulls(hulls)
	_cache = cache
	_counts.clear()
	_drawn = by_look
	for look: int in _layers.keys():
		if not by_look.has(look):
			(_layers[look] as Node).free()
			_layers.erase(look)
	for look: int in by_look:
		var mi: MultiMeshInstance3D = _layers.get(look)
		if mi == null:
			mi = _layer(look)
			add_child(mi)
			_layers[look] = mi
		mi.position = Vector3.ZERO   # placed with today's origin: a shift moved the old ones only
		var xs: Array = by_look[look]
		var mm := mi.multimesh
		mm.instance_count = xs.size()
		for j in xs.size():
			mm.set_instance_transform(j, xs[j][0])
			mm.set_instance_color(j, xs[j][1])
		_counts[look] = xs.size()


## Each frame: a cutaway change (WorldView.things_z_max) redraws at once, not on the next snapshot.
func _process(_delta: float) -> void:
	refresh()


## Follows the cutaway of the world last applied: redraws its snapshot when things_z_max() moved.
func refresh() -> void:
	if _world == null or not is_instance_valid(_world) or _world.snapshot == null:
		return
	var z := _world.things_z_max()
	if z != view_z_max:
		view_z_max = z
		apply(_world.snapshot, _world)


func shift(d: Vector3) -> void:
	for mi: MultiMeshInstance3D in _layers.values():
		mi.position += d
	for mi: MeshInstance3D in _hulls.values():
		mi.position += d


## How a vehicle is drawn: its mount grid (x ahead, z to the right, a cell per square; y metres up from the floor of
## its level) to world. Turned smoothly by face_deg; stretched by 1 / max(|cos|, |sin|) off the axes, as CDDA's tile
## rays step (a vehicle at 45 degrees covers squares 1.4 m apart); moved to fit its parts' squares best (CDDA turns a
## vehicle about a pivot, not mount 0, 0). At right angles every cell lands on its part's square.
static func frame_of(veh: Snapshot.Vehicle, coords: CddaCoords) -> Transform3D:
	var a := deg_to_rad(veh.face_deg)
	var k := 1.0 / maxf(absf(cos(a)), absf(sin(a)))
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


## One vehicle's look: [{Look -> body [vertices, normals, colours]}, {Look -> [[transform, colour], ...]}]. Parts
## above the cutaway and gap fillers are left out.
func _vehicle(veh: Snapshot.Vehicle, snap: Snapshot, world: WorldView) -> Array:
	var xf := frame_of(veh, world.coords)
	var turn := Basis(Vector3.UP, -deg_to_rad(veh.face_deg))
	var cells := {}   # Vector3i(mount x, mount y, dz) -> {floor, low, high, glass, roof: [hp_frac, state], then Color}
	var small := []   # [kind, colour, cell, broken]
	var bases := {}   # CDDA colour of the body's parts -> votes
	for i in veh.part_count():
		var k := i * Snapshot.VPART_STRIDE
		var state := veh.parts[k + 4]
		if veh.pos.z + veh.parts[k + 7] > view_z_max or (state & Snapshot.VPART_FILLER) != 0:
			continue
		var def := def_of(world.tables, snap, veh.parts[k + 2])
		var kind := kind_of(def, state)
		if kind == Kind.NONE:
			continue
		var c := Vector3i(veh.parts[k], veh.parts[k + 1], veh.parts[k + 7])
		var cell: Dictionary = cells.get(c, {})
		cells[c] = cell
		var wear := [veh.parts[k + 3], state]
		if kind == Kind.FRAME or not cell.has("floor"):
			cell["floor"] = wear if kind == Kind.FRAME else [255, 0]
		if not (kind in HULL_KINDS):
			small.append([kind, color_of(kind, def, veh.parts[k + 3], state), c, (state & Snapshot.VPART_BROKEN) != 0])
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
		var at := xf * Vector3(c.x, c.z * CddaCoords.LEVEL_M, c.y)
		if e[0] == Kind.WHEEL:   # on the body's side, half out of it
			var side := 1.0 if not cells.has(c + Vector3i(0, 1, 0)) else (-1.0 if not cells.has(c - Vector3i(0, 1, 0)) else 0.0)
			at += turn * Vector3(0.0, 0.0, side * WHEEL_OUT)
		place(by_look, e[0], e[1], at, turn, e[3])
	return [hull_of(cells, xf), by_look]


## A vehicle's body from its cells (Vector3i(mount x, mount y, dz) -> {floor, low, high, glass, roof: Color}): a
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


## Adds the prism of `region` (cell -> colour) between heights y0 and y1 (m, plus its cell's dz levels) to out[look]:
## a face up and down per cell (unless not `caps`), a side where the neighbouring cell isn't in `sides`, a corner cut
## where neither cell beside it is in `cuts`. Faces are wound clockwise seen from outside (Godot's front faces).
static func prism(out: Dictionary, look: int, region: Dictionary, sides: Dictionary, cuts: Dictionary, y0: float,
		y1: float, xf: Transform3D, caps := true) -> void:
	if region.is_empty():
		return
	var tris := []   # [a, b, c, normal, colour], world space
	for c: Vector3i in region:
		var col: Color = region[c]
		var lo := y0 + c.z * CddaCoords.LEVEL_M
		var hi := y1 + c.z * CddaCoords.LEVEL_M
		var poly := _cell_poly(c, sides, cuts)
		var pts := []   # the outline at lo, then at hi, world space
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


## A triangle facing `n` (mount frame) in colour col, wound clockwise seen from that side: [a, b, c, normal, colour].
static func _tri(xf: Transform3D, a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> Array:
	var nw := (xf.basis * n).normalized()
	return [a, c, b, nw, col] if (b - a).cross(c - a).dot(nw) > 0.0 else [a, b, c, nw, col]


func _draw_hulls(hulls: Dictionary) -> void:
	for look: int in [Look.SOLID, Look.GLASS]:
		var mi: MeshInstance3D = _hulls.get(look)
		var arrs: Array = hulls.get(look, [])
		if arrs.is_empty() or (arrs[0] as PackedVector3Array).is_empty():
			if mi != null:
				mi.free()
				_hulls.erase(look)
			continue
		if mi == null:
			mi = MeshInstance3D.new()
			mi.name = "hull_" + Look.keys()[look].to_lower()
			mi.material_override = _material(look)
			if look == Look.GLASS:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			_hulls[look] = mi
		var data := []
		data.resize(Mesh.ARRAY_MAX)
		data[Mesh.ARRAY_VERTEX] = arrs[0]
		data[Mesh.ARRAY_NORMAL] = arrs[1]
		data[Mesh.ARRAY_COLOR] = arrs[2]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data)
		mi.mesh = mesh
		mi.position = Vector3.ZERO


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


static func _layer(look: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	if look == Look.WHEEL:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5
		cyl.bottom_radius = 0.5
		cyl.height = 1.0
		cyl.radial_segments = 12
		cyl.rings = 1
		mm.mesh = cyl
	else:
		mm.mesh = BoxMesh.new()
	var mi := MultiMeshInstance3D.new()
	mi.name = Look.keys()[look].to_lower()
	mi.multimesh = mm
	mi.material_override = _material(look)
	if look == Look.GLASS:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


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
