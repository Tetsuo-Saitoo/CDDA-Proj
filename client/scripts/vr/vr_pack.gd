class_name VrPack
extends Node3D
## Block L8 (VR): a worn container taken off the shoulder and opened in front of the player. Looking inside is
## the client's own business (CDDA charges nothing to look): opening, carrying and closing send nothing; only
## taking an item out and putting one in are CDDA actions, through the shared Hands layer (Hands.adopt, then the
## normal let-go path; Hands.release with a container drop and its pocket). CDDA decides; refusals come back
## through Hands.refused (VrRig buzzes and shows the reason).
##
## States: CLOSED (hidden) -> HELD (hangs from hand `hand` by its handle) -> OPEN (floats where it was let go:
## REST_M in front of the head at chest to waist height, facing the head) -> HELD again (a hand grips its frame or
## handle) ... -> CLOSED (let go over the shoulder, the trigger on its frame, the head farther than CLOSE_M, or
## the bag gone from the snapshot). It is top_level: walking or teleporting leaves it where it is in the world.
##
## Layout (layout()): one compartment per pocket group of the bag's InventoryModel column ("worn:<uid>"), side by
## side in pocket order, as wide as the group's share of the listed volume (MIN_W..MAX_W); each item lying right
## in the pocket (depth 0; what is inside it travels with it) is a small ItemVisual model (at most MAX_ITEM_M) in a
## grid with its name; at most MAX_PER_POCKET / MAX_SHOWN / MAX_POCKETS shown, the rest as "+N more". Rebuilt only
## when the bag's rows or their pending state change (refresh(): the snapshot's seq or ItemActions.changed, then a
## signature compare); the per-frame work is a few distance checks. Pending rows are dimmed and can't be gripped.
## Names and titles come from game data: InventoryModel.clean'd and capped again here.

## The pack closed: "put back" (over the shoulder), "closed" (trigger), "far", "gone" (bag, hands or world gone).
signal closed(why: String)

enum State { CLOSED, HELD, OPEN }

const HEIGHT := 0.22          # compartments' height (m)
const TOTAL_W := 0.56         # width shared out between the compartments by volume ...
const MIN_W := 0.1            # ... each at least this ...
const MAX_W := 0.3            # ... and at most this
const GAP := 0.015            # between compartments
const RIM := 0.02             # frame around them
const TITLE_H := 0.035        # band over the compartments for their titles
const HANDLE_UP := 0.03       # the handle bar over the title band
const HANDLE_LEN := 0.22
const ITEM_Z := 0.03          # items sit this far in front of the back panel
const MAX_ITEM_M := 0.08      # an item model's longest side in the pack
const LABEL_H := 0.012        # room for a name under an item
const NAME_MIN_W := 0.05      # narrower cells show no name (the hover label still does)
const MAX_POCKETS := 6        # compartments shown; rows of the others count in `more`
const MAX_PER_POCKET := 24    # item models per compartment ...
const MAX_SHOWN := 60         # ... and in all
const MAX_NAME := 16          # characters of an item's name under it
const MAX_TITLE := 28         # characters of a title
const MAX_COUNT := 100000     # "+N more" counts are capped to this
const ITEM_REACH := 0.07      # a hand grips an item model within this of its centre
const FRAME_REACH := 0.08     # ... the handle within this of the bar
const DROP_FRONT := 0.2       # a held item is over a compartment this far in front of its back panel ...
const DROP_BACK := 0.06       # ... and this far behind it
const REST_M := 0.45          # let go in front: this far from the head, level ...
const REST_HIGH := 0.3        # ... between this ...
const REST_LOW := 0.75        # ... and this far under the head (chest to waist)
const CLOSE_M := 1.5          # the head farther than this from the open pack: it closes
const DIM := 0.6              # transparency of a pending row's model
const EMPTY_TITLE := "inside" # the one compartment of a bag with nothing listed (CDDA picks the pocket)

## The shared hands (VrRig sets it with its own).
var hands: Hands:
	set(h):
		if is_instance_valid(hands) and is_instance_valid(hands.actions) \
				and hands.actions.changed.is_connected(_on_actions_changed):
			hands.actions.changed.disconnect(_on_actions_changed)
		hands = h
		if h != null and h.actions != null and not h.actions.changed.is_connected(_on_actions_changed):
			h.actions.changed.connect(_on_actions_changed)
		_dirty = true
## The head (VrRig's camera): where the pack rests and how far away it is.
var head: Node3D
## Hands ids of the left / right controller (VrRig.HAND_IDS).
var ids: Array[String] = ["vr_l", "vr_r"]
var state := State.CLOSED
var hand := -1               # the hand holding it (HELD), else -1
var bag: ItemRef             # the worn container shown (fresh from each refresh)
var builds := 0              # layouts built (tests)
var scans := 0               # columns read (tests)
## Built compartments: {key, title, x0, x1, more, mesh}.
var comps: Array[Dictionary] = []
## Built item models: {uid, row, pos (pack space), size, name, named, pending, comp, node}.
var items: Array[Dictionary] = []
var more := 0                # rows not shown at all (the model's cut, extra pockets)
var outlines: Array[MeshInstance3D] = [null, null]   # hover outline per hand
var _names: Array[Label3D] = [null, null]            # hovered item's name per hand
var _hover: Array[Dictionary] = [{}, {}]
var _lit: Array[int] = [-1, -1]                       # compartment under a held item, per hand
var _content: Node3D
var _width := 0.0
var _sig: Array = []
var _snap_id := 0
var _seq := -1
var _dirty := true
var _held := {}              # uids a hand holds now: their models hide
var _mats := {}              # kind -> material, made once per pack


func _init() -> void:
	name = "VrPack"
	top_level = true   # stays in the world when the rig moves
	visible = false


func is_open() -> bool:
	return state != State.CLOSED


## Takes `b` (a worn container) off the shoulder into hand i: shown hanging from it, nothing sent. False when it
## is already out, or the bag has no column in the inventory model.
func open_in(i: int, b: ItemRef) -> bool:
	if state != State.CLOSED or b == null or i < 0 or i > 1 or not is_inside_tree() or not is_instance_valid(hands):
		return false
	bag = b
	state = State.HELD
	hand = i
	_sig = []
	_dirty = true
	if not refresh(true):
		return false   # refresh closed it
	visible = true
	return true


## Hand i grips target `t` (target_at's): the frame -> it holds the pack; an item -> it holds that item's copy
## (Hands.adopt: it is carried, nothing is sent until it is let go).
func grip(i: int, t: Dictionary) -> bool:
	if state == State.CLOSED or t.is_empty() or i < 0 or i > 1 or not is_instance_valid(hands):
		return false
	if t.get("kind") == "frame":
		state = State.HELD
		hand = i
		hover(i, {})
		return true
	var it: Variant = t.get("item")
	if t.get("kind") == "item" and it is ItemRef:
		return hands.adopt(ids[i], it)
	return false


## The holding hand lets go: over the shoulder (`over`) it closes; elsewhere it floats open in front of the head.
## Returns "close", "open" or "" (not held).
func let_go(over: bool, hand_pos: Vector3) -> String:
	if state != State.HELD:
		return ""
	if over:
		close("put back")
		return "close"
	state = State.OPEN
	hand = -1
	if is_inside_tree() and is_instance_valid(head) and head.is_inside_tree():
		global_transform = rest_pose(head.global_transform, hand_pos)
	return "open"


func close(why := "") -> void:
	if state == State.CLOSED:
		return
	state = State.CLOSED
	hand = -1
	bag = null
	visible = false
	_clear()
	_sig = []
	_held = {}
	closed.emit(why)


## While held: hangs from the hand (`hand_xf`, the controller) by its handle.
func follow(hand_xf: Transform3D) -> void:
	if state == State.HELD and is_inside_tree() and hand_xf.is_finite():
		global_transform = hang_pose(hand_xf)


## Per frame: a new layout when the bag's rows changed, closes when far or gone, hides the models of held items.
func update() -> void:
	if state == State.CLOSED:
		return
	if not is_inside_tree() or not is_instance_valid(hands) or not is_instance_valid(head):
		close("gone")
		return
	if not refresh():
		return
	if state == State.OPEN and head.is_inside_tree() and head.global_position.distance_to(global_position) > CLOSE_M:
		close("far")
		return
	_sync_held()


## Reads the bag's column again when the snapshot or the pending actions changed (`force`: now) and builds a new
## layout when it differs. False (and closed) when the bag, the hands or the snapshot are gone.
func refresh(force := false) -> bool:
	if state == State.CLOSED:
		return false
	if not is_instance_valid(hands) or not is_instance_valid(hands.world) or bag == null:
		close("gone")
		return false
	var snap := hands.world.snapshot
	if snap == null:
		close("gone")
		return false
	if not force and not _dirty and snap.get_instance_id() == _snap_id and snap.seq == _seq:
		return true
	_snap_id = snap.get_instance_id()
	_seq = snap.seq
	_dirty = false
	scans += 1
	var acts: ItemActions = hands.actions if is_instance_valid(hands.actions) else null
	var cols := InventoryModel.columns(hands.picker, hands.world.tables, acts)
	var col := InventoryModel.find_column(cols, "worn:%d" % bag.uid)
	var c: Variant = col.get("container")
	if col.is_empty() or not c is ItemRef or not (c as ItemRef).same(bag):
		close("gone")
		return false
	bag = c
	var sig := signature(col)
	if sig == _sig and _content != null:
		return true
	_sig = sig
	_build(layout(col))
	return true


## What a hand at `p` (world) would grip in the pack: {kind: "item", item: ItemRef, uid, index, name} (the nearest
## model within ITEM_REACH, not pending, not held), {kind: "frame"} (the handle, the rim, the title band), or {}.
func target_at(p: Vector3) -> Dictionary:
	if state == State.CLOSED or _content == null or not is_inside_tree() or not p.is_finite():
		return {}
	var l := global_transform.affine_inverse() * p
	var best := -1
	var best_d := ITEM_REACH
	for k in items.size():
		var e := items[k]
		if e["pending"] or _held.has(e["uid"]):
			continue
		var d := l.distance_to(e["pos"])
		if d <= best_d:
			best = k
			best_d = d
	if best >= 0:
		var e := items[best]
		return {"kind": "item", "item": (e["row"] as Dictionary)["item"], "uid": e["uid"], "index": best,
				"name": e["name"]}
	if _on_frame(l):
		return {"kind": "frame", "index": -1}
	return {}


## The target under hand i changed: outline it (an item: with its name). Clears the hand's drop highlight.
func hover(i: int, t: Dictionary) -> void:
	if i < 0 or i > 1:
		return
	_set_lit(i, -1)
	if _same(_hover[i], t):
		return
	_hover[i] = t
	if t.is_empty() or state == State.CLOSED:
		_hide_hover(i)
		return
	var box := _outline_box(i)
	var lab := _name_label(i)
	if t.get("kind") == "item" and int(t.get("index", -1)) in range(items.size()):
		var e := items[int(t["index"])]
		var s: float = e["size"]
		box.position = e["pos"]
		box.scale = Vector3.ONE * (s * 1.25)
		lab.text = e["name"]
		lab.position = e["pos"] + Vector3(0, s * 0.5 + 0.015, 0.02)
		lab.visible = not lab.text.is_empty()
	else:
		box.position = handle_local()
		box.scale = Vector3(minf(HANDLE_LEN, _width), 0.03, 0.03)
		lab.visible = false
	box.visible = true


func hovered(i: int) -> Dictionary:
	return _hover[i] if i >= 0 and i <= 1 else {}


## Hand i holds an item at `p`: the compartment it would go into lights up. Returns its index, -1 for none.
func show_drop(i: int, p: Vector3) -> int:
	if i < 0 or i > 1:
		return -1
	if not _hover[i].is_empty():
		hover(i, {})
	var k := compartment_at(p) if state != State.CLOSED else -1
	_set_lit(i, k)
	return k


## The compartment lit for hand i's held item, -1 for none.
func lit(i: int) -> int:
	return _lit[i] if i >= 0 and i <= 1 else -1


## Index of the compartment a held item at `p` (world) is over, -1 for none.
func compartment_at(p: Vector3) -> int:
	if state == State.CLOSED or _content == null or not is_inside_tree() or not p.is_finite():
		return -1
	return _comp_at(global_transform.affine_inverse() * p, true)


## Index of the compartment of pocket `key`, -1 if none.
func compartment_index(key: int) -> int:
	for k in comps.size():
		if comps[k]["key"] == key:
			return k
	return -1


## What letting go of `it` at `p` does: {} (not over a compartment), {kind: "none"} (it is in that pocket already:
## put back, nothing sent), else a container drop for Hands.release ({kind, container: bag, pocket when known}).
## The same mapping as InspectView.plan's worn column.
func drop_for(p: Vector3, it: ItemRef) -> Dictionary:
	if state == State.CLOSED or bag == null or it == null:
		return {}
	var k := compartment_at(p)
	if k < 0:
		return {}
	var key: int = comps[k]["key"]
	if it.uid == bag.uid or (it.carried and it.parent == bag.uid and (key < 0 or key == it.pocket)):
		return {"kind": "none"}
	var d := {"kind": "container", "container": bag}
	if key >= 0:
		d["pocket"] = key
	return d


## World point of item `uid`'s model, INF if not shown.
func item_point(uid: int) -> Vector3:
	for e in items:
		if e["uid"] == uid and is_inside_tree():
			return global_transform * (e["pos"] as Vector3)
	return Vector3.INF


## The model node of item `uid`, null if not shown.
func item_node(uid: int) -> Node3D:
	for e in items:
		if e["uid"] == uid:
			return e["node"]
	return null


## World point in front of compartment k (where a held item goes in), INF if none.
func compartment_point(k: int) -> Vector3:
	if k < 0 or k >= comps.size() or not is_inside_tree():
		return Vector3.INF
	return global_transform * Vector3((float(comps[k]["x0"]) + float(comps[k]["x1"])) * 0.5, 0.0, ITEM_Z + 0.03)


func handle_point() -> Vector3:
	return global_transform * handle_local() if is_inside_tree() else Vector3.INF


## The handle's middle in pack space.
static func handle_local() -> Vector3:
	return Vector3(0, HEIGHT * 0.5 + TITLE_H + HANDLE_UP, 0)


## Where the pack floats when let go in front of a head at `head`: REST_M away, level, toward the hand when it is
## in front (else straight ahead), at the hand's height clamped to chest..waist; its +Z faces the head.
static func rest_pose(head_xf: Transform3D, hand_pos: Vector3) -> Transform3D:
	var o := head_xf.origin if head_xf.origin.is_finite() else Vector3.ZERO
	var z := head_xf.basis.z
	var fwd := -z
	fwd.y = 0.0
	if fwd.length() < 0.01:   # looking straight down or up: the top of the head says where forward is
		fwd = head_xf.basis.y * signf(z.y)
		fwd.y = 0.0
	if not fwd.is_finite() or fwd.length() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var dir := fwd
	var y := o.y - (REST_HIGH + REST_LOW) * 0.5
	if hand_pos.is_finite():
		var to := hand_pos - o
		to.y = 0.0
		if to.length() > 0.05 and to.normalized().dot(fwd) > 0.3:
			dir = to.normalized()
		y = clampf(hand_pos.y, o.y - REST_LOW, o.y - REST_HIGH)
	var pos := o + dir * REST_M
	pos.y = y
	return Transform3D(Basis.looking_at(pos - o, Vector3.UP), pos)


## The pack hanging from a hand (controller transform) by its handle, upright, its front toward the player.
static func hang_pose(hand_xf: Transform3D) -> Transform3D:
	var fwd := -hand_xf.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = hand_xf.basis.y
		fwd.y = 0.0
	if not fwd.is_finite() or fwd.length() < 0.0001:
		fwd = Vector3.FORWARD
	var b := Basis.looking_at(fwd.normalized(), Vector3.UP)
	return Transform3D(b, hand_xf.origin - b * handle_local())


## The layout of an InventoryModel worn column (pack space, x right, y up, +z toward the head): {title, width,
## more, compartments: [{key, title, x0, x1, more, items: [{row, uid, pos, size, name, named, pending}]}]}.
## Malformed groups and rows are skipped (a warning for groups); counts and sizes are bounded.
static func layout(col: Dictionary) -> Dictionary:
	var out := {"title": InventoryModel.clean(str(col.get("title", "")), MAX_TITLE), "width": 0.0,
			"compartments": [], "more": 0}
	var extra := _count(col.get("cut", 0))
	var groups: Variant = col.get("groups")
	var kept: Array[Dictionary] = []
	var total := 0
	if groups is Array:
		for g: Variant in (groups as Array):
			if not g is Dictionary:
				push_warning("vr pack: skipping a malformed pocket group")
				continue
			var gd: Dictionary = g
			var rows := _top_rows(gd)
			var key: Variant = gd.get("key")
			if not key is int or key < -1 or key > Snapshot.MAX_POCKET:
				push_warning("vr pack: skipping a pocket group with a bad key")
				extra += rows.size()
				continue
			if kept.size() >= MAX_POCKETS:
				extra += rows.size()
				continue
			var ml := _count(gd.get("volume_ml", 0), InventoryModel.MAX_ITEM)
			var title := InventoryModel.clean(str(gd.get("title", "")), MAX_TITLE)
			if ml > 0:
				title = (title + "  " + InventoryModel.volume_text(ml)).strip_edges()
			kept.append({"key": key, "title": title, "rows": rows, "ml": ml})
			total += ml
	if kept.is_empty():
		kept.append({"key": -1, "title": EMPTY_TITLE, "rows": [], "ml": 0})
	var widths: Array[float] = []
	var width := GAP * (kept.size() - 1)
	for c in kept:
		var share := float(c["ml"]) / total if total > 0 else 1.0 / kept.size()
		var w := clampf(share * TOTAL_W, MIN_W, MAX_W)
		widths.append(w)
		width += w
	var x := -width * 0.5
	var shown := 0
	for k in kept.size():
		var c := kept[k]
		var rows: Array = c["rows"]
		var n := mini(rows.size(), mini(MAX_PER_POCKET, MAX_SHOWN - shown))
		(out["compartments"] as Array).append({"key": c["key"], "title": c["title"], "x0": x, "x1": x + widths[k],
				"more": mini(rows.size() - n, MAX_COUNT), "items": _grid(rows, n, x, widths[k])})
		shown += n
		x += widths[k] + GAP
	out["width"] = width
	out["more"] = mini(extra, MAX_COUNT)
	return out


## What a layout depends on (titles, keys, volumes, the rows' items, depth, pending, names): a new layout only
## when this changes.
static func signature(col: Dictionary) -> Array:
	var a: Array = [col.get("title"), col.get("cut"), col.get("rows")]
	var gs: Variant = col.get("groups")
	if not gs is Array:
		return a
	for g: Variant in (gs as Array):
		if not g is Dictionary:
			a.append(null)
			continue
		var gd: Dictionary = g
		a.append_array([gd.get("key"), gd.get("title"), gd.get("volume_ml")])
		var rs: Variant = gd.get("rows")
		if not rs is Array:
			continue
		for r: Variant in (rs as Array):
			if r is Dictionary and (r as Dictionary).get("item") is ItemRef:
				var it: ItemRef = (r as Dictionary)["item"]
				a.append_array([it.uid, it.type, it.pocket, (r as Dictionary).get("depth"),
						(r as Dictionary).get("pending"), (r as Dictionary).get("name")])
	return a


# --- inside ---

## A count from data: an int (or whole float) clamped to 0..cap, else 0.
static func _count(v: Variant, cap := MAX_COUNT) -> int:
	if v is int:
		return clampi(v, 0, cap)
	if v is float and is_finite(v):
		return int(clampf(v, 0.0, float(cap)))   # clamped first: a huge float doesn't fit an int
	return 0


## The rows of a group lying right in the pocket (depth 0) with an item.
static func _top_rows(g: Dictionary) -> Array:
	var out := []
	var rs: Variant = g.get("rows")
	if not rs is Array:
		return out
	var a: Array = rs
	for k in mini(a.size(), InventoryModel.MAX_ROWS):
		var r: Variant = a[k]
		if r is Dictionary and (r as Dictionary).get("depth", 0) is int and (r as Dictionary).get("depth", 0) == 0 \
				and (r as Dictionary).get("item") is ItemRef:
			out.append(r)
	return out


## The first `n` rows in a grid filling a compartment from x0, w wide: cells as square as they come, a name under
## each item when the cell is wide enough.
static func _grid(rows: Array, n: int, x0: float, w: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if n <= 0:
		return out
	var cols := clampi(ceili(sqrt(n * w / HEIGHT)), 1, n)
	var lines := ceili(float(n) / cols)
	var cw := w / cols
	var ch := HEIGHT / lines
	var named := cw >= NAME_MIN_W and ch >= LABEL_H * 2.5
	var room := ch - (LABEL_H if named else 0.0)
	var size := clampf(minf(cw, room) * 0.8, 0.01, MAX_ITEM_M)
	for k in n:
		var r: Dictionary = rows[k]
		var it: ItemRef = r["item"]
		var cx := x0 + (k % cols + 0.5) * cw
		var cy := HEIGHT * 0.5 - (k / cols + 0.5) * ch + (LABEL_H * 0.5 if named else 0.0)
		out.append({"row": r, "uid": it.uid, "pos": Vector3(cx, cy, ITEM_Z), "size": size,
				"name": InventoryModel.clean(str(r.get("name", "")), MAX_NAME), "named": named,
				"pending": r.get("pending") == true})
	return out


func _build(lay: Dictionary) -> void:
	_clear()
	builds += 1
	more = lay["more"]
	_width = lay["width"]
	_content = Node3D.new()
	_content.name = "Content"
	add_child(_content)
	var top := HEIGHT * 0.5 + TITLE_H
	_box(Vector3(_width + RIM * 2.0, HEIGHT + TITLE_H + RIM * 2.0, 0.01), Vector3(0, TITLE_H * 0.5, -0.022), "frame")
	_box(Vector3(minf(HANDLE_LEN, _width), 0.018, 0.018), handle_local(), "frame")
	var title: String = lay["title"]
	if more > 0:
		title += "  +%d more" % more
	_label(title, Vector3(0, top + HANDLE_UP + 0.025, 0.0), 0.0003, _content)
	var world := hands.world
	for c: Dictionary in lay["compartments"]:
		var x0: float = c["x0"]
		var x1: float = c["x1"]
		var mid := (x0 + x1) * 0.5
		var comp := {"key": c["key"], "title": c["title"], "x0": x0, "x1": x1, "more": c["more"],
				"mesh": _box(Vector3(x1 - x0, HEIGHT, 0.01), Vector3(mid, 0, -0.012), "pocket")}
		comps.append(comp)
		_label(c["title"], Vector3(mid, HEIGHT * 0.5 + TITLE_H * 0.5, 0.004), 0.00022, _content)
		if int(c["more"]) > 0:
			_label("+%d more" % int(c["more"]), Vector3(mid, -HEIGHT * 0.5 + 0.01, ITEM_Z), 0.00022, _content)
		for e: Dictionary in c["items"]:
			e["comp"] = comps.size() - 1
			e["node"] = _item_node(e, world)
			items.append(e)


## One item model at its cell: scaled to fit (never larger than drawn), centred, dimmed when pending.
func _item_node(e: Dictionary, world: WorldView) -> Node3D:
	var it: ItemRef = (e["row"] as Dictionary)["item"]
	var holder := Node3D.new()
	holder.name = "Item_%d" % it.uid
	holder.position = e["pos"]
	_content.add_child(holder)
	var v := ItemVisual.make(it.type, world)
	var full := maxf(ItemVisual.size_of(it.type, world), 0.001)
	var s := minf(full, float(e["size"]))
	v.scale = Vector3.ONE * s
	v.position = -ItemVisual.grip(it.type, world).origin * (s / full)
	holder.add_child(v)
	for m in v.get_children():
		if m is GeometryInstance3D:
			(m as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if e["pending"]:
				(m as GeometryInstance3D).transparency = DIM
	if e["named"]:
		var l := _label(e["name"], Vector3(0, -float(e["size"]) * 0.5 - 0.007, 0), 0.0002, holder)
		if e["pending"]:
			l.modulate.a = 1.0 - DIM
	return holder


func _box(size: Vector3, pos: Vector3, mat: String) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.position = pos
	mi.material_override = _mat(mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_content.add_child(mi)
	return mi


func _label(text: String, pos: Vector3, px: float, parent: Node3D) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.pixel_size = px
	l.font_size = 32
	l.outline_size = 6
	l.modulate = Color(0.95, 0.93, 0.85)
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(l)
	return l


func _clear() -> void:
	if _content != null and is_instance_valid(_content):
		remove_child(_content)
		_content.queue_free()
	_content = null
	items.clear()
	comps.clear()
	more = 0
	_held = {}   # the rebuilt models hide the held ones again on the next _sync_held
	for i in 2:
		_hover[i] = {}
		_lit[i] = -1
		_hide_hover(i)


func _hide_hover(i: int) -> void:
	if outlines[i] != null and is_instance_valid(outlines[i]):
		outlines[i].visible = false
	if _names[i] != null and is_instance_valid(_names[i]):
		_names[i].visible = false


func _outline_box(i: int) -> MeshInstance3D:
	if outlines[i] == null or not is_instance_valid(outlines[i]):
		var b := BoxMesh.new()
		b.size = Vector3.ONE
		var mi := MeshInstance3D.new()
		mi.name = "PackOutline_%d" % i
		mi.mesh = b
		mi.material_override = _mat("outline")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		outlines[i] = mi
	return outlines[i]


func _name_label(i: int) -> Label3D:
	if _names[i] == null or not is_instance_valid(_names[i]):
		_names[i] = _label("", Vector3.ZERO, 0.00025, self)
		_names[i].name = "PackHoverName_%d" % i
		_names[i].no_depth_test = true
		_names[i].render_priority = 4
	return _names[i]


static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return a.is_empty() and b.is_empty()
	return a.get("kind") == b.get("kind") and a.get("uid") == b.get("uid") and a.get("index") == b.get("index")


func _set_lit(i: int, k: int) -> void:
	if _lit[i] == k:
		return
	var old := _lit[i]
	_lit[i] = k
	for j: int in [old, k]:
		if j >= 0 and j < comps.size():
			var mi: MeshInstance3D = comps[j]["mesh"]
			if is_instance_valid(mi):
				mi.material_override = _mat("lit" if j in _lit else "pocket")


## Compartment under a point in pack space: `drop` = generous (a held item over it), else its panel only.
func _comp_at(l: Vector3, drop: bool) -> int:
	if not l.is_finite():
		return -1
	var pad := GAP * 0.5 if drop else 0.0
	var lo := -HEIGHT * 0.5 - (0.04 if drop else 0.0)
	var hi := HEIGHT * 0.5 + (TITLE_H if drop else 0.0)
	if drop and (l.z < -DROP_BACK or l.z > DROP_FRONT):
		return -1
	if l.y < lo or l.y > hi:
		return -1
	for k in comps.size():
		if l.x >= float(comps[k]["x0"]) - pad and l.x <= float(comps[k]["x1"]) + pad:
			return k
	return -1


## A point in pack space is on the frame: by the handle bar, or on the rim / title band / gaps (not a panel).
func _on_frame(l: Vector3) -> bool:
	var hl := handle_local()
	var half := minf(HANDLE_LEN, _width) * 0.5
	if l.distance_to(Vector3(clampf(l.x, -half, half), hl.y, hl.z)) <= FRAME_REACH:
		return true
	var m := 0.03
	if absf(l.z) > FRAME_REACH or absf(l.x) > _width * 0.5 + RIM + m or l.y < -HEIGHT * 0.5 - RIM - m \
			or l.y > HEIGHT * 0.5 + TITLE_H + RIM + m:
		return false
	return _comp_at(l, false) < 0


## Models of items a hand holds hide (the hand shows them).
func _sync_held() -> void:
	var held := {}
	for id in ids:
		var h := hands.holding(id)
		var it: Variant = h.get("item")
		if h.get("kind") == "item" and it is ItemRef:
			held[(it as ItemRef).uid] = true
	if held == _held:
		return
	_held = held
	for e in items:
		var n: Variant = e["node"]
		if is_instance_valid(n):
			(n as Node3D).visible = not held.has(e["uid"])
	for i in 2:
		if _hover[i].get("kind") == "item" and held.has(_hover[i].get("uid")):
			hover(i, {})


func _on_actions_changed() -> void:
	_dirty = true


func _mat(kind: String) -> StandardMaterial3D:
	if _mats.has(kind):
		return _mats[kind]
	var m := StandardMaterial3D.new()
	match kind:
		"frame":
			m.albedo_color = Color(0.22, 0.2, 0.16)
		"pocket":
			m.albedo_color = Color(0.42, 0.38, 0.28)
		"lit":
			m.albedo_color = Color(0.75, 0.62, 0.25)
			m.emission_enabled = true
			m.emission = Color(0.35, 0.28, 0.08)
		"outline":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_FRONT
			m.grow = true
			m.grow_amount = 0.004
			m.albedo_color = Color(Hands.OUTLINE, 0.9)
	_mats[kind] = m
	return m
