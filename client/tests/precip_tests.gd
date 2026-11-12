extends RefCounted
## Blocks C6 / I2 checks, run by run_tests.gd: where rain and snow may fall (PrecipView: open squares only, the
## rain shadow of a building in wind, open air down to the ground, nothing underground or without a map), where the
## drops start, and the two particle emitters (which one runs, how many particles, their fall and lean, start
## points worked out only on a change). Uses the mock town around the player: a roofed building to the north-west
## (squares 5..12 west of the player, north of the player's row), open ground elsewhere, the building's flat roof
## and open air on the level above. Headless can't render: how it looks is checked on screen.

var _check: Callable
var _data: Dictionary

# [precip, precip_kind, sight penalty, light modifier, sun multiplier] (weather_tests.gd)
const CLEAR := [0, 0, 1.0, 0, 1.0]
const DRIZZLE := [1, 1, 1.01, -10, 0.2]
const RAIN := [3, 1, 1.1, -30, 0.03]
const SNOWING := [3, 2, 1.3, -20, 0.15]
const R := PrecipView.RADIUS


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	_data = data
	print("rain and snow")
	_test_squares()
	_test_starts()
	_test_emitters(root)


## The mock around the player (the submaps the drops can reach), with this weather and wind.
func _near(w: Array, wind_speed := 0.0, wind_from_deg := 0.0, player := Vector3i.MAX) -> Dictionary:
	var pos: Array = _data["player"]["pos"]
	var c := Vector3i(int(pos[0]) / 12, int(pos[1]) / 12, 0)
	var d := _data.duplicate(false)
	var keep := []
	for s: Dictionary in _data["submaps"]:
		if absi(int(s["pos"][0]) - c.x) <= 1 and absi(int(s["pos"][1]) - c.y) <= 1 and int(s["pos"][2]) >= 0:
			keep.append(s.duplicate(true))
	d["submaps"] = keep
	d["env"] = {"sun_alt_deg": 45.0, "sun_az_deg": 0.0, "ambient_light": 100, "precip": w[0], "precip_kind": w[1],
			"sight_penalty": w[2], "light_modifier": w[3], "sun_multiplier": w[4], "wind_speed": wind_speed,
			"wind_dir_deg": wind_from_deg}
	if player != Vector3i.MAX:
		var p: Dictionary = (_data["player"] as Dictionary).duplicate(true)
		p["pos"] = [player.x, player.y, player.z]
		d["player"] = p
	return d


func _roofed(snap: Snapshot, p: Vector3i) -> bool:
	return PrecipView._flags(snap, p) & Snapshot.FLAG_ROOF != 0


func _test_squares() -> void:
	var snap := Snapshot.from_data(_near(RAIN))
	_check.call(snap.is_valid() and snap.submaps.size() == 18, "rain: the fixture (%d submaps) %s" %
			[snap.submaps.size(), snap.error])
	var c := snap.player_pos
	var in_reach := 0
	var roofed := 0
	for dy in range(-R, R + 1):
		for dx in range(-R, R + 1):
			if dx * dx + dy * dy <= R * R:
				in_reach += 1
				roofed += int(_roofed(snap, c + Vector3i(dx, dy, 0)))
	var t0 := Time.get_ticks_usec()
	var calm := PrecipView.landing_squares(snap, Vector2.ZERO)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var bad := 0
	for p in calm:
		bad += int(_roofed(snap, p) or p.z != c.z or Vector2(p.x - c.x, p.y - c.y).length() > R)
	_check.call(roofed > 50 and calm.size() == in_reach - roofed and bad == 0,
			"rain: lands on every open square within %d of the player, none under a roof (%d of %d, %.1f ms)" %
			[R, calm.size(), in_reach, ms])
	# A wind from the west leans the fall east: the squares right behind the building's east wall stay dry.
	var east := PrecipView.lean_of(WeatherState.wind_vector(20.0, 270.0), PrecipView.RAIN_SPEED,
			PrecipView.RAIN_LEAN_MAX)
	_check.call(east.is_equal_approx(Vector2(PrecipView.RAIN_LEAN_MAX, 0)), "rain: a strong west wind leans it east, capped")
	var lee := PrecipView.landing_squares(snap, east)
	var dry := {}
	for p in calm:
		dry[p] = true
	for p in lee:
		dry.erase(p)
	var behind_wall := 0
	for p: Vector3i in dry:
		behind_wall += int(p.x - c.x == -4 and p.y < c.y)
	_check.call(dry.size() == 11 and behind_wall == 11,
			"rain: the building's lee is dry (%d squares along its east wall)" % dry.size())
	var west := PrecipView.landing_squares(snap, -east)
	_check.call(west.size() == calm.size(), "rain: an east wind leaves no shadow on this side")
	_check.call(PrecipView.lean_of(WeatherState.wind_vector(2.0, 0.0), PrecipView.SNOW_SPEED, PrecipView.SNOW_LEAN_MAX)
			.is_equal_approx(Vector2(0, 0.75)) and PrecipView.lean_of(Vector3.ZERO, 1.6, 0.8) == Vector2.ZERO,
			"snow: leans far in little wind, straight down in none")
	# On the building's roof (one level up): the roof's squares, and past the open air beside it down to the ground.
	var top := Snapshot.from_data(_near(RAIN, 0.0, 0.0, Vector3i(c.x - 8, c.y - 6, 1)))
	var up := PrecipView.landing_squares(top, Vector2.ZERO)
	var on_roof := 0
	var on_ground := 0
	for p in up:
		on_roof += int(p.z == 1)
		on_ground += int(p.z == 0 and not _roofed(top, p))
	_check.call(top.is_valid() and on_roof > 50 and on_ground > 100 and on_roof + on_ground == up.size()
			and is_equal_approx(PrecipView.drop_m(top), 9.0) and is_equal_approx(PrecipView.drop_m(snap), 6.0),
			"rain: from a roof it falls on the roof (%d) and past it to the ground (%d), 9 m at most" %
			[on_roof, on_ground])
	var under := Snapshot.from_data(_near(RAIN, 0.0, 0.0, Vector3i(c.x, c.y, -1)))
	_check.call(under.is_valid() and PrecipView.landing_squares(under, Vector2.ZERO).is_empty(), "rain: none underground")
	var bare := _near(RAIN)
	bare["submaps"] = []
	_check.call(PrecipView.landing_squares(Snapshot.from_data(bare), east).is_empty(), "rain: none without a map")


func _test_starts() -> void:
	var snap := Snapshot.from_data(_near(RAIN))
	var coords := CddaCoords.new()
	coords.set_bubble_origin(snap.bubble_origin)
	var p := snap.player_pos + Vector3i(3, 2, 0)
	var ground := coords.ms_to_world(p)
	var above := PrecipView.start_point(coords, snap, p, Vector2.ZERO)
	_check.call(above.is_equal_approx(ground + Vector3(0, PrecipView.TOP_M, 0)), "rain: starts %d m over its square" %
			PrecipView.TOP_M)
	var lean := Vector2(0.5, -0.25)
	var upwind := PrecipView.start_point(coords, snap, p, lean)
	var landed := upwind + Vector3(lean.x, -1.0, lean.y) * PrecipView.TOP_M
	_check.call(upwind.is_equal_approx(above + Vector3(-3, 0, 1.5)) and landed.is_equal_approx(ground),
			"rain: leaning, it starts upwind and comes down on its square")
	# The squares a drop passes over: the levels above in calm air, a diagonal from upwind in wind.
	_check.call(PrecipView.way(Vector2.ZERO, 6) == [Vector3i(0, 0, 1), Vector3i(0, 0, 2)]
			and PrecipView.way(Vector2(0.5, 0), 6) == [Vector3i(-1, 0, 0), Vector3i(-2, 0, 1), Vector3i(-3, 0, 1),
			Vector3i(-3, 0, 2)], "rain: the way down is checked a metre at a time, each square once")
	_check.call(PrecipView.centre(snap) == snap.player_pos, "rain: the mock's player stands on a centre square")


func _test_emitters(root: Node) -> void:
	var view := PrecipView.new()
	root.add_child(view)
	var coords := CddaCoords.new()
	_check.call(not view.rain.emitting and not view.snow.emitting and view.rain.amount == PrecipView.MAX_RAIN
			and view.snow.amount == PrecipView.MAX_SNOW and not view.rain.local_coords
			and view.rain.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"rain: two emitters, off, with a fixed number of particles (%d rain, %d snow)" %
			[view.rain.amount, view.snow.amount])
	var mat := (view.rain.draw_pass_1 as QuadMesh).material as StandardMaterial3D
	_check.call(mat.render_priority == WorldLighting.UNDER_PRIORITY and mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
			"rain: drawn before the light pass (dark at night like the scene)")
	var snap := Snapshot.from_data(_near(RAIN))
	coords.set_bubble_origin(snap.bubble_origin)
	var t0 := Time.get_ticks_usec()
	view.apply(snap, coords, WeatherState.from_snapshot(snap))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var rain := view.rain.process_material as ParticleProcessMaterial
	_check.call(view.rain.emitting and not view.snow.emitting and view.rebuilds == 1 and view.squares > 300
			and view.points == view.squares * PrecipView.POINTS_PER_SQUARE and view.points <= PrecipView.MAX_POINTS
			and rain.emission_point_count == view.points and rain.emission_point_texture != null
			and rain.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_POINTS,
			"rain: heavy rain runs from %d start points over %d squares (placed in %.1f ms)" %
			[view.points, view.squares, ms])
	_check.call(rain.direction.is_equal_approx(Vector3.DOWN) and rain.gravity == Vector3.ZERO
			and is_equal_approx(view.rain.lifetime, 6.0 / PrecipView.RAIN_SPEED)
			and is_equal_approx((rain.initial_velocity_min + rain.initial_velocity_max) / 2.0, PrecipView.RAIN_SPEED),
			"rain: straight down at %.0f m/s, gone at the ground" % PrecipView.RAIN_SPEED)
	var share := view.squares / (PI * R * R)
	_check.call(is_equal_approx(view.rain.amount_ratio, share) and share > 0.6 and share < 1.0,
			"rain: as many particles as there is open ground (%.0f%% of %d)" % [share * 100.0, PrecipView.MAX_RAIN])
	var starts := view.start_points()
	var floor_y := coords.ms_to_world(snap.player_pos).y
	var indoors := 0
	var far := 0
	for at in starts:
		var sq := coords.world_to_ms(Vector3(at.x, floor_y + 0.1, at.z))
		indoors += int(_roofed(snap, sq))
		far += int(Vector2(sq.x - snap.player_pos.x, sq.y - snap.player_pos.y).length() > R
				or not is_equal_approx(at.y, floor_y + PrecipView.TOP_M))
	_check.call(starts.size() == view.points and indoors == 0 and far == 0,
			"rain: every start point is over an open square near the player")
	view.apply(snap, coords, WeatherState.from_snapshot(snap))
	_check.call(view.rebuilds == 1, "rain: the same turn again places nothing anew")
	# Lighter rain: fewer particles, the same start points.
	var drizzle := Snapshot.from_data(_near(DRIZZLE))
	view.apply(drizzle, coords, WeatherState.from_snapshot(drizzle))
	_check.call(view.rain.emitting and is_equal_approx(view.rain.amount_ratio, share / 9.0) and view.rebuilds == 1,
			"rain: a light drizzle is a ninth of it (%.0f particles)" % (view.rain.amount_ratio * PrecipView.MAX_RAIN))
	# Wind: the fall leans, the start points move.
	var windy := Snapshot.from_data(_near(RAIN, 5.0, 270.0))
	view.apply(windy, coords, WeatherState.from_snapshot(windy))
	var lean := 5.0 * PrecipView.WIND_SHARE / PrecipView.RAIN_SPEED
	_check.call(view.rebuilds == 2 and rain.direction.is_equal_approx(Vector3(lean, -1, 0).normalized())
			and is_equal_approx(view.rain.lifetime, 6.0 / PrecipView.RAIN_SPEED),
			"rain: a west wind of 5 m/s leans it %.0f degrees east" % rad_to_deg(atan(lean)))
	# The player walks: one square moves nothing, two give new start points around the new place.
	var step := Snapshot.from_data(_near(RAIN, 5.0, 270.0, snap.player_pos + Vector3i(1, 0, 0)))
	t0 = Time.get_ticks_usec()
	view.apply(step, coords, WeatherState.from_snapshot(step))
	var same_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check.call(view.rebuilds == 2, "rain: a step of one square keeps the start points (%.2f ms)" % same_ms)
	var moved := Snapshot.from_data(_near(RAIN, 5.0, 270.0, snap.player_pos + Vector3i(2, 0, 0)))
	t0 = Time.get_ticks_usec()
	view.apply(moved, coords, WeatherState.from_snapshot(moved))
	_check.call(view.rebuilds == 3 and view.rain.emitting and PrecipView.centre(moved).x == snap.player_pos.x + 3,
			"rain: follows the player in steps of %d squares (placed again in %.1f ms)" %
			[PrecipView.CENTRE_STEP, (Time.get_ticks_usec() - t0) / 1000.0])
	# Snow: the other emitter, slow, leaning further.
	var snowing := Snapshot.from_data(_near(SNOWING, 5.0, 270.0))
	view.apply(snowing, coords, WeatherState.from_snapshot(snowing))
	var snow := view.snow.process_material as ParticleProcessMaterial
	_check.call(view.snow.emitting and not view.rain.emitting and is_equal_approx(view.snow.lifetime, 6.0 / PrecipView.SNOW_SPEED)
			and snow.direction.is_equal_approx(Vector3(PrecipView.SNOW_LEAN_MAX, -1, 0).normalized())
			and snow.emission_point_count == view.points and view.snow.amount_ratio > 0.5,
			"snow: its own emitter, %.1f s to the ground, leaning with the wind" % view.snow.lifetime)
	# Under a roof with no open square in reach, underground, clear weather: nothing runs.
	var cellar := Snapshot.from_data(_near(RAIN, 0.0, 0.0, snap.player_pos + Vector3i(0, 0, -1)))
	view.apply(cellar, coords, WeatherState.from_snapshot(cellar))
	_check.call(not view.rain.emitting and not view.snow.emitting and view.points == 0, "rain: none underground")
	view.apply(snap, coords, WeatherState.from_snapshot(snap))
	var clear := Snapshot.from_data(_near(CLEAR))
	view.apply(clear, coords, WeatherState.from_snapshot(clear))
	_check.call(not view.rain.emitting and not view.snow.emitting, "rain: stops when the weather clears")
	view.apply(snap, coords, WeatherState.new())
	view.apply(null, coords, WeatherState.from_snapshot(snap))
	view.apply(snap, null, WeatherState.from_snapshot(snap))
	_check.call(not view.rain.emitting, "rain: nothing without a snapshot or coordinates")
	root.remove_child(view)
	view.free()
	# WeatherView runs it.
	var weather := WeatherView.new()
	root.add_child(weather)
	weather.blend_s = 0.0
	weather.apply(snap, coords, true)
	_check.call(weather.precip.rain.emitting and weather.precip.get_parent() == weather, "rain: WeatherView shows it")
	weather.apply(clear, coords, true)
	_check.call(not weather.precip.rain.emitting, "rain: and stops it")
	root.remove_child(weather)
	weather.free()
