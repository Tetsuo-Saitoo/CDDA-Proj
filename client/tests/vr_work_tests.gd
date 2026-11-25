extends RefCounted
## C6 vehicle work by hand, slice 1 (VrWork): the part of a vehicle next to the player an empty hand is in (the one
## it is most in for its size), else with the trigger half pressed the one nearest where the pull ray meets the
## vehicle; junk anchors and vehicles out of reach never; the right hand's pick lit, else the left's; looked for
## again only every PICK_MS; none while driving, holding something or with a menu up. Run by run_tests.gd.

const UID := 21

var _check: Callable
var _anchors := {}       # what the part_anchors stub answers for UID
var _lights: Array = []  # highlight calls
var _hit: Variant = {}   # what the ray stub answers
var _rays := 0
var _hides: Array = []   # hide_part calls


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr vehicle work by hand")
	var veh := Snapshot.Vehicle.new()
	veh.uid = UID
	veh.pos = Vector3i(10, 10, 0)
	# two squares: [mount x, mount y, vpart, hp_frac, state, dx, dy, dz]
	veh.parts = PackedInt32Array([0, 0, 1, 255, 0, 0, 0, 0, 1, 0, 1, 255, 0, 1, 0, 0])
	_anchors = {0: {"point": Vector3(0.0, 1.0, 0.0), "normal": Vector3.UP, "size": 0.4},
			1: {"point": Vector3(0.5, 1.0, 0.0), "normal": Vector3.UP, "size": 1.0},
			2: {"point": Vector3(NAN, 1.0, 0.0), "size": 0.5}, 3: {"point": Vector3(5.0, 1.0, 0.0), "size": 1e9},
			4: {"point": Vector3(-3.0, 1.0, 0.0)}, "x": {"point": Vector3(-5.0, 1.0, 0.0), "size": 0.4}}
	var snap := _snap(veh, Vector3i(9, 10, 0), false)   # next to its first square
	_test_pick(snap, veh)
	_test_update(snap, veh)
	_test_rig(root, snap)
	_test_menu(snap)
	_test_rig_menu(root, snap, veh)
	_test_rig_tool(root, snap)
	_test_pull(root)
	_test_rig_pull(root, snap)
	_test_install(snap)
	_test_rig_install(root, snap)


static func _snap(veh: Snapshot.Vehicle, at: Vector3i, driving: bool) -> Snapshot:
	var s := Snapshot.new()
	s.vehicles = [veh] as Array[Snapshot.Vehicle]
	s.vehicles_moved()
	s.player_pos = at
	s.player_driving = driving
	s.player_vehicle = UID if driving else 0
	return s


func _work() -> VrWork:
	var w := VrWork.new()
	w.anchors = func(uid: int) -> Dictionary: return _anchors if uid == UID else {}
	w.highlight = func(uid: int, row: int) -> void: _lights.append([uid, row])
	w.ray = func(_o: Vector3, _d: Vector3, _m: float) -> Variant:
		_rays += 1
		return _hit
	return w


## Touch: the part the hand is most in for its size; junk anchors and a vehicle out of reach never. The pull ray: the
## part nearest where it meets the vehicle.
func _test_pick(snap: Snapshot, veh: Snapshot.Vehicle) -> void:
	var w := _work()
	var small: bool = w.touch(Vector3(0.0, 1.1, 0.0), snap) == {"uid": UID, "row": 0}
	var big: bool = w.touch(Vector3(0.6, 1.0, 0.0), snap) == {"uid": UID, "row": 1}
	var off: bool = w.touch(Vector3(0.0, 3.0, 0.0), snap).is_empty()
	var junk: bool = w.touch(Vector3(5.0, 1.0, 0.0), snap).is_empty() and w.touch(Vector3(-3.0, 1.0, 0.0), snap).is_empty() \
			and w.touch(Vector3(-5.0, 1.0, 0.0), snap).is_empty() and w.touch(Vector3(NAN, 1.0, 0.0), snap).is_empty()
	var far: bool = w.touch(Vector3(0.0, 1.1, 0.0), _snap(veh, Vector3i(20, 20, 0), false)).is_empty() \
			and w.touch(Vector3(0.0, 1.1, 0.0), null).is_empty()
	var ray: bool = w.nearest(UID, Vector3(0.45, 1.0, 0.0), snap) == {"uid": UID, "row": 1} \
			and w.nearest(UID, Vector3(0.0, 2.0, 0.0), snap).is_empty() and w.nearest(99, Vector3(0.45, 1.0, 0.0), snap).is_empty() \
			and w.nearest(UID, Vector3(0.45, 1.0, 0.0), _snap(veh, Vector3i(20, 20, 0), false)).is_empty()
	_check.call(small and big and off and junk and far and ray,
			"vr work: a hand in a part's spot picks the one it is most in for its size, the pull ray the one nearest where it meets the vehicle; junk anchors and vehicles out of reach never (%s)"
			% [[small, big, off, junk, far, ray]])


## Per frame: looked for again every PICK_MS; the right hand's pick lit, else the left's, each change once; not free,
## not pointing (no ray) or driving: nothing.
func _test_update(snap: Snapshot, veh: Snapshot.Vehicle) -> void:
	var w := _work()
	_lights.clear()
	var a := Vector3(0.0, 1.1, 0.0)
	var b := Vector3(0.6, 1.0, 0.0)
	w.update(1, a, Vector3.FORWARD, true, false, snap, 1000)
	w.update(1, a, Vector3.FORWARD, true, false, snap, 1050)
	var lit: bool = w.picked[1] == {"uid": UID, "row": 0} and _lights == [[UID, 0]]
	w.update(1, b, Vector3.FORWARD, true, false, snap, 1050)   # too soon: still row 0
	var waits: bool = w.picked[1] == {"uid": UID, "row": 0}
	w.update(1, b, Vector3.FORWARD, true, false, snap, 1100)
	w.update(0, a, Vector3.FORWARD, true, false, snap, 1100)   # the left hand's pick: the right's stays lit
	var right: bool = _lights == [[UID, 0], [UID, 1]] and w.picked[0] == {"uid": UID, "row": 0}
	w.update(1, b, Vector3.FORWARD, false, false, snap, 1150)   # the right hand takes something: the left's lit
	w.update(0, a, Vector3.FORWARD, false, false, snap, 1150)
	var off: bool = _lights == [[UID, 0], [UID, 1], [UID, 0], [UID, -1]] and w.lit.is_empty()
	_hit = {"hit": true, "vehicle": UID, "point": Vector3(0.45, 1.0, 0.0)}
	_rays = 0
	var up := Vector3(0.0, 3.0, 0.0)
	w.update(1, up, Vector3.FORWARD, true, false, snap, 2000)   # touching nothing, not pointing: no ray
	var no_ray: bool = _rays == 0 and w.picked[1].is_empty()
	w.update(1, up, Vector3.FORWARD, true, true, snap, 2100)
	var pointed: bool = _rays == 1 and w.picked[1] == {"uid": UID, "row": 1} and _lights.back() == [UID, 1]
	_hit = {"hit": true, "vehicle": 99, "point": Vector3(0.45, 1.0, 0.0)}
	w.update(1, up, Vector3.FORWARD, true, true, snap, 2200)
	var other: bool = w.picked[1].is_empty()
	_hit = "junk"
	w.update(1, up, Vector3.FORWARD, true, true, snap, 2300)
	var junk: bool = w.picked[1].is_empty()
	w.update(1, a, Vector3.FORWARD, true, false, _snap(veh, Vector3i(9, 10, 0), true), 2400)
	var driving: bool = w.picked[1].is_empty()
	w.update(1, a, Vector3.FORWARD, true, false, snap, 2500)
	w.clear()
	var cleared: bool = w.picked == [{}, {}] and _lights.back() == [UID, -1]
	_hit = {}
	_check.call(lit and waits and right and off and no_ray and pointed and other and junk and driving and cleared,
			"vr work: looked for again every %d ms; the right hand's pick lit, else the left's, once a change; the pull ray only while pointing; nothing while holding something or driving (%s)"
			% [VrWork.PICK_MS, [lit, waits, right, off, no_ray, pointed, other, junk, driving, cleared, _lights]])


## The rig: an empty hand in a part's spot picks it (update_hands); a menu up, nothing.
func _test_rig(root: Node, snap: Snapshot) -> void:
	var world := WorldView.new()
	world.snapshot = snap
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	var w := _work()
	rig.work = w
	_lights.clear()
	rig.right.global_position = Vector3(0.0, 1.1, 0.0)
	rig.left.global_position = Vector3(0.0, -4.0, 0.0)
	rig.update_hands(0.016, true)
	var picks: bool = w.picked[1] == {"uid": UID, "row": 0} and _lights == [[UID, 0]]
	rig.toggle_menu()
	rig.update_hands(0.016, true)
	var menu: bool = w.picked[1].is_empty() and _lights.back() == [UID, -1]
	rig.toggle_menu()
	rig.hands = null
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	world.free()
	_check.call(picks and menu, "vr work rig: an empty hand in a part's spot picks and lights it; a menu up, nothing (%s)"
			% [[picks, menu]])


## The work wheel: only its part's read is shown (CDDA's, or the stand-in); the hand off its middle or a stick points;
## what the read refuses is greyed with its reason, an allowed command lists what it needs; junk is ignored.
func _test_menu(snap: Snapshot) -> void:
	var m := VrWorkMenu.new()
	var head := Transform3D(Basis(), Vector3(0.0, 1.5, 1.0))
	m.open(1, Vector3(NAN, 1.0, 0.0), head, UID, 0)
	var junk_open: bool = not m.is_open()
	var at := Vector3(0.0, 1.0, 0.0)
	m.open(1, at, head, UID, 0)
	var opened: bool = m.is_open() and m.armed and m.read.is_empty() and m.panel_text().begins_with("Checking")
	m.set_read(VehicleWorkData.stand_in(snap, null, UID, 1))       # another part's
	m.set_read(VehicleWorkData.stand_in(snap, null, UID, -1))      # the list's
	m.set_read(VehicleWorkData.stand_in(snap, null, UID + 1, 0))   # another vehicle's
	m.set_read({"vehicle": "x", "ok": true})
	var others: bool = m.read.is_empty()
	m.set_read(VehicleWorkData.stand_in(snap, null, UID, 0))
	var kept: bool = not m.read.is_empty() and m.allowed("o") and not m.allowed("r") and not m.allowed("m") \
			and not m.why_not("r").is_empty() and m.why_not("o").is_empty()
	m.point(at + Vector3(0.0, 0.1, 0.0))
	var up: bool = m.pointed == "r" and m.panel_text().contains("Repair: " + m.why_not("r"))
	m.point(at + Vector3(0.1, 0.01, 0.0))
	var right: bool = m.pointed == "o" and m.panel_text().contains("Remove:") and m.panel_text().contains("10 minutes")
	m.point(at + Vector3(0.01, 0.01, 0.0))
	var middle: bool = m.pointed == ""
	m.point(at, Vector2(-0.9, 0.1))
	var stick: bool = m.pointed == "f"
	m.point(Vector3(NAN, 0.0, 0.0), Vector2(NAN, 0.0))
	var bad: bool = m.pointed == ""
	m.set_read({"ok": false, "vehicle": UID, "error": "busy"})
	var refused: bool = not m.allowed("o") and m.why_not("o") == "The game couldn't answer (busy)."
	m.close()
	m.set_read(VehicleWorkData.stand_in(snap, null, UID, 0))
	var closed: bool = not m.is_open() and m.read.is_empty() and not m.visible
	m.free()
	_check.call(junk_open and opened and others and kept and up and right and middle and stick and bad and refused and closed,
			"vr work menu: only its part's read shown; the hand off the middle or a stick points; refused commands greyed with CDDA's reason, allowed ones list what they need (%s)"
			% [[junk_open, opened, others, kept, up, right, middle, stick, bad, refused, closed]])


## The rig: the trigger on a picked part opens the wheel there on main's session (the stand-in read without the game);
## let go in the middle it stays, on a greyed command it says why, on an allowed one it sends (not connected here:
## said and flashed) and closes; B, the hand moving away, or the session closing close it; out of reach, a note.
func _test_rig_menu(root: Node, snap: Snapshot, veh: Snapshot.Vehicle) -> void:
	var world := WorldView.new()
	world.snapshot = snap
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	var w := _work()
	rig.work = w
	var s := VehicleWorkSession.new()
	s.world = world
	rig.work_session = s
	s.part_focused.connect(func(row: int) -> void: _lights.append([-1, row]))   # main moves the one light (select)
	var m := rig.work_menu
	_lights.clear()
	var at := Vector3(0.0, 1.1, 0.0)
	rig.right.global_position = at
	rig.left.global_position = Vector3(0.0, -4.0, 0.0)
	rig.update_hands(0.016, true)
	rig.press(rig.right, "trigger_click")
	var opened: bool = m.is_open() and m.hand == 1 and m.uid == UID and m.row == 0 and s.uid == UID and s.selected == 0 \
			and m.allowed("o") and w.hold
	rig.release(rig.right, "trigger_click")
	rig.update_hands(0.016, true)
	var stays: bool = m.is_open() and not m.armed and w.picked[1] == {"uid": UID, "row": 0} and _lights == [[UID, 0], [-1, 0]]
	var b0: int = rig.buzzes[1]
	rig.right.global_position = at + Vector3(0.0, 0.1, 0.0)
	rig.update_wheel()
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var greyed: bool = m.is_open() and m.pointed == "r" and rig.buzzes[1] == b0 + 1 and rig.busy.get("_flash") == m.why_not("r")
	rig.right.global_position = at + Vector3(0.1, 0.0, 0.0)
	rig.update_wheel()
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var sent: bool = not m.is_open() and not w.hold and s.note == "Remove isn't connected to the game yet." \
			and rig.busy.get("_flash") == s.note
	rig.right.global_position = at
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var again: bool = m.is_open()
	rig.right.global_position = at + Vector3(0.0, 0.0, VrWorkMenu.AWAY_M + 0.1)
	rig.update_wheel()
	var away: bool = again and not m.is_open() and not w.hold
	rig.right.global_position = at
	rig.press(rig.right, "trigger_click")
	rig.press(rig.right, "by_button")
	var cancel: bool = not m.is_open() and not w.hold and _lights.back() == [UID, 0]   # the hand's pick lit again
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var far := _snap(veh, Vector3i(20, 20, 0), false)
	world.snapshot = far
	var n := _lights.size()
	s.follow(far)
	var gone: bool = not m.is_open() and s.uid == 0 and rig.busy.get("_flash") == VehicleWorkSession.GONE["too far"] \
			and _lights.size() == n + 1 and _lights.back() == [UID, 0]
	rig.busy.flash("-")
	var b1: int = rig.buzzes[1]
	var opens: bool = rig.open_work(rig.right)   # still picked; the vehicle now out of reach
	var refused: bool = opens and not m.is_open() and rig.buzzes[1] == b1 + 1 \
			and rig.busy.get("_flash") == VehicleWorkSession.GONE["too far"]
	rig.work_session = null
	var unwired: bool = s.result.get_connections().is_empty() and s.said.get_connections().is_empty()
	rig.hands = null
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	world.free()
	_check.call(opened and stays and greyed and sent and away and cancel and gone and refused and unwired,
			"vr work rig: the trigger on a picked part opens the wheel on main's session; let go in the middle it stays, on a greyed command it says why, on an allowed one it sends and closes; B, moving away or the session closing close it (%s)"
			% [[opened, stays, greyed, sent, away, cancel, gone, refused, unwired]])


## Repair by tool: an item in the hand on a part lights it; the trigger opens the session on it and, the part's read
## allowing repair, sends it (not connected here: said and flashed); an undamaged part: CDDA's reason and a buzz; a
## read come too late: nothing; an empty hand: the wheel's way, not this.
func _test_rig_tool(root: Node, snap: Snapshot) -> void:
	var hurt := Snapshot.Vehicle.new()   # the same car, its first part damaged
	hurt.uid = UID
	hurt.pos = Vector3i(10, 10, 0)
	hurt.parts = PackedInt32Array([0, 0, 1, 128, 0, 0, 0, 0, 1, 0, 1, 255, 0, 1, 0, 0])
	var damaged := _snap(hurt, Vector3i(9, 10, 0), false)
	var world := WorldView.new()
	world.snapshot = damaged
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	var w := _work()
	rig.work = w
	var s := VehicleWorkSession.new()
	s.world = world
	rig.work_session = s
	_lights.clear()
	rig.right.global_position = Vector3(0.0, 1.1, 0.0)
	rig.left.global_position = Vector3(0.0, -4.0, 0.0)
	hands.hand("vr_r").held = {"kind": "item", "item": ItemRef.new()}
	rig.update_hands(0.016, true)
	var lit: bool = w.picked[1] == {"uid": UID, "row": 0} and _lights == [[UID, 0]]
	var b0: int = rig.buzzes[1]
	rig.press(rig.right, "trigger_click")
	var sent: bool = s.uid == UID and s.selected == 0 and s.note == "Repair isn't connected to the game yet." \
			and rig.busy.get("_flash") == s.note and rig.get("_repair").is_empty() and not rig.work_menu.is_open()
	world.snapshot = snap   # repaired meanwhile
	rig.press(rig.right, "trigger_click")
	var why := VrWorkMenu.reason(VehicleWorkData.stand_in(snap, null, UID, 0), "r")
	var refused: bool = not why.is_empty() and rig.busy.get("_flash") == why and rig.buzzes[1] == b0 + 2
	world.snapshot = damaged
	rig.busy.flash("-")
	rig.set("_repair", {"uid": UID, "row": 0, "hand": 1, "until": 0})
	rig.call("_on_work_read", VehicleWorkData.stand_in(damaged, null, UID, 0))
	var late: bool = rig.busy.get("_flash") == "-" and rig.get("_repair").is_empty()
	hands.hand("vr_r").held = {}
	var empty: bool = not rig.work_tool(rig.right)
	rig.work_session = null
	rig.hands = null
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	world.free()
	_check.call(lit and sent and refused and late and empty,
			"vr work tool: an item in the hand on a part lights it; the trigger asks CDDA to repair it when its read allows, else says why and buzzes; a late read does nothing (%s)"
			% [[lit, sent, refused, late, empty]])


func _pull(p: VrPartPull, made: Array) -> void:
	p.part_copy = func(uid: int, row: int) -> Variant:
		if uid != UID or row > 1:
			return null
		var n := Node3D.new()
		n.transform = Transform3D(Basis(), Vector3(row, 1.0, 0.0))
		made.append(n)
		return n
	p.hide_part = func(uid: int, row: int, hidden: bool) -> bool:
		_hides.append([uid, row, hidden])
		return true


## Remove by hand: a gripped part's copy follows the hand with the original hidden; pulled PULL_M out it asks once;
## ended before CDDA started, it shows again at once; after, only when the work stops; no copy or a bad pose: nothing.
func _test_pull(root: Node) -> void:
	var p := VrPartPull.new()
	var made: Array = []
	_pull(p, made)
	_hides.clear()
	var parent := Node3D.new()
	root.add_child(parent)
	var hand := Transform3D(Basis(), Vector3(0.0, 1.1, 0.0))
	var none: bool = not p.grip(1, hand, UID, 5, parent) and not p.grip(1, Transform3D(Basis(), Vector3(NAN, 0.0, 0.0)), UID, 0, parent) \
			and _hides.is_empty() and p.hand == -1
	var gripped: bool = p.grip(1, hand, UID, 0, parent) and p.state == "held" and p.copy.is_inside_tree() and p.copy.top_level \
			and p.copy.global_position.is_equal_approx(Vector3(0.0, 1.0, 0.0)) and _hides == [[UID, 0, true]] \
			and not p.grip(0, hand, UID, 1, parent)
	var near: bool = not p.follow(hand.translated(Vector3(0.0, 0.0, 0.1))) and p.state == "held" \
			and p.copy.global_position.is_equal_approx(Vector3(0.0, 1.0, 0.1))
	var out: bool = p.follow(hand.translated(Vector3(0.0, 0.0, 0.2))) and p.state == "asked" \
			and not p.follow(hand.translated(Vector3(0.0, 0.0, 0.3)))
	p.end()   # refused: back in its spot
	var back: bool = p.hand == -1 and p.state == "" and _hides.back() == [UID, 0, false] and (made[0] as Node).is_queued_for_deletion()
	p.grip(1, hand, UID, 0, parent)
	p.follow(hand.translated(Vector3(0.0, 0.0, 0.2)))
	p.started()
	var n := _hides.size()
	p.end()
	p.settle(true)
	var kept: bool = _hides.size() == n and p.hand == -1
	p.settle(false)
	p.settle(false)
	var shown: bool = _hides.size() == n + 2 and _hides[n] == [UID, 0, false] and _hides.back() == [UID, -1, false]
	parent.free()
	_check.call(none and gripped and near and out and back and kept and shown,
			"vr work pull: a gripped part's copy follows the hand, the original hidden; pulled %d cm out it asks once; let go before CDDA starts it shows again, after only when the work stops (%s)"
			% [roundi(VrPartPull.PULL_M * 100.0), [none, gripped, near, out, back, kept, shown]])


## The rig: the grip on a picked part takes it into the hand on main's session; pulled out it asks for the removal
## (not connected here: it snaps back with the session's sentence); let go, refused or a read refusing it: back;
## started: it stays in the hand while the work runs, the original shown again once it stops.
func _test_rig_pull(root: Node, snap: Snapshot) -> void:
	var world := WorldView.new()
	world.snapshot = snap
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	rig.settings["grip"] = "hold"
	var w := _work()
	rig.work = w
	var s := VehicleWorkSession.new()
	s.world = world
	rig.work_session = s
	_pull(rig.pull, [])
	_hides.clear()
	var at := Vector3(0.0, 1.1, 0.0)
	rig.right.global_position = at
	rig.left.global_position = Vector3(0.0, -4.0, 0.0)
	rig.update_hands(0.016, true)
	rig.press(rig.right, "grip_click")
	var gripped: bool = rig.pull.hand == 1 and s.uid == UID and s.selected == 0 and w.hold and _hides == [[UID, 0, true]]
	rig.right.global_position = at + Vector3(0.0, 0.0, 0.1)
	rig.update_pull()
	var held: bool = rig.pull.state == "held" and rig.pull.copy.global_position.is_equal_approx(Vector3(0.0, 1.0, 0.1))
	rig.right.global_position = at + Vector3(0.0, 0.0, 0.2)
	rig.update_pull()
	var sent: bool = rig.pull.hand == -1 and not w.hold and _hides.back() == [UID, 0, false] \
			and s.note == "Remove isn't connected to the game yet." and rig.busy.get("_flash") == s.note
	rig.right.global_position = at
	rig.press(rig.right, "grip_click")
	rig.release(rig.right, "grip_click")
	var let_go: bool = rig.pull.hand == -1 and _hides.back() == [UID, 0, false] and _hides.size() == 4
	rig.press(rig.right, "grip_click")
	rig.call("_on_work_read", {"ok": false, "vehicle": UID, "error": "busy"})
	var read_no: bool = rig.pull.hand == -1 and rig.busy.get("_flash") == "The game couldn't answer (busy)."
	rig.press(rig.right, "grip_click")
	rig.pull.state = "asked"
	rig.call("_on_work_refused", "o", "No.")
	var refused: bool = rig.pull.hand == -1 and _hides.back() == [UID, 0, false]
	rig.press(rig.right, "grip_click")
	rig.pull.state = "asked"
	s.started.emit("o")
	snap.activity_id = "ACT_VEHICLE"
	rig.update_pull()
	var n := _hides.size()
	var runs: bool = rig.pull.hand == 1 and rig.pull.state == "started"
	snap.activity_id = ""
	rig.update_pull()
	var over: bool = rig.pull.hand == -1 and _hides.size() == n
	rig.update_pull()
	var shown: bool = _hides.size() == n + 2 and _hides[n] == [UID, 0, false] and _hides.back() == [UID, -1, false]
	rig.work_session = null
	rig.hands = null
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	world.free()
	_check.call(gripped and held and sent and let_go and read_no and refused and runs and over and shown,
			"vr work rig pull: the grip on a picked part takes it into the hand; pulled out it asks CDDA to remove it; let go, refused or a read refusing it: back; started: it stays in the hand while the work runs (%s)"
			% [[gripped, held, sent, let_go, read_no, refused, runs, over, shown]])


const INST := {"mount": Vector2i(1, 0), "reason": 0, "text": "", "types": [{"vpart": 3, "bits": 3},
		{"vpart": 4, "bits": 1}, {"vpart": 5, "bits": 2}, {"vpart": 6, "bits": 3}]}


## Install by hand: of CDDA's install read only the types the item serves that fit, in CDDA's order; the read for that
## square only; the square under a part's item lit; the list on the wheel picks by the hand's height or a stick push.
func _test_install(snap: Snapshot) -> void:
	var name_of := func(vp: int) -> String: return "type %d" % vp
	var rows := VrInstall.choices(INST, PackedInt32Array([5, 3, 4]), name_of)
	var picks: bool = rows.size() == 2 and rows[0]["vpart"] == 3 and rows[1]["vpart"] == 5 and rows[0]["have"] \
			and not rows[1]["have"] and rows[0]["name"] == "type 3" and VrInstall.choices(INST, PackedInt32Array([9]), name_of).is_empty()
	var r := {"ok": true, "vehicle": UID, "install": INST}
	var fors: bool = VrInstall.is_for(r, UID, Vector2i(1, 0)) and not VrInstall.is_for(r, UID, Vector2i(0, 0)) \
			and not VrInstall.is_for(r, UID + 1, Vector2i(1, 0)) and VrInstall.is_for({"ok": false, "vehicle": UID}, UID, Vector2i(5, 5)) \
			and not VrInstall.is_for({"ok": true, "vehicle": UID}, UID, Vector2i(1, 0)) \
			and not VrInstall.is_for({"vehicle": "x"}, UID, Vector2i(1, 0))
	var none: bool = VrInstall.types_for(null, 5).is_empty() and VrInstall.types_for(IdTables.new(), 5).is_empty()
	var t := IdTables.new()
	for k in 5:
		t.vpart.append(IdTables.Def.new())
	t.vpart[1].item = 9
	t.vpart[3].item = 9
	t.vpart[4].item = 2
	var served: bool = VrInstall.types_for(t, 9) == PackedInt32Array([1, 3]) and VrInstall.types_for(t, 2) == PackedInt32Array([4]) \
			and VrInstall.types_for(t, 7).is_empty() and VrInstall.types_for(t, 0).is_empty()
	t.vpart[2].item = 9
	t.generation += 1   # new tables: looked through again
	served = served and VrInstall.types_for(t, 9) == PackedInt32Array([1, 2, 3])
	var w := _work()
	w.square = func(uid: int, p: Vector3) -> Variant:
		return Vector2i(roundi(p.x), roundi(p.z)) if uid == UID and p.y < 2.0 else Vector2i.MAX
	w.light_square = func(uid: int, at: Vector2i) -> void: _lights.append([uid, at])
	_lights.clear()
	w.update_square(1, Vector3(1.0, 1.0, 0.0), true, snap, 1000)
	var sq: bool = w.picked[1] == {"uid": UID, "at": Vector2i(1, 0)} and _lights == [[UID, Vector2i(1, 0)]]
	w.update_square(1, Vector3(1.0, 3.0, 0.0), true, snap, 1100)
	var off: bool = w.picked[1].is_empty() and _lights.back() == [UID, -1]
	w.update_square(1, Vector3(1.0, 1.0, 0.0), false, snap, 1200)
	var not_free: bool = w.picked[1].is_empty()
	var m := VrWorkMenu.new()
	var head := Transform3D(Basis(), Vector3(0.0, 1.5, 1.0))
	var at := Vector3(0.0, 1.0, 0.0)
	m.open_list(1, at, head, UID, [], "x")
	var empty: bool = not m.is_open()
	m.open_list(1, at, head, UID, [{"text": "a", "value": 3}, {"text": "b", "value": 5}, {"text": "c", "value": 7}], "Install as:")
	var listed: bool = m.is_open() and not m.armed and m.choice == 0 and m.choice_value() == 3 \
			and m.panel_text().begins_with("Install as:\n> a")
	m.point(at + Vector3(0.0, -0.03, 0.0))
	var hand_down: bool = m.choice == 1 and m.panel_text().contains("> b")
	m.point(at + Vector3(0.0, -0.03, 0.0), Vector2(0.0, -0.9))
	m.point(at + Vector3(0.0, -0.03, 0.0), Vector2(0.0, -0.9))   # held: one row a push
	var stick: bool = m.choice == 2 and m.choice_value() == 7
	m.point(at + Vector3(0.0, -0.03, 0.0), Vector2.ZERO)
	m.point(at + Vector3(0.0, -0.03, 0.0), Vector2(0.0, 0.9))
	var up: bool = m.choice == 1
	m.point(at + Vector3(0.0, -1.0, 0.0))
	var clamped: bool = m.choice == 2
	m.set_read({"ok": false, "vehicle": UID, "error": "x"})
	var no_read: bool = m.read.is_empty()
	m.open(1, at, head, UID, 0)
	var back: bool = m.items.is_empty() and m.choice_value() == null and (m.get_child(0) as Label3D).visible
	m.free()
	_check.call(picks and fors and none and served and sq and off and not_free and empty and listed and hand_down and stick and up and clamped and no_read and back,
			"vr work install: only the types the item serves that fit, in CDDA's order; the read for that square only; the square under a part's item lit; the list picks by the hand's height or a stick push (%s)"
			% [[picks, fors, none, served, sq, off, not_free, empty, listed, hand_down, stick, up, clamped, no_read, back]])


## The rig: the install read for the asked square installs the one type left (not connected here: said and flashed),
## offers several on the wheel's list (the trigger let go on one installs it), says why when none fits or the read
## refuses, and ignores another square's read.
func _test_rig_install(root: Node, snap: Snapshot) -> void:
	var world := WorldView.new()
	world.snapshot = snap
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	var w := _work()
	rig.work = w
	var s := VehicleWorkSession.new()
	s.world = world
	rig.work_session = s
	s.open(UID)
	rig.set("_work_mine", true)
	rig.right.global_position = Vector3(0.0, 1.1, 0.0)
	var r := {"ok": true, "vehicle": UID, "install": INST}
	var not_yet := "Install isn't connected to the game yet."
	_rig = rig
	_ask([3])
	s.result.emit(r)
	var one: bool = rig.busy.get("_flash") == not_yet and rig.get("_install").is_empty()
	_ask([4])
	s.result.emit(r)
	var none: bool = rig.busy.get("_flash") == "That doesn't fit there." and rig.get("_install").is_empty()
	_ask([4])
	s.result.emit({"ok": true, "vehicle": UID, "install": INST.merged({"selected": {"cmd": "i", "ok": false, "reason": 0,
			"text": "Cannot install due to: no room.", "lines": []}}, true)})
	var cdda_why: bool = rig.busy.get("_flash") == "Cannot install due to: no room." and rig.get("_install").is_empty()
	_ask([3])
	s.result.emit({"ok": false, "vehicle": UID, "error": "busy"})
	var refused: bool = rig.busy.get("_flash") == "The game couldn't answer (busy)." and rig.get("_install").is_empty()
	_ask([3])
	rig.busy.flash("-")
	s.result.emit({"ok": true, "vehicle": UID, "install": INST.merged({"mount": Vector2i(0, 0)}, true)})
	var other: bool = rig.busy.get("_flash") == "-" and not rig.get("_install").is_empty()
	_ask([3, 5])
	s.result.emit(r)
	var m := rig.work_menu
	var listed: bool = m.is_open() and m.items.size() == 2 and w.hold and rig.get("_install").get("listing") == true
	rig.right.global_position = m.center + Vector3(0.0, -0.03, 0.0)
	rig.update_wheel()
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var picked: bool = m.choice == -1 and not m.is_open() and rig.busy.get("_flash") == not_yet \
			and rig.get("_install").is_empty() and not w.hold
	_ask([3, 5])
	s.result.emit(r)
	rig.press(rig.right, "by_button")
	var closed: bool = not m.is_open() and rig.get("_install").is_empty()
	var t := IdTables.new()   # the trigger with a part's item on a lit square asks CDDA's install read (here: no game)
	for k in 10:
		t.vpart.append(IdTables.Def.new())
	t.vpart[3].item = 9
	world.tables = t
	w.square = func(uid: int, _p: Vector3) -> Variant: return Vector2i(1, 0) if uid == UID else Vector2i.MAX
	var it := ItemRef.new()
	it.type = 9
	hands.hand("vr_r").held = {"kind": "item", "item": it}
	rig.right.global_position = Vector3(1.0, 1.1, 0.0)
	rig.update_hands(0.016, true)
	var b0: int = rig.buzzes[1]
	rig.press(rig.right, "trigger_click")
	var trigger: bool = w.picked[1] == {"uid": UID, "at": Vector2i(1, 0)} and rig.buzzes[1] == b0 + 1 \
			and rig.busy.get("_flash") == VehicleWorkSession.NO_INSTALL.left(VrBusy.MAX_CHARS) \
			and rig.get("_install").is_empty()   # (the flash is capped)
	hands.hand("vr_r").held = {}
	_rig = null
	rig.work_session = null
	rig.hands = null
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	world.free()
	_check.call(one and none and cdda_why and refused and other and listed and picked and closed and trigger,
			"vr work rig install: one type left installs, several go on the wheel's list (let go on one installs it), none fits or a refused read says why, another square's read is ignored (%s)"
			% [[one, none, cdda_why, refused, other, listed, picked, closed, trigger]])


var _rig: VrRig


func _ask(types: Array) -> void:
	_rig.set("_install", {"uid": UID, "at": Vector2i(1, 0), "hand": 1, "types": PackedInt32Array(types),
			"until": Time.get_ticks_msec() + 5000})
