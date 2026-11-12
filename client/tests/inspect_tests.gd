extends RefCounted
## Blocks E6 / L8: the Tab inspect view. InventoryModel (columns, pockets, totals, caps, pending) and InspectView
## (rows, drag and drop through Godot's _get_drag_data / _drop_data, refusals, Tab / Esc and the mouse mode), on
## the mock town with MockItems answering inside each call. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer
const SE := P + Vector3i(1, 1, 0)      # pile: canvas sack
const FAR := P + Vector3i(5, 0, 0)     # pile: rock, out of reach
const SACK := 500                      # worn canvas sack: rock (pocket 0), bottle with water (pocket 1)
const ROCK := 501
const BOTTLE := 502
const WATER := 503
const PACK := 504                      # worn backpack (no pockets in the mock tables, listed for what it holds)
const STONE := 505                     # in the backpack


## An item backend that takes every call and never answers: actions stay in flight.
class Silent:
	extends RefCounted

	func take_item(_u: float, _t: float, _p: Vector3i, _h := "pack") -> bool:
		return true

	func drop_item(_u: float, _t: float, _p: Vector3i, _s: Vector2) -> bool:
		return true


var _check: Callable
var _it := {}   # itype id -> index
var _tables: IdTables
var _snap: Snapshot
var _mock: MockItems
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _view: InspectView
var _mode := [Input.MOUSE_MODE_VISIBLE]   # the view's mouse mode (a fake: mouse_hook)


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_tables = tables
	print("inspect")
	for id: String in ["rock", "hammer", "bag_canvas", "backpack", "bottle_plastic", "water_clean"]:
		_it[id] = tables.index_of("itype", id)
	InputActions.ensure(false)
	_test_pockets()
	if not _setup(root, data):
		return
	_test_model()
	_test_caps(data)
	_test_rows()
	_test_select()
	_test_drops()
	_test_many()
	_test_bar()
	_test_pending()
	_test_toggle()
	_view.free()
	_hands.free()
	_actions.free()
	_world.free()


## itype pockets from the id tables (contracts/id_tables.md): read strictly, decide what counts as a container, and
## name the worn column's groups (empty ones too, so items can be dropped in; unusable ones only when used).
func _test_pockets() -> void:
	var base := {"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [], "itype": [
		{"id": ""},
		{"id": "pack", "name": "backpack", "pockets": [
			{"name": "main <color_red>bag</color>" + String.chr(0x202E) + "", "volume_ml": 15000, "max_weight_g": 30000, "flags": 0},
			{"volume_ml": 500, "max_weight_g": 1000.0, "max_item_ml": 200, "flags": IdTables.POCKET_WATERTIGHT},
			{"volume_ml": 100, "max_weight_g": 100, "flags": IdTables.POCKET_FORBIDDEN},
			{"volume_ml": 900, "max_weight_g": 1500, "flags": IdTables.POCKET_HOLSTER | IdTables.POCKET_RESTRICTED}]},
		{"id": "sealed", "name": "sealed can", "category": "container",
			"pockets": [{"volume_ml": 300, "max_weight_g": 400, "flags": IdTables.POCKET_FORBIDDEN}]},
		{"id": "rock", "name": "rock", "category": "container"}]}
	var t := IdTables.from_data(base)
	var pack: Array[Dictionary] = []
	if t.is_valid():
		pack = t.def_named("itype", "pack").pockets
	_check.call(t.is_valid() and t.has_pockets and pack.size() == 4 and pack[1] == {"name": "", "volume_ml": 500,
			"max_weight_g": 1000, "max_item_ml": 200, "flags": IdTables.POCKET_WATERTIGHT} and pack[0]["max_item_ml"] == -1
			and t.def_named("itype", "rock").pockets.is_empty(), "pockets: read per itype (%s)" % t.error)
	_check.call(MockItems.is_container(1, t) and not MockItems.is_container(2, t) and not MockItems.is_container(3, t),
			"pockets: a container has a pocket the player may use; category no longer decides once pockets are sent")
	var old := IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "box", "category": "container"}]})
	_check.call(not old.has_pockets and MockItems.is_container(1, old), "pockets: older tables fall back to the category")
	var refused := []
	var cases := {
		"pockets not a list": func(d: Dictionary) -> void: d["itype"][1]["pockets"] = {},
		"33 pockets": func(d: Dictionary) -> void: d["itype"][1]["pockets"] = range(33).map(func(_i: int) -> Dictionary: return {}),
		"pocket not an object": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0] = 5,
		"flags out of range": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0]["flags"] = 512,
		"negative volume": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0]["volume_ml"] = -1,
		"name too long": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0]["name"] = "n".repeat(5000),
		"name not text": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0]["name"] = 7,
		"fractional weight": func(d: Dictionary) -> void: d["itype"][1]["pockets"][0]["max_weight_g"] = 1.5,
	}
	for what: String in cases:
		var d: Dictionary = base.duplicate(true)
		(cases[what] as Callable).call(d)
		var r := IdTables.from_data(d)
		if r.is_valid() or not r.itype.is_empty():
			refused.append(what)
	_check.call(refused.is_empty(), "pockets: bad entries fail the tables %s" % [refused])
	if not t.is_valid():
		return
	var c := ItemRef.on_player(10, 1, 0, -1, Snapshot.CARRIED_WORN, Vector3i.ZERO)
	var kids := {10: [ItemRef.on_player(11, 3, 10, 2, 0, Vector3i.ZERO), ItemRef.on_player(12, 3, 10, 5, 0, Vector3i.ZERO)]}
	var col := InventoryModel._worn_column(c, kids, t, null, {}, Vector3i.ZERO)
	var titles: Array = (col["groups"] as Array).map(func(g: Dictionary) -> String: return "%s=%s" % [g["key"], g["title"]])
	_check.call(titles == ["0=main bag (max 15.00 L, 30.00 kg)", "1=pocket 2 (max 500 ml, 1.00 kg; watertight)",
			"2=pocket 3 (max 100 ml, 100 g; can't use)", "3=holster 4 (max 900 ml, 1.50 kg; some items only)",
			"5=pocket 6"] and (col["groups"][0]["rows"] as Array).is_empty() and (col["groups"][2]["rows"] as Array).size() == 1,
			"pockets: worn column lists the type's pockets, empty ones too; unusable only when used; extra ones by number (%s)" % [titles])
	kids = {}
	col = InventoryModel._worn_column(c, kids, t, null, {}, Vector3i.ZERO)
	_check.call((col["groups"] as Array).size() == 3, "pockets: an empty pack shows its usable pockets")


func _setup(root: Node, data: Variant) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[1, 2, [_it["rock"], _it["hammer"]]], [13, 1, [_it["bag_canvas"]]], [5, 1, [_it["rock"]]]]
		elif at != Vector3i(15, 32, 0):
			continue
		else:
			sm["items"] = []
		sm.erase("handles")
	(d["player"] as Dictionary)["items"] = [
		[PACK, _it["backpack"], 0, -1, Snapshot.CARRIED_WORN],
		[STONE, _it["rock"], PACK, 0, 0],
		[SACK, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN],
		[ROCK, _it["rock"], SACK, 0, 0],
		[BOTTLE, _it["bottle_plastic"], SACK, 1, 0],
		[WATER, _it["water_clean"], BOTTLE, 0, 0],
	]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P and _snap.carried.size() == 6 * Snapshot.CARRIED_STRIDE,
			"inspect: test town loads with a worn sack and backpack " + _snap.error)
	if not _snap.is_valid():
		return false
	_mock = MockItems.new(_snap, _tables)
	_mock.seed()
	_world = WorldView.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(_tables)
	root.add_child(_world)
	_world.apply_snapshot(_snap)
	_actions = ItemActions.new()
	_actions.backend = _mock
	_mock.changed.connect(func(s: Snapshot) -> void:
		_world.apply_snapshot(s)
		_actions.on_snapshot(s))
	_mock.message.connect(func(t: String) -> void: _actions.on_events([MockItems.message_event(t)]))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_view = InspectView.new(_hands, _actions)
	_view.mouse_hook = func(set_to: int) -> int:   # the test runner's own mouse mode stays as it is
		if set_to >= 0:
			_mode[0] = set_to
		return _mode[0]
	root.add_child(_view)
	return true


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(p: Vector3i, type: int) -> int:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


func _has_handle(p: Vector3i, uid: int) -> bool:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 1] == uid:
			return true
	return false


## The carried row [uid, type, parent, pocket, flags] of `uid`, [] if not carried.
func _carried(uid: int) -> Array:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i] == uid:
			return Array(c.slice(i, i + Snapshot.CARRIED_STRIDE))
	return []


static func _uids(g: Dictionary) -> Array:
	return (g["rows"] as Array).map(func(r: Dictionary) -> int: return r["uid"])


static func _group(col: Dictionary, key: Variant) -> Dictionary:
	for g: Dictionary in col.get("groups", []):
		if typeof(g["key"]) == typeof(key) and g["key"] == key:
			return g
	return {}


func _cols() -> Array[Dictionary]:
	return InventoryModel.columns(_hands.picker, _tables, _actions)


func _test_model() -> void:
	var cols := _cols()
	var ids := cols.map(func(c: Dictionary) -> String: return c["id"])
	_check.call(ids == ["hands", "worn:%d" % SACK, "worn:%d" % PACK, "nearby"],
			"inspect: columns hands, worn containers outermost first, nearby %s" % [ids])
	var hands := InventoryModel.find_column(cols, "hands")
	_check.call((hands["groups"] as Array).size() == 2 and _uids(_group(hands, "main")).is_empty()
			and _uids(_group(hands, "off")).is_empty(), "inspect: hands column: main and off hand, both empty")
	var sack := InventoryModel.find_column(cols, "worn:%d" % SACK)
	var p0 := _group(sack, 0)
	var p1 := _group(sack, 1)
	_check.call(sack["kind"] == "worn" and (sack["container"] as ItemRef).uid == SACK and sack["title"] == "canvas sack"
			and (sack["groups"] as Array).size() == 2 and _uids(p0) == [ROCK] and _uids(p1) == [BOTTLE, WATER]
			and p0["title"] == "pocket 1" and p1["title"] == "pocket 2", "inspect: worn container's contents by pocket")
	var pack := InventoryModel.find_column(cols, "worn:%d" % PACK)
	_check.call(pack["title"] == "backpack" and _uids(_group(pack, 0)) == [STONE] and InventoryModel.find_row(cols, SACK).is_empty()
			and InventoryModel.find_row(cols, PACK).is_empty(), "inspect: a worn item holding things gets a column, not a row")
	var water := InventoryModel.find_row(cols, WATER)
	var bottle := InventoryModel.find_row(cols, BOTTLE)
	_check.call(water["depth"] == 1 and bottle["depth"] == 0 and bottle["is_container"] and not water["is_container"]
			and water["name"] == "clean water" and not water["pending"] and (water["item"] as ItemRef).carried,
			"inspect: nested items one deeper, containers marked")
	var g := func(id: String) -> int: return _tables.def_at("itype", _it[id]).weight_g
	var ml := func(id: String) -> int: return _tables.def_at("itype", _it[id]).volume_ml
	var w1: int = g.call("bottle_plastic") + g.call("water_clean")
	_check.call(p1["weight_g"] == w1 and sack["weight_g"] == w1 + g.call("rock")
			and sack["volume_ml"] == ml.call("bottle_plastic") + ml.call("water_clean") + ml.call("rock")
			and sack["rows"] == 3 and sack["cut"] == 0, "inspect: totals in g and ml per pocket and column (%d g, %d ml)"
			% [sack["weight_g"], sack["volume_ml"]])
	var near := InventoryModel.find_column(cols, "nearby")
	var here := _group(near, P)
	var east := _group(near, E)
	var se := _group(near, SE)
	var bag := InventoryModel.find_row(cols, _handle(SE, _it["bag_canvas"]))
	_check.call(near["square"] == P and here["title"] == "here" and _uids(here).is_empty() and east["title"] == "east"
			and _uids(east).size() == 2 and _uids(se).size() == 1 and (near["groups"] as Array).size() == 3
			and InventoryModel.find_row(cols, _handle(FAR, _it["rock"])).is_empty(),
			"inspect: nearby by square, here always, nothing out of reach")
	_check.call(bag["is_container"] and bag["note"] == InventoryModel.GROUND_NOTE and not (bag["item"] as ItemRef).carried
			and (bag["item"] as ItemRef).square == SE, "inspect: a container on the ground: listed with a note, no contents")
	_check.call(InventoryModel.weight_text(657) == "657 g" and InventoryModel.weight_text(1250) == "1.25 kg"
			and InventoryModel.volume_text(250) == "250 ml" and InventoryModel.volume_text(1500) == "1.50 L",
			"inspect: weight and volume text")
	_check.call(InventoryModel.columns(null, _tables, _actions).is_empty(), "inspect: no picker: no columns")


## Caps: 230 rocks in the backpack list 200 rows (the rest counted, totals over all); names are cleaned and capped.
func _test_caps(data: Variant) -> void:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var items := [[PACK, _it["backpack"], 0, -1, Snapshot.CARRIED_WORN]]
	for i in 230:
		items.append([PACK + 10 + i, _it["rock"], PACK, i % 3, 0])
	(d["player"] as Dictionary)["items"] = items
	var big := Snapshot.from_data(d)
	var keep := _world.snapshot
	_world.snapshot = big
	var pack := InventoryModel.find_column(_cols(), "worn:%d" % PACK)
	_world.snapshot = keep
	var listed := 0
	for g: Dictionary in pack.get("groups", []):
		listed += (g["rows"] as Array).size()
	_check.call(big.is_valid() and pack["rows"] == InventoryModel.MAX_ROWS and listed == InventoryModel.MAX_ROWS
			and pack["cut"] == 30 and pack["weight_g"] == 230 * _tables.def_at("itype", _it["rock"]).weight_g
			and (pack["groups"] as Array).size() == 3, "inspect: rows capped per column, the rest counted (%s, %s)"
			% [pack.get("rows"), pack.get("cut")])
	(d["player"] as Dictionary)["items"] = [
		[600, _it["hammer"], 0, -1, Snapshot.CARRIED_WIELDED],
		[601, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_OFFHAND],
		[602, _it["rock"], 601, 0, 0],
		[603, _it["rock"], 0, -1, 0],
	]
	var held := Snapshot.from_data(d)
	_world.snapshot = held
	var cols := _cols()
	_world.snapshot = keep
	var hands := InventoryModel.find_column(cols, "hands")
	var off := _group(hands, "off")
	_check.call(held.is_valid() and cols.map(func(c: Dictionary) -> String: return c["id"]) == ["hands", "loose", "nearby"]
			and _uids(_group(hands, "main")) == [600] and _uids(off) == [601, 602] and (off["rows"] as Array)[1]["depth"] == 1
			and _uids(_group(InventoryModel.find_column(cols, "loose"), 0)) == [603],
			"inspect: hands list what each hand holds (and what is in it), loose items get their own column")
	var long := InventoryModel.clean("x".repeat(500))
	_check.call(long.length() == InventoryModel.MAX_NAME and InventoryModel.clean("a\nb\u0007c") == "a b c"
			and InventoryModel.clean("<color_red>red</color> rock") == "red rock", "inspect: names capped, no control characters or colour tags")


func _test_rows() -> void:
	_view.open()
	var rock := _view.row_slot(ROCK)
	var water := _view.row_slot(WATER)
	_check.call(_view.visible and _view.column_slot("hands") != null and _view.column_slot("worn:%d" % SACK) != null
			and _view.column_slot("nearby") != null and _view.group_slot("worn:%d" % SACK, 1) != null
			and _view.group_slot("nearby", E) != null and rock != null and water != null
			and _view.row_slot(_handle(E, _it["hammer"])) != null and _view.row_slot(_handle(FAR, _it["rock"])) == null,
			"inspect: view built: a slot per column, group and row")
	var names := rock.find_children("*", "Label", true, false).map(func(l: Label) -> String: return l.text)
	_check.call("rock" in names and rock.tooltip_text.begins_with("rock\n") and rock.modulate == Color.WHITE
			and water.target.get("kind") == "row" and water.target.get("column") == "worn:%d" % SACK,
			"inspect: a row shows its name and weight %s" % [names])
	var data: Variant = rock._get_drag_data(Vector2.ZERO)
	_check.call(data is Dictionary and data["inspect_uid"] == ROCK and _view.column_slot("hands")._get_drag_data(Vector2.ZERO) == null,
			"inspect: rows drag, columns don't")


static func _button(down: bool, shift := false, ctrl := false) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.shift_pressed = shift
	e.ctrl_pressed = ctrl
	return e


## A left click on item `uid`'s row, through the slot's own _gui_input.
func _click(uid: int, shift := false, ctrl := false) -> void:
	_view.row_slot(uid)._gui_input(_button(true, shift, ctrl))
	_view.row_slot(uid)._gui_input(_button(false, shift, ctrl))


func _selected() -> Array:
	var out := _view.selection.keys()
	out.sort()
	return out


## Selecting several rows: clicks with Ctrl / Shift, the [ ] boxes and a drag over them, kept across rebuilds,
## Esc clears it before it closes the view.
func _test_select() -> void:
	var hammer := _handle(E, _it["hammer"])
	var stone := _handle(E, _it["rock"])
	_click(ROCK)
	_click(WATER, false, true)
	_check.call(_selected() == [ROCK, WATER] and _view.selection[ROCK] == _it["rock"]
			and _view.row_slot(ROCK).get_theme_stylebox("panel") is StyleBoxFlat and _view.tick_box(WATER).text == "[x]"
			and _view.tick_box(BOTTLE).text == "[ ]" and _view._head.text.begins_with("Inventory: 2 selected"),
			"select: click, then Ctrl+click adds; rows highlighted, boxes ticked, count shown (%s)" % [_selected()])
	_view.row_slot(ROCK)._gui_input(_button(true))
	_check.call(_selected() == [ROCK, WATER], "select: pressing a selected row keeps the others (a drag takes them)")
	_view.row_slot(ROCK)._get_drag_data(Vector2.ZERO)
	_view.row_slot(ROCK)._gui_input(_button(false))
	_check.call(_selected() == [ROCK, WATER], "select: ... and after a drag they stay")
	_click(ROCK)
	_check.call(_selected() == [ROCK], "select: a click on a selected row without a drag keeps only it")
	_click(WATER, true)
	_check.call(_selected() == [ROCK, BOTTLE, WATER], "select: Shift+click selects the run in the column (%s)"
			% [_selected()])
	_click(STONE, true)
	_check.call(_selected() == [STONE], "select: Shift+click in another column selects only that row")
	_click(STONE, false, true)
	_check.call(_selected().is_empty() and _view._head.text.contains("Several:"), "select: Ctrl+click removes it")
	var at := {}   # rows laid out by hand (a test has no layout pass): uid -> y
	var y := 0.0
	for sc: Control in _view._col_scroll.values():   # each column's list too, rows shown in it
		sc.global_position = Vector2.ZERO
		sc.size = Vector2(200, 400)
	for u: int in [ROCK, BOTTLE, WATER, STONE, hammer, stone]:
		_view.row_slot(u).global_position = Vector2(0, y)
		_view.row_slot(u).size = Vector2(200, 28)   # at least its minimum size: rows are 60 apart
		at[u] = y + 10
		y += 60
	_view.tick_input(_button(true), ROCK)
	_view.paint_at(Vector2(5, at[WATER]))   # same column: BOTTLE is passed on the way
	_view.paint_at(Vector2(5, at[hammer]))
	_view.paint_at(Vector2(5000, at[stone]))   # not on a row
	_view.tick_input(_button(false), ROCK)
	_view.paint_at(Vector2(5, at[stone]))     # the button is up
	_check.call(_selected() == [ROCK, BOTTLE, WATER, hammer], "select: a drag over the boxes selects the rows passed (%s)"
			% [_selected()])
	_view.tick_input(_button(true), BOTTLE)
	_view.paint_at(Vector2(5, at[WATER]))
	var motion := InputEventMouseMotion.new()   # the button came up outside the view: the next motion ends the drag
	_view.tick_input(motion, BOTTLE)
	_view.paint_at(Vector2(5, at[ROCK]))
	_check.call(_selected() == [ROCK, hammer], "select: a drag from a ticked box unticks the rows passed (%s)"
			% [_selected()])
	(_view._col_scroll["nearby"] as Control).size = Vector2(200, 100)   # stone's row is scrolled out of sight now
	_view.tick_input(_button(true), BOTTLE)
	_view.paint_at(Vector2(5, at[stone]))
	_view.tick_input(_button(false), BOTTLE)
	_check.call(_selected() == [ROCK, BOTTLE, hammer], "select: a box drag never ticks rows out of sight (%s)" % [_selected()])
	_view.set_selected(BOTTLE, false)
	for i in InspectView.MAX_BATCH - 2:
		_view.selection[900000 + i] = 1
	_click(BOTTLE, false, true)
	_check.call(_view.selection.size() == InspectView.MAX_BATCH and not _view.selection.has(BOTTLE)
			and _view.status.contains("At most 256"), "select: at most 256 selected (%s)" % _view.status)
	for i in InspectView.MAX_BATCH - 2:
		_view.selection.erase(900000 + i)
	_view._say("")
	_view.selection[999999] = _it["rock"]   # gone since
	_view.selection[STONE] = _it["hammer"]  # another itype under its uid now
	_view.rebuild()
	_check.call(_selected() == [ROCK, hammer] and _view.tick_box(hammer).text == "[x]",
			"select: a rebuild keeps listed rows, drops gone ones (%s)" % [_selected()])
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_check.call(_view.handle_key(esc) and _view.visible and _selected().is_empty(), "select: Esc clears the selection first")
	_click(ROCK)
	_view.close()
	_view.open()
	_check.call(_selected().is_empty(), "select: opening the view starts with none")


## Drops through the slots' own _drop_data, MockItems answering inside each call.
func _test_drops() -> void:
	var sack_id := "worn:%d" % SACK
	var hammer := _handle(E, _it["hammer"])
	var bag := _handle(SE, _it["bag_canvas"])
	var stone := _handle(E, _it["rock"])
	var slot := _view.group_slot(sack_id, 1)
	var data: Variant = _view.row_slot(hammer)._get_drag_data(Vector2.ZERO)
	_check.call(slot._can_drop_data(Vector2.ZERO, data), "inspect: a ground item can go into a pocket")
	slot._drop_data(Vector2.ZERO, data)
	var row := _carried(hammer)
	_check.call(row.size() == 5 and row[2] == SACK and row[3] == 1 and row[4] == 0 and not _has_handle(E, hammer)
			and _actions.pending_count() == 0 and _view.status == "",
			"inspect: ground -> worn sack, pocket 2: taken, then put in (%s %s)" % [row, _view.status])
	_view.rebuild()
	_view.group_slot(sack_id, 0)._drop_data(Vector2.ZERO, _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO))
	row = _carried(BOTTLE)
	_check.call(row.size() == 5 and row[2] == SACK and row[3] == 0 and _carried(WATER)[2] == BOTTLE,
			"inspect: pocket 2 -> pocket 1 of the same sack (its contents go along)")
	_view.rebuild()
	_view.column_slot("nearby")._drop_data(Vector2.ZERO, _view.row_slot(ROCK)._get_drag_data(Vector2.ZERO))
	_check.call(_carried(ROCK).is_empty() and _has_handle(P, ROCK), "inspect: sack -> nearby: dropped on your square")
	_view.rebuild()
	var into := _view.row_slot(bag)
	data = _view.row_slot(hammer)._get_drag_data(Vector2.ZERO)
	_check.call(into._can_drop_data(Vector2.ZERO, data) and _view.drop(data, into.target) == "put" and _carried(hammer).is_empty()
			and not _has_handle(SE, hammer), "inspect: carried -> the sack on the ground: put in")
	_view.rebuild()
	_check.call(not _view.row_slot(WATER)._can_drop_data(Vector2.ZERO, _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO))
			and not _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, {"inspect_uid": str(ROCK), "type": 1})
			and not _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, null)
			and not _view.group_slot("nearby", P)._can_drop_data(Vector2.ZERO, _view.row_slot(ROCK)._get_drag_data(Vector2.ZERO))
			and not _view.row_slot(BOTTLE)._can_drop_data(Vector2.ZERO, _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO))
			and not _view.group_slot(sack_id, 0)._can_drop_data(Vector2.ZERO, _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO)),
			"inspect: no drop on a non-container row, bad data, where it already is or itself")
	_view.column_slot("hands")._drop_data(Vector2.ZERO, _view.row_slot(stone)._get_drag_data(Vector2.ZERO))
	row = _carried(stone)
	_check.call(row.size() == 5 and row[4] == Snapshot.CARRIED_WIELDED and row[2] == 0, "inspect: ground -> hands: into the main hand")
	_view.rebuild()
	var before := _snap.carried.duplicate()
	var seq := _snap.seq
	_view.column_slot("hands")._drop_data(Vector2.ZERO, _view.row_slot(WATER)._get_drag_data(Vector2.ZERO))
	_check.call(_view.status == InspectView.NOT_YET and _snap.seq == seq and _snap.carried == before
			and _actions.pending_count() == 0, "inspect: carried -> hands: 'not yet', nothing sent")
	_view.rebuild()
	_view.group_slot("hands", "main")._drop_data(Vector2.ZERO, _view.row_slot(bag)._get_drag_data(Vector2.ZERO))
	_check.call(_view.status.begins_with("Your hand is full") and _view.find_children("*", "Label", true, false).any(
			func(l: Label) -> bool: return l.visible and l.text == _view.status) and _has_handle(SE, bag),
			"inspect: a refusal shows CDDA's reason (%s)" % _view.status)
	_hands.refused.emit("mouse", {}, "Not for this view.")
	_check.call(_view.status.begins_with("Your hand is full"), "inspect: other hands' refusals aren't shown")


## Dragging a selected row moves the whole selection, one item after another. After _test_drops: the bottle (with
## its water) in the sack's first pocket, the stone in the backpack, a ground rock in the main hand, ROCK on your
## square, the canvas bag on the ground south-east (left there for _test_pending).
func _test_many() -> void:
	var stone := _wielded()
	var sack_id := "worn:%d" % SACK
	var p2 := {"kind": "group", "column": sack_id, "key": 1}   # pocket 2: no group shown while it is empty
	_view.rebuild()
	_click(BOTTLE)
	_click(WATER, false, true)
	_click(ROCK, false, true)
	var data: Variant = _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO)
	var preview := _view.drag_preview(_view.row_slot(BOTTLE).row)
	_check.call(data is Dictionary and (data["inspect_many"] as Array).size() == 3
			and (preview.get_child(0) as Label).text == "3 items", "many: a selected row drags the selection (%s)" % [data])
	preview.free()
	_view.drop(data, p2)
	var b := _carried(BOTTLE)
	var w := _carried(WATER)
	var r := _carried(ROCK)
	_check.call(b.size() == 5 and b[2] == SACK and b[3] == 1 and w.size() == 5 and w[2] == BOTTLE and r.size() == 5
			and r[2] == SACK and r[3] == 1 and _view.status == "" and _view.batch_left() == 0
			and not _view._head.text.begins_with("Moving"),
			"many: into pocket 2: the bottle (its water along) and the rock from the ground (%s %s %s %s)"
			% [b, w, r, _view.status])
	_view.rebuild()
	_click(stone)
	_click(BOTTLE, false, true)
	_view.drop(_view.row_slot(stone)._get_drag_data(Vector2.ZERO), p2)
	var s := _carried(stone)
	_check.call(stone > 0 and s.size() == 5 and s[2] == SACK and _view.status.begins_with("1 of 2 done.")
			and _view.status.contains(InspectView.CANT), "many: one is already there, the other goes; the status counts (%s)"
			% _view.status)
	_view.rebuild()
	_click(BOTTLE)
	_click(ROCK, false, true)
	data = _view.row_slot(BOTTLE)._get_drag_data(Vector2.ZERO)
	_check.call(not _view.can_drop(data, p2)
			and _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, data)
			and not _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, {"inspect_many": [[BOTTLE, "x"]]})
			and not _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, {"inspect_many": range(300).map(
				func(i: int) -> Array: return [i, 1])}),
			"many: no drop where none can go, or with bad or too long data")
	_actions.backend = Silent.new()   # drops are sent and never answered: the next waits
	_view.column_slot("nearby")._drop_data(Vector2.ZERO, data)
	_check.call(_actions.pending(BOTTLE) == "drop" and _actions.pending(ROCK) == "" and _view.batch_left() == 2
			and _view._head.text.begins_with("Moving 1 of 2"), "many: the second waits for the first (%s)" % _view._head.text)
	_actions.refused.emit(_hands.picker.by_uid(BOTTLE), "drop", "No room.")
	_actions.clear()
	_view._process(0.0)
	_check.call(_actions.pending(ROCK) == "drop" and _view.batch_left() == 1 and _view.status == "",
			"many: when the first is judged, the next goes")
	_actions.refused.emit(_hands.picker.by_uid(ROCK), "drop", "No room.")
	_actions.clear()
	_view._process(0.0)
	_check.call(_view.batch_left() == 0 and _view.status == "0 of 2 done. No room." and _carried(BOTTLE).size() == 5,
			"many: refusals are counted at the end (%s)" % _view.status)
	_actions.backend = _mock
	_view.clear_selection()


## The bar's buttons act on the selection. After _test_many: ROCK, the bottle (with its water) and the stone from
## the ground in the sack's second pocket.
func _test_bar() -> void:
	var stone := _carried_in(SACK, _it["rock"], ROCK)
	_view.rebuild()
	var bar := _bar_buttons()
	_check.call(bar.is_empty(), "bar: hidden with nothing selected (%s)" % [bar.keys()])
	_click(ROCK)
	_click(stone, false, true)
	bar = _bar_buttons()
	_check.call(bar.has("Drop here") and bar.has("Into the canvas sack") and bar.has("Unload") and bar.has("Clear")
			and not bar.has("Stop"), "bar: shown for a selection, with a button per worn container (%s)" % [bar.keys()])
	(bar["Drop here"] as Button).pressed.emit()
	_check.call(_has_handle(P, ROCK) and _has_handle(P, stone) and _view.status == "", "bar: Drop here drops them all")
	_view.rebuild()
	(_bar_buttons()["Into the canvas sack"] as Button).pressed.emit()
	_check.call(_carried(ROCK).size() == 5 and _carried(ROCK)[2] == SACK and _carried(stone).size() == 5
			and _carried(stone)[2] == SACK, "bar: Into the sack takes them from the ground and puts them in, one by one")
	_view.rebuild()
	(_bar_buttons()["Unload"] as Button).pressed.emit()
	_check.call(_view.status.begins_with("0 of 2 done.") and _view.status.contains("isn't loaded"),
			"bar: Unload; CDDA's refusals counted (%s)" % _view.status)
	_check.call(_view.act("into", "nearby") == "" and _view.act("into", "worn:1") == "" and _view.act("nope") == "",
			"bar: 'into' only takes a worn container's column")
	_actions.backend = Silent.new()
	_view.act("drop")
	bar = _bar_buttons()
	_check.call(bar.has("Stop") and _view.batch_left() == 2, "bar: Stop shows while a batch runs")
	(bar["Stop"] as Button).pressed.emit()
	_actions.refused.emit(_hands.picker.by_uid(ROCK), "drop", "No room.")
	_actions.clear()
	_view._process(0.0)
	_check.call(_view.batch_left() == 0 and _actions.pending(stone) == "" and not _bar_buttons().has("Stop"),
			"bar: Stop leaves the rest where they are")
	_actions.clear()
	_view.act("drop")
	_check.call(_view._batch_target == {"kind": "group", "column": "nearby", "key": P} and _view.batch_left() == 2,
			"bar: Drop here keeps the square it started on (%s)" % [_view._batch_target])
	_hands.picker.reach = func() -> Variant: return E   # walked a square on
	_view._process(0.0)
	_hands.picker.reach = Callable()
	_check.call(_view.batch_left() == 0 and _view.status.begins_with("Stopped: you moved") and _actions.pending(stone) == "",
			"bar: walking away stops a batch; the rest stay (%s)" % _view.status)
	_actions.clear()
	_view.act("drop")
	_view.on_game_state("running")
	var kept := _view.batch_left()
	_view.on_game_state("ended")
	_check.call(kept == 2 and _view.batch_left() == 0 and _view.status.begins_with("Stopped: the game"),
			"bar: a batch stops when the game stops running")
	_actions.clear()
	_actions.backend = _mock
	(_bar_buttons()["Clear"] as Button).pressed.emit()
	_check.call(_view.selection.is_empty() and _bar_buttons().is_empty(), "bar: Clear selects none and hides it")


## The selection bar's visible buttons by text ({} when the bar is hidden).
func _bar_buttons() -> Dictionary:
	var out := {}
	var bar: Control = _view._bar
	if not bar.visible:
		return out
	for b: Button in bar.find_children("*", "Button", true, false):
		if b.is_visible_in_tree() and not b.is_queued_for_deletion():
			out[b.text] = b
	return out


## The uid of the first carried item of `type` in container `parent` other than `not_uid`, -1 if none.
func _carried_in(parent: int, type: int, not_uid: int) -> int:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if c[i + 2] == parent and c[i + 1] == type and c[i] != not_uid:
			return c[i]
	return -1


## The uid of the item in the main hand, -1 if none.
func _wielded() -> int:
	var c := _snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		if (c[i + 4] & Snapshot.CARRIED_WIELDED) != 0:
			return c[i]
	return -1


## An action in flight greys its row, which can't be dragged then.
func _test_pending() -> void:
	_actions.backend = Silent.new()
	var bag := _handle(SE, _it["bag_canvas"])
	var ref := _hands.picker.by_uid(bag)
	_check.call(ref != null and _actions.take(ref, "pack") and _actions.pending(bag) == "take", "inspect: an action in flight")
	_check.call(InventoryModel.find_row(_cols(), bag)["pending"] and not InventoryModel.find_row(_cols(), WATER)["pending"],
			"inspect: the model marks it pending")
	_view.rebuild()
	var slot := _view.row_slot(bag)
	_check.call(slot != null and slot.modulate == InspectView.PENDING and slot._get_drag_data(Vector2.ZERO) == null
			and not _view.column_slot("nearby")._can_drop_data(Vector2.ZERO, {"inspect_uid": bag, "type": _it["bag_canvas"]}),
			"inspect: its row is greyed and doesn't drag")
	_actions.clear()
	_actions.backend = _mock


## Tab opens (when allowed) and closes, Esc closes; the mouse mode comes back.
func _test_toggle() -> void:
	_view.close()
	var mode := _mode
	mode[0] = Input.MOUSE_MODE_CAPTURED
	var seen: Array = []
	_view.opened.connect(func() -> void: seen.append("opened"))
	_view.closed.connect(func() -> void: seen.append("closed"))
	var tab := InputActions.slots(&"inspect")[0].duplicate() as InputEvent
	if tab is InputEventKey:
		(tab as InputEventKey).pressed = true
	_check.call(not _view.handle_key(tab, false) and not _view.visible, "inspect: Tab does nothing when not allowed")
	_check.call(_view.handle_key(tab, true) and _view.visible and mode[0] == Input.MOUSE_MODE_VISIBLE and seen == ["opened"],
			"inspect: Tab opens it and shows the mouse")
	_check.call(_view.handle_key(tab, true) and not _view.visible and mode[0] == Input.MOUSE_MODE_CAPTURED
			and seen == ["opened", "closed"], "inspect: Tab closes it and the mouse mode comes back")
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_check.call(not _view.handle_key(esc), "inspect: Esc does nothing while closed")
	_view.handle_key(tab)
	_check.call(_view.handle_key(esc) and not _view.visible and mode[0] == Input.MOUSE_MODE_CAPTURED, "inspect: Esc closes it")
	# without keys (the VR panel): the Close button, and ui_cancel like Esc
	var cancel := InputEventAction.new()
	cancel.action = &"ui_cancel"
	cancel.pressed = true
	var other := InputEventAction.new()
	other.action = &"ui_accept"
	other.pressed = true
	var closed_ignores := not _view.handle_key(cancel)
	_view.handle_key(tab)
	var by_action := not _view.handle_key(other) and _view.visible and _view.handle_key(cancel) and not _view.visible
	_view.handle_key(tab)
	_view.close_button.pressed.emit()
	_check.call(closed_ignores and by_action and not _view.visible and _view.close_button.text == "Close",
			"inspect: ui_cancel and the Close button close it without a keyboard")
