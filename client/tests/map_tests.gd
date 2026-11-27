extends RefCounted
## G5 map slice 1 (lead-ui, 2026-11-26; docs/MAP.md): MapData.parse_page (the bridge's page, contracts/overmap.md),
## LiveSession.query_overmap with a stand-in bridge, MapData's paging, MapCanvas's view (cell_at, pan_px 1:1, zoom
## about the pointer) and MapView's keys, mouse and info line. Run by run_tests.gd.

var _check: Callable


## Stands in for CddaSim's map read: keeps what was asked, answers from `results`.
class MapSim:
	var asked: Array = []
	var results := {}
	var next := 70

	func query_overmap(d: Dictionary) -> int:
		asked.append(d)
		next += 1
		return next

	func take_query_result(id: int) -> String:
		return results.get(id, "")


func run(root: Node, check: Callable) -> void:
	_check = check
	_test_parse()
	_test_query()
	_test_data()
	_test_recover()
	_test_canvas()
	_test_view(root)


## A page answer (contracts/overmap.md): (1, 2) a fully seen forest (explored), (3, 2) a vaguely seen field, a danger
## note at (5, 6); looks[0] is the unseen cell, as the bridge always sends it.
static func _page(id: int, origin: Array, extra := {}) -> Dictionary:
	var look := []
	var vision := []
	var flags := []
	for i in MapData.CELLS:
		look.append(0)
		vision.append(0)
		flags.append(0)
	look[2 * 32 + 1] = 1
	vision[2 * 32 + 1] = 4
	flags[2 * 32 + 1] = MapData.FLAG_EXPLORED
	look[2 * 32 + 3] = 2
	vision[2 * 32 + 3] = 1
	var d := {"kind": "overmap", "id": id, "ok": true, "origin": origin, "turn": 5000,
		"looks": [{"name": "", "sym": "", "color": ""}, {"name": "forest", "sym": "F", "color": "c_green"},
			{"name": "field", "sym": ".", "color": "c_brown"}],
		"look": look, "vision": vision, "flags": flags,
		"notes": [{"at": [origin[0] + 5, origin[1] + 6], "sym": "C", "color": "c_yellow",
			"text": "Cache <color_red>here</color>" + char(7) + "!", "danger": true, "radius": 2}],
		"notes_more": 0, "truncated": false}
	d.merge(extra, true)
	return d


func _parse(d: Dictionary, id := 5, asked := Vector3i(32, -64, 0)) -> Dictionary:
	return MapData.parse_page(JSON.stringify(d), id, asked)


func _test_parse() -> void:
	var o := [32, -64, 0]
	var r := _parse(_page(5, o, {"path": {"to": [34, -62, 0], "cells": [33, -62, 0, 34, -62, 0], "more": 0}}))
	var pg: MapData.Page = r.get("page")
	var good: bool = r.get("ok") == true and pg != null and pg.origin == Vector3i(32, -64, 0) \
			and pg.looks.size() == 2 and pg.looks[0]["name"] == "forest" and pg.looks[0]["symbol"] == "F" \
			and pg.looks[0]["color"] == Color(CddaText.COLORS["green"]) and pg.look[65] == 1 and pg.vision[67] == 1 \
			and pg.flags[65] == MapData.FLAG_EXPLORED
	var n: Dictionary = pg.notes.get(Vector2i(5, 6), {}) if pg != null else {}
	var noted: bool = n.get("text") == "Cache here!" and n.get("symbol") == "C" and n.get("danger") == true \
			and n.get("radius") == 2 and n.get("color") == Color(CddaText.COLORS["yellow"])
	var pathed: bool = r.get("path") == [Vector3i(33, -62, 0), Vector3i(34, -62, 0)] \
			and r.get("destination") == Vector3i(34, -62, 0)
	_check.call(good and noted and pathed, "map page: looks (the unseen one first), cells, flags, a note (colour tags and control characters out), the path")
	var odd_notes := _page(5, o)
	odd_notes["notes"] = [{"at": [32, -64], "sym": "", "color": "c_yellow", "text": "x".repeat(600), "danger": false,
			"radius": 0}, {"at": [64, -64], "sym": "N", "color": "c_red", "text": "elsewhere"},
			{"at": [33, -64], "sym": "!", "color": "c_red", "text": "far", "danger": true, "radius": 900}, "junk"]
	var on: MapData.Page = _parse(odd_notes).get("page")
	var kept: bool = on != null and on.notes.size() == 2 and (on.notes[Vector2i.ZERO]["text"] as String).length() \
			== MapData.MAX_NOTE and on.notes[Vector2i.ZERO]["symbol"] == "N" and on.notes[Vector2i(1, 0)]["radius"] \
			== MapData.MAX_RADIUS
	_check.call(kept, "map page: a note's text capped at 450, CDDA's N when it has no symbol, a radius capped; a note "
			+ "off the page or broken is left out, the page kept")
	var bad := {
		"another id": _page(6, o), "another kind": _page(5, o, {"kind": "vehicle_work"}),
		"another origin": _page(5, [0, -64, 0]), "257 looks": _page(5, o, {"looks": _looks(257)}),
		"no looks": _page(5, o, {"looks": []}), "a look past the list": _with_cell(_page(5, o), "look", 3),
		"vision 5": _with_cell(_page(5, o), "vision", 5), "a short list": _page(5, o, {"flags": [0]}),
		"a fraction": _with_cell(_page(5, o), "look", 1.5),
		"a 2049 cell path": _page(5, o, {"path": {"to": [0, 0, 0], "cells": _points(2049), "more": 0}}),
		"a path cell on level 11": _page(5, o, {"path": {"to": [0, 0, 0], "cells": [0, 0, 11], "more": 0}}),
		"a broken path cell": _page(5, o, {"path": {"to": [0, 0, 0], "cells": [0, 0, 0, 1], "more": 0}}),
		"a path without its end": _page(5, o, {"path": {"cells": [0, 0, 0], "more": 0}}),
	}
	var refused := PackedStringArray()
	for what: String in bad:
		if _parse(bad[what]).is_empty():
			refused.append(what)
	_check.call(refused.size() == bad.size(), "map page: refused (%s of %d): %s" % [refused.size(), bad.size(),
			", ".join(refused)])
	var big := JSON.stringify(_page(5, o, {"looks": _looks(200, "y".repeat(400))}))
	_check.call(big.length() > MapData.MAX_RESULT_BYTES and MapData.parse_page(big, 5, Vector3i(32, -64, 0)).is_empty(),
			"map page: an answer over 64 KB is refused")
	var err := _parse({"kind": "overmap", "id": 5, "ok": false, "error": "made up", "text": "No" + char(1)})
	var large := _parse({"kind": "overmap", "id": 5, "ok": false, "error": "too large"})
	_check.call(err == {"ok": false, "origin": Vector3i(32, -64, 0), "error": "internal", "text": "No"}
			and large.get("error") == "too large", "map page: error answers, an unknown error read as internal")


static func _looks(n: int, name := "x") -> Array:
	var out := []
	for i in n:
		out.append({"name": name, "sym": "x", "color": "c_white"})
	return out


## `n` path cells, flat (x, y, z each).
static func _points(n: int) -> Array:
	var out := []
	for i in n:
		out.append_array([i, 0, 0])
	return out


static func _with_cell(d: Dictionary, key: String, v: Variant) -> Dictionary:
	(d[key] as Array)[0] = v
	return d


func _session() -> Array:
	var sim := MapSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	return [sim, ls]


func _test_query() -> void:
	var s := _session()
	var sim: MapSim = s[0]
	var ls: LiveSession = s[1]
	var refused: bool = ls.query_overmap(Vector3i(16, 0, 0)) == 0 and ls.query_overmap(Vector3i(0, 0, 11)) == 0 \
			and ls.query_overmap(Vector3i(MapData.MAX_XY + 32, 0, 0)) == 0 and sim.asked.is_empty()
	var id := ls.query_overmap(Vector3i(-32, 64, -1), true)
	var sent: bool = id == 71 and sim.asked == [{"origin": [-32, 64, -1], "path": true}] and ls.overmap_pending()
	var held: bool = ls.query_overmap(Vector3i.ZERO) == 0
	var got: Array = []
	ls.overmap.connect(func(r: Dictionary) -> void: got.append(r))
	ls._poll_overmap()   # nothing yet
	sim.results[id] = JSON.stringify(_page(id, [-32, 64, -1]))
	ls._poll_overmap()
	var came: bool = got.size() == 1 and got[0]["ok"] == true and not ls.overmap_pending()
	var id2 := ls.query_overmap(Vector3i.ZERO)
	sim.results[id2] = "{not json"
	ls._poll_overmap()
	var bad: bool = got.size() == 2 and got[1] == {"ok": false, "origin": Vector3i.ZERO, "error": "internal"}
	_check.call(refused and sent and held and came and bad,
			"map query: bad origins refused, one at a time, the answer read, an unreadable one an error")


func _test_data() -> void:
	var s := _session()
	var sim: MapSim = s[0]
	var ls: LiveSession = s[1]
	var md := MapData.new()
	var changes := [0]
	md.changed.connect(func() -> void: changes[0] += 1)
	var snap := Snapshot.new()
	snap.player_pos = Vector3i(-1, 70, 0)   # cell (-1, 2): page (-32, 0)
	md.follow(snap)
	var quiet: bool = md.player_cell == Vector3i(-1, 2, 0) and sim.asked.is_empty()
	md.open()
	var no_bridge: bool = md.note == MapData.NO_BRIDGE
	md.live = ls
	md.want(Rect2i(-40, -10, 100, 40), 0)   # pages from x -64 to 32, y -32 to 0; the middle (10, 10)
	var first: bool = sim.asked.size() == 1 and sim.asked[0] == {"origin": [-32, 0, 0], "path": true}
	ls.overmap.connect(md.on_page)
	sim.results[sim.next] = JSON.stringify(_page(sim.next, [-32, 0, 0]))   # no destination
	ls._poll_overmap()
	var nearest: bool = sim.asked.size() == 2 and sim.asked[1] == {"origin": [0, 0, 0]}
	var i := md.info(Vector2i(-31, 2), 0)
	var known: bool = i.get("name") == "forest" and i.get("vision") == 4 and i.get("flags") == MapData.FLAG_EXPLORED \
			and md.info(Vector2i(-30, 2), 0).is_empty() and md.info(Vector2i(-27, 6), 0).has("note") \
			and md.info(Vector2i(5, 5), 0).is_empty() and md.note == ""
	sim.results[sim.next] = JSON.stringify({"kind": "overmap", "id": sim.next, "ok": false, "error": "internal"})
	ls._poll_overmap()
	var failed_once: bool = md.note.begins_with("The game couldn't read the map") \
			and sim.asked[-1]["origin"] != [0, 0, 0]   # not asked again at once
	sim.results[sim.next] = JSON.stringify(_page(sim.next, sim.asked[-1]["origin"]))
	ls._poll_overmap()   # (0, -32) came: (-32, -32) is asked next, without the path
	var next_out: bool = sim.asked[-1] == {"origin": [-32, -32, 0]}
	snap.player_pos = Vector3i(-1, -2, 0)   # a step into page (-32, -32) while its read is out
	md.follow(snap)
	sim.results[sim.next] = JSON.stringify(_page(sim.next, [-32, -32, 0]))
	ls._poll_overmap()
	var stepped: bool = next_out and md.player_cell == Vector3i(-1, -1, 0) \
			and sim.asked[-1] == {"origin": [-32, -32, 0], "path": true}   # read again, with the path
	md.close()
	var dropped: bool = not md.is_open() and md.page(Vector3i(-32, 0, 0)) == null and changes[0] > 3
	# at most 256 pages: the least recently wanted go
	md.open()
	for k in MapData.MAX_PAGES + 4:
		var o := Vector3i(k * 32, 0, 0)
		md.want(Rect2i(o.x, 0, 32, 32), 0)
		var pg := MapData.Page.new()
		pg.origin = o
		md.on_page({"ok": true, "origin": o, "page": pg})
	var capped: bool = md.page(Vector3i(0, 0, 0)) == null and md.page(Vector3i(3 * 32, 0, 0)) == null \
			and md.page(Vector3i(4 * 32, 0, 0)) != null and md.page(Vector3i((MapData.MAX_PAGES + 3) * 32, 0, 0)) != null
	var t0 := Time.get_ticks_msec()
	md.want(Rect2i(-(1 << 22), -(1 << 22), 1 << 23, 1 << 23), 0)   # a huge view: only the pages near its middle
	var near := func(o: Vector3i) -> bool: return absi(o.x) <= MapData.WANT_SPAN * 32 and absi(o.y) <= MapData.WANT_SPAN * 32
	var wide: bool = md._wanted.size() == MapData.MAX_WANTED and md._wanted.all(near) \
			and Time.get_ticks_msec() - t0 < 500
	md.close()
	_check.call(quiet and no_bridge and first and nearest and known and failed_once and stepped and dropped and capped
			and wide,
			"map data: the player's page first (with the path), then the nearest; a cell's look, unseen, a note; a "
			+ "failed page not asked again at once; a step reads the new page; closing drops all; 256 pages at most; "
			+ "a huge view reads only around its middle "
			+ "(%s)" % [[quiet, no_bridge, first, nearest, known, failed_once, stepped, dropped, capped, wide]])


func _test_recover() -> void:
	var s := _session()
	var sim: MapSim = s[0]
	var ls: LiveSession = s[1]
	var md := MapData.new()
	md.live = ls
	ls.overmap.connect(md.on_page)
	var snap := Snapshot.new()
	snap.player_pos = Vector3i(5, 5, 0)
	md.follow(snap)
	md.open()
	var mine := {"origin": [0, 0, 0], "path": true}
	sim.results[sim.next] = JSON.stringify({"kind": "overmap", "id": sim.next, "ok": false, "error": "too large"})
	ls._poll_overmap()
	md.want(Rect2i(0, 0, 10, 10), 0)
	md.follow(snap)
	var waits: bool = sim.asked == [mine] and md.note.contains("too large")
	md._failed[Vector3i.ZERO] = int(md._failed[Vector3i.ZERO]) - MapData.RETRY_MS   # its wait is over
	md.follow(snap)   # the next snapshot
	var retried: bool = sim.asked.size() == 2 and sim.asked[1] == mine
	ls.state = "ended"   # the game stopped with the read out: the session forgets it and says nothing
	ls._poll_overmap()
	ls.state = "running"
	md.follow(snap)
	var recovered: bool = sim.asked.size() == 3 and sim.asked[2] == mine
	md.reset()
	var cleared: bool = not md.has_player and md.page(Vector3i.ZERO) == null and md.note == "" and not md.reading()
	md.close()
	var odd := _page(5, [32, -64, 0])
	odd["notes"] = [{"at": [32, -64], "sym": "N", "color": "c_red",
			"text": "a" + char(0x2028).repeat(5) + char(0x2029) + "b"}]
	var pg: MapData.Page = _parse(odd).get("page")
	var one_line: bool = pg != null and pg.notes[Vector2i.ZERO]["text"] == "a" + " ".repeat(6) + "b"
	_check.call(waits and retried and recovered and cleared and one_line,
			"map data: the player's failed page waits before it is asked again; a read the session dropped is asked "
			+ "again; reset forgets the old game; a note's line breaks become spaces (%s)"
			% [[waits, retried, recovered, cleared, one_line]])


func _test_canvas() -> void:
	var c := MapCanvas.new()
	c.size = Vector2(400, 300)
	c.cell_px = 20.0
	c.middle = Vector2(0.5, 0.5)
	var moved := [0]
	c.view_moved.connect(func() -> void: moved[0] += 1)
	var mid: bool = c.cell_at(Vector2(200, 150)) == Vector2i(0, 0) and c.cell_at(Vector2(209, 150)) == Vector2i(0, 0) \
			and c.cell_at(Vector2(211, 150)) == Vector2i(1, 0) and c.cell_at(Vector2(0, 0)) == Vector2i(-10, -7)
	var spot := c.to_map(Vector2(250, 170))
	c.pan_px(Vector2(-60, 7))   # dragged 3 cells left
	var one_to_one: bool = c.to_px(spot).is_equal_approx(Vector2(190, 177)) \
			and c.cell_at(Vector2(200, 150)) == Vector2i(3, 0)
	var under := c.to_map(Vector2(100, 80))
	c.zoom_at(Vector2(100, 80), 2)
	var zoomed: bool = is_equal_approx(c.cell_px, 31.25) and c.to_map(Vector2(100, 80)).is_equal_approx(under)
	c.zoom_at(Vector2(100, 80), 8)
	c.zoom_at(Vector2(100, 80), 8)
	var top: bool = c.cell_px == MapCanvas.MAX_CELL
	c.change_level(-30)
	var low: bool = c.level == MapData.Z_MIN
	var md := MapData.new()
	md.player_cell = Vector3i(40, -5, 2)
	md.has_player = true
	c.data = md
	c.center_on_player()
	var home: bool = c.level == 2 and c.cell_at(c.size * 0.5) == Vector2i(40, -5)
	_check.call(mid and one_to_one and zoomed and top and low and home and moved[0] >= 5,
			"map canvas: cell_at, pan_px 1:1 (the spot under the pointer stays under it), zoom about the pointer, "
			+ "capped, levels -10..10, back to the player (%s)" % [[mid, one_to_one, zoomed, top, low, home, moved[0]]])
	c.free()


func _test_view(root: Node) -> void:
	var v := MapView.new()
	var mode := [Input.MOUSE_MODE_CAPTURED]
	v.mouse_hook = func(set_to: int) -> int:
		if set_to >= 0:
			mode[0] = set_to
		return mode[0]
	var md := MapData.new()
	md.player_cell = Vector3i(-31, 2, 0)
	md.has_player = true
	var s := _session()
	md.live = s[1]
	(s[1] as LiveSession).overmap.connect(md.on_page)
	v.data = md
	root.add_child(v)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.pressed = true
	var refused: bool = not v.handle_key(m, false) and not v.visible
	var opened: bool = v.handle_key(m, true) and v.visible and md.is_open() and mode[0] == Input.MOUSE_MODE_VISIBLE
	var sim: MapSim = s[0]
	var asked_mine: bool = sim.asked == [{"origin": [-32, 0, 0], "path": true}]
	sim.results[sim.next] = JSON.stringify(_page(sim.next, [-32, 0, 0]))
	(s[1] as LiveSession)._poll_overmap()
	v.canvas.size = Vector2(400, 300)
	v.canvas.center_on_player()
	var c := v.canvas
	v._hover = c.to_px(Vector2(-28.5, 2.5))   # the field two cells from the player's forest
	var field: bool = v.info_text() == "(-29, 2)  field, seen vaguely."
	var held: MapData.Page = md.page(Vector3i(-32, 0, 0))
	held.looks[1]["name"] = ""   # a look CDDA left unnamed
	var unnamed: bool = v.info_text() == "(-29, 2)  Something, seen vaguely."
	held.looks[1]["name"] = "field"
	held.vision[2 * 32 + 10] = 3   # (-22, 2): seen in detail, but its look was left out of a full page
	v._hover = c.to_px(Vector2(-21.5, 2.5))
	var unsent: bool = v.info_text() == "(-22, 2)  Something, seen in detail." \
			and MapCanvas.cell_color(held, 2 * 32 + 10) == Color(0.41, 0.41, 0.41) \
			and MapCanvas.cell_color(held, 0) == MapCanvas.FOG
	var far := MapData.Page.new()   # a read page 4 pages west of the view, with a horde's danger area reaching it
	far.origin = Vector3i(-160, 0, 0)
	far.look.resize(MapData.CELLS)
	far.vision.resize(MapData.CELLS)
	far.flags.resize(MapData.CELLS)
	far.notes[Vector2i(10, 3)] = {"text": "Horde", "symbol": "!", "color": Color.RED, "danger": true, "radius": 150}
	far.notes[Vector2i(11, 3)] = {"text": "Far", "symbol": "!", "color": Color.RED, "danger": true, "radius": 5}
	md.on_page({"ok": true, "origin": far.origin, "page": far})
	var areas := c.danger_areas()
	var danger: bool = areas.size() == 2 and areas.has(Rect2i(-29, 4, 5, 5)) and areas.has(Rect2i(-300, -147, 301, 301))
	v._hover = c.to_px(Vector2(-26.5, 6.5))
	var noted: bool = v.info_text().contains("Note (danger): Cache here!") and v.info_text().contains("Not seen.")
	v._hover = c.to_px(Vector2(40.5, 2.5))
	var unread: bool = v.info_text().ends_with("Not read yet.")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = c.global_position + Vector2(200, 150)
	v._gui_input(press)
	var was := c.middle
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(40, -20)
	drag.global_position = press.global_position + drag.relative
	v._gui_input(drag)
	var dragged: bool = (c.middle - was).is_equal_approx(Vector2(-40, 20) / c.cell_px)
	press.pressed = false
	v._gui_input(press)
	v._gui_input(drag)
	var let_go: bool = (c.middle - was).is_equal_approx(Vector2(-40, 20) / c.cell_px)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.global_position = c.global_position + Vector2(100, 100)
	var px := c.cell_px
	v._gui_input(wheel)
	var wheeled: bool = c.cell_px > px
	v.blocked = func() -> bool: return true   # a CDDA prompt over the map takes the keys
	v._input(m)
	var under_prompt: bool = v.visible
	v.blocked = Callable()
	var up := InputEventKey.new()
	up.physical_keycode = KEY_PAGEUP
	up.pressed = true
	var level_up: bool = v.handle_key(up) and c.level == 1
	var home := InputEventKey.new()
	home.physical_keycode = KEY_HOME
	home.pressed = true
	var back: bool = v.handle_key(home) and c.level == 0 and c.cell_at(c.size * 0.5) == Vector2i(-31, 2)
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	var closed: bool = v.handle_key(esc) and not v.visible and not md.is_open() \
			and mode[0] == Input.MOUSE_MODE_CAPTURED and md.page(Vector3i(-32, 0, 0)) == null
	_check.call(refused and opened and asked_mine and under_prompt and field and unnamed and unsent and danger and noted and unread and dragged and let_go and wheeled and level_up
			and back and closed, "map view: M opens it (the mouse free), the line names the cell, its vision and "
			+ "note; a drag moves the map 1:1, the wheel zooms, PgUp a level, Home back; Esc closes and drops the "
			+ "pages (%s)" % [[refused, opened, asked_mine, under_prompt, field, unnamed, unsent, danger, noted, unread, dragged, let_go, wheeled, level_up, back, closed]])
	root.remove_child(v)
	v.free()
