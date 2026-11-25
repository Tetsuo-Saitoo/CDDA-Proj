extends RefCounted
## C6 vehicle work, the carried part (lead-world's side; lead-vr's hands): a copy of a car part as drawn (its shapes,
## or a plain box for a part not drawn as one), placed where the part is; the original hidden while it is carried,
## in the car's mesh and in its interior, kept with each snapshot until the part is gone; a copy of a part on no car;
## and the ghost of a part about to be installed on a lit square. Run by run_tests.gd.

const CAR := Vector3i(195, 385, 0)
const UID := 95

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vehicle work, the carried part (C6)")
	var v := func(id: String) -> int: return tables.index_of("vpart", id)
	# facing east: (1, 0) an engine and a battery (no roof), (1, 1) a wheel; (0, 0) a seat, the controls and a roof,
	# (0, 1) a box (a lid in the interior); a frame under each
	var parts := []
	for p: Array in [[1, 0, "engine_v6"], [1, 0, "battery_car"], [1, 1, "wheel"], [0, 0, "seat"], [0, 0, "controls"],
			[0, 0, "roof"], [0, 1, "box"]]:
		if not parts.any(func(q: Array) -> bool: return q[0] == p[0] and q[1] == p[1]):
			parts.append([p[0], p[1], v.call("frame"), 255, 0, p[0], p[1], 0])
		parts.append([p[0], p[1], v.call(p[2]), 255, 0, p[0], p[1], 0])
	var snap := _snap(data, parts)
	var gone := _snap(data, parts.filter(func(q: Array) -> bool: return q[2] != v.call("engine_v6")))
	if not snap.is_valid() or not gone.is_valid():
		_check.call(false, "carried part: the test car loads " + snap.error + gone.error)
		return
	var row := func(id: String) -> int:
		var car := snap.vehicles[0]
		for i in car.part_count():
			if car.parts[i * Snapshot.VPART_STRIDE + 2] == v.call(id):
				return i
		return -1
	var world := WorldView.new()
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := VehicleView.new()
	root.add_child(view)
	view.apply(snap, world)
	_test_copy(view, row, v)
	_test_hide(view, world, snap, gone, row)
	_test_install(view, v)
	_test_mount_at(view)
	_test_item()
	view.free()
	world.free()


func _snap(data: Variant, parts: Array) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	d["vehicles"] = [{"uid": UID, "name": "Work Car", "pos": [CAR.x, CAR.y, CAR.z], "face_deg": 0.0, "turn_deg": 0.0,
			"velocity": 0.0, "parts": parts}]
	return Snapshot.from_data(d)


## A mesh's box, its size and middle.
static func _box_of(n: Node3D) -> AABB:
	return (n as MeshInstance3D).mesh.get_aabb() if n is MeshInstance3D and (n as MeshInstance3D).mesh != null else AABB()


func _test_copy(view: VehicleView, row: Callable, v: Callable) -> void:
	var engine: int = row.call("engine_v6")
	var copy := view.part_copy(UID, engine)
	var at: Dictionary = view.part_anchors(UID)[engine]
	var box := _box_of(copy)
	var held := copy != null and copy.get_parent() == null and copy.transform.origin.is_equal_approx(at["point"]) \
			and box.size.is_equal_approx(Vector3(0.8, 0.6, 0.8)) and box.get_center().length() < 0.001
	var battery := view.part_copy(UID, row.call("battery_car"))   # not drawn as a shape: a box at its spot
	var wheel := view.part_copy(UID, row.call("wheel"))
	var none := view.part_copy(UID, 9999) == null and view.part_copy(UID + 7, engine) == null \
			and view.part_copy(UID, -1) == null
	_check.call(held and _box_of(battery).size.is_equal_approx(PartSpot.ON_BATTERY[0].size)
			and absf(_box_of(wheel).size.y - 0.8) < 0.05 and absf(_box_of(wheel).size.z - 0.3) < 0.01 and none,
			"carried part: a copy as drawn, its middle where the part is (an engine; a battery as a box at its spot; a wheel); none for a row that isn't a part (%s)" % [box])
	for n: Node3D in [copy, battery, wheel]:
		if n != null:
			n.free()
	var loose := view.part_copy_of(v.call("engine_v6"))
	var loose_box := _box_of(loose)
	_check.call(loose != null and loose_box.size.is_equal_approx(Vector3(0.8, 0.6, 0.8)) and loose_box.get_center().length() < 0.001
			and view.part_copy_of(-1) == null and view.part_copy_of(1 << 30) == null,
			"carried part: a copy of a part on no car, around its middle; none for a type the tables don't hold (%s)" % loose_box)
	if loose != null:
		loose.free()


func _test_hide(view: VehicleView, world: WorldView, snap: Snapshot, gone: Snapshot, row: Callable) -> void:
	var mesh_of := func() -> int:
		var n := view.find_child("vehicle", false, false) as MeshInstance3D
		return (n.mesh as ArrayMesh).surface_get_array_len(0) if n != null and n.mesh != null else -1
	var engine: int = row.call("engine_v6")
	var full: int = mesh_of.call()
	var hid := view.hide_part(UID, engine, true)
	var without: int = mesh_of.call()
	view.apply(snap, world)   # the next snapshot: still carried
	var kept: int = mesh_of.call()
	view.apply(gone, world)   # CDDA removed it
	view.apply(snap, world)   # one like it is back: drawn, nothing hidden any more
	var back: int = mesh_of.call()
	view.hide_part(UID, engine, true)
	view.hide_part(UID, engine, false)   # refused: snaps back
	var shown: int = mesh_of.call()
	view.hide_part(UID, engine, true)
	var any := view.hide_part(UID, -1, false)   # whatever is hidden on it (a row kept from before)
	_check.call(hid and without == full - 36 and kept == without and back == full and shown == full and any
			and mesh_of.call() == full and not view.hide_part(UID, -1, true) and not view.hide_part(UID, -2, false)
			and not view.hide_part(UID, 9999, true) and not view.hide_part(UID + 7, engine, true),
			"carried part: the original is hidden while carried, with each snapshot, until CDDA removes it or it is put back (%d, %d, %d, %d)" % [full, without, kept, back])
	# in the interior: a box's lid, the controls' wheel and dash; also when the interior is built while carried
	var xf: Transform3D = view.drawn(UID)
	var box: int = row.call("box")
	view.hide_part(UID, box, true)
	view.interiors(0.0, xf * Vector3(0, 1.6, 0))
	var inside := view.interior(UID)
	var lid: Node3D = inside.get("Cargo_%d" % box)
	var lid_hidden := lid != null and not lid.visible
	view.hide_part(UID, row.call("controls"), true)   # one a car: the box is back
	var swapped := lid != null and lid.visible and not (inside["Wheel"] as Node3D).visible \
			and not (inside["Dash"] as Node3D).visible
	view.hide_part(UID, row.call("controls"), false)
	_check.call(lid_hidden and swapped and (inside["Wheel"] as Node3D).visible and (inside["Dash"] as Node3D).visible,
			"carried part: its node in the interior is hidden too (a box's lid; the controls' wheel and dash); one part a car")


func _test_install(view: VehicleView, v: Callable) -> void:
	var lit := func() -> MeshInstance3D: return view.find_child("Highlight", true, false) as MeshInstance3D
	view.highlight_square(UID, Vector2i(2, 0), v.call("engine_v6"))   # the engine about to be installed ahead of the car
	var ghost: MeshInstance3D = lit.call()
	var g := ghost.mesh.get_aabb() if ghost != null else AABB()
	var tinted := ghost != null and ghost.mesh is ArrayMesh \
			and (ghost.mesh as ArrayMesh).surface_get_material(0) == VehicleView._highlight_material()
	view.highlight_square(UID, Vector2i(2, 0), 1 << 30)   # a type the tables don't hold: the square
	var square: MeshInstance3D = lit.call()
	view.highlight_square(UID, Vector2i.MAX, v.call("engine_v6"))
	_check.call(tinted and (ghost.position + g.get_center()).is_equal_approx(Vector3(2, VehicleView.DECK + 0.3, 0))
			and g.size.is_equal_approx(Vector3(0.8, 0.6, 0.8)) and square != null and square.mesh is BoxMesh
			and lit.call() == null,
			"carried part: install mode shows the part about to be installed on its square, tinted; the square for an unknown type; none for MAX (%s)" % g)


func _test_mount_at(view: VehicleView) -> void:
	var xf: Transform3D = view.drawn(UID)
	var on := view.mount_at(UID, xf * Vector3(0.6, 0.3, 1.4))
	var ahead := view.mount_at(UID, xf * Vector3(2.3, 1.0, -0.4))   # beside the car: no part there yet
	_check.call(on == Vector2i(1, 1) and ahead == Vector2i(2, 0) and view.mount_at(UID + 7, xf.origin) == Vector2i.MAX
			and view.mount_at(UID, xf * Vector3(5000, 0, 0)) == Vector2i.MAX
			and view.mount_at(UID, Vector3(NAN, 0, 0)) == Vector2i.MAX and view.mount_at(UID, Vector3(INF, 0, 0)) == Vector2i.MAX,
			"carried part: the square under a point, on the car or beside it; none for a car not drawn or a point out of reach (%s, %s)" % [on, ahead])


## vpart.item (a part's base item, an itype row): read when sent; anything else 0, never a failed table.
func _test_item() -> void:
	var t := IdTables.from_data({"generation": 3, "ter": [{"id": "t_null"}], "furn": [{"id": "f_null"}], "trap": [],
			"field": [], "itype": [{"id": ""}, {"id": "wheel_x"}, {"id": "engine_x"}],
			"vpart": [{"id": ""}, {"id": "a", "item": 1}, {"id": "b", "item": 2.0}, {"id": "c"}, {"id": "d", "item": 3},
				{"id": "e", "item": -1}, {"id": "f", "item": 1.5}, {"id": "g", "item": "1"}, {"id": "h", "item": 1e300},
				{"id": "i", "item": null}, {"id": "j", "item": NAN}, {"id": "k", "item": [1]}]})
	var items := []
	for id: String in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"]:
		var def: IdTables.Def = t.def_named("vpart", id) if t.is_valid() else null
		items.append(def.item if def != null else -9)
	_check.call(t.is_valid() and items == [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
			"carried part: a vehicle part's base item read from the id tables; missing, out of range or not a whole number is none (%s)" % [items])
