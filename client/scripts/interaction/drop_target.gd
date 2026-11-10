class_name DropTarget
extends RefCounted
## Blocks E6 / L8: what letting go of a held item does where the pointer (mouse) or the hand (VR) is: into the
## container under it, onto a burner or a surface (with the spot it lands on), or nothing. Only what the hands
## show and send: CDDA still decides (ItemActions sends it, the sim refuses or not).

## CDDA furniture that holds a fire or heats what is put in or on it (ids checked against the 0.I id tables).
## A stand-in until the bridge says which furniture is a heat source.
const HEAT_SOURCES := {
	"f_fireplace": true, "f_fireplace_stone": true, "f_woodstove": true, "f_brazier": true,
	"f_makeshift_brazier": true, "f_hobo_stove": true, "f_portable_stove": true, "f_55gal_firebarrel": true,
	"f_30gal_firebarrel": true, "f_firering": true, "f_clay_oven": true, "f_oven": true, "f_kiln_empty": true,
	"f_kiln_portable_empty": true, "f_kiln_metal_empty": true, "f_exodii_kiln": true,
}
const SPOT_MAX := 0.999


## `hit`: a LookRay.cast() result; `under`: the item under the pointer or hand (null for none); `held`: what is
## let go; `in_reach(square) -> bool`. Returns {kind: "container" / "burner" / "surface" / "none", square,
## spot (Vector2 each 0..0.999 across the square, x east, y south; -1 none), container (ItemRef or null)}.
static func resolve(coords: CddaCoords, hit: Dictionary, under: ItemRef, held: ItemRef, tables: IdTables,
		snap: Snapshot, in_reach: Callable) -> Dictionary:
	var out := {"kind": "none", "square": Vector3i.ZERO, "spot": Vector2(-1, -1), "container": null}
	if held == null:
		return out
	if under != null and under.uid > 0 and under.uid != held.uid and MockItems.is_container(under.type, tables) \
			and (under.carried or _reach(in_reach, under.square)) and not _inside(snap, under.uid, held.uid):
		out["kind"] = "container"
		out["square"] = under.square
		out["container"] = under
		return out
	var h: Variant = hit.get("hit")
	var sq: Variant = hit.get("square")
	var pt: Variant = hit.get("point")
	var what: Variant = hit.get("what")
	if not (h is bool and h) or not sq is Vector3i or not pt is Vector3 or not (pt as Vector3).is_finite() \
			or not what is String:
		return out
	out["square"] = sq
	if (what != "furniture" and what != "floor") or not _reach(in_reach, sq):
		return out
	out["spot"] = _spot(coords, sq, pt)
	var burner: bool = what == "furniture" and is_heat_source(furniture_id(sq, snap, tables))
	out["kind"] = "burner" if burner else "surface"
	return out


static func is_heat_source(furn_id: String) -> bool:
	return HEAT_SOURCES.has(furn_id)


## The CDDA id of the furniture on square p ("" for none or unknown): the id tables' when they match the
## snapshot, else the snapshot's own name.
static func furniture_id(p: Vector3i, snap: Snapshot, tables: IdTables) -> String:
	if snap == null:
		return ""
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	var i := ItemActions.tile_of(p)
	if sm == null or i >= sm.furn.size() or sm.furn[i] <= 0:
		return ""
	var f := sm.furn[i]
	if tables != null and (snap.ids_generation < 0 or snap.ids_generation == tables.generation):
		var d := tables.def_at("furn", f)
		if d != null:
			return d.id
	var n: Variant = snap.furn_names.get(f, "")
	return n if n is String else ""


## Where `point` lies across square `sq`, each 0..SPOT_MAX (x east = +X, y south = +Z).
static func _spot(coords: CddaCoords, sq: Vector3i, point: Vector3) -> Vector2:
	if coords == null:
		return Vector2(-1, -1)
	var f := (point - coords.ms_to_world(sq)) / CddaCoords.TILE_M
	return Vector2(clampf(f.x, 0.0, SPOT_MAX), clampf(f.z, 0.0, SPOT_MAX))


static func _reach(in_reach: Callable, sq: Vector3i) -> bool:
	if not in_reach.is_valid():
		return false
	var r: Variant = in_reach.call(sq)
	return r is bool and r


## True when carried item `uid` is (nested) inside carried item `outer`.
static func _inside(snap: Snapshot, uid: int, outer: int) -> bool:
	if snap == null:
		return false
	var parent := {}
	var c := snap.carried
	for i in range(0, c.size() - Snapshot.CARRIED_STRIDE + 1, Snapshot.CARRIED_STRIDE):
		parent[c[i]] = c[i + 2]
	var at := uid
	for _step in Snapshot.MAX_CARRIED:
		at = parent.get(at, 0)
		if at == 0:
			return false
		if at == outer:
			return true
	return false
