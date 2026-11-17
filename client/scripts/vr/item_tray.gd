class_name ItemTray
extends Node3D
## Block L8 slices 3-4: a tray in front of the player that lays out what a container lying next to the player holds
## (the snapshot's `inside`, one level) or the items of a big pile on a square next to the player (its handles: up
## to Snapshot.MAX_HANDLES_NEAR there, more than PropMesher draws), PAGE at a time in CDDA's inventory order (sort_rows), with page
## arrows and "+N more" for what the bridge didn't list. Looking is the client's own business (CDDA charges nothing
## to look): opening, paging and closing send nothing. Items on it are ordinary ItemRefs (one in a container:
## `parent` = the container, `pocket`, `square` = the container's square), taken through the shared Hands like any
## lying item (target_at gives Hands' item target: VR grips it; target_on_ray for a mouse). It closes when what it
## shows is gone, empty or no longer next to the player, or the head moves away (CLOSE_M). top_level: walking
## leaves it where it is.
##
## Names come from game data: cleaned and capped here. Rebuilt only when the rows change (a new snapshot seq, then
## a signature compare); the per-frame work is a few distance checks.

## The tray closed: "closed" (the trigger on its frame), "far", "gone" (what it showed, or the world), "empty".
signal closed(why: String)

const COLS := 4
const ROWS := 3
const PAGE := COLS * ROWS
const CELL := 0.11            # m: an item cell
const MAX_ITEM_M := 0.08      # an item model's longest side on the tray
const NAME_PX := 0.0002       # an item's name (and its live state, VrTile) under it
const ITEM_Z := 0.035         # items float this far in front of the board
const RIM := 0.02
const TITLE_H := 0.035
const FOOT_H := 0.025         # band under the cells for "+N more"
const ARROW_W := 0.05
const ITEM_REACH := 0.06      # a hand grips an item within this of its cell centre
const ARROW_REACH := 0.05
## Item categories in CDDA's inventory order (data/json/item_category.json sort_rank, lowest first). A category not
## listed sorts where CDDA's default rank 0 would (before chems, UNLISTED_RANK); an item with no definition last.
const CATEGORY_ORDER: Array[String] = ["e_files", "software", "guns", "magazines", "ammo", "weapons", "tools", "food",
		"drugs", "manuals", "books", "tool_magazine", "maps", "mods", "bionics", "mutagen", "currency", "veh_parts", "other",
		"fuel", "seeds", "ma_manuals", "traps", "chems", "spare_parts", "container", "artifacts", "keys", "corpses",
		"clothing", "armor", "exosuit"]
const UNLISTED_RANK := 22.5   # between traps (22) and chems (23)
const FRAME_DEPTH := 0.08     # a hand this near the board's plane (and over it) touches the frame
const REST_M := 0.45          # opened this far in front of the head ...
const REST_LOW := 0.4         # ... and this far under it
const CLOSE_M := 1.5          # the head farther than this: it closes
const MIN_PILE := 6           # a pile opens on the tray from this many items (fewer are gripped where they lie)
const MAX_NAME := 16          # characters of a name under an item
const MAX_TITLE := 32
const MAX_COUNT := 100000     # "+N more" is capped to this
const HOVER_SCALE := 1.2

## The shared hands (VrRig sets it).
var hands: Hands
var world: WorldView
var head: Node3D
## Where open() puts it: this far in front of the head and this far under it (the desktop: nearer the view).
var rest_m := REST_M
var rest_low := REST_LOW
## Hands ids whose held items hide on the tray.
var ids: Array[String] = ["vr_l", "vr_r", "mouse"]
## {kind: "container", uid, type, square} or {kind: "pile", square}; {} while closed.
var source := {}
var page := 0
var rows: Array[ItemRef] = []          # everything listed, in CDDA's order
var items: Array[Dictionary] = []      # this page's: {item: ItemRef, pos: Vector3 (local), name, node}
var more := 0                          # not listed by the bridge (inside_more / more)
var title := ""
var builds := 0                        # layouts built (tests)
var _content: Node3D
var _sig: Array = []
var _seq := -1
var _held := {}
var _hover: Array[int] = [-1, -1]       # item index hovered per VR hand
var _mats := {}


func _init() -> void:
	top_level = true
	visible = false


func is_open() -> bool:
	return not source.is_empty()


## What touching lying item `it` opens: the container it is (the snapshot lists what is inside it), else the big
## pile it lies in (MIN_PILE or more items, counting the unlisted); {} for neither, a carried item or a square not
## next to the player.
static func source_for(snap: Snapshot, it: ItemRef) -> Dictionary:
	if snap == null or it == null or it.carried or it.parent != 0 or not ItemActions.ok_square(it.square):
		return {}
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(it.square))
	var tile := ItemActions.tile_of(it.square)
	if sm == null or not snap.near_player(sm.pos, tile) or ItemActions.lying_type(snap, it.uid, it.square) != it.type:
		return {}
	if sm.inside.has(it.uid) or sm.inside_more.get(it.uid, 0) > 0:
		return {"kind": "container", "uid": it.uid, "type": it.type, "square": it.square}
	var n := 0
	for i in range(0, sm.handles.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if sm.handles[i] == tile:
			n += 1
	if n + mini(int(sm.more.get(tile, 0)), MAX_COUNT) >= MIN_PILE:
		return {"kind": "pile", "square": it.square}
	return {}


## What `src` shows in `snap`: {rows: Array[ItemRef], more: int}; {} when it is gone (the container no longer lying
## there, the square no longer next to the player or not in the snapshot). With `tables` the rows are sorted
## (sort_rows), else they stay in the snapshot's order.
static func list(snap: Snapshot, src: Dictionary, tables: IdTables = null) -> Dictionary:
	var sq: Variant = src.get("square")
	if snap == null or not sq is Vector3i or not ItemActions.ok_square(sq):
		return {}
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(sq))
	var tile := ItemActions.tile_of(sq)
	if sm == null or not snap.near_player(sm.pos, tile):
		return {}
	var out: Array[ItemRef] = []
	var n := 0
	if src.get("kind") == "container":
		var c: int = src.get("uid", 0)
		if c <= 0 or ItemActions.lying_type(snap, c, sq) != src.get("type"):
			return {}
		for r: Array in sm.inside.get(c, []):
			var it := ItemRef.on_square(r[0], r[1], sq)
			it.parent = c
			it.pocket = r[2]
			out.append(it)
		n = sm.inside_more.get(c, 0)
	elif src.get("kind") == "pile":
		var h := sm.handles
		for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
			if h[i] == tile:
				out.append(ItemRef.on_square(h[i + 1], h[i + 2], sq))
		n = sm.more.get(tile, 0)
	else:
		return {}
	if tables != null:
		sort_rows(out, tables)
	return {"rows": out, "more": clampi(n, 0, MAX_COUNT)}


## Sorts `rows` in place the way CDDA's inventory lists items: by category (CATEGORY_ORDER), then name (ignoring
## case), then uid, so a refresh never shuffles them. Items the tables don't know go last.
static func sort_rows(rows: Array[ItemRef], tables: IdTables) -> void:
	var keyed: Array = []
	for it in rows:
		var d := it.def(tables)
		var cat := d.category if d != null else ""
		var r := float(CATEGORY_ORDER.find(cat))
		if d == null:
			r = CATEGORY_ORDER.size()
		elif r < 0.0:
			r = UNLISTED_RANK
		keyed.append([r, cat, (d.name if not d.name.is_empty() else d.id).to_lower() if d != null else "", it.uid, it])
	keyed.sort_custom(func(a: Array, b: Array) -> bool:
		for k in 4:
			if a[k] != b[k]:
				return a[k] < b[k]
		return false)
	for k in keyed.size():
		rows[k] = keyed[k][4]


## Opens the tray on `src` (source_for) in front of the head pose `head_xf`. False when there is nothing to show.
func open(src: Dictionary, head_xf: Transform3D) -> bool:
	if world == null or src.is_empty() or not head_xf.is_finite():
		return false
	var l := list(world.snapshot, src, world.tables)
	if l.is_empty() or ((l["rows"] as Array).is_empty() and l["more"] == 0):
		return false
	source = src.duplicate()
	page = 0
	_sig = []
	global_transform = rest_pose(head_xf, rest_m, rest_low)
	visible = true
	refresh(true)
	return is_open()


func close(why := "") -> void:
	if not is_open():
		return
	source = {}
	rows.clear()
	_clear()
	visible = false
	closed.emit(why)


func pages() -> int:
	return maxi(1, ceili(float(rows.size()) / PAGE))


## Turns `d` pages (wrapping). False when there is only one.
func turn_page(d: int) -> bool:
	if not is_open() or pages() <= 1:
		return false
	page = posmod(page + d, pages())
	refresh(true)
	return true


## Per frame: closes when the head walked off, rebuilds on a newer snapshot when the rows changed, hides what a
## hand holds.
func update() -> void:
	if not is_open():
		return
	if world == null or not is_instance_valid(world):
		close("gone")
		return
	if head != null and is_instance_valid(head) and head.global_position.distance_to(global_position) > CLOSE_M:
		close("far")
		return
	if world.snapshot != null and world.snapshot.seq != _seq:
		refresh()
	_sync_held()


## Reads the rows again; rebuilds the layout when they (or the page) changed. False when the tray closed.
func refresh(force := false) -> bool:
	if not is_open():
		return false
	var snap := world.snapshot if world != null else null
	var l := list(snap, source, world.tables if world != null else null)
	if l.is_empty():
		close("gone")
		return false
	_seq = snap.seq
	rows.assign(l["rows"])
	more = l["more"]
	if rows.is_empty() and more == 0:
		close("empty")
		return false
	page = clampi(page, 0, pages() - 1)
	var sig: Array = [page, more]
	for it in rows:
		sig.append_array([it.uid, it.type])
	if not force and sig == _sig:
		_dress_all()
		return true
	_sig = sig
	_build()
	return true


## The tray's pose: `m` in front of the head (level), `low` under it, the board facing the head.
static func rest_pose(head_xf: Transform3D, m := REST_M, low := REST_LOW) -> Transform3D:
	var f := -head_xf.basis.z
	f.y = 0.0
	f = f.normalized() if f.length() > 0.01 else Vector3.FORWARD
	var o := head_xf.origin + f * m + Vector3.DOWN * low
	var n := (head_xf.origin - o).normalized()
	var x := Vector3.UP.cross(n).normalized()
	return Transform3D(Basis(x, n.cross(x), n), o)


## Local centre of cell k (0 .. PAGE - 1), left to right, top to bottom.
static func cell_pos(k: int) -> Vector3:
	return Vector3((k % COLS - (COLS - 1) * 0.5) * CELL, ((ROWS - 1) * 0.5 - k / COLS) * CELL, ITEM_Z)


## Local centre of the page arrow `d` (-1 left, +1 right).
static func arrow_pos(d: int) -> Vector3:
	return Vector3(signf(d) * (COLS * CELL * 0.5 + RIM + ARROW_W * 0.5), 0.0, ITEM_Z * 0.5)


## What a hand at world point `p` touches: an item ({kind: "item", item, point, square, dist, name}, as Hands
## takes it), a page arrow ({kind: "page", dir}), the frame ({kind: "frame"}) or {}.
func target_at(p: Vector3) -> Dictionary:
	if not is_open() or _content == null or not p.is_finite() or not is_inside_tree():
		return {}
	var l := global_transform.affine_inverse() * p
	var best := -1
	var best_d := ITEM_REACH
	for k in items.size():
		var it: ItemRef = items[k]["item"]
		if _held.has(it.uid):
			continue
		var d := l.distance_to(items[k]["pos"])
		if d <= best_d:
			best = k
			best_d = d
	if best >= 0:
		return _item_target(best, best_d)
	if pages() > 1:
		for d: int in [-1, 1]:
			if l.distance_to(arrow_pos(d)) <= ARROW_REACH:
				return {"kind": "page", "dir": d}
	if absf(l.z) <= FRAME_DEPTH and absf(l.x) <= _half_w() and l.y <= _top() and l.y >= _bottom():
		return {"kind": "frame"}
	return {}


## The same for a ray (a mouse pointer): where it meets the board's plane, from the front, within `max_m`.
func target_on_ray(origin: Vector3, dir: Vector3, max_m := 3.0) -> Dictionary:
	if not is_open() or not origin.is_finite() or not dir.is_finite() or dir.length() < 0.001:
		return {}
	var n := global_transform.basis.z.normalized()
	var den := dir.normalized().dot(n)
	if den >= -0.001:
		return {}
	var t := (global_position + n * ITEM_Z - origin).dot(n) / (dir.normalized().dot(n))
	if t < 0.0 or t > max_m:
		return {}
	var hit := origin + dir.normalized() * t
	var l := global_transform.affine_inverse() * hit
	for k in items.size():
		var it: ItemRef = items[k]["item"]
		var c: Vector3 = items[k]["pos"]
		if not _held.has(it.uid) and absf(l.x - c.x) <= CELL * 0.5 and absf(l.y - c.y) <= CELL * 0.5:
			return _item_target(k, t)
	if pages() > 1:
		for d: int in [-1, 1]:
			var a := arrow_pos(d)
			if absf(l.x - a.x) <= ARROW_W * 0.5 and absf(l.y - a.y) <= CELL * 0.5:
				return {"kind": "page", "dir": d}
	if absf(l.x) <= _half_w() and l.y <= _top() and l.y >= _bottom():
		return {"kind": "frame"}
	return {}


## VR hand i hovers target `t` (target_at): an item grows a little.
func hover(i: int, t: Dictionary) -> void:
	if i < 0 or i > 1:
		return
	var k: int = t.get("index", -1) if t.get("kind") == "item" else -1
	if k == _hover[i]:
		return
	_scale_item(_hover[i], 1.0)
	_hover[i] = k
	_scale_item(k, HOVER_SCALE)


## The map's origin moved: the tray moves with it.
func shift(d: Vector3) -> void:
	if d.is_finite():
		position += d


func _item_target(k: int, dist: float) -> Dictionary:
	var e := items[k]
	var it: ItemRef = (e["item"] as ItemRef).duplicate_ref()
	it.point = global_transform * (e["pos"] as Vector3)
	it.size_m = MAX_ITEM_M
	return {"kind": "item", "node": null, "item": it, "square": it.square, "point": it.point, "dist": dist,
			"name": e["name"], "index": k}


func _half_w() -> float:
	return COLS * CELL * 0.5 + RIM + ARROW_W


func _top() -> float:
	return ROWS * CELL * 0.5 + TITLE_H


func _bottom() -> float:
	return -ROWS * CELL * 0.5 - FOOT_H


func _name(it: ItemRef) -> String:
	var t := world.tables if world != null else null
	return InventoryModel.clean(it.display_name(t) if t != null else "item", MAX_NAME)


func _build() -> void:
	_clear()
	builds += 1
	_content = Node3D.new()
	_content.name = "Tray"
	add_child(_content)
	var w := _half_w() * 2.0
	var h := _top() - _bottom()
	_box(Vector3(w, h, 0.008), Vector3(0, (_top() + _bottom()) * 0.5, -0.004), "board")
	var from := page * PAGE
	for k in mini(PAGE, rows.size() - from):
		var it := rows[from + k]
		var e := {"item": it, "pos": cell_pos(k), "name": _name(it)}
		e["node"] = _item_node(e)
		items.append(e)
	if pages() > 1:
		for d: int in [-1, 1]:
			_box(Vector3(ARROW_W * 0.8, CELL * 0.8, 0.01), arrow_pos(d), "arrow")
			_label("<" if d < 0 else ">", arrow_pos(d) + Vector3(0, 0, 0.01), 0.0006, _content)
	var what := "items"
	if source.get("kind") == "container" and world != null and world.tables != null:
		what = InventoryModel.clean(ItemRef.on_square(source["uid"], source["type"], source["square"]).display_name(world.tables), MAX_TITLE)
	title = what if pages() <= 1 else "%s  %d/%d" % [what, page + 1, pages()]
	_label(title, Vector3(0, ROWS * CELL * 0.5 + TITLE_H * 0.5, 0.004), 0.0003, _content)
	if more > 0:
		_label("+%d more" % more, Vector3(0, -ROWS * CELL * 0.5 - FOOT_H * 0.5, 0.004), 0.00025, _content)
	_held = {}
	_sync_held()


func _item_node(e: Dictionary) -> Node3D:
	var it: ItemRef = e["item"]
	var holder := Node3D.new()
	holder.name = "Item_%d" % it.uid
	holder.position = e["pos"]
	_content.add_child(holder)
	if world != null:
		var v := ItemVisual.make(it.type, world)
		var full := maxf(ItemVisual.size_of(it.type, world), 0.001)
		var s := minf(full, MAX_ITEM_M)
		v.scale = Vector3.ONE * s
		v.position = -ItemVisual.grip(it.type, world).origin * (s / full)
		holder.add_child(v)
		for m in v.get_children():
			if m is GeometryInstance3D:
				(m as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		e["visual"] = v
		ItemLookView.dress_from(v, it.uid, world.snapshot, world.tables)
	# the name, and under it the live state in a short line (VrTile.tag: "250 ml orange juice, cold")
	var l := _label(VrTile.line(e["name"], VrTile.of(world, it.uid), true),
			Vector3(0, -MAX_ITEM_M * 0.5 - 0.008 + NAME_PX * 16.0, 0), NAME_PX, holder)
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP   # a second line goes down, the name stays put
	e["label"] = l
	return holder


## Each item model wears its live look as items lying in the world do (ItemLookView.dress_from: frost, heat,
## spoilage, liquid level, grime), and its label says it (VrTile.line): when it is made and again on each newer
## snapshot.
func _dress_all() -> void:
	var snap := world.snapshot if world != null and is_instance_valid(world) else null
	for e: Dictionary in items:
		var uid := (e["item"] as ItemRef).uid
		var v: Variant = e.get("visual")
		if is_instance_valid(v) and v is Node3D:
			ItemLookView.dress_from(v, uid, snap, world.tables if snap != null else null)
		var l: Variant = e.get("label")
		if is_instance_valid(l) and l is Label3D:
			(l as Label3D).text = VrTile.line(str(e.get("name", "")), VrTile.of(world, uid) if snap != null else {}, true)


func _scale_item(k: int, s: float) -> void:
	if k >= 0 and k < items.size() and is_instance_valid(items[k]["node"]):
		(items[k]["node"] as Node3D).scale = Vector3.ONE * s


func _sync_held() -> void:
	var now := {}
	if hands != null and is_instance_valid(hands):
		for id in ids:
			var t := hands.holding(id)
			if t.get("kind") == "item" and t.get("item") is ItemRef:
				now[(t["item"] as ItemRef).uid] = true
	if now == _held:
		return
	_held = now
	for e in items:
		if is_instance_valid(e["node"]):
			(e["node"] as Node3D).visible = not _held.has((e["item"] as ItemRef).uid)


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


func _mat(kind: String) -> StandardMaterial3D:
	if not _mats.has(kind):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.16, 0.15, 0.13) if kind == "board" else Color(0.55, 0.52, 0.45)
		m.roughness = 0.9
		_mats[kind] = m
	return _mats[kind]


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
	_held = {}
	_hover = [-1, -1]
