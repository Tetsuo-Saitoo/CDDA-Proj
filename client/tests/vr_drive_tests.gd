extends RefCounted
## VR driving by hand (VrDrive, VrRig's wiring): the wheel taken at its rim while driving and turned by one or both
## hands (at most WHEEL_MAX), its angle asked of CDDA as LEFT / RIGHT one turn at a time; the triggers and the turn
## stick as UP / DOWN, repeated while held, a diagonal with a steer; nothing while real time is paused (the note, once);
## not driving: the wheel let go, no pedals; lids swung by their handle about the hinge, let go: open past LID_SNAP,
## else shut; the rig's grips, triggers and sticks go there while driving and it doesn't walk; the ride's square from
## VehicleView.square_at; car storage by hand: the cargo space a hand is in, the tray on it, a lid's changes told.
## Run by run_tests.gd.

const UID := 7

var _check: Callable
var _acts: Array = []   # what the queue stub got (members: lambdas copy locals)
var _ok := true                 # what the queue stub answers
var _lids: Array = []           # open_lid calls
var _note := ""                 # what the paused stub answers
var _flashes: Array = []
var _ci: CarInterior
var _sq: Variant = null         # what the ride_square stub answers
var _reach := true              # what the can_reach stub answers
var _cell: Variant = null       # what the square_at stub answers
var _changed: Array = []        # lid_changed calls


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr driving by hand")
	var car := Node3D.new()   # the vehicle's drawn model: turned and moved off the origin
	car.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(30.0)), Vector3(4.0, 0.2, -3.0))
	root.add_child(car)
	var veh := Snapshot.Vehicle.new()
	veh.uid = UID
	veh.pos = Vector3i(10, 10, 0)
	# (0, 0) the controls, (-2, 0) a trunk: [mount x, mount y, vpart, hp_frac, state, dx, dy, dz]
	veh.parts = PackedInt32Array([0, 0, 1, 255, 0, 0, 0, 0, -2, 0, 1, 255, 0, -2, 0, 0])
	_ci = CarInterior.new()
	_ci.uid = UID
	car.add_child(_ci)
	_ci._add_controls(veh, 0)
	_ci._add_lid(veh, 1, VehicleView.Kind.CARGO, false, Vector3.ZERO, Color.GRAY)
	var snap := _snap(veh, true, 0.0)
	var d := _drive()
	_test_wheel(d, snap, veh)
	_test_pedals(d, snap, veh)
	_test_lids(d, veh)
	_test_cargo(d, veh)
	_test_glovebox(root, d)
	_test_rig(root, snap)
	_test_rig_cargo(root, veh)
	car.free()


func _drive() -> VrDrive:
	var d := VrDrive.new()
	d.interior = func(uid: int) -> Dictionary: return _ci.anchors() if uid == UID and is_instance_valid(_ci) else {}
	d.queue_action = func(a: String) -> bool:
		_acts.append(a)
		return _ok
	d.open_lid = func(uid: int, part: int, open: bool) -> bool:
		_lids.append([uid, part, open])
		return _ci.open_lid(part, open)
	d.paused = func() -> String: return _note
	d.flash = func(n: String) -> void: _flashes.append(n)
	return d


## The player at the controls of vehicle UID (`driving`), CDDA steering `steer` degrees off its facing (east).
static func _snap(veh: Snapshot.Vehicle, driving: bool, steer: float, turn := 100) -> Snapshot:
	var s := Snapshot.new()
	veh.face_deg = 0.0
	s.vehicles = [veh] as Array[Snapshot.Vehicle]
	s.vehicles_moved()
	s.player_pos = veh.square(0)
	s.player_driving = driving
	s.player_vehicle = UID
	s.player_vehicle_state = {"uid": UID, "in_control": driving, "at_controls": true, "turn_deg": fposmod(steer, 360.0)}
	s.turn = turn
	return s


## A point on the wheel's rim `deg` round from its right (counter-clockwise seen by the driver), world.
func _rim(deg: float, out := 0.0) -> Vector3:
	var w: Node3D = _ci.wheel
	var r := CarInterior.WHEEL_R + out
	return w.global_transform * Vector3(cos(deg_to_rad(deg)) * r, sin(deg_to_rad(deg)) * r, 0.0)


func _test_wheel(d: VrDrive, snap: Snapshot, veh: Snapshot.Vehicle) -> void:
	var spin: Node3D = _ci.spin
	var hands: Array = [Vector3.ZERO, _rim(90.0)]
	var far: bool = not d.grip(1, _rim(90.0, 0.2), snap) and not d.grip(1, _ci.wheel.global_position, snap)
	var not_driving: bool = not d.grip(1, _rim(90.0), _snap(veh, false, 0.0))
	var took: bool = d.grip(1, _rim(90.0), snap) and d.holds_wheel(1) and spin.get_meta("held") == true
	# 30 degrees to the left: 5 of CDDA's, under half a step: nothing goes.
	hands[1] = _rim(120.0)
	d.update(hands, snap, 1000)
	var small: bool = is_equal_approx(d.wheel_deg(), 30.0) and absf(rad_to_deg(spin.rotation.z) - 30.0) < 0.01 \
			and _acts.is_empty()
	# 60: 10 of CDDA's to the left, one LEFT; not again until a new turn (or STEER_WAIT_MS).
	hands[1] = _rim(150.0)
	d.update(hands, snap, 1100)
	d.update(hands, snap, 1200)
	var one: bool = _acts == ["LEFT"]
	var snap2 := _snap(veh, true, -15.0, 101)
	d.update(hands, snap2, 1300)
	var there: bool = _acts.size() == 1   # CDDA steers 15 left now: within half a step of 10
	d.update(hands, snap, 2700)
	var again: bool = _acts == ["LEFT", "LEFT"]   # no new turn in STEER_WAIT_MS: once more
	_acts.clear()
	# The other hand on the bottom of the rim: both turn it 30 further right, the mean.
	hands[0] = _rim(-90.0)
	var both: bool = d.grip(0, hands[0], snap) and d.holds_wheel(0)
	hands[0] = _rim(-120.0)
	hands[1] = _rim(120.0)
	d.update(hands, snap2, 3000)
	var mean: bool = is_equal_approx(d.wheel_deg(), 30.0)
	# Right round: at most WHEEL_MAX, then RIGHT asked.
	for k in 30:
		hands[0] = _rim(-120.0 - 20.0 * (k + 1))
		hands[1] = _rim(120.0 - 20.0 * (k + 1))
		d.update(hands, snap2, 3000)
	var stops: bool = is_equal_approx(d.wheel_deg(), -CarInterior.WHEEL_MAX) and _acts == ["RIGHT"]
	# One hand off: still held; both off: it turns back (CarInterior steps, held no longer).
	var off1: bool = d.let_go(0) and spin.get_meta("held") == true and d.holds_wheel(1)
	_ci.moving = false
	var off2: bool = d.let_go(1) and spin.get_meta("held") == false and _ci.moving and not d.holds(1) and not d.let_go(1)
	_check.call(far and not_driving and took and small and one and there and again and both and mean and stops and off1 and off2,
			"vr drive: the rim taken while driving turns with one or both hands (at most %d), each 15 degrees off goes as LEFT / RIGHT once a turn; let go it turns back (%s)"
			% [CarInterior.WHEEL_MAX, [far, not_driving, took, small, one, there, again, both, mean, stops, off1, off2]])
	# Driving no more: a held wheel is let go.
	_acts.clear()
	d.grip(1, _rim(90.0), snap)
	d.update([Vector3.ZERO, _rim(90.0)], _snap(veh, false, 0.0), 4000)
	_check.call(not d.holds(1) and spin.get_meta("held") == false and _acts.is_empty(),
			"vr drive: getting up from the controls lets go of the wheel")


func _test_pedals(d: VrDrive, snap: Snapshot, veh: Snapshot.Vehicle) -> void:
	_acts.clear()
	var hands: Array = [Vector3.ZERO, Vector3.ZERO]
	var walking: bool = not d.pedal(1, true, _snap(veh, false, 0.0))
	var on: bool = d.pedal(1, true, snap)
	d.update(hands, snap, 10000)
	d.update(hands, snap, 10100)
	d.update(hands, snap, 10300)   # held: again after PEDAL_MS
	var held: bool = _acts == ["UP", "UP"]
	var up: bool = d.unpedal(1) and not d.unpedal(1)
	d.update(hands, snap, 10700)
	d.pedal(0, false, snap)   # the off hand brakes; both held: the brake
	d.pedal(1, true, snap)
	d.update(hands, snap, 10710)
	var brake: bool = _acts.back() == "DOWN"
	d.unpedal(0)
	d.unpedal(1)
	d.set_stick(-0.9)
	var n := _acts.size()
	d.update(hands, snap, 10720)   # the brake went at 10710: the stick waits out PEDAL_MS
	var waits: bool = _acts.size() == n
	d.update(hands, snap, 11010)
	var stick: bool = _acts.size() == n + 1 and _acts.back() == "DOWN"
	d.set_stick(-0.6)   # inside STICK_ON, outside STICK_OFF: still held
	var edge: bool = d._stick == -1
	d.set_stick(0.2)
	n = _acts.size()
	d.update(hands, snap, 11500)
	var rest: bool = _acts.size() == n
	# A stick wobbling at the edge sends at most one a PEDAL_MS.
	for t in range(11600, 12200, 20):
		d.set_stick(0.75 if t % 40 < 20 else 0.4)
		d.update(hands, snap, t)
	var wobble: int = _acts.size() - n
	d.set_stick(0.0)
	_check.call(walking and on and held and up and brake and waits and stick and edge and rest and wobble == 2,
			"vr drive: while driving the triggers (main: UP, other: DOWN, brake first) and the turn stick (on past %.1f, off inside %.1f) repeat every %d ms while held, at most that however the stick wobbles (%s)"
			% [VrDrive.STICK_ON, VrDrive.STICK_OFF, VrDrive.PEDAL_MS, [waits, stick, edge, rest, wobble, _acts]])
	# A steer and a pedal due together: one diagonal.
	_acts.clear()
	d.grip(1, _rim(90.0), snap)
	d.update([Vector3.ZERO, _rim(150.0)], snap, 12000)   # ... a steer goes (60 left), the trigger after
	d.let_go(1)
	d.grip(1, _rim(90.0), _snap(veh, true, 0.0, 200))
	d.pedal(0, true, snap)
	d.update([Vector3.ZERO, _rim(150.0)], _snap(veh, true, 0.0, 200), 12100)
	var diagonal: bool = _acts.back() == "LEFTUP"
	# Real time paused: nothing goes, the note once in NOTE_MS.
	_acts.clear()
	_flashes.clear()
	_note = "TIME PAUSED: menu > Time to go on"
	for t in [13000, 13400, 13800, 14600]:
		d.update([Vector3.ZERO, _rim(150.0)], _snap(veh, true, 0.0, t), t)
	_note = ""
	var paused: bool = _acts.is_empty() and _flashes.size() == 2 and _flashes[0] == "TIME PAUSED: menu > Time to go on"
	d.let_go(1)
	d.unpedal(0)
	_check.call(diagonal and paused,
			"vr drive: a steer and a trigger together go as one diagonal; real time paused sends nothing and says so once in %d ms (%s)"
			% [VrDrive.NOTE_MS, _flashes])


func _test_lids(d: VrDrive, veh: Snapshot.Vehicle) -> void:
	var walking := _snap(veh, false, 0.0)   # a passenger, or on foot beside it
	var c: Node3D = _ci.lids[1]
	var lid: Node3D = c.get_node("Lid")
	var axis: Vector3 = c.get_meta("hinge_axis")
	var handle: Vector3 = c.get_meta("handle")
	var at := func(deg: float) -> Vector3: return c.global_transform * (lid.position + Basis(axis, deg_to_rad(deg)) * handle)
	var miss: bool = not d.grip(0, at.call(0.0) + Vector3(0.0, 0.3, 0.0), walking)
	var took: bool = d.grip(0, at.call(0.0), walking) and d.holds_lid(0) and lid.get_meta("held") == true \
			and (at.call(60.0) as Vector3).y > (at.call(0.0) as Vector3).y + 0.3   # opening lifts the handle
	d.update([at.call(60.0), Vector3.ZERO], walking, 0)
	var swung := absf(_ci.lid_deg(1) - 60.0) < 0.5
	d.update([at.call(150.0), Vector3.ZERO], walking, 0)
	var top := absf(_ci.lid_deg(1) - CarInterior.LID_OPEN) < 0.5
	d.update([at.call(-30.0), Vector3.ZERO], walking, 0)
	var shut := absf(_ci.lid_deg(1)) < 0.5
	d.update([at.call(50.0), Vector3.ZERO], walking, 0)
	var opens: bool = d.let_go(0) and lid.get_meta("held") == false and _lids.back() == [UID, 1, true]
	_ci.step(1.0)
	var open: bool = absf(_ci.lid_deg(1) - CarInterior.LID_OPEN) < 0.5 and _acts.is_empty()
	d.grip(0, at.call(CarInterior.LID_OPEN), walking)
	d.update([at.call(25.0), Vector3.ZERO], walking, 0)
	d.let_go(0)
	_ci.step(1.0)
	var closes: bool = _lids.back() == [UID, 1, false] and absf(_ci.lid_deg(1)) < 0.5
	_check.call(miss and took and swung and top and shut and opens and open and closes,
			"vr drive: a lid's handle taken swings it about its hinge (0 to %d); let go past %d it opens, else shuts; nothing sent (%s)"
			% [CarInterior.LID_OPEN, VrDrive.LID_SNAP, [miss, took, swung, top, shut, opens, open, closes]])


static func _trunk_row(items: PackedInt64Array) -> Array[Dictionary]:
	return [{"part": 1, "used_ml": 250, "capacity_ml": 1000, "more": 0, "items": items}] as Array[Dictionary]


## Car storage by hand: the cargo space a hand is in (an open lid's opening while can_reach allows it; asked, any
## reachable cargo square under it), only one the snapshot lists; a lid let go open or shut, or swung under
## LID_REACH while held, is told (lid_changed).
func _test_cargo(d: VrDrive, veh: Snapshot.Vehicle) -> void:
	d.can_reach = func(_uid: int, _part: int) -> bool: return _reach
	d.square_at = func(_uid: int, _p: Vector3) -> Variant: return _cell
	d.lid_changed = func(uid: int, part: int, sq: Vector3i, open: bool) -> void: _changed.append([uid, part, sq, open])
	veh.cargo = _trunk_row(PackedInt64Array([501, 3]))
	var snap := _snap(veh, false, 0.0)
	var trunk := veh.square(1)
	var want := {"kind": "cargo", "vehicle": UID, "part": 1, "square": trunk}
	var c: Node3D = _ci.lids[1]
	var inside := c.global_transform * Vector3(0.1, CarInterior.LID_TOP - 0.3, -0.1)
	var deep := c.global_transform * Vector3(0.0, CarInterior.LID_TOP - 1.0, 0.0)
	var beside := c.global_transform * Vector3(0.6, CarInterior.LID_TOP, 0.0)
	_reach = false
	var shut: bool = d.cargo_at(inside, snap).is_empty()
	_reach = true
	# The trunk as CarInterior builds it: its own "opening" (the box under the lid) reaching up (opening_out).
	var real: bool = c.get_meta("opening") is AABB and c.get_meta("opening_out") == Vector3.UP
	var opening: bool = real and d.cargo_at(inside, snap) == want and d.cargo_at(deep, snap).is_empty() \
			and d.cargo_at(beside, snap).is_empty()
	# A box of the test's own, then an open face, a bad normal, a junk box; the trunk's own metas back after.
	var keep_box: Variant = c.get_meta("opening")
	var keep_out: Variant = c.get_meta("opening_out")
	c.remove_meta("opening_out")
	c.set_meta("opening", AABB(Vector3(-0.3, 0.1, -0.3), Vector3(0.6, 0.4, 0.6)))
	var boxed: bool = d.cargo_at(c.global_transform * Vector3(0.0, 0.3, 0.0), snap) == want \
			and d.cargo_at(inside, snap).is_empty()
	var front := c.global_transform * Vector3(-0.5, 0.3, 0.0)   # 20 cm out of the box's -x face
	var shut_side: bool = d.cargo_at(front, snap).is_empty()
	c.set_meta("opening_out", Vector3(-1.0, 0.0, 0.0))   # it opens that way (the glovebox: toward the seat)
	var out_face: bool = d.cargo_at(front, snap) == want and d.cargo_at(inside, snap).is_empty()
	c.set_meta("opening_out", Vector3(-2.0, 0.0, 0.0))   # not a unit normal: no reach out
	var bad_out: bool = d.cargo_at(front, snap).is_empty()
	c.remove_meta("opening_out")
	c.set_meta("opening", AABB(Vector3.ZERO, Vector3(INF, 1.0, 1.0)))   # junk: the lid's rule instead
	var junk: bool = d.cargo_at(inside, snap) == want
	c.remove_meta("opening")
	var no_box: bool = d.cargo_at(inside, snap) == want   # none: the lid's rule
	c.set_meta("opening", keep_box)
	c.set_meta("opening_out", keep_out)
	opening = opening and boxed and shut_side and out_face and bad_out and junk and no_box
	_cell = trunk
	var cell: bool = d.cargo_at(beside, snap, true) == want
	_cell = trunk + Vector3i(0, 1, 0)
	var off: bool = d.cargo_at(beside, snap, true).is_empty()
	_cell = null
	var bad: bool = d.cargo_at(Vector3(NAN, 0.0, 0.0), snap).is_empty() and d.cargo_at(inside, null).is_empty()
	veh.cargo = [] as Array[Dictionary]
	var unlisted: bool = d.cargo_at(inside, snap).is_empty()
	# The lid: told when hands can no longer reach in and when it is let go.
	_changed.clear()
	var lid: Node3D = c.get_node("Lid")
	var axis: Vector3 = c.get_meta("hinge_axis")
	var handle: Vector3 = c.get_meta("handle")
	var at := func(deg: float) -> Vector3: return c.global_transform * (lid.position + Basis(axis, deg_to_rad(deg)) * handle)
	d.grip(0, at.call(0.0), snap)
	d.update([at.call(70.0), Vector3.ZERO], snap, 0)
	var up_quiet: bool = _changed.is_empty()
	d.update([at.call(20.0), Vector3.ZERO], snap, 0)
	d.update([at.call(10.0), Vector3.ZERO], snap, 0)
	var swung: bool = _changed == [[UID, 1, trunk, false]]
	d.update([at.call(60.0), Vector3.ZERO], snap, 0)
	d.let_go(0)
	var opened: bool = _changed.size() == 2 and _changed[1] == [UID, 1, trunk, true]
	_ci.step(1.0)
	d.grip(0, at.call(CarInterior.LID_OPEN), snap)
	d.update([at.call(15.0), Vector3.ZERO], snap, 0)
	d.let_go(0)
	var closed: bool = _changed.size() == 4 and _changed[2] == [UID, 1, trunk, false] \
			and _changed[3] == [UID, 1, trunk, false]
	_ci.step(1.0)
	d.lid_changed = Callable()
	_check.call(shut and opening and cell and off and bad and unlisted and up_quiet and swung and opened and closed,
			"vr drive cargo: a hand in an open lid's opening (or, asked, over a cargo square) is in that cargo space while it can be reached and the snapshot lists it; a lid let go, or swung under %d degrees, is told (%s)"
			% [int(CarInterior.LID_REACH), [shut, opening, cell, off, bad, unlisted, up_quiet, swung, opened, closed, _changed]])


## The glovebox as CarInterior builds it (its door on the dash's face, opening toward the seat): a hand in the space
## behind the door, or up to REACH_ABOVE out of it toward the seat, is in it; further out or over it, not.
func _test_glovebox(root: Node, d: VrDrive) -> void:
	var car := Node3D.new()
	car.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-60.0)), Vector3(-5.0, 0.0, 2.0))
	root.add_child(car)
	var veh := Snapshot.Vehicle.new()
	veh.uid = UID + 1
	veh.pos = Vector3i(20, 20, 0)
	veh.parts = PackedInt32Array([1, 0, 1, 255, 0, 1, 0, 0])   # the glovebox, one cell ahead of the seat
	veh.cargo = [{"part": 0, "used_ml": 0, "capacity_ml": 5000, "more": 0, "items": PackedInt64Array([502, 4])}] as Array[Dictionary]
	var gi := CarInterior.new()
	gi.uid = veh.uid
	car.add_child(gi)
	gi._add_glovebox(veh, 0, Color.GRAY)
	var keep := d.interior
	d.interior = func(uid: int) -> Dictionary: return gi.anchors() if uid == veh.uid else {}
	_reach = true
	var s := Snapshot.new()
	s.vehicles = [veh] as Array[Snapshot.Vehicle]
	s.vehicles_moved()
	s.player_pos = veh.square(0) + Vector3i(-1, 0, 0)
	var c: Node3D = gi.lids[0]
	var want := {"kind": "cargo", "vehicle": veh.uid, "part": 0, "square": veh.square(0)}
	var at := func(x: float, y: float) -> Vector3: return c.global_transform * Vector3(x, y, 0.05)
	var behind: bool = d.cargo_at(at.call(0.06, 1.03), s) == want
	var out: bool = d.cargo_at(at.call(-0.2, 1.03), s) == want
	var far: bool = d.cargo_at(at.call(-0.4, 1.03), s).is_empty()
	var over: bool = d.cargo_at(at.call(0.06, 1.3), s).is_empty()
	var low: bool = d.cargo_at(at.call(-0.1, 0.8), s).is_empty()
	d.interior = keep
	car.free()
	_check.call(behind and out and far and over and low,
			"vr drive glovebox: a hand behind its door or up to %.2f m out toward the seat is in it; further, over or under it, not (%s)"
			% [VrDrive.REACH_ABOVE, [behind, out, far, over, low]])


## The rig: trigger with an empty hand in an open trunk lays out what it holds in the tray (nothing: a note; the lid
## shut: not reached); a lid let go shut puts the tray away, let go open brings it.
func _test_rig_cargo(root: Node, veh: Snapshot.Vehicle) -> void:
	var world := WorldView.new()
	veh.cargo = _trunk_row(PackedInt64Array([501, 3]))
	world.snapshot = _snap(veh, false, 0.0)
	world.snapshot.player_pos = veh.square(1) + Vector3i(1, 0, 0)   # the tray lists only what is next to the player
	var sm := Snapshot.Submap.new()
	sm.pos = CddaCoords.ms_to_sm(veh.square(1))
	world.snapshot.submaps[sm.pos] = sm
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	var wired: bool = rig.drive.lid_changed == Callable(rig, "_lid_changed")
	var d := _drive()
	d.can_reach = func(_uid: int, _part: int) -> bool: return _reach
	d.lid_changed = Callable(rig, "_lid_changed")
	rig.drive = d
	_reach = true
	var trunk := veh.square(1)
	rig.right.global_position = (_ci.lids[1] as Node3D).global_transform * Vector3(0.0, CarInterior.LID_TOP - 0.3, 0.0)
	rig.press(rig.right, "trigger_click")
	var shown: bool = rig.tray.is_open() and rig.tray.source.get("kind") == "cargo" and rig.tray.rows.size() == 1
	d.lid_changed.call(UID, 1, trunk, false)
	var put_away: bool = not rig.tray.is_open()
	d.lid_changed.call(UID, 1, trunk, true)
	var brought: bool = rig.tray.is_open()
	rig.tray.close()
	veh.cargo = _trunk_row(PackedInt64Array())
	rig.press(rig.right, "trigger_click")
	var note: bool = not rig.tray.is_open() and rig.busy._flash.begins_with("Nothing in the")
	veh.cargo = _trunk_row(PackedInt64Array([501, 3]))
	_reach = false
	rig.busy._flash = ""
	rig.press(rig.right, "trigger_click")
	var lid_shut: bool = not rig.tray.is_open() and rig.busy._flash.is_empty()
	_reach = true
	veh.cargo = [] as Array[Dictionary]
	_check.call(wired and shown and put_away and brought and note and lid_shut,
			"vr drive rig cargo: trigger in an open trunk lays out what it holds (nothing: a note; shut: not reached); a lid let go shut puts the tray away, open brings it (%s)"
			% [[wired, shown, put_away, brought, note, lid_shut]])
	rig.free()
	world.free()


## The rig: a grip at the rim takes the wheel (not an item), the trigger is a pedal, the sticks don't walk or aim a
## teleport while driving; the ride's square from ride_square.
func _test_rig(root: Node, snap: Snapshot) -> void:
	var world := WorldView.new()
	world.snapshot = snap
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.drive = _drive()
	_acts.clear()
	rig.right.global_position = _rim(90.0)
	rig.press(rig.right, "grip_click")
	var grip: bool = rig.drive.holds_wheel(1)
	rig.press(rig.right, "trigger_click")
	rig.drive.update([rig.left.global_position, rig.right.global_position], snap, 50000)
	var gas: bool = _acts.back() == "UP" if not _acts.is_empty() else false
	rig.release(rig.right, "trigger_click")
	rig.release(rig.right, "grip_click")
	var off: bool = not rig.drive.holds(1)
	var at := rig.global_position
	rig.step(0.5, {"move": Vector2(0.0, 1.0), "turn": Vector2(0.0, 0.95)})
	var still: bool = rig.global_position.is_equal_approx(at) and not rig.aiming and rig.drive._stick == 1
	# The menu opened with the stick forward, then the stick let go: the pedal goes up, nothing more is sent.
	rig.toggle_menu()
	rig.step(0.1, {"move": Vector2.ZERO, "turn": Vector2.ZERO})
	_acts.clear()
	rig.drive.update([rig.left.global_position, rig.right.global_position], snap, 60000)
	var menu_up: bool = rig.menu_open() and rig.drive._stick == 0 and _acts.is_empty()
	rig.toggle_menu()
	rig.step(0.1, {"move": Vector2.ZERO, "turn": Vector2.ZERO})
	# Riding: the head over one of the car's cells as drawn (ride_square) on this level, else not.
	var d0 := Transform3D(Basis(), rig.camera.global_position)
	rig.ride = func() -> Array: return [UID, d0, d0]
	rig.ride_square = func(_uid: int, _p: Vector3) -> Variant: return _sq
	_sq = Vector3i(3, 4, rig.z)
	rig.ride_along()
	var rides: bool = rig.riding.following() == UID
	_sq = null
	rig.ride_along()
	var leaves: bool = rig.riding.following() == 0
	_sq = Vector3i(3, 4, rig.z + 1)
	rig.ride_along()
	var level: bool = rig.riding.following() == 0
	_check.call(grip and gas and off and still and menu_up and rides and leaves and level,
			"vr drive rig: a grip at the rim takes the wheel, the trigger is a pedal, the sticks don't walk while driving and a menu up lets the stick's pedal go; the ride's square is the drawn cell's (%s)"
			% [[grip, gas, off, still, menu_up, rides, leaves, level]])
	rig.free()
	world.free()
