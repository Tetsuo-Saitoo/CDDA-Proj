class_name WorldSetup
extends RefCounted
## New-world settings model (no UI): reads a `world_setup` request's catalog (contracts/ui_requests.md), keeps
## slider levels, setting values and the mod list, and builds the answer JSON. The catalog comes from the sim:
## read defensively and capped; the sim checks the answer again.

const MAX_ITEMS := 1024
const MAX_ID := 128
const MAX_TEXT := 4000
const MAX_ANSWER_BYTES := 16384

var ok := false
var error := ""
## [{id, name, default, levels: [{name, description}]}]
var sliders: Array[Dictionary] = []
## [{id, name, group, tooltip, type, value, min, max, step, choices: [[value, name]], max_length}]
var options: Array[Dictionary] = []
## id -> {id, name, description, category, core, dependencies, conflicts}
var mods := {}
var mod_order: Array[String] = []
# Choices.
var levels := {}       # slider id -> level
var values := {}       # option id -> value (only changed ones are sent)
var picked_mods: Array[String] = []


static func parse(catalog_json: String) -> WorldSetup:
	var w := WorldSetup.new()
	var v: Variant = JSON.parse_string(catalog_json)
	if not v is Dictionary:
		w.error = "catalog is not a JSON object"
		return w
	w._read(v)
	return w


func _read(d: Dictionary) -> void:
	for s: Variant in _list(d, "sliders"):
		if not s is Dictionary or not _id_ok(s.get("id")):
			continue
		var lv: Array[Dictionary] = []
		for l: Variant in _list(s, "levels"):
			lv.append({"name": _str(l, "name", 200), "description": _str(l, "description", MAX_TEXT)})
		if lv.is_empty():
			continue
		var e := {"id": s["id"], "name": _str(s, "name", 200), "levels": lv,
				"default": clampi(_num(s, "default", 0), 0, lv.size() - 1)}
		sliders.append(e)
		levels[e["id"]] = e["default"]
	for o: Variant in _list(d, "options"):
		if not o is Dictionary or not _id_ok(o.get("id")):
			continue
		var type := _str(o, "type", 32)
		var e := {"id": o["id"], "name": _str(o, "name", 200), "group": _str(o, "group", 200),
				"tooltip": _str(o, "tooltip", MAX_TEXT), "type": type}
		var val: Variant = o.get("value")
		match type:
			"bool":
				e["value"] = val if val is bool else false
			"int", "float":
				var lo := float(_num(o, "min", 0)) if type == "int" else _numf(o, "min", 0.0)
				var hi := float(_num(o, "max", 0)) if type == "int" else _numf(o, "max", 0.0)
				if hi < lo:
					continue
				e["min"] = lo
				e["max"] = hi
				e["step"] = 1.0 if type == "int" else maxf(_numf(o, "step", 0.1), 0.0001)
				e["value"] = clampf(_numf(o, "value", lo), lo, hi)
			"int_map", "string_select":
				var choices := []
				for c: Variant in _list(o, "choices"):
					if c is Array and c.size() == 2 and c[1] is String:
						if type == "int_map" and (c[0] is int or c[0] is float):
							choices.append([int(c[0]), (c[1] as String).left(200)])
						elif type == "string_select" and c[0] is String:
							choices.append([(c[0] as String).left(MAX_ID), (c[1] as String).left(200)])
				if choices.is_empty():
					continue
				e["choices"] = choices
				e["value"] = int(val) if type == "int_map" and (val is int or val is float) else (
						val if val is String else choices[0][0])
			"string_input":
				e["max_length"] = clampi(_num(o, "max_length", 64), 1, 256)
				e["value"] = (val as String).left(e["max_length"]) if val is String else ""
			_:
				continue
		options.append(e)
	for m: Variant in _list(d, "mods"):
		if not m is Dictionary or not _id_ok(m.get("id")):
			continue
		var e := {"id": m["id"], "name": _str(m, "name", 200), "description": _str(m, "description", MAX_TEXT),
				"category": _str(m, "category", 200), "core": m.get("core") is bool and m["core"],
				"dependencies": _ids(m, "dependencies"), "conflicts": _ids(m, "conflicts")}
		if not mods.has(e["id"]):
			mods[e["id"]] = e
			mod_order.append(e["id"])
	for id: String in _ids(d, "default_mods"):
		if mods.has(id) and not picked_mods.has(id):
			picked_mods.append(id)
	ok = true


func option(id: String) -> Dictionary:
	for o in options:
		if o["id"] == id:
			return o
	return {}


func value_of(id: String) -> Variant:
	return values.get(id, option(id).get("value"))


func set_level(slider_id: String, level: int) -> bool:
	for s in sliders:
		if s["id"] == slider_id and level >= 0 and level < (s["levels"] as Array).size():
			levels[slider_id] = level
			return true
	return false


## Sets a setting; false (and nothing changes) if the value doesn't fit its type and range.
func set_value(id: String, v: Variant) -> bool:
	var o := option(id)
	if o.is_empty():
		return false
	match o["type"]:
		"bool":
			if not v is bool:
				return false
		"int":
			if not (v is int or v is float) or float(v) != floorf(float(v)) or float(v) < o["min"] or float(v) > o["max"]:
				return false
			v = int(v)
		"float":
			if not (v is int or v is float) or not is_finite(float(v)) or float(v) < o["min"] or float(v) > o["max"]:
				return false
			v = float(v)
		"int_map", "string_select":
			var found := false
			for c: Array in o["choices"]:
				if c[0] == v:
					found = true
			if not found:
				return false
		"string_input":
			if not v is String:
				return false
			v = (v as String).left(o["max_length"])
	values[id] = v
	return true


## Ticks or unticks a mod. Ticking adds its dependencies; unticking drops mods that need it. A second core
## mod replaces the first (a world has one).
func toggle_mod(id: String) -> bool:
	if not mods.has(id):
		return false
	if picked_mods.has(id):
		_untick(id)
		return true
	if not conflict_of(id).is_empty():
		return false
	if mods[id]["core"]:
		for other in picked_mods.duplicate():
			if mods.has(other) and mods[other]["core"]:
				_untick(other)
	_tick(id, 0)
	return true


## The picked mod `id` conflicts with, or "".
func conflict_of(id: String) -> String:
	if not mods.has(id):
		return ""
	for p in picked_mods:
		if not mods.has(p):
			continue
		if (mods[id]["conflicts"] as Array).has(p) or (mods[p]["conflicts"] as Array).has(id):
			return p
	return ""


func problem() -> String:
	if not ok:
		return error
	var cores := 0
	for p in picked_mods:
		if mods.has(p) and mods[p]["core"]:
			cores += 1
	if cores != 1:
		return "pick one core mod (e.g. Dark Days Ahead)"
	return ""


func answer_json() -> String:
	var opts := {}
	for id: String in values:
		opts[id] = values[id]
	var s := JSON.stringify({"sliders": levels.duplicate(), "options": opts, "mods": picked_mods.duplicate()})
	return s if s.to_utf8_buffer().size() <= MAX_ANSWER_BYTES else ""


func _tick(id: String, depth: int) -> void:
	if depth > 32 or picked_mods.has(id) or not mods.has(id):
		return
	for dep: String in mods[id]["dependencies"]:
		_tick(dep, depth + 1)
	picked_mods.append(id)


func _untick(id: String) -> void:
	picked_mods.erase(id)
	for other in picked_mods.duplicate():
		if mods.has(other) and (mods[other]["dependencies"] as Array).has(id):
			_untick(other)


# --- Reading helpers ------------------------------------------------------------------------------------

static func _id_ok(v: Variant) -> bool:
	return v is String and not (v as String).is_empty() and (v as String).length() <= MAX_ID


static func _str(d: Variant, key: String, max_chars: int) -> String:
	if not d is Dictionary:
		return ""
	var v: Variant = (d as Dictionary).get(key)
	return (v as String).left(max_chars) if v is String else ""


static func _num(d: Variant, key: String, default: int) -> int:
	var v: Variant = (d as Dictionary).get(key) if d is Dictionary else null
	if v is int or (v is float and is_finite(v)):
		return clampi(int(v), -1000000000, 1000000000)
	return default


static func _numf(d: Variant, key: String, default: float) -> float:
	var v: Variant = (d as Dictionary).get(key) if d is Dictionary else null
	if (v is int or v is float) and is_finite(float(v)):
		return clampf(float(v), -1e9, 1e9)
	return default


static func _list(d: Variant, key: String) -> Array:
	var v: Variant = (d as Dictionary).get(key) if d is Dictionary else null
	return (v as Array).slice(0, MAX_ITEMS) if v is Array else []


static func _ids(d: Variant, key: String) -> Array[String]:
	var out: Array[String] = []
	for x: Variant in _list(d, key):
		if _id_ok(x):
			out.append(x)
	return out
