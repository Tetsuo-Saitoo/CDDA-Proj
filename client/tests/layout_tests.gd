extends RefCounted
## Small windows (the user, 2026-11-20): the F1 menu (keys and Cheats pages), the HUD's text along the top and the
## other flat-screen panels stay inside the window at every size in SIZES; what doesn't fit scrolls. Each panel is
## laid out in a Control of the window's size under the test root, two frames for its containers to sort. The F1
## menu is opened large and then the window shrinks, as when the player drags it (lead-qa, 2026-11-20).

const UiTests := preload("res://tests/ui_tests.gd")
const TestDir := preload("res://tests/test_dir.gd")
const SIZES: Array[Vector2] = [Vector2(1280, 720), Vector2(1024, 576), Vector2(800, 450)]
## As long as main's _help() in first person in a live game.
const HELP := ("RMB look  MMB look at (again: close)  LMB take, hold on a door and drag to open, hold on an item to carry "
		+ "it (wheel: nearer / farther)  E take it  I inventory  W A S D or KP8 KP4 KP2 KP6 walk where you look  KP5 "
		+ "wait  < > stairs  prompts: mouse or keys, Esc cancels  PgUp/PgDn cutaway  R roofs  V next view  Esc back / "
		+ "menu  F1 keys, HUD")
const BIG := Vector2(1600, 900)   # the project's window size

var _check: Callable
var _root: Node


func run(root: Node, check: Callable) -> void:
	_root = root
	_check = check
	_test_key_help()
	for s in SIZES:
		await _test_key_menu(s)
		await _test_hud_text(s)
		await _test_requests(s)
		await _test_list_prompt(s)
		await _test_panels(s)


## The innermost visible Controls under `c` (itself too) reaching outside `area` (to a pixel), by path and rect. A
## ScrollContainer's content may (it scrolls); the container itself may not.
static func outside(c: Control, area: Rect2) -> PackedStringArray:
	var out := PackedStringArray()
	_outside(c, area.grow(1.0), out, c)
	return out


static func _outside(c: Control, area: Rect2, out: PackedStringArray, top: Control) -> bool:
	if not c.is_visible_in_tree():
		return false
	var inner := false   # a child sticks out: name it, not this one
	if not c is ScrollContainer:
		for k in c.get_children():
			if k is Control and _outside(k, area, out, top):
				inner = true
	var r := c.get_global_rect()
	if area.encloses(r):
		return inner
	if not inner:
		out.append("%s %s" % [top.get_path_to(c), r])
	return true


## `c` in a window-sized Control under the root, laid out.
func _frame(s: Vector2, c: Control) -> Control:
	var f := Control.new()
	f.size = s
	_root.add_child(f)
	f.add_child(c)
	await _root.get_tree().process_frame
	await _root.get_tree().process_frame
	return f


func _fits(f: Control, c: Control, what: String) -> void:
	var off := outside(c, f.get_global_rect())
	_check.call(off.is_empty(), "layout %s: %s fits %s" % [_size_text(f.size), what, off.slice(0, 4)])


static func _size_text(s: Vector2) -> String:
	return "%dx%d" % [s.x, s.y]


func _test_key_menu(s: Vector2) -> void:
	var menu := KeyMenu.new()
	menu.save_path = TestDir.path("layout_keys.json")
	menu.add_hud_settings(HudSettings.new(), TestDir.path("layout_hud.cfg"))
	var hints := Hints.new()
	hints.persist = false
	menu.add_hints(hints)
	menu.cheats_forced = true
	menu.add_cheat_page(CheatPanel.new())
	menu.show_clock()
	menu.show_quit_to_menu(true)
	var f := await _frame(BIG, menu)
	menu.open()
	await _root.get_tree().process_frame
	f.size = s   # the window shrinks with the menu open
	for i in 3:
		await _root.get_tree().process_frame
	_fits(f, menu, "the F1 menu")
	var keep := KeyMenu.LIST_MIN_H - 1.0
	var lists := menu._settings_scroll.size.y >= keep and menu._scroll.size.y >= keep \
			and menu._settings_scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED \
			and menu._scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
	_check.call(lists, "layout %s: the F1 settings and key list both show and scroll (%.0f, %.0f px)" % [
			_size_text(s), menu._settings_scroll.size.y, menu._scroll.size.y])
	menu.show_cheats(true)
	await _root.get_tree().process_frame
	await _root.get_tree().process_frame
	_check.call(menu.showing_cheats(), "layout %s: the Cheats page opens" % _size_text(s))
	_fits(f, menu, "the F1 Cheats page")
	f.free()
	hints.free()   # never in the tree (main puts it on the HUD layer)


func _test_hud_text(s: Vector2) -> void:
	var main_gd := preload("res://scripts/main.gd")
	var l: Label = main_gd.hud_label()
	var act := PackedStringArray()   # as main's _act_help: every CDDA action key
	for a: StringName in InputActions.CDDA:
		act.append("%s %s" % [InputActions.key_of(a), InputActions.info(a)[2]])
	var info := "first person  camera square (12, 40)  level 0  roofs on  60 fps"
	var texts: PackedStringArray = main_gd.hud_texts(true, "Ready.", info, HELP, "", "  ".join(act),
			"in hands: a 9mm pistol")
	var d := HudData.new()
	for part in ["head", "torso", "left arm", "right arm", "left leg", "right leg"]:
		d.body.append({"name": part, "frac": 0.8, "level": 0})
	var v := HudView.new()
	v.data = d
	v.warn.text = "You are hungry."
	var f := await _frame(s, v)
	f.add_child(l)
	await _root.get_tree().process_frame
	var pick: int = main_gd.fit_index(l, texts, v.text_limit() - l.position.y)
	l.text = texts[pick]
	for i in 2:
		await _root.get_tree().process_frame
	v.avoid(l.get_global_rect())
	await _root.get_tree().process_frame
	var text_end := l.get_global_rect().end.y
	_fits(f, l, "the HUD's text along the top")
	_fits(f, v, "the HUD (body, feed, warnings)")
	var column := v._body.get_global_rect().position.y
	_check.call(l.get_line_count() > 1 and column >= text_end and v.warn.get_global_rect().position.y >= text_end
			and (s.y < 700.0 or pick == 0),
			"layout %s: the HUD's text (%d lines, version %d) ends at %.0f, over the body bars (%.0f) and the warning (%.0f)" % [
			_size_text(s), l.get_line_count(), pick, text_end, column, v.warn.get_global_rect().position.y])
	f.free()


## F1 > HUD > Key help: on by default; the box turns it off and saves it; junk in the file leaves it on.
func _test_key_help() -> void:
	var path := TestDir.path("layout_key_help.cfg")
	var hs := HudSettings.new()
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	var seen := [0]
	menu.hud_changed.connect(func() -> void: seen[0] += 1)
	var was_on := hs.key_help and menu.key_help_check.button_pressed
	menu.key_help_check.button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[hud]\nkey_help=\"no\"\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(was_on and not hs.key_help and not back.key_help and seen[0] == 1 and junk.key_help,
			"layout: Key help is on by default; the F1 box turns it off and saves it; junk leaves it on")
	var main_gd := preload("res://scripts/main.gd")
	var off: PackedStringArray = main_gd.hud_texts(false, "s", "i", "", "", "", "h")
	var on: PackedStringArray = main_gd.hud_texts(true, "s", "i", "HELP", "", "ACT", "h")
	var short_only := true
	for x in off:
		short_only = short_only and x.contains(main_gd.KEY_HELP_SHORT) and not x.contains("HELP ")
	_check.call(short_only and off.size() == 2 and on.size() == 4 and on[0].contains("ACT") and not on[1].contains("ACT")
			and on[1].contains("HELP") and main_gd.KEY_HELP_SHORT.contains("F1"),
			"layout: with Key help off the HUD shows one short line that points to F1")
	menu.free()


func _test_list_prompt(s: Vector2) -> void:
	var entries := []
	for i in 41:
		entries.append({"id": i, "label": "item %d" % i, "enabled": true, "description": "A thing, number %d." % i})
	var ui := RequestUI.new()
	var f := await _frame(s, ui)
	_check.call(ui.show_request(UiTests.new()._req("menu", {"title": "Inventory", "entries": entries})),
			"layout %s: a 41-row list shows" % _size_text(s))
	for i in 3:
		await _root.get_tree().process_frame
	_fits(f, ui, "a 41-row list prompt")
	var w := ui.widget
	var inside := f.get_global_rect().grow(1.0).encloses(w.get_global_rect())
	_check.call(inside and ui._fit_box.size.y >= w.get_combined_minimum_size().y - 1.0,
			"layout %s: a long list scrolls on its own, its description and buttons in the window (%s, box %.0f)" % [
			_size_text(s), w.get_global_rect(), ui._fit_box.size.y])
	f.free()


func _test_requests(s: Vector2) -> void:
	for req: Dictionary in [
			UiTests.new()._req("chargen", {"text": JSON.stringify(UiTests.CATALOG)}),
			UiTests.new()._req("world_setup", {"text": JSON.stringify(UiTests.WORLD_CATALOG), "title": "New world"})]:
		var ui := RequestUI.new()
		var f := await _frame(s, ui)
		_check.call(ui.show_request(req), "layout %s: %s shows" % [_size_text(s), req.kind])
		await _root.get_tree().process_frame
		await _root.get_tree().process_frame
		_fits(f, ui, "the %s screen" % req.kind)
		f.free()


func _test_panels(s: Vector2) -> void:
	var mm := MainMenu.new()
	mm.setup(PackedStringArray(["World"]), func(_w: String) -> PackedStringArray: return PackedStringArray())
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(mm)
	var f := await _frame(s, center)
	_fits(f, center, "the main menu")
	f.free()
	var cv := CharacterView.new()
	f = await _frame(s, cv)
	cv.open()
	await _root.get_tree().process_frame
	_fits(f, cv, "the character screen")
	cv.close()   # gives the mouse mode back
	f.free()
