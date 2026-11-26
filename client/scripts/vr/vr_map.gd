class_name VrMap
extends Node3D
## Map slice 1 in VR (lead-vr; docs/MAP.md "The VR view", PLAN.md G5): CDDA's overmap on a paper-like sheet held in
## the off hand. The sheet shows lead-ui's MapCanvas (the one painter both views use; it reads MapData only) in a
## SubViewport. VrRig gives it, per frame, the off hand's pose (place), where the free hand's ray meets the sheet's
## plane (point: the panel laser) and the sticks; and the free hand's trigger (press / release).
## - Pointing at a cell shows CDDA's name for it over the sheet (with the wheel up: the wheel's cell's). Nothing
##   acts on gaze.
## - The trigger pressed and let go having moved under CLICK_M on the sheet (its own frame, so the off hand shaking
##   doesn't count) is a click: on a cell it opens the small wheel for that cell, on the wheel it picks. Moved more,
##   it drags 1:1 (canvas.pan_px): the spot under the ray when the trigger closed stays under it, going on off the
##   sheet on its plane; no fling. While dragging, no name and no wheel.
## - Chevrons in the edges and a drag icon in the lower corner say it scrolls; after the first drag of an opening
##   they fade over FADE_S, and they are back the next time it opens.
## - The off hand's stick pans (VrRig holds walking back meanwhile), its click comes back to the player. The free
##   hand's stick, while its ray is on the sheet, zooms on the pointed cell (up / down) and changes the level
##   (left / right), one step a push; snap turn is held back only then.
## - Only the map on the sheet moves: never the player's view or body.
## - Slice 2 (notes): the wheel on a cell adds a note, or edits one and deletes it (asked again first). The note panel
##   (VrMapNote) takes the ray while it is up. Writes go only through MapData (set_note / delete_note, one at a time);
##   CDDA decides, and a refusal (note_done) is flashed with its own sentence (`said`).
## The canvas is lead-ui's MapCanvas, used duck-typed (cell_at, pan_px, zoom_at, change_level, center_on_player,
## `level`, and its `data` MapData: open / close while the sheet is out, info(cell, level), the note calls and lists):
## a missing method does nothing, so a stand-in works until lead-ui's lands.

signal said(text: String)   # a note for the player: CDDA's refusal of a note, or why it wasn't sent (VrRig flashes it)

const SHEET_M := Vector2(0.3, 0.3)    # the canvas on the sheet, about a folded paper map
const PX := Vector2i(768, 768)        # the canvas's logical pixels (its SubViewport)
const BORDER_M := 0.012               # the paper's margin round the canvas
const CLICK_M := 0.012                # the trigger moved less than this on the sheet: a click; more: a drag
const RAY_M := 2.0                    # m: the free hand's ray reaches the sheet's plane this far
const FADE_S := 0.5                   # the scroll marker fades over this after the first drag of an opening
const PAN_PX_S := 600.0               # px/s the off hand's stick pans at a full push
const DEAD := 0.2                     # the sticks' dead zone
const STEP_ON := 0.6                  # a free-hand stick push past this zooms or changes the level once ...
const STEP_OFF := 0.3                 # ... and again only after it came back under this
const WHEEL_IN_M := 0.012             # the wheel's items: from this far from where it was clicked ...
const WHEEL_OUT_M := 0.075            # ... to this far
const WHEEL_R_M := 0.035              # its labels this far out
const MAX_NAME := 60
const CELL_PX := 24.0                 # the canvas's cell size to start with (its cell_px; the flat view's is 20)
const INK := Color(1.0, 0.95, 0.8)    # the marker and the labels
const PRIORITY := 2                   # the marker and the wheel over the canvas
const MAX_ITEMS := 4                  # wheel items at most (labels made)
const NO_TEXT := "Pick a word for the note first."
const NOT_SENT := "The note couldn't be sent."
const BUSY := "Another note is still on its way."
const MAX_TAGS := 16                  # writes waited on at most (MapData sends one at a time)

var make_canvas := Callable()   # () -> Control: a new canvas on main's MapData (main.gd gives it)
var open_note_dialog := Callable()   # (cell: Vector3i): lead-ui's note dialog on the VR panel, its keys (main.gd)
var note := VrMapNote.new()    # slice 2: the note panel over the sheet
var items: Array[Dictionary] = []   # the open wheel's items: {text, value}
## The sheet in the off hand's frame: a little ahead of and over the hand, tilted back to face the eyes.
var hold := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-50.0)), Vector3(0.0, 0.07, -0.14))
var hand := -1                  # the off hand holding it (0 left, 1 right); -1: put away
var canvas: Control             # the canvas shown, in `viewport`
var viewport: SubViewport
var pointing := false           # the free hand's ray is on the sheet (its stick zooms; no snap turn)
var dragging := false
var marker := 1.0               # the scroll marker's opacity
var wheel_at := Vector2.INF     # the open wheel's middle on the sheet (m, sheet frame); INF: none
var wheel_cell := Vector2i.MAX
var hover := -1                 # the wheel item pointed at, -1 none
var named := Vector2i.MAX       # the cell whose name shows, MAX none
var _p: Variant = null          # where the ray meets the sheet's plane (sheet frame), or null
var _press: Variant = null      # where the trigger closed (sheet frame); null: not pressed
var _last_px := Vector2.ZERO
var _dragged := false           # dragged since this opening: the marker fades
var _stick_armed := true
var _data: Object = null        # the MapData this sheet opened (its reads go on while a view is open)
var _tags := {}                 # MapData's tags of this sheet's note writes still out: a refusal is said
var _mat: StandardMaterial3D
var _ink: StandardMaterial3D
var _name: Label3D
var _marker: Node3D
var _wheel: Node3D
var _labels: Array[Label3D] = []


func _init() -> void:
	name = "Map"
	visible = false
	viewport = SubViewport.new()
	viewport.name = "MapViewport"
	viewport.size = PX
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var paper := StandardMaterial3D.new()
	paper.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paper.albedo_color = Color(0.82, 0.76, 0.62)
	add_child(_quad("Paper", SHEET_M + Vector2.ONE * BORDER_M * 2.0, paper, -0.0005))
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	add_child(_quad("Canvas", SHEET_M, _mat, 0.0))
	_ink = StandardMaterial3D.new()
	_ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ink.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ink.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ink.albedo_color = INK
	_ink.render_priority = PRIORITY
	_marker = _build_marker()
	add_child(_marker)
	_name = _label("CellName", 0.0006)
	_name.position = Vector3(0.0, SHEET_M.y * 0.5 + BORDER_M + 0.012, 0.001)
	add_child(_name)
	_wheel = Node3D.new()
	_wheel.name = "Wheel"
	_wheel.visible = false
	add_child(_wheel)
	for k in MAX_ITEMS:
		var l := _label("Item", 0.0005)
		_wheel.add_child(l)
		_labels.append(l)
	add_child(note)


func _ready() -> void:
	_mat.albedo_texture = viewport.get_texture()


## Freed (or taken out of the tree) with the sheet out: put away, so MapData keeps no user for good.
func _exit_tree() -> void:
	close()


func is_open() -> bool:
	return hand >= 0


## Opens the sheet in off hand `off` (0 left, 1 right) showing canvas `c` (not in a tree yet; it is the sheet's
## until closed). False (nothing changed) for a bad hand or canvas.
func open(off: int, c: Control) -> bool:
	if off < 0 or off > 1 or c == null or c.is_inside_tree():
		return false
	close()
	canvas = c
	viewport.add_child(c)
	c.position = Vector2.ZERO
	c.size = Vector2(PX)
	if "cell_px" in c:
		c.set("cell_px", CELL_PX)
	var d: Variant = c.get("data")
	if d is Object and (d as Object).has_method("open") and (d as Object).has_method("close"):
		_data = d
		_data.call("open")
		if _data.has_signal("note_done") and not _data.is_connected("note_done", _on_note_done):
			_data.connect("note_done", _on_note_done)   # kept: an answer after the sheet closed is still said
		note.set_lists(_const("NOTE_SYMBOLS", ""), _const("NOTE_COLORS", []),
				_const("MAX_DANGER_RADIUS", VrMapNote.MAX_RADIUS))
	_call("refresh", [])   # (lead-ui: after MapData.open, the canvas asks for its pages)
	hand = off
	marker = 1.0
	_dragged = false
	_stick_armed = false   # a stick already pushed (the click that opened it) steps nothing until let go
	visible = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	step(0.0)
	return true


## Puts the sheet away; its canvas goes, and the MapData it opened is closed again.
func close() -> void:
	_call("release", [])   # (before MapData.close: this view's pages are let go)
	if _data != null and is_instance_valid(_data):
		_data.call("close")
	_data = null
	if is_instance_valid(canvas):
		viewport.remove_child(canvas)
		canvas.queue_free()
	canvas = null
	hand = -1
	visible = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	pointing = false
	dragging = false
	_p = null
	_press = null
	named = Vector2i.MAX
	_name.text = ""
	_close_wheel()
	note.close()


## Per frame: the sheet in the off hand at pose `off_xf` (world).
func place(off_xf: Transform3D) -> void:
	if is_open() and off_xf.is_finite():
		global_transform = off_xf * hold


## Per frame: where the free hand's ray meets the sheet's plane (sheet frame, z 0), or null. A held trigger past
## CLICK_M drags.
func point(p: Variant) -> void:
	if not is_open():
		return
	_p = p if p is Vector3 and (p as Vector3).is_finite() else null
	pointing = covers(_p)
	if note.is_open():   # the note panel takes the ray: no drag, no wheel
		note.hover_at(_p)
		return
	if _press != null and _p != null:
		var moved := Vector2((_p as Vector3).x - (_press as Vector3).x, (_p as Vector3).y - (_press as Vector3).y)
		if not dragging and moved.length() > CLICK_M and wheel_at == Vector2.INF:
			dragging = true
			_dragged = true
		if dragging:
			var px := to_px(_p)
			_call("pan_px", [px - _last_px])
			_last_px = px
	hover = _wheel_item(_p)


## The free hand's trigger closed. False (not taken) when its ray isn't on the sheet.
func press() -> bool:
	if not is_open() or not pointing:
		return false
	_press = _p
	_last_px = to_px(_p)
	dragging = false
	return true


## The free hand's trigger opened. A drag ends; a click picks on the wheel (or closes it), else opens the wheel for
## the cell it was on. False when the press wasn't the map's.
func release() -> bool:
	if _press == null:
		return false
	var at := Vector2((_press as Vector3).x, (_press as Vector3).y)
	var was := dragging
	_press = null
	dragging = false
	if was:
		return true
	if note.is_open():
		_note_click(note.click(Vector3(at.x, at.y, 0.0)))
		return true
	if wheel_at != Vector2.INF:
		var v: Variant = items[hover]["value"] if hover >= 0 and hover < items.size() else null
		var mid := wheel_at
		var on := wheel_cell
		_close_wheel()   # (empties items)
		if v != null:
			_choose(v, mid, on)
		return true
	var c := _cell_at(at)
	if c != Vector2i.MAX:
		_open_wheel(at, c)
	return true


## Per frame: the off hand's stick `off` pans; the free hand's `free` zooms (y) or changes the level (x) a push while
## its ray is on the sheet.
func sticks(off: Vector2, free: Vector2, delta: float) -> void:
	if not is_open():
		return
	var o := _dead(off)
	if o != Vector2.ZERO and not dragging:
		_call("pan_px", [Vector2(-o.x, o.y) * PAN_PX_S * delta])
	var l := free.length() if pointing and free.is_finite() and not note.is_open() else 0.0
	if l < STEP_OFF:
		_stick_armed = true
	elif _stick_armed and l > STEP_ON:
		_stick_armed = false
		if absf(free.y) >= absf(free.x):
			_call("zoom_at", [to_px(_p), 1 if free.y > 0.0 else -1])
		else:
			_call("change_level", [1 if free.x > 0.0 else -1])


## The off hand's stick click: back to the player's cell and level.
func centre() -> void:
	_call("center_on_player", [])


## Per frame: the marker fades after the first drag; the pointed cell's name; the wheel item pointed at.
func step(delta: float) -> void:
	if not is_open():
		return
	if _dragged:
		marker = move_toward(marker, 0.0, delta / FADE_S)
	_ink.albedo_color = Color(INK, marker)
	_marker.visible = marker > 0.0
	var c := _cell_at(Vector2((_p as Vector3).x, (_p as Vector3).y)) if pointing and not dragging else Vector2i.MAX
	if wheel_at != Vector2.INF:
		c = wheel_cell   # the wheel's title: its cell's name
	if c != named or (c != Vector2i.MAX and _name.text.is_empty()):   # (a page read later names it then)
		named = c
		_name.text = "" if c == Vector2i.MAX else _name_of(c)
	for k in _labels.size():
		_labels[k].modulate = Color(1.0, 0.85, 0.3) if k == hover else INK


## A point on the sheet's plane (sheet frame) is on the canvas.
static func covers(p: Variant) -> bool:
	if not p is Vector3 or not (p as Vector3).is_finite():
		return false
	var v: Vector3 = p
	return absf(v.x) <= SHEET_M.x * 0.5 and absf(v.y) <= SHEET_M.y * 0.5


## A point on the sheet's plane (sheet frame; a Vector3 or its x, y) in the canvas's pixels.
static func to_px(p: Variant) -> Vector2:
	var v := Vector2((p as Vector3).x, (p as Vector3).y) if p is Vector3 else p as Vector2
	return Vector2((v.x / SHEET_M.x + 0.5) * PX.x, (0.5 - v.y / SHEET_M.y) * PX.y)


func _choose(v: Variant, mid: Vector2, c: Vector2i) -> void:
	if v == "centre":   # that spot to the sheet's middle
		_call("pan_px", [Vector2(PX) * 0.5 - to_px(mid)])
	elif v == "close":
		close()
	elif v == "note":   # slice 2: the note panel for that cell (its note, if any, to edit; its colour as a code)
		var n := _note_of(c).duplicate()
		if n.has("color"):
			var code: Variant = _data_call("note_color_code", [n["color"]]) if n["color"] is Color else n["color"]
			n["color"] = code if code is String else ""
		note.open(c, _level(), _name_of(c), n, open_note_dialog.is_valid())
	elif v == "unnote":   # asked again first: deleting can't be undone
		_open_wheel(mid, c, [{"text": "Delete it", "value": "unnote!"}, {"text": "Keep it", "value": "keep"}])
	elif v == "unnote!":
		_send("delete_note", [Vector3i(c.x, c.y, _level())])


## The note panel's answer: save sends the note through MapData (CDDA decides; a refusal comes as `said`), cancel
## closes it, keyboard hands the cell to lead-ui's flat dialog.
func _note_click(what: String) -> void:
	if what == "save":
		var r := note.result()
		if (r["text"] as String).strip_edges().is_empty():
			said.emit(NO_TEXT)
			return
		if _data_call("writing", []) == true:   # the panel stays, to save again
			said.emit(BUSY)
			return
		note.close()
		var c: Vector2i = r["cell"]
		_send("set_note", [Vector3i(c.x, c.y, r["z"]), r["text"], r["symbol"], r["color"], r["danger"], r["radius"]])
	elif what == "cancel":
		note.close()
	elif what == "keyboard":
		var at := Vector3i(note.cell.x, note.cell.y, note.z)
		note.close()
		open_note_dialog.call(at)


## The wheel's items for cell `c`: its note added, or edited and deleted.
func _items_for(c: Vector2i) -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"text": "Centre here", "value": "centre"}]
	if _note_of(c).is_empty():
		out.append({"text": "Add note", "value": "note"})
	else:
		out.append({"text": "Edit note", "value": "note"})
		out.append({"text": "Delete note", "value": "unnote"})
	out.append({"text": "Close map", "value": "close"})
	return out


## A note write through MapData (`m`: set_note / delete_note): its tag is waited on; 0 (refused here) says so.
func _send(m: String, args: Array) -> void:
	if _data_call("writing", []) == true:
		said.emit(BUSY)
		return
	var t: Variant = _data_call(m, args)
	if not t is int or t == 0:
		said.emit(NOT_SENT)
		return
	if _tags.size() >= MAX_TAGS:   # answers that never came: not waited on for good
		_tags = {}
	_tags[t] = true


## MapData's answer to a write (note_done): one of this sheet's refused says CDDA's sentence (else NOT_SENT).
func _on_note_done(tag: Variant, ok: Variant, text: Variant) -> void:
	if not _tags.has(tag):
		return
	_tags.erase(tag)
	if ok != true:
		var t := (text as String).strip_edges() if text is String else ""
		said.emit(t if not t.is_empty() else NOT_SENT)


## MapData's script constant `k`, else `fallback` (missing, or of another type).
func _const(k: String, fallback: Variant) -> Variant:
	var s: Variant = _data.get_script() if _data != null else null
	var v: Variant = (s as Script).get_script_constant_map().get(k) if s is Script else null
	return v if typeof(v) == typeof(fallback) else fallback


func _level() -> int:
	var lv: Variant = canvas.get("level") if is_instance_valid(canvas) else null
	return lv if lv is int else 0


## Calls MapData's `m` (the canvas's data); null when there is none or it has no such call.
func _data_call(m: String, args: Array) -> Variant:
	var d: Variant = canvas.get("data") if is_instance_valid(canvas) else null
	if d is Object and (d as Object).has_method(m):
		return (d as Object).callv(m, args)
	return null


## Cell `c`'s note on the shown level (MapData.info's "note": {text, symbol, color, danger, radius}), {} none.
func _note_of(c: Vector2i) -> Dictionary:
	var r: Variant = _data_call("info", [c, _level()])
	var n: Variant = (r as Dictionary).get("note") if r is Dictionary else null
	return n if n is Dictionary else {}


func _call(m: String, args: Array) -> Variant:
	if is_instance_valid(canvas) and canvas.has_method(m):
		return canvas.callv(m, args)
	return null


func _cell_at(at: Vector2) -> Vector2i:
	var v: Variant = _call("cell_at", [to_px(at)])
	return v if v is Vector2i else Vector2i.MAX


## CDDA's name for cell `c` on the canvas's level (MapData.info), "" unseen or not read yet.
func _name_of(c: Vector2i) -> String:
	if not is_instance_valid(canvas):
		return ""
	var d: Variant = canvas.get("data")
	var lv: Variant = canvas.get("level")
	if not d is Object or not (d as Object).has_method("info"):
		return ""
	var r: Variant = (d as Object).call("info", c, lv if lv is int else 0)
	var n: Variant = (r as Dictionary).get("name") if r is Dictionary else null
	return (n as String).strip_edges().left(MAX_NAME) if n is String else ""


## The wheel item at point `p` (sheet frame), -1 none: the sector around the wheel's middle it is in.
func _wheel_item(p: Variant) -> int:
	if wheel_at == Vector2.INF or not p is Vector3:
		return -1
	var d := Vector2((p as Vector3).x, (p as Vector3).y) - wheel_at
	var l := d.length()
	if l < WHEEL_IN_M or l > WHEEL_OUT_M:
		return -1
	var n := items.size()
	if n == 0:
		return -1
	return int(fposmod(atan2(d.x, d.y) + PI / n, TAU) / (TAU / n)) % n


## The wheel at `at` (sheet frame) for cell `c`: `list` ({text, value}), else the cell's own items.
func _open_wheel(at: Vector2, c: Vector2i, list: Array[Dictionary] = []) -> void:
	wheel_at = at
	wheel_cell = c
	items = list if not list.is_empty() else _items_for(c)
	items = items.slice(0, MAX_ITEMS)
	var n := items.size()
	for k in _labels.size():
		var a := TAU * k / maxi(n, 1)   # the first item up, then clockwise
		_labels[k].position = Vector3(at.x + sin(a) * WHEEL_R_M, at.y + cos(a) * WHEEL_R_M, 0.002)
		_labels[k].visible = k < n
		_labels[k].text = items[k]["text"] if k < n else ""
	_wheel.visible = true


func _close_wheel() -> void:
	wheel_at = Vector2.INF
	wheel_cell = Vector2i.MAX
	hover = -1
	items = []
	if _wheel != null:
		_wheel.visible = false


static func _dead(v: Vector2) -> Vector2:
	if not v.is_finite():
		return Vector2.ZERO
	var l := minf(v.length(), 1.0)
	return Vector2.ZERO if l < DEAD else v.normalized() * inverse_lerp(DEAD, 1.0, l)


## Chevrons inside the canvas's edges and a four-way arrow in its lower right corner.
func _build_marker() -> Node3D:
	var m := Node3D.new()
	m.name = "ScrollMarker"
	var tri := _triangle(0.024, 0.012)
	var e := SHEET_M * 0.5 - Vector2(0.014, 0.014)
	for k in 4:   # up, right, down, left: each points out over its edge
		var a := -PI * 0.5 * k
		var c := MeshInstance3D.new()
		c.name = "Chevron"
		c.mesh = tri
		c.material_override = _ink
		c.transform = Transform3D(Basis(Vector3.BACK, a), Vector3(-sin(a) * e.x, cos(a) * e.y, 0.001))
		m.add_child(c)
	var icon := Node3D.new()
	icon.name = "DragIcon"
	icon.position = Vector3(SHEET_M.x * 0.5 - 0.03, -SHEET_M.y * 0.5 + 0.03, 0.001)
	var small := _triangle(0.01, 0.007)
	for k in 4:
		var a := -PI * 0.5 * k
		var t := MeshInstance3D.new()
		t.mesh = small
		t.material_override = _ink
		t.transform = Transform3D(Basis(Vector3.BACK, a), Vector3(-sin(a), cos(a), 0.0) * 0.009)
		icon.add_child(t)
	var dot := _quad("Palm", Vector2(0.008, 0.008), _ink, 0.0)
	dot.material_override = _ink
	icon.add_child(dot)
	m.add_child(icon)
	return m


static func _quad(n: String, size: Vector2, mat: Material, z: float) -> MeshInstance3D:
	var q := QuadMesh.new()   # faces +Z: the eyes' side
	q.size = size
	q.material = mat
	var mi := MeshInstance3D.new()
	mi.name = n
	mi.mesh = q
	mi.position.z = z
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A triangle `w` wide pointing `h` up +Y from its base on the origin.
static func _triangle(w: float, h: float) -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-w * 0.5, 0.0, 0.0), Vector3(0.0, h, 0.0),
			Vector3(w * 0.5, 0.0, 0.0)])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return m


func _label(n: String, px: float) -> Label3D:
	var l := Label3D.new()
	l.name = n
	l.pixel_size = px
	l.font_size = 32
	l.outline_size = 10
	l.modulate = INK
	l.render_priority = PRIORITY + 1
	l.outline_render_priority = PRIORITY
	l.shaded = false
	l.double_sided = false
	return l
