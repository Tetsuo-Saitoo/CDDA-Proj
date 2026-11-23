extends RefCounted
## C6 vehicle work (lead-ui, 2026-11-22): VehicleWorkData (the bridge's read, contracts/vehicle_work.md, and the
## snapshot's stand-in), VehicleWorkView (list, commands, keys) and LiveSession.query_vehicle_work. Run by
## run_tests.gd.

const UID := 4343

var _check: Callable


## Stands in for CddaSim's vehicle-work query: keeps what was asked, answers from `results`.
class WorkSim:
	var asked: Array = []
	var results := {}
	var next := 40
	var queued: Array = []
	var accept := true

	func queue_vehicle_work(d: Dictionary) -> bool:
		queued.append(d)
		return accept

	func query_vehicle_work(d: Dictionary) -> int:
		asked.append(d)
		next += 1
		return next

	func take_query_result(id: int) -> String:
		return results.get(id, "")


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	_test_parse()
	_test_stand_in(data)
	_test_view(root, data)
	_test_live()
	_test_action(root)


## The mock with a car next to the player: part 0 a frame and 1 another part on the square east of the player
## (1 damaged), part 2 a broken part a square further, part 3 a gap filler.
static func _with_car(data: Variant, far := false) -> Snapshot:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var p := Snapshot.from_data(data).player_pos + Vector3i(5 if far else 1, 0, 0)
	var parts := [[0, 0, 1, 255, 0, 0, 0, 0], [0, 0, 2, 128, 0, 0, 0, 0], [1, 0, 1, 0, Snapshot.VPART_BROKEN, 1, 0, 0],
			[0, 1, 1, 255, Snapshot.VPART_FILLER, 0, 1, 0]]
	d["vehicles"] = [{"uid": UID, "name": "Pickup", "pos": [p.x, p.y, p.z], "face_deg": 0.0, "parts": parts}]
	return Snapshot.from_data(d)


static func _sample(id: int) -> Dictionary:
	return {"id": id, "ok": true, "kind": "vehicle_work", "vehicle": UID, "name": "Car", "turn": 5224405,
		"parts": [
			{"row": 0, "mount": [0, 0], "vpart": 412, "name": "frame", "variant": "cross", "hp": 100, "damage": 0, "flags": 0,
				"fill": {"what": "gasoline", "now": 45000, "max": 60000, "unit": "ml"}},
			{"row": 9, "mount": [1, -1], "vpart": 630, "name": "<color_red>wheel</color> (faulty)\u0007", "variant": "",
				"hp": 31, "damage": 3, "flags": 6 | 64, "faults": ["Flat tire", 5]},
			{"row": 9, "mount": [0, 0], "vpart": 1, "name": "again", "hp": 1, "damage": 0, "flags": 0},
			{"row": -1, "mount": [0, 0]}, {"row": 3, "mount": [999, 0]}, "junk",
			{"row": 4, "mount": [0, 0], "vpart": 2, "name": "seat", "variant": "é", "hp": 100, "damage": 0, "flags": 0,
				"fill": {"what": "x", "now": 1, "max": 2, "unit": "furlongs"}}],
		"parts_more": 2,
		"selected": {"row": 9, "here": [8, 9, 4, 4], "commands": [
			{"cmd": "r", "ok": false, "reason": 0, "text": "", "time_s": 1800, "lines": [
				{"text": "Time required:", "met": 0}, {"text": "> mechanics 1", "met": 1},
				{"text": "> 1 tool with wrenching quality of 1 or more", "met": 2}]},
			{"cmd": "o", "ok": true, "reason": 0, "text": "", "time_s": 600, "lines": []},
			{"cmd": "o", "ok": false, "reason": 3, "text": "", "time_s": 0, "lines": []},
			{"cmd": "m", "ok": true, "reason": 9, "text": "", "time_s": 0, "lines": []},
			{"cmd": "x", "ok": true, "reason": 0, "text": "", "time_s": 0, "lines": []},
			{"cmd": "f", "ok": false, "reason": 7, "text": "It's too dark.", "time_s": 0, "lines": []}]},
		"truncated": false}


func _test_parse() -> void:
	var r := VehicleWorkData.parse_result(JSON.stringify(_sample(7)), 7)
	var ok: bool = not r.is_empty() and r["ok"] and r["vehicle"] == UID and r["name"] == "Car" and r["parts"].size() == 3 \
			and r["parts_more"] == 2 + 4   # the duplicate, the bad row, the bad mount and the junk
	var wheel := VehicleWorkData.part_of(r, 9) if ok else {}
	var seat := VehicleWorkData.part_of(r, 4) if ok else {}
	ok = ok and wheel.get("name") == "wheel (faulty)" and wheel["flags"] == 6 and wheel["faults"] == PackedStringArray(["Flat tire"]) \
			and wheel["mount"] == Vector2i(1, -1) and seat.get("variant") == "" and VehicleWorkData.part_of(r, 0)["variant"] == "cross" \
			and VehicleWorkData.fill_text(VehicleWorkData.part_of(r, 0)["fill"]) == "gasoline 45.0/60.0 L" \
			and seat["fill"].is_empty() and wheel["fill"].is_empty() \
			and VehicleWorkData.fill_text({"what": "", "now": 0, "max": 0, "unit": "charges"}) == "empty 0" \
			and VehicleWorkData.fill_text({"what": "battery", "now": 3000, "max": 3000, "unit": "charges"}) == "battery 3000/3000"
	var sel: Dictionary = r.get("selected", {})
	var cmds: Array = sel.get("commands", [])
	var rep := VehicleWorkData.command_of(r, "r")
	ok = ok and sel.get("here") == PackedInt32Array([9, 4]) and cmds.size() == 4 \
			and cmds.map(func(c: Dictionary) -> String: return c["cmd"]) == ["r", "o", "m", "f"] \
			and VehicleWorkData.command_of(r, "o")["ok"] and not VehicleWorkData.command_of(r, "m")["ok"] \
			and VehicleWorkData.refusal(rep) == "Missing: 1 tool with wrenching quality of 1 or more" \
			and VehicleWorkData.refusal(VehicleWorkData.command_of(r, "f")) == "It's too dark." \
			and rep["lines"][2]["met"] == VehicleWorkData.NOT_MET \
			and VehicleWorkData.refusal({"ok": false, "reason": 0, "text": "", "lines": [
				{"text": "This part cannot be repaired.", "met": VehicleWorkData.NOT_MET}]}) == "This part cannot be repaired."
	var err := VehicleWorkData.parse_result(JSON.stringify({"id": 8, "ok": false, "kind": "vehicle_work", "vehicle": UID,
			"error": "too far"}), 8)
	var odd := VehicleWorkData.parse_result(JSON.stringify({"id": 8, "ok": false, "kind": "vehicle_work", "error": "boom"}), 8)
	var bad_sel := _sample(9)
	bad_sel["selected"]["row"] = 77
	_check.call(ok and err == {"ok": false, "vehicle": UID, "error": "too far"} and odd["error"] == "internal"
			and VehicleWorkData.parse_result(JSON.stringify(_sample(7)), 8).is_empty()
			and VehicleWorkData.parse_result(JSON.stringify({"id": 7, "ok": true, "kind": "character"}), 7).is_empty()
			and VehicleWorkData.parse_result("not json", 7).is_empty() and VehicleWorkData.parse_result(null, 7).is_empty()
			and VehicleWorkData.parse_result(JSON.stringify(bad_sel), 9)["selected"].is_empty(),
			"vehicle work read: parts, selected and commands cleaned; junk rows, repeats, unknown commands and reasons "
			+ "dropped or refused; errors, other ids and kinds (%s)" % [r.get("parts", []).size()])


func _test_stand_in(data: Variant) -> void:
	var s := _with_car(data)
	var r := VehicleWorkData.stand_in(s, null, UID, 1)
	var rows: Array = r.get("parts", []).map(func(p: Dictionary) -> int: return p["row"])
	var ok: bool = r.get("ok") == true and r.get("stand_in") == true and rows == [0, 1, 2] \
			and VehicleWorkData.part_of(r, 1)["flags"] == VehicleWorkData.REPAIRABLE \
			and VehicleWorkData.part_of(r, 2)["flags"] == VehicleWorkData.BROKEN \
			and r["selected"]["here"] == PackedInt32Array([0, 1]) and VehicleWorkData.command_of(r, "r")["ok"] \
			and not VehicleWorkData.command_of(r, "m")["ok"]
	var whole := VehicleWorkData.stand_in(s, null, UID, 0)
	_check.call(ok and not VehicleWorkData.command_of(whole, "r")["ok"]
			and VehicleWorkData.stand_in(s, null, UID + 1)["error"] == "no such vehicle"
			and VehicleWorkData.stand_in(_with_car(data, true), null, UID)["error"] == "too far"
			and VehicleWorkData.vehicle_near(s) != null and VehicleWorkData.vehicle_near(_with_car(data, true)) == null,
			"vehicle work stand-in: the snapshot's parts without gap fillers, damaged repairable, broken; too far, gone (%s)"
			% [rows])


func _test_view(root: Node, data: Variant) -> void:
	var s := _with_car(data)
	var v := VehicleWorkView.new()
	v.mouse_hook = func(_m: int) -> int: return Input.MOUSE_MODE_VISIBLE
	root.add_child(v)
	var picked: Array = []
	var chosen: Array = []
	var views: Array = []
	var closed := [0]
	v.part_selected.connect(func(row: int) -> void:
		picked.append(row)
		v.set_result(VehicleWorkData.stand_in(s, null, UID, row)))
	v.command_chosen.connect(func(c: String, row: int) -> void: chosen.append([c, row]))
	v.view_chosen.connect(func(n: String) -> void: views.append(n))
	v.closed.connect(func() -> void: closed[0] += 1)
	v.open(UID, "Pickup")
	var other := VehicleWorkData.stand_in(s, null, UID, -1)
	other["vehicle"] = UID + 1
	var ignored := not v.set_result(other) and v.selected == -1
	v.set_result(VehicleWorkData.stand_in(s, null, UID, -1))
	var first := v.selected   # front first: part 2 (mount x 1) is listed before the square of parts 0 and 1
	var detail := v.detail_text()
	# 800x450 (lead-qa): everything it holds fits the width it takes there, the command row wrapping
	var need := v.get_combined_minimum_size().x
	var fits := need <= VehicleWorkView.width_for(800.0) and v.grow_horizontal == Control.GROW_DIRECTION_BEGIN
	v.handle_key(_key(KEY_DOWN))
	var moved := v.selected
	var mend := v.choose("m")
	var mend_note := v.detail_text()
	v.handle_key(_key(KEY_O))
	v.handle_key(_key(KEY_2))
	v.blocked = func() -> bool: return true
	var held := not v.handle_key(_key(KEY_DOWN)) and v.selected == moved
	v.blocked = Callable()
	var far := {"ok": false, "vehicle": UID, "error": "too far"}
	v.set_result(far)
	var shut: bool = not v.visible and closed[0] == 1
	v.open(UID, "Pickup")
	v.set_result(VehicleWorkData.stand_in(s, null, UID, -1))
	v.handle_key(_key(KEY_ESCAPE))
	root.remove_child(v)
	v.free()
	_check.call(ignored and first == 2 and moved == 0 and picked.slice(0, 2) == [2, 0] and not mend
			and "Nothing to do on this part." in mend_note and chosen == [["o", 0]] and views == ["hood"] and held
			and shut and closed[0] == 2 and "r:on" in detail and "m:off" in detail and "i:off" in detail and fits,
			"vehicle work view: the list by square, Down moves, a refused command says why, o chosen, 2 the hood view, "
			+ "keys held while a prompt is up, too far and Esc close; fits 800x450 (%s; %s; needs %d px)"
			% [detail, chosen, need])


func _test_live() -> void:
	var sim := WorkSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	var got: Array = []
	ls.vehicle_work.connect(func(d: Dictionary) -> void: got.append(d))
	var id1 := ls.query_vehicle_work(UID, 9)
	var refused := ls.query_vehicle_work(UID)
	ls._poll_vehicle_work()   # no answer yet
	sim.results[id1] = JSON.stringify(_sample(id1))
	ls._poll_vehicle_work()
	var id2 := ls.query_vehicle_work(UID)
	sim.results[id2] = JSON.stringify(_sample(id1))   # another query's id: junk, dropped
	ls._poll_vehicle_work()
	var bad := ls.query_vehicle_work(0) == 0 and ls.query_vehicle_work(UID, 5000) == 0
	var id3 := ls.query_vehicle_work(UID, 9)   # lead-qa: the contract's exact error object has no vehicle
	sim.results[id3] = JSON.stringify({"id": id3, "ok": false, "kind": "vehicle_work", "error": "no such part"})
	ls._poll_vehicle_work()
	var id4 := ls.query_vehicle_work(UID)
	var wrong := _sample(id4)
	wrong["vehicle"] = UID + 1   # an answer about another vehicle than asked: dropped
	sim.results[id4] = JSON.stringify(wrong)
	ls._poll_vehicle_work()
	ls._sim = null
	ls.free()
	_check.call(id1 > 0 and refused == 0 and id2 > id1 and bad and got.size() == 2 and got[0]["ok"]
			and got[0]["selected"]["row"] == 9 and got[1] == {"ok": false, "vehicle": UID, "error": "no such part"}
			and sim.asked == [{"vehicle": UID, "part": 9}, {"vehicle": UID}, {"vehicle": UID, "part": 9}, {"vehicle": UID}],
			"vehicle work query: one at a time, the result handed on cleaned, an error as the contract writes it given "
			+ "the vehicle asked about, another id or vehicle dropped, out-of-range refused (%s; %s)" % [sim.asked, got.slice(1)])


static func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.pressed = true
	return k


## The action (repair and remove so far): LiveSession.queue_vehicle_work and its work_result; the read's `owned`
## and the appliance error.
func _test_action(root: Node) -> void:
	var sim := WorkSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	var t1 := ls.queue_vehicle_work(UID, 9, "r")
	var t2 := ls.queue_vehicle_work(UID, 0, "o")
	var refused := ls.queue_vehicle_work(UID, 9, "m") == 0 and ls.queue_vehicle_work(UID, -1, "r") == 0 \
			and ls.queue_vehicle_work(0, 9, "r") == 0 and ls.queue_vehicle_work(UID, 4096, "o") == 0
	sim.accept = false
	var full := ls.queue_vehicle_work(UID, 9, "r") == 0
	ls._sim = null
	ls.free()
	var sent_ok: bool = t1 > 0 and t2 == t1 + 1 and refused and full and sim.queued.size() == 3 \
			and sim.queued[0] == {"vehicle": UID, "part": 9, "cmd": "r", "tag": t1} and sim.queued[1]["cmd"] == "o"
	var ev := {"kind": "work_result", "uid": UID, "amount": 0, "detail": 5,
			"text": "You don't meet the requirements to repair the <color_white>glovebox</color>."}
	var no := VehicleWorkData.work_result(ev, 5)
	var started := ev.duplicate()
	started["amount"] = 1.0
	started["text"] = ""
	var odd := ev.duplicate()
	odd["amount"] = 2
	var ev_ok: bool = no == {"started": false, "vehicle": UID, "text": "You don't meet the requirements to repair the glovebox."} \
			and VehicleWorkData.work_result(started, 5)["started"] and VehicleWorkData.work_result(ev, 6).is_empty() \
			and VehicleWorkData.work_result(odd, 5).is_empty() and VehicleWorkData.work_result({"kind": "message"}, 5).is_empty() \
			and VehicleWorkData.work_result(ev, 0).is_empty() and VehicleWorkData.work_result("junk", 5).is_empty()
	var theirs := _sample(3)
	theirs["owned"] = false
	var r := VehicleWorkData.parse_result(JSON.stringify(theirs), 3)
	var mine := VehicleWorkData.parse_result(JSON.stringify(_sample(3)), 3)
	var app := VehicleWorkData.parse_result(JSON.stringify({"id": 3, "ok": false, "kind": "vehicle_work",
			"error": "an appliance"}), 3)
	var v := VehicleWorkView.new()
	v.mouse_hook = func(_m: int) -> int: return Input.MOUSE_MODE_VISIBLE
	root.add_child(v)
	v.open(UID)
	v.set_result(r)
	var note := v._note.text
	v.say("Repair started.")
	var said := "Repair started." in v.detail_text()
	v.forget_selection()
	var forgot := v.selected == -1
	app["vehicle"] = UID
	v.set_result(app)
	var shut := not v.visible
	root.remove_child(v)
	v.free()
	_check.call(sent_ok and ev_ok and r["owned"] == false and mine["owned"] == true and app["error"] == "an appliance"
			and note.begins_with("Not your vehicle") and said and forgot and shut,
			"vehicle work action: r and o queued with a tag, others refused; work_result read for its tag only; "
			+ "someone else's vehicle noted; an appliance closes the view (%s; %s; %s)" % [sim.queued, no, note])
