class_name RangeInfo
extends RefCounted
## K7 test range: CddaSim.get_range_info() read into bounded plain data (contracts/bridge_api.md "Test range"),
## and the argument rules of the range_* operations, checked here before anything is sent. The sim's reply is
## treated like any input: wrong types dropped, numbers range-checked, text cleaned and capped.
##
## clean() gives {} for junk, else {range: bool, ai_frozen: bool, zone: int (-1 none), zones: Array of {id, name,
## kind: String, built: bool}, results: Array of {id: int, error: String}}.

const MAX_ZONES := 128
const MAX_RESULTS := 16
const MAX_NAME := 64
const MAX_ERROR := 200
const MINUTES_PER_DAY := 1440
const MAX_ADVANCE := 10080          # a week, in minutes
const MAX_COUNT := 1000
const MAX_MONSTER_ID := 64
const MAX_OP_ID := (1 << 53) - 1


static func clean(d: Variant) -> Dictionary:
	if not d is Dictionary:
		return {}
	var src: Dictionary = d
	var zones: Array = []
	var zs: Variant = src.get("zones", [])
	if zs is Array:
		for z: Variant in zs:
			if zones.size() >= MAX_ZONES:
				break
			if not z is Dictionary:
				continue
			var zd: Dictionary = z
			var id: Variant = zd.get("id", "")
			var ids := HudData.clean(id, MAX_NAME) if id is String else (str(int(id)) if _whole(id) else "")
			var name := HudData.clean(zd.get("name", ""), MAX_NAME)
			zones.append({"id": ids, "name": name if not name.is_empty() else "Zone %d" % (zones.size() + 1),
					"kind": HudData.clean(zd.get("kind", ""), MAX_NAME), "built": _flag(zd, "built")})
	var zone := -1
	var zv: Variant = src.get("zone", -1)
	if _whole(zv) and int(zv) >= 0 and int(zv) < zones.size():
		zone = int(zv)
	var results: Array = []
	var rs: Variant = src.get("results", [])
	if rs is Array:
		for r: Variant in (rs as Array).slice(-MAX_RESULTS):
			if not r is Dictionary or not _whole((r as Dictionary).get("id")):
				continue
			var rid := int((r as Dictionary)["id"])
			if rid < 1 or rid > MAX_OP_ID:
				continue
			var err: Variant = (r as Dictionary).get("error", "")
			var text := HudData.clean(err, MAX_ERROR) if err is String else "refused"
			if err is String and not (err as String).is_empty() and text.is_empty():
				text = "refused"   # an error made only of tags or control characters still is one
			results.append({"id": rid, "error": text})
	return {"range": _flag(src, "range"), "ai_frozen": _flag(src, "ai_frozen"), "zone": zone, "zones": zones,
			"results": results}


## A CDDA monster id range_spawn_monster takes: 1..64 of a-z A-Z 0-9 _ -.
static func monster_id_ok(id: String) -> bool:
	if id.is_empty() or id.length() > MAX_MONSTER_ID:
		return false
	for c in id:
		if not (c >= "a" and c <= "z" or c >= "A" and c <= "Z" or c >= "0" and c <= "9" or c == "_" or c == "-"):
			return false
	return true


static func _flag(d: Dictionary, key: String) -> bool:
	var v: Variant = d.get(key, false)
	return v is bool and v


## A whole number from the sim (int, or a float with no fraction), not NaN.
static func _whole(v: Variant) -> bool:
	if v is int:
		return true
	return v is float and is_finite(v) and v == floorf(v) and absf(v) <= float(MAX_OP_ID)
