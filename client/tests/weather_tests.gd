extends RefCounted
## Blocks C6 / I2 checks, run by run_tests.gd: the env's weather fields (good, missing, bad), WeatherState's numbers
## for CDDA's weather types (clear, cloudy, rain, storm, fog, snow; day and night), the wind's direction, the cloud
## cover image, and WeatherView on a real Environment, sky and sun (fog placed for the camera, blending, no work
## when nothing changes). Headless can't render: how it looks is checked on screen.

var _check: Callable

# CDDA's values (data/json/weather_type.json): [precip, precip_kind, sight penalty, light modifier, sun multiplier]
const CLEAR := [0, 0, 1.0, 0, 1.0]
const CLOUDY := [0, 0, 1.0, -20, 0.3]
const DRIZZLE := [1, 1, 1.01, -10, 0.2]
const RAIN := [3, 1, 1.1, -30, 0.03]
const LIGHTNING := [3, 1, 1.25, -45, 0.01]
const FLURRIES := [2, 2, 1.12, -15, 0.3]
const FOG := [0, 0, 1.7, -40, 0.3]


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	print("weather")
	_test_parse()
	_test_state()
	_test_wind()
	_test_cover()
	_test_view(root)
	_test_blend(root)
	_test_mock(data)


## The env fields of a CDDA weather, by day unless `ambient` says otherwise.
func _env(w: Array, ambient := 100, sun_alt := 45.0) -> Dictionary:
	return {"sun_alt_deg": sun_alt, "sun_az_deg": 0.0, "ambient_light": ambient, "weather": 3,
			"precip": w[0], "precip_kind": w[1], "sight_penalty": w[2], "light_modifier": w[3],
			"sun_multiplier": w[4]}


## The smallest snapshot with this env.
func _snap(env: Variant) -> Snapshot:
	var d := {"contract_version": 0, "turn": 1, "seq": 1, "bubble_origin": [0, 0, 0], "submaps": []}
	if env != null:
		d["env"] = env
	return Snapshot.from_data(d)


func _state(w: Array, ambient := 100, sun_alt := 45.0) -> WeatherState:
	return WeatherState.from_snapshot(_snap(_env(w, ambient, sun_alt)))


func _test_parse() -> void:
	var none := _snap(null)
	_check.call(none.is_valid(), "weather: a snapshot without env is valid (%s)" % none.error)
	var s := WeatherState.from_snapshot(none)
	_check.call(s.cloud == 0.0 and s.gloom == 0.0 and s.fog == 0.0 and s.precip == 0.0 and not s.snow
			and not s.sheltered and s.wind == Vector3.ZERO and s.wind_here == Vector3.ZERO,
			"weather: no weather fields read as clear, still weather")
	var rain := _snap(_env(RAIN))
	_check.call(rain.is_valid() and rain.weather == 3 and rain.weather_precip == 3
			and rain.weather_kind == Snapshot.PRECIP_RAIN and is_equal_approx(rain.weather_sight, 1.1)
			and rain.weather_light == -30.0 and is_equal_approx(rain.weather_sun, 0.03) and not rain.weather_sheltered,
			"weather: the fields are read (%s)" % rain.error)
	var roofed := 0
	for yes: Variant in [true, 1, 1.0]:
		var e := _env(RAIN)
		e["sheltered"] = yes
		roofed += int(_snap(e).weather_sheltered)
	_check.call(roofed == 3, "weather: sheltered reads as true or 1")
	var bad := {"precip": 4, "precip_kind": 3, "sight_penalty": NAN, "light_modifier": INF, "sun_multiplier": -0.5,
			"sheltered": [1], "wind_speed": -1.0, "wind_dir_deg": 400.0, "wind_at_player": "calm", "weather": -1}
	var refused := 0
	for key: String in bad:
		var e := _env(RAIN)
		e[key] = bad[key]
		refused += int(not _snap(e).is_valid())
	_check.call(refused == bad.size(), "weather: each bad field fails the snapshot (%d of %d)" % [refused, bad.size()])
	# A mod's weather may go beyond CDDA's own numbers: read, then clamped to what can be shown.
	var wild := WeatherState.from_snapshot(_snap(_env([3, 1, 50.0, 300, 7.5])))
	_check.call(wild.cloud == 0.0 and wild.gloom == 0.0 and wild.fog == 1.0 and wild.sight_m > 1.0,
			"weather: a mod's larger numbers are read and clamped")
	var dark := WeatherState.from_snapshot(_snap(_env([0, 0, 0.2, -900, 0.0])))
	_check.call(dark.cloud == 1.0 and dark.gloom == 1.0 and dark.fog == 0.0
			and dark.sight_m == WeatherState.SIGHT_CLEAR_M, "weather: sight never beyond clear air, gloom at most full")


func _test_state() -> void:
	var clear := _state(CLEAR)
	var cloudy := _state(CLOUDY)
	var drizzle := _state(DRIZZLE)
	var rain := _state(RAIN)
	var storm := _state(LIGHTNING)
	var snow := _state(FLURRIES)
	var fog := _state(FOG)
	_check.call(clear.sun_scale() == 1.0 and clear.sky_energy() == 1.0 and clear.ambient_scale() == 1.0
			and clear.shadow_opacity() == 1.0 and clear.sun_disc() and clear.cloud_layer() == 0.0
			and clear.sky_top() == WeatherState.CLEAR_TOP, "weather: clear leaves the sky and the sun as they were")
	_check.call(cloudy.sun_scale() < 0.6 and rain.sun_scale() < cloudy.sun_scale()
			and storm.sun_scale() <= rain.sun_scale() and storm.sun_scale() >= WeatherState.SUN_SHADED - 0.001,
			"weather: the sun dims with the cover (%.2f, %.2f, %.2f)" % [cloudy.sun_scale(), rain.sun_scale(),
			storm.sun_scale()])
	_check.call(cloudy.sky_energy() < 1.0 and rain.sky_energy() < cloudy.sky_energy()
			and storm.sky_energy() < rain.sky_energy() and is_equal_approx(storm.sky_energy(), WeatherState.SKY_GLOOMY),
			"weather: the sky darkens with CDDA's light modifier (%.2f, %.2f, %.2f)" % [cloudy.sky_energy(),
			rain.sky_energy(), storm.sky_energy()])
	_check.call(not cloudy.sun_disc() and cloudy.shadow_opacity() > 0.3 and cloudy.shadow_opacity() < 0.9
			and rain.shadow_opacity() == 0.0, "weather: clouds hide the sun's disc and soften its shadows, rain has none")
	_check.call(cloudy.cloud_layer() > 0.3 and storm.cloud_layer() < 0.15 and storm.cloud_layer() > 0.0
			and storm.sky_top().is_equal_approx(WeatherState.OVERCAST_TOP),
			"weather: separate clouds at part cover, a grey sky with faint shapes under full cover")
	_check.call(clear.fog == 0.0 and drizzle.fog < 0.1 and rain.fog > 0.3 and rain.fog < 0.5 and fog.fog == 1.0
			and is_equal_approx(fog.sight_m, 60.0 / 1.7) and is_equal_approx(fog.fog_end_m(), 72.0 / 1.7),
			"weather: the distance fades by CDDA's sight penalty (fog ends at %.1f m)" % fog.fog_end_m())
	_check.call(fog.fog_color().get_luminance() > rain.fog_color().get_luminance() * 0.9
			and fog.fog_color().get_luminance() < 0.8, "weather: fog is pale, not white")
	_check.call(is_equal_approx(drizzle.precip, 1.0 / 3.0) and rain.precip == 1.0 and not rain.snow
			and is_equal_approx(snow.precip, 2.0 / 3.0) and snow.snow and not clear.snow and clear.precip == 0.0,
			"weather: precipitation's strength, and snow when it doesn't rain")
	# Night: CDDA's natural light already carries the weather, so nothing is dimmed twice.
	var night := _state(LIGHTNING, 2, -30.0)
	_check.call(night.daylight == 0.0 and night.sun_scale() == 1.0 and night.sky_energy() == 1.0
			and night.ambient_scale() == 1.0, "weather: at night the light pass alone darkens")
	var dusk := _state(LIGHTNING, 40, 2.0)
	_check.call(dusk.sun_scale() > storm.sun_scale() and dusk.sun_scale() < 1.0, "weather: dusk is in between")
	var mid := WeatherState.blend(clear, storm, 0.5)
	_check.call(is_equal_approx(mid.cloud, storm.cloud / 2.0) and is_equal_approx(mid.gloom, 0.5)
			and WeatherState.blend(clear, storm, 1.0).same_look(storm) and not mid.same_look(storm),
			"weather: states blend")


func _test_wind() -> void:
	var north := WeatherState.wind_vector(5.0, 0.0)
	var east := WeatherState.wind_vector(5.0, 90.0)
	_check.call(north.is_equal_approx(Vector3(0, 0, 5)) and east.is_equal_approx(Vector3(-5, 0, 0)),
			"weather: a north wind blows south (+z), an east wind west (-x)")
	_check.call(WeatherState.wind_vector(1e9, 0.0).length() == WeatherState.WIND_MAX
			and WeatherState.wind_vector(NAN, 0.0) == Vector3.ZERO and WeatherState.wind_vector(3.0, INF) == Vector3.ZERO
			and WeatherState.wind_vector(-4.0, 0.0) == Vector3.ZERO, "weather: wind is capped, junk is calm")
	var e := _env(RAIN)
	e["wind_speed"] = 4.0
	e["wind_dir_deg"] = 180.0
	var open := WeatherState.from_snapshot(_snap(e))
	_check.call(open.wind.is_equal_approx(Vector3(0, 0, -4)) and open.wind_here.is_equal_approx(open.wind),
			"weather: the snapshot's wind (from the south, blowing north), the same at the player when not sent")
	e["wind_at_player"] = 0.0
	var inside := WeatherState.from_snapshot(_snap(e))
	e["wind_at_player"] = 1.5
	var lee := WeatherState.from_snapshot(_snap(e))
	_check.call(inside.wind_here == Vector3.ZERO and lee.wind_here.is_equal_approx(Vector3(0, 0, -1.5))
			and lee.wind.is_equal_approx(Vector3(0, 0, -4)), "weather: calm indoors, weaker behind cover")
	# Precipitation needs a kind: a strength alone shows nothing.
	var odd := WeatherState.from_snapshot(_snap(_env([3, 0, 1.0, 0, 1.0])))
	_check.call(odd.precip == 0.0 and not odd.snow, "weather: a strength without a kind is no precipitation")


func _test_cover() -> void:
	var t0 := Time.get_ticks_usec()
	var img := WeatherView.cover_image()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check.call(img.get_width() == WeatherView.COVER_W and img.get_height() == WeatherView.COVER_H
			and img.get_format() == Image.FORMAT_L8, "weather: the cloud cover image (%d x %d, made in %.0f ms)" %
			[img.get_width(), img.get_height(), ms])
	_check.call(is_same(img, WeatherView.cover_image()), "weather: made once")
	var px := img.get_data()
	var w := WeatherView.COVER_W
	var below := 0
	for i in range(w * (WeatherView.COVER_H / 2), px.size()):
		below = maxi(below, px[i])
	var top := px.slice(0, w)
	var mid := px.slice(w * 70, w * 71)   # about 40 degrees above the horizon
	var top_lo := 255
	var top_hi := 0
	for b in top:
		top_lo = mini(top_lo, b)
		top_hi = maxi(top_hi, b)
	var mid_lo := 255
	var mid_hi := 0
	for b in mid:
		mid_lo = mini(mid_lo, b)
		mid_hi = maxi(mid_hi, b)
	_check.call(below == 0, "weather: no clouds below the horizon")
	_check.call(top_hi - top_lo <= 64, "weather: no pinch at the zenith (%d..%d around it)" % [top_lo, top_hi])
	_check.call(mid_hi - mid_lo > 150, "weather: clouds and gaps in between (%d..%d)" % [mid_lo, mid_hi])
	_check.call(absi(mid[0] - mid[w - 1]) < 40, "weather: the cover wraps around (%d, %d)" %
			[mid[0], mid[w - 1]])


## An Environment with a procedural sky and a sun, as main.gd builds them.
func _scene(root: Node) -> Array:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	root.add_child(sun)
	var view := WeatherView.new()
	root.add_child(view)
	view.setup(env, sun)
	return [view, env, sun]


func _test_view(root: Node) -> void:
	var made := _scene(root)
	var view: WeatherView = made[0]
	var env: Environment = made[1]
	var sun: DirectionalLight3D = made[2]
	var sky := env.sky.sky_material as ProceduralSkyMaterial
	view.blend_s = 0.0
	var coords := CddaCoords.new()
	_check.call(sky.sky_cover != null and sky.sky_cover_modulate == Color.BLACK and not env.fog_enabled
			and not view.is_processing(), "weather: set up clear: a cover that adds nothing, no fog, no work")
	view.apply(_snap(_env(CLEAR)), coords, true)
	_check.call(not env.fog_enabled and sun.light_energy == 1.0 and sun.shadow_enabled and sun.shadow_opacity == 1.0
			and sun.sky_mode == DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY and is_equal_approx(env.ambient_light_energy, 0.8)
			and sky.energy_multiplier == 1.0 and not view.is_processing(), "weather: a clear day")
	var updates := view.sky_updates
	view.apply(_snap(_env(CLEAR)), coords, true)
	_check.call(view.sky_updates == updates, "weather: the same weather again leaves the sky alone")
	view.apply(_snap(_env(CLOUDY)), coords, true)
	_check.call(sun.light_energy < 0.6 and sun.shadow_enabled and sun.shadow_opacity < 0.9
			and sun.sky_mode == DirectionalLight3D.SKY_MODE_LIGHT_ONLY and sky.sky_cover_modulate.r > 0.3
			and sky.energy_multiplier < 1.0 and not env.fog_enabled and view.sky_updates > updates,
			"weather: a cloudy day: dimmer sun without a disc, softer shadows, clouds")
	view.apply(_snap(_env(RAIN)), coords, true)
	_check.call(not sun.shadow_enabled and sun.light_energy < 0.3 and env.ambient_light_energy < 0.8
			and env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH and env.fog_density > 0.3
			and env.fog_density < 0.5 and sky.sky_top_color.is_equal_approx(WeatherState.OVERCAST_TOP),
			"weather: rain: no sun shadows, grey sky, a haze in the distance")
	# Fog: the fade starts at the player's eyes and ends past CDDA's sight distance.
	var fog_snap := _snap(_env(FOG))
	view.apply(fog_snap, coords, true)
	var eyes := coords.ms_center_to_world(fog_snap.player_pos) + Vector3(0, WeatherView.EYE_M, 0)
	_check.call(env.fog_enabled and env.fog_density == 1.0 and env.fog_sky_affect == 1.0
			and is_equal_approx(env.fog_depth_begin, 0.0) and absf(env.fog_depth_end - 72.0 / 1.7) < 0.01
			and view.focus.is_equal_approx(eyes) and view.is_processing(),
			"weather: fog fades everything by %.1f m from the eyes" % env.fog_depth_end)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = eyes + Vector3(0, 30, 0)
	cam.make_current()
	view._process(0.016)
	_check.call(absf(env.fog_depth_begin - 29.0) < 0.01 and absf(env.fog_depth_end - 29.0 - 72.0 / 1.7) < 0.01,
			"weather: a camera 30 m away sees the same fog around the player (%.1f..%.1f m)" %
			[env.fog_depth_begin, env.fog_depth_end])
	cam.global_position = eyes
	view._process(0.016)
	_check.call(is_equal_approx(env.fog_depth_begin, 0.0), "weather: and it follows the camera back")
	root.remove_child(cam)
	cam.free()
	var roofed := _env(FOG)
	roofed["sheltered"] = true
	view.apply(_snap(roofed), coords, true)
	_check.call(is_equal_approx(env.fog_depth_begin, WeatherView.INDOOR_CLEAR_M)
			and absf(env.fog_depth_end - WeatherView.INDOOR_CLEAR_M - 72.0 / 1.7) < 0.01,
			"weather: under a roof the fog starts %.0f m out (the room stays clear)" % env.fog_depth_begin)
	view.apply(fog_snap, coords, true)
	_check.call(is_equal_approx(env.fog_depth_begin, 0.0), "weather: and at the eyes again outside")
	# With blending on, walking under a roof moves the fog out over a moment, not in one frame.
	view.blend_s = WeatherView.BLEND_S
	view.apply(_snap(roofed), coords, true)
	view._process(0.3)
	var part := env.fog_depth_begin
	view._process(2.0)
	_check.call(part > 0.5 and part < WeatherView.INDOOR_CLEAR_M - 0.5
			and is_equal_approx(env.fog_depth_begin, WeatherView.INDOOR_CLEAR_M),
			"weather: going indoors clears the room over %.1f s (%.1f m after 0.3 s)" %
			[WeatherView.INDOOR_CLEAR_S, part])
	view.blend_s = 0.0
	view.apply(fog_snap, coords, true)
	var day_fog := env.fog_light_color
	# Night: the light pass darkens (a moon-like light at 0.8), the weather doesn't dim it again.
	view.apply(_snap(_env(LIGHTNING, 2, -30.0)), coords, true)
	_check.call(is_equal_approx(sun.light_energy, 0.8) and sun.sky_mode == DirectionalLight3D.SKY_MODE_LIGHT_ONLY
			and sky.energy_multiplier == 1.0, "weather: a stormy night is darkened by the light pass only")
	view.apply(_snap(_env(FOG, 2, -30.0)), coords, false)
	_check.call(is_equal_approx(sun.light_energy, 0.15) and env.fog_light_color.get_luminance()
			< day_fog.get_luminance() * 0.2, "weather: without the light pass the night's sun and fog are dark")
	view.apply(_snap(_env(CLEAR)), coords, true)
	_check.call(not env.fog_enabled and sun.light_energy == 1.0 and sun.shadow_enabled
			and sky.sky_cover_modulate == Color.BLACK and not view.is_processing(), "weather: and clear again")
	# Parts may be missing (a scene without a sky, or only a sun).
	var bare := WeatherView.new()
	root.add_child(bare)
	bare.blend_s = 0.0
	bare.setup(Environment.new(), null)
	bare.apply(_snap(_env(FOG)), null, true)
	bare.setup(null, null)
	bare.apply(_snap(_env(RAIN)), coords, true)
	_check.call(bare.target.precip == 1.0, "weather: works without a sky, a sun or an environment")
	for n: Node in [bare, view, sun]:
		root.remove_child(n)
		n.free()


func _test_blend(root: Node) -> void:
	var made := _scene(root)
	var view: WeatherView = made[0]
	var env: Environment = made[1]
	var sun: DirectionalLight3D = made[2]
	var coords := CddaCoords.new()
	view.apply(_snap(_env(CLEAR)), coords, true)
	_check.call(not view.blending() and sun.light_energy == 1.0, "weather: the first weather shows at once")
	view.apply(_snap(_env(CLOUDY)), coords, true)
	_check.call(view.blending() and view.is_processing() and sun.light_energy == 1.0 and view.target.cloud > 0.6,
			"weather: a change starts blending")
	var updates := view.sky_updates
	for i in 6:
		view._process(0.05)
	var early := sun.light_energy
	_check.call(early < 1.0 and early > view.target.sun_scale() and view.blending(),
			"weather: part of the way after 0.3 s (sun at %.2f)" % early)
	_check.call(view.sky_updates - updates <= 5, "weather: in steps, not every frame (%d sky changes in 6 frames)" %
			(view.sky_updates - updates))
	for i in 70:
		view._process(0.05)
	_check.call(not view.blending() and is_equal_approx(sun.light_energy, view.target.sun_scale())
			and view.state.same_look(view.target) and not view.is_processing(),
			"weather: there after %.0f s, then no more work" % WeatherView.BLEND_S)
	# A new weather halfway starts from what is shown.
	view.apply(_snap(_env(LIGHTNING)), coords, true)
	for i in 20:
		view._process(0.05)
	var half := sun.light_energy
	view.apply(_snap(_env(CLEAR)), coords, true)
	_check.call(is_equal_approx(sun.light_energy, half) and view.blending(), "weather: a change midway starts from there")
	for i in 80:
		view._process(0.05)
	_check.call(sun.light_energy == 1.0 and not env.fog_enabled and not view.is_processing(), "weather: and ends clear")
	# Dusk getting darker turn by turn is no weather change: at once.
	updates = view.sky_updates
	view.apply(_snap(_env(CLOUDY, 100)), coords, true)
	for i in 80:
		view._process(0.05)
	view.apply(_snap(_env(CLOUDY, 57)), coords, true)
	_check.call(not view.blending() and view.state.same_look(view.target), "weather: a small change shows at once")
	for n: Node in [view, sun]:
		root.remove_child(n)
		n.free()


## The mock town: an old snapshot without the weather fields, with CDDA's wind.
func _test_mock(data: Variant) -> void:
	var env: Dictionary = (data as Dictionary)["env"]
	var s := WeatherState.from_snapshot(_snap(env))
	_check.call(s.cloud == 0.0 and s.fog == 0.0 and s.precip == 0.0 and s.daylight == 1.0,
			"weather: the mock town's day is clear")
	_check.call(s.wind.is_equal_approx(Vector3(0, 0, -float(env["wind_speed"]))), "weather: its south wind (%.1f m/s)" %
			s.wind.length())
