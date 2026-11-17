extends RefCounted
## Block L8, placeholder containers that open (PropBoxes): each opening shape is a model with doors, drawers
## or a lid that open the right way and surfaces inside; in the world a dresser's drawers and a crate's lid
## become parts, its items lie inside (in the drawers, riding them) and are pointable only through an
## opening. Run by run_tests.gd on a scene cut from the mock town.

var _check: Callable


func run(check: Callable, data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	_check = check
	print("placeholder containers (L8)")
	_test_models()
	_test_world(data, tables, scene, repo)


func _test_models() -> void:
	var want := {"cupboard": [2, 0, 0], "cabinet_tall": [2, 0, 0], "locker": [1, 0, 0], "fridge": [2, 0, 0],
			"dresser": [0, 3, 0], "filing_cabinet": [0, 4, 0], "chest_freezer": [0, 0, 1], "crate": [0, 0, 1],
			"cardboard_box": [0, 0, 1], "trash_can": [0, 0, 1], "recycle_bin": [0, 0, 1], "dumpster": [0, 0, 1]}
	_check.call(want.keys().all(func(s: String) -> bool: return s in PropBoxes.OPENS) and PropBoxes.OPENS.size() == want.size(),
			"boxes: every opening shape is checked")
	for shape: String in want:
		var m := PropBoxes.make(shape, Color(0.5, 0.4, 0.3), Color(0.2, 0.5, 0.3))
		var kinds := [0, 0, 0]
		var right := m != null and m.still != null and not m.still.parts.is_empty() and not m.surfaces.is_empty()
		if m == null:
			_check.call(false, "boxes: %s builds" % shape)
			continue
		for mv: ModelLibrary.Mover in m.movers:
			var c := mv.size.get_center()
			var open := Basis(mv.axis, mv.max_amount) * c if mv.kind != "drawer" else c + mv.axis * mv.max_amount
			match mv.kind:
				"door":
					kinds[0] += 1
					right = right and open.z > c.z + 0.05 and mv.has_handle   # swings out to the front (+z)
				"drawer":
					kinds[1] += 1
					right = right and mv.axis.is_equal_approx(Vector3.BACK) and mv.max_amount > 0.1 and mv.has_handle \
							and mv.surfaces.size() == 1
				"lid":
					kinds[2] += 1
					right = right and open.y > c.y + 0.1 and mv.has_handle   # lifts at the front
		_check.call(right and kinds == want[shape],
				"boxes: %s has %s doors / drawers / lid that open outward, with handles and surfaces inside" % [shape, str(kinds)])
	_check.call(PropBoxes.make("vending", Color.WHITE, Color.WHITE) == null and PropBoxes.make("oven", Color.WHITE, Color.WHITE) == null,
			"boxes: vending machines and ovens stay closed")


func _test_world(data: Variant, tables: IdTables, scene: Callable, repo: Callable) -> void:
	var reg := AssetRegistry.new()
	reg.load_dir(repo.call("assets/registry"))
	reg.load_dir(repo.call("client/tests/pins"))   # PropBoxes' dresser and sealed crate, not the kit models
	var terrain := TerrainCatalog.new()
	terrain.registry = reg
	terrain.set_tables(tables)
	var cat := PropCatalog.new(reg)
	cat.set_tables(tables)
	var furn := func(id: String) -> PropCatalog.Prop: return cat.furniture(tables.index_of("furn", id))
	var dresser: PropCatalog.Prop = furn.call("f_dresser")
	_check.call(PropBoxes.model_of(dresser) != null and PropBoxes.model_of(dresser) == PropBoxes.model_of(dresser)
			and furn.call("f_cupboard").shape == "cupboard" and PropBoxes.model_of(furn.call("f_counter")) == null,
			"boxes: a dresser's model is made once; a cupboard opens, a counter doesn't")
	var at := func(x: int, y: int) -> int: return y * 12 + x
	var book := tables.index_of("itype", "101_carpentry")
	var snap: Snapshot = scene.call(data, tables, {}, {at.call(3, 3): "f_dresser", at.call(6, 3): "f_crate_c"},
			[[at.call(3, 3), 3, [book, 0, 0, 0]], [at.call(6, 3), 1, [book, 0, 0, 0]]])
	var pos: Array = (data as Dictionary)["submaps"][0]["pos"]
	var sm_pos := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
	var sm: Snapshot.Submap = snap.submaps[sm_pos]
	sm.handles = PackedInt64Array([at.call(3, 3), 801, book, -1, -1, at.call(3, 3), 802, book, -1, -1,
			at.call(3, 3), 803, book, -1, -1, at.call(6, 3), 804, book, -1, -1])
	terrain.set_snapshot(snap)
	cat.set_snapshot(snap)
	var r := PropMesher.new(snap, terrain, cat).build(sm_pos)
	var kinds := r.parts.map(func(s: Dictionary) -> String: return s["kind"])
	_check.call(kinds == ["drawer", "drawer", "drawer", "lid"], "boxes: the dresser's three drawers and the crate's lid are parts " + str(kinds))
	_check.call(kinds.size() == 4 and r.parts[3]["locked"] and not r.parts[0]["locked"] and (r.parts[3]["open_id"] as String).is_empty(),
			"boxes: the sealed crate's lid is locked (pried open in CDDA, never by hand); the dresser's drawers aren't")
	var safe: PropCatalog.Prop = furn.call("f_safe_c")
	_check.call(safe.shape == "locker" and safe.open_id == "f_safe_o" and furn.call("f_safe_o").close_id == "f_safe_c"
			and furn.call("f_crate_o").shape == "crate_open" and PropBoxes.model_of(furn.call("f_crate_o")) == null,
			"boxes: a safe is a one-door locker that CDDA opens; an open crate has no lid")
	var rides := {}
	for e: Array in r.item_slots:
		rides[e[0]] = [e[6], e[7]]
	var base := CddaCoords.sm_to_ms(sm_pos)
	var drawer := "%d_%d_%d/drawer_" % [base.x + 3, base.y + 3, base.z]
	var lid := "%d_%d_%d/lid" % [base.x + 6, base.y + 3, base.z]
	_check.call(r.items == 4 and rides.size() == 4 and [801, 802, 803].all(func(u: int) -> bool:
				return (rides[u][0] as String).begins_with(drawer)) and rides[804][0] == "" and Array(rides[804][1]) == [lid],
			"boxes: the dresser's books ride its drawers; the crate's lies on its floor behind the lid " + str(rides))
	var world := WorldView.new()
	world.catalog = terrain
	world.props = cat
	world.set_id_tables(tables)
	world.apply_snapshot(snap)
	_check.call(world.parts.has(lid) and world.parts.has(drawer + "1") and world.parts.has(drawer + "3"),
			"boxes: the world makes them grabbable parts (%d in the scene)" % world.parts.size())
	world.free()
