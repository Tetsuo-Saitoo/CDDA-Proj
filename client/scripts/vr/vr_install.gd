class_name VrInstall
extends RefCounted
## C6 vehicle work by hand, slice 2 (lead-vr; TASKS C6 (e)): installing by holding a part item to a vehicle's square.
## Which part types an item in the hand installs as (lead-bridge's `item` on each vpart id-table row, read onto
## IdTables.Def.item by lead-world: the itype index of the type's base item; not one to one), and of those the ones
## CDDA's install read for the lit square says fit there (VehicleWorkData.FITS). CDDA decides the rest: VrRig sends
## "i" through the session, for the one type left or the one picked from a list.

const MAX_TYPES := 64   # part types one item serves, kept
const MAX_LIST := 8     # types offered on the list

static var _types := {}       # itype -> PackedInt32Array of vpart rows
static var _key := []         # [tables instance id, generation, vpart rows] _types was built for


## The vpart rows an item of type `itype` installs as; [] none (or a bridge without `item`).
static func types_for(tables: IdTables, itype: int) -> PackedInt32Array:
	if tables == null or itype <= 0:
		return PackedInt32Array()
	var key := [tables.get_instance_id(), tables.generation, tables.vpart.size()]
	if key != _key:
		_key = key
		_types = {}
		for i in tables.vpart.size():
			var d := tables.vpart[i]
			var it := d.item if d != null else 0
			if it <= 0:
				continue
			var a: PackedInt32Array = _types.get(it, PackedInt32Array())
			if a.size() < MAX_TYPES:
				a.append(i)
				_types[it] = a
	return _types.get(itype, PackedInt32Array())


## Of install section `inst` (a read's "install", VehicleWorkData.clean), the types in `types` that fit its square,
## in CDDA's order, at most MAX_LIST: [{vpart, name, have}] (VehicleWorkData.install_rows; `name_of` (vpart) -> String).
static func choices(inst: Dictionary, types: PackedInt32Array, name_of: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in VehicleWorkData.install_rows(inst, name_of):
		if types.has(row["vpart"]):
			out.append(row)
			if out.size() >= MAX_LIST:
				break
	return out


## Whether read `r` answers the install read for square `at` of vehicle `uid` (or refuses for that vehicle).
static func is_for(r: Dictionary, uid: int, at: Vector2i) -> bool:
	var v: Variant = r.get("vehicle")
	if not v is int or v != uid:
		return false
	if not VrWorkMenu.is_ok(r):
		return true
	var inst: Variant = r.get("install")
	return inst is Dictionary and (inst as Dictionary).get("mount") == at
