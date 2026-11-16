class_name VrRange
extends RefCounted
## K7: the VR menu's Test range page (VrMenu) without any UI, like VrCheats for the Cheats page. `backend` is the
## LiveSession (lead-ui's range API: in_range, range_info, range_teleport, range_set_time, range_advance,
## range_set_ai_frozen, range_heal; signals range_changed, range_done) or a stand-in, used duck-typed: without
## those methods, or outside a range game, `available` is false and the menu hides the page. Nothing is kept here:
## rows are built from range_info each time, which is read like any input from the sim (checked, capped, cleaned).
## Each operation returns the backend's op id (0 = refused); the result comes later as range_done(op_id, error).
## Spawning: no keyboard in the headset, so a short fixed list of test items (at the feet) and monsters (two squares
## ahead of where the head looks), each shown only when the game's id tables have it (SpawnSearch, lead-ui's search:
## the exact id, its cleaned name) and the backend has range_spawn_item / range_spawn_monster. Any other type: the
## flat F1 Cheats page's search.

const TOGGLE := "toggle"
const ACTION := "action"
const FREEZE := "freeze"
const HEAL := "heal"
const WAIT := "wait_hour"
const GO := "go_"          # + zone index: teleport there
const TIME := "time_"      # + hour of the day: set the time
const SPAWN_ITEM := "item_"    # + index into ITEMS: spawn it at the feet
const SPAWN_MON := "mon_"      # + index into MONSTERS: spawn it ahead
## [CDDA item id, how many]: things a test wants at hand. Ids the tables don't have are left out.
const ITEMS := [["rock", 1], ["2x4", 1], ["backpack", 1], ["glock_19", 1], ["9mm", 15], ["bandages", 3],
		["water_clean", 1], ["can_beans", 1]]
const MONSTERS := ["mon_zombie", "mon_zombie_dog", "mon_zombie_brute", "mon_zombie_soldier", "mon_dog"]
const AHEAD := 2           # squares ahead a monster spawns
const STEPS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0),
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]
## The flat page's set time (Hour spin box) as a few fixed hours.
const HOURS: Array[int] = [6, 12, 18, 0]
const WAIT_MIN := 60
const MAX_ZONES := 64      # zones looked at (the range has 58; the bridge's list is capped at 128)
const NAME_MAX := 24       # characters of a zone name on the page
const MAX_OP_ID := (1 << 53) - 1
const METHODS: PackedStringArray = ["in_range", "range_info", "range_teleport", "range_set_time", "range_advance",
		"range_set_ai_frozen", "range_heal"]

static var _warned := false


## The menu may show the page: the backend has the range methods and a range game is running.
static func available(backend: Variant) -> bool:
	if not is_instance_valid(backend):
		return false
	var b := backend as Object
	for m in METHODS:
		if not b.has_method(m):
			return false
	var r: Variant = b.call("in_range")
	return r is bool and r


## range_info checked: {zones: [{index, name, built}] (at most MAX_ZONES looked at; bad entries skipped, their
## index kept), zone: index the character is in (-1 none), ai_frozen: bool}.
static func clean_info(d: Variant) -> Dictionary:
	var out := {"zones": [], "zone": -1, "ai_frozen": false}
	if not d is Dictionary:
		if d != null:
			_warn("range info is not a dictionary")
		return out
	var src: Dictionary = d
	var f: Variant = src.get("ai_frozen", false)
	out["ai_frozen"] = f is bool and f
	var zs: Variant = src.get("zones", [])
	if not zs is Array:
		_warn("range zones are not a list")
		return out
	var list: Array = zs
	if list.size() > MAX_ZONES:
		_warn("range info has %d zones, showing %d" % [list.size(), MAX_ZONES])
	var zones: Array = []
	for i in mini(list.size(), MAX_ZONES):
		var z: Variant = list[i]
		if not z is Dictionary:
			_warn("skipped a bad zone")
			continue
		var n: Variant = (z as Dictionary).get("name", "")
		var name := InventoryModel.clean(n, NAME_MAX) if n is String else ""
		var built: Variant = (z as Dictionary).get("built", false)
		zones.append({"index": i, "name": name if not name.is_empty() else "Zone %d" % (i + 1),
				"built": built is bool and built})
	out["zones"] = zones
	var here: Variant = src.get("zone", -1)
	if (here is int or (here is float and is_finite(here) and here == floorf(here))) and int(here) >= 0 \
			and int(here) < mini(list.size(), MAX_ZONES):
		out["zone"] = int(here)
	return out


## [{key, label, kind: "toggle" | "action", on, enabled, zone}]: the monster freeze, heal, wait an hour and the set
## times (the flat page's controls, its wording), with `tables` the spawn rows (spawn_rows), then one "Go to" per zone
## in the range's order (the zone the character is in marked "here", one not built yet marked so: going there builds
## it). `zone` is the zone index for a "Go to" row (which also has `name` and `here`), else -1. `info` is range_info().
static func rows_from(info: Variant, tables: IdTables = null, spawns := true) -> Array[Dictionary]:
	var c := clean_info(info)
	var out: Array[Dictionary] = []
	out.append(_row(FREEZE, "Monsters frozen", TOGGLE, c["ai_frozen"]))
	out.append(_row(HEAL, "Heal", ACTION))
	out.append(_row(WAIT, "Wait 1 hour", ACTION))
	for h in HOURS:
		out.append(_row(TIME + str(h), "Set time %d:00" % h, ACTION))
	if spawns:
		out.append_array(spawn_rows(tables))
	for z: Dictionary in c["zones"]:
		var i: int = z["index"]
		var mark := " (here)" if i == c["zone"] else ("" if z["built"] else " (not built yet)")
		var r := _row(GO + str(i), "Go to: %s%s" % [z["name"], mark], ACTION)
		r["zone"] = i
		r["name"] = z["name"]
		r["here"] = i == c["zone"]
		out.append(r)
	return out


## The spawn rows the id tables allow: "Spawn at feet: <name>" per ITEMS id they list, "Spawn ahead: <name>" per
## MONSTERS id they list (and RangeInfo.monster_id_ok); each also has `type` (the table index), `id`, `count`.
static func spawn_rows(tables: IdTables) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if tables == null:
		return out
	for k in ITEMS.size():
		var f := _found(tables, "itype", ITEMS[k][0])
		if not f.is_empty():
			var count: int = ITEMS[k][1]
			var r := _row(SPAWN_ITEM + str(k), "Spawn at feet: %s%s" % [f["name"], " x%d" % count if count > 1 else ""], ACTION)
			r.merge({"type": f["index"], "id": f["id"], "count": count})
			out.append(r)
	for k in MONSTERS.size():
		var f := _found(tables, "mtype", MONSTERS[k])
		if not f.is_empty() and RangeInfo.monster_id_ok(f["id"]):
			var r := _row(SPAWN_MON + str(k), "Spawn ahead: %s" % f["name"], ACTION)
			r.merge({"type": f["index"], "id": f["id"], "count": 1})
			out.append(r)
	return out


## SpawnSearch's best for `id` when it is that very id: {index, id, name}; {} when the tables don't list it.
static func _found(tables: IdTables, table: String, id: String) -> Dictionary:
	var f := SpawnSearch.find(tables, table, id, 1)
	if f.is_empty() or f[0].get("id") != id or int(f[0].get("index", 0)) < 1:
		return {}
	var name := InventoryModel.clean(str(f[0].get("name", "")), NAME_MAX)
	return {"index": int(f[0]["index"]), "id": id, "name": name if not name.is_empty() else id}


## The rows as the backend has them now; [] when the page may not show. With `tables` the spawn rows too, when the
## backend can spawn.
static func rows(backend: Variant, tables: IdTables = null) -> Array[Dictionary]:
	if not available(backend):
		return []
	var b := backend as Object
	return rows_from(b.call("range_info"), tables, b.has_method("range_spawn_item") and b.has_method("range_spawn_monster"))


## The square `AHEAD` squares from `player` the way a head with basis `b` looks (one of the 8 directions; looking
## straight down: the way the top of the head points).
static func ahead_of(player: Vector3i, b: Basis) -> Vector3i:
	var f := -b.z
	f.y = 0.0
	if f.length() < 0.01:
		f = b.y
		f.y = 0.0
	if f.length() < 0.01:
		f = Vector3.FORWARD
	var k := posmod(roundi(atan2(f.z, f.x) / (PI / 4.0)), 8)
	var s := STEPS[k] * AHEAD
	return player + Vector3i(s.x, s.y, 0)


## A "Go to" key's zone index, -1 for any other key.
static func zone_of(key: String) -> int:
	if not key.begins_with(GO):
		return -1
	var s := key.substr(GO.length())
	if not s.is_valid_int() or s.length() > 3:
		return -1
	var i := s.to_int()
	return i if i >= 0 and i < MAX_ZONES else -1


static func is_teleport(key: String) -> bool:
	return zone_of(key) >= 0


## Does row `key`: the freeze goes to the opposite of what range_info says now. A spawn row needs `where`:
## {tables: IdTables, feet: Vector3i (items), ahead: Vector3i (monsters)}. The backend's op id, 0 when it refused or
## the key is no row.
static func apply(backend: Variant, key: String, where := {}) -> int:
	if not available(backend):
		return 0
	var b := backend as Object
	var v: Variant = 0
	var zone := zone_of(key)
	if key.begins_with(SPAWN_ITEM) or key.begins_with(SPAWN_MON):
		var t: Variant = where.get("tables")
		var row := {}
		for r: Dictionary in spawn_rows(t if t is IdTables else null):
			if r["key"] == key:
				row = r
		var sq: Variant = where.get("feet" if key.begins_with(SPAWN_ITEM) else "ahead")
		if row.is_empty() or not sq is Vector3i or not b.has_method("range_spawn_item") or not b.has_method("range_spawn_monster"):
			return 0
		if key.begins_with(SPAWN_ITEM):
			v = b.call("range_spawn_item", row["type"], row["count"], sq)
		else:
			v = b.call("range_spawn_monster", row["id"], sq)
	elif zone >= 0:
		v = b.call("range_teleport", zone)
	elif key == FREEZE:
		v = b.call("range_set_ai_frozen", not clean_info(b.call("range_info"))["ai_frozen"])
	elif key == HEAL:
		v = b.call("range_heal")
	elif key == WAIT:
		v = b.call("range_advance", WAIT_MIN)
	elif key.begins_with(TIME) and key.substr(TIME.length()).is_valid_int() and key.substr(TIME.length()).to_int() in HOURS:
		v = b.call("range_set_time", key.substr(TIME.length()).to_int() * 60)
	return op_id(v)


## The menu's press on row `key`: {id: op id (0 refused), text: what was asked, as the flat page says it ("Go to
## Hub", "Monsters frozen", "Heal", ...)}.
static func use(backend: Variant, key: String, where := {}) -> Dictionary:
	var row := {}
	var t: Variant = where.get("tables")
	for r: Dictionary in rows(backend, t if t is IdTables else null):
		if r["key"] == key:
			row = r
			break
	if row.is_empty():
		return {"id": 0, "text": "Not sent: no range game" if not available(backend) else "Not sent: no such row"}
	var text: String = row["label"]
	if row["zone"] >= 0:
		text = "Go to " + str(row["name"])
	elif key == FREEZE:
		text = "Monsters moving" if row["on"] else "Monsters frozen"
	elif key.begins_with(TIME):
		text = "Time " + text.trim_prefix("Set time ")
	elif row.has("id"):
		text = "Spawn " + str(row["id"])
	return {"id": apply(backend, key, where), "text": text}


## An op id from the backend: a whole number 1..MAX_OP_ID, else 0.
static func op_id(v: Variant) -> int:
	if v is float and (not is_finite(v) or v != floorf(v) or absf(v) > float(MAX_OP_ID)):
		return 0
	if not (v is int or v is float):
		return 0
	var i := int(v)
	return i if i >= 1 and i <= MAX_OP_ID else 0


static func _row(key: String, label: String, kind: String, on := false) -> Dictionary:
	return {"key": key, "label": label, "kind": kind, "on": on, "enabled": true, "zone": -1}


static func _warn(what: String) -> void:
	if not _warned:
		_warned = true
		push_warning("VR range: " + what + " (skipped; said once)")
