extends RefCounted
## Blocks C6 / I2 checks, run by run_tests.gd: the lightning flash (the bridge's `lightning` event, junk events,
## the flash's curve, what it lights and that it ends; its safety limits: one pulse, a floor between flashes, none
## in fast-forward or asleep, the player's setting), thunder after it, and the weather's sound (the four noise
## clips, what is heard outdoors, under a roof, in snow and in wind, the glides, and that nothing runs in still,
## dry weather), the wet ground (open-sky terrain and roofs have their own material; it soaks in rain and dries
## in game time), puddles and snow lying on the ground. Headless can't render or be heard: how it looks and sounds is checked on screen.

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
	_test_snow_cover(root)
	_test_puddles(root)


func _snap(w: Array, sheltered := false, wind := 0.0, wind_here := -1.0, turn := 1, z := 0, asleep := false,
		temp: Variant = null) -> Snapshot:
	var env := {"sun_alt_deg": 45.0, "sun_az_deg": 0.0, "ambient_light": 100, "precip": w[0], "precip_kind": w[1],
			"sight_penalty": w[2], "light_modifier": w[3], "sun_multiplier": w[4], "weather_sound": w[5],
			"sheltered": sheltered, "wind_speed": wind, "wind_dir_deg": 0.0}
	if temp != null:
		env["temperature_c"] = temp
	if wind_here >= 0.0:
		env["wind_at_player"] = wind_here
	return Snapshot.from_data({"contract_version": 0, "turn": turn, "seq": 1, "bubble_origin": [0, 0, 0],
			"submaps": [], "env": env, "player": {"pos": [66, 66, z], "effects": [{"id": "sleep", "name": "Asleep",
			"body_part": 0, "intensity": 1, "rating": 0, "seconds_left": 600}] if asleep else []}})


func _state(w: Array, sheltered := false, wind := 0.0, wind_here := -1.0) -> WeatherState:
	return WeatherState.from_snapshot(_snap(w, sheltered, wind, wind_here))


func _wait(view: WeatherView, secs: float) -> void:
	for i in roundi(secs / 0.05) + 1:   # one step more: twenty steps of 0.05 are a hair under a second
		view._process(0.05)


func _test_flash(root: Node) -> void:
	_check.call(_state(STORM).thunder and not _state(RAIN).thunder and not _state(CLEAR).thunder,
			"storm: a thunderstorm is CDDA's thunder sound category")
	var odd := _snap(STORM)
	_check.call(odd.is_valid() and odd.weather_sound == Snapshot.WEATHER_SOUND_THUNDER, "storm: weather_sound is read")
	var c := WeatherView.flash_curve
	var falling := true
	for i in 50:
		falling = falling and c.call(i * 0.01) > c.call(i * 0.01 + 0.01)
	_check.call(c.call(0.0) == 1.0 and falling and c.call(0.25) < 0.15 and c.call(WeatherView.FLASH_S) == 0.0
			and c.call(-1.0) == 0.0 and c.call(9.0) == 0.0, "storm: a flash is one pulse that only fades, over in %.1f s" %
			WeatherView.FLASH_S)
	var env := Environment.new()
	var lighting := WorldLighting.new()
	root.add_child(lighting)
	lighting.flash = 7.0
	_check.call(lighting.flash == 1.0 and lighting.get("_mat").get_shader_parameter("flash") == 1.0,
			"storm: the light pass takes a flash level, at most 1")
	lighting.flash = 0.0
	var view := WeatherView.new()
	root.add_child(view)
	var clock := [1000]
	view.clock_ms = func() -> int: return clock[0]
	view.blend_s = 0.0
	view.lighting = lighting
	view.setup(env, null)
	view.apply(_snap(CLEAR), null, true)
	var light: DirectionalLight3D = view.get("_flash_light")
	_check.call(not light.visible and not light.shadow_enabled and view.flashes == 0 and not view.is_processing()
			and view.flash_enabled and view.flash_scale == 1.0, "storm: no flash, no work in clear weather")
	view.on_events([1, "lightning", null, {"kind": 5}, {"kind": "sound"}, {"type": "lightning"}, []])
	_check.call(view.flashes == 0 and not light.visible, "storm: other events and junk do nothing")
	view.on_events([{"kind": "sound"}, {"kind": "lightning", "pos": [1, 2, 0]}, {"kind": "lightning"}])
	_check.call(view.flashes == 1 and light.visible and is_equal_approx(light.light_energy, WeatherView.FLASH_LIGHT)
			and is_equal_approx(lighting.flash, WeatherView.FLASH_FLOOR)
			and is_equal_approx(env.fog_light_energy, 1.0 + WeatherView.FLASH_FOG) and view.is_processing(),
			"storm: a lightning event lights the scene, the haze and the dark at once")
	_check.call(not view.strike() and view.flashes == 1, "storm: a second strike right away is dropped")
	view._process(0.15)
	var later := light.light_energy
	view._process(0.15)
	_check.call(later < 0.4 * WeatherView.FLASH_LIGHT and light.light_energy < later, "storm: it fades and never rises again")
	_wait(view, 0.3)
	_check.call(not light.visible and lighting.flash == 0.0 and is_equal_approx(env.fog_light_energy, 1.0),
			"storm: after %.1f s everything is as before" % WeatherView.FLASH_S)
	_check.call(not view.strike() and view.flashes == 1, "storm: a strike a second later is dropped too")
	_wait(view, WeatherView.FLASH_EVERY_S)
	_check.call(not view.is_processing(), "storm: and then no more work")
	_check.call(view.strike() and view.flashes == 2, "storm: %.0f s after the last one a strike flashes again" %
			WeatherView.FLASH_EVERY_S)
	_wait(view, WeatherView.FLASH_EVERY_S)
	# Lightning in every batch of events (a bad bridge, or CDDA's flashes packed together): the floor holds.
	var before := view.flashes
	var most_in_a_second := 0
	var recent: Array[float] = []
	for i in 100:
		var n := view.flashes
		view.on_events([{"kind": "lightning"}, {"kind": "turn_end"}])
		if view.flashes > n:
			recent.append(i * 0.05)
		var in_window := 0
		for t in recent:
			in_window += int(i * 0.05 - t < 1.0)
		most_in_a_second = maxi(most_in_a_second, in_window)
		view._process(0.05)
	_check.call(view.flashes - before == 2 and most_in_a_second == 1,
			"storm: lightning in every batch for 5 s flashes twice, never twice in a second (lead-qa)")
	_wait(view, WeatherView.FLASH_EVERY_S)
	# Game time running fast (waiting, sleeping): thunder, no flash.
	before = view.flashes
	view.on_events([{"kind": "turn_end"}, {"kind": "turn_end"}, {"kind": "turn_end"}, {"kind": "lightning"}])
	_check.call(view.fast_forward and view.flashes == before and not light.visible and view.sound.get("_thunder_in") > 0.0,
			"storm: several turns in one batch is fast-forward: thunder without a flash")
	_wait(view, WeatherView.FLASH_EVERY_S)
	for i in 12:   # 12 turns in 0.6 s, one a batch: 20 a second
		clock[0] += 50
		view.on_events([{"kind": "turn_end"}])
	_check.call(view.fast_forward and not view.strike(), "storm: twenty turns a second is fast-forward too")
	_wait(view, WeatherView.FLASH_EVERY_S)
	for i in 6:   # walking: a turn every 0.15 s
		clock[0] += 150
		view.on_events([{"kind": "turn_end"}])
	_check.call(not view.fast_forward and view.strike(), "storm: walking pace is not; the flash is back")
	_wait(view, WeatherView.FLASH_EVERY_S)
	# Asleep: none.
	view.apply(_snap(STORM, false, 0.0, -1.0, 1, 0, true), null, true)
	_check.call(view.asleep and not view.strike(), "storm: no flash while the character sleeps")
	_wait(view, WeatherView.FLASH_EVERY_S)
	view.apply(_snap(STORM), null, true)
	# The player's setting: off shows none.
	view.flash_enabled = false
	_check.call(not view.asleep and not view.strike() and not light.visible and lighting.flash == 0.0
			and view.sound.get("_thunder_in") > 0.0, "storm: the setting off shows no flash; the thunder stays")
	view.flash_enabled = true
	_wait(view, WeatherView.FLASH_EVERY_S)
	# In a headset, and under a roof, it is weaker.
	view.flash_scale = WeatherView.FLASH_VR
	view.strike()
	_check.call(is_equal_approx(lighting.flash, WeatherView.FLASH_FLOOR * WeatherView.FLASH_VR) and lighting.flash < 0.25,
			"storm: weaker in a headset (the dark lifts to %.2f at most)" % lighting.flash)
	view.flash_scale = 1.0
	_wait(view, WeatherView.FLASH_EVERY_S)
	view.apply(_snap(STORM, true), null, true)
	view.strike()
	_check.call(is_equal_approx(light.light_energy, WeatherView.FLASH_LIGHT * WeatherView.FLASH_INDOORS)
			and is_equal_approx(lighting.flash, WeatherView.FLASH_FLOOR * WeatherView.FLASH_INDOORS),
			"storm: half the flash reaches under a roof")
	# At night the flash lights the mist and the storm sky too (seen on screen: the sky stayed black).
	_wait(view, WeatherView.FLASH_EVERY_S)
	var night := _snap(STORM)
	night.ambient_light = 2
	night.sun_alt_deg = -30.0
	view.apply(night, null, true)
	var dark_fog := env.fog_light_color.get_luminance()
	view.strike()
	var lit_fog := env.fog_light_color.get_luminance()
	_wait(view, 1.0)
	_check.call(env.fog_enabled and lit_fog > 5.0 * dark_fog and is_equal_approx(env.fog_light_color.get_luminance(), dark_fog),
			"storm: at night the flash lights the mist too, then it is dark again (%.3f, %.3f)" % [dark_fog, lit_fog])
	# Underground there is no flash.
	_wait(view, WeatherView.FLASH_EVERY_S)
	view.apply(_snap(STORM, true, 0.0, -1.0, 1, -1), null, true)
	_check.call(not view.strike() and not light.visible and lighting.flash == 0.0
			and is_equal_approx(env.fog_light_energy, 1.0), "storm: no flash underground")
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
	# The setting: on by default, the F1 box turns it off and saves it; junk in the file leaves it on.
	var path := preload("res://tests/test_dir.gd").path("hud_flash.cfg")
	var hs := HudSettings.new()
	var menu := KeyMenu.new()
	menu.add_hud_settings(hs, path)
	var seen := [0]
	menu.hud_changed.connect(func() -> void: seen[0] += 1)
	var was_on := hs.weather_flash and menu.flash_check.button_pressed
	menu.flash_check.button_pressed = false
	var back := HudSettings.new()
	back.load_file(path)
	_check.call(was_on and not hs.weather_flash and not back.weather_flash and back.mood_cues and seen[0] == 1,
			"storm: the flash is on by default; the F1 box turns it off and saves it")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[compass]\nopacity=0.5\n[weather]\nflash=3\n")
	f.close()
	var junk := HudSettings.new()
	junk.load_file(path)
	_check.call(junk.weather_flash, "storm: a non-bool in the file leaves it on")
	menu.free()


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
	var made := AudioServer.get_bus_index(WeatherSound.BUS) < 0   # main makes it at start; a test run may not have
	if made:
		var plain := WeatherSound.new()
		root.add_child(plain)
		_check.call(plain.rain.bus == &"Master" and plain.thunder.bus == &"Master", "sound: on Master without the Ambience bus")
		root.remove_child(plain)
		plain.free()
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, WeatherSound.BUS)
	var s := WeatherSound.new()
	root.add_child(s)
	_check.call(not s.busy() and not s.is_processing() and not s.rain.playing, "sound: silent and idle to begin with")
	_check.call([s.rain, s.roof, s.wind, s.thunder].all(func(p: AudioStreamPlayer) -> bool: return p.bus == WeatherSound.BUS),
			"sound: plays on the Ambience bus (its own volume)")
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
	# Underground: one level down a little of the patter and the thunder is left, deeper nothing.
	var cellar := WeatherState.from_snapshot(_snap(STORM, true, 8.0, 0.0, 1, -1))
	s.apply(cellar)
	s.strike()
	_check.call(s.targets[s.rain] == 0.0 and s.targets[s.wind] == 0.0
			and is_equal_approx(s.targets[s.roof], WeatherSound.ROOF_GAIN * WeatherSound.CELLAR)
			and is_equal_approx(s.get("_thunder_gain"), WeatherSound.THUNDER_GAIN * WeatherSound.CELLAR)
			and s.get("_rumble_in") > 0.0, "sound: a cellar hears a little of the rain and the thunder")
	var deep := WeatherState.from_snapshot(_snap(STORM, true, 8.0, 0.0, 1, -3))
	s.apply(deep)
	s.strike()
	_check.call(s.targets[s.rain] == 0.0 and s.targets[s.roof] == 0.0 and s.targets[s.wind] == 0.0
			and s.get("_thunder_in") < 0.0 and s.get("_rumble_in") < 0.0, "sound: deeper down the weather is silent")
	s.apply(_state(CLEAR))
	for i in 12:
		s.tick(0.1)
	root.remove_child(s)
	s.free()
	if made:
		AudioServer.remove_bus(AudioServer.get_bus_index(WeatherSound.BUS))
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
	# Seen on screen: from inside a room the ceiling was black. A roof's underside is pale, whatever the roof is.
	var arrays := mixed.roof.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var under := 0
	var dull := 0
	var top_lum := 0.0
	var tops := 0
	for i in normals.size():
		if normals[i].y < -0.5:
			under += 1
			dull += int(colors[i].get_luminance() < 0.6)
		elif normals[i].y > 0.5:
			tops += 1
			top_lum += colors[i].get_luminance()
	_check.call(under > 0 and under == tops and dull == 0 and top_lum / tops < 0.5,
			"ceiling: a roof's underside is pale (%d vertices), its top keeps the roof's colour (%.2f)" %
			[under, top_lum / maxi(tops, 1)])
	var dark_roof := Color(0.32, 0.3, 0.3)
	_check.call(TerrainMesher.ceiling_color(dark_roof).get_luminance() > 0.65
			and TerrainMesher.ceiling_color(Color(0.5, 0.35, 0.2)).r > TerrainMesher.ceiling_color(Color(0.5, 0.35, 0.2)).b,
			"ceiling: mostly plaster, with a little of the colour of what is above")
	TerrainMesher.wet_ground(1.0)
	_check.call(is_equal_approx(ground.roughness, TerrainMesher.WET_ROUGHNESS) and ground.albedo_color == TerrainMesher.WET_TINT
			and is_equal_approx(solid.roughness, 0.9) and solid.albedo_color == Color.WHITE,
			"wet: soaked ground is darker and shinier; indoors nothing changes")
	TerrainMesher.wet_ground(-3.0)
	_check.call(is_equal_approx(ground.roughness, 0.9) and ground.albedo_color == Color.WHITE
			and is_equal_approx(ground.metallic_specular, 0.5), "wet: and dry again as it was")
	_check_puddles(snap, w, open_sm, open, mixed_sm, mixed)
	root.remove_child(w)
	w.free()


## Puddles lie only on open-ground floor squares, one in a few, each inside its square, flat and facing up, with
## what the shader needs (offset from the centre, rim, the level it starts at); the same each build. The world's
## puddle meshes follow puddle_ground and cast no shadow.
func _check_puddles(snap: Snapshot, w: WorldView, open_sm: Vector3i, open: TerrainMesher.Result, mixed_sm: Vector3i,
		mixed: TerrainMesher.Result) -> void:
	var per := 3 * TerrainMesher.PUDDLE_SIDES
	var counts: Array[int] = []
	var bad: Array[String] = []
	for pair: Array in [[open_sm, open], [mixed_sm, mixed]]:
		var sm: Snapshot.Submap = snap.submaps[pair[0]]
		var r: TerrainMesher.Result = pair[1]
		var count := 0
		if r.puddles != null:
			var arrays := r.puddles.surface_get_arrays(0)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var c: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			if r.puddles.get_surface_count() != 1 or r.puddles.surface_get_material(0) != TerrainMesher.puddle_material() \
					or v.size() % per != 0 or uv.size() != v.size():
				bad.append("layout")
				v = PackedVector3Array()
			for k in range(0, v.size(), per):
				count += 1
				var mid := v[k]
				var lx := floori(mid.x)
				var ly := floori(mid.z)
				var i := ly * CddaCoords.SEEX + lx
				if sm.flags[i] & Snapshot.FLAG_ROOF or w.catalog.style_for(sm.ter[i]).kind != TerrainCatalog.Kind.FLOOR:
					bad.append("square %d,%d" % [lx, ly])
				var start := c[k].a
				if start < TerrainMesher.PUDDLE_FIRST - 0.01 or start > TerrainMesher.PUDDLE_LAST + 0.01:
					bad.append("start %.2f" % start)
				for j in range(k, k + per):
					var off := v[j] - mid
					var centre := (j - k) % 3 == 0
					if v[j].x <= lx or v[j].x >= lx + 1 or v[j].z <= ly or v[j].z >= ly + 1 \
							or not is_equal_approx(v[j].y, TerrainMesher.PUDDLE_Y) or n[j].y < 0.999 \
							or uv[j].distance_to(Vector2(off.x, off.z)) > 1e-4 or absf(c[j].a - start) > 0.01 \
							or c[j].r != (0.0 if centre else 1.0) or (centre and off.length() > 1e-5):
						bad.append("vertex %d" % j)
						break
				for t in range(k, k + per, 3):
					if (v[t + 1] - v[t]).cross(v[t + 2] - v[t]).dot(Vector3.UP) >= 0.0:
						bad.append("winding %d" % t)
						break
		counts.append(count)
	var again := TerrainMesher.new(snap, w.catalog).build(open_sm)
	var same: bool = open.puddles != null and again.puddles != null \
			and again.puddles.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == open.puddles.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check.call(bad.is_empty() and counts[0] >= 5 and counts[0] <= 72 and same, "puddles: on a few open-ground floor squares "
			+ "(%d of 144 here, %d by the building), none under a roof, each inside its square; the same each build %s" %
			[counts[0], counts[1], bad.slice(0, 4)])
	TerrainMesher.puddle_ground(1.0, null)
	w._build(open_sm, open, snap)
	var node: Node3D = w._nodes.get(open_sm)
	var mi: MeshInstance3D = (node.get_node_or_null("puddles") as MeshInstance3D) if node != null else null
	var shown := mi != null and mi.visible and mi.mesh == open.puddles and mi.is_in_group(TerrainMesher.PUDDLE_GROUP) \
			and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	TerrainMesher.puddle_ground(TerrainMesher.PUDDLE_FIRST, w.get_tree())
	var hidden := mi != null and not mi.visible and not TerrainMesher.puddles_shown
	TerrainMesher.puddle_ground(NAN, w.get_tree())
	var junk := float(TerrainMesher.puddle_material().get_shader_parameter(&"level")) == 0.0
	_check.call(shown and hidden and junk, "puddles: a submap's puddle mesh is shown while puddles fill, hidden up to the first "
			+ "one's level; it casts no shadow")
	TerrainMesher.puddle_ground(0.0, null)


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


## Snow lying on the ground: the air's temperature is read; snow covers the ground while it falls (heavier faster),
## stays at or below freezing, melts when warmer (faster the warmer) and in rain; a game loaded in snow starts
## covered; MINIMAL quality shows none; the snow pass follows the bubble's origin and leaves when it is gone.
func _test_snow_cover(root: Node) -> void:
	var t := func(w: Array, turn: int, temp: Variant) -> Snapshot: return _snap(w, false, 0.0, -1.0, turn, 0, false, temp)
	var cold: Snapshot = t.call(SNOWING, 1, -5.5)
	_check.call(cold.is_valid() and is_equal_approx(cold.temperature_c, -5.5) and is_nan(_snap(CLEAR).temperature_c)
			and not (t.call(CLEAR, 1, 150.0) as Snapshot).is_valid() and not (t.call(CLEAR, 1, "cold") as Snapshot).is_valid(),
			"snow: the air's temperature is read; none sent is unknown; out of range or not a number fails the snapshot")
	var ground := TerrainMesher.material(TerrainMesher.GROUND)
	var view := WeatherView.new()
	root.add_child(view)
	view.blend_s = 0.0
	var coords := CddaCoords.new()
	var at := func(w: Array, turn: int, temp: Variant) -> void: view.apply(t.call(w, turn, temp), coords, true)
	at.call(CLEAR, 1000, -5.0)
	var bare := view.snow_cover == 0.0 and ground.next_pass == null
	at.call(SNOWING, 1900, -5.0)
	var snow_pass := ground.next_pass as ShaderMaterial
	var half: bool = is_equal_approx(view.snow_cover, 0.5) and snow_pass != null and snow_pass.shader == TerrainMesher.SNOW_SHADER \
			and is_equal_approx(float(snow_pass.get_shader_parameter(&"cover")), 0.5) and snow_pass.render_priority == WorldLighting.UNDER_PRIORITY
	at.call(CLEAR, 5500, -5.0)
	var frozen := is_equal_approx(view.snow_cover, 0.5)
	at.call(CLEAR, 5500 + 1800, 4.0)
	var melting := is_equal_approx(view.snow_cover, 0.25)
	at.call(CLEAR, 5500 + 2700, 8.0)
	var gone := view.snow_cover == 0.0 and ground.next_pass == null
	_check.call(bare and half and frozen and melting and gone, "snow: half covered after 15 minutes of heavy snow, kept in the frost, "
			+ "melting at 4 C, gone faster at 8 C (%.2f)" % view.snow_cover)
	at.call(SNOWING, 9000, -1.0)
	at.call(SNOWING, 9000 + 3600, -1.0)
	var full := view.snow_cover == 1.0
	at.call(RAIN, 9000 + 3600 + 900, 0.0)
	var rained := is_equal_approx(view.snow_cover, 0.5)
	at.call(DRIZZLE, 9000 + 3600 + 1800, null)   # no temperature: melts slowly, as at MELT_UNKNOWN_C
	var unknown := view.snow_cover < 0.5 - 900.0 * (1.0 / 3.0) / WeatherView.RAIN_MELT_S \
			and view.snow_cover > 0.5 - 900.0 / WeatherView.RAIN_MELT_S
	_check.call(full and rained and unknown, "snow: at most covered; rain melts it; no temperature melts it as a little above freezing")
	at.call(SNOWING, 50, -3.0)   # another game, loaded in snow
	var loaded := view.snow_cover == 1.0 and ground.next_pass != null
	view.quality = WeatherView.MINIMAL
	var minimal := ground.next_pass == null
	view.quality = WeatherView.HIGH
	coords.origin_ms = Vector3i(600, -3, 0)
	at.call(SNOWING, 60, -3.0)
	var pass2 := ground.next_pass as ShaderMaterial
	var moved: bool = pass2 != null and pass2.get_shader_parameter(&"origin_m") == Vector2(88, 509)
	_check.call(loaded and minimal and moved, "snow: a game loaded in snow starts covered; none at minimal quality; the patches "
			+ "follow the bubble's origin")
	var code := TerrainMesher.SNOW_SHADER.code
	_check.call(code.contains("uniform float cover") and code.contains("origin_m") and code.contains("NORMAL")
			and code.contains("const float PERIOD = %d.0" % TerrainMesher.SNOW_PERIOD), "snow: the shader lies on what faces up, "
			+ "its patches repeat at SNOW_PERIOD")
	root.remove_child(view)
	view.free()
	_check.call(ground.next_pass == null, "snow: the shared ground material is bare again when the view goes")
	TerrainMesher.snow_ground(0.0, Vector3i.ZERO)


## Puddles fill in rain more slowly than the ground wets and dry more slowly; a game loaded in rain starts with them as
## full as the rain is heavy; snow hides them as it covers the ground; none at MINIMAL quality; the puddle meshes are
## hidden while none shows and when the view goes.
func _test_puddles(root: Node) -> void:
	var view := WeatherView.new()
	root.add_child(view)
	view.blend_s = 0.0
	var pool := MeshInstance3D.new()
	root.add_child(pool)
	pool.add_to_group(TerrainMesher.PUDDLE_GROUP)
	pool.visible = TerrainMesher.puddles_shown   # as WorldView makes them
	_pool_at(view, CLEAR, 1000)
	var dry := view.puddles == 0.0 and not pool.visible and not TerrainMesher.puddles_shown
	_pool_at(view, RAIN, 1090)
	var early := is_equal_approx(view.puddles, 0.1) and view.wet > 0.7 and not pool.visible
	var level := _pool_at(view, RAIN, 1450)
	var filling := is_equal_approx(view.puddles, 0.5) and is_equal_approx(level, 0.5) and pool.visible
	_pool_at(view, RAIN, 3000)
	var full := view.puddles == 1.0
	level = _pool_at(view, CLEAR, 3000 + 3600)
	var outlast := view.wet == 0.0 and is_equal_approx(view.puddles, 0.5) and is_equal_approx(level, 0.5) and pool.visible
	_pool_at(view, CLEAR, 3000 + 7200)
	var gone := view.puddles == 0.0 and not pool.visible
	_check.call(dry and early and filling and full and outlast and gone, "puddles: they start once the ground is wet, fill in 15 "
			+ "minutes of heavy rain, outlast the wet ground and dry up in 2 hours %s" % [[dry, early, filling, full, outlast, gone]])
	level = _pool_at(view, DRIZZLE, 50)   # another game, loaded in a drizzle
	var drizzle := is_equal_approx(view.puddles, view.target.precip) and view.puddles < 0.5 and pool.visible
	_pool_at(view, RAIN, 10)
	var heavy := view.puddles == 1.0
	view.quality = WeatherView.MINIMAL
	var minimal := not pool.visible and float(TerrainMesher.puddle_material().get_shader_parameter(&"level")) == 0.0
	view.quality = WeatherView.HIGH
	var back := pool.visible
	_check.call(drizzle and heavy and minimal and back, "puddles: a game loaded in rain starts with puddles as full as it is heavy; "
			+ "none at minimal quality")
	level = _pool_at(view, SNOWING, 10 + 900)
	var hid := is_equal_approx(view.snow_cover, 0.5) and is_equal_approx(view.puddles, 1.0 - 900.0 / WeatherView.PUDDLE_DRY_S) \
			and is_equal_approx(level, view.puddles * 0.5)
	root.remove_child(view)
	view.free()
	var left := not pool.visible and not TerrainMesher.puddles_shown \
			and float(TerrainMesher.puddle_material().get_shader_parameter(&"level")) == 0.0
	var code := TerrainMesher.PUDDLE_SHADER.code
	_check.call(hid and left and code.contains("uniform float level") and code.contains("COLOR.a") and code.contains("UV"),
			"puddles: snow hides them as it covers the ground; none left when the view goes (%.2f)" % level)
	root.remove_child(pool)
	pool.free()
	TerrainMesher.puddle_ground(0.0, null)


## Shows a snapshot's weather at `turn`; the puddles' level as shown.
func _pool_at(view: WeatherView, w: Array, turn: int) -> float:
	view.apply(_snap(w, false, 0.0, -1.0, turn), null, true)
	return float(TerrainMesher.puddle_material().get_shader_parameter(&"level"))
