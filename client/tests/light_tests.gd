extends RefCounted
## Block C6 checks, run by run_tests.gd: env.ambient_light and per-submap `lights` parsing (good and bad), the
## light/vis atlas (LightMap: size, texel of a known tile per level), the brightness curve and tints, light
## sources (local maxima: threshold, cap, nearest first; the `lights` list preferred), and WorldLighting fed by
## WorldView (pass and lamps shown, --no-light). Headless can't render: the shader is checked by screenshots.

var _check: Callable


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	print("lighting")
	_test_parse(data)
	_test_atlas(data)
	_test_curve()
	_test_sources(data)
	_test_world(root, data)


func _copy(data: Variant) -> Dictionary:
	return (data as Dictionary).duplicate(true)


func _index(d: Dictionary) -> Dictionary:
	var out := {}
	for s: Dictionary in d["submaps"]:
		out[Vector3i(s["pos"][0], s["pos"][1], s["pos"][2])] = s
	return out


## Sets `key` (light / vis) of bubble tile t (x, y 0..131, absolute z).
func _set_tile(d: Dictionary, idx: Dictionary, t: Vector3i, key: String, v: int) -> void:
	var o: Array = d["bubble_origin"]
	var sm: Dictionary = idx[Vector3i(int(o[0]) + t.x / 12, int(o[1]) + t.y / 12, t.z)]
	sm[key][(t.y % 12) * 12 + t.x % 12] = v


## The mock at night: natural light 2, every tile at light 2 and in sight.
func _night(data: Variant) -> Dictionary:
	var d := _copy(data)
	d["env"]["ambient_light"] = 2
	d["env"]["sun_alt_deg"] = -30.0
	for s: Dictionary in d["submaps"]:
		for i in 144:
			s["light"][i] = 2
			s["vis"][i] = 2
	return d


## A lamp: `v` at bubble tile t, half of it on the 8 tiles around.
func _lamp(d: Dictionary, idx: Dictionary, t: Vector3i, v: int) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			_set_tile(d, idx, t + Vector3i(dx, dy, 0), "light", v if dx == 0 and dy == 0 else v / 2)


func _test_parse(data: Variant) -> void:
	var snap := Snapshot.from_data(data)
	_check.call(snap.ambient_light == 114 and not snap.has_lights, "light: mock env.ambient_light read, no lights list")
	var d := _copy(data)
	(d["env"] as Dictionary).erase("ambient_light")
	var no_amb := Snapshot.from_data(d)
	_check.call(no_amb.is_valid() and no_amb.ambient_light == -1 and LightMap.natural_light(no_amb) == 100,
			"light: no ambient_light -> -1, natural light guessed from the sun (day 100)")
	d["env"]["sun_alt_deg"] = -30.0
	_check.call(LightMap.natural_light(Snapshot.from_data(d)) == 2, "light: and 2 at night")
	for bad: Variant in [256, -1, 1.5, "10", null]:
		var b := _copy(data)
		b["env"]["ambient_light"] = bad
		var s := Snapshot.from_data(b)
		_check.call(not s.is_valid() and s.submaps.is_empty(), "light: rejects ambient_light %s (%s)" % [bad, s.error])

	var g := _copy(data)
	g["submaps"][0]["lights"] = [[5, 40, 0], [143, 255, 2], [0, 0, 1]]
	g["submaps"][1]["lights"] = []
	var ok := Snapshot.from_data(g)
	var sm: Snapshot.Submap = ok.submaps.get(Vector3i(11, 27, -1)) if ok.is_valid() else null
	_check.call(ok.is_valid() and ok.has_lights and sm != null
			and sm.lights == PackedInt32Array([5, 40, 0, 143, 255, 2, 0, 0, 1]),
			"light: lights list read [tile, luminance, kind] (%s)" % ok.error)
	var many := []
	for i in Snapshot.MAX_LIGHTS_PER_SUBMAP + 1:
		many.append([i, 10, 0])
	for bad: Variant in [{}, null, "x", many, [[144, 1, 0]], [[-1, 1, 0]], [[0, 256, 0]], [[0, -1, 0]], [[0, 1, 3]],
			[[0, 1]], [[0, 1, 0, 0]], [["a", 1, 0]], [[0, 1.5, 0]], [5]]:
		var b := _copy(data)
		b["submaps"][0]["lights"] = bad
		var s := Snapshot.from_data(b)
		_check.call(not s.is_valid() and s.submaps.is_empty(), "light: rejects lights %s (%s)" % [str(bad).left(40), s.error])


func _test_atlas(data: Variant) -> void:
	var d := _copy(data)
	var idx := _index(d)
	_set_tile(d, idx, Vector3i(65, 67, 1), "light", 200)
	_set_tile(d, idx, Vector3i(65, 67, 1), "vis", 3)
	_set_tile(d, idx, Vector3i(0, 0, -1), "light", 77)
	_set_tile(d, idx, Vector3i(0, 0, -1), "vis", 1)
	_set_tile(d, idx, Vector3i(131, 131, 0), "light", 9)
	_set_tile(d, idx, Vector3i(131, 131, 0), "vis", 2)
	var snap := Snapshot.from_data(d)
	var t0 := Time.get_ticks_usec()
	var m := LightMap.build(snap)
	print("        light map with LUT built in %d us" % (Time.get_ticks_usec() - t0))
	_check.call(m.image.get_size() == Vector2i(264, 396) and m.image.get_format() == Image.FORMAT_R8
			and m.z_lo == -1 and m.levels == 3, "light: atlas 264 x 132*3 (light | vis), levels -1..1")
	var raw := m.image.get_data()
	var row := (2 * 132 + 67) * 264
	_check.call(raw[row + 65] == 200 and raw[row + 65 + 132] == 3 and m.texel(65, 67, 1) == Vector2i(200, 3),
			"light: tile (65, 67) of level 1 at column 65, row 2*132 + 67, its vis 132 columns right")
	_check.call(m.texel(0, 0, -1) == Vector2i(77, 1) and m.texel(131, 131, 0) == Vector2i(9, 2),
			"light: the corner tiles of levels -1 and 0")
	_check.call(m.texel(64, 67, 1) != Vector2i(200, 3) and m.texel(65, 67, 0) != Vector2i(200, 3),
			"light: neighbours and other levels keep their own")
	_check.call(m.texel(132, 0, 0) == Vector2i(-1, -1) and m.texel(0, 0, 2) == Vector2i(-1, -1), "light: off the atlas")
	_check.call(m.lut != null and m.lut.get_size() == Vector2i(256, 4)
			and m.lut.get_pixel(200, 2).is_equal_approx(LightMap.tile_color(200, 2, 114))
			and m.lut.get_pixel(4, 3).is_equal_approx(LightMap.tile_color(4, 3, 114)), "light: LUT is tile_color by (light, vis)")
	_check.call(LightMap.build(snap, false).lut == null, "light: no LUT when not asked")
	_check.call(m.sources.size() == 1 and m.sources[0].square == Vector3i(197, 391, 1),
			"light: the bright tile a level up is a lamp")
	var day := LightMap.build(Snapshot.from_data(data))
	_check.call(day.ambient == 114 and day.sky.is_equal_approx(Color.WHITE) and day.sources.is_empty(),
			"light: day mock: full sky, no lamps")


func _test_curve() -> void:
	var mono := true
	var prev := -1.0
	for i in 2560:
		var v := LightMap.brightness(i * 0.1)
		mono = mono and v >= prev
		prev = v
	_check.call(mono, "light: brightness never falls as light rises")
	_check.call(is_equal_approx(LightMap.brightness(0.0), 0.03) and is_equal_approx(LightMap.brightness(3.5), 0.25)
			and is_equal_approx(LightMap.brightness(10.0), 0.6) and is_equal_approx(LightMap.brightness(50.0), 1.0)
			and is_equal_approx(LightMap.brightness(255.0), 1.0), "light: curve 0.03 at 0, 0.25 at 3.5, 0.6 at 10, 1 from 50")
	_check.call(is_equal_approx(LightMap.brightness(-5.0), 0.03) and is_equal_approx(LightMap.brightness(NAN), 0.03), "light: negative and NaN are dark")
	var tb := func(light: float, vis: int) -> float: return LightMap.tile_brightness(light, vis)
	_check.call(tb.call(200.0, 3) == LightMap.DARK and tb.call(0.0, 3) == LightMap.DARK,
			"light: vis 3 (too dark) is night-dark")
	_check.call(tb.call(30.0, 1) < tb.call(30.0, 2) and tb.call(30.0, 1) > 0.5 * tb.call(30.0, 2)
			and tb.call(0.0, 1) >= LightMap.DARK, "light: remembered is a little dimmer")
	_check.call(is_equal_approx(tb.call(114.0, 0), 1.0) and tb.call(4.0, 0) < 0.06 and tb.call(4.0, 2) > 0.25,
			"light: never seen: daylight shows, dim light fades to dark")
	var day: Color = LightMap.tile_color(114, 2, 114)
	var lamp: Color = LightMap.tile_color(40, 2, 2)
	var moon: Color = LightMap.tile_color(3, 2, 2)
	var indoor: Color = LightMap.tile_color(30, 2, 114)
	_check.call(day.is_equal_approx(Color.WHITE), "light: daylight leaves the scene as it is")
	_check.call(lamp.r > lamp.g and lamp.g > lamp.b and lamp.r > 0.7, "light: lamplight at night is warm %s" % lamp)
	_check.call(moon.b > moon.r and moon.b < 0.3, "light: moonlight is dim and cool %s" % moon)
	_check.call(is_equal_approx(indoor.r, indoor.b), "light: a dim room by day isn't tinted")
	_check.call(LightMap.sky_color(114).is_equal_approx(Color.WHITE) and LightMap.sky_color(2).b < 0.05
			and LightMap.sky_color(20).b > LightMap.sky_color(5).b, "light: sky full by day, dark at night")
	_check.call(LightMap.light_range(1) == 2.0 and LightMap.light_range(1e6) == 14.0
			and LightMap.light_range(60) > LightMap.light_range(20) and LightMap.light_energy(200) <= 2.0,
			"light: lamp range and energy grow with luminance, capped")


func _test_sources(data: Variant) -> void:
	# The player stands on bubble tile (60, 60) of level 0.
	var d := _night(data)
	var idx := _index(d)
	var offsets := [Vector2i(3, 0), Vector2i(0, 5), Vector2i(-7, 0), Vector2i(0, -9), Vector2i(11, 0),
			Vector2i(0, 13), Vector2i(-15, 0), Vector2i(0, -17), Vector2i(19, 0), Vector2i(0, 21)]
	for o: Vector2i in offsets:
		_lamp(d, idx, Vector3i(60 + o.x, 60 + o.y, 0), 60)
	_set_tile(d, idx, Vector3i(57, 57, 0), "light", 11)   # 9 over the natural light: too weak
	var snap := Snapshot.from_data(d)
	var t0 := Time.get_ticks_usec()
	var m := LightMap.build(snap)
	print("        light map with sources built in %d us" % (Time.get_ticks_usec() - t0))
	var got := m.sources.map(func(s: LightMap.Source) -> Vector3i: return s.square)
	var want := offsets.slice(0, 8).map(func(o: Vector2i) -> Vector3i: return Vector3i(192 + o.x, 384 + o.y, 0))
	_check.call(got == want, "light: the 8 nearest lamps, nearest first %s" % [got])
	_check.call(m.sources.all(func(s: LightMap.Source) -> bool: return s.luminance == 60 and s.kind == LightMap.KIND_GUESSED),
			"light: guessed sources carry their light")

	var one := _night(data)
	var oi := _index(one)
	_lamp(one, oi, Vector3i(60 + LightMap.SOURCE_RADIUS + 5, 60, 0), 60)   # too far
	_lamp(one, oi, Vector3i(62, 60, 1), 40)                                # a level up
	_set_tile(one, oi, Vector3i(50, 50, 0), "light", 50)                   # two equal tiles side by side
	_set_tile(one, oi, Vector3i(51, 50, 0), "light", 50)
	m = LightMap.build(Snapshot.from_data(one))
	got = m.sources.map(func(s: LightMap.Source) -> Vector3i: return s.square)
	_check.call(got == [Vector3i(194, 384, 1), Vector3i(182, 374, 0)] and m.sources[0].dist2 == 4 + 9,
			"light: a lamp a level up counts, one of two equal tiles, none past the radius %s" % [got])

	var listed := _night(data)
	var li := _index(listed)
	_lamp(listed, li, Vector3i(63, 60, 0), 60)   # ignored: the list wins
	(li[Vector3i(21, 37, 0)] as Dictionary)["lights"] = [[0, 90, 2]]
	m = LightMap.build(Snapshot.from_data(listed))
	_check.call(m.sources.size() == 1 and m.sources[0].square == Vector3i(252, 444, 0) and m.sources[0].kind == 2
			and m.sources[0].luminance == 90, "light: the bridge's lights list is used instead of guessing")
	for pos: Vector3i in [Vector3i(16, 32, 0), Vector3i(17, 32, 0), Vector3i(15, 33, 1)]:
		var l := []
		for t in 16:
			l.append([t, 30, 0])
		(li[pos] as Dictionary)["lights"] = l
	m = LightMap.build(Snapshot.from_data(listed))
	var sorted := true
	for i in range(1, m.sources.size()):
		sorted = sorted and m.sources[i - 1].dist2 <= m.sources[i].dist2
	_check.call(m.sources.size() == LightMap.MAX_SOURCES and sorted and m.sources[0].square == Vector3i(192, 384, 0),
			"light: 49 listed lights -> the 8 nearest")


func _test_world(root: Node, data: Variant) -> void:
	var d := _night(data)
	var idx := _index(d)
	_lamp(d, idx, Vector3i(63, 60, 0), 60)
	var world := WorldView.new()
	root.add_child(world)
	var lit := world.lighting
	_check.call(not lit.pass_visible() and lit.lamps().is_empty(), "light: nothing shown before a snapshot")
	world.apply_snapshot(Snapshot.from_data(d))
	var lamps := lit.lamps()
	_check.call(lit.pass_visible() and lit.levels == 3 and lit.lut_ambient == 2 and lit.ambient == 2,
			"light: the pass shows the night snapshot")
	_check.call(lamps.size() == 1 and lamps[0].visible
			and lamps[0].position == world.coords.ms_center_to_world(Vector3i(195, 384, 0)) + Vector3(0, 1.5, 0)
			and is_equal_approx(lamps[0].omni_range, LightMap.light_range(60)), "light: an OmniLight on the lamp")
	world.apply_snapshot(Snapshot.from_data(data))
	_check.call(lit.ambient == 114 and lit.lut_ambient == 114 and lit.lamps().is_empty(), "light: by day, no lamps")
	lit.min_brightness = 3.0
	_check.call(lit.min_brightness == 1.0, "light: minimum brightness clamps to 1")
	lit.enabled = false
	_check.call(not lit.pass_visible(), "light: off hides the pass")
	world.apply_snapshot(Snapshot.from_data(d))
	_check.call(lit.ambient == 114 and lit.lamps().is_empty(), "light: off: snapshots don't build light maps")
	world.free()
