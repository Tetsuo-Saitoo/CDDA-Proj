class_name PartSpot
extends RefCounted
## C6 vehicle work (lead-ui's work view): where a vehicle's part is, as VehicleView draws it, in the vehicle's
## mount grid (x ahead, z to the right, a cell per square; y metres up from its floor). A part drawn as a shape is
## its shapes' box; a part not drawn (an alternator, a battery, a muffler, armour) gets a spot by CDDA's mount
## location or its flags: on the engine, on a battery mount, under the floor, on the roof. Also the side it is best
## seen from and where the work camera (WorkCamera) stands. Only CDDA's parts: nothing here is made up per vehicle.

const K := VehicleView.Kind
const DECK := VehicleView.DECK
const TOP := VehicleView.TOP
const EYE_LOW := 0.12        # m: the lowest a work camera stands (beside the vehicle, looking under it)
const NEAR_M := 1.2          # m: the nearest and furthest it stands from a part
const FAR_M := 4.0
## Spots of parts not drawn: [box in the cell, faces up (seen from above when nothing covers its square)].
const ON_ENGINE := [AABB(Vector3(-0.2, DECK + 0.6, 0.05), Vector3(0.25, 0.15, 0.25)), true]
const ON_BATTERY := [AABB(Vector3(0.05, DECK, -0.35), Vector3(0.3, 0.22, 0.2)), true]
const UNDER := [AABB(Vector3(-0.35, 0.08, -0.35), Vector3(0.7, 0.15, 0.7)), false]
const ON_ROOF := [AABB(Vector3(-0.2, TOP + VehicleView.ROOF_T, -0.2), Vector3(0.4, 0.15, 0.4)), true]
const ON_CEILING := [AABB(Vector3(-0.2, TOP - 0.12, -0.2), Vector3(0.4, 0.1, 0.4)), false]
const ARMOR := [AABB(Vector3(-0.5, DECK, -0.5), Vector3(1.0, VehicleView.SILL - DECK, 1.0)), false]
const INSIDE := [AABB(Vector3(-0.2, DECK, -0.2), Vector3(0.4, 0.3, 0.4)), true]
const BY_LOCATION := {"engine_block": ON_ENGINE, "on_battery_mount": ON_BATTERY, "under": UNDER, "axle": UNDER,
		"on_roof": ON_ROOF, "roof": ON_ROOF, "on_ceiling": ON_CEILING, "armor": ARMOR}
const BY_FLAG := [["ALTERNATOR", ON_ENGINE], ["BATTERY", ON_BATTERY], ["MUFFLER", UNDER], ["EXHAUST", UNDER]]
## Kinds seen from above (else from the side): on the roof, or in a square nothing covers.
const FROM_ABOVE := [K.ROOF, K.ROOF_LIGHT, K.TURRET]
const OPEN_ABOVE := [K.ENGINE, K.CARGO, K.SEAT, K.CONTROLS, K.OTHER]
const VIEWS := ["around", "hood", "under"]
const MAX_MOUNT := 1024      # a mount further out than this is no vehicle's square


## Part `row` of `veh` where it is drawn: {box: AABB, point: its middle, normal: the unit side it is best seen from,
## size: its longest side (m), cell: Vector2i}, all in the mount grid; {} for a row out of range or a gap filler.
static func anchor(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, row: int) -> Dictionary:
	if veh == null or row < 0 or row >= veh.part_count():
		return {}
	return _anchor(veh, snap, tables, row, cells_of(veh), null)


## anchor() for every part of `veh`: {row: anchor}, gap fillers left out. One pass over its parts for its cells and
## roofs (anchor() makes those per call): for a hand looking over all of them (lead-vr).
static func anchors(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables) -> Dictionary:
	var out := {}
	if veh == null:
		return out
	var cells := cells_of(veh)
	var roofs := roofed(veh, snap, tables)
	for row in veh.part_count():
		var a := _anchor(veh, snap, tables, row, cells, roofs)
		if not a.is_empty():
			out[row] = a
	return out


## The cells of `veh` a roof covers: {Vector2i: true}.
static func roofed(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables) -> Dictionary:
	var out := {}
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j + 4] & Snapshot.VPART_FILLER == 0 				and VehicleView.kind_of(VehicleView.def_of(tables, snap, veh.parts[j + 2]), veh.parts[j + 4]) == K.ROOF:
			out[Vector2i(veh.parts[j], veh.parts[j + 1])] = true
	return out


## anchor() with the vehicle's cells, and its roofed cells (null: looked up for this part alone).
static func _anchor(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, row: int, cells: Dictionary,
		roofs: Variant) -> Dictionary:
	var j := row * Snapshot.VPART_STRIDE
	var state := veh.parts[j + 4]
	if state & Snapshot.VPART_FILLER != 0:
		return {}
	var m := Vector2i(veh.parts[j], veh.parts[j + 1])
	var def := VehicleView.def_of(tables, snap, veh.parts[j + 2])
	var kind := VehicleView.kind_of(def, state)
	var box := AABB()
	var above := kind in FROM_ABOVE
	for sh: Array in VehicleView.shapes(kind):
		var b: AABB = sh[1]
		box = b if box.size == Vector3.ZERO else box.merge(b)
	if box.size == Vector3.ZERO:   # not drawn: a spot by where CDDA mounts it
		var spot := spot_of(def)
		box = spot[0]
		above = spot[1]
	elif kind in OPEN_ABOVE:
		above = true
	if kind == K.WHEEL:   # on the body's side, as VehicleView draws it
		var side := 1.0 if not cells.has(m + Vector2i(0, 1)) else (-1.0 if not cells.has(m - Vector2i(0, 1)) else 0.0)
		box.position.z += side * VehicleView.WHEEL_OUT
	box.position += Vector3(m.x, 0.0, m.y)
	var roof: bool = (roofs as Dictionary).has(m) if roofs is Dictionary else covered(veh, snap, tables, m)
	var up := above and (kind in FROM_ABOVE or not roof)
	return {"box": box, "point": box.get_center(), "normal": Vector3.UP if up else out_of(cells, m),
			"size": maxf(box.size.x, maxf(box.size.y, box.size.z)), "cell": m}


## Where CDDA mounts a part not drawn: [box in the cell, faces up], by its location, then its flags.
static func spot_of(def: IdTables.Def) -> Array:
	if def == null:
		return INSIDE
	if BY_LOCATION.has(def.location):
		return BY_LOCATION[def.location]
	for f: Array in BY_FLAG:
		if def.flags.has(f[0]):
			return f[1]
	return INSIDE


## The mounts of a vehicle's own cells (not its gap fillers) -> true.
static func cells_of(veh: Snapshot.Vehicle) -> Dictionary:
	var out := {}
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j + 4] & Snapshot.VPART_FILLER == 0:
			out[Vector2i(veh.parts[j], veh.parts[j + 1])] = true
	return out


## Whether a roof covers cell `m` (a part drawn as one there).
static func covered(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, m: Vector2i) -> bool:
	for i in veh.part_count():
		var j := i * Snapshot.VPART_STRIDE
		if veh.parts[j] == m.x and veh.parts[j + 1] == m.y and veh.parts[j + 4] & Snapshot.VPART_FILLER == 0 \
				and VehicleView.kind_of(VehicleView.def_of(tables, snap, veh.parts[j + 2]), veh.parts[j + 4]) == K.ROOF:
			return true
	return false


## The way out of the vehicle from cell `m` (unit, level): toward its nearest outer edge along the axes, to the
## right when it is as near both ways.
static func out_of(cells: Dictionary, m: Vector2i) -> Vector3:
	var best := Vector3(0.0, 0.0, 1.0)
	var steps := 1 << 20
	for d: Vector2i in [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]:
		var n := 0
		while cells.has(m + d * (n + 1)) and n < 256:
			n += 1
		if n < steps:
			steps = n
			best = Vector3(d.x, 0.0, d.y)
	return best


## Whether a mount is one a vehicle could have (lead-bridge's install squares come from the bridge): within MAX_MOUNT.
static func near_enough(m: Vector2i) -> bool:
	return absi(m.x) <= MAX_MOUNT and absi(m.y) <= MAX_MOUNT


## Square `mount` of `veh` (its mount grid; it may hold no part yet, as beside the vehicle): as anchor(), its box
## from the floor to the roof line, seen from out of the body (from the vehicle's middle outward for a square
## beside it); {} for a mount out of reach (near_enough).
static func square_anchor(veh: Snapshot.Vehicle, m: Vector2i) -> Dictionary:
	if veh == null or not near_enough(m):
		return {}
	var cells := cells_of(veh)
	var n := out_of(cells, m)
	if not cells.has(m) and not cells.is_empty():   # beside the vehicle: away from its middle
		var b := bounds(cells)
		var off: Vector2 = Vector2(m.x, m.y) - ((b[0] as Vector2) + (b[1] as Vector2)) * 0.5
		n = Vector3(signf(off.x), 0.0, 0.0) if absf(off.x) > absf(off.y) else Vector3(0.0, 0.0, 1.0 if off.y >= 0.0 else -1.0)
	var box := AABB(Vector3(m.x - 0.5, 0.0, m.y - 0.5), Vector3(1.0, TOP, 1.0))
	return {"box": box, "point": Vector3(m.x, 1.0, m.y), "normal": n, "size": 1.0, "cell": m}


## [lowest, highest] mount (x, z) of a vehicle's cells.
static func bounds(cells: Dictionary) -> Array:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for m: Vector2i in cells:
		lo = Vector2(minf(lo.x, m.x), minf(lo.y, m.y))
		hi = Vector2(maxf(hi.x, m.x), maxf(hi.y, m.y))
	return [lo, hi]


## Where the line from `at` to `eye` comes out of the vehicle (mount grid): past its cells or over its roof; `eye`
## when it never does. From there on what stands around it (a wall) may be in the way (WorkCamera.blocked).
static func exit_of(cells: Dictionary, at: Vector3, eye: Vector3) -> Vector3:
	var d := eye - at
	var steps := mini(ceili(d.length() / 0.05), 400)
	for i in range(1, steps + 1):
		var p := at + d * (float(i) / steps)
		if p.y > TOP + VehicleView.ROOF_T + 0.05 or not cells.has(Vector2i(roundi(p.x), roundi(p.z))):
			return p
	return eye


## Where the work camera stands: [eye, look-at point, where the line between them leaves the vehicle (exit_of)] in
## the mount grid; [] when there is nothing to look at. "part": at part `row` from its side (out past the body,
## raised a little; from above where nothing covers it); "around": ahead and right of the vehicle, above it; "hood":
## over its engines (the front row with none); "under": low beside its right side, looking under the body.
static func work_pose(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, what: String, row := -1) -> Array:
	var cells := cells_of(veh)
	if cells.is_empty():
		return []
	var p := _pose(veh, snap, tables, cells, what, row)
	return p + [exit_of(cells, p[1], p[0])] if p.size() == 2 else []


## work_pose for square `mount` (square_anchor): the camera out from it on its side.
static func square_pose(veh: Snapshot.Vehicle, m: Vector2i) -> Array:
	var cells := cells_of(veh)
	var a := square_anchor(veh, m)
	if cells.is_empty() or a.is_empty():
		return []
	var b := bounds(cells)
	var eye := part_eye(a, cells, b[0], b[1])
	return [eye, a["point"], exit_of(cells, a["point"], eye)]


static func _pose(veh: Snapshot.Vehicle, snap: Snapshot, tables: IdTables, cells: Dictionary, what: String, row: int) -> Array:
	var b := bounds(cells)
	var lo: Vector2 = b[0]
	var hi: Vector2 = b[1]
	var mid := Vector3((lo.x + hi.x) * 0.5, 0.0, (lo.y + hi.y) * 0.5)
	match what:
		"part":
			var a := anchor(veh, snap, tables, row)
			if a.is_empty():
				return []
			return [part_eye(a, cells, lo, hi), a["point"]]
		"around":
			return [Vector3(hi.x + 2.5, 2.6, hi.y + 2.5), mid + Vector3.UP * 0.8]
		"hood":
			var sum := Vector3.ZERO
			var n := 0
			for i in veh.part_count():
				var j := i * Snapshot.VPART_STRIDE
				if veh.parts[j + 4] & Snapshot.VPART_FILLER == 0 \
						and VehicleView.kind_of(VehicleView.def_of(tables, snap, veh.parts[j + 2]), veh.parts[j + 4]) == K.ENGINE:
					sum += Vector3(veh.parts[j], 0.0, veh.parts[j + 1])
					n += 1
			var at := sum / n if n > 0 else Vector3(hi.x, 0.0, mid.z)
			at.y = DECK + 0.5
			var ahead := 1.0 if at.x >= mid.x else -1.0   # an engine at the back is seen from behind
			return [at + Vector3(ahead * 1.3, 1.5, 0.0), at]
		"under":
			return [Vector3(mid.x, EYE_LOW, hi.y + 1.3), Vector3(mid.x, 0.3, mid.z)]
	return []


## Where the camera stands to see part anchor `a`: along its normal (with a little height; from above, a little
## outward too), past the body's edge, NEAR_M..FAR_M off, never under EYE_LOW.
static func part_eye(a: Dictionary, cells: Dictionary, lo: Vector2, hi: Vector2) -> Vector3:
	var n: Vector3 = a["normal"]
	var p: Vector3 = a["point"]
	var d := clampf(float(a["size"]) * 2.0 + 0.9, NEAR_M, FAR_M)
	var dir: Vector3
	if n == Vector3.UP:
		dir = (n + out_of(cells, a["cell"]) * 0.6).normalized()
	else:
		dir = (n + Vector3.UP * (0.45 if p.y >= DECK else 0.05)).normalized()
		var edge := 0.0   # how far the body runs on that way from the part
		if absf(n.z) > 0.5:
			edge = (hi.y + 0.5 - p.z) if n.z > 0.0 else (p.z - lo.y + 0.5)
		else:
			edge = (hi.x + 0.5 - p.x) if n.x > 0.0 else (p.x - lo.x + 0.5)
		d = maxf(d, edge + 0.9)
	var eye := p + dir * d
	eye.y = maxf(eye.y, EYE_LOW)
	return eye
