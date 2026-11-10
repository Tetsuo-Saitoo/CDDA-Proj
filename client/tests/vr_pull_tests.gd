extends RefCounted
## Block L2: point and pull in VR (VrRig.pointed_item, pull_with, the pull ray, the copy's flight) on the mock town,
## with MockItems answering inside each call: a touched / half-pressed trigger on an empty hand outlines the item its
## ray meets (not a door leaf, nothing out of reach, nothing with a full hand or the menu open); the click takes it
## into CDDA's main / off hand by controller (and left-handed), the copy flies from where it lay into the hand with
## one buzz on arrival; pointed stairs still win on the main trigger; nothing pointed: one buzz; a refusal empties
## the hand and shows CDDA's reason. No XR runtime: controllers are inactive, the test sets their triggers
## (VrRig.trigger_in), moves them and presses buttons. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const SE := P + Vector3i(1, 1, 0)      # pile: canvas sack
const S := P + Vector3i(0, 1, 0)       # bare floor
const FAR := P + Vector3i(5, 0, 0)     # pile: rock, out of reach
const HALF := 0.3                      # a half-pressed trigger

var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr pull")
	for id: String in ["rock", "hammer", "2x4", "bag_canvas"]:
		_it[id] = tables.index_of("itype", id)
	if not _setup(root, data, tables):
		return
	_test_point()
	_test_pull_main()
	_test_off_and_left_handed()
	_test_stairs_and_nothing()
	_test_far_and_door()
	_test_refused()
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
			sm["items"] = [[1, 3, [_it["rock"], _it["hammer"], _it["2x4"]]], [13, 1, [_it["bag_canvas"]]],
					[5, 1, [_it["rock"]]]]
		elif at in [Vector3i(15, 32, 0), Vector3i(15, 31, 0), Vector3i(16, 31, 0)]:
			sm["items"] = []
		else:
			continue
		sm.erase("handles")
	(d["player"] as Dictionary)["items"] = []
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "vr pull: test town loads " + _snap.error)
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


func _clean() -> bool:
	return _world.hidden_items.is_empty() and _actions.pending_count() == 0 and _hands.proxy("vr_l") == null \
			and _hands.proxy("vr_r") == null and _hands.holding("vr_l").is_empty() and _hands.holding("vr_r").is_empty()


## Controller c 0.8 m over a point, a little south of it, pointing at it.
func _aim(c: XRController3D, at: Vector3) -> void:
	c.global_position = at + Vector3(0.05, 0.8, 0.3)
	c.look_at(at, Vector3.UP)


## One frame, long enough for the pull ray to look again.
func _frame(d := VrRig.PULL_RAY_S * 1.2) -> void:
	_rig.update_hands(d, true)


func _hover(i: int) -> Dictionary:
	return _hands.hovered(VrRig.HAND_IDS[i])


## Lets go of what controller c holds over the floor of S (a grip click: pressed and released).
func _put_down(c: XRController3D) -> void:
	c.global_position = _world.coords.ms_center_to_world(S) + Vector3(-0.2, 0.3, 0.2)
	_rig.press(c, "grip_click")
	_rig.release(c, "grip_click")


## Trigger released: nothing; touched / half pressed: a faint ray and the item it meets outlined; the menu open or
## the hand touching something: no ray.
func _test_point() -> void:
	var bag := _handle(SE, _it["bag_canvas"])
	_aim(_rig.right, _mid(bag))
	_rig.trigger_in[1] = 0.0
	_frame()
	_check.call(_hover(1).is_empty() and not _rig.pull_rays[1].visible, "vr pull: trigger released: no ray, nothing outlined")
	_rig.trigger_in[1] = HALF
	_frame()
	var t := _hover(1)
	var outline: MeshInstance3D = _world.get_node_or_null("ItemOutline_vr_r")
	var ray := _rig.pull_rays[1]
	var mid: Vector3 = (_rig.right.global_position + (t.get("point", Vector3.INF) as Vector3)) * 0.5
	_check.call(_uid(t) == bag and outline != null and outline.visible and ray.visible
			and ray.global_position.distance_to(mid) < 0.001 and not _rig.pull_rays[0].visible,
			"vr pull: a half-pressed trigger on an empty hand: a faint ray to the item it meets, outlined")
	_rig.press(_rig.left, "menu_button")
	_frame()
	_check.call(_rig.menu_open() and _hover(1).is_empty() and not ray.visible, "vr pull: the menu open: no ray, nothing outlined")
	_rig.press(_rig.left, "menu_button")
	_frame()
	_check.call(not _rig.menu_open() and _uid(_hover(1)) == bag and ray.visible, "vr pull: menu closed: the ray is back")
	var rock := _handle(E, _it["rock"])
	_rig.right.global_position = _mid(rock)
	_frame()
	_check.call(_hover(1).get("kind") == "item" and _hover(1).get("square") == E and not ray.visible,
			"vr pull: a hand touching an item outlines that one, no ray")
	_rig.trigger_in[1] = -1.0
	_frame()


## Main (right) trigger click: taken at once into CDDA's main hand, no stairs, no buzz yet; the copy starts where the
## item lay and flies into the hand over FLY_S, one buzz on arrival; a full hand shows no ray; a grip click lets go.
func _test_pull_main() -> void:
	var bag := _handle(SE, _it["bag_canvas"])
	var stairs := [0]
	_rig.stair_used.connect(func(_s: Dictionary) -> void: stairs[0] += 1)
	_aim(_rig.right, _mid(bag))
	_rig.trigger_in[1] = HALF
	_frame()
	var slot := _world.item_slot(bag)
	var lay: Vector3 = (slot[4] as Transform3D).origin if not slot.is_empty() else Vector3.INF
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	var p := _hands.proxy("vr_r")
	_check.call(r != null and r.uid == bag and r.is_wielded() and p != null and p.global_position.distance_to(lay) < 0.001
			and _rig.buzzes == b and stairs[0] == 0 and not _rig.pull_rays[1].visible,
			"vr pull: the click takes the pointed item into CDDA's main hand at once; its copy starts where it lay, no buzz")
	var hand := _rig.right.global_position
	var far0 := _grip_point("vr_r").distance_to(hand)
	_frame(VrRig.FLY_S * 0.5)
	var half_way := _grip_point("vr_r").distance_to(hand)
	_check.call(half_way > 0.01 and half_way < far0 and p.global_position.distance_to(lay) > 0.01 and _rig.buzzes == b,
			"vr pull: ... flying toward the hand (%.2f m of %.2f to go)" % [half_way, far0])
	_frame(VrRig.FLY_S * 0.6)
	_check.call(_grip_point("vr_r").distance_to(hand) < 0.001 and _rig.buzzes[1] == b[1] + 1 and _rig.buzzes[0] == b[0],
			"vr pull: ... in the hand after %.1f s, one buzz on arrival" % VrRig.FLY_S)
	_frame()
	_frame()
	_check.call(_grip_point("vr_r").distance_to(hand) < 0.001 and _rig.buzzes[1] == b[1] + 1 and _hover(1).is_empty()
			and not _rig.pull_rays[1].visible, "vr pull: then it stays in the hand; no more buzzes; a full hand shows no ray")
	_put_down(_rig.right)
	_check.call(_hands.holding("vr_r").is_empty() and _row(bag).is_empty() and _handle(S, _it["bag_canvas"]) == bag and _clean(),
			"vr pull: a grip click lets a pulled item go (dropped where the hand is)")
	_rig.trigger_in[1] = -1.0


## The off (left) trigger pulls into CDDA's off hand; left-handed the left trigger pulls into the main hand.
func _test_off_and_left_handed() -> void:
	var bag := _handle(S, _it["bag_canvas"])
	_rig.trigger_in[0] = HALF
	_aim(_rig.left, _mid(bag))
	_frame()
	var lit := _uid(_hover(0)) == bag and _rig.pull_rays[0].visible
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.left, "trigger_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_frame(VrRig.FLY_S * 1.1)
	_check.call(lit and l != null and l.uid == bag and l.is_off_hand() and _rig.buzzes[0] == b[0] + 1 and _rig.buzzes[1] == b[1]
			and _grip_point("vr_l").distance_to(_rig.left.global_position) < 0.001,
			"vr pull: the off trigger pulls the pointed item into CDDA's off hand")
	_put_down(_rig.left)
	_rig.settings["main_hand"] = "left"
	bag = _handle(S, _it["bag_canvas"])
	_aim(_rig.left, _mid(bag))
	_frame()
	_rig.press(_rig.left, "trigger_click")
	l = _hands.holding("vr_l").get("item")
	_check.call(l != null and l.uid == bag and l.is_wielded(), "vr pull: left-handed: the left trigger pulls into the main hand")
	_frame(VrRig.FLY_S * 1.1)
	_put_down(_rig.left)
	_check.call(_handle(S, _it["bag_canvas"]) == bag and _clean(), "vr pull: ... let go again")
	_rig.settings["main_hand"] = "right"
	_rig.trigger_in[0] = -1.0


## The first square of terrain kind `kind` on level z, null if none.
func _find_kind(z: int, kind: int) -> Variant:
	for pos: Vector3i in _world.snapshot.submaps:
		if pos.z != z:
			continue
		var sm: Snapshot.Submap = _world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if _world.catalog.style_for(sm.ter[i]).kind == kind:
				return CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
	return null


## Pointed stairs still win on the main trigger (no buzz, nothing taken); the off trigger doesn't use them; pointing
## at nothing: no ray, and a click is one buzz.
func _test_stairs_and_nothing() -> void:
	var up: Variant = _find_kind(0, TerrainCatalog.Kind.STAIRS_UP)
	_check.call(up != null, "vr pull: the mock town has stairs up on level 0")
	var used := []
	_rig.stair_used.connect(func(s: Dictionary) -> void: used.append(s))
	_rig.live_stairs = true   # the ghost stays: only the trigger's choice is tested
	if up != null:
		var at := _world.coords.ms_center_to_world(up)
		for c: XRController3D in [_rig.left, _rig.right]:
			c.global_position = at + Vector3(0.6, 1.2, 0.0)
			c.look_at(at, Vector3.UP)
		var b := _rig.buzzes.duplicate()
		_rig.press(_rig.right, "trigger_click")
		_check.call(used.size() == 1 and _hands.holding("vr_r").is_empty() and _rig.buzzes == b,
				"vr pull: pointed stairs still win on the main trigger (no buzz)")
		_rig.press(_rig.left, "trigger_click")
		_check.call(used.size() == 1 and _hands.holding("vr_l").is_empty() and _rig.buzzes[0] == b[0] + 1,
				"vr pull: the off trigger doesn't use stairs: nothing to pull, one buzz")
	_rig.live_stairs = false
	_rig.go_to_square(P)
	var head := _rig.camera.global_position
	_rig.right.global_position = head + Vector3(0.2, -0.3, -0.3)
	_rig.right.look_at(_rig.right.global_position + Vector3(0, 1, -0.3), Vector3.UP)
	_rig.trigger_in[1] = HALF
	_frame()
	var shown := _hover(1).is_empty() and not _rig.pull_rays[1].visible
	var b2 := _rig.buzzes.duplicate()
	var n := used.size()
	_rig.press(_rig.right, "trigger_click")
	_check.call(shown and _rig.buzzes[1] == b2[1] + 1 and _rig.buzzes[0] == b2[0] and used.size() == n
			and _hands.holding("vr_r").is_empty(), "vr pull: nothing pointed: no ray, and the click is exactly one buzz")
	_rig.trigger_in[1] = -1.0
	_frame()


## An item out of reach: nothing outlined, the click one buzz. A door leaf the ray meets: no pull target.
func _test_far_and_door() -> void:
	var far := _handle(FAR, _it["rock"])
	_rig.trigger_in[1] = HALF
	_aim(_rig.right, _mid(far))
	_frame()
	var shown := far > 0 and _hover(1).is_empty() and not _rig.pull_rays[1].visible
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	_check.call(shown and _hands.holding("vr_r").is_empty() and _rig.buzzes[1] == b[1] + 1 and _handle(FAR, _it["rock"]) == far,
			"vr pull: an item out of reach: nothing outlined, the click one buzz, nothing taken")
	_rig.trigger_in[1] = -1.0
	var g: Grabbable = null
	for sq: Vector3i in _world.grabbables:
		var d: Grabbable = _world.grabbables[sq]
		if sq.z == 0 and not d.cdda_open and not d.locked:
			g = d
			break
	_check.call(g != null, "vr pull: the mock town has a closed door")
	if g == null:
		return
	_hands.picker.reach = func() -> Variant: return g.square
	var c := _world.coords.ms_center_to_world(g.square) + Vector3(0, 1.0, 0)
	var across := Vector3(0, 0, 1) if g.base_yaw == 0.0 else Vector3(1, 0, 0)   # the side the leaf faces
	_rig.left.global_position = c + across * 1.2
	_rig.left.look_at(c, Vector3.UP)
	var seen := _hands.find_on_ray(_rig.left.global_position, -_rig.left.global_basis.z)
	_rig.trigger_in[0] = HALF
	_frame()
	var none := _hover(0).is_empty() and not _rig.pull_rays[0].visible
	b = _rig.buzzes.duplicate()
	_rig.press(_rig.left, "trigger_click")
	_check.call(seen.get("kind") == "door" and none and _hands.holding("vr_l").is_empty() and not g.grabbed
			and _rig.buzzes[0] == b[0] + 1, "vr pull: a door leaf the ray meets is no pull target (%s)" % seen.get("kind", "nothing"))
	_rig.trigger_in[0] = -1.0
	_frame()
	_hands.picker.reach = Callable()


## CDDA refuses the take (its main hand is full): the hand is empty again, its reason by the hand, one buzz, no
## flight and no arrival buzz.
func _test_refused() -> void:
	var bag := _handle(S, _it["bag_canvas"])
	_rig.trigger_in[1] = HALF
	_aim(_rig.right, _mid(bag))
	_frame()
	_rig.press(_rig.right, "trigger_click")
	_frame(VrRig.FLY_S * 1.1)
	_rig.right.global_position = _world.coords.ms_center_to_world(FAR) + Vector3(0, 0.3, 0)
	_rig.press(_rig.right, "grip_click")
	_rig.release(_rig.right, "grip_click")   # nowhere it can go: it stays in CDDA's main hand
	var row := _row(bag)
	_check.call(not row.is_empty() and (int(row[1]) & Snapshot.CARRIED_WIELDED) != 0 and _clean(),
			"vr pull: (CDDA's main hand holds the sack)")
	_aim(_rig.right, _mid(_handle(E, _it["rock"])))
	_frame()
	var lit: bool = _hover(1).get("square") == E
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	var note := _rig.notes[1]
	_check.call(lit and _hands.holding("vr_r").is_empty() and _hands.proxy("vr_r") == null and _rig.buzzes[1] == b[1] + 1
			and note != null and note.visible and note.text.begins_with("Your hand is full") and _clean(),
			"vr pull: CDDA refuses: the hand empty, its reason by the hand, one buzz")
	_frame(VrRig.FLY_S * 2.0)
	_check.call(_rig.buzzes[1] == b[1] + 1, "vr pull: ... and no arrival buzz")
	_rig.trigger_in[1] = -1.0
	_rig.right.global_position = _world.coords.ms_center_to_world(P) + Vector3(0, 1.2, 0)
	_frame()
	_rig.press(_rig.right, "grip_click")   # grip on nothing: CDDA's wielded sack
	_rig.right.global_position = _world.coords.ms_center_to_world(S) + Vector3(-0.2, 0.3, 0.2)
	_rig.release(_rig.right, "grip_click")
	_check.call(_row(bag).is_empty() and _handle(S, _it["bag_canvas"]) == bag and _clean(), "vr pull: put down again")
