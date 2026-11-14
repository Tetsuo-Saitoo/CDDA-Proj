class_name HudData
extends RefCounted
## G1 / L4: what the HUD shows, worked out once for both views (screen widgets in ui/, wrist and body panels in
## vr/; API agreed with lead-vr). It reads the snapshot (body parts, needs, what the hands hold), CDDA's message
## events and the bridge's held state, and decides levels and warnings with CDDA's own thresholds and words
## (display.cpp). Views redraw on `changed` or read the fields any time; nothing here draws.
## Everything that comes in is game data: numbers are clamped, text is cleaned (no colour tags, no control
## characters, capped), lists are capped.

## Which groups changed: any of "body", "needs", "effects", "move", "mood", "held", "messages", "warnings",
## "cheats".
signal changed(parts: PackedStringArray)

enum { UNKNOWN = -1, OK = 0, HURT = 1, BAD = 2, BROKEN = 3 }

const MAX_PARTS := 32
const MAX_MESSAGES := 32
const MAX_TEXT := 200
const MAX_NAME := 64
const MAX_WARNINGS := 8
const MAX_EVENTS := 4096
const MAX_EFFECTS := 32
const MAX_MOOD_REASONS := 16
## Reasons named on the mood line; the rest are counted ("+2 more").
const MOOD_REASONS_SHOWN := 3
## Morale within this of 0 is neither good nor bad: the word is "Fine", no cue.
const MOOD_CALM := 10
## Morale this far from 0 gives the full cue (MoodCue's tint).
const MOOD_FULL := 100
## The HUD's word per mood band, -3..3 (CDDA shows a face, not a word).
const MOOD_WORDS := ["Depressed", "Miserable", "Unhappy", "Fine", "Content", "Happy", "Joyful"]
## Effects the HUD shows elsewhere: the body bars carry these (per part), the hunger need the hunger_* ones.
const EFFECTS_SHOWN_ELSEWHERE := ["bleed", "bandaged", "disinfected", "bite", "infected"]
## CDDA's hunger effects (effects.json; display.cpp shows them as the hunger word) -> level.
const HUNGER_LEVELS := {"hunger_engorged": HURT, "hunger_full": OK, "hunger_satisfied": OK, "hunger_blank": OK,
		"hunger_hungry": HURT, "hunger_very_hungry": HURT, "hunger_near_starving": BAD, "hunger_starving": BAD,
		"hunger_famished": BAD}
const NEEDS := ["stamina", "hunger", "thirst", "sleepiness", "pain", "morale"]
## CDDA's move_mode ids (data/json/move_modes.json) -> the HUD's word; others are shown capitalized.
const MOVE_WORDS := {"walk": "Walking", "run": "Running", "crouch": "Crouching", "prone": "Prone"}
# CDDA's sleepiness_levels (character.h)
const TIRED := 191
const DEAD_TIRED := 383
const EXHAUSTED := 575

## Per main body part, in the snapshot's order: {part: CDDA bodypart id ("torso", "arm_l", ...), name, hp,
## hp_max, frac (0..1), bleed, bandaged, infected, bite, level}.
var body: Array[Dictionary] = []
## kind (NEEDS) -> {value: int, word: String, level}; level UNKNOWN when the snapshot doesn't carry it.
## stamina's value is its fraction in percent.
var needs := {}
## The player's other effects (Snapshot.player_effects, CDDA's @ screen order) at most MAX_EFFECTS: {id, text
## ("Stunned", "Hurt (left arm)"), level (good OK, bad HURT, mixed HURT, neutral UNKNOWN), intensity, seconds_left
## (-1 permanent or unknown; CDDA doesn't show it, neither do the views)}.
var effects: Array[Dictionary] = []
## How the player moves (Snapshot.player_move_mode): {mode: CDDA's id ("walk", "run", "crouch", "prone"), text
## ("Running", "Running (stamina 23%)"), level}; {} when the snapshot or the id tables don't say.
var move := {}
## The player's mood (CDDA's morale; Snapshot.player_mood / player_morale, or player_needs["morale"] alone):
## {value: CDDA's morale level, band: -3..3 (CDDA's mood face bands), word (MOOD_WORDS: "Happy", "Unhappy" ...),
## face: CDDA's mood face (":)", "" when not sent), level (OK, HURT below -MOOD_CALM, BAD below -50), reasons:
## [{name, value, percent}] the morale entries, strongest first, at most MAX_MOOD_REASONS (value: what the entry
## adds, signed; they don't sum to the level: CDDA combines each side by squares), more: entries CDDA lists beyond
## the ones named on the line, text: the HUD line ("Mood: Unhappy (Wet -12, Cold -8, +2 more)"), cue: -1..1 for
## the views' mood cues (0 while calm, -1 / 1 from MOOD_FULL points)}; {} when the snapshot doesn't carry morale.
var mood := {}
## {main, off: ItemRef (carried) or null; main_liquid, off_liquid: String; main_fill, off_fill: 0..1 or -1;
## liquid, fill_frac: the first hand's (main, then off) that holds a liquid}.
var held := {}
## The newest last: {text, type, turn}.
var messages: Array[Dictionary] = []
## What to flash, worst first: {id, text, level}.
var warnings: Array[Dictionary] = []
## Testing cheats that are on, in LiveSession.CHEATS order: the views show a marker while it isn't empty.
var cheats := PackedStringArray()

var _bridge_held := {}


func _init() -> void:
	held = _held_from(null, {})
	for k: String in NEEDS:
		needs[k] = {"value": 0, "word": "", "level": UNKNOWN}


## A new snapshot is shown.
func update(snap: Snapshot, tables: IdTables) -> void:
	if snap == null:
		return
	var parts := PackedStringArray()
	var b := _body_from(snap, tables)
	if b != body:
		body = b
		parts.append("body")
	var n := _needs_from(snap)
	if n != needs:
		needs = n
		parts.append("needs")
	var e := effects_from(snap.player_effects, tables)
	if e != effects:
		effects = e
		parts.append("effects")
	var mv := move_from(snap.get("player_move_mode") if "player_move_mode" in snap else -1, tables, needs["stamina"])
	if mv != move:
		move = mv
		parts.append("move")
	var have: Variant = snap.get("player_needs") if "player_needs" in snap else null
	var md := mood_from((have as Dictionary).get("morale") if have is Dictionary else null,
			snap.get("player_morale") if "player_morale" in snap else [],
			snap.get("player_mood") if "player_mood" in snap else {})
	if md != mood:
		mood = md
		parts.append("mood")
	var h := _held_from(snap, _bridge_held)
	if not _same_held(h, held):
		held = h
		parts.append("held")
	_emit_with_warnings(parts)


## The bridge's held state (LiveSession.held_changed): liquids and fill levels of what the hands hold.
func set_held(d: Dictionary) -> void:
	_bridge_held = d
	var h := _held_from(null, d)
	h["main"] = held.get("main")
	h["off"] = held.get("off")
	if not _same_held(h, held):
		held = h
		_emit_with_warnings(PackedStringArray(["held"]))


## LiveSession.cheats_changed: {name: bool}. Only known names that are really true count.
func set_cheats(d: Dictionary) -> void:
	var on := PackedStringArray()
	for n: String in LiveSession.CHEATS:
		var v: Variant = d.get(n)
		if v is bool and v:
			on.append(n)
	if on != cheats:
		cheats = on
		changed.emit(PackedStringArray(["cheats"]))


## Event queue entries (contracts/events.md): `message` ones go to the feed.
func on_events(events: Array) -> void:
	var added := false
	for i in mini(events.size(), MAX_EVENTS):
		var e: Variant = events[i]
		if not e is Dictionary or (e as Dictionary).get("kind") != "message":
			continue
		var t := clean((e as Dictionary).get("text", ""), MAX_TEXT)
		if t.is_empty():
			continue
		messages.append({"text": t, "type": _int((e as Dictionary).get("type", 0), 0, 255),
				"turn": _int((e as Dictionary).get("turn", 0), 0, 1 << 52)})
		added = true
	if messages.size() > MAX_MESSAGES:
		messages = messages.slice(messages.size() - MAX_MESSAGES)
	if added:
		changed.emit(PackedStringArray(["messages"]))


## The colour of a level, opaque (views apply their own opacity).
static func level_color(level: int) -> Color:
	match level:
		OK:
			return Color(0.78, 0.95, 0.78)
		HURT:
			return Color(1.0, 0.85, 0.3)
		BAD:
			return Color(1.0, 0.45, 0.35)
		BROKEN:
			return Color(0.75, 0.15, 0.15)
	return Color(0.6, 0.6, 0.6)


## The HUD's effect rows from Snapshot.player_effects (already cleaned there): the ones shown elsewhere left out.
static func effects_from(list: Array[Dictionary], tables: IdTables) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in list:
		var id: String = e["id"]
		if id in EFFECTS_SHOWN_ELSEWHERE or id.begins_with("hunger_"):
			continue
		var text: String = e["name"]
		var bp: int = e["body_part"]
		if bp > 0:
			var part := tables.body_part_name(bp) if tables != null else ""
			text += " (%s)" % (part_name(clean(part, MAX_NAME)) if not part.is_empty() else "part %d" % bp)
		var rating: int = e["rating"]
		var level := UNKNOWN
		if rating == Snapshot.EFFECT_GOOD:
			level = OK
		elif rating == Snapshot.EFFECT_BAD or rating == Snapshot.EFFECT_MIXED:
			level = HURT
		out.append({"id": id, "text": clean(text, MAX_NAME + 20), "level": level, "intensity": e["intensity"],
				"seconds_left": e["seconds_left"]})
		if out.size() >= MAX_EFFECTS:
			break
	return out


## CDDA's word for a need's value ("" when it says nothing): display.cpp's thirst, sleepiness and pain texts.
## Hunger comes from CDDA's hunger effects instead (HUNGER_LEVELS, _needs_from).
static func word(kind: String, value: int) -> String:
	match kind:
		"thirst":
			if value > 520:
				return "Parched"
			if value > 240:
				return "Dehydrated"
			if value > 80:
				return "Very thirsty"
			if value > 40:
				return "Thirsty"
			if value < -60:
				return "Turgid"
			if value < -20:
				return "Hydrated"
			if value < 0:
				return "Slaked"
		"sleepiness":
			if value >= EXHAUSTED:
				return "Exhausted"
			if value >= DEAD_TIRED:
				return "Dead Tired"
			if value >= TIRED:
				return "Tired"
		"pain":
			var scale := value / 10.0
			if scale > 7:
				return "Severe pain"
			if scale > 6:
				return "Intense pain"
			if scale > 5:
				return "Unmanageable pain"
			if scale > 4:
				return "Distressing pain"
			if scale > 3:
				return "Distracting pain"
			if scale > 2:
				return "Moderate pain"
			if scale > 1:
				return "Mild pain"
			if scale > 0:
				return "Minimal pain"
	return ""


## The mood band of a morale level, -3..3: CDDA's default mood face bands, as the bridge's player.mood.band
## (100, 50 and 10 up; below -10, -50 and -100 down).
static func mood_band(value: int) -> int:
	if value >= 100:
		return 3
	if value >= 50:
		return 2
	if value >= MOOD_CALM:
		return 1
	if value >= -MOOD_CALM:
		return 0
	if value >= -50:
		return -1
	return -2 if value >= -100 else -3


## The HUD's word for a morale level (MOOD_WORDS by its band).
static func mood_word(value: int) -> String:
	return MOOD_WORDS[mood_band(value) + 3]


## The mood (see `mood`) from the morale level, CDDA's morale entries ([{name, value, percent}],
## Snapshot.player_morale) and the bridge's mood fields ({level, band, face, total}, Snapshot.player_mood; its
## level and band win when sent); {} when there is no level. Entries are game text: cleaned and capped again
## here, zero ones left out.
static func mood_from(value: Variant, entries: Variant, info: Variant = null) -> Dictionary:
	var m: Dictionary = info if info is Dictionary else {}
	if m.get("level") is int:
		value = m["level"]
	if not (value is int or (value is float and is_finite(value))):
		return {}
	var v := _int(value, -32768, 32767)
	var reasons: Array[Dictionary] = []
	if entries is Array:
		for e: Variant in (entries as Array).slice(0, Snapshot.MAX_MORALE):
			if not e is Dictionary:
				continue
			var name := clean((e as Dictionary).get("name"), MAX_NAME)
			var pts: Variant = (e as Dictionary).get("value")
			if name.is_empty() or not (pts is int or (pts is float and is_finite(pts))):
				continue
			var n := _int(pts, -32768, 32767)
			var pc: Variant = (e as Dictionary).get("percent")
			if n != 0:
				reasons.append({"name": name, "value": n, "percent": _int(pc, 0, 100) if pc is int and pc >= 0 else -1,
						"_i": reasons.size()})
	reasons.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:   # strongest first, CDDA's order among equals
		return absi(a["value"]) > absi(b["value"]) or (absi(a["value"]) == absi(b["value"]) and a["_i"] < b["_i"]))
	reasons = reasons.slice(0, MAX_MOOD_REASONS)
	for r in reasons:
		r.erase("_i")
	var b: Variant = m.get("band")
	var band: int = clampi(b, -3, 3) if b is int else mood_band(v)
	var word: String = MOOD_WORDS[band + 3]
	var shown := mini(reasons.size(), MOOD_REASONS_SHOWN)
	var t: Variant = m.get("total")
	var more := maxi(_int(t, 0, 1 << 20) if t is int else 0, reasons.size()) - shown   # CDDA may list more than sent
	var text := "Mood: " + word
	if not reasons.is_empty():
		var bits := PackedStringArray()
		for r: Dictionary in reasons.slice(0, shown):
			bits.append("%s %+d" % [r["name"], r["value"]])
		if more > 0:
			bits.append("+%d more" % more)
		text += " (%s)" % ", ".join(bits)
	var over := maxi(absi(v) - MOOD_CALM, 0)
	var cue := signf(v) * clampf(float(over) / (MOOD_FULL - MOOD_CALM), 0.0, 1.0)
	return {"value": v, "band": band, "word": word, "face": clean(m.get("face"), Snapshot.MAX_MOOD_FACE),
			"level": need_level("morale", v), "reasons": reasons, "more": more, "text": text, "cue": cue}


## The move line for move_mode `index` (see `move`); {} when unknown. Running says how much stamina is left once
## it is low, and that it ran out at 0 (CDDA then stops the run itself: "You're too tired to run.").
static func move_from(index: Variant, tables: IdTables, stamina: Dictionary) -> Dictionary:
	if not index is int or tables == null or not tables.has_method("move_mode_name"):
		return {}
	var id := clean(tables.move_mode_name(index), MAX_NAME)
	if id.is_empty():
		return {}
	var text: String = MOVE_WORDS.get(id, id.replace("_", " ").capitalize())
	var level := OK
	if id == "run" and stamina.get("level", UNKNOWN) != UNKNOWN:
		var pct := _int(stamina.get("value"), 0, 100)
		level = need_level("stamina", pct)
		if pct <= 0:
			text = "Running: out of stamina"
		elif level != OK:
			text = "Running (stamina %d%%)" % pct
	return {"mode": id, "text": text, "level": level}


## A level for a need's value (UNKNOWN never comes from here).
static func need_level(kind: String, value: int) -> int:
	match kind:
		"stamina":   # percent left
			return BAD if value < 10 else (HURT if value < 30 else OK)
		"thirst":
			return BAD if value > 240 else (HURT if value > 40 else OK)
		"sleepiness":
			return BAD if value >= DEAD_TIRED else (HURT if value >= TIRED else OK)
		"pain":
			return BAD if value > 50 else (HURT if value > 10 else OK)
		"morale":
			return BAD if value < -50 else (HURT if value < -10 else OK)
	return OK


## A readable name for a CDDA bodypart id: "arm_l" -> "left arm".
static func part_name(id: String) -> String:
	if id.ends_with("_l"):
		return "left " + id.left(-2).replace("_", " ")
	if id.ends_with("_r"):
		return "right " + id.left(-2).replace("_", " ")
	return id.replace("_", " ")


## Game text as one plain line: colour tags out, control characters out, capped.
static func clean(v: Variant, cap: int) -> String:
	if not v is String:
		return ""
	var s := CddaText.plain((v as String).left(cap * 4))
	var out := ""
	for c in s.left(cap):
		var u := c.unicode_at(0)
		if u < 32:
			out += " "
		elif not CddaText.is_hidden(u):
			out += c
	return out.strip_edges()


# --- inside ---

func _body_from(snap: Snapshot, tables: IdTables) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in mini(snap.player_parts.size(), MAX_PARTS):
		var bp: Snapshot.BodyPart = snap.player_parts[i]
		if bp == null:
			continue
		var id := tables.body_part_name(bp.id) if tables != null else ""
		id = clean(id, MAX_NAME) if not id.is_empty() else "part_%d" % bp.id
		var hp := clampi(bp.hp, -9999, 9999)
		var hp_max := clampi(bp.hp_max, 0, 9999)
		var frac := clampf(float(hp) / hp_max, 0.0, 1.0) if hp_max > 0 else 0.0
		var bleed := clampi(bp.bleed, 0, 255)
		var infected := clampi(bp.infected, 0, 255)
		var bite := clampi(bp.bite, 0, 255)
		var level := OK
		if hp_max > 0 and hp <= 0:
			level = BROKEN
		elif frac < 0.4 or bleed >= 2 or infected > 0:
			level = BAD
		elif frac < 0.8 or bleed > 0 or bite > 0:
			level = HURT
		out.append({"part": id, "name": part_name(id), "hp": hp, "hp_max": hp_max, "frac": frac, "bleed": bleed,
				"bandaged": clampi(bp.bandaged, 0, 255), "infected": infected, "bite": bite, "level": level})
	return out


## Needs from the snapshot when it carries them (`player_stamina` / `player_stamina_max` and `player_needs`
## {hunger, thirst, sleepiness, pain, morale}; contracts/snapshot.md player_view), else UNKNOWN.
func _needs_from(snap: Snapshot) -> Dictionary:
	var out := {}
	for k: String in NEEDS:
		out[k] = {"value": 0, "word": "", "level": UNKNOWN}
	var have: Variant = snap.get("player_needs") if "player_needs" in snap else null
	if have is Dictionary:
		for k: String in ["hunger", "thirst", "sleepiness", "pain", "morale"]:
			var v: Variant = (have as Dictionary).get(k)
			if v is int or v is float:
				var x := _int(v, -32768, 32767)
				out[k] = {"value": x, "word": word(k, x), "level": need_level(k, x) if k != "hunger" else UNKNOWN}
	for e: Dictionary in snap.player_effects:   # CDDA's hunger word is the name of its hunger_* effect
		var id: String = e["id"]
		if id.begins_with("hunger_"):
			var h: Dictionary = out["hunger"]
			var lv: int = HUNGER_LEVELS.get(id, BAD if e["rating"] == Snapshot.EFFECT_BAD else OK)
			out["hunger"] = {"value": h["value"], "word": "" if id == "hunger_blank" else str(e["name"]), "level": lv}
			break
	if "player_stamina" in snap and "player_stamina_max" in snap:   # -1: not sent
		var st := _int(snap.get("player_stamina"), -1, 1 << 30)
		var mx := _int(snap.get("player_stamina_max"), -1, 1 << 30)
		if st >= 0 and mx > 0:
			var pct := clampi(roundi(100.0 * st / mx), 0, 100)
			out["stamina"] = {"value": pct, "word": "", "level": need_level("stamina", pct)}
	return out


## What the hands hold: ItemRefs from the snapshot's carried rows (wielded, off hand), liquids from the bridge.
func _held_from(snap: Snapshot, d: Dictionary) -> Dictionary:
	var out := {"main": null, "off": null, "main_liquid": "", "off_liquid": "", "main_fill": -1.0, "off_fill": -1.0,
			"liquid": "", "fill_frac": -1.0}
	if snap != null:
		var c := snap.carried
		for k in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
			var f := int(c[k + 4])
			var key := "main" if (f & Snapshot.CARRIED_WIELDED) != 0 else ("off" if (f & Snapshot.CARRIED_OFFHAND) != 0 else "")
			if key != "" and out[key] == null:
				out[key] = ItemRef.on_player(c[k], int(c[k + 1]), c[k + 2], int(c[k + 3]), f, snap.player_pos)
	for hand: String in ["main", "off"]:
		var h: Variant = d.get(hand)
		if not h is Dictionary:
			continue
		out[hand + "_liquid"] = clean((h as Dictionary).get("liquid", ""), MAX_NAME)
		var cap := _int((h as Dictionary).get("capacity_ml", 0), 0, 1 << 30)
		if cap > 0:
			out[hand + "_fill"] = clampf(float(_int((h as Dictionary).get("ml", 0), 0, 1 << 30)) / cap, 0.0, 1.0)
	for hand: String in ["main", "off"]:
		if not (out[hand + "_liquid"] as String).is_empty():
			out["liquid"] = out[hand + "_liquid"]
			out["fill_frac"] = out[hand + "_fill"]
			break
	return out


static func _same_held(a: Dictionary, b: Dictionary) -> bool:
	for k: String in a:
		if k == "main" or k == "off":
			var x: ItemRef = a[k]
			var y: ItemRef = b.get(k)
			if (x == null) != (y == null) or (x != null and (not x.same(y) or x.flags != y.flags)):
				return false
		elif a[k] != b.get(k):
			return false
	return true


func _emit_with_warnings(parts: PackedStringArray) -> void:
	if parts.is_empty():
		return
	var w := _warnings()
	if w != warnings:
		warnings = w
		parts.append("warnings")
	changed.emit(parts)


func _warnings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Dictionary in body:
		if p["level"] == BROKEN:
			out.append({"id": "broken_" + p["part"], "text": "%s broken" % (p["name"] as String).capitalize(), "level": BROKEN})
	for p: Dictionary in body:
		if p["bleed"] > 0:
			out.append({"id": "bleed_" + p["part"], "text": "Bleeding (%s)" % p["name"], "level": BAD if p["bleed"] >= 2 else HURT})
	for p: Dictionary in body:
		if p["infected"] > 0:
			out.append({"id": "infected_" + p["part"], "text": "Infected wound (%s)" % p["name"], "level": BAD})
	for k: String in NEEDS:
		var n: Dictionary = needs[k]
		if n["level"] == BAD:
			var t: String = n["word"] if not (n["word"] as String).is_empty() else \
					{"stamina": "Out of breath", "morale": mood_word(n["value"])}.get(k, k.capitalize())
			out.append({"id": k, "text": t, "level": BAD})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["level"] > b["level"])
	return out.slice(0, MAX_WARNINGS)


static func _int(v: Variant, lo: int, hi: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return clampi(int(clampf(v, lo, hi)), lo, hi)
	return lo if lo > 0 else clampi(0, lo, hi)
