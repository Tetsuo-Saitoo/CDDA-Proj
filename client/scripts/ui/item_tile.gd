class_name ItemTile
extends RefCounted
## Block "Live item tiles" (PLAN.md G2), slice 1: what an item's row or icon shows of its live state, as a small
## Dictionary a view draws from (ItemTileView behind the Tab view's rows). From a state as Snapshot.item_states
## keeps it: [temp, rot, fill, fill_type, see_through, fill_ml, dirt] (contracts/snapshot.md). Values and
## colours are ItemLook's, grime is GunGrime's, so a row looks like the 3D item and the gun model. The state is
## network data: every value is checked again here (out of range or not a whole number: nothing to show), and
## the amount text is built from numbers only. Pure static.

## State index, as ItemLookView's.
enum { S_TEMP, S_ROT, S_FILL, S_TYPE, S_SEE, S_ML, S_DIRT, S_SIZE }

const CLEAR := Color(0, 0, 0, 0)
const MAX_TYPE := 1 << 30          # an itype index past this is no index (IdTables checks the real end)
const MAX_CONTENTS := 40           # characters of the contents' name in the words
## The symbol CDDA draws liquids with: the stand-in for a liquid when the itype table has no phase for the
## contents (an older bridge). Categories don't tell: water is "food".
const LIQUID_SYMBOL := "~"
## The amount of an empty see-through container (a clear jar shows it is empty, as the 3D item does).
const EMPTY_TEXT := "empty"
## How strong the temperature edge is (its colour's alpha).
const FROZEN_EDGE := 1.0
const COLD_EDGE := 0.6
const HOT_EDGE := 0.9


## The tile of `state` (an Array or PackedInt32Array of S_SIZE; anything else, or none: nothing to show), the
## contents' colour and name from `tables` (null: the default colour, no name):
## {level: 0..1 how full, -1 no container; amount: "250 ml", "1.5 L", EMPTY_TEXT for an empty see-through
##  container, "" none or an empty opaque one; see_through: bool;
##  liquid: Color of the largest content; contents: its name, "" unknown; temp: ItemLook.Temp; temp_color: Color,
##  its alpha the edge's strength, clear when normal; rot: permille 0..ItemLook.ROT_MAX, -1 doesn't rot;
##  rot_color: Color, clear when it doesn't rot; grime: 0..1 a gun's fouling, -1 not a gun; sloshes: the largest
##  content is a liquid (its itype's phase, else LIQUID_SYMBOL) and not frozen}.
static func of(state: Variant, tables: IdTables) -> Dictionary:
	var t := {"level": -1.0, "amount": "", "see_through": false, "liquid": ItemLook.LIQUID_DEFAULT, "contents": "",
			"sloshes": false,
			"temp": ItemLook.Temp.NORMAL, "temp_color": CLEAR, "rot": ItemLook.NO_ROT, "rot_color": CLEAR, "grime": -1.0}
	if not (state is Array or state is PackedInt32Array) or state.size() != S_SIZE:
		return t
	var temp := ItemLook.temp_of(state[S_TEMP])
	t["temp"] = temp
	if temp == ItemLook.Temp.FROZEN:
		t["temp_color"] = Color(ItemLook.FROST, FROZEN_EDGE)
	elif temp == ItemLook.Temp.COLD:
		t["temp_color"] = Color(ItemLook.COLD_TINT, COLD_EDGE)
	elif temp == ItemLook.Temp.HOT:
		t["temp_color"] = Color(ItemLook.HEAT, HOT_EDGE)
	var rot := ItemLook.rot_of(state[S_ROT])
	t["rot"] = rot
	t["rot_color"] = ItemLook.rot_color(rot)
	var fill := ItemLook.fill_of(state[S_FILL])
	if fill >= 0:
		t["level"] = clampf(fill / float(ItemLook.FILL_MAX), 0.0, 1.0)
		t["see_through"] = _int(state[S_SEE], 0, 1, 0) == 1
		var kind := _int(state[S_TYPE], 1, MAX_TYPE, 0)   # 0: empty
		if fill > 0:
			t["amount"] = amount_text(ItemLook.ml_of(state[S_ML]))
		elif t["see_through"]:
			t["amount"] = EMPTY_TEXT
		var def: IdTables.Def = tables.def_at("itype", kind) if tables != null and kind > 0 and fill > 0 else null
		if def != null:
			t["liquid"] = ItemLook.liquid_color(def)
			t["contents"] = InventoryModel.clean(def.name if def.name != "" else def.id, MAX_CONTENTS)
			t["sloshes"] = temp != ItemLook.Temp.FROZEN and (def.phase == "liquid"
					or (def.phase == "" and def.symbol == LIQUID_SYMBOL))
	var dirt := ItemLook.dirt_of(state[S_DIRT])
	t["grime"] = GunGrime.grime_for(dirt) if dirt >= 0 else -1.0
	return t


## Item `uid`'s tile from `snap`'s item_states, {} when the snapshot has no state for it (the bridge leaves out
## items with nothing to show) or it shows nothing.
static func for_item(snap: Snapshot, tables: IdTables, uid: int) -> Dictionary:
	if snap == null or uid <= 0:
		return {}
	var s: Variant = snap.item_states.get(uid)
	if s == null:
		return {}
	var t := of(s, tables)
	return t if shows(t) else {}


## Whether a tile has anything to draw: some contents, a see-through container (its glass, even empty), a
## temperature, spoilage (anything that rots) or grime. An empty opaque container, a clean gun or a plain item
## shows nothing.
static func shows(t: Dictionary) -> bool:
	var level := float(t.get("level", -1.0))
	return level > 0.0 or (level >= 0.0 and t.get("see_through", false) == true) \
			or int(t.get("temp", 0)) != ItemLook.Temp.NORMAL or int(t.get("rot", -1)) >= 0 or float(t.get("grime", -1.0)) > 0.0


## "250 ml", "1.5 L", "10 L" (to a tenth of a litre from 1 L up); "" for none (0 or less, or past ItemLook.ML_MAX).
static func amount_text(ml: int) -> String:
	if ml <= 0 or ml > ItemLook.ML_MAX:
		return ""
	if ml < 1000:
		return "%d ml" % ml
	var tenths := (ml + 50) / 100
	return "%d L" % (tenths / 10) if tenths % 10 == 0 else "%d.%d L" % [tenths / 10, tenths % 10]


## The tile in words, for a tooltip (the colours aren't the only cue): "Cold", "250 ml orange juice, 25% full",
## "Spoilage 95% (old)", "Fouling 40%", one per line; "" when it shows nothing.
static func words(t: Dictionary) -> String:
	var out := PackedStringArray()
	var temp := int(t.get("temp", 0))
	if temp == ItemLook.Temp.FROZEN:
		out.append("Frozen")
	elif temp == ItemLook.Temp.COLD:
		out.append("Cold")
	elif temp == ItemLook.Temp.HOT:
		out.append("Hot")
	var level := float(t.get("level", -1.0))
	if level > 0.0:
		var what := ("%s %s" % [str(t.get("amount", "")), str(t.get("contents", ""))]).strip_edges()
		out.append("%s%d%% full" % [what + ", " if what != "" else "", roundi(clampf(level, 0.0, 1.0) * 100.0)])
	elif level == 0.0:
		out.append("Empty, see-through" if t.get("see_through", false) == true else "Empty")
	var rot := int(t.get("rot", -1))
	if rot >= 0:
		var band := ItemLook.rot_band(rot)
		out.append("Spoilage %d%%%s" % [mini(rot, ItemLook.ROT_MAX) / 10, " (%s)" % band if band != "" else ""])
	var grime := float(t.get("grime", -1.0))
	if grime > 0.0:
		out.append("Fouling %d%%" % roundi(clampf(grime, 0.0, 1.0) * 100.0))
	return "\n".join(out)


## A whole number in lo..hi from `v` (int, or a float with no fraction), else `fallback`.
static func _int(v: Variant, lo: int, hi: int, fallback: int) -> int:
	if not (v is int or v is float) or not is_finite(float(v)) or float(v) != floorf(float(v)):
		return fallback
	var f := float(v)
	return int(f) if f >= lo and f <= hi else fallback
