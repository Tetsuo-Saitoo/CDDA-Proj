extends RefCounted
## Block L8 slice 1: looting a placeholder dresser (PropBoxes) by hand on the mock town, with MockItems answering
## inside each call. The mouse (E6: drag a drawer out as GrabController does, E takes what the crosshair is on) and
## a VR hand (pull a drawer by its handle, grip inside it takes what lies there). Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # a dresser: a rock and a hammer in its drawers

var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _mock: MockItems


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("loot by hand (L8)")
	for id: String in ["rock", "hammer"]:
		_it[id] = tables.index_of("itype", id)
	if not _setup(root, data, tables):
		return
	_test_closed()
	_test_mouse()
	_test_vr()
	_hands.free()
	_actions.free()
	_world.free()
	_mock = null   # its `changed` holds a lambda that holds this test: break the cycle


func _setup(root: Node, data: Variant, tables: IdTables) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		sm["items"] = []
		sm.erase("handles")
		if Vector3i(int(pos[0]), int(pos[1]), int(pos[2])) == Vector3i(16, 32, 0):
			sm["furn"][1] = tables.index_of("furn", "f_dresser")   # E
			sm["items"] = [[1, 2, [_it["rock"], _it["hammer"]]]]
	(d["player"] as Dictionary)["items"] = []
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "loot: test town loads " + _snap.error)
	if not _snap.is_valid():
		return false
	var mock := MockItems.new(_snap, tables)
	mock.seed()
	_mock = mock
	_world = WorldView.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(tables)
	root.add_child(_world)
	_world.apply_snapshot(_snap)
	_actions = ItemActions.new()
	_actions.backend = mock
	mock.changed.connect(func(s: Snapshot) -> void:
		_world.apply_snapshot(s)
		_actions.on_snapshot(s))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	return true


static func _uid(t: Dictionary) -> int:
	return (t["item"] as ItemRef).uid if not t.is_empty() and t.get("item") != null else -1


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(p: Vector3i, type: int) -> int:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


## The drawer item `uid` rides (null if none).
func _drawer_of(uid: int) -> Grabbable:
	var s: Array = _world._slot_of.get(uid, [])
	if s.is_empty() or (s[1] as Array).size() < 8:
		return null
	return _world.parts.get(s[1][6]) as Grabbable


func _mid(uid: int) -> Vector3:
	var s := _world.item_slot(uid)
	return s[3] if not s.is_empty() else Vector3.INF


func _carried(uid: int) -> bool:
	return _hands.picker.carried().any(func(r: ItemRef) -> bool: return r.uid == uid)


## Standing in front of drawer `g` (0.7 m out from its handle), eyes 1.6 m up.
func _eye(g: Grabbable) -> Vector3:
	var out := g.global_transform.basis * g.axis
	var at := g.handle_point() + Vector3(out.x, 0.0, out.z).normalized() * 0.7
	return Vector3(at.x, 1.6, at.z)


## Closed drawers: their items ride them, hidden; the crosshair on a drawer and a hand at it find the drawer.
func _test_closed() -> void:
	var rock := _handle(E, _it["rock"])
	var hammer := _handle(E, _it["hammer"])
	var dr := _drawer_of(rock)
	var dh := _drawer_of(hammer)
	_check.call(rock > 0 and hammer > 0 and dr != null and dh != null and dr.kind == "drawer" and dh.kind == "drawer"
			and dr.open_amount() == 0.0 and _world.item_slot(rock).is_empty() and _world.item_slot(hammer).is_empty(),
			"loot: a dresser's items ride its drawers, hidden while they're shut")
	if dr == null:
		return
	var t := _hands.find_on_ray(_eye(dr), dr.handle_point() - _eye(dr))
	var n := _hands.find_near(dr.handle_point())
	_check.call(t.get("node") == dr and n.get("node") == dr, "loot: the crosshair and a hand at a shut drawer find the drawer")


## Mouse (E6): grab the drawer the crosshair is on, drag down to pull it out (GrabController's drag_mouse), let go;
## the crosshair on the rock now finds the rock, not the drawer around it, and E takes it into the pack.
func _test_mouse() -> void:
	var rock := _handle(E, _it["rock"])
	var dr := _drawer_of(rock)
	if dr == null:
		return
	var eye := _eye(dr)
	var t := _hands.find_on_ray(eye, dr.handle_point() - eye)
	var grabbed := _hands.grab("mouse", t)
	var view := Basis.looking_at(dr.handle_point() - eye)
	for k in 20:
		dr.drag_mouse(Vector2(0, 40), view)
	_hands.release("mouse", {})
	_check.call(grabbed and dr.open_amount() > 0.99 and not _world.item_slot(rock).is_empty() and _hands.holding("mouse").is_empty(),
			"loot: mouse: drag a drawer out; what it holds shows (%.2f open)" % dr.open_amount())
	t = _hands.find_on_ray(eye, _mid(rock) - eye)
	_check.call(_uid(t) == rock, "loot: mouse: the crosshair on an item in an open drawer finds the item (%s)" % [t.get("kind")])
	_check.call(_uid(t) == rock and _hands.take("mouse", t, "pack") and _carried(rock) and _handle(E, _it["rock"]) != rock,
			"loot: mouse: E takes it out of the drawer into the pack")


## VR: a hand at the handle grabs the drawer and pulls it; a grip inside the open drawer takes the hammer into the
## hand at once (not the drawer around it).
func _test_vr() -> void:
	var hammer := _handle(E, _it["hammer"])
	var dr := _drawer_of(hammer)
	if dr == null:
		return
	var h0 := dr.handle_point()
	var out := dr.global_transform.basis * dr.axis
	_hands.set_hand("vr_r", Transform3D(Basis.IDENTITY, h0))
	var t := _hands.find_near(h0)
	var grabbed := _hands.grab("vr_r", t)
	dr.drag_hand(h0 + out * 0.6)   # VrRig.update_grabs moves a held part with the controller
	_hands.release("vr_r", {})
	var mid := _mid(hammer)
	_check.call(grabbed and t.get("node") == dr and dr.open_amount() > 0.99 and mid.is_finite(),
			"loot: VR: pull a drawer open by its handle (%.2f open)" % dr.open_amount())
	_hands.set_hand("vr_r", Transform3D(Basis.IDENTITY, mid))
	t = _hands.find_near(mid)
	_check.call(_uid(t) == hammer and _hands.grab("vr_r", t, "main") and (_hands.holding("vr_r")["item"] as ItemRef).is_wielded()
			and _handle(E, _it["hammer"]) != hammer, "loot: VR: a grip inside the open drawer takes the hammer into the hand")
