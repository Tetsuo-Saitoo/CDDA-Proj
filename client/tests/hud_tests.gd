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
	_test_mood()
	_test_mood_cue()


## MoodCue: no tint while calm, off or unknown; a cold tint for low mood, a fainter warm one for high; it fades
## toward the mood, never jumps. The setting (HudSettings.mood_cues, the F1 menu's box) is on by default and saved.
func _test_mood_cue() -> void:
	var low := MoodCue.tint_for(-1.0)
	var high := MoodCue.tint_for(1.0)
	_check.call(MoodCue.tint_for(0.0).a == 0.0 and MoodCue.tint_for(NAN).a == 0.0 and is_equal_approx(low.a, MoodCue.LOW_ALPHA)
			and is_equal_approx(high.a, MoodCue.HIGH_ALPHA) and is_equal_approx(MoodCue.tint_for(-0.5).a, MoodCue.LOW_ALPHA / 2)
			and is_equal_approx(MoodCue.tint_for(-50.0).a, MoodCue.LOW_ALPHA) and low.b > low.r and high.r > high.b
			and MoodCue.LOW_ALPHA <= 0.5 and MoodCue.HIGH_ALPHA <= 0.2,
			"mood cue: no tint at 0, cold when low, warm and fainter when high, capped")
	var h := HudData.new()
	var s := Snapshot.new()
	var c := MoodCue.new()
	c.data = h
	c.step(1.0)
	_check.call(not c.visible and c.shown == 0.0 and c.target() == 0.0, "mood cue: nothing while the mood is unknown")
	s.player_needs = {"morale": -200}
	h.update(s, null)
	c.step(0.5)
	var part := c.shown
	c.step(INF)
	c.step(-5.0)
	var held := c.shown
	c.step(1.0)
	c.step(1.0)
	c.step(1.0)
	_check.call(c.target() == -1.0 and is_equal_approx(part, -0.25) and held == part and c.shown == -1.0 and c.visible,
			"mood cue: it fades toward the mood (%.2f after half a second, then %.2f); a bad frame time moves nothing" % [part, c.shown])
	c.enabled = false
	c.step(1.0)
	var fading := c.visible
	c.step(1.0)
	_check.call(fading and not c.visible and c.shown == 0.0, "mood cue: turned off, it fades out")
	c.enabled = true
	h.mood["cue"] = "lots"
	_check.call(c.target() == 0.0, "mood cue: a cue that isn't a number is none")
	c.free()
	var path := preload("res://tests/test_dir.gd").path("hud_mood.cfg")
	var hs := HudSettings.new()
	var m := KeyMenu.new()
	m.add_hud_settings(hs, path)
	var seen := [0]
	m.hud_changed.connect(func() -> void: seen[0] += 1)
	var was_on := hs.mood_cues and m.mood_check.button_pressed
	m.mood_check.button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	_check.call(was_on and not hs.mood_cues and not back.mood_cues and seen[0] == 1,
			"mood cue: on by default; the F1 box turns it off and saves it")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[compass]\nopacity=0.5\n[mood]\ncues=\"no\"\n")
	f.close()
	var odd := HudSettings.new()
	odd.load_file(path)
	_check.call(odd.mood_cues, "mood cue: a non-bool in the file leaves it on")
	m.free()


## The player's mood: Snapshot.morale_from cleans and caps CDDA's morale entries; HudData.mood has a word for the
## level, the reasons strongest first, a HUD line naming the top three, and a cue strength; HudView shows the line.
func _test_mood() -> void:
	var raw: Array = [
		{"name": "<color_red>Wet" + String.chr(0x202E) + "</color>\n", "value": -12.0},
		{"name": "Enjoyed delicious food", "value": 20}, {"name": "Cold", "value": -8},
		{"name": "", "value": 3}, {"name": "No value"}, {"name": "Fraction", "value": 1.5}, {"name": "NaN", "value": NAN},
		{"name": "Huge", "value": 1e30}, {"name": 5, "value": 1}, "junk", 7, null,
		{"name": "Zero", "value": 0}, {"name": "Killed innocent", "value": -20}, {"name": "X".repeat(500), "value": 1},
	]
	var m := Snapshot.morale_from(raw)
	var short: Array = m.map(func(x: Dictionary) -> String: return (x["name"] as String).left(12))
	_check.call(m.size() == 6 and m[0] == {"name": "Wet", "value": -12, "percent": -1} and m[1]["value"] == 20 and m[3]["name"] == "Zero"
			and (m[5]["name"] as String).length() == Snapshot.MAX_MORALE_NAME,
			"mood: morale entries read and cleaned, bad ones skipped, names capped (%s)" % [short])
	var many: Array = []
	for i in 500:
		many.append({"name": "r%d" % i, "value": i + 1})
	_check.call(Snapshot.morale_from(many).size() == Snapshot.MAX_MORALE and Snapshot.morale_from({}).is_empty()
			and Snapshot.morale_from("x").is_empty() and Snapshot.morale_from(null).is_empty(),
			"mood: entries capped at %d; not a list: none" % Snapshot.MAX_MORALE)
	var words := [HudData.mood_word(250), HudData.mood_word(100), HudData.mood_word(50), HudData.mood_word(10),
			HudData.mood_word(9), HudData.mood_word(-10), HudData.mood_word(-11), HudData.mood_word(-50),
			HudData.mood_word(-51), HudData.mood_word(-100), HudData.mood_word(-101)]
	var bands := [HudData.mood_band(100), HudData.mood_band(99), HudData.mood_band(10), HudData.mood_band(-10),
			HudData.mood_band(-50), HudData.mood_band(-100), HudData.mood_band(-32768)]
	_check.call(words == ["Joyful", "Joyful", "Happy", "Content", "Fine", "Fine", "Unhappy", "Unhappy", "Miserable",
			"Miserable", "Depressed"] and bands == [3, 2, 1, 0, -1, -2, -3],
			"mood: a word per band, the bands CDDA's mood face uses (%s)" % [words])
	# the bridge's player.mood object: its own fields cleaned one by one, its entries with their share
	var obj := {"level": -20.0, "band": -1, "face": "<color_red>):</color>" + String.chr(0x202E), "total": 9,
			"entries": [{"name": "Craving caffeine", "value": -30, "percent": 100}, {"name": "Music", "value": 10, "percent": 250},
				{"name": "Odd", "value": 4, "percent": "half"}]}
	var info := Snapshot.mood_from(obj)
	var ents := Snapshot.morale_from(obj["entries"])
	var odd := Snapshot.mood_from({"level": 1.5, "band": 9, "face": 7, "total": -1, "extra": "x"})
	_check.call(info == {"level": -20, "band": -1, "face": "):", "total": 9} and odd.is_empty() and Snapshot.mood_from("x").is_empty()
			and Snapshot.mood_from(null).is_empty() and (Snapshot.mood_from({"face": "x".repeat(99)})["face"] as String).length() == 16
			and ents == [{"name": "Craving caffeine", "value": -30, "percent": 100}, {"name": "Music", "value": 10, "percent": -1},
				{"name": "Odd", "value": 4, "percent": -1}],
			"mood: the bridge's mood object read field by field, bad ones left out; entries carry their share (%s)" % [info])
	var from_obj := HudData.mood_from(-7, ents, info)
	_check.call(from_obj["value"] == -20 and from_obj["band"] == -1 and from_obj["word"] == "Unhappy" and from_obj["face"] == "):"
			and from_obj["more"] == 6 and from_obj["reasons"][0] == {"name": "Craving caffeine", "value": -30, "percent": 100}
			and from_obj["text"] == "Mood: Unhappy (Craving caffeine -30, Music +10, Odd +4, +6 more)"
			and HudData.mood_from(null, [], {"level": 120})["word"] == "Joyful"
			and HudData.mood_from(120, [], {"band": -3})["word"] == "Depressed" and HudData.mood_from(5, [], "junk")["band"] == 0
			and HudData.mood_from(5, [], {"band": 2.5, "total": "many", "face": 3})["more"] == 0,
			"mood: the mood object's level and band win, CDDA's total counts the rest (%s)" % from_obj["text"])
	var h := HudData.new()
	var seen: Array = []
	h.changed.connect(func(p: PackedStringArray) -> void: seen.append(p))
	var s := Snapshot.new()
	h.update(s, null)
	_check.call(h.mood.is_empty() and not seen.any(func(p: PackedStringArray) -> bool: return "mood" in p),
			"mood: unknown while the snapshot carries no morale")
	seen.clear()
	s.player_needs = {"morale": -20}
	s.player_morale = m
	h.update(s, null)
	var names: Array = h.mood["reasons"].map(func(r: Dictionary) -> String: return (r["name"] as String).left(8))
	_check.call(h.mood["value"] == -20 and h.mood["word"] == "Unhappy" and h.mood["level"] == HudData.HURT
			and h.mood["band"] == -1 and h.mood["face"] == "" and h.mood["more"] == 2
			and names == ["Enjoyed ", "Killed i", "Wet", "Cold", "XXXXXXXX"]
			and h.mood["text"] == "Mood: Unhappy (Enjoyed delicious food +20, Killed innocent -20, Wet -12, +2 more)"
			and is_equal_approx(h.mood["cue"], -10.0 / 90.0) and seen.size() == 1 and "mood" in seen[0],
			"mood: the level's word, reasons strongest first, the top three named (%s)" % h.mood["text"])
	seen.clear()
	h.update(s, null)
	_check.call(seen.is_empty(), "mood: the same mood again changes nothing")
	var cues := []
	for v: int in [0, 10, -10, 55, 100, 5000, -100, -32768]:
		cues.append(snappedf(HudData.mood_from(v, [])["cue"], 0.01))
	_check.call(cues == [0.0, 0.0, 0.0, 0.5, 1.0, 1.0, -1.0, -1.0] and HudData.mood_from(NAN, []).is_empty()
			and HudData.mood_from("5", []).is_empty() and HudData.mood_from(null, m).is_empty()
			and HudData.mood_from(30, "junk")["text"] == "Mood: Content"
			and HudData.mood_from(1e30, [{"name": "a", "value": INF}, {"name": "b", "value": "9"}, 3])["reasons"].is_empty(),
			"mood: the cue is 0 while calm and full from 100 points; hostile values and entries are ignored (%s)" % [cues])
	s.player_needs = {"morale": -150}
	h.update(s, null)
	_check.call(h.warnings.any(func(w: Dictionary) -> bool: return w["text"] == "Depressed" and w["level"] == HudData.BAD),
			"mood: very low morale warns with its word")
	s.player_mood = {"level": 10, "band": 1, "face": ":)", "total": 0}   # the object wins over player_needs
	h.update(s, null)
	_check.call(h.mood["value"] == 10 and h.mood["word"] == "Content" and h.mood["face"] == ":)" and h.mood["cue"] == 0.0
			and HudView.mood_color(h.mood) == HudData.level_color(HudData.OK),
			"mood: at exactly +10 the line is Content and green (the tint starts above it)")
	s.player_mood = {}
	h.update(s, null)
	var view := HudView.new()
	view.data = h
	_check.call(view.mood_line() == [h.mood["text"], HudData.BAD] and view.mood.text == h.mood["text"]
			and HudView.mood_color(h.mood) == HudData.level_color(HudData.BAD)
			and HudView.mood_color(HudData.mood_from(60, [])) == HudData.level_color(HudData.OK)
			and HudView.mood_color(HudData.mood_from(0, [])) == Color(1, 1, 0.9),
			"mood: the screen HUD shows the line, red when low, green when good")
	s.player_needs = {}
	h.update(s, null)
	_check.call(h.mood.is_empty() and view.mood.text == "" and view.mood_line().is_empty(),
			"mood: gone when the snapshot stops sending it")
	view.free()


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
