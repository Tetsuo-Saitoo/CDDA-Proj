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
## - Snapshot changes: an item gone frees its body; one CDDA moved to another square (or whose type changed) is made
##   again at its new pose; items hidden by someone else (a hand holding it) or in flight (`held`) stay static.
## - Stay static: items on a square whose furniture has doors, drawers or lids (they ride those parts), items whose
##   middle lies inside the square's furniture box (racks, cupboards: WorldCollision.top_at) and items not drawn as
##   pointable (behind closed doors, glyph cards past the cap).
## Without WorldView.set_hidden_items_for (WorldView's owner sets) there are no bodies at all: an item must never show
## twice. Work happens only when the snapshot, the centre square or the hidden items change; each frame only checks
## the bodies' distance from the centre.

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


class Body:
	var uid := 0
	var type := 0
	var square := Vector3i.ZERO   # CDDA's square when the body was made
	var node: RigidBody3D


var world: WorldView
## Optional: items inside its furniture boxes stay static.
var collision: WorldCollision
## () -> Variant: the centre square (Vector3i), null for none. Default: the snapshot's player square.
var centre := Callable()
## () -> Dictionary: uids (-> true) carried in flight that must stay static (ItemActions.hidden). Optional.
var held := Callable()
var max_bodies := MAX_BODIES
var pile_bodies := PILE_BODIES
## The WorldView method that hides items for an owner (tests point it at a missing one).
var hide_method: StringName = HIDE_METHOD
var syncs := 0                 # full passes over the snapshot (tests)
var _bodies := {}              # uid -> Body
var _key := []
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


## A full pass when the snapshot, the centre or the hidden items changed; else only the distance checks.
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
		return
	var skip := _skip_set()
	var key := [snap.get_instance_id(), snap.seq, c, skip.hash()]
	if key != _key:
		sync(snap, c, skip)
	_check_range(c)
	_key = [snap.get_instance_id(), snap.seq, c, _skip_set().hash()]


## Frees every body and shows the static copies again.
func clear() -> void:
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


## Makes the bodies match snapshot `snap` around square c; `skip`: uids that must stay static.
func sync(snap: Snapshot, c: Vector3i, skip: Dictionary) -> void:
	syncs += 1
	var now := _handles_near(snap, c)   # uid -> [square, type, order]
	var moved := false
	var dropped := false
	for u: int in _bodies.keys():
		var b: Body = _bodies[u]
		var n: Array = now.get(u, [])
		if n.is_empty() or skip.has(u) or not is_instance_valid(b.node) or _out_of_range(b, c):
			_free(u)
			dropped = true
		elif n[0] != b.square or n[1] != b.type:
			_free(u)   # CDDA moved it: shown again first, so its new pose is drawn, then made again below
			moved = true
	if _bodies.size() > max_bodies:
		_trim(c)
		dropped = true
	if moved:
		_publish()
	var per_square := {}
	for b: Body in _bodies.values():
		per_square[b.square] = int(per_square.get(b.square, 0)) + 1
	var parts := _part_squares()
	var cands := []   # [distance², order, uid, type, square]
	for u: int in now:
		var n: Array = now[u]
		var sq: Vector3i = n[0]
		var d2 := (sq.x - c.x) * (sq.x - c.x) + (sq.y - c.y) * (sq.y - c.y)
		if sq.z != c.z or d2 > ACTIVE_R * ACTIVE_R or _bodies.has(u) or skip.has(u) or parts.has(sq):
			continue
		cands.append([d2, n[2], u, n[1], sq])
	cands.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	var added := false
	for e: Array in cands:
		if _bodies.size() >= max_bodies:
			break
		var sq: Vector3i = e[4]
		if int(per_square.get(sq, 0)) >= pile_bodies:
			continue
		var slot := world.item_slot(e[2])
		if slot.is_empty() or slot[2] != sq or _inside(slot, sq):
			continue
		if _make(e[2], e[3], sq, slot) == null:
			continue
		per_square[sq] = int(per_square.get(sq, 0)) + 1
		added = true
	if added or dropped or moved:
		_publish()


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


## The item handles on the levels c.z - 1 .. c.z + 1 within the hysteresis of c: uid -> [square, type, order]
## (order: the handle's place in the snapshot, so a pile keeps its order). A uid listed twice counts once.
func _handles_near(snap: Snapshot, c: Vector3i) -> Dictionary:
	var out := {}
	var r := ceili(ACTIVE_R + HYSTERESIS_M) + 1
	var lo := CddaCoords.ms_to_sm(Vector3i(c.x - r, c.y - r, 0))
	var hi := CddaCoords.ms_to_sm(Vector3i(c.x + r, c.y + r, 0))
	var order := 0
	for z in range(c.z - 1, c.z + 2):
		for sy in range(lo.y, hi.y + 1):
			for sx in range(lo.x, hi.x + 1):
				var sm: Snapshot.Submap = snap.submaps.get(Vector3i(sx, sy, z))
				if sm == null:
					continue
				var base := CddaCoords.sm_to_ms(sm.pos)
				var hs := sm.handles
				for k in range(0, hs.size() - HS + 1, HS):
					order += 1
					if order > MAX_SCAN:
						return out
					var tile := int(hs[k])
					var uid := int(hs[k + 1])
					var type := int(hs[k + 2])
					if tile < 0 or tile >= Snapshot.TILES or uid <= 0 or type <= 0 or out.has(uid):
						continue
					var sq := base + Vector3i(tile % CddaCoords.SEEX, tile / CddaCoords.SEEX, 0)
					if absi(sq.x - c.x) > r or absi(sq.y - c.y) > r:
						continue
					out[uid] = [sq, type, order]
	return out


## Uids that must stay static: hidden by another owner (a hand holds it) or in flight (`held`).
func _skip_set() -> Dictionary:
	var out := {}
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
func _inside(slot: Array, sq: Vector3i) -> bool:
	if collision == null:
		return false
	var top := collision.top_at(sq)
	if top <= 0.0:
		return false
	var mid: Vector3 = slot[3]
	return mid.y - world.coords.ms_to_world(sq).y < top - INSIDE_M


## A body for item `uid` (type, CDDA square) where `slot` (WorldView.item_slot) draws it; null when it can't be.
func _make(uid: int, type: int, sq: Vector3i, slot: Array) -> RigidBody3D:
	var xf: Transform3D = slot[4]
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
		return AABB(Vector3(-size * 0.5, 0.0, -size * 0.5), Vector3.ONE * size).abs()
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
