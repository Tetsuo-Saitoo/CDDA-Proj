class_name Snapshot
extends RefCounted
## One validated snapshot of the reality bubble (contracts/snapshot.md), read from the JSON form.
##
## The input is hostile. Every field the client uses is type-, range- and size-checked here, and a
## snapshot with any bad field is rejected whole: [member error] is set and [member submaps] is empty.
## Fields the client doesn't use yet (fields, creatures, vehicles) are ignored, not trusted; whoever
## starts using them adds their checks here. A submap without `trap` or `items` has none.

const CONTRACT_VERSION := 0
const TILES := 144
const MAX_FILE_BYTES := 16 << 20          # a full 21-level bubble is ~6 MB of JSON
const MAX_SUBMAPS := 11 * 11 * 21
const MAX_ID := 1 << 20                   # CDDA has ~1.1k terrain ids; anything larger is garbage
const MAX_REVISION := 0xFFFFFFFF
const MAX_ABS_SM := 1 << 26               # keeps absolute squares (x 12) well inside int32
const MAX_TURN := 1 << 52                 # JSON numbers are doubles
const MAX_NAMES := 65536
const MAX_NAME_LEN := 128
const MAX_ITEM_COUNT := 0xFFFF            # uint16 in the contract
const PILE_STRIDE := 6                    # items: tile, count, top[4]

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
	var items: PackedInt32Array   # piles, PILE_STRIDE ints each: tile, count, top[4] (itype indices, 0 = none)
	var flags: PackedByteArray
	var vis: PackedByteArray      # 0 never seen, 1 remembered, 2 seen, 3 in sight but dark
	var light: PackedByteArray


var error := ""
var turn := 0
var seq := 0
var ids_generation := -1   # -1: the snapshot doesn't say
var bubble_origin := Vector3i.ZERO
var player_pos := Vector3i.ZERO
var player_wielded := 0                    # itype index of what the player holds, 0 for nothing
var sun_alt_deg := 45.0
var sun_az_deg := 180.0
var submaps := {}       # Vector3i (absolute submap) -> Submap
var ter_names := {}     # int -> String
var furn_names := {}    # int -> String
var trap_names := {}    # int -> String


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
	bubble_origin = _vec3i(d.get("bubble_origin"), MAX_ABS_SM, "bubble_origin")
	if is_valid() and bubble_origin.z != 0:
		_fail("bubble_origin z must be 0")
	_read_player(d.get("player"))
	_read_env(d.get("env"))
	_read_ids(d.get("ids"))
	_read_submaps(d.get("submaps"))


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
	if list.size() > MAX_SUBMAPS:
		_fail("%d submaps, cap is %d" % [list.size(), MAX_SUBMAPS])
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
				or sm.pos.z < CddaCoords.Z_MIN or sm.pos.z > CddaCoords.Z_MAX:
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
			_int(a[2], CddaCoords.Z_MIN, CddaCoords.Z_MAX, what + ".z"))


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
		if not p is Array or (p as Array).size() != 3 or not p[2] is Array or (p[2] as Array).size() > 4:
			_fail(w + ": expected [tile, count, [up to 4 itypes]]")
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
