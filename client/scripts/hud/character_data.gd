class_name CharacterData
extends RefCounted
## G4: what the character screen shows, worked out once for every view (the screen's CharacterView; the VR panel
## shows that same view). Sources: HudData (body, needs, mood, effects: already cleaned there), the snapshot's
## worn items (G2's paper doll: each item with its layer and damage, and the layers on each body part) and the
## bridge's character sheet (`set_sheet`: name, stats, speed, encumbrance, skills, proficiencies, traits, bionics
## and descriptions). The sheet is game data: only the fields below are read, numbers are clamped, text is
## cleaned (no colour tags, no control characters, capped) and lists are capped. Nothing here draws.

signal changed

const MAX_ROWS := 128
const MAX_LABEL := 64
const MAX_VALUE := 40
const MAX_TIP := 400
## CDDA's four stats, in its order: sheet id -> label, tooltip.
const STATS := {
	"str": ["Strength", "Melee damage, how much you can carry, your hit points and resistance to many diseases."],
	"dex": ["Dexterity", "Melee and ranged accuracy, dodging, and how well you handle fine work."],
	"int": ["Intelligence", "How fast you read and learn skills, and success at crafting and first aid."],
	"per": ["Perception", "Ranged accuracy, noticing traps and things far away, and spotting lies."],
}
## CDDA's layer names by layer_level (item::layer_to_string), inner to outer.
const LAYERS := ["Personal aura", "Close to skin", "Normal", "Waist", "Outer", "Strapped", "Outer aura"]
## A worn item's damage_level 0..5 as words (CDDA's own words depend on the material).
const DAMAGE := ["undamaged", "slightly damaged", "damaged", "very damaged", "badly damaged", "nearly destroyed"]
## Needs shown on the Needs card, in HudData.NEEDS order (morale has its own card).
const NEEDS := ["stamina", "hunger", "thirst", "sleepiness", "pain"]
const NO_SHEET := "Stats, skills, proficiencies, traits and bionics come with the game's character data, which this game doesn't send yet."
const WAITING := "Asking the game for stats, skills, proficiencies, traits and bionics..."
const FAILED := "The game couldn't send the character data (%s)."
## `truncated`: the bridge emptied descriptions and, for a huge sheet, cut entries off the ends of the lists.
const TRUNCATED := "The character data was too big to send whole: some descriptions or list entries are left out."
## A query result's errors (contracts/bridge_api.md "Character queries"); anything else reads as "internal".
const ERRORS := ["internal", "too large"]
const MAX_RESULT_BYTES := 72 << 10   # the bridge caps a result at 64 KB
const MAX_QUERY_ID := (1 << 53) - 1

## The screen's heading: the character's name, or "Character" without a sheet.
var title := "Character"
## Profession, age and height, "" when the sheet doesn't say.
var subtitle := ""
## Why some cards are missing, "" when the sheet is there.
var note := NO_SHEET
## The cards in display order, empty ones left out: {id, title, rows: [{label, value, level (HudData.OK ...),
## tip}]}. Rows are at most MAX_ROWS per card.
var cards: Array[Dictionary] = []
## Bumped with each `changed`: views skip a rebuild when they have shown this revision already.
var revision := 0

var _hud: HudData
var _snap: Snapshot
var _tables: IdTables
var _sheet := {}
var _waiting := false
var _error := ""


## A character query's result text (CddaSim.take_query_result) for query `id`: its Dictionary (still game data:
## set_sheet reads only known fields), or {} when it isn't one (too big, not JSON, another id or kind).
static func parse_result(text: Variant, id: int) -> Dictionary:
	if not text is String or (text as String).is_empty() or (text as String).length() > MAX_RESULT_BYTES:
		return {}
	var j := JSON.new()   # parse() returns its error quietly (parse_string logs one)
	if j.parse(text) != OK or not j.data is Dictionary:
		return {}
	var d: Dictionary = j.data
	if _int(d.get("id"), 0, MAX_QUERY_ID) != id or id < 1 or d.get("kind") != "character" or not d.get("ok") is bool:
		return {}
	return d


## A new snapshot is shown (HudData.update ran): the body, needs, mood and effects cards follow it, and the worn
## cards follow `snap` (its worn items, named by `tables`).
func update(hud: HudData, snap: Snapshot = null, tables: IdTables = null) -> void:
	_hud = hud
	_snap = snap
	_tables = tables
	_build()


## The bridge's character sheet (a Dictionary, see contracts/bridge_api.md "Character queries"); one with `ok`
## false keeps the last sheet and notes the error; anything else clears it.
func set_sheet(d: Variant) -> void:
	_waiting = false
	var ok: Variant = (d as Dictionary).get("ok", true) if d is Dictionary else null
	if ok is bool and not ok:
		var e: Variant = (d as Dictionary).get("error")
		_error = e if e is String and e in ERRORS else "internal"
	else:
		_sheet = d if d is Dictionary else {}
		_error = ""
	_build()


## A query was sent: until its result comes, a screen without a sheet says so.
func set_waiting(on: bool) -> void:
	if on != _waiting:
		_waiting = on
		if not has_sheet():   # with a sheet the note doesn't change
			_build()


func has_sheet() -> bool:
	return not _sheet.is_empty()


func card(id: String) -> Dictionary:
	for c: Dictionary in cards:
		if c["id"] == id:
			return c
	return {}


## Works the cards out again; `changed` only when something shown differs (each new turn calls this while most of
## the screen stays the same).
func _build() -> void:
	var was := [title, subtitle, note, cards]
	var fresh: Array[Dictionary] = []
	cards = fresh
	_heading()
	_add("stats", "Stats", _stats_rows())
	if _hud != null:
		_add("body", "Body", _body_rows())
		_add("needs", "Needs", _needs_rows())
		_add("mood", "Mood", _mood_rows())
		_add("effects", "Effects", _effect_rows())
	if _snap != null:
		_add("worn", "Worn", _worn_rows())
		_add("worn_parts", "Worn by body part", _worn_part_rows())
	_add("skills", "Skills", _skill_rows())
	_add("proficiencies", "Proficiencies", _proficiency_rows())
	_add("traits", "Traits and mutations", _trait_rows())
	_add("bionics", "Bionics", _bionic_rows())
	_add("speed", "Speed", _speed_rows())
	if [title, subtitle, note, cards] == was:
		return
	revision += 1
	changed.emit()


func _add(id: String, card_title: String, rows: Array[Dictionary]) -> void:
	if not rows.is_empty():
		cards.append({"id": id, "title": card_title, "rows": rows.slice(0, MAX_ROWS)})


static func row(label: String, value: String, level := HudData.UNKNOWN, tip := "") -> Dictionary:
	return {"label": label, "value": value, "level": level, "tip": tip}


func _heading() -> void:
	if has_sheet():
		var cut: Variant = _sheet.get("truncated", false)
		note = TRUNCATED if cut is bool and cut else ""
	elif not _error.is_empty():
		note = FAILED % _error
	else:
		note = WAITING if _waiting else NO_SHEET
	var n := HudData.clean(_sheet.get("name"), MAX_LABEL)
	title = n if not n.is_empty() else "Character"
	var bits := PackedStringArray()
	var prof := HudData.clean(_sheet.get("profession"), MAX_LABEL)
	if not prof.is_empty():
		bits.append(prof)
	var age := _int(_sheet.get("age"), 0, 1000)
	if age > 0:
		bits.append("age %d" % age)
	var cm := _int(_sheet.get("height_cm"), 0, 1000)
	if cm > 0:
		bits.append("%d cm" % cm)
	subtitle = ", ".join(bits)


func _stats_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var by_id := {}
	for s: Dictionary in _list(_sheet.get("stats"), 8):
		by_id[str(s.get("id", ""))] = s
	for id: String in STATS:
		if not by_id.has(id):
			continue
		var cur := _int(by_id[id].get("cur"), -1000, 1000)
		var base := _int(by_id[id].get("base"), -1000, 1000)
		var value := str(cur) if cur == base else "%d (base %d)" % [cur, base]
		out.append(row(STATS[id][0], value, HudData.HURT if cur < base else HudData.UNKNOWN, STATS[id][1]))
	var sp: Variant = _sheet.get("speed")
	if sp is Dictionary and (sp as Dictionary).has("cur"):
		var cur := _int((sp as Dictionary)["cur"], 0, 10000)
		out.append(row("Speed", str(cur), HudData.HURT if cur < 100 else HudData.UNKNOWN,
				"Moves per turn; 100 is normal. The Speed card lists what changes it."))
	return out


func _speed_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var sp: Variant = _sheet.get("speed")
	if not sp is Dictionary:
		return out
	if (sp as Dictionary).has("move_cost"):
		var mc := _int((sp as Dictionary)["move_cost"], 0, 100000)
		out.append(row("Move cost", str(mc), HudData.HURT if mc > 100 else HudData.UNKNOWN,
				"What a step costs in moves; 100 is normal, more is slower."))
	for m: Dictionary in _list((sp as Dictionary).get("modifiers"), 32):
		var label := HudData.clean(m.get("name"), MAX_LABEL)
		var v := _int(m.get("value"), -10000, 10000)
		if label.is_empty() or v == 0:
			continue
		var pc: Variant = m.get("percent", false)
		var cost: Variant = m.get("move_cost", false)
		var is_cost: bool = cost is bool and cost
		var good := (v < 0) if is_cost else (v > 0)   # a dearer step is bad, more speed good
		out.append(row(label, ("%+d%%" if pc is bool and pc else "%+d") % v, HudData.OK if good else HudData.HURT,
				"Changes your move cost." if is_cost else "Changes your speed."))
	return out


func _body_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var enc := _list(_sheet.get("encumbrance"), HudData.MAX_PARTS)
	# the sheet's encumbrance is in the snapshot's body-part order; HudData.body skips missing parts
	var at: Array[int] = []
	if _snap != null:
		for j in _snap.player_parts.size():
			if _snap.player_parts[j] != null:
				at.append(j)
	for i in _hud.body.size():
		var b: Dictionary = _hud.body[i]
		var tip := PackedStringArray()
		for k: String in ["bleed", "bite", "infected", "bandaged"]:
			if int(b.get(k, 0)) > 0:
				tip.append({"bleed": "bleeding", "bite": "bitten", "infected": "infected", "bandaged": "bandaged"}[k])
		var value := "%d / %d" % [b["hp"], b["hp_max"]]
		var idx := at[i] if i < at.size() else i
		if idx < enc.size():
			# CDDA shows clothing's encumbrance plus the layering penalty
			var worn := _int(enc[idx].get("enc"), -1000, 1000)
			var layers := _int(enc[idx].get("layer"), 0, 1000)
			value += ", enc %d" % (worn + layers)
			tip.append("encumbrance %d%s, warmth %d" % [worn + layers, " (%d from layering)" % layers if layers > 0 else "",
					_int(enc[idx].get("warmth"), -100000, 100000)])
		out.append(row(first_upper(str(b["name"])), value, b["level"], first_upper("; ".join(tip))))
	return out


func _needs_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for kind: String in NEEDS:
		var n: Dictionary = _hud.needs.get(kind, {})
		if n.is_empty() or (n.get("level", HudData.UNKNOWN) == HudData.UNKNOWN and str(n.get("word", "")).is_empty()):
			continue
		var w: String = n.get("word", "")
		# CDDA shows no word while a need is fine; its raw numbers (thirst 1 ...) mean nothing to a player
		var value := ("%d%%" % n["value"]) if kind == "stamina" else (w if not w.is_empty() else "fine")
		out.append(row(first_upper(kind), value, n["level"]))
	return out


func _mood_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var m := _hud.mood
	if m.is_empty():
		return out
	var face: String = m.get("face", "")
	out.append(row("Mood", ("%s %s" % [m["word"], face]).strip_edges(), m["level"],
			"Morale %d. Each reason below adds or takes away; they don't simply add up." % m["value"]))
	for r: Dictionary in m.get("reasons", []):
		var v: int = r["value"]
		out.append(row(r["name"], "%+d" % v, HudData.OK if v > 0 else HudData.HURT,
				"%d%% of the %s side" % [r["percent"], "good" if v > 0 else "bad"]))
	return out


func _effect_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tips: Variant = _sheet.get("effect_descriptions")
	for e: Dictionary in _hud.effects:
		var tip := HudData.clean(tips.get(e["id"]), MAX_TIP) if tips is Dictionary else ""
		out.append(row(e["text"], "", e["level"], tip))
	return out


## What the player wears, inner to outer (the snapshot's order): its name, its layer, coloured by damage.
func _worn_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for w: Snapshot.Worn in _snap.player_worn:
		var parts := PackedStringArray()
		for p in w.covers:
			parts.append(_part(p))
		var dmg := clampi(w.damage, 0, DAMAGE.size() - 1)
		var tip := "%s. Covers %s." % [first_upper(DAMAGE[dmg]), ", ".join(parts) if not parts.is_empty() else "nothing"]
		out.append(row(_item_name(w.type), _layer(w.layer), _damage_level(dmg), tip))
	return out


## The paper doll as rows: each body part the snapshot lists, then any other part something covers, with how many
## layers are on it ("bare" for none) and, as the tooltip, the items on it inner to outer.
func _worn_part_rows() -> Array[Dictionary]:
	var order: Array[int] = []
	for b in _snap.player_parts:
		if not order.has(b.id):
			order.append(b.id)
	var on := {}   # part index -> item names, inner to outer (an Array: a packed one would be copied out of the dict)
	for w: Snapshot.Worn in _snap.player_worn:
		for p in w.covers:
			if not order.has(p):
				order.append(p)
			if not on.has(p):
				on[p] = []
			(on[p] as Array).append(_item_name(w.type))
	var out: Array[Dictionary] = []
	for p in order:
		var items: Array = on.get(p, [])
		var value := "bare" if items.is_empty() else ("1 layer" if items.size() == 1 else "%d layers" % items.size())
		out.append(row(first_upper(_part(p)), value, HudData.UNKNOWN, ", ".join(PackedStringArray(items))))
	return out


func _item_name(type: int) -> String:
	var d: IdTables.Def = _tables.def_at("itype", type) if _tables != null else null
	var n := HudData.clean(d.name, MAX_LABEL) if d != null else ""
	if n.is_empty() and d != null:
		n = HudData.clean(d.id, MAX_LABEL)
	return n if not n.is_empty() else "item type %d" % type


func _part(index: int) -> String:
	var id := HudData.clean(_tables.body_part_name(index), MAX_LABEL) if _tables != null else ""
	return HudData.part_name(id) if not id.is_empty() else "part %d" % index


static func _layer(level: int) -> String:
	return LAYERS[level] if level >= 0 and level < LAYERS.size() else "Layer %d" % level


static func _damage_level(dmg: int) -> int:
	if dmg >= 4:
		return HudData.BAD
	return HudData.HURT if dmg >= 2 else HudData.UNKNOWN


func _skill_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Dictionary in _list(_sheet.get("skills"), 64):
		var label := HudData.clean(s.get("name"), MAX_LABEL)
		if label.is_empty():
			continue
		# `level` is the practical level, `knowledge` the theory (books, teaching); progress 0..100 to the next
		var lv := _int(s.get("level"), 0, 100)
		var prog := _int(s.get("progress"), 0, 99)
		var know := maxi(_int(s.get("knowledge"), 0, 100), lv)
		var kprog := _int(s.get("knowledge_progress"), 0, 99)
		var value := str(lv) + (" (%d%%)" % prog if prog > 0 else "") + (", theory %d" % know if know > lv else "")
		var tip := HudData.clean(s.get("description"), MAX_TIP)
		var how := "Level %d, %d%% to the next." % [lv, prog]
		if know > lv or kprog > 0:
			how += " Theory %d, %d%% to the next: practice comes faster up to it." % [know, kprog]
		out.append(row(label, value, HudData.OK if lv > 0 else HudData.UNKNOWN,
				(tip + "\n" + how) if not tip.is_empty() else how))
	return out


func _proficiency_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var p: Variant = _sheet.get("proficiencies")
	if not p is Dictionary:
		return out
	for k: Dictionary in _list((p as Dictionary).get("known"), 64):
		var label := HudData.clean(k.get("name"), MAX_LABEL)
		if not label.is_empty():
			out.append(row(label, "known", HudData.OK, HudData.clean(k.get("description"), MAX_TIP)))
	for k: Dictionary in _list((p as Dictionary).get("learning"), 64):
		var label := HudData.clean(k.get("name"), MAX_LABEL)
		if not label.is_empty():
			out.append(row(label, "%d%%" % _int(k.get("percent"), 0, 100), HudData.UNKNOWN,
					HudData.clean(k.get("description"), MAX_TIP)))
	return out


func _trait_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t: Dictionary in _list(_sheet.get("traits"), 128):
		var label := HudData.clean(t.get("name"), MAX_LABEL)
		if label.is_empty():
			continue
		var rating := _int(t.get("rating"), -1, 1)
		var level := HudData.OK if rating > 0 else (HudData.HURT if rating < 0 else HudData.UNKNOWN)
		out.append(row(label, "mutation" if t.get("mutation") == true else "", level,
				HudData.clean(t.get("description"), MAX_TIP)))
	return out


func _bionic_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var list := _list(_sheet.get("bionics"), 64)
	var pw: Variant = _sheet.get("power")
	if pw is Dictionary and (not list.is_empty() or _int((pw as Dictionary).get("max_kj"), 0, 1000000) > 0):
		out.append(row("Power", "%d / %d kJ" % [_int((pw as Dictionary).get("cur_kj"), 0, 1000000),
				_int((pw as Dictionary).get("max_kj"), 0, 1000000)]))
	for b: Dictionary in list:
		var label := HudData.clean(b.get("name"), MAX_LABEL)
		if not label.is_empty():
			var on: bool = b.get("active") == true
			out.append(row(label, "on" if on else "", HudData.OK if on else HudData.UNKNOWN,
					HudData.clean(b.get("description"), MAX_TIP)))
	return out


## "left arm" -> "Left arm" (String.capitalize would make it "Left Arm" and rewrite underscores).
static func first_upper(s: String) -> String:
	return s.left(1).to_upper() + s.substr(1)


## The Dictionary entries of `v` when it is an Array, at most `cap`; [] for anything else.
static func _list(v: Variant, cap: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if v is Array:
		for e: Variant in v:
			if out.size() >= cap:
				break
			if e is Dictionary:
				out.append(e)
	return out


static func _int(v: Variant, lo: int, hi: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return clampi(int(clampf(v, lo, hi)), lo, hi)
	return clampi(0, lo, hi)
