extends RefCounted
## G5 map slice 1 in VR (VrMap; docs/MAP.md "The VR view"): the sheet in the off hand shows a canvas; the free hand's
## trigger clicks (under 12 mm: the wheel, no pan) or drags 1:1 (on and off the sheet); the scroll marker fades
## after the first drag and is back on the next opening; the off hand's stick pans, the free hand's zooms and changes
## the level while its ray is on the sheet; the player neither walks nor turns meanwhile (turns only off the sheet).
## The canvas is a stand-in with lead-ui's agreed calls. Run by run_tests.gd.

var _check: Callable


## lead-ui's MapData as far as VrMap uses it: open / close counted, a name for every cell on level 0, notes kept
## (set_note / delete_note recorded; `refuse` answers false).
class Data extends RefCounted:
	signal note_done(tag: int, ok: bool, text: String)
	const NOTE_SYMBOLS := "N!X+*#@"   # not all of VrMapNote.PICKS ($ and ? missing); @ isn't one
	const NOTE_COLORS := [["Y", "yellow", Color(1, 1, 0)], ["R", "red", Color(1, 0, 0)], ["Q"],
			["G", "green", Color(0, 1, 0)]]   # ["Q"]: a bad row, dropped
	const MAX_DANGER_RADIUS := 20
	var opens := 0
	var closes := 0
	var notes := {}          # Vector2i -> {text, symbol, color (a Color), danger, radius}
	var sets: Array = []
	var deletes: Array = []
	var refuse := false      # set_note / delete_note answer 0
	var busy := false        # writing()
	var tag := 0

	func set_note(c: Vector3i, text: String, symbol := "N", color := "Y", danger := false, radius := 0) -> int:
		sets.append([c, text, symbol, color, danger, radius])
		return _tag()

	func delete_note(c: Vector3i) -> int:
		deletes.append(c)
		return _tag()

	func writing() -> bool:
		return busy

	func note_color_code(c: Color) -> String:
		for row: Array in NOTE_COLORS:
			if row.size() == 3 and row[2] == c:
				return row[0]
		return "Y"

	func _tag() -> int:
		if refuse:
			return 0
		tag += 1
		return tag

	func open() -> void:
		opens += 1

	func close() -> void:
		closes += 1

	func info(c: Vector2i, z: int) -> Dictionary:
		if z != 0:
			return {}
		var r := {"name": "field %d,%d" % [c.x, c.y]}
		if notes.has(c):
			r["note"] = notes[c]
		return r


## lead-ui's MapCanvas as far as VrMap uses it: cells CELL px square, `offset` the px the map was moved.
class Canvas extends Control:
	const CELL := 24.0
	var data := Data.new()
	var level := 0
	var cell_px := 20.0
	var shown := 0   # refresh() after data.open(), release() before data.close()
	var offset := Vector2.ZERO
	var pans: Array[Vector2] = []
	var zooms: Array = []
	var levels: Array[int] = []
	var centred := 0

	func cell_at(px: Vector2) -> Vector2i:
		return Vector2i(((px - offset) / CELL).floor())

	func pan_px(d: Vector2) -> void:
		offset += d
		pans.append(d)

	func zoom_at(px: Vector2, steps: int) -> void:
		zooms.append([px, steps])

	func change_level(d: int) -> void:
		levels.append(d)

	func center_on_player() -> void:
		centred += 1

	func refresh() -> void:
		shown += 1 if data.opens == data.closes + 1 else 100

	func release() -> void:
		shown -= 1 if data.opens == data.closes + 1 else 100


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr map")
	_test_sheet(root)
	_test_marker(root)
	_test_sticks(root)
	_test_rig(root)
	_test_real(root)
	_test_notes(root)


static func _m(px: float) -> float:   # canvas px to metres on the sheet
	return px / VrMap.PX.x * VrMap.SHEET_M.x


static func _sum(a: Array[Vector2]) -> Vector2:
	var s := Vector2.ZERO
	for v in a:
		s += v
	return s


## Click and drag: under CLICK_M a click opens the wheel on that cell and pans nothing; a drag of 3 cells moves the
## map exactly 3 cells and keeps the pressed spot under the ray; it goes on off the sheet; wheel items pick.
func _test_sheet(root: Node) -> void:
	var m := VrMap.new()
	root.add_child(m)
	var in_tree := Canvas.new()
	root.add_child(in_tree)
	var refused := not m.open(0, in_tree) and not m.open(2, Canvas.new()) and not m.is_open()
	in_tree.free()
	var cv := Canvas.new()
	var opened := m.open(0, cv) and m.is_open() and m.visible and cv.get_parent() == m.viewport and m.marker == 1.0 \
			and cv.data.opens == 1 and cv.data.closes == 0 and cv.cell_px == VrMap.CELL_PX and cv.shown == 1
	var p0 := Vector3(0.01, 0.0, 0.0)
	m.point(p0)
	m.step(0.016)
	var named: bool = m.named == cv.cell_at(VrMap.to_px(p0)) and (m.get("_name") as Label3D).text == "field 17,16"
	var pressed := m.press()
	m.point(p0 + Vector3(0.006, 0.006, 0.0))   # 8.5 mm: still a click
	m.release()
	m.point(Vector3(-0.1, 0.1, 0.0))   # pointing elsewhere: the title stays the wheel's cell's name
	m.step(0.016)
	var click: bool = pressed and cv.pans.is_empty() and m.wheel_at == Vector2(0.01, 0.0) and m.named == Vector2i(17, 16) \
			and m.wheel_cell == Vector2i(17, 16) and not m.dragging
	m.point(Vector3(-0.1, -0.1, 0.0))   # a click away from the wheel's items closes it, choosing nothing
	m.press()
	m.release()
	var shut: bool = m.wheel_at == Vector2.INF and cv.pans.is_empty() and m.is_open()
	var start := cv.cell_at(VrMap.to_px(p0))
	m.point(p0)
	m.press()
	m.point(p0 + Vector3(0.01, 0.0, 0.0))   # 10 mm: not yet
	var held: bool = cv.pans.is_empty() and not m.dragging
	var to := p0 + Vector3(_m(3.0 * Canvas.CELL), 0.0, 0.0)
	m.point(to)
	m.step(0.016)
	var moved := _sum(cv.pans)
	var drag: bool = m.dragging and moved.is_equal_approx(Vector2(3.0 * Canvas.CELL, 0.0)) \
			and cv.cell_at(VrMap.to_px(to)) == start and m.named == Vector2i.MAX
	m.point(Vector3(0.25, 0.0, 0.0))   # off the sheet: on along its plane
	var off_sheet: bool = not m.pointing and m.dragging \
			and _sum(cv.pans).is_equal_approx(VrMap.to_px(Vector3(0.25, 0.0, 0.0)) - VrMap.to_px(p0))
	m.release()
	var ended: bool = not m.dragging and m.wheel_at == Vector2.INF
	m.point(Vector3(0.05, 0.05, 0.0))   # the wheel, then "Centre here" (up): that spot to the middle
	m.press()
	m.release()
	m.point(Vector3(0.05, 0.05 + VrMap.WHEEL_R_M, 0.0))
	var hover := m.hover
	var n := cv.pans.size()
	m.press()
	m.release()
	var centre: bool = hover == 0 and cv.pans.size() == n + 1 \
			and cv.pans[n].is_equal_approx(Vector2(VrMap.PX) * 0.5 - VrMap.to_px(Vector3(0.05, 0.05, 0.0)))
	m.point(Vector3(0.0, 0.0, 0.0))   # "Close map" puts it away
	m.press()
	m.release()
	m.point(_item(m, "close"))
	m.press()
	m.release()
	var closed: bool = not m.is_open() and m.canvas == null and not m.visible and cv.data.opens == 1 \
			and cv.data.closes == 1 and cv.shown == 0
	m.free()
	_check.call(refused and opened and named and click and shut and held and drag and off_sheet and ended and centre and closed,
			"vr map: under 12 mm a click opens the wheel on that cell and pans nothing; a drag of 3 cells moves the map 3 cells, the pressed spot staying under the ray, on off the sheet; the wheel centres or closes (%s)"
			% [[refused, opened, named, click, shut, held, drag, off_sheet, ended, centre, closed]])


## The scroll marker shows on opening, stays until the first drag, then fades over FADE_S; back on the next opening.
func _test_marker(root: Node) -> void:
	var m := VrMap.new()
	root.add_child(m)
	m.open(1, Canvas.new())
	var mk: Node3D = m.get("_marker")
	m.step(2.0)
	var stays: bool = m.marker == 1.0 and mk.visible and mk.get_child_count() == 5
	m.point(Vector3.ZERO)
	m.press()
	m.point(Vector3(0.05, 0.0, 0.0))
	m.release()
	m.step(VrMap.FADE_S * 0.5)
	var half: bool = is_equal_approx(m.marker, 0.5) and mk.visible
	m.step(VrMap.FADE_S)
	var gone: bool = m.marker == 0.0 and not mk.visible
	m.close()
	var cv := Canvas.new()
	m.open(1, cv)
	m.step(0.5)
	var back: bool = m.marker == 1.0 and mk.visible
	root.remove_child(m)   # taken out (or freed) with the sheet out: MapData's user goes too
	var left: bool = not m.is_open() and cv.data.opens == 1 and cv.data.closes == 1 and cv.shown == 0
	m.free()
	_check.call(stays and half and gone and back and left,
			"vr map marker: four chevrons and a drag icon until the first drag, then faded over 0.5 s; back on the next opening; leaving the tree puts the sheet away (%s)"
			% [[stays, half, gone, back, left]])


## The off hand's stick pans; the free hand's, only while its ray is on the sheet, zooms on the pointed cell (y)
## and changes the level (x), once a push.
func _test_sticks(root: Node) -> void:
	var m := VrMap.new()
	root.add_child(m)
	var cv := Canvas.new()
	m.open(0, cv)
	m.sticks(Vector2(1.0, 0.0), Vector2.ZERO, 0.1)
	var pan: bool = cv.pans.size() == 1 and cv.pans[0].is_equal_approx(Vector2(-VrMap.PAN_PX_S * 0.1, 0.0))
	m.sticks(Vector2(0.1, 0.0), Vector2.ZERO, 0.1)
	var dead: bool = cv.pans.size() == 1
	m.point(Vector3(0.6, 0.0, 0.0))   # the ray off the sheet: the free stick is left to turning
	m.sticks(Vector2.ZERO, Vector2(0.0, 0.9), 0.016)
	var off: bool = cv.zooms.is_empty()
	m.point(Vector3(0.03, 0.0, 0.0))
	m.sticks(Vector2.ZERO, Vector2(0.0, 0.9), 0.016)
	m.sticks(Vector2.ZERO, Vector2(0.0, 0.95), 0.016)   # held: one step a push
	var zoom: bool = cv.zooms.size() == 1 and cv.zooms[0][1] == 1 \
			and (cv.zooms[0][0] as Vector2).is_equal_approx(VrMap.to_px(Vector3(0.03, 0.0, 0.0)))
	m.sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	m.sticks(Vector2.ZERO, Vector2(-0.9, 0.1), 0.016)
	m.sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	m.sticks(Vector2.ZERO, Vector2(0.0, -0.9), 0.016)
	var level: bool = cv.levels.size() == 1 and cv.levels[0] == -1 and cv.zooms.size() == 2 and cv.zooms[1][1] == -1
	m.centre()
	var home: bool = cv.centred == 1
	m.free()
	_check.call(pan and dead and off and zoom and level and home,
			"vr map sticks: the off hand's pans; the free hand's zooms on the pointed cell and changes the level a push, only with its ray on the sheet (%s)"
			% [[pan, dead, off, zoom, level, home]])


## The rig: the left stick click opens the map in the off hand (no canvas: a note); the hint once; the sheet follows
## that hand; the free hand's ray on it points; its trigger clicks; walking is held back and turning too while the
## ray is on the sheet; something taken into the off hand, or B / Y, puts it away.
func _test_rig(root: Node) -> void:
	var snap := Snapshot.new()
	var world := WorldView.new()
	world.snapshot = snap
	var hands := Hands.new(world, ItemActions.new())
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.hands = hands
	var hints := Hints.new()
	hints.persist = false
	rig.hint.source = hints
	rig.settings["vignette"] = 0.5
	var b0: int = rig.buzzes[1]
	rig.press(rig.left, "primary_click")
	var note: bool = not rig.map.is_open() and rig.busy.get("_flash") == VrRig.NO_MAP and rig.buzzes[1] == b0 + 1
	var made: Array[Canvas] = []
	rig.map.make_canvas = func() -> Control:
		var c := Canvas.new()
		made.append(c)
		return c
	rig.press(rig.left, "primary_click")
	var opened: bool = rig.map.is_open() and rig.map.hand == 0 and rig.ui_open() and hints.seen.has("vr_map")
	rig.left.global_transform = Transform3D(Basis(), Vector3(0.0, 1.0, -0.3))
	rig.update_map(0.016, true)
	var held: bool = rig.map.global_transform.is_equal_approx(rig.left.global_transform * rig.map.hold)
	var sheet := rig.map.global_transform
	rig.right.global_transform = Transform3D(sheet.basis, sheet * Vector3(0.02, 0.0, 0.3))   # looking at the sheet
	rig.update_pointer(true)
	var points: bool = rig.map.pointing and rig.pointer.visible and rig.pointer_dot.visible \
			and rig.pointer_dot.global_position.is_equal_approx(sheet * Vector3(0.02, 0.0, 0.0))
	rig.press(rig.right, "trigger_click")
	rig.release(rig.right, "trigger_click")
	var click: bool = rig.map.wheel_at.is_equal_approx(Vector2(0.02, 0.0)) and made[0].pans.is_empty()
	var b1: int = rig.buzzes[0]
	rig.press(rig.left, "trigger_click")   # the off hand's trigger: nothing on the map
	var off_trigger: bool = rig.buzzes[0] == b1 + 1 and rig.map.is_open()
	rig.press(rig.left, "primary_click")   # the off hand's stick click: back to the player
	var b2: int = rig.buzzes[1]
	rig.map.said.emit(VrMap.NOT_SENT)   # the map's notes: flashed, a buzz in the pointing hand
	var home: bool = rig.map.is_open() and made[0].centred == 1 and rig.busy.get("_flash") == VrMap.NOT_SENT \
			and rig.buzzes[1] == b2 + 1
	var at := rig.global_position
	var yaw := rig.global_basis
	rig.step(0.5, {"move": Vector2(0.0, 1.0), "turn": Vector2.ZERO})
	rig.step(0.016, {"move": Vector2.ZERO, "turn": Vector2(1.0, 0.0)})   # the ray on the sheet: no snap turn
	var still: bool = rig.global_position == at and rig.global_basis.is_equal_approx(yaw) and rig.vignette == 0.0
	rig.map.point(null)   # the ray off the sheet: the turn stick turns again
	rig.step(0.016, {"move": Vector2.ZERO, "turn": Vector2.ZERO})
	rig.step(0.016, {"move": Vector2.ZERO, "turn": Vector2(1.0, 0.0)})
	var turns: bool = not rig.global_basis.is_equal_approx(yaw)
	hands.hand("vr_l").held = {"kind": "item", "item": ItemRef.new()}
	rig.update_map(0.016, true)
	var taken: bool = not rig.map.is_open()
	hands.hand("vr_l").held = {}
	rig.press(rig.left, "primary_click")
	rig.press(rig.right, "by_button")
	var away: bool = not rig.map.is_open() and made.size() == 2 and not rig.ui_open()
	rig.step(0.5, {"move": Vector2(0.0, 1.0), "turn": Vector2.ZERO})
	var walks: bool = rig.vignette > 0.0   # (the map put away: the same stick walks again, the vignette shows)
	rig.free()
	if is_instance_valid(hands):
		hands.free()
	hints.free()
	world.free()
	_check.call(note and opened and held and points and click and off_trigger and home and still and turns and taken and away and walks,
			"vr map rig: the left stick click opens the map in the off hand (the hint once; no canvas: a note); the free hand's ray points and its trigger clicks; no walking, no turning with the ray on the sheet; taking something or B / Y puts it away (%s)"
			% [[note, opened, held, points, click, off_trigger, home, still, turns, taken, away, walks]])


## VrMap on lead-ui's real MapCanvas and MapData (what main's make_canvas gives): its cell size and MapData's user
## while out; a click opens the wheel on the cell under the ray; a drag of 3 cells moves the map 3 cells, the pressed
## spot staying under the ray; a zoom keeps the pointed cell still; put away, MapData's user goes.
func _test_real(root: Node) -> void:
	var m := VrMap.new()
	root.add_child(m)
	var d := MapData.new()
	var c := MapCanvas.new()
	c.data = d
	var opened: bool = m.open(0, c) and c.cell_px == VrMap.CELL_PX and d.get("_users") == 1 \
			and c.size == Vector2(VrMap.PX)
	var p0 := Vector3(0.02, -0.01, 0.0)
	var under := c.cell_at(VrMap.to_px(p0))
	m.point(p0)
	m.press()
	m.release()
	var click: bool = m.wheel_cell == under
	m.point(Vector3(-0.12, 0.12, 0.0))   # away from the wheel's items: it closes
	m.press()
	m.release()
	m.point(p0)
	m.press()
	var p1 := p0 + Vector3(VrMap.SHEET_M.x * 3.0 * VrMap.CELL_PX / VrMap.PX.x, 0.0, 0.0)
	m.point(p1)
	m.release()
	var drag: bool = c.cell_at(VrMap.to_px(p1)) == under and c.cell_at(VrMap.to_px(p0)) == under - Vector2i(3, 0)
	m.point(p0)
	m.sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	var at := c.cell_at(VrMap.to_px(p0))
	m.sticks(Vector2.ZERO, Vector2(0.0, 0.9), 0.016)
	var zoom: bool = c.cell_px > VrMap.CELL_PX and c.cell_at(VrMap.to_px(p0)) == at
	m.close()
	var closed: bool = d.get("_users") == 0 and not is_instance_valid(m.canvas)
	m.free()
	_check.call(opened and click and drag and zoom and closed,
			"vr map on the real canvas: MapData has a user while out; a click opens the wheel on the cell under the ray; a drag of 3 cells keeps that spot under it; a zoom keeps the pointed cell (%s)"
			% [[opened, click, drag, zoom, closed]])


## Where wheel item `value` is (sheet frame); far off when it isn't on the wheel.
static func _item(m: VrMap, value: String) -> Vector3:
	for k in m.items.size():
		if m.items[k]["value"] == value:
			return (m.get("_labels")[k] as Label3D).position * Vector3(1.0, 1.0, 0.0)
	return Vector3(9.0, 9.0, 0.0)


## Where note panel button `id` is (sheet frame).
static func _button(m: VrMap, id: String) -> Vector3:
	for b: Dictionary in m.note.get("_buttons"):
		if b["id"] == id:
			var c := (b["rect"] as Rect2).get_center()
			return Vector3(c.x, c.y, 0.0)
	return Vector3(9.0, 9.0, 0.0)


static func _click(m: VrMap, p: Vector3) -> void:
	m.point(p)
	m.press()
	m.release()


## Slice 2: the wheel adds a note, or edits and deletes one (asked again first). The panel offers MapData's symbols
## and colours (a bad row dropped), steps them, toggles danger and steps its radius, picks up to 3 words (picked
## again: out); editing keeps the old text, symbol and colour unless changed, and an odd old symbol isn't offered
## for the next note. Save with no text, with another write out or refused here says so; CDDA's refusal of this
## sheet's write says its sentence (others' answers, and one already given, nothing). The panel takes the ray (no
## drag, no zoom); "Type" only with lead-ui's dialog given, handing the cell to it.
func _test_notes(root: Node) -> void:
	var m := VrMap.new()
	root.add_child(m)
	var cv := Canvas.new()
	var d := cv.data
	m.open(0, cv)
	var said := []
	m.said.connect(func(t: String) -> void: said.append(t))
	var at := Vector3(-0.08, -0.08, 0.0)
	var cell := cv.cell_at(VrMap.to_px(at))
	var c3 := Vector3i(cell.x, cell.y, 0)
	_click(m, at)
	var plain: bool = m.items.map(func(i: Dictionary) -> String: return i["value"]) == ["centre", "note", "close"]
	_click(m, _item(m, "note"))
	var panel: bool = m.note.is_open() and m.note.cell == cell and m.wheel_at == Vector2.INF \
			and not (m.note.get("_title") as Label3D).text.is_empty() and m.note._button_at(_button(m, "keyboard")) == ""
	var lists: bool = "".join(PackedStringArray(m.note.symbols)) == "N!X+*#" and m.note.colors.size() == 3 \
			and m.note.colors[2] == "G" and m.note.max_radius == 20
	_click(m, _button(m, "save"))   # no words, no old text
	var no_text: bool = d.sets.is_empty() and m.note.is_open() and said == [VrMap.NO_TEXT]
	for w in ["Zombies", "Horde", "Loot", "Food"]:   # the fourth is one too many
		_click(m, _button(m, "w:" + w))
	var three: bool = m.note.text() == "Zombies Horde Loot"
	_click(m, _button(m, "w:Horde"))
	_click(m, _button(m, "sym+"))
	_click(m, _button(m, "col+"))
	_click(m, _button(m, "danger"))
	_click(m, _button(m, "rad+"))
	_click(m, _button(m, "rad+"))
	m.point(Vector3(0.0, 0.0, 0.0))   # a press moved far on the panel: no drag
	m.press()
	m.point(Vector3(0.1, 0.0, 0.0))
	m.release()
	m.sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	m.sticks(Vector2.ZERO, Vector2(0.0, 0.9), 0.016)
	var held: bool = cv.pans.is_empty() and cv.zooms.is_empty() and not m.dragging
	d.busy = true   # another write still out: said, and the panel stays to save again
	_click(m, _button(m, "save"))
	var busy: bool = d.sets.is_empty() and m.note.is_open() and said.size() == 2 and said[1] == VrMap.BUSY
	d.busy = false
	_click(m, _button(m, "save"))
	var sent: bool = d.sets == [[c3, "Zombies Loot", "!", "R", true, 2]] and not m.note.is_open()
	d.notes[cell] = {"text": "Old words", "symbol": "$", "color": Color(0, 1, 0), "danger": true, "radius": 3}
	_click(m, at)
	var both: bool = m.items.map(func(i: Dictionary) -> String: return i["value"]) == ["centre", "note", "unnote", "close"] \
			and (m.get("_labels")[1] as Label3D).text == "Edit note"
	_click(m, _item(m, "note"))
	var edit: bool = m.note.symbols[m.note.symbol] == "$" and m.note.colors[m.note.color] == "G" and m.note.danger \
			and m.note.radius == 3 and m.note.text() == "Old words" and d.notes[cell]["color"] is Color
	_click(m, _button(m, "save"))
	var kept: bool = d.sets.size() == 2 and d.sets[1] == [c3, "Old words", "$", "G", true, 3]
	_click(m, Vector3(0.08, 0.08, 0.0))   # another cell's new note: the defaults, no "$"
	_click(m, _item(m, "note"))
	var fresh: bool = m.note.symbols[m.note.symbol] == "N" and not m.note.symbols.has("$") \
			and m.note.colors[m.note.color] == "Y"
	_click(m, _button(m, "cancel"))
	fresh = fresh and not m.note.is_open() and d.sets.size() == 2
	_click(m, at)
	_click(m, _item(m, "unnote"))
	var asked: bool = m.items.size() == 2 and d.deletes.is_empty()
	_click(m, _item(m, "keep"))
	var keep: bool = d.deletes.is_empty() and m.wheel_at == Vector2.INF
	_click(m, at)
	_click(m, _item(m, "unnote"))
	_click(m, _item(m, "unnote!"))
	var deleted: bool = d.deletes == [c3] and said.size() == 2
	d.note_done.emit(1, true, "")                                    # the first save went in: nothing
	d.note_done.emit(d.tag, false, "  That note can't go there.  ")   # CDDA refused the delete
	d.note_done.emit(d.tag, false, "again")                           # answered already: nothing
	d.note_done.emit(99, false, "not ours")                          # another view's write: nothing
	var cdda: bool = said.size() == 3 and said[2] == "That note can't go there."
	d.refuse = true
	_click(m, at)
	_click(m, _item(m, "unnote"))
	_click(m, _item(m, "unnote!"))
	var refused: bool = said.size() == 4 and said[3] == VrMap.NOT_SENT
	d.refuse = false
	var dialog: Array = []
	m.open_note_dialog = func(c: Vector3i) -> void: dialog.append(c)
	_click(m, at)
	_click(m, _item(m, "note"))
	_click(m, _button(m, "keyboard"))
	var keyboard: bool = dialog == [c3] and not m.note.is_open()
	m.free()
	var all := [plain, panel, lists, no_text, three, held, busy, sent, both, edit, kept, fresh, asked, keep, deleted, cdda,
			refused, keyboard]
	_check.call(not all.has(false),
			"vr map notes: the wheel adds, edits or deletes (asked again) a note; MapData's lists; symbol, colour, danger and radius step; 3 words at most; editing keeps the old note; no text, busy or a refusal says so; the panel takes the ray; Type only with the dialog given (%s)"
			% [all])
