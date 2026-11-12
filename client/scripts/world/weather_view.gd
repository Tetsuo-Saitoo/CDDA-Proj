class_name WeatherView
extends Node
## Blocks C6 / I2: shows the weather on the sky, the sun and the distance (clouds, darker days, fog).
##
## setup() takes the scene's Environment (a ProceduralSkyMaterial sky) and its sun; apply() shows a snapshot's
## weather (WeatherState). Only engine features: the procedural sky with a cloud cover texture, depth fog and the
## sun's energy and shadows, so VR gets the same per eye and nothing is drawn extra. A change of weather blends
## over blend_s seconds in a few steps (each step makes the engine filter the sky's light again); between changes
## this node only moves the fog's start with the camera, and does nothing at all without fog.

const BLEND_S := 3.0
const BLEND_STEP_S := 0.25
## Changes smaller than this (dusk getting darker turn by turn) show at once.
const BLEND_MIN := 0.08
const AMBIENT_ENERGY := 0.8
const EYE_M := 1.6
const INDOOR_CLEAR_M := 8.0   # under a roof the fog starts this far out: the room is clear, the windows show it
const INDOOR_CLEAR_S := 1.5   # seconds it takes to clear or close in when the player goes under or leaves a roof
const COVER_W := 512
const COVER_H := 256
const CLOUD_SCALE := 2.2      # cloud shapes per unit of the layer (its height above the eye is 1)
const CLOUD_HORIZON := 0.2    # keeps the layer's far end finite at the horizon

var state := WeatherState.new()    # shown now
var target := WeatherState.new()   # the last snapshot's
var blend_s := BLEND_S             # 0: every change shows at once
var focus := Vector3.ZERO          # the player's eyes: the fog starts there, also for a camera further away
var light_pass := true             # WorldLighting darkens the scene by CDDA's light (else the fog darkens itself)
var sky_updates := 0               # times the sky was changed (each one costs a re-filter of its light)
var _env: Environment
var _sky: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var _sun_up := true
var _sun_base := 1.0               # the sun's energy before the weather
var _from: WeatherState
var _blend_t := 1.0
var _since_step := 0.0
var _shown := false
var _clear_m := 0.0                # how far out the fog starts now (INDOOR_CLEAR_M under a roof)
static var _cover: Image


func _ready() -> void:
	_update_processing()   # a node with _process starts processing on its own


## `env` and `sun` may be null (a test with only one of them).
func setup(env: Environment, sun: DirectionalLight3D) -> void:
	_env = env
	_sun = sun
	_sky = null
	if env != null and env.sky != null:
		_sky = env.sky.sky_material as ProceduralSkyMaterial
	if _sky != null and _sky.sky_cover == null:
		_sky.sky_cover = ImageTexture.create_from_image(cover_image())
		_sky.sky_cover_modulate = Color.BLACK
	if _env != null:
		_env.fog_mode = Environment.FOG_MODE_DEPTH
		_env.fog_depth_curve = 1.0
		_env.fog_aerial_perspective = 0.0
		_env.fog_sun_scatter = 0.0
	_show()


## Shows `snap`'s weather and sun. `lighting_on`: WorldLighting's pass is on.
func apply(snap: Snapshot, coords: CddaCoords, lighting_on: bool) -> void:
	light_pass = lighting_on
	if coords != null:
		focus = coords.ms_center_to_world(snap.player_pos) + Vector3(0.0, EYE_M, 0.0)
	aim_sun(snap.sun_alt_deg, snap.sun_az_deg)
	target = WeatherState.from_snapshot(snap)
	if not _shown or blend_s <= 0.0:
		_clear_m = INDOOR_CLEAR_M if target.sheltered else 0.0
	if not _shown or blend_s <= 0.0 or _close(state, target):
		_blend_t = 1.0
		state = target
	else:
		_from = state
		_blend_t = 0.0
		_since_step = 0.0
	_shown = true
	_show()
	_place_fog(0.0)
	_update_processing()


## CDDA's azimuth is measured from the south, positive toward the west (calendar.cpp). At night with the light
## pass on, a high moon-like light keeps the scene lit and the pass darkens it (no double darkening).
func aim_sun(alt_deg: float, az_deg: float) -> void:
	_sun_up = alt_deg > 0.0
	var night_lit := not _sun_up and light_pass
	_sun_base = 1.0 if _sun_up else (0.8 if night_lit else 0.15)
	if _sun == null:
		return
	var alt := deg_to_rad(45.0 if night_lit else maxf(alt_deg, 8.0))
	var az := deg_to_rad(az_deg)
	var to_sun := Vector3(-sin(az) * cos(alt), sin(alt), cos(az) * cos(alt))
	_sun.basis = Basis.looking_at(-to_sun, Vector3.FORWARD if absf(to_sun.y) > 0.99 else Vector3.UP)


## True while a change of weather is still blending in.
func blending() -> bool:
	return _blend_t < 1.0


func _process(delta: float) -> void:
	if _blend_t < 1.0:
		_blend_t = minf(1.0, _blend_t + delta / maxf(blend_s, 0.001))
		_since_step += delta
		if _since_step >= BLEND_STEP_S or _blend_t >= 1.0:
			_since_step = 0.0
			state = target if _blend_t >= 1.0 else WeatherState.blend(_from, target, smoothstep(0.0, 1.0, _blend_t))
			_show()
	_place_fog(delta)
	_update_processing()


func _update_processing() -> void:
	set_process(_blend_t < 1.0 or (_env != null and _env.fog_enabled))


static func _close(a: WeatherState, b: WeatherState) -> bool:
	return (absf(a.cloud - b.cloud) < BLEND_MIN and absf(a.gloom - b.gloom) < BLEND_MIN
			and absf(a.fog - b.fog) < BLEND_MIN and absf(a.daylight - b.daylight) < 2.0 * BLEND_MIN)


func _show() -> void:
	if _sky != null:
		var layer := state.cloud_layer()
		_set_sky(&"sky_top_color", state.sky_top())
		_set_sky(&"sky_horizon_color", state.sky_horizon())
		_set_sky(&"ground_horizon_color", state.sky_horizon())
		_set_sky(&"energy_multiplier", state.sky_energy())
		_set_sky(&"sky_cover_modulate", Color(layer, layer, layer))
	if _sun != null:
		var opacity := state.shadow_opacity()
		_sun.light_energy = _sun_base * state.sun_scale()
		_sun.shadow_opacity = opacity
		_sun.shadow_enabled = opacity > 0.05
		_sun.sky_mode = (DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY if _sun_up and state.sun_disc()
				else DirectionalLight3D.SKY_MODE_LIGHT_ONLY)
	if _env != null:
		_env.ambient_light_energy = AMBIENT_ENERGY * state.ambient_scale()
		_env.fog_enabled = state.fog > 0.01
		if _env.fog_enabled:
			var c := state.fog_color()
			if not light_pass:
				var night := lerpf(0.05, 1.0, state.daylight)
				c = Color(c.r * night, c.g * night, c.b * night)
			_env.fog_light_color = c
			_env.fog_density = state.fog   # depth mode: the most the distance fades
			_env.fog_sky_affect = state.fog


## Only real changes reach the sky material: every one makes the engine filter the sky's light again.
func _set_sky(property: StringName, value: Variant) -> void:
	if _sky.get(property) != value:
		_sky.set(property, value)
		sky_updates += 1


## The fade starts at the player (a few metres out when under a roof) and ends past CDDA's sight distance,
## wherever the camera is (an outside view looks down from far away and would otherwise see only fog).
func _place_fog(delta: float) -> void:
	if _env == null or not _env.fog_enabled:
		return
	_clear_m = move_toward(_clear_m, INDOOR_CLEAR_M if state.sheltered else 0.0,
			delta * INDOOR_CLEAR_M / INDOOR_CLEAR_S)
	var away := _clear_m
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		away += maxf(0.0, cam.global_position.distance_to(focus) - 1.0)
	var end := away + state.fog_end_m()
	if absf(_env.fog_depth_begin - away) > 0.05 or absf(_env.fog_depth_end - end) > 0.05:
		_env.fog_depth_begin = away
		_env.fog_depth_end = end


## The cloud layer for the sky's cover (equirectangular, L8), made once: soft noise shapes on a flat layer overhead
## as seen from below (large overhead, small and hazy toward the horizon, nothing below it; no seam and no pinch at
## the zenith). The sky adds it to its own colour, scaled by WeatherState.cloud_layer.
static func cover_image() -> Image:
	if _cover != null:
		return _cover
	var noise := FastNoiseLite.new()
	noise.seed = 20261112
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = CLOUD_SCALE
	var cos_az := PackedFloat32Array()
	var sin_az := PackedFloat32Array()
	for x in COVER_W:
		var az := TAU * (x + 0.5) / COVER_W
		cos_az.append(cos(az))
		sin_az.append(sin(az))
	var px := PackedByteArray()
	px.resize(COVER_W * COVER_H)   # zeros: the lower half stays empty
	var i := 0
	for y in COVER_H / 2:
		var v := (y + 0.5) / COVER_H   # 0 zenith, 0.5 horizon
		var up := PI * (0.5 - v)
		var reach := cos(up) / (sin(up) + CLOUD_HORIZON)   # how far out on the layer this row looks
		var haze := 1.0 - smoothstep(0.32, 0.47, v)
		for x in COVER_W:
			var n := 0.5 + 0.5 * noise.get_noise_2d(cos_az[x] * reach, sin_az[x] * reach)
			px[i] = roundi(255.0 * haze * smoothstep(0.4, 0.75, n))
			i += 1
	_cover = Image.create_from_data(COVER_W, COVER_H, false, Image.FORMAT_L8, px)
	return _cover
