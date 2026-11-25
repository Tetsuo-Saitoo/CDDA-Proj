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


## main's WorldView as VehicleWorkSession reads it.
class FakeWorld:
	var snapshot: Snapshot
	var tables: IdTables


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	_test_parse()
	_test_stand_in(data)
	_test_view(root, data)
	_test_live()
	_test_action(root)
	_test_gate()
	_test_install(root)
	_test_mend_refill()
	_test_frame()
	_test_session(data)


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
	var held: bool = not v.handle_key(_key(KEY_DOWN)) and v.selected == moved
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
			and shut and closed[0] == 2 and "r:on" in detail and "m:off" in detail and "i:on" in detail and fits,
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
	var m := Vector2i(1, -1)
	var t1 := ls.queue_vehicle_work(UID, 9, 630, m, "r")
	var t2 := ls.queue_vehicle_work(UID, 0, 412, Vector2i.ZERO, "o")
	var refused := ls.queue_vehicle_work(UID, 9, 630, m, "x") == 0 and ls.queue_vehicle_work(UID, -1, 630, m, "r") == 0 \
			and ls.queue_vehicle_work(0, 9, 630, m, "r") == 0 and ls.queue_vehicle_work(UID, 4096, 630, m, "o") == 0 \
			and ls.queue_vehicle_work(UID, 9, -1, m, "r") == 0 and ls.queue_vehicle_work(UID, 9, 0, m, "r") == 0 \
			and ls.queue_vehicle_work(UID, 9, (1 << 20) + 1, m, "r") == 0 \
			and ls.queue_vehicle_work(UID, 9, 630, Vector2i(1024, 0), "r") == 0 \
			and ls.queue_vehicle_work(UID, 9, 630, Vector2i(0, -1024), "r") == 0
	sim.accept = false
	var full := ls.queue_vehicle_work(UID, 9, 630, m, "r") == 0
	ls._sim = null
	ls.free()
	var sent_ok: bool = t1 > 0 and t2 == t1 + 1 and refused and full and sim.queued.size() == 3 \
			and sim.queued[0] == {"vehicle": UID, "part": 9, "vpart": 630, "mount": [1, -1], "cmd": "r", "tag": t1} \
			and sim.queued[1]["cmd"] == "o" and sim.queued[1]["vpart"] == 412 and sim.queued[1]["mount"] == [0, 0]
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
	var mounted := VehicleWorkData.parse_result(JSON.stringify({"id": 3, "ok": false, "kind": "vehicle_work",
			"vehicle": UID, "error": "mounted", "text": "You cannot interact with a vehicle while <color_red>mounted</color>."}), 3)
	v.set_result(mounted)
	var shell := VehicleWorkData.parse_result(JSON.stringify({"id": 3, "ok": false, "kind": "vehicle_work",
			"vehicle": UID, "error": "in shell"}), 3)
	var told: bool = v.visible and "You cannot interact with a vehicle while mounted." in v.detail_text() \
			and mounted == {"ok": false, "vehicle": UID, "error": "mounted",
				"text": "You cannot interact with a vehicle while mounted."} \
			and shell == {"ok": false, "vehicle": UID, "error": "in shell"}
	app["vehicle"] = UID
	v.set_result(app)
	var shut := not v.visible
	root.remove_child(v)
	v.free()
	_check.call(sent_ok and ev_ok and r["owned"] == false and mine["owned"] == true and app["error"] == "an appliance"
			and note.begins_with("Not your vehicle") and said and forgot and shut and told,
			"vehicle work action: r and o queued with a tag, others refused; work_result read for its tag only; "
			+ "someone else's vehicle noted; CDDA's sentence for mounted shown; an appliance closes the view "
			+ "(%s; %s; %s; %s)" % [sim.queued, no, note, mounted])


## The hold on r and o (VehicleWorkData.Gate): after a parts change or started work, until a read asked after it,
## with the player free, comes back whole.
func _test_gate() -> void:
	var g := VehicleWorkData.Gate.new()
	var at_first: bool = g.held(false, "") == "" and not g.wants_read(false)
	g.asked(false)   # a read out before the change...
	g.changed()
	g.answered(true)   # ... doesn't clear it
	var old_kept: bool = g.stale and g.held(false, "") == "Checking the parts again..." and g.wants_read(false) \
			and not g.wants_read(true)
	g.asked(true)   # asked while the removal still runs
	g.answered(true)
	var busy_kept: bool = g.stale and g.held(true, "removing") == "Not while you're removing." \
			and g.held(true, "") == "Not while you're busy."
	g.asked(false)
	g.changed()   # another part came off while it was out
	g.answered(true)
	var twice_kept: bool = g.stale
	g.asked(false)
	g.answered(false)   # an error answer has no new list
	var error_kept: bool = g.stale and g.wants_read(false)
	g.asked(false)
	g.answered(true)
	var cleared: bool = not g.stale and g.held(false, "") == "" and not g.wants_read(false)
	_check.call(at_first and old_kept and busy_kept and twice_kept and error_kept and cleared,
			"vehicle work hold: r and o wait after a parts change or started work until a read asked after it, "
			+ "with the player free, comes back whole (%s %s %s %s %s %s)" % [at_first, old_kept, busy_kept,
			twice_kept, error_kept, cleared])

## The read's install section for square `at`: three whole types (212 has and fits, 57 has but doesn't fit, 12
## fits but is missing items) and four that aren't whole; `pick` > 0: that type's requirement lines.
static func _install_sample(id: int, pick: int, at := [0, 0]) -> Dictionary:
	var d := _sample(id)
	d.erase("selected")
	d["install"] = {"mount": at, "reason": 0, "text": "", "types_more": 4,
		"types": [[212, 3], [57, 1], [12, 2], [12, 3], "junk", [0, 3], [99, 9]]}
	if pick > 0:
		d["install"]["selected"] = {"cmd": "i", "vpart": pick, "ok": true, "reason": 0, "text": "", "time_s": 300,
			"lines": [{"text": "Time required:", "met": 0}, {"text": "> mechanics 1", "met": 1}]}
	return d


## C6 install: the read's install section cleaned and listed; LiveSession's install read and "i" action; the view's
## install mode (types, pick, square, all types, install, back).
func _test_install(root: Node) -> void:
	var names := func(vp: int) -> String: return {212: "seat", 57: "<color_red>frame</color>"}.get(vp, "")
	var inst: Dictionary = VehicleWorkData.parse_result(JSON.stringify(_install_sample(5, 0)), 5)["install"]
	var picked: Dictionary = VehicleWorkData.parse_result(JSON.stringify(_install_sample(6, 212)), 6)["install"]
	var bad := _install_sample(7, 0)
	bad["install"]["mount"] = [2000, 0]
	var rows := VehicleWorkData.install_rows(inst, names)
	var all := VehicleWorkData.install_rows(inst, names, true)
	var data_ok: bool = inst["mount"] == Vector2i.ZERO and inst["types"].size() == 3 and inst["types_more"] == 8 \
			and inst["selected"].is_empty() and rows.size() == 2 and rows[0]["name"] == "seat" and rows[0]["have"] \
			and rows[1]["name"] == "part #12" and not rows[1]["have"] and all.size() == 3 and all[1]["name"] == "frame" \
			and not all[1]["fits"] and picked["selected"]["vpart"] == 212 and picked["selected"]["ok"] \
			and VehicleWorkData.parse_result(JSON.stringify(bad), 7)["install"].is_empty() \
			and VehicleWorkData.install_refusal(inst) == "" \
			and VehicleWorkData.install_refusal({"reason": 7, "text": ""}) == VehicleWorkData.REASONS[7]
	var sim := WorkSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	var q1 := ls.query_vehicle_work(UID, -1, Vector2i(1, 0))
	ls._work_query = 0
	var q2 := ls.query_vehicle_work(UID, -1, Vector2i(1, 0), 212)
	ls._work_query = 0
	var q_refused := ls.query_vehicle_work(UID, 3, Vector2i(1, 0)) == 0 and ls.query_vehicle_work(UID, -1, Vector2i.MAX, 212) == 0 \
			and ls.query_vehicle_work(UID, -1, Vector2i(1024, 0)) == 0 and ls.query_vehicle_work(UID, -1, Vector2i(1, 0), -1) == 0
	var t := ls.queue_vehicle_work(UID, -1, 212, Vector2i(1, 0), "i")
	var i_refused := ls.queue_vehicle_work(UID, 3, 212, Vector2i(1, 0), "i") == 0
	ls._sim = null
	ls.free()
	var live_ok: bool = q1 > 0 and q2 > 0 and q_refused and i_refused and sim.asked.size() == 2 \
			and sim.asked[0] == {"vehicle": UID, "install": [1, 0]} and sim.asked[1] == {"vehicle": UID, "install": [1, 0], "vpart": 212} \
			and sim.queued == [{"vehicle": UID, "vpart": 212, "mount": [1, 0], "cmd": "i", "tag": t}]
	var asked: Array = []
	var chosen: Array = []
	var v := VehicleWorkView.new()
	v.mouse_hook = func(_m: int) -> int: return Input.MOUSE_MODE_VISIBLE
	v.type_name = names
	v.install_asked.connect(func(at: Vector2i, vp: int) -> void: asked.append([at, vp]))
	v.install_chosen.connect(func(vp: int, at: Vector2i) -> void: chosen.append([vp, at]))
	root.add_child(v)
	v.open(UID)
	v.set_result(VehicleWorkData.parse_result(JSON.stringify(_sample(3)), 3))
	v.select(0)
	v.choose("i")
	var began: bool = v.installing and v.install_at == Vector2i.ZERO and asked == [[Vector2i.ZERO, 0]]
	v.set_result(VehicleWorkData.parse_result(JSON.stringify(_install_sample(4, 0)), 4))
	var listed := v.list_text()
	var early := v.choose("i")   # nothing picked yet
	v.move(1)
	v.set_result(VehicleWorkData.parse_result(JSON.stringify(_install_sample(5, 212)), 5))
	var detail := v.detail_text()
	var sent: bool = v.choose("i")
	v.toggle_all()
	var listed_all := v.list_text()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_RIGHT
	key.shift_pressed = true
	key.pressed = true
	v.handle_key(key)
	var moved: bool = v.install_at == Vector2i(0, 1) and asked.back() == [Vector2i(0, 1), 0] and v.install_pick == 0
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	v.handle_key(esc)
	var back: bool = not v.installing and v.visible and v.selected == 0 and "missing items" not in v.list_text()
	root.remove_child(v)
	v.free()
	var view_ok: bool = began and listed == "  seat\n  part #12  (missing items)" and not early \
			and asked[1] == [Vector2i.ZERO, 212] and sent and chosen == [[212, Vector2i.ZERO]] \
			and "Install with: frame" in detail and "> seat" in detail and "> mechanics 1" in detail and "i:on" in detail \
			and "r:off" in detail and "frame  (doesn't fit here)" in listed_all and moved and back
	_check.call(data_ok and live_ok and view_ok,
			"vehicle work install: the read's install section cleaned and listed (fitting types, names, missing items); "
			+ "the install read and the i action go out in the contract's shape; the view's install mode picks a type, "
			+ "installs it, moves the square, lists all types and goes back (%s %s %s; %s; %s)" % [data_ok, live_ok,
			view_ok, listed, detail])


## C6 mend and refill: "m" and "f" go out like r and o (row, type, mount); CDDA's own menu and item list follow.
func _test_mend_refill() -> void:
	var sim := WorkSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	var tm := ls.queue_vehicle_work(UID, 9, 630, Vector2i(1, -1), "m")
	var tf := ls.queue_vehicle_work(UID, 0, 412, Vector2i.ZERO, "f")
	var no_row := ls.queue_vehicle_work(UID, -1, 630, Vector2i(1, -1), "m") == 0
	ls._sim = null
	ls.free()
	_check.call(tm > 0 and tf > 0 and no_row and sim.queued == [
			{"vehicle": UID, "part": 9, "vpart": 630, "mount": [1, -1], "cmd": "m", "tag": tm},
			{"vehicle": UID, "part": 0, "vpart": 412, "mount": [0, 0], "cmd": "f", "tag": tf}],
			"vehicle work mend and refill: m and f queued with the part's row, type and mount; no row refused (%s)"
			% [sim.queued])


## The work camera's frame_x: the middle of the window left of the view, at 800, 1280 and 1920 wide.
func _test_frame() -> void:
	var at := [VehicleWorkView.free_center(800.0), VehicleWorkView.free_center(1280.0), VehicleWorkView.free_center(1920.0)]
	var left_of_view := true
	for w: float in [800.0, 1280.0, 1920.0]:
		left_of_view = left_of_view and VehicleWorkView.free_center(w) * w < w - VehicleWorkView.width_for(w)
	_check.call(absf(at[0] - 0.265) < 0.01 and absf(at[1] - 0.2906) < 0.01 and absf(at[2] - 0.3604) < 0.01
			and left_of_view and VehicleWorkView.free_center(0.0) == 0.3,
			"vehicle work camera frame: the part centred left of the view (%s)" % [at])


## VehicleWorkSession (main.work, shared with VR's panel): the stand-in without a bridge; with one, the read for what
## the presenter shows, an action from the last read, one at a time, held while busy, its work_result (started,
## or the part moved), and closing when the vehicle is out of reach.
func _test_session(data: Variant) -> void:
	var w := FakeWorld.new()
	w.snapshot = _with_car(data)
	var s := VehicleWorkSession.new()
	s.world = w
	var got: Array = []
	var said: Array = []
	var shut: Array = []
	var seen: Array = []
	s.result.connect(func(r: Dictionary) -> void: got.append(r))
	s.said.connect(func(t: String) -> void: said.append(t))
	s.closed.connect(func(v: int, why: String) -> void: shut.append([v, why]))
	s.part_focused.connect(func(row: int) -> void: seen.append("part %d" % row))
	s.started.connect(func(cmd: String) -> void: seen.append("started " + cmd))
	s.moved.connect(func() -> void: seen.append("moved"))
	s.refused.connect(func(cmd: String, t: String) -> void: seen.append("refused %s: %s" % [cmd, t]))
	# no bridge: the snapshot's stand-in, nothing sent
	w.snapshot = _with_car(data, true)
	var refused: bool = not s.open(UID) and s.note == "The vehicle is out of reach." and not s.open(UID + 1) \
			and s.note == "The vehicle is gone." and got.is_empty() and shut.is_empty()
	w.snapshot = _with_car(data)
	var stand: bool = refused and s.open(UID) and s.note == "" and got.size() == 1 and got[0].get("stand_in") == true
	s.select(1)
	stand = stand and got.size() == 2 and got[1]["selected"]["row"] == 1 and not s.send("o", 1) \
			and said == ["Remove isn't connected to the game yet."] and not s.show_install(Vector2i.ZERO)
	s.follow(_with_car(data, true))
	var away: bool = s.uid == 0 and shut == [[UID, "The vehicle is out of reach."]]
	# with the bridge
	var sim := WorkSim.new()
	var ls := LiveSession.new()
	ls.state = "running"
	ls._sim = sim
	ls.vehicle_work.connect(s.on_read)
	s.live = ls
	got.clear()
	said.clear()
	seen.clear()
	var opened: bool = s.open(UID) and sim.asked[-1] == {"vehicle": UID}
	sim.results[sim.next] = JSON.stringify(_sample(sim.next))
	ls._poll_vehicle_work()
	s.select(9)
	var asked_part: bool = sim.asked[-1] == {"vehicle": UID, "part": 9}
	sim.results[sim.next] = JSON.stringify(_sample(sim.next))
	ls._poll_vehicle_work()
	var sent: bool = s.send("o", 9) and sim.queued.size() == 1 and sim.queued[0]["part"] == 9 \
			and sim.queued[0]["vpart"] == 630 and sim.queued[0]["mount"] == [1, -1] and sim.queued[0]["cmd"] == "o"
	var tag: int = sim.queued[0]["tag"] if not sim.queued.is_empty() else 0
	var once: bool = not s.send("o", 9) and sim.queued.size() == 1 and said.slice(-2) == ["Starting...", "Still starting the last one."]
	s.on_events([{"kind": "message"}, {"kind": "work_result", "uid": UID, "amount": 1, "detail": tag, "text": ""}])
	var began: bool = seen.has("started o") and said[-1] == "Remove started." and s.selected == -1 and s.busy()
	var held: bool = not s.send("r", 9) and sim.queued.size() == 1 and said[-1] == "Not while you're busy."
	var n := sim.asked.size()
	s.follow(w.snapshot)   # the next snapshot: no longer busy, the list is read again before anything goes out
	var reread: bool = not s.busy() and sim.asked.size() == n + 1
	sim.results[sim.next] = JSON.stringify(_sample(sim.next))
	ls._poll_vehicle_work()
	var again: bool = s.send("r", 9) and sim.queued.size() == 2
	s.on_events([{"kind": "work_result", "uid": UID, "amount": 0, "detail": sim.queued[-1]["tag"],
			"text": VehicleWorkData.MOVED}])
	var gone: bool = seen.slice(-2) == ["refused r: " + VehicleWorkData.MOVED, "moved"] and said[-1] == VehicleWorkData.MOVED \
			and sim.asked.size() == n + 2 and s.selected == -1 and str(seen).count("refused") == 1
	sim.results[sim.next] = JSON.stringify(_sample(sim.next))
	ls._poll_vehicle_work()
	var plain: bool = s.send("m", 9) and sim.queued.size() == 3
	s.on_events([{"kind": "work_result", "uid": UID, "amount": 0, "detail": sim.queued[-1]["tag"], "text": ""}])
	plain = plain and seen[-1] == "refused m: Not started." and said[-1] == "Not started."
	s.close()
	ls._sim = null
	ls.free()
	_check.call(stand and away and opened and asked_part and sent and once and began and held and reread and again
			and gone and plain and shut[-1] == [UID, ""] and s.uid == 0,
			"vehicle work session: stand-in without a bridge; the read for what is shown, an action from it, one at a "
			+ "time, held while busy and read again after; started and moved handled; closed out of reach (%s; %s; %s)"
			% [said, seen, shut])
