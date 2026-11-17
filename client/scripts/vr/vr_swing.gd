class_name VrSwing
extends RefCounted
## Block L3: melee by hand in VR (VrRig `swing`, called every frame). A hand moving faster than SWING_SPEED swings.
## Its striking lines run from the hand to the ends of what it holds (the held copy's farthest point from the hand,
## and the far end from there: an item held at its middle strikes with either end; MAX_TIP_M at most; an empty hand,
## a gun or something small: FIST_M along the hand's pointing direction). When a line meets a creature's figure
## (AimController.strike_segment: nothing solid before it, the body part it met) standing 1 - 2 squares off the
## player along one of the 8 ways, CDDA's aimed strike goes out for that hand (`fp3d_attack_<main|off>_aim_<DIR>`;
## the main controller is CDDA's main hand) and the aim AimController kept answers CDDA's `swing` request
## (contracts/ui_requests.md, Melee). CDDA rolls the hit and owns time, damage and reach: how hard you swing changes
## nothing.
## A line that meets no creature but ends in a wall, window, door or furniture next to the player (a hand at least
## SMASH_SPEED fast: a bit more than a strike, so brushing a wall smashes nothing) smashes that square: CDDA's smash
## (AimController.SMASH_AT and smash_square, as the flat screen's strike keys at furniture) through the same queue.
## One strike per swing: the hand must slow under REARM_SPEED before it strikes again, at least GAP_S apart, and no
## hand strikes, or even looks for a figure (that would replace the kept aim), while a strike is in flight: until
## CDDA's swing request was answered (AimController used the kept aim up), FLIGHT_S at most. No strikes while a menu
## or prompt is up, without a game, or from a hand that isn't tracked, holds a door or the open pack, steadies the
## other hand's two-handed item (that item's hand strikes), racks the gun's slide, is still pulling an item in, or
## is the gun hand with a finger on the trigger. A buzz when a strike goes out, a stronger one when CDDA says it hit
## (HitFeedback.strike_confirmed for the creature struck, within HIT_KEEP_MS), a faint one when it missed
## (swing_resolved); only the hand that struck buzzes. A technique CDDA used for that strike (technique_used) shows
## by that hand: one billboarded label at a time, LABEL_S, then it fades over LABEL_FADE_S. Nothing here talks to
## the sim but that one action.

## A strike went out: CDDA's hand ("main" / "off"), the way (a direction name such as "LEFT", or "at": a knight's
## move, AimController.strike_square), the creature touched.
signal struck(hand: String, dir: String, uid: int)

const SWING_SPEED := 2.5   # m/s: a hand this fast swings ...
const SMASH_SPEED := 3.0   # ... and this fast smashes what its line ends in (no creature on it)
const REARM_SPEED := 1.0   # ... and strikes again only after slowing under this
const GAP_S := 0.4         # seconds between a hand's strikes at least
const FLIGHT_S := 1.5      # a strike sent blocks the next this long, or until its swing request was answered
const FIST_M := 0.15       # an empty hand strikes this far along its pointing direction
const MIN_TIP_M := 0.2     # a held item reaching less than this from the hand strikes like a fist
const MAX_TIP_M := 2.5     # no striking line is longer (a long spear)
const MAX_NODES := 64      # nodes of a held copy looked at for its tip
const HIT_KEEP_MS := 3000  # a hit confirmed this long after a strike is that strike's
const AIM_MARK := "_aim_"  # in the action's name, before its way
const MISS_AMP := 0.25     # a strike CDDA says missed: a faint buzz ...
const MISS_S := 0.05
const LABEL_S := 1.5       # a technique's name shows this long by the hand ...
const LABEL_FADE_S := 0.5  # ... then fades over this
const LABEL_LEN := 40      # characters of it at most (the name comes from the sim)
const LABEL_UP := 0.19     # m over the hand (above VrRig.say's notes)

var rig: VrRig
## The aim controller that picks the figure and answers the swing request; null: the gun's (main.gd sets that).
var aim: AimController
## Queues a main-loop action (-> bool: taken); invalid: the gun's.
var queue_action := Callable()
var strikes := 0           # strikes sent (tests)
var hits := 0              # strikes CDDA confirmed as hits (tests)
var misses := 0            # strikes CDDA said missed (tests)
var smashes := 0           # smashes sent (tests)
var label: Label3D        # the technique's name by the hand that struck; null until one shows
var _label_left := 0.0    # seconds before it is gone
var _armed: Array[bool] = [true, true]
var _cool: Array[float] = [0.0, 0.0]
var _flight := 0.0         # > 0: a strike went out, seconds left before the next may
var _last := {}            # the last strike sent: {hand (0 left / 1 right), uid, time msec}


## Every frame from the rig, after track_hands: looks for a swing meeting a figure and sends its strike.
func update(delta: float) -> void:
	if rig == null or rig.world == null:
		return
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	_fade_label(d)
	var snap := rig.world.snapshot
	if _flight > 0.0:
		_flight = maxf(_flight - d, 0.0)
		var am := aim if aim != null else rig.gun.aim
		if am != null and am.melee_aim.is_empty():
			_flight = 0.0   # the swing request was answered: the kept aim is used up
	for i in 2:
		_cool[i] = maxf(_cool[i] - d, 0.0)
		var v: Vector3 = rig.hand_vel[i]
		var speed := v.length() if v.is_finite() else 0.0
		if speed < REARM_SPEED:
			_armed[i] = true
		if speed < SWING_SPEED or not _armed[i] or _cool[i] > 0.0 or _flight > 0.0 or snap == null:
			continue
		if rig.ui_open() or not can_swing(i):
			continue
		var lines := strike_lines(i)
		var spent := false
		for line: Array in lines:
			if _strike(i, line[0], line[1], snap):
				spent = true
				break
		if spent or speed < SMASH_SPEED:
			continue
		for line: Array in lines:
			if _smash(i, line[0], line[1], snap):
				break


## Hand i may strike: tracked; not holding a door or the open pack; not racking the gun's slide or still pulling an
## item in; not the gun hand with a finger on the trigger; not steadying the two-handed item the other hand holds
## (CDDA has both hands on it: that item's hand strikes with it).
func can_swing(i: int) -> bool:
	if not rig.tracked(i) or rig.pack.hand == i or rig._fly_t[i] >= 0.0 or rig.gun.rack_hand() == i \
			or (rig._gun_hand(i) and rig.trigger_half(i)):
		return false
	if rig.hands == null:
		return true
	var held := rig.hands.holding(VrRig.HAND_IDS[i])
	if not held.is_empty():
		return held.get("kind") == "item"
	var other := rig.hands.proxy(VrRig.HAND_IDS[1 - i])
	return other == null or not rig._supports(i, other.global_transform)


## Hand i's striking lines in the world, each [from, to]: the hand to the far end of what it holds and, when the
## other end sticks out too, to that one; else one line, a fist's reach along its pointing direction. [] for a bad
## pose.
func strike_lines(i: int) -> Array:
	var c := rig._ctrl(i)
	if not c.is_inside_tree():
		return []
	var a := c.global_position
	var fwd := -c.global_basis.z
	if not a.is_finite() or not fwd.is_finite() or fwd.length_squared() < 1e-8:
		return []
	var out := []
	var proxy: Node3D = rig.hands.proxy(VrRig.HAND_IDS[i]) if rig.hands != null else null
	if proxy != null and proxy.is_inside_tree():
		var tip: Variant = tip_of(proxy, a)
		if tip is Vector3 and a.distance_to(tip) >= MIN_TIP_M:
			out.append([a, a + ((tip as Vector3) - a).limit_length(MAX_TIP_M)])
			var other: Variant = tip_of(proxy, tip)
			if other is Vector3 and a.distance_to(other) >= MIN_TIP_M:
				out.append([a, a + ((other as Vector3) - a).limit_length(MAX_TIP_M)])
	if out.is_empty():
		out.append([a, a + fwd.normalized() * FIST_M])
	return out


## The point of `node`'s meshes (their boxes' corners; MAX_NODES nodes at most) farthest from `from`, in the world;
## null when it has none or a bad pose. A copy's live look (ItemLookView.DRESS) isn't counted.
static func tip_of(node: Node3D, from: Vector3) -> Variant:
	var best: Variant = null
	var best_d := -1.0
	var todo: Array[Node] = [node]
	var seen := 0
	while not todo.is_empty() and seen < MAX_NODES:
		var n: Node = todo.pop_back()
		seen += 1
		if n.name == ItemLookView.DRESS:
			continue   # a copy's live look (ItemLookView.dress): its shells sit 2 mm out over the copy's own meshes
		todo.append_array(n.get_children())
		var m := n as MeshInstance3D
		if m == null or m.mesh == null or not m.is_inside_tree():
			continue
		var box := m.get_aabb()
		var xf := m.global_transform
		for k in 8:
			var p := xf * box.get_endpoint(k)
			if not p.is_finite():
				return null
			var dist := p.distance_squared_to(from)
			if dist > best_d:
				best_d = dist
				best = p
	return best


## CDDA confirmed a hit on creature `uid` (HitFeedback.strike_confirmed): when that is the creature the last strike
## went for, within HIT_KEEP_MS, the striking hand buzzes (longer for a kill). True if it was that strike's.
func on_hit(uid: int, killed: bool) -> bool:
	if not _is_last(uid):
		return false
	var i: int = _last["hand"]
	_last = {}
	hits += 1
	if rig != null:
		rig.feel(rig._ctrl(i), 1.0, 0.25 if killed else 0.15)
	return true


func _on_strike_confirmed(uid: int, _part: String, _amount: int, killed: bool) -> void:
	on_hit(uid, killed)


## CDDA says the player's strike at `uid` is over (HitFeedback.swing_resolved): a miss on the creature the last
## strike went for, within HIT_KEEP_MS, buzzes the striking hand faintly and ends that strike (a hit waits for its
## damage, on_hit). True if it was that strike's miss.
func on_resolved(uid: int, hit: bool) -> bool:
	if hit or not _is_last(uid):
		return false
	var i: int = _last["hand"]
	_last = {}
	misses += 1
	if rig != null:
		rig.feel(rig._ctrl(i), MISS_AMP, MISS_S)
	return true


## CDDA used `technique` for the last strike, at `uid` (HitFeedback.technique_used, before the hit's damage): its
## name shows by the hand that struck (plain text, LABEL_LEN characters at most). True if it showed.
func on_technique(uid: int, technique: String) -> bool:
	var text := Snapshot.plain_text(technique, LABEL_LEN)
	if text.is_empty() or not _is_last(uid) or rig == null:
		return false
	var c := rig._ctrl(_last["hand"])
	if label == null or not is_instance_valid(label):
		label = Label3D.new()
		label.name = "Technique"
		label.pixel_size = 0.0003
		label.font_size = 32
		label.outline_size = 8
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.render_priority = 5
		label.position = Vector3(0, LABEL_UP, 0.04)
	if label.get_parent() != c:
		if label.get_parent() != null:
			label.get_parent().remove_child(label)
		c.add_child(label)
	label.text = text
	label.modulate = Color(1.0, 0.9, 0.55)
	label.visible = true
	_label_left = LABEL_S + LABEL_FADE_S
	return true


## The last strike went for `uid`, within HIT_KEEP_MS.
func _is_last(uid: int) -> bool:
	return not _last.is_empty() and uid == _last["uid"] and Time.get_ticks_msec() - int(_last["time"]) <= HIT_KEEP_MS


func _on_swing_resolved(uid: int, hit: bool) -> void:
	on_resolved(uid, hit)


func _on_technique_used(uid: int, technique: String, _family: int) -> void:
	on_technique(uid, technique)


## The technique's label counts down `d` seconds: full for LABEL_S, then fading, then hidden.
func _fade_label(d: float) -> void:
	if _label_left <= 0.0 or label == null or not is_instance_valid(label):
		return
	_label_left = maxf(_label_left - d, 0.0)
	label.modulate.a = clampf(_label_left / LABEL_FADE_S, 0.0, 1.0)
	label.outline_modulate.a = label.modulate.a
	label.visible = _label_left > 0.0


## The line from a to b, no creature on it: when it ends in a wall, window, door or furniture in a square next to
## the player (AimController.smash_at within the line's length), CDDA's smash goes out at that square for hand i.
## True when it did, or when the queue didn't take it (the hand is spent for this swing either way).
func _smash(i: int, a: Vector3, b: Vector3, snap: Snapshot) -> bool:
	var am := aim if aim != null else rig.gun.aim
	var q := queue_action if queue_action.is_valid() else rig.gun.queue_action
	if am == null or not q.is_valid():
		return false
	var sq: Variant = am.smash_at(a, b - a, snap.player_pos, false, a.distance_to(b))
	if not sq is Vector3i:
		return false
	_armed[i] = false
	_cool[i] = GAP_S
	am.smash_square = sq
	var ok: Variant = q.call(AimController.SMASH_AT)
	if not (ok is bool and ok):
		am.smash_square = null   # nothing went out: no square left for a later smash
		return true
	smashes += 1
	rig.feel(rig._ctrl(i), 0.8, 0.1)
	return true


## The line from a to b: when it meets a figure standing 1 - 2 squares off the player along one of the 8 ways
## (AimController.strike_segment: it keeps the aim for the swing request and names the action), the strike for hand
## i goes out. True when it did, or when the queue didn't take it (the hand is spent for this swing either way);
## false when the line strikes nothing.
func _strike(i: int, a: Vector3, b: Vector3, snap: Snapshot) -> bool:
	var am := aim if aim != null else rig.gun.aim
	var q := queue_action if queue_action.is_valid() else rig.gun.queue_action
	if am == null or not q.is_valid():
		return false
	var hand := "main" if rig._ctrl(i) == rig.main_ctrl() else "off"
	var act := am.strike_segment(hand, a, b, snap.player_pos)
	if act.is_empty():
		return false
	var uid: Variant = am.melee_aim.get("uid")
	_armed[i] = false
	_cool[i] = GAP_S
	var ok: Variant = q.call(act)
	if not (ok is bool and ok):
		am.melee_aim = {}   # nothing went out: no swing request to answer
		return true
	strikes += 1
	_flight = FLIGHT_S
	_last = {"hand": i, "uid": int(uid) if uid is int else 0, "time": Time.get_ticks_msec()}
	if am.hits != null:
		if not am.hits.strike_confirmed.is_connected(_on_strike_confirmed):
			am.hits.strike_confirmed.connect(_on_strike_confirmed)
		if not am.hits.swing_resolved.is_connected(_on_swing_resolved):
			am.hits.swing_resolved.connect(_on_swing_resolved)
		if not am.hits.technique_used.is_connected(_on_technique_used):
			am.hits.technique_used.connect(_on_technique_used)
	rig.feel(rig._ctrl(i), 0.8, 0.1)
	struck.emit(hand, act.get_slice(AIM_MARK, 1), _last["uid"])
	return true
