class_name RecipeMatches
extends RefCounted
## L9: reads a recipe query's result (CddaSim.take_query_result, contracts/bridge_api.md "Recipe queries") into
## plain bounded data for the screen and VR cooking views. The text is the sim's, but it is checked like any
## input: size-capped, wrong types dropped, numbers clamped, text cleaned (no colour tags or control
## characters) and capped, at most MAX_MATCHES matches of MAX_MISSING missing texts each.
##
## parse() gives {} for junk, else {id: int, ok: bool, error: String, container: int (uid), matches: Array of
## {recipe, result, name: String, batch_max: int 0..20, time_s: int (game seconds), known, skills_ok, tools_ok,
## can_start: bool, missing: PackedStringArray}}.

const MAX_BYTES := 72 << 10        # the bridge caps a result at 64 KB
const MAX_MATCHES := 32
const MAX_MISSING := 8
const MAX_TEXT := 128
const MAX_BATCH := 20
const MAX_TIME_S := 365 * 24 * 3600   # a year of game time: past it, the number is junk
const MAX_UID := (1 << 53) - 1
const ERRORS := ["", "out of reach", "not found", "not a container", "internal", "too large"]


static func parse(text: String) -> Dictionary:
	if text.is_empty() or text.length() > MAX_BYTES:
		return {}
	var j := JSON.new()   # parse() returns its error quietly (parse_string logs one)
	if j.parse(text) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	var id := _int(d.get("id"), 1, MAX_UID)
	var container := _int(d.get("container"), 0, MAX_UID)
	if id < 1 or container < 0:
		return {}
	var err: Variant = d.get("error", "")
	var out := {"id": id, "ok": d.get("ok") is bool and d["ok"], "container": container,
			"error": err if err is String and err in ERRORS else "internal", "matches": []}
	if not out["ok"]:
		return out
	var ms: Variant = d.get("matches", [])
	if not ms is Array:
		return out
	for m: Variant in ms:
		if (out["matches"] as Array).size() >= MAX_MATCHES:
			break
		var e := _match(m)
		if not e.is_empty():
			(out["matches"] as Array).append(e)
	return out


## One match, {} when it can't be read (no recipe id).
static func _match(m: Variant) -> Dictionary:
	if not m is Dictionary:
		return {}
	var d: Dictionary = m
	var recipe := _id(d.get("recipe"))
	if recipe.is_empty():
		return {}
	var missing := PackedStringArray()
	var mv: Variant = d.get("missing", [])
	if mv is Array:
		for t: Variant in mv:
			if missing.size() >= MAX_MISSING:
				break
			var s := HudData.clean(t, MAX_TEXT)
			if not s.is_empty():
				missing.append(s)
	var name := HudData.clean(d.get("name", ""), MAX_TEXT)
	return {"recipe": recipe, "result": _id(d.get("result")), "name": name if not name.is_empty() else recipe,
			"batch_max": maxi(_int(d.get("batch_max"), 0, MAX_BATCH), 0),
			"time_s": maxi(_int(d.get("time_s"), 0, MAX_TIME_S), 0),
			"known": _flag(d, "known"), "skills_ok": _flag(d, "skills_ok"), "tools_ok": _flag(d, "tools_ok"),
			"can_start": _flag(d, "can_start"), "missing": missing}


## A CDDA id: letters, digits and _ - . : only, at most MAX_TEXT; "" otherwise.
static func _id(v: Variant) -> String:
	if not v is String or (v as String).is_empty() or (v as String).length() > MAX_TEXT:
		return ""
	for c in (v as String):
		if not (c >= "a" and c <= "z" or c >= "A" and c <= "Z" or c >= "0" and c <= "9" or c in "_-.:"):
			return ""
	return v


static func _flag(d: Dictionary, key: String) -> bool:
	var v: Variant = d.get(key, false)
	return v is bool and v


## An integer from JSON (a float there) within lo..hi; -1 for anything else (not a whole number, NaN, out of
## range).
static func _int(v: Variant, lo: int, hi: int) -> int:
	if v is int:
		return v if v >= lo and v <= hi else -1
	if not v is float or not is_finite(v) or v != floorf(v) or v < float(lo) or v > float(hi):
		return -1
	return int(v)
