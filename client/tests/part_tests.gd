extends RefCounted
## Block L8, the world side: a furniture model's doors, drawers and lids (ModelLibrary movers) become Grabbable
## parts: PropMesher lists them as specs and draws the rest still, WorldView makes, keeps, syncs and drops the
## nodes and finds them for a hand or a ray. Models are built here with GLTFDocument (model_tests.gd's helpers)
## into this run's folder (tests/test_dir.gd); run by run_tests.gd on a scene cut from the mock town.

const TestDir := preload("res://tests/test_dir.gd")
const ModelTests := preload("res://tests/model_tests.gd")
const AT_SAFE := Vector2i(5, 5)

var _check: Callable
var _tables: IdTables
var _dir := ""
var _pos := Vector3i.ZERO   # the scene's submap (the mock's first, rewritten)
var _book := 0


func run(root: Node, check: Callable, data: Variant, tables: IdTables, repo: Callable) -> void:
	print("furniture parts")
	_check = check
	_tables = tables
	_book = tables.index_of("itype", "101_carpentry")
	_dir = TestDir.global("part_test")
	DirAccess.make_dir_recursive_absolute(_dir.path_join("models/furniture"))
	DirAccess.make_dir_recursive_absolute(_dir.path_join("registry"))
	_write("models/furniture/cabinet.glb", cabinet_glb())
	_write("models/furniture/many.glb", many_glb())
	var entries := [
		{"type": "fp3d_model", "id": ["f_safe_c", "f_safe_o"], "kind": "furniture", "model": "furniture/cabinet.glb"},
		{"type": "fp3d_model", "id": "f_gunsafe_c", "kind": "furniture", "model": "furniture/many.glb"},
	]
	_write("registry/parts.json", JSON.stringify(entries).to_utf8_buffer())
	var reg := AssetRegistry.new()
	reg.models.root = _dir.path_join("models")
	reg.load_dir(repo.call("assets/registry"))
	reg.load_dir(_dir.path_join("registry"))
	var p: Array = (data as Dictionary)["submaps"][0]["pos"]
	_pos = Vector3i(int(p[0]), int(p[1]), int(p[2]))
	_test_movers(reg.models)
	_test_hostile(reg.models)
	var world := WorldView.new()
	world.catalog.registry = reg
	world.props = PropCatalog.new(reg)
	root.add_child(world)
	world.set_id_tables(tables)
	var cab := reg.models.get_model("furniture/cabinet.glb")
	if cab != null:
		_test_specs(world, data, cab)
		_test_world(world, data, cab)
	_test_submap_cap(world, data, reg.models.get_model("furniture/many.glb"))
	world.free()


## A 0.8 x 1.2 x 0.5 m cabinet: a body with a shelf (surface_1); door_1 hinged on its left edge (an empty on the
## hinge, the leaf a child mesh) with handle_1; door_2 hinged on its right edge; drawer_1 (a mesh centred on its
## slide origin) with its floor (surface_2); a lid hinged at the back of the top.
static func cabinet_glb() -> PackedByteArray:
	var root := Node3D.new()
	root.name = "cabinet"
	ModelTests._box(root, "body", Vector3(0.8, 1.2, 0.5), Vector3(0, 0.6, 0))
	ModelTests._plane(root, "surface_1", Vector2(0.6, 0.4), Vector3(0, 0.5, 0))
	var d1 := _empty(root, "door_1", Vector3(-0.4, 0.05, 0.26))
	ModelTests._box(d1, "door_1_leaf", Vector3(0.38, 0.6, 0.02), Vector3(0.19, 0.3, 0.01))
	ModelTests._box(d1, "handle_1", Vector3(0.02, 0.1, 0.02), Vector3(0.34, 0.3, 0.03))
	var d2 := _empty(root, "door_2", Vector3(0.4, 0.05, 0.26))
	ModelTests._box(d2, "door_2_leaf", Vector3(0.38, 0.6, 0.02), Vector3(-0.19, 0.3, 0.01))
	var drawer := ModelTests._box(root, "drawer_1", Vector3(0.6, 0.15, 0.45), Vector3(0, 0.95, 0.02))
	ModelTests._plane(drawer, "surface_2", Vector2(0.5, 0.35), Vector3(0, -0.06, 0))
	var lid := _empty(root, "lid", Vector3(0, 1.2, -0.25))
	ModelTests._box(lid, "lid_board", Vector3(0.8, 0.02, 0.5), Vector3(0, 0.01, 0.25))
	return ModelTests.scene_glb(root)


## A hostile cabinet: 21 doors (door_1's leaf 6 m from its hinge), drawer_1 inside door_2.
static func many_glb() -> PackedByteArray:
	var root := Node3D.new()
	root.name = "many"
	ModelTests._box(root, "body", Vector3(0.8, 1.0, 0.5), Vector3(0, 0.5, 0))
	for n in range(1, 22):
		var d := _empty(root, "door_%d" % n, Vector3(-0.4 + 0.035 * n, 0.05, 0.26))
		ModelTests._box(d, "door_%d_leaf" % n, Vector3(0.03, 0.4, 0.02), Vector3(6.0 if n == 1 else 0.015, 0.2, 0.01))
		if n == 2:
			ModelTests._box(d, "drawer_1", Vector3(0.03, 0.05, 0.02), Vector3(0.015, 0.5, 0.01))
	return ModelTests.scene_glb(root)


static func _empty(parent: Node, name: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position = pos
	parent.add_child(n)
	return n


func _mover(m: ModelLibrary.Model, name: String) -> ModelLibrary.Mover:
	for mv: ModelLibrary.Mover in m.movers:
		if mv.name == name:
			return mv
	return null


func _test_movers(lib: ModelLibrary) -> void:
	var m := lib.get_model("furniture/cabinet.glb")
	_check.call(m != null and lib.get_warnings().is_empty(), "parts: the cabinet loads without warnings " + str(lib.get_warnings()))
	if m == null:
		return
	var names := m.movers.map(func(mv: ModelLibrary.Mover) -> String: return mv.name)
	_check.call(names == ["lid", "door_1", "door_2", "drawer_1"] and m.parts.size() == 6,
			"parts: lid, door_N, drawer_N are movers (%s), 6 drawn meshes" % str(names))
	var d1 := _mover(m, "door_1")
	var d2 := _mover(m, "door_2")
	var dr := _mover(m, "drawer_1")
	var lid := _mover(m, "lid")
	if d1 == null or d2 == null or dr == null or lid == null:
		return
	_check.call(d1.kind == "door" and d1.axis.is_equal_approx(Vector3.DOWN) and is_equal_approx(d1.max_amount, ModelLibrary.DOOR_MAX)
			and d1.pivot.origin.is_equal_approx(Vector3(-0.4, 0.05, 0.26)) and d1.meshes.size() == 2,
			"parts: a door hinged on its left edge turns about -Y (opens toward the front), with its leaf and handle")
	_check.call(d1.has_handle and d1.handle.origin.is_equal_approx(Vector3(0.34, 0.3, 0.03)),
			"parts: handle_1 is the door's grab point, in the door's own space")
	_check.call(d2.axis.is_equal_approx(Vector3.UP) and not d2.has_handle, "parts: a door hinged on its right edge turns about +Y")
	_check.call(lid.kind == "lid" and lid.axis.is_equal_approx(Vector3.LEFT) and is_equal_approx(lid.max_amount, ModelLibrary.LID_MAX),
			"parts: a lid hinged at the back turns about -X (lifts its front)")
	_check.call(dr.kind == "drawer" and dr.axis.is_equal_approx(Vector3.BACK)
			and is_equal_approx(dr.max_amount, ModelLibrary.DRAWER_OUT * 0.45) and dr.meshes.size() == 1,
			"parts: a drawer slides toward the front (+Z), out by %.0f%% of its depth (%.3f m)" % [ModelLibrary.DRAWER_OUT * 100, dr.max_amount])
	_check.call(dr.surfaces.size() == 1 and (dr.surfaces[0][0] as Transform3D).origin.is_equal_approx(Vector3(0, -0.06, 0))
			and (dr.surfaces[0][1] as Rect2).size.is_equal_approx(Vector2(0.5, 0.35))
			and m.surface_mover == PackedInt32Array([-1, m.movers.find(dr)]),
			"parts: the drawer's surface_2 moves with it (in its space); the shelf stays " + str(m.surface_mover))
	_check.call(m.still != null and m.still.parts.size() == 1 and m.still.movers.is_empty() and m.still.surfaces == m.surfaces,
			"parts: `still` is the model without its movers' meshes")
	var t := lib.get_tinted("furniture/cabinet.glb", "wood_dark")
	var tinted_ok := t != null and t != m and t.movers.size() == 4 and t.still != null and t.still.parts.size() == 1
	if tinted_ok:
		var tdr := _mover(t, "drawer_1")
		tinted_ok = tdr != null and tdr.meshes[0][0] != dr.meshes[0][0] and t.parts.any(func(e: Array) -> bool: return e[0] == tdr.meshes[0][0])
	_check.call(tinted_ok, "parts: a tinted variant's movers draw its tinted meshes")


func _test_hostile(lib: ModelLibrary) -> void:
	var m := lib.get_model("furniture/many.glb")
	var w := "\n".join(lib.get_warnings())
	_check.call(m != null and m.movers.size() == ModelLibrary.MAX_MOVERS, "parts: at most %d movers per model (%d)"
			% [ModelLibrary.MAX_MOVERS, m.movers.size() if m else -1])
	if m == null:
		return
	_check.call(w.contains("door_1 stays put") and w.contains("more than %d" % ModelLibrary.MAX_MOVERS)
			and w.contains("drawer_1 is inside door_2"), "parts: a far door, the ones past the cap and a nested drawer are warned about")
	var d2 := _mover(m, "door_2")
	_check.call(_mover(m, "door_1") == null and d2 != null and d2.meshes.size() == 2 and _mover(m, "drawer_1") == null,
			"parts: the far door stays put; the nested drawer moves with its door")
	# body, door_1's leaf (stays put), door_18..21's leaves (past the cap)
	_check.call(m.still != null and m.still.parts.size() == 6, "parts: what doesn't open is drawn still (%d)" % (m.still.parts.size() if m.still else -1))


## The mock's first submap rewritten (floor, the safe at AT_SAFE with two books: on the shelf and in the drawer)
## and its second as it is.
func _scene(data: Variant, furn: String, revision := 0, items := true) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate()
	var src: Array = d["submaps"]
	var sm: Dictionary = (src[0] as Dictionary).duplicate(true)
	d["submaps"] = [sm, src[1]]
	var floor_id := _tables.index_of("ter", "t_floor")
	for i in 144:
		sm["ter"][i] = floor_id
		sm["furn"][i] = 0
		sm["trap"][i] = 0
		sm["flags"][i] = 1
	var at := AT_SAFE.y * CddaCoords.SEEX + AT_SAFE.x
	sm["furn"][at] = _tables.index_of("furn", furn)
	sm["items"] = [[at, 2, [_book, 0, 0, 0]]] if items else []
	sm["handles"] = [[at, 701, _book, -1, -1], [at, 702, _book, -1, -1]] if items else []
	sm["revision"] = int(sm.get("revision", 1)) + revision
	sm["detail_revision"] = int(sm.get("detail_revision", 1)) + revision
	return Snapshot.from_data(d)


func _safe_sq() -> Vector3i:
	return CddaCoords.sm_to_ms(_pos) + Vector3i(AT_SAFE.x, AT_SAFE.y, 0)


func _id(name: String) -> String:
	var s := _safe_sq()
	return "%d_%d_%d/%s" % [s.x, s.y, s.z, name]


func _build(world: WorldView, snap: Snapshot) -> PropMesher.Result:
	world.catalog.set_snapshot(snap)
	world.props.set_snapshot(snap)
	return PropMesher.new(snap, world.catalog, world.props).build(_pos)


func _spec(r: PropMesher.Result, name: String) -> Dictionary:
	for s: Dictionary in r.parts:
		if s["id"] == _id(name):
			return s
	return {}


func _test_specs(world: WorldView, data: Variant, cab: ModelLibrary.Model) -> void:
	var snap := _scene(data, "f_safe_c")
	_check.call(snap.is_valid(), "parts: scene valid " + snap.error)
	var r := _build(world, snap)
	var still: Array = r.models.get(cab.still, [])
	_check.call(r.parts.size() == 4 and still.size() == 1 and not r.models.has(cab) and r.furniture == 1,
			"parts: the safe draws its still model and lists 4 parts (%d)" % r.parts.size())
	if r.parts.size() != 4 or still.size() != 1:
		return
	var mxf: Transform3D = still[0]
	var d1 := _spec(r, "door_1")
	var dr := _spec(r, "drawer_1")
	_check.call(not d1.is_empty() and d1["square"] == _safe_sq() and d1["kind"] == "door"
			and (d1["pivot"] as Transform3D).is_equal_approx(mxf * cab.marker("door_1"))
			and (d1["axis"] as Vector3).is_equal_approx(Vector3.DOWN) and is_equal_approx(d1["max"], ModelLibrary.DOOR_MAX)
			and (d1["handle"] as Transform3D).origin.is_equal_approx(Vector3(0.34, 0.3, 0.03)) and (d1["meshes"] as Array).size() == 2,
			"parts: door_1's spec: id by square and marker, pivot in the submap, axis, max, handle")
	_check.call(d1["open_id"] == "f_safe_o" and d1["close_id"] == "f_safe_c" and d1["cdda_open"] == false and d1["locked"] == false,
			"parts: a furniture with CDDA's open / closed pair names both, closed")
	_check.call(not _spec(r, "lid").has("handle") and not dr.is_empty() and dr["kind"] == "drawer",
			"parts: without a handle_N the spec leaves the grab point to Grabbable")
	var on_drawer: bool = not dr.is_empty() and (dr["items_mesh"] != null or not (dr["items_models"] as Dictionary).is_empty()
			or not (dr["items_glyphs"] as Array).is_empty())
	var uids := r.item_slots.map(func(e: Array) -> int: return e[0])
	var rides := r.item_slots.map(func(e: Array) -> String: return e[6])
	_check.call(on_drawer and uids == [701, 702] and rides == ["", _id("drawer_1")] and r.items == 2,
			"parts: the book on the drawer's floor is drawn with the drawer, its slot names the drawer " + str(uids))
	var open := _build(world, _scene(data, "f_safe_o"))
	_check.call(open.parts.size() == 4 and _spec(open, "door_1")["cdda_open"] == true
			and (_spec(open, "door_1")["pivot"] as Transform3D).is_equal_approx(d1["pivot"]),
			"parts: the open furniture of the pair: cdda_open, same pivot")


func _test_world(world: WorldView, data: Variant, cab: ModelLibrary.Model) -> void:
	world.door_local = true
	var snap := _scene(data, "f_safe_c")
	world.apply_snapshot(snap)
	var node := world.node_of(_pos)
	var g1: Grabbable = world.parts.get(_id("door_1"))
	var gd: Grabbable = world.parts.get(_id("drawer_1"))
	_check.call(world.parts.size() == 4 and g1 != null and gd != null and g1.get_parent() == node and gd.get_parent() == node
			and g1.mech == "hinge" and gd.mech == "slide" and world.prop_counts["parts"] == 4,
			"parts: the world makes a Grabbable per part under the submap's node (%d)" % world.parts.size())
	if g1 == null or gd == null or node == null:
		return
	var moving := {}
	for mv: ModelLibrary.Mover in cab.movers:
		for e: Array in mv.meshes:
			moving[e[0]] = true
	var holder := node.get_node_or_null("models")
	var mms := holder.get_children() if holder else []
	_check.call(mms.size() == 1 and not mms.any(func(n: Node) -> bool: return moving.has((n as MultiMeshInstance3D).multimesh.mesh)),
			"parts: the static multimesh leaves the moving meshes out (%d multimeshes)" % mms.size())
	var model := g1.leaf.get_node_or_null("Model")
	_check.call(model != null and model.get_child_count() == 2 and moving.has((model.get_child(0) as MeshInstance3D).mesh),
			"parts: the door's own meshes are under its leaf")
	var items := gd.contents().get_node_or_null("Items") as Node3D
	var at := items.global_position if items else Vector3.ZERO
	_check.call(world.item_slot(702).is_empty() and not world.item_slot(701).is_empty(),
			"parts: the book in the closed drawer can't be pointed at; the shelf's can")
	gd.set_amount(0.3)
	var front := (gd.global_basis * gd.axis).normalized()
	_check.call(items != null and items.global_position.distance_to(at + front * 0.3) < 0.001,
			"parts: what lies in the drawer slides out with it")
	# Its item slot follows: pointable while open, where it is drawn now.
	var s702 := world.item_slot(702)
	var rest: Vector3 = world.coords.sm_to_world(_pos) + (world._slot_of[702][1][5] as Vector3)
	var near := world.items_near(rest + front * 0.3, 0.05, _safe_sq())
	_check.call(not s702.is_empty() and (s702[3] as Vector3).distance_to(rest + front * 0.3) < 0.001
			and not near.is_empty() and near[0] == 702,
			"parts: the book in the open drawer is pointed at where it is drawn now")
	# An item behind the model's doors (a slot gated by them) shows while one is open; a gone part hides it.
	var gated := [1, 1, 0, Transform3D(), 0.1, Vector3.ZERO, "", PackedStringArray([_id("door_1")])]
	g1.set_amount(0.0)
	var shut := world._slot_shown(gated)
	g1.set_amount(g1.max_amount)
	var gone := gated.duplicate()
	gone[6] = _id("nothing")
	_check.call(not shut and world._slot_shown(gated) and not world._slot_shown(gone),
			"parts: items behind a door show when it opens; on a part that is gone, never")
	# Hands and rays find parts.
	g1.set_amount(0.0)
	var hp := g1.handle_point()
	_check.call(world.grabbable_near(hp, 0.05) == g1 and world.grabbable_near(hp, 0.05, func(_s: Vector3i) -> bool: return false) == null,
			"parts: a hand at the door's handle finds the door (and not when its square is out of reach)")
	var o := gd.handle_point() + front * 1.0
	var hit := world.grabbable_on_ray(o, -front, _safe_sq(), 5.0)
	_check.call(not hit.is_empty() and hit[0] == gd and absf((hit[1] as Vector3).distance_to(o) - 1.0) < 0.01,
			"parts: a ray at the drawer's front picks the drawer")
	_check.call(world.grabbable_on_ray(o, -front, _safe_sq() + Vector3i(5, 0, 0), 5.0).is_empty(), "parts: not from squares out of reach")
	# A rebuild of the same snapshot keeps the nodes and their state.
	world.set_id_tables(_tables)
	world.apply_snapshot(snap)
	_check.call(world.props_built > 0 and world.parts.get(_id("door_1")) == g1 and world.parts.get(_id("drawer_1")) == gd
			and is_equal_approx(gd.amount, 0.3) and gd.contents().get_node_or_null("Items") != null,
			"parts: a rebuild keeps the same Grabbables and their state")
	# A newer snapshot (live): CDDA opened the safe.
	world.door_local = false
	world.apply_snapshot(_scene(data, "f_safe_o", 1))
	_check.call(world.parts.get(_id("door_1")) == g1 and g1.cdda_open and gd.cdda_open and g1.is_processing(),
			"parts: a newer snapshot syncs CDDA's state into the same nodes (sync_part)")
	# Other furniture on the square: parts made from another model are new nodes; gone ones are freed.
	var d2: Grabbable = world.parts.get(_id("door_2"))
	world.apply_snapshot(_scene(data, "f_gunsafe_c", 2))
	var n2: Grabbable = world.parts.get(_id("door_2"))
	_check.call(n2 != null and n2 != d2 and not is_instance_valid(d2) and not is_instance_valid(g1) and not world.parts.has(_id("lid"))
			and world.parts.size() == ModelLibrary.MAX_MOVERS,
			"parts: another model on the square makes new parts and frees the old ones")
	# The submap leaves: its parts go, with their kept state (live).
	var dg := (data as Dictionary).duplicate()
	dg["submaps"] = [(data as Dictionary)["submaps"][1]]
	world.apply_snapshot(Snapshot.from_data(dg))
	_check.call(world.parts.is_empty() and not is_instance_valid(n2) and world._parts_at.is_empty() and world._part_ids.is_empty()
			and not world.door_state.has(_id("door_2")) and world.grabbable_near(hp, 0.5) == null,
			"parts: dropping the submap frees its parts and their state")
	world.door_local = true


## A submap holds at most PropMesher.MAX_PARTS parts: furniture past it is drawn whole.
func _test_submap_cap(world: WorldView, data: Variant, many: ModelLibrary.Model) -> void:
	if many == null:
		_check.call(false, "parts: the many-door model loads")
		return
	var d: Dictionary = (data as Dictionary).duplicate()
	var sm: Dictionary = ((d["submaps"] as Array)[0] as Dictionary).duplicate(true)
	d["submaps"] = [sm]
	for i in 144:
		sm["furn"][i] = 0
		sm["ter"][i] = _tables.index_of("ter", "t_floor")
	var n := PropMesher.MAX_PARTS / ModelLibrary.MAX_MOVERS + 1
	for k in n:
		sm["furn"][k * 8] = _tables.index_of("furn", "f_gunsafe_c")
	sm["items"] = []
	sm["handles"] = []
	var r := _build(world, Snapshot.from_data(d))
	_check.call(r.parts.size() == PropMesher.MAX_PARTS and (r.models.get(many.still, []) as Array).size() == n - 1
			and (r.models.get(many, []) as Array).size() == 1,
			"parts: at most %d per submap, the furniture past it drawn whole (%d parts)" % [PropMesher.MAX_PARTS, r.parts.size()])


func _write(rel: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(_dir.path_join(rel), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
