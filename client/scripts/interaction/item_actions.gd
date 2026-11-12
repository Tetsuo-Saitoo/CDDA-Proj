class_name ItemActions
extends Node
## Blocks E6 / L2 / L8: the one-item actions (take, put, drop, unload, reload, clear a jam, throw, pour, hold) shared by the flat-screen hands and the VR hands,
## with no UI. Each goes out through a backend (LiveSession live, MockItems in mock mode) and is followed until a
## snapshot shows the item moved (finished) or still where it was (refused, with CDDA's message). The sim decides
## everything (contracts/bridge_api.md "Single items"): this only reads what later snapshots and message events
## say. While a take is in flight the world hides the item (hidden_changed), so a hand can show it held.
## Unload and reload change what is inside an item, which the snapshot shows only for carried items and not as
## round counts: they finish when the carried rows around the item change, are refused on CDDA's message, and
## otherwise (rounds topped up in place, an unload into the pack still running as an activity) finish at the
## timeout once the sim has had them for two snapshots without a refusal.
##
## Wiring: LiveSession.snapshot_ready -> on_snapshot, LiveSession.events_arrived -> on_events (mock mode:
## MockItems.changed -> on_snapshot, MockItems.message -> on_events([MockItems.message_event(text)])).

## Uids (-> true) of items in flight that lie in the world (not carried): the world hides them meanwhile.
signal hidden_changed(uids: Dictionary)
## The set of pending actions changed (sent, judged, cleared).
signal changed()
signal finished(item: ItemRef, op: String)
signal refused(item: ItemRef, op: String, reason: String)
## clear() forgot everything in flight (no finished / refused for any of it).
signal cleared()

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
## Ops judged by the carried rows around the item (see above).
const CONTENT_OPS := ["unload", "reload", "pour"]
## Ops whose result the snapshot may not show (rounds topped up, one unit of a stack thrown, a partial pour, a jam
## still being cleared): no message after two looks is no refusal.
const QUIET_OK := ["unload", "reload", "throw", "pour", "clear"]

enum Where { STILL, MOVED, UNKNOWN }

## Anything with take_item / put_item / drop_item / unload_item / reload_item / clear_item / throw_item / pour_item /
## pour_into / hold_item (-> bool; a missing one refuses that op here) and queued_actions()
## (-> int): a LiveSession or a MockItems.
var backend: Object
## Returns the time in msec; Time.get_ticks_msec() when not set (tests set it).
var clock := Callable()

## uid -> {op, item (ItemRef copy), target, spot, sent_ms, seq, messages, info, looks, before}
var _pending := {}
var _seq := 0   # seq of the newest snapshot seen
var _snap: Snapshot   # the newest snapshot seen (unload / reload compare against it)


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


## Unloads `item` (carried, or lying in reach on its square): a gun gives its magazine whole, a magazine its
## rounds, to hand "pack", "main" or "off"; a loaded gunmod comes after the item itself, one per call.
func unload(item: ItemRef, hand := "pack") -> bool:
	if not _ok_ref(item) or not (hand in HANDS) or not ok_square(item.square):
		return false
	return _send("unload", item, hand, Vector2(-1, -1), "unload_item",
			[float(item.uid), float(item.type), item.square, hand])


## Reloads a carried `item` (gun or magazine) with `ammo` (a magazine or rounds, carried or lying in reach), as
## much as fits, into the first part CDDA's reload menu would offer (the item, the magazine in it, gunmods).
func reload(item: ItemRef, ammo: ItemRef) -> bool:
	if not _ok_ref(item) or not item.carried or not _ok_ref(ammo) or ammo.uid == item.uid \
			or not ok_square(ammo.square):
		return false
	return _send("reload", item, ammo.duplicate_ref(), Vector2(-1, -1), "reload_item",
			[float(item.uid), float(item.type), float(ammo.uid), float(ammo.type), ammo.square])


## Clears the jam of the wielded gun `item` (bridge op "clear": CDDA's mend of its gun_mechanical_simple fault,
## ~10 s a jam). Finished when the snapshot's wielded_gun faults change; the game refuses with a message when it
## isn't wielded, isn't jammed or can't be fixed. (Not `clear()`: that forgets everything in flight.)
func clear_jam(item: ItemRef) -> bool:
	if not _ok_ref(item) or not item.carried or not item.is_wielded():
		return false
	return _send("clear", item, null, Vector2(-1, -1), "clear_item", [float(item.uid), float(item.type)])


## The wielded gun's faults (Snapshot.player_gun) when `item` is what the player wields, else null.
static func gun_faults(snap: Snapshot, item: ItemRef) -> Variant:
	if snap == null or item == null:
		return null
	var row := carried_row(snap, item.uid, item.type)
	if row < 0 or (snap.carried[row * Snapshot.CARRIED_STRIDE + 4] & Snapshot.CARRIED_WIELDED) == 0 			or snap.player_gun.get("type") != item.type:
		return null
	return (snap.player_gun.get("faults", []) as Array).duplicate()


## Throws a carried, unworn `item` at `square` (one you see, on your level, in throw range, not your own): CDDA's
## throw, one unit of a stack.
func throw(item: ItemRef, square: Vector3i) -> bool:
	if not _ok_ref(item) or not item.carried or item.flags & Snapshot.CARRIED_WORN or not ok_square(square):
		return false
	if _snap != null and square == _snap.player_pos:
		return false
	return _send("throw", item, square, Vector2(-1, -1), "throw_item", [float(item.uid), float(item.type), square])


## Moves a carried, unworn `item` into hand "main" (CDDA's wield) or "off" (held in the off hand): the hand change
## of Hands.hand_over. Backend method hold_item(uid, type, hand) (MockItems has it; the bridge has no such op yet, so
## a live backend without it refuses here and nothing is sent).
func hold(item: ItemRef, hand: String) -> bool:
	if not _ok_ref(item) or not item.carried or item.flags & Snapshot.CARRIED_WORN or not (hand in ["main", "off"]):
		return false
	return _send("hold", item, hand, Vector2(-1, -1), "hold_item", [float(item.uid), float(item.type), hand])


## Pours the liquid out of a carried `item` (a container, or the liquid in one) onto `square`: yours or one next
## to it, all of it.
func pour(item: ItemRef, square: Vector3i) -> bool:
	if not _ok_ref(item) or not item.carried or not ok_square(square):
		return false
	if _snap != null:
		var d := square - _snap.player_pos
		if d.z != 0 or absi(d.x) > 1 or absi(d.y) > 1:
			return false
	return _send("pour", item, square, Vector2(-1, -1), "pour_item", [float(item.uid), float(item.type), square])


## Pours the liquid out of a carried `item` into `container` (carried, or on or next to your square), as much as
## fits; `pocket` -1 = CDDA's pick.
func pour_into(item: ItemRef, container: ItemRef, pocket := -1) -> bool:
	if not _ok_ref(item) or not item.carried or not _ok_ref(container) or container.uid == item.uid \
			or pocket < -1 or pocket > Snapshot.MAX_POCKET or not ok_square(container.square):
		return false
	return _send("pour", item, container.duplicate_ref(), Vector2(-1, -1), "pour_into",
			[float(item.uid), float(item.type), float(container.uid), float(container.type), pocket])


## The op in flight for `uid` ("take", "put", "drop", "unload", "reload", "clear", "throw", "pour"), "" when none.
func pending(uid: int) -> String:
	return (_pending[uid] as Dictionary)["op"] if _pending.has(uid) else ""


func pending_count() -> int:
	return _pending.size()


## Messages kept for the action on `uid` (newest last).
func messages(uid: int) -> PackedStringArray:
	return PackedStringArray((_pending[uid] as Dictionary)["messages"]) if _pending.has(uid) else PackedStringArray()


## Uids (-> true) of items being taken from the world (an unload off the floor leaves its item shown).
func hidden() -> Dictionary:
	var out := {}
	for uid: int in _pending:
		var e: Dictionary = _pending[uid]
		if e["op"] == "take" and not (e["item"] as ItemRef).carried:
			out[uid] = true
	return out


## Forgets everything in flight (the game ended or was left). No finished/refused signals.
func clear() -> void:
	_pending.clear()
	_seq = 0
	_snap = null
	cleared.emit()
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
	_snap = snap
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
				if not (e["info"] as String).is_empty() or (e["looks"] >= 2 and not (e["op"] in QUIET_OK)):
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
			var quiet: bool = (e["info"] as String).is_empty()
			if e["op"] in QUIET_OK and quiet and e["looks"] >= 2:
				done.append([e, ""])   # taken without a refusal; the change didn't show
				continue
			done.append([e, _reason(e) if e["looks"] > 0 or not quiet else NO_ANSWER])
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


## What `snap` shows around an unload / reload as (uid, parent, pocket) per carried row: everything inside
## `item` when it is carried (rows are depth first, contents after their container), else every carried row
## (an unload off the floor lands there); plus the row of `other` (a reload's ammo) when it is carried.
static func contents_sig(snap: Snapshot, item: ItemRef, other: ItemRef = null) -> PackedInt64Array:
	var out := PackedInt64Array()
	if snap == null or item == null:
		return out
	var c := snap.carried
	var whole := carried_row(snap, item.uid, item.type) < 0
	var inside := {item.uid: true}
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		var within := inside.has(c[i + 2]) and c[i] != item.uid
		if within:
			inside[c[i]] = true
		if whole or within or (other != null and c[i] == other.uid and c[i + 1] == other.type):
			out.append_array(PackedInt64Array([c[i], c[i + 2], c[i + 3]]))
	return out


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
	if op in CONTENT_OPS:
		e["before"] = contents_sig(_snap, item, target if target is ItemRef else null)
	elif op == "clear":
		e["before"] = gun_faults(_snap, item)
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
	# The snapshot lists the first MAX_CARRIED carried items only: past that, missing from the list isn't moved.
	var full := snap.carried.size() / Snapshot.CARRIED_STRIDE >= Snapshot.MAX_CARRIED
	match e["op"]:
		"take":
			return Where.MOVED if row >= 0 else _on_square(snap, item)
		"drop":
			if row >= 0:
				return Where.STILL
			if not full:
				return Where.MOVED
			var at := item.duplicate_ref()   # its handle on the square it was dropped on: it landed
			at.square = e["target"]
			return Where.MOVED if _on_square(snap, at) == Where.STILL else Where.UNKNOWN
		"put":
			# Gone from carried counts too: into a container on the ground, or merged into a stack (new uid).
			if row < 0:
				return Where.UNKNOWN if full else Where.MOVED
			var i := row * Snapshot.CARRIED_STRIDE
			var same: bool = snap.carried[i + 2] == item.parent and snap.carried[i + 3] == item.pocket
			return Where.STILL if same else Where.MOVED
		"throw":
			if row < 0:
				return Where.UNKNOWN if full else Where.MOVED
			return Where.STILL   # also one unit thrown off a stack: QUIET_OK
		"hold":   # in the hand asked for now
			if row < 0:
				return Where.UNKNOWN if full else Where.MOVED
			var flag := Snapshot.CARRIED_WIELDED if e["target"] == "main" else Snapshot.CARRIED_OFFHAND
			return Where.MOVED if (snap.carried[row * Snapshot.CARRIED_STRIDE + 4] & flag) != 0 else Where.STILL
		"pour":
			if row < 0:   # the poured liquid itself, all gone
				return Where.UNKNOWN if full else Where.MOVED
			var into: ItemRef = e["target"] if e["target"] is ItemRef else null
			return Where.MOVED if contents_sig(snap, item, into) != e["before"] else Where.STILL
		"clear":   # the faults changed while it is still the wielded gun: cleared
			var now: Variant = gun_faults(snap, item)
			if not now is Array:
				return Where.UNKNOWN   # not wielded any more
			return Where.MOVED if e["before"] is Array and now != e["before"] else Where.STILL
		"unload", "reload":
			var other: ItemRef = e["target"] if e["target"] is ItemRef else null
			return Where.MOVED if contents_sig(snap, item, other) != e["before"] else Where.STILL
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
	return absi(p.x) <= lim and absi(p.y) <= lim and absi(p.z) <= CddaCoords.Z_LIMIT


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
