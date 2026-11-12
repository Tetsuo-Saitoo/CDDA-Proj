extends RefCounted
## Blocks C6 / I2 checks, run by run_tests.gd: the lightning flash (the bridge's `lightning` event, junk events,
## the flash's curve, what it lights and that it ends), thunder after it, and the weather's sound (the four noise
## clips, what is heard outdoors, under a roof, in snow and in wind, the glides, and that nothing runs in still,
## dry weather), and the wet ground (open-sky terrain and roofs have their own material; it soaks in rain and dries
## in game time). Headless can't render or be heard: how it looks and sounds is checked on screen.

var _check: Callable

# [precip, precip_kind, sight penalty, light modifier, sun multiplier, weather_sound] (weather_tests.gd)
const CLEAR := [0, 0, 1.0, 0, 1.0, 9]
const RAIN := [3, 1, 1.1, -30, 0.03, 2]
const DRIZZLE := [1, 1, 1.01, -10, 0.2, 1]
const STORM := [3, 1, 1.25, -45, 0.01, 4]
const SNOWING := [3, 2, 1.3, -20, 0.15, 7]


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("storms and weather sound")
	_test_flash(root)
	_test_clips()
	_test_sound(root)
	_test_wet_mesh(root, data, tables)
	_test_soak(root)


func _snap(w: Array, sheltered := false, wind := 0.0, wind_here := -1.0, turn := 1) -> Snapshot:
	var env := {"sun_alt_deg": 45.0, "sun_az_deg": 0.0, "ambient_light": 100, "precip": w[0], "precip_kind": w[1],
			"sight_penalty": w[2], "light_modifier": w[3], "sun_multiplier": w[4], "weather_sound": w[5],
			"sheltered": sheltered, "wind_speed": wind, "wind_dir_deg": 0.0}
	if wind_here >= 0.0:
		env["wind_at_player"] = wind_here
	return Snapshot.from_data({"contract_version": 0, "turn": turn, "seq": 1, "bubble_origin": [0, 0, 0],
			"submaps": [], "env": env})


func _state(w: Array, sheltered := false, wind := 0.0, wind_here := -1.0) -> WeatherState:
	return WeatherState.from_snapshot(_snap(w, sheltered, wind, wind_here))


func _test_flash(root: Node) -> void:
	_check.call(_state(STORM).thunder and not _state(RAIN).thunder and not _state(CLEAR).thunder,
			"storm: a thunderstorm is CDDA's thunder sound category")
	var odd := _snap(STORM)
	_check.call(odd.is_valid() and odd.weather_sound == Snapshot.WEATHER_SOUND_THUNDER, "storm: weather_sound is read")
	var c := WeatherView.flash_curve
	_check.call(c.call(0.0) == 1.0 and c.call(0.1) < 0.3 and c.call(0.15) > 0.6 and c.call(0.15) < 0.8
			and c.call(0.45) < 0.05 and c.call(WeatherView.FLASH_S) == 0.0 and c.call(-1.0) == 0.0 and c.call(9.0) == 0.0,
			"storm: a flash is two quick pulses, over in %.1f s" % WeatherView.FLASH_S)
	var env := Environment.new()
	var lighting := WorldLighting.new()
	root.add_child(lighting)
	lighting.flash = 7.0
	_check.call(lighting.flash == 1.0 and lighting.get("_mat").get_shader_parameter("flash") == 1.0,
			"storm: the light pass takes a flash level, at most 1")
	lighting.flash = 0.0
	var view := WeatherView.new()
	root.add_child(view)
	view.blend_s = 0.0
	view.lighting = lighting
	view.setup(env, null)
	view.apply(_snap(CLEAR), null, true)
	var light: DirectionalLight3D = view.get("_flash_light")
	_check.call(not light.visible and not light.shadow_enabled and view.flashes == 0 and not view.is_processing(),
			"storm: no flash, no work in clear weather")
	view.on_events([1, "lightning", null, {"kind": 5}, {"kind": "sound"}, {"type": "lightning"}, []])
	_check.call(view.flashes == 0 and not light.visible, "storm: other events and junk do nothing")
	view.on_events([{"kind": "sound"}, {"kind": "lightning", "pos": [1, 2, 0]}, {"kind": "lightning"}])
	_check.call(view.flashes == 1 and light.visible and is_equal_approx(light.light_energy, WeatherView.FLASH_LIGHT)
			and is_equal_approx(lighting.flash, WeatherView.FLASH_FLOOR)
			and is_equal_approx(env.fog_light_energy, 1.0 + WeatherView.FLASH_FOG) and view.is_processing(),
			"storm: a lightning event lights the scene, the haze and the dark at once")
	view.strike()
	_check.call(view.flashes == 1, "storm: a second strike right away is the same flash")
	view._process(0.1)
	var dip := light.light_energy
	view._process(0.05)
	_check.call(dip < 0.3 * WeatherView.FLASH_LIGHT and light.light_energy > dip and lighting.flash > 0.3,
			"storm: it flickers (down to %.2f, up to %.2f)" % [dip, light.light_energy])
	view._process(0.2)
	view.strike()
	_check.call(view.flashes == 2 and is_equal_approx(light.light_energy, WeatherView.FLASH_LIGHT),
			"storm: a strike %.2f s later is a new flash" % 0.35)
	for i in 12:
		view._process(0.05)
	_check.call(not light.visible and lighting.flash == 0.0 and is_equal_approx(env.fog_light_energy, 1.0)
			and not view.is_processing(), "storm: then everything is as before, and no more work")
	# Under a roof the flash is weaker.
	view.apply(_snap(STORM, true), null, true)
	view.strike()
	_check.call(is_equal_approx(light.light_energy, WeatherView.FLASH_LIGHT * WeatherView.FLASH_INDOORS)
			and is_equal_approx(lighting.flash, WeatherView.FLASH_FLOOR * WeatherView.FLASH_INDOORS),
			"storm: half the flash reaches under a roof")
	# Without a light pass or an environment it still works.
	var bare := WeatherView.new()
	root.add_child(bare)
	bare.strike()
	bare._process(1.0)
	_check.call(bare.flashes == 1 and not (bare.get("_flash_light") as DirectionalLight3D).visible,
			"storm: works without a light pass or an environment")
	for n: Node in [bare, view, lighting]:
		root.remove_child(n)
		n.free()


## Loudness (root mean square, 0..1) and how often the wave crosses zero per second (brightness).
func _measure(data: PackedByteArray) -> Vector3:
	var n := data.size() / 2
	var sum := 0.0
	var peak := 0
	var crossings := 0
	var last := 0
	for i in n:
		var v := data.decode_s16(i * 2)
		sum += float(v) * v
		peak = maxi(peak, absi(v))
		crossings += int((v >= 0) != (last >= 0))
		last = v
	return Vector3(sqrt(sum / n) / 32768.0, peak / 32768.0, crossings * WeatherSound.RATE / float(n))


func _test_clips() -> void:
	var t0 := Time.get_ticks_usec()
	var rain := WeatherSound.clip("rain")
	var roof := WeatherSound.clip("roof")
	var wind := WeatherSound.clip("wind")
	var thunder := WeatherSound.clip("thunder")
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check.call(rain.size() == int(WeatherSound.RATE * WeatherSound.RAIN_S) * 2 and roof.size() == rain.size()
			and wind.size() == int(WeatherSound.RATE * WeatherSound.WIND_S) * 2
			and thunder.size() == int(WeatherSound.RATE * WeatherSound.THUNDER_S) * 2,
			"sound: four clips of noise, %.1f s in all (made in %.0f ms, on a worker in the game)" %
			[2.0 * WeatherSound.RAIN_S + WeatherSound.WIND_S + WeatherSound.THUNDER_S, ms])
	var m_rain := _measure(rain)
	var m_roof := _measure(roof)
	var m_wind := _measure(wind)
	var m_thunder := _measure(thunder)
	var quiet := 0
	var clipped := 0
	for m: Vector3 in [m_rain, m_roof, m_wind, m_thunder]:
		quiet += int(m.x < 0.05)
		clipped += int(m.y > 0.99)
	_check.call(quiet == 0 and clipped == 0, "sound: each clip is audible and none clips (loudness %.2f %.2f %.2f %.2f)" %
			[m_rain.x, m_roof.x, m_wind.x, m_thunder.x])
	_check.call(m_rain.z > 2500.0 and m_roof.z < m_rain.z / 3.0 and m_wind.z < m_roof.z and m_thunder.z < m_rain.z / 3.0,
			"sound: rain hisses, the roof patter is duller, wind and thunder are low (%.0f, %.0f, %.0f, %.0f crossings/s)"
			% [m_rain.z, m_roof.z, m_wind.z, m_thunder.z])
	# Thunder: a crack, then a rumble that fades to nothing.
	var half := WeatherSound.RATE / 2 * 2   # bytes in half a second, whole samples
	var head := _measure(thunder.slice(0, half))
	var tail := _measure(thunder.slice(thunder.size() - half))
	_check.call(head.x > 4.0 * tail.x and absi(thunder.decode_s16(thunder.size() - 2)) < 400,
			"sound: thunder cracks and fades out (%.2f, then %.3f)" % [head.x, tail.x])
	_check.call(WeatherSound.clip("rain") == rain, "sound: the same clip every time")
	_check.call(WeatherSound.ready_now(true) and WeatherSound.stream("rain").loop_mode == AudioStreamWAV.LOOP_FORWARD
			and WeatherSound.stream("rain").loop_end == rain.size() / 2
			and WeatherSound.stream("wind").loop_mode == AudioStreamWAV.LOOP_FORWARD
			and WeatherSound.stream("thunder").loop_mode == AudioStreamWAV.LOOP_DISABLED
			and WeatherSound.stream("thunder").mix_rate == WeatherSound.RATE and WeatherSound.stream("nope") == null,
			"sound: rain, roof and wind loop, thunder plays once")


func _test_sound(root: Node) -> void:
	var s := WeatherSound.new()
	root.add_child(s)
	_check.call(not s.busy() and not s.is_processing() and not s.rain.playing, "sound: silent and idle to begin with")
	s.apply(_state(RAIN))
	_check.call(is_equal_approx(s.targets[s.rain], WeatherSound.RAIN_GAIN) and s.targets[s.roof] == 0.0
			and s.targets[s.wind] == 0.0 and s.is_processing(), "sound: heavy rain in the open is the hiss alone")
	s.tick(0.1)
	var early := db_to_linear(s.rain.volume_db)
	for i in 10:
		s.tick(0.1)
	_check.call(s.rain.playing and early > 0.05 and early < 0.2
			and is_equal_approx(db_to_linear(s.rain.volume_db), WeatherSound.RAIN_GAIN) and not s.roof.playing,
			"sound: it glides in (%.2f after 0.1 s, then %.2f)" % [early, db_to_linear(s.rain.volume_db)])
	s.apply(_state(RAIN, true))
	for i in 10:
		s.tick(0.1)
	_check.call(s.roof.playing and is_equal_approx(db_to_linear(s.roof.volume_db), WeatherSound.ROOF_GAIN)
			and is_equal_approx(db_to_linear(s.rain.volume_db), WeatherSound.RAIN_GAIN * WeatherSound.INDOOR_RAIN),
			"sound: under a roof the hiss is faint and the patter on the roof joins it")
	s.apply(_state(DRIZZLE))
	_check.call(is_equal_approx(s.targets[s.rain], WeatherSound.RAIN_GAIN / 9.0), "sound: a drizzle is much quieter")
	s.apply(_state(SNOWING, false, 8.0))
	_check.call(s.targets[s.rain] == 0.0 and s.targets[s.roof] == 0.0
			and is_equal_approx(s.targets[s.wind], WeatherSound.WIND_GAIN * 8.0 / WeatherSound.WIND_FULL),
			"sound: snow is silent; the wind is heard by its speed")
	s.apply(_state(CLEAR, true, 8.0, 0.0))
	_check.call(is_equal_approx(s.targets[s.wind], WeatherSound.WIND_GAIN * 8.0 * WeatherSound.INDOOR_WIND / WeatherSound.WIND_FULL),
			"sound: indoors a little of the wind outside is left")
	s.apply(_state(CLEAR, false, 99.0))
	_check.call(s.targets[s.wind] <= WeatherSound.WIND_GAIN, "sound: a gale is as loud as it gets")
	s.apply(_state(CLEAR))
	for i in 12:
		s.tick(0.1)
	_check.call(not s.rain.playing and not s.roof.playing and not s.wind.playing and not s.busy() and not s.is_processing(),
			"sound: clear and calm: everything fades out and stops, no more work")
	# Thunder follows a strike; a thunderstorm rumbles now and then.
	s.strike()
	_check.call(s.busy() and s.is_processing() and not s.thunder.playing, "sound: thunder doesn't come with the flash")
	for i in 40:
		s.tick(0.1)
	_check.call(s.thunder.stream == WeatherSound.stream("thunder") and s.thunder.pitch_scale == 1.0
			and db_to_linear(s.thunder.volume_db) > 0.8 and not s.busy(), "sound: but within %.1f s" % 3.0)
	s.apply(_state(STORM))
	_check.call(s.get("_rumble_in") >= WeatherSound.RUMBLE_EVERY.x and s.get("_rumble_in") <= WeatherSound.RUMBLE_EVERY.y,
			"sound: a thunderstorm has a far rumble coming (in %.0f s)" % s.get("_rumble_in"))
	for i in 75:
		s.tick(1.0)
	_check.call(s.thunder.pitch_scale < 1.0 and is_equal_approx(db_to_linear(s.thunder.volume_db), WeatherSound.FAR_GAIN)
			and s.get("_rumble_in") > 0.0, "sound: it comes, lower and quieter, and the next is due")
	s.apply(_state(CLEAR))
	_check.call(s.get("_rumble_in") < 0.0, "sound: no rumbles once the storm is over")
	root.remove_child(s)
	s.free()
	# WeatherView runs it.
	var view := WeatherView.new()
	root.add_child(view)
	view.blend_s = 0.0
	view.apply(_snap(RAIN), null, true)
	_check.call(is_equal_approx(view.sound.targets[view.sound.rain], WeatherSound.RAIN_GAIN), "sound: WeatherView sets it")
	view.strike()
	_check.call(view.sound.get("_thunder_in") > 0.0, "sound: and a flash brings thunder")
	root.remove_child(view)
	view.free()


func _materials(mesh: ArrayMesh) -> Array:
	var out := []
	for i in mesh.get_surface_count():
		out.append(mesh.surface_get_material(i))
	return out


## The mock town: the player's submap is open ground; the one to its north-west holds part of a roofed building.
func _test_wet_mesh(root: Node, data: Variant, tables: IdTables) -> void:
	var pos: Array = data["player"]["pos"]
	var open_sm := Vector3i(int(pos[0]) / 12, int(pos[1]) / 12, 0)
	var mixed_sm := open_sm + Vector3i(-1, -1, 0)
	var d: Dictionary = (data as Dictionary).duplicate(false)
	var keep := []
	for s: Dictionary in data["submaps"]:
		if absi(int(s["pos"][0]) - open_sm.x) <= 2 and absi(int(s["pos"][1]) - open_sm.y) <= 2 and int(s["pos"][2]) == 0:
			keep.append(s)
	d["submaps"] = keep
	var snap := Snapshot.from_data(d)
	var w := WorldView.new()
	w.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(w)
	w.set_id_tables(tables)
	var ground := TerrainMesher.material(TerrainMesher.GROUND)
	var solid := TerrainMesher.material("solid")
	_check.call(snap.is_valid() and ground != solid and is_same(ground, TerrainMesher.material(TerrainMesher.GROUND)),
			"wet: the ground has a material of its own (%s)" % snap.error)
	var open := TerrainMesher.new(snap, w.catalog).build(open_sm)
	_check.call(open.terrain != null and _materials(open.terrain) == [ground], "wet: open ground is all ground material")
	var mixed := TerrainMesher.new(snap, w.catalog).build(mixed_sm)
	var mats := _materials(mixed.terrain)
	_check.call(mats.size() >= 2 and mats[0] == ground and mats[1] == solid,
			"wet: a submap with a building has ground outside and plain solid under the roof (%d surfaces)" % mats.size())
	_check.call(mixed.roof != null and _materials(mixed.roof) == [ground], "wet: roofs are ground material too")
	TerrainMesher.wet_ground(1.0)
	_check.call(is_equal_approx(ground.roughness, TerrainMesher.WET_ROUGHNESS) and ground.albedo_color == TerrainMesher.WET_TINT
			and is_equal_approx(solid.roughness, 0.9) and solid.albedo_color == Color.WHITE,
			"wet: soaked ground is darker and shinier; indoors nothing changes")
	TerrainMesher.wet_ground(-3.0)
	_check.call(is_equal_approx(ground.roughness, 0.9) and ground.albedo_color == Color.WHITE
			and is_equal_approx(ground.metallic_specular, 0.5), "wet: and dry again as it was")
	root.remove_child(w)
	w.free()


func _test_soak(root: Node) -> void:
	var ground := TerrainMesher.material(TerrainMesher.GROUND)
	var view := WeatherView.new()
	root.add_child(view)
	view.blend_s = 0.0
	view.apply(_snap(CLEAR, false, 0.0, -1.0, 1000), null, true)
	_check.call(view.wet == 0.0 and is_equal_approx(ground.roughness, 0.9), "wet: a game that starts dry is dry")
	view.apply(_snap(RAIN, false, 0.0, -1.0, 1060), null, true)
	_check.call(is_equal_approx(view.wet, 0.5) and ground.roughness < 0.7 and ground.roughness > 0.5,
			"wet: a minute of heavy rain wets the ground half way (roughness %.2f)" % ground.roughness)
	view.apply(_snap(DRIZZLE, false, 0.0, -1.0, 1120), null, true)
	_check.call(is_equal_approx(view.wet, 0.5 + 60.0 / 3.0 / WeatherView.WET_IN_S), "wet: a drizzle wets slowly")
	view.apply(_snap(RAIN, false, 0.0, -1.0, 5000), null, true)
	_check.call(view.wet == 1.0 and is_equal_approx(ground.roughness, TerrainMesher.WET_ROUGHNESS), "wet: soaked at most")
	view.apply(_snap(CLEAR, false, 0.0, -1.0, 5000 + 900), null, true)
	_check.call(is_equal_approx(view.wet, 0.5), "wet: it dries in game time (half dry after %d minutes)" % 15)
	var before := ground.roughness
	view.apply(_snap(CLEAR, false, 0.0, -1.0, 5000 + 910), null, true)
	_check.call(ground.roughness == before and view.wet < 0.5, "wet: small changes leave the material alone")
	view.apply(_snap(SNOWING, false, 0.0, -1.0, 5000 + 1800), null, true)
	_check.call(view.wet == 0.0 and is_equal_approx(ground.roughness, 0.9), "wet: snow doesn't wet; dry after half an hour")
	# Another game (the turn goes back): what it is like there, at once.
	view.apply(_snap(RAIN, false, 0.0, -1.0, 50), null, true)
	_check.call(view.wet == 1.0, "wet: a game loaded in the rain starts wet")
	view.apply(_snap(CLEAR, false, 0.0, -1.0, 10), null, true)
	_check.call(view.wet == 0.0 and is_equal_approx(ground.roughness, 0.9), "wet: and one loaded in the dry starts dry")
	root.remove_child(view)
	view.free()
	TerrainMesher.wet_ground(0.0)
