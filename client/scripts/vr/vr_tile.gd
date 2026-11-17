class_name VrTile
extends RefCounted
## Live item tiles in the headset (block "Live item tiles", PLAN.md G2; lead-vr): what the VR item lists show of an
## item's live state, from ItemTile (values and colours ItemLook's, grime GunGrime's), so a VR line reads as the
## flat rows and the 3D items do. The tray's item labels (short: "250 ml, cold") and the open pack's hover name get a
## second line under the name ("250 ml orange juice, cold", "empty", "frozen, old", "fouled 40%"); the hand labels
## (VrHeld) the tile's words
## and a gauge and strip in its colours. Everything comes from ItemTile, which checks the network values again;
## the line is capped. Pure static.

const TAG_MAX := 48                       # characters of the short line ...
const SHORT_MAX := 24                     # ... and of a short one (a tray cell): no contents' name
const SEP := ", "
const TEXT := Color(0.9, 0.9, 0.9)        # words with no temperature


## Item `uid`'s tile on `world`'s newest snapshot; {} when there is none (no world or snapshot, no state, nothing
## to show).
static func of(world: WorldView, uid: int) -> Dictionary:
	if world == null or not is_instance_valid(world) or world.snapshot == null:
		return {}
	return ItemTile.for_item(world.snapshot, world.tables, uid)


## The tile as one short line: how much of what ("250 ml orange juice"; "empty" for an empty see-through
## container), the temperature ("frozen", "cold", "hot"), spoilage when it matters ("old", "rotten"), a gun's
## fouling ("fouled 40%"); "" when it shows nothing. `short`: without the contents' name, SHORT_MAX at most.
static func tag(t: Dictionary, short := false) -> String:
	if t.is_empty() or not ItemTile.shows(t):
		return ""
	var out := PackedStringArray()
	var level := float(t.get("level", -1.0))
	if level > 0.0:
		var what := ("%s %s" % [str(t.get("amount", "")), "" if short else str(t.get("contents", ""))]).strip_edges()
		out.append(what if what != "" else "%d%% full" % roundi(clampf(level, 0.0, 1.0) * 100.0))
	elif level == 0.0 and t.get("see_through", false) == true:
		out.append(ItemTile.EMPTY_TEXT)
	var temp := int(t.get("temp", 0))
	if temp == ItemLook.Temp.FROZEN:
		out.append("frozen")
	elif temp == ItemLook.Temp.COLD:
		out.append("cold")
	elif temp == ItemLook.Temp.HOT:
		out.append("hot")
	var band := ItemLook.rot_band(int(t.get("rot", -1)))
	if band == "old" or band == "rotten":
		out.append(band)
	var grime := float(t.get("grime", -1.0))
	if grime > 0.0:
		out.append("fouled %d%%" % roundi(clampf(grime, 0.0, 1.0) * 100.0))
	return SEP.join(out).left(SHORT_MAX if short else TAG_MAX)


## `item_name` with the tile's tag (`short` as tag's) on a second line when it has one.
static func line(item_name: String, t: Dictionary, short := false) -> String:
	var tg := tag(t, short)
	return item_name if tg.is_empty() else "%s\n%s" % [item_name, tg]


## The tile in words (ItemTile.words: one fact a line) for a hand label; without the fill when the hand's own text
## already says how full (`with_fill` false).
static func words(t: Dictionary, with_fill := true) -> String:
	if t.is_empty():
		return ""
	if with_fill:
		return ItemTile.words(t)
	var c := t.duplicate()
	c["level"] = -1.0
	return ItemTile.words(c)


## The colour the tile's words are written in: its temperature's (frost, cold, heat), else TEXT.
static func color(t: Dictionary) -> Color:
	var v: Variant = t.get("temp_color")
	if v is Color and (v as Color).a > 0.0:
		var c: Color = v
		return Color(c.r, c.g, c.b, 1.0)
	return TEXT
