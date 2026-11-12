class_name WeatherState
extends RefCounted
## Blocks C6 / I2: what the weather looks like, as plain numbers from one snapshot's `env`.
##
## Everything comes from CDDA's own values for the current weather type (sun multiplier, light modifier, sight
## penalty, precipitation), never from the weather's name, so a mod's weather shows too. A snapshot without those
## fields reads as clear weather. WeatherView shows a state; tests check the numbers here.

const SIGHT_CLEAR_M := 60.0    # CDDA's sight distance in open air by day (LIGHT_TRANSPARENCY_OPEN_AIR)
const GLOOM_FULL := 45.0       # CDDA's darkest weather (lightning) takes 45 off the natural light
const FOG_FULL := 0.25         # sight penalty above 1 at which the distance fades fully (snow 0.3, fog 0.7)
const WIND_MAX := 40.0         # m/s shown at most (CDDA's storms stay far below)
const SUN_SHADED := 0.2        # sunlight left under the heaviest cover
const SKY_GLOOMY := 0.5        # sky brightness left in the darkest weather
const AMBIENT_GLOOMY := 0.8
const CLEAR_TOP := Color(0.385, 0.454, 0.55)       # Godot's default procedural sky
const CLEAR_HORIZON := Color(0.646, 0.656, 0.671)
const OVERCAST_TOP := Color(0.43, 0.45, 0.48)
const OVERCAST_HORIZON := Color(0.58, 0.6, 0.62)
const FOG_WHITE := Color(0.78, 0.8, 0.82)

var cloud := 0.0        # 0 clear sky .. 1 overcast (1 - CDDA's sun multiplier)
var gloom := 0.0        # 0 .. 1: how much the weather darkens the day (CDDA's light modifier)
var fog := 0.0          # 0 none .. 1 full: how strongly the distance fades
var sight_m := SIGHT_CLEAR_M   # CDDA's sight distance in this weather, metres
var precip := 0.0       # 0 none, 1/3 very light, 2/3 light, 1 heavy
var snow := false       # the precipitation is snow
var wind := Vector3.ZERO        # the region's wind, m/s, where it blows to (world space, level)
var wind_here := Vector3.ZERO   # the same on the player's square (calm indoors); the region's when not sent
var sheltered := false  # rain and snow don't reach the player
var daylight := 1.0     # 0 night .. 1 day: the weather only dims what the day lights


static func from_snapshot(snap: Snapshot) -> WeatherState:
	var s := WeatherState.new()
	if snap == null:
		return s
	s.cloud = clampf(1.0 - snap.weather_sun, 0.0, 1.0)
	s.gloom = clampf(-snap.weather_light / GLOOM_FULL, 0.0, 1.0)
	var penalty := maxf(snap.weather_sight, 1.0)
	s.sight_m = SIGHT_CLEAR_M / penalty
	s.fog = clampf((penalty - 1.0) / FOG_FULL, 0.0, 1.0)
	if snap.weather_kind != Snapshot.PRECIP_NONE:
		s.precip = clampi(snap.weather_precip, 0, 3) / 3.0
	s.snow = s.precip > 0.0 and snap.weather_kind == Snapshot.PRECIP_SNOW
	s.wind = wind_vector(snap.wind_speed, snap.wind_dir_deg)
	s.wind_here = s.wind if snap.wind_at_player < 0.0 else wind_vector(snap.wind_at_player, snap.wind_dir_deg)
	s.sheltered = snap.weather_sheltered
	s.daylight = smoothstep(20.0, 60.0, float(LightMap.natural_light(snap)))
	return s


## CDDA's wind: `dir_deg` is where it comes from, 0 north, 90 east (north is -y on CDDA's map, -z here).
static func wind_vector(speed: float, dir_deg: float) -> Vector3:
	if not is_finite(speed) or not is_finite(dir_deg):
		return Vector3.ZERO
	var a := deg_to_rad(dir_deg)
	return Vector3(-sin(a), 0.0, cos(a)) * clampf(speed, 0.0, WIND_MAX)


## The state `t` of the way from `a` to `b` (flags are b's).
static func blend(a: WeatherState, b: WeatherState, t: float) -> WeatherState:
	var s := WeatherState.new()
	s.cloud = lerpf(a.cloud, b.cloud, t)
	s.gloom = lerpf(a.gloom, b.gloom, t)
	s.fog = lerpf(a.fog, b.fog, t)
	s.sight_m = lerpf(a.sight_m, b.sight_m, t)
	s.precip = lerpf(a.precip, b.precip, t)
	s.wind = a.wind.lerp(b.wind, t)
	s.wind_here = a.wind_here.lerp(b.wind_here, t)
	s.daylight = lerpf(a.daylight, b.daylight, t)
	s.snow = b.snow
	s.sheltered = b.sheltered
	return s


## True when the two look the same (nothing to blend).
func same_look(o: WeatherState) -> bool:
	return (is_equal_approx(cloud, o.cloud) and is_equal_approx(gloom, o.gloom) and is_equal_approx(fog, o.fog)
			and is_equal_approx(sight_m, o.sight_m) and is_equal_approx(precip, o.precip)
			and is_equal_approx(daylight, o.daylight) and wind.is_equal_approx(o.wind) and snow == o.snow)


## 1 by night (CDDA's natural light already carries the weather there), `dimmed` by day.
func _by_day(dimmed: float) -> float:
	return lerpf(1.0, dimmed, daylight)


## Multiplier on the sun's light.
func sun_scale() -> float:
	return _by_day(lerpf(1.0, SUN_SHADED, maxf(cloud, gloom)))


## Multiplier on the sky's brightness.
func sky_energy() -> float:
	return _by_day(lerpf(1.0, SKY_GLOOMY, gloom))


## Multiplier on the ambient light.
func ambient_scale() -> float:
	return _by_day(lerpf(1.0, AMBIENT_GLOOMY, gloom))


## How dark the sun's shadows are: sharp under a clear sky, gone under full cover.
func shadow_opacity() -> float:
	return 1.0 - smoothstep(0.5, 0.95, cloud)


## Whether the sun's disc shows through.
func sun_disc() -> bool:
	return cloud < 0.6


func sky_top() -> Color:
	return CLEAR_TOP.lerp(OVERCAST_TOP, smoothstep(0.2, 0.9, cloud))


func sky_horizon() -> Color:
	return CLEAR_HORIZON.lerp(OVERCAST_HORIZON, smoothstep(0.2, 0.9, cloud))


## Brightness of the cloud layer over the sky's own colour: none when clear, bright separate clouds at half
## cover, a faint mottling under full cover (the sky itself is grey then).
func cloud_layer() -> float:
	return 0.55 * 4.0 * cloud * (1.0 - cloud) + 0.06 * cloud


## The colour the distance fades to: the horizon, whiter in thick fog, darker in dark weather.
func fog_color() -> Color:
	var c := sky_horizon().lerp(FOG_WHITE, 0.5 * fog)
	var e := _by_day(lerpf(1.0, 0.7, gloom))
	return Color(c.r * e, c.g * e, c.b * e)


## Where the fade is complete, metres from the viewer: a little past CDDA's sight distance.
func fog_end_m() -> float:
	return sight_m * 1.2
