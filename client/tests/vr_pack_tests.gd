extends RefCounted
## Block L8 (VR): the worn bag opened in front of the player (VrPack in VrRig) on the mock town, with MockItems
## answering inside each call: layout statics (pockets, sizes, caps, "+N more", hostile columns), rest / hang
## poses; grip over the shoulder takes the biggest worn bag off (nothing sent), let go in front it floats open
## facing the head, one compartment per pocket; an item taken out and dropped on the floor; a world item put into
## a chosen pocket; its own pocket = back, nothing sent; pending rows dim; a refused put buzzes; closing over the
## shoulder and with the trigger; it stays put while walking and closes when far; no new layout when nothing
## changed; hands freed / bag gone / nothing worn. No XR runtime: the test moves the controllers and presses
## buttons. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const S := P + Vector3i(0, 1, 0)       # bare floor
const FAR := P + Vector3i(5, 0, 0)     # out of reach
const BAG_S := 900                     # worn garbage bag (the smaller)
const BAG_L := 901                     # worn canvas sack: rock and hammer (pocket 0), plank (pocket 2)
const ROCK := 902
const HAMMER := 903
const PLANK := 904
const CS := Snapshot.CARRIED_STRIDE


## An item backend that takes a put and never answers: it stays in flight.
class Silent:
	extends RefCounted

	func put_item(_u: float, _t: float, _c: float, _ct: float, _p: Vector3i, _pocket := -1) -> bool:
		return true

	func queued_actions() -> int:
		return 0


var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _mock: MockItems
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig
var _closed: Array[String] = []


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr pack")
	for id: String in ["rock", "hammer", "2x4", "bag_canvas", "bag_garbage"]:
		_it[id] = tables.index_of("itype", id)
	_test_layout()
	_test_poses()
	if not _setup(root, data, tables):
		return
	_test_open()
	_test_no_rebuild()
	_test_take_out()
	_test_put_in()
	_test_same_pocket()
	_test_pending()
	_test_refused()
	_test_close()
	_test_far()
	_test_freed(root)
	_test_gone()
	_rig.free()
	_hands.free()
	_actions.free()
	_world.free()


func _setup(root: Node, data: Variant, tables: IdTables) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[1, 3, [_it["rock"], _it["hammer"], _it["2x4"]]]]
		elif at in [Vector3i(15, 32, 0), Vector3i(15, 31, 0), Vector3i(16, 31, 0)]:
			sm["items"] = []
		else:
			continue
		sm.erase("handles")
	(d["player"] as Dictionary)["items"] = [
		[BAG_S, _it["bag_garbage"], 0, -1, Snapshot.CARRIED_WORN],
		[BAG_L, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN],
		[ROCK, _it["rock"], BAG_L, 0, 0],
		[HAMMER, _it["hammer"], BAG_L, 0, 0],
		[PLANK, _it["2x4"], BAG_L, 2, 0],
	]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P and _snap.carried.size() == 5 * CS,
			"vr pack: test town loads with two worn bags " + _snap.error)
	if not _snap.is_valid():
		return false
	_mock = MockItems.new(_snap, tables)
	_mock.seed()
	_world = WorldView.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(tables)
	root.add_child(_world)
	_world.apply_snapshot(_snap)
	_actions = ItemActions.new()
	_actions.backend = _mock
	_mock.changed.connect(func(s: Snapshot) -> void:
		_world.apply_snapshot(s)
		_actions.on_snapshot(s))
	_mock.message.connect(func(t: String) -> void: _actions.on_events([MockItems.message_event(t)]))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_rig.hands = _hands
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_rig.go_to_square(P)
	_rig.pack.closed.connect(func(why: String) -> void: _closed.append(why))
	return true


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(p: Vector3i, type: int) -> int:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


func _mid(uid: int) -> Vector3:
	var s := _world.item_slot(uid)
	return s[3] if not s.is_empty() else Vector3.INF


## [parent, flags, pocket] of carried item `uid`, [] when it isn't carried.
func _row(uid: int) -> Array:
	var c := _snap.carried
	for i in range(0, c.size() - CS + 1, CS):
		if c[i] == uid:
			return [c[i + 2], c[i + 4], c[i + 3]]
	return []


## Takes carried item `uid` and what is inside it out of the snapshot (CDDA took it off, or it was dropped).
func _remove_rows(uid: int) -> void:
	var gone := {uid: true}
	var keep := PackedInt64Array()
	var c := _snap.carried
	for i in range(0, c.size() - CS + 1, CS):
		if gone.has(c[i]) or gone.has(c[i + 2]):
			gone[c[i]] = true
			continue
		keep.append_array(c.slice(i, i + CS))
	_snap.carried = keep
	_snap.seq += 1
	_mock.changed.emit(_snap)


func _head() -> Vector3:
	return _rig.camera.global_position


func _shoulder() -> Vector3:
	return _head() + Vector3(0.15, 0.05, 0.2)


## Over the floor of S, hand height.
func _over_floor() -> Vector3:
	return _world.coords.ms_center_to_world(S) + Vector3(-0.25, 0.3, 0.25)


func _clean() -> bool:
	return _world.hidden_items.is_empty() and _actions.pending_count() == 0 and _hands.proxy("vr_l") == null \
			and _hands.proxy("vr_r") == null and _hands.holding("vr_l").is_empty() and _hands.holding("vr_r").is_empty()


## The right hand takes the bag off over the shoulder and lets go of it in front.
func _open_in_front() -> void:
	_rig.right.global_position = _shoulder()
	_rig.press(_rig.right, "grip_click")
	_rig.right.global_position = _head() + Vector3(0.1, -0.45, -0.4)
	_rig.update_hands(0.016, true)
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)


## An item model drawn see-through (pending).
static func _dim(n: Node3D) -> bool:
	if n == null or n.get_child_count() == 0:
		return false
	for m in n.get_child(0).get_children():
		if m is GeometryInstance3D and is_equal_approx((m as GeometryInstance3D).transparency, VrPack.DIM):
			return true
	return false


static func _rows(n: int, first_uid: int, type: int, pocket: int) -> Array:
	var out := []
	for k in n:
		out.append({"uid": first_uid + k, "item": ItemRef.on_player(first_uid + k, type, BAG_L, pocket, 0, P),
				"name": "rock", "depth": 0, "pending": false})
	return out


func _test_layout() -> void:
	var rock: int = _it["rock"]
	var rows := _rows(40, 10, rock, 0)
	for r: Dictionary in rows:
		r["name"] = "rock\u0007" + "x".repeat(100)
	rows.append({"uid": 99, "item": ItemRef.on_player(99, rock, 10, 0, 0, P), "name": "inside", "depth": 1, "pending": false})
	rows.append("junk")
	var one := _rows(1, 200, rock, 1)
	one[0]["pending"] = true
	var col := {"title": "canvas sack", "cut": 5, "rows": 42, "groups": [
		{"key": 0, "title": "pocket 1", "rows": rows, "volume_ml": 3000},
		{"key": 1, "title": "pocket 2", "rows": one, "volume_ml": 10},
		"junk",
		{"key": "x", "title": "bad", "rows": one, "volume_ml": 5},
		{"key": 3, "title": 7, "rows": "nope", "volume_ml": -5}]}
	var lay := VrPack.layout(col)
	var cs: Array = lay["compartments"]
	var keys := cs.map(func(c: Dictionary) -> Variant: return c["key"])
	_check.call(keys == [0, 1, 3] and lay["more"] == 6 and lay["title"] == "canvas sack",
			"vr pack: one compartment per good pocket group, in order; bad groups skipped, their rows and the model's cut counted (%s, +%d)" % [keys, lay["more"]])
	var c0: Dictionary = cs[0]
	var c1: Dictionary = cs[1]
	var c2: Dictionary = cs[2]
	var ok := true
	var sum := 0.0
	for c: Dictionary in cs:
		var w: float = float(c["x1"]) - float(c["x0"])
		sum += w
		ok = ok and w >= VrPack.MIN_W - 0.0001 and w <= VrPack.MAX_W + 0.0001
		for e: Dictionary in c["items"]:
			var p: Vector3 = e["pos"]
			var n: String = e["name"]
			ok = ok and p.x >= float(c["x0"]) and p.x <= float(c["x1"]) and absf(p.y) <= VrPack.HEIGHT * 0.5 \
					and float(e["size"]) > 0.0 and float(e["size"]) <= VrPack.MAX_ITEM_M and n.length() <= VrPack.MAX_NAME \
					and not n.contains("\u0007")
	_check.call(ok and float(c0["x1"]) - float(c0["x0"]) > float(c1["x1"]) - float(c1["x0"])
			and float(c0["x1"]) <= float(c1["x0"]) and is_equal_approx(float(lay["width"]), sum + 2 * VrPack.GAP),
			"vr pack: compartments side by side, sized by volume share within bounds; items inside them, small, names short and clean")
	_check.call((c0["items"] as Array).size() == VrPack.MAX_PER_POCKET and c0["more"] == 40 - VrPack.MAX_PER_POCKET
			and (c1["items"] as Array).size() == 1 and (c1["items"] as Array)[0]["pending"] and (c2["items"] as Array).is_empty()
			and str(c0["title"]).begins_with("pocket 1") and str(c0["title"]).contains("L") and c2["title"] == "7",
			"vr pack: at most %d models per pocket, the rest '+N more'; nested rows not shown; pending kept; titles with the volume" % VrPack.MAX_PER_POCKET)
	var big := _rows(30, 300, rock, 0)
	var three := VrPack.layout({"title": "x", "groups": [{"key": 0, "rows": big}, {"key": 1, "rows": big}, {"key": 2, "rows": big}]})
	var shown := (three["compartments"] as Array).map(func(c: Dictionary) -> int: return (c["items"] as Array).size())
	var rest := (three["compartments"] as Array).map(func(c: Dictionary) -> int: return c["more"])
	var groups := []
	for k in 8:
		groups.append({"key": k, "rows": _rows(1, 400 + k, rock, k)})
	var many := VrPack.layout({"groups": groups})
	_check.call(shown == [24, 24, 12] and rest == [6, 6, 18] and (many["compartments"] as Array).size() == VrPack.MAX_POCKETS
			and many["more"] == 8 - VrPack.MAX_POCKETS, "vr pack: at most %d models in all and %d compartments (%s %s)" % [VrPack.MAX_SHOWN, VrPack.MAX_POCKETS, shown, rest])
	var empty := VrPack.layout({})
	var e0: Dictionary = (empty["compartments"] as Array)[0]
	_check.call((empty["compartments"] as Array).size() == 1 and e0["key"] == -1 and e0["title"] == VrPack.EMPTY_TITLE
			and (e0["items"] as Array).is_empty() and VrPack.layout({"cut": 1e30})["more"] == VrPack.MAX_COUNT
			and VrPack.layout({"cut": NAN})["more"] == 0 and VrPack.layout({"cut": "5", "groups": "x"})["more"] == 0,
			"vr pack: nothing listed: one compartment (CDDA picks the pocket); hostile counts bounded")
	var changed := col.duplicate(true)
	((changed["groups"] as Array)[1] as Dictionary)["rows"] = _rows(1, 200, rock, 1)
	_check.call(VrPack.signature(col) == VrPack.signature(col.duplicate(true)) and VrPack.signature(col) != VrPack.signature(changed),
			"vr pack: the layout signature changes with a row's pending state, not otherwise")


func _test_poses() -> void:
	var head := Transform3D(Basis(), Vector3(0, 1.6, 0))   # facing north (-Z)
	var a := VrPack.rest_pose(head, Vector3(0.1, 1.2, -0.4))
	var to_head := (head.origin - a.origin).normalized()
	_check.call(absf(Vector2(a.origin.x, a.origin.z).length() - VrPack.REST_M) < 0.001 and is_equal_approx(a.origin.y, 1.2)
			and a.origin.x > 0.0 and a.basis.z.dot(to_head) > 0.999 and a.basis.x.y == 0.0,
			"vr pack: let go in front: %.2f m out toward the hand, at its height, facing the head, level" % VrPack.REST_M)
	var behind := VrPack.rest_pose(head, Vector3(0, 1.2, 0.4))
	var low := VrPack.rest_pose(head, Vector3(0, 0.2, -0.4))
	var high := VrPack.rest_pose(head, Vector3(0, 2.5, -0.4))
	var odd := VrPack.rest_pose(head, Vector3(NAN, 1, 0))
	var down := VrPack.rest_pose(Transform3D(Basis.from_euler(Vector3(-PI / 2, 0, 0)), head.origin), Vector3.INF)
	var mid := 1.6 - (VrPack.REST_HIGH + VrPack.REST_LOW) * 0.5
	_check.call(behind.origin.is_equal_approx(Vector3(0, 1.2, -VrPack.REST_M)) and is_equal_approx(low.origin.y, 1.6 - VrPack.REST_LOW)
			and is_equal_approx(high.origin.y, 1.6 - VrPack.REST_HIGH) and odd.is_finite()
			and odd.origin.is_equal_approx(Vector3(0, mid, -VrPack.REST_M)) and down.origin.is_equal_approx(Vector3(0, mid, -VrPack.REST_M)),
			"vr pack: straight ahead when the hand is behind; chest to waist height; bad hand or looking down still finite")
	var hand := Transform3D(Basis(), Vector3(0.2, 1.0, -0.3))
	var hang := VrPack.hang_pose(hand)
	var tilted := VrPack.hang_pose(Transform3D(Basis.from_euler(Vector3(0.6, 0.4, 0.3)), hand.origin))
	_check.call((hang * VrPack.handle_local()).is_equal_approx(hand.origin) and hang.basis.z.is_equal_approx(Vector3.BACK)
			and (tilted * VrPack.handle_local()).is_equal_approx(hand.origin) and tilted.basis.y.is_equal_approx(Vector3.UP),
			"vr pack: carried, it hangs upright from the hand by its handle, its front toward the player")


## Grip over the shoulder with an empty hand: the biggest worn bag comes off into that hand (nothing sent); let go
## in front: it floats open there, facing the head, one compartment per pocket with a model per item.
func _test_open() -> void:
	var pack := _rig.pack
	var b := _rig.buzzes.duplicate()
	var seq := _snap.seq
	_rig.right.global_position = _shoulder()
	_rig.press(_rig.right, "grip_click")
	_check.call(pack.state == VrPack.State.HELD and pack.hand == 1 and pack.bag != null and pack.bag.uid == BAG_L
			and pack.visible and _hands.holding("vr_r").is_empty() and _rig.buzzes == b and _snap.seq == seq and _clean(),
			"vr pack: grip over the shoulder with an empty hand takes the biggest worn bag off (no CDDA action)")
	var front := _head() + Vector3(0.1, -0.45, -0.4)
	_rig.right.global_position = front
	_rig.update_hands(0.016, true)
	_check.call(pack.handle_point().is_equal_approx(front), "vr pack: ... it hangs from that hand")
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	var h := _head()
	var at := pack.global_position
	_check.call(pack.state == VrPack.State.OPEN and pack.hand == -1 and absf(Vector2(at.x - h.x, at.z - h.z).length() - VrPack.REST_M) < 0.001
			and is_equal_approx(at.y, front.y) and pack.global_basis.z.dot((h - at).normalized()) > 0.999,
			"vr pack: let go in front: it floats open there, facing the head")
	var keys := pack.comps.map(func(c: Dictionary) -> Variant: return c["key"])
	var uids := pack.items.map(func(e: Dictionary) -> Variant: return e["uid"])
	var where := pack.items.map(func(e: Dictionary) -> Variant: return e["comp"])
	_check.call(keys == [0, 2] and str(pack.comps[0]["title"]).begins_with("pocket 1")
			and str(pack.comps[1]["title"]).begins_with("pocket 3") and float(pack.comps[0]["x1"]) < float(pack.comps[1]["x0"]),
			"vr pack: a compartment per pocket, in pocket order (%s)" % [keys])
	var models := true
	for e: Dictionary in pack.items:
		var n: Node3D = e["node"]
		models = models and n != null and n.get_child_count() > 0 and n.get_child(0).scale.x <= VrPack.MAX_ITEM_M + 0.0001 \
				and not _dim(n)
	_check.call(uids == [ROCK, HAMMER, PLANK] and where == [0, 0, 1] and models and pack.more == 0
			and pack.item_point(ROCK).is_finite() and pack.item_point(12345) == Vector3.INF,
			"vr pack: a small model per item in its pocket's compartment (%s)" % [uids])


## No new layout while nothing changes; a new snapshot with the same rows is read but keeps the layout.
func _test_no_rebuild() -> void:
	var pack := _rig.pack
	var b := pack.builds
	var s := pack.scans
	for k in 5:
		_rig.update_hands(0.016, true)
	_check.call(pack.builds == b and pack.scans == s, "vr pack: nothing changed: not read again, no new layout")
	_snap.seq += 1
	_mock.changed.emit(_snap)
	_rig.update_hands(0.016, true)
	_check.call(pack.scans == s + 1 and pack.builds == b, "vr pack: a new snapshot with the same rows: same layout kept")


## A free hand on an item in the pack outlines it and takes its copy (carried, nothing sent); let go over the floor:
## dropped there, and the pack lays out without it.
func _test_take_out() -> void:
	var pack := _rig.pack
	_rig.left.global_position = pack.item_point(ROCK)
	_rig.update_hands(0.016, true)
	var hv := pack.hovered(0)
	_check.call(hv.get("kind") == "item" and hv.get("uid") == ROCK and pack.outlines[0] != null and pack.outlines[0].visible
			and _hands.hand("vr_l").hover.is_empty(), "vr pack: a free hand on an item in the pack outlines it")
	var seq := _snap.seq
	_rig.press(_rig.left, "grip_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_rig.update_hands(0.016, true)
	_check.call(l != null and l.uid == ROCK and l.carried and _hands.proxy("vr_l") != null and not pack.item_node(ROCK).visible
			and _snap.seq == seq and not pack.outlines[0].visible, "vr pack: grip takes it into the hand (nothing sent); its model in the pack hides")
	_rig.left.global_position = _over_floor()
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	_check.call(_row(ROCK).is_empty() and _handle(S, _it["rock"]) == ROCK and pack.item_node(ROCK) == null
			and pack.items.size() == 2 and _clean(), "vr pack: let go over the floor: dropped there; the pack lays out without it")


## An item taken from the world, let go over the pocket-2 compartment: into that pocket.
func _test_put_in() -> void:
	var pack := _rig.pack
	var hammer := _handle(E, _it["hammer"])
	_rig.right.global_position = _mid(hammer)
	_rig.press(_rig.right, "grip_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	_check.call(r != null and r.uid == hammer and r.is_wielded(), "vr pack: (the right hand takes the hammer lying east)")
	var k := pack.compartment_index(2)
	_rig.right.global_position = pack.compartment_point(k)
	_rig.update_hands(0.016, true)
	_check.call(k == 1 and pack.lit(1) == k and pack.hovered(1).is_empty(), "vr pack: a held item over a compartment lights it")
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	var row := _row(hammer)
	var in_k := pack.items.any(func(e: Dictionary) -> bool: return e["uid"] == hammer and e["comp"] == k)
	_check.call(not row.is_empty() and row[0] == BAG_L and row[2] == 2 and (int(row[1]) & Snapshot.CARRIED_WIELDED) == 0
			and in_k and pack.lit(1) == -1 and _clean(), "vr pack: let go over it: into that pocket (%s)" % [row])


## Taken out and let go over its own pocket: back, nothing sent.
func _test_same_pocket() -> void:
	var pack := _rig.pack
	var seq := _snap.seq
	var b := pack.builds
	_rig.left.global_position = pack.item_point(PLANK)
	_rig.press(_rig.left, "grip_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_rig.left.global_position = pack.compartment_point(pack.compartment_index(2))
	_rig.update_hands(0.016, true)
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	var row := _row(PLANK)
	_check.call(l != null and l.uid == PLANK and _snap.seq == seq and row[0] == BAG_L and row[2] == 2
			and pack.item_node(PLANK).visible and pack.builds == b and _clean(), "vr pack: back into its own pocket: nothing sent")


## An action in flight: its model dims and can't be gripped; done: back to normal.
func _test_pending() -> void:
	var pack := _rig.pack
	_actions.backend = Silent.new()
	_rig.left.global_position = pack.item_point(PLANK)
	_rig.press(_rig.left, "grip_click")
	_rig.left.global_position = pack.compartment_point(pack.compartment_index(0))
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	var n := pack.item_node(PLANK)
	_check.call(_actions.pending(PLANK) == "put" and n != null and n.visible and _dim(n)
			and pack.target_at(pack.item_point(PLANK)).get("uid") != PLANK, "vr pack: a row in flight is dimmed and can't be gripped")
	_actions.clear()
	_actions.backend = _mock
	_rig.update_hands(0.016, true)
	_check.call(not _dim(pack.item_node(PLANK)) and _clean(), "vr pack: ... and back to normal when it is over")


## A put CDDA refuses (a stand-in: the worn garbage bag held and let go over a compartment): a buzz, CDDA's reason
## by the hand, the hand empty, the pack still open.
func _test_refused() -> void:
	var pack := _rig.pack
	var b := _rig.buzzes[1]
	_rig.right.global_position = pack.compartment_point(pack.compartment_index(0))
	var held := _hands.adopt("vr_r", ItemRef.on_player(BAG_S, _it["bag_garbage"], 0, -1, Snapshot.CARRIED_WORN, P))
	_rig.update_hands(0.016, true)
	_rig.release(_rig.right, "grip_click")
	var row := _row(BAG_S)
	var note := _rig.notes[1]
	_check.call(held and _rig.buzzes[1] == b + 1 and note != null and note.visible and note.text.begins_with("Take off")
			and not row.is_empty() and row[0] == 0 and (int(row[1]) & Snapshot.CARRIED_WORN) != 0 and pack.is_open() and _clean(),
			"vr pack: a refused put-in: a buzz and CDDA's reason by the hand, nothing moved")


## Gripped by its handle and let go over the shoulder: closed. Again with the trigger on its frame (no stairs).
func _test_close() -> void:
	var pack := _rig.pack
	_rig.right.global_position = pack.handle_point()
	_rig.update_hands(0.016, true)
	_check.call(pack.hovered(1).get("kind") == "frame" and pack.outlines[1].visible, "vr pack: a free hand on the handle outlines it")
	_rig.press(_rig.right, "grip_click")
	_check.call(pack.state == VrPack.State.HELD and pack.hand == 1 and _hands.holding("vr_r").is_empty(),
			"vr pack: grip on the handle: the hand holds the pack")
	_rig.right.global_position = _shoulder()
	_rig.update_hands(0.016, true)
	_rig.release(_rig.right, "grip_click")
	_check.call(pack.state == VrPack.State.CLOSED and not pack.visible and _closed.back() == "put back" and pack.items.is_empty()
			and pack.bag == null and _clean(), "vr pack: let go over the shoulder: closed and hidden")
	_open_in_front()
	var stairs := [0]
	_rig.stair_used.connect(func(_s: Dictionary) -> void: stairs[0] += 1)
	var b := _rig.buzzes[1]
	_rig.right.global_position = pack.handle_point()
	_rig.press(_rig.right, "trigger_click")
	_check.call(not pack.is_open() and _closed.back() == "closed" and stairs[0] == 0 and _rig.buzzes[1] == b,
			"vr pack: the trigger on its frame closes it (the stairs trigger isn't used)")


## Walking, teleporting or turning with it open: it stays where it was; farther than CLOSE_M: it closes.
func _test_far() -> void:
	var pack := _rig.pack
	_open_in_front()
	var at := pack.global_transform
	_rig.teleport_to(_head() + Vector3(0.5, 0, 0))
	_rig.turn_by(PI / 2)
	_rig.update_hands(0.016, true)
	_check.call(pack.is_open() and pack.global_transform.is_equal_approx(at), "vr pack: moving or turning with it open: it stays where it was")
	_rig.teleport_to(_head() + Vector3(2.0, 0, 0))
	_rig.update_hands(0.016, true)
	_check.call(not pack.is_open() and _closed.back() == "far" and not pack.visible, "vr pack: more than %.1f m away: it closes" % VrPack.CLOSE_M)
	_rig.turn_by(-PI / 2)
	_rig.go_to_square(P)


## The hands freed under an open pack: it closes cleanly.
func _test_freed(root: Node) -> void:
	var h2 := Hands.new(_world, _actions)
	var p2 := VrPack.new()
	p2.head = _rig.camera
	root.add_child(p2)
	p2.hands = h2
	var opened := p2.open_in(0, ItemRef.on_player(BAG_L, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN, P))
	var put := p2.let_go(false, _head() + Vector3(0, -0.4, -0.4))
	var shown := p2.items.size()
	h2.free()
	p2.update()
	_check.call(opened and put == "open" and shown == 3 and not p2.is_open() and not p2.visible and p2.items.is_empty()
			and p2.target_at(_head()).is_empty(), "vr pack: hands freed under an open pack: it closes cleanly")
	p2.free()


## The bag gone from the snapshot while open: it closes. Nothing worn: grip over the shoulder only buzzes (it
## doesn't pick up the wielded item instead).
func _test_gone() -> void:
	var pack := _rig.pack
	_open_in_front()
	var was := pack.is_open()
	_remove_rows(BAG_L)
	_rig.update_hands(0.016, true)
	_check.call(was and not pack.is_open() and _closed.back() == "gone" and not pack.visible and pack.items.is_empty(),
			"vr pack: the bag gone from the snapshot: it closes")
	_remove_rows(BAG_S)
	var rock := _handle(E, _it["rock"])
	_rig.right.global_position = _mid(rock)
	_rig.press(_rig.right, "grip_click")
	_rig.right.global_position = _world.coords.ms_center_to_world(FAR) + Vector3(0, 0.3, 0)
	_rig.release(_rig.right, "grip_click")
	var row := _row(rock)
	var b := _rig.buzzes[1]
	_rig.right.global_position = _shoulder()
	_rig.press(_rig.right, "grip_click")
	_check.call(not row.is_empty() and (int(row[1]) & Snapshot.CARRIED_WIELDED) != 0 and _rig.buzzes[1] == b + 1
			and not pack.is_open() and _clean(), "vr pack: nothing worn: grip over the shoulder buzzes")
	_rig.release(_rig.right, "grip_click")
