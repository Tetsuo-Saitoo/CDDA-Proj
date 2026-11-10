class_name ItemRef
extends RefCounted
## Blocks E6 / L2 / L8: one item the player can point at, grab or carries, by its snapshot handle
## (contracts/snapshot.md: pile `handles`, the player's carried `items`). Only a reference: the sim finds the
## item again by uid + itype + square and refuses when it moved (contracts/bridge_api.md "Single items"), so
## nothing here is trusted beyond the snapshot's own checks. Shared by the flat-screen hands (ui/) and VR (vr/).

var uid := 0
var type := 0                       # itype index (IdTables.itype)
var square := Vector3i.ZERO         # where it lies; carried: the player's square
var carried := false
var flags := 0                      # Snapshot.CARRIED_* bits (carried only)
var parent := 0                     # carried: the container's uid, 0 on the body
var pocket := -1                    # carried: index into the parent's container pockets, -1 on the body
var spot := Vector2(-1, -1)         # where it was placed on its square, each 0..1 (x east, y south); -1 none
var point := Vector3.INF            # world point where it is drawn (INF: not drawn, e.g. carried)
var size_m := 0.0                   # drawn size (its longest side), 0 when not drawn


## An item in a pile on `sq` (a handle: spot in permille, -1 none).
static func on_square(item_uid: int, itype: int, sq: Vector3i, spot_x := -1, spot_y := -1) -> ItemRef:
	var r := ItemRef.new()
	r.uid = item_uid
	r.type = itype
	r.square = sq
	if spot_x >= 0 and spot_y >= 0:
		r.spot = Vector2(spot_x / 1000.0, spot_y / 1000.0)
	return r


## A carried item (one row of Snapshot.carried); `sq` is the player's square.
static func on_player(item_uid: int, itype: int, container: int, pocket_index: int, carried_flags: int,
		sq: Vector3i) -> ItemRef:
	var r := ItemRef.new()
	r.uid = item_uid
	r.type = itype
	r.square = sq
	r.carried = true
	r.parent = container
	r.pocket = pocket_index
	r.flags = carried_flags
	return r


func is_worn() -> bool:
	return carried and (flags & Snapshot.CARRIED_WORN) != 0


func is_wielded() -> bool:
	return carried and (flags & Snapshot.CARRIED_WIELDED) != 0


func is_off_hand() -> bool:
	return carried and (flags & Snapshot.CARRIED_OFFHAND) != 0


## In a hand (main or off).
func in_hand() -> bool:
	return is_wielded() or is_off_hand()


func is_drawn() -> bool:
	return point.is_finite()


func has_spot() -> bool:
	return spot.x >= 0.0 and spot.y >= 0.0


## The same item as `o` (uid and itype: a uid the sim gave another itype is another item).
func same(o: ItemRef) -> bool:
	return o != null and o.uid == uid and o.type == type


## The itype's definition, null without tables or for an index they don't have.
func def(tables: IdTables) -> IdTables.Def:
	return tables.def_at("itype", type) if tables != null else null


## Volume and weight of one such item from the id tables (0 when unknown; a stack counts as one).
func volume_ml(tables: IdTables) -> int:
	var d := def(tables)
	return d.volume_ml if d != null else 0


func weight_g(tables: IdTables) -> int:
	var d := def(tables)
	return d.weight_g if d != null else 0


## Needs both hands, CDDA's rule (item::is_two_handed): the ALWAYS_TWOHAND flag, or heavier than the character's
## strength x 4 quarter-pounds (113 g). A client estimate for how a hand carries it; the sim still decides.
func two_handed(tables: IdTables, strength := 8) -> bool:
	var d := def(tables)
	if d == null:
		return false
	return d.has("ALWAYS_TWOHAND") or d.weight_g / 113 > strength * 4


## Holds other items (MockItems.is_container: the id tables' pockets when the bridge sends them, else category).
func is_container(tables: IdTables) -> bool:
	return MockItems.is_container(type, tables)


## Display name: the id tables' name, else its id, else "item #<index>".
func display_name(tables: IdTables) -> String:
	var d := def(tables)
	if d != null:
		return d.name if not d.name.is_empty() else d.id
	return "item #%d" % type


func duplicate_ref() -> ItemRef:
	var r := ItemRef.new()
	r.uid = uid
	r.type = type
	r.square = square
	r.carried = carried
	r.flags = flags
	r.parent = parent
	r.pocket = pocket
	r.spot = spot
	r.point = point
	r.size_m = size_m
	return r


func _to_string() -> String:
	return "ItemRef(%d, type %d, %s%s)" % [uid, type, "carried" if carried else str(square),
			(" spot %s" % spot) if has_spot() else ""]
