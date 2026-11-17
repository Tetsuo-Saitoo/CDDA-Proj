class_name VrSlots
extends Node3D
## Block L8 slice 5 (VR): body slots. The player's worn containers other than the shoulder bag (VrRig.shoulder_bag,
## the biggest: taken off and opened as VrPack) each get a place on the body. Holsters and sheaths (every pocket a
## holster, IdTables.POCKET_HOLSTER) go to the main hand's hip, the other hip, then the thighs; the rest (pouches,
## belts, chest rigs) to the chest, main side first, then any place left. That makes MAX_SLOTS at most, in CDDA's
## worn order (outermost first). A holster stays a slot even when it is the biggest worn container.
## The places follow the head: its yaw, its height over the rig's floor (ANCHORS' fractions), and a little behind
## the eyes (BACK_M). The list is read again when the snapshot changes; the rings and lines are kept (one per place
## in the list) and a line's text is set only when it changed.
## Nothing here is sent. VrRig takes from and puts into a slot through Hands, as with the pack:
## - grip at a slot with an empty hand takes the first thing in it (Hands.adopt; CDDA moves it into that hand once
##   it is carried SWITCH_M away);
## - let go of an item at a slot puts it into that container; its own container puts it back with nothing sent;
## - the wielded gun let go at a slot goes into it (Hands.move).
## A slot shows only while a hand is within SHOW_M: a ring (lit within REACH_M) and a line with the container's
## name and what's in it. VrRig buzzes a hand once when it comes within REACH_M of a slot (`entered`). Names come
## from the game data, cleaned and capped.

const MAX_SLOTS := 6
const REACH_M := 0.12        # a hand this near a slot's centre is at it
const SHOW_M := 0.3          # a slot shows while a hand is this near
const BACK_M := 0.08         # the body's middle this far behind the eyes
const MIN_HEIGHT := 1.0      # the head's height over the floor is taken within these
const MAX_HEIGHT := 2.2
const NAME_MAX := 20         # characters of a name on a slot's line
const RING_R := 0.045
const LABEL_UP := 0.06       # the line this far over the ring
## Places on the body: [sideways (m, + = the main hand's side), up (fraction of the head's height over the floor),
## forward (m, the way the head faces)].
const ANCHORS: Array[Vector3] = [
	Vector3(0.2, 0.52, 0.0),     # 0 main hip
	Vector3(-0.2, 0.52, 0.0),    # 1 other hip
	Vector3(0.12, 0.42, 0.06),   # 2 main thigh
	Vector3(-0.12, 0.42, 0.06),  # 3 other thigh
	Vector3(0.1, 0.72, 0.12),    # 4 chest, main side
	Vector3(-0.1, 0.72, 0.12),   # 5 chest, other side
]
const HOLSTER_ORDER: Array[int] = [0, 1, 2, 3, 4, 5]
const OTHER_ORDER: Array[int] = [4, 5, 2, 3, 0, 1]

var world: WorldView
var hands: Hands
var head: Node3D
var main_right := true       # the main hand is the right one (VrRig: left-handed flips it)
## Each slot: {uid, item (the container, ItemRef), contents (Array[ItemRef] directly inside, in CDDA's order),
## holster, anchor (ANCHORS index), point (world, this frame)}.
var slots: Array[Dictionary] = []
var at: Array[int] = [-1, -1]          # slot index each hand is at (within REACH_M), -1 none
var entered: Array[bool] = [false, false]   # hand i came to a slot this frame
var builds := 0                        # slot lists that differed from the last (tests)
var _rings: Array[MeshInstance3D] = [] # slot k's ring, made when it first shows
var _labels: Array[Label3D] = []
var _sig: Array = []
var _seq := -1
var _snap_id := 0
var _yaw_fwd := Vector3.FORWARD        # the last level facing (kept while the head looks straight down)
var _mat: StandardMaterial3D
var _mat_lit: StandardMaterial3D
var _ring_mesh: TorusMesh


func _init() -> void:
	name = "VrSlots"


## Builds the slot list from the snapshot when it changed (or `force`). Returns whether it was rebuilt.
func refresh(force := false) -> bool:
	var snap: Snapshot = world.snapshot if world != null else null
	if snap == null or not is_instance_valid(hands) or hands.picker == null:
		if not slots.is_empty():
			_clear()
		_seq = -1
		return false
	if not force and snap.seq == _seq and snap.get_instance_id() == _snap_id:
		return false
	_seq = snap.seq
	_snap_id = snap.get_instance_id()
	slots.clear()
	var tables: IdTables = world.tables
	var worn := hands.picker.worn_containers()
	var bag := VrRig.shoulder_bag(worn, null, tables)
	var inside := {}   # container uid -> Array[ItemRef]
	for r in hands.picker.carried():
		if r.parent != 0:
			if not inside.has(r.parent):
				var fresh: Array[ItemRef] = []
				inside[r.parent] = fresh
			var list: Array[ItemRef] = inside[r.parent]
			list.append(r)
	var used := {}
	for r in worn:
		if slots.size() >= MAX_SLOTS:
			break
		var h := is_holster(r.type, tables)
		if bag != null and r.uid == bag.uid and not h:
			continue
		var anchor := -1
		for k: int in (HOLSTER_ORDER if h else OTHER_ORDER):
			if not used.has(k):
				anchor = k
				break
		if anchor < 0:
			break
		used[anchor] = true
		var stuff: Array[ItemRef] = []
		if inside.has(r.uid):
			stuff = inside[r.uid]
		slots.append({"uid": r.uid, "item": r, "contents": stuff, "holster": h, "anchor": anchor, "point": Vector3.INF})
	var sig := slots.map(func(e: Dictionary) -> Array:
		return [e["uid"], e["item"].type, e["anchor"], (e["contents"] as Array).map(func(c: ItemRef) -> Array:
			return [c.uid, c.type, c.is_off_hand()])])
	if sig == _sig:
		return false
	_sig = sig
	builds += 1
	return true


## Every pocket of itype `type` is a holster (a sheath, a gun holster, a quiver's slot); false without pockets.
static func is_holster(type: int, tables: IdTables) -> bool:
	var def: IdTables.Def = tables.def_at("itype", type) if tables != null else null
	if def == null or def.pockets.is_empty():
		return false
	for p: Dictionary in def.pockets:
		if not int(p.get("flags", 0)) & IdTables.POCKET_HOLSTER:
			return false
	return true


## Where anchor `k` is in the world for a head at `head_xf` facing level `fwd`, the floor at `floor_y`.
static func anchor_point(k: int, head_xf: Transform3D, fwd: Vector3, floor_y: float, main_right_side: bool) -> Vector3:
	var a := ANCHORS[clampi(k, 0, ANCHORS.size() - 1)]
	var right := fwd.cross(Vector3.UP).normalized()
	var h := clampf(head_xf.origin.y - floor_y, MIN_HEIGHT, MAX_HEIGHT)
	var mid := Vector3(head_xf.origin.x, floor_y, head_xf.origin.z) - fwd * BACK_M
	var side := a.x if main_right_side else -a.x
	return mid + right * side + Vector3.UP * (a.y * h) + fwd * a.z


## Every frame (VrRig): rebuilds when the snapshot changed, places the slots, finds the slot each hand is at
## (`hand_pts`: the hands' points, INF for one that doesn't count) and shows the slots a hand is near.
func update(floor_y: float, hand_pts: Array[Vector3]) -> void:
	refresh()
	var was := at.duplicate()
	at = [-1, -1]
	entered = [false, false]
	if slots.is_empty() or not is_instance_valid(head) or not head.is_inside_tree() or not is_finite(floor_y):
		_hide_all()
		return
	var xf := head.global_transform
	var f := -xf.basis.z
	f.y = 0.0
	if f.is_finite() and f.length() > 0.2:
		_yaw_fwd = f.normalized()
	for s: Dictionary in slots:
		s["point"] = anchor_point(s["anchor"], xf, _yaw_fwd, floor_y, main_right)
	for i in 2:
		var p: Vector3 = hand_pts[i] if i < hand_pts.size() else Vector3.INF
		at[i] = slot_at(p)
		entered[i] = at[i] >= 0 and at[i] != was[i]
	for k in slots.size():
		_show(k, hand_pts)
	for k in range(slots.size(), _rings.size()):
		_rings[k].visible = false
		_labels[k].visible = false


## The slot nearest `p` within REACH_M, -1 none.
func slot_at(p: Vector3) -> int:
	if not p.is_finite():
		return -1
	var best := -1
	var best_d := REACH_M
	for k in slots.size():
		var q: Vector3 = slots[k]["point"]
		if not q.is_finite():
			continue
		var d := p.distance_to(q)
		if d <= best_d:
			best = k
			best_d = d
	return best


## What a grip at `p` takes: the first thing in the slot there that no hand holds and no action is under way on;
## null none.
func take_at(p: Vector3) -> ItemRef:
	var k := slot_at(p)
	if k < 0:
		return null
	for r: ItemRef in slots[k]["contents"]:
		if r.is_off_hand() or r.is_wielded() or hands.busy(r.uid):
			continue
		var held := false
		for id: String in VrRig.HAND_IDS:
			var it: Variant = hands.holding(id).get("item")
			held = held or (it is ItemRef and (it as ItemRef).uid == r.uid)
		if not held:
			return r
	return null


## What letting go of `it` at `p` does: {} (no slot there, or the slot is that item), {kind: "none"} (back in its own
## container: nothing sent), else a container drop for Hands.release / move ({kind, container, pocket 0 when the
## container has one pocket, else CDDA's pick}).
func drop_for(p: Vector3, it: ItemRef) -> Dictionary:
	var k := slot_at(p)
	if k < 0 or it == null:
		return {}
	var s := slots[k]
	var c: ItemRef = s["item"]
	if it.uid == c.uid:
		return {}
	if it.carried and it.parent == c.uid and not it.is_off_hand() and not it.is_wielded():
		return {"kind": "none"}
	var d := {"kind": "container", "container": c}
	var def: IdTables.Def = world.tables.def_at("itype", c.type) if world != null and world.tables != null else null
	if def != null and def.pockets.size() == 1:
		d["pocket"] = 0
	return d


## World point of the slot of container `uid`, INF if it has none.
func point_of(uid: int) -> Vector3:
	for s: Dictionary in slots:
		if s["uid"] == uid:
			return s["point"]
	return Vector3.INF


## Slot k's line: "Holster: pistol", "+N" for more, "empty" when nothing is in it.
func text_of(k: int) -> String:
	var s := slots[k]
	var tables: IdTables = world.tables if world != null else null
	var c: ItemRef = s["item"]
	var nm := InventoryModel.clean(VrCook._item_name(c.type, tables), NAME_MAX)
	var stuff: Array[ItemRef] = s["contents"]
	if stuff.is_empty():
		return "%s: empty" % nm.capitalize()
	var first := InventoryModel.clean(VrCook._item_name(stuff[0].type, tables), NAME_MAX)
	return "%s: %s%s" % [nm.capitalize(), first, " +%d" % (stuff.size() - 1) if stuff.size() > 1 else ""]


## Slot k's ring and line (null until it first showed).
func ring_of(k: int) -> MeshInstance3D:
	return _rings[k] if k >= 0 and k < _rings.size() else null


func label_of(k: int) -> Label3D:
	return _labels[k] if k >= 0 and k < _labels.size() else null


func _show(k: int, hand_pts: Array[Vector3]) -> void:
	var p: Vector3 = slots[k]["point"]
	var near := false
	var lit := at[0] == k or at[1] == k
	for q: Vector3 in hand_pts:
		if q.is_finite() and p.is_finite() and q.distance_to(p) <= SHOW_M:
			near = true
	if not near:
		if k < _rings.size():
			_rings[k].visible = false
			_labels[k].visible = false
		return
	while _rings.size() <= k:
		var r := MeshInstance3D.new()
		r.mesh = _ring()
		r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(r)
		_rings.append(r)
		var l := Label3D.new()
		l.pixel_size = 0.0003
		l.font_size = 32
		l.outline_size = 8
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.render_priority = 5
		add_child(l)
		_labels.append(l)
	var ring := _rings[k]
	var label := _labels[k]
	var text := text_of(k)
	if label.text != text:
		label.text = text
	ring.material_override = _material(lit)
	ring.global_position = p
	ring.global_basis = Basis.looking_at(_yaw_fwd, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5)
	label.global_position = p + Vector3.UP * LABEL_UP
	ring.visible = true
	label.visible = true


func _hide_all() -> void:
	for k in _rings.size():
		_rings[k].visible = false
		_labels[k].visible = false


func _clear() -> void:
	slots.clear()
	_sig = []
	at = [-1, -1]
	_hide_all()


func _ring() -> TorusMesh:
	if _ring_mesh == null:
		_ring_mesh = TorusMesh.new()
		_ring_mesh.inner_radius = RING_R - 0.006
		_ring_mesh.outer_radius = RING_R
		_ring_mesh.rings = 24
		_ring_mesh.ring_segments = 6
	return _ring_mesh


func _material(lit: bool) -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.no_depth_test = true
		_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.35)
		_mat_lit = _mat.duplicate()
		_mat_lit.albedo_color = Color(0.55, 0.9, 1.0, 0.9)
	return _mat_lit if lit else _mat
