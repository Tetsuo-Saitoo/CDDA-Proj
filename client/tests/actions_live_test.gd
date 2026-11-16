extends SceneTree
## Headless run of CDDA's action keys in the test range, through main's own input path: each key's first binding
## is pushed into the window as a key press, the menu or prompt CDDA answers with must show in RequestUI with the
## widget for its kind, and Esc must cancel it back to the main loop with the game still running. The lists get
## things to list first: the test kit and a few items at the feet. A key whose action finds nothing to work on may
## answer with a message instead (CDDA's "nothing to ..."): that is reported, not failed, except for the keys whose
## list or direction prompt is sure (KEYS). Last, F1 in the game: a free key goes in inventory's next key slot by
## the slot's button (saved in this run's folder, never the player's keys file), Esc closes the menu, and the new
## key opens the inventory. Then the screen HUD: body bars, needs, move line and message feed from the live game.
## Then the off hand: H holds a kit item (water when it pours, else a knife), holding E pours a liquid out, Shift+H
## puts it away. Then F3's classic view of the map around the player. Uses this run's own CDDA folder, never the
## player's saves.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda, or --cdda=<folder>). ~3 min. From the repo
## root:
##   godot --headless --path client --script res://tests/actions_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 90000
const ASK_TIMEOUT_MS := 15000    # a key's prompt or message showing up
const SETTLE_MS := 1500          # after a message: a prompt may still follow
const MAX_ESC := 4               # Esc presses to get back to the main loop (chained prompts)
const LIST_KINDS := ["menu", "item_select", "item_multi"]
## [action, what CDDA must answer with: "list", "direction", or "" for either a prompt or a message]
const KEYS := [
	[&"cdda_inventory", "list"], [&"cdda_eat", "list"], [&"cdda_wear", "list"], [&"cdda_wield", "list"],
	[&"cdda_drop", "list"], [&"cdda_throw", "list"], [&"cdda_read", ""], [&"cdda_apply", ""],
	[&"cdda_take_off", ""], [&"cdda_unload", ""], [&"cdda_pickup", ""], [&"cdda_butcher", ""],
	[&"cdda_smash", "direction"], [&"cdda_open", ""], [&"cdda_close", ""], [&"cdda_examine", ""],
	[&"cdda_grab", ""],
]
## Laid at the feet for the lists: the first id of each the game knows (something to wear, read and eat).
const AT_FEET := [["tshirt", "jeans"], ["novel_mystery", "mag_guns", "textbook_firearms", "news_regional"],
		["apple", "can_beans"]]

var _failed := 0
var _main: Main
var _live: LiveSession
var _cp: CheatPanel
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0    # the last prompt this script answered (setup only)
var _messages: PackedStringArray = []
var _seen: Array[String] = []   # one line per key, printed at the end


func _initialize() -> void:
	_run()


func _run() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_check(LiveSession.test_range_available(), "the bridge has the test range")
	if _failed > 0:
		_finish()
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-actions")
	root.add_child(_main)
	await process_frame
	_main.key_menu.save_path = TestDir.path("keys.json")   # a key set in F1 here never reaches the player's file
	_live = _main.live
	_cp = _main.cheat_panel
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	_live.events_arrived.connect(_on_events)
	var menu := _main.main_menu
	var button := _find_button(menu, "Test range") if menu != null else null
	_check(menu != null and button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	var t0 := Time.get_ticks_msec()
	var up := func() -> bool: return (_live.state == "running" and _main.world.snapshot != null
			and _cp.tables != null)
	_check(await _until(up, BOOT_TIMEOUT_MS, true), "the range runs (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if _live.state != "running":
		_finish()
		return
	var kits := _live.kits_given()
	_check(_live.give_test_kit(), "test kit asked for")
	_live.queue_action("pause")
	var kit_in := func() -> bool: return _live.kits_given() > kits
	_check(await _until(kit_in, OP_TIMEOUT_MS, true), "the test kit arrived")
	for ids: Array in AT_FEET:
		var id := ""
		for c: String in ids:
			if _cp.tables.index_of("itype", c) >= 0:
				id = c
				break
		if id.is_empty():
			print("  (none of %s in this game's data)" % [ids])
			continue
		_cp.item_id.text = id
		_cp.item_count.value = 1
		_check(await _op(_cp.spawn_item, "Spawn " + id) == "", "spawned a %s at the feet" % id)
	# the spawn pickers find types by name in this game's own tables
	var zs := SpawnSearch.find(_cp.tables, "mtype", "zombie").map(func(f: Dictionary) -> String: return f["id"])
	var gs := SpawnSearch.find(_cp.tables, "itype", "glock 19").map(func(f: Dictionary) -> String: return f["id"])
	_check(zs.size() > 1 and zs[0] == "mon_zombie" and not gs.is_empty() and gs[0] == "glock_19",
			"spawn search: \"zombie\" finds %d monster types, mon_zombie first; \"glock 19\" finds glock_19 first" % zs.size())
	print("    zombie: %s; glock 19: %s" % [zs.slice(0, 6), gs.slice(0, 4)])
	if _main.key_menu.visible:
		_main.key_menu.close()
	for k: Array in KEYS:
		await _try_key(k[0], k[1])
		if _live.state != "running":
			_check(false, "the game stopped after %s (%s %s)" % [k[0], _live.state, _live.error])
			break
	if _live.state == "running":
		await _rebind_live(&"cdda_inventory")
		_hud_live()
		await _hands_live()
		await _consume_live()
		_classic_live()
		await _character_live()
		await _compass_live()
	print("  what each key did:")
	for line in _seen:
		print("    " + line)
	await _stop()
	_finish()


## F1 in the game, then a free key put in `action`'s next key slot by its button in the menu (saved to this run's
## folder), Esc closes the menu, and the new key does the action in the game.
func _rebind_live(action: StringName) -> void:
	var km := _main.key_menu
	var key: InputEventKey = null
	for code: Key in [KEY_SEMICOLON, KEY_APOSTROPHE, KEY_F8, KEY_F9, KEY_K]:
		var k := InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = true
		if InputActions.users_of(InputActions.binding_from(k)).is_empty():
			key = k
			break
	if key == null:
		_check(false, "F1: a free key to bind")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	var old := InputActions.slots(action)
	var f1 := InputEventKey.new()
	f1.keycode = InputActions.MENU_KEY
	f1.physical_keycode = InputActions.MENU_KEY
	f1.pressed = true
	root.push_input(f1)
	_check(km.visible, "F1 opens the key menu in the live game")
	(km._buttons[action][mini(old.size(), KeyMenu.SLOTS - 1)] as Button).pressed.emit()
	root.push_input(key)
	var t := InputActions.event_text(InputActions.binding_from(key))
	var bound := false
	for e in InputActions.slots(action):
		bound = bound or InputActions.event_text(e) == t
	_check(bound and FileAccess.file_exists(km.save_path) and km._status.text.begins_with(InputActions.info(action)[2] + ": "),
			"F1: %s bound to %s, saved in this run's folder (%s)" % [action, t, km._status.text])
	root.push_input(_esc_key())
	_check(not km.visible, "Esc closes the key menu")
	await _try_key(action, "list", key)
	InputActions.set_slots(action, old)


## The screen HUD (main's HudView) in the live game: body bars, needs and the move line from CDDA's snapshot, and
## the message feed from its events (the keys above made CDDA say "nothing ... nearby").
func _hud_live() -> void:
	var v := _main.hud_view
	var rows := v.body_rows()
	var fracs := not rows.is_empty()
	for r: Array in rows:
		fracs = fracs and float(r[1]) >= 0.0 and float(r[1]) <= 1.0
	_check(rows.size() >= 6 and fracs, "HUD: %d body bars from the live game (%s ...)" % [rows.size(), rows.slice(0, 2)])
	_check(not v.need_lines().is_empty() and not v.move_line().is_empty(),
			"HUD: needs and the move line (%s; %s)" % [", ".join(v.need_lines()), v.move_line()])
	var said := false
	for m: Dictionary in _main.hud_data.messages:
		said = said or str(m["text"]).contains("nothing that can be examined")
	var feed := v.feed.text.split("\n")
	var last: String = _main.hud_data.messages.back()["text"] if not _main.hud_data.messages.is_empty() else ""
	_check(said and not last.is_empty() and feed[feed.size() - 1] == last,
			"HUD: CDDA's messages reach the feed, newest last (\"%s\")" % last)


## F3 in the live game: the classic view shows CDDA's symbols around the player, @ in the middle; F3 hides it.
func _classic_live() -> void:
	var v := _main.classic
	root.push_input(_key_of(&"classic_view"))
	var lines := v.text().split("\n")
	var mid := lines[ClassicView.RY].substr(ClassicView.RX, 1) if lines.size() > ClassicView.RY else ""
	var drawn := 0
	for l in lines:
		drawn += l.length() - l.count(" ")
	_check(v.visible and mid == "@" and drawn > 100, "F3: CDDA's classic view, @ in the middle, %d squares drawn" % drawn)
	print("    " + "\n    ".join(lines.slice(ClassicView.RY - 4, ClassicView.RY + 5)))
	root.push_input(_key_of(&"classic_view"))
	_check(not v.visible, "F3 again hides it")


## The compass in the live game: a zombie spawned two squares ahead (by name, through the Cheats page's picker; at
## noon, monsters frozen) shows as a hostile marker near the middle of the strip, close by.
func _compass_live() -> void:
	var c := _main.compass
	if not _live.range_info().get("ai_frozen", false):
		_check(await _op(func() -> void: _cp.set_frozen(true), "Freeze") == "", "monsters frozen")
	_cp.hour.value = 12
	_check(await _op(_cp.set_time, "Time 12:00") == "", "time set to noon")
	var hostiles := func() -> int: return c.blips.filter(func(b: Vector3) -> bool: return int(b.z) == Snapshot.Creature.HOSTILE).size()
	var before: int = hostiles.call()
	_cp.monster_id.text = "zombie"
	_check(await _op(_cp.spawn_monster, "Spawn mon_zombie") == "", "a zombie spawned ahead (picked: %s)"
			% (_cp.monster_pick.get_item_text(_cp.monster_pick.selected) if _cp.monster_pick.selected >= 0 else "none"))
	var more := func() -> bool: return hostiles.call() > before
	var seen := await _until(more, OP_TIMEOUT_MS, true)
	var b: Vector3 = c.blips[0] if not c.blips.is_empty() else Vector3(0, INF, -1)   # hostiles come first, nearest first
	var at := Compass.strip_pos(b.x, c.heading_deg)
	_check(seen and int(b.z) == Snapshot.Creature.HOSTILE and absf(at) < 0.3 and b.y < 4.0,
			"compass: the zombie ahead is a hostile marker near the strip's middle (%.2f of half the strip, %.1f m away, heading %.0f)"
			% [at, b.y, c.heading_deg])
	if not _main.first_person:
		print("  (compass turn not tried: not in first person)")
		return
	var fp := _main.fp
	var yaw0 := fp.yaw
	var h0 := c.heading_deg
	fp.set_look(yaw0 - PI / 2.0, fp.pitch)   # a quarter turn right: the zombie is now to the left
	await process_frame
	await process_frame
	var b2: Vector3 = c.blips[0] if not c.blips.is_empty() else Vector3(0, INF, -1)
	var at2 := Compass.strip_pos(b2.x, c.heading_deg)
	_check(absf(wrapf(c.heading_deg - h0, -180.0, 180.0) - 90.0) < 1.0 and absf(at2 - (at - 1.0)) < 0.05,
			"compass: a quarter turn right turns the heading 90 and moves the zombie to the strip's left end (%.2f)" % at2)
	fp.set_look(yaw0, fp.pitch)


## G4: P shows the character screen with the live game's body and needs; Esc closes it.
func _character_live() -> void:
	var v := _main.character
	root.push_input(_key_of(&"character"))
	var t := v.text()
	var body: Dictionary = _main.character_data.card("body")
	_check(v.visible and t.find("[Body]") >= 0 and t.find("[Needs]") >= 0 and (body.get("rows", []) as Array).size() >= 6,
			"P: the character screen, %d body parts" % (body.get("rows", []) as Array).size())
	var worn: Array = _main.character_data.card("worn").get("rows", [])
	var parts: Array = _main.character_data.card("worn_parts").get("rows", [])
	var covered := parts.filter(func(r: Dictionary) -> bool: return r["value"] != "bare").size()
	_check(worn.size() >= 1 and parts.size() >= 6 and covered >= 3 and t.find("[Worn]") >= 0 and t.find("[Worn by body part]") >= 0,
			"P: what the character wears (%d items) and the layers on %d body parts, %d covered" % [worn.size(), parts.size(), covered])
	print("    " + "\n    ".join(t.split("\n").slice(0, 12)))
	var at := t.find("[Worn]")
	print("    " + "\n    ".join(t.substr(at if at >= 0 else 0).split("\n").slice(0, 14)))
	# G4: the game's character sheet (bridge query_character), asked when the screen opens
	if _live._sim.has_method("query_character"):
		var cd := _main.character_data
		var came: bool = await _until(func() -> bool: return cd.has_sheet(), ASK_TIMEOUT_MS, false)
		var stats: Array = cd.card("stats").get("rows", [])
		var skills: Array = cd.card("skills").get("rows", [])
		_check(came and stats.size() == 5 and skills.size() >= 10 and cd.title != "Character" and not cd.subtitle.is_empty()
				and cd.note.is_empty() and v.text().find("[Skills]") >= 0,
				"P: the game's sheet: %s (%s), %d stats, %d skills, %d traits" % [cd.title, cd.subtitle, stats.size(),
				skills.size(), (cd.card("traits").get("rows", []) as Array).size()])
		var carry := cd.carry
		_check(carry["weight_g"] >= 0 and carry["weight_max_g"] > 0 and carry["volume_ml"] >= 0
				and carry["volume_max_ml"] > 0 and v.text().find("[Carrying]") >= 0,
				"P: what the character carries and can carry, from the sheet (%s)" % [carry])
		print("    " + "\n    ".join(v.text().substr(maxi(0, v.text().find("[Stats]"))).split("\n").slice(0, 8)))
	else:
		print("    (this DLL has no query_character: the sheet's cards not checked)")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	_check(not v.visible, "Esc closes it")
	if _main.character_data.carry["weight_max_g"] > 0:   # G2: the Tab view's top line shows the same numbers
		root.push_input(_key_of(&"inspect"))
		var box := _main.inspect.find_child("Carry", true, false) as Control
		_check(_main.inspect.visible and box != null and box.visible and box.get_child_count() == 2,
				"Tab: carried weight and volume bars in the top line")
		root.push_input(esc)
		_check(not _main.inspect.visible, "Esc closes the Tab view")


## The off hand in the live game: H asks which item to hold and one is picked as a player would (typed into the
## list's filter, Enter): water when the kit's pours (else a knife), poured out by holding E; Shift+H puts it away.
## The hands (HudData.held, from the bridge's held state) follow each step.
func _hands_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"hold_off"))
	var asked := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if not await _until(asked, ASK_TIMEOUT_MS, false):
		_check(false, "H: CDDA asks which item to hold (%s)" % [_live.request])
		return
	var w := _main.request_ui.widget as ListRequestWidget
	var pick := ""   # a liquid that pours (the kit's water may be frozen or sealed), else a knife
	for want: String in ["water", "knife"]:
		for it: Dictionary in w.items:
			var n := str(it.get("plain", ""))
			var ok: bool = it.get("enabled", false) and not n.contains("frozen") and not n.contains("sealed")
			if pick.is_empty() and ok and n.to_lower().contains(want):
				pick = n
	_check(not pick.is_empty(), "H: the hold list has something to hold (%d entries)" % w.items.size())
	if pick.is_empty():
		root.push_input(_esc_key())
		return
	w.set_filter(pick)   # typed into the list's filter, as a player would
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	root.push_input(enter)
	var in_off := func() -> bool: return _main.hud_data.held.get("off") is ItemRef
	_check(await _until(in_off, OP_TIMEOUT_MS, false), "H: \"%s\" held in the off hand" % pick)
	if not in_off.call():
		return
	if str(_main.hud_data.held.get("off_liquid", "")).is_empty():
		print("  (pour not tried: no liquid that pours in the kit; held %s)" % pick)
	else:
		await _pour_live()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"stow_off"))
	var empty := func() -> bool: return _main.hud_data.held.get("off") == null
	_check(await _until(empty, OP_TIMEOUT_MS, false), "Shift+H puts it away: the off hand is empty (%s)"
			% [_main.hud_data.held.get("off")])


## H, then the first enabled entry whose name has `want` (not frozen or sealed), typed into the list's filter and
## Enter, as a player would; the off hand's ItemRef once it holds it, else null (the list closed).
func _hold_off(want: String) -> ItemRef:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"hold_off"))
	var asked := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.widget is ListRequestWidget
	if not await _until(asked, ASK_TIMEOUT_MS, false):
		return null
	var w := _main.request_ui.widget as ListRequestWidget
	var pick := ""
	for it: Dictionary in w.items:
		var n := str(it.get("plain", ""))
		var ok: bool = it.get("enabled", false) and not n.contains("frozen") and not n.contains("sealed")
		if pick.is_empty() and ok and n.to_lower().contains(want):
			pick = n
	if pick.is_empty():
		root.push_input(_esc_key())
		return null
	w.set_filter(pick)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	root.push_input(enter)
	var in_off := func() -> bool: return _main.hud_data.held.get("off") is ItemRef
	await _until(in_off, OP_TIMEOUT_MS, false)
	return _main.hud_data.held.get("off") as ItemRef


## Shift+E with water in the off hand drinks it with CDDA's consume rules, no menu (its own questions answered as a
## player would); a held knife sent to consume anyway is refused with CDDA's words, and the player sees them.
func _consume_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var seen: Array = []
	var on_done := func(it: ItemRef, op: String) -> void: seen.append(["finished", it.uid, op, ""])
	var on_refused := func(it: ItemRef, op: String, why: String) -> void: seen.append(["refused", it.uid, op, why])
	_main.item_actions.finished.connect(on_done)
	_main.item_actions.refused.connect(on_refused)
	var water := await _hold_off("water")
	var food := _main._held_consumable()
	_check(water != null and food != null and food.uid == water.uid, "Shift+E: held water counts as something to drink (%s)"
			% [_main.hud_data.held.get("off")])
	if food != null:
		var msgs := _messages.size()
		root.push_input(_key_of(&"cdda_eat"))
		var over := func() -> bool: return not seen.is_empty() and _main._in_main_loop()
		await _until(over, OP_TIMEOUT_MS, true)   # CDDA's own questions (not thirsty ...) answered YES
		var said := " / ".join(_messages.slice(msgs)).left(200)
		_check(not seen.is_empty() and seen[0][0] == "finished" and seen[0][2] == "consume",
				"Shift+E drinks the held water, no menu (%s; said %s)" % [seen, said])
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	root.push_input(_key_of(&"stow_off"))
	await _until(func() -> bool: return _main.hud_data.held.get("off") == null, OP_TIMEOUT_MS, false)
	var knife := await _hold_off("knife")
	if knife == null:
		_check(false, "consume refusal: a knife held in the off hand")
	else:
		seen.clear()
		var msgs := _messages.size()
		var feed := _main.hud_data.messages.size()
		var sent := _main.item_actions.consume(knife)
		await _until(func() -> bool: return not seen.is_empty(), OP_TIMEOUT_MS, true)
		var why: String = seen[0][3] if not seen.is_empty() else ""
		var shown := _main.hud_data.messages.slice(feed).any(func(m: Dictionary) -> bool: return m["text"] == why)
		_check(sent and not seen.is_empty() and seen[0][0] == "refused" and not why.is_empty() and shown,
				"consume refusal: a knife is refused with CDDA's words, in the feed (%s; said %s)"
				% [seen, " / ".join(_messages.slice(msgs)).left(160)])
		await _until(in_loop, ASK_TIMEOUT_MS, false)
		root.push_input(_key_of(&"stow_off"))
		await _until(func() -> bool: return _main.hud_data.held.get("off") == null, OP_TIMEOUT_MS, false)
	_main.item_actions.finished.disconnect(on_done)
	_main.item_actions.refused.disconnect(on_refused)


## Holding E with a liquid in the off hand pours it out on the square you face.
func _pour_live() -> void:
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	var hint := _main.pour.hint(_main.world.tables)
	_check(hint.contains("pour"), "the HUD's hint says how to pour (%s)" % hint)
	await _until(in_loop, ASK_TIMEOUT_MS, false)
	var msgs := _messages.size()
	var e_key := _key_of(&"use_held")
	root.push_input(e_key)
	await create_timer(PourHold.HOLD_MS / 1000.0 + 0.3).timeout
	var up := e_key.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)
	var poured := func() -> bool: return str(_main.hud_data.held.get("off_liquid", "?")).is_empty()
	_check(await _until(poured, OP_TIMEOUT_MS, false), "holding E pours the water out on the square you face (%s)"
			% " / ".join(_messages.slice(msgs)).left(160))


## Presses `action`'s key (`ev`, else its first binding) in the main loop; CDDA's answer must show (and be the
## `want` kind, when set), and Esc must bring the game back to its main loop.
func _try_key(action: StringName, want: String, ev: InputEventKey = null) -> void:
	if ev == null:
		ev = _key_of(action)
	var label := "%s (%s)" % [action, ev.as_text() if ev != null else "no key"]
	if ev == null:
		_check(false, label + ": has a key")
		return
	var in_loop := func() -> bool: return _main._in_main_loop() and not _main.request_ui.is_showing()
	if not await _until(in_loop, ASK_TIMEOUT_MS, false):
		_check(false, label + ": the game is in its main loop first (%s)" % [_live.request])
		return
	var msgs := _messages.size()
	root.push_input(ev)
	var asked := func() -> bool: return not _main._in_main_loop() or _messages.size() > msgs
	await _until(asked, ASK_TIMEOUT_MS, false)
	if _main._in_main_loop() and _messages.size() > msgs:   # a message first: a prompt may still follow
		var prompt := func() -> bool: return not _main._in_main_loop()
		await _until(prompt, SETTLE_MS, false)
	if _main._in_main_loop():
		var said := " / ".join(_messages.slice(msgs)) if _messages.size() > msgs else "nothing"
		_seen.append("%s: no prompt; said %s" % [label, said.left(160)])
		_check(want.is_empty(), label + ": %s (said %s)" % ["no prompt is fine" if want.is_empty()
				else "should ask with a " + want, said.left(160)])
		return
	var req := _live.request
	var kind := str(req.get("kind", ""))
	var id := int(req.get("id", 0))
	var drawn := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.request_id == id
	var shown := await _until(drawn, ASK_TIMEOUT_MS, false)
	var w := _main.request_ui.widget
	var fits := ((kind in LIST_KINDS and w is ListRequestWidget) or (kind == "direction" and w is DirectionRequestWidget)
			or not (kind in LIST_KINDS or kind == "direction"))
	var title := (str(req.get("context", "")) + " " + str(req.get("text", ""))).strip_edges().left(80).replace("\n", " ")
	_check(shown and fits, label + ": CDDA asks (%s \"%s\"), RequestUI shows it with %s" % [kind, title,
			"nothing" if w == null else String((w.get_script() as Script).get_global_name())])
	var wanted := (want == "list" and kind in LIST_KINDS) or (want == "direction" and kind == "direction") or want.is_empty()
	_check(wanted, label + ": asks with a %s" % (want if not want.is_empty() else "prompt"))
	var esc := 0
	while not _main._in_main_loop() and esc < MAX_ESC:
		var now := int(_live.request.get("id", 0))
		var on_screen := func() -> bool: return _main.request_ui.is_showing() and _main.request_ui.request_id == now
		await _until(on_screen, ASK_TIMEOUT_MS, false)
		root.push_input(_esc_key())
		esc += 1
		var gone := func() -> bool: return _main._in_main_loop() or int(_live.request.get("id", 0)) != now
		if not await _until(gone, ASK_TIMEOUT_MS, false):
			break
	var back := _main._in_main_loop() and _live.state == "running"
	_seen.append("%s: %s \"%s\", %d Esc back to the game%s" % [label, kind, title, esc, "" if back else " (NOT back)"])
	_check(back, label + ": Esc goes back to the game (%d Esc; now %s)" % [esc, _live.request])


## The key bound first to `action` (F1 defaults), as a press; null if it has none.
func _key_of(action: StringName) -> InputEventKey:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			return k
	return null


func _esc_key() -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.physical_keycode = KEY_ESCAPE
	k.pressed = true
	return k


func _on_events(events: Array) -> void:
	for e: Variant in events:
		if e is Dictionary and str((e as Dictionary).get("kind", "")) == "message":
			_messages.append(CddaText.plain(str((e as Dictionary).get("text", ""))).left(200))


## Presses a range control and waits for the game's answer: "" done, else the error (or why it wasn't sent).
func _op(press: Callable, label: String) -> String:
	var before: Array = _cp._range_ops.keys()
	press.call()
	var sent: Array = _cp._range_ops.keys().filter(func(k: int) -> bool: return not k in before)
	if sent.is_empty():
		return "not sent: " + _cp.status.text
	var id: int = sent[0]
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS, true):
		return "no answer"
	print("  %s -> %s" % [label, "done" if str(_done[id]).is_empty() else _done[id]])
	return _done[id]


## Waits (playing on) until `cond` holds; false on timeout or if the game stops. `answer`: prompts get the answer
## a player would give meanwhile (setup only; the keys' own prompts are this test's to answer).
func _until(cond: Callable, timeout_ms: int, answer: bool) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
		if answer:
			_answer_prompt()
		await create_timer(0.05).timeout
	return false


## A prompt main would show the player gets the answer a player would give (YES to confirmations, else cancel);
## main answers raw-key screens and shots itself.
func _answer_prompt() -> void:
	var req := _live.request
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY":
		return
	var id := int(req.get("id", 0))
	if id == _answered:
		return
	_answered = id
	var a := {"id": id, "cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		a = {"id": id, "action": "YES" if "YES" in acts else acts[0]}
	print("  answering %s %s %s: %s" % [req.get("kind", "?"), req.get("context", ""), acts, a])
	_live.answer(a)


func _stop() -> void:
	_live.stop()
	var stopped := func() -> bool: return _live.state != "running"
	await _until(stopped, 30000, false)
	_main.queue_free()
	await process_frame


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("actions live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
