class_name VrMouth
extends RefCounted
## Eat or drink in VR (VrRig `mouth`): bring what a hand holds to the mouth and keep it there HOLD_S; CDDA's own
## consume goes out (ItemActions.consume, the bridge's "consume" op: its rules, its questions on the panel, its
## time; a bottle drinks what is inside it). Only a carried item ItemActions.consumable calls food, drink or pills (or
## a container holding some), with nothing in flight for it and no menu or panel open. A light tick when the hand
## reaches the mouth, a buzz when sent; CDDA's no (with its reason) by that hand. The hand leaves the mouth (LEAVE_M)
## before it can again. The time it takes shows as VrBusy's "Eating..." (CDDA's activity).

const BELOW := 0.09     # m: the mouth is this far under the eyes ...
const AHEAD := 0.06     # ... and this far ahead of them
const REACH_M := 0.12   # the hand this near the mouth ...
const HOLD_S := 0.5     # ... for this long: so a hand passing the face eats nothing
const LEAVE_M := 0.2    # out this far before the same hand can again
const MAX_SENT := 16    # consumes waiting for CDDA's answer we keep the hand of

enum { NONE, NEAR, SENT }

var rig: VrRig
## main.gd's ItemActions; null: nothing is eaten.
var actions: ItemActions:
	set(a):
		if is_instance_valid(actions):
			if actions.finished.is_connected(_on_finished):
				actions.finished.disconnect(_on_finished)
			if actions.refused.is_connected(_on_refused):
				actions.refused.disconnect(_on_refused)
		actions = a
		_sent.clear()
		if a != null:
			a.finished.connect(_on_finished)
			a.refused.connect(_on_refused)

var _at := [0.0, 0.0]          # seconds each hand has been at the mouth
var _near := [false, false]
var _armed := [true, true]     # false once sent, until the hand leaves the mouth
var _sent := {}                # uid -> the hand whose consume CDDA hasn't answered yet
var _hinted := false


## Where the mouth is for eyes at `eyes`: under and a little ahead of them, turning and tilting with the head.
static func point(eyes: Transform3D) -> Vector3:
	return eyes * Vector3(0.0, -BELOW, -AHEAD)


## Whether hand i may eat or drink `item` now (see the top).
func edible(i: int, item: ItemRef) -> bool:
	if item == null or not item.carried or actions == null or rig == null or rig.world == null:
		return false
	if actions.pending(item.uid) != "" or _sent.size() >= MAX_SENT or rig.ui_open() or rig.pack.hand == i:
		return false
	return ItemActions.consumable(item, rig.world.snapshot, rig.world.tables)


## Hand i at `at` holding `item` (null: none) for `delta` seconds: NONE, NEAR (at the mouth, waiting HOLD_S) or SENT
## (its consume went out just now).
func update(i: int, item: ItemRef, at: Vector3, delta: float) -> int:
	if i < 0 or i > 1 or rig == null or rig.camera == null:
		return NONE
	var d := at.distance_to(point(rig.camera.global_transform)) if at.is_finite() else INF
	if d > LEAVE_M:
		_armed[i] = true
	var ok := edible(i, item)
	if ok and not _hinted:
		_hinted = true
		rig.hint_due.emit("vr_eat")
	if not ok or d > REACH_M or not _armed[i]:
		_at[i] = 0.0
		_near[i] = false
		return NONE
	var c := _ctrl(i)
	if not _near[i]:
		_near[i] = true
		rig.feel(c, 0.15, 0.03)   # it is at the mouth
	_at[i] += clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	if _at[i] < HOLD_S:
		return NEAR
	_at[i] = 0.0
	_near[i] = false
	_armed[i] = false
	if not actions.consume(item):
		rig.feel(c)
		rig.say(i, "You can't eat or drink that now.")
		return NONE
	_sent[item.uid] = i
	rig.feel(c, 0.3, 0.06)
	return SENT


func _ctrl(i: int) -> XRController3D:
	return rig.left if i == 0 else rig.right


func _on_finished(item: ItemRef, op: String) -> void:
	if op == "consume" and item != null:
		_sent.erase(item.uid)


## CDDA said no (too full, rotten and the player said no, nothing inside): a buzz and its reason by that hand.
func _on_refused(item: ItemRef, op: String, reason: String) -> void:
	if op != "consume" or item == null or not _sent.has(item.uid):
		return
	var i: int = _sent[item.uid]
	_sent.erase(item.uid)
	if rig != null and is_instance_valid(rig):
		rig.feel(_ctrl(i))
		rig.say(i, reason)
