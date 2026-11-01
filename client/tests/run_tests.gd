extends SceneTree
## Headless checks for blocks C1/C2. From the repo root:
##   godot --headless --path client --import          (once, so class names resolve)
##   godot --headless --path client --script res://tests/run_tests.gd
## Exit code 0 = all passed.

const MOCK := "contracts/mock/snapshot_town.json"

var _failed := 0


func _initialize() -> void:
	_test_coords()
	var data: Variant = _mock_data()
	_test_mock(data)
	_test_malformed(data)
	_test_catalog()
	print("tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)


func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


func _mock_data() -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(_repo(MOCK)))


func _test_coords() -> void:
	print("coords")
	var c := CddaCoords.new()
	var shifts: Array[Vector3] = []
	c.origin_shifted.connect(func(d: Vector3) -> void: shifts.append(d))
	c.set_bubble_origin(Vector3i(11, 27, 0))
	_check(c.origin_ms == Vector3i(132, 324, 0), "origin is bubble corner in squares")
	_check(c.ms_to_world(Vector3i(132, 324, 0)) == Vector3.ZERO, "bubble corner is Godot origin")
	_check(c.ms_to_world(Vector3i(133, 326, -1)) == Vector3(1, -3, 2), "x east, y south -> +Z, z -> 3 m down")
	_check(c.world_to_ms(Vector3(1.5, -2.9, 2.2)) == Vector3i(133, 326, -1), "world -> square floors correctly")
	_check(c.world_to_ms(c.ms_center_to_world(Vector3i(140, 330, 2))) == Vector3i(140, 330, 2), "centre round trip")
	_check(CddaCoords.ms_to_sm(Vector3i(-1, -12, 0)) == Vector3i(-1, -1, 0), "negative squares -> submap floor")
	_check(CddaCoords.ms_to_sm(Vector3i(-13, 11, 0)) == Vector3i(-2, 0, 0), "negative squares, other edge")
	_check(CddaCoords.ms_to_local(Vector3i(-1, 13, 0)) == Vector2i(11, 1), "local square of negative x")
	_check(c.world_to_sm(c.sm_to_world(Vector3i(15, 30, 1)) + Vector3(0.1, 0.1, 0.1)) == Vector3i(15, 30, 1), "submap round trip")
	var d := c.set_bubble_origin(Vector3i(12, 27, 0))
	_check(d == Vector3(-12, 0, 0) and shifts.size() == 2 and shifts[1] == d, "rebase east by one submap shifts -12 m")
	_check(c.ms_to_world(Vector3i(144, 324, 0)) == Vector3.ZERO, "new corner at origin after rebase")
	_check(c.set_bubble_origin(Vector3i(12, 27, 0)) == Vector3.ZERO and shifts.size() == 2, "no signal without a move")


func _test_mock(data: Variant) -> void:
	print("mock snapshot")
	var snap := Snapshot.load_file(_repo(MOCK))
	_check(snap.is_valid(), "mock loads: " + snap.error)
	_check(snap.submaps.size() == 363, "363 submaps (11 x 11 x 3)")
	_check(snap.ter_names.get(0, "") == "t_null" or not snap.ter_names.is_empty(), "terrain names read")
	var world := WorldView.new()
	world.catalog.load_registry_dir(_repo("assets/registry"))
	_check(world.catalog.warnings.is_empty(), "registry loads without warnings %s" % world.catalog.warnings)
	root.add_child(world)
	var t0 := Time.get_ticks_msec()
	_check(world.apply_snapshot(snap) == 363, "first apply builds all 363")
	print("        build took %d ms, %d vertices" % [Time.get_ticks_msec() - t0, world.vertex_count])
	_check(world.vertex_count > 50000, "meshes are not empty")
	_check(world.z_min_loaded == -1 and world.z_max_loaded == 1, "loaded levels -1..1")
	_check(world.apply_snapshot(Snapshot.load_file(_repo(MOCK))) == 0, "same revisions: nothing rebuilt")

	var bumped := Snapshot.from_data(data)
	(bumped.submaps[Vector3i(16, 32, 0)] as Snapshot.Submap).revision = 2
	_check(world.apply_snapshot(bumped) == 7, "one revision bump rebuilds it and its 6 neighbours")
	var back := Snapshot.from_data(data)
	_check(world.apply_snapshot(back) == 7, "a lower revision (submap came back) rebuilds too")

	world.view_z_max = 1
	world.set_view_z_max(0)
	_check(not world.node_of(Vector3i(16, 32, 1)).visible and world.node_of(Vector3i(16, 32, 0)).visible, "cutaway hides z 1")
	world.set_view_z_max(99)
	_check(world.view_z_max == 1, "cutaway clamps to loaded levels")

	# Bubble moves one submap east: column x=11 leaves, x=22 isn't sent; nothing else changed.
	var moved: Dictionary = (data as Dictionary).duplicate(true)
	moved["bubble_origin"] = [12, 27, 0]
	moved["submaps"] = (moved["submaps"] as Array).filter(func(s: Dictionary) -> bool: return s["pos"][0] >= 12)
	var shifted := Snapshot.from_data(moved)
	_check(shifted.is_valid(), "shifted snapshot valid: " + shifted.error)
	_check(world.apply_snapshot(shifted) == 33, "shift rebuilds only the new edge column (11 x 3)")
	_check(world.node_of(Vector3i(11, 27, 0)) == null, "submap that left is freed")
	_check(world.node_of(Vector3i(12, 27, 0)).position == Vector3.ZERO, "kept submap repositioned to new origin")
	_check(world.node_of(Vector3i(13, 28, -1)).position == Vector3(12, -3, 12), "z -1 node one level down")
	world.free()


func _reject(snap: Snapshot, what: String) -> void:
	_check(not snap.is_valid() and snap.submaps.is_empty(), "rejects %s (%s)" % [what, snap.error])


func _mutated(data: Variant, f: Callable) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	f.call(d)
	return Snapshot.from_data(d)


func _test_malformed(data: Variant) -> void:
	print("malformed input")
	_reject(Snapshot.parse_text(""), "empty text")
	_reject(Snapshot.parse_text("{\"contract_version\": 0,"), "truncated JSON")
	_reject(Snapshot.parse_text("[1, 2, 3]"), "a list at top level")
	_reject(Snapshot.parse_text("[".repeat(100000)), "100k nested lists")
	_reject(Snapshot.load_file(_repo("contracts/mock/does_not_exist.json")), "missing file")
	var big := OS.get_user_data_dir().path_join("big_snapshot.json")
	var f := FileAccess.open(big, FileAccess.WRITE)
	f.store_buffer(_spaces(Snapshot.MAX_FILE_BYTES + 1))
	f.close()
	_reject(Snapshot.load_file(big), "file over the size cap")
	DirAccess.remove_absolute(big)

	var sm0 := func(d: Dictionary) -> Dictionary: return (d["submaps"] as Array)[0]
	_reject(_mutated(data, func(d: Dictionary) -> void: d["contract_version"] = 1), "wrong contract version")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["contract_version"] = "0"), "version as string")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["bubble_origin"] = [1, 2]), "origin with 2 coords")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["bubble_origin"] = [1e30, 27, 0]), "origin far out")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["bubble_origin"] = [11, 27, 1]), "origin z != 0")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["submaps"] = {}), "submaps not a list")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["submaps"] = range(2542).map(func(_i: int) -> int: return 0)), "too many submaps")
	_reject(_mutated(data, func(d: Dictionary) -> void: (d["submaps"] as Array).append(sm0.call(d).duplicate(true))), "duplicate submap")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["pos"] = [0, 0, 0]), "submap outside bubble")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["pos"] = [11, 27, 11]), "z 11")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["revision"] = -1), "negative revision")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["revision"] = 1.5), "fractional revision")
	_reject(_mutated(data, func(d: Dictionary) -> void: (sm0.call(d)["ter"] as Array).pop_back()), "143 terrain ids")
	_reject(_mutated(data, func(d: Dictionary) -> void: (sm0.call(d)["ter"] as Array).append(0)), "145 terrain ids")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["ter"][5] = -1), "negative id")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["ter"][5] = 1e12), "huge id")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["ter"][5] = "t_floor"), "id as string")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["furn"][5] = null), "null furniture id")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["flags"][0] = 256), "flags over 255")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["vis"][0] = 4), "vis over 3")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d).erase("flags")), "missing flags")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["ids"]["ter"]["abc"] = "t_x"), "id table key not a number")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["ids"]["ter"]["7"] = "t".repeat(500)), "id name too long")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["env"]["sun_alt_deg"] = 1e9), "sun altitude out of range")

	var unknown := _mutated(data, func(d: Dictionary) -> void: sm0.call(d)["ter"][5] = 99999)
	_check(unknown.is_valid(), "an unnamed id in range is accepted")
	var world := WorldView.new()
	root.add_child(world)
	_check(world.apply_snapshot(unknown) == 363, "and builds (as an unknown box)")
	world.free()


func _spaces(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	b.fill(32)
	return b


func _test_catalog() -> void:
	print("terrain catalog")
	var cat := TerrainCatalog.new()
	cat.load_registry_dir(_repo("assets/registry"))
	var K := TerrainCatalog.Kind
	var expect := {
		"t_open_air": K.NONE, "t_floor": K.FLOOR, "t_linoleum_white": K.FLOOR, "t_wall_w": K.WALL,
		"t_soil": K.WALL, "t_door_c": K.DOOR, "t_door_o": K.DOOR, "t_window": K.WINDOW,
		"t_curtains": K.WINDOW, "t_flat_roof": K.ROOF, "t_shingle_flat_roof": K.ROOF,
		"t_dirtfloor_no_roof": K.FLOOR, "t_stairs_up": K.STAIRS_UP, "t_wood_stairs_down": K.STAIRS_DOWN,
		"t_ladder_up": K.LADDER_UP, "t_earth_ramp_up_high": K.RAMP_UP, "t_tree_maple": K.TREE,
		"t_treetop": K.TREETOP, "t_chainfence": K.FENCE, "t_gutter": K.FENCE, "t_water_pump": K.BOX,
		"t_sewage_pipe": K.BOX, "t_sewage": K.WATER, "t_monkey_bars": K.BOX,
	}
	for n: String in expect:
		_check(cat.make_style(n).kind == expect[n], "%s -> %s" % [n, K.keys()[expect[n]]])
	_check(cat.make_style("t_door_o").state == 1 and cat.make_style("t_door_b").state == 2, "door states")
	_check(cat.make_style("t_window_empty").state == 1 and cat.make_style("t_wall_glass").state == 3, "window states")
	_check(cat.make_style("t_a").color == cat.make_style("t_a").color and cat.make_style("").kind == K.BOX, "fallback boxes")

	var dir := OS.get_user_data_dir().path_join("bad_registry")
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("a.json"), FileAccess.WRITE).store_string("{not json")
	FileAccess.open(dir.path_join("b.json"), FileAccess.WRITE).store_string(
			"[1, {\"type\": \"fp3d_model\", \"kind\": \"terrain\", \"id\": 5, \"mesher\": \"floor\"}," +
			" {\"type\": \"fp3d_model\", \"kind\": \"terrain\", \"id\": \"t_x\", \"mesher\": \"rm -rf\"}]")
	var bad := TerrainCatalog.new()
	bad.load_registry_dir(dir)
	_check(bad.warnings.size() == 3, "bad registry files and entries skipped with warnings: %s" % bad.warnings)
	for n in ["a.json", "b.json"]:
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)
