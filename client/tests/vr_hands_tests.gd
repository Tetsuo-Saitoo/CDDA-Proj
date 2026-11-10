extends RefCounted
## Block L2: the VR controllers as hands of the shared Hands layer (VrRig: "vr_l" / "vr_r") on the mock town, with
## MockItems answering inside each call: grip takes into CDDA's main / off hand by controller (and left-handed),
## letting go drops where the hand is or, over the shoulder, into the biggest worn container; nowhere it can go
## keeps it in CDDA's hand; a refusal buzzes and shows CDDA's reason by the hand; grip on nothing picks up what
## CDDA holds; toggle grip; VrHeld hidden under a copy; weight lag and two-handed carrying; the statics.
## No XR runtime: controllers are inactive, the test moves them and presses buttons. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const SE := P + Vector3i(1, 1, 0)      # pile: canvas sack
const S := P + Vector3i(0, 1, 0)       # bare floor
const FAR := P + Vector3i(5, 0, 0)     # out of reach
const BAG_S := 900                     # worn garbage bag (42 ml)
const BAG_L := 901                     # worn canvas sack (1000 ml)

var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr hands")
	for id: String in ["rock", "hammer", "2x4", "bag_canvas", "bag_garbage"]:
		_it[id] = tables.index_of("itype", id)
	_test_statics(tables)
	if not _setup(root, data, tables):
		return
	_test_menu()
	_test_take_by_hand()
	_test_left_handed()
	_test_refused()
	_test_adopt_and_held()
	_test_toggle()
	_test_two_hands()
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
			sm["items"] = [[1, 3, [_it["rock"], _it["hammer"], _it["2x4"]]], [13, 1, [_it["bag_canvas"]]]]
		elif at in [Vector3i(15, 32, 0), Vector3i(15, 31, 0), Vector3i(16, 31, 0)]:
			sm["items"] = []
		else:
			continue
		sm.erase("handles")
	var player: Dictionary = d["player"]
	player["items"] = [[BAG_S, _it["bag_garbage"], 0, -1, Snapshot.CARRIED_WORN],
			[BAG_L, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN]]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "vr hands: test town loads " + _snap.error)
	if not _snap.is_valid():
		return false
	var mock := MockItems.new(_snap, tables)
	mock.seed()
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
	mock.message.connect(func(t: String) -> void: _actions.on_events([MockItems.message_event(t)]))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_rig.hands = _hands
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_rig.go_to_square(P)
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


func _mid(uid: int) -> Vector3:
	var s := _world.item_slot(uid)
	return s[3] if not s.is_empty() else Vector3.INF


## [parent, flags] of carried item `uid`, [] when it isn't carried.
func _row(uid: int) -> Array:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i] == uid:
			return [c[i + 2], c[i + 4]]
	return []


## Where hand `id`'s copy of its item is held (its grip point, world), INF without one.
func _grip_point(id: String) -> Vector3:
	var p := _hands.proxy(id)
	var it: ItemRef = _hands.holding(id).get("item")
	if p == null or it == null:
		return Vector3.INF
	return p.global_transform * (ItemVisual.grip(it.type, _world).origin / p.scale.x)


func _head() -> Vector3:
	return _rig.camera.global_position


## Over the floor of S, hand height.
func _over_floor(off := Vector3(-0.25, 0.3, 0.25)) -> Vector3:
	return _world.coords.ms_center_to_world(S) + off


func _clean() -> bool:
	return _world.hidden_items.is_empty() and _actions.pending_count() == 0 and _hands.proxy("vr_l") == null \
			and _hands.proxy("vr_r") == null and _hands.holding("vr_l").is_empty() and _hands.holding("vr_r").is_empty()


func _test_statics(tables: IdTables) -> void:
	var head := Transform3D(Basis(), Vector3(0, 1.6, 0))   # facing north (-Z)
	_check.call(VrRig.over_shoulder(head, Vector3(0.15, 1.5, 0.15)) and VrRig.over_shoulder(head, Vector3(-0.1, 1.9, 0.05))
			and not VrRig.over_shoulder(head, Vector3(0.15, 1.5, -0.15)) and not VrRig.over_shoulder(head, Vector3(0.15, 1.2, 0.2))
			and not VrRig.over_shoulder(head, Vector3(NAN, 1.5, 0.2)), "vr hands: over the shoulder = high and behind the head")
	var turned := Transform3D(Basis(Vector3.UP, PI), head.origin)
	var down := Transform3D(Basis.from_euler(Vector3(-PI / 2, 0, 0)), head.origin)
	var up := Transform3D(Basis.from_euler(Vector3(PI / 2, 0, 0)), head.origin)
	_check.call(VrRig.over_shoulder(turned, Vector3(0.15, 1.5, -0.15)) and not VrRig.over_shoulder(turned, Vector3(0.15, 1.5, 0.15))
			and VrRig.over_shoulder(down, Vector3(0, 1.5, 0.15)) and not VrRig.over_shoulder(down, Vector3(0, 1.5, -0.15))
			and VrRig.over_shoulder(up, Vector3(0, 1.5, 0.15)), "vr hands: behind follows the head's turn, looking down or up too")
	var small := ItemRef.on_player(BAG_S, _it["bag_garbage"], 0, -1, Snapshot.CARRIED_WORN, P)
	var large := ItemRef.on_player(BAG_L, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN, P)
	var worn: Array[ItemRef] = [small, large]
	var none: Array[ItemRef] = []
	_check.call(VrRig.shoulder_bag(worn, null, tables) == large and VrRig.shoulder_bag(worn, large, tables) == small
			and VrRig.shoulder_bag(none, null, tables) == null, "vr hands: over the shoulder: the biggest worn container but the item")
	var plank := VrRig.follow_rate(2440, 8, false)
	_check.call(VrRig.follow_rate(600, 8, false) == INF and is_finite(plank) and VrRig.follow_rate(3500, 8, false) < plank
			and VrRig.follow_rate(2440, 8, true) < plank and VrRig.follow_rate(2440, 16, false) > plank
			and VrRig.follow_rate(30000, 8, true) >= VrRig.MIN_RATE and VrRig.follow_rate(-5, 8, false) == INF,
			"vr hands: light items follow at once, heavier ones slower, two-handed in one hand slowest (%.1f/s)" % plank)
	var a := Transform3D(Basis(), Vector3(0, 1, 0))
	var b := Transform3D(Basis(Vector3.UP, 0.5), Vector3(0.4, 1, 0))
	var half := VrRig.ease_toward(a, b, 5.0, 0.1, Vector3.ONE)
	var k := 1.0 - exp(-0.5)
	_check.call(VrRig.ease_toward(a, b, INF, 0.016, Vector3.ONE) == b and VrRig.ease_toward(a, b, 5.0, 0.0, Vector3.ONE).is_equal_approx(a)
			and half.origin.is_equal_approx(Vector3(0.4 * k, 1, 0)) and is_equal_approx(half.basis.get_euler().y, 0.5 * k)
			and VrRig.ease_toward(Transform3D(Basis(), Vector3(5, 1, 0)), b, 1.0, 0.016, Vector3.ONE) == b
			and VrRig.ease_toward(a, b, 5.0, 0.1, Vector3.ONE * 2.0).basis.get_scale().is_equal_approx(Vector3.ONE * 2.0),
			"vr hands: easing toward the hand (at once when light or far behind, keeps the item's scale)")
	var hand := Transform3D(Basis(), Vector3(0, 1, 0))
	var held := Transform3D(Basis(), Vector3(0, 1, -0.5))   # 0.5 m in front of the hand
	var sagged := VrRig.sag(held, hand, 0.4)
	_check.call(sagged.origin.y < 1.0 - 0.15 and (-sagged.basis.z).y < -0.3 and absf(sagged.origin.x) < 0.001
			and VrRig.sag(held, Transform3D(Basis.from_euler(Vector3(-PI / 2, 0, 0)), hand.origin), 0.4).origin.is_equal_approx(
			held.origin - Vector3(0, VrRig.SAG_DROP, 0)), "vr hands: a heavy item in one hand tips down and hangs lower")
	var two := VrRig.two_hand_pose(Vector3(0.3, 1, 0), Vector3(-0.3, 1, 0), Vector3.UP, Transform3D.IDENTITY, Vector3.ONE)
	var g := Transform3D(Basis(), Vector3(0, 0.1, 0))
	var two_g := VrRig.two_hand_pose(Vector3(0, 1, -0.3), Vector3(0, 1, 0.3), Vector3.UP, g, Vector3.ONE * 2.0)
	var odd := VrRig.two_hand_pose(Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3.UP, g, Vector3.ONE)
	var odd2 := VrRig.two_hand_pose(Vector3(0, 1.3, 0), Vector3(0, 1, 0), Vector3.UP, g, Vector3.ONE)
	_check.call(two.origin.is_equal_approx(Vector3(0, 1, 0)) and (-two.basis.z).is_equal_approx(Vector3.RIGHT)
			and two.basis.y.is_equal_approx(Vector3.UP)
			and (two_g.origin + two_g.basis.orthonormalized() * g.origin).is_equal_approx(Vector3(0, 1, 0))
			and two_g.basis.get_scale().is_equal_approx(Vector3.ONE * 2.0) and odd.is_finite() and odd2.is_finite()
			and (-odd2.basis.z).is_equal_approx(Vector3.UP), "vr hands: a two-handed item between the hands, off hand to main hand")
	_check.call(VrSettings.clean("grip", "toggle") == "toggle" and VrSettings.clean("grip", "both") == null
			and VrSettings.from_args({"vr-grip": "toggle"})["grip"] == "toggle" and VrSettings.from_args({"vr-grip": "x"})["grip"] == "hold"
			and VrSettings.DEFAULTS["grip"] == "hold" and VrSettings.label("grip", "toggle").begins_with("press")
			and VrSettings.ROWS.any(func(r: Array) -> bool: return r[0] == "grip"), "vr hands: grip setting (hold / toggle), option and menu row")


## The menu open: no outline, the grip grabs nothing.
func _test_menu() -> void:
	var rock := _handle(E, _it["rock"])
	_rig.press(_rig.left, "menu_button")
	_rig.right.global_position = _mid(rock)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.right, "grip_click")
	_check.call(_rig.menu_open() and _hands.hand("vr_r").hover.is_empty() and _hands.holding("vr_r").is_empty(),
			"vr hands: with the menu open, no outline and the grip grabs nothing")
	_rig.release(_rig.right, "grip_click")
	_rig.press(_rig.left, "menu_button")
	_rig.update_hands(0.016, true)
	_check.call(not _rig.menu_open() and _uid(_hands.hand("vr_r").hover) == rock, "vr hands: menu closed: the item is outlined again")


## Right (main) grips the rock, left (off) the hammer: taken into those hands at once. The rock follows at once
## (light); left lets go over the floor (dropped there), right over the shoulder (into the bigger worn container).
func _test_take_by_hand() -> void:
	var rock := _handle(E, _it["rock"])
	var hammer := _handle(E, _it["hammer"])
	_rig.right.global_position = _mid(rock)
	_rig.left.global_position = _mid(hammer)
	_rig.update_hands(0.016, true)
	_check.call(_uid(_hands.hand("vr_r").hover) == rock and _uid(_hands.hand("vr_l").hover) == hammer,
			"vr hands: each hand outlines the item it touches")
	_rig.press(_rig.right, "grip_click")
	_rig.left.global_position = _mid(hammer)   # the pile is laid out again without the rock
	_rig.press(_rig.left, "grip_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_check.call(r != null and r.uid == rock and r.is_wielded() and l != null and l.uid == hammer and l.is_off_hand()
			and _hands.proxy("vr_r") != null and _hands.proxy("vr_l") != null and _rig.buzzes[0] == 0 and _rig.buzzes[1] == 0,
			"vr hands: grip takes into CDDA's main hand (main controller) and off hand (the other) at once")
	_rig.right.global_position += Vector3(0.1, 0.25, 0.0)
	_rig.update_hands(0.016, true)
	_check.call(_grip_point("vr_r").distance_to(_rig.right.global_position) < 0.001, "vr hands: a light item follows the hand at once")
	_rig.left.global_position = _over_floor()
	_rig.release(_rig.left, "grip_click")
	_check.call(_hands.holding("vr_l").is_empty() and _row(hammer).is_empty() and _handle(S, _it["hammer"]) == hammer,
			"vr hands: let go over the floor: dropped there")
	_rig.right.global_position = _head() + Vector3(0.15, 0.05, 0.2)
	_check.call(VrRig.over_shoulder(_rig.camera.global_transform, _rig.right.global_position), "vr hands: (the hand is over the shoulder)")
	_rig.release(_rig.right, "grip_click")
	var row := _row(rock)
	_check.call(_hands.holding("vr_r").is_empty() and not row.is_empty() and row[0] == BAG_L
			and (int(row[1]) & Snapshot.CARRIED_WIELDED) == 0 and _clean(),
			"vr hands: let go over the shoulder: into the biggest worn container (%s)" % [row])


## Left-handed: the left controller takes into the main hand.
func _test_left_handed() -> void:
	var hammer := _handle(S, _it["hammer"])
	_rig.settings["main_hand"] = "left"
	_rig.left.global_position = _mid(hammer)
	_rig.press(_rig.left, "grip_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_check.call(l != null and l.uid == hammer and l.is_wielded(), "vr hands: left-handed: the left grip takes into the main hand")
	_rig.left.global_position = _head() + Vector3(-0.15, 0.05, 0.2)
	_rig.release(_rig.left, "grip_click")
	var row := _row(hammer)
	_check.call(not row.is_empty() and row[0] == BAG_L and _clean(), "vr hands: ... and over the left shoulder into the bag")
	_rig.settings["main_hand"] = "right"


## Nowhere it can go keeps an item in CDDA's hand; a take into the full main hand is refused: a buzz, CDDA's reason
## by that hand for a while, the hand empty, the item where it was.
func _test_refused() -> void:
	var plank := _handle(E, _it["2x4"])
	var bag := _handle(SE, _it["bag_canvas"])
	_rig.right.global_position = _mid(plank)
	_rig.press(_rig.right, "grip_click")
	_rig.right.global_position = _world.coords.ms_center_to_world(FAR) + Vector3(0, 0.3, 0)
	_rig.release(_rig.right, "grip_click")
	var row := _row(plank)
	_check.call(not row.is_empty() and (int(row[1]) & Snapshot.CARRIED_WIELDED) != 0 and _clean(),
			"vr hands: let go where it can't go: it stays in CDDA's main hand")
	var buzz := _rig.buzzes[1]
	_rig.right.global_position = _mid(bag)
	_rig.press(_rig.right, "grip_click")
	var note := _rig.notes[1]
	_check.call(_rig.buzzes[1] == buzz + 1 and note != null and note.visible and note.text.begins_with("Your hand is full")
			and _handle(SE, _it["bag_canvas"]) == bag and _clean(), "vr hands: refused take: a buzz, CDDA's reason by the hand, the hand empty")
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(VrRig.NOTE_S * 0.5, true)
	var still := note.visible
	_rig.update_hands(VrRig.NOTE_S * 0.6, true)
	_check.call(still and not note.visible, "vr hands: the reason goes after a few seconds")
	var b := _rig.buzzes.duplicate()
	_hands.refused.emit("vr_l", {}, "  " + "x".repeat(500) + "\n")
	_hands.refused.emit("mouse", {}, "not for VR")
	_check.call(_rig.notes[0].text.length() == VrRig.NOTE_MAX and _rig.buzzes[0] == b[0] + 1 and _rig.buzzes[1] == b[1],
			"vr hands: a long reason is cut; the mouse's refusals don't buzz VR")
	var main_i := 0 if _rig.main_ctrl() == _rig.left else 1
	var b2 := _rig.buzzes.duplicate()
	_rig.refused_here("stairs: wait for the last move to finish")
	_check.call(_rig.buzzes[main_i] == b2[main_i] + 1 and _rig.buzzes[1 - main_i] == b2[1 - main_i]
			and _rig.notes[main_i].visible and _rig.notes[main_i].text.begins_with("stairs:"),
			"vr hands: a refused stair use buzzes the main hand and says why there")


## Grip on nothing picks up what CDDA wields (shown on the hand by VrHeld, hidden while the hand holds its copy);
## a heavy item lags behind the hand; the empty off hand only buzzes.
func _test_adopt_and_held() -> void:
	var plank := _handle_carried(_it["2x4"])
	_rig.show_held({"main": {"name": "plank"}, "off": {}})
	_check.call(_rig.right_held.visible and not _rig.left_held.visible, "vr hands: CDDA's wielded item shows on the main hand")
	_rig.right.global_position = _world.coords.ms_center_to_world(P) + Vector3(0, 1.2, 0)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.right, "grip_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	_rig.update_hands(0.016, true)
	_check.call(r != null and r.uid == plank and r.carried and _hands.proxy("vr_r") != null and not _rig.right_held.visible,
			"vr hands: grip on nothing picks up the wielded item; its label hides while the hand holds it")
	var buzz := _rig.buzzes[0]
	_rig.left.global_position = _rig.right.global_position + Vector3(-0.5, 0, 0)
	_rig.press(_rig.left, "grip_click")
	_rig.release(_rig.left, "grip_click")
	_check.call(_rig.buzzes[0] == buzz + 1 and _hands.holding("vr_l").is_empty(), "vr hands: nothing in the off hand: a buzz")
	_rig.right.global_position += Vector3(0.3, 0, 0)
	_rig.update_hands(0.016, true)
	var lag := _grip_point("vr_r").distance_to(_rig.right.global_position)
	for i in 5:
		_rig.update_hands(1.0, true)
	var lag2 := _grip_point("vr_r").distance_to(_rig.right.global_position)
	_check.call(lag > 0.1 and lag < 0.45 and lag2 < 0.01, "vr hands: a heavy item lags behind the hand, then catches up (%.3f, %.3f)" % [lag, lag2])
	_rig.right.global_position = _over_floor()
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	_check.call(_row(plank).is_empty() and _handle(S, _it["2x4"]) == plank and _clean() and _rig.right_held.visible,
			"vr hands: put down on the floor; the hand's label is back")
	_rig.show_held({"main": {}, "off": {}})


## Uid of the first carried item of `type`, -1 if none.
func _handle_carried(type: int) -> int:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i + 1] == type:
			return c[i]
	return -1


## Toggle grip: one press takes, letting the button go keeps it, the next press lets go.
func _test_toggle() -> void:
	var plank := _handle(S, _it["2x4"])
	_rig.settings["grip"] = "toggle"
	_rig.left.global_position = _mid(plank)
	_rig.press(_rig.left, "grip_click")
	_rig.release(_rig.left, "grip_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_check.call(l != null and l.uid == plank and l.is_off_hand() and _hands.proxy("vr_l") != null,
			"vr hands: toggle grip: the button let go, the hand still holds it")
	_rig.left.global_position = _over_floor(Vector3(0.2, 0.3, -0.2))
	_rig.press(_rig.left, "grip_click")
	_check.call(_hands.holding("vr_l").is_empty() and _handle(S, _it["2x4"]) == plank and _clean(),
			"vr hands: toggle grip: the next press lets go (dropped)")
	_rig.release(_rig.left, "grip_click")
	_rig.settings["grip"] = "hold"


## A two-handed item (the plank with strength 3): in one hand it sags and lags; the other hand gripping near it
## holds it too (between the hands, no lag, nothing grabbed, no buzz); letting that hand go: one hand again.
func _test_two_hands() -> void:
	var plank := _handle(S, _it["2x4"])
	_rig.strength = 3
	_rig.right.global_position = _mid(plank)
	_rig.press(_rig.right, "grip_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	_check.call(r != null and r.uid == plank and r.two_handed(_world.tables, _rig.strength), "vr hands: a two-handed item in one hand")
	for i in 10:
		_rig.update_hands(1.0, true)
	var hand := _rig.right.global_position
	var drop := hand.y - _grip_point("vr_r").y
	_check.call(drop > 0.04 and drop < 0.08, "vr hands: ... it sags (%.3f m)" % drop)
	var buzz := _rig.buzzes[0]
	_rig.left.global_position = hand + Vector3(0.25, 0, 0)
	_rig.press(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	var p := _hands.proxy("vr_r")
	var want := VrRig.two_hand_pose(hand, _rig.left.global_position, _rig.right.global_basis.y,
			ItemVisual.grip(r.type, _world), p.scale)
	_check.call(_hands.holding("vr_l").is_empty() and _rig.buzzes[0] == buzz and p.global_transform.is_equal_approx(want)
			and _grip_point("vr_r").is_equal_approx((hand + _rig.left.global_position) * 0.5),
			"vr hands: the other hand grips it too: it sits between both hands")
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	_check.call(_grip_point("vr_r").distance_to(hand) > 0.05 and _hands.holding("vr_l").is_empty(),
			"vr hands: one hand again: it lags back toward that hand")
	_rig.right.global_position = _over_floor()
	_rig.release(_rig.right, "grip_click")
	_check.call(_handle(S, _it["2x4"]) == plank and _clean(), "vr hands: put down")
	_rig.strength = VrRig.STRENGTH
