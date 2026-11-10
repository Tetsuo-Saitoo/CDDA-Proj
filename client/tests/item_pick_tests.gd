extends RefCounted
## Blocks E6 / L8: single items on the ground. PropMesher draws one item per snapshot handle (spots, stacks,
## hidden ones), WorldView keeps their slots and hides a held item at once, ItemPicker points at them (ray,
## hand, reach) and lists what the player carries. Run by run_tests.gd on a scene cut from the mock town.

const AT_TABLE := Vector2i(5, 5)
const AT_FLOOR := Vector2i(2, 5)
const AT_DRESSER := Vector2i(7, 5)
const AT_STACK := Vector2i(8, 8)
const AT_WALL := Vector2i(5, 9)
const AT_WALLED := Vector2i(6, 9)   # behind the wall, seen from the west

var _check: Callable
var _tables: IdTables
var _pos := Vector3i.ZERO   # the scene's submap (the mock's first, rewritten)
var _ids := {}              # item id -> itype index


func run(_root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_tables = tables
	print("item picking")
	for id: String in ["101_carpentry", "hammer", "rock", "can_beans", "backpack"]:
		_ids[id] = tables.index_of("itype", id)
	var p: Array = (data as Dictionary)["submaps"][0]["pos"]
	_pos = Vector3i(int(p[0]), int(p[1]), int(p[2]))
	var snap := _scene(data, true)
	_check.call(snap.is_valid() and _ids.values().all(func(i: int) -> bool: return i > 0), "items: scene valid " + snap.error)
	if not snap.is_valid():
		return
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	world.apply_snapshot(snap)
	_test_mesher(world, snap, _scene(data, false))
	_test_hidden(world, data)
	_test_picker(world)
	_test_carried(world)
	_test_no_snapshot()
	world.free()


static func _at(v: Vector2i) -> int:
	return v.y * CddaCoords.SEEX + v.x


func _sq(v: Vector2i) -> Vector3i:
	return CddaCoords.sm_to_ms(_pos) + Vector3i(v.x, v.y, 0)


func _it(id: String) -> int:
	return _ids[id]


## The mock's first submap rewritten (floor; a table, a dresser, a wall; piles with or without handles) and
## its second as it is; the player stands at 3,4 carrying a backpack with a book in it and a hammer.
func _scene(data: Variant, with_handles: bool) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate()
	var src: Array = d["submaps"]
	var sm: Dictionary = (src[0] as Dictionary).duplicate(true)
	d["submaps"] = [sm, src[1]]
	var player: Dictionary = (d["player"] as Dictionary).duplicate(true)
	player["pos"] = [_pos.x * 12 + 3, _pos.y * 12 + 4, _pos.z]
	player["items"] = [[10, _it("backpack"), 0, -1, Snapshot.CARRIED_WORN], [11, _it("101_carpentry"), 10, 0, 0],
			[12, _it("hammer"), 0, -1, Snapshot.CARRIED_WIELDED]]
	d["player"] = player
	var floor_id := _tables.index_of("ter", "t_floor")
	for i in 144:
		sm["ter"][i] = floor_id
		sm["furn"][i] = 0
		sm["trap"][i] = 0
		sm["flags"][i] = 1
	sm["ter"][_at(AT_WALL)] = _tables.index_of("ter", "t_wall_w")
	sm["furn"][_at(AT_TABLE)] = _tables.index_of("furn", "f_table")
	sm["furn"][_at(AT_DRESSER)] = _tables.index_of("furn", "f_dresser")
	var book := _it("101_carpentry")
	var rock := _it("rock")
	var beans := _it("can_beans")
	sm["items"] = [[_at(AT_TABLE), 2, [book, _it("hammer"), 0, 0]], [_at(AT_FLOOR), 5, [_it("backpack"), beans, rock, 0]],
			[_at(AT_DRESSER), 2, [book, 0, 0, 0]], [_at(AT_STACK), 20, [rock, 0, 0, 0]], [_at(AT_WALLED), 1, [beans, 0, 0, 0]]]
	var hs := [[_at(AT_TABLE), 101, book, 500, 500], [_at(AT_TABLE), 102, _it("hammer"), 250, 750],
			[_at(AT_FLOOR), 201, rock, 200, 500], [_at(AT_FLOOR), 202, beans, 800, 500],
			[_at(AT_FLOOR), 203, _it("backpack"), 500, 900],
			[_at(AT_DRESSER), 301, book, -1, -1], [_at(AT_DRESSER), 302, book, 500, 500],
			[_at(AT_WALLED), 401, beans, 500, 500]]
	for k in 20:
		hs.append([_at(AT_STACK), 501 + k, rock, -1, -1])
	sm["handles"] = hs if with_handles else []
	return Snapshot.from_data(d)


func _build(world: WorldView, snap: Snapshot, hidden := {}) -> PropMesher.Result:
	world.catalog.set_snapshot(snap)
	world.props.set_snapshot(snap)
	var pm := PropMesher.new(snap, world.catalog, world.props)
	pm.hidden = hidden
	return pm.build(_pos)


func _slots(r: PropMesher.Result, v: Vector2i) -> Array:
	return r.item_slots.filter(func(e: Array) -> bool: return e[2] == _at(v))


func _test_mesher(world: WorldView, snap: Snapshot, bare: Snapshot) -> void:
	var r := _build(world, snap)
	var on_floor := _slots(r, AT_FLOOR)
	_check.call(r.items == 2 + 5 + 20 + 1 and on_floor.map(func(e: Array) -> int: return e[0]) == [201, 202, 203]
			and on_floor.map(func(e: Array) -> int: return e[1]) == [_it("rock"), _it("can_beans"), _it("backpack")],
			"items: one per handle, in order, with its itype; clutter for the rest (%d shown)" % r.items)
	var rect: Array = PropShapes.FLOOR_INFO["rect"]
	var o201: Vector3 = (on_floor[0][3] as Transform3D).origin
	var want := Vector3(AT_FLOOR.x + 0.5 + lerpf(rect[0], rect[2], 0.2), 0.0, AT_FLOOR.y + 0.5 + lerpf(rect[1], rect[3], 0.5))
	_check.call(o201.distance_to(want) < 0.001, "items: a spot puts the item at that place of its square (%s)" % o201)
	var table := world.props.furniture(_tables.index_of("furn", "f_table"))
	var tr: Array = PropShapes.info("table")["rect"]
	var o102: Vector3 = (_slots(r, AT_TABLE)[1][3] as Transform3D).origin
	var want_t := Vector3(AT_TABLE.x + 0.5, 0.77, AT_TABLE.y + 0.5) + table.offset \
			+ Vector3((tr[2] - tr[0]) * (0.25 - 0.5), 0.0, (tr[3] - tr[1]) * (0.75 - 0.5))
	_check.call(table.model == null and table.shape == "table" and o102.distance_to(want_t) < 0.001,
			"items: a spot on a table: on its top, toward that side of the square (%s)" % o102)
	_check.call(_slots(r, AT_DRESSER).is_empty(), "items: handles in a closed dresser get no slot")
	_check.call(str(_build(world, snap).item_slots) == str(r.item_slots), "items: placement is deterministic")
	var st := _slots(r, AT_STACK)
	var spread := st.size() == 20
	for a in mini(st.size(), 16):
		for b in a:
			var d: Vector3 = (st[a][3] as Transform3D).origin - (st[b][3] as Transform3D).origin
			spread = spread and Vector2(d.x, d.z).length() > 0.12
	_check.call(spread, "items: 16 items each on their own sub-tile slot")
	if st.size() == 20:
		var lo: Transform3D = st[0][3]
		var hi: Transform3D = st[16][3]
		_check.call(Vector2(lo.origin.x - hi.origin.x, lo.origin.z - hi.origin.z).length() < 0.0001
				and hi.origin.y > lo.origin.y + 0.005 and (st[16][5] as Vector3).y > (st[0][5] as Vector3).y,
				"items: the 17th and later lie on top of the first ones")
	var rb := _build(world, bare)
	_check.call(rb.item_slots.is_empty() and rb.items == 2 + 5 + 8 + 1, "items: piles without handles draw as before (%d)" % rb.items)
	var rh := _build(world, snap, {201: true})
	_check.call(rh.items == r.items - 1 and not rh.item_slots.any(func(e: Array) -> bool: return e[0] == 201),
			"items: a hidden item is neither drawn, slotted nor clutter")
	_check.call(_slots(rh, AT_FLOOR)[0][3] == on_floor[1][3] and _slots(rh, AT_STACK)[1][3] == st[1][3],
			"items: the rest of the pile stays put")
	var ball := WorldView.item_hit_radius(on_floor[0][4])
	_check.call(ball >= WorldView.ITEM_HIT_MIN_M and (on_floor[0][5] as Vector3).y > o201.y, "items: hit as a ball around its middle")


func _test_hidden(world: WorldView, data: Variant) -> void:
	var other_pos: Vector3i = Vector3i.ZERO
	for pos: Vector3i in world.snapshot.submaps:
		if pos != _pos:
			other_pos = pos
	var mesh_of := func(pos: Vector3i) -> Mesh:
		var mi := world.node_of(pos).get_node_or_null("props") as MeshInstance3D
		return mi.mesh if mi != null else null
	var mine: Mesh = mesh_of.call(_pos)
	var other: Mesh = mesh_of.call(other_pos)
	_check.call(not world.item_slot(201).is_empty() and world.item_slot(301).is_empty(), "items: drawn items have a slot, hidden ones don't")
	world.set_hidden_items({201: true})
	_check.call(world.item_slot(201).is_empty() and world.props_built == 1 and mesh_of.call(_pos) != mine
			and mesh_of.call(other_pos) == other, "items: a hidden item leaves its pile at once, only its submap rebuilt")
	world.set_hidden_items({})
	_check.call(not world.item_slot(201).is_empty() and world.props_built == 1, "items: and comes back when shown again")
	var bumped := _scene(data, true)
	(bumped.submaps[_pos] as Snapshot.Submap).detail_revision += 1
	world.submit(bumped)
	world.set_hidden_items({202: true})
	world.finish_pending()
	_check.call(world.item_slot(202).is_empty() and not world.item_slot(201).is_empty(),
			"items: hidden while a snapshot meshes: gone once it shows")
	world.set_hidden_items({})
	_check.call(not world.item_slot(202).is_empty(), "items: and back")
	var many := {"x": true}
	for k in 100:
		many[1000 + k] = true
	world.set_hidden_items(many)
	_check.call(world.hidden_items.size() == WorldView.MAX_HIDDEN and not world.hidden_items.has("x"), "items: hidden items capped, ints only")
	world.set_hidden_items({})


func _test_picker(world: WorldView) -> void:
	var pk := ItemPicker.new(world)
	var reach: Array = [_sq(Vector2i(2, 4))]
	pk.reach = func() -> Variant: return reach[0]
	var c201: Vector3 = world.item_slot(201)[3]
	var c202: Vector3 = world.item_slot(202)[3]
	var eye := world.coords.ms_to_world(_sq(Vector2i(2, 3))) + Vector3(0.5, 1.6, 0.5)
	var r1 := pk.on_ray(eye, c201 - eye)
	var r2 := pk.on_ray(eye, c202 - eye)
	_check.call(r1 != null and r1.uid == 201 and r1.type == _it("rock") and r1.square == _sq(AT_FLOOR)
			and r1.spot.is_equal_approx(Vector2(0.2, 0.5)) and r1.is_drawn() and r1.size_m > 0.0
			and r2 != null and r2.uid == 202, "items: the ray picks the one of two it points at")
	reach[0] = _sq(Vector2i(5, 10))
	var behind: Vector3 = world.item_slot(401)[3]
	var eye2 := world.coords.ms_to_world(_sq(Vector2i(4, 9))) + Vector3(0.5, 1.6, 0.5)
	_check.call(pk.on_ray(eye2, behind - eye2) == null
			and not world.items_on_ray(eye2, (behind - eye2).normalized(), reach[0], 4.0).is_empty(),
			"items: a wall hides the item behind it")
	reach[0] = _sq(Vector2i(4, 5))
	var on_table: Vector3 = world.item_slot(101)[3]
	var eye3 := world.coords.ms_to_world(_sq(Vector2i(3, 5))) + Vector3(0.5, 1.2, 0.5)
	var lr := pk.look_ray.cast(eye3, on_table - eye3, 4.0, false)
	var r3 := pk.on_ray(eye3, on_table - eye3)
	_check.call(lr["hit"] and lr["what"] == "furniture" and r3 != null and r3.uid == 101,
			"items: an item on a table is hit though the ray meets the table first")
	reach[0] = _sq(Vector2i(2, 4))
	var n1 := pk.near(c201 + Vector3(0.05, 0, 0))
	_check.call(n1 != null and n1.uid == 201 and n1.is_drawn() and pk.near(c201 + Vector3(0, 1.0, 0)) == null,
			"items: a hand picks the item it is at")
	_check.call(pk.in_reach(_sq(Vector2i(3, 5))) and pk.in_reach(_sq(Vector2i(2, 4))) and not pk.in_reach(_sq(Vector2i(4, 4)))
			and not pk.in_reach(_sq(Vector2i(2, 4)) + Vector3i(0, 0, 1)), "items: reach is the square and the 8 around it, same level")
	reach[0] = _sq(Vector2i(6, 1))
	_check.call(pk.near(c201) == null and pk.on_ray(eye, c201 - eye) == null, "items: nothing out of reach")
	reach[0] = null
	_check.call(pk.on_ray(eye, c201 - eye) == null and not pk.in_reach(_sq(AT_FLOOR)), "items: no reach square, nothing")
	pk.reach = Callable()
	_check.call(pk.in_reach(_sq(AT_FLOOR)) and not pk.in_reach(_sq(AT_TABLE)), "items: without a reach callable, the player's square")


func _test_carried(world: WorldView) -> void:
	var pk := ItemPicker.new(world)
	var c := pk.carried()
	_check.call(c.size() == 3 and c[0].uid == 10 and c[0].is_worn() and c[2].is_wielded() and c[1].parent == 10
			and c[1].pocket == 0 and c.all(func(r: ItemRef) -> bool: return r.carried and r.square == world.snapshot.player_pos),
			"items: carried items from the snapshot")
	var inside := pk.contents(10)
	_check.call(inside.size() == 1 and inside[0].uid == 11, "items: a container's contents")
	var b11 := pk.by_uid(11)
	var b202 := pk.by_uid(202)
	var b301 := pk.by_uid(301)
	_check.call(b11 != null and b11.carried and b202 != null and not b202.carried and b202.square == _sq(AT_FLOOR)
			and b202.spot.is_equal_approx(Vector2(0.8, 0.5)) and b202.is_drawn() and b301 != null and not b301.is_drawn()
			and pk.by_uid(999) == null, "items: by uid, carried or on the ground (drawn or not)")


func _test_no_snapshot() -> void:
	var w := WorldView.new()
	var pk := ItemPicker.new(w)
	w.set_hidden_items({5: true})
	_check.call(pk.on_ray(Vector3.ZERO, Vector3.FORWARD) == null and pk.near(Vector3.ZERO) == null
			and not pk.in_reach(Vector3i.ZERO) and pk.carried().is_empty() and pk.contents(0).is_empty() and pk.by_uid(1) == null
			and w.items_on_ray(Vector3.ZERO, Vector3.FORWARD, Vector3i.ZERO, 4.0).is_empty() and w.item_slot(5).is_empty(),
			"items: no snapshot, nothing picked")
	w.free()
