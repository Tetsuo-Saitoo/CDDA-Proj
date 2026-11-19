extends RefCounted
## Block C5 slice 1, vehicles: the snapshot's `vehicles` read as hostile input (Snapshot.vehicles_from: a malformed
## vehicle or part is left out, caps hold, the snapshot still loads), the part squares (the bridge's dx, dy, dz as
## they are, checked against CDDA's own for an L of four frames at 0, 90 and 45 degrees; without them the mounts
## turned by the facing, CDDA's own at right angles), VehicleView's look (slice 2: one body per vehicle in its own
## grid, closed and on its cells; the small parts on their squares, turned, tinted; kept until the vehicle changes;
## after a map shift every view sits at the origin again), what
## blocks walking (CDDA's obstacle rule, gap fillers too) and LookRay naming the vehicle and part. Walking into cars:
## vr_tests.gd; items on them: item_physics_tests.gd. Run by run_tests.gd.

var _check: Callable

const P := Vector3i(192, 384, 0)     # the mock town's player; the road east of it is open
const CAR := Vector3i(195, 385, 0)   # the test car's pos: six squares east along y 385
const UID := 77


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vehicles (C5)")
	_test_mock(data, tables)
	_test_hostile(data)
	_test_caps()
	_test_squares()
	_test_view(root, data, tables)


## The mock town without its vehicles and with one test car, facing east (face_deg 0), parts as 8-int rows (CDDA's
## squares); `edit` changes the car.
func _data(data: Variant, tables: IdTables, edit := Callable()) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var v := func(id: String) -> int: return tables.index_of("vpart", id)
	var frame: int = v.call("frame")
	var parts := []
	# square 0 a board, 1 a closed door, 2 an open door, 3 frame only, 4 a broken halfboard, 5 a windshield with a roof
	var plan := [["board", 0], ["door", 0], ["door", 1], ["", 0], ["halfboard", 2], ["windshield", 0]]
	for x in plan.size():
		parts.append([x, 0, frame, 255, 0, x, 0, 0])
		if not (plan[x][0] as String).is_empty():
			parts.append([x, 0, v.call(plan[x][0]), 128 if x == 0 else 255, plan[x][1], x, 0, 0])
	parts.append([5, 0, v.call("roof"), 255, 0, 5, 0, 0])
	parts.append([0, 1, frame, 255, 0, 0, 1, 0])
	parts.append([0, 1, v.call("wheel"), 255, 0, 0, 1, 0])
	# a gap filler copying the board, one square south-east of it (as CDDA adds on a turned vehicle's diagonal)
	parts.append([0, 0, v.call("board"), 255, Snapshot.VPART_FILLER, 1, 1, 0])
	var car := {"uid": UID, "name": "Test Car", "pos": [CAR.x, CAR.y, CAR.z], "face_deg": 0.0, "turn_deg": 0.0,
			"velocity": 0.0, "parts": parts}
	d["vehicles"] = [car]
	if edit.is_valid():
		edit.call(car)
	return d


func _test_mock(data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(data)
	var vs := snap.vehicles
	var first: Snapshot.Vehicle = vs[0] if not vs.is_empty() else null
	_check.call(snap.is_valid() and vs.size() == 35 and first.name == "Rolling Trash Can" and first.pos == Vector3i(138, 382, 0)
			and first.face_deg == 180.0 and first.part_count() == 3 and not first.exact and first.uid == 8589934592,
			"vehicles: the mock town's 35 are read (names, positions, facings, parts)")
	# Without dx, dy the mounts are turned by the facing. The mock's tile flags (bit 3) are CDDA's own vehicle squares:
	# every vehicle turned about mount 0,0 matches them; the armored car turns about another pivot, one square off
	# (why the bridge is to send dx, dy).
	var flagged := {}
	for sm: Snapshot.Submap in snap.submaps.values():
		var base := CddaCoords.sm_to_ms(sm.pos)
		for t in Snapshot.TILES:
			if (sm.flags[t] & Snapshot.FLAG_VEHICLE) != 0:
				flagged[base + Vector3i(t % CddaCoords.SEEX, t / CddaCoords.SEEX, 0)] = true
	var off := PackedStringArray()
	var matched := 0
	for veh in vs:
		for i in veh.part_count():
			var sq := veh.square(i)
			if not snap.submaps.has(CddaCoords.ms_to_sm(sq)):
				continue   # outside the mock's loaded area
			if flagged.has(sq):
				matched += 1
			elif not veh.name in off:
				off.append(veh.name)
	_check.call(matched > 700 and Array(off) == ["Armored Car"],
			"vehicles: mounts turned by right-angle facings land on CDDA's vehicle squares (%d parts; off: %s)" % [matched, off])
	var kinds := {}
	for veh in vs:
		for i in veh.part_count():
			var k := VehicleView.kind_of(VehicleView.def_of(tables, snap, veh.parts[i * Snapshot.VPART_STRIDE + 2]),
					veh.parts[i * Snapshot.VPART_STRIDE + 4])
			kinds[k] = true
	var want := [VehicleView.Kind.FRAME, VehicleView.Kind.HALF, VehicleView.Kind.WINDOW, VehicleView.Kind.ROOF,
			VehicleView.Kind.WHEEL, VehicleView.Kind.SEAT, VehicleView.Kind.DOOR, VehicleView.Kind.GLASS_DOOR,
			VehicleView.Kind.ENGINE, VehicleView.Kind.TANK, VehicleView.Kind.CARGO, VehicleView.Kind.LIGHT,
			VehicleView.Kind.TURRET, VehicleView.Kind.CONTROLS, VehicleView.Kind.NONE]
	_check.call(want.all(func(k: int) -> bool: return kinds.has(k)),
			"vehicles: the mock's parts sort into kinds by their flags and location (%s)" % [kinds.keys()])


func _test_hostile(data: Variant) -> void:
	var good := {"uid": 5, "name": "<color_red>Evil</color>\u0007 Car" + "x".repeat(100), "pos": [10, 20, 0],
			"face_deg": -90.0, "velocity": 1e9, "parts": [[0, 0, 3, 255, 0], [1, 0, 3, 255, 9, 7, 8, 1]]}
	var bad_parts := [
		"x", [0, 0, 3, 255], [0, 0, 3, 255, 0, 1], [0, 0, 3, 255, 0, 1, 2], [0, 0, 3, 255, 0, 1, 2, 0, 0],
		[129, 0, 3, 255, 0], [0, 0, 0, 255, 0], [0, 0, 3, 256, 0], [0, 0, 3, 255, 16], [0, 0, 3, 255, -1],
		[0, 0, 3, 255, 0, 257, 0, 0], [0, 0, 3, 255, 0, 0, 0, 5], [0, 0, 3, 255, 0, 0, 0, 11], [0.5, 0, 3, 255, 0],
		[0, "0", 3, 255, 0], [0, 0, 1 << 21, 255, 0], [0, 0, 3, NAN, 0], [0, 0, 3, 255, 0, INF, 0, 0], null,
	]
	var vs := [
		good, "junk", null, 7,
		{"uid": 5, "pos": [1, 1, 0], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},        # the same uid again
		{"uid": 0, "pos": [1, 1, 0], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 1.5, "pos": [1, 1, 0], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": -3, "pos": [1, 1, 0], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 6, "pos": [1, 1], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 7, "pos": [1, 1, 99], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 8, "pos": [1e12, 1, 0], "face_deg": 0.0, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 9, "pos": [1, 1, 0], "face_deg": NAN, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 10, "pos": [1, 1, 0], "face_deg": 1e9, "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 11, "pos": [1, 1, 0], "face_deg": "east", "parts": [[0, 0, 3, 255, 0]]},
		{"uid": 12, "pos": [1, 1, 0], "face_deg": 0.0, "parts": "all"},
		{"uid": 13, "pos": [1, 1, 0], "face_deg": 0.0, "parts": []},
		{"uid": 14, "pos": [1, 1, 0], "face_deg": 0.0, "parts": bad_parts},
		{"uid": 15, "pos": [1, 1, 0], "face_deg": 0.0, "turn_deg": NAN, "velocity": -INF, "name": 42,
				"parts": bad_parts + [[2, -3, 4, 0, 7]]},
	]
	var out := Snapshot.vehicles_from(vs, -10, 10)
	var g: Snapshot.Vehicle = out[0] if out.size() == 2 else null
	var h: Snapshot.Vehicle = out[1] if out.size() == 2 else null
	_check.call(g != null and g.uid == 5 and g.name.begins_with("Evil Car") and g.name.length() == 60
			and g.face_deg == 270.0 and g.turn_deg == 270.0 and g.velocity == 0.0 and not g.exact and g.part_count() == 2
			and g.square(0) == Vector3i(10, 20, 0) and g.square(1) == Vector3i(17, 28, 1)
			and h.uid == 15 and h.name == "" and h.turn_deg == 0.0 and h.velocity == 0.0 and h.part_count() == 1
			and Array(h.parts) == [2, -3, 4, 0, 7, 2, -3, 0],
			"vehicles: hostile entries are left out (bad uid, repeated uid, position, level, facing, parts); names are plain and capped")
	var top := Snapshot.vehicles_from([{"uid": 1, "pos": [0, 0, 10], "face_deg": 0.0,
			"parts": [[0, 0, 3, 255, 0, 0, 0, 1], [0, 0, 3, 255, 0, 0, 0, -1]]}], -10, 10)
	_check.call(top.size() == 1 and top[0].part_count() == 1 and top[0].square(0) == Vector3i(0, 0, 9),
			"vehicles: a part off the vehicle's level stays within the map's levels")
	var d: Dictionary = (data as Dictionary).duplicate(true)
	d["vehicles"] = {"not": "a list"}
	var snap := Snapshot.from_data(d)
	d["vehicles"] = vs
	var snap2 := Snapshot.from_data(d)
	_check.call(snap.is_valid() and snap.vehicles.is_empty() and snap2.is_valid() and snap2.vehicles.size() == 2,
			"vehicles: malformed vehicles never fail the snapshot")


func _test_caps() -> void:
	var many := []
	for i in Snapshot.MAX_VEHICLES + 20:
		many.append({"uid": i + 1, "pos": [i, 0, 0], "face_deg": 0.0, "parts": [[0, 0, 1, 255, 0]]})
	var big := []
	for i in Snapshot.MAX_VEHICLE_PARTS + 10:
		big.append([i % 100, i / 100, 1, 255, 0])
	var heavy := []
	for i in 20:
		heavy.append({"uid": i + 1, "pos": [0, 0, 0], "face_deg": 0.0, "parts": big})
	var a := Snapshot.vehicles_from(many, 0, 0)
	var b := Snapshot.vehicles_from(heavy, 0, 0)
	var total := 0
	for veh in b:
		total += veh.part_count()
	_check.call(a.size() == Snapshot.MAX_VEHICLES and a[-1].uid == Snapshot.MAX_VEHICLES
			and b[0].part_count() == Snapshot.MAX_VEHICLE_PARTS and total == Snapshot.MAX_ALL_VEHICLE_PARTS
			and b.size() == Snapshot.MAX_ALL_VEHICLE_PARTS / Snapshot.MAX_VEHICLE_PARTS,
			"vehicles: at most %d vehicles, %d parts each and %d in all (%d, %d)" % [Snapshot.MAX_VEHICLES,
			Snapshot.MAX_VEHICLE_PARTS, Snapshot.MAX_ALL_VEHICLE_PARTS, a.size(), total])


## Part squares: the bridge's dx, dy, dz as sent; without them the mount turned by the facing, CDDA's own at right
## angles (tileray: 0 east, 90 south; mount x ahead, y to the right).
func _test_squares() -> void:
	# CDDA's own squares for an L of four frames turned about its origin part (the bridge's fp3d-snapshot-test, 0.I):
	# facing -> [[mount, offset], ...]. At 45 degrees CDDA steps (0, 1) to (-1, 0) and (2, 0) to (2, 2), where turning
	# and rounding gives (-1, 1) and (1, 1).
	var cdda := {
		0.0: [[Vector2i(0, 0), Vector2i(0, 0)], [Vector2i(1, 0), Vector2i(1, 0)], [Vector2i(2, 0), Vector2i(2, 0)],
				[Vector2i(0, 1), Vector2i(0, 1)]],
		90.0: [[Vector2i(0, 0), Vector2i(0, 0)], [Vector2i(1, 0), Vector2i(0, 1)], [Vector2i(2, 0), Vector2i(0, 2)],
				[Vector2i(0, 1), Vector2i(-1, 0)]],
		45.0: [[Vector2i(0, 0), Vector2i(0, 0)], [Vector2i(1, 0), Vector2i(1, 1)], [Vector2i(2, 0), Vector2i(2, 2)],
				[Vector2i(0, 1), Vector2i(-1, 0)]],
	}
	var exact_ok := true
	var turned_off := {}   # facing -> mounts the 5-int fallback puts elsewhere than CDDA
	for f: float in cdda:
		var rows := []
		var short := []
		for e: Array in cdda[f]:
			rows.append([e[0].x, e[0].y, 3, 255, 0, e[1].x, e[1].y, 0])
			short.append([e[0].x, e[0].y, 3, 255, 0])
		var a := Snapshot.vehicles_from([{"uid": 1, "pos": [50, 60, 0], "face_deg": f, "parts": rows}], 0, 0)
		var b := Snapshot.vehicles_from([{"uid": 1, "pos": [50, 60, 0], "face_deg": f, "parts": short}], 0, 0)
		var off := []
		for k in (cdda[f] as Array).size():
			var want := Vector3i(50 + cdda[f][k][1].x, 60 + cdda[f][k][1].y, 0)
			exact_ok = exact_ok and a.size() == 1 and a[0].exact and a[0].square(k) == want
			if b.size() != 1 or b[0].square(k) != want:
				off.append(cdda[f][k][0])
		turned_off[f] = off
	_check.call(exact_ok, "vehicles: an L car at 0, 90 and 45 degrees lands on CDDA's own squares (the bridge's dx, dy)")
	_check.call((turned_off[0.0] as Array).is_empty() and (turned_off[90.0] as Array).is_empty()
			and turned_off[45.0] == [Vector2i(2, 0), Vector2i(0, 1)],
			"vehicles: without dx, dy the turned mounts are CDDA's at 0 and 90 degrees, a square off at 45 (%s)" % [turned_off])
	var m := Vector2i(2, 1)
	var t := func(f: float) -> Vector2i: return Snapshot.turn_mount(m, f)
	_check.call(t.call(0.0) == Vector2i(2, 1) and t.call(90.0) == Vector2i(-1, 2) and t.call(180.0) == Vector2i(-2, -1)
			and t.call(270.0) == Vector2i(1, -2) and t.call(45.0) == Vector2i(1, 2),
			"vehicles: mounts turn as CDDA's do at 0, 90, 180 and 270 degrees (45: %s)" % t.call(45.0))
	# CDDA's gap fillers (the bridge's fp3d-snapshot-test): a wall of three boards on frames at 45 degrees gets two, the
	# boards of (0, 0) and (1, 0) copied onto 1, 0 and 2, 1; both squares are the vehicle's and block.
	var tables := IdTables.from_data({"generation": 1, "ter": [], "furn": [], "trap": [], "field": [], "itype": [],
			"vpart": [{"id": ""}, {"id": "frame", "name": "frame", "location": "structure", "flags": ["MOUNTABLE"]},
			{"id": "board", "name": "board", "location": "center", "flags": ["FULL_BOARD", "OBSTACLE", "OPAQUE"]}]})
	var wall := []
	for k: Array in [[0, 0, 0], [1, 1, 1], [2, 2, 2]]:
		wall.append([k[0], 0, 1, 255, 0, k[1], k[2], 0])
		wall.append([k[0], 0, 2, 255, 0, k[1], k[2], 0])
	wall.append([0, 0, 2, 255, Snapshot.VPART_FILLER, 1, 0, 0])
	wall.append([1, 0, 2, 255, Snapshot.VPART_FILLER, 2, 1, 0])
	var snap := Snapshot.new()
	snap.ids_generation = 1
	snap.vehicles = Snapshot.vehicles_from([{"uid": 4, "pos": [20, 30, 0], "face_deg": 45.0, "parts": wall}], 0, 0)
	var at_filler := snap.vehicle_at(Vector3i(21, 30, 0))
	_check.call(tables.is_valid() and snap.vehicles.size() == 1 and snap.vehicles[0].part_count() == 8 and not at_filler.is_empty()
			and Array(at_filler[1]) == [6] and VehicleView.blocks(snap, tables, Vector3i(21, 30, 0))
			and VehicleView.blocks(snap, tables, Vector3i(22, 31, 0)) and VehicleView.blocks(snap, tables, Vector3i(21, 31, 0))
			and not VehicleView.blocks(snap, tables, Vector3i(20, 31, 0)),
			"vehicles: CDDA's gap fillers on a wall at 45 degrees are the vehicle's squares and block like the boards they copy")
	var vs := Snapshot.vehicles_from([{"uid": 1, "pos": [100, 100, 0], "face_deg": 45.0,
			"parts": [[2, 1, 3, 255, 0, 1, 3, 0], [3, 0, 3, 255, 0, 2, 2, 1]]}], 0, 1)
	_check.call(vs.size() == 1 and vs[0].exact and vs[0].square(0) == Vector3i(101, 103, 0) and vs[0].square(1) == Vector3i(102, 102, 1),
			"vehicles: the bridge's own squares (dx, dy, dz) are used as they are")


## The test car's body (face 0: its cells on its squares): inside its cells and heights; walls above the deck only
## on the board, the closed door and the windshield (not on bare frame, the open door or the broken halfboard); glass
## in the closed door and the windshield; the roof over the windshield. A body's prism is closed, faces wound
## clockwise seen from outside, outer corners cut; at 45 degrees the frame puts each cell near CDDA's own square.
func _test_hull(view: VehicleView, car: Snapshot.Vehicle, world: WorldView) -> void:
	var inv := VehicleView.frame_of(car, world.coords).affine_inverse()
	var solid := view.hull(VehicleView.Look.SOLID)
	var glass := view.hull(VehicleView.Look.GLASS)
	var vs: PackedVector3Array = solid[0]
	var inside := vs.size() > 0 and vs.size() % 3 == 0 and (solid[1] as PackedVector3Array).size() == vs.size() \
			and (solid[2] as PackedColorArray).size() == vs.size()
	var walls := true
	var roof := false
	for p: Vector3 in vs:
		var m := inv * p
		inside = inside and m.x > -0.51 and m.x < 5.51 and m.z > -0.51 and m.z < 1.51 and m.y > VehicleView.CLEAR - 0.01 \
				and m.y < VehicleView.TOP + VehicleView.ROOF_T + 0.01
		if m.y > VehicleView.DECK + 0.01:
			walls = walls and (m.x < 1.51 or m.x > 4.49) and m.z < 0.51
		roof = roof or (m.y > VehicleView.TOP + 0.01 and m.x > 4.49)
	var panes := (glass[0] as PackedVector3Array).size() > 0
	for p: Vector3 in glass[0]:
		var m := inv * p
		panes = panes and m.y > VehicleView.SILL - 0.01 and m.y < VehicleView.TOP + 0.01 and m.z < 0.51 \
				and ((m.x > 0.49 and m.x < 1.51) or m.x > 4.49)
	_check.call(inside and walls and roof and panes,
			"vehicles: one body on the car's cells: walls on the board, closed door and windshield, glass above the door and windshield, the roof (%d, %d vertices)" % [vs.size(), (glass[0] as PackedVector3Array).size()])
	var out := {}
	var region := {Vector3i(0, 0, 0): Color.RED, Vector3i(1, 0, 0): Color.RED, Vector3i(0, 1, 0): Color.RED}
	var xf := Transform3D(Basis(Vector3.UP, 0.7) * Basis.from_scale(Vector3(1.4, 1.0, 1.4)), Vector3(3.0, 0.0, 2.0))
	VehicleView.prism(out, VehicleView.Look.SOLID, region, region, region, 0.0, 1.0, xf)
	var lv: PackedVector3Array = out[VehicleView.Look.SOLID][0]
	var ln: PackedVector3Array = out[VehicleView.Look.SOLID][1]
	var area := Vector3.ZERO
	var clockwise := lv.size() > 0
	var sides := 0
	for t in range(0, lv.size(), 3):
		var cr := (lv[t + 1] - lv[t]).cross(lv[t + 2] - lv[t])
		area += cr
		clockwise = clockwise and cr.dot(ln[t]) < 0.0
		sides += 1 if absf(ln[t].y) < 0.01 else 0
	_check.call(area.length() < 1e-3 and clockwise and sides == 26,
			"vehicles: a body is closed, wound clockwise seen from outside, its 5 outer corners of an L cut (%s, %d side triangles)" % [area, sides])
	var l45 := Snapshot.vehicles_from([{"uid": 1, "pos": [100, 100, 0], "face_deg": 45.0,
			"parts": [[0, 0, 1, 255, 0, 0, 0, 0], [1, 0, 1, 255, 0, 1, 1, 0], [2, 0, 1, 255, 0, 2, 2, 0], [0, 1, 1, 255, 0, -1, 0, 0]]}], 0, 0)
	var f45 := VehicleView.frame_of(l45[0], world.coords)
	var worst := 0.0
	for i in 4:
		var k := i * Snapshot.VPART_STRIDE
		var at := f45 * Vector3(l45[0].parts[k], 0.0, l45[0].parts[k + 1])
		var sq := world.coords.ms_center_to_world(l45[0].square(i))
		worst = maxf(worst, Vector2(at.x - sq.x, at.z - sq.z).length())
	var a45 := f45.basis * Vector3.RIGHT
	_check.call(worst < 0.8 and is_equal_approx(a45.length(), sqrt(2.0)) and absf(a45.x - a45.z) < 1e-4,
			"vehicles: at 45 degrees the body is turned smoothly, stretched as CDDA steps, each cell within %.2f of its square" % worst)


## After a map shift (the world's origin moves; main.gd sends shift) and the next snapshot, the vehicle, field and gore
## views sit at the origin again: what they draw was placed with the new origin, so it lands once, not twice.
func _test_shift(root: Node, view: VehicleView, snap: Snapshot, world: WorldView) -> void:
	var fields := FieldView.new()
	var gore := GoreView.new()
	root.add_child(fields)
	root.add_child(gore)
	fields.apply(snap, world)
	gore.apply(snap, world)
	view.apply(snap, world)
	var before: Vector3 = view.hull(VehicleView.Look.SOLID)[0][0]
	var o0: Vector3 = (view.drawn(UID) as Transform3D).origin
	var d := world.coords.set_bubble_origin(snap.bubble_origin + Vector3i(1, 0, 0))
	for v: Node in [view, fields, gore]:
		v.call("shift", d)
	var moved := (view.drawn(UID) as Transform3D).origin.is_equal_approx(o0 + d)
	for v: Node in [view, fields, gore]:
		v.call("apply", snap, world)
	var after: Vector3 = view.hull(VehicleView.Look.SOLID)[0][0]
	var home := fields.get_child_count() + gore.get_child_count() > 0 \
			and (view.drawn(UID) as Transform3D).origin.is_equal_approx(o0 + d)
	for v: Node in [fields, gore]:
		for c: Node in v.get_children():
			home = home and (c as Node3D).position == Vector3.ZERO
	var back := world.coords.set_bubble_origin(snap.bubble_origin)
	for v: Node in [view, fields, gore]:
		v.call("shift", back)
		v.call("apply", snap, world)
	_check.call(d != Vector3.ZERO and moved and home and after.is_equal_approx(before + d),
			"vehicles: after a map shift the vehicle, field and gore views are placed once, not twice (%s -> %s)" % [before, after])
	fields.queue_free()
	gore.queue_free()


## Slice 3: a vehicle that moved glides from where it is drawn to its new pose over about the time it took (its mesh
## kept), and the eyes of a player on it ride along (ride_transform); a far jump shows at once. A car on sloping
## ground leans with it (tilt_of); flat ground gives no tilt.
func _test_glide(view: VehicleView, snap: Snapshot, world: WorldView) -> void:
	var car := snap.vehicles[0]
	var b0 := view.built
	var start: Transform3D = view.drawn(UID)
	var e0 := world.coords.ms_center_to_world(car.square(0))
	car.pos += Vector3i(3, 0, 0)
	snap.vehicles_moved()
	view.apply(snap, world)
	var c: VehicleView.Car = view._cars[UID]
	var at0: Transform3D = view.drawn(UID)
	view.glide(c.dur * 0.5)
	var mid: Transform3D = view.drawn(UID)
	var player := snap.player_pos
	snap.player_pos = car.square(0)
	var e1 := world.coords.ms_center_to_world(car.square(0))
	var seated := (view.ride_transform(snap) * e1).is_equal_approx(e0.lerp(e1, 0.5))
	view.glide(c.dur)
	var arrived := view.ride_transform(snap) == Transform3D() and (view.drawn(UID) as Transform3D).is_equal_approx(c.to)
	snap.player_pos = player
	_check.call(view.built == b0 and at0.is_equal_approx(start) and mid.origin.is_equal_approx(start.origin.lerp(c.to.origin, 0.5))
			and seated and arrived and c.dur >= VehicleView.GLIDE_MIN and c.dur <= VehicleView.GLIDE_MAX,
			"vehicles: a car that moved glides there over %.2f s, its mesh kept, and the eyes ride with it" % c.dur)
	car.pos += Vector3i(97, 0, 0)
	snap.vehicles_moved()
	view.apply(snap, world)
	var far := (view.drawn(UID) as Transform3D).is_equal_approx(c.to)
	car.pos -= Vector3i(100, 0, 0)
	snap.vehicles_moved()
	view.apply(snap, world)
	view.glide(10.0)
	_check.call(far and (view.drawn(UID) as Transform3D).is_equal_approx(start),
			"vehicles: a far jump (a teleport, the map loaded again) is shown at once")
	var ramp := VehicleView.tilt_of([Vector3(0, 0, 0), Vector3(1, 0.5, 0), Vector3(2, 1.0, 0), Vector3(0, 0, 1),
			Vector3(1, 0.5, 1), Vector3(2, 1.0, 1)])
	var ahead := ramp.basis * Vector3.RIGHT
	var steep := VehicleView.tilt_of([Vector3(0, 0, 0), Vector3(1, 3.0, 0)])
	var side := VehicleView.tilt_of([Vector3(0, 0, 0), Vector3(0, 0.25, 1), Vector3(1, 0, 0), Vector3(1, 0.25, 1)])
	var flat := VehicleView.pose_of(car, world)
	_check.call(is_equal_approx(ahead.y / ahead.x, 0.5) and absf(ahead.z) < 1e-5 and absf(ramp.origin.y) < 1e-5
			and is_equal_approx((steep.basis * Vector3.RIGHT).angle_to(Vector3.RIGHT), atan(VehicleView.MAX_SLOPE))
			and is_equal_approx((side.basis * Vector3.BACK).y / (side.basis * Vector3.BACK).z, 0.25)
			and (flat.basis * Vector3.UP).is_equal_approx(Vector3.UP),
			"vehicles: on a ramp a car leans with the ground under it (along and across, at most 45 degrees); flat ground, no lean")


func _test_view(root: Node, data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(_data(data, tables))
	if not snap.is_valid() or snap.vehicles.size() != 1:
		_check.call(false, "vehicles: the test car loads " + snap.error)
		return
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := VehicleView.new()
	root.add_child(view)
	view.apply(snap, world)
	var car := snap.vehicles[0]
	var squares := {}
	for i in car.part_count():
		squares[car.square(i)] = true
	var on_squares := true
	for look: int in [VehicleView.Look.SOLID, VehicleView.Look.GLASS, VehicleView.Look.WHEEL]:
		for e: Array in view.instances(look):
			var sq := world.coords.world_to_ms((e[0] as Transform3D).origin)
			on_squares = on_squares and squares.has(Vector3i(sq.x, sq.y, CAR.z))
	_check.call(view.count(VehicleView.Look.SOLID) == 1 and view.count(VehicleView.Look.GLASS) == 0
			and view.count(VehicleView.Look.WHEEL) == 1 and on_squares,
			"vehicles: the small parts (an open door, a wheel) are drawn on their own squares (%d solid, %d glass, %d wheels)" % [view.count(VehicleView.Look.SOLID),
			view.count(VehicleView.Look.GLASS), view.count(VehicleView.Look.WHEEL)])
	_test_hull(view, car, world)
	var b0 := view.built
	view.apply(snap, world)
	var cached := view.built == b0
	var wheel_axis := func() -> Vector3:
		var ws := view.instances(VehicleView.Look.WHEEL)
		return ((ws[0][0] as Transform3D).basis * Vector3.UP).normalized() if not ws.is_empty() else Vector3.ZERO
	var east: Vector3 = wheel_axis.call()
	car.face_deg = 90.0
	view.apply(snap, world)
	var south: Vector3 = wheel_axis.call()
	_check.call(absf(east.z) > 0.99 and absf(south.x) > 0.99,
			"vehicles: parts turn with the facing (wheel axles across the car: %s facing east, %s facing south)" % [east, south])
	var turned_kept := view.built == b0
	car.face_deg = 45.0
	view.apply(snap, world)
	_check.call(cached and turned_kept and view.built == b0 + 1,
			"vehicles: a vehicle's mesh is kept while it moves or turns by right angles, built again when its stretch changes (%d, %d)" % [b0, view.built])
	car.face_deg = 0.0
	view.apply(snap, world)
	view.glide(10.0)
	_test_shift(root, view, snap, world)
	_test_glide(view, snap, world)
	# tint: the half-broken board is darker than intact, the broken halfboard charred, glass only where unbroken
	var def := func(id: String) -> IdTables.Def: return tables.def_named("vpart", id)
	var intact := VehicleView.color_of(VehicleView.Kind.BOARD, def.call("board"), 255, 0)
	var half := VehicleView.color_of(VehicleView.Kind.BOARD, def.call("board"), 128, 0)
	var broken := VehicleView.color_of(VehicleView.Kind.BOARD, def.call("board"), 255, Snapshot.VPART_BROKEN)
	var glass := {}
	VehicleView.place(glass, VehicleView.Kind.WINDOW, intact, Vector3.ZERO, Basis(), true)
	var worn_tyre := VehicleView.color_of(VehicleView.Kind.WHEEL, def.call("wheel"), 0, 0)
	_check.call(half.get_luminance() < intact.get_luminance() and broken.get_luminance() < half.get_luminance()
			and not glass.has(VehicleView.Look.GLASS) and glass.has(VehicleView.Look.SOLID) and worn_tyre == VehicleView.TYRE,
			"vehicles: damaged parts darken, broken ones char, broken glass is gone, worn tyres stay black")
	var b1 := view.built
	view.max_verts = 0
	view.apply(snap, world)
	var none := view.get_child_count() == 0 and view.count() == 0 and view.built == b1
	view.max_verts = VehicleView.MAX_VERTS
	view.apply(snap, world)
	_check.call(none and view.get_child_count() == 1 and view.built == b1 + 1,
			"vehicles: past the vertex budget for all vehicles the rest aren't built; drawn again when there's room")
	view.view_z_max = CAR.z - 1
	view.apply(snap, world)
	_check.call(view.count() == 0 and view.hull(VehicleView.Look.SOLID)[0].is_empty() and view.get_child_count() == 0,
			"vehicles: a car above the cutaway isn't drawn")
	# blocking, as CDDA's vehicle::obstacle_at_part
	var sq := func(x: int) -> Vector3i: return CAR + Vector3i(x, 0, 0)
	var blocks := func(x: int) -> bool: return VehicleView.blocks(snap, tables, sq.call(x))
	_check.call(blocks.call(0) and blocks.call(1) and not blocks.call(2) and not blocks.call(3) and not blocks.call(4)
			and blocks.call(5) and not blocks.call(6) and not VehicleView.blocks(snap, tables, CAR + Vector3i(0, 1, 0))
			and VehicleView.blocks(snap, tables, CAR + Vector3i(1, 1, 0)) and not VehicleView.blocks(snap, null, sq.call(0)),
			"vehicles: a board, a closed door, a windshield and a gap filler copying a board block walking; an open door, bare frame, a broken board, wheels and parts without id tables don't")
	_check.call(VehicleView.rest_at(snap, tables, sq.call(0)) == VehicleView.TOP and VehicleView.rest_at(snap, tables, sq.call(3)) == VehicleView.DECK
			and is_equal_approx(VehicleView.rest_at(snap, tables, sq.call(5)), VehicleView.TOP + VehicleView.ROOF_T)
			and VehicleView.rest_at(snap, tables, sq.call(6)) == 0.0 and is_equal_approx(VehicleView.rest_at(snap, tables, CAR + Vector3i(0, 1, 0)), 0.8),
			"vehicles: items rest on top of a car's walls and roof, on its deck and wheels inside")
	var other := IdTables.from_data({"generation": tables.generation + 1, "ter": [], "furn": [], "trap": [], "field": [], "itype": []})
	_check.call(not VehicleView.blocks(snap, other, sq.call(0)) and VehicleView.def_of(other, snap, 3) == null,
			"vehicles: id tables of another generation name no parts (their indices mean something else)")
	# look-at
	var ray := LookRay.new(world)
	var look := func(x: int, h: float) -> Dictionary:
		var o := world.coords.ms_center_to_world(sq.call(x - 1)) + Vector3(0, h, 0)
		return ray.cast(o, Vector3.RIGHT, 1.0)
	var board: Dictionary = look.call(0, 1.5)
	var door: Dictionary = look.call(1, 1.5)
	var open: Dictionary = look.call(2, 1.5)
	var frame: Dictionary = look.call(3, 0.4)
	var over: Dictionary = look.call(0, 2.5)
	var desc := ray.describe(sq.call(0))
	_check.call(board.get("what") == "Test Car: board" and board.get("vehicle") == UID and board.get("square") == sq.call(0)
			and door.get("what") == "Test Car: door" and not open.get("hit", false) and frame.get("what") == "Test Car: frame"
			and not over.get("hit", false) and "\n".join(desc).contains("vehicle: Test Car (2 parts here: frame, board)"),
			"vehicles: look-at names the vehicle and the part met (%s, %s, %s; %s)" % [board.get("what"), door.get("what"),
			frame.get("what"), desc])
	view.free()
	world.free()
