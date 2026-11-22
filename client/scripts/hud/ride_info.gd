class_name RideInfo
extends RefCounted
## The driving HUD's data (user via the coordinator, 2026-11-21): the snapshot's player.ride block, present only
## while the player is on a vehicle (contracts/snapshot.md; field names agreed with lead-bridge). Everything is
## checked: a junk field falls back to its default, numbers are clamped, strings capped, lists cut. Speeds stay in
## CDDA's vmiph (100 = 1 mph, negative in reverse) until shown (shown()).

const MAX_NAME := 64
const MAX_FUELS := 8
const MAX_VMIPH := 100000          # 1000 mph: anything faster is junk
const MAX_AMOUNT := 1 << 40        # fuel and battery amounts
const MAX_MASS_KG := 10000000
const UNITS := {"mph": 1.0, "km/h": 1.609344}   # what one mph shows as; "t/t" only with the bridge's factor
enum Band { SAFE, WARN, OVER }

var ok := false              # a ride block was there
var name := ""
var driver := false          # holds the controls
var velocity := 0            # vmiph
var cruise := 0              # the throttle / target, vmiph
var cruise_on := false
var safe := 0                # safe_velocity, vmiph (0: unknown, no engine)
var top := 0                 # max_velocity, vmiph
var engine_on := false
var fuels: Array[Dictionary] = []   # {id, name, left, cap}
var battery_left := -1       # kJ; -1: no batteries
var battery_cap := -1
var skidding := false
var out_of_control := false
var turn := 0                # degrees 0..359, where the driver steers
var face := 0                # degrees 0..359, where the vehicle points
var mass_kg := -1
var health := -1             # percent, -1 unknown
var unit := "mph"
var unit_per_mph := 1.0


## player.ride as a RideInfo; `ok` false (and the defaults) when it isn't a Dictionary.
static func read(v: Variant) -> RideInfo:
	var r := RideInfo.new()
	if not v is Dictionary:
		return r
	var d: Dictionary = v
	r.ok = true
	r.name = _text(d.get("name"), MAX_NAME)
	r.driver = _bool(d.get("driver"))
	r.velocity = _int(d.get("velocity"), -MAX_VMIPH, MAX_VMIPH, 0)
	r.cruise = _int(d.get("cruise"), -MAX_VMIPH, MAX_VMIPH, 0)
	r.cruise_on = _bool(d.get("cruise_on"))
	r.safe = _int(d.get("safe"), 0, MAX_VMIPH, 0)
	r.top = maxi(_int(d.get("max"), 0, MAX_VMIPH, 0), r.safe)
	r.engine_on = _bool(d.get("engine_on"))
	var fl: Variant = d.get("fuel")
	if fl is Array:
		for f: Variant in (fl as Array).slice(0, MAX_FUELS):
			if not f is Dictionary:
				continue
			var cap := _int((f as Dictionary).get("cap"), 0, MAX_AMOUNT, -1)
			var left := _int((f as Dictionary).get("left"), 0, MAX_AMOUNT, -1)
			var id := _text((f as Dictionary).get("id"), MAX_NAME)
			if cap <= 0 or left < 0 or id.is_empty():
				continue
			var shown_name := _text((f as Dictionary).get("name"), MAX_NAME)
			r.fuels.append({"id": id, "name": shown_name if not shown_name.is_empty() else id,
					"left": mini(left, cap), "cap": cap})
	var b: Variant = d.get("battery")
	if b is Array and (b as Array).size() == 2:
		var bl := _int(b[0], 0, MAX_AMOUNT, -1)
		var bc := _int(b[1], 0, MAX_AMOUNT, -1)
		if bl >= 0 and bc > 0:
			r.battery_left = mini(bl, bc)
			r.battery_cap = bc
	r.skidding = _bool(d.get("skidding"))
	r.out_of_control = _bool(d.get("out_of_control"))
	r.turn = posmod(_int(d.get("turn"), -100000, 100000, 0), 360)
	r.face = posmod(_int(d.get("face"), -100000, 100000, 0), 360)
	r.mass_kg = _int(d.get("mass_kg"), 0, MAX_MASS_KG, -1)
	r.health = _int(d.get("health"), 0, 100, -1)
	var u: Variant = d.get("unit")
	var k: Variant = d.get("unit_per_mph")
	var factor_ok: bool = (k is float or k is int) and is_finite(float(k)) and float(k) > 0.0001 and float(k) < 100.0
	if u is String and (u == "t/t" or UNITS.has(u)) and (factor_ok or UNITS.has(u)):
		r.unit = u
		r.unit_per_mph = float(k) if factor_ok else UNITS[u]
	return r


## `vmiph` in the player's units (CDDA's option).
func shown(vmiph: int) -> float:
	return vmiph / 100.0 * unit_per_mph


## Where `vmiph` falls: up to the safe speed, up to the top speed, beyond. Unknown limits (no engine): safe.
func band(vmiph: int) -> Band:
	var v := absi(vmiph)
	if safe <= 0 or v <= safe:
		return Band.SAFE
	return Band.WARN if v <= top else Band.OVER


## Degrees the driver steers off where the vehicle points: negative left, positive right (-180..179).
func steer() -> int:
	return posmod(turn - face + 180, 360) - 180


## The warning to show, or "" (out of control first).
func warning() -> String:
	if out_of_control:
		return "OUT OF CONTROL"
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


## A plain one-line string, capped; "" for anything else.
static func _text(v: Variant, cap: int) -> String:
	if not v is String:
		return ""
	return (v as String).replace("\n", " ").strip_edges().left(cap)
