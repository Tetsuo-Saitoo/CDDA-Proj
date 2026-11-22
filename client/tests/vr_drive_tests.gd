extends RefCounted
## VR driving by hand (VrDrive, VrRig's wiring): the wheel taken at its rim while driving and turned by one or both
## hands (at most WHEEL_MAX), its angle asked of CDDA as LEFT / RIGHT one turn at a time; the triggers and the turn
## stick as UP / DOWN, repeated while held, a diagonal with a steer; nothing while real time is paused (the note, once);
## not driving: the wheel let go, no pedals; lids swung by their handle about the hinge, let go: open past LID_SNAP,
## else shut; the rig's grips, triggers and sticks go there while driving and it doesn't walk; the ride's square from
## VehicleView.square_at. Run by run_tests.gd.

const UID := 7

var _check: Callable
var _acts: Array = []   # what the queue stub got (members: lambdas copy locals)
var _ok := true                 # what the queue stub answers
var _lids: Array = []           # open_lid calls
var _note := ""                 # what the paused stub answers
var _flashes: Array = []
var _ci: CarInterior
var _sq: Variant = null         # what the ride_square stub answers


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
	_test_rig(root, snap)
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
	d.update(hands, snap, 10720)
	var stick: bool = _acts.back() == "DOWN"
	d.set_stick(0.2)
	var n := _acts.size()
	d.update(hands, snap, 11500)
	var rest: bool = _acts.size() == n
	_check.call(walking and on and held and up and brake and stick and rest,
			"vr drive: while driving the triggers (main: UP, other: DOWN, brake first) and the turn stick repeat every %d ms while held (%s)"
			% [VrDrive.PEDAL_MS, _acts])
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
	_check.call(grip and gas and off and still and rides and leaves and level,
			"vr drive rig: a grip at the rim takes the wheel, the trigger is a pedal, the sticks don't walk while driving; the ride's square is the drawn cell's (%s)"
			% [[grip, gas, off, still, rides, leaves, level]])
	rig.free()
	world.free()
