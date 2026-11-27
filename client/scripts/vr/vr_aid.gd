class_name VrAid
extends RefCounted
## First aid in VR (VrRig `aid`): bring a first aid item a hand holds (IdTables.Def.heal: a bandage, disinfectant, ...)
## to a body part and keep it there HOLD_S: CDDA's own consume with that part goes out (ItemActions.consume(item,
## part): its treatment without its menu, its time, ACT_FIRSTAID: the result comes at the end, VrBusy shows it going).
## Parts: the other hand's forearm (that arm), the head, the chest (torso), a leg (the hand low, on that side). A part
## lights (a green ball there) when the item can treat it by CDDA's rule (needs(); the bridge decides in the end), with
## a light tick; a buzz when sent; CDDA's no (with why) by that hand. The hand leaves the part before it can again.
## Once the snapshot shows the treatment on that part (its bleed down, bandaged or disinfected up, a bite or an
## infection down), what was done shows by that hand ("Left arm: bandaged") with a light buzz (watch()).

const HOLD_S := 0.6       # s at a part before it goes out: so a hand passing by treats nothing
const ARM_BACK := 0.12    # m behind the other controller (toward its elbow): that forearm's middle ...
const ARM_M := 0.12       # ... and how near the hand comes to it
const HEAD_UP := 0.04     # the head's middle above the eyes ...
const HEAD_M := 0.16
const CHEST_DOWN := 0.45  # the chest: this far under the eyes ...
const CHEST_AHEAD := 0.1  # ... and ahead
const CHEST_M := 0.2
const LEG_DOWN := 0.8     # the hand this far under the eyes: a leg, on its side of the head
const MARK_R := 0.05
const MAX_SENT := 16
const WATCH_S := 600.0    # s a sent treatment is watched for in the snapshot at most (CDDA's time in real time) ...
const AFTER_S := 5.0      # ... and after CDDA finished it (the snapshot showing it comes a little later)
const NAMES := {"arm_l": "Left arm", "arm_r": "Right arm", "head": "Head", "torso": "Chest", "leg_l": "Left leg",
		"leg_r": "Right leg"}
const STATE := ["bleed", "bandaged", "disinfected", "bite", "infected"]

enum { NONE, NEAR, SENT }

var rig: VrRig
## main.gd's ItemActions; null: nothing is treated.
var actions: ItemActions:
	set(a):
		if is_instance_valid(actions):
			if actions.refused.is_connected(_on_refused):
				actions.refused.disconnect(_on_refused)
			if actions.finished.is_connected(_on_finished):
				actions.finished.disconnect(_on_finished)
			if actions.cleared.is_connected(_forget):
				actions.cleared.disconnect(_forget)
		actions = a
		_sent.clear()
		if a != null:
			a.refused.connect(_on_refused)
			a.finished.connect(_on_finished)
			a.cleared.connect(_forget)

var _at := [0.0, 0.0]       # seconds each hand has been at its part
var _part := ["", ""]       # the part each hand is at and can treat, "" none
var _armed := [true, true]  # false once sent, until the hand is at no part
var _sent := {}             # uid -> the hand whose treatment CDDA hasn't answered yet
var _watch := {}            # uid -> {hand, part, was (the part's state when sent), left (s)}: not seen done yet
var _marks: Array[MeshInstance3D] = []
var _hinted := false


## Item `item`'s first aid bits (IdTables.HEAL_*), 0 when it is none (food, pills) or unknown.
static func heals(item: ItemRef, tables: IdTables) -> int:
	if item == null or tables == null:
		return 0
	var d := tables.def_at("itype", item.type)
	return d.heal if d != null else 0


## The body part a hand at `at` is on: {part, at: where it lights}, {} none. `eyes`: the head; `other`: the other
## controller, on side `other_side` ("l" / "r").
static func part_at(at: Vector3, eyes: Transform3D, other: Transform3D, other_side: String) -> Dictionary:
	if not at.is_finite() or not eyes.origin.is_finite():
		return {}
	if other.origin.is_finite() and other_side in ["l", "r"]:
		var arm := other * Vector3(0.0, 0.0, ARM_BACK)
		if at.distance_to(arm) <= ARM_M:
			return {"part": "arm_" + other_side, "at": arm}
	var head := eyes.origin + Vector3.UP * HEAD_UP
	if at.distance_to(head) <= HEAD_M:
		return {"part": "head", "at": head}
	var f := -eyes.basis.z
	f.y = 0.0
	f = f.normalized() if f.length_squared() > 1e-4 else Vector3.FORWARD
	var chest := eyes.origin + Vector3.DOWN * CHEST_DOWN + f * CHEST_AHEAD
	if at.distance_to(chest) <= CHEST_M:
		return {"part": "torso", "at": chest}
	if at.y <= eyes.origin.y - LEG_DOWN:
		var right := f.cross(Vector3.UP)
		return {"part": "leg_r" if (at - eyes.origin).dot(right) >= 0.0 else "leg_l", "at": at}
	return {}


## Whether first aid with bits `heal` does something to body part `part` now, by CDDA's rule: it stops a bleed there,
## treats a bite or an infection there, or the part is hurt but not broken and it bandages, disinfects or heals.
static func needs(part: String, heal: int, snap: Snapshot, tables: IdTables) -> bool:
	if heal == 0 or snap == null or tables == null:
		return false
	for b: Snapshot.BodyPart in snap.player_parts:
		if tables.body_part_name(b.id) != part:
			continue
		var mends := (heal & (IdTables.HEAL_BANDAGE | IdTables.HEAL_DISINFECT | IdTables.HEAL_HP)) != 0
		return ((heal & IdTables.HEAL_BLEED) != 0 and b.bleed > 0) \
				or ((heal & IdTables.HEAL_BITE) != 0 and b.bite > 0) \
				or ((heal & IdTables.HEAL_INFECTION) != 0 and b.infected > 0) \
				or (mends and b.hp > 0 and b.hp < b.hp_max)
	return false


## Hand i's first aid bits for `item` now: 0 when it isn't first aid, isn't carried, has something in flight, or a
## menu, panel or the pack is open.
func _heal(i: int, item: ItemRef) -> int:
	if item == null or not item.carried or actions == null or rig == null or rig.world == null:
		return 0
	if actions.pending(item.uid) != "" or _sent.size() >= MAX_SENT or rig.ui_open() or rig.pack.hand == i:
		return 0
	return heals(item, rig.world.tables)


## Hand i at `at` holding `item` (null: none) for `delta` seconds: NONE, NEAR (at a part it can treat, waiting HOLD_S)
## or SENT (its treatment went out just now).
func update(i: int, item: ItemRef, at: Vector3, delta: float) -> int:
	if i < 0 or i > 1 or rig == null or rig.camera == null:
		return NONE
	var heal := _heal(i, item)
	if heal != 0 and not _hinted:
		_hinted = true
		rig.hint_due.emit("vr_bleed")
	var other := rig.right if i == 0 else rig.left
	var z := part_at(at, rig.camera.global_transform, other.global_transform, "r" if i == 0 else "l") \
			if heal != 0 else {}
	var p: String = z.get("part", "")
	if p == "":
		_armed[i] = true
	if p == "" or not _armed[i] or not needs(p, heal, rig.world.snapshot, rig.world.tables):
		_at[i] = 0.0
		_part[i] = ""
		_mark(i, null)
		return NONE
	var c := rig.left if i == 0 else rig.right
	_mark(i, z["at"])
	if p != _part[i]:
		_part[i] = p
		_at[i] = 0.0
		rig.feel(c, 0.15, 0.03)   # a part it can treat
	_at[i] += clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	if _at[i] < HOLD_S:
		return NEAR
	_at[i] = 0.0
	_part[i] = ""
	_armed[i] = false
	_mark(i, null)
	if not actions.consume(item, p):
		rig.feel(c)
		rig.say(i, "You can't do that now.")
		return NONE
	_sent[item.uid] = i
	var was := state_of(p, rig.world.snapshot, rig.world.tables)
	if not was.is_empty() and _watch.size() < MAX_SENT:
		_watch[item.uid] = {"hand": i, "part": p, "was": was, "left": WATCH_S}
	rig.feel(c, 0.3, 0.06)
	return SENT


## Body part `part`'s treatment state in `snap` ({bleed, bandaged, disinfected, bite, infected}), {} not there.
static func state_of(part: String, snap: Snapshot, tables: IdTables) -> Dictionary:
	if snap == null or tables == null:
		return {}
	for b: Snapshot.BodyPart in snap.player_parts:
		if tables.body_part_name(b.id) == part:
			return {"bleed": b.bleed, "bandaged": b.bandaged, "disinfected": b.disinfected, "bite": b.bite,
					"infected": b.infected}
	return {}


## What a treatment did to part `part`, from its state before (`was`) to now: "Left arm: bandaged, disinfected";
## "" nothing yet.
static func treated(part: String, was: Dictionary, now: Dictionary) -> String:
	if was.is_empty() or now.is_empty():
		return ""
	var done := PackedStringArray()
	if int(now["bleed"]) < int(was["bleed"]):
		done.append("bleeding stopped" if int(now["bleed"]) <= 0 else "bleeding slowed")
	if int(now["bandaged"]) > int(was["bandaged"]):
		done.append("bandaged")
	if int(now["disinfected"]) > int(was["disinfected"]):
		done.append("disinfected")
	if int(now["bite"]) < int(was["bite"]) or int(now["infected"]) < int(was["infected"]):
		done.append("treated")
	if done.is_empty():
		return ""
	return "%s: %s" % [NAMES.get(part, "That part"), ", ".join(done)]


## Per frame: a sent treatment the snapshot now shows says so by its hand; one not seen in time is let go.
func watch(delta: float) -> void:
	if _watch.is_empty() or rig == null or rig.world == null:
		return
	var dt := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	for uid: int in _watch.keys():
		var w: Dictionary = _watch[uid]
		var text := treated(w["part"], w["was"], state_of(w["part"], rig.world.snapshot, rig.world.tables))
		var left: float = w["left"] - dt
		if text != "":
			_watch.erase(uid)
			var i: int = w["hand"]
			rig.feel(rig.left if i == 0 else rig.right, 0.2, 0.04)
			rig.say(i, text, true)
		elif left <= 0.0:
			_watch.erase(uid)
		else:
			_watch[uid] = {"hand": w["hand"], "part": w["part"], "was": w["was"], "left": left}


## The part hand i is at, "" none (tests).
func part_of(i: int) -> String:
	return _part[i] if i == 0 or i == 1 else ""


## Hand i's green ball at `where` (a Vector3), hidden for null.
func _mark(i: int, where: Variant) -> void:
	if _marks.is_empty():
		if not where is Vector3:
			return
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.35, 1.0, 0.45, 0.35)
		mat.no_depth_test = true
		mat.render_priority = 90
		var ball := SphereMesh.new()
		ball.radius = MARK_R
		ball.height = MARK_R * 2.0
		ball.radial_segments = 12
		ball.rings = 6
		ball.material = mat
		for side: String in ["Left", "Right"]:
			var m := MeshInstance3D.new()
			m.name = "AidMark" + side
			m.mesh = ball
			m.top_level = true
			m.visible = false
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			rig.add_child(m)
			_marks.append(m)
	if not is_instance_valid(_marks[i]):
		return
	_marks[i].visible = where is Vector3
	if where is Vector3:
		_marks[i].global_position = where


## The ball shown for hand i (tests).
func mark_shown(i: int) -> bool:
	return i >= 0 and i < _marks.size() and is_instance_valid(_marks[i]) and _marks[i].visible


func _on_finished(item: ItemRef, op: String) -> void:
	if op == "consume" and item != null:
		_sent.erase(item.uid)
		if _watch.has(item.uid):   # done: its result shows in a snapshot soon, or not at all
			var w: Dictionary = _watch[item.uid]
			_watch[item.uid] = {"hand": w["hand"], "part": w["part"], "was": w["was"],
					"left": minf(w["left"], AFTER_S)}


## CDDA said no (nothing to treat there, a broken or bionic limb, a filthy item): a buzz and why by that hand.
func _on_refused(item: ItemRef, op: String, reason: String) -> void:
	if op != "consume" or item == null or not _sent.has(item.uid):
		return
	var i: int = _sent[item.uid]
	_sent.erase(item.uid)
	_watch.erase(item.uid)
	if rig != null and is_instance_valid(rig):
		rig.feel(rig.left if i == 0 else rig.right)
		rig.say(i, reason)


## The game ended or was left (ItemActions.cleared): nothing it had in flight will be answered.
func _forget() -> void:
	_sent.clear()
	_watch.clear()
