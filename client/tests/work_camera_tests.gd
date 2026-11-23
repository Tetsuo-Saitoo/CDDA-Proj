extends RefCounted
## C6 vehicle work, lead-world's side (PartSpot, VehicleView.part_anchor / highlight, WorkCamera): where a part is
## (drawn ones by their shapes, the rest by CDDA's location or flags), the side it is seen from, where the work
## camera stands (outside the body, low for what is under it), the highlight over a part (kept with each snapshot,
## gone with -1), and the camera gliding to a part or a view on the vehicle as drawn and giving the view back.
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
	d["vehicles"] = [{"uid": UID, "name": "Work Car", "pos": [CAR.x, CAR.y, CAR.z], "face_deg": 0.0, "turn_deg": 0.0,
			"velocity": 0.0, "parts": parts}]
	var snap := Snapshot.from_data(d)
	if not snap.is_valid() or snap.vehicles.size() != 1:
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
			and view.part_anchor(UID + 1, seat).is_empty() and view.part_anchor(UID, -1).is_empty(),
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
	# the camera: glides to the part on the vehicle as drawn, to a view, and gives the view back
	var before := Camera3D.new()
	root.add_child(before)
	before.make_current()
	var cam := WorkCamera.new(view)
	root.add_child(cam)
	cam.focus(UID, 9999)
	cam.view(UID, "junk")
	var idle := not cam.active and root.get_viewport().get_camera_3d() == before
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
	cam.focus(UID, seat)
	view.apply(null, world)   # the vehicle is gone: back to the view before
	cam.step(0.1)
	_check.call(not cam.active and root.get_viewport().get_camera_3d() == before,
			"work view: the camera gives the view back when the vehicle goes")
	cam.free()
	before.free()
	view.free()
	world.free()
