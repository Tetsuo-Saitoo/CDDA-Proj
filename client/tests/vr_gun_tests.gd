extends RefCounted
## Block L2: guns handled by hand in VR (VrGun on VrRig) on the mock town, with MockItems answering inside each call
## (a gun > magazine > rounds from give()), the real AimController (a zombie three squares east) and a stand-in for
## LiveSession.queue_action: the wielded gun in the main hand by its Grip (left-handed too), VrHeld hidden; the main
## trigger fires from the Muzzle pose (fire_from), else queues `fire` once and fires when its request shows; live_aim
## follows the muzzle; haptics; magazine out / in at the well by the off hand (refusals, alignment, distance, the copy
## while it comes out); racking a jammed / clean gun; hostile player_gun data; no gun: the trigger as before. No XR
## runtime: controllers are inactive, the test moves them and presses buttons. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const ZP := P + Vector3i(3, 0, 0)      # the zombie
const ZUID := 8589934593
const HALF := 0.3                      # a half-pressed trigger

var _check: Callable
var _it := {}   # itype id -> index
var _snap: Snapshot
var _world: WorldView
var _mock: MockItems
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig
var _ui: RequestUI
var _aim: AimController
var _cv: CreatureView
var _gdef: IdTables.Def
var _answers: Array = []
var _sent: Array = []          # actions queued through VrGun.queue_action
var _accept := true            # the stand-in queue takes them
var _refusals := 0
var _gun := 0                  # uids: the glock, its magazine, its rounds
var _mag := 0
var _round := 0
var _req := {}


## LiveSession's item backend for an action that doesn't land at once (MockItems answers inside the call).
class Later:
	extends RefCounted
	var calls: Array = []

	func unload_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
		calls.append([int(uid), int(type), pos, hand])
		return true

	func queued_actions() -> int:
		return 0


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr gun")
	for id: String in ["rock", "hammer", "2x4", "bag_canvas", "glock_19", "glockmag", "9mm", "remington_870"]:
		_it[id] = tables.index_of("itype", id)
	_check.call(VrGun.loadable(ItemRef.on_player(5, _it["glockmag"], 0, -1, 0, P), tables)
			and VrGun.loadable(ItemRef.on_player(5, _it["9mm"], 0, -1, 0, P), tables)
			and not VrGun.loadable(ItemRef.on_player(5, _it["rock"], 0, -1, 0, P), tables)
			and not VrGun.loadable(null, tables) and not VrGun.loadable(ItemRef.on_player(5, 0, 0, -1, 0, P), tables),
			"vr gun: magazines and rounds go into a well by hand, nothing else")
	var hp := VrGun.hold_pose(Transform3D(Basis(Vector3.UP, 0.5), Vector3(1, 2, 3)), Vector3(0, -0.06, 0.02))
	_check.call((hp * Vector3(0, -0.06, 0.02)).is_equal_approx(Vector3(1, 2, 3)) and hp.basis.is_equal_approx(Basis(Vector3.UP, 0.5)),
			"vr gun: hold_pose puts the grip point on the grip pose, turned with it")
	if not _setup(root, data, tables):
		return
	_test_shown()
	_test_fire()
	_test_mag_out()
	_test_mag_in()
	_test_mag_out_refused()
	_test_mag_pending()
	_test_rack()
	_test_long_gun()
	_test_hostile()
	_test_no_gun()
	_aim.crosshair.free()
	for n: Node in [_rig, _hands, _actions, _cv, _aim, _ui, _world]:
		n.free()


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
	(d["player"] as Dictionary)["items"] = []
	d["creatures"] = [d["creatures"][0], {"uid": ZUID, "kind": 2, "type": tables.index_of("mtype", "mon_zombie"),
			"pos": [ZP.x, ZP.y, ZP.z], "hp_frac": 255}]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P, "vr gun: test town loads " + _snap.error)
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
	_actions.refused.connect(func(_i: ItemRef, _op: String, _why: String) -> void: _refusals += 1)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_rig.hands = _hands
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_rig.go_to_square(P)
	_ui = RequestUI.new()
	root.add_child(_ui)
	_ui.answered.connect(func(a: Dictionary) -> void: _answers.append(a))
	_aim = AimController.new(_world, _ui)
	root.add_child(_aim)
	_cv = CreatureView.new()
	root.add_child(_cv)
	_cv.apply(_snap, _world)
	_aim.creature_view = _cv
	_gdef = IdTables.Def.new()
	_gdef.gun = "pistol"
	_gdef.gun_ammo = "9mm"
	_aim.wielded_gun = func() -> IdTables.Def: return _gdef
	_rig.gun.aim = _aim
	_rig.gun.actions = _actions
	_rig.gun.queue_action = func(a: String) -> bool:
		_sent.append(a)
		return _accept
	_req = {"id": 9, "kind": "target", "mode": "fire", "origin": P, "cursor": P, "range": 10, "candidates": [ZP],
			"actions": PackedStringArray(["AIM", "FIRE"]), "allow_cancel": true}
	_gun = _mock.give(_it["glock_19"], 0, Snapshot.CARRIED_WIELDED)
	_mag = _mock.give(_it["glockmag"], _gun)
	_round = _mock.give(_it["9mm"], _mag)
	_snap.player_gun = {"type": _it["glock_19"], "dirt": 0, "faults": [], "rounds": 15}
	_captured()
	_rest_hands()
	return true


## The snapshot was edited in place: captured again, as MockItems does.
func _captured() -> void:
	_snap.seq += 1
	_world.apply_snapshot(_snap)
	_actions.on_snapshot(_snap)


## The main hand low in front, pointing at the zombie's chest; the off hand low at the side.
func _rest_hands() -> void:
	var head := _rig.camera.global_position
	_rig.right.global_transform = Transform3D(Basis(), head + Vector3(0.2, -0.35, -0.25))
	_rig.right.look_at(_world.coords.ms_center_to_world(ZP) + Vector3(0, 1.2, 0), Vector3.UP)
	_rig.left.global_transform = Transform3D(Basis(), head + Vector3(-0.3, -0.55, 0.0))


func _frame(d := 0.016) -> void:
	_rig.update_hands(d, true)
	_rig.gun.update(d)


## [parent, flags] of carried item `uid`, [] when it isn't carried.
func _row(uid: int) -> Array:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i] == uid:
			return [c[i + 2], c[i + 4]]
	return []


## Takes carried item `uid` (and what is in it) out of the snapshot.
func _remove(uid: int) -> void:
	var keep := PackedInt64Array()
	var gone := {uid: true}
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if gone.has(c[i]) or gone.has(c[i + 2]):
			gone[c[i]] = true
			continue
		keep.append_array(c.slice(i, i + Snapshot.CARRIED_STRIDE))
	_snap.carried = keep
	_captured()


func _part(n: String) -> Node3D:
	return _rig.gun.model.get_node_or_null(n) as Node3D if _rig.gun.model != null else null


func _mag_shown() -> bool:
	var m := _part("Magazine")
	return m != null and m.visible


func _clean() -> bool:
	return _world.hidden_items.is_empty() and _actions.pending_count() == 0 and _hands.proxy("vr_l") == null \
			and _hands.proxy("vr_r") == null and _hands.holding("vr_l").is_empty() and _hands.holding("vr_r").is_empty()


## The gun in the main hand by its Grip marker, the bore along the hand; VrHeld hidden there; left-handed in the left
## hand; the main grip on nothing just holds it.
func _test_shown() -> void:
	var g := _rig.gun
	_rig.show_held({"main": {"name": "Glock"}, "off": {}})
	_check.call(_rig.right_held.visible and not g.shown, "vr gun: (CDDA's wielded item shows on the main hand before the first frame)")
	_frame()
	var want := _rig.right.global_transform * VrGun.GRIP_FROM_AIM
	var grip := _part("Grip")
	var bore := (-g.part_pose("Muzzle").basis.z).normalized()
	_check.call(g.shown and g.visible and g.shape == "pistol" and grip != null
			and grip.global_position.distance_to(want.origin) < 0.001
			and bore.dot((-_rig.right.global_basis.z).normalized()) > 0.999 and not _rig.right_held.visible,
			"vr gun: the wielded gun shows in the main hand, its Grip at the grip pose, the bore along the hand; VrHeld hidden")
	_check.call(g.gun != null and g.gun.uid == _gun and g.mag != null and g.mag.uid == _mag and g.loaded() and _mag_shown()
			and g.jam == "" and g.grime == 0.0, "vr gun: its carried rows: the magazine is in (shown)")
	_rig.settings["main_hand"] = "left"
	_frame()
	var lwant := _rig.left.global_transform * VrGun.GRIP_FROM_AIM
	_check.call(g.shown and _part("Grip").global_position.distance_to(lwant.origin) < 0.001 and not _rig.left_held.visible,
			"vr gun: left-handed: in the left hand, its VrHeld hidden")
	_rig.settings["main_hand"] = "right"
	_frame()
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "grip_click")
	_check.call(_hands.holding("vr_r").is_empty() and _hands.proxy("vr_r") == null and _rig.buzzes == b and g.shown,
			"vr gun: the main grip on nothing holds the gun: nothing adopted, no buzz")
	_rig.release(_rig.right, "grip_click")
	_check.call(_clean() and g.shown and _row(_gun) == [0, Snapshot.CARRIED_WIELDED], "vr gun: ... and letting go keeps it in CDDA's hand")


## Trigger with a fire request: flown from the Muzzle pose (fire_from), a kick and a buzz; a kill buzzes harder;
## live_aim follows the muzzle; no request: `fire` queued once and fired when its request shows (or given up after
## FIRE_WAIT_S); a busy game buzzes; a request the client can't fly: plain FIRE.
func _test_fire() -> void:
	var g := _rig.gun
	_aim.on_request(_req)
	_ui.show_request(_req)
	_answers.clear()
	_frame()
	var muzzle := g.part_pose("Muzzle")
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	var a: Dictionary = _answers[0] if _answers.size() == 1 else {}
	var shot: Dictionary = a.get("shot", {})
	var o: Variant = _aim.shot_aim.get("origin")
	var s: Variant = _aim.shot_aim.get("sight")
	_check.call(a.get("action") == "FIRE" and shot.get("fly") == true and o is Vector3 and (o as Vector3).distance_to(muzzle.origin) < 0.001
			and s is Vector3 and (s as Vector3).dot((-muzzle.basis.z).normalized()) > 0.999 and g.kicks == 1
			and _rig.buzzes[1] == b[1] + 1 and _rig.buzz_amp[1] == VrGun.SHOT_AMP and _rig.buzzes[0] == b[0] and _sent.is_empty(),
			"vr gun: the main trigger fires from the Muzzle pose (fire_from), kicks and buzzes once (hit %s)" % [shot.get("hit_uid")])
	_frame()
	var kicked := _part("Muzzle").global_position.distance_to(muzzle.origin)
	for i in 4:
		_frame(0.25)
	_check.call(kicked > 0.005 and _part("Muzzle").global_position.distance_to(muzzle.origin) < 0.001,
			"vr gun: the model kicks (%.3f m at the muzzle) and settles back" % kicked)
	b = _rig.buzzes.duplicate()
	_aim.hits.hit_confirmed.emit(ZUID, "torso", 12, false)
	var plain_hit := _rig.buzzes == b
	_aim.hits.hit_confirmed.emit(ZUID, "head", 30, true)
	_check.call(plain_hit and _rig.buzzes[1] == b[1] + 1 and _rig.buzz_amp[1] == VrGun.KILL_AMP,
			"vr gun: a confirmed kill buzzes the main hand harder (a hit alone doesn't)")
	var lp: Variant = _aim.live_aim.call() if _aim.live_aim.is_valid() else null
	_rig.right.global_position += Vector3(0.1, 0.05, 0.0)
	_frame()
	var lp2: Variant = _aim.live_aim.call() if _aim.live_aim.is_valid() else null
	_check.call(lp is Dictionary and lp2 is Dictionary and (lp as Dictionary).get("origin") is Vector3
			and ((lp2 as Dictionary)["origin"] as Vector3).distance_to(g.part_pose("Muzzle").origin) < 0.0001
			and ((lp2 as Dictionary)["origin"] - (lp as Dictionary)["origin"]).distance_to(Vector3(0.1, 0.05, 0.0)) < 0.001,
			"vr gun: live_aim follows the muzzle (bursts fly from the hand)")
	_rest_hands()
	_frame()

	# no request: CDDA's fire, once; the shot when its request shows
	_ui.clear()
	_answers.clear()
	b = _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	_rig.press(_rig.right, "trigger_click")
	_check.call(_sent == ["fire"] and g.fire_wait > 0.0 and _answers.is_empty() and _rig.buzzes == b,
			"vr gun: no fire request: CDDA's fire action is queued once, however often the trigger is pulled")
	_aim.on_request(_req)
	_ui.show_request(_req)
	_frame()
	a = _answers[0] if _answers.size() == 1 else {}
	_check.call(a.get("action") == "FIRE" and (a.get("shot", {}) as Dictionary).get("fly") == true and g.fire_wait == 0.0
			and g.kicks == 2, "vr gun: ... and fires from the muzzle when its request shows")
	_answers.clear()
	_rig.press(_rig.right, "trigger_click")
	for i in 4:
		_frame(1.0)
	_ui.show_request(_req)
	_frame()
	_check.call(_sent == ["fire", "fire"] and g.fire_wait == 0.0 and _answers.is_empty(),
			"vr gun: a fire request later than %.0f s isn't fired at" % VrGun.FIRE_WAIT_S)
	_ui.clear()
	_accept = false
	b = _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	_check.call(_sent.size() == 3 and g.fire_wait == 0.0 and _rig.buzzes[1] == b[1] + 1,
			"vr gun: the game can't take the fire now: a buzz, nothing waits")
	_accept = true

	# a fire request the client doesn't fly (another gun firing): plain FIRE at the square the muzzle meets, never at
	# CDDA's own pick (its cursor is on the player's square here)
	var other := _req.duplicate()
	other["weapon_wielded"] = false
	_aim.on_request(other)
	_ui.show_request(other)
	_answers.clear()
	_frame()
	var msq: Variant = g.muzzle_square()
	_rig.press(_rig.right, "trigger_click")
	a = _answers[0] if _answers.size() == 1 else {}
	_check.call(msq == ZP and a.get("action") == "FIRE" and a.get("pos") == ZP and not a.has("shot") and g.kicks == 3
			and _sent.size() == 3, "vr gun: a fire request it can't fly gets plain FIRE at the muzzle's square (%s)" % [a])
	_aim.on_request(other)
	_ui.show_request(other)
	_answers.clear()
	var hand := _rig.right.global_position
	_rig.right.look_at(hand + Vector3(0.0, -1.0, 0.01), Vector3(0, 0, -1))   # the muzzle at the floor at your feet
	_frame()
	var down: Variant = g.muzzle_square()
	b = _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	_check.call(down == P and _answers.is_empty() and g.kicks == 3 and _rig.buzzes[1] == b[1] + 1
			and _aim.request_ui.target_widget() != null, "vr gun: ... the muzzle at your own square: no shot, a buzz")
	_rest_hands()
	_frame()
	_aim.on_request(_req)
	_ui.clear()
	_answers.clear()


## The off grip at the well: the magazine comes out into CDDA's off hand and the off hand holds it.
func _test_mag_out() -> void:
	var g := _rig.gun
	var well := g.part_pose("MagWell")
	_rig.left.global_transform = Transform3D(well.basis, well.origin + Vector3(0.02, -0.02, 0.0))
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.left, "grip_click")   # held through _test_mag_in
	var l: ItemRef = _hands.holding("vr_l").get("item")
	var row := _row(_mag)
	_frame()
	_check.call(l != null and l.uid == _mag and l.is_off_hand() and not row.is_empty() and row[0] != _gun
			and _row(_round) == [_mag, 0] and _hands.proxy("vr_l") != null and g.mag == null and not g.loaded()
			and not _mag_shown() and g.mag_copy() == null and _rig.buzzes == b,
			"vr gun: the off grip at the well takes the magazine out into CDDA's off hand; the off hand holds it")
	_frame()
	_check.call(_hands.holding("vr_l").get("item") != null and _row(_mag)[0] != _gun,
			"vr gun: ... it isn't put straight back while the hand is still at the well")


## The held magazine to the well: turned away or too far does nothing; refused: back in the hand with CDDA's reason,
## no retry until the hand moved away; turned its way and close: reloaded, the hand empty, the gun shows it.
func _test_mag_in() -> void:
	var g := _rig.gun
	_rig.left.global_position = g.part_pose("MagWell").origin + Vector3(0, -0.3, 0)
	_frame()
	var well := g.part_pose("MagWell")
	_rig.left.global_transform = Transform3D(well.basis * Basis(Vector3(0, 0, 1), PI / 2.0), well.origin)
	_frame()
	var turned: bool = _hands.holding("vr_l").get("item") != null and _row(_mag)[0] != _gun
	_rig.left.global_transform = Transform3D(well.basis, well.origin - well.basis.y * 0.08)
	_frame()
	var far: bool = _hands.holding("vr_l").get("item") != null and _row(_mag)[0] != _gun
	_check.call(turned and far and _actions.pending_count() == 0,
			"vr gun: a magazine at the well turned sideways, or 8 cm short of it: nothing")
	_mock.reload_check = func(_t: int, _a: int) -> String: return "That magazine doesn't fit your Glock."
	var b := _rig.buzzes.duplicate()
	var n := _refusals
	_rig.left.global_transform = Transform3D(well.basis, well.origin)
	_frame()
	var l: ItemRef = _hands.holding("vr_l").get("item")
	_check.call(_refusals == n + 1 and l != null and l.uid == _mag and _row(_mag)[0] != _gun and _rig.buzzes[0] == b[0] + 1
			and _rig.notes[0] != null and _rig.notes[0].visible and _rig.notes[0].text == "That magazine doesn't fit your Glock.",
			"vr gun: refused reload: the magazine is back in the off hand, a buzz and CDDA's reason by it")
	_frame()
	_frame()
	_check.call(_refusals == n + 1, "vr gun: ... no retry while the hand stays at the well")
	_mock.reload_check = Callable()
	_rig.left.global_position = well.origin + Vector3(0, -0.3, 0)
	_frame()
	_rig.left.global_transform = Transform3D(well.basis, well.origin + Vector3(0.01, -0.02, 0.0))
	_frame()
	var empty := _hands.holding("vr_l").is_empty() and _hands.proxy("vr_l") == null
	_frame()
	_check.call(empty and _row(_mag) == [_gun, 0] and _row(_round) == [_mag, 0] and g.mag != null and g.mag.uid == _mag
			and _mag_shown() and _clean(), "vr gun: the magazine to the well, turned its way: reloaded; the hand lets go, the gun shows it")
	_rig.release(_rig.left, "grip_click")
	_check.call(_clean() and _row(_mag) == [_gun, 0], "vr gun: ... letting the grip go then does nothing")


## CDDA's off hand is full: the unload is refused, the magazine snaps back, a buzz and the reason by the off hand.
func _test_mag_out_refused() -> void:
	var g := _rig.gun
	var rock := _mock.give(_it["rock"], 0, Snapshot.CARRIED_OFFHAND)
	_captured()
	_frame()
	var well := g.part_pose("MagWell")
	_rig.left.global_transform = Transform3D(well.basis, well.origin)
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.left, "grip_click")
	_frame()
	_check.call(_rig.buzzes[0] == b[0] + 1 and _rig.notes[0].visible and _rig.notes[0].text.begins_with("Your off hand is full")
			and _hands.holding("vr_l").is_empty() and _row(_mag) == [_gun, 0] and g.mag_copy() == null and _mag_shown(),
			"vr gun: refused magazine out: it snaps back, a buzz and CDDA's reason by the off hand")
	_rig.release(_rig.left, "grip_click")
	_remove(rock)
	_frame()
	_check.call(_clean(), "vr gun: (the off hand's rock gone)")


## A magazine that doesn't land at once: its copy rides in the off hand meanwhile; the grip let go before it lands:
## it is let go where the hand is (dropped).
func _test_mag_pending() -> void:
	var g := _rig.gun
	var later := Later.new()
	_actions.backend = later
	var well := g.part_pose("MagWell")
	_rig.left.global_transform = Transform3D(Basis(), well.origin + Vector3(0.0, -0.03, 0.0))
	_rig.press(_rig.left, "grip_click")
	_rig.left.global_position += Vector3(-0.1, -0.1, 0.05)
	_frame()
	var copy := g.mag_copy()
	_check.call(later.calls.size() == 1 and later.calls[0][0] == _gun and later.calls[0][3] == "off" and copy != null
			and copy.is_visible_in_tree() and copy.global_position.distance_to(_rig.left.global_position) < 0.001
			and not _mag_shown() and _hands.holding("vr_l").is_empty() and _actions.pending(_gun) == "unload",
			"vr gun: while the magazine comes out its copy rides in the off hand (the gun's hidden)")
	_rig.release(_rig.left, "grip_click")
	_actions.backend = _mock
	_mock.unload_item(float(_gun), float(_it["glock_19"]), P, "off")
	_frame()
	_check.call(g.mag_copy() == null and _row(_mag).is_empty() and _row(_round).is_empty() and _clean()
			and not g.loaded() and not _mag_shown(), "vr gun: the grip let go before it landed: the magazine is let go (dropped)")


## A jam shows by the main hand and holds the slide open; racking the slide back past RACK_PULL_M and letting go queues
## reload_weapon on a jammed gun once per jam, only buzzes on a clean one; a short pull does nothing.
func _test_rack() -> void:
	var g := _rig.gun
	var b := _rig.buzzes.duplicate()
	_snap.player_gun["faults"] = ["fault_stovepipe"]
	_captured()
	_frame()
	var sp := g.part_pose("Slide")
	var slide := _part("Slide")
	_check.call(g.jam == "fault_stovepipe" and _rig.buzzes[1] == b[1] + 1 and _rig.notes[1] != null and _rig.notes[1].visible
			and _rig.notes[1].text == "Stovepipe: rack the slide to clear"
			and slide.global_position.distance_to(sp * Vector3(0, 0, WeaponViewmodel.JAM_BACK)) < 0.001,
			"vr gun: a jam: its name and how to clear it by the main hand, a buzz, the slide held open")
	var n := _sent.size()
	_check.call(_rack(sp, 0.06) and _sent.size() == n and g.racks == 1 and g.jam == "" and _clean()
			and slide.global_position.distance_to(sp.origin) < 0.001,
			"vr gun: racked a jammed gun: ItemActions.clear_jam clears it (CDDA's mend, no reload), the slide closes, a buzz")
	# without clear_jam (an older ItemActions): CDDA's reload_weapon, once per jam
	var acts := g.actions
	g.actions = null
	_snap.player_gun["faults"] = ["fault_stovepipe"]
	_captured()
	_frame()
	_check.call(_rack(sp, 0.06) and _sent.size() == n + 1 and _sent[-1] == "reload_weapon" and g.racks == 2,
			"vr gun: no clear_jam: CDDA's reload_weapon queued (the fork mends the jam)")
	_check.call(_rack(sp, 0.06) and _sent.size() == n + 1 and g.racks == 3 and _rig.notes[0] != null and _rig.notes[0].visible
			and _rig.notes[0].text == VrGun.CLEARING,
			"vr gun: racked again before the jam clears: nothing more queued (it would reload the cleared gun)")
	_snap.player_gun["faults"] = []
	_captured()
	_frame()
	_check.call(g.jam == "" and slide.global_position.distance_to(sp.origin) < 0.001, "vr gun: jam cleared: the slide closes")
	n = _sent.size()
	_check.call(_rack(sp, 0.06) and _sent.size() == n and g.racks == 4, "vr gun: racked a clean gun: only the motion and a buzz")
	b = _rig.buzzes.duplicate()
	_rig.left.global_transform = Transform3D(sp.basis, sp * Vector3(0, 0.03, 0.09))
	_rig.press(_rig.left, "grip_click")
	_rig.left.global_position = sp * Vector3(0, 0.03, 0.11)
	_frame()
	_rig.release(_rig.left, "grip_click")
	_check.call(_rig.buzzes == b and g.racks == 4 and _sent.size() == n and not g.racking() and _clean(),
			"vr gun: a short pull: nothing")
	_accept = false
	_snap.player_gun["faults"] = ["fault_double_feed"]
	_captured()
	_frame()
	_check.call(_rack(sp, 0.06) and _sent.size() == n + 1 and _rig.notes[0].visible and _rig.notes[0].text == VrGun.CANT_CLEAR,
			"vr gun: a rack the game can't take now says so")
	_accept = true
	g.actions = acts
	_snap.player_gun["faults"] = []
	_captured()
	_frame()


## The off hand grips the slide (slide pose `sp`) at its back and pulls it `pull` m back along the bore, then lets go:
## the slide followed the hand (at most RACK_TRAVEL) and the let go buzzed once.
func _rack(sp: Transform3D, pull: float) -> bool:
	var g := _rig.gun
	var b := _rig.buzzes.duplicate()
	_rig.left.global_transform = Transform3D(sp.basis, sp * Vector3(0, 0.03, 0.09))
	_rig.press(_rig.left, "grip_click")
	var holding := g.racking() and _hands.holding("vr_l").is_empty()
	_rig.left.global_position = sp * Vector3(0, 0.03, 0.09 + pull)
	_frame()
	var back := _part("Slide").global_position.distance_to(sp.origin)
	_rig.release(_rig.left, "grip_click")
	_frame()
	return holding and absf(back - minf(pull, VrGun.RACK_TRAVEL)) < 0.001 and not g.racking() \
			and _rig.buzzes[0] == b[0] + 1 and _rig.buzzes[1] == b[1]


## A long gun (here not in the carried rows): its bolt, held by its grip; a jam says to rack the bolt.
func _test_long_gun() -> void:
	var g := _rig.gun
	_snap.player_gun = {"type": _it["remington_870"], "dirt": 6000, "faults": ["fault_double_feed"], "rounds": 4}
	_captured()
	_frame()
	var want := _rig.right.global_transform * VrGun.GRIP_FROM_AIM
	_check.call(g.shape == "long" and _part("Bolt") != null and _part("Grip").global_position.distance_to(want.origin) < 0.001
			and g.gun == null and g.loaded() and _mag_shown() and is_equal_approx(g.grime, 0.6)
			and _rig.notes[1].text == "Double feed: rack the bolt to clear",
			"vr gun: a long gun: held by its grip, its bolt; no carried row: rounds say it's loaded; grime; the jam note")
	var m := g.model
	_snap.player_gun["dirt"] = 2000
	_snap.player_gun["rounds"] = 0
	_captured()
	_frame()
	var mats := WeaponViewmodel.grime_materials(g.model)
	_check.call(g.model == m and is_equal_approx(g.grime, 0.2) and not mats.is_empty()
			and is_equal_approx(float(mats[0].get_shader_parameter("grime")), 0.2) and not _mag_shown(),
			"vr gun: dirt and rounds change the parts in place (no rebuild)")
	_snap.player_gun = {"type": _it["glock_19"], "dirt": 0, "faults": [], "rounds": 0}
	_captured()
	_frame()


## Junk in player_gun: no gun, or a pistol with junk ignored; a long fault list is capped.
func _test_hostile() -> void:
	var g := _rig.gun
	var gt: int = _it["glock_19"]
	var many: Array = []
	for i in 100:
		many.append("fault_stovepipe" if i == 50 else "x".repeat(i))
	var cases := [
		[{"type": "x"}, false, ""], [{"type": -5}, false, ""], [{"type": 1 << 40}, false, ""], [{"type": NAN}, false, ""],
		[{"faults": ["fault_stovepipe"]}, false, ""], [{"type": [gt]}, false, ""],
		[{"type": gt, "faults": "junk", "dirt": "x", "rounds": INF}, true, ""],
		[{"type": float(gt), "faults": [1, null, {}, "fault_stovepipe"], "dirt": 1e30}, true, "fault_stovepipe"],
		[{"type": gt, "faults": many}, true, ""],
		[{"type": _it["rock"], "faults": []}, true, ""],
	]
	var got := []
	var ok := true
	for c: Array in cases:
		_snap.player_gun = c[0]
		_captured()
		_frame()
		got.append([g.shown, g.shape, g.jam])
		ok = ok and g.shown == c[1] and g.jam == c[2] and (g.shape == "pistol" if c[1] else g.shape == "") and g.dirt <= 10000
	_check.call(ok, "vr gun: junk player_gun data: no gun, or a pistol with the junk ignored (%s)" % [got])
	_snap.player_gun = {"type": gt, "dirt": 0, "faults": [], "rounds": 0}
	_captured()
	_frame()
	_check.call(g.shown and g.shape == "pistol" and g.jam == "", "vr gun: (back to the clean pistol)")


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


## With a gun the main trigger fires even at stairs and no pull ray shows; without one: hidden, VrHeld back, stairs,
## the pull and the buzz for nothing work as before.
func _test_no_gun() -> void:
	var g := _rig.gun
	var rock := -1
	var h := (_snap.submaps[CddaCoords.ms_to_sm(E)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(E) and h[i + 2] == _it["rock"]:
			rock = h[i + 1]
	var s := _world.item_slot(rock)
	var at_rock: Vector3 = s[3] if not s.is_empty() else Vector3.INF
	_rig.right.global_position = at_rock + Vector3(0.05, 0.8, 0.3)
	_rig.right.look_at(at_rock, Vector3.UP)
	_rig.trigger_in[1] = HALF
	_frame(VrRig.PULL_RAY_S * 1.2)
	_check.call(g.shown and not _rig.pull_rays[1].visible and _hands.hovered("vr_r").is_empty(),
			"vr gun: a finger on the gun's trigger points no pull ray")
	var up: Variant = _find_kind(0, TerrainCatalog.Kind.STAIRS_UP)
	var used := []
	_rig.stair_used.connect(func(st: Dictionary) -> void: used.append(st))
	_rig.live_stairs = true   # the ghost stays: only the trigger's choice is tested
	if up != null:
		var at := _world.coords.ms_center_to_world(up)
		_rig.right.global_position = at + Vector3(0.6, 1.2, 0.0)
		_rig.right.look_at(at, Vector3.UP)
		var n := _sent.size()
		_rig.press(_rig.right, "trigger_click")
		_check.call(used.is_empty() and _sent.size() == n + 1 and _sent[-1] == "fire",
				"vr gun: with a gun the main trigger fires (CDDA's fire), even pointed at stairs")
	_snap.carried = PackedInt64Array()
	_snap.player_wielded = 0
	_snap.player_gun = {}
	_captured()
	_frame()
	_check.call(not g.shown and not g.visible and g.model == null and g.fire_wait == 0.0 and _rig.right_held.visible,
			"vr gun: no gun wielded: hidden, CDDA's hand shows on the main hand again")
	if up != null:
		_rig.press(_rig.right, "trigger_click")
		_check.call(used.size() == 1, "vr gun: no gun: pointed stairs take the main trigger again")
	_rig.live_stairs = false
	_rig.go_to_square(P)
	_rig.show_held({"main": {}, "off": {}})
	_rig.right.global_position = at_rock + Vector3(0.05, 0.8, 0.3)
	_rig.right.look_at(at_rock, Vector3.UP)
	_frame(VrRig.PULL_RAY_S * 1.2)
	var lit := _rig.pull_rays[1].visible
	_rig.press(_rig.right, "trigger_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	_check.call(lit and r != null and r.uid == rock and r.is_wielded(), "vr gun: no gun: the main trigger pulls the pointed item")
	_frame(VrRig.FLY_S * 1.1)
	_rig.right.global_position = _world.coords.ms_center_to_world(E) + Vector3(-0.2, 0.3, 0.2)
	_rig.press(_rig.right, "grip_click")
	_rig.release(_rig.right, "grip_click")
	var head := _rig.camera.global_position
	_rig.right.global_position = head + Vector3(0.2, -0.3, -0.3)
	_rig.right.look_at(_rig.right.global_position + Vector3(0, 1, -0.3), Vector3.UP)
	_frame(VrRig.PULL_RAY_S * 1.2)
	var b := _rig.buzzes.duplicate()
	_rig.press(_rig.right, "trigger_click")
	_check.call(_rig.buzzes[1] == b[1] + 1 and _hands.holding("vr_r").is_empty() and _clean(),
			"vr gun: no gun: nothing pointed is one buzz, as before")
	_rig.trigger_in[1] = -1.0
