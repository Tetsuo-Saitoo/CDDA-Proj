extends RefCounted
## Live item tiles: the shared values (ItemLook: CDDA's rot bands, the spoilage colours and tint, hostile values
## fall back to "nothing to show"), the snapshot's `player.item_states` (look-only: a malformed entry is left out,
## the snapshot still loads), and the 3D shells (ItemLookView) on items lying next to the player in the mock
## town. Run by run_tests.gd.

const L := preload("res://scripts/world/item_look.gd")

var _check: Callable

const P := Vector3i(192, 384, 0)       # the mock town's player
const SM := Vector3i(16, 32, 0)        # its submap; the player's tile is 0, tile 1 is east of it
const U_HOT := 501
const U_ICE := 502
const U_OFF := 503
const U_NONE := 504


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("live item state (ItemLook)")
	_test_values()
	_test_colours()
	_test_snapshot(data, tables)
	_test_shells(root, data, tables)


## The mock town with four items east of the player (a hot rock, a frozen hammer with water a quarter up a
## see-through pocket, a rotten can of beans, a book with nothing to show), a carried frozen hammer, and
## `player.item_states` for them (entries [uid, temp, rot, fill, fill_type, see_through, fill_ml, dirt]);
## `edit` changes the data.
func _data(data: Variant, tables: IdTables, edit := Callable()) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var ids := ["rock", "hammer", "can_beans", "101_carpentry"].map(func(n: String) -> int: return tables.index_of("itype", n))
	var water := maxi(tables.index_of("itype", "water"), 0)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		if Vector3i(int(pos[0]), int(pos[1]), int(pos[2])) == SM:
			sm["items"] = [[1, 4, ids]]
			sm["handles"] = [[1, U_HOT, ids[0], 200, 300], [1, U_ICE, ids[1], 700, 300], [1, U_OFF, ids[2], 300, 700],
					[1, U_NONE, ids[3], 700, 700]]
			for k: String in ["poses", "shelves", "inside", "inside_more", "more"]:
				sm.erase(k)
	var pl: Dictionary = d["player"]
	pl["items"] = [[601, ids[1], 0, -1, 2]]
	pl["item_states"] = [[U_HOT, 1, -1, -1, 0, 0, -1, -1], [U_ICE, 3, -1, 250, water, 1, 250, -1],
			[U_OFF, 0, 1500, 900, 0, 0, 450, -1], [U_NONE, 0, 50, -1, 0, 0, -1, -1], [601, 3, -1, -1, 0, 0, -1, 2500]]
	if edit.is_valid():
		edit.call(d)
	return d


const GOOD_HOT := [U_HOT, 1, -1, -1, 0, 0, -1, -1]


func _test_snapshot(data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(_data(data, tables))
	var st := snap.item_states
	_check.call(snap.is_valid() and st.size() == 5 and Array(st.get(U_ICE, [])) == [3, -1, 250, maxi(tables.index_of("itype", "water"), 0), 1, 250, -1]
			and Array(st.get(601, [])) == [3, -1, -1, 0, 0, -1, 2500] and Array(st.get(U_HOT, [])) == GOOD_HOT.slice(1),
			"item state: the snapshot reads the states of lying and carried items " + snap.error)
	_check.call(Snapshot.STATE_SIZE == ItemLookView.S_SIZE and Snapshot.MAX_DIRT == L.DIRT_MAX and Snapshot.MAX_STATE_ML == L.ML_MAX,
			"item state: the snapshot and ItemLook agree on the format")
	var old := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void: (d["player"] as Dictionary).erase("item_states")))
	_check.call(old.is_valid() and old.item_states.is_empty(), "item state: an older bridge sends none")
	var bag := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void:
		for sm: Dictionary in d["submaps"]:
			if Vector3i(int(sm["pos"][0]), int(sm["pos"][1]), int(sm["pos"][2])) == SM:
				sm["inside"] = [[U_OFF, 701, tables.index_of("itype", "rock"), 0]]
		(d["player"] as Dictionary)["item_states"] = [GOOD_HOT, [701, 0, 1500, -1, 0, 0, -1, -1], [702, 0, 1500, -1, 0, 0, -1, -1]]))
	_check.call(bag.is_valid() and Array(bag.item_states.get(701, [])) == [0, 1500, -1, 0, 0, -1, -1] and not bag.item_states.has(702),
			"item state: what is in a container lying next to the player has its state too (its tray row) " + bag.error)
	var junk := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void: (d["player"] as Dictionary)["item_states"] = {"x": 1}))
	_check.call(junk.is_valid() and junk.item_states.is_empty(), "item state: a list that isn't one is ignored")
	# Each bad entry is for U_NONE, next to a good one for U_HOT: the bad one goes, the rest stays.
	var n := U_NONE
	var bad := {
		"short": [n, 0, 50, -1, 0, 0, -1], "long": [n, 0, 50, -1, 0, 0, -1, -1, 0], "not a list": "x",
		"not a handle": [999, 0, 50, -1, 0, 0, -1, -1], "uid 0": [0, 0, 50, -1, 0, 0, -1, -1],
		"uid not whole": [n + 0.5, 0, 50, -1, 0, 0, -1, -1], "temp 4": [n, 4, -1, -1, 0, 0, -1, -1],
		"temp -1": [n, -1, -1, -1, 0, 0, -1, -1], "rot 2001": [n, 0, 2001, -1, 0, 0, -1, -1], "rot -2": [n, 0, -2, -1, 0, 0, -1, -1],
		"fill 1001": [n, 0, -1, 1001, 0, 0, 5, -1], "fill without ml": [n, 0, -1, 500, 0, 0, -1, -1],
		"ml without fill": [n, 0, -1, -1, 0, 0, 5, -1], "type -1": [n, 0, -1, -1, -1, 0, -1, -1],
		"type huge": [n, 0, -1, -1, Snapshot.MAX_ID + 1, 0, -1, -1], "see 2": [n, 0, -1, -1, 0, 2, -1, -1],
		"ml huge": [n, 0, -1, 10, 0, 0, Snapshot.MAX_STATE_ML + 1, -1], "dirt 10001": [n, 0, -1, -1, 0, 0, -1, 10001],
		"dirt -2": [n, 0, -1, -1, 0, 0, -1, -2], "NaN": [n, NAN, -1, -1, 0, 0, -1, -1], "INF": [n, 0, INF, -1, 0, 0, -1, -1],
		"text": [n, "1", -1, -1, 0, 0, -1, -1], "null": [n, 0, null, -1, 0, 0, -1, -1], "huge": [n, 0, 1e300, -1, 0, 0, -1, -1],
	}
	var kept := PackedStringArray()
	for k: String in bad:
		var e: Variant = bad[k]
		var sn := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void: (d["player"] as Dictionary)["item_states"] = [GOOD_HOT, e]))
		if not (sn.is_valid() and sn.item_states.size() == 1 and sn.item_states.has(U_HOT)):
			kept.append(k)
	_check.call(kept.is_empty(), "item state: a malformed entry is left out, the snapshot still loads (wrong: %s)" % ", ".join(kept))
	var twice := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void:
		(d["player"] as Dictionary)["item_states"] = [GOOD_HOT, [U_HOT, 3, -1, -1, 0, 0, -1, -1]]))
	_check.call(twice.is_valid() and Array(twice.item_states.get(U_HOT, [])) == GOOD_HOT.slice(1), "item state: an item sent twice keeps its first state")
	var lots := range(Snapshot.MAX_ITEM_STATES).map(func(_i: int) -> Array: return GOOD_HOT) + [[U_ICE, 3, -1, -1, 0, 0, -1, -1]]
	var many := Snapshot.from_data(_data(data, tables, func(d: Dictionary) -> void: (d["player"] as Dictionary)["item_states"] = lots))
	_check.call(many.is_valid() and many.item_states.size() == 1 and not many.item_states.has(U_ICE),
			"item state: past %d entries the rest are left out" % Snapshot.MAX_ITEM_STATES)


func _test_shells(root: Node, data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(_data(data, tables))
	if not snap.is_valid():
		_check.call(false, "item state: the shell scene loads " + snap.error)
		return
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := ItemLookView.new()
	view.world = world
	root.add_child(view)
	view.apply(snap)
	view.tick(1.0)
	var param := func(uid: int, p: StringName) -> Variant:
		var sh := view.shell(uid)
		return (sh.get_meta(&"mat") as ShaderMaterial).get_shader_parameter(p) if sh != null else null
	_check.call(view.shell_count() == 3 and view.shell(U_NONE) == null and view.shell(601) == null,
			"item state: shells on the three lying items with something to show, none on the plain one or the carried one (%d)" % view.shell_count())
	_check.call(param.call(U_HOT, &"heat") == 1.0 and param.call(U_HOT, &"frost") == 0.0
			and param.call(U_ICE, &"frost") == 1.0 and param.call(U_ICE, &"heat") == 0.0
			and (param.call(U_OFF, &"tint") as Color).a > 0.5 and (param.call(U_HOT, &"tint") as Color).a == 0.0,
			"item state: the hot rock shimmers, the frozen hammer frosts, the rotten can is tinted")
	var slot := world.item_slot(U_ICE)
	var ice := view.shell(U_ICE)
	var wb: AABB = (slot[4] as Transform3D) * (ice.get_meta(&"box") as AABB) if not slot.is_empty() and ice != null else AABB()
	var ly: Variant = param.call(U_ICE, &"level_y")
	var model := world.props.item(tables.index_of("itype", "hammer")).model
	_check.call(ly is float and ly > wb.position.y + wb.size.y * 0.2 and ly < wb.position.y + wb.size.y * 0.3
			and (param.call(U_ICE, &"liquid") as Color).a > 0.0 and (param.call(U_OFF, &"liquid") as Color).a == 0.0
			and ice.global_transform.is_equal_approx(slot[4]) and (model == null or ice.get_child_count() == model.parts.size()),
			"item state: the see-through one shows its liquid a quarter up, over its own meshes; the opaque can none (%s in %s)" % [ly, wb])
	var hot_slot := world.item_slot(U_HOT)
	world.set_hidden_items({U_HOT: true})
	view.tick(0.01)
	_check.call(not view.shell(U_HOT).visible and view.shell(U_ICE).visible, "item state: an item taken into a hand loses its shell")
	var body_xf := (hot_slot[4] as Transform3D).translated(Vector3(0.3, 0.4, 0.0)) if not hot_slot.is_empty() else Transform3D()
	view.body_slot = func(uid: int) -> Array:
		return [uid, hot_slot[1], hot_slot[2], body_xf.origin, body_xf, hot_slot[5]] if uid == U_HOT else []
	view.tick(0.01)
	var on_body := view.shell(U_HOT).visible and view.shell(U_HOT).global_transform.is_equal_approx(body_xf)
	view.body_slot = func(uid: int) -> Array: return [uid, "x", 0, Vector3(NAN, 0, 0), body_xf, 1.0] if uid == U_HOT else []
	view.tick(0.01)
	_check.call(not hot_slot.is_empty() and on_body and not view.shell(U_HOT).visible,
			"item state: an item drawn as a physics body (static copy hidden) keeps its shell, on the body; a malformed body entry hides it")
	view.body_slot = Callable()
	world.set_hidden_items({})
	view.set_states({U_ICE: PackedInt32Array([3, -1, -1, 0, 0, -1, -1]), "x": PackedInt32Array([1, 0, 0, 0, 0, 0, 0]),
			U_OFF: PackedInt32Array([1]), U_HOT: [1, -1, -1, 0, 0, -1, -1]})
	view.tick(0.01)
	_check.call(view.shell_count() == 1 and view.shell(U_ICE) != null, "item state: new states replace the old; malformed ones are left out")
	view.set_states({U_NONE: PackedInt32Array([0, -1, -1, 0, 0, -1, 5000])})
	view.tick(0.01)
	var gun := view.shell(U_NONE)
	var gun_mat := gun.get_meta(&"mat") as ShaderMaterial if gun != null else null
	_check.call(gun != null and is_equal_approx(GunGrime.level_of(gun), 0.5) and GunGrime.meshes(gun).size() >= 1
			and gun_mat.get_shader_parameter(&"frost") == 0.0 and gun_mat.get_shader_parameter(&"heat") == 0.0
			and not ItemLookView.shows(PackedInt32Array([0, -1, -1, 0, 0, -1, 0])) and not ItemLookView.shows(PackedInt32Array([0, -1, -1, 0, 0, -1, -1]))
			and not ItemLookView.shows(PackedInt32Array([0, -1, -1, 0, 0, -1, 99999])),
			"item state: a fouled gun lying in the world gets GunGrime's grime (half at 5000) and nothing else; clean or bad dirt shows nothing")
	if gun != null:
		ItemLookView.paint(gun, PackedInt32Array([1, -1, -1, 0, 0, -1, -1]), ItemLook.LIQUID_DEFAULT)
	_check.call(gun != null and GunGrime.level_of(gun) == 0.0, "item state: the grime goes when the gun is clean")
	view.set_states({})
	view.tick(0.01)
	_check.call(view.shell_count() == 0 and view.get_child_count() == 0, "item state: no states, no shells")
	var held := ItemLookView.make_shell(world.props.item(tables.index_of("itype", "hammer")), tables.index_of("itype", "hammer"))
	ItemLookView.paint(held, PackedInt32Array([1, -1, -1, 0, 0, -1, -1]), ItemLook.LIQUID_DEFAULT)
	_check.call((held.get_meta(&"mat") as ShaderMaterial).get_shader_parameter(&"heat") == 1.0 and held.get_child_count() >= 1,
			"item state: a shell can be made for an item in a hand too")
	held.free()
	view.free()
	world.free()


func _test_values() -> void:
	_check.call(L.temp_of(0) == L.Temp.NORMAL and L.temp_of(1) == L.Temp.HOT and L.temp_of(2) == L.Temp.COLD
			and L.temp_of(3.0) == L.Temp.FROZEN, "item state: temperatures 0 normal, 1 hot, 2 cold, 3 frozen read")
	var bad_temp := [-1, 4, 2.5, NAN, INF, "3", null, [3], 1e300]
	_check.call(bad_temp.all(func(v: Variant) -> bool: return L.temp_of(v) == L.Temp.NORMAL),
			"item state: a bad temperature shows nothing")
	_check.call(L.rot_of(0) == 0 and L.rot_of(950) == 950 and L.rot_of(2000) == 2000,
			"item state: rot 0..2000 read")
	var bad_rot := [-1, -5, 2001, 99999, 0.5, NAN, -INF, "500", null, {}, 1e300]
	_check.call(bad_rot.all(func(v: Variant) -> bool: return L.rot_of(v) == L.NO_ROT), "item state: a bad rot means it doesn't rot")
	_check.call(L.ml_of(0) == 0 and L.ml_of(2000) == 2000 and [-1, L.ML_MAX + 1, 0.3, NAN, "x", null, 1e300].all(
			func(v: Variant) -> bool: return L.ml_of(v) == L.NO_ML), "item state: volumes read, anything else isn't a container")
	_check.call(L.fill_of(0) == 0 and L.fill_of(1000) == 1000 and L.fill_of(250.0) == 250 and [-1, 1001, 0.5, NAN, "5", null, 1e300].all(
			func(v: Variant) -> bool: return L.fill_of(v) == L.NO_FILL), "item state: fill 0..1000 read, anything else isn't a container")
	_check.call(L.level(500) == 0.5 and L.level(1000) == 1.0 and L.level(250.0) == 0.25 and L.level(0) == 0.0
			and L.level(L.NO_FILL) == 0.0 and L.level(1001) == 0.0 and L.level(NAN) == 0.0 and L.level("x") == 0.0,
			"item state: the level is the fill, empty when it isn't a container")
	_check.call(L.dirt_of(0) == 0 and L.dirt_of(L.DIRT_MAX) == L.DIRT_MAX and [-1, L.DIRT_MAX + 1, 0.5, INF, "1", null].all(
			func(v: Variant) -> bool: return L.dirt_of(v) == L.NO_DIRT), "item state: fouling 0..10000 read, anything else none")
	_check.call(L.rot_band(-1) == "" and L.rot_band(0) == "fresh" and L.rot_band(99) == "fresh" and L.rot_band(100) == ""
			and L.rot_band(900) == "" and L.rot_band(901) == "old" and L.rot_band(1000) == "old" and L.rot_band(1001) == "rotten",
			"item state: CDDA's bands (fresh under 0.1, old past 0.9, rotten past 1.0)")


func _test_colours() -> void:
	_check.call(L.rot_color(-1).a == 0.0 and L.rot_color(0) == L.FRESH_COLOR and L.rot_color(L.OLD).is_equal_approx(L.OLD_COLOR)
			and L.rot_color(L.ROTTEN).is_equal_approx(L.ROTTEN_COLOR) and L.rot_color(1800).is_equal_approx(L.ROTTEN_COLOR),
			"item state: the icon colour goes green, yellow by old, brown when rotten")
	var mid := L.rot_color(500)
	_check.call(not mid.is_equal_approx(L.FRESH_COLOR) and not mid.is_equal_approx(L.OLD_COLOR) and mid.r > L.FRESH_COLOR.r,
			"item state: between fresh and old it is on the way")
	_check.call(L.rot_tint(-1).a == 0.0 and L.rot_tint(0).a == 0.0 and L.rot_tint(L.TINT_FROM).a == 0.0
			and L.rot_tint(750).a > 0.0 and L.rot_tint(750).a < L.TINT_MAX and is_equal_approx(L.rot_tint(L.ROTTEN).a, L.TINT_MAX)
			and is_equal_approx(L.rot_tint(2000).a, L.TINT_MAX),
			"item state: the 3D tint starts at %d and is full when rotten" % L.TINT_FROM)
	var water := IdTables.Def.new()
	water.color = "c_light_blue"
	var odd := IdTables.Def.new()
	odd.color = "c_" + "x".repeat(500)
	_check.call(L.liquid_color(water) == CddaPalette.NAMED["light_blue"] and L.liquid_color(odd) == L.LIQUID_DEFAULT
			and L.liquid_color(null) == L.LIQUID_DEFAULT, "item state: a liquid shows in its CDDA colour, else the default")
