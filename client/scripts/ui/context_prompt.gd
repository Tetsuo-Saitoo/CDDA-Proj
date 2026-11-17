class_name ContextPrompt
extends RefCounted
## Radial menus (user, 2026-11-16): the line by the crosshair that names the furniture in the square you face and
## what E (a pad's A when the pad was used last: InputActions.prompt_of) does there: a tap uses it (CDDA's default),
## a hold shows its choices on the wheel. GrabController shows it when nothing else is under the pointer.

const MAX_NAME := 40


## Furniture index at an absolute square; 0 none or not loaded.
static func furn_at(snap: Snapshot, p: Vector3i) -> int:
	if snap == null:
		return 0
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return 0
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	return sm.furn[i] if i >= 0 and i < sm.furn.size() else 0


## The prompt for square `p`: "<furniture>\nE use   hold E: choices"; "" when no furniture is there.
## `menu`: HudSettings.context_menu (MENU_LIST: no wheel to mention).
static func text(snap: Snapshot, tables: IdTables, p: Vector3i, menu: int) -> String:
	var f := furn_at(snap, p)
	var d: IdTables.Def = tables.def_at("furn", f) if f > 0 and tables != null else null
	if d == null:
		return ""
	var name := CddaText.plain(d.name).strip_edges().left(MAX_NAME)
	if name.is_empty():
		return ""
	var k := InputActions.prompt_of(&"use_held")
	if menu == HudSettings.MENU_LIST:
		return "%s\n%s use" % [name.capitalize(), k]
	return "%s\n%s use   hold %s: choices" % [name.capitalize(), k, k]
