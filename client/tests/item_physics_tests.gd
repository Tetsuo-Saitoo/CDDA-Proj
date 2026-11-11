extends RefCounted
## Block E2 slices 1-2 (item physics) on the mock town, rewritten around the player: WorldCollision's boxes (a slab
## per square on the player's level and the one below, none on open air, walls and closed doors filling their square,
## furniture boxes by coverage, a table as high as the surface its items lie on, impassable furniture full), rebuilt
## only when the centre or the snapshot changes and then touching only the changed shapes, the shape cap; ItemBodies'
## bodies (at the pose the pile draws the item in, asleep, mass from CDDA's weight, own layers, the static copies
## hidden through the owner set), the caps (total, per pile), the hysteresis, items taken / moved / held / in flight,
## nothing without WorldView owner sets. Headless runs don't step physics: only the structure is checked, not falling
## or settling. WorldView's owner sets (set_hidden_items_for) come from another branch: OwnerWorld stands in for them.
## Run by run_tests.gd.

const P := Vector3i(192, 384, 0)          # the mock town's player: square 0, 0 of submap SM
const SM := Vector3i(16, 32, 0)
const WALL := P + Vector3i(3, 0, 0)
const AIR := P + Vector3i(0, 3, 0)        # open air (no floor)
const TABLE := P + Vector3i(2, 2, 0)      # f_table with a hammer on it
const RACK := P + Vector3i(4, 2, 0)       # f_rack (impassable) with a rock on a shelf
const CHAIR := P + Vector3i(2, 4, 0)      # f_chair: coverage 40
const DOOR := P + Vector3i(4, 4, 0)       # t_door_c
const E := P + Vector3i(1, 0, 0)          # rock, hammer, 2x4
const PILE := P + Vector3i(1, 1, 0)       # six rocks
const S := P + Vector3i(0, 1, 0)          # bare floor
const FAR := P + Vector3i(7, 0, 0)        # a rock past ACTIVE_R
const UID := 900_000                      # E: +1..3, PILE: +11..16, TABLE: +21, RACK: +31, FAR: +41
const SLAB := WorldCollision.SLAB
const BOX := WorldCollision.BOX

var _check: Callable
var _it := {}   # itype id -> index
var _tables: IdTables
var _snap: Snapshot
var _mock: MockItems
var _world: OwnerWorld
var _col: WorldCollision
var _bodies: ItemBodies
var _centre := P
var _full := 0   # shapes with nothing capped


## WorldView with hidden items per owner, as the world lead's branch has it (set_hidden_items is the hands' set).
class OwnerWorld extends WorldView:
	var by_owner := {}   # StringName -> {uid: true}

	func set_hidden_items(uids: Dictionary) -> void:
		set_hidden_items_for(&"hands", uids)

	func set_hidden_items_for(who: StringName, uids: Dictionary) -> void:
		var mine := {}
		for u: Variant in uids:
			if u is int:
				mine[u] = true
		if mine.is_empty():
			by_owner.erase(who)
		else:
			by_owner[who] = mine
		var all := {}
		for o: StringName in by_owner:
			all.merge(by_owner[o])
		var changed := WorldView._changed(hidden_items, all)
		hidden_items = all
		if not changed.is_empty():
			_hidden_rev += 1
			_rebuild_hidden(changed)


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_tables = tables
	print("item physics")
	for id: String in ["rock", "hammer", "2x4"]:
		_it[id] = tables.index_of("itype", id)
	if not _setup(root, data, tables):
		return
	_test_collision()
	_test_rebuild()
	_test_shape_cap()
	_test_bodies()
	_test_body_caps()
	_test_hysteresis()
	_test_snapshot_changes()
	_test_held()
	_test_hostile()
	_bodies.clear()
	_check.call(_world.hidden_items.is_empty() and not _world.item_slot(UID + 11).is_empty(),
			"item physics: clear shows every static copy again")
	_bodies.free()
	_col.free()
	_world.free()
	_mock = null   # its `changed` holds a lambda that holds this test: break the cycle
	_snap = null


static func _tile(p: Vector3i) -> int:
	var l := CddaCoords.ms_to_local(p)
	return l.y * CddaCoords.SEEX + l.x


func _setup(root: Node, data: Variant, tables: IdTables) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var floor_id := tables.index_of("ter", "t_floor")
	var rock: int = _it["rock"]
	var hammer: int = _it["hammer"]
	var plank: int = _it["2x4"]
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if not (at.x in [15, 16] and at.y in [31, 32] and at.z in [-1, 0]):
			continue
		for i in Snapshot.TILES:   # bare indoor floor around the player, on both levels
			sm["ter"][i] = floor_id
			sm["furn"][i] = 0
			sm["flags"][i] = Snapshot.FLAG_ROOF
			if sm.has("trap"):
				sm["trap"][i] = 0
		sm["items"] = []
		sm.erase("handles")
		if at != SM:
			continue
		sm["ter"][_tile(WALL)] = tables.index_of("ter", "t_wall")
		sm["ter"][_tile(AIR)] = tables.index_of("ter", "t_open_air")
		sm["flags"][_tile(AIR)] = Snapshot.FLAG_NO_FLOOR
		sm["ter"][_tile(DOOR)] = tables.index_of("ter", "t_door_c")
		sm["furn"][_tile(TABLE)] = tables.index_of("furn", "f_table")
		sm["furn"][_tile(RACK)] = tables.index_of("furn", "f_rack")
		sm["furn"][_tile(CHAIR)] = tables.index_of("furn", "f_chair")
		sm["items"] = [[_tile(E), 3, [rock, hammer, plank]], [_tile(PILE), 6, [rock]], [_tile(TABLE), 1, [hammer]],
				[_tile(RACK), 1, [rock]], [_tile(FAR), 1, [rock]]]
		var hs := [[_tile(E), UID + 1, rock, -1, -1], [_tile(E), UID + 2, hammer, -1, -1],
				[_tile(E), UID + 3, plank, -1, -1], [_tile(TABLE), UID + 21, hammer, -1, -1],
				[_tile(RACK), UID + 31, rock, -1, -1], [_tile(FAR), UID + 41, rock, -1, -1]]
		for k in 6:
			hs.append([_tile(PILE), UID + 11 + k, rock, -1, -1])
		sm["handles"] = hs
	(d["player"] as Dictionary)["items"] = []
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "item physics: test town loads " + _snap.error)
	if not _snap.is_valid():
		return false
	_mock = MockItems.new(_snap, tables)
	_world = OwnerWorld.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(tables)
	root.add_child(_world)
	_world.apply_snapshot(_snap)
	_mock.changed.connect(func(s: Snapshot) -> void: _world.apply_snapshot(s))
	var at_centre := func() -> Variant: return _centre
	_col = WorldCollision.new(_world)
	_col.centre = at_centre
	root.add_child(_col)
	_bodies = ItemBodies.new(_world, _col)
	_bodies.centre = at_centre
	root.add_child(_bodies)
	return true


func _corner(p: Vector3i) -> Vector3:
	return _world.coords.ms_to_world(p)


func _test_collision() -> void:
	_check.call(_col.update(), "item physics: collision built around the player")
	var n := WorldCollision.offsets().size()
	_full = 2 * n - 1 + 3   # a slab per square on two levels; open air: none; wall / door: a box instead; 3 furniture
	_check.call(n == 113 and _col.shape_count() == _full,
			"item physics: a slab per square within ACTIVE_R on two levels, boxes on walls and furniture (%d squares, %d shapes)"
			% [n, _col.shape_count()])
	_check.call(_col.box_at(P, SLAB) == AABB(_corner(P) + Vector3(0, -WorldCollision.SLAB_M, 0),
			Vector3(1, WorldCollision.SLAB_M, 1)) and _col.box_at(P + Vector3i(0, 0, -1), SLAB).has_volume()
			and not _col.box_at(P, BOX).has_volume(), "item physics: a slab under the floor line, the level below too")
	_check.call(_col.box_at(WALL, BOX) == AABB(_corner(WALL), Vector3(1, 3, 1)) and not _col.box_at(WALL, SLAB).has_volume(),
			"item physics: a wall fills its square (1 x 3 x 1 m)")
	_check.call(not _col.box_at(AIR, SLAB).has_volume() and not _col.box_at(AIR, BOX).has_volume()
			and _col.box_at(AIR + Vector3i(0, 0, -1), SLAB).has_volume(), "item physics: open air has no floor, the level below has")
	_check.call(_col.box_at(DOOR, BOX).size == Vector3(1, 3, 1), "item physics: a closed door is a wall")
	_check.call(_col.box_at(RACK, BOX).size == Vector3(1, 3, 1) and _col.box_at(RACK, SLAB).has_volume(),
			"item physics: impassable furniture fills its square")
	var chair := _col.box_at(CHAIR, BOX)
	_check.call(chair.position.is_equal_approx(_corner(CHAIR)) and chair.size.is_equal_approx(Vector3(1, 0.6, 1)),
			"item physics: other furniture is coverage / 100 x 1.5 m high (chair: %s)" % chair.size)
	var slot := _world.item_slot(UID + 21)
	var top := _col.box_at(TABLE, BOX).end.y - _corner(TABLE).y
	var lies := (slot[4] as Transform3D).origin.y - _corner(TABLE).y if not slot.is_empty() else -1.0
	_check.call(absf(top - lies) < 0.02 and is_equal_approx(_col.top_at(TABLE), top),
			"item physics: a table's box reaches the surface its items lie on (%.2f, %.2f m)" % [top, lies])
	var layers_ok := WorldCollision.LAYER_WORLD != WorldCollision.LAYER_ITEMS and WorldCollision.LAYER_WORLD != 1 \
			and WorldCollision.LAYER_ITEMS != 1
	var in_space := 0
	for ch: Node in _col.get_children():
		var b := ch as StaticBody3D
		if b != null and b.process_mode != Node.PROCESS_MODE_DISABLED:
			in_space += 1
			layers_ok = layers_ok and b.collision_layer == WorldCollision.LAYER_WORLD and b.collision_mask == 0
	_check.call(layers_ok and in_space == _col.shape_count(), "item physics: collision on its own layer, one body per shape")
	_world.door_open[DOOR] = true
	_check.call(_col.update() and not _col.box_at(DOOR, BOX).has_volume() and _col.box_at(DOOR, SLAB).has_volume(),
			"item physics: a door opened in the client leaves a floor")
	_world.door_open.erase(DOOR)
	_col.update()
	_check.call(_col.box_at(DOOR, BOX).size == Vector3(1, 3, 1) and _col.shape_count() == _full, "item physics: closed again")


func _test_rebuild() -> void:
	var r := _col.rebuilds
	_check.call(not _col.update() and _col.rebuilds == r, "item physics: nothing changed, no rebuild")
	var slab := _col.body_at(P, SLAB)
	_snap.seq += 1
	_check.call(_col.update() and _col.last_touched == 0, "item physics: a new snapshot with the same squares touches no shape")
	_centre = P + Vector3i(1, 0, 0)
	_col.update()
	_check.call(_col.last_touched > 0 and _col.last_touched < _col.shape_count() / 2 and _col.body_at(P, SLAB) == slab
			and _col.box_at(P + Vector3i(7, 0, 0), SLAB).has_volume() and not _col.box_at(P + Vector3i(-6, 0, 0), SLAB).has_volume(),
			"item physics: a step east moves only the shapes at the edges (%d touched)" % _col.last_touched)
	_centre = P
	_col.update()
	_check.call(_col.shape_count() == _full and _col.body_at(P, SLAB) == slab, "item physics: back, the same shapes")
	var moved := _col.body_at(P, SLAB).position
	_col.shift(Vector3(12, 0, 0))
	_check.call(_col.body_at(P, SLAB).position.is_equal_approx(moved + Vector3(12, 0, 0)), "item physics: shapes follow an origin shift")
	_col.shift(Vector3(-12, 0, 0))


func _test_shape_cap() -> void:
	_col.max_shapes = 40
	_snap.seq += 1
	_col.update()
	_check.call(_col.shape_count() == 40 and _col.body_at(P, SLAB) != null and _col.body_at(P + Vector3i(5, 3, 0), SLAB) == null,
			"item physics: the shape cap keeps the nearest squares")
	_col.max_shapes = WorldCollision.MAX_SHAPES
	_snap.seq += 1
	_col.update()
	_check.call(_col.shape_count() == _full, "item physics: all shapes back under the full cap")


## Uids of the test items that have a body on square sq.
func _on(sq: Vector3i) -> Array:
	var out := []
	for u: int in _bodies.uids():
		if _bodies.square_of(u) == sq:
			out.append(u)
	return out


func _test_bodies() -> void:
	var slots := {}
	for u: int in [UID + 1, UID + 2, UID + 3, UID + 11, UID + 21, UID + 31, UID + 41]:
		slots[u] = _world.item_slot(u)
	_check.call(not (slots[UID + 1] as Array).is_empty() and not (slots[UID + 21] as Array).is_empty()
			and not (slots[UID + 31] as Array).is_empty(), "item physics: the test items are drawn")
	_bodies.hide_method = &"no_owner_sets"
	_bodies.update()
	_check.call(_bodies.count() == 0 and _world.hidden_items.is_empty(),
			"item physics: without WorldView owner sets no bodies (an item never shows twice)")
	_bodies.hide_method = ItemBodies.HIDE_METHOD
	_bodies.update()
	_check.call(_bodies.count() == 8 and _on(E).size() == 3 and _on(PILE).size() == 4 and _on(TABLE).size() == 1,
			"item physics: bodies for the items within ACTIVE_R (%d)" % _bodies.count())
	_check.call(_bodies.body_of(UID + 31) == null and not _world.item_slot(UID + 31).is_empty(),
			"item physics: an item inside a rack's box stays static")
	_check.call(_bodies.body_of(UID + 41) == null and not _world.item_slot(UID + 41).is_empty(),
			"item physics: an item past ACTIVE_R stays static")
	var mine: Dictionary = _world.by_owner.get(ItemBodies.OWNER, {})
	var hidden_ok := mine.size() == _bodies.count()
	for u: int in _bodies.uids():
		hidden_ok = hidden_ok and mine.has(u) and _world.item_slot(u).is_empty()
	_check.call(hidden_ok, "item physics: the static copies are hidden through the physics owner set")
	var posed := true
	var asleep := true
	var layered := true
	var boxed := true
	var sizes := []
	for u: int in [UID + 1, UID + 11, UID + 21]:
		var b := _bodies.body_of(u)
		var xf: Transform3D = (slots[u] as Array)[4]
		posed = posed and b != null and b.global_position.is_equal_approx(xf.origin) \
				and b.global_basis.is_equal_approx(xf.basis.orthonormalized())
		if b == null:
			continue
		asleep = asleep and b.sleeping and not b.freeze
		layered = layered and b.collision_layer == WorldCollision.LAYER_ITEMS \
				and b.collision_mask == (WorldCollision.LAYER_WORLD | WorldCollision.LAYER_ITEMS)
		var cs: CollisionShape3D = null
		var visual: Node3D = null
		for ch: Node in b.get_children():
			if ch is CollisionShape3D:
				cs = ch
			elif ch is Node3D:
				visual = ch
		var size := (cs.shape as BoxShape3D).size if cs != null and cs.shape is BoxShape3D else Vector3.ZERO
		sizes.append(size)
		var lo := ItemBodies.MIN_BOX_M - 0.0001   # the shape keeps 32-bit floats
		var hi := ItemBodies.MAX_BOX_M + 0.0001
		boxed = boxed and size.x >= lo and size.y >= lo and size.z >= lo and size.x <= hi and size.y <= hi and size.z <= hi \
				and visual != null and visual.get_child_count() > 0
	_check.call(posed, "item physics: bodies lie where their piles drew them (on the table too)")
	_check.call(asleep, "item physics: bodies start asleep")
	_check.call(layered, "item physics: bodies on the item layer, colliding with the world and each other")
	_check.call(boxed, "item physics: a box from the drawn bounds and a copy of the item's look %s" % [sizes])
	var rock: int = _it["rock"]
	var w := _tables.def_at("itype", rock).weight_g
	var rb := _bodies.body_of(UID + 1)
	_check.call(rb != null and is_equal_approx(rb.mass, clampf(w / 1000.0, ItemBodies.MIN_KG, ItemBodies.MAX_KG))
			and is_equal_approx(_bodies.mass_of(rock), clampf(w / 1000.0, ItemBodies.MIN_KG, ItemBodies.MAX_KG)),
			"item physics: mass from CDDA's weight (rock %d g)" % w)
	var gen := _snap.ids_generation
	_snap.ids_generation = _tables.generation + 1
	_check.call(is_equal_approx(_bodies.mass_of(rock), ItemBodies.UNKNOWN_KG), "item physics: tables that don't match: a default mass")
	_snap.ids_generation = gen
	var s := _bodies.syncs
	_bodies.update()
	_check.call(_bodies.syncs == s, "item physics: nothing changed, no pass over the snapshot")


func _test_body_caps() -> void:
	_check.call(_bodies.body_of(UID + 15) == null and _bodies.body_of(UID + 16) == null
			and not _world.item_slot(UID + 15).is_empty(), "item physics: at most PILE_BODIES per pile, the rest stays static")
	_bodies.max_bodies = 5
	_snap.seq += 1
	_bodies.update()
	_check.call(_bodies.count() == 5 and _bodies.body_of(UID + 21) == null and not _world.item_slot(UID + 21).is_empty()
			and (_world.by_owner.get(ItemBodies.OWNER, {}) as Dictionary).size() == 5,
			"item physics: the total cap keeps the nearest bodies, the far ones shown static")
	_bodies.max_bodies = ItemBodies.MAX_BODIES
	_snap.seq += 1
	_bodies.update()
	_check.call(_bodies.count() == 8, "item physics: back under the full cap")


func _test_hysteresis() -> void:
	_centre = P + Vector3i(2, 0, 0)
	_bodies.update()
	var far := _bodies.body_of(UID + 41)
	_check.call(far != null and far.sleeping and not far.freeze, "item physics: an item within ACTIVE_R of the new centre gets a body")
	_centre = P
	_bodies.update()
	far = _bodies.body_of(UID + 41)
	_check.call(far != null and far.freeze and not _bodies.body_of(UID + 1).freeze,
			"item physics: kept within ACTIVE_R + 2 m, frozen past ACTIVE_R (no collision there)")
	_centre = P + Vector3i(-3, 0, 0)
	_bodies.update()
	_check.call(_bodies.body_of(UID + 41) == null and not _world.hidden_items.has(UID + 41)
			and not _world.item_slot(UID + 41).is_empty() and _bodies.body_of(UID + 21) != null,
			"item physics: farther than ACTIVE_R + 2 m the body goes and the static copy shows")
	_centre = P
	_bodies.update()
	_check.call(_bodies.count() == 8, "item physics: back at the player")


func _test_snapshot_changes() -> void:
	var rock: int = _it["rock"]
	var hammer: int = _it["hammer"]
	_check.call(_mock.take_item(UID + 1, rock, E, "pack"), "item physics: mock take")
	_bodies.update()
	_check.call(_bodies.body_of(UID + 1) == null and not _world.hidden_items.has(UID + 1) and _bodies.count() == 7,
			"item physics: an item gone from the snapshot frees its body")
	_mock.take_item(UID + 2, hammer, E, "pack")
	_mock.drop_item(UID + 2, hammer, S)
	_bodies.update()
	var b := _bodies.body_of(UID + 2)
	_check.call(b != null and _bodies.square_of(UID + 2) == S and _world.coords.world_to_ms(b.global_position) == S
			and b.sleeping and _world.hidden_items.has(UID + 2) and _world.item_slot(UID + 2).is_empty(),
			"item physics: an item CDDA moved is made again at its new square, asleep, its copy hidden")


func _test_held() -> void:
	_bodies.clear()
	_world.set_hidden_items({UID + 3: true})   # what Hands does when it grabs the 2x4
	_bodies.update()
	_check.call(_bodies.body_of(UID + 3) == null and _world.hidden_items.has(UID + 3) and _bodies.count() > 0,
			"item physics: an item a hand holds gets no body and stays hidden")
	_world.set_hidden_items({})
	_bodies.update()
	_check.call(_bodies.body_of(UID + 3) != null, "item physics: let go, it gets a body")
	_bodies.held = func() -> Dictionary: return {UID + 21: true}
	_bodies.update()
	_check.call(_bodies.body_of(UID + 21) == null and not _world.hidden_items.has(UID + 21),
			"item physics: an item being taken (in flight) is static")
	_bodies.held = Callable()
	_bodies.update()
	_check.call(_bodies.body_of(UID + 21) != null, "item physics: and a body again once it isn't")


func _test_hostile() -> void:
	var n := _bodies.count()
	var gone := _bodies.body_of(UID + 11)
	if gone != null:
		gone.free()   # freed behind its back
	var sm: Snapshot.Submap = _snap.submaps[SM]
	var keep := sm.handles
	var hs := sm.handles
	hs.append_array(PackedInt64Array([999, UID + 51, 1, -1, -1, 3, -7, 1, -1, -1, 4, UID + 52, -3, -1, -1]))
	sm.handles = hs
	_snap.seq += 1
	_bodies.update()
	_check.call(_bodies.body_of(UID + 11) == null and not _world.hidden_items.has(UID + 11) and _bodies.count() <= n
			and _bodies.body_of(UID + 51) == null and _bodies.body_of(UID + 52) == null,
			"item physics: a body freed elsewhere and bad handles are skipped")
	sm.handles = keep
	_snap.seq += 1
	_bodies.update()
