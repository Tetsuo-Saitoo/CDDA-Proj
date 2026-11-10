extends RefCounted
## Blocks E6 / L2 / L8: Hands (targets, outline, holding, letting go, the take-then-drop move, refusals) and the
## mouse's item flows in GrabController (hover line, E takes, hold LMB carries, wheel, Esc), on the mock town with
## MockItems answering inside each call. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer
const NO_SQ := Vector3i(-1073741824, 0, 0)
const SE := P + Vector3i(1, 1, 0)      # pile: canvas bag
const S := P + Vector3i(0, 1, 0)       # bare floor
const FAR := P + Vector3i(5, 0, 0)     # pile: rock, out of reach

var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _seen: Array = []   # ["confirmed" | "refused" | "lit", hand, uid (-1 none), reason]


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("hands")
	for id: String in ["rock", "hammer", "bag_canvas"]:
		_it[id] = tables.index_of("itype", id)
	InputActions.ensure(false)
	if not _setup(root, data, tables):
		return
	_test_targets()
	_test_carry_to_floor()
	_test_take_and_put()
	_test_vr_refused()
	_test_cancel()
	_test_mouse(root)
	_test_move()
	_test_door_names()
	_test_freed_leaf()
	_test_flick(root)   # last: throws the bag away
	_hands.free()
	_actions.free()
	_world.free()


func _setup(root: Node, data: Variant, tables: IdTables) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[1, 2, [_it["rock"], _it["hammer"]]], [13, 1, [_it["bag_canvas"]]], [5, 1, [_it["rock"]]]]
		elif at != Vector3i(15, 32, 0):
			continue
		else:
			sm["items"] = []
		sm.erase("handles")
	var player: Dictionary = d["player"]
	player["items"] = []
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "hands: test town loads " + _snap.error)
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
	_hands.confirmed.connect(func(h: String, t: Dictionary) -> void: _seen.append(["confirmed", h, _uid(t), ""]))
	_hands.refused.connect(func(h: String, t: Dictionary, why: String) -> void: _seen.append(["refused", h, _uid(t), why]))
	_hands.highlighted.connect(func(h: String, t: Dictionary) -> void: _seen.append(["lit", h, _uid(t), ""]))
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


## The handle row [tile, uid, type, spot x, spot y] of `uid` on square p, [] if none.
func _handle_row(p: Vector3i, uid: int) -> Array:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 1] == uid:
			return Array(h.slice(i, i + Snapshot.HANDLE_STRIDE))
	return []


func _mid(uid: int) -> Vector3:
	var s := _world.item_slot(uid)
	return s[3] if not s.is_empty() else Vector3.INF


func _carried(uid: int) -> bool:
	return _hands.picker.carried().any(func(r: ItemRef) -> bool: return r.uid == uid)


func _test_targets() -> void:
	var bag := _handle(SE, _it["bag_canvas"])
	var t := _hands.find_near(_mid(bag))
	_check.call(_uid(t) == bag and t["kind"] == "item" and t["square"] == SE and not str(t["name"]).is_empty(),
			"hands: a hand at an item finds it (%s)" % t.get("name", ""))
	var eye := _world.coords.ms_center_to_world(P) + Vector3(0, 1.6, 0)
	var r := _hands.find_on_ray(eye, _mid(bag) - eye)
	_check.call(_uid(r) == bag, "hands: the crosshair ray finds it")
	var far := _handle(FAR, _it["rock"])
	_check.call(far > 0 and _hands.find_near(_mid(far)).is_empty(),
			"hands: nothing out of reach")
	_seen.clear()
	_hands.hover("mouse", t)
	var outline: MeshInstance3D = _world.get_node_or_null("ItemOutline_mouse")
	_check.call(_seen == [["lit", "mouse", bag, ""]] and outline != null and outline.visible
			and outline.global_position.distance_to(_mid(bag)) < 0.001, "hands: hover outlines the item around its middle")
	_hands.hover("mouse", _hands.find_near(_mid(bag)))
	_check.call(_seen.size() == 1, "hands: the same item again: no new highlight")
	_hands.hover("mouse", {})
	_check.call(_seen[-1] == ["lit", "mouse", -1, ""] and not outline.visible, "hands: nothing under it: outline off")


## Mouse: grab the rock on E, carry it, let go over the floor south: taken into the main hand, then dropped there
## at the spot the ray met.
func _test_carry_to_floor() -> void:
	var rock := _handle(E, _it["rock"])
	var t := _hands.find_near(_mid(rock), 0.05)
	var drawn := _world.item_slot(rock)
	_check.call(_uid(t) == rock and _hands.grab("mouse", t), "hands: grab an item")
	_check.call(_hands.proxy("mouse") != null and _hands.proxy("mouse").is_inside_tree() and _world.hidden_items.has(rock),
			"hands: it leaves its pile and a copy follows the hand")
	var px := _hands.proxy("mouse")
	var want := Basis((drawn[4] as Transform3D).basis.get_rotation_quaternion()) if not drawn.is_empty() else Basis()
	_check.call(not drawn.is_empty() and px != null and px.global_position.is_equal_approx((drawn[4] as Transform3D).origin)
			and px.global_basis.orthonormalized().is_equal_approx(want.orthonormalized()),
			"hands: the copy starts where the pile drew the item, turned the same way")
	_check.call(not _hands.grab("vr_l", t) and _uid(_hands.find_near(_mid(rock), 0.01)) != rock,
			"hands: another hand can't grab or find what one holds")
	var o := _world.coords.ms_center_to_world(S) + Vector3(0.2, 1.5, -0.1)
	var held: ItemRef = _hands.holding("mouse")["item"]
	var d := _hands.drop_on_ray(o, Vector3.DOWN, held)
	_check.call(d["kind"] == "surface" and d["square"] == S and (d["spot"] as Vector2).x > 0.5 and d["point"] is Vector3
			and Hands.drop_hint(d, _world.tables) == "put it here", "hands: over the floor: put it here (%s)" % [d])
	_seen.clear()
	var op := _hands.release("mouse", d)
	var row := _handle_row(S, rock)
	var spot: Vector2 = d["spot"]
	_check.call(op == "take" and _seen == [["confirmed", "mouse", rock, ""]] and not _carried(rock)
			and not row.is_empty() and absi(int(row[3]) - int(spot.x * 1000)) <= 1 and absi(int(row[4]) - int(spot.y * 1000)) <= 1,
			"hands: let go: taken, then dropped at that spot (%s, %s)" % [op, row])
	_check.call(_hands.holding("mouse").is_empty() and _hands.proxy("mouse") == null and _world.hidden_items.is_empty()
			and _actions.pending_count() == 0 and _snap.player_wielded == 0, "hands: nothing held, hidden or in flight after")


## E takes the hammer into the pack; then the hand puts the carried hammer into the canvas bag on the ground.
func _test_take_and_put() -> void:
	var hammer := _handle(E, _it["hammer"])
	var bag := _handle(SE, _it["bag_canvas"])
	_seen.clear()
	var t := _hands.find_near(_mid(hammer), 0.05)
	_check.call(_uid(t) == hammer and _hands.take("mouse", t, "pack") and _carried(hammer)
			and _seen == [["confirmed", "mouse", hammer, ""]], "hands: take an item into the pack")
	_seen.clear()
	_check.call(not _hands.take("mouse", t, "pack") and _seen.is_empty() and _actions.pending_count() == 0,
			"hands: a stale target (carried since) isn't taken again")
	var ref: ItemRef = null
	for r in _hands.picker.carried():
		if r.uid == hammer:
			ref = r
	_check.call(ref != null and _hands.adopt("mouse", ref) and _hands.holding("mouse")["item"].carried
			and _world.hidden_items.is_empty(), "hands: a carried item can be held (nothing hidden on the ground)")
	var eye := _world.coords.ms_center_to_world(P) + Vector3(0, 1.6, 0)
	var d := _hands.drop_on_ray(eye, _mid(bag) - eye, ref)
	_check.call(d["kind"] == "container" and (d["container"] as ItemRef).uid == bag
			and Hands.drop_hint(d, _world.tables).begins_with("put it in the "), "hands: over a bag: put it in (%s)" % [d])
	_seen.clear()
	_check.call(_hands.release("mouse", d) == "put" and not _carried(hammer) and _seen == [["confirmed", "mouse", hammer, ""]],
			"hands: let go over the bag: put in")


## VR: grabbing with take_into takes at once (the hand holds a carried item); a second take into the full main
## hand is refused with CDDA's reason and that hand is empty again; letting the first go over the floor drops it.
func _test_vr_refused() -> void:
	var bag := _handle(SE, _it["bag_canvas"])
	var rock := _handle(S, _it["rock"])
	_seen.clear()
	_check.call(_hands.grab("vr_r", _hands.find_near(_mid(bag), 0.05), "main") and (_hands.holding("vr_r")["item"] as ItemRef).is_wielded()
			and _seen == [["confirmed", "vr_r", bag, ""]] and not _world.hidden_items.has(bag),
			"hands: VR grab takes into the hand at once")
	_seen.clear()
	_hands.grab("vr_l", _hands.find_near(_mid(rock), 0.05), "main")
	_check.call(_hands.holding("vr_l").is_empty() and _seen.size() == 1 and _seen[0][0] == "refused" and _seen[0][1] == "vr_l"
			and (_seen[0][3] as String).begins_with("Your hand is full") and not _world.hidden_items.has(rock)
			and _handle(S, _it["rock"]) == rock, "hands: refused take: the hand lets go, CDDA's reason (%s)" % [_seen])
	var p := _world.coords.ms_center_to_world(S) + Vector3(-0.25, 0.3, 0.25)
	var d := _hands.drop_at(p, _hands.holding("vr_r")["item"])
	_seen.clear()
	_check.call(d["kind"] == "surface" and d["square"] == S and _hands.release("vr_r", d) == "drop"
			and _seen == [["confirmed", "vr_r", bag, ""]] and not _handle_row(S, bag).is_empty(),
			"hands: VR let go over the floor: dropped there")


func _test_cancel() -> void:
	var rock := _handle(S, _it["rock"])
	_seen.clear()
	_check.call(_hands.grab("mouse", _hands.find_near(_mid(rock), 0.05)) and _world.hidden_items.has(rock), "hands: grab for cancel")
	_hands.cancel("mouse")
	_check.call(_hands.holding("mouse").is_empty() and _world.hidden_items.is_empty() and _actions.pending_count() == 0
			and _seen.is_empty() and _handle(S, _it["rock"]) == rock, "hands: cancel puts it back, nothing sent")
	_check.call(_hands.release("mouse", {"kind": "surface", "square": S}) == "", "hands: letting go of nothing does nothing")


## GrabController with hands: the crosshair over an item shows its name and keys; E takes it; hold LMB carries the
## bag, the wheel moves it, letting go over the floor puts it there; Esc puts it back; refusals flash in red.
func _test_mouse(root: Node) -> void:
	var ctl := GrabController.new(_world)
	root.add_child(ctl)
	ctl.reach = func() -> Variant: return P
	ctl.hands = _hands
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	var mid := root.get_viewport().get_visible_rect().size / 2
	var eye := _world.coords.ms_center_to_world(P) + Vector3(0, 1.6, 0)
	var rock := _handle(S, _it["rock"])
	cam.look_at_from_position(eye, _mid(rock))
	ctl.update(cam, mid, true, true)
	_check.call(_uid(ctl.item_hover) == rock and ctl.icon.mode == GrabController.GrabIcon.HAND
			and ctl.icon.text.begins_with(str(ctl.item_hover["name"])), "hands: crosshair on an item: hand pointer, its name and keys")
	var e_key := InputActions.slots(&"use_held")[0].duplicate() as InputEvent
	if e_key is InputEventKey:
		(e_key as InputEventKey).pressed = true
	_check.call(ctl.take_hovered(e_key) and _carried(rock), "hands: E takes the item under the crosshair")
	var bag := _handle(S, _it["bag_canvas"])
	cam.look_at_from_position(eye, _mid(bag))
	ctl.update(cam, mid, true, true)
	var lmb := InputEventMouseButton.new()
	lmb.button_index = MOUSE_BUTTON_LEFT
	lmb.pressed = true
	_check.call(_uid(ctl.item_hover) == bag and ctl.handle_event(lmb, cam, mid) and ctl.carrying(), "hands: hold LMB grabs the item")
	var floor_at := _world.coords.ms_center_to_world(SE) + Vector3(0.1, 0.0, 0.1)
	cam.look_at_from_position(eye, floor_at)
	ctl.update(cam, mid, true, true)
	_check.call(ctl.icon.mode == GrabController.GrabIcon.FIST and ctl.drop.get("kind") == "surface"
			and ctl.icon.text == "put it here\nflick and let go: throw it",
			"hands: carrying: fist and where it would go (%s)" % ctl.icon.text)
	var m0 := ctl.carry_m
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	_check.call(ctl.handle_event(wheel, cam, mid) and is_equal_approx(ctl.carry_m, minf(m0 + GrabController.CARRY_STEP_M,
			GrabController.CARRY_MAX_M)), "hands: the wheel carries it farther")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	_seen.clear()
	_check.call(ctl.handle_event(up, cam, mid) and not ctl.carrying() and not _handle_row(SE, bag).is_empty()
			and _seen == [["confirmed", "mouse", bag, ""]], "hands: letting go over the floor puts it there")
	cam.look_at_from_position(eye, _mid(bag))
	ctl.update(cam, mid, true, true)
	ctl.handle_event(lmb, cam, mid)
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_seen.clear()
	_check.call(ctl.carrying() and ctl.handle_event(esc, cam, mid) and not ctl.carrying() and _seen.is_empty()
			and _handle(SE, _it["bag_canvas"]) == bag and _world.hidden_items.is_empty(), "hands: Esc puts it back")
	_hands.refused.emit("mouse", {}, "You can't do that.")
	ctl.update(cam, mid, true, true)
	_check.call(ctl.icon.text == "You can't do that." and ctl.icon.bad, "hands: a refusal flashes its reason in red")
	cam.free()
	ctl.free()


## A door leaf freed while a hand hovers or holds it (its submap dropped): forgotten, no cast errors; also the
## public hovered() and set_proxy_pose(), and the hit ball's cap.
func _test_freed_leaf() -> void:
	var g := Grabbable.new()
	g.leaf = MeshInstance3D.new()
	g.add_child(g.leaf)
	var t := {"kind": "door", "node": g, "item": null, "square": P, "point": Vector3.ZERO, "dist": 1.0, "name": "door"}
	_hands.hover("vr_l", t)
	_check.call(Hands.same_target(_hands.hovered("vr_l"), t), "hands: hovered() gives the target under a hand")
	g.free()
	_check.call(_hands.hovered("vr_l").is_empty() and _hands.release("vr_l", {}) == "" and not _hands.grab("vr_l", t),
			"hands: a freed door leaf is forgotten, not grabbed")
	_hands.hover("vr_l", {})
	var bag := _handle(SE, _it["bag_canvas"])
	_check.call(_hands.grab("vr_r", _hands.find_near(_mid(bag), 0.05)), "hands: grab for set_proxy_pose")
	var p := _hands.proxy("vr_r")
	var s := p.scale
	_hands.set_proxy_pose("vr_r", Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3)))
	_check.call(p.global_position.is_equal_approx(Vector3(1, 2, 3)) and p.scale.is_equal_approx(s),
			"hands: set_proxy_pose places the held copy, keeping its size")
	_hands.cancel("vr_r")
	_check.call(WorldView.item_hit_radius(0.7) == WorldView.ITEM_HIT_MAX_M and WorldView.item_hit_radius(0.01) == WorldView.ITEM_HIT_MIN_M,
			"hands: an item's hit ball is capped (a long item doesn't swallow its neighbours)")


## Throwing: Hands.throw at your own square sends nothing (the item goes back); in GrabController a slow let-go
## puts the item down, a flick (fast mouse motion right before) throws it at the square under the pointer:
## taken first, then CDDA's throw (MockItems), landing there.
func _test_flick(root: Node) -> void:
	var bag := _handle(SE, _it["bag_canvas"])
	_seen.clear()
	_check.call(_hands.grab("mouse", _hands.find_near(_mid(bag), 0.05)) and _hands.throw("mouse", P) == ""
			and _hands.holding("mouse").is_empty() and _world.hidden_items.is_empty() and _actions.pending_count() == 0
			and _handle(SE, _it["bag_canvas"]) == bag, "hands: a throw at your own square sends nothing, the item is back")
	var ctl := GrabController.new(_world)
	root.add_child(ctl)
	ctl.reach = func() -> Variant: return P
	ctl.hands = _hands
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	var mid := root.get_viewport().get_visible_rect().size / 2
	var eye := _world.coords.ms_center_to_world(P) + Vector3(0, 1.6, 0)
	cam.look_at_from_position(eye, _mid(bag))
	ctl.update(cam, mid, true, true)
	var lmb := InputEventMouseButton.new()
	lmb.button_index = MOUSE_BUTTON_LEFT
	lmb.pressed = true
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	ctl.handle_event(lmb, cam, mid)
	var now := Time.get_ticks_msec()
	ctl._motion = [[now - 1000, 5000.0]]
	_check.call(ctl.carrying() and ctl.flick_speed(now) == 0.0, "hands: old mouse motion is no flick")
	cam.look_at_from_position(eye, eye + Vector3(0.002, -1.0, 0.0))
	_check.call(ctl.throw_square(cam, mid) == null, "hands: looking straight down: nowhere to throw")
	cam.look_at_from_position(eye, _world.coords.ms_center_to_world(P + Vector3i(3, 0, 0)))
	ctl.update(cam, mid, true, true)
	var sq: Variant = ctl.throw_square(cam, mid)
	var flick := InputEventMouseMotion.new()
	flick.relative = Vector2(0, -120)
	var used := false
	for i in 3:
		used = used or ctl.handle_event(flick, cam, mid)
	_check.call(not used and ctl.flick_speed(Time.get_ticks_msec()) >= GrabController.FLICK_PX_S,
			"hands: carrying, mouse motion still turns the view and is counted for a flick")
	_seen.clear()
	_check.call(sq is Vector3i and sq != P and (sq as Vector3i).z == P.z and ctl.handle_event(up, cam, mid)
			and not ctl.carrying() and _handle(sq, _it["bag_canvas"]) == bag and not _carried(bag)
			and _seen == [["confirmed", "mouse", bag, ""]], "hands: a flick throws it at the square under the pointer (%s, %s)" % [sq, _seen])
	cam.free()
	ctl.free()


## Hands.move (the Tab view's drag and drop): the carried rock into the bag on SE without a hand holding it;
## malformed drops do nothing.
func _test_move() -> void:
	var rock: ItemRef = null
	for r in _hands.picker.carried():
		if r.type == _it["rock"]:
			rock = r
	var bag := _hands.picker.by_uid(_handle(SE, _it["bag_canvas"]))
	_check.call(rock != null and bag != null and _hands.move("mouse", rock, {"kind": "container", "container": 5}) == ""
			and _hands.move("mouse", rock, {"kind": "surface", "square": "here"}) == ""
			and _hands.move("mouse", rock, {"kind": "none"}) == "" and _hands.move("mouse", null, {"kind": "surface"}) == ""
			and _actions.pending_count() == 0, "hands: move refuses malformed drops")
	_seen.clear()
	_check.call(rock != null and bag != null and _hands.move("mouse", rock, {"kind": "container", "container": bag}) == "put"
			and _seen == [["confirmed", "mouse", rock.uid, ""]] and not _carried(rock.uid), "hands: move puts a carried item in a bag")


## Under the pointer a terrain door is named by its terrain, a furniture part by its kind and furniture
## ("drawer (dresser)"), locked ones say so; a freed leaf has no name.
func _test_door_names() -> void:
	var w := _hands.world
	var door_sq := NO_SQ
	var furn_sq := NO_SQ
	for pos: Vector3i in w.snapshot.submaps:
		var sm: Snapshot.Submap = w.snapshot.submaps[pos]
		for i in sm.ter.size():
			var sq := CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
			if door_sq == NO_SQ and w.tables.def_at("ter", sm.ter[i]).id.begins_with("t_door"):
				door_sq = sq
			if furn_sq == NO_SQ and i < sm.furn.size() and sm.furn[i] != 0:
				furn_sq = sq
	var g := Grabbable.new()
	g.square = door_sq
	var ter := _hands._name_at("ter", door_sq)
	var door_ok := door_sq != NO_SQ and not ter.is_empty() and _hands.door_name(g) == ter
	g.locked = true
	door_ok = door_ok and _hands.door_name(g) == ter + ", locked"
	g.locked = false
	g.mech = "slide"
	g.kind = "drawer"
	g.square = furn_sq
	var furn := _hands._name_at("furn", furn_sq)
	var part_ok := furn_sq != NO_SQ and not furn.is_empty() and _hands.door_name(g) == "drawer (%s)" % furn
	g.square = P + Vector3i(0, 0, 40)   # nothing known there
	part_ok = part_ok and _hands.door_name(g) == "drawer"
	g.free()
	_check.call(door_ok and part_ok and _hands.door_name(null) == "",
			"hands: doors named by terrain, parts by kind and furniture (%s, %s)" % [ter, furn])
