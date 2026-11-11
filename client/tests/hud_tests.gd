extends RefCounted
## G1 / L4: HudData (the HUD's data for the screen and VR views): body parts and their levels, CDDA's need words,
## what the hands hold, the message feed (cleaned, capped), warnings, `changed` groups. Run by run_tests.gd.

var _check: Callable


func run(check: Callable, tables: IdTables) -> void:
	_check = check
	print("hud data")
	_test_words()
	_test_body_and_held(tables)
	_test_needs()
	_test_effects(tables)
	_test_messages()
	_test_view(tables)
	_test_move(tables)


## player.move_mode: the id tables name it, HudData words it, running says how much stamina is left once it runs
## low, HudView shows it first in the needs column.
func _test_move(tables: IdTables) -> void:
	_check.call(tables.move_modes == PackedStringArray(["", "crouch", "prone", "run", "walk"])
			and tables.move_mode_name(4) == "walk" and tables.move_mode_name(5) == "" and tables.move_mode_name(-1) == "",
			"move: the id tables name the move modes")
	var base := {"generation": 0, "ter": [], "furn": [], "trap": [], "field": [], "itype": []}
	var ok := base.duplicate(true)
	ok["tables"] = {"body_part": ["torso"]}
	var bad := base.duplicate(true)
	bad["tables"] = {"move_mode": "walk"}
	var junk := base.duplicate(true)
	junk["tables"] = {"move_mode": [5]}
	_check.call(IdTables.from_data(ok).is_valid() and IdTables.from_data(ok).move_modes.is_empty()
			and not IdTables.from_data(bad).is_valid() and not IdTables.from_data(junk).is_valid(),
			"move: no move_mode list is fine, a malformed one fails the tables")
	var none := {"level": HudData.UNKNOWN}
	var low := {"value": 20, "word": "", "level": HudData.HURT}
	var out := {"value": 0, "word": "", "level": HudData.BAD}
	var full := {"value": 80, "word": "", "level": HudData.OK}
	_check.call(HudData.move_from(4, tables, none) == {"mode": "walk", "text": "Walking", "level": HudData.OK}
			and HudData.move_from(1, tables, low)["text"] == "Crouching" and HudData.move_from(2, tables, out)["text"] == "Prone"
			and HudData.move_from(3, tables, none)["text"] == "Running" and HudData.move_from(3, tables, full)["text"] == "Running"
			and HudData.move_from(3, tables, low) == {"mode": "run", "text": "Running (stamina 20%)", "level": HudData.HURT}
			and HudData.move_from(3, tables, out) == {"mode": "run", "text": "Running: out of stamina", "level": HudData.BAD},
			"move: CDDA's mode in words; running mentions stamina once it runs low or out")
	_check.call(HudData.move_from(0, tables, none).is_empty() and HudData.move_from(9, tables, none).is_empty()
			and HudData.move_from(-1, tables, none).is_empty() and HudData.move_from("3", tables, none).is_empty()
			and HudData.move_from(3, null, none).is_empty(), "move: unknown index, no tables or not an int: nothing shown")
	var h := HudData.new()
	var v := HudView.new()
	v.data = h
	var seen: Array = []
	h.changed.connect(func(p: PackedStringArray) -> void: seen.append(p))
	var s := Snapshot.new()
	h.update(s, tables)
	_check.call(h.move.is_empty() and v.move_line().is_empty() and seen.is_empty(), "move: not sent, no line")
	s.player_move_mode = 3
	s.player_stamina = 5
	s.player_stamina_max = 100
	h.update(s, tables)
	_check.call(v.move_line() == ["Running (stamina 5%)", HudData.BAD] and seen.size() == 1 and "move" in seen[0],
			"hud view: the move line, coloured by stamina while running (%s)" % [v.move_line()])
	h.update(s, tables)
	s.player_move_mode = 4
	h.update(s, tables)
	_check.call(seen.size() == 2 and "move" in seen[1] and v.move_line() == ["Walking", HudData.OK],
			"move: changed only when the line changes")
	v.free()


## player.effects: Snapshot cleans them (bad entries skipped, never a failed snapshot), HudData shows the ones the
## body bars and needs don't (hunger_* gives the hunger word), HudView lists at most EFFECT_LINES.
func _test_effects(tables: IdTables) -> void:
	var arm := tables.body_parts.find("arm_l")
	var raw: Array = [
		{"id": "stunned", "name": "<color_red>Stun" + String.chr(0x202E) + "ned</color>\n", "body_part": 0.0, "intensity": 1.0, "rating": -1.0,
			"seconds_left": 300.0},
		{"id": "drunk", "name": "", "rating": 2, "seconds_left": -1},
		{"id": "high", "name": "High", "rating": 1, "seconds_left": 1e30},
		{"id": "bad_rating", "rating": 7}, {"id": "", "name": "no id"}, {"id": "x", "body_part": 1.5},
		{"id": "y", "intensity": NAN}, {"id": "z", "body_part": -1}, {"id": 5}, "junk", 5, null,
		{"id": "bleed", "name": "Bleeding", "body_part": arm, "intensity": 2, "rating": -1, "seconds_left": 60},
		{"id": "hunger_starving", "name": "Starving!", "rating": -1},
		{"id": "hurt", "name": "Hurt", "body_part": arm, "rating": -1},
	]
	var e := Snapshot.effects_from(raw)
	_check.call(e.size() == 6 and e[0] == {"id": "stunned", "name": "Stunned", "body_part": 0, "intensity": 1, "rating": -1,
			"seconds_left": 300} and e[1]["name"] == "drunk" and e[1]["seconds_left"] == -1 and e[1]["intensity"] == 1
			and e[2]["seconds_left"] == -1 and e[3]["id"] == "bleed",
			"effects: read and cleaned, bad entries skipped, long or missing time is -1 (%s)" % [e])
	var many: Array = []
	for i in 100:
		many.append({"id": "e%d" % i})
	_check.call(Snapshot.effects_from(many).size() == Snapshot.MAX_EFFECTS and Snapshot.effects_from({}).is_empty()
			and Snapshot.effects_from("x").is_empty(), "effects: capped at 64; not a list: none")
	var h := HudData.new()
	var seen: Array = []
	h.changed.connect(func(p: PackedStringArray) -> void: seen.append(p))
	var s := Snapshot.new()
	s.player_effects = e
	h.update(s, tables)
	var texts: Array = h.effects.map(func(x: Dictionary) -> String: return x["text"])
	var levels: Array = h.effects.map(func(x: Dictionary) -> int: return x["level"])
	_check.call(arm > 0 and texts == ["Stunned", "drunk", "High", "Hurt (left arm)"]
			and levels == [HudData.HURT, HudData.HURT, HudData.OK, HudData.HURT] and seen.size() == 1 and "effects" in seen[0],
			"hud: effects shown but bleeding and hunger, coloured by rating (%s)" % [texts])
	_check.call(h.needs["hunger"]["word"] == "Starving!" and h.needs["hunger"]["level"] == HudData.BAD
			and h.warnings.any(func(w: Dictionary) -> bool: return w["text"] == "Starving!"),
			"hud: the hunger word comes from CDDA's hunger effect and warns when bad")
	var full: Array[Dictionary] = [{"id": "hunger_blank", "name": "", "body_part": 0, "intensity": 1, "rating": 0,
			"seconds_left": -1}]
	s.player_effects = full
	h.update(s, tables)
	_check.call(h.effects.is_empty() and h.needs["hunger"]["word"] == "" and h.needs["hunger"]["level"] == HudData.OK,
			"hud: normal hunger shows no word")
	var v := HudView.new()
	var lots: Array[Dictionary] = []
	for i in 11:
		lots.append({"id": "e%d" % i, "name": "Effect %d" % i, "body_part": 0, "intensity": 1, "rating": 0, "seconds_left": -1})
	s.player_effects = lots
	h.update(s, tables)
	v.data = h
	var lines := v.effect_lines()
	_check.call(lines.size() == HudView.EFFECT_LINES and lines[0] == ["Effect 0", HudData.UNKNOWN] and lines[-1][0] == "+4 more",
			"hud view: at most 8 effect lines, the last says how many more (%s)" % [lines])
	v.free()


## HudView draws what HudData decided: body rows, the feed (newest 6), warnings, need words.
func _test_view(tables: IdTables) -> void:
	var h := HudData.new()
	var v := HudView.new()
	v.data = h
	var s := Snapshot.new()
	var parts: Array[Snapshot.BodyPart] = [_part(tables.body_parts.find("head"), 60, 60), _part(tables.body_parts.find("leg_r"), 0, 60)]
	s.player_parts = parts
	h.update(s, tables)
	var ev: Array = []
	for i in 8:
		ev.append({"kind": "message", "text": "line %d" % i})
	h.on_events(ev)
	_check.call(v.body_rows() == [["head", 1.0, HudData.OK], ["right leg", 0.0, HudData.BROKEN]]
			and v.feed.text == "line 2\nline 3\nline 4\nline 5\nline 6\nline 7" and v.warn.text == "Right Leg broken"
			and v.need_lines().is_empty(), "hud view: body rows, newest messages, warnings; unknown needs hidden (%s)" % [v.body_rows()])
	v.data = null
	_check.call(v.feed.text == "" and v.warn.text == "" and v.body_rows().is_empty(), "hud view: no data, nothing shown")
	v.free()


func _part(id: int, hp: int, hp_max: int, bleed := 0, infected := 0) -> Snapshot.BodyPart:
	var p := Snapshot.BodyPart.new()
	p.id = id
	p.hp = hp
	p.hp_max = hp_max
	p.bleed = bleed
	p.infected = infected
	return p


func _test_words() -> void:
	_check.call(HudData.word("thirst", 600) == "Parched" and HudData.word("thirst", 50) == "Thirsty"
			and HudData.word("thirst", 0) == "" and HudData.word("thirst", -30) == "Hydrated"
			and HudData.word("sleepiness", 400) == "Dead Tired" and HudData.word("sleepiness", 100) == ""
			and HudData.word("pain", 0) == "" and HudData.word("pain", 25) == "Moderate pain"
			and HudData.word("pain", 75) == "Severe pain" and HudData.word("hunger", 900) == "",
			"hud: CDDA's words for thirst, sleepiness and pain")
	_check.call(HudData.part_name("arm_l") == "left arm" and HudData.part_name("foot_r") == "right foot"
			and HudData.part_name("torso") == "torso", "hud: body part names")
	_check.call(HudData.level_color(HudData.BAD).a == 1.0 and HudData.level_color(HudData.UNKNOWN).a == 1.0
			and HudData.level_color(HudData.OK) != HudData.level_color(HudData.HURT), "hud: level colours, opaque")
	_check.call(HudData.clean("<color_red>a\nb</color>\u0007", 200) == "a b" and HudData.clean(42, 10) == ""
			and HudData.clean("x".repeat(500), 200).length() == 200, "hud: text cleaned and capped")


func _test_body_and_held(tables: IdTables) -> void:
	var torso := tables.body_parts.find("torso")
	var arm := tables.body_parts.find("arm_l")
	var h := HudData.new()
	var seen: Array = []
	h.changed.connect(func(p: PackedStringArray) -> void: seen.append(p))
	var s := Snapshot.new()
	s.player_pos = Vector3i(1, 2, 0)
	var parts: Array[Snapshot.BodyPart] = [_part(torso, 80, 80), _part(arm, 0, 60), _part(999, 30, 60, 1)]
	s.player_parts = parts
	s.carried = PackedInt64Array([7, 5, 0, -1, Snapshot.CARRIED_WIELDED, 8, 6, 0, -1, Snapshot.CARRIED_WORN])
	h.update(s, tables)
	_check.call(torso >= 0 and arm >= 0 and h.body.size() == 3 and h.body[0]["part"] == "torso" and h.body[0]["level"] == HudData.OK
			and h.body[1]["part"] == "arm_l" and h.body[1]["name"] == "left arm" and h.body[1]["level"] == HudData.BROKEN
			and h.body[2]["part"] == "part_999" and h.body[2]["level"] == HudData.HURT and is_equal_approx(h.body[2]["frac"], 0.5),
			"hud: body parts by CDDA id, in order, with levels (%s)" % [h.body.map(func(p: Dictionary) -> String: return "%s %d" % [p["part"], p["level"]])])
	var main: ItemRef = h.held["main"]
	_check.call(main != null and main.uid == 7 and main.carried and main.is_wielded() and h.held["off"] == null,
			"hud: the main hand holds a carried ItemRef")
	_check.call(seen.size() == 1 and "body" in seen[0] and "held" in seen[0] and "warnings" in seen[0]
			and h.warnings[0]["level"] == HudData.BROKEN and h.warnings[0]["text"] == "Left Arm broken"
			and h.warnings.any(func(w: Dictionary) -> bool: return (w["text"] as String).begins_with("Bleeding")),
			"hud: changed names the groups; warnings worst first (%s)" % [h.warnings])
	seen.clear()
	h.update(s, tables)
	_check.call(seen.is_empty(), "hud: the same snapshot again: no change")
	h.set_held({"main": {"id": "jug", "liquid": "water", "ml": 500, "capacity_ml": 2000}, "off": {}})
	_check.call(seen.size() == 1 and seen[0] == PackedStringArray(["held"]) and h.held["liquid"] == "water"
			and is_equal_approx(h.held["fill_frac"], 0.25) and h.held["main"] == main,
			"hud: the bridge's held state adds liquid and fill, keeps the ItemRefs")
	h.set_held({"main": {"liquid": "<color_red>x\u0001</color>", "ml": 1e30, "capacity_ml": -5}, "off": "bad"})
	_check.call(h.held["main_liquid"] == "x" and h.held["main_fill"] == -1.0, "hud: hostile held state cleaned")


func _test_needs() -> void:
	var h := HudData.new()
	var s := Snapshot.new()
	h.update(s, null)
	_check.call(h.needs["thirst"]["level"] == HudData.UNKNOWN and h.needs["stamina"]["level"] == HudData.UNKNOWN,
			"hud: needs unknown while the snapshot doesn't carry them")
	s.player_stamina = 5
	s.player_stamina_max = 100
	s.player_needs = {"thirst": 300, "sleepiness": 200, "pain": 0, "morale": -60, "hunger": 500}
	h.update(s, null)
	var texts: Array = h.warnings.map(func(w: Dictionary) -> String: return w["text"])
	_check.call(h.needs["stamina"] == {"value": 5, "word": "", "level": HudData.BAD}
			and h.needs["thirst"] == {"value": 300, "word": "Dehydrated", "level": HudData.BAD}
			and h.needs["sleepiness"]["word"] == "Tired" and h.needs["sleepiness"]["level"] == HudData.HURT
			and h.needs["pain"]["level"] == HudData.OK and h.needs["morale"]["level"] == HudData.BAD
			and h.needs["hunger"]["level"] == HudData.UNKNOWN and h.needs["hunger"]["value"] == 500
			and "Dehydrated" in texts and "Out of breath" in texts and "Miserable" in texts,
			"hud: needs from the snapshot with CDDA's words; bad ones warn (%s)" % [texts])
	s.player_stamina = -1
	h.update(s, null)
	_check.call(h.needs["stamina"]["level"] == HudData.UNKNOWN, "hud: stamina not sent: unknown")


func _test_messages() -> void:
	var h := HudData.new()
	var n := [0]
	h.changed.connect(func(p: PackedStringArray) -> void: n[0] += 1)
	var ev: Array = [{"kind": "sound"}, "junk", {"kind": "message", "text": "<color_red>Ouch</color>", "type": 3, "turn": 12},
			{"kind": "message", "text": 5}, {"kind": "message", "text": "   "}]
	h.on_events(ev)
	_check.call(h.messages.size() == 1 and h.messages[0] == {"text": "Ouch", "type": 3, "turn": 12} and n[0] == 1,
			"hud: messages from events, colour tags out (%s)" % [h.messages])
	var many: Array = []
	for i in 40:
		many.append({"kind": "message", "text": "m%d" % i, "type": 1e20, "turn": -4})
	h.on_events(many)
	_check.call(h.messages.size() == HudData.MAX_MESSAGES and h.messages[-1]["text"] == "m39" and h.messages[-1]["type"] == 255
			and h.messages[-1]["turn"] == 0, "hud: the feed keeps the newest 32, numbers clamped")
