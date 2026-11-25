class_name VrDrive
extends RefCounted
## VR driving by hand (the user's, 2026-11-21; contracts/ui_requests.md "Driving"): only CDDA's own actions, no new
## rules, and the camera is never moved. While the player drives (the snapshot's player.driving), a grip on the rim of
## that vehicle's steering wheel (CarInterior's "Wheel" > "WheelSpin", one hand or both) turns it with the hands; how
## far it is turned (CarInterior.WHEEL_RATIO wheel degrees a degree) is the steer asked of CDDA: "LEFT" / "RIGHT"
## steer STEP_DEG an action and take a turn, so one goes, then the next once a new turn came. Let go, the wheel turns
## back to CDDA's steer (CarInterior). The triggers (a hand that is empty or on the wheel: the main hand speeds up, the
## other slows down) and the turn stick forward / back are the throttle and the brake: "UP" / "DOWN" change the speed
## it is set to reach by 4 mph and take no time; held, they repeat every PEDAL_MS. A steer and a pedal due together go
## as one diagonal ("LEFTUP"). Real time paused: nothing goes, the pause note shows (at most once per NOTE_MS).
## A grip on the handle of a lid (any drawn interior's "Cargo_<part>" > "Lid") swings it about its hinge with the hand,
## 0 to its open_deg; let go, it opens fully past LID_SNAP, else shuts (VehicleView.open_lid: the client's own, CDDA
## has no lids; hands reach in from CarInterior.LID_REACH, VehicleView.can_reach). Nothing is sent for a lid.
## The hood (C6; CarInterior's "Hood", no CDDA part) by its handle the same way: let go, VehicleView.open_hood.
## Car storage by hand: `lid_changed` tells the rig when a hand lets a lid go open (its cargo laid out in the tray, as
## the flat screen's E does) or shut, or swings a held one under LID_REACH (the tray on it goes); `cargo_at` is the
## cargo space a hand is in (an open lid's opening; with `cells` any reachable cargo square under it).

const GRAB_M := 0.08          # m: a hand this near the rim's circle (in its plane and off it) takes the wheel
const HUB_M := 0.03           # m: a hand this near the wheel's axis turns nothing (no angle there)
const STEP_DEG := 15.0        # CDDA steers this far an action
const STEER_WAIT_MS := 1500   # a steer no new turn answered in this long: the next may go anyway
const PEDAL_MS := 300         # a held pedal repeats no faster
const STICK_ON := 0.7         # the turn stick past this forward / back is a pedal ...
const STICK_OFF := 0.5        # ... until it comes back inside this (no flicker at the edge)
const LID_GRAB_M := 0.09      # m: a hand this near a lid's handle takes the lid
const LID_SNAP := 40.0        # degrees: let go past this, a lid opens; else it shuts
const NOTE_MS := 1500         # the pause note again no sooner (main.gd's PAUSE_NOTE_MS)
const MAX_CARS := 64          # vehicles looked through for a lid's handle or a cargo space
const REACH_DEPTH := 0.7      # m: a hand this far down into a lid's opening reaches in ...
const REACH_ABOVE := 0.25     # ... and this far over it (no "opening" meta)
const OPENING_GROW := 0.05    # m: round a Cargo node's "opening" box, still in it
const MAX_OPENING_M := 4.0    # an "opening" box this big or more is junk: the rule above instead
const MAX_SENT := 16

var interior := Callable()      # (uid) -> Dictionary: VehicleView.interior (main.gd); unset: no wheel, no lids
var open_lid := Callable()      # (uid, part, open) -> bool: VehicleView.open_lid (main.gd)
var open_hood := Callable()     # (uid, open) -> bool: VehicleView.open_hood (main.gd)
var queue_action := Callable()  # (act) -> bool: CDDA's action (main.gd's _queue_act); false: not sent
var paused := Callable()        # () -> String: the note to show while real time is paused, "" while it runs
var flash := Callable()         # (note) -> void: shows a note low in the view (VrBusy.flash)
var can_reach := Callable()     # (uid, part) -> bool: VehicleView.can_reach (main.gd); unset: no cargo by hand
var square_at := Callable()     # (uid, world point) -> Vector3i or null: VehicleView.square_at (main.gd)
var lid_changed := Callable()   # (uid, part, square, open) -> void: a lid let go open / shut, or swung under LID_REACH

var sent: Array[String] = []    # the actions sent, newest last (MAX_SENT; tests)
var _wheel: Array = [null, null]    # hand (0 left, 1 right) -> the WheelSpin it holds
var _last_ang: Array[float] = [0.0, 0.0]   # degrees about the wheel's z where each hand was last frame
var _spin_deg := 0.0                # the wheel as the hands turn it (unwrapped; + = left)
var _uid := 0                       # the vehicle whose wheel is held
var _steer_turn := -1               # the snapshot's turn when the last steer went; -1: none waiting
var _steer_ms := 0
var _steer_snap: Snapshot           # steer_of's last snapshot ...
var _steer_now: Variant = null      # ... and what it read
var _pedal: Array[int] = [0, 0]     # hand -> +1 throttle / -1 brake while its trigger is held, else 0
var _stick := 0                     # the turn stick: +1 forward, -1 back, 0
var _pedal_due := 0                 # ms: a pedal held may go again from here
var _note_ms := -NOTE_MS
var _lid: Array = [{}, {}]          # hand -> {uid, part, cargo: Node3D, lid: Node3D}


## The vehicle the player drives (holds the controls of), 0 when none.
static func driving_uid(snap: Snapshot) -> int:
	return snap.player_vehicle if snap != null and snap.player_driving and snap.player_vehicle > 0 else 0


## Degrees CDDA steers the player's vehicle off its facing (RideInfo.steer: negative left), null when not known.
static func steer_read(snap: Snapshot) -> Variant:
	if snap == null or snap.player_vehicle_state.is_empty():
		return null
	var face := NAN
	for veh: Snapshot.Vehicle in snap.vehicles:
		if veh.uid == snap.player_vehicle:
			face = veh.face_deg
			break
	var r := RideInfo.read(snap.player_vehicle_state, Callable(), face)
	if not r.ok or is_nan(r.turn_deg) or is_nan(r.face_deg):
		return null
	return r.steer()


## The angle (degrees) `v` is turned from `from` about `axis`, both seen along it; NAN when either lies on it.
static func angle_about(axis: Vector3, from: Vector3, v: Vector3) -> float:
	var a := axis.normalized()
	var p := from - a * a.dot(from)
	var q := v - a * a.dot(v)
	if p.length() < 1e-4 or q.length() < 1e-4:
		return NAN
	return rad_to_deg(atan2(a.dot(p.cross(q)), p.dot(q)))


func holds_wheel(i: int) -> bool:
	return _wheel[i] != null and is_instance_valid(_wheel[i])


func holds_lid(i: int) -> bool:
	return not (_lid[i] as Dictionary).is_empty()


## Whether hand `i` (0 left, 1 right) holds the wheel or a lid.
func holds(i: int) -> bool:
	return holds_wheel(i) or holds_lid(i)


## How far the held wheel is turned (degrees, + = left).
func wheel_deg() -> float:
	return _spin_deg


## A grip of hand `i` at `at` (world): the wheel's rim while driving, else a lid's handle; false when neither is there.
func grip(i: int, at: Vector3, snap: Snapshot) -> bool:
	if i < 0 or i > 1 or holds(i) or not at.is_finite() or snap == null or not interior.is_valid():
		return false
	var uid := driving_uid(snap)
	return (uid != 0 and _grip_wheel(i, at, uid)) or _grip_lid(i, at, snap)


func _grip_wheel(i: int, at: Vector3, uid: int) -> bool:
	var a: Variant = interior.call(uid)
	var w: Variant = (a as Dictionary).get("Wheel") if a is Dictionary else null
	if not w is Node3D or not is_instance_valid(w) or not (w as Node3D).is_inside_tree():
		return false
	var spin := (w as Node3D).get_node_or_null("WheelSpin") as Node3D
	if spin == null:
		return false
	var l := (w as Node3D).global_transform.affine_inverse() * at
	var r := float((w as Node3D).get_meta("radius_m", CarInterior.WHEEL_R))
	if absf(Vector2(l.x, l.y).length() - r) > GRAB_M or absf(l.z) > GRAB_M:
		return false
	if not holds_wheel(1 - i):   # the first hand on it: from where it is drawn
		var ci := (w as Node3D).get_parent() as CarInterior
		_spin_deg = ci.wheel_deg() if ci != null else rad_to_deg(spin.rotation.z)
		_steer_turn = -1
	_wheel[i] = spin
	_last_ang[i] = rad_to_deg(atan2(l.y, l.x))
	_uid = uid
	spin.set_meta("held", true)
	return true


func _grip_lid(i: int, at: Vector3, snap: Snapshot) -> bool:
	var best := {}
	var best_d := LID_GRAB_M
	var n := 0
	for veh: Snapshot.Vehicle in snap.vehicles:
		n += 1
		if n > MAX_CARS:
			break
		var a: Variant = interior.call(veh.uid)
		if not a is Dictionary:
			continue
		for k: Variant in a:
			var hood: bool = k is String and k == "Hood"   # the hood: no CDDA part, found by its name
			if not hood and (not k is String or not (k as String).begins_with("Cargo_")):
				continue
			var c: Variant = a[k]
			if not c is Node3D or not is_instance_valid(c) or not (c as Node3D).is_inside_tree():
				continue
			var lid := (c as Node3D).get_node_or_null("Lid") as Node3D
			var h: Variant = _meta(c, "handle")
			var part: Variant = CarInterior.HOOD if hood else _meta(c, "part")
			if lid == null or not h is Vector3 or not part is int or lid.get_meta("held", false):
				continue
			var d := (lid.global_transform * (h as Vector3)).distance_to(at)
			if d < best_d:
				best_d = d
				best = {"uid": veh.uid, "part": part, "cargo": c, "lid": lid, "hood": hood,
						"reach": _lid_deg(c, lid) >= CarInterior.LID_REACH - 0.01}
	if best.is_empty():
		return false
	(best["lid"] as Node3D).set_meta("held", true)
	_lid[i] = best
	return true


## Hand `i` lets go of what it holds here (the wheel: it turns back to CDDA's steer once no hand holds it; a lid: it
## opens or shuts, VehicleView.open_lid); false when it held nothing.
func let_go(i: int) -> bool:
	if i < 0 or i > 1:
		return false
	if _wheel[i] != null:
		var spin: Variant = _wheel[i]
		_wheel[i] = null
		if is_instance_valid(spin) and not holds_wheel(1 - i):
			(spin as Node3D).set_meta("held", false)
			_wake(spin)
		return true
	var g: Dictionary = _lid[i]
	if g.is_empty():
		return false
	_lid[i] = {}
	var lid: Variant = g["lid"]
	var c: Variant = g["cargo"]
	if is_instance_valid(lid):
		(lid as Node3D).set_meta("held", false)
		var deg := _lid_deg(c, lid) if is_instance_valid(c) else 0.0
		if g.get("hood", false):
			if open_hood.is_valid():
				open_hood.call(g["uid"], deg >= LID_SNAP)
		else:
			if open_lid.is_valid():
				open_lid.call(g["uid"], g["part"], deg >= LID_SNAP)
			_tell(g, deg >= LID_SNAP)
	return true


## How far lid `lid` of cargo node `c` is open, degrees about its hinge.
static func _lid_deg(c: Variant, lid: Variant) -> float:
	return rad_to_deg(CarInterior.angle_about((lid as Node3D).basis, (c as Node3D).get_meta("hinge_axis", Vector3.BACK)))


## lid_changed for held lid `g` (open: let go open; else shut, or swung under LID_REACH).
func _tell(g: Dictionary, open: bool) -> void:
	var c: Variant = g.get("cargo")
	if not lid_changed.is_valid() or not is_instance_valid(c):
		return
	var sq: Variant = _meta(c, "square")
	if sq is Vector3i:
		lid_changed.call(g["uid"], g["part"], sq, open)


## The cargo space hand point `p` reaches into, as ItemTray.source_for_cargo gives it ({kind: "cargo", vehicle, part,
## square}; {} none): within a drawn lid's opening (REACH_DEPTH down to REACH_ABOVE over its top) while can_reach
## allows it; `cells`: else anywhere over one of a vehicle's cargo squares (square_at) that can_reach allows (one
## without a lid: a truck bed, a seat's storage). Only what the snapshot lists (next to the player).
func cargo_at(p: Vector3, snap: Snapshot, cells := false) -> Dictionary:
	if snap == null or not p.is_finite() or not can_reach.is_valid():
		return {}
	var n := 0
	for veh: Snapshot.Vehicle in snap.vehicles:
		n += 1
		if n > MAX_CARS:
			break
		if veh.cargo.is_empty():
			continue
		var a: Variant = interior.call(veh.uid) if interior.is_valid() else {}
		if a is Dictionary:
			for k: Variant in a:
				var c: Variant = a[k]
				if not k is String or not (k as String).begins_with("Cargo_") or not c is Node3D \
						or not is_instance_valid(c) or not (c as Node3D).is_inside_tree():
					continue
				var sq: Variant = _meta(c, "square")
				var lid := (c as Node3D).get_node_or_null("Lid") as Node3D
				if not sq is Vector3i or lid == null:
					continue
				var l := (c as Node3D).global_transform.affine_inverse() * p
				if _in_opening(c as Node3D, lid, l):
					var src := _reachable(snap, veh.uid, sq)
					if not src.is_empty():
						return src
		if cells and square_at.is_valid():
			var sq: Variant = square_at.call(veh.uid, p)
			if sq is Vector3i:
				var src := _reachable(snap, veh.uid, sq)
				if not src.is_empty():
					return src
	return {}


## Whether `l` (in cargo node c's frame) is in its container: lead-world's meta "opening" (an AABB in that frame,
## where a hand is in it; the glovebox's too) reaching REACH_ABOVE out past its open face (meta "opening_out", that
## face's unit normal: (0, 1, 0) under a lid, toward the seat for the glovebox), OPENING_GROW round; without one (or
## a junk one), the box under a lid hinged on its top's edge (|x|, |z| within the hinge's offset, REACH_DEPTH down to
## REACH_ABOVE over LID_TOP).
static func _in_opening(c: Node3D, lid: Node3D, l: Vector3) -> bool:
	var box: Variant = _meta(c, "opening")
	if box is AABB:
		var b := box as AABB
		if b.position.is_finite() and b.size.is_finite() and b.size.x > 0.0 and b.size.y > 0.0 and b.size.z > 0.0 \
				and b.size.length() < MAX_OPENING_M:
			var out: Variant = _meta(c, "opening_out")
			if out is Vector3 and (out as Vector3).is_finite() and absf((out as Vector3).length() - 1.0) < 0.01:
				b = b.merge(AABB(b.position + (out as Vector3) * REACH_ABOVE, b.size))
			return b.grow(OPENING_GROW).has_point(l)
	var h := absf(lid.position.x)
	return absf(l.x) <= h and absf(l.z) <= h and l.y <= CarInterior.LID_TOP + REACH_ABOVE \
			and l.y >= CarInterior.LID_TOP - REACH_DEPTH


## Node n's meta `k`, null when it has none (get_meta's own null default logs an error).
static func _meta(n: Variant, k: String) -> Variant:
	return (n as Object).get_meta(k) if is_instance_valid(n) and (n as Object).has_meta(k) else null


func _reachable(snap: Snapshot, uid: int, sq: Vector3i) -> Dictionary:
	var src := ItemTray.source_for_cargo(snap, sq)
	if src.is_empty() or src["vehicle"] != uid or can_reach.call(uid, src["part"]) != true:
		return {}
	return src


## The interior of a WheelSpin moves on (CarInterior.step: it follows the held wheel, turns it back once let go).
static func _wake(spin: Variant) -> void:
	var w: Variant = (spin as Node3D).get_parent() if is_instance_valid(spin) else null
	var ci: Variant = (w as Node).get_parent() if w != null else null
	if ci is CarInterior:
		(ci as CarInterior).moving = true


## A trigger of hand `i` pressed (`speed_up`: the throttle, else the brake): true while driving (it is a pedal).
func pedal(i: int, speed_up: bool, snap: Snapshot) -> bool:
	if i < 0 or i > 1 or driving_uid(snap) == 0:
		return false
	_pedal[i] = 1 if speed_up else -1
	_pedal_due = 0
	return true


## That trigger let go: true when it was a pedal.
func unpedal(i: int) -> bool:
	if i < 0 or i > 1 or _pedal[i] == 0:
		return false
	_pedal[i] = 0
	return true


## The turn stick's forward / back (-1..1) while driving; 0 whenever the rig's driving branch didn't read it (a menu,
## a CDDA panel or a radial wheel up). On past STICK_ON, off inside STICK_OFF; a stick let go and pushed again waits
## out the last pedal's PEDAL_MS, so it sends at most one a PEDAL_MS however it wobbles.
func set_stick(y: float) -> void:
	if not is_finite(y):
		y = 0.0
	var s := 1 if y > STICK_ON else (-1 if y < -STICK_ON else 0)
	if s == 0 and _stick != 0 and y * _stick > STICK_OFF:
		s = _stick
	_stick = s


## Each frame: the held wheel and lids follow the hands (`hands`: [left, right] world positions), a steer or pedal due
## goes to CDDA. Not driving: the wheel and pedals let go.
func update(hands: Array, snap: Snapshot, now_ms := Time.get_ticks_msec()) -> void:
	_follow_lids(hands)
	var uid := driving_uid(snap)
	if uid == 0:
		for i in 2:
			if _wheel[i] != null:
				let_go(i)
		_pedal.fill(0)
		_stick = 0
		return
	var steer := _follow_wheel(hands, snap, uid, now_ms)
	var speed := _pedal_due_now(now_ms)
	if steer.is_empty() and speed.is_empty():
		return
	if not steer.is_empty():
		_steer_turn = snap.turn
		_steer_ms = now_ms
	if not speed.is_empty():
		_pedal_due = now_ms + PEDAL_MS
	_send(steer + speed, now_ms)


## The held wheel turned by the hands (the mean of their turns about its axis, at most WHEEL_MAX either way); the
## steer action due now ("LEFT" / "RIGHT", "" none).
func _follow_wheel(hands: Array, snap: Snapshot, uid: int, now_ms: int) -> String:
	for i in 2:
		if _wheel[i] != null and not is_instance_valid(_wheel[i]):
			_wheel[i] = null   # the interior was built again: the hand is off it
	if not holds_wheel(0) and not holds_wheel(1):
		return ""
	if uid != _uid:
		for i in 2:
			if _wheel[i] != null:
				let_go(i)
		return ""
	var spin: Node3D = _wheel[0] if holds_wheel(0) else _wheel[1]
	var w := spin.get_parent() as Node3D
	if w == null or not w.is_inside_tree():
		return ""
	var inv := w.global_transform.affine_inverse()
	var turn := 0.0
	var n := 0
	for i in 2:
		if not holds_wheel(i) or i >= hands.size() or not hands[i] is Vector3 or not (hands[i] as Vector3).is_finite():
			continue
		var l := inv * (hands[i] as Vector3)
		if Vector2(l.x, l.y).length() < HUB_M:
			continue
		var ang := rad_to_deg(atan2(l.y, l.x))
		turn += wrapf(ang - _last_ang[i], -180.0, 180.0)
		_last_ang[i] = ang
		n += 1
	if n > 0:
		_spin_deg = clampf(_spin_deg + turn / n, -CarInterior.WHEEL_MAX, CarInterior.WHEEL_MAX)
		spin.rotation = Vector3(0.0, 0.0, deg_to_rad(_spin_deg))
	_wake(spin)   # CarInterior keeps up with it, so letting go turns back from here
	if _steer_turn >= 0 and snap.turn == _steer_turn and now_ms - _steer_ms < STEER_WAIT_MS:
		return ""   # the last one not answered yet
	if snap != _steer_snap:
		_steer_snap = snap
		_steer_now = steer_read(snap)
	if _steer_now == null:
		return ""
	var off := -_spin_deg / CarInterior.WHEEL_RATIO - float(_steer_now)
	if absf(off) <= STEP_DEG * 0.5:
		return ""
	return "RIGHT" if off > 0.0 else "LEFT"


## The pedal action due now ("UP" / "DOWN", "" none): a trigger before the stick, the brake before the throttle.
func _pedal_due_now(now_ms: int) -> String:
	var d := 0
	for p: int in _pedal:
		if p != 0:
			d = p if d == 0 else mini(d, p)
	if d == 0:
		d = _stick
	if d == 0:
		return ""   # _pedal_due stays: pushed again, the stick waits it out (a trigger press goes at once: pedal)
	if now_ms < _pedal_due:
		return ""
	return "UP" if d > 0 else "DOWN"


func _send(act: String, now_ms: int) -> void:
	var note: Variant = paused.call() if paused.is_valid() else ""
	if note is String and not (note as String).is_empty():
		if now_ms - _note_ms >= NOTE_MS:
			_note_ms = now_ms
			if flash.is_valid():
				flash.call(note)
		return
	var ok: Variant = queue_action.call(act) if queue_action.is_valid() else false
	if ok is bool and ok:
		sent.append(act)
		if sent.size() > MAX_SENT:
			sent.remove_at(0)


## Each held lid swings with its hand about its hinge (0 to its open_deg; a hand past the hinge's far side: open).
func _follow_lids(hands: Array) -> void:
	for i in 2:
		var g: Dictionary = _lid[i]
		if g.is_empty():
			continue
		var c: Variant = g["cargo"]
		var lid: Variant = g["lid"]
		if not is_instance_valid(c) or not is_instance_valid(lid) or not (c as Node3D).is_inside_tree():
			_lid[i] = {}   # the interior went
			continue
		if i >= hands.size() or not hands[i] is Vector3 or not (hands[i] as Vector3).is_finite():
			continue
		var axis: Vector3 = (c as Node3D).get_meta("hinge_axis", Vector3.BACK)
		var top := float((c as Node3D).get_meta("open_deg", CarInterior.LID_OPEN))
		var v := (c as Node3D).global_transform.affine_inverse() * (hands[i] as Vector3) - (lid as Node3D).position
		var deg := angle_about(axis, (c as Node3D).get_meta("handle", Vector3.LEFT), v)
		if is_nan(deg):
			continue
		deg = top if deg < -90.0 else clampf(deg, 0.0, top)
		(lid as Node3D).basis = Basis(axis.normalized(), deg_to_rad(deg))
		var reach := deg >= CarInterior.LID_REACH - 0.01
		if g.get("reach", true) and not reach:
			_tell(g, false)   # swung shut far enough that hands no longer reach in
		g["reach"] = reach
