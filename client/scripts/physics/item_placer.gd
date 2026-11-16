class_name ItemPlacer
extends Node
## Block E2 slices 3-4 (item physics): tells CDDA where a physics body came to rest. The client owns only the pose
## within a square; CDDA owns the square and every rule, so a body lying somewhere new is reported, never decided
## here. When ItemBodies says a body came to rest somewhere new (`settled`: a body a hand let go, or one that was
## pushed), then, once CDDA's own drop has landed and the body still lies still:
## - on the square CDDA has it on: the bridge op "spot" (where across the square, its yaw, whether it lies on its side);
## - on another square: the bridge op "place", one square at a time toward where it lies (CDDA moves an item one
##   square per turn), the last step with the spot; ItemBodies keeps the body where it is meanwhile (transit). CDDA
##   refuses a place onto open air or into a wall (falling is CDDA's, with its time and harm): a body that fell or
##   lies on another level than CDDA's square goes back where CDDA has it, with nothing sent.
## CDDA answers each op with an `item_result` event (the `tag` sent with it: done or refused with its reason,
## contracts/bridge_api.md). A refused or unanswered place puts the body back where CDDA has the item (snap back); a
## refused spot only means the pose isn't kept. Only `amount` decides; the reason is for showing (`refused`).
## CDDA runs item actions only while its clock runs: an op counts as unanswered only after RESULT_MS and
## RESULT_TURNS game turns (Snapshot.turn), so a pause, or a turn-based game waiting for the player, never times one
## out. A clock that goes back (another save was loaded) forgets everything waiting or in flight.
## Limits kept here so nothing is sent that the bridge would refuse: the item's square within FROM_SQUARES of the
## player on its level; one op every GAP_MS, one place per item per game turn (and PLACE_GAP_MS apart), MAX_FLIGHT
## in flight, MAX_WANT waiting; MAX_TRIES per item, then it is put back. Nothing is sent while a body moves.
## `backend` (main.gd: the live session) is duck-typed: place_item(uid, type, pos, to, spot, yaw, side, tag) and
## spot_item(uid, type, pos, spot, yaw, side, tag), both -> bool (taken). Without them nothing is sent and the
## bodies behave as before. Events are checked (kinds, numbers, capped text): the bridge's data is not trusted.
## Nothing is sent for an item a hand's one-item action (take, put, drop...) is under way on (`busy`).

## CDDA refused to move or pose item `uid` (its reason, cleaned and capped).
signal refused(uid: int, reason: String)

const MAX_WANT := 32          # bodies waiting to be reported
const MAX_FLIGHT := 16        # ops waiting for their result (the bridge takes 16 place / spot ops a turn)
const MAX_TOLD := 256         # poses remembered as told
const MAX_EVENTS := 4096      # events looked at per batch (the bridge queue's cap)
const MAX_REASON := 200       # characters kept of a refusal's reason
const MAX_TAG := 2147483647
const RESULT_MS := 5000       # an op without a result is given up after this ...
const RESULT_TURNS := 2       # ... once the game's clock has also run this many turns since it went out
const EXPECT_MS := 3000       # after a place was done, the snapshot shows the new square within this
const GAP_MS := 250           # between two ops (a few per second is plenty)
const PLACE_GAP_MS := 1100    # between two places of one item (CDDA takes one per turn; a turn is a second at 1x)
const MAX_TRIES := 3          # ops for one item that got no answer or weren't taken, then it is put back
const RETRY_MS := 1000        # an op the backend didn't take (the game is busy) is tried again after this
const SPOT_EPS := 0.03        # a spot this near the one told is the same
const YAW_EPS := 10           # degrees: a yaw this near the one told is the same
const FROM_SQUARES := 2       # CDDA takes ops for items this many squares from the player at most

var bodies: ItemBodies:
	set(b):
		if is_instance_valid(bodies) and bodies.settled.is_connected(_on_settled):
			bodies.settled.disconnect(_on_settled)
		bodies = b
		if b != null:
			b.settled.connect(_on_settled)
var backend: Object
## The player's square (-> Vector3i): where CDDA measures reach from.
var centre := Callable()
## Milliseconds (tests); invalid: the engine's clock.
var clock := Callable()
## uid -> the one-item action in flight on it, "" none (main.gd: ItemActions.pending).
var busy := Callable()
var spots := 0            # spot ops sent (tests)
var places := 0           # place ops sent
var refusals := 0         # ops CDDA refused
var put_backs := 0        # bodies put back where CDDA has the item
var _want := {}           # uid -> tries used: came to rest somewhere new, to be told
var _flight := {}         # tag -> {uid, op, to, pose, ms, turn}
var _by_uid := {}         # uid -> its tag in flight
var _expect := {}         # uid -> [square, ms]: a place was done, waiting for the snapshot to show it there
var _told := {}           # uid -> [square, spot, yaw, side]: the pose CDDA last took
var _placed_ms := {}      # uid -> when its last place went out ...
var _placed_turn := {}    # ... and the game turn it went out on
var _retry_ms := {}       # uid -> not before this (an op wasn't taken)
var _tag := 0
var _last_ms := -GAP_MS
var _seen_turn := 0       # the game turn at the last update


func _process(_delta: float) -> void:
	update()


## ItemBodies: a body came to rest somewhere new.
func _on_settled(uid: int, _square: Vector3i, _spot: Vector2) -> void:
	if uid <= 0 or (not _want.has(uid) and _want.size() >= MAX_WANT):
		return
	if not _want.has(uid):
		_want[uid] = 0


## Bodies waiting to be reported or with an op in flight (tests, vr_perf).
func waiting() -> int:
	return _want.size()


## Every frame: gives up ops without an answer, then sends at most one op.
func update() -> void:
	if not is_instance_valid(bodies):
		return
	var turn := _turn()
	if turn < _seen_turn:
		clear()   # the game's clock went back (another save loaded): nothing from before applies
	_seen_turn = turn
	var now := _now()
	_expire(now)
	if _want.is_empty() or now - _last_ms < GAP_MS or _flight.size() >= MAX_FLIGHT:
		return
	var c: Variant = centre.call() if centre.is_valid() else null
	if not c is Vector3i:
		return
	for uid: int in _want.keys():
		if _step(uid, c, now):
			_last_ms = now
			return


## The bridge's events: `item_result` for a tag in flight ends that op. Anything else, or anything odd, is skipped.
func on_events(events: Array) -> void:
	if _flight.is_empty():
		return
	for i in mini(events.size(), MAX_EVENTS):
		var ev: Variant = events[i]
		if not ev is Dictionary or (ev as Dictionary).get("kind") != "item_result":
			continue
		var tag := _int((ev as Dictionary).get("detail"))
		var f: Variant = _flight.get(tag)
		if tag <= 0 or not f is Dictionary or _int((ev as Dictionary).get("uid")) != (f as Dictionary)["uid"]:
			continue
		_flight.erase(tag)
		_by_uid.erase((f as Dictionary)["uid"])
		if _int((ev as Dictionary).get("amount")) == 1:
			_done(f)
		else:
			var t: Variant = (ev as Dictionary).get("text")
			_refused(f, HudData.clean(t, MAX_REASON) if t is String else "")


## Forgets everything (the game ended): no ops in flight, nothing waiting, bodies no longer held in transit.
func clear() -> void:
	if is_instance_valid(bodies):
		for uid: int in _want:
			bodies.transit(uid, false)
	_want.clear()
	_flight.clear()
	_by_uid.clear()
	_expect.clear()
	_told.clear()
	_placed_ms.clear()
	_placed_turn.clear()
	_retry_ms.clear()


## One body's next op. True when one went out.
func _step(uid: int, c: Vector3i, now: int) -> bool:
	if bodies.body_of(uid) == null:
		_drop(uid)
		return false
	if _by_uid.has(uid) or bodies.is_pending(uid) or now < int(_retry_ms.get(uid, 0)) or _busy(uid):
		return false   # its op is in flight, CDDA's own drop or a hand's action on it hasn't landed, or the game was busy
	if not bodies.at_rest(uid):
		_drop(uid)   # moving again: it reports when it rests
		return false
	var rest := bodies.rest_of(uid)
	var at: Variant = bodies.square_of(uid)
	var type := bodies.type_of(uid)
	if rest.is_empty() or not at is Vector3i or type <= 0:
		_drop(uid)
		return false
	var cdda: Vector3i = at
	var sq: Vector3i = rest["square"]
	if _expect.has(uid):   # a place was done: wait for the snapshot that shows it
		var e: Array = _expect[uid]
		if cdda != e[0] and now - int(e[1]) < EXPECT_MS:
			return false
		_expect.erase(uid)
	if cdda.z != c.z or maxi(absi(cdda.x - c.x), absi(cdda.y - c.y)) > FROM_SQUARES:
		if sq == cdda:
			_drop(uid)   # out of CDDA's reach: the pose isn't kept
		else:
			_put_back(uid)
		return false
	if sq == cdda:
		if _same(uid, rest):
			_drop(uid)
			return false
		return _send(uid, "spot", [float(uid), float(type), cdda, rest["spot"], rest["yaw"], rest["side"]], cdda, rest, now)
	var to := Vector3i(cdda.x + clampi(sq.x - cdda.x, -1, 1), cdda.y + clampi(sq.y - cdda.y, -1, 1), cdda.z)
	if sq.z != cdda.z:   # it fell to (or lies on) another level: CDDA never moves an item down or up for free
		_put_back(uid)
		return false
	if now - int(_placed_ms.get(uid, -PLACE_GAP_MS)) < PLACE_GAP_MS or _turn() <= int(_placed_turn.get(uid, -1)):
		return false   # CDDA moves an item once a turn
	if not bodies.transit(uid, true):
		_put_back(uid)
		return false
	var last := to == sq   # the last step carries the pose; a step on the way has none
	var spot: Vector2 = rest["spot"] if last else Vector2(-1, -1)
	var args := [float(uid), float(type), cdda, to, spot, rest["yaw"] if last else 0, rest["side"] if last else false]
	if not _send(uid, "place", args, to, rest if last else {}, now):
		return false
	_placed_ms[uid] = now
	_placed_turn[uid] = _turn()
	return true


## Sends one op with a new tag. False when the backend can't or won't take it (a try used; too many: put back).
func _send(uid: int, op: String, args: Array, to: Vector3i, pose: Dictionary, now: int) -> bool:
	var method := StringName(op + "_item")
	if backend == null or not is_instance_valid(backend) or not backend.has_method(method):
		_drop(uid)   # no such op (the mock, an older bridge): nothing is told, the body stays as it lies
		return false
	_tag = _tag % MAX_TAG + 1
	var ok: Variant = backend.callv(method, args + [_tag])
	if not (ok is bool and ok):
		_retry_ms[uid] = now + RETRY_MS
		_tried(uid)
		return false
	_flight[_tag] = {"uid": uid, "op": op, "to": to, "pose": pose, "ms": now, "turn": _turn()}
	_by_uid[uid] = _tag
	if op == "spot":
		spots += 1
	else:
		places += 1
	return true


## CDDA did the op: a spot (or a place's last step) is remembered as told; a place waits for the snapshot.
func _done(f: Dictionary) -> void:
	var uid: int = f["uid"]
	var pose: Dictionary = f["pose"]
	if not _want.has(uid):
		return   # dropped while its op was in flight (its body went): nothing more to do for it
	_want[uid] = 0
	if not pose.is_empty():
		if _told.size() >= MAX_TOLD and not _told.has(uid):
			_told.clear()
		_told[uid] = [f["to"], pose["spot"], pose["yaw"], pose["side"]]
	if f["op"] == "spot":
		_drop(uid)
	else:
		_expect[uid] = [f["to"], _now()]


## CDDA refused the op: a place puts the body back where CDDA has the item; a spot just isn't kept.
func _refused(f: Dictionary, reason: String) -> void:
	var uid: int = f["uid"]
	refusals += 1
	if f["op"] == "place":
		_put_back(uid)
	else:
		_drop(uid)
	refused.emit(uid, reason)


## Ops in flight longer than RESULT_MS, with the game's clock RESULT_TURNS on, got no answer: a try used.
func _expire(now: int) -> void:
	var turn := _turn()
	for tag: int in _flight.keys():
		var f: Dictionary = _flight[tag]
		if now - int(f["ms"]) >= RESULT_MS and turn - int(f["turn"]) >= RESULT_TURNS:
			_flight.erase(tag)
			_by_uid.erase(f["uid"])
			_tried(f["uid"])


## One more try used for `uid`; past MAX_TRIES it is put back where CDDA has it (a spot: just forgotten).
func _tried(uid: int) -> void:
	if not _want.has(uid):
		return
	_want[uid] = int(_want[uid]) + 1
	if int(_want[uid]) < MAX_TRIES:
		return
	var rest := bodies.rest_of(uid)
	if not rest.is_empty() and rest["square"] == bodies.square_of(uid):
		_drop(uid)
	else:
		_put_back(uid)


## The body's pose is what CDDA was last told (or the spot its handle stores, when nothing was told yet).
func _same(uid: int, rest: Dictionary) -> bool:
	var spot: Vector2 = rest["spot"]
	var t: Variant = _told.get(uid)
	if t is Array:
		var d := absi(wrapi(int(rest["yaw"]) - int(t[2]) + 180, 0, 360) - 180)
		return t[0] == rest["square"] and spot.distance_to(t[1]) < SPOT_EPS and d <= YAW_EPS and t[3] == rest["side"]
	return false


## Nothing more to tell for `uid`.
func _drop(uid: int) -> void:
	_want.erase(uid)
	_expect.erase(uid)
	_placed_ms.erase(uid)
	_placed_turn.erase(uid)
	_retry_ms.erase(uid)
	if is_instance_valid(bodies):
		bodies.transit(uid, false)


## The body goes back where CDDA has the item.
func _put_back(uid: int) -> void:
	_drop(uid)
	_told.erase(uid)
	if is_instance_valid(bodies) and bodies.put_back(uid):
		put_backs += 1


static func _int(v: Variant) -> int:
	if v is int:
		return v
	if v is float and is_finite(v) and absf(v) <= float(MAX_TAG):
		return int(v)
	return 0


## A hand's one-item action on `uid` is in flight.
func _busy(uid: int) -> bool:
	var p: Variant = busy.call(uid) if busy.is_valid() else ""
	return p is String and not (p as String).is_empty()


## The game turn the world's snapshot shows (0 without one).
func _turn() -> int:
	var snap := bodies.world.snapshot if is_instance_valid(bodies) and bodies.world != null else null
	return snap.turn if snap != null else 0


func _now() -> int:
	var t: Variant = clock.call() if clock.is_valid() else null
	return int(t) if t is int or t is float else Time.get_ticks_msec()
