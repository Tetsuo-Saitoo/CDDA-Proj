class_name Hands
extends Node
## Blocks E6 / L2 / L8: the player's hands, device-free. A hand ("mouse" for the crosshair, "vr_l" / "vr_r" for
## the controllers) points at or reaches for a target, grabs it and lets it go somewhere. Targets are door leaves
## (Grabbable, dragged as before) and single items (ItemRef by snapshot handle). Every item move is one or two
## one-item CDDA actions through ItemActions (take, then put / drop); CDDA's time, volume and weight rules decide,
## and a refusal brings the item back with CDDA's reason. Flat-screen input lives in ui/GrabController, VR input in
## vr/VrRig; both only feed this.
## E2 item physics (`bodies` set, main.gd): items lying as physics bodies are pointed at and grabbed where their bodies
## are now (ItemPicker asks ItemBodies); a grabbed body goes while the hand holds it; letting go with a velocity
## onto a surface, or onto bare floor at all, makes a body at the copy's pose with that velocity, while CDDA's drop
## goes out exactly as without it (same square and spot). hand_over() moves an item from one hand to the other (CDDA's
## hand change for a carried one).
## Always (with or without bodies): a held container that may hold something stays upright, its yaw following the
## hand (held containers never tip or spill, PLAN L2).
##
## A target is a Dictionary: {kind: "door" | "item", node: Grabbable (doors) or null, item: ItemRef (items) or null,
## square: Vector3i, point: Vector3 (world), dist: float, name: String}; {} for none.

## The hover outline changed for a hand ({} = nothing under it any more).
signal highlighted(hand: String, target: Dictionary)
## An item action the hand started went through (the snapshot shows the item moved).
signal confirmed(hand: String, target: Dictionary)
## CDDA said no (or didn't answer): `reason` is its message. The item is back where it was.
signal refused(hand: String, target: Dictionary, reason: String)

const RAY_M := 4.0
const THROW_SPEED := 4.0    # m/s at release: a throw (VR's release doesn't use it yet; throw() does the throwing)
const OUTLINE := Color(1.0, 0.85, 0.3)

var world: WorldView
var picker: ItemPicker
var actions: ItemActions
var look_ray: LookRay
## (type: int, size_m: float, world: WorldView) -> Node3D: what a hand carries. Default: a box of the item's size.
var proxy_factory := Callable()
## The second step of a move (put / drop after its take) runs on the next frame, outside ItemActions' signal;
## tests turn it off to run it at once.
var defer_steps := true
## E2 item physics (optional, main.gd): the items lying near the player as physics bodies. Set: bodies are pointed at
## and grabbed where they are, and letting go may make a body (release). Null: everything as before.
var bodies: ItemBodies:
	set(b):
		bodies = b
		if picker != null:
			picker.bodies = b

var _hands := {}           # id -> Hand
var _held_hidden := {}     # uid -> true: items a hand holds right now (hidden in their pile)
var _pending_hidden := {}  # uid -> true: items in flight (ItemActions.hidden_changed)
var _owner := {}           # uid -> hand id that started the action
var _then := {}            # uid -> Callable(item: ItemRef) -> bool: second step after a take finishes
var _handing := {}         # uid -> hand id it was handed over from while CDDA's hand change is in flight
var _sent_hidden := {}     # the set last given to world.set_hidden_items (the hands' owner set)

static var _outline_mat: StandardMaterial3D
static var _box_mesh: BoxMesh


class Hand:
	var id := ""
	var xform := Transform3D.IDENTITY
	var hover := {}
	var held := {}
	var proxy: Node3D
	var outline: MeshInstance3D
	var upright_key := []   # what `upright` was worked out for (item, carried, snapshot)
	var upright := false    # the held copy is kept upright (a container that may hold something)


func _init(w: WorldView, a: ItemActions) -> void:
	name = "Hands"
	world = w
	actions = a
	picker = ItemPicker.new(w)
	look_ray = LookRay.new(w)
	a.hidden_changed.connect(_on_pending_hidden)
	a.finished.connect(_on_finished)
	a.refused.connect(_on_refused)


func _exit_tree() -> void:
	for h: Hand in _hands.values():
		_free_visuals(h)


func hand(id: String) -> Hand:
	if not _hands.has(id):
		var h := Hand.new()
		h.id = id
		_hands[id] = h
	return _hands[id]


## The square the hands reach from (the picker's; the player's by default), or null without a snapshot.
func reach_square() -> Variant:
	if picker.reach.is_valid():
		return picker.reach.call()
	return world.snapshot.player_pos if world.snapshot != null else null


## The nearest door leaf or item a ray meets within reach (the crosshair, a VR pointer); {} if none.
func find_on_ray(origin: Vector3, dir: Vector3, max_m := RAY_M) -> Dictionary:
	var centre: Variant = reach_square()
	if centre == null:
		return {}
	var best := {}
	var r := look_ray.cast(origin, dir, max_m, false)
	var limit := max_m
	if r["hit"]:   # nothing behind the first wall; a closed door's leaf stands inside its square
		limit = minf(max_m, origin.distance_to(r["point"]) + (1.5 if r["what"] == "door" else 0.3))
	var d := world.grabbable_on_ray(origin, dir, centre, limit)
	if not d.is_empty():
		best = _door_target(d[0], d[1], origin.distance_to(d[1]))
	var it := picker.on_ray(origin, dir, max_m)
	if it != null and _usable(it):
		var dist := origin.distance_to(it.point)
		if best.is_empty() or dist < float(best["dist"]):
			best = _item_target(it, dist)
	return best


## The nearest door leaf or item within `radius` of a point (a VR hand); {} if none.
func find_near(pos: Vector3, radius := 0.15) -> Dictionary:
	var best := {}
	var g := world.grabbable_near(pos, radius, picker.in_reach)
	if g != null:
		best = _door_target(g, pos, g.distance_to(pos))
	var it := picker.near(pos, radius)
	if it != null and _usable(it):
		var dist := pos.distance_to(it.point)
		if best.is_empty() or dist < float(best["dist"]):
			best = _item_target(it, dist)
	return best


## Where a hand is (VR: the controller; mouse: the carry point in front of the camera). Moves what it holds.
func set_hand(id: String, xform: Transform3D) -> void:
	set_hand_pose(id, xform, false)


## The same; `turn`: what it holds follows the whole hand (VR), held by its grip point (ItemVisual.grip), not only
## its position (mouse: it keeps its own turn, see turn_held).
func set_hand_pose(id: String, xform: Transform3D, turn: bool) -> void:
	var h := hand(id)
	_forget_freed(h)
	h.xform = xform
	if h.proxy == null or not is_instance_valid(h.proxy):
		return
	if not turn:
		h.proxy.global_transform = Transform3D(h.proxy.global_basis, xform.origin)
		return
	var it: ItemRef = h.held.get("item")
	var g := ItemVisual.grip(it.type, world) if it != null else Transform3D.IDENTITY
	var b := xform.basis.orthonormalized() * g.basis.inverse()
	if _keeps_upright(h):
		b = upright(b)   # a container that may hold something hangs from the grip, only turning with the hand
	h.proxy.global_transform = Transform3D(b.scaled(h.proxy.scale), xform.origin - b * g.origin)


## Turns what a hand holds about the up axis (mouse wheel with Shift).
func turn_held(id: String, radians: float) -> void:
	var h := hand(id)
	if h.proxy != null and is_instance_valid(h.proxy):
		h.proxy.global_basis = Basis(Vector3.UP, radians) * h.proxy.global_basis


## Places what a hand holds directly (VR's weight lag): `xform` without scale, the copy keeps its item's size. A
## container kept upright turns only about the up axis, around its grip point.
func set_proxy_pose(id: String, xform: Transform3D) -> void:
	var h: Hand = _hands.get(id)
	if h == null or h.proxy == null or not is_instance_valid(h.proxy):
		return
	var b := xform.basis.orthonormalized()
	var o := xform.origin
	if _keeps_upright(h):
		var it: ItemRef = h.held.get("item")
		var g := ItemVisual.grip(it.type, world).origin if it != null else Vector3.ZERO
		var up := upright(b)
		o = xform.origin + b * g - up * g   # the grip point stays where it was
		b = up
	h.proxy.global_transform = Transform3D(b.scaled(h.proxy.scale), o)


## The target under a hand now ({} for none; a door leaf freed since is forgotten).
func hovered(id: String) -> Dictionary:
	if not _hands.has(id):
		return {}
	var h: Hand = _hands[id]
	_forget_freed(h)
	return h.hover


## The target under a hand changed: outline it (and drop the old outline).
func hover(id: String, target: Dictionary) -> void:
	var h := hand(id)
	_forget_freed(h)
	if same_target(h.hover, target):
		if not target.is_empty() and target["kind"] == "item":
			h.hover = target   # follow the newest point
		return
	_light(h, h.hover, false)
	h.hover = target
	_light(h, target, true)
	highlighted.emit(id, target)


## Grabs a target: a door leaf follows the hand (mouse: Grabbable.drag_mouse from the caller); an item leaves its
## pile and a proxy follows the hand until release(). False when there is nothing to grab or the item is busy.
## A carried item works too (one CDDA already has in a hand: adopt()). `take_into` ("main" / "off" / "pack", VR)
## takes an item lying in the world at once, so it is carried while you walk; refused -> the proxy goes and
## `refused` fires. Without it (mouse) the take waits for release().
func grab(id: String, target: Dictionary, take_into := "") -> bool:
	if not _grab(id, target):
		return false
	var it: ItemRef = target.get("item")
	if take_into != "" and it != null and not it.carried:
		_owner[it.uid] = id   # before the call: a backend may answer inside it (MockItems)
		if not actions.take(it, take_into):
			_owner.erase(it.uid)
			_drop_hold(hand(id))
			return false
	return true


## Shows an item CDDA already has in a hand (wielded or held through a menu) in hand `id`, ready to let go.
func adopt(id: String, item: ItemRef) -> bool:
	return item != null and item.carried and grab(id, _item_target(item, 0.0))


func _grab(id: String, target: Dictionary) -> bool:
	var h := hand(id)
	_forget_freed(h)
	if target.is_empty() or not h.held.is_empty():
		return false
	if target["kind"] == "door":
		var n: Variant = target.get("node")
		if not is_instance_valid(n):
			return false
		var g := n as Grabbable
		if g == null:
			return false
		if id == "mouse":
			g.begin_grab(target["point"])
		else:
			g.begin_hand(h.xform.origin)
		g.set_highlight(true)
		h.held = target
		return true
	var it: ItemRef = target["item"]
	if it == null or not _usable(it):
		return false
	h.held = target
	h.upright_key = []
	_light(h, h.hover, false)
	h.hover = {}
	var slot := picker.slot(it.uid)   # before hiding it: item_slot gives nothing for hidden items (a body: its pose)
	if not it.carried:
		_held_hidden[it.uid] = true
		_sync_hidden()
		var bs := _bodies()
		if bs != null:
			bs.hold(it.uid)   # its body goes (after the hand hid it: the static copy stays hidden throughout)
	h.proxy = _make_proxy(it)
	world.add_child(h.proxy)
	var start := Transform3D(Basis.IDENTITY, it.point if it.is_drawn() else h.xform.origin)
	if not slot.is_empty():   # where the pile drew it, turned the same way (the proxy has its own scale)
		var xf: Transform3D = slot[4]
		start = Transform3D(Basis(xf.basis.get_rotation_quaternion()), xf.origin)
	if _keeps_upright(h):
		start.basis = upright(start.basis)
	h.proxy.position = Vector3.ZERO
	h.proxy.global_position = start.origin
	h.proxy.global_basis = start.basis.scaled(h.proxy.scale) if h.proxy.scale != Vector3.ONE else start.basis
	return true


func holding(id: String) -> Dictionary:
	return hand(id).held if _hands.has(id) else {}


## The held item's proxy (for the caller to place, e.g. resting on the surface under the crosshair).
func proxy(id: String) -> Node3D:
	var h: Hand = _hands.get(id)
	return h.proxy if h != null and is_instance_valid(h.proxy) else null


## What letting go of `held` does when the crosshair ray is (origin, dir): DropTarget.resolve's answer.
func drop_on_ray(origin: Vector3, dir: Vector3, held: ItemRef, max_m := RAY_M) -> Dictionary:
	var hit := look_ray.cast(origin, dir, max_m, false)
	var under := picker.on_ray(origin, dir, max_m)
	if under != null and held != null and under.uid == held.uid:
		under = null
	return _drop(hit, under, held)


## The same for a hand at `p` (VR): what is under it and the item it touches.
func drop_at(p: Vector3, held: ItemRef) -> Dictionary:
	var hit := look_ray.cast(p + Vector3.UP * 0.05, Vector3.DOWN, 2.0, false)
	var under := picker.near(p, 0.12)
	if under != null and held != null and under.uid == held.uid:
		under = null
	return _drop(hit, under, held)


## DropTarget's answer plus `point`: where the ray met something (the carried item can rest there), or null.
func _drop(hit: Dictionary, under: ItemRef, held: ItemRef) -> Dictionary:
	var d := DropTarget.resolve(world.coords, hit, under, held, world.tables, world.snapshot, picker.in_reach)
	d["point"] = under.point if under != null and d.get("kind") == "container" else hit.get("point")
	return d


## Lets go. Doors: the leaf settles. Items: `drop` (from drop_on_ray / drop_at) says where; kind "none" (or {})
## puts it back. Returns the action started: "" (none or put back), "put", "drop", or "take" (first of two steps).
## With `bodies` set, letting go onto a surface with a `velocity` (world m/s; VR: the hand's), or onto bare floor at
## all, also makes a body where the copy was, moving at that velocity (ItemBodies.let_go): it falls and rolls while
## CDDA's drop goes out unchanged (same square, same spot); CDDA's answer keeps it (landed) or removes it (refused:
## the item stays carried, or back where it lay). Without `bodies` (or into a container, onto a burner, put back) the
## velocity changes nothing: the item shows at its spot as before.
func release(id: String, drop: Dictionary, velocity := Vector3.ZERO) -> String:
	var h := hand(id)
	var t := h.held
	h.held = {}
	if t.is_empty():
		return ""
	if t["kind"] == "door":
		var n: Variant = t.get("node")   # untyped: the leaf may have been freed with its submap
		if is_instance_valid(n) and n is Grabbable:
			(n as Grabbable).end_grab()
			(n as Grabbable).set_highlight(false)
		return ""
	var it: ItemRef = t["item"]
	var loose: Variant = _loose_pose(h, drop, velocity)   # before the copy goes
	_free_visuals(h, false)
	_held_hidden.erase(it.uid)
	var kind: String = drop.get("kind", "none")
	var op := ""
	var bs := _bodies()
	var body := false
	if loose is Transform3D:   # before the drop goes out: a backend may answer inside the call (MockItems)
		body = bs.let_go(it.uid, it.type, loose, velocity, drop["square"], it.size_m) != null
	if kind in ["surface", "burner", "container"]:
		op = _move(id, it, drop)
	if bs != null:
		if body and op == "":
			bs.forget(it.uid)   # nothing went out: the item is where it was
		bs.unhold(it.uid)
	_sync_hidden()
	return op


## Moves an item no hand holds (drag and drop in the Tab view) the way letting go would: `drop` as from
## drop_on_ray / drop_at, or built by the caller ({kind: container, container: ItemRef, pocket: int (optional,
## -1 = CDDA's pick)} or {kind: surface, square, spot}). Returns the action started, "" when none.
func move(id: String, it: ItemRef, drop: Dictionary) -> String:
	if it == null or not _usable(it) or not (drop.get("kind", "none") in ["surface", "burner", "container"]):
		return ""
	if drop.get("kind") == "container" and not drop.get("container") is ItemRef:
		return ""
	if not drop.get("square", Vector3i.ZERO) is Vector3i or not drop.get("spot", Vector2.ZERO) is Vector2:
		return ""
	var pocket: Variant = drop.get("pocket", -1)
	if not pocket is int or pocket < -1 or pocket > Snapshot.MAX_POCKET:
		return ""
	return _move(id, it, drop)


## Throws the item hand `id` holds at `square` (CDDA's throw: its range, aim, time; one unit of a stack). An item
## lying in the world is taken first (into the main hand when it is free, else the pack), then thrown; a square
## that can't be (your own, another level) sends nothing. Returns "throw", "take" (first of two steps) or ""
## (nothing sent: the item is back where it was).
func throw(id: String, square: Vector3i) -> String:
	var h := hand(id)
	var t := h.held
	if t.is_empty() or t["kind"] != "item":
		return ""
	var s := world.snapshot   # checked before a take: a throw that can't go leaves a lying item where it was
	if s == null or square == s.player_pos or square.z != s.player_pos.z or not ItemActions.ok_square(square):
		release(id, {})
		return ""
	h.held = {}
	var it: ItemRef = t["item"]
	_free_visuals(h, false)
	_held_hidden.erase(it.uid)
	var second := func(c: ItemRef) -> bool: return actions.throw(c, square)
	var op := _two_step(id, it, second, "throw")
	_unhold(it.uid)
	_sync_hidden()
	return op


## Item `uid` has an action in flight, or a second step (put / drop / throw) waiting for its take.
func busy(uid: int) -> bool:
	return actions.pending(uid) != "" or _then.has(uid)


## Cancels a hold: the item goes back, nothing is sent.
func cancel(id: String) -> void:
	release(id, {})


## Hands what hand `from_id` holds to hand `to_id` (which must hold nothing). An item lying in the world that no
## action is under yet only changes hands. A carried one: `into` ("main" / "off") is the CDDA hand `to_id` stands for;
## when it is there already it only changes hands, else CDDA moves it (ItemActions.hold, the queued item actions: its
## time and rules). The copy is in the new hand at once; when CDDA refuses it goes back to `from_id` (`refused` names
## `to_id`). False (nothing changed, nothing sent) when there is nothing to hand over, `to_id` holds something, an
## action on the item is in flight, or `into` is missing for a carried item. (Not `pass`: a GDScript keyword.)
func hand_over(from_id: String, to_id: String, into := "") -> bool:
	if from_id == to_id or not _hands.has(from_id):
		return false
	var a := hand(from_id)
	var b := hand(to_id)
	_forget_freed(a)
	_forget_freed(b)
	if a.held.is_empty() or a.held.get("kind") != "item" or not b.held.is_empty():
		return false
	var it: ItemRef = a.held.get("item")
	if it == null or actions.pending(it.uid) != "" or _then.has(it.uid) or _handing.has(it.uid):
		return false
	var send := false
	if it.carried:
		if not (into in ["main", "off"]):
			return false
		var flag := Snapshot.CARRIED_WIELDED if into == "main" else Snapshot.CARRIED_OFFHAND
		send = (it.flags & flag) == 0
	_move_hold(a, b)
	if not send:
		return true
	_owner[it.uid] = to_id   # before the call: a backend may answer inside it (MockItems)
	_handing[it.uid] = from_id
	if actions.hold(it, into):
		return true
	_owner.erase(it.uid)
	_handing.erase(it.uid)
	_move_hold(b, a)
	return false


## Whether hand `id`'s copy is kept upright now (tests, VR).
func keeps_upright(id: String) -> bool:
	return _hands.has(id) and _keeps_upright(_hands[id])


## `b` (orthonormal) turned about the up axis only, its pitch and roll dropped: the yaw of its forward (-Z), or of
## its right (X) when it points straight up or down.
static func upright(b: Basis) -> Basis:
	var f := -b.z
	f.y = 0.0
	if f.length_squared() < 1e-6:
		var r := b.x
		r.y = 0.0
		if r.length_squared() < 1e-6:
			return Basis.IDENTITY
		f = Vector3.UP.cross(r)
	return Basis.looking_at(f.normalized(), Vector3.UP)


## Takes the targeted item into the pack, the main hand or the off hand (E on the crosshair's item).
func take(id: String, target: Dictionary, where := "pack") -> bool:
	if target.is_empty() or target["kind"] != "item":
		return false
	var it: ItemRef = target["item"]
	var now := picker.by_uid(it.uid)   # a stale target: carried or gone since
	if it.carried or now == null or now.carried or not _usable(it):
		return false
	_owner[it.uid] = id
	if not actions.take(it, where):
		_owner.erase(it.uid)
		return false
	return true


## Two targets are the same thing (door node, or item uid + type).
static func same_target(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return a.is_empty() and b.is_empty()
	if a["kind"] != b["kind"]:
		return false
	if a["kind"] == "door":
		return is_same(a.get("node"), b.get("node"))
	return (a["item"] as ItemRef).same(b["item"])


## One line for the crosshair: what letting go does now.
static func drop_hint(drop: Dictionary, tables: IdTables) -> String:
	match drop.get("kind", "none"):
		"container":
			return "put it in the %s" % (drop["container"] as ItemRef).display_name(tables)
		"burner":
			var heat: Variant = drop.get("heat", {})
			var cold: bool = heat is Dictionary and (heat as Dictionary).get("lit", true) == false
			return "put it on the heat (not lit)" if cold else "put it on the heat"
		"surface":
			return "put it here"
	return "can't put it there"


# --- inside ---

## Carried items go straight to the target; an item lying in the world is taken first (into the main hand when it
## is free, else the pack), then put / dropped when the take finishes. Owner and second step are recorded before
## each call, as a backend may answer inside it (MockItems).
func _move(id: String, it: ItemRef, drop: Dictionary) -> String:
	var kind: String = drop["kind"]
	var square: Vector3i = drop.get("square", it.square)
	var spot: Vector2 = drop.get("spot", Vector2(-1, -1))
	var container: ItemRef = drop.get("container")
	var pocket: int = drop.get("pocket", -1)
	var second := func(c: ItemRef) -> bool:
		if kind == "container":
			return actions.put(c, container, pocket)
		return actions.drop(c, square, spot)
	return _two_step(id, it, second, "put" if kind == "container" else "drop")


## `second` (put / drop / throw) on a carried item at once (returns `op`), else a take first and `second` when it
## lands (returns "take"); "" when nothing was sent. Nothing sent: the item's owner is what it was before (an action
## still in flight for it, e.g. a hand_over's hold, keeps reporting to its own hand).
func _two_step(id: String, it: ItemRef, second: Callable, op: String) -> String:
	var prev: Variant = _owner.get(it.uid)
	_owner[it.uid] = id
	if it.carried:
		if second.call(it):
			return op
		_restore_owner(it.uid, prev)
		return ""
	_then[it.uid] = second
	if actions.pending(it.uid) == "take":   # taken on grab (VR) and not landed yet: go on when it does
		return "take"
	if actions.take(it, "main" if _main_free() else "pack"):
		return "take"
	_restore_owner(it.uid, prev)
	_then.erase(it.uid)
	return ""


func _restore_owner(uid: int, prev: Variant) -> void:
	if prev is String:
		_owner[uid] = prev
	else:
		_owner.erase(uid)


func _main_free() -> bool:
	var s := world.snapshot
	if s == null:
		return false
	for k in range(0, s.carried.size(), Snapshot.CARRIED_STRIDE):
		if (s.carried[k + 4] & Snapshot.CARRIED_WIELDED) != 0:
			return false
	return true


## An item no other hand holds and with no action in flight.
func _usable(it: ItemRef) -> bool:
	if actions.pending(it.uid) != "" or _then.has(it.uid):
		return false
	for h: Hand in _hands.values():
		if not h.held.is_empty() and h.held["kind"] == "item" and (h.held["item"] as ItemRef).uid == it.uid:
			return false
	return true


func _door_target(g: Grabbable, point: Vector3, dist: float) -> Dictionary:
	return {"kind": "door", "node": g, "item": null, "square": g.square, "point": point, "dist": dist,
			"name": door_name(g)}


## What a door leaf or furniture part is called under the pointer: a terrain door by its terrain ("wooden
## door"), a part by its kind and furniture ("drawer (dresser)", "lid (chest)"), ", locked" when CDDA says so.
## Names are game data: cleaned and capped.
func door_name(g: Grabbable) -> String:
	if g == null or not is_instance_valid(g):
		return ""
	var s := ""
	if g.mech.is_empty():
		s = _name_at("ter", g.square)
		if s.is_empty():
			s = "door"
	else:
		var furn := _name_at("furn", g.square)
		s = g.kind if furn.is_empty() else "%s (%s)" % [g.kind, furn]
	return s + (", locked" if g.locked else "")


## The id table name of the terrain or furniture ("ter" / "furn") on square `sq`, "" when unknown.
func _name_at(table: String, sq: Vector3i) -> String:
	var snap := world.snapshot if world != null else null
	if snap == null or world.tables == null:
		return ""
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(sq))
	if sm == null:
		return ""
	var l := CddaCoords.ms_to_local(sq)
	var i := l.y * CddaCoords.SEEX + l.x
	var arr: PackedInt32Array = sm.ter if table == "ter" else sm.furn
	if i < 0 or i >= arr.size() or (table == "furn" and arr[i] == 0):
		return ""
	var d := world.tables.def_at(table, arr[i])
	return HudData.clean(d.name if d != null and not d.name.is_empty() else (d.id if d != null else ""), HudData.MAX_NAME)


func _item_target(it: ItemRef, dist: float) -> Dictionary:
	return {"kind": "item", "node": null, "item": it, "square": it.square, "point": it.point, "dist": dist,
			"name": it.display_name(world.tables)}


func _light(h: Hand, t: Dictionary, on: bool) -> void:
	if t.is_empty():
		return
	if t["kind"] == "door":
		var n: Variant = t.get("node")   # untyped: the leaf may have been freed with its submap
		if not is_instance_valid(n) or not n is Grabbable:
			return
		var held_door: bool = not h.held.is_empty() and is_same(h.held.get("node"), n)
		if not held_door:
			(n as Grabbable).set_highlight(on)
		return
	if not on:
		if h.outline != null and is_instance_valid(h.outline):
			h.outline.visible = false
		return
	var slot := picker.slot((t["item"] as ItemRef).uid)
	if slot.is_empty():
		return
	if h.outline == null or not is_instance_valid(h.outline):
		h.outline = MeshInstance3D.new()
		h.outline.name = "ItemOutline_" + h.id
		h.outline.mesh = _box()
		h.outline.material_override = _outline()
		h.outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(h.outline)
	var size: float = maxf(float(slot[5]), 0.05)
	var xf: Transform3D = slot[4]
	h.outline.global_transform = Transform3D(Basis(xf.basis.get_rotation_quaternion()).scaled(Vector3.ONE * size),
			slot[3])   # around the middle of what is drawn
	h.outline.visible = true


## Door leaves freed since (their submap was dropped) leave the hand's hover and hold.
func _forget_freed(h: Hand) -> void:
	if not h.hover.is_empty() and h.hover.get("kind") == "door" and not is_instance_valid(h.hover.get("node")):
		h.hover = {}
	if not h.held.is_empty() and h.held.get("kind") == "door" and not is_instance_valid(h.held.get("node")):
		h.held = {}


func _free_visuals(h: Hand, outline := true) -> void:
	if h.proxy != null and is_instance_valid(h.proxy):
		h.proxy.queue_free()
	h.proxy = null
	if outline and h.outline != null and is_instance_valid(h.outline):
		h.outline.queue_free()
		h.outline = null


func _make_proxy(it: ItemRef) -> Node3D:
	if proxy_factory.is_valid():
		var n: Node3D = proxy_factory.call(it.type, it.size_m if it.size_m > 0.0 else 0.1, world)
		if n != null:
			return n
	return ItemVisual.make(it.type, world)


func _on_pending_hidden(uids: Dictionary) -> void:
	_pending_hidden = uids.duplicate()
	_sync_hidden()


func _sync_hidden() -> void:
	var all := _pending_hidden.duplicate()
	all.merge(_held_hidden)
	# Against the set last given, not world.hidden_items alone: that is the union with other owners' sets (ItemBodies
	# hides the items it has bodies for), which can equal this set while the hands' own set lacks a uid.
	if all.hash() != _sent_hidden.hash() or not world.hidden_items.has_all(all.keys()):
		_sent_hidden = all
		world.set_hidden_items(all)


func _on_finished(item: ItemRef, op: String) -> void:
	var id: String = _owner.get(item.uid, "")
	var bs := _bodies()
	if op == "drop" and bs != null:
		bs.landed(item.uid)   # a body let go with it stays (ItemBodies keeps it once the world shows it there)
	if op == "hold":   # handed over: the hand holding it now holds it as CDDA has it now
		_handing.erase(item.uid)
		var hh := _holder(item.uid)
		if hh != null:
			hh.held = _item_target(_carried(item), 0.0)
			hh.upright_key = []
	if op == "take":   # a hand still holding it (taken on grab) holds a carried item now, no pile to hide it in
		var h := _holder(item.uid)
		if h != null:
			var c := _carried(item)
			h.held = _item_target(c, 0.0)
			h.upright_key = []
		if _held_hidden.erase(item.uid):
			_sync_hidden()
	if op == "take" and _then.has(item.uid):
		if defer_steps:
			_second_step.call_deferred(item)   # not while ItemActions is still judging its list
		else:
			_second_step(item)
		return
	_owner.erase(item.uid)
	confirmed.emit(id, _item_target(item, 0.0))


## The hand holding item `uid`, or null.
func _holder(uid: int) -> Hand:
	for h: Hand in _hands.values():
		if not h.held.is_empty() and h.held["kind"] == "item" and (h.held["item"] as ItemRef).uid == uid:
			return h
	return null


## `item` as carried by the player now (after a take): its row in the newest snapshot (which container, which
## hand), so a later put is judged against where it really is.
func _carried(item: ItemRef) -> ItemRef:
	var s := world.snapshot
	if s != null:
		var row := ItemActions.carried_row(s, item.uid, item.type)
		if row >= 0:
			var i := row * Snapshot.CARRIED_STRIDE
			return ItemRef.on_player(item.uid, item.type, s.carried[i + 2], int(s.carried[i + 3]),
					int(s.carried[i + 4]), s.player_pos)
	var c := item.duplicate_ref()
	c.carried = true
	c.point = Vector3.INF
	if world.snapshot != null:
		c.square = world.snapshot.player_pos
	return c


## A hand lets go of an item without sending anything (refused take, failed grab).
func _drop_hold(h: Hand) -> void:
	var it: ItemRef = h.held.get("item")
	h.held = {}
	_free_visuals(h, false)
	if it != null:
		_held_hidden.erase(it.uid)
		_unhold(it.uid)
		_sync_hidden()


## What hand `from` holds (its target and copy) moves to hand `to`, nothing sent; `to`'s outline goes.
func _move_hold(from: Hand, to: Hand) -> void:
	_light(to, to.hover, false)
	to.hover = {}
	to.held = from.held
	to.proxy = from.proxy
	to.upright_key = []
	from.held = {}
	from.proxy = null
	from.upright_key = []


## The bodies when set and not freed, else null.
func _bodies() -> ItemBodies:
	return bodies if is_instance_valid(bodies) else null


## No hand holds item `uid` any more: it may lie as a body again.
func _unhold(uid: int) -> void:
	var bs := _bodies()
	if bs != null:
		bs.unhold(uid)


## Where hand h's copy becomes a physics body as it lets go toward `drop` (release): with `bodies` set, onto a
## surface while the hand moves, or onto bare floor at all; null otherwise (no bodies, a container, a burner, put
## back, no copy). The copy's pose without its scale.
func _loose_pose(h: Hand, drop: Dictionary, velocity: Vector3) -> Variant:
	if _bodies() == null or drop.get("kind") != "surface" or not drop.get("square") is Vector3i:
		return null
	if h.proxy == null or not is_instance_valid(h.proxy) or not h.proxy.is_inside_tree():
		return null
	var moving := velocity.is_finite() and not velocity.is_zero_approx()
	if not moving and not _bare_floor(drop["square"]):
		return null
	var xf := h.proxy.global_transform
	return Transform3D(xf.basis.orthonormalized(), xf.origin) if xf.is_finite() else null


## No furniture on square `sq` in the snapshot (unknown: false).
func _bare_floor(sq: Vector3i) -> bool:
	var s := world.snapshot
	var sm: Snapshot.Submap = s.submaps.get(CddaCoords.ms_to_sm(sq)) if s != null else null
	if sm == null:
		return false
	var l := CddaCoords.ms_to_local(sq)
	var i := l.y * CddaCoords.SEEX + l.x
	return i >= 0 and i < sm.furn.size() and sm.furn[i] == 0


## Hand h's copy is kept upright: its item is a container (the id tables say it has pockets) that holds something
## (carried: a carried row inside it; lying in the world: unknown, so it might). Worked out once per snapshot.
func _keeps_upright(h: Hand) -> bool:
	var it: ItemRef = h.held.get("item") if h.held.get("kind") == "item" else null
	if it == null:
		return false
	var s := world.snapshot
	var key := [it.uid, it.type, it.carried, s.get_instance_id() if s != null else 0, s.seq if s != null else -1]
	if key == h.upright_key:
		return h.upright
	h.upright_key = key
	h.upright = it.is_container(world.tables) and (not it.carried or _holds_any(it.uid))
	return h.upright


## Something carried is inside carried item `uid` (the snapshot's rows).
func _holds_any(uid: int) -> bool:
	var s := world.snapshot
	if s == null:
		return false
	var c := s.carried
	var n := mini(c.size(), Snapshot.MAX_CARRIED * Snapshot.CARRIED_STRIDE)
	for k in range(0, n - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[k + 2] == uid and c[k] != uid:
			return true
	return false


## The put / drop after a take landed; confirmed or refused when it lands in turn.
func _second_step(item: ItemRef) -> void:
	var id: String = _owner.get(item.uid, "")
	var next: Callable = _then.get(item.uid, Callable())
	_then.erase(item.uid)
	if not next.is_valid():
		return
	if next.call(_carried(item)):
		return
	_owner.erase(item.uid)
	var bs := _bodies()
	if bs != null:
		bs.forget(item.uid)   # the drop didn't go out: it stays carried, its body goes
	refused.emit(id, _item_target(item, 0.0), "It can't go there now (it is in your hands).")


func _on_refused(item: ItemRef, op: String, reason: String) -> void:
	var id: String = _owner.get(item.uid, "")
	_owner.erase(item.uid)
	_then.erase(item.uid)
	var bs := _bodies()
	if bs != null:
		bs.forget(item.uid)   # a body let go with a refused take / drop goes: carried, or back where it lay
	var h := _holder(item.uid) if op == "take" else null
	if h != null:   # taken on grab and refused: the hand is empty again (refused carries where it was)
		_drop_hold(h)
	if op == "hold" and _handing.has(item.uid):   # handed over and refused: back to the first hand
		var back := hand(str(_handing[item.uid]))
		_handing.erase(item.uid)
		var now := _holder(item.uid)
		if now != null and back.held.is_empty():
			_move_hold(now, back)
		elif now != null:
			_drop_hold(now)   # the first hand holds something else now: CDDA still has it, nothing shown
	refused.emit(id, _item_target(item, 0.0), reason)


static func _outline() -> StandardMaterial3D:
	if _outline_mat == null:
		_outline_mat = StandardMaterial3D.new()
		_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_outline_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT
		_outline_mat.grow = true
		_outline_mat.grow_amount = 0.015
		_outline_mat.albedo_color = Color(OUTLINE, 0.9)
	return _outline_mat


static func _box() -> BoxMesh:
	if _box_mesh == null:
		_box_mesh = BoxMesh.new()
		_box_mesh.size = Vector3(1.1, 1.1, 1.1)
	return _box_mesh
