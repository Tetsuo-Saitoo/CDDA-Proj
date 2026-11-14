extends RefCounted
## Blocks E6 / L2 / L8: ItemActions (sends one-item actions, refuses bad ones here, judges them on later snapshots
## and CDDA's messages, times out), MockItems (the mock backend on the mock town: seed, take, put, drop, caps)
## and DropTarget (what letting go does). Run by run_tests.gd.

const SQ := Vector3i(3, 4, 0)          # a square of submap (0, 0, 0) in the hand-made snapshots
const TILE := 4 * 12 + 3
const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer (count 3)
const SE := P + Vector3i(1, 1, 0)      # pile: canvas bag
const S := P + Vector3i(0, 1, 0)       # bare floor
const W := P + Vector3i(-1, 0, 0)      # pile: small box (another submap)
const FAR := P + Vector3i(5, 0, 0)     # pile: rock, out of reach
const WORN := Snapshot.CARRIED_WORN
const WIELDED := Snapshot.CARRIED_WIELDED
const OFFHAND := Snapshot.CARRIED_OFFHAND

var _check: Callable
var _it := {}   # itype id -> index


## Records every call; answers `ok`, reports `queued` actions waiting.
class FakeBackend:
	var calls: Array = []
	var ok := true
	var queued := 0

	func take_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
		calls.append(["take", uid, type, pos, hand])
		return ok

	func put_item(uid: float, type: float, container: float, container_type: float, pos: Vector3i,
			pocket := -1) -> bool:
		calls.append(["put", uid, type, container, container_type, pos, pocket])
		return ok

	func drop_item(uid: float, type: float, pos: Vector3i, spot := Vector2(-1, -1)) -> bool:
		calls.append(["drop", uid, type, pos, spot])
		return ok

	func unload_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
		calls.append(["unload", uid, type, pos, hand])
		return ok

	func reload_item(uid: float, type: float, ammo: float, ammo_type: float, pos: Vector3i) -> bool:
		calls.append(["reload", uid, type, ammo, ammo_type, pos])
		return ok

	func throw_item(uid: float, type: float, pos: Vector3i) -> bool:
		calls.append(["throw", uid, type, pos])
		return ok

	func pour_item(uid: float, type: float, pos: Vector3i) -> bool:
		calls.append(["pour", uid, type, pos])
		return ok

	func pour_into(uid: float, type: float, container: float, container_type: float, pocket := -1) -> bool:
		calls.append(["pour_into", uid, type, container, container_type, pocket])
		return ok

	func hold_item(uid: float, type: float, hand: String) -> bool:
		calls.append(["hold", uid, type, hand])
		return ok

	func queued_actions() -> int:
		return queued


## hold (a hand change): finished when the carried row shows the hand asked for; a row gone from the list is no
## hand change: it waits and times out.
func _test_hold() -> void:
	var a := ItemActions.new()
	var b := FakeBackend.new()
	a.backend = b
	var now := [1000]
	a.clock = func() -> int: return now[0]
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	a.on_snapshot(_snap(5, [], [[31, 8, 0, -1, 0], [32, 8, 0, -1, 0]]))
	var sent: bool = a.hold(ItemRef.on_player(31, 8, 0, -1, 0, SQ), "off") and b.calls[-1] == ["hold", 31.0, 8.0, "off"]
	a.on_snapshot(_snap(6, [], [[31, 8, 0, -1, OFFHAND], [32, 8, 0, -1, 0]]))
	_check.call(sent and seen == [["finished", 31, "hold"]] and not a.hold(ItemRef.on_player(33, 8, 0, -1, 0, SQ), "teeth")
			and not a.hold(ItemRef.on_player(33, 8, 0, -1, WORN, SQ), "main") and not a.hold(ItemRef.on_square(34, 8, SQ), "main"),
			"item actions: hold finishes when the row shows that hand; bad hands, worn and lying items refused here")
	a.hold(ItemRef.on_player(32, 8, 0, -1, 0, SQ), "main")
	a.on_snapshot(_snap(7, [], [[31, 8, 0, -1, OFFHAND]]))
	a.on_snapshot(_snap(8, [], [[31, 8, 0, -1, OFFHAND]]))
	var waits := seen.size() == 1 and a.pending(32) == "hold"
	now[0] = 6000
	a.check_timeouts()
	_check.call(waits and seen[-1] == ["refused", 32, "hold", ItemActions.NO_ANSWER] and a.pending_count() == 0,
			"item actions: a held item gone from the carried list is no hand change: it times out (%s)" % [seen[-1]])
	a.free()
	# LiveSession.hold_item: the bridge's "hold" op, checked here first
	var ls := LiveSession.new()
	var off := ls.hold_item(31.0, 8.0, "main")
	var sim := QueueSim.new()
	ls._sim = sim
	var ok := ls.hold_item(31.0, 8.0, "off")
	var bad := [[31.0, 8.0, "pack"], [31.0, 8.0, "MAIN"], [31.0, 8.0, ""], [0.0, 8.0, "main"], [1.5, 8.0, "main"],
		[NAN, 8.0, "main"], [INF, 8.0, "main"], [float(Snapshot.MAX_UID), 8.0, "main"], [31.0, 0.0, "main"],
		[31.0, 8.5, "main"], [31.0, float(Snapshot.MAX_ID + 1), "main"], [-31.0, 8.0, "main"]]
	var none := bad.all(func(c: Array) -> bool: return not ls.hold_item(c[0], c[1], c[2]))
	sim.accept = false
	var full := ls.hold_item(32.0, 8.0, "main")
	_check.call(not off and ok and none and not full and sim.sent == [{"op": "hold", "item": 31, "type": 8, "hand": "off"},
			{"op": "hold", "item": 32, "type": 8, "hand": "main"}],
			"live session: hold_item sends the bridge's hold op; other hands and bad handles aren't sent (%s)" % [sim.sent])
	ls.free()


## A stand-in for CddaSim's queue_item_action: records what it is given, queues while `accept`.
class QueueSim extends RefCounted:
	var sent: Array = []
	var accept := true

	func queue_item_action(d: Dictionary) -> bool:
		sent.append(d)
		return accept


func run(_root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	for id: String in ["rock", "hammer", "bag_canvas", "bag_plastic", "box_small"]:
		_it[id] = tables.index_of("itype", id)
	print("item actions")
	_test_local()
	_test_judge()
	_test_messages_timeout()
	_test_content_ops()
	_test_throw_pour()
	_test_pour_hold()
	_test_hold()
	print("mock items")
	_test_mock(data, tables)
	_test_mock_caps(data, tables)
	_test_mock_with_actions(data, tables)
	_test_mock_guns(data, tables)
	_test_mock_throw_pour(data, tables)
	print("drop target")
	_test_drop_target(data, tables)


## A snapshot of one submap (0, 0, 0), every square seen, with these handles and carried rows.
func _snap(seq: int, handles: Array, carried: Array) -> Snapshot:
	var s := Snapshot.new()
	s.seq = seq
	var sm := Snapshot.Submap.new()
	sm.pos = Vector3i.ZERO
	var vis := PackedByteArray()
	vis.resize(Snapshot.TILES)
	vis.fill(2)
	sm.vis = vis
	var h := PackedInt64Array()
	for x: Array in handles:
		h.append_array(PackedInt64Array(x))
	sm.handles = h
	s.submaps[sm.pos] = sm
	var c := PackedInt64Array()
	for x: Array in carried:
		c.append_array(PackedInt64Array(x))
	s.carried = c
	return s


func _test_local() -> void:
	var a := ItemActions.new()
	var lying := ItemRef.on_square(11, 7, SQ)
	_check.call(not a.take(lying), "item actions: no backend, nothing sent")
	var b := FakeBackend.new()
	a.backend = b
	var held := ItemRef.on_player(21, 8, 0, -1, 0, SQ)
	var bag := ItemRef.on_player(22, 9, 0, -1, WORN, SQ)
	_check.call(not a.take(ItemRef.on_square(0, 7, SQ)) and not a.take(ItemRef.on_square(11, 0, SQ))
			and not a.take(null) and not a.take(held) and not a.take(lying, "teeth") and b.calls.is_empty(),
			"item actions: bad refs, taking a carried item, a bad hand: refused here")
	_check.call(not a.drop(lying, SQ) and not a.put(lying, bag) and not a.put(held, held) and not a.put(held, null)
			and not a.put(held, bag, 300) and not a.drop(held, SQ, Vector2(NAN, 0.5))
			and not a.drop(held, Vector3i(0, 0, 99)) and b.calls.is_empty(),
			"item actions: dropping or putting what isn't carried, into itself, bad pocket, NaN spot, bad square")
	b.ok = false
	_check.call(not a.take(lying) and b.calls.size() == 1 and a.pending_count() == 0,
			"item actions: the backend said no: nothing pending")
	b.ok = true
	b.calls.clear()
	var hid: Array = []
	var changes := [0]
	a.hidden_changed.connect(func(u: Dictionary) -> void: hid.append(u.duplicate()))
	a.changed.connect(func() -> void: changes[0] += 1)
	_check.call(a.take(lying, "main") and b.calls == [["take", 11.0, 7.0, SQ, "main"]] and a.pending(11) == "take"
			and a.pending_count() == 1, "item actions: take sent (uid, type, square, hand)")
	_check.call(hid == [{11: true}] and changes[0] == 1, "item actions: hidden_changed lists the item lying in the world")
	_check.call(not a.take(lying) and b.calls.size() == 1, "item actions: an item in flight isn't sent again")
	_check.call(a.drop(held, SQ + Vector3i(1, 0, 0), Vector2(1.5, 0.25))
			and b.calls[1] == ["drop", 21.0, 8.0, SQ + Vector3i(1, 0, 0), Vector2(0.999, 0.25)],
			"item actions: drop sent, spot clamped to 0..0.999")
	_check.call(a.drop(ItemRef.on_player(25, 8, 0, -1, 0, SQ), SQ) and b.calls[2][4] == Vector2(-1, -1),
			"item actions: drop without a spot")
	_check.call(hid[-1] == {11: true} and changes[0] == 3, "item actions: carried items in flight aren't hidden")
	_check.call(a.put(ItemRef.on_player(23, 10, 0, -1, WIELDED, SQ), bag, 2)
			and b.calls[3] == ["put", 23.0, 10.0, 22.0, 9.0, SQ, 2], "item actions: put sent (container, its square, pocket)")
	_check.call(not a.put(ItemRef.on_player(24, 10, 0, -1, 0, SQ), ItemRef.on_player(23, 10, 0, -1, 0, SQ)),
			"item actions: not into a container that is itself in flight")
	a.clear()
	_check.call(a.pending_count() == 0 and hid[-1] == {} and a.pending(11) == "", "item actions: clear forgets everything")
	a.free()


func _test_judge() -> void:
	var a := ItemActions.new()
	var b := FakeBackend.new()
	a.backend = b
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var hid: Array = []
	a.hidden_changed.connect(func(u: Dictionary) -> void: hid.append(u.duplicate()))
	var both := [[TILE, 11, 7, -1, -1], [TILE, 12, 7, -1, -1]]
	var still := [[TILE, 12, 7, -1, -1]]
	a.on_snapshot(_snap(5, both, []))
	a.take(ItemRef.on_square(11, 7, SQ))
	a.on_snapshot(_snap(5, still, [[11, 7, 0, -1, 0]]))
	_check.call(seen.is_empty() and a.pending(11) == "take", "item actions: not judged on the snapshot seen when sent")
	b.queued = 1
	a.on_snapshot(_snap(6, still, [[11, 7, 0, -1, 0]]))
	_check.call(seen.is_empty(), "item actions: not judged while the bridge still has actions queued")
	b.queued = 0
	a.on_snapshot(_snap(7, still, [[11, 7, 0, -1, 0]]))
	_check.call(seen == [["finished", 11, "take"]] and a.pending_count() == 0 and hid[-1] == {},
			"item actions: finished when a newer snapshot shows it carried; no longer hidden")
	a.take(ItemRef.on_square(12, 7, SQ))
	a.on_events([{"kind": "message", "type": 5, "text": "You hear a thump."}, "junk", {"kind": "sound"},
			{"kind": "message", "type": 4.0, "text": "Your hand is full: you're holding your hammer."},
			{"kind": "message", "text": 3}])
	_check.call(a.messages(12) == PackedStringArray(["You hear a thump.", "Your hand is full: you're holding your hammer."]),
			"item actions: message events kept while pending, junk skipped")
	a.on_snapshot(_snap(8, still, []))
	_check.call(seen[-1] == ["refused", 12, "take", "Your hand is full: you're holding your hammer."],
			"item actions: nothing moved: refused with CDDA's reason")
	a.take(ItemRef.on_square(12, 7, SQ))
	a.on_events([{"kind": "message", "type": 5, "text": "You pick up the rock."}])
	a.on_snapshot(_snap(9, still, []))
	_check.call(a.pending(12) == "take", "item actions: no reason yet: waits one more snapshot (the first may predate it)")
	a.on_snapshot(_snap(9, still, []))
	_check.call(a.pending(12) == "take", "item actions: the same snapshot again doesn't count")
	a.on_snapshot(_snap(10, still, []))
	_check.call(seen[-1] == ["refused", 12, "take", ItemActions.DIDNT_WORK], "item actions: still there twice: \"That didn't work.\"")
	a.take(ItemRef.on_square(12, 7, SQ))
	var dark := _snap(11, [], [])
	var sm: Snapshot.Submap = dark.submaps[Vector3i.ZERO]
	var vis := sm.vis
	vis[TILE] = 1
	sm.vis = vis
	a.on_snapshot(dark)
	a.on_snapshot(_snap(12, [], [[99, 7, 0, -1, 0]]))
	_check.call(seen[-1] == ["finished", 12, "take"] and seen.size() == 4,
			"item actions: an unseen square isn't judged; handle gone (stack merged, new uid) = finished")
	var bag := ItemRef.on_player(22, 9, 0, -1, WORN, SQ)
	a.drop(ItemRef.on_player(21, 8, 22, 0, 0, SQ), SQ)
	a.put(ItemRef.on_player(23, 10, 0, -1, WIELDED, SQ), bag)
	a.put(ItemRef.on_player(24, 10, 22, 1, 0, SQ), bag, 0)
	a.put(ItemRef.on_player(26, 8, 22, 1, 0, SQ), bag, 0)
	a.drop(ItemRef.on_player(27, 8, 0, -1, 0, SQ), SQ)
	a.on_events([{"kind": "message", "type": 4, "text": "There's no room for your rock there."}])
	a.on_snapshot(_snap(13, [[TILE, 21, 8, -1, -1]],
			[[22, 9, 0, -1, WORN], [23, 10, 22, 1, 0], [24, 10, 22, 1, 0], [27, 8, 0, -1, 0]]))
	var why := "There's no room for your rock there."
	_check.call(seen.has(["finished", 21, "drop"]) and seen.has(["finished", 23, "put"]) and seen.has(["finished", 26, "put"])
			and seen.has(["refused", 24, "put", why]),
			"item actions: drop (no longer carried), put (new parent, or gone: merged) finished; unmoved put refused")
	# CDDA's message goes to everything in flight: the unmoved drop takes the same reason.
	_check.call(seen.has(["refused", 27, "drop", why]) and a.pending_count() == 0 and seen.size() == 9,
			"item actions: one judgement each")
	a.free()


func _test_messages_timeout() -> void:
	var a := ItemActions.new()
	a.backend = FakeBackend.new()
	var now := [1000]
	a.clock = func() -> int: return now[0]
	var seen: Array = []
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append([it.uid, op, why]))
	a.on_events([{"kind": "message", "type": 4, "text": "nobody listens"}])   # nothing pending: ignored
	a.take(ItemRef.on_square(11, 7, SQ))
	var filler := "x\n".repeat(300)
	var evs: Array = []
	for i in 10:
		evs.append({"kind": "message", "type": 5, "text": "%d %s" % [i, filler]})
	a.on_events(evs)
	var kept := a.messages(11)
	_check.call(kept.size() == ItemActions.MAX_MESSAGES and kept[0].begins_with("2 ")
			and kept[7].length() <= ItemActions.MAX_TEXT and not ("\n" in kept[7]),
			"item actions: 8 newest messages kept, 200 chars, one line")
	now[0] = 5999
	a.check_timeouts()
	_check.call(seen.is_empty() and a.pending(11) == "take", "item actions: not timed out before 5 s")
	now[0] = 6000
	a._process(0.0)
	_check.call(seen == [[11, "take", ItemActions.NO_ANSWER]] and a.pending_count() == 0,
			"item actions: no judgement within 5 s: \"No answer from the game.\"")
	a.free()


## Unload / reload: judged on what changes inside the item (carried rows), refused on CDDA's message, and
## finished at the timeout when the sim took them quietly (rounds topped up in place show no change).
func _test_content_ops() -> void:
	var a := ItemActions.new()
	var b := FakeBackend.new()
	a.backend = b
	var now := [1000]
	a.clock = func() -> int: return now[0]
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var gun := ItemRef.on_player(31, 20, 0, -1, WIELDED, SQ)
	var loaded := [[31, 20, 0, -1, WIELDED], [32, 21, 31, 0, 0], [33, 22, 32, 0, 0]]   # gun > magazine > rounds
	var out := [[31, 20, 0, -1, WIELDED], [32, 21, 0, -1, OFFHAND], [33, 22, 32, 0, 0]]
	a.on_snapshot(_snap(5, [], loaded))
	_check.call(a.unload(gun, "off") and b.calls[-1] == ["unload", 31.0, 20.0, SQ, "off"] and a.hidden().is_empty(),
			"item actions: unload sends the item, its square and the hand; nothing hidden")
	a.on_snapshot(_snap(6, [], loaded))
	a.on_snapshot(_snap(7, [], loaded))
	_check.call(seen.is_empty() and a.pending(31) == "unload", "item actions: an unload unchanged and unrefused keeps waiting")
	a.on_snapshot(_snap(8, [], out))
	_check.call(seen == [["finished", 31, "unload"]], "item actions: unload finished when the magazine left the gun")
	var mag := ItemRef.on_player(32, 21, 0, -1, OFFHAND, SQ)
	_check.call(a.reload(gun, mag) and b.calls[-1] == ["reload", 31.0, 20.0, 32.0, 21.0, SQ],
			"item actions: reload sends the item and the ammo with the ammo's square")
	a.on_events([MockItems.message_event("That magazine doesn't fit your gun.")])
	a.on_snapshot(_snap(9, [], out))
	_check.call(seen[-1] == ["refused", 31, "reload", "That magazine doesn't fit your gun."],
			"item actions: reload refused with CDDA's message")
	a.reload(gun, mag)
	a.on_snapshot(_snap(10, [], loaded))
	_check.call(seen[-1] == ["finished", 31, "reload"], "item actions: reload finished when the magazine is in")
	# Rounds topped up in a magazine that already held some: the rows don't change.
	var box := ItemRef.on_player(34, 22, 0, -1, 0, SQ)
	var topped := loaded + [[34, 22, 0, -1, 0]]
	a.on_snapshot(_snap(11, [], topped))
	a.reload(ItemRef.on_player(32, 21, 31, 0, 0, SQ), box)
	a.on_snapshot(_snap(12, [], topped))
	a.on_snapshot(_snap(13, [], topped))
	now[0] = 1000 + ItemActions.TIMEOUT_MS
	a.check_timeouts()
	_check.call(seen[-1] == ["finished", 32, "reload"], "item actions: taken quietly (no change shows): finished at the timeout")
	a.unload(ItemRef.on_player(32, 21, 31, 0, 0, SQ))
	now[0] += ItemActions.TIMEOUT_MS
	a.check_timeouts()
	_check.call(seen[-1] == ["refused", 32, "unload", ItemActions.NO_ANSWER], "item actions: never looked at: no answer")
	var floor_gun := ItemRef.on_square(35, 20, SQ)
	_check.call(a.unload(floor_gun) and a.hidden().is_empty(), "item actions: unloading a gun on the floor leaves it shown")
	var n := b.calls.size()
	_check.call(not a.unload(gun, "belt") and not a.reload(gun, gun) and not a.reload(floor_gun, box)
			and not a.reload(gun, ItemRef.on_square(36, 22, Vector3i(1 << 30, 0, 0))) and b.calls.size() == n,
			"item actions: bad hand, itself, an uncarried item or a square out of range: nothing sent")
	_check.call(ItemActions.contents_sig(_snap(1, [], loaded), gun) == PackedInt64Array([32, 31, 0, 33, 32, 0])
			and ItemActions.contents_sig(_snap(1, [], loaded), floor_gun).size() == 9,
			"item actions: contents seen are what is inside a carried item, else everything carried")
	a.free()


## Hold E to pour (PourHold): with a liquid in hand a tap still does E's usual thing, a hold pours once onto the
## square or into the container it is given; no liquid: E isn't touched; a cancelled press sends nothing.
func _test_pour_hold() -> void:
	InputActions.ensure(false)
	var a := ItemActions.new()
	var b := FakeBackend.new()
	a.backend = b
	var s := _snap(5, [], [[43, 32, 0, -1, WIELDED]])
	s.player_pos = SQ
	a.on_snapshot(s)
	var jug := ItemRef.on_player(43, 32, 0, -1, WIELDED, SQ)
	var p := PourHold.new()
	p.actions = a
	var hold: Array = [jug]
	p.held = func() -> Variant: return hold[0]
	var next := SQ + Vector3i(1, 0, 0)
	var where: Array = [{"square": next}]
	p.target = func() -> Dictionary: return where[0]
	var taps := [0]
	p.tap = func() -> void: taps[0] += 1
	var down := InputActions.slots(&"use_held")[0].duplicate() as InputEventKey
	down.pressed = true
	var echo := down.duplicate() as InputEventKey
	echo.echo = true
	var release := down.duplicate() as InputEventKey
	release.pressed = false
	_check.call(p.handle(down, 0) and p.waiting() and p.update(100) == "" and p.handle(echo, 200) and p.handle(release, 300)
			and taps[0] == 1 and not p.waiting() and b.calls.is_empty(), "pour hold: a tap does E's usual thing, nothing poured")
	_check.call(p.hint(null) == "hold %s: pour it out" % InputActions.key_of(&"use_held"), "pour hold: hint (%s)" % p.hint(null))
	p.handle(down, 1000)
	_check.call(p.update(1000 + PourHold.HOLD_MS) == "pour" and b.calls[-1] == ["pour", 43.0, 32.0, next]
			and not p.handle(release, 1600) and taps[0] == 1, "pour hold: held long enough: poured onto the square, no tap")
	hold[0] = ItemRef.on_player(44, 32, 0, -1, WIELDED, SQ)   # another jug: the first one's pour is still in flight
	where[0] = {"container": ItemRef.on_square(50, 34, next)}
	p.handle(down, 2000)
	_check.call(p.update(2000 + PourHold.HOLD_MS) == "pour_into" and b.calls[-1] == ["pour_into", 44.0, 32.0, 50.0, 34.0, -1],
			"pour hold: into the container under the pointer")
	hold[0] = ItemRef.on_player(45, 32, 0, -1, WIELDED, SQ)
	where[0] = {"square": SQ + Vector3i(3, 0, 0)}
	var n := b.calls.size()
	p.handle(down, 3000)
	_check.call(p.update(3000 + PourHold.HOLD_MS) == "refused" and b.calls.size() == n, "pour hold: too far: refused here")
	p.handle(down, 4000)
	p.cancel()
	_check.call(p.update(9000) == "" and b.calls.size() == n and taps[0] == 1, "pour hold: a cancelled press sends nothing")
	hold[0] = null
	_check.call(not p.handle(down, 5000) and not p.waiting() and p.hint(null) == "", "pour hold: no liquid in hand: E isn't touched")
	a.free()


## Throw and pour: what they send, what they refuse here, and how later snapshots judge them.
func _test_throw_pour() -> void:
	var a := ItemActions.new()
	var b := FakeBackend.new()
	a.backend = b
	var now := [1000]
	a.clock = func() -> int: return now[0]
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var seq := [5]
	var look := func(rows: Array) -> void:
		var s := _snap(seq[0], [], rows)
		s.player_pos = SQ
		seq[0] += 1
		a.on_snapshot(s)
	# a rock held; a worn bag holding a bottle of water
	var all := [[41, 30, 0, -1, WIELDED], [42, 31, 0, -1, WORN], [43, 32, 42, 0, 0], [44, 33, 43, 0, 0]]
	look.call(all)
	var rock := ItemRef.on_player(41, 30, 0, -1, WIELDED, SQ)
	var bag := ItemRef.on_player(42, 31, 0, -1, WORN, SQ)
	var bottle := ItemRef.on_player(43, 32, 42, 0, 0, SQ)
	var there := SQ + Vector3i(4, 0, 0)
	var n := b.calls.size()
	_check.call(not a.throw(bag, there) and not a.throw(rock, SQ) and not a.pour(bottle, SQ + Vector3i(2, 0, 0))
			and not a.pour(bottle, SQ + Vector3i(0, 0, 1)) and not a.pour_into(bottle, bottle)
			and not a.pour_into(bottle, ItemRef.on_square(45, 34, SQ), 999) and b.calls.size() == n,
			"throw / pour: worn, at your own square, too far to pour, into itself or a bad pocket: nothing sent")
	_check.call(a.throw(rock, there) and b.calls[-1] == ["throw", 41.0, 30.0, there], "throw: sends the item and the square")
	look.call(all.slice(1))
	_check.call(seen[-1] == ["finished", 41, "throw"], "throw: finished when it left your hands")
	var stack := ItemRef.on_player(42, 31, 0, -1, 0, SQ)   # one of a stack flies, the row stays
	all[1] = [42, 31, 0, -1, 0]
	look.call(all.slice(1))
	a.throw(stack, there)
	look.call(all.slice(1))
	look.call(all.slice(1))
	now[0] += ItemActions.TIMEOUT_MS
	a.check_timeouts()
	_check.call(seen[-1] == ["finished", 42, "throw"], "throw: one unit off a stack, no refusal: finished at the timeout")
	var next := SQ + Vector3i(1, 0, 0)
	_check.call(a.pour(bottle, next) and b.calls[-1] == ["pour", 43.0, 32.0, next], "pour: sends the item and the square")
	look.call(all.slice(1, 3))
	_check.call(seen[-1] == ["finished", 43, "pour"], "pour: finished when the water left the bottle")
	var jug := ItemRef.on_square(45, 34, next)
	_check.call(a.pour_into(bottle, jug, 0) and b.calls[-1] == ["pour_into", 43.0, 32.0, 45.0, 34.0, 0],
			"pour into: sends the item, the container and the pocket")
	a.on_events([MockItems.message_event("There's no room in the jug.")])
	look.call(all.slice(1, 3))
	_check.call(seen[-1] == ["refused", 43, "pour", "There's no room in the jug."], "pour into: refused with CDDA's message")
	a.free()


## MockItems' throw and pour.
func _test_mock_throw_pour(data: Variant, tables: IdTables) -> void:
	var snap := _town(data, tables)
	var m := MockItems.new(snap, tables)
	var a := ItemActions.new()
	a.backend = m
	m.changed.connect(a.on_snapshot)
	m.message.connect(func(t: String) -> void: a.on_events([MockItems.message_event(t)]))
	a.on_snapshot(snap)
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var rock: int = _it["rock"]
	var r := m.give(rock, 0, WIELDED)
	var held := ItemRef.on_player(r, rock, 0, -1, WIELDED, P)
	var far := P + Vector3i(MockItems.THROW_RANGE + 1, 0, 0)
	_check.call(a.throw(held, far) and (seen[-1][3] as String).begins_with("That's too far"),
			"mock throw: out of range refused (%s)" % [seen[-1]])
	var at := P + Vector3i(0, 3, 0)
	var thrown := a.throw(held, at)
	_check.call(thrown and seen[-1] == ["finished", r, "throw"] and _row(snap, r).is_empty() and snap.player_wielded == 0
			and _handle(snap, at, rock) == r, "mock throw: the rock lands on the square (%s)" % [seen[-1]])
	var bottle := m.give(_it["bag_plastic"])
	var water := m.give(rock, bottle)   # a stand-in: the mock pours whatever is inside
	var b := ItemRef.on_player(bottle, _it["bag_plastic"], 0, -1, 0, P)
	_check.call(a.pour(b, S) and seen[-1] == ["finished", bottle, "pour"] and _row(snap, water).is_empty(),
			"mock pour: what the bottle held is gone")
	_check.call(a.pour(b, S) and seen[-1] == ["refused", bottle, "pour", "Your %s is empty." % m._name(_it["bag_plastic"])],
			"mock pour: an empty bottle refused")
	var refill := m.give(rock, bottle)
	var box := m.give(_it["box_small"])
	_check.call(a.pour_into(b, ItemRef.on_player(box, _it["box_small"], 0, -1, 0, P), 0)
			and seen[-1] == ["finished", bottle, "pour"] and _row(snap, refill)[2] == box,
			"mock pour into: the contents go into the box")
	_check.call(a.pending_count() == 0, "mock throw / pour: every action judged at once")
	a.free()


## MockItems' unload / reload on a gun row holding a magazine row holding rounds.
func _test_mock_guns(data: Variant, tables: IdTables) -> void:
	var gt: int = _it["hammer"]   # stand-ins: the mock only needs types
	var mt: int = _it["box_small"]
	var rt: int = _it["rock"]
	var snap := _town(data, tables)
	var m := MockItems.new(snap, tables)
	var a := ItemActions.new()
	a.backend = m
	m.changed.connect(a.on_snapshot)
	m.message.connect(func(t: String) -> void: a.on_events([MockItems.message_event(t)]))
	a.on_snapshot(snap)
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var g := m.give(gt, 0, WIELDED)
	var mg := m.give(mt, g)
	var rd := m.give(rt, mg)
	_check.call(g > 0 and _row(snap, mg) == [mg, mt, g, 0, 0] and _row(snap, rd) == [rd, rt, mg, 0, 0]
			and snap.player_wielded == gt and m.give(rt, 12345) == -1, "mock guns: give builds gun > magazine > rounds")
	var gun := ItemRef.on_player(g, gt, 0, -1, WIELDED, P)
	_check.call(a.unload(gun, "main") and (seen[-1][3] as String).begins_with("Your hand is full"),
			"mock guns: unload into the main hand holding the gun: refused")
	_check.call(a.unload(gun, "off") and seen[-1] == ["finished", g, "unload"] and _row(snap, mg)[4] == OFFHAND
			and _row(snap, mg)[2] != g and _row(snap, rd)[2] == mg, "mock guns: magazine out whole into the off hand")
	var mag := ItemRef.on_player(mg, mt, _row(snap, mg)[2], _row(snap, mg)[3], OFFHAND, P)
	m.reload_check = func(_it_t: int, _ammo_t: int) -> String: return "That magazine doesn't fit your gun."
	_check.call(a.reload(gun, mag) and seen[-1] == ["refused", g, "reload", "That magazine doesn't fit your gun."]
			and _row(snap, mg)[4] == OFFHAND, "mock guns: reload_check refuses, nothing moves")
	m.reload_check = Callable()
	_check.call(a.reload(gun, mag) and seen[-1] == ["finished", g, "reload"] and _row(snap, mg) == [mg, mt, g, 0, 0]
			and _row(snap, rd)[2] == mg, "mock guns: magazine back in the gun")
	var box := m.give(rt)
	_check.call(a.reload(ItemRef.on_player(mg, mt, g, 0, 0, P), ItemRef.on_player(box, rt, 0, -1, 0, P))
			and seen[-1] == ["finished", mg, "reload"] and _row(snap, box).is_empty(),
			"mock guns: rounds merge into the magazine's rounds (counts aren't modelled)")
	_check.call(a.reload(gun, ItemRef.on_player(box + 1, mt, 0, -1, 0, P)) and seen[-1][0] == "refused",
			"mock guns: ammo no longer there: refused")
	_check.call(a.unload(ItemRef.on_player(rd, rt, mg, 0, 0, P)) and seen[-1] == ["refused", rd, "unload",
			"Your %s isn't loaded." % m._name(rt)], "mock guns: nothing inside: refused")
	_check.call(a.pending_count() == 0, "mock guns: every action judged at once")
	var faults: Array[String] = ["fault_gun_dirt", "fault_stovepipe"]
	snap.player_gun = {"type": gt, "dirt": 0, "rounds": -1, "faults": faults}
	_check.call(a.clear_jam(gun) and seen[-1] == ["finished", g, "clear"] and snap.player_gun["faults"] == ["fault_gun_dirt"],
			"mock guns: clear_jam clears the jam, other faults stay (%s)" % [seen[-1]])
	_check.call(a.clear_jam(gun) and seen[-1] == ["refused", g, "clear", "It isn't jammed."], "mock guns: not jammed: refused")
	_check.call(not a.clear_jam(mag) and not a.clear_jam(ItemRef.on_square(g, gt, P)) and a.pending_count() == 0,
			"mock guns: clear_jam only for the wielded gun")
	a.free()


## A copy of the mock town with known piles around the player.
func _town(data: Variant, tables: IdTables) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[1, 3, [_it["rock"], _it["hammer"]]], [13, 1, [_it["bag_canvas"]]], [5, 1, [_it["rock"]]]]
		elif at == Vector3i(15, 32, 0):
			sm["items"] = [[11, 1, [_it["box_small"]]]]
		else:
			continue
		sm.erase("handles")
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid() and snap.player_pos == P, "mock items: test town loads " + snap.error)
	return snap


func _sm(snap: Snapshot, p: Vector3i) -> Snapshot.Submap:
	return snap.submaps[CddaCoords.ms_to_sm(p)]


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(snap: Snapshot, p: Vector3i, type: int) -> int:
	var h := _sm(snap, p).handles
	for i in range(0, h.size(), Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


## The pile row on square p ([] if none).
func _pile(snap: Snapshot, p: Vector3i) -> Array:
	var items := _sm(snap, p).items
	for i in range(0, items.size(), Snapshot.PILE_STRIDE):
		if items[i] == ItemActions.tile_of(p):
			return Array(items.slice(i, i + Snapshot.PILE_STRIDE))
	return []


## Carried row of uid ([] if not carried).
func _row(snap: Snapshot, uid: int) -> Array:
	for i in range(0, snap.carried.size(), Snapshot.CARRIED_STRIDE):
		if snap.carried[i] == uid:
			return Array(snap.carried.slice(i, i + Snapshot.CARRIED_STRIDE))
	return []


func _test_mock(data: Variant, tables: IdTables) -> void:
	var rock: int = _it["rock"]
	var hammer: int = _it["hammer"]
	var canvas: int = _it["bag_canvas"]
	var plastic: int = _it["bag_plastic"]
	var box: int = _it["box_small"]
	_check.call(MockItems.is_container(canvas, tables) and MockItems.is_container(box, tables)
			and not MockItems.is_container(hammer, tables) and not MockItems.is_container(0, tables)
			and not MockItems.is_container(1 << 20, tables) and not MockItems.is_container(canvas, null),
			"mock items: containers by category (no pocket counts in the tables yet)")
	var snap := _town(data, tables)
	snap.carried = PackedInt64Array([900, plastic, 0, -1, WORN])
	var m := MockItems.new(snap, tables)
	var said: Array = []
	var caps := [0]
	m.message.connect(func(t: String) -> void: said.append(t))
	m.changed.connect(func(_s: Snapshot) -> void: caps[0] += 1)
	var added := m.seed()
	var rock_uid := _handle(snap, E, rock)
	var hammer_uid := _handle(snap, E, hammer)
	var canvas_uid := _handle(snap, SE, canvas)
	var box_uid := _handle(snap, W, box)
	var h := _sm(snap, E).handles
	_check.call(added >= 5 and rock_uid >= MockItems.FIRST_UID and hammer_uid > 0 and canvas_uid > 0 and box_uid > 0
			and _handle(snap, FAR, rock) > 0 and h.size() == 4 * Snapshot.HANDLE_STRIDE and h[3] == -1 and h[4] == -1,
			"mock items: seed gives each pile a handle per top itype (%d), no spot" % added)
	_check.call(m.seed() == 0, "mock items: seeding again adds nothing")
	var sm := _sm(snap, E)
	var rev := sm.detail_revision
	var seq := snap.seq
	_check.call(m.take_item(rock_uid, rock, E, "pack") and _row(snap, rock_uid) == [rock_uid, rock, 900, 0, 0]
			and snap.carried[Snapshot.CARRIED_STRIDE] == rock_uid and _handle(snap, E, rock) < 0
			and _handle(snap, E, hammer) == hammer_uid, "mock items: take into the pack = the worn container")
	_check.call(_pile(snap, E).slice(0, 4) == [1, 2, hammer, rock] and sm.detail_revision == rev + 1
			and snap.seq == seq + 1 and caps[0] == 1 and said.is_empty(),
			"mock items: pile count and top4 (largest first) kept, detail_revision and seq bumped")
	_check.call(m.take_item(hammer_uid, hammer, E, "main") and _row(snap, hammer_uid) == [hammer_uid, hammer, 0, -1, WIELDED]
			and snap.carried[0] == hammer_uid and snap.player_wielded == hammer and _pile(snap, E)[1] == 1,
			"mock items: take into the main hand (wielded, listed first)")
	var before := snap.carried
	rev = _sm(snap, SE).detail_revision
	_check.call(m.take_item(canvas_uid, canvas, SE, "main") and said.size() == 1 and said[0].begins_with("Your hand is full")
			and snap.carried == before and _handle(snap, SE, canvas) == canvas_uid and _sm(snap, SE).detail_revision == rev
			and caps[0] == 3, "mock items: main hand busy: refused with a message, nothing changes (still a new capture)")
	_check.call(m.take_item(canvas_uid, canvas, SE, "off") and _row(snap, canvas_uid) == [canvas_uid, canvas, 900, 0, OFFHAND]
			and _pile(snap, SE).is_empty(), "mock items: take into the off hand; the last item's pile row goes")
	_check.call(m.take_item(_handle(snap, FAR, rock), rock, FAR) and said[-1] == "You can't reach that from here."
			and _handle(snap, FAR, rock) > 0, "mock items: out of reach refused")
	_check.call(m.drop_item(rock_uid, rock, S, Vector2(0.25, 0.5)) and _row(snap, rock_uid).is_empty()
			and Array(_sm(snap, S).handles.slice(-5)) == [12, rock_uid, rock, 250, 500] and _pile(snap, S) == [12, 1, rock, 0, 0, 0, 0, 0],
			"mock items: drop with a spot (permille) makes a pile")
	_check.call(m.drop_item(hammer_uid, hammer, FAR) and said[-1] == "You can't reach that from here."
			and m.drop_item(900, plastic, S) and said[-1].begins_with("Take off") and _row(snap, hammer_uid).size() == 5,
			"mock items: drop out of reach or of a worn item refused")
	_check.call(m.put_item(hammer_uid, hammer, 900, plastic, P, 1) and _row(snap, hammer_uid) == [hammer_uid, hammer, 900, 1, 0]
			and snap.player_wielded == 0 and snap.carried.find(900) < snap.carried.find(hammer_uid),
			"mock items: put the wielded hammer into the worn bag (pocket 1)")
	var n := said.size()
	_check.call(m.put_item(canvas_uid, canvas, hammer_uid, hammer, P) and said.size() == n + 1
			and said[-1].contains("can't hold anything") and _row(snap, canvas_uid)[2] == 900,
			"mock items: put into a non-container refused")
	_check.call(m.put_item(canvas_uid, canvas, canvas_uid, canvas, P) and said[-1].contains("inside itself"),
			"mock items: put into itself refused")
	_check.call(m.put_item(canvas_uid, canvas, box_uid, box, FAR) and said[-1] == "You can't reach that from here.",
			"mock items: a container out of reach refused")
	rev = _sm(snap, W).detail_revision
	_check.call(m.put_item(canvas_uid, canvas, box_uid, box, W) and _row(snap, canvas_uid).is_empty()
			and _sm(snap, W).detail_revision == rev + 1 and _handle(snap, W, box) == box_uid,
			"mock items: put into a container lying in reach")
	# A test's own pocket rule (put_check): refused with its message and nothing moves; other pockets still go.
	m.put_check = func(it: int, _ct: int, pocket: int) -> Variant:
		return "The hammer is too big for that pocket." if it == hammer and pocket == 2 else ""
	n = said.size()
	_check.call(m.put_item(hammer_uid, hammer, 900, plastic, P, 2) and said.size() == n + 1
			and said[-1] == "The hammer is too big for that pocket." and _row(snap, hammer_uid)[3] == 1,
			"mock items: put_check refuses a pocket with its own message, nothing moves")
	_check.call(m.put_item(hammer_uid, hammer, 900, plastic, P, 0) and said.size() == n + 1
			and _row(snap, hammer_uid)[3] == 0, "mock items: put_check lets the other pockets through")
	m.put_check = Callable()
	caps[0] = 0
	_check.call(not m.take_item(NAN, rock, E) and not m.take_item(rock_uid, 0.5, E) and not m.take_item(rock_uid, rock, E, "teeth")
			and not m.drop_item(hammer_uid, hammer, S, Vector2(2.0, 0.5)) and not m.drop_item(hammer_uid, hammer, S, Vector2(0.5, NAN))
			and not m.put_item(hammer_uid, hammer, 900, plastic, P, 300) and caps[0] == 0,
			"mock items: malformed calls return false like the bridge, no capture")
	_check.call(m.queued_actions() == 0, "mock items: nothing queued")
	var bare := _town(data, tables)
	var m2 := MockItems.new(bare, tables)
	m2.seed()
	var r2 := _handle(bare, E, rock)
	_check.call(m2.take_item(r2, rock, E) and _row(bare, r2) == [r2, rock, 0, -1, 0], "mock items: no worn container: on the body")


func _test_mock_caps(data: Variant, tables: IdTables) -> void:
	var rock: int = _it["rock"]
	var snap := _town(data, tables)
	var m := MockItems.new(snap, tables)
	m.seed()
	var said: Array = []
	m.message.connect(func(t: String) -> void: said.append(t))
	var full := PackedInt64Array()
	for i in Snapshot.MAX_CARRIED:
		full.append_array(PackedInt64Array([5000 + i, rock, 0, -1, 0]))
	snap.carried = full
	var r := _handle(snap, E, rock)
	_check.call(m.take_item(r, rock, E) and said[-1].begins_with("There's no room in your inventory")
			and _handle(snap, E, rock) == r and snap.carried.size() == full.size(), "mock items: 256 carried: take refused")
	snap.carried = PackedInt64Array([77, rock, 0, -1, 0])
	var sm := _sm(snap, S)
	var hs := sm.handles
	for i in Snapshot.MAX_HANDLES_PER_TILE:
		hs.append_array(PackedInt64Array([ItemActions.tile_of(S), 7000 + i, rock, -1, -1]))
	sm.handles = hs
	_check.call(m.drop_item(77, rock, S) and said[-1].begins_with("There's no room for your") and _row(snap, 77).size() == 5,
			"mock items: 32 handles on a square: drop refused")


func _test_mock_with_actions(data: Variant, tables: IdTables) -> void:
	var rock: int = _it["rock"]
	var canvas: int = _it["bag_canvas"]
	var snap := _town(data, tables)
	var m := MockItems.new(snap, tables)
	m.seed()
	var a := ItemActions.new()
	a.backend = m
	m.changed.connect(a.on_snapshot)
	m.message.connect(func(t: String) -> void: a.on_events([MockItems.message_event(t)]))
	a.on_snapshot(snap)
	var seen: Array = []
	a.finished.connect(func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op]))
	a.refused.connect(func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why]))
	var r := _handle(snap, E, rock)
	var c := _handle(snap, SE, canvas)
	_check.call(a.take(ItemRef.on_square(r, rock, E), "main") and seen == [["finished", r, "take"]] and a.pending_count() == 0,
			"mock + actions: take answered at once: finished")
	_check.call(a.take(ItemRef.on_square(c, canvas, SE), "main") and seen[-1][0] == "refused"
			and (seen[-1][3] as String).begins_with("Your hand is full"), "mock + actions: main hand busy: refused with the mock's reason")
	_check.call(a.drop(ItemRef.on_player(r, rock, 0, -1, WIELDED, P), S, Vector2(0.5, 0.5)) and seen[-1] == ["finished", r, "drop"]
			and Array(_sm(snap, S).handles.slice(-5)) == [ItemActions.tile_of(S), r, rock, 500, 500],
			"mock + actions: drop with a spot finished, the handle keeps the spot")
	a.free()


func _test_drop_target(data: Variant, tables: IdTables) -> void:
	var rock: int = _it["rock"]
	var plastic: int = _it["bag_plastic"]
	var box: int = _it["box_small"]
	var snap := _town(data, tables)
	MockItems.new(snap, tables).seed()
	var coords := CddaCoords.new()
	coords.set_bubble_origin(snap.bubble_origin)
	var sm := _sm(snap, E)
	var f := sm.furn
	f[ItemActions.tile_of(E)] = tables.index_of("furn", "f_woodstove")
	sm.furn = f
	snap.carried = PackedInt64Array([77, rock, 0, -1, WIELDED, 78, plastic, 77, 0, 0, 79, plastic, 0, -1, WORN])
	var reach := func(sq: Vector3i) -> bool:
		var d := sq - snap.player_pos
		return d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1
	var held := ItemRef.on_player(77, rock, 0, -1, WIELDED, P)
	var at := func(sq: Vector3i, off: Vector3, what: String) -> Dictionary:
		return {"hit": true, "square": sq, "point": coords.ms_to_world(sq) + off, "what": what}
	var res := DropTarget.resolve(coords, at.call(S, Vector3(0.25, 0.0, 0.75), "floor"), null, held, tables, snap, reach)
	_check.call(res["kind"] == "surface" and res["square"] == S and res["spot"] == Vector2(0.25, 0.75) and res["container"] == null,
			"drop target: floor in reach: a surface, spot across the square (x east, y south)")
	res = DropTarget.resolve(coords, at.call(E, Vector3(1.0, 0.6, 0.5), "furniture"), null, held, tables, snap, reach)
	_check.call(DropTarget.furniture_id(E, snap, tables) == "f_woodstove" and res["kind"] == "burner"
			and res["spot"] == Vector2(0.999, 0.5) and (res["heat"] as Dictionary).is_empty(),
			"drop target: a wood stove is a burner (no heat squares in the snapshot: by id), spot clamped")
	# The bridge's heat squares decide when the snapshot has them: a fire on the floor is a burner, lit or not.
	var sms := _sm(snap, S)
	sms.heat = PackedInt32Array([ItemActions.tile_of(S), Snapshot.HEAT_FIRE, 0, 2, 0, 0])
	res = DropTarget.resolve(coords, at.call(S, Vector3(0.5, 0.0, 0.5), "floor"), null, held, tables, snap, reach)
	_check.call(res["kind"] == "burner" and res["heat"]["fire"] == 2 and res["heat"]["lit"] == false
			and Hands.drop_hint(res, tables) == "put it on the heat (not lit)",
			"drop target: a heat square from the snapshot is a burner; the hint says it isn't lit")
	sms.heat = PackedInt32Array([ItemActions.tile_of(S), Snapshot.HEAT_FIRE, 0, 2, 0, 1])
	res = DropTarget.resolve(coords, at.call(S, Vector3(0.5, 0.0, 0.5), "floor"), null, held, tables, snap, reach)
	_check.call(res["kind"] == "burner" and Hands.drop_hint(res, tables) == "put it on the heat", "drop target: a lit fire")
	sms.heat = PackedInt32Array()
	res = DropTarget.resolve(coords, at.call(P, Vector3(0.5, 0.6, 0.5), "furniture"), null, held, tables, snap, reach)
	_check.call(res["kind"] == "surface" and not DropTarget.is_heat_source("f_table"), "drop target: other furniture is a surface")
	var none := true
	for what: String in ["wall", "door", "ceiling", "zombie"]:
		none = none and DropTarget.resolve(coords, at.call(S, Vector3(0.5, 0, 0.5), what), null, held, tables, snap, reach)["kind"] == "none"
	none = none and DropTarget.resolve(coords, at.call(FAR, Vector3(0.5, 0, 0.5), "floor"), null, held, tables, snap, reach)["kind"] == "none"
	none = none and DropTarget.resolve(coords, {"hit": false}, null, held, tables, snap, reach)["kind"] == "none"
	none = none and DropTarget.resolve(coords, {"hit": "yes", "square": "x"}, null, held, tables, snap, reach)["kind"] == "none"
	none = none and DropTarget.resolve(coords, at.call(S, Vector3(NAN, 0, 0), "floor"), null, held, tables, snap, reach)["kind"] == "none"
	none = none and DropTarget.resolve(coords, at.call(S, Vector3(0.5, 0, 0.5), "floor"), null, held, tables, snap, Callable())["kind"] == "none"
	none = none and DropTarget.resolve(coords, at.call(S, Vector3(0.5, 0, 0.5), "floor"), null, null, tables, snap, reach)["kind"] == "none"
	_check.call(none, "drop target: walls, doors, ceilings, creatures, out of reach, no hit, bad hits, nothing held: none")
	var ground_box := ItemRef.on_square(_handle(snap, W, box), box, W)
	res = DropTarget.resolve(coords, {"hit": false}, ground_box, held, tables, snap, reach)
	_check.call(res["kind"] == "container" and res["container"] == ground_box and res["square"] == W,
			"drop target: a container under the pointer takes it")
	var floor_hit: Dictionary = at.call(S, Vector3(0.5, 0, 0.5), "floor")
	var far_box := ItemRef.on_square(_handle(snap, FAR, rock), box, FAR)
	_check.call(DropTarget.resolve(coords, floor_hit, far_box, held, tables, snap, reach)["kind"] == "surface"
			and DropTarget.resolve(coords, floor_hit, held, held, tables, snap, reach)["kind"] == "surface"
			and DropTarget.resolve(coords, floor_hit, ItemRef.on_square(5, rock, S), held, tables, snap, reach)["kind"] == "surface",
			"drop target: not a container out of reach, the held item itself, or a non-container")
	var worn := ItemRef.on_player(79, plastic, 0, -1, WORN, P)
	var inner := ItemRef.on_player(78, plastic, 77, 0, 0, P)
	_check.call(DropTarget.resolve(coords, floor_hit, worn, held, tables, snap, reach)["kind"] == "container"
			and DropTarget.resolve(coords, floor_hit, inner, held, tables, snap, reach)["kind"] == "surface",
			"drop target: a worn container takes it; one inside the held item doesn't")
