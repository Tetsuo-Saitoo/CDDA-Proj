extends RefCounted
## L3: melee by hand in VR (VrSwing on VrRig.swing) on the mock town with a zombie next to the player. A fast hand
## whose fist line meets the zombie sends CDDA's aimed strike for that hand (main / off by controller, left-handed
## too) and AimController answers the swing request with the part touched (the head; the body leaves CDDA's pick);
## one strike per swing (re-arm, gap, one in flight); a confirmed hit buzzes the striking hand once; nothing from a
## slow hand, a hand off the figure, a creature off the 8 ways, with a menu open, from an untracked hand, the pack
## hand or the gun hand with a finger on the trigger; a refused queue sends nothing on; a held plank reaches where a
## fist doesn't, with either end. No XR runtime: the test places the controllers and sets their speed.
## Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const ZP := P + Vector3i(0, 1, 0)      # the zombie, next to the player (the way "DOWN")
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const ZUID := 8589934593
const DT := 0.02
const FAST := 3.0
const SLOW := 0.5

var _check: Callable
var _it := {}
var _snap: Snapshot
var _world: WorldView
var _mock: MockItems
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig
var _ui: RequestUI
var _aim: AimController
var _cv: CreatureView
var _sent: Array = []          # actions queued through VrSwing.queue_action
var _accept := true            # the stand-in queue takes them
var _struck: Array = []
var _torso := Vector3.ZERO     # the middle of the zombie's torso
var _toward := Vector3.ZERO    # level, from the player's square to the zombie
var _reach := 0.0              # from the torso's middle back along _toward to its surface
var _head := Vector3.ZERO      # the same for its head
var _head_reach := 0.0
var _zdef: IdTables.Def        # the zombie's type: the test gives it a head weak point (as aim_tests does)
var _old_wp := {}


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr swing")
	for id: String in ["rock", "hammer", "2x4"]:
		_it[id] = tables.index_of("itype", id)
	_test_static(root)
	if not _setup(root, data, tables):
		return
	_zdef = tables.def_named("mtype", "mon_zombie")
	if _zdef != null:
		_old_wp = _zdef.weakpoints
		_zdef.weakpoints = {"head": true, "eye": true}
	_test_fist()
	_test_hands()
	_test_blocked()
	_test_held_item()
	if _zdef != null:
		_zdef.weakpoints = _old_wp
	_rig.free()
	_cv.free()
	_aim.free()
	_ui.free()
	_hands.free()
	_actions.free()
	_world.free()


func _test_static(root: Node) -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var stick := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.1, 1.0, 0.1)
	stick.mesh = box
	stick.position = Vector3(0, 0.5, 0)
	holder.add_child(stick)
	var tip: Variant = VrSwing.tip_of(holder, Vector3.ZERO)
	var empty := Node3D.new()
	root.add_child(empty)
	_check.call(tip is Vector3 and is_equal_approx((tip as Vector3).y, 1.0) and absf((tip as Vector3).x) < 0.051
			and VrSwing.tip_of(empty, Vector3.ZERO) == null,
			"vr swing: a held copy's tip is its farthest point from the hand (%s); no meshes: none" % [tip])
	holder.global_position = Vector3(NAN, 0, 0)
	_check.call(VrSwing.tip_of(holder, Vector3.ZERO) == null, "vr swing: a bad pose has no tip")
	holder.free()
	empty.free()


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
	(d["player"] as Dictionary)["items"] = []
	d["creatures"] = [d["creatures"][0], {"uid": ZUID, "kind": 2, "type": tables.index_of("mtype", "mon_zombie"),
			"pos": [ZP.x, ZP.y, ZP.z], "hp_frac": 255}]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "vr swing: test town loads " + _snap.error)
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
		_actions.on_snapshot(s)
		_cv.apply(s, _world))
	_mock.message.connect(func(t: String) -> void: _actions.on_events([MockItems.message_event(t)]))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_rig.hands = _hands
	_rig.assume_tracked = true
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_rig.go_to_square(P)
	_ui = RequestUI.new()
	root.add_child(_ui)
	_aim = AimController.new(_world, _ui)
	root.add_child(_aim)
	_cv = CreatureView.new()
	root.add_child(_cv)
	_cv.apply(_snap, _world)
	_aim.creature_view = _cv
	_rig.swing.aim = _aim
	_rig.swing.queue_action = func(a: String) -> bool:
		_sent.append(a)
		return _accept
	_rig.swing.struck.connect(func(hand: String, dir: String, uid: int) -> void: _struck.append([hand, dir, uid]))
	var z: CreatureFigure = _cv.figures().get(ZUID)
	var found := false
	if z != null:
		for zz: Array in z.hit_zones():
			if zz[1] != "torso" and zz[1] != "head":
				continue
			var m: MeshInstance3D = zz[0]
			var box: AABB = m.global_transform * m.get_aabb()
			var from := _world.coords.ms_center_to_world(P)
			var mid := box.get_center()
			var to := Vector3(mid.x - from.x, 0.0, mid.z - from.z).normalized()
			var reach := minf(box.size.x * 0.5 / maxf(absf(to.x), 0.001), box.size.z * 0.5 / maxf(absf(to.z), 0.001))
			if zz[1] == "torso":
				_torso = mid
				_toward = to
				_reach = reach
				found = true
			else:
				_head = mid
				_head_reach = reach
	_check.call(found and _toward.length() > 0.9 and _reach > 0.0 and _reach < 1.0 and _head_reach > 0.0,
			"vr swing: the zombie stands next to the player with a torso and a head to hit (reach %.2f)" % _reach)
	return found and _head_reach > 0.0


## Puts controller c on the player's side of the torso, pointing at it, so that a line of `length` from the hand ends
## `inside` metres inside it.
func _hand_at(c: XRController3D, length := VrSwing.FIST_M, inside := 0.08) -> void:
	c.global_transform = Transform3D(Basis.looking_at(_toward, Vector3.UP), _torso - _toward * (_reach + length - inside))


## The same at its head.
func _hand_at_head(c: XRController3D) -> void:
	c.global_transform = Transform3D(Basis.looking_at(_toward, Vector3.UP),
			_head - _toward * (_head_reach + VrSwing.FIST_M - 0.08))


## One frame of the swing with hand i moving at `speed` toward the zombie (the other hand still).
func _swing(i: int, speed: float, d := DT) -> void:
	_rig.hand_vel[i] = _toward * speed
	_rig.hand_vel[1 - i] = Vector3.ZERO
	_rig.swing.update(d)


## Slows both hands, lets the gap pass and shows a newer snapshot: the next swing may strike.
func _rest() -> void:
	_world.snapshot.seq += 1
	_swing(0, 0.0, VrSwing.GAP_S + 0.01)


func _test_fist() -> void:
	_hand_at_head(_rig.right)
	_swing(1, VrSwing.SWING_SPEED - 0.5)
	_check.call(_sent.is_empty() and _rig.swing.strikes == 0, "vr swing: a slow hand on the zombie strikes nothing")
	_swing(1, FAST)
	_check.call(_sent == ["fp3d_attack_main_aim_DOWN"] and _rig.swing.strikes == 1 and _struck == [["main", "DOWN", ZUID]]
			and _aim.melee_aim.get("uid") == ZUID,
			"vr swing: a fast main hand on the zombie sends CDDA's aimed strike that way (%s)" % [_sent])
	var a := _aim.on_request({"kind": "swing", "id": 41, "cursor": ZP, "origin": P, "range": 1, "mode": "main"})
	var s: Dictionary = a.get("shot", {})
	_check.call(a.get("id") == 41 and s.get("end") == ZP and s.get("hit_uid") == ZUID and s.get("part") == "head",
			"vr swing: the swing request is answered with the part the hand touched, the head (%s)" % [a])
	_check.call(not _rig.swing.on_hit(ZUID + 1, false) and _rig.swing.on_hit(ZUID, false) and _rig.swing.hits == 1
			and not _rig.swing.on_hit(ZUID, true), "vr swing: CDDA's hit on the creature struck counts once for that strike")
	_hand_at(_rig.right)
	_swing(1, FAST)
	_swing(1, SLOW)
	_swing(1, FAST)
	_check.call(_sent.size() == 1, "vr swing: one strike per swing, and none right after it")
	_world.snapshot.seq += 1
	_swing(1, SLOW, VrSwing.GAP_S + 0.01)
	_swing(1, FAST)
	_check.call(_sent.size() == 2, "vr swing: slowed, the gap passed and a newer snapshot: the next swing strikes")
	_swing(1, SLOW, VrSwing.GAP_S + 0.01)
	_swing(1, FAST)
	var waits := _sent.size() == 2
	_swing(1, SLOW, 1.0)   # (a frame counts for 1 s at most)
	_swing(1, SLOW, 1.0)
	_swing(1, FAST)
	_check.call(waits and _sent.size() == 3, "vr swing: no newer snapshot: the next strike waits %.1f s for the one in flight"
			% VrSwing.FLIGHT_S)
	var body := _aim.on_request({"kind": "swing", "id": 42, "cursor": ZP, "origin": P, "range": 1, "mode": "main"})
	_check.call(body.get("id") == 42 and body.get("cancel") == true,
			"vr swing: a strike on the body (no weak point there) leaves the part to CDDA (%s)" % [body])
	_rest()


func _test_hands() -> void:
	_hand_at(_rig.left)
	_rig.right.global_position = Vector3(0, -50, 0)
	_swing(0, FAST)
	_check.call(_sent.back() == "fp3d_attack_off_aim_DOWN" and _struck.back() == ["off", "DOWN", ZUID],
			"vr swing: the other controller is CDDA's off hand")
	_rest()
	_rig.settings["main_hand"] = "left"
	_swing(0, FAST)
	_check.call(_sent.back() == "fp3d_attack_main_aim_DOWN", "vr swing: left-handed, the left controller is the main hand")
	_rig.settings["main_hand"] = "right"
	_rig.left.global_position = Vector3(0, -50, 0)
	_rest()


func _test_blocked() -> void:
	var n := _sent.size()
	var strikes := _rig.swing.strikes
	_hand_at(_rig.right)
	_accept = false
	_swing(1, FAST)
	_accept = true
	_check.call(_sent.size() == n + 1 and _rig.swing.strikes == strikes and _aim.melee_aim.is_empty(),
			"vr swing: the queue doesn't take it (not CDDA's turn): no strike counted, no aim kept")
	_rest()
	n = _sent.size()
	_world.snapshot.player_pos = P + Vector3i(1, -1, 0)   # the zombie is now a knight's move off: not one of the 8 ways
	_swing(1, FAST)
	_world.snapshot.player_pos = P
	_check.call(_sent.size() == n and _aim.melee_aim.is_empty(), "vr swing: a creature off the 8 ways: nothing sent")
	_rest()
	_rig.press(_rig.left, "menu_button")
	_swing(1, FAST)
	var with_menu := _sent.size() == n and _rig.menu_open()
	_rig.press(_rig.left, "menu_button")
	_check.call(with_menu and not _rig.menu_open(), "vr swing: the settings menu open: no strike")
	_rig.assume_tracked = false
	_swing(1, FAST)
	_rig.assume_tracked = true
	_rig.pack.hand = 1
	_swing(1, FAST)
	_rig.pack.hand = -1
	_rig.hand_vel[1] = Vector3(NAN, 0, 0)
	_rig.swing.update(DT)
	_rig.swing.update(NAN)
	_check.call(_sent.size() == n, "vr swing: an untracked hand, the hand holding the pack, a bad speed: no strike")
	_rig.gun.shown = true
	_rig.trigger_in[1] = 0.5
	_swing(1, FAST)
	var finger := _sent.size() == n
	_rig.trigger_in[1] = 0.0
	_swing(1, FAST)
	_rig.gun.shown = false
	_rig.trigger_in[1] = -1.0
	_check.call(finger and _sent.size() == n + 1 and _sent.back() == "fp3d_attack_main_aim_DOWN",
			"vr swing: the gun hand with a finger on the trigger doesn't strike; off the trigger it does (with the gun)")
	_rest()
	n = _sent.size()
	_rig.right.global_position += Vector3(0, 1.5, 0)   # over the zombie's head
	_swing(1, FAST)
	var missed := _sent.size() == n
	_hand_at(_rig.right)
	_swing(1, FAST)   # still fast: the swing that met nothing is still on
	_check.call(missed and _sent.size() == n + 1, "vr swing: a fast hand off the figure strikes nothing until it meets it")
	_rest()


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(p: Vector3i, type: int) -> int:
	var h := (_world.snapshot.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


func _test_held_item() -> void:
	var plank := _handle(E, _it["2x4"])
	var slot := _world.item_slot(plank)
	var c := _rig.right
	if not slot.is_empty():
		c.global_position = slot[3]
	_rig.update_hands(0.2, true)
	_rig.press(c, "grip_click")
	for k in 20:
		_rig.update_hands(0.05, true)
	var lines := _rig.swing.strike_lines(1)
	var line: Array = lines[0] if not lines.is_empty() else []
	var length := (line[0] as Vector3).distance_to(line[1]) if line.size() == 2 else 0.0
	_check.call(_hands.proxy("vr_r") != null and length >= VrSwing.MIN_TIP_M and length <= VrSwing.MAX_TIP_M + 0.001
			and lines.size() <= 2,
			"vr swing: a held plank's striking lines run from the hand to its ends (%d, the first %.2f m)" % [lines.size(), length])
	_check.call(_rig.swing.strike_lines(0).size() == 1 and is_equal_approx(
			(_rig.swing.strike_lines(0)[0][0] as Vector3).distance_to(_rig.swing.strike_lines(0)[0][1]), VrSwing.FIST_M),
			"vr swing: an empty hand has one line, a fist's reach")
	if length < VrSwing.MIN_TIP_M:
		return
	# turn the hand so that the line points at the torso from `length` away: a fist wouldn't reach (a few rounds:
	# the held copy settles in the hand after each turn)
	var want := _torso - _toward * (_reach - 0.05)
	for round in 4:
		lines = _rig.swing.strike_lines(1)
		if lines.is_empty():
			break
		line = lines[0]
		length = (line[0] as Vector3).distance_to(line[1])
		var dir_now: Vector3 = ((line[1] as Vector3) - (line[0] as Vector3)).normalized()
		c.global_transform = Transform3D(Basis(Quaternion(dir_now, _toward)) * c.global_basis,
				_torso - _toward * (_reach + length - 0.05))
		for k in 40:
			_rig.update_hands(0.05, true)
	var ends: Array = _rig.swing.strike_lines(1).map(func(l: Array) -> float: return (l[1] as Vector3).distance_to(want))
	var end_ok: bool = ends.any(func(dist: float) -> bool: return dist < 0.06)
	var far := c.global_position.distance_to(_torso) > _reach + VrSwing.FIST_M + 0.02
	var n := _sent.size()
	_swing(1, FAST)
	_check.call(end_ok and far and _sent.size() == n + 1 and _sent.back() == "fp3d_attack_main_aim_DOWN",
			"vr swing: the plank's end on the zombie strikes from where a fist wouldn't reach (ends off by %s, far %s, sent %d)"
			% [ends, far, _sent.size() - n])
	_rest()
