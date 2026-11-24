extends RefCounted
## C6 vehicle work, lead-world's side (PartSpot, VehicleView.part_anchor / highlight, WorkCamera): where a part is
## (drawn ones by their shapes, the rest by CDDA's location or flags), the side it is seen from, where the work
## camera stands (outside the body, low for what is under it), the highlight over a part (kept with each snapshot,
## gone with -1), the hood, install mode's squares, and the camera gliding to a part, a square or a view on the vehicle
## as drawn (left of the work panel, in front of what is in the way) and giving the view back.
## Run by run_tests.gd.

const CAR := Vector3i(195, 385, 0)
const UID := 90

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vehicle work view, lead-world (C6)")
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var v := func(id: String) -> int: return tables.index_of("vpart", id)
	# facing east, two wide: (1, 0) engine bay (an alternator, a battery; no roof), (1, 1) a wheel; (0, 0) seat and
	# controls, (0, 1) seat, both roofed; (-1, 0) a tank, (-1, 1) a muffler; a frame under each
	var parts := []
	for p: Array in [[1, 0, "engine_v6"], [1, 0, "alternator_car"], [1, 0, "battery_car"], [1, 1, "wheel"],
			[0, 0, "seat"], [0, 0, "controls"], [0, 0, "roof"], [0, 1, "seat"], [0, 1, "roof"], [-1, 0, "tank"],
			[-1, 1, "muffler"]]:
		if not parts.any(func(q: Array) -> bool: return q[0] == p[0] and q[1] == p[1]):
			parts.append([p[0], p[1], v.call("frame"), 255, 0, p[0], p[1], 0])
		parts.append([p[0], p[1], v.call(p[2]), 255, 0, p[0], p[1], 0])
	# and a van six squares south: one cell, its engine under the roof
	var van := [[0, 0, v.call("frame"), 255, 0, 0, 0, 0], [0, 0, v.call("engine_v6"), 255, 0, 0, 0, 0],
			[0, 0, v.call("roof"), 255, 0, 0, 0, 0]]
	d["vehicles"] = [{"uid": UID, "name": "Work Car", "pos": [CAR.x, CAR.y, CAR.z], "face_deg": 0.0, "turn_deg": 0.0,
			"velocity": 0.0, "parts": parts}, {"uid": UID + 1, "name": "Van", "pos": [CAR.x, CAR.y + 6, CAR.z],
			"face_deg": 0.0, "turn_deg": 0.0, "velocity": 0.0, "parts": van}]
	var snap := Snapshot.from_data(d)
	if not snap.is_valid() or snap.vehicles.size() != 2:
		_check.call(false, "work view: the test car loads " + snap.error)
		return
	var car := snap.vehicles[0]
	var row := func(id: String, m: Vector2i) -> int:
		for i in car.part_count():
			var j := i * Snapshot.VPART_STRIDE
			if car.parts[j] == m.x and car.parts[j + 1] == m.y and car.parts[j + 2] == tables.index_of("vpart", id):
				return i
		return -1
	_test_spots(snap, tables, row)
	_test_view(root, snap, tables, row)


func _test_spots(snap: Snapshot, tables: IdTables, row: Callable) -> void:
	var car := snap.vehicles[0]
	var at := func(id: String, m: Vector2i) -> Dictionary: return PartSpot.anchor(car, snap, tables, row.call(id, m))
	var engine: Dictionary = at.call("engine_v6", Vector2i(1, 0))
	var alt: Dictionary = at.call("alternator_car", Vector2i(1, 0))
	var bat: Dictionary = at.call("battery_car", Vector2i(1, 0))
	var seat: Dictionary = at.call("seat", Vector2i(0, 1))
	var wheel: Dictionary = at.call("wheel", Vector2i(1, 1))
	var muffler: Dictionary = at.call("muffler", Vector2i(-1, 1))
	var right := Vector3(0, 0, 1)
	_check.call(engine["normal"] == Vector3.UP and absf((engine["point"] as Vector3).x - 1.0) < 0.5
			and alt["box"] == AABB(PartSpot.ON_ENGINE[0].position + Vector3(1, 0, 0), PartSpot.ON_ENGINE[0].size)
			and alt["normal"] == Vector3.UP and bat["box"] != alt["box"]
			and seat["normal"] == right and is_equal_approx((wheel["point"] as Vector3).z, 1.0 + VehicleView.WHEEL_OUT)
			and wheel["normal"] == right and (muffler["point"] as Vector3).y < VehicleView.DECK and muffler["normal"] == right
			and PartSpot.anchor(car, snap, tables, -1).is_empty() and PartSpot.anchor(car, snap, tables, 9999).is_empty(),
			"work view: parts drawn by their shapes, the rest by where CDDA mounts them (on the engine, the battery mount, under); seen from above in the open engine bay, from the side under a roof or under the floor")
	# the camera stands outside the body: beside the roofed seat, low for the muffler, above the engine
	var pose := func(what: String, id := "", m := Vector2i.ZERO) -> Array:
		return PartSpot.work_pose(car, snap, tables, what, row.call(id, m) if not id.is_empty() else -1)
	var p_seat: Array = pose.call("part", "seat", Vector2i(0, 1))
	var p_muffler: Array = pose.call("part", "muffler", Vector2i(-1, 1))
	var p_engine: Array = pose.call("part", "engine_v6", Vector2i(1, 0))
	var around: Array = pose.call("around")
	var hood: Array = pose.call("hood")
	var under: Array = pose.call("under")
	_check.call((p_seat[0] as Vector3).z > 1.5 and p_seat[1] == seat["point"] and (p_muffler[0] as Vector3).z > 1.5
			and (p_muffler[0] as Vector3).y < 0.6 and (p_muffler[0] as Vector3).y >= PartSpot.EYE_LOW - 0.001
			and (p_engine[0] as Vector3).y > (engine["point"] as Vector3).y + 0.5
			and (around[0] as Vector3).x > 1.5 and (around[0] as Vector3).z > 1.5
			and absf((hood[1] as Vector3).x - 1.0) < 0.01 and (hood[0] as Vector3).x > (hood[1] as Vector3).x
			and is_equal_approx((under[0] as Vector3).y, PartSpot.EYE_LOW) and (under[0] as Vector3).z > 1.5
			and PartSpot.work_pose(car, snap, tables, "junk").is_empty()
			and PartSpot.work_pose(car, snap, tables, "part", -1).is_empty(),
			"work view: the camera stands outside the body for a part, low beside it for what is under the floor, above the open engine bay, around, over the engine and under (%s)" % [p_seat])
	# the hood: over the open bay across the engine's row; none where a roof covers the engine
	var bay := CarInterior.hood_of(car, snap, tables, CddaCoords.Z_LIMIT)
	_check.call(bay == AABB(Vector3(0.5, CarInterior.HOOD_UP, -0.5), Vector3(1, CarInterior.HOOD_T, 2))
			and CarInterior.hood_of(snap.vehicles[1], snap, tables, CddaCoords.Z_LIMIT) == AABB(),
			"work view: a hood covers the open engine bay across its row; none over an engine under a roof (%s)" % bay)
	# a square for install mode: beside the car, seen from out there; one far out is none
	var sq := PartSpot.square_anchor(car, Vector2i(2, 0))
	var sq_pose := PartSpot.square_pose(car, Vector2i(2, 0))
	var exit: Vector3 = p_seat[2]
	_check.call(sq["box"] == AABB(Vector3(1.5, 0, -0.5), Vector3(1, VehicleView.TOP, 1)) and sq["normal"] == Vector3(1, 0, 0)
			and (sq_pose[0] as Vector3).x > 3.0 and sq_pose[1] == sq["point"]
			and PartSpot.square_anchor(car, Vector2i(5000, 0)).is_empty() and PartSpot.square_pose(car, Vector2i(5000, 0)).is_empty()
			and exit.z > 1.5 and exit.z < 1.7 and (p_seat[0] as Vector3).z > exit.z,
			"work view: a square beside the car is seen from out there; the line to the eye leaves the body at its edge (%s, exit %s)" % [sq_pose, exit])


func _test_view(root: Node, snap: Snapshot, tables: IdTables, row: Callable) -> void:
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := VehicleView.new()
	root.add_child(view)
	view.apply(snap, world)
	var car := snap.vehicles[0]
	var seat: int = row.call("seat", Vector2i(0, 1))
	var engine: int = row.call("engine_v6", Vector2i(1, 0))
	var xf: Transform3D = view.drawn(UID)
	var local := PartSpot.anchor(car, snap, tables, seat)
	var world_a := view.part_anchor(UID, seat)
	_check.call(not world_a.is_empty() and (world_a["point"] as Vector3).is_equal_approx(xf * (local["point"] as Vector3))
			and view.part_anchor(UID + 7, seat).is_empty() and view.part_anchor(UID, -1).is_empty(),
			"work view: a part's anchor in the world is where the vehicle is drawn (%s)" % [world_a])
	# the highlight: over the part, kept with each snapshot, gone with -1
	var lit := func() -> MeshInstance3D: return view.find_child("Highlight", true, false) as MeshInstance3D
	view.highlight(UID, engine)
	var first: MeshInstance3D = lit.call()
	var box: AABB = PartSpot.anchor(car, snap, tables, engine)["box"]
	var placed := first != null and first.position.is_equal_approx(box.get_center()) \
			and ((first.mesh as BoxMesh).size as Vector3).is_equal_approx(box.grow(0.03).size)
	view.apply(snap, world)
	var kept: MeshInstance3D = lit.call()
	view.highlight(UID, -1)
	var none: bool = lit.call() == null
	view.highlight(UID, 9999)
	_check.call(placed and kept != null and none and lit.call() == null,
			"work view: the highlight sits over the selected part, stays with a new snapshot, goes with -1 or a row that isn't a part")
	view.highlight_square(UID, Vector2i(2, 0))   # install mode: a square beside the car
	var on_sq: MeshInstance3D = lit.call()
	var sq_ok := on_sq != null and on_sq.position.is_equal_approx(Vector3(2, 0.5 * VehicleView.TOP, 0))
	view.highlight(UID, engine)   # either replaces the other
	var swapped: MeshInstance3D = lit.call()
	var one := swapped != null and swapped.position.is_equal_approx(box.get_center()) \
			and view.find_children("Highlight", "", true, false).size() == 1
	view.highlight_square(UID, Vector2i.MAX)
	var sq_none: bool = lit.call() == null
	view.highlight_square(UID, Vector2i(5000, 0))
	_check.call(sq_ok and one and sq_none and lit.call() == null,
			"work view: a square is highlighted floor to roof line (also beside the car); one highlight at a time; none for MAX or a mount far out")
	# the hood opens on the client, its front rising
	view.interiors(0.0, xf * Vector3(0, 1.6, 0))
	var hood: Node3D = view.interior(UID).get("Hood")
	var hood_ok: bool = hood != null and is_equal_approx(hood.position.x, 0.5) and hood.get_meta("hinge_axis") == Vector3(0, 0, 1)
	var opened := view.open_hood(UID, true) and not view.open_hood(UID + 7, true)
	for i in 40:
		view.interiors(0.1, xf * Vector3(0, 1.6, 0))
	var it: CarInterior = hood.get_parent() if hood != null else null
	var up := it != null and absf(it.lid_deg(CarInterior.HOOD) - CarInterior.HOOD_OPEN) < 0.1 \
			and ((hood.get_node("Lid") as Node3D).global_transform * (hood.get_meta("handle") as Vector3)).y > xf.origin.y + CarInterior.HOOD_UP + 0.5
	view.open_hood(UID, false)
	for i in 40:
		view.interiors(0.1, xf * Vector3(0, 1.6, 0))
	_check.call(hood_ok and opened and up and absf(it.lid_deg(CarInterior.HOOD)) < 0.1 and not view.interior(UID + 1).has("Hood"),
			"work view: the hood over the engine bay opens on the client, its front rising, and closes; none on the van")
	# the camera: glides to the part on the vehicle as drawn, to a view, and gives the view back
	var before := Camera3D.new()
	root.add_child(before)
	before.make_current()
	var cam := WorkCamera.new(view)
	root.add_child(cam)
	cam.focus(UID, 9999)
	cam.view(UID, "junk")
	cam.focus_square(UID, Vector2i(5000, 0))
	var idle := not cam.active and root.get_viewport().get_camera_3d() == before
	cam.frame_x = 0.5   # in the middle first
	cam.focus(UID, seat)
	for i in 40:
		cam.step(0.1)
	var p := view.work_pose(UID, "part", seat)
	var goal: Transform3D = view.global_transform * xf * (WorkCamera.pose_of(p[0], p[1]) as Transform3D)
	var at_part := cam.active and root.get_viewport().get_camera_3d() == cam and cam.global_position.distance_to(goal.origin) < 0.01 \
			and (-cam.global_basis.z).dot(((xf * (p[1] as Vector3)) - cam.global_position).normalized()) > 0.999
	cam.view(UID, "under")
	for i in 40:
		cam.step(0.1)
	var low := absf(cam.global_position.y - (xf * (view.work_pose(UID, "under")[0] as Vector3)).y) < 0.01
	cam.leave()
	_check.call(idle and at_part and low and not cam.active and root.get_viewport().get_camera_3d() == before,
			"work view: the camera glides to a part and looks at it, to the view under the car, and gives the view back (%s)" % cam.global_position)
	# left of the work view's panel: what it looks at sits frame_x across, here on a square beside the car
	cam.frame_x = 0.3
	cam.focus_square(UID, Vector2i(2, 0))
	for i in 40:
		cam.step(0.1)
	var target: Vector3 = xf * Vector3(2, 1, 0)
	var to_t := (target - cam.global_position).normalized()
	var size := root.get_viewport().get_visible_rect().size
	var want := WorkCamera.frame_turn(0.3, cam.fov, size.x / size.y if size.y > 0.0 else 16.0 / 9.0)
	_check.call(cam.active and absf((-cam.global_basis.z).angle_to(to_t) - want) < 0.01 and cam.global_basis.x.dot(to_t) < 0.0
			and want > 0.1 and (xf.affine_inverse() * cam.global_position).x > 2.5,
			"work view: a square beside the car is looked at from out there, left of the middle (%.2f rad)" % want)
	# something in the way: it stands in front of it, not past it (the wall stand-in says 0.6 m is free)
	var pose := view.work_pose(UID, "part", seat)
	cam.blocked = func(_a: Vector3, _b: Vector3, _v: int) -> float: return 0.6
	var near_wall := cam.eye_clear(pose, xf, UID)
	cam.blocked = func(_a: Vector3, _b: Vector3, _v: int) -> float: return INF
	var clear := cam.eye_clear(pose, xf, UID)
	# the real way out: LookRay meets the car's body from beside it, unless that body is the vehicle's own
	var ray := LookRay.new(world)
	var side := xf * Vector3(0, 1.0, 3.5)
	var into := WorkCamera.free_way(ray, side, xf * Vector3(0, 1.0, -0.2), 0)
	var past := WorkCamera.free_way(ray, side, xf * Vector3(0, 1.0, -0.2), UID)
	_check.call(absf(near_wall.distance_to(pose[2]) - (0.6 - WorkCamera.WALL_GAP)) < 0.01 and clear == pose[0]
			and absf(into - 2.0) < 0.15 and past > into,
			"work view: the camera stands in front of what is in the way between the car and its spot (%.2f m; the body met at %.2f m)" % [near_wall.distance_to(pose[2]), into])
	cam.leave()
	cam.blocked = Callable()
	cam.focus(UID, seat)
	view.apply(null, world)   # the vehicle is gone: back to the view before
	cam.step(0.1)
	_check.call(not cam.active and root.get_viewport().get_camera_3d() == before,
			"work view: the camera gives the view back when the vehicle goes")
	cam.free()
	before.free()
	view.free()
	world.free()
