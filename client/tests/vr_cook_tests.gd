extends RefCounted
## L9 VR cooking cards (VrCook), run by run_tests.gd. A stand-in for LiveSession's recipe wrapper (match_recipes,
## recipes_matched, recipe_matches; lead-ui's, not on this branch) records the queries and the test answers them.
## Snapshots are built by hand: one submap with heat squares and cookware (Snapshot's parser is world_tests').
## No XR runtime: a Node3D stands in for the head, at square (5, 5).

var _check: Callable
var _tables: IdTables
var _world: WorldView
var _head: Node3D
var _cook: VrCook
var _root: Node
var _pot := 0
var _water := 0
var _meat := 0
var _plate := 0
var _soup := 0

const SM := Vector3i(0, 0, 0)


## LiveSession's recipe wrapper: query ids count up, every answer is also kept for recipe_matches.
class Backend extends RefCounted:
	signal recipes_matched(container_uid: int, result: Dictionary)
	var calls: Array = []   # [uid, type, square, avatar_square]
	var refuse := false
	var last := {}
	var _next := 0

	func match_recipes(container: ItemRef, avatar_square := Vector3i.ZERO) -> int:
		calls.append([container.uid, container.type, container.square, avatar_square])
		if refuse:
			return 0
		_next += 1
		return _next

	func recipe_matches(uid: int) -> Dictionary:
		return last.get(uid, {})

	func answer(uid: int, id: int, matches: Array, ok := true, error := "") -> void:
		var r := {"id": id, "ok": ok, "error": error, "container": uid, "matches": matches}
		last[uid] = r
		recipes_matched.emit(uid, r)

	## Anything at all, as a broken emitter would pass it (straight to the connected callables: emit itself may
	## check the declared types).
	func send(uid: Variant, result: Variant) -> void:
		for c: Dictionary in get_signal_connection_list("recipes_matched"):
			(c["callable"] as Callable).call(uid, result)


## Only recipe_matches (no signal): VrCook polls it.
class Polled extends RefCounted:
	var calls := 0
	var last := {}

	func match_recipes(_container: ItemRef, _avatar_square := Vector3i.ZERO) -> int:
		calls += 1
		return 40 + calls

	func recipe_matches(uid: int) -> Dictionary:
		return last.get(uid, {})


func run(root: Node, check: Callable, tables: IdTables) -> void:
	_check = check
	_tables = tables
	_root = root
	print("vr cook (L9)")
	_pot = tables.index_of("itype", "pot")
	_water = tables.index_of("itype", "water_clean")
	_meat = tables.index_of("itype", "meat")
	_plate = tables.index_of("itype", "hotplate")
	_soup = tables.index_of("itype", "soup_meat")
	_check.call(_pot > 0 and _water > 0 and _meat > 0 and _plate > 0 and _soup > 0, "vr cook: mock itypes found")
	_world = WorldView.new()
	_world.tables = tables
	_head = Node3D.new()
	_head.position = Vector3(5.5, 1.6, 5.5)
	root.add_child(_head)
	_test_texts()
	_test_cards()
	_test_queries()
	_test_limits()
	_test_hostile()
	_test_polled()
	_test_rig()
	if is_instance_valid(_cook):
		_cook.free()
	_head.free()
	_world.free()


# --- helpers ---

func _new_cook(backend: Object) -> VrCook:
	if is_instance_valid(_cook):
		_cook.free()
	_cook = VrCook.new()
	_cook.world = _world
	_cook.head = _head
	_cook.backend = backend
	_root.add_child(_cook)
	return _cook


static func _at(x: int, y: int) -> int:
	return y * 12 + x


func _heat(x: int, y: int, lit := true, source := 1, tool := -1, fire := 0, charges := 120) -> Array:
	return [_at(x, y), source, _plate if tool < 0 else tool, fire, charges if lit else 0, 1 if lit else 0]


func _pot_at(x: int, y: int, uid: int, contents: Array = [], progress := 0, result := 0, recipe := "") -> Snapshot.Cookware:
	var c := Snapshot.Cookware.new()
	c.tile = _at(x, y)
	c.uid = uid
	c.type = _pot
	c.contents = PackedInt64Array(contents)
	c.craft_progress = progress
	c.craft_result = result
	c.craft_recipe = recipe
	return c


func _snap(heat: Array, pots: Array, player := Vector3i(5, 5, 0)) -> Snapshot:
	var s := Snapshot.new()
	s.player_pos = player
	var sm := Snapshot.Submap.new()
	sm.pos = SM
	var h := PackedInt32Array()
	for e: Array in heat:
		h.append_array(PackedInt32Array(e))
	sm.heat = h
	sm.cookware = pots
	s.submaps[SM] = sm
	return s


## Shows `snap` and looks once.
func _look(snap: Snapshot) -> void:
	_world.snapshot = snap
	_cook.refresh()


func _lines(uid: int) -> PackedStringArray:
	var c: VrCook.Card = _cook.cards.get(uid)
	return c.text.split("\n") if c != null else PackedStringArray()


func _m(nm: String, secs: Variant, can: bool, missing := PackedStringArray()) -> Dictionary:
	return {"recipe": nm.to_snake_case(), "result": "x", "name": nm, "batch_max": 1, "time_s": secs, "known": true,
			"skills_ok": true, "tools_ok": can, "can_start": can, "missing": missing}


func _water_in() -> Array:
	return [901, _water, 250]


# --- tests ---

func _test_texts() -> void:
	_check.call(VrCook.heat_text({"source": 1, "tool": _plate, "fire": 0, "charges": 120, "lit": true}, _tables)
			== "hotplate: lit (120 charges)" and VrCook.heat_text({"source": 0, "tool": 0, "fire": 2, "charges": 0, "lit": true}, _tables)
			== "fire: lit (fire 2/3)" and VrCook.heat_text({"source": 2, "tool": 0, "fire": 0, "charges": 0, "lit": false}, null)
			== "vehicle: not lit" and VrCook.heat_text({}, _tables) == "no heat",
			"vr cook: heat lines: tool name or source, lit / not lit, fire level and charges")
	var odd := VrCook.heat_text({"source": "x", "tool": -5, "fire": 1e30, "charges": NAN, "lit": "yes"}, _tables)
	_check.call(odd == "heat: not lit (fire 3/3)", "vr cook: odd heat values clamped, a non-bool lit is not lit (%s)" % odd)
	var three := PackedInt64Array([901, _water, 250, 902, _meat, 1, 903, _meat, 1])
	_check.call(VrCook.contents_text(PackedInt64Array(), _tables) == "empty"
			and VrCook.contents_text(three, _tables) == "in it: clean water (250), chunk of meat +1 more"
			and VrCook.contents_text(three, null) == "3 items"
			and VrCook.contents_text(PackedInt64Array([5, 999999, 1]), _tables) == "in it: something",
			"vr cook: contents: first names from the id tables, +N more; a count without tables; unknown types")
	_check.call(VrCook.time_text(30) == "30 s" and VrCook.time_text(720) == "12 min" and VrCook.time_text(3900) == "1 h 5 min"
			and VrCook.time_text(7200) == "2 h" and VrCook.time_text(-5) == "0 s", "vr cook: times in s / min / h")
	_check.call(VrCook.match_line(VrCook.clean_match(_m("Soup", 720, true))) == "+ Soup — 12 min"
			and VrCook.match_line(VrCook.clean_match(_m("Stew", 60, false, PackedStringArray(["boiling 1", "fire"]))))
			== "- Stew — needs boiling 1"
			and VrCook.match_line(VrCook.clean_match(_m("Tea", 60, false))) == "- Tea (can't start)",
			"vr cook: match lines: + for can start with the time, - with the first missing thing")


func _test_cards() -> void:
	_new_cook(null)
	var heat := [_heat(6, 5), _heat(8, 5), _heat(4, 5)]   # (4, 5): heat, no pot
	var pots := [_pot_at(6, 5, 100, _water_in()), _pot_at(8, 5, 101, _water_in()), _pot_at(5, 6, 102, _water_in())]
	_look(_snap(heat, pots))   # 102 lies where nothing heats (Snapshot refuses that; here it is forced in)
	var c: VrCook.Card = _cook.cards.get(100)
	_check.call(_cook.cards.keys() == [100] and c != null and c.visible
			and c.position.is_equal_approx(Vector3(6.5, VrCook.FALLBACK_Y + VrCook.CARD_UP, 5.5)),
			"vr cook: a card over the pot on a lit heat square near the head, not for a far one or one off the heat")
	_check.call(_lines(100) == PackedStringArray(["hotplate: lit (120 charges)", "in it: clean water (250)"])
			and c.label.text == c.text and c.steam.emitting and not c.back.visible,
			"vr cook: no backend: heat and contents only; a lit pot with something in it steams")
	var drawn := _cook.redraws
	_cook.refresh()
	_cook.refresh()
	_check.call(_cook.redraws == drawn, "vr cook: nothing changed, nothing redrawn")
	_look(_snap([_heat(6, 5, false)], [_pot_at(6, 5, 100, _water_in())]))
	_check.call(_lines(100)[0] == "hotplate: not lit" and not c.steam.emitting and _cook.redraws == drawn + 1,
			"vr cook: not lit: said, no steam, one redraw")
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, [])]))
	_check.call(_lines(100)[1] == "empty" and not c.steam.emitting, "vr cook: an empty pot: 'empty', no steam")
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, [902, _meat, 1], 450, _soup, "soup_meat")]))
	_check.call(_lines(100).size() == 3 and _lines(100)[2] == "making meat soup 45%" and c.back.visible and c.fill.visible
			and is_equal_approx(c.fill.scale.x, 0.45) and is_equal_approx(c.progress, 0.45),
			"vr cook: a craft in progress: the result's name, its share and a bar")
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, [902, _meat, 1], 10, 0, "soup_meat")]))
	_check.call(_lines(100)[2] == "making soup meat 1%" and is_equal_approx(c.fill.scale.x, 0.01),
			"vr cook: no result type: the recipe id; the bar follows")
	# Six pots around the head: the four nearest (1.41 m) get cards, the corners (1.73 m) don't.
	var six_heat := []
	var six := []
	var uid := 200
	for xy: Vector2i in [Vector2i(6, 6), Vector2i(6, 5), Vector2i(4, 5), Vector2i(4, 4), Vector2i(5, 6), Vector2i(5, 4)]:
		six_heat.append(_heat(xy.x, xy.y))
		six.append(_pot_at(xy.x, xy.y, uid, _water_in()))
		uid += 1
	_look(_snap(six_heat, six))
	var keys: Array = _cook.cards.keys()
	keys.sort()
	_check.call(keys == [201, 202, 204, 205] and _cook.get_child_count() <= VrCook.MAX_CARDS,
			"vr cook: at most 4 cards, the nearest; card nodes are reused (%s, %d nodes)" % [keys, _cook.get_child_count()])
	_head.position = Vector3(30.5, 1.6, 30.5)
	_cook.refresh()
	_check.call(_cook.cards.is_empty() and _cook.get_children().all(func(n: Node) -> bool: return not (n as Node3D).visible),
			"vr cook: the head walks away: cards hidden")
	_head.position = Vector3(5.5, 1.6, 5.5)
	_world.snapshot = null
	_cook.refresh()
	_check.call(_cook.cards.is_empty(), "vr cook: no snapshot: no cards")
	# Turned to the head: the label's front (+Z) points at it, level.
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, _water_in())]))
	_cook.face()
	var z := (_cook.cards[100] as VrCook.Card).basis.z
	_check.call(z.is_equal_approx(Vector3(-1, 0, 0)), "vr cook: the card faces the head (%s)" % z)


func _test_queries() -> void:
	var b := Backend.new()
	_new_cook(b)
	var heat := [_heat(6, 5), _heat(8, 5)]
	_look(_snap(heat, [_pot_at(6, 5, 100, _water_in()), _pot_at(8, 5, 101, _water_in())]))
	_check.call(b.calls.size() == 1 and b.calls[0] == [100, _pot, Vector3i(6, 5, 0), Vector3i.ZERO]
			and _lines(100).size() == 3 and _lines(100)[2] == "checking recipes...",
			"vr cook: the near pot is asked once with its uid, type and square (not the far one): 'checking recipes...'")
	_cook.refresh()
	_check.call(b.calls.size() == 1 and _cook.pending_count() == 1, "vr cook: one query in flight per pot")
	b.answer(100, 1, [_m("Soup", 720, true), _m("Stew", 3900, false, PackedStringArray(["boiling 1"])), _m("Tea", 30, true),
			_m("Broth", 60, true)])
	_cook.refresh()
	_check.call(_lines(100).slice(2) == PackedStringArray(["+ Soup — 12 min", "- Stew — needs boiling 1", "+ Tea — 30 s",
			"+1 more"]) and _cook.pending_count() == 0,
			"vr cook: up to 3 matches with the can-start mark or the first missing thing, +N more")
	_cook.refresh()
	_cook.update(1.0)
	_check.call(b.calls.size() == 1, "vr cook: answered: not asked again for the same contents and heat")
	var two := _water_in() + [902, _meat, 1]
	_look(_snap(heat, [_pot_at(6, 5, 100, two)]))
	_check.call(b.calls.size() == 2 and _lines(100)[2] == "checking recipes...", "vr cook: new contents: asked again")
	var three := two + [903, _meat, 1]
	_look(_snap(heat, [_pot_at(6, 5, 100, three)]))
	_check.call(b.calls.size() == 2, "vr cook: contents changed with a query in flight: no second query for that pot")
	b.answer(100, 2, [_m("Old", 60, true)])
	_check.call(_cook.pending_count() == 0, "vr cook: the answer for the old contents ends that query")
	_cook.refresh()
	_check.call(b.calls.size() == 3 and not "\n".join(_lines(100)).contains("Old") and _lines(100)[2] == "checking recipes...",
			"vr cook: ... but is dropped, and the pot is asked again")
	b.answer(100, 2, [_m("Older", 60, true)])
	b.answer(555, 3, [_m("Elsewhere", 60, true)])
	_cook.refresh()
	_check.call(_cook.pending_count() == 1 and _lines(100)[2] == "checking recipes...",
			"vr cook: answers for an older query or another pot are ignored")
	b.answer(100, 3, [_m("Meat soup", 1500, true)])
	_cook.refresh()
	_check.call(_lines(100)[2] == "+ Meat soup — 25 min", "vr cook: the answer for these contents shows")
	_look(_snap([_heat(6, 5, false)], [_pot_at(6, 5, 100, three)]))
	_check.call(b.calls.size() == 4, "vr cook: the heat went out: asked again")
	b.answer(100, 4, [])
	_cook.refresh()
	_check.call(_lines(100).slice(2) == PackedStringArray(["nothing to cook from this"]),
			"vr cook: no match on a cold heat: 'nothing to cook from this'")
	_look(_snap(heat, [_pot_at(6, 5, 100, three)]))
	b.answer(100, 5, [])
	_cook.refresh()
	_check.call(_lines(100).slice(2) == PackedStringArray(["nothing to cook from this", "it only warms up"]),
			"vr cook: no match on a lit heat: it only warms up")
	_look(_snap(heat, [_pot_at(6, 5, 100, _water_in())]))
	b.answer(100, 6, [], false, "out of reach")
	_cook.refresh()
	_check.call(_lines(100)[2] == "too far from you to check" and b.calls.size() == 6, "vr cook: a refusal says why")
	_cook.update(VrCook.ERROR_RETRY_S + 0.1)
	_check.call(b.calls.size() == 7, "vr cook: ... and is asked again a while later")
	b.answer(100, 7, [_m("Boiled water", 600, true)])
	_cook.refresh()
	_look(_snap(heat, [_pot_at(6, 5, 100, [902, _meat, 1], 300, _soup)]))
	_check.call(b.calls.size() == 7 and _lines(100)[2] == "making meat soup 30%", "vr cook: a craft in progress: not asked")
	_look(_snap(heat, [_pot_at(6, 5, 100, [])]))
	_check.call(b.calls.size() == 7 and _lines(100).size() == 2, "vr cook: an empty pot: not asked")
	_look(_snap(heat, [_pot_at(6, 5, 100, three + [904, _water, 5])], Vector3i(20, 20, 0)))
	_check.call(b.calls.size() == 7 and _lines(100)[2] == "(out of your reach)",
			"vr cook: a pot out of the player's crafting reach (the ghost is near it): not asked")


## Four queries in flight at most; refused queries wait; unanswered ones are given up after the timeout.
func _test_limits() -> void:
	var b := Backend.new()
	_new_cook(b)
	var heat := []
	var pots := []
	for i in 8:   # two rows of four, 3 m apart: x 4..7, y 3 and 6 ... the head picks one row
		var xy := Vector2i(4 + i % 4, 3 if i < 4 else 9)
		heat.append(_heat(xy.x, xy.y))
		pots.append(_pot_at(xy.x, xy.y, 300 + i, _water_in()))
	var snap := _snap(heat, pots)
	_head.position = Vector3(5.5, 1.6, 2.5)
	_look(snap)
	_check.call(b.calls.size() == 4 and _cook.pending_count() == 4, "vr cook: four pots near: four queries")
	_head.position = Vector3(5.5, 1.6, 9.5)
	_cook.refresh()
	_check.call(_cook.cards.size() == 4 and b.calls.size() == 4 and _lines(304)[2] == "checking recipes...",
			"vr cook: four in flight: the next pots wait")
	_cook.update(VrCook.QUERY_TIMEOUT_S + 1.0)
	_check.call(b.calls.size() == 8 and _cook.pending_count() == 4, "vr cook: unanswered queries are given up after the timeout")
	b.answer(300, 1, [_m("Late", 60, true)])
	_check.call(_cook.pending_count() == 4, "vr cook: a late answer for a given-up query is ignored")
	_head.position = Vector3(5.5, 1.6, 5.5)
	var b2 := Backend.new()
	b2.refuse = true
	_new_cook(b2)
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, _water_in())]))
	_cook.refresh()
	_check.call(b2.calls.size() == 1 and _cook.pending_count() == 0 and _cook.queries_sent == 0,
			"vr cook: a refused query (0) isn't counted and isn't retried at once")
	b2.refuse = false
	_cook.update(VrCook.RETRY_S + 0.1)
	_check.call(b2.calls.size() == 2 and _cook.pending_count() == 1, "vr cook: ... it is retried a moment later")


func _test_hostile() -> void:
	var b := Backend.new()
	_new_cook(b)
	var heat := [_heat(6, 5)]
	_look(_snap(heat, [_pot_at(6, 5, 100, _water_in())]))
	print("        (the next WARNING lines are on purpose)")
	b.send("100", {"id": 1, "ok": true, "container": 100, "matches": [_m("Wrong uid type", 60, true)]})
	b.send(100.0, {"id": 1, "ok": true, "container": 100, "matches": []})
	b.send(100, {"id": "1", "ok": true, "container": 100, "matches": []})
	b.send(100, {"id": 1, "ok": true, "container": 101, "matches": []})
	_check.call(_cook.pending_count() == 1, "vr cook: answers with a bad uid, id or container are ignored")
	var many := []
	for i in 1000:
		many.append(_m("Soup\n[b]%d[/b] " % i + "x".repeat(500), 60.0 * i, i % 2 == 0, PackedStringArray(["fire ".repeat(100)])))
	var bad := [5, "x", null, {"name": 7}, {"name": "", "recipe": ""}, {"name": "Odd", "time_s": "abc", "can_start": "yes",
			"missing": "boiling"}, {"name": "Inf", "time_s": INF}, {"name": "Big", "time_s": 1e300, "missing": [1, {}, "pan"]}]
	b.send(100, {"id": 1.0, "ok": true, "container": 100.0, "matches": bad + many})
	_cook.refresh()
	var lines := _lines(100)
	_check.call(lines.size() == 2 + VrCook.MAX_MATCHES + 1 and lines[2] == "- Odd (can't start)" and lines[3] == "- Inf (can't start)"
			and lines[4] == "- Big — needs pan" and lines[5] == "+%d more" % (VrCook.MAX_SCAN - 5 - 3),
			"vr cook: a huge answer with bad entries: bad ones skipped, 3 shown, the rest counted up to the scan cap %s" % lines)
	var r := VrCook.clean_result({"ok": true, "matches": many})
	_check.call(r["matches"].size() == VrCook.MAX_MATCHES and r["more"] == VrCook.MAX_SCAN - VrCook.MAX_MATCHES
			and r["matches"].all(_bounded), "vr cook: names and missing texts cleaned and capped, times clamped")
	var shown := _look_lines([_m("Soup\n" + "y".repeat(300), 1e12, true, PackedStringArray(["z".repeat(300)]))], b, 2)
	_check.call(shown.size() == 3 and shown[2].length() <= VrCook.LINE_MAX, "vr cook: a long line is cut (%s)" % shown[2])
	_check.call(VrCook.clean_result(null)["ok"] == false and VrCook.clean_result({"ok": "true"})["ok"] == false
			and VrCook.clean_result({"ok": true, "matches": "all"})["matches"].is_empty()
			and VrCook.clean_result({"ok": false, "error": "x".repeat(5000)})["error"].length() <= VrCook.ERROR_MAX,
			"vr cook: odd answers: not ok, no matches, error capped")
	b.answer(100, 2, [_m("asked and answered already", 60, true)])
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, [906, _meat, 3])]))
	_check.call(b.calls.size() == 3 and _cook.pending_count() == 1, "vr cook: new contents, query 3")
	b.send(100, [1, 2, 3])   # a list, not an answer
	_check.call(_cook.pending_count() == 0, "vr cook: an answer that isn't a dictionary ends the query (with a warning)")
	_cook.refresh()
	_check.call(b.calls.size() == 3, "vr cook: ... and the pot is asked again after a moment, not at once")


func _bounded(m: Dictionary) -> bool:
	var nm: String = m["name"]
	var miss: String = m["missing"]
	return nm.length() <= VrCook.NAME_MAX and not nm.contains("\n") and miss.length() <= VrCook.MISSING_MAX \
			and m["time_s"] >= 0 and m["time_s"] <= VrCook.MAX_TIME_S


## Sends contents nobody asked about yet, answers query `id` with `matches`, returns the card's lines.
func _look_lines(matches: Array, b: Backend, id: int) -> PackedStringArray:
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, [905, _meat, id])]))
	b.answer(100, id, matches)
	_cook.refresh()
	return _lines(100)


func _test_polled() -> void:
	var p := Polled.new()
	_new_cook(p)
	p.last[100] = {"id": 7, "ok": true, "container": 100, "matches": [_m("Stale", 60, true)]}
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, _water_in())]))
	_cook.refresh()
	_check.call(p.calls == 1 and _lines(100)[2] == "checking recipes...",
			"vr cook: no signal: recipe_matches is polled, an older result (another id) ignored")
	p.last[100] = {"id": 41, "ok": true, "container": 100, "matches": [_m("Soup", 600, true)]}
	_cook.refresh()
	_check.call(p.calls == 1 and _lines(100)[2] == "+ Soup — 10 min", "vr cook: ... the answer to its query shows")
	_new_cook(RefCounted.new())
	_look(_snap([_heat(6, 5)], [_pot_at(6, 5, 100, _water_in())]))
	_check.call(_lines(100).size() == 2 and not _cook.can_ask(), "vr cook: a backend without match_recipes: heat and contents only")


func _test_rig() -> void:
	var rig := VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_check.call(rig.cook != null and rig.cook.get_parent() == rig and rig.cook.head == rig.camera and rig.cook.world == _world,
			"vr cook: the rig has one, on its head and world")
	var b := Backend.new()
	rig.cook.backend = b
	_check.call(b.is_connected("recipes_matched", rig.cook._on_matched), "vr cook: the backend's signal is connected")
	rig.cook.backend = null
	_check.call(not b.is_connected("recipes_matched", rig.cook._on_matched), "vr cook: ... and let go when it changes")
	rig.free()
