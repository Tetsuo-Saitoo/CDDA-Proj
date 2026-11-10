extends RefCounted
## Block C7 checks, run by run_tests.gd: the map's z range from the snapshot (`z_levels`), no nodes for submaps
## with nothing to draw, the levels with something drawn, and the cutaway stepping over empty levels.

var _check: Callable
var _air := 0
var _floor := 0


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("z-levels (C7)")
	_air = tables.index_of("ter", "t_open_air")
	_floor = tables.index_of("ter", "t_floor")
	_test_z_levels(data)
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(world)
	world.set_id_tables(tables)
	_test_empty_levels(world)
	_test_stepping(world)
	_test_props_only(world, tables)
	_test_tall_sky(world)
	world.free()


func _test_z_levels(data: Variant) -> void:
	var plain := Snapshot.from_data(data)
	_check.call(plain.is_valid() and plain.z_min == -10 and plain.z_max == 10 and plain.max_submaps() == 2541,
			"levels: no z_levels -> -10..10, at most 2541 submaps")
	var tall: Dictionary = (data as Dictionary).duplicate(true)
	tall["z_levels"] = [-20, 30]
	var high: Dictionary = (tall["submaps"][0] as Dictionary).duplicate(true)
	var at := Vector3i(int(high["pos"][0]), int(high["pos"][1]), 25)
	high["pos"] = [at.x, at.y, at.z]
	(tall["submaps"] as Array).append(high)
	tall["creatures"] = [{"uid": 7, "kind": 2, "pos": [at.x * 12, at.y * 12, 25]}]
	var s := Snapshot.from_data(tall)
	_check.call(s.is_valid() and s.z_min == -20 and s.z_max == 30 and s.submaps.has(at) and s.creatures.size() == 1
			and s.max_submaps() == 121 * 51, "levels: [-20, 30] read; a submap and a creature at z 25 validate " + s.error)
	tall.erase("z_levels")
	_check.call(not Snapshot.from_data(tall).is_valid(), "levels: the same z 25 refused without z_levels")
	for bad: Variant in [[5, 3], [1, 2], [-2, -1], ["-10", "10"], [-10, "10"], [-65, 10], [-10, 65], [-1e30, 10],
			[-1.5, 10], [-10], [-10, 10, 0], [], {}, null, "-10..10"]:
		var d: Dictionary = (data as Dictionary).duplicate(true)
		d["z_levels"] = bad
		var r := Snapshot.from_data(d)
		_check.call(not r.is_valid() and r.submaps.is_empty(), "levels: z_levels %s refused (%s)" % [str(bad), r.error])


## Two submaps side by side on each given level: z -> [terrain id, revision], plus extra keys per submap.
func _snap(levels: Dictionary, z_levels := [], extra := {}) -> Snapshot:
	var subs := []
	for z: int in levels:
		var ter: int = levels[z][0]
		for x in 2:
			var sm := {"pos": [x, 0, z], "revision": levels[z][1], "detail_revision": 1, "ter": _fill(ter),
					"furn": _fill(0), "flags": _fill(Snapshot.FLAG_NO_FLOOR if ter == _air else 0),
					"vis": _fill(2), "light": _fill(100)}
			sm.merge(extra.get(Vector3i(x, 0, z), {}), true)
			subs.append(sm)
	var d := {"contract_version": 0, "turn": 1, "seq": 1, "bubble_origin": [0, 0, 0], "submaps": subs}
	if not z_levels.is_empty():
		d["z_levels"] = z_levels
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid(), "levels: test snapshot valid " + snap.error)
	return snap


static func _fill(v: int) -> Array:
	var a := []
	a.resize(Snapshot.TILES)
	a.fill(v)
	return a


func _test_empty_levels(world: WorldView) -> void:
	var s := _snap({0: [_floor, 1], 1: [_air, 1], 2: [_floor, 1], 3: [_air, 1]}, [-2, 5])
	_check.call(world.apply_snapshot(s) == 8, "levels: all 8 submaps built")
	_check.call(world.node_of(Vector3i(0, 0, 1)) == null and world.node_of(Vector3i(1, 0, 3)) == null
			and world.node_of(Vector3i(0, 0, 0)) != null and world.node_of(Vector3i(1, 0, 2)) != null
			and world.get_child_count() == 4, "levels: open sky gets no node, floors do (4 nodes for 8 submaps)")
	_check.call(world.built_revision(Vector3i(0, 0, 1)) == 1 and world.built_revision(Vector3i(1, 0, 3)) == 1,
			"levels: an empty submap still counts as built")
	_check.call(world.apply_snapshot(s) == 0, "levels: same revisions, nothing rebuilt (empty ones included)")
	_check.call(world.levels_with_content() == PackedInt32Array([0, 2]) and world.z_min_content == 0
			and world.z_max_content == 2 and world.z_min_loaded == 0 and world.z_max_loaded == 3,
			"levels: content on 0 and 2 of the loaded 0..3")
	_check.call(world.coords.z_min == -2 and world.coords.z_max == 5, "levels: the snapshot's z range reaches coords")


func _test_stepping(world: WorldView) -> void:
	world.set_view_z_max(world.coords.z_max)
	_check.call(world.view_z_max == 2 and world.level_text() == "level 2 (0..2)" and world.things_z_max() == 5,
			"levels: every level: view at the top content level, creatures uncut up to the map's top")
	world.step_view_z(-1)
	_check.call(world.view_z_max == 0 and not world.node_of(Vector3i(0, 0, 2)).visible
			and world.node_of(Vector3i(0, 0, 0)).visible and world.things_z_max() == 0,
			"levels: cutaway down jumps over empty level 1")
	world.step_view_z(-1)
	_check.call(world.view_z_max == 0, "levels: and stays at the bottom content level")
	world.step_view_z(1)
	_check.call(world.view_z_max == 2 and world.node_of(Vector3i(0, 0, 2)).visible, "levels: cutaway up jumps over it too")
	world.step_view_z(1)
	_check.call(world.view_z_max == 2, "levels: and stays at the top content level")
	world.set_view_z_max(-99)
	_check.call(world.view_z_max == 0, "levels: clamped to the content range")
	# Floors on 1 and 3: new nodes; a cutaway at 0 stays, one at the top follows the top up.
	var grown := _snap({0: [_floor, 1], 1: [_floor, 2], 2: [_floor, 1], 3: [_floor, 2]})
	world.apply_snapshot(grown)
	_check.call(world.node_of(Vector3i(0, 0, 1)) != null and world.node_of(Vector3i(1, 0, 3)) != null
			and world.levels_with_content() == PackedInt32Array([0, 1, 2, 3]) and world.view_z_max == 0,
			"levels: a level that gets a floor gets nodes; a cut view stays cut")
	world.set_view_z_max(3)
	world.apply_snapshot(_snap({0: [_floor, 1], 1: [_air, 3], 2: [_floor, 1], 3: [_air, 3]}))
	_check.call(world.node_of(Vector3i(0, 0, 1)) == null and world.get_child_count() == 4 and world.view_z_max == 2
			and world.levels_with_content() == PackedInt32Array([0, 2]), "levels: back to sky: nodes freed, view comes down")
	world.apply_snapshot(grown)
	_check.call(world.view_z_max == 3, "levels: a view at the top follows the top up")
	_check.call(world.coords.z_min == -10 and world.coords.z_max == 10, "levels: no z_levels: coords back to -10..10")


## A pile on open air: props alone make the node, and their going frees it.
func _test_props_only(world: WorldView, tables: IdTables) -> void:
	var levels := {0: [_floor, 1], 1: [_air, 1]}
	world.apply_snapshot(_snap(levels))
	var item := tables.index_of("itype", "101_carpentry")
	var pile := {Vector3i(0, 0, 1): {"detail_revision": 2, "items": [[5, 1, [item]]]}}
	_check.call(world.apply_snapshot(_snap(levels, [], pile)) == 0 and world.node_of(Vector3i(0, 0, 1)) != null
			and world.levels_with_content() == PackedInt32Array([0, 1]), "levels: an item on an empty submap makes its node")
	var gone := {Vector3i(0, 0, 1): {"detail_revision": 3}}
	_check.call(world.apply_snapshot(_snap(levels, [], gone)) == 0 and world.node_of(Vector3i(0, 0, 1)) == null
			and world.levels_with_content() == PackedInt32Array([0]), "levels: and its going frees it")


## 21 levels, a floor on one: 2 nodes, not 42.
func _test_tall_sky(world: WorldView) -> void:
	var levels := {}
	for z in range(-10, 11):
		levels[z] = [_floor if z == 0 else _air, 5]
	_check.call(world.apply_snapshot(_snap(levels)) > 0 and world.get_child_count() == 2
			and world.z_min_loaded == -10 and world.z_max_loaded == 10 and world.level_text() == "level 0 (0..0)",
			"levels: 21 levels of sky around one floor: 2 nodes")
	world.step_view_z(1)
	world.step_view_z(-1)
	_check.call(world.view_z_max == 0, "levels: stepping with one content level stays on it")
