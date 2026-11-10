class_name ItemPicker
extends RefCounted
## Blocks E6 / L2 / L8: which single item on the ground the player points at (a crosshair's ray) or holds a
## hand on (VR), and ItemRefs for what the player carries, from the newest snapshot and the item slots
## WorldView draws. Only items on squares the player reaches count (the bridge's rule: the reach square and
## the 8 around it, same level); walls hide items behind them. Nothing here decides anything: the sim checks
## every action on an ItemRef again. No snapshot: null and [] everywhere.

const RAY_M := 4.0
const NEAR_M := 0.15
## Past the first thing the ray meets an item still counts (one lying right at it). Furniture: past the far
## side of its square, as LookRay meets furniture as a 1 m block where the ray enters it, above the items
## lying on it.
const PAST_M := 0.3

var world: WorldView
var look_ray: LookRay
## () -> Variant: the square the player reaches from (Vector3i), or null for none. Not set: the player's square.
var reach: Callable


func _init(w: WorldView) -> void:
	world = w
	look_ray = LookRay.new(w)


## The item a ray (from `origin` along `dir`) meets first within `max_d`, or null.
func on_ray(origin: Vector3, dir: Vector3, max_d := RAY_M) -> ItemRef:
	var c: Variant = _centre()
	if c == null or dir.length() < 0.001 or not (max_d > 0.0):
		return null
	dir = dir.normalized()
	var limit := max_d
	var r := look_ray.cast(origin, dir, max_d, false)
	if r["hit"]:
		limit = minf(max_d, _past(origin, dir, r))
	return _ref(world.items_on_ray(origin, dir, c, limit))


## The item nearest point `p` (a hand) within `radius`, or null.
func near(p: Vector3, radius := NEAR_M) -> ItemRef:
	var c: Variant = _centre()
	if c == null:
		return null
	return _ref(world.items_near(p, maxf(radius, 0.0), c))


## Whether an item on `square` is in reach: the reach square or one of the 8 around it, same level.
func in_reach(square: Vector3i) -> bool:
	var c: Variant = _centre()
	if c == null:
		return false
	var d: Vector3i = square - (c as Vector3i)
	return d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1


## Everything the player carries (Snapshot.carried, containers before their contents).
func carried() -> Array[ItemRef]:
	var out: Array[ItemRef] = []
	var snap := _snap()
	if snap == null:
		return out
	var c := snap.carried
	for k in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		out.append(ItemRef.on_player(c[k], int(c[k + 1]), c[k + 2], int(c[k + 3]), int(c[k + 4]), snap.player_pos))
	return out


## The carried items directly inside `container_uid` (0: the ones on the body).
func contents(container_uid: int) -> Array[ItemRef]:
	var out: Array[ItemRef] = []
	for r in carried():
		if r.parent == container_uid:
			out.append(r)
	return out


## Worn items that hold things, outermost first (backpack before shirt pockets): the body slots VR puts items
## into and the Tab view lists. Until the bridge sends pockets per itype, "holds things" = a container by
## category (MockItems.is_container) or something carried inside it now; an empty backpack isn't known yet.
func worn_containers() -> Array[ItemRef]:
	var all := carried()
	var has_contents := {}
	for r in all:
		has_contents[r.parent] = true
	var out: Array[ItemRef] = []
	var tables := world.tables if world != null else null
	for r in all:
		if r.is_worn() and r.parent == 0 and (has_contents.has(r.uid) or MockItems.is_container(r.type, tables)):
			out.push_front(r)   # CDDA lists worn items inner to outer
	return out


## Item `uid`: carried, or on the ground in the snapshot's handles (drawn: point and size from its slot); null.
func by_uid(uid: int) -> ItemRef:
	var snap := _snap()
	if snap == null or uid <= 0:
		return null
	for r in carried():
		if r.uid == uid:
			return r
	for pos: Vector3i in snap.submaps:
		var hs := (snap.submaps[pos] as Snapshot.Submap).handles
		for k in range(0, hs.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
			if hs[k + 1] != uid:
				continue
			var tile := int(hs[k])
			var sq := CddaCoords.sm_to_ms(pos) + Vector3i(tile % CddaCoords.SEEX, tile / CddaCoords.SEEX, 0)
			var r := ItemRef.on_square(uid, int(hs[k + 2]), sq, int(hs[k + 3]), int(hs[k + 4]))
			var s := world.item_slot(uid)
			if not s.is_empty() and s[1] == r.type and s[2] == sq:
				r.point = s[3]
				r.size_m = s[5]
			return r
	return null


func _snap() -> Snapshot:
	return world.snapshot if world != null else null


## The square reach is measured from, or null.
func _centre() -> Variant:
	if _snap() == null:
		return null
	if not reach.is_valid():
		return world.snapshot.player_pos
	var c: Variant = reach.call()
	return c if c is Vector3i else null


## How far along the ray items still count, given what LookRay met (see PAST_M).
func _past(origin: Vector3, dir: Vector3, hit: Dictionary) -> float:
	var t := origin.distance_to(hit["point"])
	if hit["what"] == "furniture":
		var lo := world.coords.ms_to_world(hit["square"])
		t = maxf(t, _exit(origin, dir, lo, lo + Vector3(CddaCoords.TILE_M, 0, CddaCoords.TILE_M)))
	return t + PAST_M


## Where a ray leaves the column over a square (x and z between lo and hi), INF for a vertical ray.
static func _exit(o: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> float:
	var t := INF
	for a: int in [Vector3.AXIS_X, Vector3.AXIS_Z]:
		if absf(d[a]) > 1e-6:
			t = minf(t, ((hi[a] if d[a] > 0.0 else lo[a]) - o[a]) / d[a])
	return t


## An ItemRef for an entry of WorldView.items_on_ray / items_near (spot from the snapshot's handle), or null.
func _ref(hit: Array) -> ItemRef:
	if hit.is_empty():
		return null
	var uid: int = hit[0]
	var sq: Vector3i = hit[2]
	var spot := _spot(uid, sq)
	var r := ItemRef.on_square(uid, hit[1], sq, spot.x, spot.y)
	r.point = hit[3]
	r.size_m = hit[5]
	return r


## The handle's spot (permille, -1 none) of item `uid` on square `sq` in the snapshot.
func _spot(uid: int, sq: Vector3i) -> Vector2i:
	var sm: Snapshot.Submap = _snap().submaps.get(CddaCoords.ms_to_sm(sq))
	if sm != null:
		var hs := sm.handles
		for k in range(0, hs.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
			if hs[k + 1] == uid:
				return Vector2i(int(hs[k + 3]), int(hs[k + 4]))
	return Vector2i(-1, -1)
