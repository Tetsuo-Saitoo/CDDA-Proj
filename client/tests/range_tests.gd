extends RefCounted
## K7 test range on the client: RangeInfo.clean checks get_range_info like any input; LiveSession sends the
## range_* ops (checked here first), polls the info and emits range_changed / range_done; the cheats page shows
## range controls only in a range game. FakeSim answers like CddaSim. Run by run_tests.gd.

const Main := preload("res://scripts/main.gd")

var _check: Callable


class FakeSim extends RefCounted:
	var info := {"seq": 1, "range": true, "ai_frozen": true, "zone": 0, "results": [],
		"zones": [{"id": "hub", "name": "Hub", "kind": "hub", "built": true},
			{"id": "guns", "name": "<color_red>Guns</color>", "kind": "items", "built": false}]}
	var calls: Array = []
	var actions: Array = []
	var next_id := 1
	var refuse := false
	var reads := 0

	func get_range_info() -> Dictionary:
		reads += 1
		return info.duplicate(true)

	func _op(name: String, args: Array) -> int:
		if refuse:
			return 0
		calls.append([name] + args)
		next_id += 1
		return next_id - 1

	func range_teleport(zone: int) -> int:
		return _op("teleport", [zone])

	func range_rebuild_zone(zone: int) -> int:
		return _op("rebuild", [zone])

	func range_set_time(minute: int) -> int:
		return _op("time", [minute])

	func range_advance(minutes: int) -> int:
		return _op("advance", [minutes])

	func range_set_ai_frozen(on: bool) -> int:
		return _op("frozen", [on])

	func range_heal() -> int:
		return _op("heal", [])

	func range_spawn_item(itype: int, count: int, pos: Vector3i) -> int:
		return _op("item", [itype, count, pos])

	func range_spawn_monster(id: String, pos: Vector3i) -> int:
		return _op("monster", [id, pos])

	func cheat_teleport(pos: Vector3i) -> int:
		return _op("tp", [pos])

	func queue_action(a: String) -> bool:
		actions.append(a)
		return true

	var allowed: Array = []   # each set_cheats_allowed

	func set_cheats_allowed(on: bool) -> void:
		allowed.append(on)


func run(root: Node, check: Callable, tables: IdTables) -> void:
	_check = check
	print("range")
	_test_clean()
	_test_session()
	_test_panel(root, tables)
	_test_loaded(root)
	_test_teleport(root)


## The teleport cheat: TeleportAim picks the square to stand on, LiveSession sends it only with cheats allowed (in
## any game, not only the range), its result comes back through range_done; the F1 entry is greyed out without it.
func _test_teleport(root: Node) -> void:
	var to_ms := func(v: Vector3) -> Vector3i: return Vector3i(floori(v.x), floori(v.z), floori(v.y / 3.0))
	var wall := {"hit": true, "square": Vector3i(5, 0, 0), "point": Vector3(5.02, 1.5, 0.5), "what": "wall"}
	var diag := {"hit": true, "square": Vector3i(5, 5, 0), "point": Vector3(5.0, 1.0, 5.3), "what": "furniture"}
	_check.call(TeleportAim.square(wall, Vector3.RIGHT, to_ms) == Vector3i(4, 0, 0)
			and TeleportAim.square(diag, Vector3(1, 0, 1), to_ms) == Vector3i(4, 5, 0),
			"teleport aim: a wall or furniture: the square the ray crossed before it")
	_check.call(TeleportAim.square({"hit": true, "square": Vector3i(2, 3, -1), "point": Vector3(2.5, -0.01, 3.5), "what": "floor"},
			Vector3.DOWN, to_ms) == Vector3i(2, 3, -1) and TeleportAim.square({"hit": true, "square": Vector3i(2, 3, 1),
			"point": Vector3(2.5, 3.0, 3.5), "what": "ceiling"}, Vector3.UP, to_ms) == Vector3i(2, 3, 1),
			"teleport aim: a floor below or a ceiling above: the square standing on it")
	_check.call(TeleportAim.square({"hit": false}, Vector3.RIGHT, to_ms) == null
			and TeleportAim.square({"hit": true, "square": "x", "point": Vector3.ZERO}, Vector3.RIGHT, to_ms) == null
			and TeleportAim.square({"hit": true, "square": Vector3i(1, 1, 0)}, Vector3.RIGHT, to_ms) == null,
			"teleport aim: nothing hit or a malformed hit: no square")
	var sim := FakeSim.new()
	sim.info = {"seq": 1, "range": false, "zones": [], "results": []}
	var ls := _session(sim)
	var done: Array = []
	ls.range_done.connect(func(id: int, e: String) -> void: done.append([id, e]))
	_check.call(not ls.can_teleport() and ls.cheat_teleport(Vector3i(3, 4, 0)) == 0 and sim.calls.is_empty(),
			"teleport: refused here while cheats aren't allowed")
	ls.set_cheats_allowed(true)
	var id := ls.cheat_teleport(Vector3i(3, 4, 0))
	_check.call(ls.can_teleport() and id == 1 and sim.calls == [["tp", Vector3i(3, 4, 0)]]
			and ls.cheat_teleport(Vector3i(1 << 30, 0, 0)) == 0 and sim.calls.size() == 1,
			"teleport: sent with cheats allowed in a normal game; a square out of bounds isn't")
	sim.info["results"] = [{"id": id, "error": "That square is outside the reality bubble."}]
	ls._poll_range(0.0)
	_check.call(done == [[1, "That square is outside the reality bubble."]], "teleport: the result comes back by its id (%s)" % [done])
	var p := CheatPanel.new()
	root.add_child(p)
	p.backend = ls
	var sent: Array = []
	p.teleport = func() -> int:
		sent.append(1)
		return ls.cheat_teleport(Vector3i(6, 6, 0))
	ls.range_done.connect(p.on_range_done)
	p.refresh()
	_check.call(not p.teleport_button.disabled and p.teleport_button.tooltip_text.contains("J"), "teleport panel: the F1 entry, with its key")
	p.teleport_here()
	sim.info["results"] = [{"id": 2, "error": ""}]
	ls._poll_range(0.0)
	_check.call(sent.size() == 1 and sim.calls[-1] == ["tp", Vector3i(6, 6, 0)] and p.status.text == "Teleport: done.",
			"teleport panel: the entry sends it and says when it was done (%s)" % p.status.text)
	ls.set_cheats_allowed(false)
	p.refresh()
	p.teleport_here()
	_check.call(p.teleport_button.disabled and sent.size() == 1 and p.status.text.begins_with("Teleport: needs"),
			"teleport panel: greyed out while cheats aren't allowed")
	p.free()
	ls.free()


## A range save loaded from the menu (no Test range start, no --test): the game reaches running with cheats not
## allowed by the player; the range info says range, so main forces them and pushes true again (main.gd wires
## range_changed to range_forces_cheats), and the F1 Test range section shows.
func _test_loaded(root: Node) -> void:
	var m := KeyMenu.new()
	m.save_path = preload("res://tests/test_dir.gd").path("range_load_keys.cfg")
	m.hud_path = preload("res://tests/test_dir.gd").path("range_load_hud.cfg")   # not the player's debug switch
	var p := CheatPanel.new()
	m.add_cheat_page(p)
	root.add_child(m)
	var sim := FakeSim.new()
	var ls := _session(sim)
	p.backend = ls
	ls.range_changed.connect(p.on_range_changed)
	ls.range_changed.connect(func(i: Dictionary) -> void: Main.range_forces_cheats(i, m, ls))
	ls.set_cheats_allowed(m.cheats_allowed())   # as the session does when the game reaches running
	ls._poll_range(0.0)
	_check.call(sim.allowed == [false, true] and m.cheats_forced and m.cheats_allowed() and ls.cheats_allowed
			and p.range_box.visible, "range load: a loaded range game forces cheats, pushes true, shows the range (%s)"
			% [sim.allowed])
	sim.info["seq"] = 2
	ls._poll_range(0.0)
	_check.call(sim.allowed == [false, true], "range load: pushed once, not on every range change")
	var m2 := KeyMenu.new()
	var plain := FakeSim.new()
	plain.info = {"seq": 1, "range": false, "zones": []}
	var ls2 := _session(plain)
	ls2.range_changed.connect(func(i: Dictionary) -> void: Main.range_forces_cheats(i, m2, ls2))
	ls2.set_cheats_allowed(m2.cheats_allowed())
	ls2._poll_range(0.0)
	_check.call(plain.allowed == [false] and not m2.cheats_forced and not Main.range_forces_cheats({"range": "yes"}, m2, ls2)
			and not Main.range_forces_cheats({}, null, ls2), "range load: a normal game (or junk) forces nothing")
	ls.free()
	ls2.free()
	m.free()
	m2.free()


func _test_clean() -> void:
	var c := RangeInfo.clean(FakeSim.new().info)
	_check.call(c["range"] and c["ai_frozen"] and c["zone"] == 0 and (c["zones"] as Array).size() == 2
			and c["zones"][1]["name"] == "Guns" and c["zones"][1]["built"] == false, "range: info reads, tags removed")
	var junk := {"range": "yes", "ai_frozen": 1, "zone": 7, "zones": ["x", {"id": 3, "name": 5, "built": "y"}],
		"results": [{"id": 0, "error": ""}, {"id": 2.5}, {"id": 4, "error": 9}, {"id": 5, "error": "<color_red></color>"},
			{"id": 6, "error": "out of reach"}, "junk"]}
	var j := RangeInfo.clean(junk)
	_check.call(not j["range"] and not j["ai_frozen"] and j["zone"] == -1 and (j["zones"] as Array).size() == 1
			and j["zones"][0]["id"] == "3" and j["zones"][0]["name"] == "Zone 1" and not j["zones"][0]["built"],
			"range: non-bools off, a zone index out of the list is -1, nameless zones get one")
	_check.call(j["results"] == [{"id": 4, "error": "refused"}, {"id": 5, "error": "refused"},
			{"id": 6, "error": "out of reach"}], "range: results need an id; a junk error still refuses (%s)" % [j["results"]])
	var many := {"zones": [], "results": []}
	for i in 300:
		many["zones"].append({"id": "z%d" % i, "name": "x".repeat(500)})
		many["results"].append({"id": i + 1, "error": ""})
	var m := RangeInfo.clean(many)
	_check.call((m["zones"] as Array).size() == RangeInfo.MAX_ZONES and (m["results"] as Array).size() == RangeInfo.MAX_RESULTS
			and m["results"][0]["id"] == 285 and (m["zones"][0]["name"] as String).length() == RangeInfo.MAX_NAME,
			"range: zones, results (the newest 16) and names capped")
	_check.call(RangeInfo.clean("nope").is_empty() and RangeInfo.clean([]).is_empty(), "range: junk gives {}")
	_check.call(RangeInfo.monster_id_ok("mon_zombie-2") and not RangeInfo.monster_id_ok("") and not RangeInfo.monster_id_ok("a b")
			and not RangeInfo.monster_id_ok("x".repeat(65)) and not RangeInfo.monster_id_ok("../x"), "range: monster id rule")


func _session(sim: FakeSim) -> LiveSession:
	var ls := LiveSession.new()
	ls._sim = sim
	ls.state = "running"
	return ls


func _test_session() -> void:
	var sim := FakeSim.new()
	var ls := _session(sim)
	var changed: Array = []
	var done: Array = []
	ls.range_changed.connect(func(i: Dictionary) -> void: changed.append(i))
	ls.range_done.connect(func(id: int, e: String) -> void: done.append([id, e]))
	ls._poll_range(0.0)
	_check.call(changed.size() == 1 and ls.in_range() and not ls.range_info().has("results")
			and (ls.range_info()["zones"] as Array).size() == 2, "range: info polled, range_changed (no results in it)")
	ls._poll_range(0.0)
	_check.call(changed.size() == 1, "range: nothing new while seq stays")
	var t := ls.range_teleport(1)
	var a := ls.range_advance(60)
	_check.call(t == 1 and a == 2 and sim.calls == [["teleport", 1], ["advance", 60]] and sim.actions == ["pause"],
			"range: ops send and return their ids; a wait answers the next request with pause")
	var n := sim.calls.size()
	_check.call(ls.range_teleport(-1) == 0 and ls.range_rebuild_zone(-1) == 0
			and ls.range_rebuild_zone(RangeInfo.MAX_ZONES) == 0 and ls.range_set_time(1440) == 0 and ls.range_advance(0) == 0
			and ls.range_advance(10081) == 0 and ls.range_spawn_item(0, 1, Vector3i.ZERO) == 0
			and ls.range_spawn_item(5, 1001, Vector3i.ZERO) == 0 and ls.range_spawn_monster("a b", Vector3i.ZERO) == 0
			and ls.range_spawn_item(5, 1, Vector3i(1 << 30, 0, 0)) == 0 and sim.calls.size() == n,
			"range: bad arguments are refused here, nothing sent")
	_check.call(ls.range_set_time(600) == 3 and ls.range_set_ai_frozen(false) == 4 and ls.range_heal() == 5
			and ls.range_spawn_item(5, 3, Vector3i(1, 2, 0)) == 6 and ls.range_spawn_monster("mon_zombie", Vector3i(3, 4, 0)) == 7
			and sim.calls[-2] == ["item", 5, 3, Vector3i(1, 2, 0)] and sim.calls[-1] == ["monster", "mon_zombie", Vector3i(3, 4, 0)],
			"range: the other ops reach the sim")
	sim.info["results"] = [{"id": 99, "error": ""}, {"id": 1, "error": ""}, {"id": 2, "error": "You can't wait now."}]
	ls._poll_range(0.0)
	ls._poll_range(0.0)
	_check.call(done == [[1, ""], [2, "You can't wait now."]] and changed.size() == 1,
			"range: one range_done per own op's result; results alone don't bump range_changed")
	sim.info["seq"] = 2
	sim.info["zone"] = 1
	sim.info["ai_frozen"] = false
	ls._poll_range(0.0)
	_check.call(changed.size() == 2 and changed[1]["zone"] == 1 and not changed[1]["ai_frozen"], "range: a new zone shows")
	ls._range_ops[3] = Time.get_ticks_msec() - LiveSession.QUERY_TIMEOUT_MS - 1
	ls._poll_range(0.0)
	_check.call(done.has([3, LiveSession.NO_ANSWER]), "range: an op whose result never came is given up")
	var waiting := ls._range_ops.size()
	for i in LiveSession.MAX_RANGE_OPS:
		if ls._range_ops.size() < LiveSession.MAX_RANGE_OPS:
			ls.range_heal()
	_check.call(waiting < LiveSession.MAX_RANGE_OPS and ls.range_heal() == 0 and LiveSession.MAX_RANGE_OPS == RangeInfo.MAX_RESULTS,
			"range: no more ops wait than results are kept (%d)" % LiveSession.MAX_RANGE_OPS)
	ls._range_ops.clear()
	sim.refuse = true
	_check.call(ls.range_heal() == 0, "range: the bridge's 0 is a refusal")
	# A normal game: looked at about once a second only.
	var plain := FakeSim.new()
	plain.info = {"seq": 1, "range": false, "zones": []}
	var ls2 := _session(plain)
	ls2._poll_range(0.0)
	ls2._poll_range(0.5)
	ls2._poll_range(0.4)
	var before := plain.reads
	ls2._poll_range(0.2)
	_check.call(before == 1 and plain.reads == 2 and not ls2.in_range(), "range: outside a range game, polled once a second")
	ls.state = "ended"
	ls._poll_range(0.0)
	_check.call(changed[-1] == {} and not ls.in_range() and ls._range_ops.is_empty(), "range: {} when the game stops")
	_check.call(ls.range_heal() == 0, "range: nothing sent without a running game")
	ls.free()
	ls2.free()


func _test_panel(root: Node, tables: IdTables) -> void:
	var m := KeyMenu.new()
	m.save_path = preload("res://tests/test_dir.gd").path("range_keys.cfg")
	var p := CheatPanel.new()
	m.add_cheat_page(p)
	m.cheats_forced = true
	root.add_child(m)
	p.refresh()
	_check.call(not p.range_box.visible, "range page: hidden without a range game")
	var sim := FakeSim.new()
	var ls := _session(sim)
	ls._poll_range(0.0)
	p.backend = ls
	p.tables = tables
	p.player_square = func() -> Variant: return Vector3i(10, 20, 0)
	p.ahead_square = func() -> Variant: return Vector3i(10, 18, 0)
	p.refresh()
	_check.call(p.range_box.visible and p.zone_pick.item_count == 2 and p.zone_pick.selected == 0
			and p.zone_pick.get_item_text(1) == "Guns (not built yet)" and p.freeze.button_pressed,
			"range page: zones listed, the current one picked, monsters frozen shown")
	p.zone_pick.select(1)
	p.go_zone()
	p.freeze.button_pressed = false
	p.hour.value = 22
	p.set_time()
	p.heal()
	p.wait_hour()
	_check.call(sim.calls == [["teleport", 1], ["frozen", false], ["time", 1320], ["heal"], ["advance", 60]],
			"range page: buttons send their ops (%s)" % [sim.calls])
	p.rebuild_zone()
	_check.call(sim.calls.pop_back() == ["rebuild", 1] and p.status.text == "Rebuild Guns: asked for.",
			"range page: Rebuild sends the picked zone (%s)" % p.status.text)
	p._range_ops.erase(p._range_ops.keys()[-1])
	var rock := tables.index_of("itype", "rock")
	p.item_id.text = " rock "
	p.item_count.value = 5
	p.spawn_item()
	p.monster_id.text = "mon_zombie"
	p.spawn_monster()
	_check.call(sim.calls[-2] == ["item", rock, 5, Vector3i(10, 20, 0)] and sim.calls[-1] == ["monster", "mon_zombie", Vector3i(10, 18, 0)],
			"range page: an item by id at your feet, a monster ahead")
	var n := sim.calls.size()
	p.item_id.text = "no_such_item"
	p.spawn_item()
	var said := p.status.text
	p.monster_id.text = "bad id!"
	p.spawn_monster()
	_check.call(sim.calls.size() == n and said.begins_with("No item type") and p.status.text.begins_with("Monster ids"),
			"range page: unknown item ids and bad monster ids aren't sent")
	p.on_range_done(1, "")
	var ok_text := p.status.text
	p.on_range_done(5, "You can't wait now.")
	_check.call(ok_text == "Go to Guns: done." and p.status.text.ends_with("You can't wait now.") and p._range_ops.size() == 5,
			"range page: results show in the status line, zones by name (%s)" % ok_text)
	p.on_range_done(12345, "")
	_check.call(p.status.text.ends_with("You can't wait now."), "range page: results of other ops ignored")
	# Typing in an id field: the menu lets the keys through, Esc still closes.
	m.open()
	m.show_cheats(true)
	p.item_id.grab_focus()
	var key := InputEventKey.new()
	key.pressed = true
	key.physical_keycode = KEY_A
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.physical_keycode = KEY_ESCAPE
	_check.call(m._typing(key) and not m._typing(esc), "range page: keys reach a focused id field, Esc doesn't")
	p.item_id.release_focus()
	_check.call(not m._typing(key), "range page: without a focused field the menu keeps its keys")
	ls.state = "ended"
	ls._poll_range(0.0)
	p.on_range_changed({})
	_check.call(not p.range_box.visible, "range page: hidden when the game ends")
	ls.free()
	m.free()
