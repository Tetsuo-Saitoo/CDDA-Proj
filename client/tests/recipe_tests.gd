extends RefCounted
## L9: recipe queries on the client. RecipeMatches.parse checks the sim's JSON like any input (caps, types,
## clamps, cleaned text); LiveSession.match_recipes sends a handle, polls take_query_result and emits
## recipes_matched once per answer (FakeSim answers like CddaSim). Run by run_tests.gd.

var _check: Callable


class FakeSim extends RefCounted:
	var asked: Array = []
	var results := {}   # id -> text, taken once
	var next_id := 1

	func match_recipes(d: Dictionary) -> int:
		asked.append(d)
		next_id += 1
		return next_id - 1

	func take_query_result(id: int) -> String:
		var t: String = results.get(id, "")
		results.erase(id)
		return t


func run(check: Callable) -> void:
	_check = check
	print("recipes")
	_test_parse()
	_test_session()


func _good(id: int, container: int) -> Dictionary:
	return {"id": id, "ok": true, "error": "", "container": container, "matches": [
		{"recipe": "soup_veggy", "result": "soup_veggy", "name": "<color_red>vegetable soup</color>", "batch_max": 2,
			"time_s": 1800, "known": true, "skills_ok": true, "tools_ok": true, "missing": [], "can_start": true},
		{"recipe": "meat_cooked", "result": "meat_cooked", "name": "cooked meat", "batch_max": 99, "time_s": -5,
			"known": "yes", "skills_ok": true, "tools_ok": false, "missing": ["fire or hotplate", 7, "boiling 1"],
			"can_start": false},
	]}


func _test_parse() -> void:
	var r := RecipeMatches.parse(JSON.stringify(_good(3, 1000123)))
	var m: Array = r.get("matches", [])
	_check.call(r.get("id") == 3 and r.get("ok") == true and r.get("container") == 1000123 and m.size() == 2,
			"recipes: a result reads (%s)" % [r.keys()])
	if m.size() == 2:
		_check.call(m[0]["name"] == "vegetable soup" and m[0]["can_start"] and m[0]["batch_max"] == 2 and m[0]["time_s"] == 1800,
				"recipes: a match's fields, colour tags removed")
		_check.call(m[1]["batch_max"] == 0 and m[1]["time_s"] == 0 and m[1]["known"] == false
				and m[1]["missing"] == PackedStringArray(["fire or hotplate", "boiling 1"]),
				"recipes: out-of-range numbers, non-bool flags and non-text missing entries dropped")
	var refused := RecipeMatches.parse('{"id": 4, "ok": false, "error": "out of reach", "container": 5, "matches": []}')
	_check.call(refused.get("ok") == false and refused.get("error") == "out of reach" and (refused["matches"] as Array).is_empty(),
			"recipes: a refusal keeps its reason")
	var odd := RecipeMatches.parse('{"id": 4, "ok": false, "error": "<script>", "container": 5}')
	_check.call(odd.get("error") == "internal", "recipes: an unknown error reads as internal")
	var many := _good(5, 6)
	var lots: Array = []
	for i in 100:
		lots.append({"recipe": "r%d" % i, "missing": range(50).map(func(k: int) -> String: return "m%d" % k)})
	many["matches"] = lots + [{"recipe": "bad id!"}, {"name": "no id"}, "junk"]
	var big := RecipeMatches.parse(JSON.stringify(many))
	_check.call((big["matches"] as Array).size() == RecipeMatches.MAX_MATCHES
			and (big["matches"][0]["missing"] as PackedStringArray).size() == RecipeMatches.MAX_MISSING,
			"recipes: matches and missing texts capped")
	var bad := 0
	for t: String in ["", "[]", "nope", '{"id": 0, "container": 1}', '{"id": 1.5, "container": 1}',
			'{"id": 1, "container": -3}', '{"id": "1", "container": 1}', "x".repeat(RecipeMatches.MAX_BYTES + 1)]:
		if RecipeMatches.parse(t).is_empty():
			bad += 1
	_check.call(bad == 8, "recipes: junk results give {} (%d of 8)" % bad)
	var weird := _good(7, 8)
	weird["matches"] = [{"recipe": "ok_id", "name": "x".repeat(500)}]
	var w := RecipeMatches.parse(JSON.stringify(weird))
	_check.call((w["matches"][0]["name"] as String).length() == RecipeMatches.MAX_TEXT and w["matches"][0]["result"] == "",
			"recipes: long names capped, a missing result id is empty")


func _test_session() -> void:
	var sim := FakeSim.new()
	var ls := LiveSession.new()
	ls._sim = sim
	ls.state = "running"
	var pot := ItemRef.on_square(1000123, 42, Vector3i(10, 20, 0))
	var carried := ItemRef.on_player(55, 43, 0, -1, 0, Vector3i(1, 2, 0))
	var got: Array = []
	ls.recipes_matched.connect(func(uid: int, r: Dictionary) -> void: got.append([uid, r]))
	var id := ls.match_recipes(pot)
	var id2 := ls.match_recipes(carried, Vector3i(3, 4, 0))
	_check.call(id == 1 and id2 == 2 and sim.asked[0] == {"uid": 1000123, "type": 42, "pos": Vector3i(10, 20, 0)}
			and sim.asked[1]["pos"] == Vector3i(3, 4, 0), "recipes: a query sends the handle and square (carried: the player's)")
	ls._poll_queries()
	_check.call(got.is_empty() and ls.recipe_matches(1000123).is_empty(), "recipes: nothing until the sim answers")
	sim.results[1] = JSON.stringify(_good(1, 1000123))
	sim.results[2] = JSON.stringify(_good(2, 999))   # names another container: ignored
	ls._poll_queries()
	ls._poll_queries()
	_check.call(got.size() == 1 and got[0][0] == 1000123 and (got[0][1]["matches"] as Array).size() == 2
			and ls.recipe_matches(1000123)["id"] == 1 and ls.recipe_matches(55).is_empty() and ls._queries.is_empty(),
			"recipes: one recipes_matched per answer; a result for another container is dropped")
	_check.call(ls.match_recipes(null) == 0 and ls.match_recipes(ItemRef.on_square(0, 42, Vector3i.ZERO)) == 0,
			"recipes: no container or a bad handle asks nothing")
	ls.state = "booting"
	_check.call(ls.match_recipes(pot) == 0, "recipes: nothing while no game runs")
	ls.state = "running"
	for i in LiveSession.MAX_QUERIES:
		ls.match_recipes(pot)
	_check.call(ls.match_recipes(pot) == 0 and ls._queries.size() == LiveSession.MAX_QUERIES, "recipes: at most 8 pending")
	ls.free()
