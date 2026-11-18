class_name Vise
extends RefCounted
## Gun modification, vise (V1 VR in VrGun; V2 the flat screen): a bench vise (CDDA's `bench_vise`, tool quality VISE 3)
## lying on the player's square or one of the 8 around it holds the wielded gun so both hands are free to fit mods.
## Only the client shows the gun in it: CDDA still wields it, and nothing about it goes to CDDA. Snapshot data only
## (the submaps' checked handles), capped.

const ITEM := "bench_vise"
const MAX_NEAR := 8        # vises looked at, at most
const JAWS_UP := 0.05      # its jaws: this far (m) above the middle of the drawn item


## The uids of the bench vises lying on the player's square and the 8 around it (same level) with handles, at most
## MAX_NEAR, in the snapshot's order; [] without a snapshot or the id tables' `bench_vise`.
static func near(s: Snapshot, tables: IdTables) -> Array[int]:
	var out: Array[int] = []
	var t := tables.index_of("itype", ITEM) if tables != null else -1
	if s == null or t <= 0:
		return out
	var seen := {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var smp := CddaCoords.ms_to_sm(s.player_pos + Vector3i(dx, dy, 0))
			if seen.has(smp):
				continue
			seen[smp] = true
			var sm: Snapshot.Submap = s.submaps.get(smp)
			if sm == null:
				continue
			var h := sm.handles
			for k in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
				if h[k + 2] != t or not s.near_player(smp, int(h[k])) or out.has(int(h[k + 1])):
					continue
				out.append(int(h[k + 1]))
				if out.size() >= MAX_NEAR:
					return out
	return out


## Where vise `uid` holds a gun (world): JAWS_UP above the middle of the item as drawn (ItemPicker.slot: its pile's
## slot or its physics body); null when it isn't drawn (held by a hand, gone, or not built).
static func jaws(picker: ItemPicker, uid: int) -> Variant:
	if picker == null or uid <= 0:
		return null
	var e := picker.slot(uid)
	if e.size() < 4 or not e[3] is Vector3 or not (e[3] as Vector3).is_finite():
		return null
	return (e[3] as Vector3) + Vector3.UP * JAWS_UP
