class_name HudData
extends RefCounted
## G1 / L4: what the HUD shows, worked out once for both views (screen widgets in ui/, wrist and body panels in
## vr/; API agreed with lead-vr). It reads the snapshot (body parts, needs, what the hands hold), CDDA's message
## events and the bridge's held state, and decides levels and warnings with CDDA's own thresholds and words
## (display.cpp). Views redraw on `changed` or read the fields any time; nothing here draws.
## Everything that comes in is game data: numbers are clamped, text is cleaned (no colour tags, no control
## characters, capped), lists are capped.

## Which groups changed: any of "body", "needs", "held", "messages", "warnings".
signal changed(parts: PackedStringArray)

enum { UNKNOWN = -1, OK = 0, HURT = 1, BAD = 2, BROKEN = 3 }

const MAX_PARTS := 32
const MAX_MESSAGES := 32
const MAX_TEXT := 200
const MAX_NAME := 64
const MAX_WARNINGS := 8
const MAX_EVENTS := 4096
const NEEDS := ["stamina", "hunger", "thirst", "sleepiness", "pain", "morale"]
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
## {main, off: ItemRef (carried) or null; main_liquid, off_liquid: String; main_fill, off_fill: 0..1 or -1;
## liquid, fill_frac: the first hand's (main, then off) that holds a liquid}.
var held := {}
## The newest last: {text, type, turn}.
var messages: Array[Dictionary] = []
## What to flash, worst first: {id, text, level}.
var warnings: Array[Dictionary] = []

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


## CDDA's word for a need's value ("" when it says nothing): display.cpp's thirst, sleepiness and pain texts.
## Hunger is shown from effects in CDDA (stomach and kcal), which the snapshot doesn't carry yet: "".
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
		out += " " if c.unicode_at(0) < 32 or c.unicode_at(0) == 127 else c
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
					{"stamina": "Out of breath", "morale": "Miserable"}.get(k, k.capitalize())
			out.append({"id": k, "text": t, "level": BAD})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["level"] > b["level"])
	return out.slice(0, MAX_WARNINGS)


static func _int(v: Variant, lo: int, hi: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return clampi(int(clampf(v, lo, hi)), lo, hi)
	return lo if lo > 0 else clampi(0, lo, hi)
