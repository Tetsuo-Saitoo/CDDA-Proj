class_name VrWork
extends RefCounted
## C6 vehicle work by hand (lead-vr; TASKS C6 (e)): which part of a vehicle next to the player each empty hand, or
## item held in a hand (repair by tool, VrRig.work_tool), is on. A hand inside a part's drawn spot (VehicleView.part_anchors: its middle and size, worked out once a
## snapshot) picks it, the one it is most in for its size; with nothing touched and the trigger half pressed, the
## pull ray picks the part nearest where it meets the vehicle. The picked part is lit (VehicleView.highlight, one at a
## time: the right hand's, else the left's). Nothing goes to CDDA here; the trigger on a picked part opens the command
## wheel (VrWorkMenu, VrRig.open_work) on lead-ui's VehicleWorkSession. Reach is CDDA's (VehicleWorkData.in_reach: a part of the vehicle next to the player);
## not while driving.

const TOUCH_M := 0.08       # m past a part's half size a hand still touches it
const RAY_NEAR_M := 0.6     # m from where the pull ray meets a vehicle to the middle of the part it picks
const RAY_M := 3.0          # m the pull ray looks
const PICK_MS := 100        # a hand's pick is looked for again no sooner
const MAX_CARS := 16        # vehicles looked through
const MAX_ROWS := 512       # parts of one vehicle looked through
const MAX_SIZE_M := 10.0    # a part's size past this is junk

var anchors := Callable()     # (uid) -> {row: {point, normal, size}}: VehicleView.part_anchors (main.gd)
var highlight := Callable()   # (uid, row) -> void: VehicleView.highlight (main.gd); row -1: none
var ray := Callable()         # (origin, dir, max_m) -> Dictionary: LookRay.cast ("hit", "point", "vehicle")

var picked: Array = [{}, {}]  # hand (0 left, 1 right) -> {uid, row} it is on; {} none
var lit: Array = []           # [uid, row] highlighted; [] none
var hold := false             # the work wheel is up on a pick (VrRig): picks and light stay
var _due: Array[int] = [0, 0]


## The part of a vehicle in reach that point `p` touches: {uid, row}; {} none.
func touch(p: Vector3, snap: Snapshot) -> Dictionary:
	var best := {}
	var best_k := INF
	for veh in _in_reach(snap):
		var a: Variant = anchors.call(veh.uid) if anchors.is_valid() else null
		if not a is Dictionary or not p.is_finite():
			continue
		var m := 0
		for row: Variant in a:
			m += 1
			if m > MAX_ROWS:
				break
			var r := _radius(a[row])
			if not row is int or r < 0.0:
				continue
			var k := ((a[row] as Dictionary)["point"] as Vector3).distance_to(p) / (r + TOUCH_M)
			if k <= 1.0 and k < best_k:
				best_k = k
				best = {"uid": veh.uid, "row": row}
	return best


## The part of vehicle `uid` (in reach) whose middle is nearest point `p`, within RAY_NEAR_M: {uid, row}; {} none.
func nearest(uid: int, p: Vector3, snap: Snapshot) -> Dictionary:
	if not p.is_finite():
		return {}
	for veh in _in_reach(snap):
		if veh.uid != uid:
			continue
		var a: Variant = anchors.call(uid) if anchors.is_valid() else null
		if not a is Dictionary:
			return {}
		var best := {}
		var best_d := RAY_NEAR_M
		var m := 0
		for row: Variant in a:
			m += 1
			if m > MAX_ROWS:
				break
			if not row is int or _radius(a[row]) < 0.0:
				continue
			var d := ((a[row] as Dictionary)["point"] as Vector3).distance_to(p)
			if d < best_d:
				best_d = d
				best = {"uid": uid, "row": row}
		return best
	return {}


## Per frame for hand `i` at `p` pointing along `dir`: `free` when it is empty and nothing else of the rig's is under
## it; `pointing` when its trigger is half pressed with nothing else to point at. Looks again at most every PICK_MS;
## not free, or driving: nothing picked at once. Then the light follows.
func update(i: int, p: Vector3, dir: Vector3, free: bool, pointing: bool, snap: Snapshot,
		now_ms := Time.get_ticks_msec()) -> void:
	if i < 0 or i > 1 or hold:
		return
	if not free or snap == null or VrDrive.driving_uid(snap) != 0:
		picked[i] = {}
		_due[i] = 0
	elif now_ms >= _due[i]:
		_due[i] = now_ms + PICK_MS
		var w := touch(p, snap)
		if w.is_empty() and pointing and ray.is_valid() and p.is_finite() and dir.is_finite() and dir != Vector3.ZERO:
			var hit: Variant = ray.call(p, dir.normalized(), RAY_M)
			if hit is Dictionary and hit.get("hit") == true and hit.get("vehicle") is int and hit.get("point") is Vector3:
				w = nearest(hit["vehicle"], hit["point"], snap)
		picked[i] = w
	_light()


## Nothing picked, nothing lit (the hands went away: no hands, a menu).
func clear() -> void:
	picked = [{}, {}]
	_due = [0, 0] as Array[int]
	_light()


## The light again (another highlight put it out).
func relight() -> void:
	lit = []
	_light()


func _light() -> void:
	var want: Array = []
	for i in [1, 0]:
		var w: Dictionary = picked[i]
		if not w.is_empty():
			want = [w["uid"], w["row"]]
			break
	if want == lit:
		return
	if highlight.is_valid():
		if want.is_empty():
			highlight.call(lit[0], -1)
		else:
			highlight.call(want[0], want[1])
	lit = want


## The vehicles work could be done on from where the player stands (at most MAX_CARS looked at).
static func _in_reach(snap: Snapshot) -> Array[Snapshot.Vehicle]:
	var out: Array[Snapshot.Vehicle] = []
	if snap == null:
		return out
	var n := 0
	for veh in snap.vehicles:
		n += 1
		if n > MAX_CARS:
			break
		if VehicleWorkData.in_reach(snap, veh):
			out.append(veh)
	return out


## Half a part anchor's size (its spot's largest side), or -1 for a junk anchor.
static func _radius(e: Variant) -> float:
	if not e is Dictionary:
		return -1.0
	var pt: Variant = (e as Dictionary).get("point")
	var sz: Variant = (e as Dictionary).get("size")
	if not pt is Vector3 or not (pt as Vector3).is_finite() or not (sz is float or sz is int):
		return -1.0
	var s := float(sz)
	return s * 0.5 if s >= 0.0 and s <= MAX_SIZE_M else -1.0
