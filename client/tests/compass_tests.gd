extends RefCounted
## Compass checks, run by run_tests.gd: bearings, creatures from the snapshot (attitude, malformed input),
## hostile and other markers (kind, order, caps), and the opacity setting (HudSettings, the F1 slider, user://).

const TEST_FILE := "user://test_hud.cfg"

var _check: Callable


func run(root: Node, check: Callable, data: Variant) -> void:
	_check = check
	print("compass")
	_test_bearings()
	_test_hostiles(data)
	_test_opacity(root)


func _test_bearings() -> void:
	var o := Vector3(3, 0, 5)
	var got := []
	for to: Vector3 in [Vector3(3, 0, 0), Vector3(8, 0, 5), Vector3(3, 0, 9), Vector3(-1, 0, 5), Vector3(4, 7, 4)]:
		got.append(snappedf(Compass.bearing_deg(o, to), 0.01))
	_check.call(got == [0.0, 90.0, 180.0, 270.0, 45.0], "compass: bearings N E S W, NE ignoring height %s" % [got])
	_check.call(is_equal_approx(Compass.strip_pos(90.0, 0.0), 1.0) and is_equal_approx(Compass.strip_pos(0.0, 90.0), -1.0)
			and is_equal_approx(Compass.strip_pos(0.0, 0.0), 0.0), "compass: strip ends at +-90 degrees, centre ahead")
	_check.call(is_equal_approx(Compass.strip_pos(350.0, 10.0), -20.0 / 90.0)
			and is_equal_approx(Compass.strip_pos(10.0, 350.0), 20.0 / 90.0), "compass: bearings wrap through north")
	_check.call(absf(Compass.strip_pos(180.0, 0.0)) > 1.0 and Compass.strip_pos(200.0, 0.0) < -1.0,
			"compass: behind you is off the strip, on the nearer side")
	_check.call(Compass.nearness(0.0) == 1.0 and Compass.nearness(Compass.FAR_M / 2.0) == 0.5
			and Compass.nearness(Compass.FAR_M * 3.0) == 0.0, "compass: nearer markers count more")


func _creature(uid: int, kind: int, p: Vector3i, attitude: Variant = null) -> Dictionary:
	var c := {"uid": uid, "kind": kind, "type": 0, "pos": [p.x, p.y, p.z], "hp_frac": 255}
	if attitude != null:
		c["attitude"] = attitude
	return c


func _test_hostiles(data: Variant) -> void:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var me: Dictionary = d["creatures"][0]
	var pp: Array = d["player"]["pos"]
	var p := Vector3i(int(pp[0]), int(pp[1]), int(pp[2]))
	var M := Snapshot.Creature.MONSTER
	var N := Snapshot.Creature.NPC
	d["creatures"] = [me,
			_creature(10, M, p + Vector3i(0, -3, 0)),        # zombie 3 north, no attitude -> hostile
			_creature(11, N, p + Vector3i(2, 0, 0)),         # NPC, no attitude -> not
			_creature(12, N, p + Vector3i(4, 0, 0), 0),      # hostile NPC 4 east
			_creature(13, M, p + Vector3i(0, 1, 0), 2),      # friendly dog
			_creature(14, M, p + Vector3i(-1, 0, 0), 1),     # neutral cat
			_creature(15, M, p + Vector3i(0, 10, 1), 0.0)]   # hostile, 10 south one level up (JSON numbers are floats)
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid() and snap.creatures.size() == 7, "compass: creatures with attitudes read (%s)" % snap.error)
	if not snap.is_valid():
		return
	var hostile := []
	for c in snap.creatures:
		if c.is_hostile():
			hostile.append(c.uid)
	_check.call(hostile == [10, 12, 15], "compass: hostile = attitude 0, or a monster when unsaid; not the player %s" % [hostile])
	var kinds := []
	for c in snap.creatures:
		kinds.append(Compass.marker_kind(c))
	_check.call(kinds == [-1, 0, 1, 0, 2, 1, 0], "compass: marker kinds, unknown NPC neutral, player none %s" % [kinds])
	var coords := CddaCoords.new()
	coords.set_bubble_origin(snap.bubble_origin)
	var from := coords.ms_center_to_world(p)
	var blips := Compass.creature_blips(snap, from, coords.ms_center_to_world)
	var want: Array[Vector3] = [Vector3(0, 3, 0), Vector3(90, 4, 0), Vector3(180, 10, 0),   # hostiles, nearest first
			Vector3(180, 1, 2), Vector3(270, 1, 1), Vector3(90, 2, 1)]                      # then the others
	var ok := blips.size() == want.size()
	for i in mini(blips.size(), want.size()):
		ok = ok and blips[i].is_equal_approx(want[i])
	_check.call(ok, "compass: markers at bearing and distance, hostiles then others, nearest first %s" % [blips])
	_check.call(Compass.creature_blips(null, from, coords.ms_center_to_world).is_empty(), "compass: no snapshot, no markers")
	# Other levels: level_blips / creature_blip_levels add the level offset, in creature_blips' order.
	var lb := Compass.level_blips(snap, from, coords.ms_center_to_world)
	var levels := Compass.creature_blip_levels(snap, from, coords.ms_center_to_world)
	var same := lb.size() == blips.size() and levels.size() == blips.size()
	for i in mini(lb.size(), mini(blips.size(), levels.size())):
		same = same and Vector3(lb[i].x, lb[i].y, lb[i].z) == blips[i] and int(lb[i].w) == levels[i]
	_check.call(same and levels == PackedInt32Array([0, 0, 1, 0, 0, 0]),
			"compass: level offsets in the markers' order, the zombie one up is +1 %s" % [levels])
	_check.call(Compass.level_blips(null, from, coords.ms_center_to_world).is_empty()
			and Compass.creature_blip_levels(null, from, coords.ms_center_to_world).is_empty(), "compass: no snapshot, no levels")
	var up := Compass.level_ticks(Vector2(10, 10), 1)
	var down := Compass.level_ticks(Vector2(10, 10), -3)
	_check.call(Compass.level_ticks(Vector2(10, 10), 0).is_empty() and up.size() == 1 and down.size() == 2
			and up[0][1].y < up[0][0].y and down[0][1].y > down[0][0].y and down[1][1].y > down[0][1].y,
			"compass: no chevron on your level, one up for above, two down for 2+ below")
	var many := [me]
	for i in Compass.MAX_BLIPS + 20:
		many.append(_creature(100 + i, M, p + Vector3i(i + 1, 0, 0)))
		many.append(_creature(1000 + i, M, p + Vector3i(0, i + 1, 0), 2))
	d["creatures"] = many
	snap = Snapshot.from_data(d)
	blips = Compass.creature_blips(snap, from, coords.ms_center_to_world)
	var counts := [0, 0, 0]
	for b in blips:
		counts[int(b.z)] += 1
	_check.call(counts == [Compass.MAX_BLIPS, 0, Compass.MAX_OTHER_BLIPS] and is_equal_approx(blips[Compass.MAX_BLIPS - 1].y, Compass.MAX_BLIPS)
			and is_equal_approx(blips[-1].y, Compass.MAX_OTHER_BLIPS),
			"compass: only the nearest %d hostiles and %d others are drawn %s" % [Compass.MAX_BLIPS, Compass.MAX_OTHER_BLIPS, counts])
	for bad: Variant in ["hostile", 3, -1, 0.5, null, [0], INF]:
		var c := _creature(10, M, p, 0)
		c["attitude"] = bad
		d["creatures"] = [me, c]
		_check.call(not Snapshot.from_data(d).is_valid(), "compass: attitude %s refused" % str(bad))
	var cmp := Compass.new()
	var list: Array[Vector3] = [Vector3(10, 2, 0), Vector3(30, 5, 2)]
	var with_levels: Array[Vector4] = [Vector4(10, 2, 0, -1), Vector4(30, 5, 2, 0)]
	cmp.set_level_blips(with_levels)
	_check.call(cmp.blips == list and cmp.blip_levels == PackedInt32Array([-1, 0]), "compass: takes markers with levels")
	cmp.set_blips(list)
	_check.call(cmp.blips == list and cmp.blip_levels.is_empty(), "compass: takes the markers (all on your level)")
	cmp.free()


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_opacity(root: Node) -> void:
	_remove(TEST_FILE)
	var s := HudSettings.new()
	_check.call(s.load_file(TEST_FILE) == "" and s.compass_opacity == HudSettings.DEFAULT_COMPASS_OPACITY,
			"compass: no settings file, default opacity")
	s.compass_opacity = 0.35
	_check.call(s.save_file(TEST_FILE) == OK, "compass: opacity saved")
	var back := HudSettings.new()
	_check.call(back.load_file(TEST_FILE) == "" and is_equal_approx(back.compass_opacity, 0.35), "compass: opacity loads back")
	_check.call(HudSettings.clamp_opacity(3.0) == 1.0 and HudSettings.clamp_opacity(-2.0) == 0.0
			and HudSettings.clamp_opacity(NAN) == HudSettings.DEFAULT_COMPASS_OPACITY, "compass: opacity clamped, NaN -> default")
	var cases := {
		"[compass]\nopacity=7.5\n": 1.0,
		"[compass]\nopacity=\"half\"\n": HudSettings.DEFAULT_COMPASS_OPACITY,
		"[compass]\nopacity=Object(Node,\"name\":\"x\")\n": HudSettings.DEFAULT_COMPASS_OPACITY,
		"[compass\nopacity=": HudSettings.DEFAULT_COMPASS_OPACITY,
		"[compass]\nopacity=0.2\n" + " ".repeat(HudSettings.MAX_FILE_BYTES): HudSettings.DEFAULT_COMPASS_OPACITY,
	}
	for text: String in cases:
		_write(TEST_FILE, text)
		var h := HudSettings.new()
		var why := h.load_file(TEST_FILE)
		_check.call(is_equal_approx(h.compass_opacity, cases[text]), "compass: settings file %s -> %.2f (%s)" % [
				text.left(30).c_escape(), h.compass_opacity, why])
	# The F1 menu's slider: changes the setting, saves it, tells main.gd.
	_remove(TEST_FILE)
	var menu := KeyMenu.new()
	root.add_child(menu)
	var settings := HudSettings.new()
	menu.add_hud_settings(settings, TEST_FILE)
	var told := [0]
	menu.hud_changed.connect(func() -> void: told[0] += 1)
	menu.compass_slider.value_changed.emit(0.4)   # Godot 4.7: setting value from a script doesn't emit
	var again := HudSettings.new()
	again.load_file(TEST_FILE)
	_check.call(is_equal_approx(settings.compass_opacity, 0.4) and told[0] == 1 and is_equal_approx(again.compass_opacity, 0.4),
			"compass: the F1 slider sets, saves and reports the opacity")
	menu.open()
	_check.call(is_equal_approx(menu.compass_slider.value, 0.4), "compass: the slider shows the saved opacity")
	menu.free()
	var cmp := Compass.new()
	cmp.opacity = 0.3
	_check.call(is_equal_approx(cmp.modulate.a, 0.3), "compass: opacity fades the strip")
	cmp.free()
	_remove(TEST_FILE)
