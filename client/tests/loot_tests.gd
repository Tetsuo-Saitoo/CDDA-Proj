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
	_test_open_at()
	_test_shelf_ops()
	_test_take_container()
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
	var at := _mid(rock)
	t = _hands.find_on_ray(eye, at - eye)
	_check.call(_uid(t) == rock, "loot: mouse: the crosshair on an item in an open drawer finds the item (%s)" % [t.get("kind")])
	_check.call(_uid(t) == rock and _hands.take("mouse", t, "pack") and _carried(rock) and _handle(E, _it["rock"]) != rock,
			"loot: mouse: E takes it out of the drawer into the pack")
	# slice 2: the crosshair on the open drawer's floor puts it back on that drawer's shelf; shut, it's no shelf
	var held := ItemRef.on_player(rock, _it["rock"], 0, -1, 0, P)
	var d := _hands.drop_on_ray(eye, at - eye, held)
	_check.call(d["kind"] == "surface" and d["square"] == E and int(d["shelf"]) >= 0,
			"loot: mouse: the crosshair on the open drawer's floor puts it back on its shelf (%s)" % [d])
	dr.set_amount(0.0)
	d = _hands.drop_on_ray(eye, at - eye, held)
	_check.call(int(d["shelf"]) == -1, "loot: mouse: a shut drawer is no shelf (%s)" % [d])
	dr.set_amount(1.0)


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
	# slice 2: let go inside the open drawer again: it goes back onto that drawer's floor, where the hand was
	var spot_at := mid + out * -0.05
	var held: ItemRef = _hands.holding("vr_r").get("item")
	var d := _hands.drop_at(spot_at, held)
	var shelf: int = d.get("shelf", -1)
	_check.call(d.get("kind") == "surface" and d.get("square") == E and shelf >= 0,
			"loot: VR: letting go in an open drawer puts it on that drawer's shelf (%s)" % [d])
	_hands.set_hand("vr_r", Transform3D(Basis.IDENTITY, spot_at))
	var op := _hands.release("vr_r", d)
	var sm: Snapshot.Submap = _snap.submaps[CddaCoords.ms_to_sm(E)]
	var back := _drawer_of(hammer)
	var at := _mid(hammer)
	_check.call(op == "drop" and _handle(E, _it["hammer"]) == hammer and sm.shelves.get(hammer, -1) == shelf
			and back != null and back.id == dr.id and at.is_finite() and at.distance_to(spot_at) < 0.12,
			"loot: VR: it's back in that drawer, drawn where the hand let go (%s, %.2f m off)" % [op, at.distance_to(spot_at)])
	back.set_amount(0.0)
	_check.call(_world.item_slot(hammer).is_empty(), "loot: VR: the drawer pushed shut hides it again")


## An older DLL's CddaSim: no queue_action_at.
class OldSim extends RefCounted:
	func queue_action(_action: String) -> bool:
		return true


## Stands in for CddaSim with queue_action_at: keeps what reached it.
class ActAtSim extends RefCounted:
	var sent: Array = []

	func queue_action_at(action: String, square: Vector3i) -> bool:
		sent.append([action, square])
		return true


## LiveSession.open_at (safes and every door, main.gd _on_door_wants): CDDA's open / close for exactly that square;
## refused here, nothing sent, unless it is one of the eight squares around the player; an older DLL without
## queue_action_at says so (can_act_at), so main.gd answers CDDA's "where?" prompt instead.
func _test_open_at() -> void:
	var ls := LiveSession.new()
	var none := not ls.can_act_at() and not ls.open_at(true, E, P)
	var sim := ActAtSim.new()
	ls._sim = sim
	var ok := ls.can_act_at() and ls.open_at(true, E, P) and ls.open_at(false, P + Vector3i(-1, 1, 0), P)
	_check.call(none and ok and sim.sent == [["open", E], ["close", P + Vector3i(-1, 1, 0)]],
			"loot: open_at: CDDA's open / close for exactly that square (%s)" % [sim.sent])
	var far := Vector3i(1 << 30, 0, 0)
	var bad: Array[bool] = [ls.open_at(true, P, P), ls.open_at(true, P + Vector3i(2, 0, 0), P),
			ls.open_at(true, E + Vector3i(0, 0, 1), P), ls.open_at(true, far, far + Vector3i(-1, 0, 0))]
	_check.call(not bad.has(true) and sim.sent.size() == 2,
			"loot: open_at: the player's own square, two away, another level or out of range: nothing sent (%s)" % [bad])
	ls._sim = OldSim.new()
	_check.call(not ls.can_act_at() and not ls.open_at(true, E, P), "loot: open_at: an older DLL can't (main.gd asks the old way)")
	ls._sim = null
	ls.free()


## Stands in for CddaSim's queue_item_action: keeps what reached it.
class ItemSim extends RefCounted:
	var sent: Array[Dictionary] = []

	func queue_item_action(a: Dictionary) -> bool:
		sent.append(a)
		return true


## Stands in for an ItemActions backend: keeps each drop_item call's arguments.
class DropBackend extends RefCounted:
	var calls: Array = []

	func drop_item(uid: float, type: float, pos: Vector3i, spot := Vector2(-1, -1), shelf := -1) -> bool:
		calls.append([int(uid), int(type), pos, spot, shelf])
		return true


## L8 slice 2, the drop side of a shelf (the bridge's `shelf`, 0..15, kept with the spot): LiveSession sends it only
## with a spot and refuses one out of range; ItemActions passes it on (no shelf without a spot); DropTarget takes a
## well-formed shelf_at answer in reach (a container under the pointer still comes first).
func _test_shelf_ops() -> void:
	var ls := LiveSession.new()
	var sim := ItemSim.new()
	ls._sim = sim
	var half := Vector2(0.5, 0.25)
	var ok := ls.drop_item(5.0, 3.0, E, half, 2) and ls.drop_item(5.0, 3.0, E, Vector2(-1, -1), 2) \
			and ls.place_item(5.0, 3.0, P, E, half, 90, false, 7, 15) and ls.spot_item(6.0, 4.0, P, half, 0, false, 8, 0) \
			and ls.drop_item(5.0, 3.0, E, half)
	var shelves := sim.sent.map(func(a: Dictionary) -> int: return a.get("shelf", -1))
	_check.call(ok and shelves == [2, -1, 15, 0, -1], "loot: shelf: LiveSession sends it only with a spot (%s)" % [shelves])
	var n := sim.sent.size()
	var bad: Array[bool] = [ls.drop_item(5.0, 3.0, E, half, 16), ls.drop_item(5.0, 3.0, E, half, -2),
			ls.place_item(5.0, 3.0, P, E, half, 0, false, 1, 16), ls.spot_item(5.0, 3.0, P, half, 0, false, 1, -5)]
	_check.call(not bad.has(true) and sim.sent.size() == n, "loot: shelf: one outside 0..15 is refused, nothing sent (%s)" % [bad])
	ls._sim = null
	ls.free()
	var acts := ItemActions.new()
	var be := DropBackend.new()
	acts.backend = be
	var item := func(u: int) -> ItemRef: return ItemRef.on_player(u, _it["rock"], 0, -1, 0, P)
	ok = acts.drop(item.call(21), E, half, 3) and acts.drop(item.call(22), E, Vector2(-1, -1), 3) \
			and not acts.drop(item.call(23), E, half, ItemActions.MAX_SHELF + 1)
	_check.call(ok and be.calls.size() == 2 and be.calls[0][4] == 3 and be.calls[1][4] == -1,
			"loot: shelf: ItemActions.drop passes it on, never without a spot (%s)" % [be.calls])
	acts.free()
	var reach := func(sq: Vector3i) -> bool: return GrabController.adjacent(sq - P) or sq == P
	var held: ItemRef = item.call(24)
	var shelf := {"square": E, "shelf": 1, "spot": Vector2(0.3, 1.4)}
	var d := DropTarget.resolve(_world.coords, {}, null, held, _world.tables, _world.snapshot, reach, shelf)
	_check.call(d["kind"] == "surface" and d["square"] == E and d["shelf"] == 1 and d["spot"] == Vector2(0.3, DropTarget.SPOT_MAX),
			"loot: shelf: DropTarget puts it on the shelf it's over, the spot clamped (%s)" % [d])
	var odd: Array = [{"square": E, "shelf": 16, "spot": half}, {"square": E, "shelf": 1.0, "spot": half},
			{"square": E, "shelf": 1, "spot": Vector2(NAN, 0)}, {"square": P + Vector3i(3, 0, 0), "shelf": 1, "spot": half}]
	var none := odd.all(func(o: Dictionary) -> bool:
		return DropTarget.resolve(_world.coords, {}, null, held, _world.tables, _world.snapshot, reach, o)["shelf"] == -1)
	_check.call(none, "loot: shelf: a malformed or out-of-reach shelf counts as none")


## Stands in for an ItemActions backend: keeps each take_item call's arguments.
class TakeBackend extends RefCounted:
	var calls: Array = []

	func take_item(uid: float, type: float, pos: Vector3i, hand := "pack", container := -1.0,
			container_type := -1.0) -> bool:
		calls.append([int(uid), int(type), pos, hand, container, container_type])
		return true

	func queued_actions() -> int:
		return 0


## L8 slice 3, taking out of a lying container (the bridge's take `container` + `container_type`): LiveSession
## sends the pair only when both are good handles (else nothing), a take without one exactly as before; ItemActions
## takes the container only from the item's own lying parent, with its itype from the snapshot.
func _test_take_container() -> void:
	var ls := LiveSession.new()
	var sim := ItemSim.new()
	ls._sim = sim
	var ok := ls.take_item(5.0, 3.0, E, "pack", 9.0, 4.0) and ls.take_item(5.0, 3.0, E)
	var sent := sim.sent.duplicate()
	var plain := {"op": "take", "item": 5, "type": 3, "pos": E, "hand": "pack"}
	_check.call(ok and sent.size() == 2 and sent[0].get("container") == 9 and sent[0].get("container_type") == 4
			and sent[1] == plain, "loot: container take: LiveSession sends the pair; without one, the take as before (%s)" % [sent])
	var bad: Array[bool] = [ls.take_item(5.0, 3.0, E, "pack", NAN, 4.0), ls.take_item(5.0, 3.0, E, "pack", 9.0, NAN),
			ls.take_item(5.0, 3.0, E, "pack", 0.0, 4.0), ls.take_item(5.0, 3.0, E, "pack", -3.0, 4.0),
			ls.take_item(5.0, 3.0, E, "pack", 9.0, 0.0), ls.take_item(5.0, 3.0, E, "pack", 9.0),
			ls.take_item(5.0, 3.0, E, "pack", -1.0, 4.0), ls.take_item(5.0, 3.0, E, "pack", 9.5, 4.0),
			ls.take_item(5.0, 3.0, E, "pack", INF, 4.0), ls.take_item(5.0, 3.0, E, "pack", 1e30, 4.0),
			ls.take_item(5.0, 3.0, E, "pack", 5.0, 3.0)]
	_check.call(not bad.has(true) and sim.sent.size() == 2,
			"loot: container take: a bad, half or self pair is refused, nothing sent (%s)" % [bad])
	ls._sim = null
	ls.free()
	var acts := ItemActions.new()
	var be := TakeBackend.new()
	acts.backend = be
	var c := _handle(E, _it["hammer"])   # lying on E; the client doesn't judge what's a container, CDDA does
	var inside := func(u: int, parent: int) -> ItemRef:
		var r := ItemRef.on_square(u, _it["rock"], E)
		r.parent = parent
		r.pocket = 0
		return r
	ok = not acts.take(inside.call(424240, c))   # no snapshot yet: no container known
	acts.on_snapshot(_snap)
	ok = ok and acts.take(inside.call(424241, c)) and acts.take(ItemRef.on_square(424242, _it["rock"], E))
	_check.call(c > 0 and ok and be.calls.size() == 2 and be.calls[0].slice(4) == [float(c), float(_it["hammer"])]
			and be.calls[1].size() == 6 and be.calls[1].slice(4) == [-1.0, -1.0],
			"loot: container take: ItemActions sends the item's lying parent and its type from the snapshot (%s)" % [be.calls])
	var worn := int(_snap.carried[0]) if _snap.carried.size() > 0 else 999999
	var away: ItemRef = inside.call(424246, c)
	away.square = P   # the container lies on E, not where this item claims to be
	var refused: Array[bool] = [acts.take(inside.call(424243, worn)), acts.take(inside.call(424244, -7)),
			acts.take(inside.call(424245, 424245)), acts.take(away), acts.take(inside.call(424247, 31337))]
	_check.call(not refused.has(true) and be.calls.size() == 2,
			"loot: container take: a carried, negative, own, elsewhere or unknown parent is refused, nothing sent (%s)" % [refused])
	_test_take_judged(acts, be, c)
	acts.free()
	_test_mock_take_container(c)


## A container take is judged by the container's `inside` (the item was never a handle on the square): still
## listed there = not done (refused after two looks), cut short = unknown, gone from it = done.
func _test_take_judged(acts: ItemActions, be: TakeBackend, c: int) -> void:
	var sm: Snapshot.Submap = _snap.submaps[CddaCoords.ms_to_sm(E)]
	var rock: int = _it["rock"]
	var r := ItemRef.on_square(424260, rock, E)
	r.parent = c
	r.pocket = 0
	sm.inside[c] = [[424260, rock, 0]]
	acts.on_snapshot(_snap)
	var sent := acts.take(r)
	_snap.seq += 1
	acts.on_snapshot(_snap)
	var after_one := acts.pending(424260)
	_snap.seq += 1
	acts.on_snapshot(_snap)
	_check.call(sent and after_one == "take" and acts.pending(424260) == "" and be.calls.size() == 3,
			"loot: container take: still in the container is not done; a second look refuses it (%s)" % after_one)
	var r2 := r.duplicate_ref()
	r2.uid = 424261
	sm.inside[c] = [[424261, rock, 0]]
	acts.on_snapshot(_snap)
	sent = acts.take(r2)
	sm.inside[c] = []
	sm.inside_more[c] = 3
	_snap.seq += 1
	acts.on_snapshot(_snap)
	var cut := acts.pending(424261)
	sm.inside_more.erase(c)
	_snap.seq += 1
	acts.on_snapshot(_snap)
	_check.call(sent and cut == "take" and acts.pending(424261) == "",
			"loot: container take: a cut list is unknown; gone from the container is done (%s)" % cut)
	sm.inside.erase(c)


## MockItems answers a container take the bridge's way: out of `inside` only for that container on that square.
func _test_mock_take_container(c: int) -> void:
	var sm: Snapshot.Submap = _snap.submaps[CddaCoords.ms_to_sm(E)]
	var rock := float(_it["rock"])
	var ham := float(_it["hammer"])
	sm.inside[c] = [[424250, _it["rock"], 0], [424251, _it["rock"], 0]]
	var said: Array[String] = []
	var hear := func(t: String) -> void: said.append(t)
	_mock.message.connect(hear)
	var seq := _snap.seq
	# refused, nothing moves: another square, the wrong container type, not in it, a half pair, itself
	var bad := [_mock.take_item(424250, rock, P, "pack", c, ham),
			_mock.take_item(424250, rock, E, "pack", c, rock), _mock.take_item(424259, rock, E, "pack", c, ham),
			_mock.take_item(424250, rock, E, "pack", c), _mock.take_item(c, ham, E, "pack", c, ham),
			_mock.take_item(424250, rock, E, "pack", NAN, ham)]
	_check.call(bad == [true, true, true, false, false, false] and said.size() == 3
			and said.all(func(t: String) -> bool: return t == "That isn't there any more.")
			and (sm.inside[c] as Array).size() == 2 and ItemActions.carried_row(_snap, 424250, _it["rock"]) < 0,
			"loot: mock container take: elsewhere, wrong or missing is refused; bad args return false (%s %s)" % [bad, said])
	var ok := _mock.take_item(424250, rock, E, "pack", c, ham)
	_check.call(ok and _snap.seq > seq and (sm.inside[c] as Array).size() == 1 and ItemActions.carried_row(_snap, 424250, _it["rock"]) >= 0
			and _handle(E, _it["hammer"]) == c,
			"loot: mock container take: the item leaves the container for the pack, the container stays")
	ok = _mock.take_item(424251, rock, E, "pack", c, ham)
	_check.call(ok and not sm.inside.has(c) and ItemActions.carried_row(_snap, 424251, _it["rock"]) >= 0, "loot: mock container take: the last one empties its list")
	_mock.message.disconnect(hear)
