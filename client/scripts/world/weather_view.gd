class_name WeatherView
extends Node
## Blocks C6 / I2: shows the weather on the sky, the sun and the distance (clouds, darker days, fog), and runs the
## rest of it: rain and snow (PrecipView), sound (WeatherSound), the lightning flash and the wet ground.
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
const FLASH_S := 0.5          # a lightning flash: two quick pulses
const FLASH_GAP_S := 0.3      # a second strike this soon is the same flash
const FLASH_LIGHT := 2.5      # energy of the flash's light at its peak
const FLASH_FOG := 3.0        # how much brighter the haze and the storm sky get
const FLASH_FLOOR := 0.55     # the light pass shows the dark world at least this bright at the peak
const FLASH_INDOORS := 0.5    # share of the flash that reaches under a roof
const NIGHT_FOG := 0.05       # share of the fog's colour left at night
const WET_IN_S := 120.0       # game seconds of heavy rain that soak the ground
const DRY_IN_S := 1800.0      # game seconds a soaked ground takes to dry
const WET_STEP := 0.02        # the ground's material changes only by steps this large
const COVER_W := 512
const COVER_H := 256
const CLOUD_SCALE := 2.2      # cloud shapes per unit of the layer (its height above the eye is 1)
const CLOUD_HORIZON := 0.2    # keeps the layer's far end finite at the horizon

var state := WeatherState.new()    # shown now
var target := WeatherState.new()   # the last snapshot's
var blend_s := BLEND_S             # 0: every change shows at once
var focus := Vector3.ZERO          # the player's eyes: the fog starts there, also for a camera further away
var light_pass := true             # WorldLighting darkens the scene by CDDA's light (the night's sun differs)
var sky_updates := 0               # times the sky was changed (each one costs a re-filter of its light)
var precip := PrecipView.new()     # rain and snow around the player
var sound := WeatherSound.new()    # rain, wind and thunder
var lighting: WorldLighting        # the light pass, for the lightning flash at night (may be null)
var flashes := 0                   # lightning flashes shown
var wet := 0.0                     # how wet the ground is, 0 dry .. 1 soaked
var _wet_shown := -1.0
var _wet_turn := -1                # the game turn `wet` is for, -1 none yet
var _flash_t := -1.0               # seconds into the flash, -1 none
var _flash_light := DirectionalLight3D.new()
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


func _init() -> void:
	add_child(precip)
	add_child(sound)
	_flash_light.light_color = Color(0.85, 0.9, 1.0)
	_flash_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	_flash_light.rotation_degrees = Vector3(-70.0, 30.0, 0.0)
	_flash_light.visible = false
	add_child(_flash_light)


func _ready() -> void:
	_update_processing()   # a node with _process starts processing on its own


func _exit_tree() -> void:
	if _wet_shown > 0.0:   # the ground's material is shared: leave it dry
		_wet_shown = -1.0
		TerrainMesher.wet_ground(0.0)


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
	var next := WeatherState.from_snapshot(snap)
	# The same weather as the last snapshot's (light and wind drift a little each turn): a blend toward it goes on.
	var same_goal := _shown and _close(target, next)
	target = next
	if not _shown or blend_s <= 0.0:
		_clear_m = INDOOR_CLEAR_M if target.sheltered else 0.0
	if not _shown or blend_s <= 0.0 or (_blend_t >= 1.0 and _close(state, target)):
		_blend_t = 1.0
		state = target
	elif _blend_t >= 1.0 or not same_goal:
		_from = state
		_blend_t = 0.0
		_since_step = 0.0
	_shown = true
	_show()
	_place_fog(0.0)
	_update_processing()
	precip.apply(snap, coords, target)
	sound.apply(target)
	_soak(snap.turn)


## The ground gets wet in rain and dries after it, in game time (waiting an hour dries it). A game that starts or
## loads in rain starts wet. Snow doesn't wet.
func _soak(turn: int) -> void:
	var rain := 0.0 if target.snow else target.precip
	if _wet_turn < 0 or turn < _wet_turn:
		wet = 1.0 if rain > 0.0 else 0.0
	elif rain > 0.0:
		wet = minf(1.0, wet + (turn - _wet_turn) * rain / WET_IN_S)
	else:
		wet = maxf(0.0, wet - (turn - _wet_turn) / DRY_IN_S)
	_wet_turn = turn
	if absf(wet - _wet_shown) >= WET_STEP or (wet != _wet_shown and (wet == 0.0 or wet == 1.0)):
		_wet_shown = wet
		TerrainMesher.wet_ground(wet)


## The game's events: a `lightning` event (the bridge sends one each time CDDA flashes) lights the scene for a
## moment and brings thunder. Anything else, junk included, is ignored.
func on_events(events: Array) -> void:
	for e: Variant in events:
		if e is Dictionary and (e as Dictionary).get("kind") is String and e["kind"] == "lightning":
			strike()
			return


## A lightning flash now, thunder a moment later.
func strike() -> void:
	if _flash_t >= 0.0 and _flash_t < FLASH_GAP_S:
		return
	flashes += 1
	_flash_t = 0.0
	sound.strike()
	_show_flash()
	_update_processing()


## How bright the flash is `t` seconds in (0..1): a pulse, a dip, a weaker second pulse, gone by FLASH_S.
static func flash_curve(t: float) -> float:
	if t < 0.0 or t >= FLASH_S:
		return 0.0
	var second := 0.75 * exp(-(t - 0.14) * 12.0) if t >= 0.14 else 0.0
	return maxf(exp(-t * 16.0), second) * minf((FLASH_S - t) * 10.0, 1.0)


func _show_flash() -> void:
	var f := flash_curve(_flash_t) * (FLASH_INDOORS if target.sheltered else 1.0)
	if target.depth > 0:
		f = 0.0   # underground
	_flash_light.visible = f > 0.0
	_flash_light.light_energy = FLASH_LIGHT * f
	if _env != null:
		_env.fog_light_energy = 1.0 + FLASH_FOG * f
	if lighting != null:
		lighting.flash = FLASH_FLOOR * f


## The bubble moved: every world position moves by `d` (CddaCoords.origin_shifted).
func shift(d: Vector3) -> void:
	focus += d
	precip.shift(d)


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
	if _flash_t >= 0.0:
		_flash_t += delta
		if _flash_t >= FLASH_S:
			_flash_t = -1.0
		_show_flash()
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
	set_process(_blend_t < 1.0 or _flash_t >= 0.0 or (_env != null and _env.fog_enabled))


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
			# Dark at night, with the light pass too: what is drawn after the pass (flames, sparks, markers) takes
			# the fog's own colour, and what is drawn before it is night-dark anyway.
			var c := state.fog_color()
			var night := lerpf(NIGHT_FOG, 1.0, state.daylight)
			_env.fog_light_color = Color(c.r * night, c.g * night, c.b * night)
			_env.fog_density = state.fog   # depth mode: the most the distance fades
			_env.fog_sky_affect = state.fog


## Only real changes reach the sky material: every one makes the engine filter the sky's light again.
func _set_sky(property: StringName, value: Variant) -> void:
	var now: Variant = _sky.get(property)   # the engine keeps 32-bit floats: compare loosely
	var same: bool = is_equal_approx(now, value) if value is float else (now as Color).is_equal_approx(value)
	if not same:
		_sky.set(property, value)
		sky_updates += 1


## The fade starts at the player (a few metres out when under a roof) and ends past CDDA's sight distance,
## wherever the camera is (an outside view looks down from far away and would otherwise see only fog).
func _place_fog(delta: float) -> void:
	if _env == null or not _env.fog_enabled:
		return
	_clear_m = move_toward(_clear_m, INDOOR_CLEAR_M if target.sheltered else 0.0,
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
