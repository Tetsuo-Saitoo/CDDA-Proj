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
	_test_poses(world, data, snap)
	_test_hidden(world, data)
	_test_picker(world)
	_test_carried(world)
	_test_shelves(world, data, _root)
	_test_trays(world, data)
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
func _scene(data: Variant, with_handles: bool, poses: Variant = null, shelves: Variant = null) -> Snapshot:
	return Snapshot.from_data(_scene_data(data, with_handles, poses, shelves))


## _scene's JSON data.
func _scene_data(data: Variant, with_handles: bool, poses: Variant = null, shelves: Variant = null) -> Dictionary:
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
	if poses != null:
		sm["poses"] = poses
	if shelves != null:
		sm["shelves"] = shelves
	return d


func _build(world: WorldView, snap: Snapshot, hidden := {}) -> PropMesher.Result:
	world.catalog.set_snapshot(snap)
	world.props.set_snapshot(snap)
	var pm := PropMesher.new(snap, world.catalog, world.props)
	pm.hidden = hidden
	return pm.build(_pos)


func _slots(r: PropMesher.Result, v: Vector2i) -> Array:
	return r.item_slots.filter(func(e: Array) -> bool: return e[2] == _at(v))


## Placed items lie as their body lay (the snapshot's `poses`); the rest as before; bad poses are refused.
func _test_poses(world: WorldView, data: Variant, plain: Snapshot) -> void:
	var snap := _scene(data, true, [[201, 90, 0], [202, 0, 1]])
	_check.call(snap.is_valid() and (snap.submaps[_pos] as Snapshot.Submap).poses == {201: Vector2i(90, 0), 202: Vector2i(0, 1)},
			"poses: read per submap " + snap.error)
	if not snap.is_valid():
		return
	var was := _slots(_build(world, plain), AT_FLOOR)
	var now := _slots(_build(world, snap), AT_FLOOR)
	var xf := func(slots: Array, uid: int) -> Transform3D:
		for e: Array in slots:
			if e[0] == uid:
				return e[3]
		return Transform3D()
	var a: Transform3D = xf.call(now, 201)
	_check.call((a.basis * Vector3.BACK).normalized().is_equal_approx(Vector3.RIGHT)
			and (a.basis * Vector3.UP).normalized().is_equal_approx(Vector3.UP) and a.origin.is_equal_approx((xf.call(was, 201) as Transform3D).origin),
			"poses: yaw 90 turns the item's +Z from south to east, on the same spot")
	var b: Transform3D = xf.call(now, 202)
	var beans := world.props.item(_it("can_beans"))
	var low := (b * PropMesher._item_box(beans, _it("can_beans"))).position.y
	_check.call((b.basis * Vector3.UP).normalized().is_equal_approx(Vector3.BACK) and absf(low) < 0.001 and b.origin.y > 0.0,
			"poses: on its side its top points south and it rests on the floor (lowest %.4f)" % low)
	_check.call(str(xf.call(now, 203)) == str(xf.call(was, 203)), "poses: an item without a pose lies as before")
	_check.call(PropMesher.pose_basis(0, false) == Basis.IDENTITY
			and (PropMesher.pose_basis(270, true) * Vector3.UP).is_equal_approx(Vector3.LEFT), "poses: the basis follows the convention")
	for bad: Array in [[[201, 360, 0]], [[201, -1, 0]], [[201, 0, 2]], [[999, 0, 0]], [[201, 0, 0], [201, 5, 0]],
			[[201, 0]], [[201, 0.5, 0]], range(29).map(func(i: int) -> Array: return [201, 0, 0])]:
		_check.call(not _scene(data, true, bad).is_valid(), "poses: refused " + str(bad).left(40))
	_check.call(not _scene(data, true, {}).is_valid() and not _scene(data, false, [[201, 0, 0]]).is_valid(),
			"poses: refused when not a list, or with no handles")


## L8 slice 2: the snapshot's `shelves` (bounded like poses), an item put on a shelf drawn there (riding its
## drawer), and WorldView.shelf_at finding the shelf and spot under a point that draws an item there.
func _test_shelves(world: WorldView, data: Variant, root: Node) -> void:
	var snap := _scene(data, true, null, [[302, 2], [101, 0]])
	_check.call(snap.is_valid() and (snap.submaps[_pos] as Snapshot.Submap).shelves == {302: 2, 101: 0},
			"shelves: read per submap " + snap.error)
	if not snap.is_valid():
		return
	for bad: Array in [[[302, 16]], [[302, -1]], [[999, 0]], [[302, 0], [302, 1]], [[302]], [[302, 0.5]],
			range(29).map(func(i: int) -> Array: return [302, 0])]:
		_check.call(not _scene(data, true, null, bad).is_valid(), "shelves: refused " + str(bad).left(40))
	_check.call(not _scene(data, true, null, {}).is_valid() and not _scene(data, false, null, [[302, 0]]).is_valid()
			and (_scene(data, true).submaps[_pos] as Snapshot.Submap).shelves.is_empty(),
			"shelves: refused when not a list or with no handles; none from an older bridge")
	var m := PropBoxes.model_of(world.props.furniture(_tables.index_of("furn", "f_dresser")))
	var sq := _sq(AT_DRESSER)
	var mi := m.surface_mover[2] if m != null and m.surfaces.size() > 2 else -1
	var want := "%d_%d_%d/%s" % [sq.x, sq.y, sq.z, m.movers[mi].name] if mi >= 0 else ""
	var r := _build(world, snap)
	var ride := func(res: PropMesher.Result, uid: int) -> Variant:
		for e: Array in res.item_slots:
			if e[0] == uid:
				return e
		return []
	var e302: Array = ride.call(r, 302)
	var list: Array = r.shelves.get(sq, [])
	_check.call(want != "" and e302.size() > 6 and e302[6] == want and list.size() == m.surfaces.size()
			and list[2][2] == want and r.shelves.has(_sq(AT_TABLE)) and not r.shelves.has(_sq(AT_FLOOR)),
			"shelves: a book put on shelf 2 of a dresser rides that surface's drawer (%s); the dresser has %d shelves"
			% [e302[6] if e302.size() > 6 else "?", list.size()])
	if list.size() < 3 or want == "":
		return
	root.add_child(world)   # shelf_at reads where the submap and its drawers are now
	world.apply_snapshot(snap)
	var rest: Transform3D = list[2][0]
	var rect: Rect2 = list[2][1]
	var mid := rest * Vector3(rect.get_center().x, 0.0, rect.get_center().y)   # submap-local, the drawer shut
	_check.call((e302[3] as Transform3D).origin.distance_to(mid) < 0.01,
			"shelves: put at the middle of the square (spot 500, 500) it lies at that surface's middle")
	var node_xf := Transform3D(Basis.IDENTITY, world.coords.sm_to_world(_pos))
	var local := Vector3(rect.position.x + rect.size.x * 0.3, 0.05, rect.position.y + rect.size.y * 0.7)
	_check.call(world.shelf_at(node_xf * (rest * local)).is_empty(),
			"shelves: a drawer shut is no shelf (a drop over the dresser doesn't land inside it)")
	var g: Grabbable = world.parts.get(want)
	_check.call(g != null, "shelves: the drawer is a part")
	if g == null:
		root.remove_child(world)
		return
	g.set_amount(g.max_amount)
	var top := g.surface_global(list[2][3])
	var hit := world.shelf_at(top * local)
	var surf := PropMesher.Surface.new()
	surf.planes = [[rest, rect, 0.0]]
	var spot: Vector2 = hit.get("spot", Vector2(-1, -1))
	var uv := surf.spot_uv(0, spot)
	var drawn := surf.at(0, uv.x, uv.y)
	_check.call(hit.get("square") == sq and hit.get("shelf") == 2
			and drawn.distance_to(rest * Vector3(local.x, 0.0, local.z)) < 0.01,
			"shelves: shelf_at finds shelf 2 in the drawer pulled out (a hand %.2f m over its floor), and its spot "
			% local.y + "draws an item right there " + str(hit))
	var on := top * Vector3(local.x, 0.0, local.z)
	var ray := world.shelf_on_ray(on + Vector3(0.05, 1.2, 0.1), (on - (on + Vector3(0.05, 1.2, 0.1))), 3.0)
	_check.call(ray.get("shelf") == 2 and ray.get("square") == sq and (ray.get("point", Vector3.INF) as Vector3).distance_to(on) < 0.01
			and (ray.get("spot", Vector2.ZERO) as Vector2).distance_to(spot) < 0.01,
			"shelves: a ray coming down into the open drawer meets shelf 2 at the same spot " + str(ray))
	_check.call(world.shelf_on_ray(on - Vector3(0, 0.3, 0), Vector3.UP, 3.0).is_empty()
			and world.shelf_on_ray(on + Vector3(0, 1.2, 0), Vector3.DOWN, 1.0).is_empty()
			and world.shelf_on_ray(on + Vector3(0, 1.2, 0), Vector3.ZERO, 3.0).is_empty(),
			"shelves: no shelf for a ray from below, one too short or one with no direction")
	g.set_amount(0.0)
	var table := world.coords.ms_center_to_world(_sq(AT_TABLE)) + Vector3(0, 0.82, 0)
	var on_table := world.shelf_at(table)
	_check.call(on_table.get("shelf") == 0 and (on_table.get("spot", Vector2.ZERO) as Vector2).distance_to(Vector2(0.5, 0.5)) < 0.01,
			"shelves: over a placeholder table, its top is shelf 0 " + str(on_table))
	var slant := world.shelf_on_ray(table + Vector3(-1.5, 1.0, 0.0), Vector3(1.5, -1.0 - 0.05, 0.0), 5.0)
	_check.call(slant.get("shelf") == 0 and slant.get("square") == _sq(AT_TABLE)
			and (slant.get("point", Vector3.INF) as Vector3).distance_to(table - Vector3(0, 0.05, 0)) < 0.02,
			"shelves: a slanting ray meets the table top " + str(slant))
	_check.call(world.shelf_at(table + Vector3(0, 1.0, 0)).is_empty()
			and world.shelf_at(world.coords.ms_center_to_world(_sq(AT_FLOOR)) + Vector3(0, 0.05, 0)).is_empty()
			and world.shelf_at(Vector3(NAN, 0, 0)).is_empty(),
			"shelves: none in mid-air, on the bare floor or at a broken point")
	root.remove_child(world)


func _test_mesher(world: WorldView, snap: Snapshot, bare: Snapshot) -> void:
	var r := _build(world, snap)
	var on_floor := _slots(r, AT_FLOOR)
	_check.call(r.items == 2 + 5 + 2 + 20 + 1 and on_floor.map(func(e: Array) -> int: return e[0]) == [201, 202, 203]
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
	_check.call(_slots(r, AT_DRESSER).size() == 2 and _slots(r, AT_DRESSER).all(func(e: Array) -> bool: return (e[6] as String).contains("/drawer_")),
			"items: handles in a dresser ride its drawers (pointable while one is open)")
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
	_check.call(rb.item_slots.is_empty() and rb.items == 2 + 5 + 2 + 8 + 1, "items: piles without handles draw as before (%d)" % rb.items)
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
	# Two owners: what is drawn hides the union, and each owner only shows its own again.
	world.set_hidden_items({201: true})
	world.set_hidden_items_for(&"physics", {201: true, 202: true})
	_check.call(world.item_slot(201).is_empty() and world.item_slot(202).is_empty() and world.hidden_items.size() == 2,
			"items: hidden sets of two owners add up")
	world.set_hidden_items({})
	_check.call(world.item_slot(201).is_empty() and world.item_slot(202).is_empty(),
			"items: one owner showing an item another still hides leaves it hidden")
	world.set_hidden_items_for(&"physics", {})
	_check.call(not world.item_slot(201).is_empty() and not world.item_slot(202).is_empty() and world.hidden_items.is_empty(),
			"items: shown once no owner hides it")
	for k in WorldView.MAX_HIDDEN_OWNERS + 1:
		world.set_hidden_items_for(StringName("o%d" % k), {201: true})
	world.set_hidden_items_for(StringName("o%d" % WorldView.MAX_HIDDEN_OWNERS), {})
	for k in WorldView.MAX_HIDDEN_OWNERS:
		world.set_hidden_items_for(StringName("o%d" % k), {})
	_check.call(world.hidden_items.is_empty() and not world.item_slot(201).is_empty(), "items: owners capped, all cleared")


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


## Block L8 slices 3-4: a pile next to the player (AT_FLOOR) lists up to MAX_HANDLES_NEAR handles (handles_at,
## more_at) and still draws its first MAX_HANDLES_PER_TILE; the containers lying there list what is in them
## (inside_of, inside_more_of), which isn't drawn; bad lists fail the snapshot.
func _test_trays(world: WorldView, data: Variant) -> void:
	var rock := _it("rock")
	var beans := _it("can_beans")
	# The scene with `near` more rocks on AT_FLOOR (3 handles already), `far` more on AT_TABLE (2), and `extra` keys.
	var big := func(near: int, far: int, extra: Dictionary) -> Dictionary:
		var d := _scene_data(data, true)
		var sm: Dictionary = d["submaps"][0]
		var hs: Array = sm["handles"]
		for k in near:
			hs.append([_at(AT_FLOOR), 1001 + k, rock, -1, -1])
		for k in far:
			hs.append([_at(AT_TABLE), 2001 + k, rock, -1, -1])
		for p: Array in sm["items"]:
			if p[0] == _at(AT_FLOOR):
				p[1] = 300
		for key: String in extra:
			sm[key] = extra[key]
		return d
	var sq := _sq(AT_FLOOR)
	var snap := Snapshot.from_data(big.call(253, 30, {"more": [[_at(AT_FLOOR), 44]],
			"inside": [[203, 601, beans, 0], [203, 602, rock, 1]], "inside_more": [[203, 5]]}))
	var uids := snap.handles_at(sq)
	_check.call(snap.is_valid() and uids.size() == Snapshot.MAX_HANDLES_NEAR and uids[0] == 201 and uids[3] == 1001
			and uids[255] == 1253 and snap.handles_at(_sq(AT_TABLE)).size() == Snapshot.MAX_HANDLES_PER_TILE
			and snap.more_at(sq) == 44 and snap.more_at(_sq(AT_TABLE)) == 0 and snap.handles_at(_sq(Vector2i(0, 0))) == [],
			"trays: a pile next to the player lists 256 handles in order, one elsewhere 32, and how many more " + snap.error)
	_check.call(snap.inside_of(203) == [[601, beans, 0], [602, rock, 1]] and snap.inside_more_of(203) == 5
			and snap.inside_of(201) == [] and snap.inside_of(999) == [] and snap.inside_more_of(999) == 0,
			"trays: what is in a bag lying next to the player, and how many more")
	if snap.is_valid():
		var r := _build(world, snap)
		var drawn := _slots(r, AT_FLOOR).map(func(e: Array) -> int: return e[0])
		var inside := r.item_slots.filter(func(e: Array) -> bool: return e[0] == 601 or e[0] == 602)
		_check.call(drawn.size() == Snapshot.MAX_HANDLES_PER_TILE and drawn.has(201) and drawn.has(1029)
				and not drawn.has(1030) and inside.is_empty(),
				"trays: the big pile still draws its first 32 items, nothing in the bag is drawn %d" % drawn.size())
	var bad := {
		"33 on a square away from the player": big.call(0, 31, {}),
		"257 next to the player": big.call(254, 0, {}),
		"more: a tile twice": big.call(0, 0, {"more": [[1, 2], [1, 3]]}),
		"more: none left out": big.call(0, 0, {"more": [[1, 0]]}),
		"more: not [tile, n]": big.call(0, 0, {"more": [[1]]}),
		"more: not a list": big.call(0, 0, {"more": {}}),
		"inside: a container not lying here": big.call(0, 0, {"inside": [[999, 601, beans, 0]]}),
		"inside: a container away from the player": big.call(0, 0, {"inside": [[101, 601, beans, 0]]}),
		"inside: an item twice": big.call(0, 0, {"inside": [[203, 601, beans, 0], [202, 601, beans, 0]]}),
		"inside: an item lying on the ground": big.call(0, 0, {"inside": [[203, 201, rock, 0]]}),
		"inside: pocket 256": big.call(0, 0, {"inside": [[203, 601, beans, 256]]}),
		"inside: type 0": big.call(0, 0, {"inside": [[203, 601, 0, 0]]}),
		"inside: not [container, uid, type, pocket]": big.call(0, 0, {"inside": [[203, 601, beans]]}),
		"inside: 65 in one bag": big.call(0, 0, {"inside": range(65).map(func(k: int) -> Array: return [203, 601 + k, beans, 0])}),
		"inside: 257 in a submap": big.call(10, 0, {"inside": range(257).map(func(k: int) -> Array: return [1001 + k % 5, 5001 + k, beans, 0])}),
		"inside_more: a container not lying here": big.call(0, 0, {"inside_more": [[999, 1]]}),
		"inside_more: a container away from the player": big.call(0, 0, {"inside_more": [[101, 1]]}),
		"inside_more: a container twice": big.call(0, 0, {"inside_more": [[203, 1], [203, 2]]}),
		"inside_more: none left out": big.call(0, 0, {"inside_more": [[203, 0]]}),
	}
	var passed := []
	for k: String in bad:
		if Snapshot.from_data(bad[k]).is_valid():
			passed.append(k)
	var full: Dictionary = big.call(10, 0, {"inside": range(256).map(func(k: int) -> Array: return [1001 + k % 5, 5001 + k, beans, 0])})
	_check.call(passed.is_empty() and Snapshot.from_data(full).is_valid() and Snapshot.from_data(big.call(0, 30, {})).is_valid(),
			"trays: bad lists fail the snapshot, full ones don't %s" % [passed])


func _test_no_snapshot() -> void:
	var w := WorldView.new()
	var pk := ItemPicker.new(w)
	w.set_hidden_items({5: true})
	_check.call(pk.on_ray(Vector3.ZERO, Vector3.FORWARD) == null and pk.near(Vector3.ZERO) == null
			and not pk.in_reach(Vector3i.ZERO) and pk.carried().is_empty() and pk.contents(0).is_empty() and pk.by_uid(1) == null
			and w.items_on_ray(Vector3.ZERO, Vector3.FORWARD, Vector3i.ZERO, 4.0).is_empty() and w.item_slot(5).is_empty(),
			"items: no snapshot, nothing picked")
	w.free()
