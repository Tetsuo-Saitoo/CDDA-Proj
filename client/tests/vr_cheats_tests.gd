extends RefCounted
## K7: the VR menu's Cheats page (VrCheats, VrMenu, VrRig) and the wrist HUD's cheat line (VrHud), run by
## run_tests.gd. A stand-in backend with LiveSession's cheat methods (not on this branch yet) records the calls.
## No XR runtime: the test places the head and the pointing hand, and presses the buttons.

var _check: Callable


## LiveSession's cheat surface: `state` is what the sim has ({} = no running game); set_cheat only records (the
## sim applies at its next turn; the test changes `state` and emits cheats_changed for that).
class Backend extends RefCounted:
	signal cheats_changed(cheats: Dictionary)
	var state := {}
	var paused := false
	var accept := true
	var calls: Array = []

	func cheats() -> Dictionary:
		return state.duplicate()

	func set_cheat(n: String, on: bool) -> bool:
		calls.append(["set_cheat", n, on])
		return accept and not state.is_empty()

	func give_test_kit() -> bool:
		calls.append(["kit"])
		return accept and not state.is_empty()

	func set_auto_pause(on: bool) -> bool:
		calls.append(["set_auto_pause", on])
		if not accept or state.is_empty():
			return false
		paused = on
		return true

	func auto_pause() -> bool:
		return paused


## No auto-pause.
class NoPause extends RefCounted:
	var state := {"invincible": false}

	func cheats() -> Dictionary:
		return state

	func set_cheat(_n: String, _on: bool) -> bool:
		return true

	func give_test_kit() -> bool:
		return true


## Can list but not set: no page.
class Partial extends RefCounted:
	func cheats() -> Dictionary:
		return {"invincible": true}


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr cheats")
	_test_rows()
	_test_use()
	_test_menu(root)
	_test_hud()


func _keys(rows: Array[Dictionary]) -> Array:
	return rows.map(func(r: Dictionary) -> String: return r["key"])


func _off() -> Dictionary:
	var d := {}
	for n in VrCheats.ORDER:
		d[n] = false
	return d


func _test_rows() -> void:
	var known: Array = Array(VrCheats.ORDER) + [VrCheats.AUTO_PAUSE, VrCheats.TEST_KIT]
	var none := VrCheats.rows({}, true)
	_check.call(_keys(none) == known and none.all(func(r: Dictionary) -> bool: return r["enabled"] == false and r["on"] == false)
			and none[0]["label"] == "No damage (can't die)" and none[-1]["kind"] == VrCheats.ACTION
			and none[-2]["kind"] == VrCheats.TOGGLE and none[-2]["label"] == "Auto-pause on hostiles (real time)"
			and none[-1]["label"] == "Give test kit",
			"vr cheats: no game, the flat page's rows in its order (auto-pause, then the kit), all greyed")
	var long := "long_" + "x".repeat(55)
	var d := {"night_vision": "yes", "zz_new": true, "invincible": true, "aaa_cheat": false, long: false,
			5: true, "Bad Name": true, "x".repeat(100): true, "drop_table;": true}
	var r := VrCheats.rows(d, true)
	_check.call(_keys(r) == Array(VrCheats.ORDER) + ["aaa_cheat", long, "zz_new", VrCheats.AUTO_PAUSE, VrCheats.TEST_KIT]
			and r[0]["on"] == true and r[6]["on"] == false and r[7]["label"] == "aaa cheat" and r[9]["on"] == true
			and (r[8]["label"] as String).length() == VrCheats.LABEL_MAX and r[10]["on"] == true
			and r.all(func(x: Dictionary) -> bool: return x["enabled"] == true),
			"vr cheats: known names in order, then the sim's others by name (bounded labels); bad names and values skipped")
	var many := {}
	for i in 12:
		many["extra_%02d" % i] = true
	_check.call(VrCheats.rows(many, false).size() == VrCheats.ORDER.size() + VrCheats.MAX_EXTRA + 2,
			"vr cheats: at most MAX_EXTRA unknown cheats")
	var b := Backend.new()
	_check.call(VrCheats.available(b) and not VrCheats.available(null) and not VrCheats.available(Partial.new())
			and not VrCheats.available(RefCounted.new()) and not VrCheats.available(5), "vr cheats: backend needs cheats, set_cheat, give_test_kit")
	_check.call(_keys(VrCheats.read(null)) == known and VrCheats.read(Partial.new()).all(func(x: Dictionary) -> bool: return not x["enabled"]),
			"vr cheats: no usable backend, greyed rows")
	b.state = _off()
	b.state["stamina"] = true
	b.paused = true
	var rd := VrCheats.read(b)
	_check.call(rd[4]["on"] == true and rd[0]["on"] == false and rd[-2]["on"] == true and rd[-2]["enabled"] == true,
			"vr cheats: read shows what the backend says now (cheats, auto-pause)")
	var np := VrCheats.read(NoPause.new())
	_check.call(np[0]["enabled"] == true and np[-2]["enabled"] == false and np[-1]["enabled"] == true,
			"vr cheats: a backend without auto-pause greys that row")
	_check.call(VrCheats.short_name("night_vision") == "Night vision" and VrCheats.marker(PackedStringArray(["invincible", "night_vision"]))
			== "CHEATS: invincible, night vision" and VrCheats.marker(PackedStringArray()) == "" and VrCheats.marker(null) == ""
			and VrCheats.marker([5, "Bad Name", "stamina"]) == "CHEATS: stamina" and VrCheats.marker("invincible") == "",
			"vr cheats: names and the HUD marker, bad entries skipped")


func _test_use() -> void:
	var b := Backend.new()
	var sent := VrCheats.apply(b, "invincible", true)   # no game: the stand-in says no
	_check.call(not sent and b.calls.back() == ["set_cheat", "invincible", true], "vr cheats: apply sends set_cheat, false when refused")
	b.calls.clear()
	_check.call(not VrCheats.apply(b, "Bad Name") and not VrCheats.apply(null, "invincible") and b.calls.is_empty(),
			"vr cheats: apply refuses a bad name and no backend without calling")
	var u := VrCheats.use(b, "invincible")
	_check.call(u["ok"] == false and u["text"] == "Not changed: no running game" and b.calls.is_empty(),
			"vr cheats: no running game, nothing sent")
	b.state = _off()
	u = VrCheats.use(b, "invincible")
	_check.call(u["ok"] == true and b.calls.back() == ["set_cheat", "invincible", true] and u["text"] == "Invincible: on next turn",
			"vr cheats: an off cheat is turned on")
	b.state["invincible"] = true
	u = VrCheats.use(b, "invincible")
	_check.call(u["ok"] == true and b.calls.back() == ["set_cheat", "invincible", false] and u["text"] == "Invincible: off next turn",
			"vr cheats: ... and an on one off, by what the backend says now")
	u = VrCheats.use(b, VrCheats.TEST_KIT)
	_check.call(u["ok"] == true and b.calls.back() == ["kit"] and u["text"] == "Test kit: next turn", "vr cheats: the test kit")
	u = VrCheats.use(b, VrCheats.AUTO_PAUSE)
	_check.call(u["ok"] == true and b.calls.back() == ["set_auto_pause", true] and b.paused and u["text"].ends_with(": on"),
			"vr cheats: auto-pause flips")
	b.accept = false
	var n := b.calls.size()
	u = VrCheats.use(b, "no_needs")
	_check.call(u["ok"] == false and u["text"] == "Not changed: the game said no" and b.calls.size() == n + 1,
			"vr cheats: a refused cheat says so")
	u = VrCheats.use(b, VrCheats.TEST_KIT)
	_check.call(u["ok"] == false and u["text"] == "No test kit: the game said no", "vr cheats: a refused kit says so")
	u = VrCheats.use(b, "not_a_row")
	_check.call(u["ok"] == false and (u["text"] as String).begins_with("Not changed"), "vr cheats: an unknown row")


## The menu row whose text contains `s`, -1 for none.
func _line_with(menu: VrMenu, s: String) -> int:
	var t := menu.texts()
	for i in t.size():
		if t[i].contains(s):
			return i
	return -1


func _row_key(menu: VrMenu, key: String) -> int:
	for i in menu.row_count():
		if menu.key_of(i) == key:
			return i
	return -1


func _test_menu(root: Node) -> void:
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var b := Backend.new()
	b.state = _off()
	rig.cheats_backend = b
	rig.press(rig.left, "menu_button")
	var menu := rig.menu
	var n := VrSettings.ROWS.size()
	_check.call(rig.menu_open() and not menu.cheats_shown() and menu.row_count() == n and _line_with(menu, "Cheats >") < 0,
			"vr cheats menu: no Cheats row unless allowed")
	rig.cheats_allowed = true
	_check.call(menu.cheats_shown() and menu.row_count() == n + 1 and _line_with(menu, "Cheats >") == n + 1,
			"vr cheats menu: allowed: a Cheats row at the bottom of the settings page")
	rig.cheats_backend = Partial.new()
	var partial := menu.row_count()
	rig.cheats_backend = null
	_check.call(partial == n and menu.row_count() == n and not menu.cheats_shown(),
			"vr cheats menu: no Cheats row without a backend that can do cheats")
	rig.cheats_backend = b
	# Stick: up from the first row wraps to "Cheats >", right opens the page.
	rig.step(0.1, {"move": Vector2(0, 1)})
	rig.step(0.1, {})
	var picked := menu.row
	rig.step(0.1, {"move": Vector2(1, 0)})
	rig.step(0.1, {})
	var t := menu.texts()
	_check.call(picked == n and menu.page == VrMenu.CHEATS_PAGE and menu.row == 0 and t[0] == "Cheats"
			and t[1].contains("< Back") and t[2].contains("No damage (can't die):  off") and _line_with(menu, VrMenu.CHEAT_WARNING) > 0
			and _line_with(menu, "Give test kit:  press") > 0 and _line_with(menu, "Auto-pause on hostiles (real time):  off") > 0,
			"vr cheats menu: stick picks Cheats > and opens the page (back, toggles, auto-pause, kit, warning)")
	rig.step(0.1, {"move": Vector2(-1, 0)})
	rig.step(0.1, {})
	_check.call(menu.page == VrMenu.SETTINGS_PAGE and menu.row == n, "vr cheats menu: stick left goes back, on Cheats >")
	# Pointer: the main hand's ray and trigger.
	var lh := VrMenu.LINE_H
	var click := func(r: int) -> void:
		var at := menu.global_transform * Vector3(0.1, -(r + 1) * lh, 0)
		rig.right.global_position = at + menu.global_basis.z * 0.6 + Vector3(0.05, -0.3, 0)
		rig.right.look_at(at, Vector3.UP)
		rig.update_pointer(true)
		rig.press(rig.right, "trigger_click")
	click.call(n)
	_check.call(menu.page == VrMenu.CHEATS_PAGE, "vr cheats menu: pointer click on Cheats > opens the page")
	var inv := _row_key(menu, "invincible")
	click.call(inv)
	_check.call(b.calls.back() == ["set_cheat", "invincible", true] and menu.status == "Invincible: on next turn"
			and _line_with(menu, "Invincible: on next turn") > 0 and _line_with(menu, "No damage (can't die):  off") > 0,
			"vr cheats menu: pointer click turns a cheat on; the row shows the sim's state until it applies")
	var before := menu.refreshes
	b.state["invincible"] = true
	b.cheats_changed.emit(b.state.duplicate())
	_check.call(menu.refreshes == before + 1 and _line_with(menu, "No damage (can't die):  on") > 0,
			"vr cheats menu: cheats_changed refreshes the page")
	click.call(inv)
	_check.call(b.calls.back() == ["set_cheat", "invincible", false], "vr cheats menu: the toggle goes by the backend's state")
	var buzz: int = rig.buzzes[1]
	b.accept = false
	click.call(_row_key(menu, "no_needs"))
	_check.call(menu.status == "Not changed: the game said no" and menu.status_warn and rig.buzzes[1] == buzz + 1
			and rig.buzzes[0] == 0 and _line_with(menu, "the game said no") > 0,
			"vr cheats menu: a refused cheat says so on the page and buzzes the main hand")
	b.accept = true
	menu.row = _row_key(menu, VrCheats.TEST_KIT)
	rig.press(rig.left, "trigger_click")   # the off trigger uses the row the stick picked
	_check.call(b.calls.back() == ["kit"] and menu.status == "Test kit: next turn", "vr cheats menu: trigger gives the test kit")
	click.call(_row_key(menu, VrCheats.AUTO_PAUSE))
	_check.call(b.calls.back() == ["set_auto_pause", true] and _line_with(menu, "Auto-pause on hostiles (real time):  on") > 0,
			"vr cheats menu: auto-pause row")
	b.state = {}
	b.cheats_changed.emit({})
	buzz = rig.buzzes[1]
	click.call(inv)
	_check.call(_line_with(menu, "no running game") > 0 and rig.buzzes[1] == buzz + 1 and b.calls.back() == ["set_auto_pause", true],
			"vr cheats menu: no running game: rows greyed, a press is refused without a call")
	b.state = _off()
	rig.press(rig.left, "menu_button")   # closed: cheats_changed doesn't read the backend
	before = menu.refreshes
	b.cheats_changed.emit(b.state.duplicate())
	var hidden_reads := menu.refreshes - before
	rig.press(rig.left, "menu_button")   # opened: read again
	_check.call(hidden_reads == 0 and menu.refreshes == before + 1 and menu.page == VrMenu.CHEATS_PAGE,
			"vr cheats menu: no reads while closed, read again on open")
	click.call(0)
	_check.call(menu.page == VrMenu.SETTINGS_PAGE and menu.row == n, "vr cheats menu: pointer click on < Back")
	click.call(n)
	rig.cheats_allowed = false
	_check.call(menu.page == VrMenu.SETTINGS_PAGE and menu.row_count() == n and _line_with(menu, "Cheats >") < 0,
			"vr cheats menu: not allowed any more: back to the settings page, no Cheats row")
	rig.free()
	world.free()


func _test_hud() -> void:
	var h: HudData = HudData.new()
	var plain := not ("cheats" in h)
	var hud := VrHud.new()
	hud.data = h
	_check.call(not hud.cheat_label.visible, "vr hud cheats: no cheats property or none on: no line")
	if plain:   # this branch's HudData has no `cheats` yet (lead-ui adds it): a stand-in with one
		var s := GDScript.new()
		s.source_code = "extends HudData\nvar cheats := PackedStringArray()\n"
		s.reload()
		h = s.new()
		hud.data = h
	hud._dirty = false
	h.set("cheats", PackedStringArray(["invincible", "night_vision"]))
	h.changed.emit(PackedStringArray(["cheats"]))
	_check.call(hud.cheat_label.visible and hud.cheat_label.text == "CHEATS: invincible, night vision" and hud._dirty,
			"vr hud cheats: an amber CHEATS line, redrawn on a cheats change")
	h.set("cheats", PackedStringArray())
	h.changed.emit(PackedStringArray(["cheats"]))
	_check.call(not hud.cheat_label.visible, "vr hud cheats: gone when no cheat is on")
	hud.free()
