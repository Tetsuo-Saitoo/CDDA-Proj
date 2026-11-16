extends RefCounted
## Block G4: CharacterData (the character screen's cards from HudData and the bridge's sheet, hostile sheet data
## cleaned and capped) and CharacterView (P opens and closes it, Esc closes it, rebuilt only while shown, the
## mouse mode put back). Run by run_tests.gd.

var _check: Callable


func run(check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("character screen")
	var snap := Snapshot.from_data(data)
	if not snap.is_valid():
		_check.call(false, "character screen: the mock town loads (%s)" % snap.error)
		return
	var hud := HudData.new()
	hud.update(snap, tables)
	var cd := CharacterData.new()
	var fired := [0]
	cd.changed.connect(func() -> void: fired[0] += 1)
	cd.update(hud)
	var ids := cd.cards.map(func(c: Dictionary) -> String: return c["id"])
	_check.call(fired[0] == 1 and "body" in ids and "needs" in ids and not "stats" in ids and not "skills" in ids
			and cd.note == CharacterData.NO_SHEET and cd.title == "Character" and not cd.has_sheet()
			and (cd.card("body")["rows"] as Array).size() == hud.body.size()
			and (cd.card("needs")["rows"] as Array).all(func(r: Dictionary) -> bool: return not (r["value"] as String).is_valid_int()),
			"character screen: without the game's sheet, the snapshot's cards and a note (%s)" % [ids])
	cd.set_sheet(_sheet())
	ids = cd.cards.map(func(c: Dictionary) -> String: return c["id"])
	var stats: Array = cd.card("stats")["rows"]
	var labels := stats.map(func(r: Dictionary) -> String: return r["label"] + "=" + r["value"])
	_check.call(cd.has_sheet() and cd.note.is_empty() and cd.title == "Ana Red" and cd.subtitle == "Medic, age 30, 170 cm"
			and ids.slice(0, 2) == ["stats", "body"] and ids.back() == "speed"
			and labels == ["Strength=7 (base 8)", "Dexterity=8", "Intelligence=0", "Perception=1000 (base 8)", "Speed=95"]
			and stats[0]["level"] == HudData.HURT and stats[1]["level"] == HudData.UNKNOWN and stats[4]["level"] == HudData.HURT,
			"character screen: the sheet's name, stats in CDDA's order, a bad number clamped, unknown stats left out (%s)" % [labels])
	var skills: Array = cd.card("skills")["rows"]
	var traits: Array = cd.card("traits")["rows"]
	var bionics: Array = cd.card("bionics")["rows"]
	var prof: Array = cd.card("proficiencies")["rows"]
	_check.call(skills.size() == 64 and skills[0]["label"] == "Melee" and skills[0]["value"] == "2 (40%)"
			and skills[0]["level"] == HudData.OK and skills[1]["value"] == "0" and (skills[0]["tip"] as String).length() == CharacterData.MAX_TIP
			and traits.size() == 2 and traits[0]["level"] == HudData.OK and traits[1]["level"] == HudData.HURT
			and traits[1]["value"] == "mutation" and bionics[0]["value"] == "50 / 100 kJ" and bionics[1]["value"] == "on"
			and prof.size() == 2 and prof[1]["value"] == "25%",
			"character screen: skills (capped at 64, progress, long descriptions cut), traits by rating, bionics and power, proficiencies")
	var all_text := JSON.stringify(cd.cards) + cd.title + cd.subtitle
	var clean := all_text.find("<color") < 0 and all_text.find(char(7)) < 0 and all_text.find("Hidden") < 0
	_check.call(clean and (cd.card("speed")["rows"] as Array).size() == 1 and cd.card("effects").is_empty() == hud.effects.is_empty(),
			"character screen: colour tags and control characters dropped, entries of the wrong type skipped")
	cd.set_sheet("not a dictionary")
	_check.call(not cd.has_sheet() and cd.card("stats").is_empty() and cd.note == CharacterData.NO_SHEET,
			"character screen: a sheet that isn't a Dictionary is dropped")
	cd.set_sheet(_sheet())
	_test_view(cd)


func _test_view(cd: CharacterData) -> void:
	var mode := [Input.MOUSE_MODE_CAPTURED]
	var v := CharacterView.new()
	v.mouse_hook = func(set_to: int) -> int:
		if set_to >= 0:
			mode[0] = set_to
		return mode[0]
	v.data = cd
	var idle: bool = v.text().is_empty() and not v.visible
	v.handle_key(_key(KEY_P))
	var shown := v.text()
	var opened: bool = (v.visible and mode[0] == Input.MOUSE_MODE_VISIBLE and shown.begins_with("[Stats]")
			and shown.find("Strength: 7 (base 8)") >= 0 and shown.find("[Skills]") >= 0)
	var tip_ok := _first_tip(v) != ""
	v.handle_key(_key(KEY_ESCAPE))
	var esc_closed: bool = not v.visible and mode[0] == Input.MOUSE_MODE_CAPTURED
	cd.set_sheet({})
	var kept := v.text() == shown   # hidden: not rebuilt
	v.handle_key(_key(KEY_P))
	var reopened: bool = v.visible and v.text().find("[Stats]") < 0
	var used_closed: bool = v.handle_key(_key(KEY_P)) and not v.visible
	var not_allowed: bool = not v.handle_key(_key(KEY_P), false) and not v.visible
	_check.call(idle and opened and tip_ok and esc_closed and kept and reopened and used_closed and not_allowed,
			"character screen: hidden until P, cards with tooltips, Esc and P close it and give the mouse back, rebuilt only while shown")
	v.free()


static func _first_tip(v: CharacterView) -> String:
	for l: Node in v.find_children("*", "Label", true, false):
		if not (l as Label).tooltip_text.is_empty():
			return (l as Label).tooltip_text
	return ""


static func _key(code: Key) -> InputEventKey:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	return k


## A sheet as the bridge would send it, with hostile bits: colour tags, control characters, wrong types, too many
## entries, numbers out of range.
static func _sheet() -> Dictionary:
	var skills: Array = [{"id": "melee", "name": "<color_white>Melee</color>", "level": 2, "progress": 40,
			"description": "x".repeat(2000)}, {"id": "dodge", "name": "Dodge", "level": 0, "progress": 0}]
	for i in 100:
		skills.append({"id": "s%d" % i, "name": "Skill %d" % i, "level": i % 3, "progress": 0})
	skills.append("Hidden skill as a string")
	return {
		"name": "<color_red>Ana Red</color>" + char(7), "profession": "Medic", "age": 30, "height_cm": 170.0,
		"stats": [{"id": "per", "cur": 1e9, "base": 8}, {"id": "str", "cur": 7, "base": 8}, {"id": "dex", "cur": 8, "base": 8},
				{"id": "int", "cur": "nine", "base": 0}, {"id": "luck", "cur": 3, "base": 3}, "Hidden"],
		"speed": {"cur": 95, "modifiers": [{"name": "Pain", "value": -5}, {"name": "Nothing", "value": 0}, ["Hidden", 3]]},
		"skills": skills,
		"proficiencies": {"known": [{"name": "Wound care", "description": "Basics."}],
				"learning": [{"name": "Splinting", "percent": 25}]},
		"traits": [{"name": "Fast learner", "rating": 1}, {"name": "Night blindness", "rating": -5, "mutation": true}],
		"bionics": [{"name": "Flashlight", "active": true}],
		"power": {"cur_kj": 50, "max_kj": 100},
		"effect_descriptions": {"stunned": "You can't move straight."},
	}
