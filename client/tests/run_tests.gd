extends SceneTree
## Headless checks for blocks C1-C3 (models: tests/model_tests.gd), C6 (tests/light_tests.gd), E3 (tests/ui_tests.gd), L1 (tests/vr_tests.gd) and C9 (tests/fp_tests.gd). From the repo root:
##   godot --headless --path client --import          (once, so class names resolve)
##   godot --headless --path client --script res://tests/run_tests.gd
## Exit code 0 = all passed and no unexpected ERROR / SCRIPT ERROR line was printed (tests/error_catch.gd).

const MOCK := "contracts/mock/snapshot_town.json"
const IDS := "contracts/mock/id_tables.json"
const ErrorCatch := preload("res://tests/error_catch.gd")
const TestDir := preload("res://tests/test_dir.gd")
## Error lines the negative tests cause on purpose: bad JSON and ConfigFile text fed to the parsers.
const EXPECTED_ERRORS := ["Parse JSON failed", "ConfigFile parse error"]

var _failed := 0
var _errors: ErrorCatch


func _initialize() -> void:
	_errors = ErrorCatch.new()
	_errors.allowed = PackedStringArray(EXPECTED_ERRORS)
	OS.add_logger(_errors)
	_test_error_catch()
	_test_test_dir()
	_test_scripts_compile()
	_test_coords()
	var data: Variant = _mock_data()
	var t0 := Time.get_ticks_msec()
	var tables := IdTables.load_file(_repo(IDS))
	print("id tables load in %d ms" % (Time.get_ticks_msec() - t0))
	_test_id_tables(tables)
	_test_mock(data, tables)
	_test_malformed(data)
	_test_catalog(tables)
	_test_registry(tables)
	_test_bad_registry()
	_test_props(data, tables)
	preload("res://tests/model_tests.gd").new().run(_check, data, tables, _scene, _repo)
	preload("res://tests/ui_tests.gd").new().run(root, _check)
	await process_frame   # the root is in the tree from here on: the VR rig needs global transforms
	preload("res://tests/vr_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/fp_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/door_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/part_tests.gd").new().run(root, _check, data, tables, _repo)
	preload("res://tests/item_action_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/item_pick_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/hands_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/vr_hands_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/vr_pack_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/vr_pull_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/vr_hud_tests.gd").new().run(root, _check, tables)
	preload("res://tests/vr_cheats_tests.gd").new().run(root, _check)
	preload("res://tests/vr_cook_tests.gd").new().run(root, _check, tables)
	preload("res://tests/inspect_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/aim_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/compass_tests.gd").new().run(root, _check, data)
	preload("res://tests/hud_tests.gd").new().run(_check, tables)
	preload("res://tests/cheat_tests.gd").new().run(_check)
	preload("res://tests/world_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/level_tests.gd").new().run(root, _check, data, tables)
	preload("res://tests/light_tests.gd").new().run(root, _check, data)
	TestDir.clean()
	var errs := _errors.take()
	OS.remove_logger(_errors)
	_check(errs.is_empty(), "no unexpected ERROR / SCRIPT ERROR lines (%d)" % errs.size())
	for e in errs:
		printerr("        " + e)
	print("tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


## The catcher itself: a push_error and a runtime script error (a cast of a freed object, which also stops
## the function it is in) are both seen. The ERROR and SCRIPT ERROR lines this prints are on purpose.
func _test_error_catch() -> void:
	print("error catcher (the next ERROR and SCRIPT ERROR lines are on purpose)")
	push_error("fp3d error-catch probe")
	_cast_freed()
	_check(_errors.take_matching("fp3d error-catch probe") == 1, "push_error is caught")
	_check(_errors.take_matching("Trying to cast a freed object") == 1, "a runtime script error is caught")


## The run's scratch folder (tests/test_dir.gd): one per process, and clean() removes it and stale folders of
## other runs (no stamp, or old), never a folder another checkout's run is still using.
func _test_test_dir() -> void:
	print("test folder")
	var mine := TestDir.path("probe.txt")
	_check(mine.begins_with("%s/%s%d/" % [TestDir.ROOT, TestDir.PREFIX, OS.get_process_id()]), "files go in this run's folder (%s)" % mine)
	# A stale run's folder (stamped long ago) goes; another live run's folder (fresh stamp, or just made and not
	# stamped yet) stays. Fake ids are 10^9 + pid*10 + k: unique per run, and never a real pid (Linux caps at 2^22).
	var stale := TestDir.ROOT.path_join(TestDir.PREFIX + str(1000000000 + OS.get_process_id() * 10 + 1))
	DirAccess.make_dir_recursive_absolute(stale.path_join("save/w"))
	FileAccess.open(stale.path_join("save/w/f.txt"), FileAccess.WRITE).store_string("x")
	TestDir.stamp(stale, 1)
	var other := TestDir.ROOT.path_join(TestDir.PREFIX + str(1000000000 + OS.get_process_id() * 10 + 3))
	DirAccess.make_dir_recursive_absolute(other)
	TestDir.stamp(other)
	var fresh := TestDir.ROOT.path_join(TestDir.PREFIX + str(1000000000 + OS.get_process_id() * 10 + 5))
	DirAccess.make_dir_recursive_absolute(fresh)
	FileAccess.open(mine, FileAccess.WRITE).store_string("x")
	TestDir.clean()
	_check(not DirAccess.dir_exists_absolute(stale) and not FileAccess.file_exists(mine),
			"clean() removes this run's folder and a stale run's")
	_check(DirAccess.dir_exists_absolute(other) and DirAccess.dir_exists_absolute(fresh),
			"clean() keeps folders other runs are still using (stamped, or not stamped yet)")
	DirAccess.remove_absolute(other.path_join(TestDir.STAMP))
	DirAccess.remove_absolute(other)
	DirAccess.remove_absolute(fresh)


func _cast_freed() -> void:
	var n := Node.new()
	n.free()
	var v: Variant = n
	var _x := v as Node


## Every script under res://scripts and res://tests must compile: a parse error elsewhere otherwise only
## shows as a SCRIPT ERROR line while the suites that use it are skipped and the run still "passes".
func _test_scripts_compile() -> void:
	var bad := PackedStringArray()
	var dirs := ["res://scripts", "res://tests"]
	while not dirs.is_empty():
		var d: String = dirs.pop_back()
		for sub in DirAccess.get_directories_at(d):
			dirs.append(d.path_join(sub))
		for f in DirAccess.get_files_at(d):
			if f.ends_with(".gd"):
				var sc := load(d.path_join(f)) as GDScript
				if sc == null or not sc.can_instantiate():
					bad.append(d.path_join(f))
	_check(bad.is_empty(), "every script compiles %s" % bad)


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


func _test_mock(data: Variant, tables: IdTables) -> void:
	print("mock snapshot")
	var snap := Snapshot.load_file(_repo(MOCK))
	_check(snap.is_valid(), "mock loads: " + snap.error)
	_check(snap.submaps.size() == 363, "363 submaps (11 x 11 x 3)")
	_check(snap.ter_names.get(0, "") == "t_null" or not snap.ter_names.is_empty(), "terrain names read")
	var world := WorldView.new()
	world.catalog.load_registry_dir(_repo("assets/registry"))
	_check(world.catalog.warnings.is_empty(), "registry loads without warnings %s" % world.catalog.warnings)
	root.add_child(world)
	world.set_id_tables(tables)
	var t0 := Time.get_ticks_msec()
	_check(world.apply_snapshot(snap) == 363, "first apply builds all 363")
	print("        build took %d ms, %d vertices, props %s" % [Time.get_ticks_msec() - t0, world.vertex_count, world.prop_counts])
	_check(world.vertex_count > 50000, "meshes are not empty")
	_check(world.prop_counts["furniture"] == 1058, "all 1058 furniture placed")
	_check(world.prop_counts["items"] > 50 and world.prop_counts["glyphs"] == 0, "item piles shown, no glyph cards")
	_check(not world.tables_mismatch, "id tables match the snapshot's generation")
	var detail := Snapshot.from_data(data)
	(detail.submaps[Vector3i(16, 32, 0)] as Snapshot.Submap).detail_revision += 1
	_check(world.apply_snapshot(detail) == 0 and world.props_built == 1, "detail revision: only that submap's props")
	_check(world.apply_snapshot(Snapshot.load_file(_repo(MOCK))) == 0 and world.props_built == 1, "and back")
	_check(world.z_min_loaded == -1 and world.z_max_loaded == 1, "loaded levels -1..1")
	_check(world.apply_snapshot(Snapshot.load_file(_repo(MOCK))) == 0, "same revisions: nothing rebuilt")

	var bumped := Snapshot.from_data(data)
	(bumped.submaps[Vector3i(16, 32, 0)] as Snapshot.Submap).revision = 2
	_check(world.apply_snapshot(bumped) == 7, "one revision bump rebuilds it and its 6 neighbours")
	var back := Snapshot.from_data(data)
	_check(world.apply_snapshot(back) == 7, "a lower revision (submap came back) rebuilds too")

	var up: Node3D = null   # a z 1 submap with something drawn (roofs); open sky has no node
	for pos: Vector3i in back.submaps:
		if pos.z == 1 and world.node_of(pos) != null:
			up = world.node_of(pos)
	print("        %d of 363 submaps have a node, levels with content %s" % [world.get_child_count(), world.levels_with_content()])
	_check(world.node_of(Vector3i(16, 32, 1)) == null and world.built_revision(Vector3i(16, 32, 1)) >= 0,
			"open sky over (16, 32): built, no node")
	world.view_z_max = 1
	world.set_view_z_max(0)
	_check(up != null and not up.visible and world.node_of(Vector3i(16, 32, 0)).visible, "cutaway hides z 1")
	world.set_view_z_max(99)
	_check(world.view_z_max == 1, "cutaway clamps to the levels with content")

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
	var big := TestDir.global("big_snapshot.json")
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


func _test_catalog(tables: IdTables) -> void:
	print("terrain catalog (id tables)")
	var cat := TerrainCatalog.new()
	cat.load_registry_dir(_repo("assets/registry"))
	cat.set_tables(tables)
	var K := TerrainCatalog.Kind
	var expect := {
		"t_open_air": K.NONE, "t_floor": K.FLOOR, "t_linoleum_white": K.FLOOR, "t_wall_w": K.WALL,
		"t_soil": K.WALL, "t_door_c": K.DOOR, "t_door_o": K.DOOR, "t_door_metal_locked": K.DOOR,
		"t_door_frame": K.DOOR, "t_window": K.WINDOW, "t_curtains": K.WINDOW, "t_wall_glass": K.WINDOW,
		"t_flat_roof": K.ROOF, "t_shingle_flat_roof": K.ROOF, "t_dirt": K.FLOOR, "t_grass": K.FLOOR,
		"t_dirtfloor_no_roof": K.FLOOR, "t_grate": K.FLOOR, "t_stairs_up": K.STAIRS_UP,
		"t_wood_stairs_down": K.STAIRS_DOWN, "t_ladder_up": K.LADDER_UP, "t_ladder_down": K.LADDER_DOWN,
		"t_earth_ramp_up_high": K.RAMP_UP, "t_earth_ramp_down_low": K.NONE, "t_earth_ramp_down_high": K.NONE,
		"t_tree_maple": K.TREE, "t_tree_young": K.TREE, "t_treetop": K.TREETOP, "t_treetop_evergreen": K.TREETOP,
		"t_chainfence": K.FENCE, "t_gutter": K.FENCE, "t_fence": K.FENCE, "t_chaingate_l": K.FENCE,
		"t_water_pump": K.BOX, "t_sewage_pipe": K.BOX, "t_sewage": K.WATER, "t_monkey_bars": K.BOX,
		"t_wall_half": K.WALL, "t_underbrush": K.SHRUB, "t_fern": K.SHRUB,
	}
	for n: String in expect:
		_check(cat.style_for_id(n).kind == expect[n], "%s -> %s" % [n, K.keys()[expect[n]]])
	var st := func(n: String) -> TerrainCatalog.Style: return cat.style_for_id(n)
	_check(st.call("t_door_c").state == 0 and st.call("t_door_o").state == 1 and st.call("t_door_b").state == 2
			and st.call("t_door_frame").state == 2, "door states from passability and the open/close pair")
	_check(st.call("t_door_glass_c").glass and not st.call("t_door_c").glass, "glass door from transparency")
	_check(st.call("t_window").state == 0 and st.call("t_window_open").state == 1 and st.call("t_curtains").state == 2
			and st.call("t_wall_glass").state == 3, "window states")
	_check(st.call("t_wall_half").height < 2.0 and st.call("t_wall_w").height == 3.0, "half walls are low")
	_check(st.call("t_gutter").height < 0.5 and st.call("t_fence").height < 1.5 and st.call("t_chainfence").height > 1.5,
			"fence heights from TINY/SHORT")
	var blue: Color = st.call("t_wall_b").color
	_check(blue.b > blue.r and st.call("t_wall_w").color == CddaPalette.material("plaster_white"),
			"wall colour: registry material, else CDDA colour")
	_check(st.call("t_tree_pine").color2 == CddaPalette.fg("c_green"), "tree crown takes its treetop's colour")
	_check((st.call("t_door_c").connects_to & st.call("t_wall_w").groups) != 0
			and (st.call("t_gutter").connects_to & st.call("t_wall_w").groups) == 0, "connect groups: doors join walls, gutters don't")
	_check(not tables.is_roof("t_dirt") and tables.is_roof("t_flat_roof") and tables.is_treetop("t_treetop"), "roof links")

	print("terrain catalog (no id tables)")
	var bare := TerrainCatalog.new()
	bare.load_registry_dir(_repo("assets/registry"))
	_check(bare.style_for_id("t_floor").kind == K.FLOOR and bare.style_for_id("t_wall_w").kind == K.WALL, "registry meshers still work")
	_check(bare.style_for_id("t_door_c").kind == K.BOX and bare.style_for_id("").kind == K.BOX, "the rest are boxes")
	_check(bare.style_for_id("t_a").color == bare.style_for_id("t_a").color, "stable fallback colour")
	bare.set_tables(tables)
	bare.set_names({7: "t_door_c"})
	_check(bare.style_for(7).kind == K.DOOR, "by name when the tables don't match the snapshot")
	var gen2 := IdTables.from_data({"generation": 2, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [], "itype": []})
	var world := WorldView.new()
	world.catalog.load_registry_dir(_repo("assets/registry"))
	world.set_id_tables(gen2)
	var snap := Snapshot.load_file(_repo(MOCK))
	root.add_child(world)
	world.apply_snapshot(snap)
	_check(world.tables_mismatch and world.prop_counts["furniture"] == 1058, "mismatched generation: flagged, still builds")
	world.free()


func _test_id_tables(t: IdTables) -> void:
	print("id tables")
	_check(t.is_valid(), "mock id tables load: " + t.error)
	_check(t.generation == 1 and t.ter.size() == 1109 and t.furn.size() == 660 and t.trap.size() == 125
			and t.itype.size() == 9913, "generation and table sizes")
	_check(t.ter[0].id == "t_null" and t.furn[0].id == "f_null" and t.index_of("ter", "t_floor") > 0, "null at 0, index by id")
	var w := t.def_named("ter", "t_wall_w")
	_check(w.has("WALL") and (w.groups & t.group_bit("WALL")) != 0 and w.looks_like == "t_wall", "flags, groups, looks_like")
	_check(t.def_named("ter", "t_door_c").open == "t_door_o" and t.def_named("ter", "t_door_o").close == "t_door_c", "open/close pair")
	_check(t.def_named("furn", "f_rack").move_cost == -1 and t.def_named("itype", "101_carpentry").category == "manuals", "furniture and items")

	var base := {"generation": 3, "ter": [{"id": "t_null"}, {"id": "t_x", "flags": ["FLAT"], "connect_groups": ["WALL"]}],
			"furn": [{"id": "f_null"}], "trap": [], "field": [], "itype": [{"id": ""}, {"id": "i_x", "volume_ml": 250}]}
	_check(IdTables.from_data(base).is_valid(), "small tables valid")
	var bad := func(f: Callable, what: String) -> void:
		var d: Dictionary = base.duplicate(true)
		f.call(d)
		var r := IdTables.from_data(d)
		_check(not r.is_valid() and r.ter.is_empty() and r.itype.is_empty(), "rejects %s (%s)" % [what, r.error])
	_check(not IdTables.parse_text("").is_valid() and not IdTables.parse_text("[1]").is_valid(), "rejects empty text and a list")
	_check(not IdTables.parse_text("[".repeat(100000)).is_valid(), "rejects 100k nested lists")
	bad.call(func(d: Dictionary) -> void: d["generation"] = -1, "negative generation")
	bad.call(func(d: Dictionary) -> void: d.erase("ter"), "missing table")
	bad.call(func(d: Dictionary) -> void: d["ter"] = {}, "table not a list")
	bad.call(func(d: Dictionary) -> void: d["ter"][1] = 5, "row not an object")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["id"] = "t".repeat(500), "id too long")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["id"] = 7, "id not a string")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["name"] = "n".repeat(5000), "name too long")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["flags"] = "FLAT", "flags not a list")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["flags"] = [1], "flag not a string")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["flags"] = range(300).map(func(i: int) -> String: return "F%d" % i), "300 flags")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["connect_groups"] = [null], "null group")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["move_cost"] = 1.5, "fractional move cost")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["move_cost"] = 1e12, "huge move cost")
	bad.call(func(d: Dictionary) -> void: d["ter"][1]["transparent"] = "yes", "transparent not a bool")
	bad.call(func(d: Dictionary) -> void: d["ter"].append({"id": "t_x"}), "duplicate id")
	bad.call(func(d: Dictionary) -> void: d["itype"][1]["volume_ml"] = -5, "negative volume")
	bad.call(func(d: Dictionary) -> void: d["ter"] = range(IdTables.MAX_ROWS + 1).map(func(_i: int) -> Dictionary: return {}), "too many rows")
	var groups := []
	for i in 70:
		groups.append({"id": "t_g%d" % i, "connect_groups": ["G%d" % i]})
	var many := IdTables.from_data({"generation": 0, "ter": groups, "furn": [], "trap": [], "field": [], "itype": []})
	_check(many.is_valid() and many.group_bits.size() == IdTables.MAX_GROUP_BITS and many.ter[69].groups == 0,
			"connect groups past the bit cap join nothing")


func _test_bad_registry() -> void:
	var dir := TestDir.global("bad_registry")
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


func _test_registry(tables: IdTables) -> void:
	print("asset registry and fallback chain")
	var reg := AssetRegistry.new()
	reg.load_dir(_repo("assets/registry"))
	_check(reg.warnings.is_empty(), "registry loads without warnings %s" % reg.warnings)
	var S := AssetRegistry.Step
	var f := reg.find_prop("furniture", "f_chair", [], [])
	_check(f.step == S.EXACT and f.entry.placeholder == "chair", "1: exact id")
	f = reg.find_prop("furniture", "f_unknown", ["f_nope", "f_chair"], ["seat"])
	_check(f.step == S.LOOKS_LIKE and f.via == "f_chair", "2: looks_like chain")
	f = reg.find_prop("furniture", "f_unknown", ["t_floor"], ["seat"])
	_check(f.step == S.GENERIC and f.via == "generic_furniture_seat", "a terrain mesher is no prop art; 3: category generic")
	f = reg.find_prop("furniture", "f_unknown", [], ["nonsense"])
	_check(f.step == S.GENERIC and f.via == "generic_furniture", "3: kind generic last")
	_check(reg.find_prop("trap", "f_chair", [], []).via == "generic_trap", "exact needs the same kind")
	_check(AssetRegistry.new().find_prop("furniture", "f_chair", [], []).step == S.GLYPH, "5: glyph without a registry")

	var cat := PropCatalog.new(reg)
	cat.set_tables(tables)
	var furn := func(id: String) -> PropCatalog.Prop: return cat.furniture(tables.index_of("furn", id))
	_check(furn.call("f_rack").shape == "shelf" and furn.call("f_rack").rotates_to != 0, "rack: shelf facing the room")
	_check(furn.call("f_lily").shape == "flower" and furn.call("f_lily").step == S.GENERIC, "flowers by the FLOWER flag")
	_check(furn.call("f_stool").step == S.EXACT and furn.call("f_table").main == CddaPalette.material("wood"), "material colours the body")
	var book := cat.item(tables.index_of("itype", "101_carpentry"))
	_check(book.shape == "item_book" and book.scale >= PropCatalog.ITEM_MIN_M and book.scale <= PropCatalog.ITEM_MAX_M,
			"items by category, sized by volume (%.2f m)" % book.scale)
	var ring := IdTables.from_data({"generation": 0, "ter": [], "trap": [], "field": [], "itype": [],
			"furn": [{"id": "f_null"}, {"id": "f_a", "looks_like": "f_b"}, {"id": "f_b", "looks_like": "f_a"}]})
	var rc := PropCatalog.new(reg)
	rc.set_tables(ring)
	_check(rc.furniture(1).step == S.GENERIC, "a looks_like cycle ends the chain")
	var glyphs := PropCatalog.new(AssetRegistry.new())
	glyphs.set_tables(tables)
	var g := glyphs.furniture(tables.index_of("furn", "f_chair"))
	_check(g.shape.is_empty() and g.symbol == "#", "no art at all: a glyph card with the CDDA symbol")

	var dir := TestDir.global("bad_registry2")
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("c.json"), FileAccess.WRITE).store_string(JSON.stringify([
		{"type": "fp3d_model", "kind": "furniture", "id": "f_a", "placeholder": "../x"},
		{"type": "fp3d_model", "kind": "furniture", "id": "f_b", "placeholder": "chair", "scale": -1},
		{"type": "fp3d_model", "kind": "furniture", "id": "f_c", "placeholder": "chair", "offset": [1, 2]},
		{"type": "fp3d_model", "kind": "furniture", "id": "f_d", "model": "../../x.glb"},
		{"type": "fp3d_model", "kind": "dragon", "id": "f_e", "placeholder": "chair"},
		{"type": "fp3d_model", "kind": "furniture", "id": "f e;", "placeholder": "chair"},
		{"type": "fp3d_model", "kind": "furniture", "id": "f_ok", "placeholder": "chair"}]))
	var r2 := AssetRegistry.new()
	r2.load_dir(dir)
	_check(r2.warnings.size() == 5 and r2.entry("f_ok", "furniture") != null and r2.entry("f e;", "furniture") == null,
			"bad prop entries skipped: %s" % r2.warnings)
	DirAccess.remove_absolute(dir.path_join("c.json"))
	DirAccess.remove_absolute(dir)


## A copy of the mock with its first submap rewritten: floor everywhere, then the given ter/furn/items.
func _scene(data: Variant, tables: IdTables, ter: Dictionary, furn: Dictionary, items: Array, traps := {}) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var sm: Dictionary = d["submaps"][0]
	var floor_id := tables.index_of("ter", "t_floor")
	for i in 144:
		sm["ter"][i] = floor_id
		sm["furn"][i] = 0
		sm["trap"][i] = 0
		sm["flags"][i] = 1
	for i: int in ter:
		sm["ter"][i] = tables.index_of("ter", ter[i])
	for i: int in furn:
		sm["furn"][i] = tables.index_of("furn", furn[i])
	for i: int in traps:
		sm["trap"][i] = tables.index_of("trap", traps[i])
	sm["items"] = items
	return Snapshot.from_data(d)


func _test_props(data: Variant, tables: IdTables) -> void:
	print("props (C3)")
	var sm0 := func(d: Dictionary) -> Dictionary: return (d["submaps"] as Array)[0]
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = {}), "items not a list")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[144, 1, [5]]]), "pile tile 144")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, 1, [5]], [3, 2, [6]]]), "two piles on a tile")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, -1, [5]]]), "negative count")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, 70000, [5]]]), "count over uint16")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, 5, [1, 2, 3, 4, 5]]]), "five top items")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, 5, ["i_x"]]]), "itype as string")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = [[3, 5]]), "pile without top list")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["items"] = range(145).map(func(i: int) -> Array: return [i % 144, 1, []])), "145 piles")
	_reject(_mutated(data, func(d: Dictionary) -> void: (sm0.call(d)["trap"] as Array).pop_back()), "143 trap ids")
	_reject(_mutated(data, func(d: Dictionary) -> void: sm0.call(d)["trap"][0] = -2), "negative trap id")
	_reject(_mutated(data, func(d: Dictionary) -> void: d["ids_generation"] = "1"), "ids_generation as string")
	var lean := _mutated(data, func(d: Dictionary) -> void:
		sm0.call(d).erase("items")
		sm0.call(d).erase("trap"))
	_check(lean.is_valid() and lean.ids_generation == 1, "a submap without items or traps is valid")
	# Item handles (L8) and carried items: bounded, checked, never trusted.
	var handled := _mutated(data, func(d: Dictionary) -> void:
		sm0.call(d)["handles"] = JSON.parse_string("[[3, 9007199254740991, 5, 250, 750], [3, 77, 5, -1, -1]]")
		(d["player"] as Dictionary)["items"] = [[10, 4, 0, -1, 1], [11, 5, 10, 0, 0], [12, 5, 0, -1, 6]])
	var hs := PackedInt64Array()
	for sm: Snapshot.Submap in handled.submaps.values():
		hs.append_array(sm.handles)
	_check(handled.is_valid() and handled.carried.size() == 15 and hs.size() == 10 and hs[1] == 9007199254740991
			and hs[3] == 250, "handles and carried items read: " + handled.error)
	var hdl := func(h: Array) -> Callable: return func(d: Dictionary) -> void: sm0.call(d)["handles"] = h
	_reject(_mutated(data, hdl.call([[3, 0, 5, -1, -1]])), "handle uid 0")
	_reject(_mutated(data, hdl.call(JSON.parse_string("[[3, 9007199254740992, 5, -1, -1]]"))), "handle uid 2^53")
	_reject(_mutated(data, hdl.call([[3, 7, 5, 1000, 0]])), "spot 1000")
	_reject(_mutated(data, hdl.call([[3, 7, 5, 0.5, 0]])), "spot not an integer")
	_reject(_mutated(data, hdl.call([[3, 7, 5, -1, -1], [4, 7, 5, -1, -1]])), "uid twice")
	_reject(_mutated(data, hdl.call(range(33).map(func(i: int) -> Array: return [3, i + 1, 5, -1, -1]))), "33 handles on a tile")
	_reject(_mutated(data, hdl.call([[3, 7, 5, -1]])), "short handle")
	var car := func(c: Array) -> Callable: return func(d: Dictionary) -> void: (d["player"] as Dictionary)["items"] = c
	_reject(_mutated(data, car.call([[11, 5, 10, 0, 0]])), "carried before its container")
	_reject(_mutated(data, car.call([[10, 4, 0, 256, 0]])), "pocket 256")
	_reject(_mutated(data, car.call([[10, 4, 0, -1, 8]])), "unknown carried flag")
	var most := _mutated(data, car.call(range(257).map(func(i: int) -> Array: return [i + 1, 4, 0, -1, 0])))
	_check(most.is_valid() and most.carried.size() == Snapshot.MAX_CARRIED * Snapshot.CARRIED_STRIDE,
			"257 carried: the first 256 kept " + most.error)

	var reg := AssetRegistry.new()
	reg.load_dir(_repo("assets/registry"))
	var terrain := TerrainCatalog.new()
	terrain.registry = reg
	terrain.set_tables(tables)
	var cat := PropCatalog.new(reg)
	cat.set_tables(tables)
	var it := func(id: String) -> int: return tables.index_of("itype", id)
	# Table at 5,5, dresser at 7,5, nothing at 9,5; a sofa at 2,8 with a wall south of it; a rack at
	# 5,10 walled in except to the east; a chair at 9,9 with a table west of it; a trap at 1,1.
	var at := func(x: int, y: int) -> int: return y * 12 + x
	var walls := {at.call(2, 9): "t_wall_w", at.call(4, 10): "t_wall_w", at.call(5, 9): "t_wall_w", at.call(5, 11): "t_wall_w"}
	var furn := {at.call(5, 5): "f_table", at.call(7, 5): "f_dresser", at.call(2, 8): "f_sofa", at.call(5, 10): "f_rack",
			at.call(9, 9): "f_chair", at.call(8, 9): "f_table"}
	var book: int = it.call("101_carpentry")
	var items := [[at.call(5, 5), 3, [book, book, 0, 0]], [at.call(7, 5), 2, [book, 0, 0, 0]], [at.call(9, 5), 20, [book, 0, 0, 0]]]
	var snap := _scene(data, tables, walls, furn, items, {at.call(1, 1): "tr_bubblewrap"})
	_check(snap.is_valid(), "scene valid: " + snap.error)
	var sm: Snapshot.Submap = null
	for p: Vector3i in snap.submaps:
		var s: Snapshot.Submap = snap.submaps[p]
		if s.items.size() == 3 * Snapshot.PILE_STRIDE and s.furn[at.call(5, 5)] == tables.index_of("furn", "f_table"):
			sm = s
	terrain.set_snapshot(snap)
	cat.set_snapshot(snap)
	var pm := PropMesher.new(snap, terrain, cat)
	var base := CddaCoords.sm_to_ms(sm.pos)
	var r := pm.build(sm.pos)
	_check(r.furniture == 6 and r.traps == 1 and r.items == 3 + 8 and r.glyphs.is_empty() and r.props != null,
			"builds furniture, a trap and piles (%d, %d, %d)" % [r.furniture, r.traps, r.items])
	var r2 := pm.build(sm.pos)
	_check(r2.vertices == r.vertices and r2.props.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == r.props.surface_get_arrays(0)[Mesh.ARRAY_VERTEX],
			"rebuilding gives the same mesh")

	var pile := func(k: int) -> Array: return pm.pile_transforms(sm, base, sm.items.slice(k * Snapshot.PILE_STRIDE, (k + 1) * Snapshot.PILE_STRIDE), {})
	var on_table: Array = pile.call(0)
	_check(on_table.size() == 3 and on_table.all(func(e: Array) -> bool: return absf((e[0] as Transform3D).origin.y - 0.77) < 0.001),
			"items rest on the table top")
	var in_box := on_table.all(func(e: Array) -> bool:
		var o: Vector3 = (e[0] as Transform3D).origin
		return o.x > 5.0 and o.x < 6.0 and o.z > 5.0 and o.z < 6.0)
	_check(in_box, "and stay on their tile")
	_check((pile.call(1) as Array).is_empty(), "items in a closed dresser are hidden")
	var floor_items: Array = pile.call(2)
	_check(floor_items.size() == PropMesher.MAX_SHOWN and floor_items[1][1] == 0, "a pile of 20 shows %d, clutter after the top 4" % PropMesher.MAX_SHOWN)
	var spread := true
	for a in floor_items.size():
		for b in a:
			var d: Vector3 = (floor_items[a][0] as Transform3D).origin - (floor_items[b][0] as Transform3D).origin
			spread = spread and Vector2(d.x, d.z).length() > 0.12
	_check(spread, "each item on its own sub-tile slot")
	_check(str(pile.call(2)) == str(floor_items), "placement is deterministic")

	var rng := RandomNumberGenerator.new()
	var face := func(x: int, y: int) -> int:
		return pm.facing(base + Vector3i(x, y, 0), cat.furniture(sm.furn[at.call(x, y)]), rng)
	_check(face.call(2, 8) == 0, "sofa: back to the wall (faces north)")
	_check(face.call(5, 10) == 1, "rack: faces the open floor (east)")
	_check(face.call(9, 9) == 3, "chair: faces the table (west)")
	_check(cat.furniture(500000) == cat.furniture(500001) and terrain.style_for(900000) == terrain.style_for(900001),
			"undefined ids share one cache entry")
	_test_layout(data, tables, terrain, cat)


## Furniture faces the open side it is used from, and joined tiles lay out as one piece: one facing per
## row or block, one pillow per bed head tile.
func _test_layout(data: Variant, tables: IdTables, terrain: TerrainCatalog, cat: PropCatalog) -> void:
	print("furniture layout (facing, joined pieces)")
	var at := func(x: int, y: int) -> int: return y * 12 + x
	var cells := func(xys: Array, id: String, into: Dictionary) -> void:
		for xy: Vector2i in xys:
			into[at.call(xy.x, xy.y)] = id
	# Walls #, counters C, benches B, a table T with a chair c, a fridge F, beds: b (1 x 2), D (2 x 2),
	# d (3 x 2: a dorm row of three single beds).
	#   x  0123456789AB
	#   y0  ###
	#    1 #CCC  #
	#    2       B#
	#    3       B# T
	#    4          c#
	#    9   b  DD ddd
	#   10   b FDD ddd
	#   11   # ### ###
	var walls := {}
	cells.call([Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(0, 1), Vector2i(6, 1), Vector2i(7, 2),
			Vector2i(7, 3), Vector2i(10, 4), Vector2i(2, 11), Vector2i(4, 11), Vector2i(5, 11), Vector2i(6, 11),
			Vector2i(8, 11), Vector2i(9, 11), Vector2i(10, 11)], "t_wall_w", walls)
	var furn := {}
	cells.call([Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)], "f_counter", furn)
	cells.call([Vector2i(6, 2), Vector2i(6, 3)], "f_bench", furn)
	cells.call([Vector2i(9, 3)], "f_table", furn)
	cells.call([Vector2i(9, 4)], "f_chair", furn)
	cells.call([Vector2i(4, 10)], "f_fridge", furn)
	cells.call([Vector2i(2, 9), Vector2i(2, 10)], "f_bed", furn)
	cells.call([Vector2i(5, 9), Vector2i(6, 9), Vector2i(5, 10), Vector2i(6, 10)], "f_bed", furn)
	cells.call([Vector2i(8, 9), Vector2i(9, 9), Vector2i(10, 9), Vector2i(8, 10), Vector2i(9, 10), Vector2i(10, 10)], "f_bed", furn)
	var book := tables.index_of("itype", "101_carpentry")
	var snap := _scene(data, tables, walls, furn, [[at.call(5, 9), 2, [book, book, 0, 0]]])
	_check(snap.is_valid(), "layout scene valid: " + snap.error)
	var sm: Snapshot.Submap = null
	for p: Vector3i in snap.submaps:
		var s: Snapshot.Submap = snap.submaps[p]
		if s.furn[at.call(1, 1)] == tables.index_of("furn", "f_counter") and s.furn[at.call(6, 2)] == tables.index_of("furn", "f_bench"):
			sm = s
	terrain.set_snapshot(snap)
	cat.set_snapshot(snap)
	var pm := PropMesher.new(snap, terrain, cat)
	var base := CddaCoords.sm_to_ms(sm.pos)
	var r := pm.build(sm.pos)
	var faces := func(xys: Array) -> Array:
		return xys.map(func(xy: Vector2i) -> int:
			return pm.facing(base + Vector3i(xy.x, xy.y, 0), cat.furniture(sm.furn[at.call(xy.x, xy.y)])))
	var N := 0
	var S := 2
	var W := 3
	_check(faces.call([Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]) == [S, S, S],
			"3 counters along a wall: one facing, across the row, to the floor (the corner one too)")
	_check(faces.call([Vector2i(6, 2), Vector2i(6, 3)]) == [W, W], "benches between floor and a wall face the floor, not each other")
	_check(faces.call([Vector2i(9, 4)]) == [N], "a chair at a table faces it, though a wall is beside it")
	_check(faces.call([Vector2i(4, 10)]) == [N], "a fridge against a wall faces the room")
	_check(faces.call([Vector2i(2, 9), Vector2i(2, 10)]) == [N, N], "1 x 2 bed: one facing, along it, head at the wall")
	_check(faces.call([Vector2i(5, 9), Vector2i(6, 9), Vector2i(5, 10), Vector2i(6, 10)]) == [N, N, N, N],
			"2 x 2 bed: one facing, head at the wall")
	_check(faces.call([Vector2i(8, 9), Vector2i(10, 10)]) == [N, N], "a dorm row of beds: heads at the wall")
	var links := func(x: int, y: int) -> int:
		var p := base + Vector3i(x, y, 0)
		var prop := cat.furniture(sm.furn[at.call(x, y)])
		return pm._links(p, prop, pm.facing(p, prop))
	_check([links.call(2, 10), links.call(2, 9)] == [1, 4], "1 x 2 bed links: the head row to its foot, the foot row to its head")
	_check([links.call(5, 10), links.call(6, 9)] == [1 | 2, 4 | 8], "2 x 2 bed links: one wide bed")
	_check([links.call(9, 10), links.call(8, 9)] == [1, 4], "dorm row: three single beds side by side, not joined")
	_check(links.call(2, 1) == (2 | 8), "counters: the row joins")
	var tops := 0   # pillow top faces: 6 vertices each; colours are stored as 8 bits per channel
	var arrays := r.props.surface_get_arrays(0)
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var P := PropShapes.PILLOW
	for k in colours.size():
		var c := colours[k]
		if normals[k].y > 0.9 and absf(c.r - P.r) < 0.005 and absf(c.g - P.g) < 0.005 and absf(c.b - P.b) < 0.005:
			tops += 1
	_check(tops == 6 * 6, "one pillow per bed head tile: 1 + 2 + 3 = %d" % (tops / 6))
	var face_d: int = pm.facing(base + Vector3i(5, 9, 0), cat.furniture(sm.furn[at.call(5, 9)]))
	var tile := {at.call(5, 9): Transform3D(Basis(Vector3.UP, PropMesher.YAW[face_d]), Vector3(5.5, 0, 9.5))}
	var on_bed: Array = pm.pile_transforms(sm, base, sm.items.slice(0, Snapshot.PILE_STRIDE), tile)
	_check(on_bed.size() == 2 and on_bed.all(func(e: Array) -> bool:
		var o: Vector3 = (e[0] as Transform3D).origin
		return absf(o.y - 0.58) < 0.001 and o.x > 5.0 and o.x < 6.0 and o.z > 9.0 and o.z < 10.0),
			"items on a joined bed lie on its blanket, on their own tile")
