class_name Hands
extends Node
## Blocks E6 / L2 / L8: the player's hands, device-free. A hand ("mouse" for the crosshair, "vr_l" / "vr_r" for
## the controllers) points at or reaches for a target, grabs it and lets it go somewhere. Targets are door leaves
## (Grabbable, dragged as before) and single items (ItemRef by snapshot handle). Every item move is one or two
## one-item CDDA actions through ItemActions (take, then put / drop); CDDA's time, volume and weight rules decide,
## and a refusal brings the item back with CDDA's reason. Flat-screen input lives in ui/GrabController, VR input in
## vr/VrRig; both only feed this.
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
const THROW_SPEED := 4.0    # m/s at release: a throw (needs the bridge's throw op; until then a drop)
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

var _hands := {}           # id -> Hand
var _held_hidden := {}     # uid -> true: items a hand holds right now (hidden in their pile)
var _pending_hidden := {}  # uid -> true: items in flight (ItemActions.hidden_changed)
var _owner := {}           # uid -> hand id that started the action
var _then := {}            # uid -> Callable(item: ItemRef) -> bool: second step after a take finishes

static var _outline_mat: StandardMaterial3D
static var _box_mesh: BoxMesh


class Hand:
	var id := ""
	var xform := Transform3D.IDENTITY
	var hover := {}
	var held := {}
	var proxy: Node3D
	var outline: MeshInstance3D


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
	h.xform = xform
	if h.proxy == null or not is_instance_valid(h.proxy):
		return
	if not turn:
		h.proxy.global_transform = Transform3D(h.proxy.global_basis, xform.origin)
		return
	var it: ItemRef = h.held.get("item")
	var g := ItemVisual.grip(it.type, world) if it != null else Transform3D.IDENTITY
	var b := xform.basis.orthonormalized() * g.basis.inverse()
	h.proxy.global_transform = Transform3D(b.scaled(h.proxy.scale), xform.origin - b * g.origin)


## Turns what a hand holds about the up axis (mouse wheel with Shift).
func turn_held(id: String, radians: float) -> void:
	var h := hand(id)
	if h.proxy != null and is_instance_valid(h.proxy):
		h.proxy.global_basis = Basis(Vector3.UP, radians) * h.proxy.global_basis


## The target under a hand changed: outline it (and drop the old outline).
func hover(id: String, target: Dictionary) -> void:
	var h := hand(id)
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
	if target.is_empty() or not h.held.is_empty():
		return false
	if target["kind"] == "door":
		var g: Grabbable = target["node"]
		if not is_instance_valid(g):
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
	_light(h, h.hover, false)
	h.hover = {}
	if not it.carried:
		_held_hidden[it.uid] = true
		_sync_hidden()
	h.proxy = _make_proxy(it)
	world.add_child(h.proxy)
	var start := Transform3D(Basis.IDENTITY, it.point if it.is_drawn() else h.xform.origin)
	var slot := world.item_slot(it.uid)
	if not slot.is_empty():   # where the pile drew it, turned the same way (the proxy has its own scale)
		var xf: Transform3D = slot[4]
		start = Transform3D(Basis(xf.basis.get_rotation_quaternion()), xf.origin)
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
func release(id: String, drop: Dictionary, _velocity := Vector3.ZERO) -> String:
	var h := hand(id)
	var t := h.held
	h.held = {}
	if t.is_empty():
		return ""
	if t["kind"] == "door":
		var g: Grabbable = t["node"]
		if is_instance_valid(g):
			g.end_grab()
			g.set_highlight(false)
		return ""
	var it: ItemRef = t["item"]
	_free_visuals(h, false)
	_held_hidden.erase(it.uid)
	var kind: String = drop.get("kind", "none")
	var op := ""
	if kind in ["surface", "burner", "container"]:
		op = _move(id, it, drop)
	_sync_hidden()
	return op


## Cancels a hold: the item goes back, nothing is sent.
func cancel(id: String) -> void:
	release(id, {})


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
		return a["node"] == b["node"]
	return (a["item"] as ItemRef).same(b["item"])


## One line for the crosshair: what letting go does now.
static func drop_hint(drop: Dictionary, tables: IdTables) -> String:
	match drop.get("kind", "none"):
		"container":
			return "put it in the %s" % (drop["container"] as ItemRef).display_name(tables)
		"burner":
			return "put it on the heat"
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
	var second := func(c: ItemRef) -> bool:
		if kind == "container":
			return actions.put(c, container)
		return actions.drop(c, square, spot)
	_owner[it.uid] = id
	if it.carried:
		if second.call(it):
			return "put" if kind == "container" else "drop"
		_owner.erase(it.uid)
		return ""
	_then[it.uid] = second
	if actions.pending(it.uid) == "take":   # taken on grab (VR) and not landed yet: go on when it does
		return "take"
	if actions.take(it, "main" if _main_free() else "pack"):
		return "take"
	_owner.erase(it.uid)
	_then.erase(it.uid)
	return ""


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
	return {"kind": "door", "node": g, "item": null, "square": g.square, "point": point, "dist": dist, "name": "door"}


func _item_target(it: ItemRef, dist: float) -> Dictionary:
	return {"kind": "item", "node": null, "item": it, "square": it.square, "point": it.point, "dist": dist,
			"name": it.display_name(world.tables)}


func _light(h: Hand, t: Dictionary, on: bool) -> void:
	if t.is_empty():
		return
	if t["kind"] == "door":
		var g: Grabbable = t["node"]
		var held_door: bool = not h.held.is_empty() and h.held.get("node") == g
		if is_instance_valid(g) and not held_door:
			g.set_highlight(on)
		return
	if not on:
		if h.outline != null and is_instance_valid(h.outline):
			h.outline.visible = false
		return
	var slot := world.item_slot((t["item"] as ItemRef).uid)
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
	if all.hash() != world.hidden_items.hash():
		world.set_hidden_items(all)


func _on_finished(item: ItemRef, op: String) -> void:
	var id: String = _owner.get(item.uid, "")
	if op == "take":   # a hand still holding it (taken on grab) holds a carried item now, no pile to hide it in
		var h := _holder(item.uid)
		if h != null:
			var c := _carried(item)
			h.held = _item_target(c, 0.0)
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
		_sync_hidden()


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
	refused.emit(id, _item_target(item, 0.0), "It can't go there now (it is in your hands).")


func _on_refused(item: ItemRef, op: String, reason: String) -> void:
	var id: String = _owner.get(item.uid, "")
	_owner.erase(item.uid)
	_then.erase(item.uid)
	var h := _holder(item.uid) if op == "take" else null
	if h != null:   # taken on grab and refused: the hand is empty again (refused carries where it was)
		_drop_hold(h)
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
