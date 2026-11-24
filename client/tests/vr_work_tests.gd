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
	var refused: bool = not m.allowed("o") and m.why_not("o") == "busy"
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
	var stays: bool = m.is_open() and not m.armed and w.picked[1] == {"uid": UID, "row": 0} and _lights == [[UID, 0]]
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
	var cancel: bool = not m.is_open() and not w.hold
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
