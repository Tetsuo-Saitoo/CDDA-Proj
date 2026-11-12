class_name ItemBodies
extends Node3D
## Block E2 slice 2 (item physics): the items lying near the player as Godot physics bodies. Each item handle
## (Snapshot.Submap.handles) on the centre's level within ACTIVE_R becomes a RigidBody3D: a box from its drawn bounds
## (the copy ItemVisual makes, as a hand holds it), mass from CDDA's weight (MIN_KG..MAX_KG), asleep at the pose its
## pile draws it in (WorldView.item_slot), its static copy hidden (WorldView.set_hidden_items_for, owner OWNER). The
## client owns only the pose within the square; CDDA owns the square and every rule, and nothing is sent to it here.
## - Caps: max_bodies in all, pile_bodies per square (nearest squares first, a pile in the snapshot's order; the
##   rest of a pile stays static).
## - Hysteresis: a body farther than ACTIVE_R + HYSTERESIS_M from the centre square, or fallen out of the levels
##   around it, is freed and its static copy shown again; past ACTIVE_R it is frozen (the collision ends there).
## - Snapshot changes: an item gone frees its body; one CDDA moved to another square is put down there on the floor
##   at its handle's spot (one whose type changed is made again where it is), its copy hidden throughout; where it
##   can't lie as a body (furniture, opening parts, another level) it shows static. Items hidden by someone else (a
##   hand holding it) or in flight (`held`) stay static.
## - Stay static: items on a square whose furniture has doors, drawers or lids (they ride those parts), items whose
##   middle lies inside the square's furniture box (racks, cupboards: WorldCollision.top_at) and items not drawn as
##   pointable (behind closed doors, glyph cards past the cap).
## Without WorldView.set_hidden_items_for (WorldView's owner sets) there are no bodies at all: an item must never show
## twice. A pass over the snapshot happens only when the handles near the centre (one native hash per nearby submap),
## the centre square, the hidden items or the caps change, and it publishes (re-meshes) at most once; each frame
## only checks the bodies' distance from the centre.
## Slice 5 (the hands use the bodies; Hands.bodies, ItemPicker.bodies): a body can be pointed at where it is now
## (on_ray / near / slot, the entries WorldView gives for drawn items; WorldView doesn't list hidden items). A hand
## that grabs one calls hold(): the body goes and none is made while the hand holds it (unhold() when it lets go).
## A hand letting go calls let_go(): a body at the hand's pose with the hand's velocity, waiting for CDDA's answer to
## the drop (landed(): kept, not made again at the pile's pose; forget(): gone, the item stays carried or shows static
## where it was). When such a body first comes to rest, `settled` says where (slices 3-4 will send that to CDDA).

## A body a hand let go came to rest for the first time: the square under it and where across it (spot, each
## 0..SPOT_MAX, x east, y south). Nothing is sent from here: the hook for slices 3-4 (drop where it settled).
signal settled(uid: int, square: Vector3i, spot: Vector2)

const OWNER := &"physics"
const HIDE_METHOD := &"set_hidden_items_for"
const ACTIVE_R := WorldCollision.ACTIVE_R
const HYSTERESIS_M := 2.0
const MAX_BODIES := 48         # WorldView keeps at most 64 hidden items per owner
const PILE_BODIES := 4
const MIN_KG := 0.05
const MAX_KG := 50.0
const UNKNOWN_KG := 1.0        # no id tables, or they don't match the snapshot
const MIN_BOX_M := 0.02
const MAX_BOX_M := 2.5
const INSIDE_M := 0.1          # an item whose middle is this far under its square's box top lies inside the furniture
const MAX_SCAN := 8192         # handles looked at per sync at most
const HS := Snapshot.HANDLE_STRIDE
const MAX_SPEED := 20.0        # m/s: a body let go moves at most this fast (VrRig drops tracking jumps past 30)
const PENDING_MS := 10000      # a body let go waits this long for CDDA's answer (ItemActions gives up after 5 s)
const MAX_HOLDING := 16        # items hands hold at once (three hands; more means someone forgot to unhold)
const SPOT_MAX := 0.999
const REST_UP_M := 0.05        # where a body rests is looked up this far over its origin (floor line rounding)
const FLOOR_UP_M := 0.002      # a body CDDA moved to another square is put down this far over its floor
const SORT_ORDER := 16384      # sync's sort key: distance² * SORT_ORDER + scan order (order <= MAX_SCAN)


class Body:
	var uid := 0
	var type := 0
	var square := Vector3i.ZERO   # CDDA's square: where the pile lay when made, or where CDDA's drop of a let-go goes
	var node: RigidBody3D
	var visual: Node3D            # the item's look inside the body (its transform carries the drawn size)
	var box := AABB()             # its collision box in the body's space
	var mid := Vector3.ZERO       # the box's middle in the body's space
	var size_m := 0.1             # the drawn size: the ball pointing meets (WorldView.item_hit_radius)
	var pending := false          # let go by a hand: not yet seen lying on `square` after CDDA's drop landed
	var landed := false           # CDDA's drop landed (landed()); pending until the world's snapshot shows it
	var since_ms := 0             # when it was let go
	var told := false             # `settled` was emitted for it


var world: WorldView
## Optional: items inside its furniture boxes stay static.
var collision: WorldCollision
## () -> Variant: the centre square (Vector3i), null for none. Default: the snapshot's player square.
var centre := Callable()
## () -> Dictionary: uids (-> true) carried in flight that must stay static (ItemActions.hidden). Optional.
var held := Callable()
## () -> int: the time in msec (tests); Time.get_ticks_msec() when not set.
var clock := Callable()
var max_bodies := MAX_BODIES
var pile_bodies := PILE_BODIES
## The WorldView method that hides items for an owner (tests point it at a missing one).
var hide_method: StringName = HIDE_METHOD
var syncs := 0                 # full passes over the snapshot (tests)
var skipped := 0               # new snapshots whose nearby handles were the same: no pass (tests)
var _bodies := {}              # uid -> Body
var _holding := {}             # uid -> true: a hand holds it (hold / unhold)
var _key := []
var _sig := 0                  # _near_sig of the last pass (0: none; a pass is due)
var _told_off := false


func _init(w: WorldView, c: WorldCollision = null) -> void:
	name = "ItemBodies"
	world = w
	collision = c
	w.coords.origin_shifted.connect(shift)


func _process(_delta: float) -> void:
	update()


## Leaving the scene: the bodies go with this node, the static copies show again (unless the world goes too).
func _exit_tree() -> void:
	for b: Body in _bodies.values():
		if is_instance_valid(b.node):
			b.node.queue_free()
	var had := not _bodies.is_empty()
	_bodies.clear()
	if had and is_instance_valid(world) and world.is_inside_tree() and not world.is_queued_for_deletion():
		_publish()


func count() -> int:
	return _bodies.size()


## The body standing in for item `uid`, null when it has none.
func body_of(uid: int) -> RigidBody3D:
	var b: Body = _bodies.get(uid)
	return b.node if b != null and is_instance_valid(b.node) else null


## CDDA's square of the item a body stands in for (when it was made), null when it has none.
func square_of(uid: int) -> Variant:
	var b: Body = _bodies.get(uid)
	return b.square if b != null else null


## Uids (-> true) that have a body.
func uids() -> Dictionary:
	var out := {}
	for u: int in _bodies:
		out[u] = true
	return out


## Whether item `uid`'s body was let go by a hand and waits for CDDA's answer to the drop.
func is_pending(uid: int) -> bool:
	var b: Body = _bodies.get(uid)
	return b != null and b.pending


## Whether a hand holds item `uid` (hold() without unhold() or let_go() yet).
func is_held(uid: int) -> bool:
	return _holding.has(uid)


# --- pointing (slice 5): bodies as WorldView's item entries ---

## The body a ray (normalized `dir`) meets first within `max_d`, among those whose CDDA square is one of the 3 x 3
## around `centre` (same level), as WorldView.items_on_ray gives a drawn item: [uid, itype, square, hit point, world
## transform (as drawn, scaled), size_m], or []. Hit as WorldView hits items: a ball around the box's middle where
## the body is now. Bodies let go and not answered by CDDA yet, and held ones, aren't pointable.
func on_ray(origin: Vector3, dir: Vector3, centre_sq: Vector3i, max_d: float) -> Array:
	if not origin.is_finite() or not dir.is_finite() or dir.length() < 0.001 or not (max_d > 0.0):
		return []
	dir = dir.normalized()
	var best: Array = []
	var best_t := max_d
	for b: Body in _bodies.values():
		if not _pointable(b, centre_sq):
			continue
		var c := _mid_of(b)
		var t := _ray_ball(origin, dir, c, WorldView.item_hit_radius(b.size_m))
		if t <= best_t and t < INF:
			best_t = t
			best = _entry(b, origin + dir * t)
	return best


## The body nearest `p` (its ball's surface; inside counts as nearer) within `radius`, among those on the 3 x 3
## squares around `centre` (CDDA's squares, same level): the entry as on_ray (the point: the ball's point nearest
## p), or [].
func near(p: Vector3, radius: float, centre_sq: Vector3i) -> Array:
	if not p.is_finite() or not (radius >= 0.0):
		return []
	var best: Array = []
	var best_d := radius
	for b: Body in _bodies.values():
		if not _pointable(b, centre_sq):
			continue
		var c := _mid_of(b)
		var r := WorldView.item_hit_radius(b.size_m)
		var d := p.distance_to(c) - r
		if d <= best_d:
			best_d = d
			best = _entry(b, c + (p - c).limit_length(r))
	return best


## Item `uid`'s body as WorldView.item_slot gives a drawn item (the point: the box's middle where the body is now),
## [] when it has no pointable body.
func slot(uid: int) -> Array:
	var b: Body = _bodies.get(uid)
	if b == null or b.pending or _holding.has(uid) or not is_instance_valid(b.node) or not b.node.is_inside_tree():
		return []
	var c := _mid_of(b)
	return _entry(b, c) if c.is_finite() else []


# --- hands (slice 5) ---

## A hand took item `uid` (lying in the world): its body goes now (the hand's copy starts where it was: ask slot()
## first) and none is made for it until unhold() or let_go(). Its static copy stays hidden by the hand meanwhile.
func hold(uid: int) -> void:
	if uid <= 0:
		return
	if not _holding.has(uid) and _holding.size() >= MAX_HOLDING:
		push_warning("item physics: more than %d held items, %d not kept as held" % [MAX_HOLDING, uid])
	else:
		_holding[uid] = true
	if _bodies.has(uid):
		_free(uid)
		_publish()


## The hand let item `uid` go without a body (put back, into a container, thrown by CDDA): it may get one again
## from its pile once it lies there.
func unhold(uid: int) -> void:
	_holding.erase(uid)


## A hand let go of item `uid` (itype `type`, drawn `size_m`, 0: from its type) where its copy was (`xform`, any
## scale) moving at `velocity` (world m/s, at most MAX_SPEED), while CDDA's drop to `square` goes out: a body there
## now, awake, waiting for CDDA's answer (landed() keeps it, forget() frees it; PENDING_MS without one frees it too).
## Null when none can be made (no snapshot, centre or owner sets, `square` off the centre's level or past ACTIVE_R,
## a square with parts that open, the total cap, a bad pose): the item then shows as before.
func let_go(uid: int, type: int, xform: Transform3D, velocity: Vector3, square: Vector3i, size_m := 0.0) -> RigidBody3D:
	_holding.erase(uid)
	var snap := world.snapshot
	var c: Variant = null
	if snap != null:
		c = centre.call() if centre.is_valid() else snap.player_pos
	if uid <= 0 or type <= 0 or snap == null or not c is Vector3i or not world.has_method(hide_method):
		return null
	var cv: Vector3i = c
	var d2 := (square.x - cv.x) * (square.x - cv.x) + (square.y - cv.y) * (square.y - cv.y)
	if square.z != cv.z or d2 > ACTIVE_R * ACTIVE_R or _part_squares().has(square):
		return null
	var had := _bodies.has(uid)
	if had:
		_free(uid)
	elif _bodies.size() >= max_bodies:
		return null
	var size := size_m if is_finite(size_m) and size_m > 0.0 else ItemVisual.size_of(type, world)
	var rb := _make(uid, type, square, xform, size)
	if rb == null:
		if had:
			_publish()
		return null
	var b: Body = _bodies[uid]
	b.pending = true
	b.since_ms = _now()
	rb.sleeping = false
	rb.linear_velocity = velocity.limit_length(MAX_SPEED) if velocity.is_finite() else Vector3.ZERO
	rb.sleeping_state_changed.connect(_on_sleep.bind(uid))
	_publish()
	return rb


## CDDA's drop of a let-go item landed: its body stays. It stays pending (not pointable) until the world's snapshot
## shows the item on its square (WorldView may show a snapshot a few frames after ItemActions judged it), then it is
## kept as any other body instead of being made again at the pile's pose. False when it has no body waiting.
func landed(uid: int) -> bool:
	var b: Body = _bodies.get(uid)
	if b == null or not b.pending:
		return false
	b.landed = true
	if _lies_on(uid, b.type, b.square):
		b.pending = false   # the world shows it there already
	_key = []
	return true


## Whether the world's snapshot lists item `uid` (itype `type`) lying on square sq.
func _lies_on(uid: int, type: int, sq: Vector3i) -> bool:
	var snap := world.snapshot
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(sq)) if snap != null else null
	return sm != null and ItemActions.handle_index(sm, ItemActions.tile_of(sq), uid, type) >= 0


## CDDA refused the drop of a let-go item, or nothing was sent: its body goes (the item stays carried, or shows
## static where it lies). False when it had no body waiting.
func forget(uid: int) -> bool:
	var b: Body = _bodies.get(uid)
	if b == null or not b.pending or b.landed:
		return false
	_free(uid)
	_resync()   # back where it lay (a refused take): a pass makes its body from the pile again
	_publish()
	return true


## Where item `uid`'s body lies now: {square, spot (each 0..SPOT_MAX, x east, y south)}, {} without a body.
func rest_of(uid: int) -> Dictionary:
	var b: Body = _bodies.get(uid)
	if b == null or not is_instance_valid(b.node) or not b.node.is_inside_tree():
		return {}
	var p := b.node.global_position
	if not p.is_finite():
		return {}
	var sq := world.coords.world_to_ms(p + Vector3(0.0, REST_UP_M, 0.0))
	var f := (p - world.coords.ms_to_world(sq)) / CddaCoords.TILE_M
	return {"square": sq, "spot": Vector2(clampf(f.x, 0.0, SPOT_MAX), clampf(f.z, 0.0, SPOT_MAX))}


## A full pass when the nearby handles, the centre, the hidden items or the caps changed; else only the distance
## checks. A new snapshot whose handles near the centre are the same (a cheap signature: one hash per nearby
## submap's handles) costs no pass.
func update() -> void:
	var snap := world.snapshot
	var c: Variant = null
	if snap != null:
		c = centre.call() if centre.is_valid() else snap.player_pos
	if snap == null or not c is Vector3i or not world.has_method(hide_method):
		if snap != null and not _told_off and not world.has_method(hide_method):
			_told_off = true
			print("item physics: off (WorldView has no %s)" % hide_method)
		if not _bodies.is_empty():
			clear()
		_key = []
		_sig = 0
		return
	_expire()
	var skip := _skip_set()
	var key := [snap.get_instance_id(), snap.seq, c, skip.hash()]
	if key != _key:
		var sig := _near_sig(snap, c, skip)
		if sig != _sig:
			_sig = sig
			sync(snap, c, skip)
		else:
			skipped += 1
	_key = [snap.get_instance_id(), snap.seq, c, _skip_set().hash()]
	_check_range(c)   # after the key: bodies it frees ask for a pass next time (_resync)


## The next update() makes a full pass (bodies went outside a pass: their items may need one from the pile).
func _resync() -> void:
	_sig = 0
	_key = []


## Frees every body and shows the static copies again.
func clear() -> void:
	_resync()
	if _bodies.is_empty():
		return
	for u: int in _bodies.keys():
		_free(u)
	_publish()


## Moves every body by `delta` (CddaCoords.origin_shifted); a sleeping one stays asleep.
func shift(delta: Vector3) -> void:
	for b: Body in _bodies.values():
		if is_instance_valid(b.node):
			var asleep := b.node.sleeping
			b.node.global_position += delta
			if asleep:
				b.node.sleeping = true


## Makes the bodies match snapshot `snap` around square c; `skip`: uids that must stay static. Publishes once at
## most (each publish re-meshes the submaps drawing a changed item, on the main thread). An item CDDA moved to
## another square (or changed into another itype) keeps its body, moved there (_follow), so its static copy stays
## hidden without a show / hide round trip; where it can't lie as a body it shows static.
func sync(snap: Snapshot, c: Vector3i, skip: Dictionary) -> void:
	syncs += 1
	var now := _handles_near(snap, c)   # uid -> [square, type, order, spot]
	var parts := _part_squares()
	var tops := {}                      # square -> its furniture box's top (WorldCollision.top_at), once per square
	var changed := false
	for u: int in _bodies.keys():
		var b: Body = _bodies[u]
		var n: Array = now.get(u, [])
		if not is_instance_valid(b.node) or _out_of_range(b, c):
			_free(u)
			changed = true
		elif b.pending:   # let go by a hand: carried (or still on the square it is taken from) until CDDA's drop lands
			if b.landed and n.size() > 1 and n[0] == b.square and n[1] == b.type:
				b.pending = false   # landed, and the world shows it there: this body stays
		elif n.is_empty() or skip.has(u):
			_free(u)
			changed = true
		elif (n[0] != b.square or n[1] != b.type) and not _follow(b, n, c, parts, tops):
			_free(u)   # CDDA moved it where it can't lie as a body: static there
			changed = true
	if _bodies.size() > max_bodies:
		_trim(c)
		changed = true
	var per_square := {}
	for b: Body in _bodies.values():
		per_square[b.square] = int(per_square.get(b.square, 0)) + 1
	var keys := PackedInt64Array()   # distance² * SORT_ORDER + order: nearest squares first, a pile in its order
	var by_key := {}
	for u: int in now:
		var n: Array = now[u]
		var sq: Vector3i = n[0]
		var d2 := (sq.x - c.x) * (sq.x - c.x) + (sq.y - c.y) * (sq.y - c.y)
		if sq.z != c.z or d2 > ACTIVE_R * ACTIVE_R or _bodies.has(u) or skip.has(u) or parts.has(sq):
			continue
		var k: int = d2 * SORT_ORDER + int(n[2])
		keys.append(k)
		by_key[k] = u
	keys.sort()
	for k: int in keys:
		if _bodies.size() >= max_bodies:
			break
		var u: int = by_key[k]
		var n: Array = now[u]
		var sq: Vector3i = n[0]
		if int(per_square.get(sq, 0)) >= pile_bodies:
			continue
		var slot := world.item_slot(u)
		if slot.size() < 6 or slot[2] != sq or not slot[4] is Transform3D or not slot[3] is Vector3 \
				or _inside(slot, sq, tops):
			continue
		var size: float = slot[5] if slot[5] is float else 0.0
		if _make(u, n[1], sq, slot[4], size) == null:
			continue
		per_square[sq] = int(per_square.get(sq, 0)) + 1
		changed = true
	if changed:
		_publish()


## CDDA moved item b to another square or changed it into another itype (n: its handle now). A new square on the
## centre's level within ACTIVE_R without opening parts or a furniture box: the body lies on its floor at the handle's
## spot (the middle without one), resting as it lay, asleep. Another itype: made again where it is. The uid stays
## hidden: nothing is re-meshed. False when it can't lie there as a body (the caller frees it: static there).
func _follow(b: Body, n: Array, c: Vector3i, parts: Dictionary, tops: Dictionary) -> bool:
	var sq: Vector3i = n[0]
	var type: int = n[1]
	var xf := b.node.global_transform
	var rot := xf.basis.orthonormalized()
	if not rot.is_finite():
		return false
	if sq != b.square:
		var d2 := (sq.x - c.x) * (sq.x - c.x) + (sq.y - c.y) * (sq.y - c.y)
		if sq.z != c.z or d2 > ACTIVE_R * ACTIVE_R or parts.has(sq) or _top(sq, tops) > 0.0:
			return false
		var spot: Vector2 = n[3]
		var f := spot if spot.x >= 0.0 and spot.y >= 0.0 else Vector2(0.5, 0.5)
		var on := world.coords.ms_to_world(sq) + Vector3(f.x * CddaCoords.TILE_M, 0.0, f.y * CddaCoords.TILE_M)
		var low := (Transform3D(rot, Vector3.ZERO) * b.box).position.y   # its lowest point under its origin
		xf = Transform3D(rot, on + Vector3(0.0, FLOOR_UP_M - low, 0.0))
	else:
		xf = Transform3D(rot, xf.origin)
	if not xf.is_finite():
		return false
	var uid := b.uid
	if type != b.type:
		_free(uid)
		return _make(uid, type, sq, xf, ItemVisual.size_of(type, world)) != null
	b.node.global_transform = xf
	b.node.linear_velocity = Vector3.ZERO
	b.node.angular_velocity = Vector3.ZERO
	b.node.sleeping = true
	b.square = sq
	return true


## Every frame: frees bodies past the hysteresis (shown static again) and freezes those past ACTIVE_R.
func _check_range(c: Vector3i) -> void:
	var gone := false
	for u: int in _bodies.keys():
		var b: Body = _bodies[u]
		if not is_instance_valid(b.node) or _out_of_range(b, c):
			_free(u)
			gone = true
			continue
		var far := _flat_distance(b.node.global_position, c) > ACTIVE_R
		if far != b.node.freeze:
			b.node.freeze = far
			if not far:
				b.node.sleeping = true   # thawed in place: it stays where it was until something moves it
	if gone:
		_resync()
		_publish()


func _out_of_range(b: Body, c: Vector3i) -> bool:
	if not is_instance_valid(b.node):
		return true
	var p := b.node.global_position
	if not p.is_finite():
		return true
	var lo := world.coords.ms_to_world(Vector3i(c.x, c.y, c.z - 1)).y - 1.0
	var hi := world.coords.ms_to_world(Vector3i(c.x, c.y, c.z + 2)).y
	return p.y < lo or p.y > hi or _flat_distance(p, c) > ACTIVE_R + HYSTERESIS_M


## Horizontal metres from the middle of square c to point p.
func _flat_distance(p: Vector3, c: Vector3i) -> float:
	var m := world.coords.ms_center_to_world(c)
	return Vector2(p.x - m.x, p.z - m.z).length()


## Frees the bodies farthest from c until max_bodies are left.
func _trim(c: Vector3i) -> void:
	var by_d := []
	for u: int in _bodies:
		var b: Body = _bodies[u]
		by_d.append([_flat_distance(b.node.global_position, c), u])
	by_d.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for e: Array in by_d:
		if _bodies.size() <= max_bodies:
			break
		_free(e[1])


## The item handles within the hysteresis of c: uid -> [square, type, order, spot (Vector2 0..0.999, -1 none)]
## (order: the handle's place in the scan, so a pile keeps its order). The centre's level first, then the levels
## below and above (only items that have a body there: one fallen down a level), each nearest submap first, so a
## crowded basement can't use up MAX_SCAN before the player's level. On the centre's level at most pile_bodies new
## items per square are kept (more could never get a body), plus every item that has one. A uid listed twice
## counts once.
func _handles_near(snap: Snapshot, c: Vector3i) -> Dictionary:
	var out := {}
	var r := ceili(ACTIVE_R + HYSTERESIS_M) + 1
	var subs := _subs_near(c, r)
	var per_sq := {}   # square -> new items kept there
	var order := 0
	for z: int in [c.z, c.z - 1, c.z + 1]:
		for s: Vector2i in subs:
			var sm: Snapshot.Submap = snap.submaps.get(Vector3i(s.x, s.y, z))
			if sm == null:
				continue
			var base := CddaCoords.sm_to_ms(sm.pos)
			var hs := sm.handles
			for k in range(0, hs.size() - HS + 1, HS):
				order += 1
				if order > MAX_SCAN:
					return out
				var uid := int(hs[k + 1])
				var has := _bodies.has(uid)
				if z != c.z and not has:
					continue
				var tile := int(hs[k])
				var type := int(hs[k + 2])
				if tile < 0 or tile >= Snapshot.TILES or uid <= 0 or type <= 0 or out.has(uid):
					continue
				var sq := base + Vector3i(tile % CddaCoords.SEEX, tile / CddaCoords.SEEX, 0)
				if absi(sq.x - c.x) > r or absi(sq.y - c.y) > r:
					continue
				if not has:
					var kept: int = per_sq.get(sq, 0)
					if kept >= pile_bodies:
						continue
					per_sq[sq] = kept + 1
				out[uid] = [sq, type, order, _spot(int(hs[k + 3]), int(hs[k + 4]))]
	return out


## The submaps (x, y) within r squares of c, nearest first (by their middles).
static func _subs_near(c: Vector3i, r: int) -> Array[Vector2i]:
	var lo := CddaCoords.ms_to_sm(Vector3i(c.x - r, c.y - r, 0))
	var hi := CddaCoords.ms_to_sm(Vector3i(c.x + r, c.y + r, 0))
	var by_d := {}   # distance² -> [Vector2i]
	var ds := PackedInt64Array()
	for sy in range(lo.y, hi.y + 1):
		for sx in range(lo.x, hi.x + 1):
			var m := CddaCoords.sm_to_ms(Vector3i(sx, sy, 0)) + Vector3i(CddaCoords.SEEX / 2, CddaCoords.SEEX / 2, 0)
			var d2 := (m.x - c.x) * (m.x - c.x) + (m.y - c.y) * (m.y - c.y)
			if not by_d.has(d2):
				by_d[d2] = []
				ds.append(d2)
			(by_d[d2] as Array).append(Vector2i(sx, sy))
	ds.sort()
	var out: Array[Vector2i] = []
	for d2: int in ds:
		for s: Vector2i in by_d[d2]:
			out.append(s)
	return out


## A cheap signature of what a sync depends on: the centre, the uids kept static, the caps, the opening parts and
## one hash per nearby submap's handles (Snapshot's packed arrays hash in native code).
func _near_sig(snap: Snapshot, c: Vector3i, skip: Dictionary) -> int:
	var r := ceili(ACTIVE_R + HYSTERESIS_M) + 1
	var parts := [c, skip.hash(), max_bodies, pile_bodies, world.parts.size()]
	for s: Vector2i in _subs_near(c, r):
		for z: int in [c.z, c.z - 1, c.z + 1]:
			var sm: Snapshot.Submap = snap.submaps.get(Vector3i(s.x, s.y, z))
			parts.append(hash(sm.handles) if sm != null else 0)
	var h := parts.hash()
	return h if h != 0 else 1   # 0 means "no pass yet"


## A handle's spot (permille each, -1 none) as 0..SPOT_MAX across the square, (-1, -1) for none or out of range.
static func _spot(x: int, y: int) -> Vector2:
	if x < 0 or y < 0 or x > 999 or y > 999:
		return Vector2(-1, -1)
	return Vector2(minf(x / 1000.0, SPOT_MAX), minf(y / 1000.0, SPOT_MAX))


## Uids that must stay static: held by a hand (hold), hidden by another owner (a hand holds it) or in flight (`held`).
func _skip_set() -> Dictionary:
	var out := _holding.duplicate()
	for u: Variant in world.hidden_items:
		if u is int and not _bodies.has(u):
			out[u] = true
	if held.is_valid():
		var h: Variant = held.call()
		if h is Dictionary:
			for u: Variant in h:
				if u is int:
					out[u] = true
	return out


## Squares whose furniture has parts that open (items there ride them).
func _part_squares() -> Dictionary:
	var out := {}
	for g: Variant in world.parts.values():
		if is_instance_valid(g) and g is Grabbable:
			out[(g as Grabbable).square] = true
	return out


## Whether the item drawn at `slot` lies inside the furniture box of square sq (a shelf of a rack, a cupboard).
func _inside(slot: Array, sq: Vector3i, tops: Dictionary) -> bool:
	var top := _top(sq, tops)
	if top <= 0.0:
		return false
	var mid: Vector3 = slot[3]
	return mid.y - world.coords.ms_to_world(sq).y < top - INSIDE_M


## The top of square sq's furniture box over its floor (WorldCollision.top_at; 0: none or no collision), looked up
## once per square and sync in `tops`.
func _top(sq: Vector3i, tops: Dictionary) -> float:
	if collision == null:
		return 0.0
	if not tops.has(sq):
		tops[sq] = collision.top_at(sq)
	return tops[sq]


## A body for item `uid` (type, CDDA square) at `xf` (as WorldView.item_slot draws it, or a hand's copy: its scale is
## dropped), drawn `size_m` across; null when it can't be.
func _make(uid: int, type: int, sq: Vector3i, xf: Transform3D, size_m: float) -> RigidBody3D:
	if not xf.is_finite() or is_zero_approx(xf.basis.determinant()):
		return null
	var rot := xf.basis.orthonormalized()
	if not rot.is_finite():
		return null
	var visual := ItemVisual.make(type, world)
	var box := _bounds(visual, type)
	var rb := RigidBody3D.new()
	rb.name = "Item_%d" % uid
	rb.collision_layer = WorldCollision.LAYER_ITEMS
	rb.collision_mask = WorldCollision.LAYER_WORLD | WorldCollision.LAYER_ITEMS
	rb.mass = mass_of(type)
	rb.continuous_cd = true
	rb.can_sleep = true
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	cs.shape = shape
	cs.position = box.get_center()
	rb.add_child(cs)
	rb.add_child(visual)
	rb.transform = Transform3D(rot, xf.origin)
	add_child(rb)
	rb.sleeping = true   # after it entered the space: placing a body wakes it
	var b := Body.new()
	b.uid = uid
	b.type = type
	b.square = sq
	b.node = rb
	b.visual = visual
	b.box = box
	b.mid = box.get_center()
	b.size_m = clampf(size_m, MIN_BOX_M, MAX_BOX_M) if is_finite(size_m) and size_m > 0.0 else box.get_longest_axis_size()
	_bodies[uid] = b
	return rb


## The box of the copy `visual` (ItemVisual.make: its meshes, at its scale) in its body's space, every side within
## MIN_BOX_M..MAX_BOX_M; a cube of the item's size when it has no meshes.
func _bounds(visual: Node3D, type: int) -> AABB:
	var box := AABB()
	var first := true
	for ch: Node in visual.get_children():
		var mi := ch as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a := mi.transform * mi.mesh.get_aabb()
		box = a if first else box.merge(a)
		first = false
	var s := visual.scale.x
	if first or not box.position.is_finite() or not box.size.is_finite() or not is_finite(s) or s <= 0.0:
		var size := ItemVisual.size_of(type, world)
		size = clampf(size, MIN_BOX_M, MAX_BOX_M) if is_finite(size) else MIN_BOX_M   # as the mesh path
		return AABB(Vector3(-size * 0.5, 0.0, -size * 0.5), Vector3.ONE * size)
	box = AABB(box.position * s, box.size * s).abs()
	var size := box.size.clamp(Vector3.ONE * MIN_BOX_M, Vector3.ONE * MAX_BOX_M)
	var mid := box.get_center().clamp(-Vector3.ONE * MAX_BOX_M, Vector3.ONE * MAX_BOX_M)
	return AABB(mid - size * 0.5, size)


## CDDA's weight of item type `type` in kg, MIN_KG..MAX_KG (UNKNOWN_KG without matching id tables).
func mass_of(type: int) -> float:
	var t := world.tables
	var snap := world.snapshot
	if t == null or snap == null or (snap.ids_generation >= 0 and snap.ids_generation != t.generation):
		return UNKNOWN_KG
	var d := t.def_at("itype", type)
	if d == null:
		return UNKNOWN_KG
	return clampf(d.weight_g / 1000.0, MIN_KG, MAX_KG)


func _free(uid: int) -> void:
	var b: Body = _bodies.get(uid)
	_bodies.erase(uid)
	if b != null and is_instance_valid(b.node):
		if b.node.get_parent() == self:
			remove_child(b.node)
		b.node.queue_free()


## Tells the world which static copies the bodies stand in for.
func _publish() -> void:
	if is_instance_valid(world) and world.has_method(hide_method):
		world.call(hide_method, OWNER, uids())


## Frees the bodies let go whose drop CDDA didn't answer within PENDING_MS (or the world never showed landed).
func _expire() -> void:
	var now := _now()
	var gone := false
	for u: int in _bodies.keys():
		var b: Body = _bodies[u]
		if b.pending and now - b.since_ms >= PENDING_MS:
			_free(u)
			gone = true
	if gone:
		_resync()   # the item may lie in reach: a pass makes its body from the pile again
		_publish()


## A body a hand let go fell asleep: the first time, `settled` says where it lies.
func _on_sleep(uid: int) -> void:
	var b: Body = _bodies.get(uid)
	if b == null or b.told or not is_instance_valid(b.node) or not b.node.sleeping:
		return
	var r := rest_of(uid)
	if r.is_empty():
		return
	b.told = true
	settled.emit(uid, r["square"], r["spot"])


## Pointable from `c`: settled (not let go and waiting), not held, in the tree, its CDDA square one of the 3 x 3 around
## c on c's level (CDDA's reach rule; the sim checks it again).
func _pointable(b: Body, c: Vector3i) -> bool:
	if b.pending or _holding.has(b.uid) or not is_instance_valid(b.node) or not b.node.is_inside_tree():
		return false
	var d := b.square - c
	return d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1


## The middle of a body's box, world.
func _mid_of(b: Body) -> Vector3:
	return b.node.global_transform * b.mid


## WorldView's item entry for a body: [uid, itype, CDDA square, point, world transform as drawn (scaled), size_m].
func _entry(b: Body, point: Vector3) -> Array:
	var xf := b.node.global_transform
	if is_instance_valid(b.visual) and b.visual.get_parent() == b.node:
		xf = xf * b.visual.transform
	return [b.uid, b.type, b.square, point, xf, b.size_m]


## Distance along a ray (normalized `d`) to a ball: 0 from inside it, INF when it misses or lies behind.
static func _ray_ball(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := c - o
	var t := oc.dot(d)
	var miss := oc.length_squared() - t * t - r * r
	if miss > 0.0:
		return INF
	var th := sqrt(-miss)
	if t + th < 0.0:
		return INF
	return maxf(t - th, 0.0)


func _now() -> int:
	if clock.is_valid():
		var t: Variant = clock.call()
		if t is int:
			return t
	return Time.get_ticks_msec()
