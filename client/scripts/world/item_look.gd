class_name ItemLook
extends RefCounted
## Live item state (block "Live item tiles", PLAN.md G2; the snapshot's `player.item_states`,
## contracts/snapshot.md): what an item's temperature, rot, fill and fouling mean and
## the colours they show in, in one place for the item icons (menus, hands panel, VR) and the 3D items (in
## the world and in hands), so both look the same. The values are CDDA's own (the bridge sends its item flags
## and its relative rot), so nothing here depends on an item's name and mod items behave the same.
## Pure static: no scene or snapshot needed.

## Temperature, from CDDA's item flags: HOT at about 38 C and up, COLD at about 4.4 C and down, FROZEN below
## the item's own freezing point (game_constants.h `temperatures`, item temperature flags). The bridge's codes.
enum Temp { NORMAL = 0, HOT = 1, COLD = 2, FROZEN = 3 }

## Rot: CDDA's relative rot in permille (1000 = the item's shelf life is used up); NO_ROT for things that
## don't rot. The bands are item.h's.
const NO_ROT := -1
const FRESH := 100      # up to here CDDA says "(fresh)" (is_fresh: relative rot < 0.1)
const OLD := 900        # past here "(old)" (is_going_bad: > 0.9)
const ROTTEN := 1000    # past here rotten (> 1.0)
const ROT_MAX := 2000   # CDDA removes most things at twice their shelf life
## The 3D tint starts here (an icon shows the whole ramp); full at ROTTEN.
const TINT_FROM := 500
const TINT_MAX := 0.6   # how much of the item's own colours the tint covers at most

## Fill: permille of a container's CONTAINER pockets in use (FILL_MAX = full); NO_FILL when it has none.
const NO_FILL := -1
const FILL_MAX := 1000
## Volume inside a container in ml; NO_ML when it has no CONTAINER pocket.
const NO_ML := -1
const ML_MAX := 100000000   # 100 m3: past any container
## A gun's fouling, the unit of the snapshot's wielded_gun.dirt; NO_DIRT when it isn't a gun or doesn't foul.
const NO_DIRT := -1
const DIRT_MAX := 10000

const FROST := Color(0.84, 0.93, 1.0)
const COLD_TINT := Color(0.6, 0.78, 1.0)
const HEAT := Color(1.0, 0.52, 0.18)
const FRESH_COLOR := Color(0.3, 0.72, 0.3)
const OLD_COLOR := Color(0.82, 0.72, 0.24)
const ROTTEN_COLOR := Color(0.38, 0.26, 0.12)
const LIQUID_DEFAULT := Color(0.5, 0.64, 0.82)
## The map symbol CDDA gives liquids: is_liquid's fallback for a bridge that sends no phase.
const LIQUID_SYMBOL := "~"


## A temperature value from the snapshot: Temp, anything else NORMAL.
static func temp_of(v: Variant) -> int:
	return int(v) if _whole(v) and int(v) >= Temp.NORMAL and int(v) <= Temp.FROZEN else Temp.NORMAL


## A rot value from the snapshot: 0..ROT_MAX, anything else (negative, too big, not a whole number) NO_ROT.
static func rot_of(v: Variant) -> int:
	return int(v) if _whole(v) and int(v) >= 0 and int(v) <= ROT_MAX else NO_ROT


## A fill value from the snapshot: 0..FILL_MAX permille, anything else NO_FILL.
static func fill_of(v: Variant) -> int:
	return int(v) if _whole(v) and int(v) >= 0 and int(v) <= FILL_MAX else NO_FILL


## A volume from the snapshot: 0..ML_MAX ml, anything else NO_ML.
static func ml_of(v: Variant) -> int:
	return int(v) if _whole(v) and int(v) >= 0 and int(v) <= ML_MAX else NO_ML


## A fouling value from the snapshot: 0..DIRT_MAX, anything else NO_DIRT.
static func dirt_of(v: Variant) -> int:
	return int(v) if _whole(v) and int(v) >= 0 and int(v) <= DIRT_MAX else NO_DIRT


static func _whole(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v)) and absf(float(v)) < 1e15 and float(v) == floorf(float(v))


## The band CDDA names: "fresh", "old", "rotten", "" in between or when it doesn't rot.
static func rot_band(rot: int) -> String:
	if rot < 0:
		return ""
	if rot < FRESH:
		return "fresh"
	if rot > ROTTEN:
		return "rotten"
	return "old" if rot > OLD else ""


## The icon's spoilage colour: green while fresh, to yellow by OLD, to brown at ROTTEN and after; clear when
## it doesn't rot.
static func rot_color(rot: int) -> Color:
	if rot < 0:
		return Color(0, 0, 0, 0)
	if rot <= FRESH:
		return FRESH_COLOR
	if rot <= OLD:
		return FRESH_COLOR.lerp(OLD_COLOR, float(rot - FRESH) / (OLD - FRESH))
	return OLD_COLOR.lerp(ROTTEN_COLOR, clampf(float(rot - OLD) / (ROTTEN - OLD), 0.0, 1.0))


## How strongly a 3D item is tinted (0..TINT_MAX): none below TINT_FROM, full at ROTTEN.
static func rot_strength(rot: int) -> float:
	if rot < TINT_FROM:
		return 0.0
	return TINT_MAX * clampf(float(rot - TINT_FROM) / (ROTTEN - TINT_FROM), 0.0, 1.0)


## The 3D tint: rot_color with rot_strength as its alpha.
static func rot_tint(rot: int) -> Color:
	var c := rot_color(rot)
	c.a = rot_strength(rot)
	return c


## How full, 0..1, from a fill value (permille; NO_FILL and anything malformed is 0).
static func level(fill: Variant) -> float:
	return maxi(fill_of(fill), 0) / float(FILL_MAX)


## Whether contents of item type `def` are a liquid (a see-through container shows their level, an icon's surface
## sloshes): CDDA's phase for the type (IdTables.Def.phase), else, with no phase (an older bridge), its "~" symbol.
## The type's phase: frozen water is still a liquid (the item's temp says it is frozen). null: no.
static func is_liquid(def: IdTables.Def) -> bool:
	return def != null and (def.phase == "liquid" or (def.phase == "" and def.symbol == LIQUID_SYMBOL))


## The colour a liquid shows in: its itype's CDDA colour (muted, CddaPalette), else LIQUID_DEFAULT.
static func liquid_color(def: IdTables.Def) -> Color:
	return CddaPalette.fg(def.color, LIQUID_DEFAULT) if def != null else LIQUID_DEFAULT
