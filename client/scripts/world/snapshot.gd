class_name Snapshot
extends RefCounted
## One validated snapshot of the reality bubble (contracts/snapshot.md), read from the JSON form.
##
## The input is hostile. Every field the client uses is type-, range- and size-checked here, and a
## snapshot with any bad field is rejected whole: [member error] is set and [member submaps] is empty.
## Fields the client doesn't use yet (vehicles) are ignored, not trusted; whoever
## starts using them adds their checks here. A submap without `trap` or `items` has none.

const CONTRACT_VERSION := 0
const TILES := 144
const MAX_FILE_BYTES := 16 << 20          # a full 21-level bubble is ~6 MB of JSON
const MAX_ID := 1 << 20                   # CDDA has ~1.1k terrain ids; anything larger is garbage
const MAX_REVISION := 0xFFFFFFFF
const MAX_ABS_SM := 1 << 26               # keeps absolute squares (x 12) well inside int32
const MAX_TURN := 1 << 52                 # JSON numbers are doubles
const MAX_NAMES := 65536
const MAX_NAME_LEN := 128
const MAX_ITEM_COUNT := 0xFFFF            # uint16 in the contract
const MAX_CREATURES := 1024               # the contract's cap
const MAX_UID := 1 << 53                  # JSON numbers are doubles
const PILE_STRIDE := 8                    # items: tile, count, top[4], corpse, corpse state
const PILE_TOP_END := 6                   # top[4] is at [2, PILE_TOP_END)
const PILE_CORPSE := 6                    # mtype index of the largest corpse on the tile, 0 = none
const PILE_CORPSE_STATE := 7              # its butchery state, CORPSE_* bits
const CORPSE_BLED := 1
const CORPSE_FIELD_DRESSED := 2
const CORPSE_DRESS_FAILED := 4
const CORPSE_SKINNED := 8
const CORPSE_QUARTERED := 16
const CORPSE_PULPED := 32
const CORPSE_GIBBED := 64
const HANDLE_STRIDE := 5                  # handles: tile, uid, itype, spot x, spot y (permille, -1 none)
const MAX_HANDLES_PER_TILE := 32
const CARRIED_STRIDE := 5                 # carried: uid, itype, parent uid (0 on the body), pocket, flags
const MAX_CARRIED := 256
const MAX_POCKET := 255
const CARRIED_WORN := 1
const CARRIED_WIELDED := 2
const CARRIED_OFFHAND := 4
const FIELD_STRIDE := 4                   # fields: tile, type (CDDA field id), intensity, age turns
const MAX_FIELDS_PER_TILE := 4
const MAX_BODY_PARTS := 32                # CDDA has 12 main parts
const MAX_WORN := 64                      # the contract's cap

const FLAG_ROOF := 1        # not outside
const FLAG_NO_FLOOR := 2    # open air or a hole
const FLAG_SIGN := 4
const FLAG_VEHICLE := 8


class Submap:
	var pos: Vector3i
	var revision: int
	var detail_revision: int
	var ter: PackedInt32Array     # index = y * 12 + x
	var furn: PackedInt32Array
	var trap: PackedInt32Array    # CDDA trap ids, 0 = none (only traps the player knows)
	var items: PackedInt32Array   # piles, PILE_STRIDE ints each: tile, count, top[4] (itype indices, 0 = none), corpse (mtype index, 0 = none)
	var fields: PackedInt32Array  # FIELD_STRIDE ints each (seen tiles only)
	var handles: PackedInt64Array # HANDLE_STRIDE ints per item a client can point at (seen tiles only)
	var flags: PackedByteArray
	var vis: PackedByteArray      # 0 never seen, 1 remembered, 2 seen, 3 in sight but dark
	var light: PackedByteArray


var error := ""
var turn := 0
var seq := 0
var ids_generation := -1   # -1: the snapshot doesn't say
## The map's whole z range (`z_levels`, CddaCoords defaults when absent). Every z in the snapshot is inside it.
var z_min := CddaCoords.Z_MIN_DEFAULT
var z_max := CddaCoords.Z_MAX_DEFAULT
var bubble_origin := Vector3i.ZERO
var player_pos := Vector3i.ZERO
var player_wielded := 0                    # itype index of what the player holds, 0 for nothing
var player_parts: Array[BodyPart] = []     # the player's main body parts (hp, wounds), snapshot order
var player_worn: Array[Worn] = []          # what the player wears, inner to outer
var carried := PackedInt64Array()          # CARRIED_STRIDE ints per carried item, depth first
var creatures: Array[Creature] = []        # the ones the player perceives, the player first
var _creature_at := {}                     # Vector3i -> Creature, built on first use
var sun_alt_deg := 45.0
var sun_az_deg := 180.0
var submaps := {}       # Vector3i (absolute submap) -> Submap
var ter_names := {}     # int -> String
var furn_names := {}    # int -> String
var trap_names := {}    # int -> String


## One of the player's body parts (contracts/snapshot.md player_view arrays).
class BodyPart:
	var id := 0            # body_part index (IdTables.body_parts names it)
	var hp := 0
	var hp_max := 0
	var bleed := 0         # effect intensities, 0 = none
	var bandaged := 0
	var disinfected := 0
	var bite := 0
	var infected := 0


## A worn item (contracts/snapshot.md worn_view).
class Worn:
	var type := 0          # itype index
	var layer := 0         # CDDA layer_level, 0 personal .. 5 aux
	var damage := 0        # 0 fine .. 5 nearly destroyed
	var degradation := 0   # 0..255
	var covers := PackedInt32Array()   # body_part indices


## A creature the player perceives (contracts/snapshot.md creature_view).
class Creature:
	const PLAYER := 0
	const NPC := 1
	const MONSTER := 2
	const UNKNOWN := -1   # attitudes: CDDA's Attitude (to the player) order; UNKNOWN when the bridge doesn't say
	const HOSTILE := 0
	const NEUTRAL := 1
	const FRIENDLY := 2
	var uid := 0
	var kind := MONSTER
	var type := 0        # mtype index (monsters), 0 otherwise
	var pos := Vector3i.ZERO
	var hp_frac := 255   # 0..255
	var attitude := UNKNOWN

	## Hostile to the player. Without an attitude from the bridge, monsters count as hostile and people don't.
	func is_hostile() -> bool:
		if kind == PLAYER:
			return false
		return attitude == HOSTILE or (attitude == UNKNOWN and kind == MONSTER)


func is_valid() -> bool:
	return error.is_empty()


static func load_file(path: String) -> Snapshot:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return Snapshot.new()._fail("cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	if f.get_length() > MAX_FILE_BYTES:
		return Snapshot.new()._fail("%s is %d bytes, cap is %d" % [path, f.get_length(), MAX_FILE_BYTES])
	return parse_text(f.get_as_text())


static func parse_text(text: String) -> Snapshot:
	if text.length() > MAX_FILE_BYTES:
		return Snapshot.new()._fail("snapshot text is longer than %d" % MAX_FILE_BYTES)
	var json := JSON.new()
	if json.parse(text) != OK:
		return Snapshot.new()._fail("JSON line %d: %s" % [json.get_error_line(), json.get_error_message()])
	return from_data(json.data)


## Builds from already-parsed JSON data (Dictionary/Array/String/float/bool/null).
static func from_data(data: Variant) -> Snapshot:
	var snap := Snapshot.new()
	snap._read(data)
	if not snap.is_valid():
		snap.submaps.clear()
		snap.ter_names.clear()
		snap.furn_names.clear()
		snap.trap_names.clear()
		snap.creatures.clear()
	return snap


func _fail(msg: String) -> Snapshot:
	if error.is_empty():
		error = msg
	return self


func _read(data: Variant) -> void:
	if not data is Dictionary:
		_fail("top level is not an object")
		return
	var d: Dictionary = data
	var version := _int(d.get("contract_version"), 0, 0xFFFF, "contract_version")
	if is_valid() and version != CONTRACT_VERSION:
		_fail("contract_version %d, this client reads %d" % [version, CONTRACT_VERSION])
	turn = _int(d.get("turn"), -MAX_TURN, MAX_TURN, "turn")
	seq = _int(d.get("seq"), 0, MAX_TURN, "seq")
	if d.has("ids_generation"):
		ids_generation = _int(d["ids_generation"], 0, 0xFFFFFFFF, "ids_generation")
	if d.has("z_levels"):
		_read_z_levels(d["z_levels"])
	bubble_origin =_vec3i(d.get("bubble_origin"), MAX_ABS_SM, "bubble_origin")
	if is_valid() and bubble_origin.z != 0:
		_fail("bubble_origin z must be 0")
	_read_player(d.get("player"))
	_read_env(d.get("env"))
	_read_ids(d.get("ids"))
	_read_submaps(d.get("submaps"))
	_read_creatures(d.get("creatures"))


## [min, max]: the map's z range. It must hold z 0 and stay within CddaCoords.Z_LIMIT either way.
func _read_z_levels(v: Variant) -> void:
	if not is_valid():
		return
	if not v is Array or (v as Array).size() != 2:
		_fail("z_levels: expected [min, max]")
		return
	var lo := _int(v[0], -CddaCoords.Z_LIMIT, 0, "z_levels min")
	var hi := _int(v[1], 0, CddaCoords.Z_LIMIT, "z_levels max")
	if is_valid():
		z_min = lo
		z_max = hi


## The most submaps a snapshot can list: the whole bubble on every level of its z range.
func max_submaps() -> int:
	return CddaCoords.MAPSIZE * CddaCoords.MAPSIZE * (z_max - z_min + 1)


func _read_player(v: Variant) -> void:
	player_pos = CddaCoords.sm_to_ms(bubble_origin) + Vector3i(66, 66, 0)   # bubble centre
	if v == null or not is_valid():
		return
	if not v is Dictionary:
		_fail("player is not an object")
		return
	var p: Variant = (v as Dictionary).get("pos")
	if p != null:
		player_pos = _vec3i(p, MAX_ABS_SM * CddaCoords.SEEX, "player.pos")
	var w: Variant = (v as Dictionary).get("wielded")
	if w != null:
		player_wielded = _int(w, 0, MAX_ID, "player.wielded")
	_read_body((v as Dictionary))
	_read_worn((v as Dictionary).get("worn"))
	carried = _carried((v as Dictionary).get("items"), "player.items")


func _read_body(d: Dictionary) -> void:
	var ids: Variant = d.get("body_parts")
	if ids == null or not is_valid():
		return
	if not ids is Array:
		_fail("player.body_parts: expected a list")
		return
	var all := (ids as Array).size()
	var n := mini(all, MAX_BODY_PARTS)   # parts past the cap (a mod's) aren't drawn
	var cols := {}
	for key: String in ["hp", "hp_max", "bleed", "bandaged", "disinfected", "bite", "infected"]:
		var a: Variant = d.get(key)
		if a == null:
			continue   # older bridges: no wounds
		if not a is Array or (a as Array).size() != all:
			_fail("player.%s: expected %d values" % [key, all])
			return
		cols[key] = a
	for i in n:
		var b := BodyPart.new()
		b.id = _int(ids[i], 0, MAX_ID, "player.body_parts[%d]" % i)
		b.hp = _int(cols["hp"][i], -32768, 32767, "player.hp") if cols.has("hp") else 1
		b.hp_max = _int(cols["hp_max"][i], -32768, 32767, "player.hp_max") if cols.has("hp_max") else 1
		for key: String in ["bleed", "bandaged", "disinfected", "bite", "infected"]:
			if cols.has(key):
				b.set(key, _int(cols[key][i], 0, 255, "player." + key))
		if not is_valid():
			return
		player_parts.append(b)


func _read_worn(v: Variant) -> void:
	if v == null or not is_valid():
		return
	if not v is Array or (v as Array).size() > MAX_WORN:
		_fail("player.worn: expected a list of at most %d" % MAX_WORN)
		return
	for i in (v as Array).size():
		var what := "player.worn[%d]" % i
		var r: Variant = v[i]
		if not r is Dictionary:
			_fail(what + " is not an object")
			return
		var w := Worn.new()
		w.type = _int(r.get("type"), 0, MAX_ID, what + ".type")
		w.layer = _int(r.get("layer", 2), 0, 255, what + ".layer")
		w.damage = _int(r.get("damage", 0), 0, 255, what + ".damage")
		w.degradation = _int(r.get("degradation", 0), 0, 255, what + ".degradation")
		var c: Variant = r.get("covers")
		if not c is Array:
			_fail(what + ".covers: expected a list")
			return
		for k in mini((c as Array).size(), MAX_BODY_PARTS * 4):   # each part once, at most MAX_BODY_PARTS
			var x := _int(c[k], 0, MAX_ID, what + ".covers")
			if w.covers.size() < MAX_BODY_PARTS and not w.covers.has(x):
				w.covers.append(x)
		if not is_valid():
			return
		player_worn.append(w)


func _read_creatures(v: Variant) -> void:
	if v == null or not is_valid():
		return
	if not v is Array or (v as Array).size() > MAX_CREATURES:
		_fail("creatures: expected a list of at most %d" % MAX_CREATURES)
		return
	for i in (v as Array).size():
		var what := "creatures[%d]" % i
		var r: Variant = v[i]
		if not r is Dictionary:
			_fail(what + " is not an object")
			return
		var c := Creature.new()
		c.uid = _int(r.get("uid"), 0, MAX_UID, what + ".uid")
		c.kind = _int(r.get("kind"), 0, 2, what + ".kind")
		c.type = _int(r.get("type", 0), 0, MAX_ID, what + ".type")
		c.pos = _vec3i(r.get("pos"), MAX_ABS_SM * CddaCoords.SEEX, what + ".pos")
		c.hp_frac = _int(r.get("hp_frac", 255), 0, 255, what + ".hp_frac")
		if r.has("attitude"):
			c.attitude = _int(r["attitude"], Creature.HOSTILE, Creature.FRIENDLY, what + ".attitude")
		if not is_valid():
			return
		creatures.append(c)


## Call after changing creature positions (tests, demos): creature_at() rebuilds its index.
func creatures_moved() -> void:
	_creature_at.clear()


## The creature (not the player) standing on square p, or null.
func creature_at(p: Vector3i) -> Creature:
	if _creature_at.is_empty():
		for c in creatures:
			if c.kind != Creature.PLAYER:
				_creature_at[c.pos] = c
		_creature_at[Vector3i.MAX] = null   # built, even when nobody is there
	return _creature_at.get(p)


func _read_env(v: Variant) -> void:
	if v == null or not is_valid():
		return
	if not v is Dictionary:
		_fail("env is not an object")
		return
	var e: Dictionary = v
	if e.has("sun_alt_deg"):
		sun_alt_deg = _float(e["sun_alt_deg"], -90.0, 90.0, "env.sun_alt_deg")
	if e.has("sun_az_deg"):
		sun_az_deg = _float(e["sun_az_deg"], -360.0, 360.0, "env.sun_az_deg")


func _read_ids(v: Variant) -> void:
	if v == null or not is_valid():
		return
	if not v is Dictionary:
		_fail("ids is not an object")
		return
	ter_names = _names((v as Dictionary).get("ter"), "ids.ter")
	furn_names = _names((v as Dictionary).get("furn"), "ids.furn")
	trap_names = _names((v as Dictionary).get("trap"), "ids.trap")


func _read_submaps(v: Variant) -> void:
	if not is_valid():
		return
	if not v is Array:
		_fail("submaps is not a list")
		return
	var list: Array = v
	if list.size() > max_submaps():
		_fail("%d submaps, cap is %d" % [list.size(), max_submaps()])
		return
	var lo := bubble_origin
	for i in list.size():
		var what := "submaps[%d]" % i
		if not list[i] is Dictionary:
			_fail(what + " is not an object")
			return
		var s: Dictionary = list[i]
		var sm := Submap.new()
		sm.pos = _vec3i(s.get("pos"), MAX_ABS_SM, what + ".pos")
		if not is_valid():
			return
		var rel := sm.pos - lo
		if rel.x < 0 or rel.x >= CddaCoords.MAPSIZE or rel.y < 0 or rel.y >= CddaCoords.MAPSIZE \
				or sm.pos.z < z_min or sm.pos.z > z_max:
			_fail("%s.pos %s is outside the bubble" % [what, sm.pos])
			return
		if submaps.has(sm.pos):
			_fail("%s.pos %s appears twice" % [what, sm.pos])
			return
		sm.revision = _int(s.get("revision"), 0, MAX_REVISION, what + ".revision")
		sm.detail_revision = _int(s.get("detail_revision"), 0, MAX_REVISION, what + ".detail_revision")
		sm.ter = _ids(s.get("ter"), what + ".ter")
		sm.furn = _ids(s.get("furn"), what + ".furn")
		sm.trap = _ids(s["trap"], what + ".trap") if s.has("trap") else _zeros()
		sm.items = _piles(s.get("items"), what + ".items")
		sm.fields = _fields(s.get("fields"), what + ".fields")
		sm.handles = _handles(s.get("handles"), what + ".handles")
		sm.flags = _bytes(s.get("flags"), 255, what + ".flags")
		sm.vis = _bytes(s.get("vis"), 3, what + ".vis")
		sm.light = _bytes(s.get("light"), 255, what + ".light")
		if not is_valid():
			return
		submaps[sm.pos] = sm


## Integer in [lo, hi]; JSON gives every number as a float, so integral floats are accepted.
func _int(v: Variant, lo: int, hi: int, what: String) -> int:
	if not is_valid():
		return 0
	if v is int:
		if v < lo or v > hi:
			_fail("%s: %d is outside %d..%d" % [what, v, lo, hi])
			return 0
		return v
	if v is float:
		var f: float = v
		# Also catches NaN (f != floor(f)) and infinities (out of range).
		if f != floorf(f) or f < lo or f > hi:
			_fail("%s: %s is not an integer in %d..%d" % [what, f, lo, hi])
			return 0
		return int(f)
	_fail("%s: expected an integer" % what)
	return 0


func _float(v: Variant, lo: float, hi: float, what: String) -> float:
	if not is_valid():
		return 0.0
	if not (v is float or v is int):
		_fail("%s: expected a number" % what)
		return 0.0
	var f := float(v)
	if not (f >= lo and f <= hi):   # false for NaN
		_fail("%s: %s is outside %s..%s" % [what, f, lo, hi])
		return 0.0
	return f


func _vec3i(v: Variant, limit: int, what: String) -> Vector3i:
	if not is_valid():
		return Vector3i.ZERO
	if not v is Array or (v as Array).size() != 3:
		_fail("%s: expected [x, y, z]" % what)
		return Vector3i.ZERO
	var a: Array = v
	return Vector3i(_int(a[0], -limit, limit, what + ".x"), _int(a[1], -limit, limit, what + ".y"),
			_int(a[2], z_min, z_max, what + ".z"))


## 144 CDDA int ids. Ids with no name in the table are allowed; they render as unknown boxes.
func _ids(v: Variant, what: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not is_valid():
		return out
	if not v is Array or (v as Array).size() != TILES:
		_fail("%s: expected a list of %d ids" % [what, TILES])
		return out
	var a: Array = v
	out.resize(TILES)
	for i in TILES:
		var x: Variant = a[i]
		if x is float:
			var f: float = x
			if f != floorf(f) or f < 0.0 or f > MAX_ID:
				_fail("%s[%d]: %s is not an id" % [what, i, f])
				return out
			out[i] = int(f)
		elif x is int and x >= 0 and x <= MAX_ID:
			out[i] = x
		else:
			_fail("%s[%d]: not an id" % [what, i])
			return out
	return out


static func _zeros() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(TILES)
	return out


## [[tile, count, [top...]], ...]: at most one pile per tile, at most 4 top itypes.
func _piles(v: Variant, what: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > TILES:
		_fail("%s: expected a list of at most %d piles" % [what, TILES])
		return out
	var seen := {}
	for i in (v as Array).size():
		var p: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if (not p is Array or (p as Array).size() < 3 or (p as Array).size() > 5 or not p[2] is Array
				or (p[2] as Array).size() > 4):
			_fail(w + ": expected [tile, count, [up to 4 itypes], corpse mtype, corpse state (both optional)]")
			return out
		var tile := _int(p[0], 0, TILES - 1, w + ".tile")
		var count := _int(p[1], 0, MAX_ITEM_COUNT, w + ".count")
		if is_valid() and seen.has(tile):
			_fail("%s: tile %d has two piles" % [w, tile])
		seen[tile] = true
		out.append(tile)
		out.append(count)
		var top: Array = p[2]
		for k in 4:
			out.append(_int(top[k], 0, MAX_ID, w + ".top") if k < top.size() else 0)
		out.append(_int(p[3], 0, MAX_ID, w + ".corpse") if (p as Array).size() > 3 else 0)
		out.append(_int(p[4], 0, 0xffff, w + ".corpse_state") if (p as Array).size() > 4 else 0)
		if not is_valid():
			return out
	return out


## [[tile, uid, type, spot_x, spot_y], ...]: at most MAX_HANDLES_PER_TILE per tile, distinct uids.
func _handles(v: Variant, what: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > TILES * MAX_HANDLES_PER_TILE:
		_fail("%s: expected a list of at most %d handles" % [what, TILES * MAX_HANDLES_PER_TILE])
		return out
	var per_tile := {}
	var uids := {}
	for i in (v as Array).size():
		var h: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not h is Array or (h as Array).size() != HANDLE_STRIDE:
			_fail(w + ": expected [tile, uid, type, spot_x, spot_y]")
			return out
		var tile := _int(h[0], 0, TILES - 1, w + ".tile")
		var uid := _int(h[1], 1, MAX_UID - 1, w + ".uid")
		out.append(tile)
		out.append(uid)
		out.append(_int(h[2], 1, MAX_ID, w + ".type"))
		out.append(_int(h[3], -1, 999, w + ".spot_x"))
		out.append(_int(h[4], -1, 999, w + ".spot_y"))
		per_tile[tile] = per_tile.get(tile, 0) + 1
		if is_valid() and (per_tile[tile] > MAX_HANDLES_PER_TILE or uids.has(uid)):
			_fail("%s: more than %d on tile %d, or uid %d twice" % [w, MAX_HANDLES_PER_TILE, tile, uid])
		uids[uid] = true
		if not is_valid():
			return out
	return out


## [[uid, type, parent, pocket, flags], ...]: at most MAX_CARRIED, a container listed before what's in it.
func _carried(v: Variant, what: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_CARRIED:
		_fail("%s: expected a list of at most %d items" % [what, MAX_CARRIED])
		return out
	var uids := {}
	for i in (v as Array).size():
		var c: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not c is Array or (c as Array).size() != CARRIED_STRIDE:
			_fail(w + ": expected [uid, type, parent, pocket, flags]")
			return out
		var uid := _int(c[0], 1, MAX_UID - 1, w + ".uid")
		var parent := _int(c[2], 0, MAX_UID - 1, w + ".parent")
		out.append(uid)
		out.append(_int(c[1], 1, MAX_ID, w + ".type"))
		out.append(parent)
		out.append(_int(c[3], -1, MAX_POCKET, w + ".pocket"))
		out.append(_int(c[4], 0, CARRIED_WORN | CARRIED_WIELDED | CARRIED_OFFHAND, w + ".flags"))
		if is_valid() and (uids.has(uid) or (parent != 0 and not uids.has(parent))):
			_fail("%s: uid %d twice, or its container %d not listed before it" % [w, uid, parent])
		uids[uid] = true
		if not is_valid():
			return out
	return out


## [[tile, type, intensity, age], ...]: at most MAX_FIELDS_PER_TILE per tile.
func _fields(v: Variant, what: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > TILES * MAX_FIELDS_PER_TILE:
		_fail("%s: expected a list of at most %d fields" % [what, TILES * MAX_FIELDS_PER_TILE])
		return out
	for i in (v as Array).size():
		var f: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not f is Array or (f as Array).size() != 4:
			_fail(w + ": expected [tile, type, intensity, age]")
			return out
		out.append(_int(f[0], 0, TILES - 1, w + ".tile"))
		out.append(_int(f[1], 0, MAX_ID, w + ".type"))
		out.append(_int(f[2], 0, 255, w + ".intensity"))
		out.append(_int(f[3], 0, 0xffff, w + ".age"))
		if not is_valid():
			return out
	return out


func _bytes(v: Variant, hi: int, what: String) -> PackedByteArray:
	var out := PackedByteArray()
	if not is_valid():
		return out
	if not v is Array or (v as Array).size() != TILES:
		_fail("%s: expected a list of %d values" % [what, TILES])
		return out
	var a: Array = v
	out.resize(TILES)
	for i in TILES:
		var x: Variant = a[i]
		var f := float(x) if (x is float or x is int) else -1.0
		if f != floorf(f) or f < 0.0 or f > hi:
			_fail("%s[%d]: not an integer in 0..%d" % [what, i, hi])
			return out
		out[i] = int(f)
	return out


## {"12": "t_floor", ...} -> {12: "t_floor"}.
func _names(v: Variant, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	if not v is Dictionary:
		_fail(what + " is not an object")
		return out
	var d: Dictionary = v
	if d.size() > MAX_NAMES:
		_fail("%s: %d names, cap is %d" % [what, d.size(), MAX_NAMES])
		return out
	for k: Variant in d:
		if not k is String or (k as String).length() > 7 or not (k as String).is_valid_int():
			_fail("%s: key is not an id number" % what)
			return out
		var id := (k as String).to_int()
		var name: Variant = d[k]
		if id < 0 or id > MAX_ID or not name is String or (name as String).length() > MAX_NAME_LEN:
			_fail("%s[%s]: bad id or name" % [what, k])
			return out
		out[id] = name
	return out
