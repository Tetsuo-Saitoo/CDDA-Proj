class_name IdTables
extends RefCounted
## What the ids in snapshots stand for (contracts/id_tables.md): terrain, furniture, trap, field and
## item definitions, read from the JSON form (the mock file, or CddaSim.get_id_tables_json() live).
##
## The input is hostile like a snapshot: every field the client reads is type-, range- and size-checked,
## and tables with any bad field are rejected whole ([member error] set, every table empty). A missing
## field takes its default; a present one must be valid (`mtype` may be missing: no monster names). `vpart`
## and `tables` aren't read yet,
## so they aren't trusted either: whoever starts using them adds their checks here.

const MAX_FILE_BYTES := 16 << 20          # the 0.I tables are ~2.7 MB
const MAX_ROWS := 65536                   # ter/furn/trap/field (CDDA has ~1.1k terrain)
const MAX_ITEMS := 1 << 17                # itype (~10k with core data; mods add more)
const MAX_ID := 128
const MAX_NAME := 256
const MAX_SYMBOL := 8
const MAX_COLOR := 48
const MAX_FLAGS := 256
const MAX_FLAG_LEN := 64
const MAX_GROUPS := 64
## Connect groups past this many get no bit (CDDA has ~36); they then join nothing.
const MAX_GROUP_BITS := 62
const TABLES := ["ter", "furn", "trap", "field", "itype", "mtype"]
const MAX_POCKETS := 32               # per itype, the contract's cap
const POCKET_RIGID := 1               # itype pocket flags (contracts/id_tables.md)
const POCKET_WATERTIGHT := 2
const POCKET_AIRTIGHT := 4
const POCKET_HOLSTER := 8
const POCKET_OPEN := 16
const POCKET_SEALABLE := 32
const POCKET_AMMO_ONLY := 64
const POCKET_RESTRICTED := 128
const POCKET_FORBIDDEN := 256         # the player can't use it
const POCKET_FLAGS := 511


class Def:
	var id := ""
	var name := ""
	var symbol := ""
	var color := ""
	var looks_like := ""
	var move_cost := 0       # ter: 0 impassable; furn: a modifier, -1 impassable
	var coverage := 0
	var transparent := false
	var flags := {}          # flag name -> true
	var groups := 0          # connect_groups as bits (see IdTables.group_bit)
	var connects_to := 0
	var rotates_to := 0
	var open := ""           # id of the open state (closed doors, windows)
	var close := ""          # id of the closed state
	var roof := ""           # ter: what is built on top of it
	var category := ""       # itype
	var gun_ammo := ""       # itype, guns: the first ammo type (9mm, 223, shot, arrow, ...)
	var weakpoints := {}     # mtype: CDDA weak point ids (head, eye, arm, leg, ...) -> true
	var gun := ""            # itype: the skill a gun uses (pistol, rifle, archery, ...), "" if not a gun
	var volume_ml := 0
	var weight_g := 0
	var size := 0           # mtype: CDDA's creature_size, 1 tiny .. 5 huge
	var species := {}       # mtype: species name -> true (HUMAN, ZOMBIE, MAMMAL, ...)
	var bodytype := ""      # mtype: CDDA's body type (human, dog, insect, ...), "" if the bridge doesn't say
	## itype: the type's own container pockets, the array index being the `pocket` for put/pour: each {name ("" when
	## not sent), volume_ml, max_weight_g, max_item_ml (-1 = only the volume), flags (POCKET_* bits)}. Empty when
	## the type holds nothing or the bridge doesn't send pockets. Filled while the tables load, never changed after
	## (meshing workers read Defs from other threads).
	var pockets: Array[Dictionary] = []

	func has(flag: String) -> bool:
		return flags.has(flag)


var error := ""
var generation := -1
var ter: Array[Def] = []
var furn: Array[Def] = []
var trap: Array[Def] = []
var field: Array[Def] = []
var itype: Array[Def] = []
var body_parts := PackedStringArray()   # body_part index -> id (tables.body_part), empty if missing
var mtype: Array[Def] = []
var group_bits := {}     # connect group name -> bit index
## Some itype row has `pockets`: the bridge sends them, so a type without any holds nothing.
var has_pockets := false
var _by_name := {}       # table -> {id -> index}
## Terrain ids built on top of a TREE (treetops) and of anything else (roofs).
var _treetops := {}
var _roofs := {}


func is_valid() -> bool:
	return error.is_empty()


static func load_file(path: String) -> IdTables:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return IdTables.new()._fail("cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	if f.get_length() > MAX_FILE_BYTES:
		return IdTables.new()._fail("%s is %d bytes, cap is %d" % [path, f.get_length(), MAX_FILE_BYTES])
	return parse_text(f.get_as_text())


static func parse_text(text: String) -> IdTables:
	if text.length() > MAX_FILE_BYTES:
		return IdTables.new()._fail("id tables text is longer than %d" % MAX_FILE_BYTES)
	var json := JSON.new()
	if json.parse(text) != OK:
		return IdTables.new()._fail("JSON line %d: %s" % [json.get_error_line(), json.get_error_message()])
	return from_data(json.data)


static func from_data(data: Variant) -> IdTables:
	var t := IdTables.new()
	t._read(data)
	if not t.is_valid():
		t._clear()
	return t


## Definition by table name and index, or null.
func def_at(table: String, index: int) -> Def:
	var list: Array[Def] = _table(table)
	return list[index] if index >= 0 and index < list.size() else null


## Index of a CDDA id in a table, -1 if absent.
func index_of(table: String, id: String) -> int:
	return (_by_name.get(table, {}) as Dictionary).get(id, -1)


func def_named(table: String, id: String) -> Def:
	return def_at(table, index_of(table, id))


func group_bit(group: String) -> int:
	return 1 << group_bits[group] if group_bits.has(group) else 0


## True when the terrain id is what some TREE has on top of it.
func is_treetop(id: String) -> bool:
	return _treetops.has(id)


## True when the terrain id is a built roof: the `roof` of some indoor floor or wall, and not itself
## ground (t_soil's roof is t_dirt) or a floor (basement ceilings are floors of the level above).
func is_roof(id: String) -> bool:
	return _roofs.has(id)


func _table(table: String) -> Array[Def]:
	match table:
		"ter": return ter
		"furn": return furn
		"trap": return trap
		"field": return field
		"itype": return itype
		"mtype": return mtype
	return []


func _fail(msg: String) -> IdTables:
	if error.is_empty():
		error = msg
	return self


func _clear() -> void:
	for t: String in TABLES:
		_table(t).clear()
	_by_name.clear()
	group_bits.clear()
	_treetops.clear()
	_roofs.clear()
	body_parts.clear()


func _read(data: Variant) -> void:
	if not data is Dictionary:
		_fail("top level is not an object")
		return
	var d: Dictionary = data
	generation = _int(d.get("generation"), 0, 0xFFFFFFFF, "generation")
	for t: String in TABLES:
		if t == "mtype" and d.get(t) == null:
			continue   # older tables: monsters go unnamed
		_read_table(t, d.get(t))
		if not is_valid():
			return
	_read_body_parts(d.get("tables"))
	_index_roofs()


func _read_body_parts(v: Variant) -> void:
	if not v is Dictionary:
		return
	var a: Variant = (v as Dictionary).get("body_part")
	if a == null:
		return
	if not a is Array or (a as Array).size() > MAX_ROWS:
		_fail("tables.body_part is not a list")
		return
	for i in (a as Array).size():
		body_parts.append(_str(a[i], MAX_ID, "tables.body_part[%d]" % i))


## The body_part id at an index ("" if unknown).
func body_part_name(index: int) -> String:
	return body_parts[index] if index >= 0 and index < body_parts.size() else ""


func _read_table(table: String, v: Variant) -> void:
	if not v is Array:
		_fail("%s is not a list" % table)
		return
	var rows: Array = v
	var cap := MAX_ITEMS if table == "itype" else MAX_ROWS
	if rows.size() > cap:
		_fail("%s: %d rows, cap is %d" % [table, rows.size(), cap])
		return
	var list: Array[Def] = _table(table)
	var names := {}
	_by_name[table] = names
	for i in rows.size():
		var what := "%s[%d]" % [table, i]
		if not rows[i] is Dictionary:
			_fail(what + " is not an object")
			return
		var r: Dictionary = rows[i]
		var def := Def.new()
		def.id = _str(r.get("id"), MAX_ID, what + ".id")
		def.name = _str(r.get("name"), MAX_NAME, what + ".name")
		def.symbol = _str(r.get("symbol"), MAX_SYMBOL, what + ".symbol")
		def.color = _str(r.get("color"), MAX_COLOR, what + ".color")
		def.looks_like = _str(r.get("looks_like"), MAX_ID, what + ".looks_like")
		if table == "ter" or table == "furn":
			def.move_cost = _int(r.get("move_cost"), -1000, 1000, what + ".move_cost")
			def.coverage = _int(r.get("coverage"), 0, 1000, what + ".coverage")
			def.transparent = _bool(r.get("transparent"), what + ".transparent")
			def.flags = _flags(r.get("flags"), what + ".flags")
			def.groups = _groups(r.get("connect_groups"), what + ".connect_groups")
			def.connects_to = _groups(r.get("connects_to"), what + ".connects_to")
			def.rotates_to = _groups(r.get("rotates_to"), what + ".rotates_to")
			def.open = _str(r.get("open"), MAX_ID, what + ".open")
			def.close = _str(r.get("close"), MAX_ID, what + ".close")
			def.roof = _str(r.get("roof"), MAX_ID, what + ".roof")
		elif table == "itype":
			def.category = _str(r.get("category"), MAX_FLAG_LEN, what + ".category")
			if r.has("gun"):
				def.gun = _str(r.get("gun"), MAX_FLAG_LEN, what + ".gun")
			def.gun_ammo = _str(r.get("gun_ammo"), MAX_FLAG_LEN, what + ".gun_ammo")
			def.volume_ml = _int(r.get("volume_ml"), 0, 1 << 40, what + ".volume_ml")
			def.weight_g = _int(r.get("weight_g"), 0, 1 << 40, what + ".weight_g")
			if r.has("pockets"):
				def.pockets = _pockets(r["pockets"], what + ".pockets")
				has_pockets = true
		elif table == "mtype":
			def.size = _int(r.get("size"), 0, 5, what + ".size")
			def.species = _flags(r.get("species"), what + ".species")
			def.bodytype = _str(r.get("bodytype"), MAX_FLAG_LEN, what + ".bodytype")
			def.weakpoints = _flags(r.get("weakpoints"), what + ".weakpoints")
		if not is_valid():
			return
		if not def.id.is_empty():
			if names.has(def.id):
				_fail("%s: id %s appears twice" % [what, def.id])
				return
			names[def.id] = i
		list.append(def)


func _index_roofs() -> void:
	for def: Def in ter:
		if def.roof.is_empty():
			continue
		if def.has("TREE"):
			_treetops[def.roof] = true
		elif def.has("INDOORS") or def.has("WALL") or def.has("WINDOW") or def.has("DOOR"):
			_roofs[def.roof] = true
	for id: String in _roofs.keys():
		var r := def_named("ter", id)
		if r == null or r.has("INDOORS") or r.has("DIGGABLE") or r.has("WALL") or r.has("NO_FLOOR") \
				or r.has("GOES_DOWN") or _treetops.has(id):
			_roofs.erase(id)


## itype pockets: a list of at most MAX_POCKETS {name?, volume_ml, max_weight_g, max_item_ml?, flags}.
func _pockets(v: Variant, what: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_POCKETS:
		_fail("%s: expected a list of at most %d" % [what, MAX_POCKETS])
		return out
	for i in (v as Array).size():
		var w := "%s[%d]" % [what, i]
		if not v[i] is Dictionary:
			_fail(w + " is not an object")
			return out
		var p: Dictionary = v[i]
		var pocket := {
			"name": _str(p.get("name"), MAX_NAME, w + ".name"),
			"volume_ml": _int(p.get("volume_ml"), 0, 1 << 40, w + ".volume_ml"),
			"max_weight_g": _int(p.get("max_weight_g"), 0, 1 << 40, w + ".max_weight_g"),
			"max_item_ml": _int(p["max_item_ml"], 0, 1 << 40, w + ".max_item_ml") if p.has("max_item_ml") else -1,
			"flags": _int(p.get("flags"), 0, POCKET_FLAGS, w + ".flags"),
		}
		if not is_valid():
			return []
		out.append(pocket)
	return out


func _int(v: Variant, lo: int, hi: int, what: String) -> int:
	if v == null or not is_valid():
		return 0
	if v is int and v >= lo and v <= hi:
		return v
	if v is float:
		var f: float = v
		if f == floorf(f) and f >= lo and f <= hi:   # false for NaN; infinities are out of range
			return int(f)
	_fail("%s: expected an integer in %d..%d" % [what, lo, hi])
	return 0


func _str(v: Variant, cap: int, what: String) -> String:
	if v == null or not is_valid():
		return ""
	if not v is String or (v as String).length() > cap:
		_fail("%s: expected a string of at most %d characters" % [what, cap])
		return ""
	return v


func _bool(v: Variant, what: String) -> bool:
	if v == null or not is_valid():
		return false
	if not v is bool:
		_fail(what + ": expected true or false")
		return false
	return v


func _flags(v: Variant, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_FLAGS:
		_fail("%s: expected a list of at most %d flags" % [what, MAX_FLAGS])
		return out
	for f: Variant in v:
		if not f is String or (f as String).length() > MAX_FLAG_LEN:
			_fail(what + ": bad flag")
			return out
		out[f] = true
	return out


func _groups(v: Variant, what: String) -> int:
	if v == null or not is_valid():
		return 0
	if not v is Array or (v as Array).size() > MAX_GROUPS:
		_fail("%s: expected a list of at most %d groups" % [what, MAX_GROUPS])
		return 0
	var bits := 0
	for g: Variant in v:
		if not g is String or (g as String).length() > MAX_FLAG_LEN:
			_fail(what + ": bad group")
			return 0
		if not group_bits.has(g) and group_bits.size() < MAX_GROUP_BITS:
			group_bits[g] = group_bits.size()
		if group_bits.has(g):
			bits |= 1 << group_bits[g]
	return bits
