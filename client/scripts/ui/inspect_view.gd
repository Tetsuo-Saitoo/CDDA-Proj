class_name InspectView
extends Control
## Blocks E6 / L8: the Tab inspect view. A panel with one column per place items can be (InventoryModel: your
## hands, each worn container by pocket, loose on you, the ground in reach by square); drag a row onto another
## column, a pocket / square heading or a container row to move it. Every move is one or two one-item CDDA actions
## through the shared Hands ("inspect" is its hand id), so CDDA's rules decide and a refusal shows its reason in
## the status line. Rows of items in flight are greyed and can't be dragged. Rebuilt on ItemActions.changed and
## when main shows a new snapshot (refresh), at most once a frame. No screen size, OS cursor or global mouse
## position is used, so it works inside a SubViewport (VR panel). Item names are game data: plain Label text only,
## cleaned and capped by InventoryModel.
##
## Keys: Tab (the `inspect` action) opens it (main.gd, when allowed) and closes it, as does Esc; while open it
## takes those keys before the game (_input). Opening shows the mouse cursor, closing puts the old mouse mode back.
##
## Selecting several rows: a click selects a row, Ctrl+click adds or removes one, Shift+click selects the rows of a
## column from the last clicked one; pressing a row's [ ] box and dragging over other rows sets them all as that
## box became (no modifier keys needed: VR pointers). Esc clears the selection before it closes the view. The
## selection is kept across rebuilds by uid and itype while the item is listed; opening the view starts empty.

signal opened
signal closed

const HAND := "inspect"          # the Hands id of moves started here
const COLUMN_W := 240.0
const INDENT := 14.0
const MAX_STATUS := 200
const PENDING := Color(1, 1, 1, 0.4)
const DIM := Color(0.65, 0.65, 0.7)
const BAD := Color(1.0, 0.5, 0.45)
const BOX := Color(0.7, 0.85, 1.0)   # container rows
const SELECTED := Color(0.25, 0.4, 0.7, 0.5)
const TICK_ON := "[x]"
const TICK_OFF := "[ ]"
const NOT_YET := "Taking a carried item into your hands: not yet."
const CANT := "You can't move that there now."
const CANT_TAKE := "You can't take that now."

var hands: Hands
var actions: ItemActions
## (set_to: int) -> int: sets the mouse mode when set_to >= 0 and returns the mode now. Not set: Input.mouse_mode
## (tests set a fake).
var mouse_hook := Callable()
## The columns shown (InventoryModel.columns, newest rebuild).
var cols: Array[Dictionary] = []
## The status line: the last refusal or local "can't".
var status := ""
## The rows picked to act on together: uid -> itype.
var selection := {}

var _prev_mouse: int = Input.MOUSE_MODE_VISIBLE
var _dirty := false
var _box: HBoxContainer
var _head: Label
var _status: Label
var _row_slots := {}     # uid -> InspectSlot
var _col_slots := {}     # column id -> InspectSlot
var _group_slots := {}   # "column id|key" -> InspectSlot
var _ticks := {}         # uid -> the row's [ ] box
var _row_col := {}       # uid -> column id
var _col_uids := {}      # column id -> [uid, ...] in listing order
var _anchor := -1        # the row last clicked (Shift+click selects from it)
var _click_uid := -1     # a plain press on a selected row: only it stays selected when let go without a drag
var _paint := false      # a [ ] box was pressed and the button is still down
var _paint_on := false   # what the rows a drag passes become
var _paint_uid := -1     # the row the drag is on
var _sel_style := _style(SELECTED, 0)
var _no_style := StyleBoxEmpty.new()


func _init(h: Hands, a: ItemActions) -> void:
	name = "InspectView"
	hands = h
	actions = a
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # nothing behind it gets clicks while it is open
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 40
	panel.offset_top = 40
	panel.offset_right = -40
	panel.offset_bottom = -40
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_theme_stylebox_override("panel", _style(Color(0.07, 0.07, 0.09, 0.95), 12))
	add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	_head = _label("", Color(1.0, 0.85, 0.3))
	v.add_child(_head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # each column scrolls on its own
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(scroll)
	_box = HBoxContainer.new()
	_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_box)
	_status = _label("", BAD)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.visible = false
	v.add_child(_status)
	if a != null:
		a.changed.connect(refresh)
	if h != null:
		h.refused.connect(_on_refused)


## Shows the view: mouse cursor on (the old mode is kept for close), a fresh build, no old status.
func open() -> void:
	if visible:
		return
	_prev_mouse = _mouse()
	_mouse(Input.MOUSE_MODE_VISIBLE)
	_say("")
	selection.clear()
	_anchor = -1
	visible = true
	rebuild()
	opened.emit()


## Hides the view and puts the mouse mode back.
func close() -> void:
	if not visible:
		return
	visible = false
	_mouse(_prev_mouse)
	closed.emit()


## Tab (the `inspect` action) opens the view (when `allowed`) or closes it; Esc clears the selection, or closes it
## when there is none. True when used.
func handle_key(event: InputEvent, allowed := true) -> bool:
	if InputActions.pressed(event, &"inspect"):
		if visible:
			close()
			return true
		if allowed:
			open()
			return true
		return false
	var k := event as InputEventKey
	if visible and k != null and k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE:
		if selection.is_empty():
			close()
		else:
			clear_selection()
		return true
	return false


func _input(event: InputEvent) -> void:
	if visible and handle_key(event):
		get_viewport().set_input_as_handled()


## Something changed (a snapshot, an action sent or judged): rebuilt on the next frame while open.
func refresh() -> void:
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty and visible and not _paint and not (is_inside_tree() and get_viewport().gui_is_dragging()):
		rebuild()


## Builds the columns again from the newest snapshot (now).
func rebuild() -> void:
	_dirty = false
	cols.clear()
	if hands != null:
		cols = InventoryModel.columns(hands.picker, hands.world.tables, actions)
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	_row_slots.clear()
	_col_slots.clear()
	_group_slots.clear()
	_ticks.clear()
	_row_col.clear()
	_col_uids.clear()
	_paint = false
	var listed := {}   # uid -> itype of every row
	for col in cols:
		for g: Dictionary in col["groups"]:
			for r: Dictionary in g["rows"]:
				var it: Variant = r.get("item")
				if it is ItemRef:
					listed[r["uid"]] = (it as ItemRef).type
	for uid: int in selection.keys():   # gone, or another item under its uid now
		if listed.get(uid, -1) != selection[uid]:
			selection.erase(uid)
	for col in cols:
		_box.add_child(_column_ui(col))
	if not _row_col.has(_anchor):
		_anchor = -1
	_show_selection()


## The slot of item `uid`'s row, of a column, or of a group (pocket index / square), null if none shown.
func row_slot(uid: int) -> InspectSlot:
	return _row_slots.get(uid)


func column_slot(id: String) -> InspectSlot:
	return _col_slots.get(id)


func group_slot(id: String, key: Variant) -> InspectSlot:
	return _group_slots.get(_gkey(id, key))


## Item `uid`'s [ ] box, null if its row isn't shown.
func tick_box(uid: int) -> Label:
	return _ticks.get(uid)


# --- selecting several ---

## A mouse event on item row `r` (InspectSlot). A left press: Ctrl+click adds or removes the row, Shift+click selects
## the rows of its column from the last clicked one, a click selects only it; on a row already selected that waits
## for the button to come up without a drag (dragging takes the selection along).
func row_input(r: Dictionary, event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var uid: int = r.get("uid", -1)
	if not _row_col.has(uid):
		return
	if not mb.pressed:
		if uid == _click_uid:
			select_only(uid)
		_click_uid = -1
		return
	_click_uid = -1
	if mb.ctrl_pressed or mb.meta_pressed:
		set_selected(uid, not selection.has(uid))
		_anchor = uid
	elif mb.shift_pressed and _anchor >= 0:
		select_run(_anchor, uid)
	elif selection.has(uid):
		_click_uid = uid
		_anchor = uid
	else:
		select_only(uid)


## A mouse event on row `uid`'s [ ] box (`box`): a left press ticks or unticks it, and until the button comes up the
## rows a drag passes are set the same way (paint_at).
func tick_input(event: InputEvent, uid: int, box: Control = null) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_paint = false
		if mb.pressed and _row_col.has(uid):
			set_selected(uid, not selection.has(uid))
			_paint_on = selection.has(uid)
			_paint = true
			_paint_uid = uid
			_anchor = uid
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _paint:
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			_paint = false
		elif box != null and box.is_inside_tree():
			paint_at(box.get_global_transform() * mm.position)


## A [ ] box drag is at `point` (global canvas position): the row there, and in the same column the rows between it
## and the last one passed, are set as the press set its row.
func paint_at(point: Vector2) -> void:
	if not _paint:
		return
	for uid: int in _row_slots:
		var s: InspectSlot = _row_slots[uid]
		if uid != _paint_uid and s.is_visible_in_tree() and s.get_global_rect().has_point(point):
			if _row_col.get(uid) == _row_col.get(_paint_uid):
				_put_run(_paint_uid, uid, _paint_on)
			else:
				_put(uid, _paint_on)
			_paint_uid = uid
			_show_selection()
			return


## Only row `uid` is selected.
func select_only(uid: int) -> void:
	selection.clear()
	_put(uid, true)
	_anchor = uid
	_show_selection()


## Selects (`on`) or unselects row `uid`.
func set_selected(uid: int, on: bool) -> void:
	_put(uid, on)
	_show_selection()


## Only the rows from `a` to `b` are selected (listing order), when both are in one column; else only `b`.
func select_run(a: int, b: int) -> void:
	selection.clear()
	if _row_col.has(a) and _row_col.get(a) == _row_col.get(b):
		_put_run(a, b, true)
	else:
		_put(b, true)
		_anchor = b
	_show_selection()


func clear_selection() -> void:
	selection.clear()
	_show_selection()


# --- drag and drop (InspectSlot hands over) ---

## What dragging a row carries, null when it can't be dragged (in flight).
func drag_data(row: Dictionary) -> Variant:
	_click_uid = -1   # a drag, not a click
	var it: Variant = row.get("item")
	if not it is ItemRef or row.get("pending", false) or actions == null or actions.pending((it as ItemRef).uid) != "":
		return null
	return {"inspect_uid": (it as ItemRef).uid, "type": (it as ItemRef).type}


## The little label that follows the mouse while dragging.
func drag_preview(row: Dictionary) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(Color(0.15, 0.15, 0.2, 0.9), 4))
	p.add_child(_label(str(row.get("name", "")), Color.WHITE))
	return p


func can_drop(data: Variant, target: Dictionary) -> bool:
	return plan(data, target)["do"] != "none"


## Does the drop: returns the action started ("put", "drop", "take" or ""), as Hands.move / take.
func drop(data: Variant, target: Dictionary) -> String:
	var p := plan(data, target)
	var it: ItemRef = p.get("item")
	match p["do"]:
		"move":
			_say("")
			var op := hands.move(HAND, it, p["drop"])
			if op == "" and status == "":
				_say(CANT)
			refresh()
			return op
		"take":
			_say("")
			var ok := hands.take(HAND, _target(it), p["hand"])
			if not ok and status == "":
				_say(CANT_TAKE)
			refresh()
			return "take" if ok else ""
		"not_yet":
			_say(p["why"])
	return ""


## What a drop of `data` on `target` would do: {do: "move" (drop: for Hands.move) | "take" (hand) | "not_yet" (why)
## | "none", item: ItemRef}.
func plan(data: Variant, target: Dictionary) -> Dictionary:
	var none := {"do": "none"}
	var it := _dragged(data)
	var col := InventoryModel.find_column(cols, str(target.get("column", "")))
	if it == null or col.is_empty():
		return none
	var kind: String = str(target.get("kind", ""))
	var key: Variant = target.get("key")
	if kind == "row":   # onto a container row: into it; anything else goes on to the column around it
		var r: Variant = target.get("row")
		var c: Variant = r.get("item") if r is Dictionary else null
		if c is ItemRef and r.get("is_container", false) and not r.get("pending", false) and (c as ItemRef).uid != it.uid:
			return {"do": "move", "item": it, "drop": {"kind": "container", "container": c}}
		return none
	if kind != "column" and kind != "group":
		return none
	match col["kind"]:
		"hands":
			if it.carried:
				return {"do": "not_yet", "item": it, "why": NOT_YET}
			var hand: String = key if kind == "group" and key is String and key in ["main", "off"] else _free_hand()
			return {"do": "take", "item": it, "hand": hand}
		"worn":
			var c: ItemRef = col["container"]
			var pocket: int = key if kind == "group" and key is int and key >= 0 else -1
			if c == null or c.uid == it.uid or (it.carried and it.parent == c.uid and (pocket < 0 or pocket == it.pocket)):
				return none
			var d := {"kind": "container", "container": c}
			if pocket >= 0:
				d["pocket"] = pocket
			return {"do": "move", "item": it, "drop": d}
		"nearby":
			var sq: Variant = key if kind == "group" and key is Vector3i else col["square"]
			if not sq is Vector3i or (not it.carried and it.square == sq):
				return none
			return {"do": "move", "item": it, "drop": {"kind": "surface", "square": sq, "spot": Vector2(-1, -1)}}
	return none


# --- inside ---

## The item a drag carries, from the rows shown now; null when it is malformed, gone or in flight.
func _dragged(data: Variant) -> ItemRef:
	if not data is Dictionary or actions == null or hands == null:
		return null
	var u: Variant = (data as Dictionary).get("inspect_uid")
	var t: Variant = (data as Dictionary).get("type")
	if not u is int or not t is int:
		return null
	var row := InventoryModel.find_row(cols, u)
	var it: ItemRef = row.get("item")
	if it == null or it.type != t or actions.pending(it.uid) != "":
		return null
	return it


## "main" unless the main hand holds something and the off hand doesn't (CDDA refuses a full hand itself).
func _free_hand() -> String:
	var main := false
	var off := false
	for r in hands.picker.carried():
		main = main or r.is_wielded()
		off = off or r.is_off_hand()
	return "off" if main and not off else "main"


## A Hands target for item `it` (Hands.take).
func _target(it: ItemRef) -> Dictionary:
	return {"kind": "item", "node": null, "item": it, "square": it.square, "point": it.point, "dist": 0.0,
			"name": InventoryModel.clean(it.display_name(hands.world.tables))}


func _on_refused(hand: String, _target_: Dictionary, reason: String) -> void:
	if hand == HAND:
		_say(InventoryModel.clean(reason, MAX_STATUS))
		refresh()


## Adds or removes row `uid` (a shown row with an item) without redrawing.
func _put(uid: int, on: bool) -> void:
	var s: InspectSlot = _row_slots.get(uid)
	var it: Variant = s.row.get("item") if s != null else null
	if on and it is ItemRef:
		selection[uid] = (it as ItemRef).type
	else:
		selection.erase(uid)


## _put on the rows from `a` to `b` in `b`'s column (listing order); only `b` when `a` isn't in it.
func _put_run(a: int, b: int, on: bool) -> void:
	var list: Array = _col_uids.get(_row_col.get(b, ""), [])
	var i := list.find(a)
	var j := list.find(b)
	if i < 0 or j < 0:
		_put(b, on)
		return
	for k in range(mini(i, j), maxi(i, j) + 1):
		_put(list[k], on)


## Shows the selection: highlighted rows, ticked boxes, the count in the heading.
func _show_selection() -> void:
	for uid: int in _row_slots:
		var on := selection.has(uid)
		(_row_slots[uid] as InspectSlot).add_theme_stylebox_override("panel", _sel_style if on else _no_style)
		var t: Label = _ticks.get(uid)
		if t != null:
			t.text = TICK_ON if on else TICK_OFF
	var keys := InputActions.key_of(&"inspect")
	if selection.is_empty():
		_head.text = ("Inventory: drag an item onto a column, a pocket, a square or a container. Several: drag over "
				+ "the [ ] boxes, Ctrl+click, Shift+click.   %s or Esc closes") % keys
	else:
		_head.text = "Inventory: %d selected.   Esc clears the selection, %s closes" % [selection.size(), keys]


func _say(text: String) -> void:
	status = text
	_status.text = text
	_status.visible = text != ""


func _mouse(set_to := -1) -> int:
	if mouse_hook.is_valid():
		var m: Variant = mouse_hook.call(set_to)
		return m if m is int else Input.MOUSE_MODE_VISIBLE
	if set_to >= 0:
		Input.mouse_mode = set_to as Input.MouseMode
	return Input.mouse_mode


func _column_ui(col: Dictionary) -> InspectSlot:
	var id: String = col["id"]
	var slot := _slot({"kind": "column", "column": id})
	slot.custom_minimum_size = Vector2(COLUMN_W, 0)
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot.add_theme_stylebox_override("panel", _style(Color(0.12, 0.12, 0.15, 0.95), 6))
	_col_slots[id] = slot
	_col_uids[id] = []
	var v := VBoxContainer.new()
	slot.add_child(v)
	v.add_child(_label(col["title"], Color.WHITE))
	v.add_child(_label(_totals(col), DIM))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	for g: Dictionary in col["groups"]:
		var gs := _slot({"kind": "group", "column": id, "key": g["key"]})
		var head := "%s   %s" % [g["title"], _totals(g)] if not (g["rows"] as Array).is_empty() else str(g["title"])
		gs.add_child(_label(head, DIM))
		rows.add_child(gs)
		_group_slots[_gkey(id, g["key"])] = gs
		if (g["rows"] as Array).is_empty():
			rows.add_child(_label("   (empty)", DIM))
		for r: Dictionary in g["rows"]:
			rows.add_child(_row_ui(id, r))
	if int(col["cut"]) > 0:
		rows.add_child(_label("... and %d more" % int(col["cut"]), DIM))
	return slot


func _row_ui(col_id: String, r: Dictionary) -> InspectSlot:
	var slot := _slot({"kind": "row", "column": col_id, "row": r})
	slot.row = r
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	slot.add_child(v)
	var line := HBoxContainer.new()
	v.add_child(line)
	var depth := clampi(int(r["depth"]), 0, InventoryModel.MAX_DEPTH)
	if depth > 0:
		var pad := Control.new()
		pad.custom_minimum_size.x = INDENT * depth
		pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(pad)
	var uid: int = r["uid"]
	if r.get("item") is ItemRef:
		var tick := _label(TICK_OFF, DIM)
		tick.mouse_filter = Control.MOUSE_FILTER_STOP   # a press here selects; it never starts a move
		tick.tooltip_text = "Select; drag over more boxes to select them too"
		tick.gui_input.connect(tick_input.bind(uid, tick))
		line.add_child(tick)
		_ticks[uid] = tick
		_row_col[uid] = col_id
		(_col_uids[col_id] as Array).append(uid)
	var box: bool = r["is_container"]
	var name_label := _label(("+ " if box else "") + str(r["name"]), BOX if box else Color.WHITE)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(name_label)
	line.add_child(_label(InventoryModel.weight_text(r["weight_g"]), DIM))
	var note: String = r["note"]
	if note != "":
		var n := _label(note, DIM)
		n.add_theme_font_size_override("font_size", 12)
		v.add_child(n)
	slot.tooltip_text = "%s\n%s, %s%s" % [r["name"], InventoryModel.weight_text(r["weight_g"]),
			InventoryModel.volume_text(r["volume_ml"]), ("\n" + note) if note != "" else ""]
	if r["pending"]:
		slot.modulate = PENDING
		slot.tooltip_text += "\n(moving)"
	_row_slots[r["uid"]] = slot
	return slot


func _slot(target: Dictionary) -> InspectSlot:
	var s := InspectSlot.new()
	s.view = self
	s.target = target
	s.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	return s


static func _totals(d: Dictionary) -> String:
	return "%s, %s" % [InventoryModel.weight_text(d["weight_g"]), InventoryModel.volume_text(d["volume_ml"])]


static func _gkey(id: String, key: Variant) -> String:
	return "%s|%s" % [id, key]


static func _label(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func _style(bg: Color, margin: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(4)
	s.set_content_margin_all(margin)
	return s
