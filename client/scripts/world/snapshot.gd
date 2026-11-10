class_name Snapshot
extends RefCounted
## One validated snapshot of the reality bubble (contracts/snapshot.md), read from the JSON form.
##
## The input is hostile. Every field the client uses is type-, range- and size-checked here, and a
## snapshot with any bad field is rejected whole: [member error] is set and [member submaps] is empty.
## Fields the client doesn't use yet (vehicles) are ignored, not trusted; whoever
## starts using them adds their checks here. A submap without `trap`, `items` or `lights` has none.
## `env.ambient_light` and per-submap `lights` ([[tile, luminance, kind], ...], block C6) are optional
## until the bridge sends them.

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
const MAX_STAMINA := 1 << 24
const NEEDS := ["hunger", "thirst", "sleepiness", "pain", "morale"]   # player_view int16s
const MAX_BODY_PARTS := 32                # CDDA has 12 main parts
const MAX_WORN := 64                      # the contract's cap
const LIGHT_STRIDE := 3                   # lights: tile, luminance, kind
const MAX_LIGHTS_PER_SUBMAP := 16
const LIGHT_FIXED := 0                    # kinds (assumed until the contract says): terrain, furniture, vehicle
const LIGHT_ITEM := 1                     # an item, on the ground or carried
const LIGHT_FIRE := 2                     # a field: fire, burning things
## Heat for CDDA's crafting (block L9, optional per-submap `heat`): HEAT_STRIDE ints per square.
const HEAT_STRIDE := 6                    # heat: tile, source (HEAT_*), tool (itype index, 0 a fire only), fire 0..3, charges, lit 0/1
const MAX_HEAT_PER_SUBMAP := 32
const HEAT_FIRE := 0                      # a fire alone (fd_fire, or terrain / furniture usable as one)
const HEAT_FURNITURE := 1                 # fireplace, wood stove, oven, smoker
const HEAT_VEHICLE := 2                   # a vehicle part's heat tool (kitchen unit, oven appliance)
const MAX_CHARGES := 0x7FFFFFFF           # int32 in the contract
## Cookware on heat squares (block L9, optional per-submap `cookware`).
const MAX_COOKWARE_PER_SUBMAP := 16
const COOK_ITEM_STRIDE := 3               # Cookware.contents: uid, itype, count (charges, or 1)
const MAX_COOK_CONTENTS := 16

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
	var lights: PackedInt32Array  # LIGHT_STRIDE ints per light source: tile, luminance 0..255, kind (LIGHT_*)
	var heat: PackedInt32Array    # HEAT_STRIDE ints per square that heats (seen tiles only), distinct tiles
	var cookware: Array = []      # Cookware on those squares


## An item with CDDA's COOK or BOIL quality lying on a heat square (block L9): its handle, what is in it (one
## level) and a CDDA craft in progress among its contents.
class Cookware:
	var tile := 0
	var uid := 0
	var type := 0                         # itype index
	var contents := PackedInt64Array()    # COOK_ITEM_STRIDE per item: uid, itype, count
	var craft_result := 0                 # itype index of what is being made, 0 none
	var craft_recipe := ""                # CDDA recipe id, "" none
	var craft_progress := 0               # permille


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
var player_gun := {}                       # player.wielded_gun: {type, dirt, faults, rounds}, {} for none
var player_parts: Array[BodyPart] = []     # the player's main body parts (hp, wounds), snapshot order
var player_worn: Array[Worn] = []          # what the player wears, inner to outer
var carried := PackedInt64Array()          # CARRIED_STRIDE ints per carried item, depth first
var player_stamina := -1                   # -1: not sent
var player_stamina_max := -1
var player_needs := {}                     # NEEDS key -> int, only the ones sent (clamped to int16)
var creatures: Array[Creature] = []        # the ones the player perceives, the player first
var _creature_at := {}                     # Vector3i -> Creature, built on first use
var sun_alt_deg := 45.0
var sun_az_deg := 180.0
var ambient_light := -1  # env.ambient_light: CDDA's natural light at the player's z, 0..255; -1 when not sent
var has_lights := false  # some submap has a `lights` list: light sources come from the lists, not guessed
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
	var g: Variant = (v as Dictionary).get("wielded_gun")
	if g != null:
		player_gun = _read_gun(g)
	_read_body((v as Dictionary))
	_read_needs((v as Dictionary))
	_read_worn((v as Dictionary).get("worn"))
	carried = _carried((v as Dictionary).get("items"), "player.items")


## player.wielded_gun: {type (itype index), dirt (0..10000, -1 absent), faults (fault ids), rounds (-1 absent)}.
func _read_gun(v: Variant) -> Dictionary:
	const MAX_FAULTS := 16
	const MAX_FAULT_LEN := 64
	if not is_valid():
		return {}
	if not v is Dictionary:
		_fail("player.wielded_gun is not an object")
		return {}
	var d: Dictionary = v
	var gun := {
		"type": _int(d.get("type", 0), 0, MAX_ID, "player.wielded_gun.type"),
		"dirt": _int(d["dirt"], 0, 10000, "player.wielded_gun.dirt") if d.has("dirt") else -1,
		"rounds": _int(d["rounds"], 0, 100000, "player.wielded_gun.rounds") if d.has("rounds") else -1,
	}
	var f: Variant = d.get("faults", [])
	if not f is Array or (f as Array).size() > MAX_FAULTS:
		_fail("player.wielded_gun.faults: expected a list of at most %d" % MAX_FAULTS)
		return {}
	var faults: Array[String] = []
	for i in (f as Array).size():
		var s: Variant = f[i]
		if not s is String or (s as String).length() > MAX_FAULT_LEN:
			_fail("player.wielded_gun.faults[%d]: expected a string of at most %d characters" % [i, MAX_FAULT_LEN])
			return {}
		faults.append(s)
	gun["faults"] = faults
	return gun if is_valid() else {}


## Stamina and needs for the HUD: optional; numbers out of range are clamped, anything else rejects.
func _read_needs(d: Dictionary) -> void:
	if not is_valid():
		return
	for key: String in ["stamina", "stamina_max"] + NEEDS:
		var x: Variant = d.get(key)
		if x == null:
			continue
		if not (x is int or x is float) or is_nan(float(x)):
			_fail("player.%s is not a number" % key)
			return
		if key.begins_with("stamina"):
			set("player_" + key, int(clampf(float(x), 0.0, MAX_STAMINA)))
		else:
			player_needs[key] = int(clampf(float(x), -32768.0, 32767.0))


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
	if not v is Array:
		_fail("player.worn: expected a list")
		return
	for i in range(maxi(0, (v as Array).size() - MAX_WORN), (v as Array).size()):   # past the cap: the outer ones
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


## What heats square p for CDDA's crafting (block L9): {source (HEAT_*), tool (itype index, 0 a fire only),
## fire (0..3), charges, lit (bool)}; {} where nothing does (or the square isn't seen).
func heat_at(p: Vector3i) -> Dictionary:
	var sm: Submap = submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return {}
	var l := CddaCoords.ms_to_local(p)
	var tile := l.y * CddaCoords.SEEX + l.x
	for j in range(0, sm.heat.size(), HEAT_STRIDE):
		if sm.heat[j] == tile:
			return {"source": sm.heat[j + 1], "tool": sm.heat[j + 2], "fire": sm.heat[j + 3],
					"charges": sm.heat[j + 4], "lit": sm.heat[j + 5] == 1}
	return {}


## The cookware lying on square p (Cookware, the bridge's order); empty where none is.
func cookware_at(p: Vector3i) -> Array:
	var out: Array = []
	var sm: Submap = submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return out
	var l := CddaCoords.ms_to_local(p)
	var tile := l.y * CddaCoords.SEEX + l.x
	for cw: Cookware in sm.cookware:
		if cw.tile == tile:
			out.append(cw)
	return out


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
	if e.has("ambient_light"):
		ambient_light = _int(e["ambient_light"], 0, 255, "env.ambient_light")


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
		if s.has("lights"):
			has_lights = true
			sm.lights = _lights(s["lights"], what + ".lights")
		sm.heat = _heat(s.get("heat"), what + ".heat")
		sm.cookware = _cookware(s.get("cookware"), sm.heat, what + ".cookware")
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
	if not v is Array:
		_fail("%s: expected a list" % what)
		return out
	var uids := {}
	for i in mini((v as Array).size(), MAX_CARRIED):   # past the cap: left out (a container comes before its contents)
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


## [[tile, luminance, kind], ...]: at most MAX_LIGHTS_PER_SUBMAP light sources.
func _lights(v: Variant, what: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_LIGHTS_PER_SUBMAP:
		_fail("%s: expected a list of at most %d lights" % [what, MAX_LIGHTS_PER_SUBMAP])
		return out
	for i in (v as Array).size():
		var l: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not l is Array or (l as Array).size() != LIGHT_STRIDE:
			_fail(w + ": expected [tile, luminance, kind]")
			return out
		out.append(_int(l[0], 0, TILES - 1, w + ".tile"))
		out.append(_int(l[1], 0, 255, w + ".luminance"))
		out.append(_int(l[2], LIGHT_FIXED, LIGHT_FIRE, w + ".kind"))
		if not is_valid():
			return out
	return out


## [[tile, source, tool, fire, charges, lit], ...]: at most MAX_HEAT_PER_SUBMAP squares, each once.
func _heat(v: Variant, what: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_HEAT_PER_SUBMAP:
		_fail("%s: expected a list of at most %d heat squares" % [what, MAX_HEAT_PER_SUBMAP])
		return out
	var tiles := {}
	for i in (v as Array).size():
		var h: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not h is Array or (h as Array).size() != HEAT_STRIDE:
			_fail(w + ": expected [tile, source, tool, fire, charges, lit]")
			return out
		var tile := _int(h[0], 0, TILES - 1, w + ".tile")
		out.append(tile)
		out.append(_int(h[1], HEAT_FIRE, HEAT_VEHICLE, w + ".source"))
		out.append(_int(h[2], 0, MAX_ID, w + ".tool"))
		out.append(_int(h[3], 0, 3, w + ".fire"))
		out.append(_int(h[4], 0, MAX_CHARGES, w + ".charges"))
		var lit: Variant = h[5]
		out.append(int(lit) if lit is bool else _int(lit, 0, 1, w + ".lit"))
		if is_valid() and tiles.has(tile):
			_fail("%s: tile %d twice" % [w, tile])
		tiles[tile] = true
		if not is_valid():
			return out
	return out


## [{tile, uid, type, contents, craft_result, craft_recipe, craft_progress}, ...]: at most
## MAX_COOKWARE_PER_SUBMAP, each on a square of `heat`, distinct uids.
func _cookware(v: Variant, heat: PackedInt32Array, what: String) -> Array:
	var out: Array = []
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_COOKWARE_PER_SUBMAP:
		_fail("%s: expected a list of at most %d cookware" % [what, MAX_COOKWARE_PER_SUBMAP])
		return out
	var heated := {}
	for j in range(0, heat.size(), HEAT_STRIDE):
		heated[heat[j]] = true
	var uids := {}
	for i in (v as Array).size():
		var w := "%s[%d]" % [what, i]
		if not v[i] is Dictionary:
			_fail(w + " is not an object")
			return out
		var d: Dictionary = v[i]
		var cw := Cookware.new()
		cw.tile = _int(d.get("tile"), 0, TILES - 1, w + ".tile")
		cw.uid = _int(d.get("uid"), 1, MAX_UID - 1, w + ".uid")
		cw.type = _int(d.get("type"), 1, MAX_ID, w + ".type")
		cw.craft_result = _int(d.get("craft_result", 0), 0, MAX_ID, w + ".craft_result")
		cw.craft_progress = _int(d.get("craft_progress", 0), 0, 1000, w + ".craft_progress")
		cw.craft_recipe = _text_id(d.get("craft_recipe", ""), w + ".craft_recipe")
		cw.contents = _cook_contents(d.get("contents", []), cw.uid, w + ".contents")
		if is_valid() and (not heated.has(cw.tile) or uids.has(cw.uid)):
			_fail("%s: tile %d has no heat entry, or uid %d twice" % [w, cw.tile, cw.uid])
		uids[cw.uid] = true
		if not is_valid():
			return out
		out.append(cw)
	return out


## [[uid, type, count], ...]: at most MAX_COOK_CONTENTS, distinct uids, none the container's own.
func _cook_contents(v: Variant, container: int, what: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	if not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_COOK_CONTENTS:
		_fail("%s: expected a list of at most %d items" % [what, MAX_COOK_CONTENTS])
		return out
	var uids := {container: true}
	for i in (v as Array).size():
		var c: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not c is Array or (c as Array).size() != COOK_ITEM_STRIDE:
			_fail(w + ": expected [uid, type, count]")
			return out
		var uid := _int(c[0], 1, MAX_UID - 1, w + ".uid")
		out.append(uid)
		out.append(_int(c[1], 1, MAX_ID, w + ".type"))
		out.append(_int(c[2], 0, MAX_CHARGES, w + ".count"))
		if is_valid() and uids.has(uid):
			_fail("%s: uid %d twice" % [w, uid])
		uids[uid] = true
		if not is_valid():
			return out
	return out


## A CDDA id sent as text: at most MAX_NAME_LEN characters, no control characters.
func _text_id(v: Variant, what: String) -> String:
	if not is_valid():
		return ""
	if not v is String or (v as String).length() > MAX_NAME_LEN:
		_fail("%s: expected text of at most %d characters" % [what, MAX_NAME_LEN])
		return ""
	var t: String = v
	for i in t.length():
		var ch := t.unicode_at(i)
		if ch < 32 or ch == 127:
			_fail(what + ": control character")
			return ""
	return t


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
