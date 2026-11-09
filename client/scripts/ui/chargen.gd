class_name Chargen
extends RefCounted
## Character creation model (no UI): reads the catalog of a `chargen` request (contracts/ui_requests.md),
## keeps the player's choices, computes points like CDDA's own screen and builds the answer JSON. The catalog
## comes from the sim: everything is read defensively and capped. The sim checks the answer again.

const MAX_ITEMS := 4096
const MAX_ID := 128
const MAX_NAME := 200
const MAX_DESC := 4000
const MAX_ANSWER_BYTES := 16384   # the bridge's cap for chargen answers
const STATS := ["str", "dex", "int", "per"]
const STAT_NAMES := {"str": "Strength", "dex": "Dexterity", "int": "Intelligence", "per": "Perception"}
const DEFAULT_BACKGROUND := "adult_basic_background"

var ok := false
var error := ""
# Rules.
var enforce_points := false
var stat_pool := 40
var trait_pool := 0
var skill_pool := 0
var max_trait_points := 12
var min_stat := 4
var max_stat := 20
var high_stat := 12
var skill_costs: Array[int] = [0, 1, 1, 2, 4, 6, 9, 12, 16, 20, 25]
var min_age := 16
var max_age := 55
var min_height := 145
var max_height := 200
var max_name := 64
# Catalog: id -> Dictionary; lists keep the sim's order.
var scenarios: Array[Dictionary] = []
var professions := {}
var backgrounds := {}
var traits := {}
var skills: Array[Dictionary] = []
var default_scenario := ""
var templates: Array[String] = []
# Choices.
var scenario := ""
var profession := ""
var picked_backgrounds: Array[String] = []
var stats := {"str": 8, "dex": 8, "int": 8, "per": 8}
var picked_traits: Array[String] = []
var skill_levels := {}
var char_name := ""
var male := true
var age := 25
var height := 175
## Saves the character as a CDDA template under this name too ("" = don't).
var save_template := ""


static func parse(catalog_json: String) -> Chargen:
	var c := Chargen.new()
	var v: Variant = JSON.parse_string(catalog_json)
	if not v is Dictionary:
		c.error = "catalog is not a JSON object"
		return c
	c._read(v)
	return c


func _read(d: Dictionary) -> void:
	enforce_points = d.get("enforce_points") is bool and d["enforce_points"]
	stat_pool = _int(d, "stat_pool", 40, 0, 1000)
	trait_pool = _int(d, "trait_pool", 0, -1000, 1000)
	skill_pool = _int(d, "skill_pool", 0, -1000, 1000)
	max_trait_points = _int(d, "max_trait_points", 12, 0, 1000)
	min_stat = _int(d, "min_stat", 4, 1, 100)
	max_stat = _int(d, "max_stat", 20, min_stat, 100)
	high_stat = _int(d, "high_stat", 12, min_stat, 100)
	min_age = _int(d, "min_age", 16, 0, 200)
	max_age = _int(d, "max_age", 55, min_age, 200)
	min_height = _int(d, "min_height", 145, 1, 1000)
	max_height = _int(d, "max_height", 200, min_height, 1000)
	max_name = _int(d, "max_name", 64, 1, 256)
	var costs: Variant = d.get("skill_costs")
	if costs is Array and not (costs as Array).is_empty() and (costs as Array).size() <= 32:
		skill_costs.clear()
		for x: Variant in costs:
			skill_costs.append(clampi(int(x), 0, 1000) if (x is int or x is float) else 0)
	for s: Variant in _list(d, "scenarios"):
		var e := _entry(s)
		if not e.is_empty():
			for key: String in ["professions", "backgrounds", "extra_traits", "forbidden_traits", "locked_traits"]:
				e[key] = _ids(s, key)
			e["default_background"] = not (s.get("default_background") is bool) or s["default_background"]
			e["start_name"] = _str(s, "start_name", MAX_NAME)
			scenarios.append(e)
	for key: String in ["professions", "backgrounds"]:
		var into: Dictionary = professions if key == "professions" else backgrounds
		for p: Variant in _list(d, key):
			var e := _entry(p)
			if e.is_empty():
				continue
			e["name_female"] = _str(p, "name_female", MAX_NAME)
			e["locked_traits"] = _ids(p, "locked_traits")
			var sk := {}
			var raw: Variant = p.get("skills")
			if raw is Dictionary:
				for k: Variant in raw:
					if k is String and _id_ok(k) and sk.size() < 64:
						sk[k] = clampi(int(raw[k]), 0, 100) if (raw[k] is int or raw[k] is float) else 0
			e["skills"] = sk
			into[e["id"]] = e
	for t: Variant in _list(d, "traits"):
		var e := _entry(t)
		if e.is_empty():
			continue
		e["starting"] = t.get("starting") is bool and t["starting"]
		e["cancels"] = _ids(t, "cancels")
		e["types"] = _ids(t, "types")
		traits[e["id"]] = e
	for s: Variant in _list(d, "skills"):
		var e := _entry(s)
		if not e.is_empty():
			skills.append(e)
	default_scenario = _str(d, "default_scenario", MAX_ID)
	for t: String in _ids(d, "templates"):
		if template_name_ok(t) and templates.size() < 256:
			templates.append(t)
	if scenarios.is_empty():
		error = "the catalog has no scenarios"
		return
	ok = true
	set_scenario(default_scenario if scenario_entry(default_scenario) != null else scenarios[0]["id"])


# --- Catalog lookups ---------------------------------------------------------------------------------

func scenario_entry(id: String) -> Variant:
	for s in scenarios:
		if s["id"] == id:
			return s
	return null


func scen() -> Dictionary:
	var s: Variant = scenario_entry(scenario)
	return s if s != null else {}


## Professions the current scenario allows, in catalog order.
func allowed_professions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in scen().get("professions", []):
		if professions.has(id):
			out.append(professions[id])
	return out


func allowed_backgrounds() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in scen().get("backgrounds", []):
		if backgrounds.has(id):
			out.append(backgrounds[id])
	return out


## Traits the scenario lists: starting traits plus its extras (forbidden ones too, shown as unavailable).
func listed_traits() -> Array[Dictionary]:
	var extra: Array = scen().get("extra_traits", [])
	var out: Array[Dictionary] = []
	for id: String in traits:
		var t: Dictionary = traits[id]
		if t["starting"] or extra.has(id):
			out.append(t)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	return out


## Traits given by the scenario, profession and backgrounds (free, can't be removed).
func locked_traits() -> Array[String]:
	var out: Array[String] = []
	for id: String in scen().get("locked_traits", []):
		out.append(id)
	if professions.has(profession):
		for id: String in professions[profession]["locked_traits"]:
			if not out.has(id):
				out.append(id)
	for b in picked_backgrounds:
		if backgrounds.has(b):
			for id: String in backgrounds[b]["locked_traits"]:
				if not out.has(id):
					out.append(id)
	return out


# --- Choices -----------------------------------------------------------------------------------------

## Picks a scenario and resets what depends on it, like CDDA's screen (profession, backgrounds, traits).
func set_scenario(id: String) -> bool:
	var s: Variant = scenario_entry(id)
	if s == null:
		return false
	scenario = id
	profession = ""
	var best := 1 << 30
	for p in allowed_professions():
		if p["points"] < best:
			best = p["points"]
			profession = p["id"]
	picked_backgrounds.clear()
	if (s["default_background"] and (s["backgrounds"] as Array).has(DEFAULT_BACKGROUND)
			and backgrounds.has(DEFAULT_BACKGROUND)):
		picked_backgrounds.append(DEFAULT_BACKGROUND)
	picked_traits.clear()
	for k: String in STATS:
		stats[k] = 8
	skill_levels.clear()
	return true


func set_profession(id: String) -> bool:
	if not (scen().get("professions", []) as Array).has(id) or not professions.has(id):
		return false
	profession = id
	_drop_bad_traits()
	return true


func toggle_background(id: String) -> bool:
	if picked_backgrounds.has(id):
		picked_backgrounds.erase(id)
		return true
	if not (scen().get("backgrounds", []) as Array).has(id) or not backgrounds.has(id):
		return false
	picked_backgrounds.append(id)
	_drop_bad_traits()
	return true


func set_stat(key: String, value: int) -> bool:
	if not stats.has(key) or value < min_stat or value > max_stat:
		return false
	stats[key] = value
	return true


func set_skill(id: String, level: int) -> bool:
	if not _skill_known(id) or level < 0 or level >= skill_costs.size():
		return false
	if level == 0:
		skill_levels.erase(id)
	else:
		skill_levels[id] = level
	return true


## Why trait `id` can't be added now ("" if it can).
func trait_blocker(id: String) -> String:
	if not traits.has(id):
		return "unknown trait"
	var t: Dictionary = traits[id]
	if not (t["starting"] or (scen().get("extra_traits", []) as Array).has(id)):
		return "not available in this scenario"
	if locked_traits().has(id):
		return "given by your scenario, profession or background"
	if (scen().get("forbidden_traits", []) as Array).has(id):
		return "the scenario forbids it"
	for other: String in picked_traits + locked_traits():
		if other != id and conflicts(id, other):
			return "conflicts with " + (traits[other]["name"] if traits.has(other) else other)
	if enforce_points:
		var pts: int = t["points"]
		var good := 0
		var bad := 0
		for p in picked_traits:
			var q: int = traits[p]["points"] if traits.has(p) else 0
			if q > 0:
				good += q
			else:
				bad += q
		if pts > 0 and good + pts > max_trait_points:
			return "too many advantage points"
		if pts < 0 and bad + pts < -max_trait_points:
			return "too many disadvantage points"
	return ""


func conflicts(a: String, b: String) -> bool:
	if not traits.has(a) or not traits.has(b):
		return false
	var ta: Dictionary = traits[a]
	var tb: Dictionary = traits[b]
	if (ta["cancels"] as Array).has(b) or (tb["cancels"] as Array).has(a):
		return true
	for ty: String in ta["types"]:
		if (tb["types"] as Array).has(ty):
			return true
	return false


func toggle_trait(id: String) -> bool:
	if picked_traits.has(id):
		picked_traits.erase(id)
		return true
	if not trait_blocker(id).is_empty():
		return false
	picked_traits.append(id)
	return true


func set_name(n: String) -> void:
	char_name = n.strip_edges().left(max_name)


func set_age(a: int) -> void:
	age = clampi(a, min_age, max_age)


func set_height(h: int) -> void:
	height = clampi(h, min_height, max_height)


## Random profession, stats and name ("" = the sim picks one); keeps the scenario.
func randomize_choices(rng: RandomNumberGenerator) -> void:
	var profs := allowed_professions()
	if not profs.is_empty():
		profession = profs[rng.randi_range(0, profs.size() - 1)]["id"]
	for k: String in STATS:
		stats[k] = clampi(rng.randi_range(6, high_stat - 2), min_stat, max_stat)
	picked_traits.clear()
	skill_levels.clear()
	male = rng.randi_range(0, 1) == 0
	char_name = ""
	_drop_bad_traits()


# --- Points (newcharacter.cpp) -------------------------------------------------------------------------

func stat_points_used() -> int:
	var used := 0
	for k: String in STATS:
		used += stats[k] + maxi(0, stats[k] - high_stat)
	return used


func trait_points_used() -> int:
	var used := 0
	var locked := locked_traits()
	for id in picked_traits:
		if traits.has(id) and not locked.has(id):
			used += traits[id]["points"]
	return used


func skill_points_used() -> int:
	var used: int = scen().get("points", 0)
	if professions.has(profession):
		used += professions[profession]["points"]
	for b in picked_backgrounds:
		if backgrounds.has(b):
			used += backgrounds[b]["points"]
	for id: String in skill_levels:
		used += skill_costs[clampi(skill_levels[id], 0, skill_costs.size() - 1)]
	return used


func points_left() -> int:
	return stat_pool + trait_pool + skill_pool - stat_points_used() - trait_points_used() - skill_points_used()


## "" if the choices can be sent, else why not (the sim checks again).
func problem() -> String:
	if not ok:
		return error
	if not professions.has(profession):
		return "pick a profession"
	if enforce_points:
		var ps := stat_pool - stat_points_used()
		var pt := trait_pool - trait_points_used()
		var pk := skill_pool - skill_points_used()
		if ps + mini(0, pt + mini(0, pk)) < 0 or ps + pt + mini(0, pk) < 0 or ps + pt + pk < 0:
			return "not enough points"
	if char_name.begins_with("#"):
		return "the name can't start with #"
	if not save_template.is_empty() and not template_name_ok(save_template):
		return "template names are letters, digits, spaces, _ or -"
	return ""


## Like the sim's rule: 1-64 of letters, digits, space, _ -, no space at either end.
static func template_name_ok(n: String) -> bool:
	if n.is_empty() or n.length() > 64 or n.strip_edges() != n:
		return false
	for c in n:
		if not (c >= "a" and c <= "z" or c >= "A" and c <= "Z" or c >= "0" and c <= "9" or c in [" ", "_", "-"]):
			return false
	return true


## The answer `text` that starts from template `t` (one of `templates`), with `char_name` if set; "" if unknown.
func template_answer(t: String) -> String:
	if not templates.has(t):
		return ""
	return JSON.stringify({"template": t, "name": char_name})


## The answer `text` for the sim, or "" if it would be too long.
func answer_json() -> String:
	var sk := {}
	for id: String in skill_levels:
		sk[id] = skill_levels[id]
	var d := {
		"scenario": scenario, "profession": profession, "backgrounds": picked_backgrounds.duplicate(),
		"str": stats["str"], "dex": stats["dex"], "int": stats["int"], "per": stats["per"],
		"traits": picked_traits.duplicate(), "skills": sk, "name": char_name, "male": male,
		"age": age, "height": height,
	}
	if not save_template.is_empty():
		d["save_template"] = save_template
	var s := JSON.stringify(d)
	return s if s.to_utf8_buffer().size() <= MAX_ANSWER_BYTES else ""


func profession_name(id: String) -> String:
	var p: Dictionary = professions.get(id, backgrounds.get(id, {}))
	if p.is_empty():
		return id
	return p["name_female"] if not male and not (p["name_female"] as String).is_empty() else p["name"]


# --- Reading helpers ------------------------------------------------------------------------------------

func _skill_known(id: String) -> bool:
	for s in skills:
		if s["id"] == id:
			return true
	return false


func _drop_bad_traits() -> void:
	var locked := locked_traits()
	var keep: Array[String] = []
	for id in picked_traits:
		if locked.has(id):
			continue
		picked_traits = keep
		if trait_blocker(id).is_empty():
			keep.append(id)
	picked_traits = keep


static func _id_ok(s: String) -> bool:
	return not s.is_empty() and s.length() <= MAX_ID


static func _str(d: Variant, key: String, max_chars: int) -> String:
	if not d is Dictionary:
		return ""
	var v: Variant = (d as Dictionary).get(key)
	return (v as String).left(max_chars) if v is String else ""


static func _int(d: Dictionary, key: String, default: int, lo: int, hi: int) -> int:
	var v: Variant = d.get(key)
	if v is int or (v is float and is_finite(v)):
		return clampi(int(v), lo, hi)
	return default


static func _list(d: Dictionary, key: String) -> Array:
	var v: Variant = d.get(key)
	if not v is Array:
		return []
	return (v as Array).slice(0, MAX_ITEMS)


## {id, name, description, points} or {} if the entry is unusable.
static func _entry(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var id := _str(v, "id", MAX_ID + 1)
	if not _id_ok(id):
		return {}
	var name := _str(v, "name", MAX_NAME)
	var pts: Variant = (v as Dictionary).get("points")
	return {"id": id, "name": name if not name.is_empty() else id, "description": _str(v, "description", MAX_DESC),
			"points": clampi(int(pts), -1000, 1000) if (pts is int or (pts is float and is_finite(pts))) else 0}


static func _ids(d: Variant, key: String) -> Array[String]:
	var out: Array[String] = []
	if not d is Dictionary:
		return out
	var v: Variant = (d as Dictionary).get(key)
	if not v is Array:
		return out
	for x: Variant in v:
		if out.size() >= MAX_ITEMS:
			break
		if x is String and _id_ok(x):
			out.append(x)
	return out
