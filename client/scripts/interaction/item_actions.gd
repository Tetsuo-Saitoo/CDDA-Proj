class_name ItemActions
extends Node
## Blocks E6 / L2 / L8: the one-item actions (take, put, drop) shared by the flat-screen hands and the VR hands,
## with no UI. Each goes out through a backend (LiveSession live, MockItems in mock mode) and is followed until a
## snapshot shows the item moved (finished) or still where it was (refused, with CDDA's message). The sim decides
## everything (contracts/bridge_api.md "Single items"): this only reads what later snapshots and message events
## say. While a take is in flight the world hides the item (hidden_changed), so a hand can show it held.
##
## Wiring: LiveSession.snapshot_ready -> on_snapshot, LiveSession.events_arrived -> on_events (mock mode:
## MockItems.changed -> on_snapshot, MockItems.message -> on_events([MockItems.message_event(text)])).

## Uids (-> true) of items in flight that lie in the world (not carried): the world hides them meanwhile.
signal hidden_changed(uids: Dictionary)
## The set of pending actions changed (sent, judged, cleared).
signal changed()
signal finished(item: ItemRef, op: String)
signal refused(item: ItemRef, op: String, reason: String)

const TIMEOUT_MS := 5000
const MAX_PENDING := 32
const MAX_TEXT := 200
const MAX_MESSAGES := 8
const MAX_EVENTS := 4096           # the bridge's event queue
const M_INFO := 4                  # CDDA's game_message_type m_info: every refusal of the bridge's item actions
const HANDS := ["pack", "main", "off"]
const SPOT_MAX := 0.999
const DIDNT_WORK := "That didn't work."
const NO_ANSWER := "No answer from the game."

enum Where { STILL, MOVED, UNKNOWN }

## Anything with take_item / put_item / drop_item (-> bool) and queued_actions() (-> int): a LiveSession or a
## MockItems.
var backend: Object
## Returns the time in msec; Time.get_ticks_msec() when not set (tests set it).
var clock := Callable()

## uid -> {op, item (ItemRef copy), target, spot, sent_ms, seq, messages, info, looks}
var _pending := {}
var _seq := 0   # seq of the newest snapshot seen


## Takes `item` (lying on its square) into hand "pack", "main" or "off". False when refused here (nothing sent).
func take(item: ItemRef, hand := "pack") -> bool:
	if not _ok_ref(item) or item.carried or not (hand in HANDS) or not ok_square(item.square):
		return false
	return _send("take", item, hand, Vector2(-1, -1), "take_item",
			[float(item.uid), float(item.type), item.square, hand])


## Puts a carried `item` into `container` (carried, or lying in reach); `pocket` -1 = CDDA's pick.
func put(item: ItemRef, container: ItemRef, pocket := -1) -> bool:
	if not _ok_ref(item) or not item.carried or not _ok_ref(container) or container.uid == item.uid \
			or pocket < -1 or pocket > Snapshot.MAX_POCKET or not ok_square(container.square):
		return false
	return _send("put", item, container.duplicate_ref(), Vector2(-1, -1), "put_item",
			[float(item.uid), float(item.type), float(container.uid), float(container.type), container.square, pocket])


## Drops a carried `item` on `square`; `spot` (each 0..1 across the square, x east, y south) places it there,
## (-1, -1) none.
func drop(item: ItemRef, square: Vector3i, spot := Vector2(-1, -1)) -> bool:
	if not _ok_ref(item) or not item.carried or not ok_square(square) or is_nan(spot.x) or is_nan(spot.y):
		return false
	if spot.x >= 0.0 and spot.y >= 0.0:
		spot = Vector2(clampf(spot.x, 0.0, SPOT_MAX), clampf(spot.y, 0.0, SPOT_MAX))
	else:
		spot = Vector2(-1, -1)
	return _send("drop", item, square, spot, "drop_item", [float(item.uid), float(item.type), square, spot])


## The op in flight for `uid` ("take", "put", "drop"), "" when none.
func pending(uid: int) -> String:
	return (_pending[uid] as Dictionary)["op"] if _pending.has(uid) else ""


func pending_count() -> int:
	return _pending.size()


## Messages kept for the action on `uid` (newest last).
func messages(uid: int) -> PackedStringArray:
	return PackedStringArray((_pending[uid] as Dictionary)["messages"]) if _pending.has(uid) else PackedStringArray()


## Uids (-> true) of pending items that lie in the world.
func hidden() -> Dictionary:
	var out := {}
	for uid: int in _pending:
		if not ((_pending[uid] as Dictionary)["item"] as ItemRef).carried:
			out[uid] = true
	return out


## Forgets everything in flight (the game ended or was left). No finished/refused signals.
func clear() -> void:
	_pending.clear()
	_seq = 0
	hidden_changed.emit({})
	changed.emit()


## A new snapshot: judges what it can. An action is judged on the first snapshot newer than the one seen when it
## was sent, while the bridge's queue is empty: moved = finished; still there = refused when CDDA said why (an
## m_info message), otherwise on the next such snapshot (the first may have been taken before the action ran:
## LiveSession parses snapshots on a worker, so one can be in flight when the action goes out).
func on_snapshot(snap: Snapshot) -> void:
	if snap == null or not snap.is_valid():
		return
	_seq = snap.seq
	if _pending.is_empty() or _queued() > 0:
		return
	var done: Array = []   # [entry, reason ("" = finished)]
	for uid: int in _pending:
		var e: Dictionary = _pending[uid]
		if snap.seq <= e["seq"]:
			continue
		match _where(e, snap):
			Where.MOVED:
				done.append([e, ""])
			Where.STILL:
				e["looks"] += 1
				e["seq"] = snap.seq   # a second look needs a newer snapshot
				if not (e["info"] as String).is_empty() or e["looks"] >= 2:
					done.append([e, _reason(e)])
	_resolve(done)


## Message events (contracts/events.md) arriving while something is in flight are kept as possible reasons.
func on_events(events: Array) -> void:
	if _pending.is_empty():
		return
	for i in mini(events.size(), MAX_EVENTS):
		var ev: Variant = events[i]
		if not ev is Dictionary or (ev as Dictionary).get("kind") != "message":
			continue
		var t: Variant = (ev as Dictionary).get("text")
		if not t is String:
			continue
		var text := _clean(t)
		if text.is_empty():
			continue
		var ty: Variant = (ev as Dictionary).get("type")
		var info: bool = (ty is int and ty == M_INFO) or (ty is float and ty == float(M_INFO))
		for uid: int in _pending:
			var e: Dictionary = _pending[uid]
			var kept: Array = e["messages"]
			kept.append(text)
			if kept.size() > MAX_MESSAGES:
				kept.pop_front()
			if info:
				e["info"] = text


## Refuses what got no judgement within TIMEOUT_MS. Called each frame.
func check_timeouts() -> void:
	if _pending.is_empty():
		return
	var now := _now()
	var done: Array = []
	for uid: int in _pending:
		var e: Dictionary = _pending[uid]
		if now - int(e["sent_ms"]) >= TIMEOUT_MS:
			var said: bool = e["looks"] > 0 or not (e["info"] as String).is_empty()
			done.append([e, _reason(e) if said else NO_ANSWER])
	_resolve(done)


func _process(_delta: float) -> void:
	check_timeouts()


## Row of the carried item uid + type in snap.carried, -1 if it isn't carried.
static func carried_row(snap: Snapshot, uid: int, type: int) -> int:
	var c := snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i] == uid and c[i + 1] == type:
			return i / Snapshot.CARRIED_STRIDE
	return -1


## Row of handle uid + type on `tile` in the submap's handles, -1 if none.
static func handle_index(sm: Snapshot.Submap, tile: int, uid: int, type: int) -> int:
	if sm == null:
		return -1
	var h := sm.handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == tile and h[i + 1] == uid and h[i + 2] == type:
			return i / Snapshot.HANDLE_STRIDE
	return -1


## Index of square p within its submap (y * 12 + x).
static func tile_of(p: Vector3i) -> int:
	var l := CddaCoords.ms_to_local(p)
	return l.y * CddaCoords.SEEX + l.x


func _send(op: String, item: ItemRef, target: Variant, spot: Vector2, method: String, args: Array) -> bool:
	if backend == null or not is_instance_valid(backend) or not backend.has_method(method) \
			or _pending.size() >= MAX_PENDING:
		return false
	var e := {"op": op, "item": item.duplicate_ref(), "target": target, "spot": spot, "sent_ms": _now(),
			"seq": _seq, "messages": [], "info": "", "looks": 0}
	# Recorded before the call: a backend that answers inside the call (MockItems) has it judged right there.
	_pending[item.uid] = e
	var ok: Variant = backend.callv(method, args)
	if not (ok is bool and ok):
		if is_same(_pending.get(item.uid), e):
			_pending.erase(item.uid)
		return false
	if is_same(_pending.get(item.uid), e):
		hidden_changed.emit(hidden())
		changed.emit()
	return true


func _resolve(done: Array) -> void:
	if done.is_empty():
		return
	for d: Array in done:
		_pending.erase(((d[0] as Dictionary)["item"] as ItemRef).uid)
	for d: Array in done:
		var e: Dictionary = d[0]
		var reason: String = d[1]
		if reason.is_empty():
			finished.emit(e["item"], e["op"])
		else:
			refused.emit(e["item"], e["op"], reason)
	hidden_changed.emit(hidden())
	changed.emit()


## Where the item is in `snap` compared with where it was when the action went out.
func _where(e: Dictionary, snap: Snapshot) -> Where:
	var item: ItemRef = e["item"]
	var row := carried_row(snap, item.uid, item.type)
	match e["op"]:
		"take":
			return Where.MOVED if row >= 0 else _on_square(snap, item)
		"drop":
			return Where.STILL if row >= 0 else Where.MOVED
		"put":
			# Gone from carried counts too: into a container on the ground, or merged into a stack (new uid).
			if row < 0:
				return Where.MOVED
			var i := row * Snapshot.CARRIED_STRIDE
			var same: bool = snap.carried[i + 2] == item.parent and snap.carried[i + 3] == item.pocket
			return Where.STILL if same else Where.MOVED
	return Where.UNKNOWN


## STILL when its handle is still on its square, MOVED when not, UNKNOWN when the square isn't seen (no handles).
func _on_square(snap: Snapshot, item: ItemRef) -> Where:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(item.square))
	var tile := tile_of(item.square)
	if sm == null or tile >= sm.vis.size() or sm.vis[tile] != 2:
		return Where.UNKNOWN
	return Where.STILL if handle_index(sm, tile, item.uid, item.type) >= 0 else Where.MOVED


func _reason(e: Dictionary) -> String:
	var info: String = e["info"]
	return info if not info.is_empty() else DIDNT_WORK


func _ok_ref(r: ItemRef) -> bool:
	return r != null and r.uid > 0 and r.uid < Snapshot.MAX_UID and r.type > 0 and r.type <= Snapshot.MAX_ID \
			and not _pending.has(r.uid)


## A square inside the range snapshots allow.
static func ok_square(p: Vector3i) -> bool:
	var lim := Snapshot.MAX_ABS_SM * CddaCoords.SEEX
	return absi(p.x) <= lim and absi(p.y) <= lim and p.z >= CddaCoords.Z_MIN and p.z <= CddaCoords.Z_MAX


func _queued() -> int:
	if backend == null or not is_instance_valid(backend) or not backend.has_method("queued_actions"):
		return 0
	var q: Variant = backend.call("queued_actions")
	return q if q is int else 0


func _now() -> int:
	if clock.is_valid():
		var t: Variant = clock.call()
		if t is int:
			return t
		if t is float and is_finite(t):
			return int(t)
	return Time.get_ticks_msec()


## Capped, one line, no control characters.
static func _clean(s: String) -> String:
	var out := ""
	for c in s.left(MAX_TEXT):
		out += " " if c.unicode_at(0) < 32 else c
	return out.strip_edges()
