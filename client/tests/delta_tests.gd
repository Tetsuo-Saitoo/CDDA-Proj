extends RefCounted
## Delta snapshots (contracts/snapshot.md "Deltas"), read as hostile input: the `submap_keys` rows are checked
## against the bodies; a delta takes each submap it doesn't send from the snapshot held, only when that holds the
## position with the same revisions and hash (same id tables); anything that doesn't add up fails the snapshot (the
## caller then asks for a full one) and leaves the held snapshot as it was. LiveSession's fetch (SnapJob) with a
## stand-in bridge. Run by run_tests.gd.

var _check: Callable


func run(check: Callable, data: Variant) -> void:
	_check = check
	print("deltas")
	var full := _full(data)
	var base := Snapshot.from_data(full)
	_check.call(base.is_valid() and base.submaps.size() == 363 and base.submap_hash.size() == 363
			and base.submap_hash[_pos(full, 4)] == _hash(full["submaps"][4]["pos"]) and base.base_seq == -1
			and base.reused_submaps == 0, "deltas: a full answer with a key row per body " + base.error)
	_test_full_rows(full)
	_test_delta(full, base)
	_test_bad_delta(data, full, base)
	_test_moved(full, base)
	_test_derived(full)
	_test_live(full)


## The mock town as a full answer (seq 1) with its key rows; the hash is made up (the client keeps it, never computes it).
func _full(data: Variant) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	d["seq"] = 1
	var keys := []
	for s: Dictionary in d["submaps"]:
		var p: Array = s["pos"]
		keys.append([p[0], p[1], p[2], s["revision"], s["detail_revision"], _hash(p)])
	d["submap_keys"] = keys
	return d


static func _hash(p: Array) -> int:
	return (int(p[0]) * 7919 + int(p[1]) * 104729 + int(p[2]) * 31 + 12345) & 0xFFFFFFFF


static func _pos(d: Dictionary, i: int) -> Vector3i:
	var p: Array = d["submaps"][i]["pos"]
	return Vector3i(int(p[0]), int(p[1]), int(p[2]))


## A delta on `full` as seq 2: `edit` changes it (rows and bodies still all there, same order), then only the bodies
## numbered in `bodies` are kept.
static func _delta(full: Dictionary, bodies: Array, edit := Callable()) -> Dictionary:
	var d: Dictionary = full.duplicate(true)
	d["seq"] = 2
	d["base"] = 1
	if edit.is_valid():
		edit.call(d)
	var sent := []
	for i: int in bodies:
		sent.append(d["submaps"][i])
	d["submaps"] = sent
	return d


## A full answer (no `base`) needs a body for every row and a row for every body, rows well formed.
func _test_full_rows(full: Dictionary) -> void:
	var top := full.duplicate(true)
	top["submap_keys"][0][5] = 4294967295.0
	top["submap_keys"][1][5] = 0
	var ok := Snapshot.from_data(top)
	_check.call(ok.is_valid() and ok.submap_hash[_pos(full, 0)] == 0xFFFFFFFF, "deltas: hashes 0..2^32-1 " + ok.error)
	var bad := {
		"a row without its body": func(d: Dictionary) -> void: d["submaps"].remove_at(3),
		"a body without its row": func(d: Dictionary) -> void: d["submap_keys"].remove_at(3),
		"a row twice": func(d: Dictionary) -> void: d["submap_keys"][1] = d["submap_keys"][0].duplicate(),
		"a row of 5": func(d: Dictionary) -> void: d["submap_keys"][2].resize(5),
		"a row of 7": func(d: Dictionary) -> void: d["submap_keys"][2].append(0),
		"a row not a list": func(d: Dictionary) -> void: d["submap_keys"][2] = "1,2,3,4,5,6",
		"keys not a list": func(d: Dictionary) -> void: d["submap_keys"] = {"0": 1},
		"too many rows": func(d: Dictionary) -> void: d["submap_keys"].append([0, 0, 0, 0, 0, 0]),
		"revision not its body's": func(d: Dictionary) -> void: d["submap_keys"][2][3] += 1,
		"detail_revision not its body's": func(d: Dictionary) -> void: d["submap_keys"][2][4] += 1,
		"a fractional revision": func(d: Dictionary) -> void: d["submap_keys"][2][3] += 0.5,
		"a negative hash": func(d: Dictionary) -> void: d["submap_keys"][2][5] = -1,
		"a hash over 32 bits": func(d: Dictionary) -> void: d["submap_keys"][2][5] = 4294967296.0,
		"an infinite hash": func(d: Dictionary) -> void: d["submap_keys"][2][5] = INF,
		"a NaN x": func(d: Dictionary) -> void: d["submap_keys"][2][0] = NAN,
		"a string z": func(d: Dictionary) -> void: d["submap_keys"][2][2] = "0",
		"x outside the bubble": func(d: Dictionary) -> void: d["submap_keys"][2][0] = 11 + CddaCoords.MAPSIZE,
		"z outside the levels": func(d: Dictionary) -> void: d["submap_keys"][2][2] = 5,
		"a huge x": func(d: Dictionary) -> void: d["submap_keys"][2][0] = 1e300,
	}
	var failed := []
	for why: String in bad:
		var d: Dictionary = full.duplicate(true)
		(bad[why] as Callable).call(d)
		var snap := Snapshot.from_data(d)
		if snap.is_valid() or not snap.submaps.is_empty() or not snap.submap_hash.is_empty():
			failed.append(why)
	_check.call(failed.is_empty(), "deltas: bad key rows fail a full answer (passed: %s)" % [failed])


## A delta keeps the submaps it doesn't send (the very same objects), takes the sent ones, and can be the base of the next.
func _test_delta(full: Dictionary, base: Snapshot) -> void:
	var p5 := _pos(full, 5)
	var p9 := _pos(full, 9)
	var rev5: int = base.submaps[p5].revision
	var bump := func(d: Dictionary) -> void:
		d["submaps"][5]["revision"] += 1
		d["submap_keys"][5][3] += 1
		d["submap_keys"][5][5] = 99
	var d2 := _delta(full, [0, 5], bump)
	var snap := Snapshot.from_data(d2, base)
	_check.call(snap.is_valid() and snap.seq == 2 and snap.base_seq == 1 and snap.reused_submaps == 361
			and snap.submaps.size() == 363 and snap.submap_hash.size() == 363 and snap.submap_hash[p5] == 99
			and is_same(snap.submaps[p9], base.submaps[p9]) and not is_same(snap.submaps[_pos(full, 0)], base.submaps[_pos(full, 0)])
			and snap.submaps[p5].revision == rev5 + 1, "deltas: a delta takes the unsent submaps from its base " + snap.error)
	_check.call(base.is_valid() and base.submaps.size() == 363 and base.submaps[p5].revision == rev5
			and base.submap_hash[p5] == _hash(full["submaps"][5]["pos"]), "deltas: the base is left as it was")
	var again := Snapshot.from_data(d2, base)
	var d3 := _delta(full, [], bump)
	d3["seq"] = 3
	d3["base"] = 2
	var next := Snapshot.from_data(d3, snap)
	_check.call(again.is_valid() and next.is_valid() and next.reused_submaps == 363 and is_same(next.submaps[p5], snap.submaps[p5])
			and is_same(next.submaps[p9], base.submaps[p9]), "deltas: the same base twice, and a delta on a delta " + next.error)
	var all := Snapshot.from_data(_delta(full, range(363)), base)
	_check.call(all.is_valid() and all.reused_submaps == 0, "deltas: a delta may send every body " + all.error)


## A delta that doesn't fit the snapshot held fails, and so does one with no base; the held snapshot stays as it was.
func _test_bad_delta(data: Variant, full: Dictionary, base: Snapshot) -> void:
	var p5 := _pos(full, 5)
	var short := full.duplicate(true)
	short["submaps"].remove_at(3)
	short["submap_keys"].remove_at(3)
	var holes := Snapshot.from_data(short)
	var old := Snapshot.from_data(data)
	_check.call(holes.is_valid() and old.is_valid() and old.submap_hash.is_empty(), "deltas: bases " + holes.error + old.error)
	var bad := {
		"no base held": [_delta(full, [0]), null],
		"another base": [_delta(full, [0], func(d: Dictionary) -> void: d["base"] = 7), base],
		"a fractional base": [_delta(full, [0], func(d: Dictionary) -> void: d["base"] = 1.5), base],
		"a string base": [_delta(full, [0], func(d: Dictionary) -> void: d["base"] = "1"), base],
		"a negative base": [_delta(full, [0], func(d: Dictionary) -> void: d["base"] = -1), base],
		"a failed base": [_delta(full, [0]), Snapshot.from_data({})],
		"a base from the old call": [_delta(full, [0]), old],
		"a row the base hasn't": [_delta(full, [0]), holes],
		"a revision the base hasn't": [_delta(full, [0], func(d: Dictionary) -> void: d["submap_keys"][3][3] += 1), base],
		"a detail_revision the base hasn't": [_delta(full, [0], func(d: Dictionary) -> void: d["submap_keys"][3][4] += 1), base],
		"a hash the base hasn't": [_delta(full, [0], func(d: Dictionary) -> void: d["submap_keys"][3][5] += 1), base],
		"other id tables": [_delta(full, [0], func(d: Dictionary) -> void: d["ids_generation"] = 2), base],
		"no key rows": [_delta(full, [0], func(d: Dictionary) -> void: d.erase("submap_keys")), base],
		"a body without its row": [_delta(full, [0], func(d: Dictionary) -> void: d["submap_keys"].remove_at(0)), base],
		"a body not its row's": [_delta(full, [0], func(d: Dictionary) -> void: d["submaps"][0]["revision"] += 1), base],
		"a row twice": [_delta(full, [0], func(d: Dictionary) -> void: d["submap_keys"][1] = d["submap_keys"][2].duplicate()), base],
	}
	var failed := []
	for why: String in bad:
		var snap := Snapshot.from_data(bad[why][0], bad[why][1])
		if snap.is_valid() or not snap.submaps.is_empty():
			failed.append(why)
	_check.call(failed.is_empty() and base.is_valid() and base.submaps.size() == 363 and base.submap_hash.size() == 363
			and base.submaps[p5].revision == int(full["submaps"][5]["revision"]),
			"deltas: a delta that doesn't fit its base fails, the base unharmed (passed: %s)" % [failed])
	var whole := Snapshot.from_data(full, base)
	_check.call(whole.is_valid() and whole.reused_submaps == 0 and whole.base_seq == -1,
			"deltas: a full answer when a delta was asked for is read as one " + whole.error)


## The bubble and the player move between a base and its delta: only positions are compared.
func _test_moved(full: Dictionary, base: Snapshot) -> void:
	var east := func(d: Dictionary) -> void:
		d["bubble_origin"] = [12, 27, 0]
		d["player"]["pos"] = [200, 390, 0]
		var keep := []
		for r: Array in d["submap_keys"]:
			if r[0] >= 12:
				keep.append(r)
		d["submap_keys"] = keep
	var snap := Snapshot.from_data(_delta(full, [], east), base)
	_check.call(snap.is_valid() and snap.reused_submaps == 330 and snap.bubble_origin == Vector3i(12, 27, 0)
			and not snap.submaps.has(Vector3i(11, 27, 0)), "deltas: the bubble moved a submap east " + snap.error)
	var out := func(d: Dictionary) -> void:
		east.call(d)
		d["submap_keys"].append([11, 27, 0, 0, 0, 0])
	_check.call(not Snapshot.from_data(_delta(full, [], out), base).is_valid(),
			"deltas: a row the moved bubble doesn't hold fails")


## A stand-in bridge with the delta call: hands out `answers` in turn and notes each `since` asked for.
class FakeSim extends RefCounted:
	var seq := 0
	var answers: Array = []
	var asked: Array = []

	func get_snapshot_seq() -> int:
		return seq

	func get_snapshot_delta_json(_below: int, _above: int, since: int) -> String:
		asked.append(since)
		return answers.pop_front() if not answers.is_empty() else ""

	func stop() -> void:
		pass


## An older bridge: only the full call.
class OldSim extends RefCounted:
	var text := ""

	func get_snapshot_json(_below: int, _above: int) -> String:
		return text


## LiveSession's fetch: the first snapshot whole (since 0), the next a delta on it, a delta that doesn't fit asked
## for again whole and counted; stopping forgets the base; an older bridge keeps the full call.
func _test_live(full: Dictionary) -> void:
	var sim := FakeSim.new()
	var ls := LiveSession.new()
	ls._sim = sim
	ls.ids_generation = 1
	var got: Array[Snapshot] = []
	ls.snapshot_ready.connect(func(s: Snapshot) -> void: got.append(s))
	var poll := func(seq: int, answers: Array) -> void:
		sim.seq = seq
		sim.answers = answers
		for _k in 5000:
			if ls._poll_snapshot():
				return
			OS.delay_msec(1)
	poll.call(1, [JSON.stringify(full)])
	_check.call(got.size() == 1 and got[0].seq == 1 and sim.asked == [0] and ls._base == got[0] and ls.deltas_read == 0,
			"deltas live: the first fetch asks for everything (since 0) and keeps it as the base %s" % [sim.asked])
	poll.call(2, [JSON.stringify(_delta(full, [0]))])
	_check.call(got.size() == 2 and got[1].base_seq == 1 and got[1].reused_submaps == 362 and sim.asked == [0, 1]
			and ls._base == got[1] and ls.deltas_read == 1 and ls.delta_fallbacks == 0,
			"deltas live: the next fetch is a delta on it %s" % [sim.asked])
	var bad := _delta(full, [0], func(d: Dictionary) -> void: d["base"] = 7)
	bad["seq"] = 3
	var whole := full.duplicate(true)
	whole["seq"] = 3
	poll.call(3, [JSON.stringify(bad), JSON.stringify(whole)])
	_check.call(got.size() == 3 and got[2].seq == 3 and got[2].base_seq == -1 and got[2].reused_submaps == 0
			and sim.asked == [0, 1, 2, 0] and ls._base == got[2] and ls.delta_fallbacks == 1,
			"deltas live: a delta that doesn't fit is fetched again whole and counted %s" % [sim.asked])
	ls.stop()
	_check.call(ls._base == null, "deltas live: stopping forgets the base")
	ls.free()
	var job := LiveSession.SnapJob.new(sim, 4, 1, got[2])
	sim.answers = [JSON.stringify(bad), "{"]
	job.run()
	var old := OldSim.new()
	old.text = JSON.stringify(whole)
	var old_job := LiveSession.SnapJob.new(old, 3, 1, got[2])
	old_job.run()
	_check.call(not job.snap.is_valid() and not job.fallback_why.is_empty() and got[2].is_valid()
			and old_job.snap.is_valid() and old_job.snap.base_seq == -1 and old_job.fallback_why.is_empty(),
			"deltas live: a bad delta and a bad full one fail, the base unharmed; an older bridge keeps the full call")


## What a snapshot works out from all its submaps (lights listed, containers, item uids) counts the reused ones too.
func _test_derived(full: Dictionary) -> void:
	var lit := full.duplicate(true)
	lit["submaps"][3]["lights"] = []
	var base := Snapshot.from_data(lit)
	var p7 := _pos(full, 7)
	var sm: Snapshot.Submap = base.submaps[p7]
	sm.inside = {555: [[556, 1, 0]]}
	sm.handles = PackedInt64Array()
	sm.handles.resize(Snapshot.HANDLE_STRIDE)
	sm.handles[1] = 9001
	var snap := Snapshot.from_data(_delta(lit, [0]), base)
	var unlit := Snapshot.from_data(_delta(lit, [3], func(d: Dictionary) -> void: d["submaps"][3].erase("lights")), base)
	_check.call(base.has_lights and snap.is_valid() and snap.has_lights and snap.inside_of(555).size() == 1
			and snap._known_uids().has(9001) and unlit.is_valid() and not unlit.has_lights,
			"deltas: lights, containers and item uids of the reused submaps count " + snap.error + unlit.error)
