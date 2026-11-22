class_name RideInfo
extends RefCounted
## The driving HUD's data (user via the coordinator, 2026-11-21): the snapshot's player.vehicle_state, present only
## while the player is boarded on a vehicle, driver or passenger (contracts/snapshot.md "The player's vehicle",
## lead-bridge). Everything is checked: a junk field falls back to its default, numbers are clamped, strings capped,
## lists cut. Speeds stay in CDDA's units (mph * 100, negative backwards) until shown (shown()).

const MAX_NAME := 64
const MAX_LIST := 16               # engines and fuels, as the bridge caps them
const MAX_FUELS := 8               # fuel rows shown
const MAX_VMIPH := 100000          # 1000 mph: anything faster is junk
const MAX_AMOUNT := 1 << 40        # fuel and battery amounts
const MAX_MASS_KG := 10000000
const MAX_INDEX := 1 << 24         # itype indexes
## speed_unit -> the factor when the bridge's speed_scale is junk.
const SCALES := {"mph": 0.01, "km/h": 0.01609344, "t/t": 0.0025}
## CDDA's words for its overall condition, from the top: above this percent.
const HEALTH_WORDS := [[95, "like new"], [67, "dented"], [34, "battered"], [0, "wrecked"]]
const ENGINE_RUNNING := 2
const ENGINE_BROKEN := 4
enum Band { SAFE, WARN, OVER }

var ok := false              # a vehicle_state block was there
var uid := 0
var name := ""
var driver := false          # in_control: holds the controls
var at_controls := false     # the player's square has controls
var velocity := 0            # mph * 100
var cruise := 0              # cruise_velocity: the speed it is set to reach
var safe := 0                # safe_velocity (0: unknown, no engine)
var top := 0                 # max_velocity
var engine_on := false
var engines := 0             # engines listed
var engines_running := 0
var engines_broken := 0
var fuels: Array[Dictionary] = []   # {type, name, left, cap}, up to MAX_FUELS
var battery_left := -1       # kJ; -1: no battery
var battery_cap := -1
var skidding := false
var turn_deg := NAN          # the facing it steers to; NAN when not sent
var face_deg := NAN          # the facing it has (Snapshot.vehicles); NAN when unknown
var mass_kg := -1
var health := -1             # percent, -1 unknown
var unit := "mph"
var scale := 0.01            # a speed times this shows in `unit`


## player.vehicle_state as a RideInfo; `ok` false (and the defaults) when it isn't a Dictionary. `item_name`:
## (itype index) -> String for the fuels' names. `face`: the vehicle's facing from Snapshot.vehicles, NAN unknown.
static func read(v: Variant, item_name := Callable(), face := NAN) -> RideInfo:
	var r := RideInfo.new()
	if not v is Dictionary:
		return r
	var d: Dictionary = v
	r.ok = true
	r.uid = _int(d.get("uid"), 0, 0x7fffffffffffffff, 0)
	r.name = _text(d.get("name"), MAX_NAME)
	r.driver = _bool(d.get("in_control"))
	r.at_controls = _bool(d.get("at_controls"))
	r.velocity = _int(d.get("velocity"), -MAX_VMIPH, MAX_VMIPH, 0)
	r.cruise = _int(d.get("cruise_velocity"), -MAX_VMIPH, MAX_VMIPH, 0)
	r.safe = _int(d.get("safe_velocity"), 0, MAX_VMIPH, 0)
	r.top = maxi(_int(d.get("max_velocity"), 0, MAX_VMIPH, 0), r.safe)
	r.engine_on = _bool(d.get("engine_on"))
	var en: Variant = d.get("engines")
	if en is Array:
		for e: Variant in (en as Array).slice(0, MAX_LIST):
			if not e is Array or (e as Array).size() < 2:
				continue
			var state := _int(e[1], 0, 255, -1)
			if state < 0:
				continue
			r.engines += 1
			if state & ENGINE_RUNNING:
				r.engines_running += 1
			if state & ENGINE_BROKEN:
				r.engines_broken += 1
	var fl: Variant = d.get("fuels")
	if fl is Array:
		for f: Variant in (fl as Array).slice(0, MAX_LIST):
			if r.fuels.size() >= MAX_FUELS:
				break
			if not f is Array or (f as Array).size() != 3:
				continue
			var type := _int(f[0], 0, MAX_INDEX, -1)
			var left := _int(f[1], 0, MAX_AMOUNT, -1)
			var cap := _int(f[2], 0, MAX_AMOUNT, -1)
			if type <= 0 or left < 0 or cap <= 0:
				continue
			var n: Variant = item_name.call(type) if item_name.is_valid() else null
			var shown_name := _text(n, MAX_NAME)
			r.fuels.append({"type": type, "name": shown_name if not shown_name.is_empty() else "fuel",
					"left": mini(left, cap), "cap": cap})
	var b: Variant = d.get("battery")
	if b is Array and (b as Array).size() == 2:
		var bl := _int(b[0], 0, MAX_AMOUNT, -1)
		var bc := _int(b[1], 0, MAX_AMOUNT, -1)
		if bl >= 0 and bc > 0:   # [0, 0]: no battery
			r.battery_left = mini(bl, bc)
			r.battery_cap = bc
	r.skidding = _bool(d.get("skidding"))
	r.turn_deg = _angle(d.get("turn_deg"))
	r.face_deg = _angle(face)
	r.mass_kg = _int(d.get("mass_kg"), 0, MAX_MASS_KG, -1)
	r.health = _int(d.get("health_pct"), 0, 100, -1)
	var u: Variant = d.get("speed_unit")
	if u is String and SCALES.has(u):
		r.unit = u
		var k: Variant = d.get("speed_scale")
		var good: bool = (k is float or k is int) and is_finite(float(k)) and float(k) > 0.00001 and float(k) < 1.0
		r.scale = float(k) if good else SCALES[u]
	return r


## A speed (mph * 100) in the player's unit (CDDA's option).
func shown(vmiph: int) -> float:
	return vmiph * scale


## Where a speed falls: up to the safe speed (no strain), up to the top speed, beyond. Unknown limits: safe.
func band(vmiph: int) -> Band:
	var v := absi(vmiph)
	if safe <= 0 or v <= safe:
		return Band.SAFE
	return Band.WARN if v <= top else Band.OVER


## Degrees the driver steers off where the vehicle points: negative left, positive right (CDDA's angles grow
## clockwise); 0 when either is unknown.
func steer() -> int:
	if is_nan(turn_deg) or is_nan(face_deg):
		return 0
	return posmod(roundi(turn_deg - face_deg) + 180, 360) - 180


## CDDA's word for the vehicle's condition ("" unknown).
func health_word() -> String:
	if health < 0:
		return ""
	for w: Array in HEALTH_WORDS:
		if health > w[0]:
			return w[1]
	return "destroyed"


## The warning to show, or "".
func warning() -> String:
	return "SKIDDING" if skidding else ""


## Only a real true is true (comparing a String with a bool is an error in Godot).
static func _bool(v: Variant) -> bool:
	return v is bool and v


static func _int(v: Variant, lo: int, hi: int, fallback: int) -> int:
	if v is int:
		return clampi(v, lo, hi)
	if v is float and is_finite(v):
		return roundi(clampf(v, lo, hi))   # clamped first: a huge float has no int
	return fallback


## An angle 0..360, NAN for anything else.
static func _angle(v: Variant) -> float:
	if (v is float or v is int) and is_finite(float(v)) and absf(float(v)) <= 100000.0:
		return fposmod(float(v), 360.0)
	return NAN


## A plain one-line string, capped; "" for anything else.
static func _text(v: Variant, cap: int) -> String:
	if not v is String:
		return ""
	return (v as String).replace("\n", " ").replace("\r", " ").replace("\t", " ").strip_edges().left(cap)
