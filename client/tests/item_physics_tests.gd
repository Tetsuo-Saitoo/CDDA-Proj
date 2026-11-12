extends RefCounted
## Block E2 slices 1-2 and 5 (item physics) on the mock town, rewritten around the player: WorldCollision's boxes (a
## slab per square on the player's level and the one below, none on open air, walls and closed doors filling their
## square, furniture boxes by coverage, a table as high as the surface its items lie on, impassable furniture full),
## rebuilt only when the centre or the snapshot changes and then touching only the changed shapes, the shape cap;
## ItemBodies' bodies (at the pose the pile draws the item in, asleep, mass from CDDA's weight, own layers, the static
## copies hidden through the owner set), the caps (total, per pile), the hysteresis, items taken / moved / held / in
## flight, nothing without WorldView owner sets; slice 5's pointing, hold, let_go, landed / forget / expiry and
## `settled`, and the scan's cost (one entry per uid, nearest submaps first, a pass only when nearby handles change, one
## publish); slices 3-4: ItemPlacer tells a stand-in bridge where a body came to rest (spot on its own square, place
## square by square to another, the limits, refusals and silence putting the body back, odd events ignored).
## Headless runs don't step physics: only the structure is checked, not falling or settling. WorldView's owner
## sets (set_hidden_items_for) come from another branch: OwnerWorld stands in for them. Run by run_tests.gd.

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
var _ms := 0     # ItemBodies.clock in _test_hands_api


## WorldView with hidden items per owner, as the world lead's branch has it (set_hidden_items is the hands' set).
class OwnerWorld extends WorldView:
	var by_owner := {}   # StringName -> {uid: true}
	var physics_sets := 0   # calls from ItemBodies (each re-meshes what changed)

	func set_hidden_items(uids: Dictionary) -> void:
		set_hidden_items_for(&"hands", uids)

	func set_hidden_items_for(who: StringName, uids: Dictionary) -> void:
		if who == ItemBodies.OWNER:
			physics_sets += 1
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
	_test_scan()
	_test_hands_api()
	_test_sync_cost()
	_test_placer()
	_bodies.clear()
	var drawn := 0   # the pile's rocks drawn static again (one of the six was taken into the pack in _test_sync_cost)
	for k in 6:
		if not _world.item_slot(UID + 11 + k).is_empty():
			drawn += 1
	_check.call(_world.hidden_items.is_empty() and drawn == 5 and _bodies.count() == 0,
			"item physics: clear shows every static copy again (%d of the pile's 5 left)" % drawn)
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
			"item physics: an item CDDA moved is put down at its new square, asleep, its copy hidden")


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


## The scan (MED 3 / LOW 4): one entry per uid, at most PILE_BODIES new items per square, bad spots dropped,
## nearest submaps first, the player's level before a crowded basement; the static helpers; the fallback box.
func _test_scan() -> void:
	var plank: int = _it["2x4"]
	var rock: int = _it["rock"]
	var sm: Snapshot.Submap = _snap.submaps[SM]
	var keep := sm.handles
	var hs := keep.duplicate()
	hs.append_array(PackedInt64Array([_tile(S), UID + 3, plank, 2000, 5]))   # the plank listed again, a bad spot
	for k in 10:
		hs.append_array(PackedInt64Array([_tile(S), UID + 100 + k, rock, 500, 250]))   # a big new pile on S
	sm.handles = hs
	var hn := _bodies._handles_near(_snap, P)
	var new_on_s := 0
	for k in 10:
		new_on_s += 1 if hn.has(UID + 100 + k) else 0
	var e3: Array = hn.get(UID + 3, [])
	var e100: Array = hn.get(UID + 100, [])
	_check.call(e3.size() == 4 and e3[0] == E and e3[3] == Vector2(-1, -1) and new_on_s == ItemBodies.PILE_BODIES
			and e100.size() == 4 and (e100[3] as Vector2).is_equal_approx(Vector2(0.5, 0.25)),
			"item physics: the scan lists a uid once, at most %d new items per square, spots checked" % ItemBodies.PILE_BODIES)
	sm.handles = keep
	var below: Snapshot.Submap = _snap.submaps.get(SM + Vector3i(0, 0, -1))
	var crowded := false
	if below != null:
		var keep_below := below.handles
		var many := PackedInt64Array()
		many.resize(9000 * ItemBodies.HS)
		for k in 9000:
			var i := k * ItemBodies.HS
			many[i] = k % Snapshot.TILES
			many[i + 1] = 700_000 + k
			many[i + 2] = rock
			many[i + 3] = -1
			many[i + 4] = -1
		below.handles = many
		hn = _bodies._handles_near(_snap, P)
		crowded = hn.has(UID + 3) and hn.has(UID + 21) and hn.has(UID + 11) and not hn.has(700_000)
		below.handles = keep_below
	_check.call(crowded, "item physics: 9000 items in the basement under the player don't crowd out the player's level")
	var c := P + Vector3i(3, 3, 0)
	var subs := ItemBodies._subs_near(c, 9)
	var sorted := subs.size() == 9 and subs[0] == Vector2i(SM.x, SM.y)
	var last := -1
	for s: Vector2i in subs:
		var m := CddaCoords.sm_to_ms(Vector3i(s.x, s.y, 0)) + Vector3i(CddaCoords.SEEX / 2, CddaCoords.SEEX / 2, 0)
		var d2 := (m.x - c.x) * (m.x - c.x) + (m.y - c.y) * (m.y - c.y)
		sorted = sorted and d2 >= last
		last = d2
	_check.call(sorted, "item physics: submaps scanned nearest first (%s)" % [subs])
	_check.call(ItemBodies._spot(-1, 5) == Vector2(-1, -1) and ItemBodies._spot(1000, 0) == Vector2(-1, -1)
			and ItemBodies._spot(500, 250).is_equal_approx(Vector2(0.5, 0.25)) and ItemBodies._spot(999, 999).x <= ItemBodies.SPOT_MAX + 1e-6,
			"item physics: a handle's spot from permille, out of range: none")
	var empty := Node3D.new()
	var bx := _bodies._bounds(empty, rock)
	empty.free()
	var lo := ItemBodies.MIN_BOX_M - 0.0001
	var hi := ItemBodies.MAX_BOX_M + 0.0001
	_check.call(bx.size.x >= lo and bx.size.x <= hi and bx.size.is_equal_approx(Vector3.ONE * bx.size.x)
			and is_zero_approx(bx.position.y), "item physics: no meshes: a cube of the item's size, within the box limits (%s)" % bx)


## A pass only when the handles near the centre change (one hash per nearby submap); a pass publishes (re-meshes)
## once; an item CDDA moved keeps its body, put down on its new square at the handle's spot, nothing re-meshed.
func _test_sync_cost() -> void:
	var rock: int = _it["rock"]
	var hammer: int = _it["hammer"]
	_snap.seq += 1
	_bodies.update()
	var syn := _bodies.syncs
	var sk := _bodies.skipped
	var pubs := _world.physics_sets
	_snap.seq += 1
	_bodies.update()
	_check.call(_bodies.syncs == syn and _bodies.skipped == sk + 1 and _world.physics_sets == pubs,
			"item physics: a new snapshot with the same handles nearby: no pass, nothing published")
	var far_sm: Snapshot.Submap = null
	for pos: Vector3i in _snap.submaps:
		if pos.z == 0 and (pos.x < SM.x - 1 or pos.x > SM.x or pos.y < SM.y - 1 or pos.y > SM.y):
			far_sm = _snap.submaps[pos]
			break
	var far_ok := true   # (the mock town may have no far submap: then nothing to check)
	if far_sm != null:
		var keep := far_sm.handles
		var hs := keep.duplicate()
		hs.append_array(PackedInt64Array([0, 990_001, rock, -1, -1]))
		far_sm.handles = hs
		_snap.seq += 1
		_bodies.update()
		far_ok = _bodies.syncs == syn and _bodies.skipped == sk + 2
		far_sm.handles = keep
		_snap.seq += 1
		_bodies.update()
	_check.call(far_ok, "item physics: an item changing on a far submap: no pass")
	var hb := _bodies.body_of(UID + 2)
	syn = _bodies.syncs
	pubs = _world.physics_sets
	_mock.take_item(UID + 2, hammer, S, "pack")
	_mock.drop_item(UID + 2, hammer, E, Vector2(0.25, 0.75))
	_bodies.update()
	var c := _corner(E)
	var on_floor := false
	if hb != null and _bodies._bodies.has(UID + 2):
		var box: AABB = (_bodies._bodies[UID + 2] as ItemBodies.Body).box
		on_floor = absf((hb.global_transform * box).position.y - (c.y + ItemBodies.FLOOR_UP_M)) < 0.001
	_check.call(hb != null and _bodies.body_of(UID + 2) == hb and _bodies.square_of(UID + 2) == E and on_floor
			and absf(hb.global_position.x - (c.x + 0.25)) < 0.001 and absf(hb.global_position.z - (c.z + 0.75)) < 0.001
			and hb.sleeping and _bodies.syncs == syn + 1 and _world.physics_sets == pubs and _world.hidden_items.has(UID + 2),
			"item physics: an item CDDA moved: the same body put down at its new spot, nothing re-meshed")
	pubs = _world.physics_sets
	syn = _bodies.syncs
	var pile: Array = _on(PILE)
	var x: int = pile[0] if not pile.is_empty() else -1
	_mock.take_item(x, rock, PILE, "pack")   # its body goes; a rock of the pile lying static gets one
	_bodies.update()
	_check.call(pile.size() == ItemBodies.PILE_BODIES and _bodies.body_of(x) == null and _on(PILE).size() == ItemBodies.PILE_BODIES
			and _bodies.syncs == syn + 1 and _world.physics_sets == pubs + 1,
			"item physics: a pass that frees a body and makes one publishes once")


## Slice 5: bodies as pointing entries (on_ray / near / slot: CDDA's reach rule, not held, not waiting), hold /
## unhold, let_go (waiting for CDDA, awake, speed capped), `settled` once, landed (kept), forget, the expiry.
func _test_hands_api() -> void:
	var plank: int = _it["2x4"]
	var rock: int = _it["rock"]
	var b := _bodies.body_of(UID + 3)
	var s := _bodies.slot(UID + 3)
	var mid: Vector3 = s[3] if s.size() >= 6 else Vector3.INF
	var hit := _bodies.on_ray(mid + Vector3(0, 0.3, 0), Vector3.DOWN, P, 4.0)
	var nr := _bodies.near(mid + Vector3(0.01, 0, 0), 0.1, P)
	_check.call(b != null and s.size() == 6 and s[0] == UID + 3 and s[1] == plank and s[2] == E
			and (s[4] as Transform3D).origin.is_equal_approx(b.global_position)
			and is_equal_approx((s[4] as Transform3D).basis.get_scale().x, ItemVisual.size_of(plank, _world))
			and hit.size() == 6 and hit[0] == UID + 3 and nr.size() == 6 and nr[0] == UID + 3,
			"item physics: a body is pointed at as WorldView points at a drawn item (where the body is)")
	_check.call(_bodies.on_ray(mid + Vector3(0, 0.3, 0), Vector3.DOWN, P + Vector3i(-3, 0, 0), 4.0).is_empty()
			and _bodies.near(mid, 0.1, P + Vector3i(0, 0, 1)).is_empty()
			and _bodies.on_ray(Vector3(NAN, 0, 0), Vector3.DOWN, P, 4.0).is_empty()
			and _bodies.on_ray(mid, Vector3.ZERO, P, 4.0).is_empty() and _bodies.near(mid, NAN, P).is_empty()
			and _bodies.near(mid, -1.0, P).is_empty(), "item physics: out of reach, another level or a bad ray: nothing")
	_bodies.hold(UID + 3)
	var mine: Dictionary = _world.by_owner.get(ItemBodies.OWNER, {})
	_check.call(_bodies.body_of(UID + 3) == null and _bodies.is_held(UID + 3) and _bodies.slot(UID + 3).is_empty()
			and not mine.has(UID + 3), "item physics: a hand holds it: its body goes")
	_snap.seq += 1
	_bodies.update()
	var kept_off := _bodies.body_of(UID + 3) == null
	_bodies.unhold(UID + 3)
	_bodies.update()
	_check.call(kept_off and _bodies.body_of(UID + 3) != null and _bodies.square_of(UID + 3) == E and not _bodies.is_held(UID + 3),
			"item physics: none made while held; put back: a body again")
	for k in ItemBodies.MAX_HOLDING + 1:
		_bodies.hold(800_000 + k)
	var capped := _bodies.is_held(800_000 + ItemBodies.MAX_HOLDING - 1) and not _bodies.is_held(800_000 + ItemBodies.MAX_HOLDING)
	for k in ItemBodies.MAX_HOLDING + 1:
		_bodies.unhold(800_000 + k)
	_bodies.hold(0)
	_bodies.hold(-4)
	_check.call(capped and not _bodies.is_held(0) and not _bodies.is_held(-4) and not _bodies.is_held(800_000),
			"item physics: at most %d held items, bad uids ignored" % ItemBodies.MAX_HOLDING)
	_ms = 5_000_000
	_bodies.clock = func() -> int: return _ms
	_bodies.hold(UID + 3)
	var xf := Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3.ONE * 0.3), _corner(S) + Vector3(0.5, 0.8, 0.5))
	var rb := _bodies.let_go(UID + 3, plank, xf, Vector3(30, 0, 40), S)
	mine = _world.by_owner.get(ItemBodies.OWNER, {})
	_check.call(rb != null and _bodies.is_pending(UID + 3) and not _bodies.is_held(UID + 3) and _bodies.square_of(UID + 3) == S
			and rb.global_position.is_equal_approx(xf.origin) and rb.global_basis.is_equal_approx(Basis(Vector3.UP, 0.4))
			and not rb.sleeping and is_equal_approx(rb.linear_velocity.length(), ItemBodies.MAX_SPEED)
			and _bodies.slot(UID + 3).is_empty() and mine.has(UID + 3),
			"item physics: let go: a body at the hand's pose (its scale dropped), awake, at most %d m/s, waiting for CDDA" % int(ItemBodies.MAX_SPEED))
	_snap.seq += 1
	_bodies.update()
	_check.call(_bodies.body_of(UID + 3) == rb and _bodies.is_pending(UID + 3),
			"item physics: while it waits the pile's handle doesn't make a second body")
	var got := []
	var on_settle := func(u: int, sq: Vector3i, sp: Vector2) -> void: got.append([u, sq, sp])
	_bodies.settled.connect(on_settle)
	if rb != null:
		rb.sleeping_state_changed.emit()   # still awake: nothing
		rb.sleeping = true
		rb.sleeping_state_changed.emit()
		rb.sleeping_state_changed.emit()
	_bodies.settled.disconnect(on_settle)
	var rest := _bodies.rest_of(UID + 3)
	_check.call(got.size() == 1 and got[0][0] == UID + 3 and got[0][1] == S and (got[0][2] as Vector2).is_equal_approx(Vector2(0.5, 0.5))
			and rest.get("square") == S, "item physics: the first time it comes to rest `settled` says where (%s)" % [got])
	var early := _bodies.landed(UID + 3) and _bodies.is_pending(UID + 3)   # the world doesn't show it on S yet
	_mock.take_item(UID + 3, plank, E, "pack")
	_mock.drop_item(UID + 3, plank, S, Vector2(0.5, 0.5))
	_bodies.update()
	_check.call(early and not _bodies.is_pending(UID + 3) and _bodies.body_of(UID + 3) == rb and rb.global_position.is_equal_approx(xf.origin)
			and not _bodies.forget(UID + 3) and not _bodies.landed(UID + 99) and not _bodies.forget(UID + 99),
			"item physics: CDDA's drop landed and the world shows it there: that body stays where it is")
	var pile: Array = _on(PILE)
	var a: int = pile[0] if not pile.is_empty() else -1
	_bodies.hold(a)
	var r2 := _bodies.let_go(a, rock, Transform3D(Basis(), _corner(S) + Vector3(0.3, 0.5, 0.3)), Vector3(NAN, 0, 0), S)
	var zero := r2 != null and r2.linear_velocity == Vector3.ZERO
	var forgot := _bodies.forget(a) and _bodies.body_of(a) == null and not _bodies.forget(a)
	_bodies.update()
	_check.call(zero and forgot and _back_on_pile(a), "item physics: a refused drop: its body goes, the item is back in its pile")
	pile = _on(PILE)
	var e: int = pile[0] if not pile.is_empty() else -1
	_bodies.hold(e)
	var r3 := _bodies.let_go(e, rock, Transform3D(Basis(), _corner(S) + Vector3(0.7, 0.5, 0.7)), Vector3.ZERO, S)
	_ms += ItemBodies.PENDING_MS - 1
	_bodies.update()
	var waiting := r3 != null and _bodies.body_of(e) == r3 and _bodies.is_pending(e)
	_ms += 1
	_bodies.update()
	_check.call(waiting and _bodies.body_of(e) != r3 and _back_on_pile(e),
			"item physics: no answer from CDDA in %d s: the body goes, the item is back in its pile" % (ItemBodies.PENDING_MS / 1000))
	# A drop that landed but never shows on its square (a charge stack merged into another there: a new uid).
	pile = _on(PILE)
	var m: int = pile[0] if not pile.is_empty() else -1
	_bodies.hold(m)
	var r4 := _bodies.let_go(m, rock, Transform3D(Basis(), _corner(S) + Vector3(0.4, 0.5, 0.6)), Vector3.ZERO, S)
	_ms += ItemBodies.PENDING_MS - ItemBodies.LANDED_MS - 100   # late in its wait: landing starts its own clock
	var m_landed := r4 != null and _bodies.landed(m)
	_ms += ItemBodies.LANDED_MS - 1
	_bodies.landed(m)   # told twice: the clock doesn't start again
	_bodies.update()
	var m_waits := _bodies.body_of(m) == r4 and _bodies.is_pending(m)
	_ms += 1
	_bodies.update()
	_check.call(m_landed and m_waits and _bodies.body_of(m) != r4 and not _bodies.is_pending(m),
			"item physics: landed but never shown on its square (merged into a stack): its body goes after %.1f s"
			% (ItemBodies.LANDED_MS / 1000.0))
	# The game stops: nothing is held any more.
	_bodies.hold(UID + 3)
	var was_held := _bodies.is_held(UID + 3)
	_bodies.clear()
	var cleared := not _bodies.is_held(UID + 3) and _bodies.count() == 0
	_bodies.hold(UID + 3)
	_bodies.clear()   # no bodies left: still forgets the hold
	_check.call(was_held and cleared and not _bodies.is_held(UID + 3), "item physics: clear() forgets what the hands held")
	_snap.seq += 1
	_bodies.update()
	_bodies.clock = Callable()
	var pose := Transform3D(Basis(), _corner(S) + Vector3(0.5, 0.5, 0.5))
	var none := _bodies.let_go(UID + 41, rock, pose, Vector3.ZERO, S + Vector3i(0, 0, 1)) == null \
			and _bodies.let_go(UID + 41, rock, pose, Vector3.ZERO, P + Vector3i(7, 0, 0)) == null \
			and _bodies.let_go(0, rock, pose, Vector3.ZERO, S) == null and _bodies.let_go(UID + 41, 0, pose, Vector3.ZERO, S) == null \
			and _bodies.let_go(UID + 41, rock, Transform3D(Basis(), Vector3(NAN, 0, 0)), Vector3.ZERO, S) == null \
			and _bodies.let_go(UID + 41, rock, Transform3D(Basis.from_scale(Vector3.ZERO), pose.origin), Vector3.ZERO, S) == null
	_bodies.max_bodies = _bodies.count()
	none = none and _bodies.let_go(UID + 41, rock, pose, Vector3.ZERO, S) == null
	_bodies.max_bodies = ItemBodies.MAX_BODIES
	_check.call(none and _bodies.body_of(UID + 41) == null,
			"item physics: no body let go onto another level, past ACTIVE_R, over the cap or from a bad pose")


## Item u lies in its pile again, not waiting: as a body there or drawn static; the pile has its PILE_BODIES bodies.
## Stands in for the live session's place / spot ops (lead-bridge's shapes): keeps what was sent.
class FakeBridge extends RefCounted:
	var ops: Array[Dictionary] = []
	var take := true

	func place_item(uid: float, type: float, pos: Vector3i, to: Vector3i, spot: Vector2, yaw: int, side: bool, tag: int) -> bool:
		ops.append({"op": "place", "uid": int(uid), "type": int(type), "pos": pos, "to": to, "spot": spot, "yaw": yaw,
				"side": side, "tag": tag})
		return take

	func spot_item(uid: float, type: float, pos: Vector3i, spot: Vector2, yaw: int, side: bool, tag: int) -> bool:
		ops.append({"op": "spot", "uid": int(uid), "type": int(type), "pos": pos, "spot": spot, "yaw": yaw, "side": side,
				"tag": tag})
		return take


## The body of `uid` now lies at `spot` across square sq, turned `rot`, and comes to rest there.
func _rest_at(uid: int, sq: Vector3i, spot: Vector2, rot := Basis.IDENTITY) -> void:
	var rb := _bodies.body_of(uid)
	if rb == null:
		return
	var c := _corner(sq)
	rb.global_transform = Transform3D(rot, Vector3(c.x + spot.x, rb.global_position.y, c.z + spot.y))
	rb.sleeping = true
	rb.sleeping_state_changed.emit()


## The snapshot now has item `uid` on square `to` (in submap SM), as CDDA's place leaves it.
func _cdda_moves(uid: int, to: Vector3i) -> void:
	var sm: Snapshot.Submap = _world.snapshot.submaps[SM]
	var hs := sm.handles
	for k in range(0, hs.size() - ItemBodies.HS + 1, ItemBodies.HS):
		if hs[k + 1] == uid:
			hs[k] = _tile(to)
	sm.handles = hs
	_world.snapshot.seq += 1
	_bodies.update()


static func _result(uid: int, tag: int, done: bool, text := "") -> Dictionary:
	return {"kind": "item_result", "uid": uid, "detail": tag, "amount": 1 if done else 0, "text": text}


## Slices 3-4: ItemPlacer and the stand-in bridge. X and Y are two items lying next to the player, put on E first
## (the tests before this one moved things about).
func _test_placer() -> void:
	var a := P + Vector3i(2, 0, 0)    # floor next to E
	var b := P + Vector3i(0, 2, 0)    # floor two squares from A, by way of PILE
	_snap = _world.snapshot
	_snap.seq += 1
	_bodies.update()
	var near: Array = _on(E) + _on(S) + _on(TABLE)
	var x: int = near[0] if near.size() >= 2 else -1
	var y: int = near[1] if near.size() >= 2 else -1
	for u: int in [x, y]:
		if u > 0 and _bodies.square_of(u) != E:
			_cdda_moves(u, E)
	var rock := _bodies.type_of(x)     # X's itype
	var hammer := _bodies.type_of(y)   # Y's itype
	var fake := FakeBridge.new()
	var placer := ItemPlacer.new()
	_ms = 9_000_000
	placer.clock = func() -> int: return _ms
	placer.centre = func() -> Variant: return P
	placer.bodies = _bodies
	placer.backend = fake
	var refusals: Array = []
	placer.refused.connect(func(u: int, why: String) -> void: refusals.append([u, why]))
	var rx := _bodies.body_of(x)
	_check.call(rx != null and _bodies.body_of(y) != null and _bodies.square_of(x) == E and _bodies.square_of(y) == E
			and rock > 0 and hammer > 0, "item placer: two items lie on E as bodies (%s of %s)" % [[x, y], near])
	if rx == null or _bodies.body_of(y) == null:
		placer.free()
		return
	# at rest where it was made, or a hair off: nothing to tell
	rx.sleeping_state_changed.emit()
	rx.global_position += Vector3(ItemBodies.MOVED_M * 0.5, 0, 0)
	rx.sleeping_state_changed.emit()
	placer.update()
	_check.call(placer.waiting() == 0 and fake.ops.is_empty(), "item placer: a body at rest where it lay tells nothing")
	# moved and turned on its own square: one spot op
	_rest_at(x, E, Vector2(0.7, 0.6), Basis(Vector3.UP, PI / 2.0))
	var want := placer.waiting() == 1
	placer.update()
	var op: Dictionary = fake.ops[-1] if not fake.ops.is_empty() else {}
	_check.call(want and fake.ops.size() == 1 and op.get("op") == "spot" and op.get("uid") == x and op.get("type") == rock
			and op.get("pos") == E and (op.get("spot", Vector2.INF) as Vector2).distance_to(Vector2(0.7, 0.6)) < 0.01
			and op.get("yaw") == 90 and op.get("side") == false and op.get("tag") == 1 and placer.spots == 1,
			"item placer: moved on its own square: one spot op with where it lies and its yaw (%s)" % [op])
	# odd events: not this op's result
	var n_ref := placer.refusals
	placer.on_events([5, {"kind": "item_result"}, _result(x, 77, true), _result(y, 1, true), {"kind": "item_result", "uid": x,
			"detail": NAN, "amount": 1}, {"kind": "message", "uid": x, "detail": 1, "amount": 1}, _result(x, -1, false)])
	placer.update()
	_check.call(placer.waiting() == 1 and fake.ops.size() == 1 and placer.refusals == n_ref,
			"item placer: results for another tag or item, odd events: ignored, the op stays in flight")
	placer.on_events([_result(x, 1, true)])
	rx.sleeping_state_changed.emit()   # still where it was told
	_ms += ItemPlacer.GAP_MS
	placer.update()
	_check.call(placer.waiting() == 0 and fake.ops.size() == 1, "item placer: CDDA took the spot: nothing more to tell")
	# a refused spot: the body stays, the reason is passed on (bounded)
	_rest_at(x, E, Vector2(0.3, 0.3))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	op = fake.ops[-1]
	placer.on_events([_result(x, int(op.get("tag", 0)), false, "No. " + "x".repeat(500))])
	var why: String = refusals[-1][1] if not refusals.is_empty() else ""
	_check.call(op.get("op") == "spot" and placer.refusals == n_ref + 1 and placer.waiting() == 0 and _bodies.body_of(x) == rx
			and refusals.size() == 1 and refusals[0][0] == x and why.begins_with("No.") and why.length() <= ItemPlacer.MAX_REASON,
			"item placer: a refused spot: the body stays where it lies, CDDA's reason is passed on, capped")
	# onto the next square, lying on its side: one place with the pose; the body stays put when the snapshot shows it
	_rest_at(x, a, Vector2(0.5, 0.5), Basis(Vector3.UP, PI / 2.0) * Basis(Vector3.RIGHT, PI / 2.0))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	op = fake.ops[-1]
	var at := rx.global_position
	_check.call(op.get("op") == "place" and op.get("pos") == E and op.get("to") == a and op.get("yaw") == 90 and op.get("side") == true
			and (op.get("spot", Vector2.INF) as Vector2).distance_to(Vector2(0.5, 0.5)) < 0.01 and placer.places == 1,
			"item placer: at rest on the next square, on its side: one place there with the pose (%s)" % [op])
	placer.on_events([_result(x, int(op.get("tag", 0)), true)])
	_ms += ItemPlacer.GAP_MS
	placer.update()
	var waits := placer.waiting() == 1 and fake.ops.size() == 3   # done, but the snapshot doesn't show it yet
	_cdda_moves(x, a)
	_ms += ItemPlacer.GAP_MS
	placer.update()
	_check.call(waits and _bodies.body_of(x) == rx and rx.global_position.is_equal_approx(at) and _bodies.square_of(x) == a
			and placer.waiting() == 0 and fake.ops.size() == 3 and not _bodies._transit.has(x),
			"item placer: CDDA placed it: the body keeps its pose, its CDDA square is the new one, nothing more sent")
	# two squares away: a place per turn, the first without a pose, the last with it
	_rest_at(x, b, Vector2(0.2, 0.8))
	_ms += ItemPlacer.PLACE_GAP_MS
	placer.update()
	op = fake.ops[-1]
	var step1: bool = op.get("op") == "place" and op.get("pos") == a and op.get("to") == PILE and op.get("spot") == Vector2(-1, -1) \
			and _bodies._transit.has(x)
	placer.on_events([_result(x, int(op.get("tag", 0)), true)])
	_cdda_moves(x, PILE)
	var kept: bool = _bodies.body_of(x) == rx and _bodies.square_of(x) == PILE and _bodies.rest_of(x).get("square") == b
	_ms += ItemPlacer.GAP_MS
	placer.update()
	var too_soon := fake.ops.size() == 4
	_ms += ItemPlacer.PLACE_GAP_MS
	placer.update()
	op = fake.ops[-1]
	var step2: bool = fake.ops.size() == 5 and op.get("pos") == PILE and op.get("to") == b \
			and (op.get("spot", Vector2.INF) as Vector2).distance_to(Vector2(0.2, 0.8)) < 0.01
	placer.on_events([_result(x, int(op.get("tag", 0)), true)])
	_cdda_moves(x, b)
	_ms += ItemPlacer.GAP_MS
	placer.update()
	_check.call(step1 and kept and too_soon and step2 and placer.waiting() == 0 and _bodies.square_of(x) == b
			and _bodies.body_of(x) == rx and not _bodies._transit.has(x) and placer.places == 3,
			"item placer: two squares away: one place a turn, square by square, the body lying still meanwhile (%s %s %s %s)"
			% [step1, kept, too_soon, step2])
	# a refused place: the body goes back where CDDA has the item
	var ry := _bodies.body_of(y)
	_rest_at(y, a, Vector2(0.5, 0.5))
	_ms += ItemPlacer.PLACE_GAP_MS
	placer.update()
	op = fake.ops[-1]
	placer.on_events([_result(y, int(op.get("tag", 0)), false, "There's no room.")])
	_snap.seq += 1
	_bodies.update()
	var back := _bodies.body_of(y)
	_check.call(op.get("op") == "place" and op.get("uid") == y and op.get("type") == hammer and placer.put_backs == 1
			and back != null and back != ry and _bodies.square_of(y) == E and _bodies.rest_of(y).get("square") == E
			and placer.waiting() == 0 and refusals[-1] == [y, "There's no room."],
			"item placer: a refused place: the body is back where CDDA has the item")
	# no answer: tried MAX_TRIES times, then put back
	var sent := fake.ops.size()
	_rest_at(y, a, Vector2(0.5, 0.5))
	for k in ItemPlacer.MAX_TRIES + 2:
		_ms += ItemPlacer.RESULT_MS + ItemPlacer.PLACE_GAP_MS
		placer.update()
	_snap.seq += 1
	_bodies.update()
	_check.call(fake.ops.size() == sent + ItemPlacer.MAX_TRIES and placer.put_backs == 2 and placer.waiting() == 0
			and _bodies.rest_of(y).get("square") == E,
			"item placer: no answer %d times: the body is put back (%d sent)" % [ItemPlacer.MAX_TRIES, fake.ops.size() - sent])
	# the game is busy (the op isn't taken): tried again later, then a spot is just forgotten
	sent = fake.ops.size()
	fake.take = false
	_rest_at(y, E, Vector2(0.8, 0.2))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	placer.update()
	var once := fake.ops.size() == sent + 1
	for k in ItemPlacer.MAX_TRIES + 1:
		_ms += ItemPlacer.RETRY_MS
		placer.update()
	fake.take = true
	_check.call(once and fake.ops.size() == sent + ItemPlacer.MAX_TRIES and placer.waiting() == 0 and placer.put_backs == 2,
			"item placer: an op the game doesn't take is tried again a second later, %d times in all" % ItemPlacer.MAX_TRIES)
	# out of CDDA's reach, moving again, no such op: nothing sent
	sent = fake.ops.size()
	placer.centre = func() -> Variant: return P + Vector3i(4, 0, 0)
	_rest_at(y, E, Vector2(0.4, 0.4))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	var far_spot := placer.waiting() == 0 and placer.put_backs == 2
	_rest_at(y, a, Vector2(0.5, 0.5))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	placer.centre = func() -> Variant: return P
	_snap.seq += 1
	_bodies.update()
	_check.call(far_spot and fake.ops.size() == sent and placer.put_backs == 3 and _bodies.rest_of(y).get("square") == E,
			"item placer: an item out of CDDA's reach: nothing sent; lying on another square it is put back")
	_rest_at(y, E, Vector2(0.6, 0.6))
	var moving := _bodies.body_of(y)
	if moving != null:
		moving.sleeping = false
	_ms += ItemPlacer.GAP_MS
	placer.update()
	placer.backend = RefCounted.new()
	_rest_at(y, E, Vector2(0.65, 0.35))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	placer.backend = null
	_rest_at(y, E, Vector2(0.35, 0.65))
	_ms += ItemPlacer.GAP_MS
	placer.update()
	_check.call(fake.ops.size() == sent and placer.waiting() == 0,
			"item placer: a body moving again, a backend without the ops, no backend: nothing sent, nothing kept waiting")
	# a body a hand let go waits for CDDA's own drop
	placer.backend = fake
	_bodies.clock = func() -> int: return _ms
	_bodies.hold(y)
	var let := _bodies.let_go(y, hammer, Transform3D(Basis(), _corner(a) + Vector3(0.5, 0.3, 0.5)), Vector3.ZERO, a)
	if let != null:
		let.sleeping = true
		let.sleeping_state_changed.emit()
	_ms += ItemPlacer.GAP_MS
	placer.update()
	var pending := let != null and placer.waiting() == 1 and fake.ops.size() == sent
	_bodies.forget(y)
	_ms += ItemPlacer.GAP_MS
	placer.update()
	_bodies.clock = Callable()
	_check.call(pending and placer.waiting() == 0 and fake.ops.size() == sent,
			"item placer: a body a hand let go: nothing sent before CDDA's drop lands; a refused drop: nothing at all")
	_rest_at(x, b, Vector2(0.5, 0.5))
	placer.clear()
	_check.call(placer.waiting() == 0 and placer._flight.is_empty(), "item placer: clear forgets everything")
	placer.bodies = null
	placer.free()
	_snap.seq += 1
	_bodies.update()


func _back_on_pile(u: int) -> bool:
	var as_body: bool = _bodies.body_of(u) != null and _bodies.square_of(u) == PILE
	var drawn: bool = _bodies.body_of(u) == null and not _world.hidden_items.has(u) and not _world.item_slot(u).is_empty()
	return u > 0 and not _bodies.is_pending(u) and (as_body or drawn) and _on(PILE).size() == ItemBodies.PILE_BODIES
