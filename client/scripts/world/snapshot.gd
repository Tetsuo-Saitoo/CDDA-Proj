class_name Snapshot
extends RefCounted
## One validated snapshot of the reality bubble (contracts/snapshot.md), read from the JSON form.
##
## The input is hostile. Every field the client uses is type-, range- and size-checked here, and a
## snapshot with any bad field is rejected whole: [member error] is set and [member submaps] is empty.
## Fields the client doesn't use yet are ignored, not trusted; whoever starts using them adds their checks here.
## `vehicles` are cleaned like the HUD lists (vehicles_from: a bad vehicle or part is left out, never failing the
## snapshot). A submap without `trap`, `items` or `lights` has none.
## `env.ambient_light` and per-submap `lights` ([[tile, luminance, kind], ...], block C6) are optional
## until the bridge sends them. So are per-submap `more` (how many items a cut-short pile list left out),
## `inside` and `inside_more` (what is in the containers lying next to the player, block L8).

const CONTRACT_VERSION := 0
const TILES := 144
const MAX_FILE_BYTES := 16 << 20          # a full 21-level bubble is ~6 MB of JSON
const MAX_ID := 1 << 20                   # CDDA has ~1.1k terrain ids; anything larger is garbage
const WEATHER_MAX := 10000.0              # the env's weather numbers (wind, sight, light, sun): finite and no larger
const PRECIP_NONE := 0                    # env.precip_kind
const PRECIP_RAIN := 1
const PRECIP_SNOW := 2
const WEATHER_SOUND_THUNDER := 4          # env.weather_sound: CDDA's category for thunder and lightning storms
const MAX_REVISION := 0xFFFFFFFF
const MAX_ABS_SM := 1 << 26               # keeps absolute squares (x 12) well inside int32
const MAX_TURN := 1 << 52                 # JSON numbers are doubles
const KEY_STRIDE := 6                     # submap_keys rows: x, y, z, revision, detail_revision, hash
const MAX_HASH := 0xFFFFFFFF              # the bridge's 32-bit hash of a submap body
const MAX_NAMES := 65536
const MAX_NAME_LEN := 128
const MAX_ITEM_COUNT := 0xFFFF            # uint16 in the contract
const MAX_CREATURES := 1024               # the contract's cap
const MAX_UID := 1 << 53                  # JSON numbers are doubles
const MAX_SHELF := 15   # shelves: a furniture square's numbered surfaces are 0..15
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
const MAX_HANDLES_NEAR := 256             # ... on the player's square and the 8 around it (same level): a big pile's tray
const MAX_HANDLES_PER_SUBMAP := TILES * MAX_HANDLES_PER_TILE + 9 * (MAX_HANDLES_NEAR - MAX_HANDLES_PER_TILE)
const MAX_INSIDE_PER_CONTAINER := 64      # inside: what is in a container lying next to the player, one level
const MAX_INSIDE_PER_SUBMAP := 256
const MAX_MORE := 0x7FFFFFFF              # more, inside_more: how many items the bridge left out of a list
const CARRIED_STRIDE := 5                 # carried: uid, itype, parent uid (0 on the body), pocket, flags
const MAX_CARRIED := 256
const STATE_SIZE := 7                     # item_states: temp, rot, fill, fill_type, see_through, fill_ml, dirt (after the uid)
const MAX_ITEM_STATES := 512
const MAX_ITEM_AMOUNTS := 1024             # item_amounts: carried items, then in reach (the contract's cap)
const MAX_COUNT := 2147483647              # an item_amounts count (charges), 1 at least
const MAX_AMOUNT := 1_000_000_000          # an item_amounts weight in g / volume in ml
const MAX_STATE_ML := 100000000           # 100 m3
const MAX_DIRT := 10000                   # a gun's fouling, as wielded_gun.dirt
const MAX_GUN_MODS := 16                  # wielded_gun.mods: the gunmods installed (gun modification)
const MAX_GUN_FITS := 32                  # wielded_gun.fits: carried gunmods judged against the gun
const MAX_GUN_SLOTS := 16                 # wielded_gun.slots: its mod locations as it is now
const MAX_FIT_REASON := 80                # a fit's reason (plain_text)
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
const MAX_EFFECTS := 64                   # the contract's cap
const MAX_EFFECT_ID := 64
const MAX_EFFECT_NAME := 40
const MAX_EFFECT_SECONDS := 366 * 86400   # longer reads as "unknown" (-1)
const MAX_MORALE := 32                    # morale entries kept (the contract sends at most 12)
const MAX_MORALE_NAME := 64
const MAX_NPC_NAME := 40                  # creatures' `name` (NPCs only), the contract's 40 columns
const MAX_ACTIVITY_ID := 64               # player.activity id, bytes
const MAX_ACTIVITY_VERB := 40             # player.activity verb, columns
const MAX_MOOD_FACE := 16
const EFFECT_GOOD := 1                    # player.effects rating
const EFFECT_NEUTRAL := 0
const EFFECT_BAD := -1
const EFFECT_MIXED := 2
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
const MAX_VEHICLES := 256                 # vehicles: the contract's caps
const MAX_VEHICLE_PARTS := 4096           # ... parts per vehicle
const MAX_ALL_VEHICLE_PARTS := 65536      # parts kept in all (a town has ~1000); later vehicles are left out
const MAX_VEHICLE_NAME := 60              # columns
const MAX_MOUNT := 128                    # a part's mount, per axis; its square's offset from pos at most twice that
const MAX_VEHICLE_DZ := 4                 # levels a part's square may be off the vehicle's (CDDA moves parts on ramps)
const MAX_SPEED := 1000.0                 # m/s; anything else reads as 0
const MAX_ANGLE := 1e6                    # degrees; a facing past this (or not finite) leaves the vehicle out
const VPART_STRIDE := 8                   # Vehicle.parts: mount x, mount y, vpart, hp_frac, state, dx, dy, dz
const VPART_OPEN := 1                     # part state bits
const VPART_BROKEN := 2
const VPART_ENABLED := 4
const VPART_FILLER := 8                   # one of the parts CDDA adds to fill a turned vehicle's diagonal gaps


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
	var poses := {}               # uid -> Vector2i(yaw whole degrees 0..359, side 0 / 1): how a placed item lies
	var shelves := {}             # uid -> shelf 0..MAX_SHELF: the furniture surface it was put on (PropMesher numbers them)
	var more := {}                # tile -> how many items of its pile have no handle (the bridge cut the list short)
	var inside := {}              # container uid -> [[uid, itype, pocket], ...]: what is in a container lying next to the player
	var inside_more := {}         # container uid -> how many more are in it than `inside` lists
	var flags: PackedByteArray
	var vis: PackedByteArray      # 0 never seen, 1 remembered, 2 seen, 3 in sight but dark
	var light: PackedByteArray
	var lights: PackedInt32Array  # LIGHT_STRIDE ints per light source: tile, luminance 0..255, kind (LIGHT_*)
	var lights_sent := false      # the body had a `lights` list (has_lights, also when a delta reuses this submap)
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
## While CDDA's peek is open: the square the body is on (player_pos is then the peeked square, which everything is
## seen from); null otherwise, also when it isn't next to player_pos on its level (contracts/snapshot.md).
var player_peeking_from: Variant = null
var player_wielded := 0                    # itype index of what the player holds, 0 for nothing
var player_gun := {}                       # player.wielded_gun: {type, dirt, faults, rounds, suppressed; mods, fits,
                                           # slots only when sent}, {} for none
var player_parts: Array[BodyPart] = []     # the player's main body parts (hp, wounds), snapshot order
var player_worn: Array[Worn] = []          # what the player wears, inner to outer
var carried := PackedInt64Array()          # CARRIED_STRIDE ints per carried item, depth first
var item_states := {}                      # uid -> PackedInt32Array(STATE_SIZE): live state of a carried item or one lying in reach (ItemLook)
var _item_states_sent: Variant             # player.item_states as sent, read once the submaps' handles are known
## uid -> PackedInt32Array([count, weight_g, volume_ml]): CDDA's own numbers for a carried item or one in reach (the
## whole stack; weight with contents, volume as it takes room where it is); {} from an older bridge (amounts_from).
var item_amounts := {}
var _item_amounts_sent: Variant
var player_stamina := -1                   # -1: not sent
var player_stamina_max := -1
var player_needs := {}                     # NEEDS key -> int, only the ones sent (clamped to int16)
## player.effects (what CDDA's @ screen lists): {id, name, body_part, intensity, rating, seconds_left}, at most
## MAX_EFFECTS. HUD-only data: a bad entry is skipped, not a failed snapshot. seconds_left -1 = permanent or unknown.
var player_effects: Array[Dictionary] = []
## player.mood.entries (CDDA's morale list, strongest first: the reasons behind the morale level): {name, value
## (what it adds now, signed), percent (its share of its side, good or bad, 0..100; -1 not sent)}, at most
## MAX_MORALE. HUD-only data: a bad entry is skipped, not a failed snapshot.
var player_morale: Array[Dictionary] = []
## player.mood without its entries: {level (CDDA's morale level), band (-3..3, CDDA's mood face bands), face (its
## mood face text, ":)"), total (entries CDDA's morale screen lists)}, each only when sent and well-formed; {}
## when the snapshot has no mood object. HUD-only.
var player_mood := {}
## player.move_mode: index into the id tables' move_mode list (walk, run, crouch, prone); -1 when not sent or bad
## (HUD-only: never fails the snapshot).
var player_move_mode := -1
## player.activity while one runs (a long wait, a craft): CDDA's activity type id (letters, digits and _, up to
## MAX_ACTIVITY_ID bytes, else "") and its verb ("waiting", cleaned, up to MAX_ACTIVITY_VERB); "" for none or not
## sent. player.asleep: CDDA's sleep effect (not lying awake trying). HUD-only: never fails the snapshot.
var activity_id := ""
var activity_verb := ""
var asleep := false
var creatures: Array[Creature] = []        # the ones the player perceives, the player first
var _creature_at := {}                     # Vector3i -> Creature, built on first use
var vehicles: Array[Vehicle] = []          # in the bubble (vehicles_from), the bridge's order
var _vehicle_at := {}                      # Vector3i -> [Vehicle, PackedInt32Array part indices], built on first use
var sun_alt_deg := 45.0
var sun_az_deg := 180.0
var ambient_light := -1  # env.ambient_light: CDDA's natural light at the player's z, 0..255; -1 when not sent
## The weather (WeatherState reads these; all optional, clear weather when not sent). CDDA's own numbers for the
## current weather type, so a mod's weather works too: only wildly wrong values fail the snapshot.
var weather := 0                 # env.weather: index into the id tables' weather list, 0 = none
var wind_speed := 0.0            # env.wind_speed: the region's wind, m/s
var wind_dir_deg := 0.0          # env.wind_dir_deg: where the wind comes from, 0 north, 90 east
var wind_at_player := -1.0       # env.wind_at_player: m/s on the player's square (0 indoors); -1 when not sent
var weather_precip := 0          # env.precip: 0 none, 1 very light, 2 light, 3 heavy
var weather_kind := 0            # env.precip_kind: PRECIP_NONE, PRECIP_RAIN or PRECIP_SNOW
var weather_sight := 1.0         # env.sight_penalty: 1 clear, 1.7 fog
var weather_light := 0.0         # env.light_modifier: 0 clear, -45 a thunderstorm
var weather_sun := 1.0           # env.sun_multiplier: 1 clear, 0.01 a storm
var weather_sheltered := false   # env.sheltered: rain and snow don't reach the player
var weather_sound := 0           # env.weather_sound: CDDA's sound category (WEATHER_SOUND_THUNDER in a thunderstorm)
var temperature_c := NAN         # env.temperature_c: the air on the player's square, -100..100; NAN when not sent
var has_lights := false  # some submap has a `lights` list: light sources come from the lists, not guessed
var submaps := {}       # Vector3i (absolute submap) -> Submap
var submap_hash := {}   # Vector3i -> the bridge's hash of its body (`submap_keys`); a delta built on this needs it
var base_seq := -1      # a delta (`base`): the seq of the snapshot it was built on; -1 for a full answer
var reused_submaps := 0 # a delta: submaps taken unchanged from that snapshot (shared with it, never changed)
var _container_sm := {} # container uid -> the submap whose `inside` / `inside_more` lists it
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
	## NPCs: CDDA's name for them (plain_text: tags and control characters removed, capped); "" for anyone else, or
	## when the bridge sends none or something that isn't a string.
	var name := ""

	## Hostile to the player. Without an attitude from the bridge, monsters count as hostile and people don't.
	func is_hostile() -> bool:
		if kind == PLAYER:
			return false
		return attitude == HOSTILE or (attitude == UNKNOWN and kind == MONSTER)


## A vehicle in the bubble (contracts/snapshot.md vehicle_view), as vehicles_from cleans it.
class Vehicle:
	var uid := 0
	var name := ""                 # plain_text, at most MAX_VEHICLE_NAME columns; "" when none was sent
	var pos := Vector3i.ZERO       # absolute square of the vehicle's position: its parts' squares are offsets from it
	var face_deg := 0.0            # CDDA's facing, 0..360: 0 east, 90 south
	var turn_deg := 0.0            # the facing it is turning to, 0..360
	var velocity := 0.0            # m/s, negative in reverse
	## Whether every part's square is CDDA's own (the bridge sent dx, dy, dz); otherwise the parts without are at their
	## mounts turned by face_deg (turn_mount), which can be a square off where CDDA turns about a pivot.
	var exact := true
	var parts := PackedInt32Array()   # VPART_STRIDE ints per part, the bridge's order (several share a square)

	func part_count() -> int:
		return parts.size() / Snapshot.VPART_STRIDE

	## The absolute square of part i.
	func square(i: int) -> Vector3i:
		var k := i * Snapshot.VPART_STRIDE
		return pos + Vector3i(parts[k + 5], parts[k + 6], parts[k + 7])


func is_valid() -> bool:
	return error.is_empty()


static func load_file(path: String) -> Snapshot:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return Snapshot.new()._fail("cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())])
	if f.get_length() > MAX_FILE_BYTES:
		return Snapshot.new()._fail("%s is %d bytes, cap is %d" % [path, f.get_length(), MAX_FILE_BYTES])
	return parse_text(f.get_as_text())


static func parse_text(text: String, base: Snapshot = null) -> Snapshot:
	if text.length() > MAX_FILE_BYTES:
		return Snapshot.new()._fail("snapshot text is longer than %d" % MAX_FILE_BYTES)
	var json := JSON.new()
	if json.parse(text) != OK:
		return Snapshot.new()._fail("JSON line %d: %s" % [json.get_error_line(), json.get_error_message()])
	return from_data(json.data, base)


## Builds from already-parsed JSON data (Dictionary/Array/String/float/bool/null). `base`: the snapshot held, for a
## delta (contracts/snapshot.md "Deltas"); a delta that doesn't fit it fails, and the caller asks for a full one.
static func from_data(data: Variant, base: Snapshot = null) -> Snapshot:
	var snap := Snapshot.new()
	snap._read(data, base)
	if not snap.is_valid():
		snap.submaps.clear()
		snap.submap_hash.clear()
		snap._container_sm.clear()
		snap.ter_names.clear()
		snap.furn_names.clear()
		snap.trap_names.clear()
		snap.creatures.clear()
		snap.vehicles.clear()
	return snap


func _fail(msg: String) -> Snapshot:
	if error.is_empty():
		error = msg
	return self


func _read(data: Variant, base: Snapshot = null) -> void:
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
	_read_keys(d, base)
	_read_creatures(d.get("creatures"))
	if is_valid():
		vehicles = vehicles_from(d.get("vehicles"), z_min, z_max)
	if is_valid() and (_item_states_sent != null or _item_amounts_sent != null):
		var known := _known_uids()
		if _item_states_sent != null:
			item_states = states_from(_item_states_sent, known)
		if _item_amounts_sent != null:
			item_amounts = amounts_from(_item_amounts_sent, known)
	_item_states_sent = null
	_item_amounts_sent = null


## The item uids per-item lists may name: carried items, the submaps' handles and what is in a container lying
## next to the player (its tray row, `inside`).
func _known_uids() -> Dictionary:
	var known := {}
	for k in range(0, carried.size(), CARRIED_STRIDE):
		known[carried[k]] = true
	for sm: Submap in submaps.values():
		for k in range(1, sm.handles.size(), HANDLE_STRIDE):
			known[sm.handles[k]] = true
		for c: int in sm.inside:
			for e: Array in sm.inside[c]:
				known[e[0]] = true
	return known


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
	player_peeking_from = null
	if v == null or not is_valid():
		return
	if not v is Dictionary:
		_fail("player is not an object")
		return
	var p: Variant = (v as Dictionary).get("pos")
	if p != null:
		player_pos = _vec3i(p, MAX_ABS_SM * CddaCoords.SEEX, "player.pos")
	player_peeking_from = _next_to(player_pos, (v as Dictionary).get("peeking_from"), MAX_ABS_SM * CddaCoords.SEEX)
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
	_item_states_sent = (v as Dictionary).get("item_states")
	_item_amounts_sent = (v as Dictionary).get("item_amounts")
	player_effects = effects_from((v as Dictionary).get("effects"))
	var md: Variant = (v as Dictionary).get("mood")
	player_mood = mood_from(md)
	player_morale = morale_from((md as Dictionary).get("entries") if md is Dictionary else null)
	var mm: Variant = _whole((v as Dictionary).get("move_mode"), 0, MAX_ID)
	player_move_mode = mm if mm is int else -1
	var act: Variant = (v as Dictionary).get("activity")
	if act is Dictionary:
		var id: Variant = (act as Dictionary).get("id")
		# ASCII only, so its length is its size in bytes
		if id is String and (id as String).length() <= MAX_ACTIVITY_ID and IdTables._is_word(id):
			activity_id = id
		activity_verb = plain_text((act as Dictionary).get("verb"), MAX_ACTIVITY_VERB)
	var sl: Variant = (v as Dictionary).get("asleep")
	asleep = sl is bool and sl


## player.effects, cleaned: anything malformed is left out (HUD-only data never fails a snapshot).
static func effects_from(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not v is Array:
		return out
	for e: Variant in (v as Array).slice(0, MAX_EFFECTS):
		if not e is Dictionary:
			continue
		var d: Dictionary = e
		var id := plain_text(d.get("id"), MAX_EFFECT_ID)
		var part: Variant = _whole(d.get("body_part", 0), 0, MAX_ID)
		var level: Variant = _whole(d.get("intensity", 1), 0, 255)
		var rating: Variant = _whole(d.get("rating", EFFECT_NEUTRAL), EFFECT_BAD, EFFECT_MIXED)
		if id.is_empty() or part == null or level == null or rating == null:
			continue
		var name := plain_text(d.get("name"), MAX_EFFECT_NAME)
		var secs: Variant = _whole(d.get("seconds_left", -1), 0, MAX_EFFECT_SECONDS)
		out.append({"id": id, "name": name if not name.is_empty() else id, "body_part": part, "intensity": level,
				"rating": rating, "seconds_left": secs if secs != null else -1})
	return out


## player.mood's own fields, cleaned: the ones malformed or not sent are left out (HUD-only data never fails a
## snapshot); {} when it isn't an object.
static func mood_from(v: Variant) -> Dictionary:
	var out := {}
	if not v is Dictionary:
		return out
	var d: Dictionary = v
	var level: Variant = _whole(d.get("level"), -32768, 32767)
	if level != null:
		out["level"] = level
	var band: Variant = _whole(d.get("band"), -3, 3)
	if band != null:
		out["band"] = band
	var face := plain_text(d.get("face"), MAX_MOOD_FACE)
	if not face.is_empty():
		out["face"] = face
	var total: Variant = _whole(d.get("total"), 0, 1 << 20)
	if total != null:
		out["total"] = total
	return out


## player.mood.entries, cleaned: anything malformed is left out (HUD-only data never fails a snapshot).
static func morale_from(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not v is Array:
		return out
	for e: Variant in (v as Array).slice(0, MAX_MORALE):
		if not e is Dictionary:
			continue
		var name := plain_text((e as Dictionary).get("name"), MAX_MORALE_NAME)
		var value: Variant = _whole((e as Dictionary).get("value"), -32768, 32767)
		if name.is_empty() or value == null:
			continue
		var pct: Variant = _whole((e as Dictionary).get("percent", -1), 0, 100)
		out.append({"name": name, "value": value, "percent": pct if pct != null else -1})
	return out


## v as an int when it is a whole number in lo..hi, else null (NaN, infinities, fractions and strings too).
## An optional [x, y, z] square next to `at` on its level (player.peeking_from): a Vector3i, else null (junk is left
## out, never failing the snapshot).
func _next_to(at: Vector3i, v: Variant, limit: int) -> Variant:
	if not v is Array or (v as Array).size() != 3:
		return null
	var a: Array = v
	var x: Variant = _whole(a[0], -limit, limit)
	var y: Variant = _whole(a[1], -limit, limit)
	var z: Variant = _whole(a[2], z_min, z_max)
	if not x is int or not y is int or not z is int:
		return null
	var sq := Vector3i(x, y, z)
	var d := sq - at
	return sq if d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1 else null


static func _whole(v: Variant, lo: int, hi: int) -> Variant:
	if v is int:
		return v if v >= lo and v <= hi else null
	if not v is float or is_nan(v) or is_inf(v) or v != floorf(v) or v < lo or v > hi:
		return null
	return int(v)


## Text from the bridge for one plain line: colour tags removed, control and direction characters dropped, at
## most `cap` characters.
static func plain_text(v: Variant, cap: int) -> String:
	if not v is String:
		return ""
	var out := PackedStringArray()
	for c in CddaText.plain((v as String).left(cap * 4)):
		var u := c.unicode_at(0)
		if u >= 0x20 and not CddaText.is_hidden(u):
			out.append(c)
	return "".join(out).left(cap).strip_edges()


## Gun modification: wielded_gun.mods, cleaned: [[uid, type, location id, flags], ...] -> [{uid, type, location, flags
## (1 irremovable)}]. Entries that aren't whole or repeat a uid are left out (never fails the snapshot); at most
## MAX_GUN_MODS looked at.
static func mods_from(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not v is Array:
		return out
	var seen := {}
	for e: Variant in (v as Array).slice(0, MAX_GUN_MODS):
		if not e is Array or (e as Array).size() < 4:
			continue
		var a: Array = e
		var uid: Variant = _whole(a[0], 1, MAX_UID - 1)
		var t: Variant = _whole(a[1], 1, MAX_ID)
		var flags: Variant = _whole(a[3], 0, 255)
		if uid == null or t == null or flags == null or seen.has(uid) or not IdTables.is_location(a[2]):
			continue
		seen[uid] = true
		out.append({"uid": uid, "type": t, "location": a[2], "flags": flags})
	return out


## wielded_gun.fits, cleaned: [[uid, ok 0/1, chance 0..100, risk 0..100, reason], ...] -> [{uid, ok (bool), chance,
## risk, reason (plain_text, MAX_FIT_REASON)}]; bad or repeated entries left out, at most MAX_GUN_FITS looked at.
static func fits_from(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not v is Array:
		return out
	var seen := {}
	for e: Variant in (v as Array).slice(0, MAX_GUN_FITS):
		if not e is Array or (e as Array).size() < 5:
			continue
		var a: Array = e
		var uid: Variant = _whole(a[0], 1, MAX_UID - 1)
		var ok: Variant = _whole(a[1], 0, 1)
		var chance: Variant = _whole(a[2], 0, 100)
		var risk: Variant = _whole(a[3], 0, 100)
		if uid == null or ok == null or chance == null or risk == null or seen.has(uid):
			continue
		seen[uid] = true
		out.append({"uid": uid, "ok": ok == 1, "chance": chance, "risk": risk, "reason": plain_text(a[4], MAX_FIT_REASON)})
	return out


## wielded_gun.slots, cleaned: [[location id, slots, free], ...] -> [{location, slots, free}] (free at most slots, both
## 0..IdTables.MAX_MOD_SLOTS); bad or repeated locations left out, at most MAX_GUN_SLOTS looked at.
static func slots_from(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not v is Array:
		return out
	var seen := {}
	for e: Variant in (v as Array).slice(0, MAX_GUN_SLOTS):
		if not e is Array or (e as Array).size() < 3:
			continue
		var a: Array = e
		var n: Variant = _whole(a[1], 0, IdTables.MAX_MOD_SLOTS)
		var free: Variant = _whole(a[2], 0, IdTables.MAX_MOD_SLOTS)
		if n == null or free == null or free > n or not IdTables.is_location(a[0]) or seen.has(a[0]):
			continue
		seen[a[0]] = true
		out.append({"location": a[0], "slots": n, "free": free})
	return out


## player.wielded_gun: {type (itype index), dirt (0..10000, -1 absent), faults (fault ids), rounds (-1 absent),
## suppressed (a gunmod quiets it; only a JSON true counts)}.
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
		"suppressed": d.get("suppressed") is bool and d["suppressed"],
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
	if d.has("mods"):   # gun modification: cleaned, never fail the snapshot; the keys only when sent
		gun["mods"] = mods_from(d["mods"])
	if d.has("fits"):
		gun["fits"] = fits_from(d["fits"])
	if d.has("slots"):
		gun["slots"] = slots_from(d["slots"])
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
		if c.kind == Creature.NPC:
			c.name = plain_text(r.get("name"), MAX_NPC_NAME)
		if not is_valid():
			return
		creatures.append(c)


## Call after changing creature positions (tests, demos): creature_at() rebuilds its index.
func creatures_moved() -> void:
	_creature_at.clear()


## `vehicles`, cleaned: anything malformed is left out (vehicles never fail a snapshot). The first MAX_VEHICLES,
## each with a uid not seen before, a position (z in z_lo..z_hi), a finite facing and at least one good part, and at
## most MAX_ALL_VEHICLE_PARTS parts in all. Parts are [mount_x, mount_y, vpart, hp_frac, state], plus [dx, dy, dz]
## (the part's square minus pos, CDDA's own) from a bridge that sends them: the first MAX_VEHICLE_PARTS of a vehicle,
## mounts within MAX_MOUNT, vpart 1..MAX_ID, hp_frac 0..255, state 0..15 (VPART_* bits), dx and dy within twice
## MAX_MOUNT, dz within MAX_VEHICLE_DZ and the part's level in z_lo..z_hi.
static func vehicles_from(v: Variant, z_lo: int, z_hi: int) -> Array[Vehicle]:
	var out: Array[Vehicle] = []
	if not v is Array:
		return out
	var seen := {}
	var left := MAX_ALL_VEHICLE_PARTS
	var lim := MAX_ABS_SM * CddaCoords.SEEX
	for e: Variant in (v as Array).slice(0, MAX_VEHICLES):
		if not e is Dictionary or left <= 0:
			continue
		var d: Dictionary = e
		var uid: Variant = _whole(d.get("uid"), 1, MAX_UID - 1)
		var face: Variant = _angle(d.get("face_deg"))
		var p: Variant = d.get("pos")
		if uid == null or seen.has(uid) or face == null or not p is Array or (p as Array).size() != 3:
			continue
		var x: Variant = _whole(p[0], -lim, lim)
		var y: Variant = _whole(p[1], -lim, lim)
		var z: Variant = _whole(p[2], z_lo, z_hi)
		if x == null or y == null or z == null:
			continue
		var veh := Vehicle.new()
		veh.uid = uid
		veh.pos = Vector3i(x, y, z)
		veh.face_deg = face
		var turn: Variant = _angle(d.get("turn_deg"))
		veh.turn_deg = turn if turn != null else face
		var sp: Variant = d.get("velocity")
		veh.velocity = float(sp) if (sp is float or sp is int) and absf(float(sp)) <= MAX_SPEED else 0.0
		veh.name = plain_text(d.get("name"), MAX_VEHICLE_NAME)
		veh.parts = _vehicle_parts(d.get("parts"), veh, mini(left, MAX_VEHICLE_PARTS), z_lo, z_hi)
		if veh.parts.is_empty():
			continue
		left -= veh.part_count()
		seen[uid] = true
		out.append(veh)
	return out


## An angle in degrees from the bridge as 0..360, or null when it isn't a number within MAX_ANGLE.
static func _angle(v: Variant) -> Variant:
	if not (v is float or v is int) or not (absf(float(v)) <= MAX_ANGLE):   # also false for NaN
		return null
	return fposmod(float(v), 360.0)


## A vehicle's part rows (vehicles_from), the first `cap` of them looked at; parts without dx, dy, dz get their
## mounts turned by the vehicle's facing on its level (and the vehicle isn't `exact`).
static func _vehicle_parts(v: Variant, veh: Vehicle, cap: int, z_lo: int, z_hi: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not v is Array:
		return out
	var lo := [-MAX_MOUNT, -MAX_MOUNT, 1, 0, 0, -2 * MAX_MOUNT, -2 * MAX_MOUNT, maxi(-MAX_VEHICLE_DZ, z_lo - veh.pos.z)]
	var hi := [MAX_MOUNT, MAX_MOUNT, MAX_ID, 255, 15, 2 * MAX_MOUNT, 2 * MAX_MOUNT, mini(MAX_VEHICLE_DZ, z_hi - veh.pos.z)]
	for e: Variant in (v as Array).slice(0, cap):
		if not e is Array or not ((e as Array).size() == 5 or (e as Array).size() == VPART_STRIDE):
			continue
		var row := PackedInt32Array()
		for k in (e as Array).size():
			var x: Variant = _whole(e[k], lo[k], hi[k])
			if x == null:
				break
			row.append(x)
		if row.size() != (e as Array).size():
			continue
		if row.size() == 5:
			var q := turn_mount(Vector2i(row[0], row[1]), veh.face_deg)
			row.append_array(PackedInt32Array([q.x, q.y, 0]))
			veh.exact = false
		out.append_array(row)
	return out


## A part's mount turned to facing `face_deg`: its square's offset from the vehicle's pos (mount x points ahead, y
## to the right). CDDA's own at right angles for a vehicle turned about mount 0,0; otherwise CDDA's square can be one
## off (it turns about a pivot and steps diagonals its own way), which is why the bridge sends dx, dy, dz.
static func turn_mount(m: Vector2i, face_deg: float) -> Vector2i:
	var a := deg_to_rad(face_deg)
	return Vector2i(roundi(m.x * cos(a) - m.y * sin(a)), roundi(m.x * sin(a) + m.y * cos(a)))


## The vehicle with parts on square p and which (indices into its parts, the bridge's order): [Vehicle,
## PackedInt32Array], or [] where there is none. Where two vehicles share a square the first listed wins.
func vehicle_at(p: Vector3i) -> Array:
	if _vehicle_at.is_empty():
		for veh in vehicles:
			for i in veh.part_count():
				var sq := veh.square(i)
				var e: Array = _vehicle_at.get(sq, [])
				if e.is_empty():
					_vehicle_at[sq] = [veh, PackedInt32Array([i])]
				elif e[0] == veh:
					var idx: PackedInt32Array = e[1]
					idx.append(i)
					e[1] = idx
		_vehicle_at[Vector3i.MAX] = []   # built, even when there are no vehicles
	return _vehicle_at.get(p, [])


## Call after changing vehicles (tests, demos): vehicle_at() rebuilds its index.
func vehicles_moved() -> void:
	_vehicle_at.clear()


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


## Whether tile `tile` of submap `pos` is the player's square or one of the 8 around it, on the same level.
func near_player(pos: Vector3i, tile: int) -> bool:
	var sq := CddaCoords.sm_to_ms(pos) + Vector3i(tile % CddaCoords.SEEX, tile / CddaCoords.SEEX, 0)
	return sq.z == player_pos.z and absi(sq.x - player_pos.x) <= 1 and absi(sq.y - player_pos.y) <= 1


## The uids of the items lying on square `sq` that have handles, in CDDA's order (a pile's first
## MAX_HANDLES_NEAR next to the player, its first MAX_HANDLES_PER_TILE elsewhere); [] for none.
func handles_at(sq: Vector3i) -> Array:
	var out := []
	var sm: Submap = submaps.get(CddaCoords.ms_to_sm(sq))
	if sm == null:
		return out
	var l := CddaCoords.ms_to_local(sq)
	var tile := l.y * CddaCoords.SEEX + l.x
	for k in range(0, sm.handles.size() - HANDLE_STRIDE + 1, HANDLE_STRIDE):
		if sm.handles[k] == tile:
			out.append(sm.handles[k + 1])
	return out


## How many items of the pile on square `sq` have no handle (the bridge cut its list short); 0 for none.
func more_at(sq: Vector3i) -> int:
	var sm: Submap = submaps.get(CddaCoords.ms_to_sm(sq))
	if sm == null:
		return 0
	var l := CddaCoords.ms_to_local(sq)
	return sm.more.get(l.y * CddaCoords.SEEX + l.x, 0)


## What is in container `container_uid` lying next to the player, one level (the snapshot's `inside`):
## [[uid, itype, pocket], ...] in the bridge's order; [] when nothing is listed.
func inside_of(container_uid: int) -> Array:
	var sm: Submap = submaps.get(_container_sm.get(container_uid, Vector3i.MAX))
	return (sm.inside.get(container_uid, []) as Array).duplicate(true) if sm != null else []


## How many more items are in that container than inside_of lists; 0 for none.
func inside_more_of(container_uid: int) -> int:
	var sm: Submap = submaps.get(_container_sm.get(container_uid, Vector3i.MAX))
	return sm.inside_more.get(container_uid, 0) if sm != null else 0


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
	if e.has("weather"):
		weather = _int(e["weather"], 0, MAX_ID, "env.weather")
	if e.has("wind_speed"):
		wind_speed = _float(e["wind_speed"], 0.0, WEATHER_MAX, "env.wind_speed")
	if e.has("wind_dir_deg"):
		wind_dir_deg = _float(e["wind_dir_deg"], -360.0, 360.0, "env.wind_dir_deg")
	if e.has("wind_at_player"):
		wind_at_player = _float(e["wind_at_player"], 0.0, WEATHER_MAX, "env.wind_at_player")
	if e.has("precip"):
		weather_precip = _int(e["precip"], 0, 3, "env.precip")
	if e.has("precip_kind"):
		weather_kind = _int(e["precip_kind"], PRECIP_NONE, PRECIP_SNOW, "env.precip_kind")
	if e.has("sight_penalty"):
		weather_sight = _float(e["sight_penalty"], 0.0, WEATHER_MAX, "env.sight_penalty")
	if e.has("light_modifier"):
		weather_light = _float(e["light_modifier"], -WEATHER_MAX, WEATHER_MAX, "env.light_modifier")
	if e.has("sun_multiplier"):
		weather_sun = _float(e["sun_multiplier"], 0.0, WEATHER_MAX, "env.sun_multiplier")
	if e.has("sheltered"):
		weather_sheltered = _flag(e["sheltered"], "env.sheltered")
	if e.has("weather_sound"):
		weather_sound = _int(e["weather_sound"], 0, 255, "env.weather_sound")
	if e.has("temperature_c"):
		temperature_c = _float(e["temperature_c"], -100.0, 100.0, "env.temperature_c")


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
		sm.handles = _handles(s.get("handles"), sm.pos, what + ".handles")
		sm.poses = _poses(s.get("poses"), sm.handles, what + ".poses")
		sm.shelves = _shelves(s.get("shelves"), sm.handles, what + ".shelves")
		sm.more = _more(s.get("more"), what + ".more")
		sm.inside = _inside(s.get("inside"), sm, what + ".inside")
		sm.inside_more = _inside_more(s.get("inside_more"), sm, what + ".inside_more")
		sm.flags = _bytes(s.get("flags"), 255, what + ".flags")
		sm.vis = _bytes(s.get("vis"), 3, what + ".vis")
		sm.light = _bytes(s.get("light"), 255, what + ".light")
		if s.has("lights"):
			has_lights = true
			sm.lights_sent = true
			sm.lights = _lights(s["lights"], what + ".lights")
		sm.heat = _heat(s.get("heat"), what + ".heat")
		sm.cookware = _cookware(s.get("cookware"), sm.heat, what + ".cookware")
		if not is_valid():
			return
		submaps[sm.pos] = sm
		for c: int in sm.inside:
			_container_sm[c] = sm.pos
		for c: int in sm.inside_more:
			_container_sm[c] = sm.pos


## `submap_keys` (contracts/snapshot.md "Deltas"): a row [x, y, z, revision, detail_revision, hash] per submap. A
## full answer has a body for every row. A delta (`base`: the seq of the snapshot it was built on) has bodies only
## for some; every other row must name a submap `base` holds with the same revisions and hash (same id tables), and
## that Submap is taken over as it is. Only positions are compared: the bubble and the player may have moved. Any
## row that doesn't add up fails the snapshot (the caller then asks for a full one); `base` is never changed.
func _read_keys(d: Dictionary, base: Snapshot) -> void:
	if not is_valid():
		return
	var delta := d.has("base")
	if delta:
		base_seq = _int(d["base"], 0, MAX_TURN, "base")
		if is_valid() and (base == null or not base.is_valid() or base.seq != base_seq):
			_fail("a delta on snapshot %d, but %s is held" % [base_seq, "none" if base == null else str(base.seq)])
	if not is_valid():
		return
	if not d.has("submap_keys"):
		if delta:
			_fail("a delta without submap_keys")
		return
	if not d["submap_keys"] is Array:
		_fail("submap_keys is not a list")
		return
	var rows: Array = d["submap_keys"]
	if rows.size() > max_submaps():
		_fail("%d submap_keys, cap is %d" % [rows.size(), max_submaps()])
		return
	for i in rows.size():
		var what := "submap_keys[%d]" % i
		if not rows[i] is Array or (rows[i] as Array).size() != KEY_STRIDE:
			_fail(what + " is not [x, y, z, revision, detail_revision, hash]")
			return
		var r: Array = rows[i]
		var p := Vector3i(_int(r[0], -MAX_ABS_SM, MAX_ABS_SM, what + ".x"), _int(r[1], -MAX_ABS_SM, MAX_ABS_SM, what + ".y"),
				_int(r[2], z_min, z_max, what + ".z"))
		var rev := _int(r[3], 0, MAX_REVISION, what + ".revision")
		var detail := _int(r[4], 0, MAX_REVISION, what + ".detail_revision")
		var h := _int(r[5], 0, MAX_HASH, what + ".hash")
		if not is_valid():
			return
		var rel := p - bubble_origin
		if rel.x < 0 or rel.x >= CddaCoords.MAPSIZE or rel.y < 0 or rel.y >= CddaCoords.MAPSIZE:
			_fail("%s: %s is outside the bubble" % [what, p])
			return
		if submap_hash.has(p):
			_fail("%s: %s appears twice" % [what, p])
			return
		var sm: Submap = submaps.get(p)
		if sm != null:
			if sm.revision != rev or sm.detail_revision != detail:
				_fail("%s: the revisions of %s aren't its body's" % [what, p])
				return
		elif not delta:
			_fail("%s: %s has no body" % [what, p])
			return
		else:
			var old: Submap = base.submaps.get(p)
			if old == null or old.revision != rev or old.detail_revision != detail or base.submap_hash.get(p, -1) != h \
					or base.ids_generation != ids_generation:
				_fail("%s: %s isn't in snapshot %d as the row says" % [what, p, base_seq])
				return
			submaps[p] = old
			reused_submaps += 1
			if old.lights_sent:
				has_lights = true
			for c: int in old.inside:
				_container_sm[c] = p
			for c: int in old.inside_more:
				_container_sm[c] = p
		submap_hash[p] = h
	if submap_hash.size() != submaps.size():
		_fail("%d submaps have no submap_keys row" % (submaps.size() - submap_hash.size()))


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


## A true/false field: a bool, or 0 / 1.
func _flag(v: Variant, what: String) -> bool:
	if v is bool:
		return v
	return _int(v, 0, 1, what) == 1


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


## [[tile, uid, type, spot_x, spot_y], ...] of submap `pos`: at most MAX_HANDLES_PER_TILE per tile
## (MAX_HANDLES_NEAR on the player's square and the 8 around it), distinct uids.
func _handles(v: Variant, pos: Vector3i, what: String) -> PackedInt64Array:
	var out := PackedInt64Array()
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_HANDLES_PER_SUBMAP:
		_fail("%s: expected a list of at most %d handles" % [what, MAX_HANDLES_PER_SUBMAP])
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
		var cap := MAX_HANDLES_NEAR if near_player(pos, tile) else MAX_HANDLES_PER_TILE
		if is_valid() and (per_tile[tile] > cap or uids.has(uid)):
			_fail("%s: more than %d on tile %d, or uid %d twice" % [w, cap, tile, uid])
		uids[uid] = true
		if not is_valid():
			return out
	return out


## player.item_states, cleaned (look-only data: anything malformed is left out, it never fails a snapshot):
## [[uid, temp, rot, fill, fill_type, see_through, fill_ml, dirt], ...] -> uid -> PackedInt32Array(STATE_SIZE),
## the first MAX_ITEM_STATES, each uid one of `known` (carried items, handles and what is in the containers lying next to the player), the
## first of a repeat kept.
## temp 0..3, rot -1..2000, fill -1..1000 permille and fill_ml -1..MAX_STATE_ML (both -1 or neither: not a
## container), fill_type an itype index or 0, see_through 0/1, dirt -1..MAX_DIRT. Values as ItemLook reads them.
static func states_from(v: Variant, known: Dictionary) -> Dictionary:
	var out := {}
	if not v is Array:
		return out
	var lo := [0, -1, -1, 0, 0, -1, -1]
	var hi := [3, 2000, 1000, MAX_ID, 1, MAX_STATE_ML, MAX_DIRT]
	for e: Variant in (v as Array).slice(0, MAX_ITEM_STATES):
		if not e is Array or (e as Array).size() != STATE_SIZE + 1:
			continue
		var uid: Variant = _whole(e[0], 1, MAX_UID - 1)
		if uid == null or not known.has(uid) or out.has(uid):
			continue
		var s := PackedInt32Array()
		for k in STATE_SIZE:
			var x: Variant = _whole(e[k + 1], lo[k], hi[k])
			if x == null:
				break
			s.append(x)
		if s.size() == STATE_SIZE and (s[2] == -1) == (s[5] == -1):
			out[uid] = s
	return out


## player.item_amounts, cleaned like item_states (anything malformed is left out, it never fails a snapshot):
## [[uid, count, weight_g, volume_ml], ...] -> uid -> PackedInt32Array([count, weight_g, volume_ml]), the first
## MAX_ITEM_AMOUNTS, each uid one of `known`, the first of a repeat kept; count 1..MAX_COUNT, grams and ml
## 0..MAX_AMOUNT.
static func amounts_from(v: Variant, known: Dictionary) -> Dictionary:
	var out := {}
	if not v is Array:
		return out
	var hi := [MAX_COUNT, MAX_AMOUNT, MAX_AMOUNT]
	for e: Variant in (v as Array).slice(0, MAX_ITEM_AMOUNTS):
		if not e is Array or (e as Array).size() != 4:
			continue
		var uid: Variant = _whole(e[0], 1, MAX_UID - 1)
		if uid == null or not known.has(uid) or out.has(uid):
			continue
		var a := PackedInt32Array()
		for k in 3:
			var x: Variant = _whole(e[k + 1], 1 if k == 0 else 0, hi[k])
			if x == null:
				break
			a.append(x)
		if a.size() == 3:
			out[uid] = a
	return out


## [[uid, yaw, side], ...]: how placed items lie (older bridges send none); each uid one of the submap's
## handles, at most once.
func _poses(v: Variant, handles: PackedInt64Array, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	var n := handles.size() / HANDLE_STRIDE
	if not v is Array or (v as Array).size() > n:
		_fail("%s: expected a list of at most %d poses (one per handle)" % [what, n])
		return out
	var known := {}
	for k in range(1, handles.size(), HANDLE_STRIDE):
		known[handles[k]] = true
	for i in (v as Array).size():
		var e: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not e is Array or (e as Array).size() != 3:
			_fail(w + ": expected [uid, yaw, side]")
			return out
		var uid := _int(e[0], 1, MAX_UID - 1, w + ".uid")
		var yaw := _int(e[1], 0, 359, w + ".yaw")
		var side := _flag(e[2], w + ".side")
		if is_valid() and (not known.has(uid) or out.has(uid)):
			_fail("%s: uid %d is not a handle here, or comes twice" % [w, uid])
		if not is_valid():
			return out
		out[uid] = Vector2i(yaw, 1 if side else 0)
	return out


## [[uid, shelf], ...]: the furniture surface each placed item was put on (older bridges send none); each uid
## one of the submap's handles, at most once; shelf 0..MAX_SHELF.
func _shelves(v: Variant, handles: PackedInt64Array, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	var n := handles.size() / HANDLE_STRIDE
	if not v is Array or (v as Array).size() > n:
		_fail("%s: expected a list of at most %d shelves (one per handle)" % [what, n])
		return out
	var known := {}
	for k in range(1, handles.size(), HANDLE_STRIDE):
		known[handles[k]] = true
	for i in (v as Array).size():
		var e: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not e is Array or (e as Array).size() != 2:
			_fail(w + ": expected [uid, shelf]")
			return out
		var uid := _int(e[0], 1, MAX_UID - 1, w + ".uid")
		var shelf := _int(e[1], 0, MAX_SHELF, w + ".shelf")
		if is_valid() and (not known.has(uid) or out.has(uid)):
			_fail("%s: uid %d is not a handle here, or comes twice" % [w, uid])
		if not is_valid():
			return out
		out[uid] = shelf
	return out


## [[tile, n], ...]: how many items of a tile's pile have no handle, where the bridge cut its list short (older
## bridges send none); distinct tiles, n 1..MAX_MORE.
func _more(v: Variant, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > TILES:
		_fail("%s: expected a list of at most %d [tile, n]" % [what, TILES])
		return out
	for i in (v as Array).size():
		var e: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not e is Array or (e as Array).size() != 2:
			_fail(w + ": expected [tile, n]")
			return out
		var tile := _int(e[0], 0, TILES - 1, w + ".tile")
		var n := _int(e[1], 1, MAX_MORE, w + ".n")
		if is_valid() and out.has(tile):
			_fail("%s: tile %d comes twice" % [w, tile])
		if not is_valid():
			return out
		out[tile] = n
	return out


## Handle uid -> tile, of one submap's handles.
static func _handle_tiles(handles: PackedInt64Array) -> Dictionary:
	var out := {}
	for k in range(0, handles.size() - HANDLE_STRIDE + 1, HANDLE_STRIDE):
		out[handles[k + 1]] = int(handles[k])
	return out


## [[container_uid, uid, type, pocket], ...]: what is in the containers lying on the player's square and the 8
## around it, one level (older bridges send none). Each container is one of the submap's handles on such a
## square; at most MAX_INSIDE_PER_CONTAINER in one and MAX_INSIDE_PER_SUBMAP in all; uids distinct and none
## of them a handle (they don't lie on the ground); pocket 0..MAX_POCKET (the item-action index, as carried).
func _inside(v: Variant, sm: Submap, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	if not v is Array or (v as Array).size() > MAX_INSIDE_PER_SUBMAP:
		_fail("%s: expected a list of at most %d items" % [what, MAX_INSIDE_PER_SUBMAP])
		return out
	var tiles := _handle_tiles(sm.handles)
	var uids := {}
	for i in (v as Array).size():
		var e: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not e is Array or (e as Array).size() != 4:
			_fail(w + ": expected [container_uid, uid, type, pocket]")
			return out
		var c := _int(e[0], 1, MAX_UID - 1, w + ".container_uid")
		var uid := _int(e[1], 1, MAX_UID - 1, w + ".uid")
		var type := _int(e[2], 1, MAX_ID, w + ".type")
		var pocket := _int(e[3], 0, MAX_POCKET, w + ".pocket")
		if is_valid() and (not tiles.has(c) or not near_player(sm.pos, tiles[c])):
			_fail("%s: container %d is not a handle next to the player" % [w, c])
		elif is_valid() and (uids.has(uid) or tiles.has(uid)):
			_fail("%s: uid %d comes twice, or lies on the ground" % [w, uid])
		elif is_valid() and (out.get(c, []) as Array).size() >= MAX_INSIDE_PER_CONTAINER:
			_fail("%s: more than %d in container %d" % [w, MAX_INSIDE_PER_CONTAINER, c])
		if not is_valid():
			return out
		uids[uid] = true
		if not out.has(c):
			out[c] = []
		(out[c] as Array).append([uid, type, pocket])
	return out


## [[container_uid, n], ...]: how many more are in a container than `inside` lists (older bridges send none);
## each container one of the submap's handles next to the player, at most once; n 1..MAX_MORE.
func _inside_more(v: Variant, sm: Submap, what: String) -> Dictionary:
	var out := {}
	if v == null or not is_valid():
		return out
	var tiles := _handle_tiles(sm.handles)
	if not v is Array or (v as Array).size() > tiles.size():
		_fail("%s: expected a list of at most %d [container_uid, n] (one per handle)" % [what, tiles.size()])
		return out
	for i in (v as Array).size():
		var e: Variant = v[i]
		var w := "%s[%d]" % [what, i]
		if not e is Array or (e as Array).size() != 2:
			_fail(w + ": expected [container_uid, n]")
			return out
		var c := _int(e[0], 1, MAX_UID - 1, w + ".container_uid")
		var n := _int(e[1], 1, MAX_MORE, w + ".n")
		if is_valid() and (not tiles.has(c) or not near_player(sm.pos, tiles[c]) or out.has(c)):
			_fail("%s: container %d is not a handle next to the player, or comes twice" % [w, c])
		if not is_valid():
			return out
		out[c] = n
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
