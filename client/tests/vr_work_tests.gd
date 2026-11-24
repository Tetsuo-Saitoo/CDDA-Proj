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
