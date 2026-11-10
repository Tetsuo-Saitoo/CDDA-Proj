extends RefCounted
## K7: testing cheats on the client side. LiveSession's wrappers (only known names reach the sim, nothing while
## no game runs, cheats_changed only on a real change), HudData's cheat list and HudView's marker, the debug
## switch in hud.cfg (hostile file values), the F1 menu's Cheats page and CheatPanel (state always from the
## sim), and main.gd's --cheats= parsing. A stand-in sim (FakeSim) answers like CddaSim. Run by run_tests.gd.

const TestDir := preload("res://tests/test_dir.gd")
const Main := preload("res://scripts/main.gd")

var _check: Callable


## Answers like CddaSim's cheat calls (contracts/bridge_api.md); set_cheat only records (the sim applies later).
class FakeSim extends RefCounted:
	var cheats := {}
	var seq := 1
	var calls: Array = []
	var kits := 0
	var auto := true

	func set_cheat(n: String, on: bool) -> bool:
		calls.append([n, on])
		return true

	func get_cheats() -> Dictionary:
		return {"seq": seq, "cheats": cheats.duplicate(), "kits_given": kits}

	func give_test_kit() -> bool:
		kits += 1
		return true

	func set_auto_pause(on: bool) -> void:
		auto = on

	func get_clock() -> Dictionary:
		return {"auto_pause": auto, "paused": false}


func run(check: Callable) -> void:
	_check = check
	print("cheats")
	_test_clean()
	_test_session()
	_test_hud()
	_test_model()
	_test_settings()
	_test_menu_and_panel()
	_test_args()
	_test_range_entry()


func _session(sim: FakeSim) -> LiveSession:
	var ls := LiveSession.new()
	ls._sim = sim
	ls.state = "running"
	return ls


func _all_off() -> Dictionary:
	var d := {}
	for n in LiveSession.CHEATS:
		d[n] = false
	return d


## The sim's reply is checked: unknown names dropped, non-bools read as off, junk gives {}.
func _test_clean() -> void:
	var c := LiveSession.clean_cheats({"cheats": {"invincible": true, "no_needs": "yes", "god_mode": true,
			"night_vision": 1}})
	var want := _all_off()
	want["invincible"] = true
	_check.call(c == want, "cheats: clean_cheats keeps known names, real bools only (%s)" % [c])
	_check.call(LiveSession.clean_cheats("x").is_empty() and LiveSession.clean_cheats({"cheats": [1]}).is_empty()
			and LiveSession.clean_cheats(null).is_empty(), "cheats: clean_cheats of junk is empty")


func _test_session() -> void:
	var sim := FakeSim.new()
	sim.cheats = _all_off()
	var ls := _session(sim)
	_check.call(not ls.set_cheat("god_mode", true) and not ls.set_cheat("", true) and sim.calls.is_empty(),
			"cheats: an unknown name never reaches the sim")
	_check.call(ls.set_cheat("night_vision", true) and sim.calls == [["night_vision", true]],
			"cheats: a known name goes to the sim")
	ls.state = "booting"
	_check.call(not ls.set_cheat("invincible", true) and ls.cheats().is_empty() and not ls.give_test_kit()
			and not ls.set_auto_pause(false) and sim.calls.size() == 1 and sim.kits == 0 and sim.auto,
			"cheats: nothing goes to the sim while no game runs")
	ls.state = "running"
	_check.call(ls.give_test_kit() and ls.give_test_kit() and sim.kits == 2 and ls.kits_given() == 2,
			"cheats: give_test_kit gives one per call")
	_check.call(ls.set_auto_pause(false) and not sim.auto and not ls.auto_pause(), "cheats: auto-pause setting")
	# cheats_changed: only when a value changes, not on every seq bump (once per turn)
	var got: Array = []
	ls.cheats_changed.connect(func(d: Dictionary) -> void: got.append(d))
	ls._poll_cheats()
	ls._poll_cheats()
	sim.seq += 1
	ls._poll_cheats()
	var first := got.size()
	sim.cheats["invincible"] = true
	sim.seq += 1
	ls._poll_cheats()
	ls.state = "ended"
	ls._poll_cheats()
	ls._poll_cheats()
	_check.call(first == 1 and got.size() == 3 and got[1]["invincible"] == true and got[2].is_empty(),
			"cheats: cheats_changed on a change only, {} when the game ends (%d, %s)" % [first, got])
	ls.free()


## CheatModel: the rows both pages draw (flat F1 and VR), and apply() for each kind of row.
func _test_model() -> void:
	var off := CheatModel.rows({}, true)
	var keys := []
	var dead := true
	for r: Dictionary in off:
		keys.append(r["key"])
		dead = dead and not r["enabled"] and not r["on"]
	var want := Array(LiveSession.CHEATS) + [CheatModel.AUTO_PAUSE, CheatModel.TEST_KIT]
	_check.call(keys == want and dead and off[-1]["kind"] == CheatModel.ACTION and off[0]["kind"] == CheatModel.TOGGLE,
			"cheat model: cheats, auto-pause, test kit in order; all greyed out without a game (%s)" % [keys])
	var c := _all_off()
	c["invincible"] = true
	c["no_needs"] = "yes"
	var on := CheatModel.rows(c, true)
	_check.call(on[0]["on"] and on[0]["enabled"] and not on[1]["on"] and on[-2]["on"] and not on[-1]["on"],
			"cheat model: rows show the sim's state, only real bools on")
	var sim := FakeSim.new()
	sim.cheats = _all_off()
	var ls := _session(sim)
	_check.call(not CheatModel.apply(ls, "god_mode") and not CheatModel.apply(null, "invincible") and sim.calls.is_empty(),
			"cheat model: unknown key or no backend does nothing")
	_check.call(CheatModel.apply(ls, "night_vision", true) and CheatModel.apply(ls, CheatModel.AUTO_PAUSE, false)
			and CheatModel.apply(ls, CheatModel.TEST_KIT) and sim.calls == [["night_vision", true]] and not sim.auto
			and sim.kits == 1, "cheat model: apply sets a cheat, auto-pause, gives a kit")
	_check.call(CheatModel.read(ls)[-2]["on"] == false and CheatModel.read(null)[0]["enabled"] == false,
			"cheat model: read() asks the backend")
	ls.free()


func _test_hud() -> void:
	var h := HudData.new()
	var v := HudView.new()
	v.data = h
	var parts: Array = []
	h.changed.connect(func(p: PackedStringArray) -> void: parts.append(p))
	h.set_cheats({"night_vision": true, "invincible": true, "no_needs": "true", "god_mode": true})
	h.set_cheats({"invincible": true, "night_vision": true})
	_check.call(h.cheats == PackedStringArray(["invincible", "night_vision"]) and parts.size() == 1
			and parts[0] == PackedStringArray(["cheats"]), "cheats: HudData keeps known true names in order, emits on change (%s)" % [h.cheats])
	_check.call(v.cheat_mark.text == "CHEATS: invincible, night vision", "cheats: HUD marker names them (%s)" % v.cheat_mark.text)
	h.set_cheats({})
	_check.call(h.cheats.is_empty() and v.cheat_mark.text == "", "cheats: no cheats, no marker")
	v.free()


## [debug] cheats in hud.cfg: off by default; only a real bool turns it on.
func _test_settings() -> void:
	var path := TestDir.path("hud_cheats.cfg")
	var s := HudSettings.new()
	_check.call(not s.debug_cheats, "cheats: debug setting off by default")
	s.debug_cheats = true
	_check.call(s.save_file(path) == OK, "cheats: settings saved")
	var r := HudSettings.new()
	_check.call(r.load_file(path) == "" and r.debug_cheats, "cheats: debug setting read back")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[compass]\nopacity=0.5\n[debug]\ncheats=\"true\"\n")
	f.close()
	var b := HudSettings.new()
	var why := b.load_file(path)
	_check.call(not b.debug_cheats and why != "" and is_equal_approx(b.compass_opacity, 0.5),
			"cheats: a string in the file doesn't turn cheats on (%s)" % why)


func _test_menu_and_panel() -> void:
	var path := TestDir.path("hud_menu_cheats.cfg")
	var s := HudSettings.new()
	var m := KeyMenu.new()
	m.add_hud_settings(s, path)
	var p := CheatPanel.new()
	m.add_cheat_page(p)
	_check.call(not m.cheats_button.visible and not m.cheats_allowed(), "cheats: no Cheats button while the debug setting is off")
	m.show_cheats(true)
	_check.call(not p.visible, "cheats: the page doesn't open while not allowed")
	m.debug_check.button_pressed = true   # the F1 switch: saved at once
	var r := HudSettings.new()
	r.load_file(path)
	_check.call(s.debug_cheats and r.debug_cheats and m.cheats_button.visible, "cheats: debug switch shows the button and is saved")
	m.cheats_button.pressed.emit()
	_check.call(p.visible and not m._scroll.visible and m.cheats_button.text == "Keys", "cheats: the button swaps in the Cheats page")
	# no game: everything greyed out, says why
	_check.call((p.toggles["invincible"] as CheckButton).disabled and p.kit_button.disabled
			and p.status.text.contains("running live game"), "cheats: without a game the page is greyed out")
	var sim := FakeSim.new()
	sim.cheats = _all_off()
	sim.cheats["no_needs"] = true
	var ls := _session(sim)
	p.backend = ls
	p.refresh()
	var t: CheckButton = p.toggles["invincible"]
	_check.call(not t.disabled and not t.button_pressed and (p.toggles["no_needs"] as CheckButton).button_pressed
			and p.auto_pause.button_pressed, "cheats: toggles show the sim's state")
	t.button_pressed = true
	_check.call(sim.calls == [["invincible", true]], "cheats: a toggle asks the sim (%s)" % [sim.calls])
	p.refresh()   # not applied yet: the page shows the sim, not what was asked
	_check.call(not t.button_pressed, "cheats: the page never keeps its own copy")
	sim.cheats["invincible"] = true
	p.on_cheats_changed(sim.cheats)
	_check.call(t.button_pressed, "cheats: applied change shows")
	p.kit_button.pressed.emit()
	p.auto_pause.button_pressed = false
	_check.call(sim.kits == 1 and not sim.auto, "cheats: kit button and auto-pause reach the sim")
	ls.state = "ended"
	t.button_pressed = false
	_check.call(sim.calls.size() == 1 and t.disabled, "cheats: a toggle after the game ended goes nowhere")
	m.debug_check.button_pressed = false
	_check.call(not p.visible and m._scroll.visible and not m.cheats_button.visible, "cheats: debug off takes the page away")
	m.cheats_forced = true
	_check.call(m.cheats_button.visible, "cheats: --test / --cheats show the button with the setting off")
	ls.free()
	m.free()


func _test_args() -> void:
	var n := Main.cheat_names(" invincible, ,night_vision,invincible,%s" % "x".repeat(100))
	_check.call(n == PackedStringArray(["invincible", "night_vision", "x".repeat(32)]), "cheats: --cheats= names trimmed, deduped, capped (%s)" % [n])
	var many := PackedStringArray()
	for i in 40:
		many.append("c%d" % i)
	_check.call(Main.cheat_names(",".join(many)).size() == 16 and Main.cheat_names("").is_empty(), "cheats: at most 16 names")


## The main menu's "Test range" entry shows only when the bridge has start_test_range, and only asks.
func _test_range_entry() -> void:
	var m := MainMenu.new()
	m.setup(PackedStringArray(), func(_w: String) -> PackedStringArray: return PackedStringArray())
	var asked := [0]
	m.test_range_requested.connect(func() -> void: asked[0] += 1)
	_check.call(_find_button(m, "Test range") == null, "test range: no entry by default")
	m.test_range = true
	m.show_page("main")
	var b := _find_button(m, "Test range")
	if b != null:
		b.pressed.emit()
	_check.call(b != null and asked[0] == 1, "test range: the entry asks main.gd to start it")
	var ls := LiveSession.new()
	if not LiveSession.test_range_available():
		_check.call(not ls.start_test_range("x", "y") and ls.error != "" and ls.sim() == null,
				"test range: a bridge without it starts nothing (%s)" % ls.error)
	ls.free()
	m.free()


func _find_button(n: Node, text: String) -> Button:
	for c in n.find_children("*", "Button", true, false):
		if (c as Button).text == text and not c.is_queued_for_deletion():
			return c
	return null
