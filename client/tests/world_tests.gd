extends RefCounted
## World view checks (block C, world lead), run by run_tests.gd: fields in the air (FieldView: fire, sparks,
## smoke and gas) and on the ground (GoreView's newer kinds).

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("fields (C6)")
	var world := WorldView.new()
	root.add_child(world)
	world.set_id_tables(tables)
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var bo: Array = d["bubble_origin"]
	world.coords.set_bubble_origin(Vector3i(int(bo[0]), int(bo[1]), int(bo[2])))
	var sm0: Dictionary = d["submaps"][0]
	var L := FieldView.Look
	var fv := FieldView.new()
	root.add_child(fv)
	var gv := GoreView.new()
	root.add_child(gv)
	sm0["fields"] = []   # the mock town has fields of its own elsewhere: count on top of them
	var plain := Snapshot.from_data(d)
	fv.apply(plain, world)
	gv.apply(plain, world)
	var before := [fv.count(L.FLAME), fv.count(L.GAS), fv.count(L.SPARK), fv.count(L.SWARM), fv.count(), gv.count()]
	var f := func(id: String) -> int: return tables.index_of("field", id)
	sm0["fields"] = [[5, f.call("fd_fire"), 2, 0], [7, f.call("fd_smoke"), 3, 0], [9, f.call("fd_hot_air2"), 2, 0],
			[11, f.call("fd_blood"), 1, 0], [13, f.call("fd_electricity"), 1, 0], [15, f.call("fd_bee_swarm"), 1, 0],
			[17, f.call("fd_acid"), 2, 0]]
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid(), "fields: scene valid " + snap.error)
	fv.apply(snap, world)
	var added := [fv.count(L.FLAME) - before[0], fv.count(L.GAS) - before[1], fv.count(L.SPARK) - before[2],
			fv.count(L.SWARM) - before[3]]
	_check.call(added == [2, 3, 2, 7], "fields: 2 flames, 3 smoke puffs, 2 sparks, 7 bees %s" % [added])
	_check.call(fv.count() - before[4] == 14, "fields: hot air, blood and acid are not drawn in the air")
	gv.apply(snap, world)
	_check.call(gv.count() - before[5] == 2, "ground fields: blood and acid splats (+%d)" % (gv.count() - before[5]))

	var sq := Vector3i(100, 200, 1)
	var corner := Vector3(4, 3, 7)
	var fl := []
	FieldView.place(fl, L.FLAME, Color.ORANGE, corner, sq, 3, 99)
	var ok := fl.size() == 3
	for e: Array in fl:
		var xf: Transform3D = e[0]
		var o := xf.origin - corner
		ok = ok and o.x > 0.0 and o.x < 1.0 and o.z > 0.0 and o.z < 1.0 and absf(o.y - xf.basis.y.length() * 0.5) < 0.001
	_check.call(ok, "fields: flames stand on their square, base on the floor")
	var again := []
	FieldView.place(again, L.FLAME, Color.ORANGE, corner, sq, 3, 99)
	_check.call(str(again) == str(fl), "fields: placement is deterministic")
	var gas := []
	FieldView.place(gas, L.GAS, FieldView.KINDS["fd_smoke"][1], corner, sq, 3, 99)
	var c0: Color = gas[0][1]
	_check.call(c0.a < 0.6 and c0.r < 0.5 and (gas[2][0] as Transform3D).origin.y > corner.y + 2.0,
			"fields: smoke is grey and see-through, and fills the room's height")
	var capped := []
	FieldView.place(capped, L.SWARM, Color.BLACK, corner, sq, 3, 4)
	_check.call(capped.size() == 4, "fields: place stops at the cap")
	for look: int in [L.FLAME, L.SPARK, L.GAS, L.SWARM]:
		var code := FieldView.shader(look).code
		_check.call(code.contains("MAIN_CAM_INV_VIEW_MATRIX") and code.contains("blend_add" if look == L.SPARK else "blend_mix"),
				"fields: %s shader faces the main camera (both VR eyes)" % L.keys()[look])

	fv.view_z_max = int(sm0["pos"][2]) - 1
	fv.apply(snap, world)
	_check.call(fv.count() == 0 and fv.get_node_or_null("flame") == null, "fields: cut away above the view level")
	fv.view_z_max = CddaCoords.Z_LIMIT
	fv.max_per_look = 1
	fv.apply(snap, world)
	_check.call(fv.count(L.GAS) == 1 and fv.count(L.SWARM) == 1, "fields: instances per look are capped")
	var bare := WorldView.new()
	root.add_child(bare)
	fv.apply(snap, bare)
	_check.call(fv.count() == 0, "fields: nothing without id tables")
	bare.free()
	gv.free()
	fv.free()
	world.free()
	_job_catalogs(root, data, tables)
	_door_leaves(root)


## The meshing job has catalogs of its own (it runs on a worker while the main thread looks styles up).
func _job_catalogs(root: Node, data: Variant, tables: IdTables) -> void:
	print("meshing job catalogs")
	var w := WorldView.new()
	w.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(w)
	w.set_id_tables(tables)
	var snap := Snapshot.from_data(data)
	w.submit(snap)
	var mid := w.catalog.style_for(snap.submaps.values()[0].ter[0])   # main thread, while the job may run
	w.finish_pending()
	_check.call(mid != null and w._job_catalog != w.catalog and w._job_props != w.props
			and w._job_catalog.registry == w.catalog.registry and w._job_catalog.tables == tables,
			"job: own catalogs, same registry and tables")
	var first := w._job_catalog
	w.apply_snapshot(snap)
	_check.call(w._job_catalog == first, "job: catalogs kept while nothing changes")
	w.set_id_tables(null)
	w.apply_snapshot(snap)
	_check.call(w._job_catalog != first and w._job_catalog.tables == null and w.catalog.tables == null,
			"job: new catalogs when the tables change")
	w.free()


## A leaf made again follows CDDA's state, not an angle kept from before (live: dropped leaves forget theirs).
func _door_leaves(root: Node) -> void:
	print("door leaves made again")
	var w := WorldView.new()
	root.add_child(w)
	w.door_local = false
	var sq := Vector3i(-900, -900, 0)
	var d := {"square": sq, "local": Vector3.ZERO, "along_x": true, "color": Color.GRAY, "glass": false,
			"open": false, "locked": false}
	w.door_state[sq] = {"angle": Grabbable.OPEN_REST}   # left open, then CDDA closed it
	var g := Grabbable.door(w, d)
	_check.call(g.angle == 0.0, "doors: a kept open angle doesn't open a door CDDA has shut")
	g.free()
	w.door_state[sq] = {"angle": 0.0}
	d["open"] = true
	g = Grabbable.door(w, d)
	_check.call(g.angle == Grabbable.OPEN_REST, "doors: a kept shut angle doesn't shut a door CDDA has opened")
	g.free()
	w.door_state[sq] = {"angle": 1.2}
	g = Grabbable.door(w, d)
	_check.call(is_equal_approx(g.angle, 1.2), "doors: an angle that agrees is kept")
	g.free()
	w.door_state.clear()
	var pos := CddaCoords.ms_to_sm(sq)
	var one: Array[Dictionary] = [d]
	var none: Array[Dictionary] = []
	var node := Node3D.new()
	w.add_child(node)
	w._build_doors(node, pos, one)
	w.door_state[sq] = {"angle": 1.2}
	w._build_doors(node, pos, none)
	_check.call(not w.grabbables.has(sq) and not w.door_state.has(sq), "doors: live, a dropped leaf forgets its angle")
	w.door_local = true
	w._build_doors(node, pos, one)
	w.door_state[sq] = {"angle": 1.2}
	w._build_doors(node, pos, none)
	_check.call(not w.grabbables.has(sq) and w.door_state.has(sq) and w._door_squares.is_empty(),
			"doors: mock keeps the client's own door state")
	w.free()
