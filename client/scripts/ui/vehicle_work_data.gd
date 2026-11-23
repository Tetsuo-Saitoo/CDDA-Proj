class_name VehicleWorkData
extends RefCounted
## C6 vehicle work (lead-ui, 2026-11-22): the bridge's vehicle-work read (contracts/vehicle_work.md:
## CddaSim.query_vehicle_work, its result through take_query_result) checked and cleaned for VehicleWorkView; and a
## stand-in built from the snapshot, for the mock and for a game whose bridge doesn't answer the read yet.
## The result is game data: every field is checked, text is one plain line and cut, lists are capped, and an entry
## that isn't whole is left out (never a failed read).

const MAX_RESULT_BYTES := 72 << 10   # the bridge keeps a result under 64 KB
const MAX_QUERY_ID := (1 << 53) - 1
const MAX_UID := (1 << 53) - 1
const MAX_ROW := Snapshot.MAX_VEHICLE_PARTS - 1
const MAX_PARTS := 512
const MAX_FAULTS := 8
const MAX_HERE := 32
const MAX_LINES := 64
const MAX_NAME := 60
const MAX_TEXT := 200
const MAX_VARIANT := 64
const MAX_DAMAGE := 100
const MAX_TIME_S := 365 * 24 * 3600
const MAX_TURN := (1 << 53) - 1

## Part flags (a part's `flags`).
const BROKEN := 1
const REPAIRABLE := 2
const FAULTY := 4
const REFILLABLE := 8
const ON_RACK := 16
const ALL_FLAGS := 31

## A requirement line's `met`.
const NOTE := 0
const MET := 1
const NOT_MET := 2

## The commands per part, in the bridge's order: CDDA's own keys.
const COMMANDS: PackedStringArray = ["r", "o", "m", "f"]
const COMMAND_NAMES := {"r": "Repair", "o": "Remove", "m": "Mend", "f": "Refill", "i": "Install"}
## CDDA's task_reason (veh_interact.h) in words, for a refusal without its own sentence.
const REASONS: PackedStringArray = ["", "Nothing to do on this part.", "Missing tools.", "Something is attached to it.",
		"Not enough skill.", "The vehicle is moving.", "Your morale is too low.", "It's too dark to see."]
const ERRORS: PackedStringArray = ["no such vehicle", "too far", "no such part", "internal", "too large",
		"an appliance"]
## The commands the vehicle_work action takes so far (contracts/vehicle_work.md "The action").
const ACTION_CMDS: PackedStringArray = ["r", "o"]
const MAX_TAG := (1 << 31) - 1
const MAX_EVENT_TEXT := 200


## A vehicle-work result's text (CddaSim.take_query_result) for query `id`: {ok: true, vehicle, name, turn, parts,
## parts_more, selected, truncated} or {ok: false, vehicle, error}, cleaned; {} when it isn't one (too big, not
## JSON, another id or kind).
static func parse_result(text: Variant, id: int) -> Dictionary:
	if not text is String or (text as String).is_empty() or (text as String).length() > MAX_RESULT_BYTES:
		return {}
	var j := JSON.new()   # parse() returns its error quietly (parse_string logs one)
	if j.parse(text) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	if id < 1 or _int(d.get("id"), 1, MAX_QUERY_ID) != id or d.get("kind") != "vehicle_work" or not d.get("ok") is bool:
		return {}
	return clean(d)


## The read's Dictionary, checked (see parse_result).
static func clean(d: Dictionary) -> Dictionary:
	var uid: Variant = _int(d.get("vehicle"), 1, MAX_UID)
	if d.get("ok") != true:
		var e: Variant = d.get("error")
		return {"ok": false, "vehicle": uid if uid != null else 0, "error": e if e is String and e in ERRORS else "internal"}
	if uid == null:
		return {"ok": false, "vehicle": 0, "error": "internal"}
	var parts: Array[Dictionary] = []
	var rows := {}
	var dropped := 0
	var raw: Variant = d.get("parts")
	if raw is Array:
		for p: Variant in (raw as Array).slice(0, MAX_PARTS):
			var c := _part(p)
			if c.is_empty() or rows.has(c["row"]):
				dropped += 1
				continue
			rows[c["row"]] = parts.size()
			parts.append(c)
		dropped += maxi((raw as Array).size() - MAX_PARTS, 0)
	var more: Variant = _int(d.get("parts_more"), 0, Snapshot.MAX_VEHICLE_PARTS)
	var sel := _selected(d.get("selected"), rows)
	var turn: Variant = _int(d.get("turn"), 0, MAX_TURN)
	return {"ok": true, "vehicle": uid, "name": Snapshot.plain_text(d.get("name"), MAX_NAME),
			"turn": turn if turn != null else 0, "owned": d.get("owned") != false, "parts": parts, "rows": rows,
			"parts_more": (more if more != null else 0) + dropped, "selected": sel, "truncated": d.get("truncated") == true}


## A `work_result` event (contracts/events.md) answering the vehicle_work action tagged `tag`: {started, vehicle,
## text (CDDA's reason when refused; "" when started or the player said no)}; {} for another tag, kind or junk.
static func work_result(ev: Variant, tag: int) -> Dictionary:
	if not ev is Dictionary or (ev as Dictionary).get("kind") != "work_result" or tag < 1:
		return {}
	var d: Dictionary = ev
	var amount: Variant = _int(d.get("amount"), 0, 1)
	if _int(d.get("detail"), 1, MAX_TAG) != tag or amount == null:
		return {}
	var uid: Variant = _int(d.get("uid"), 0, MAX_UID)
	return {"started": amount == 1, "vehicle": uid if uid != null else 0,
			"text": Snapshot.plain_text(d.get("text"), MAX_EVENT_TEXT)}


## The part entry with row `row` in a cleaned result, {} when it has none.
static func part_of(r: Dictionary, row: int) -> Dictionary:
	var rows: Dictionary = r.get("rows", {})
	return r["parts"][rows[row]] if rows.has(row) else {}


## The command `cmd` of a cleaned result's `selected`, {} when it has none.
static func command_of(r: Dictionary, cmd: String) -> Dictionary:
	var sel: Dictionary = r.get("selected", {})
	for c: Dictionary in sel.get("commands", []):
		if c["cmd"] == cmd:
			return c
	return {}


## Why a command can't be done, in words: CDDA's sentence, else its task_reason, else the first line not met; ""
## when it can.
static func refusal(c: Dictionary) -> String:
	if c.is_empty():
		return "Not available."
	if c["ok"]:
		return ""
	if not (c["text"] as String).is_empty():
		return c["text"]
	if c["reason"] > 0:
		return REASONS[c["reason"]]
	for l: Dictionary in c["lines"]:
		if l["met"] == NOT_MET:   # a requirement ("> ...") is missing; CDDA's own red sentence is said as it is
			var t: String = l["text"]
			return "Missing: %s" % t.trim_prefix("> ") if t.begins_with("> ") else t
	return "Not possible now."


## A stand-in for the read, built from snapshot `snap` (part names from `tables`): the parts of vehicle `uid`, and
## for `part` simple commands (repair when damaged or broken, remove, refill a tank). Marked `stand_in`: CDDA's
## own checks aren't in it. {ok: false, error} as the bridge would answer for a vehicle that isn't there or is
## farther than one square.
static func stand_in(snap: Snapshot, tables: IdTables, uid: int, part := -1) -> Dictionary:
	var veh: Snapshot.Vehicle = null
	if snap != null:
		for v in snap.vehicles:
			if v.uid == uid:
				veh = v
				break
	if veh == null:
		return {"ok": false, "vehicle": uid, "error": "no such vehicle"}
	if not in_reach(snap, veh):
		return {"ok": false, "vehicle": uid, "error": "too far"}
	var d := {"id": 1, "ok": true, "kind": "vehicle_work", "vehicle": uid, "name": veh.name, "turn": 0, "owned": true,
			"parts": []}
	for i in mini(veh.part_count(), MAX_PARTS):
		var k := i * Snapshot.VPART_STRIDE
		var state := veh.parts[k + 4]
		if (state & Snapshot.VPART_FILLER) != 0:
			continue
		var hp := roundi(veh.parts[k + 3] * 100.0 / 255.0)
		var broken := (state & Snapshot.VPART_BROKEN) != 0
		var flags := (BROKEN if broken else 0) | (REPAIRABLE if not broken and hp < 100 else 0) \
				| (REFILLABLE if _tank(snap, tables, veh.parts[k + 2]) else 0)
		var def := VehicleView.def_of(tables, snap, veh.parts[k + 2])
		(d["parts"] as Array).append({"row": i, "mount": [veh.parts[k], veh.parts[k + 1]], "vpart": veh.parts[k + 2],
				"name": def.name if def != null and not def.name.is_empty() else "part", "variant": "", "hp": hp,
				"damage": 0 if hp >= 100 else 1 + int((100 - hp) / 25.0), "flags": flags})
	var r := clean(d)
	var p := part_of(r, part)
	if not p.is_empty():
		var here: Array = []
		var at: Array = snap.vehicle_at(veh.square(part))
		for i: int in (at[1] if at.size() == 2 else PackedInt32Array([part])):
			if (r["rows"] as Dictionary).has(i):
				here.append(i)
		var f: int = p["flags"]
		var fix := (f & (BROKEN | REPAIRABLE)) != 0
		r["selected"] = {"row": part, "here": PackedInt32Array(here.slice(0, MAX_HERE)), "commands": [
			_cmd("r", fix, 0 if fix else 1, 1800 if fix else 0, [["Time required:", NOTE], ["> 30 minutes", NOTE]] if fix else []),
			_cmd("o", true, 0, 600, [["Time required:", NOTE], ["> 10 minutes", NOTE]]),
			_cmd("m", false, 1, 0, []),
			_cmd("f", (f & REFILLABLE) != 0, 0 if (f & REFILLABLE) != 0 else 1, 0, [])]}
	r["stand_in"] = true
	return r


## Whether a part of `veh` is on the player's square or next to it on the player's level (CDDA's rule for
## examining a vehicle, as the bridge checks it).
static func in_reach(snap: Snapshot, veh: Snapshot.Vehicle) -> bool:
	if snap == null or veh == null:
		return false
	for i in veh.part_count():
		var d := veh.square(i) - snap.player_pos
		if d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1:
			return true
	return false


## The vehicle work could be done on from where the player stands: the one at `prefer` (a pointed-at square) when
## it is in reach, else the first in reach; null for none.
static func vehicle_near(snap: Snapshot, prefer := Vector3i.MAX) -> Snapshot.Vehicle:
	if snap == null:
		return null
	if prefer != Vector3i.MAX:
		var at: Array = snap.vehicle_at(prefer)
		if at.size() == 2 and in_reach(snap, at[0]):
			return at[0]
	for v in snap.vehicles:
		if in_reach(snap, v):
			return v
	return null


static func _tank(snap: Snapshot, tables: IdTables, vpart: int) -> bool:
	var def := VehicleView.def_of(tables, snap, vpart)
	return def != null and (def.flags.has("FUEL_TANK") or def.flags.has("BATTERY"))


static func _cmd(cmd: String, ok: bool, reason: int, time_s: int, lines: Array) -> Dictionary:
	var out: Array[Dictionary] = []
	for l: Array in lines:
		out.append({"text": l[0], "met": l[1]})
	return {"cmd": cmd, "ok": ok, "reason": reason, "text": "", "time_s": time_s, "lines": out}


static func _part(p: Variant) -> Dictionary:
	if not p is Dictionary:
		return {}
	var d: Dictionary = p
	var row: Variant = _int(d.get("row"), 0, MAX_ROW)
	var m: Variant = d.get("mount")
	var mx: Variant = _int(m[0], -Snapshot.MAX_MOUNT, Snapshot.MAX_MOUNT) if m is Array and (m as Array).size() == 2 else null
	var my: Variant = _int(m[1], -Snapshot.MAX_MOUNT, Snapshot.MAX_MOUNT) if m is Array and (m as Array).size() == 2 else null
	if row == null or mx == null or my == null:
		return {}
	var vpart: Variant = _int(d.get("vpart"), 0, Snapshot.MAX_ID)
	var hp: Variant = _int(d.get("hp"), 0, 100)
	var dmg: Variant = _int(d.get("damage"), 0, MAX_DAMAGE)
	var flags: Variant = _int(d.get("flags"), 0, (1 << 31) - 1)
	var faults := PackedStringArray()
	var fv: Variant = d.get("faults")
	if fv is Array:
		for f: Variant in (fv as Array).slice(0, MAX_FAULTS):
			var s := Snapshot.plain_text(f, MAX_NAME)
			if not s.is_empty():
				faults.append(s)
	var name := Snapshot.plain_text(d.get("name"), MAX_NAME)
	return {"row": row, "mount": Vector2i(mx, my), "vpart": vpart if vpart != null else -1,
			"name": name if not name.is_empty() else "part", "variant": _variant(d.get("variant")),
			"hp": hp if hp != null else 0, "damage": dmg if dmg != null else 0,
			"flags": (flags if flags != null else 0) & ALL_FLAGS, "faults": faults}


static func _selected(v: Variant, rows: Dictionary) -> Dictionary:
	if not v is Dictionary:
		return {}
	var d: Dictionary = v
	var row: Variant = _int(d.get("row"), 0, MAX_ROW)
	if row == null or not rows.has(row):
		return {}
	var here := PackedInt32Array()
	var hv: Variant = d.get("here")
	if hv is Array:
		for h: Variant in (hv as Array).slice(0, MAX_HERE):
			var r: Variant = _int(h, 0, MAX_ROW)
			if r != null and rows.has(r) and not here.has(r):
				here.append(r)
	if not here.has(row):
		here.append(row)
	var cmds: Array[Dictionary] = []
	var cv: Variant = d.get("commands")
	if cv is Array:
		for c: Variant in (cv as Array).slice(0, COMMANDS.size() * 2):
			var k := _command(c)
			if not k.is_empty() and cmds.all(func(o: Dictionary) -> bool: return o["cmd"] != k["cmd"]):
				cmds.append(k)
	return {"row": row, "here": here, "commands": cmds}


static func _command(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var d: Dictionary = v
	var cmd: Variant = d.get("cmd")
	var reason: Variant = _int(d.get("reason"), 0, REASONS.size() - 1)
	if not cmd is String or not cmd in COMMANDS or not d.get("ok") is bool:
		return {}
	var lines: Array[Dictionary] = []
	var lv: Variant = d.get("lines")
	if lv is Array:
		for l: Variant in (lv as Array).slice(0, MAX_LINES):
			if l is Dictionary:
				var met: Variant = _int((l as Dictionary).get("met"), NOTE, NOT_MET)
				var t := Snapshot.plain_text((l as Dictionary).get("text"), MAX_TEXT)
				if not t.is_empty():
					lines.append({"text": t, "met": met if met != null else NOTE})
	var time: Variant = _int(d.get("time_s"), 0, MAX_TIME_S)
	# an unknown reason is a refusal: never offer work the sim didn't say it can do
	return {"cmd": cmd, "ok": d["ok"] and reason == 0, "reason": reason if reason != null else 1,
			"text": Snapshot.plain_text(d.get("text"), MAX_TEXT), "time_s": time if time != null else 0, "lines": lines}


static func _variant(v: Variant) -> String:
	if not v is String or (v as String).length() > MAX_VARIANT:
		return ""
	for c in (v as String):
		var u := c.unicode_at(0)
		if u < 0x20 or u > 0x7e:
			return ""
	return v


static func _int(v: Variant, lo: int, hi: int) -> Variant:
	if v is int:
		return v if v >= lo and v <= hi else null
	if not v is float or is_nan(v) or is_inf(v) or v != floorf(v) or v < lo or v > hi:
		return null
	return int(v)
