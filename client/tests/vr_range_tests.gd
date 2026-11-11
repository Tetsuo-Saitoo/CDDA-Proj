extends RefCounted
## K7: the VR menu's Test range page (VrRange, VrMenu, VrRig), run by run_tests.gd. A stand-in backend with
## LiveSession's range surface (lead-ui's, not on this branch yet) records the calls and hands out op ids; the test
## emits range_done / range_changed itself. No XR runtime: the test places the head and the pointing hand.

var _check: Callable


## LiveSession's range methods and signals. `info` is what range_info returns (anything: tests feed junk);
## `ranged` what in_range says; refused ops (accept false, or not in range) return 0 but are recorded.
class Backend extends RefCounted:
	signal range_changed(info: Dictionary)
	signal range_done(op_id: int, error: String)
	var info: Variant = {}
	var ranged: Variant = true
	var accept := true
	var next_id := 40
	var calls: Array = []

	func in_range() -> Variant:
		return ranged

	func range_info() -> Variant:
		return info.duplicate(true) if info is Dictionary else info

	func _op(c: Array) -> int:
		calls.append(c)
		if not accept or ranged != true:
			return 0
		next_id += 1
		return next_id

	func range_teleport(zone: int) -> int:
		return _op(["teleport", zone])

	func range_set_time(minute: int) -> int:
		return _op(["time", minute])

	func range_advance(minutes: int) -> int:
		return _op(["advance", minutes])

	func range_set_ai_frozen(on: bool) -> int:
		return _op(["frozen", on])

	func range_heal() -> int:
		return _op(["heal"])

	func range_spawn_item(itype: int, count: int, pos: Vector3i) -> int:
		return _op(["item", itype, count, pos])

	func range_spawn_monster(id: String, pos: Vector3i) -> int:
		return _op(["monster", id, pos])


## Has the queries but no ops: no page.
class Partial extends RefCounted:
	func in_range() -> bool:
		return true

	func range_info() -> Dictionary:
		return {"range": true, "zones": [{"name": "Hub", "built": true}], "zone": 0}


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr range")
	_test_rows()
	_test_apply()
	_test_menu(root)
	_test_follow(root)


func _info(zone := 1, frozen := true) -> Dictionary:
	return {"range": true, "ai_frozen": frozen, "zone": zone, "zones": [
		{"id": "hub", "name": "Hub", "kind": "hub", "built": true},
		{"id": "gallery", "name": "Gallery", "kind": "gallery", "built": true},
		{"id": "armory", "name": "Armory", "kind": "armory", "built": false}]}


func _keys(rows: Array[Dictionary]) -> Array:
	return rows.map(func(r: Dictionary) -> String: return r["key"])


const FIXED := ["freeze", "heal", "wait_hour", "time_6", "time_12", "time_18", "time_0"]


func _test_rows() -> void:
	var b := Backend.new()
	b.info = _info()
	_check.call(VrRange.available(b) and not VrRange.available(null) and not VrRange.available(RefCounted.new())
			and not VrRange.available(Partial.new()) and not VrRange.available(5),
			"vr range: available needs the range methods")
	b.ranged = false
	var outside := VrRange.available(b)
	b.ranged = 1
	var odd := VrRange.available(b)
	b.ranged = true
	_check.call(not outside and not odd and VrRange.rows(Backend.new()).size() == FIXED.size(),
			"vr range: not in a range game (or a non-bool answer): not available")
	b.ranged = false
	_check.call(VrRange.rows(b).is_empty(), "vr range: no rows outside the range")
	b.ranged = true
	var r := VrRange.rows(b)
	_check.call(_keys(r) == FIXED + ["go_0", "go_1", "go_2"] and r[0]["kind"] == VrRange.TOGGLE and r[0]["on"] == true
			and r[0]["label"] == "Monsters frozen" and r[1]["label"] == "Heal" and r[2]["label"] == "Wait 1 hour"
			and r[4]["label"] == "Set time 12:00" and r[7]["label"] == "Go to: Hub" and r[8]["label"] == "Go to: Gallery (here)"
			and r[8]["here"] == true and r[9]["label"] == "Go to: Armory (not built yet)" and r[9]["zone"] == 2
			and r.slice(1).all(func(x: Dictionary) -> bool: return x["kind"] == VrRange.ACTION and x["enabled"] == true),
			"vr range: the flat page's controls, then a Go to per zone (here and not built yet marked)")
	# Hostile range_info: junk zones skipped (their index kept), names cleaned and capped, caps, bad fields defaulted.
	var zones: Array = [5, {"name": "<color_red>Evil</color>\n\t" + "x".repeat(100), "built": "yes"}, {"name": 7}, {}]
	for i in 80:
		zones.append({"name": "Z%d" % i, "built": true})
	var h := VrRange.rows_from({"zones": zones, "zone": 1.5, "ai_frozen": "true"})
	var go: Array = h.filter(func(x: Dictionary) -> bool: return x["zone"] >= 0)
	var evil: String = go[0]["name"]
	_check.call(go.size() == VrRange.MAX_ZONES - 1 and go[0]["zone"] == 1 and go[0]["key"] == "go_1"
			and evil.begins_with("Evil") and not evil.contains("<") and not evil.contains("\n")
			and evil.length() <= VrRange.NAME_MAX and (go[0]["label"] as String).ends_with("(not built yet)")
			and go[1]["label"] == "Go to: Zone 3 (not built yet)" and go[2]["label"] == "Go to: Zone 4 (not built yet)"
			and go[-1]["zone"] == VrRange.MAX_ZONES - 1 and h[0]["on"] == false
			and go.all(func(x: Dictionary) -> bool: return x["here"] == false),
			"vr range: hostile info: bad zones skipped, names cleaned and capped, at most MAX_ZONES, bad zone / freeze ignored")
	_check.call(VrRange.rows_from(null).size() == FIXED.size() and VrRange.rows_from("junk").size() == FIXED.size()
			and VrRange.rows_from({"zones": "abc"}).size() == FIXED.size()
			and VrRange.clean_info({"zones": [{}, {}], "zone": 9})["zone"] == -1
			and VrRange.clean_info({"zones": [{}, {}], "zone": 1.0})["zone"] == 1
			and VrRange.clean_info({"zones": [{}, {}], "zone": -1})["zone"] == -1,
			"vr range: junk info, only the fixed rows; the zone index checked")
	_check.call(VrRange.zone_of("go_3") == 3 and VrRange.zone_of("go_-1") == -1 and VrRange.zone_of("go_x") == -1
			and VrRange.zone_of("go_64") == -1 and VrRange.zone_of("go_1000") == -1 and VrRange.zone_of("heal") == -1
			and VrRange.zone_of("go_") == -1, "vr range: Go to keys parsed and bounded")
	_check.call(VrRange.op_id(5) == 5 and VrRange.op_id(5.0) == 5 and VrRange.op_id(5.5) == 0 and VrRange.op_id(NAN) == 0
			and VrRange.op_id(-1) == 0 and VrRange.op_id(0) == 0 and VrRange.op_id("7") == 0 and VrRange.op_id(null) == 0
			and VrRange.op_id(1 << 60) == 0 and VrRange.op_id(INF) == 0, "vr range: op ids checked")


func _test_apply() -> void:
	var b := Backend.new()
	b.info = _info()
	var id := VrRange.apply(b, "go_2")
	_check.call(id > 0 and b.calls.back() == ["teleport", 2], "vr range: Go to calls range_teleport with the zone index")
	VrRange.apply(b, "freeze")
	var froze: Array = b.calls.back()
	b.info["ai_frozen"] = false
	VrRange.apply(b, "freeze")
	_check.call(froze == ["frozen", false] and b.calls.back() == ["frozen", true], "vr range: the freeze flips what range_info says")
	VrRange.apply(b, "heal")
	var healed: Array = b.calls.back()
	VrRange.apply(b, "wait_hour")
	var waited: Array = b.calls.back()
	VrRange.apply(b, "time_18")
	var evening: Array = b.calls.back()
	VrRange.apply(b, "time_0")
	_check.call(healed == ["heal"] and waited == ["advance", 60] and evening == ["time", 1080] and b.calls.back() == ["time", 0],
			"vr range: heal, wait 1 hour, set times")
	var n := b.calls.size()
	_check.call(VrRange.apply(b, "time_7") == 0 and VrRange.apply(b, "nope") == 0 and VrRange.apply(b, "go_x") == 0
			and VrRange.apply(null, "heal") == 0 and b.calls.size() == n, "vr range: no call for a bad key or no backend")
	b.ranged = false
	_check.call(VrRange.apply(b, "heal") == 0 and b.calls.size() == n, "vr range: no call outside the range")
	b.ranged = true
	b.accept = false
	_check.call(VrRange.apply(b, "heal") == 0 and b.calls.size() == n + 1, "vr range: a refusal is op id 0")
	b.accept = true
	var u := VrRange.use(b, "go_1")
	var f := VrRange.use(b, "freeze")
	var t := VrRange.use(b, "time_6")
	_check.call(u["text"] == "Go to Gallery" and u["id"] > 0 and f["text"] == "Monsters frozen" and t["text"] == "Time 6:00"
			and VrRange.use(b, "go_9")["id"] == 0, "vr range: use says what was asked; a zone that isn't there isn't sent")


## The menu line containing `s`, -1 for none.
func _line_with(menu: VrMenu, s: String) -> int:
	var t := menu.texts()
	for i in t.size():
		if t[i].contains(s):
			return i
	return -1


## The main hand's pointer and trigger on row r of the open menu (x: where on the line, < 0 the left half).
func _click(rig: VrRig, r: int, x := 0.1) -> void:
	var menu := rig.menu
	var at := menu.global_transform * Vector3(x, -(r + 1) * VrMenu.LINE_H, 0)
	rig.right.global_position = at + menu.global_basis.z * 0.6 + Vector3(0.05, -0.3, 0)
	rig.right.look_at(at, Vector3.UP)
	rig.update_pointer(true)
	rig.press(rig.right, "trigger_click")


func _test_menu(root: Node) -> void:
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var b := Backend.new()
	b.info = _info()
	rig.cheats_backend = b
	rig.press(rig.left, "menu_button")
	var menu := rig.menu
	var n := VrSettings.ROWS.size()
	_check.call(rig.menu_open() and not menu.range_shown() and menu.row_count() == n and _line_with(menu, "Test range >") < 0,
			"vr range menu: no Test range row unless cheats are allowed")
	rig.cheats_allowed = true
	_check.call(menu.range_shown() and not menu.cheats_shown() and menu.row_count() == n + 1 and menu.key_of(n) == VrMenu.RANGE_ROW
			and _line_with(menu, "Test range >") == n + 1, "vr range menu: allowed and in a range game: a Test range row")
	b.ranged = false
	b.range_changed.emit({})
	var gone := menu.row_count() == n and _line_with(menu, "Test range >") < 0
	b.ranged = true
	b.range_changed.emit(b.info)
	_check.call(gone and menu.row_count() == n + 1, "vr range menu: the row goes when the range game stops (range_changed)")
	rig.cheats_backend = Partial.new()
	var partial := menu.row_count()
	rig.cheats_backend = b
	_check.call(partial == n and menu.row_count() == n + 1, "vr range menu: no row for a backend without the range ops")
	# Stick: up from the first row wraps to "Test range >", right opens the page.
	menu.row = 0
	rig.step(0.1, {"move": Vector2(0, 1)})
	rig.step(0.1, {})
	var picked := menu.row
	rig.step(0.1, {"move": Vector2(1, 0)})
	rig.step(0.1, {})
	var t := menu.texts()
	_check.call(picked == n and menu.page == VrMenu.RANGE_PAGE and menu.row == 0 and t[0] == "Test range" and t[1].contains("< Back")
			and t[2].contains("Monsters frozen:  on") and _line_with(menu, "Go to: Gallery (here)") > 0
			and _line_with(menu, "Go to: Armory (not built yet)") > 0 and _line_with(menu, "Set time 12:00") > 0
			and _line_with(menu, "Zones") < 0 and menu.line_count() == menu.row_count() + 3,
			"vr range menu: stick opens the page (back, freeze, heal, wait, times, the zones; no pager for 3)")
	# Pointer: teleport, then its range_done.
	var armory := menu.row_of("go_2")
	_click(rig, armory)
	var id: int = b.next_id
	_check.call(b.calls.back() == ["teleport", 2] and menu.range_status == "Go to Armory: …" and _line_with(menu, "Go to Armory: …") > 0
			and not menu.range_warn, "vr range menu: pointer on a zone teleports there; the status waits")
	b.range_done.emit(id + 7, "")
	b.range_done.emit(id + 7, "boom")
	var kept := menu.range_status == "Go to Armory: …"
	b.range_done.emit(id, "")
	_check.call(kept and menu.range_status == "Go to Armory: done" and _line_with(menu, "Go to Armory: done") > 0 and not menu.range_warn,
			"vr range menu: other op ids ignored; done for this one")
	# The freeze toggle reflects ai_frozen and flips; range_changed reads again.
	_click(rig, menu.row_of("freeze"))
	_check.call(b.calls.back() == ["frozen", false] and menu.range_status == "Monsters moving: …"
			and _line_with(menu, "Monsters frozen:  on") > 0, "vr range menu: freeze row asks for the opposite; shows the sim's state")
	var reads := menu.range_reads
	b.info["ai_frozen"] = false
	b.range_changed.emit(b.info)
	_check.call(menu.range_reads == reads + 1 and _line_with(menu, "Monsters frozen:  off") > 0,
			"vr range menu: range_changed refreshes the page")
	# An error: bounded, cleaned, buzzes.
	var buzz: int = rig.buzzes[1]
	_click(rig, menu.row_of("heal"))
	b.range_done.emit(b.next_id, "<color_red>dead</color>\n" + "x".repeat(300))
	_check.call(menu.range_status.begins_with("Heal: dead") and menu.range_status.length() <= VrMenu.STATUS_MAX
			and not menu.range_status.contains("<") and not menu.range_status.contains("\n") and menu.range_warn
			and rig.buzzes[1] == buzz + 1 and rig.buzzes[0] == 0, "vr range menu: an error shows (cleaned, bounded) and buzzes the main hand")
	# A refusal (op id 0).
	b.accept = false
	_click(rig, menu.row_of("wait_hour"))
	_check.call(menu.range_status == "Wait 1 hour: not sent" and menu.range_warn and rig.buzzes[1] == buzz + 2
			and b.calls.back() == ["advance", 60] and _line_with(menu, "Wait 1 hour: not sent") > 0,
			"vr range menu: a refused op says so and buzzes")
	b.accept = true
	menu.row = menu.row_of("time_12")
	rig.press(rig.left, "trigger_click")   # the off trigger uses the row the stick picked
	_check.call(b.calls.back() == ["time", 720] and menu.range_status == "Time 12:00: …", "vr range menu: trigger sets the time")
	# Many zones: a pager row, the page with the character's zone first; left / right halves page (wrapping).
	var many: Array = []
	for i in 20:
		many.append({"name": "Z%d" % (i + 1), "built": i < 2})
	b.info = {"range": true, "ai_frozen": false, "zone": 13, "zones": many}
	_click(rig, 0)   # back, then open again
	var back_row := menu.row
	menu.row = menu.row_of(VrMenu.RANGE_ROW)
	rig.press(rig.left, "trigger_click")
	var pager := menu.row_of(VrMenu.PAGER_ROW)
	_check.call(back_row == n and menu.page == VrMenu.RANGE_PAGE and pager == FIXED.size() + 1 and menu.zone_page == 1
			and _line_with(menu, "Zones 9-16 of 20:  < >") > 0 and _line_with(menu, "Go to: Z14 (here)") > 0
			and _line_with(menu, "Go to: Z8 ") < 0 and menu.row_count() == 1 + FIXED.size() + 1 + VrMenu.ZONES_PER_PAGE,
			"vr range menu: back lands on Test range >; 20 zones: a pager on the page with the character's zone")
	_click(rig, pager, 0.1)
	var right_ok := _line_with(menu, "Zones 17-20 of 20") > 0 and _line_with(menu, "Go to: Z20 (not built yet)") > 0 \
			and menu.row_count() == 1 + FIXED.size() + 1 + 4
	_click(rig, pager, -0.1)
	_click(rig, pager, -0.1)
	var first_ok := _line_with(menu, "Zones 1-8 of 20") > 0 and _line_with(menu, "Go to: Z1") > 0
	_click(rig, pager, -0.1)
	_check.call(right_ok and first_ok and _line_with(menu, "Zones 17-20 of 20") > 0 and menu.page == VrMenu.RANGE_PAGE,
			"vr range menu: pointer right half pages on, left half back, wrapping")
	_click(rig, menu.row_of("go_17"))
	_check.call(b.calls.back() == ["teleport", 17] and menu.range_status == "Go to Z18: …", "vr range menu: a zone on a later page")
	menu.row = menu.row_of(VrMenu.PAGER_ROW)
	rig.step(0.1, {"move": Vector2(-1, 0)})
	rig.step(0.1, {})
	var stick_page := menu.zone_page == 1 and menu.page == VrMenu.RANGE_PAGE
	menu.row = menu.row_of("heal")
	rig.step(0.1, {"move": Vector2(-1, 0)})
	rig.step(0.1, {})
	_check.call(stick_page and menu.page == VrMenu.SETTINGS_PAGE and menu.row == n,
			"vr range menu: stick left pages on the pager, goes back elsewhere")
	# The range game stops while the page shows: back to the settings page.
	menu.open_page(VrMenu.RANGE_PAGE)
	b.ranged = false
	b.range_changed.emit({})
	_check.call(menu.page == VrMenu.SETTINGS_PAGE and menu.row_count() == n, "vr range menu: range game over: back to settings")
	b.ranged = true
	# Closed: range_changed reads nothing; a result still updates the status (shown on the next open).
	menu.open_page(VrMenu.RANGE_PAGE)
	_click(rig, menu.row_of("heal"))
	var heal_id: int = b.next_id
	rig.press(rig.left, "menu_button")
	reads = menu.range_reads
	b.range_changed.emit(b.info)
	b.range_done.emit(heal_id, "")
	var closed_reads := menu.range_reads - reads
	rig.press(rig.left, "menu_button")
	_check.call(closed_reads == 0 and menu.range_status == "Heal: done" and menu.page == VrMenu.RANGE_PAGE
			and _line_with(menu, "Heal: done") > 0, "vr range menu: no reads while closed; the result still arrives")
	rig.cheats_allowed = false
	_check.call(menu.page == VrMenu.SETTINGS_PAGE and menu.row_count() == n, "vr range menu: not allowed any more: page gone")
	rig.free()
	world.free()


## The head stands over square p (no snapshot terrain here: go_to_player falls back to the player's own square).
func _at(rig: VrRig, p: Vector3i) -> bool:
	var c := rig.world.coords.ms_center_to_world(p)
	var h := rig.camera.global_position
	return Vector2(h.x - c.x, h.z - c.z).length() < 0.01 and rig.z == p.z


func _snap_at(p: Vector3i) -> Snapshot:
	var s := Snapshot.new()
	s.player_pos = p
	return s


func _test_follow(root: Node) -> void:
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var b := Backend.new()
	b.info = _info()
	rig.cheats_backend = b
	rig.cheats_allowed = true
	var p0 := Vector3i(10, 10, 0)
	var p1 := Vector3i(60, 30, 0)
	var away := Vector3i(30, 40, 0)
	world.snapshot = _snap_at(p0)
	rig.press(rig.left, "menu_button")
	var menu := rig.menu
	menu.open_page(VrMenu.RANGE_PAGE)
	# The result comes first, the moved player after it.
	_click(rig, menu.row_of("go_2"))
	var id: int = b.next_id
	rig.go_to_square(away)
	b.range_done.emit(id, "")
	rig.follow_teleport(0.1)
	var waited := _at(rig, away)
	world.snapshot = _snap_at(p1)
	rig.follow_teleport(0.1)
	var followed := _at(rig, p1)
	rig.go_to_square(away)
	world.snapshot = _snap_at(p0)
	rig.follow_teleport(0.1)
	_check.call(waited and followed and _at(rig, away), "vr range follow: after a teleport is done the head goes to the player once they moved, once")
	# The moved player first, the result after it.
	world.snapshot = _snap_at(p0)
	_click(rig, menu.row_of("go_0"))
	id = b.next_id
	rig.go_to_square(away)
	world.snapshot = _snap_at(p1)
	b.range_done.emit(id, "")
	_check.call(_at(rig, p1), "vr range follow: a snapshot that came before the result: follows at once")
	# A failed teleport: no follow.
	world.snapshot = _snap_at(p0)
	_click(rig, menu.row_of("go_1"))
	id = b.next_id
	rig.go_to_square(away)
	b.range_done.emit(id, "the character is busy")
	world.snapshot = _snap_at(p1)
	rig.follow_teleport(0.1)
	_check.call(_at(rig, away), "vr range follow: a refused teleport doesn't move the head")
	# Other ops don't follow either.
	_click(rig, menu.row_of("heal"))
	b.range_done.emit(b.next_id, "")
	world.snapshot = _snap_at(p0)
	rig.follow_teleport(0.1)
	_check.call(_at(rig, away), "vr range follow: only teleports")
	# A teleport to where the player stood: no move seen, the head goes to them after FOLLOW_WAIT_S.
	_click(rig, menu.row_of("go_1"))
	b.range_done.emit(b.next_id, "")
	rig.follow_teleport(1.0)
	var early := _at(rig, away)
	rig.follow_teleport(VrRig.FOLLOW_WAIT_S)
	_check.call(early and _at(rig, p0), "vr range follow: no move seen: to the player after the wait")
	rig.free()
	world.free()
