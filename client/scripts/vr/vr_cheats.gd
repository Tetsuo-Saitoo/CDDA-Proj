class_name VrCheats
extends RefCounted
## K7: the VR menu's Cheats page (VrMenu) without any UI. A drop-in match for lead-ui's CheatModel
## (hud/cheat_model.gd: rows / read / apply, same keys, labels and order), so the VR page can switch to it later.
## `backend` is a LiveSession or a stand-in, used duck-typed (has_method): this branch's LiveSession has no cheat
## methods yet, so `available` is false and the page stays hidden until they land. Nothing is kept here: rows are
## built from what the sim says each time (backend.cheats() asks the bridge). Cheat names come from the sim:
## checked, bounded, and an unknown one is shown by its name.

## The flat F1 page's wording (CheatModel.LABELS), in its order.
const LABELS := {
	"invincible": "No damage (can't die)",
	"no_needs": "No hunger, thirst or sleepiness",
	"no_weight_limit": "No weight limit",
	"unlimited_ammo": "Unlimited ammo (wielded gun)",
	"stamina": "Unlimited stamina",
	"no_temperature": "No heat or cold",
	"night_vision": "Night vision (also reveals the map)",
	AUTO_PAUSE: "Auto-pause on hostiles (real time)",
	TEST_KIT: "Give test kit",
}
## The bridge's cheats in the flat page's order (LiveSession.CHEATS).
const ORDER: PackedStringArray = ["invincible", "no_needs", "no_weight_limit", "unlimited_ammo", "stamina",
		"no_temperature", "night_vision"]
const AUTO_PAUSE := "auto_pause"
const TEST_KIT := "test_kit"
const TOGGLE := "toggle"
const ACTION := "action"
const WARN := Color(1.0, 0.75, 0.3)   # amber: the cheat warning and markers
const MAX_NAME := 64     # characters of a cheat name from the sim
const LABEL_MAX := 40    # characters of an unknown cheat's label
const MAX_EXTRA := 5     # unknown cheats shown after the known ones
const MAX_KEYS := 64     # entries of a cheats reply looked at
const MAX_MARKED := 16   # names in a HUD marker

static var _warned := false


## The menu may show the page: the backend can list, set and give.
static func available(backend: Variant) -> bool:
	return is_instance_valid(backend) and (backend as Object).has_method("cheats") \
			and (backend as Object).has_method("set_cheat") and (backend as Object).has_method("give_test_kit")


## A name the sim may use: 1..MAX_NAME of a-z, 0-9 and _.
static func valid_name(n: String) -> bool:
	if n.is_empty() or n.length() > MAX_NAME:
		return false
	for c in n:
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true


## A cheats reply ({name: bool}) checked: valid names only, non-bools off, at most MAX_KEYS looked at.
static func clean(d: Variant) -> Dictionary:
	var out := {}
	if not d is Dictionary:
		if d != null:
			_warn("cheats reply is not a dictionary")
		return out
	var keys: Array = (d as Dictionary).keys()
	if keys.size() > MAX_KEYS:
		_warn("cheats reply has %d entries, looking at %d" % [keys.size(), MAX_KEYS])
		keys = keys.slice(0, MAX_KEYS)
	for k: Variant in keys:
		if not (k is String or k is StringName) or not valid_name(str(k)):
			_warn("skipped a bad cheat name")
			continue
		var v: Variant = (d as Dictionary)[k]
		out[str(k)] = v if v is bool else false
	return out


## [{key, label, on, kind: "toggle" | "action", enabled}]: the known cheats in ORDER, then up to MAX_EXTRA
## others the sim named (by name), then the auto-pause toggle, then the test-kit action. `cheats` is
## backend.cheats(): {} (no running game) greys every row out. Only real bools count as on.
static func rows(cheats: Dictionary, auto_pause: bool) -> Array[Dictionary]:
	var c := clean(cheats)
	var live := not c.is_empty()
	var out: Array[Dictionary] = []
	for n: String in ORDER:
		out.append(_row(n, live and c.get(n, false) == true, TOGGLE, live))
	var extra: Array = c.keys().filter(func(n: String) -> bool: return not n in ORDER)
	extra.sort()
	for n: String in extra.slice(0, MAX_EXTRA):
		out.append(_row(n, c[n] == true, TOGGLE, live))
	out.append(_row(AUTO_PAUSE, live and auto_pause, TOGGLE, live))
	out.append(_row(TEST_KIT, false, ACTION, live))
	return out


## The rows as the sim has them now (no usable backend: every row greyed out; no auto-pause: that row greyed).
static func read(backend: Variant) -> Array[Dictionary]:
	if not available(backend):
		return rows({}, false)
	var b := backend as Object
	var c := clean(b.call("cheats"))
	var can_pause := b.has_method("auto_pause") and b.has_method("set_auto_pause")
	var ap: Variant = b.call("auto_pause") if can_pause and not c.is_empty() else false
	var out := rows(c, ap is bool and ap)
	if not can_pause:
		out[out.size() - 2]["enabled"] = false
	return out


## Does a row: a cheat or auto-pause set to `on`, the test kit given (one per call; `on` unused). False when the
## backend refused (no running game), can't, or the key is no cheat name.
static func apply(backend: Variant, key: String, on := true) -> bool:
	if not is_instance_valid(backend):
		return false
	var b := backend as Object
	var r: Variant = false
	if key == TEST_KIT:
		if b.has_method("give_test_kit"):
			r = b.call("give_test_kit")
	elif key == AUTO_PAUSE:
		if b.has_method("set_auto_pause"):
			r = b.call("set_auto_pause", on)
	elif valid_name(key) and b.has_method("set_cheat"):
		r = b.call("set_cheat", key, on)
	return r is bool and r


## The menu's press on row `key`: a toggle goes to the opposite of what the backend says now (read fresh), the
## kit is asked for. {ok, text}: text is the short line the page shows ("Invincible: on next turn", or why not).
static func use(backend: Variant, key: String) -> Dictionary:
	var all := read(backend)
	var row := {}
	for r: Dictionary in all:
		if r["key"] == key:
			row = r
			break
	var what := "No test kit" if key == TEST_KIT else "Not changed"
	if row.is_empty():
		return {"ok": false, "text": what + ": no such cheat now"}
	if not row["enabled"]:
		return {"ok": false, "text": what + (": no running game" if not all[0]["enabled"] else ": not supported")}
	var on: bool = row["kind"] == ACTION or not row["on"]
	if not apply(backend, key, on):
		return {"ok": false, "text": what + ": the game said no"}
	if key == TEST_KIT:
		return {"ok": true, "text": "Test kit: next turn"}
	if key == AUTO_PAUSE:
		return {"ok": true, "text": "Auto-pause on hostiles: " + ("on" if on else "off")}
	return {"ok": true, "text": "%s: %s next turn" % [short_name(key), "on" if on else "off"]}


## A cheat name as a short word: "night_vision" -> "Night vision", bounded.
static func short_name(n: String) -> String:
	var s := n.replace("_", " ").left(LABEL_MAX)
	return s.left(1).to_upper() + s.substr(1)


## The wrist marker for HudData.cheats (names on): "CHEATS: invincible, night vision", "" for none or bad data.
static func marker(names: Variant) -> String:
	if not (names is PackedStringArray or names is Array):
		return ""
	var list: Array = names if names is Array else Array(names as PackedStringArray)
	var words := PackedStringArray()
	for n: Variant in list.slice(0, MAX_MARKED):
		if n is String and valid_name(n):
			words.append((n as String).replace("_", " "))
	return "" if words.is_empty() else "CHEATS: " + ", ".join(words)


static func _row(n: String, on: bool, kind: String, enabled: bool) -> Dictionary:
	var label: String = LABELS[n] if LABELS.has(n) else n.replace("_", " ").left(LABEL_MAX)
	return {"key": n, "label": label, "on": on, "kind": kind, "enabled": enabled}


static func _warn(what: String) -> void:
	if not _warned:
		_warned = true
		push_warning("VR cheats: " + what + " (skipped; said once)")
