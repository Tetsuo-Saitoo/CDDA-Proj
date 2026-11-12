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
## One strike per swing: the hand must slow under REARM_SPEED before it strikes again, at least GAP_S apart, and no
## hand strikes while a strike is in flight (until a newer snapshot, FLIGHT_S at most). No strikes while a menu or
## prompt is up, without a game, or from a hand that isn't tracked, holds a door or the open pack, or is the gun
## hand with a finger on the trigger. A buzz when a strike goes out, a stronger one when CDDA says it hit
## (HitFeedback.strike_confirmed for the creature struck, within HIT_KEEP_MS). Nothing here talks to the sim but
## that one action.

## A strike went out: CDDA's hand ("main" / "off"), the way (a direction name such as "LEFT"), the creature touched.
signal struck(hand: String, dir: String, uid: int)

const SWING_SPEED := 2.5   # m/s: a hand this fast swings ...
const REARM_SPEED := 1.0   # ... and strikes again only after slowing under this
const GAP_S := 0.4         # seconds between a hand's strikes at least
const FLIGHT_S := 1.5      # a strike sent blocks the next this long, or until a newer snapshot
const FIST_M := 0.15       # an empty hand strikes this far along its pointing direction
const MIN_TIP_M := 0.2     # a held item reaching less than this from the hand strikes like a fist
const MAX_TIP_M := 2.5     # no striking line is longer (a long spear)
const MAX_NODES := 64      # nodes of a held copy looked at for its tip
const HIT_KEEP_MS := 3000  # a hit confirmed this long after a strike is that strike's
const NEAR_M := 0.75       # (without AimController's segment pick) a figure this far past the line still counts
const ACTION := "fp3d_attack_%s_aim_%s"
const AIM_MARK := "_aim_"

var rig: VrRig
## The aim controller that picks the figure and answers the swing request; null: the gun's (main.gd sets that).
var aim: AimController
## Queues a main-loop action (-> bool: taken); invalid: the gun's.
var queue_action := Callable()
var strikes := 0           # strikes sent (tests)
var hits := 0              # strikes CDDA confirmed as hits (tests)
var _armed: Array[bool] = [true, true]
var _cool: Array[float] = [0.0, 0.0]
var _flight := 0.0         # > 0: a strike went out, seconds left before the next may
var _flight_seq := -1      # the snapshot seq it went out on
var _last := {}            # the last strike sent: {hand (0 left / 1 right), uid, time msec}


## Every frame from the rig, after track_hands: looks for a swing meeting a figure and sends its strike.
func update(delta: float) -> void:
	if rig == null or rig.world == null:
		return
	var d := clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	var snap := rig.world.snapshot
	if _flight > 0.0:
		_flight = maxf(_flight - d, 0.0)
		if snap != null and snap.seq != _flight_seq:
			_flight = 0.0
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
		for line: Array in strike_lines(i):
			if _strike(i, line[0], line[1], snap):
				break


## Hand i may strike: tracked, not holding a door or the open pack, not the gun hand with a finger on the trigger.
func can_swing(i: int) -> bool:
	if not rig.tracked(i) or rig.pack.hand == i or (rig._gun_hand(i) and rig.trigger_half(i)):
		return false
	if rig.hands == null:
		return true
	var held := rig.hands.holding(VrRig.HAND_IDS[i])
	return held.is_empty() or held.get("kind") == "item"


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
## null when it has none or a bad pose.
static func tip_of(node: Node3D, from: Vector3) -> Variant:
	var best: Variant = null
	var best_d := -1.0
	var todo: Array[Node] = [node]
	var seen := 0
	while not todo.is_empty() and seen < MAX_NODES:
		var n: Node = todo.pop_back()
		seen += 1
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
	if _last.is_empty() or uid != _last["uid"] or Time.get_ticks_msec() - int(_last["time"]) > HIT_KEEP_MS:
		return false
	var i: int = _last["hand"]
	_last = {}
	hits += 1
	if rig != null:
		rig.feel(rig._ctrl(i), 1.0, 0.25 if killed else 0.15)
	return true


func _on_strike_confirmed(uid: int, _part: String, _amount: int, killed: bool) -> void:
	on_hit(uid, killed)


## The line from a to b: when it meets a figure standing along one of the 8 ways, the strike for hand i goes out.
## True when the line met a figure (the hand is spent for this swing, sent or not).
func _strike(i: int, a: Vector3, b: Vector3, snap: Snapshot) -> bool:
	var am := aim if aim != null else rig.gun.aim
	var q := queue_action if queue_action.is_valid() else rig.gun.queue_action
	if am == null or not q.is_valid():
		return false
	var hand := "main" if rig._ctrl(i) == rig.main_ctrl() else "off"
	var act := _action(am, hand, a, b, snap.player_pos)
	if act.is_empty():
		return not am.melee_aim.is_empty() and _spend(i, am)   # met a figure off the 8 ways
	var uid: Variant = am.melee_aim.get("uid")
	_spend(i, null)
	var ok: Variant = q.call(act)
	if not (ok is bool and ok):
		am.melee_aim = {}   # nothing went out: no swing request to answer
		return true
	strikes += 1
	_flight = FLIGHT_S
	_flight_seq = snap.seq
	_last = {"hand": i, "uid": int(uid) if uid is int else 0, "time": Time.get_ticks_msec()}
	if am.hits != null and am.hits.has_signal(&"strike_confirmed") \
			and not am.hits.is_connected(&"strike_confirmed", _on_strike_confirmed):
		am.hits.connect(&"strike_confirmed", _on_strike_confirmed)
	rig.feel(rig._ctrl(i), 0.8, 0.1)
	struck.emit(hand, act.get_slice(AIM_MARK, 1), _last["uid"])
	return true


## Hand i struck (or met a figure it can't strike): no more from this swing. Clears `am`'s kept aim when given.
func _spend(i: int, am: AimController) -> bool:
	_armed[i] = false
	_cool[i] = GAP_S
	if am != null:
		am.melee_aim = {}
	return true


## The action to queue for a strike of `hand` along a -> b from the player's square `me`, "" when the line meets no
## figure or the figure isn't 1 - 2 squares off along the 8 ways. AimController keeps the aim (melee_aim) for the
## swing request; left non-empty with "" only by the stand-in paths, for a figure off the 8 ways.
func _action(am: AimController, hand: String, a: Vector3, b: Vector3, me: Vector3i) -> String:
	if am.has_method(&"strike_segment"):
		var r: Variant = am.call(&"strike_segment", hand, a, b, me)
		return r if r is String else ""
	# Until AimController.strike_segment is on main: its own pick, then the way.
	var hit := {}
	if am.has_method(&"melee_segment"):
		var r: Variant = am.call(&"melee_segment", a, b)
		hit = r if r is Dictionary else {}
	else:   # the ray pick looks MELEE_REACH_M far: kept only when the figure's square is within the line's length
		hit = am.melee_from(a, b - a)
		var at: Variant = hit.get("square")
		if at is Vector3i:
			var mid := rig.world.coords.ms_center_to_world(at)
			if Vector2(mid.x - a.x, mid.z - a.z).length() > a.distance_to(b) + NEAR_M:
				am.melee_aim = {}
				hit = {}
	var sq: Variant = hit.get("square")
	var dir := AimController.strike_dir(me, sq) if sq is Vector3i else ""
	return ACTION % [hand, dir] if dir != "" else ""
