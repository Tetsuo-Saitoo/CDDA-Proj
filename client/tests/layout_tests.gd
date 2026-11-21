extends RefCounted
## Small windows (the user, 2026-11-20): the F1 menu (keys and Cheats pages), the HUD's text along the top and the
## other flat-screen panels stay inside the window at every size in SIZES; what doesn't fit scrolls. Each panel is
## laid out in a Control of the window's size under the test root, two frames for its containers to sort.

const UiTests := preload("res://tests/ui_tests.gd")
const TestDir := preload("res://tests/test_dir.gd")
const SIZES: Array[Vector2] = [Vector2(1280, 720), Vector2(1024, 576), Vector2(800, 450)]
## As long as main's _help() in first person in a live game.
const HELP := ("RMB look  MMB look at (again: close)  LMB take, hold on a door and drag to open, hold on an item to carry "
		+ "it (wheel: nearer / farther)  E take it  I inventory  W A S D or KP8 KP4 KP2 KP6 walk where you look  KP5 "
		+ "wait  < > stairs  prompts: mouse or keys, Esc cancels  PgUp/PgDn cutaway  R roofs  V next view  Esc back / "
		+ "menu  F1 keys, HUD")
const MIN_LIST_H := 60.0   # a scrolling list keeps at least this much (three rows) on the smallest window

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
	var f := await _frame(s, menu)
	menu.open()
	await _root.get_tree().process_frame
	await _root.get_tree().process_frame
	_fits(f, menu, "the F1 menu")
	var lists := menu._settings_scroll.size.y >= MIN_LIST_H and menu._scroll.size.y >= MIN_LIST_H \
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
	var l := preload("res://scripts/main.gd").hud_label()
	var act := PackedStringArray()   # as main's _act_help: every CDDA action key
	for a: StringName in InputActions.CDDA:
		act.append("%s %s" % [InputActions.key_of(a), InputActions.info(a)[2]])
	l.text = "\n".join(["Ready.", "first person  camera square (12, 40)  level 0  roofs on  60 fps", HELP,
			"  ".join(act), "in hands: a 9mm pistol"])
	var f := await _frame(s, l)
	_fits(f, l, "the HUD's text along the top")
	_check.call(l.get_line_count() > 1 and l.position.y >= 50.0,
			"layout %s: the HUD's text wraps (%d lines), under the compass" % [_size_text(s), l.get_line_count()])
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
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	_check.call(main_src.contains("_help() if hud_settings.key_help else KEY_HELP_SHORT")
			and preload("res://scripts/main.gd").KEY_HELP_SHORT.contains("F1"),
			"layout: with Key help off the HUD shows one short line that points to F1")
	menu.free()


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
