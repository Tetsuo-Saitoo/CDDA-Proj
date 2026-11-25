class_name VrPartPull
extends RefCounted
## C6 vehicle work by hand, slice 2 (lead-vr; TASKS C6 (e)): a vehicle part pulled out of its spot. Gripping a part
## VrWork picked takes a copy of it into the hand (VehicleView.part_copy: the part as drawn, at its anchor) and hides
## the original (hide_part). Pulled PULL_M from where the grip closed, CDDA's removal is asked for once (VrRig sends
## "o" through the session; CDDA checks it all again). Let go before that, or CDDA refused: the copy goes and the
## original shows again (it snaps back). Started: the copy stays in the hand while the removal runs and the original
## stays hidden until the part is gone (hide_part ends by itself then, or here when the work stops with the part
## still there). Only a picture: CDDA never puts the part in the hand; its removal yields it to cargo or the floor.

const PULL_M := 0.15   # m from where the grip closed that asks for the removal

var part_copy := Callable()   # (uid, row) -> Node3D, not in the tree, at the part's world pose: VehicleView.part_copy
var hide_part := Callable()   # (uid, row, hidden) -> bool: VehicleView.hide_part (one part a car)

var hand := -1        # the gripping hand (0 left, 1 right); -1 none
var uid := 0
var row := -1
var state := ""       # "held": not pulled out yet; "asked": "o" sent; "started": CDDA's removal runs; "": none
var copy: Node3D      # the part's copy in the hand
var _grip_at := Vector3.ZERO   # where the hand closed (world)
var _offset := Transform3D()   # the copy's pose in the hand's frame
var _hidden: Array = []        # [uid, row] left hidden after a started removal was let go: shown when the work stops


## Hand `i` at pose `hand_xf` grips part `part_row` of vehicle `vehicle`: its copy, a top-level child of `parent`,
## follows the hand and the original is hidden. False (nothing changed) when one is gripped already or no copy comes.
func grip(i: int, hand_xf: Transform3D, vehicle: int, part_row: int, parent: Node) -> bool:
	if hand >= 0 or i < 0 or i > 1 or not hand_xf.is_finite() or parent == null or not part_copy.is_valid():
		return false
	var c: Variant = part_copy.call(vehicle, part_row)
	if not c is Node3D or (c as Node3D).is_inside_tree():
		return false
	var xf := (c as Node3D).transform   # the part's world pose: not in the tree yet
	if not xf.is_finite():
		(c as Node3D).free()
		return false
	copy = c
	copy.top_level = true
	parent.add_child(copy)
	copy.global_transform = xf
	hand = i
	uid = vehicle
	row = part_row
	state = "held"
	_grip_at = hand_xf.origin
	_offset = hand_xf.affine_inverse() * xf
	if hide_part.is_valid():
		hide_part.call(vehicle, part_row, true)
	return true


## Per frame: the copy follows hand pose `hand_xf`. True once, the frame it is first pulled PULL_M out.
func follow(hand_xf: Transform3D) -> bool:
	if hand < 0 or not hand_xf.is_finite():
		return false
	if is_instance_valid(copy):
		copy.global_transform = hand_xf * _offset
	if state == "held" and hand_xf.origin.distance_to(_grip_at) > PULL_M:
		state = "asked"
		return true
	return false


## CDDA's removal started (VehicleWorkSession.started "o").
func started() -> void:
	if state == "asked":
		state = "started"


## The hand let go, CDDA refused, or the work is over: the copy goes. The original shows again, unless CDDA's removal
## started: then it stays hidden until the part is gone or the work stops (settle).
func end() -> void:
	if hand < 0:
		return
	if state == "started":
		_hidden = [uid, row]
	elif hide_part.is_valid():
		hide_part.call(uid, row, false)
	if is_instance_valid(copy):
		copy.queue_free()
	copy = null
	hand = -1
	uid = 0
	row = -1
	state = ""


## Per frame: `busy` false (the player's CDDA activity is over): a part left hidden after a started removal shows
## again. If the removal took it, lead-world's hide already ended and this shows nothing new.
func settle(busy: bool) -> void:
	if _hidden.is_empty() or busy or (hand >= 0 and uid == _hidden[0]):
		return   # (a part of that car in the hand now: its own hide wins until let go)
	if hide_part.is_valid():
		hide_part.call(_hidden[0], _hidden[1], false)
		hide_part.call(_hidden[0], -1, false)   # lead-world's 50653fa: whatever is still hidden there (rows moved)
	_hidden = []
