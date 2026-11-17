class_name ContextPrompt
extends RefCounted
## Radial menus (user, 2026-11-16): the line by the crosshair that names the furniture (or terrain with an examine
## action) in the square you face and what E (a pad's A when the pad was used last: InputActions.prompt_of) does
## there: a tap does CDDA's default, a hold shows its choices on the wheel. The word comes from the id tables'
## `examine` (CDDA's examine action for the type, lead-bridge): a hint only, since what CDDA offers can depend on the
## moment (a fireplace lit or not). GrabController shows it when nothing else is under the pointer.

const MAX_NAME := 40
## CDDA examine action ids -> what E does there, as a verb; any other id: "examine". Without `examine` in the
## tables (an older bridge): "use".
const WORDS := {
	"fireplace": "light", "water_source": "drink", "finite_water_source": "drink", "clean_water_source": "drink",
	"toilet": "drink", "workbench": "craft", "door_peephole": "peek", "curtains": "open", "locked_object": "pry",
	"locked_object_pickable": "pick lock", "gaspump": "pump", "pay_gas": "pay", "keg": "tap", "vending": "buy",
	"atm": "bank", "bulletin_board": "read", "sign": "read", "elevator": "ride", "controls_gate": "operate",
	"cardreader": "swipe card", "rubble": "clear", "chainfence": "climb", "harvest_furn": "harvest",
	"harvest_ter": "harvest", "harvest_furn_nectar": "harvest", "harvest_ter_nectar": "harvest",
	"shrub_wildveggies": "forage", "dirtmound": "plant", "aggie_plant": "tend", "fvat_empty": "brew",
	"fvat_full": "brew", "kiln_empty": "fire", "kiln_full": "fire", "smoker_options": "smoke",
	"deployed_furniture": "take down", "portable_structure": "take down", "safe": "crack", "reload_furniture": "load",
	"autodoc": "operate", "workout": "exercise", "check_power": "check",
}


## The square's index in `layer` ("ter" or "furn") at an absolute square; 0 none or not loaded.
static func at(snap: Snapshot, p: Vector3i, layer := "furn") -> int:
	if snap == null:
		return 0
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return 0
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	var a: PackedInt32Array = sm.ter if layer == "ter" else sm.furn
	return a[i] if i >= 0 and i < a.size() else 0


## Furniture index at an absolute square; 0 none or not loaded.
static func furn_at(snap: Snapshot, p: Vector3i) -> int:
	return at(snap, p, "furn")


## What E does at a type with this examine id (`known`: the tables carry examine ids at all).
static func word_for(examine: String, known: bool) -> String:
	return str(WORDS.get(examine, "examine")) if known else "use"


## The prompt for square `p`: "<furniture>\nE light   hold E: choices"; terrain only when it has an examine
## action; "" when there is nothing to examine there. `menu`: HudSettings.context_menu (MENU_LIST: no wheel).
static func text(snap: Snapshot, tables: IdTables, p: Vector3i, menu: int) -> String:
	if tables == null:
		return ""
	var f := at(snap, p, "furn")
	var d: IdTables.Def = tables.def_at("furn", f) if f > 0 else null
	if d == null and tables.has_examine:
		var t := at(snap, p, "ter")
		d = tables.def_at("ter", t) if t > 0 else null
		if d != null and d.examine == "":
			d = null
	if d == null:
		return ""
	var name := CddaText.plain(d.name).strip_edges().left(MAX_NAME)
	if name.is_empty():
		return ""
	var k := InputActions.prompt_of(&"use_held")
	var verb := word_for(d.examine, tables.has_examine)
	if menu == HudSettings.MENU_LIST:
		return "%s\n%s %s" % [name.capitalize(), k, verb]
	return "%s\n%s %s   hold %s: choices" % [name.capitalize(), k, verb, k]
