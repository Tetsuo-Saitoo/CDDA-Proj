extends RefCounted
## Block C9 checks, run by run_tests.gd: the first-person camera (free walk on the mock town, live follow,
## look), the start view option, the default action map, and camera-relative CDDA move directions.

const Main := preload("res://scripts/main.gd")

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("first person")
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(world)
	world.set_id_tables(tables)
	world.apply_snapshot(Snapshot.from_data(data))
	_test_args()
	_test_actions()
	_test_look(world)
	_test_walk(world)
	_test_follow(world)
	_test_octants(world)
	_test_compass()
	_test_look_ray(world)
	_test_stairs(world)
	_test_stair_flights(world, data, tables)
	_test_cdda_keys()
	_test_rebinding(root)
	_test_creatures(root, world, data, tables)
	_test_player_body(root, data, tables)
	world.free()


func _test_args() -> void:
	_check.call(FirstPersonCamera.view_from_args({}) == "first", "fp: first person by default")
	_check.call(FirstPersonCamera.view_from_args({"view": "outside"}) == "outside", "fp: --view=outside")
	_check.call(FirstPersonCamera.view_from_args({"camera": "1,2,3,4,5"}) == "outside", "fp: --camera= starts outside")
	_check.call(FirstPersonCamera.view_from_args({"view": "first", "camera": "1,2,3,4,5"}) == "first",
			"fp: --view=first wins over --camera=")
	_check.call(FirstPersonCamera.view_from_args({"view": "top"}) == "first", "fp: a bad --view= keeps first person")


func _test_actions() -> void:
	InputActions.ensure(false)
	var all := true
	for a in InputActions.names():
		all = all and InputMap.has_action(a)
	_check.call(all, "fp: every default action exists")
	var w := InputMap.action_get_events(&"move_forward")
	_check.call(w.size() == 2 and w.any(func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_W),
			"fp: move_forward is W and the left stick")
	InputActions.ensure(false)
	_check.call(InputMap.action_get_events(&"move_forward").size() == 2, "fp: ensure twice adds nothing")
	InputMap.erase_action(&"view_toggle")
	InputMap.add_action(&"view_toggle")
	var u := InputEventKey.new()
	u.physical_keycode = KEY_U
	InputMap.action_add_event(&"view_toggle", u)
	InputActions.ensure(false)
	var ev := InputMap.action_get_events(&"view_toggle")
	_check.call(ev.size() == 1 and ev[0].physical_keycode == KEY_U, "fp: a binding already there is kept")
	InputMap.erase_action(&"view_toggle")
	InputActions.ensure(false)


func _test_look(world: WorldView) -> void:
	var fp := FirstPersonCamera.new(world)
	fp.set_look(0.0, 0.0)
	_check.call(fp.forward().is_equal_approx(Vector3.FORWARD) and (-fp.basis.z).is_equal_approx(fp.forward()),
			"fp: yaw 0 looks north (-Z)")
	fp.set_look(PI / 2, 0.0)
	_check.call(fp.forward().is_equal_approx(Vector3.LEFT) and fp.right().is_equal_approx(Vector3.FORWARD),
			"fp: yaw 90 looks west, right is north")
	fp.set_look(0.0, 3.0)
	_check.call(fp.pitch == FirstPersonCamera.PITCH_MAX, "fp: pitch is clamped")
	fp.set_look(0.0, 0.0)
	fp.look(Vector2(100, 0))
	_check.call(is_equal_approx(fp.yaw, -100 * fp.sensitivity), "fp: mouse right turns right")
	fp.set_look(0.0, 0.0)
	fp.step(0.1, {"look": Vector2(0, 1)})
	_check.call(fp.pitch < 0.0, "fp: right stick down looks down")
	fp.free()


## First square on level 0 of terrain kind `kind` whose west neighbour is standable.
func _find_west_free(world: WorldView, w: VrWalk, kind: int) -> Variant:
	for pos: Vector3i in world.snapshot.submaps:
		if pos.z != 0:
			continue
		var sm: Snapshot.Submap = world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if world.catalog.style_for(sm.ter[i]).kind != kind:
				continue
			var p := CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
			if w.can_stand(p - Vector3i(1, 0, 0)):
				return p
	return null


func _test_walk(world: WorldView) -> void:
	var fp := FirstPersonCamera.new(world)
	var player := world.snapshot.player_pos
	fp.go_to_square(player)
	var eye := world.coords.ms_center_to_world(player) + Vector3(0, FirstPersonCamera.EYE_H, 0)
	_check.call(fp.position.is_equal_approx(eye) and fp.z == player.z and not fp.follow,
			"fp: eyes 1.6 m above the player's square")
	var K := TerrainCatalog.Kind
	var wall: Variant = _find_west_free(world, fp.walk, K.WALL)
	_check.call(wall != null, "fp: the mock has a wall with a free square west of it")
	if wall != null:
		fp.go_to_square(wall - Vector3i(1, 0, 0))
		fp.set_look(-PI / 2, 0.4)   # east, looking a little up: pitch must not slow the walk
		var y := fp.position.y
		for i in 20:
			fp.step(0.05, {"move": Vector2(0, 1)})
		var wall_x := world.coords.ms_to_world(wall).x
		_check.call(fp.position.x <= wall_x - VrWalk.BODY_R + 0.001 and fp.position.x > wall_x - 0.5,
				"fp: walking into a wall stops before it")
		_check.call(fp.position.y == y, "fp: walking keeps the eye height")
	var door: Variant = _find_west_free(world, fp.walk, K.DOOR)
	_check.call(door != null, "fp: the mock has a door with a free square west of it")
	if door != null:
		var start: Vector3i = door - Vector3i(1, 0, 0)
		world.door_open[door] = false
		fp.go_to_square(start)
		fp.set_look(-PI / 2, 0.0)
		var x0 := fp.position.x
		for i in 5:
			fp.step(0.05, {"move": Vector2(0, 1)})
		_check.call(fp.position.x - x0 < 0.5 and fp.walk.square_at(fp.position, 0) == start,
				"fp: a closed door stops you")
		world.door_open[door] = true   # dragged open
		fp.go_to_square(start)
		for i in 5:
			fp.step(0.05, {"move": Vector2(0, 1)})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75) and fp.walk.square_at(fp.position, 0) == door,
				"fp: walks through an open door")
		fp.go_to_square(start)
		fp.step(0.1, {"move": Vector2(0, 1), "fast": true})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75), "fp: fast walks 2.5x")
		fp.go_to_square(start)
		for i in 5:
			fp.step(0.05, {"move": Vector2(0, 5)})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75), "fp: stick input past 1 is cut to 1")
		world.door_open.erase(door)
	fp.go_to_square(player)
	var z0 := fp.z
	_check.call(not fp.change_level(5) and fp.z == z0 and fp.position.is_equal_approx(eye),
			"fp: no level change to a level not loaded")
	if fp.change_level(1):
		_check.call(fp.z == z0 + 1 and is_equal_approx(fp.position.y, VrWalk.floor_y(z0 + 1) + FirstPersonCamera.EYE_H)
				and fp.walk.can_stand(fp.walk.square_at(fp.position, fp.z)), "fp: level up lands on a free square")
		_check.call(fp.change_level(-1) and fp.z == z0, "fp: and back down")
	else:
		_check.call(fp.z == z0, "fp: level up refused keeps the level")
	fp.free()


func _test_follow(world: WorldView) -> void:
	var fp := FirstPersonCamera.new(world)
	var p := world.snapshot.player_pos
	var eye := world.coords.ms_center_to_world(p) + Vector3(0, FirstPersonCamera.EYE_H, 0)
	fp.follow_square(p)
	_check.call(fp.follow and fp.position.is_equal_approx(eye), "fp: live view starts on the player's square")
	var next := p + Vector3i(1, 0, 0)
	fp.follow_square(next)
	_check.call(fp.position.is_equal_approx(eye), "fp: a one-square step glides, no jump")
	var before := fp.position.distance_to(fp.target)
	fp.step(0.05, {"move": Vector2(0, 1)})
	var after := fp.position.distance_to(fp.target)
	_check.call(after < before and after > 0.1, "fp: the camera glides toward the player")
	for i in 40:
		fp.step(0.05, {"move": Vector2(-1, 0)})
	_check.call(fp.position.distance_to(fp.target) < 0.01, "fp: and arrives; walking keys don't move it")
	fp.follow_square(p + Vector3i(0, 0, 1))
	_check.call(fp.z == p.z + 1, "fp: follows the player's level")
	fp.follow_square(p + Vector3i(10, 0, 0))
	_check.call(fp.position.is_equal_approx(fp.target), "fp: a long move jumps")
	var d := Vector3(132, 0, -12)
	var t := fp.target
	fp.shift(d)
	_check.call(fp.target.is_equal_approx(t + d) and fp.position.is_equal_approx(t + d), "fp: map shift moves with the origin")
	fp.free()


func _test_octants(world: WorldView) -> void:
	var acts: Array = Main.OCT_ACTIONS
	var fwd := Vector2(0, 1)
	_check.call(acts[Main.octant_for(Basis(), fwd)] == "UP" and acts[Main.octant_for(Basis(), Vector2(1, 0))] == "RIGHT"
			and acts[Main.octant_for(Basis(), Vector2(1, 1))] == "RIGHTUP", "fp: looking north, W is UP, D is RIGHT")
	var west := Basis(Vector3.UP, PI / 2)
	_check.call(acts[Main.octant_for(west, fwd)] == "LEFT" and acts[Main.octant_for(west, Vector2(1, 0))] == "UP",
			"fp: looking west, W is LEFT, D is UP")
	_check.call(acts[Main.octant_for(Basis(Vector3.RIGHT, -PI / 2), fwd)] == "UP", "fp: looking straight down, W is up on screen")
	var fp := FirstPersonCamera.new(world)
	fp.set_look(-PI * 3 / 4, -0.5)   # south-east, looking down a bit
	_check.call(acts[Main.octant_for(fp.basis, fwd)] == "RIGHTDOWN" and acts[Main.octant_for(fp.basis, Vector2(0, -1))] == "LEFTUP",
			"fp: steps follow where the first-person camera looks")
	fp.free()


func _test_compass() -> void:
	var ok := true
	for want: float in [0.0, 90.0, 180.0, 270.0]:
		var b := Basis(Vector3.UP, deg_to_rad(-want))   # yaw: turning right from north (-z)
		ok = ok and is_equal_approx(fposmod(Compass.heading_of(b) - want + 180.0, 360.0) - 180.0, 0.0)
	_check.call(ok, "look: compass reads N/E/S/W (-z is north)")
	var down := Basis.from_euler(Vector3(-PI / 2, 0, 0))   # looking straight down, north up on screen
	_check.call(is_equal_approx(Compass.heading_of(down), 0.0), "look: compass looking straight down")


func _test_look_ray(world: WorldView) -> void:
	var lr := LookRay.new(world)
	var p := world.snapshot.player_pos
	var above := world.coords.ms_center_to_world(p) + Vector3(0, 1.6, 0)
	var r := lr.cast(above, Vector3.DOWN)
	_check.call(r["hit"] and r["what"] == "floor" and r["square"] == p, "look: straight down hits the floor you stand on (%s)" % r)
	var lines := lr.describe(p)
	_check.call(lines.size() >= 2 and lines[0].begins_with("terrain: ") and not lines[0].contains("#"),
			"look: describes the terrain by name (%s)" % lines)
	var pair := _wall_and_floor_next_to_it(world, lr, p)
	_check.call(not pair.is_empty(), "look: the mock town has a wall next to an empty floor near the player")
	if not pair.is_empty():
		var w: Vector3i = pair[0]
		var f: Vector3i = pair[1]
		var h := lr.cast(world.coords.ms_center_to_world(f) + Vector3(0, 1.5, 0), Vector3(w.x - f.x, 0, w.y - f.y))
		_check.call(h["hit"] and h["what"] == "wall" and h["square"] == w, "look: a level look meets the wall in front (%s)" % h)
	_check.call(not lr.cast(above, Vector3.UP * 0.0)["hit"], "look: no direction, no hit")


func _test_cdda_keys() -> void:
	InputActions.ensure(false)
	var ok := true
	for a: StringName in InputActions.CDDA:
		ok = ok and not InputActions.info(a).is_empty()
	_check.call(ok, "keys: every CDDA action is in the action list")
	# Walking, steps, hands and CDDA actions are all read in a live game: no default key may be shared.
	var seen := {}
	var clash := PackedStringArray()
	for a: Array in InputActions.ACTIONS:
		if a[0] in [&"fly_up", &"fly_down", &"move_fast"]:
			continue   # outside view only (E/Q also fly there: TASKS leftover)
		for t: String in a[3]:
			if seen.has(t):
				clash.append("%s: %s and %s" % [t, seen[t], a[0]])
			seen[t] = a[0]
	_check.call(clash.is_empty(), "keys: no two actions share a default key %s" % clash)
	var round_trip := true
	for a in InputActions.names():
		for t: String in InputActions.info(a)[3]:
			var e := InputActions.parse_event(t)
			round_trip = round_trip and e != null and InputActions.event_text(e) == t
	_check.call(round_trip, "keys: every default key reads back to the same text")
	var eat := InputEventKey.new()
	eat.physical_keycode = KEY_E
	eat.shift_pressed = true
	eat.pressed = true
	_check.call(InputActions.pressed(eat, &"cdda_eat") and not InputActions.pressed(eat, &"cdda_examine"),
			"keys: Shift+E is eat, not examine")
	var bang := eat.duplicate() as InputEventKey
	bang.physical_keycode = KEY_1
	_check.call(InputActions.pressed(bang, &"cdda_safemode") and not InputActions.pressed(bang, &"hand_off"),
			"keys: Shift+1 is safe mode, not the left hand")


## Rebinding: hostile key files, save/load, and the key menu.
func _test_rebinding(root: Node) -> void:
	var path := preload("res://tests/test_dir.gd").path("keys_test.json")
	InputActions.reset_all()
	for t: String in ["", "Nope", "mouse:0", "mouse:99", "pad:-1", "pad:x", "axis:9+", "axis:1*", "Shift+",
			"Shift+Nope", "w", "A".repeat(50)]:
		_check.call(InputActions.parse_event(t) == null, "keys: \"%s\" is refused" % t.left(12))
	var sx := InputActions.parse_event("Shift+X")
	_check.call(sx is InputEventKey and sx.shift_pressed and sx.physical_keycode == KEY_X, "keys: Shift+X reads")
	var shift_key := InputEventKey.new()
	shift_key.physical_keycode = KEY_SHIFT
	shift_key.shift_pressed = true
	_check.call(InputActions.event_text(InputActions.binding_from(shift_key)) == "Shift",
			"keys: Shift pressed alone binds without a modifier")
	# Save writes only what changed; load brings it back.
	var x: Array[InputEvent] = [InputActions.parse_event("Y")]
	InputActions.set_slots(&"cdda_examine", x)
	_check.call(InputActions.save_bindings(path) == "", "keys: saved")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check.call(saved is Dictionary and saved["actions"].keys() == ["cdda_examine"], "keys: only changed actions are written")
	InputActions.reset_all()
	_check.call(InputActions.load_bindings(path).is_empty() and InputActions.key_of(&"cdda_examine") == "Y"
			and InputActions.key_of(&"move_forward") == "W", "keys: loaded back, others keep their defaults")
	# A hostile file: unknown actions, junk entries, a non-list; only good entries are used.
	InputActions.reset_all()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"actions": {"bogus": ["W"], "cdda_wield": ["Nope", 5, "K", "K"],
			"move_back": "S", "../x": []}}))
	f.close()
	var bad := InputActions.load_bindings(path)
	_check.call(bad.size() == 5 and InputActions.key_of(&"cdda_wield") == "K"
			and InputActions.slots(&"cdda_wield").size() == 1 and InputActions.key_of(&"move_back") == "S",
			"keys: a hostile file only gives its good entries (%s)" % ", ".join(bad))
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[" + "1,".repeat(InputActions.MAX_FILE_BYTES / 2) + "1]")
	f.close()
	_check.call(InputActions.load_bindings(path).size() == 1, "keys: an oversized file is ignored")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	_check.call(InputActions.load_bindings(path).size() == 1, "keys: a broken file is ignored")
	# The menu: click a slot, press a key.
	InputActions.reset_all()
	var menu := KeyMenu.new()
	menu.save_path = path
	root.add_child(menu)
	menu.open()
	menu.start_capture(&"cdda_wield", 0)
	var k := InputEventKey.new()
	k.physical_keycode = KEY_Y
	k.pressed = true
	_check.call(menu.take(k) and InputActions.key_of(&"cdda_wield") == "Y", "keys menu: a pressed key binds")
	menu.start_capture(&"cdda_wield", 1)
	var ctrl := InputEventKey.new()
	ctrl.physical_keycode = KEY_CTRL
	ctrl.ctrl_pressed = true
	ctrl.pressed = true
	menu.take(ctrl)
	k.ctrl_pressed = true
	menu.take(k)
	var texts := []
	for e in InputActions.slots(&"cdda_wield"):
		texts.append(InputActions.event_text(e))
	_check.call(texts == ["Y", "Ctrl+Y"], "keys menu: Ctrl+Y goes in the second slot (%s)" % [texts])
	menu.start_capture(&"cdda_wield", 0)
	var bs := InputEventKey.new()
	bs.physical_keycode = KEY_BACKSPACE
	bs.pressed = true
	menu.take(bs)
	_check.call(InputActions.key_of(&"cdda_wield") == "Ctrl+Y", "keys menu: Backspace clears a slot")
	menu.start_capture(&"cdda_wield", 0)
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	menu.take(esc)
	_check.call(InputActions.key_of(&"cdda_wield") == "Ctrl+Y" and menu.visible, "keys menu: Esc cancels a capture")
	saved = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check.call(saved is Dictionary and saved["actions"].get("cdda_wield") == ["Ctrl+Y"], "keys menu: each change is saved")
	menu.take(esc)
	_check.call(not menu.visible, "keys menu: Esc closes")
	_test_pad_rebinding(menu, path)
	menu.free()
	InputActions.reset_all()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## The key menu's pad column: pad buttons and pushed sticks bind there (saved, loaded back), nothing else does.
func _test_pad_rebinding(menu: KeyMenu, path: String) -> void:
	var pad_texts := func(action: StringName) -> Array:
		return InputActions.pad_slots(action).map(func(e: InputEvent) -> String: return InputActions.event_text(e))
	menu.open()
	menu.start_capture(&"cdda_wield", KeyMenu.PAD_SLOT)
	var drift := InputEventJoypadMotion.new()
	drift.axis = JOY_AXIS_RIGHT_X
	drift.axis_value = 0.2
	var nan := drift.duplicate() as InputEventJoypadMotion
	nan.axis_value = NAN
	var y := InputEventKey.new()
	y.physical_keycode = KEY_Y
	y.pressed = true
	menu.take(drift)
	menu.take(nan)
	_check.call(menu.take(y) and pad_texts.call(&"cdda_wield").is_empty() and InputActions.key_of(&"cdda_wield") == "Ctrl+Y",
			"keys menu pad: stick drift, NaN and keys don't bind in the pad column")
	var btn := InputEventJoypadButton.new()
	btn.button_index = JOY_BUTTON_Y
	btn.pressed = true
	_check.call(menu.take(btn) and pad_texts.call(&"cdda_wield") == ["pad:3"] and InputActions.key_of(&"cdda_wield") == "Ctrl+Y"
			and (menu._buttons[&"cdda_wield"][KeyMenu.PAD_SLOT] as Button).text == "Pad Y",
			"keys menu pad: a pad button binds in the pad column, keys stay")
	menu.start_capture(&"cdda_wield", 0)
	_check.call(not menu.take(btn) and InputActions.key_of(&"cdda_wield") == "Ctrl+Y", "keys menu pad: a key slot ignores pad buttons")
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	menu.take(esc)
	menu.start_capture(&"move_forward", KeyMenu.PAD_SLOT)
	var push := InputEventJoypadMotion.new()
	push.axis = JOY_AXIS_RIGHT_Y
	push.axis_value = -0.9
	menu.take(push)
	var pads := InputActions.pad_slots(&"move_forward")
	_check.call(pad_texts.call(&"move_forward") == ["axis:3-"] and InputActions.key_of(&"move_forward") == "W"
			and InputActions.event_label(pads[0]) == "R stick up" and InputActions.users_of(pads[0], &"move_forward") == [&"look_up"],
			"keys menu pad: the right stick pushed up replaces the left stick, W stays (also look up) %s" % [pad_texts.call(&"move_forward")])
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check.call(saved is Dictionary and saved["actions"].get("cdda_wield") == ["Ctrl+Y", "pad:3"]
			and saved["actions"].get("move_forward") == ["W", "axis:3-"], "keys menu pad: saved in the same key file")
	InputActions.reset_all()
	_check.call(InputActions.load_bindings(path).is_empty() and pad_texts.call(&"cdda_wield") == ["pad:3"]
			and pad_texts.call(&"move_forward") == ["axis:3-"] and InputActions.key_of(&"cdda_wield") == "Ctrl+Y",
			"keys menu pad: loaded back")
	menu.start_capture(&"move_forward", KeyMenu.PAD_SLOT)
	var bs := InputEventKey.new()
	bs.physical_keycode = KEY_BACKSPACE
	bs.pressed = true
	menu.take(bs)
	_check.call(pad_texts.call(&"move_forward").is_empty() and InputActions.key_of(&"move_forward") == "W",
			"keys menu pad: Backspace clears the pad slot only")
	var up := btn.duplicate() as InputEventJoypadButton
	up.pressed = false
	var big := btn.duplicate() as InputEventJoypadButton
	big.button_index = 200 as JoyButton
	_check.call(InputActions.pad_binding_from(up) == null and InputActions.pad_binding_from(big) == null
			and InputActions.pad_binding_from(y) == null, "keys pad: releases, unknown buttons and keys make no pad binding")
	_check.call(InputActions.event_label(InputActions.parse_event("pad:10")) == "Pad R1"
			and InputActions.event_label(InputActions.parse_event("axis:5+")) == "R2"
			and InputActions.event_label(InputActions.parse_event("pad:20")) == "Pad 20", "keys pad: labels")
	menu.close()
	InputActions.reset_all()


## Nearest wall square on p's level with an empty floor square beside it: [wall, floor], or [].
func _wall_and_floor_next_to_it(world: WorldView, lr: LookRay, p: Vector3i) -> Array:
	var K := TerrainCatalog.Kind
	for r in range(1, 40):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var q := p + Vector3i(dx, dy, 0)
				var c := lr._cell(q)
				if c.is_empty() or world.catalog.style_for(c["ter"]).kind != K.WALL:
					continue
				for n: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0)]:
					var nc := lr._cell(q + n)
					if not nc.is_empty() and nc["furn"] == 0 and world.catalog.style_for(nc["ter"]).kind == K.FLOOR:
						return [q, q + n]
	return []


## Placeholder creatures: read from the snapshot, drawn as figures by body type, moved smoothly, animated by
## events, met by look; bad data is refused.
func _test_creatures(root: Node, world: WorldView, data: Variant, tables: IdTables) -> void:
	var zi := tables.index_of("mtype", "mon_zombie")
	var di := tables.index_of("mtype", "mon_dog_zombie_cop")
	_check.call(zi >= 0 and tables.mtype[zi].size == 3 and tables.mtype[zi].bodytype == "human"
			and tables.mtype[zi].species.has("ZOMBIE"), "creatures: mon_zombie is medium, human, a zombie")
	var P := CreatureFigure.Plan
	var plans := {}
	for id: String in ["mon_zombie", "mon_dog_zombie_cop", "mon_ant", "mon_rattlesnake", "mon_crow", "mon_blob",
			"mon_bear", "mon_fish_bluegill"]:
		var d := tables.def_named("mtype", id)
		plans[id] = CreatureFigure.plan_for(Snapshot.Creature.MONSTER, d) if d != null else -1
	_check.call(plans["mon_zombie"] == P.HUMANOID and plans["mon_dog_zombie_cop"] == P.QUADRUPED
			and plans["mon_ant"] == P.CRAWLER and plans["mon_rattlesnake"] == P.SNAKE and plans["mon_crow"] == P.FLYER
			and plans["mon_blob"] == P.BLOB and plans["mon_bear"] == P.QUADRUPED,
			"creatures: body plans from CDDA's body types %s" % plans)
	var old := IdTables.Def.new()   # an older bridge: no body type, species decide
	old.species = {"ZOMBIE": true, "MAMMAL": true}
	var odd := IdTables.Def.new()
	odd.bodytype = "apeirohedra"
	_check.call(CreatureFigure.plan_for(Snapshot.Creature.MONSTER, old) == P.QUADRUPED
			and CreatureFigure.plan_for(Snapshot.Creature.MONSTER, odd) == P.BLOB
			and CreatureFigure.plan_for(Snapshot.Creature.NPC, null) == P.HUMANOID,
			"creatures: no body type -> species (zombie mammal = four legs); unknown body type -> blob; NPC -> human")
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var pp: Array = d["player"]["pos"]
	var me: Dictionary = d["creatures"][0]
	var zp := Vector3i(int(pp[0]) + 1, int(pp[1]), int(pp[2]))
	var zuid := 8589934593
	var nuid := 4294967297
	var zombie := {"uid": zuid, "kind": 2, "type": zi, "pos": [zp.x, zp.y, zp.z], "hp_frac": 128}
	var npc := {"uid": nuid, "kind": 1, "type": 0, "pos": [zp.x - 1, zp.y + 1, zp.z], "hp_frac": 255}
	d["creatures"] = [me, zombie, npc]
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid() and snap.creatures.size() == 3, "creatures: read (%s)" % snap.error)
	if not snap.is_valid():
		return
	world.apply_snapshot(snap)
	var cv := CreatureView.new()
	root.add_child(cv)
	cv.apply(snap, world)
	_check.call(cv.count() == 2, "creatures: a figure each for the zombie and the NPC, none for the player in first person")
	cv.show_player = true
	_check.call(cv.count() == 3 and cv.figure(1) != null, "creatures: the player's own figure for the outside view")
	cv.show_player = false
	var z := cv.figure(zuid)
	var at := world.coords.ms_center_to_world(zp)
	var label := z.get_child(z.get_child_count() - 1) as Label3D if z != null else null
	_check.call(z != null and z.plan == P.HUMANOID and z.shamble and is_equal_approx(z.top, 1.75)
			and z.position.is_equal_approx(at) and label != null and label.text == "zombie",
			"creatures: the zombie is a 1.75 m shambling human figure on its square, named")
	var lr := LookRay.new(world)
	var eye := world.coords.ms_center_to_world(zp - Vector3i(1, 0, 0)) + Vector3(0, 1.0, 0)
	var h := lr.cast(eye, Vector3.RIGHT)
	_check.call(h["hit"] and h["what"] == "zombie" and h["square"] == zp, "creatures: look meets the zombie (%s)" % h)
	_check.call("creature: zombie, health 50%" in lr.describe(zp), "creatures: look names it with its health")
	# One square east: it walks there over the move time, turning to face east.
	zombie["pos"] = [zp.x + 1, zp.y, zp.z]
	var snap2 := Snapshot.from_data(d)
	world.apply_snapshot(snap2)
	cv.apply(snap2, world)
	var to := world.coords.ms_center_to_world(zp + Vector3i(1, 0, 0))
	_check.call(z.is_moving() and z.position.is_equal_approx(at), "creatures: a step starts a walk, not a jump")
	cv.tick(0.05)
	var mid := z.position.x
	for i in 30:
		cv.tick(0.05)
	_check.call(mid > at.x and mid < to.x and z.position.is_equal_approx(to) and not z.is_moving(),
			"creatures: it walks over to the next square (%.2f between %.2f and %.2f)" % [mid, at.x, to.x])
	_check.call(absf(angle_difference(z.rotation.y, -PI / 2.0)) < 0.05, "creatures: it turned to face east (%.2f)" % z.rotation.y)
	# Far away: a jump. Snapping off: every step is a jump.
	zombie["pos"] = [zp.x + 6, zp.y, zp.z]
	var snap3 := Snapshot.from_data(d)
	cv.apply(snap3, world)
	_check.call(not z.is_moving() and z.position.is_equal_approx(world.coords.ms_center_to_world(zp + Vector3i(6, 0, 0))),
			"creatures: a long jump isn't walked")
	cv.smooth = false
	zombie["pos"] = [zp.x + 5, zp.y, zp.z]
	cv.apply(Snapshot.from_data(d), world)
	_check.call(not z.is_moving(), "creatures: with snapping on, steps jump")
	cv.smooth = true
	# Events: attack, damage, death; junk is skipped.
	cv.on_events([{"kind": "attack", "uid": zuid, "other": nuid, "pos": zp}, {"kind": "damage", "uid": nuid},
			{"kind": 5, "uid": zuid}, {"kind": "death", "uid": "x"}, "junk", {"kind": "attack", "uid": 99}])
	var n := cv.figure(nuid)
	_check.call(z.is_attacking() and n.is_hurt(), "creatures: attack lunges, damage flinches")
	for i in 20:
		cv.tick(0.05)
	_check.call(not z.is_attacking() and not n.is_hurt(), "creatures: the lunge and the flinch end")
	cv.on_events([{"kind": "death", "uid": nuid}])
	_check.call(cv.figure(nuid) == null and cv.dying_count() == 1, "creatures: a death starts the fall")
	for i in 80:
		cv.tick(0.05)
	_check.call(cv.dying_count() == 0, "creatures: the fallen figure is removed after a while")
	# Out of sight without a death: it lingers a moment, then goes.
	d["creatures"] = [me]
	var gone := Snapshot.from_data(d)
	world.apply_snapshot(gone)
	cv.apply(gone, world)
	_check.call(cv.count() == 0 and cv.get_child_count() == 1, "creatures: out of sight, it lingers")
	for i in 20:
		cv.tick(0.05)
	_check.call(cv.get_child_count() == 0, "creatures: then it is gone")
	cv.view_z_max = zp.z - 1
	cv.free()
	for bad: Variant in [[{"uid": 2, "kind": 7, "pos": pp}], [{"uid": -1, "kind": 2, "pos": pp}],
			[{"uid": 2, "kind": 2, "pos": [1, 2]}], ["zombie"], {"uid": 2}]:
		d["creatures"] = bad
		_check.call(not Snapshot.from_data(d).is_valid(), "creatures: refused %s" % str(bad).left(40))
	var many := []
	many.resize(Snapshot.MAX_CREATURES + 1)
	many.fill(me)
	d["creatures"] = many
	_check.call(not Snapshot.from_data(d).is_valid(), "creatures: more than %d refused" % Snapshot.MAX_CREATURES)


## Stairs: pointing at them (StairUse) finds where they go, the free-walk camera takes them, and a live game
## gets CDDA's own actions.
func _test_stairs(world: WorldView) -> void:
	var up: Variant = null
	for pos: Vector3i in world.snapshot.submaps:
		var sm: Snapshot.Submap = world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if up == null and world.catalog.style_for(sm.ter[i]).kind == TerrainCatalog.Kind.STAIRS_UP:
				up = CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
	_check.call(up != null, "stairs: the mock town has stairs up")
	if up == null:
		return
	var s := StairUse.find(world, up, up.z)
	_check.call(s.get("dz") == 1 and s["stand"] == up and s["to"] == up + Vector3i(0, 0, 1), "stairs: up from their level (%s)" % s)
	var d := StairUse.find(world, up, up.z + 1)
	_check.call(d.get("dz") == -1 and d["to"] == up, "stairs: seen from above (a stairwell) they lead down")
	_check.call(StairUse.find(world, up, up.z + 3).is_empty(), "stairs: not from a level they don't touch")
	_check.call(StairUse.find(world, world.snapshot.player_pos, world.snapshot.player_pos.z).is_empty(),
			"stairs: a plain floor is no stair")
	_check.call(StairUse.live_actions(up, s) == PackedStringArray(["LEVEL_UP"]), "stairs live: on them, < only")
	_check.call(StairUse.live_actions(up + Vector3i(-1, 0, 0), s) == PackedStringArray(["RIGHT", "LEVEL_UP"]),
			"stairs live: next to them, a step then <")
	_check.call(StairUse.live_actions(up + Vector3i(5, 0, 0), s).is_empty(), "stairs live: too far, nothing")
	_check.call(StairUse.live_actions(up + Vector3i(0, 0, 1), d) == PackedStringArray(["LEVEL_DOWN"]),
			"stairs live: on the top end, >")
	var fp := FirstPersonCamera.new(world)
	fp.go_to_square(up)
	_check.call(fp.use_stair(s) and fp.z == up.z + 1, "stairs: the free-walk camera goes up them")
	_check.call(not fp.use_stair({}), "stairs: no stair, no move")
	fp.free()


## Stair blocks draw as one flight: every square of a 2x2 block rises the same way, split along its length.
func _test_stair_flights(world: WorldView, data: Variant, tables: IdTables) -> void:
	var K := TerrainCatalog.Kind
	var map := {}
	for x in range(-1, 3):
		for y in range(-1, 4):
			map[Vector3i(x, y, 0)] = K.FLOOR
	for x in range(-1, 3):
		map[Vector3i(x, -1, 0)] = K.WALL   # wall to the north
	for q in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0)]:
		map[q] = K.STAIRS_UP
	var kind_at := func(q: Vector3i) -> int: return map.get(q, -1)
	var walk := func(k: int) -> bool: return k == K.FLOOR
	var fs := []
	for q in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0)]:
		fs.append(TerrainMesher.stair_flight(q, kind_at, K.STAIRS_UP, walk))
	_check.call(fs.all(func(f: Vector3i) -> bool: return f.x == 0 and f.z == 2), "stairs look: a 2x2 block is one flight rising north to the wall (%s)" % [fs])
	_check.call(fs[2].y == 0 and fs[0].y == 1, "stairs look: the south row is the bottom half, the north row the top")
	var single := TerrainMesher.stair_flight(Vector3i(0, 2, 0), func(q: Vector3i) -> int: return K.STAIRS_UP if q == Vector3i(0, 2, 0) else K.FLOOR, K.STAIRS_UP, walk)
	_check.call(single.y == 0 and single.z == 1, "stairs look: a lone stair is a whole flight")
	# The level above decides: entered from the west with a wall to the east, the old terms say east, but upstairs
	# the east side is a railing and the north side the floor you step onto.
	var o := Vector3i(10, 10, 0)
	var up := Vector3i(0, 0, 1)
	var lone := {o: K.STAIRS_UP, o + Vector3i(-1, 0, 0): K.FLOOR, o + Vector3i(1, 0, 0): K.WALL,
			o + Vector3i(0, -1, 0): K.FLOOR, o + Vector3i(0, 1, 0): K.FLOOR}
	var no_above := TerrainMesher.stair_flight(o, func(q: Vector3i) -> int: return lone.get(q, -1), K.STAIRS_UP, walk)
	_check.call(no_above.x == 1, "stairs look: without the level above, the old terms rise toward the wall (%s)" % no_above)
	lone.merge({o + up: K.STAIRS_DOWN, o + up + Vector3i(1, 0, 0): K.FENCE, o + up + Vector3i(0, -1, 0): K.FLOOR,
			o + up + Vector3i(-1, 0, 0): K.WALL, o + up + Vector3i(0, 1, 0): K.WALL})
	var with_above := TerrainMesher.stair_flight(o, func(q: Vector3i) -> int: return lone.get(q, -1), K.STAIRS_UP, walk)
	_check.call(with_above.x == 0, "stairs look: with it, they rise north onto the floor upstairs (%s)" % with_above)
	_test_mock_stairs(world)
	_test_ramp_runs(world)
	_test_ramp_mesh(world, data, tables)
	_test_stair_pick(world)


## Every staircase of the mock town rises toward a floor on the level above (both did not before).
func _test_mock_stairs(world: WorldView) -> void:
	var K := TerrainCatalog.Kind
	var kind_at := TerrainMesher.kind_lookup(world.snapshot, world.catalog)
	var walk := func(k: int) -> bool: return k in TerrainMesher.WALKABLE
	var bad := []
	var n := 0
	for pos: Vector3i in world.snapshot.submaps:
		var sm: Snapshot.Submap = world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if world.catalog.style_for(sm.ter[i]).kind != K.STAIRS_UP:
				continue
			var p := CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
			var f := TerrainMesher.stair_flight(p, kind_at, K.STAIRS_UP, walk)
			var off: int = kind_at.call(p + TerrainMesher.DIRS[f.x] * (f.z - f.y) + Vector3i(0, 0, 1))
			n += 1
			if not walk.call(off):
				bad.append([p, f])
	_check.call(n >= 3 and bad.is_empty(), "stairs look: the mock's %d stairs all lead onto a floor upstairs %s" % [n, bad])


## Ramp runs on the mock's L-shaped sewer ramp (cs_open_sewer: a high column rising west, a high row rising south,
## the low ends inside the L) and on small made-up maps.
func _test_ramp_runs(world: WorldView) -> void:
	var K := TerrainCatalog.Kind
	var cat := world.catalog
	_check.call(cat.style_for_id("t_earth_ramp_up_low").ramp_low and cat.style_for_id("t_ramp_up_low").ramp_low
			and cat.style_for_id("t_railroad_ramp_up_low").ramp_low and not cat.style_for_id("t_earth_ramp_up_high").ramp_low
			and not cat.style_for_id("t_earth_ramp_down_low").ramp_low and not cat.style_for_id("t_dirt").ramp_low,
			"ramps: low ends are known by their id only")
	var kind_at := TerrainMesher.kind_lookup(world.snapshot, world.catalog)
	var low_at := TerrainMesher.low_lookup(world.snapshot, world.catalog)
	var place := func(x: int, y: int) -> Vector3i: return TerrainMesher.ramp_place(Vector3i(x, y, -1), kind_at, low_at)
	_check.call(place.call(176, 324) == Vector3i(3, 1, 2) and place.call(177, 324) == Vector3i(3, 0, 2)
			and place.call(176, 326) == Vector3i(3, 1, 2) and place.call(177, 325) == Vector3i(3, 0, 2),
			"ramps: the west leg rises west from its low ends, low then high (%s %s)" % [place.call(176, 324), place.call(177, 324)])
	_check.call(place.call(180, 327) == Vector3i(2, 1, 2) and place.call(180, 326) == Vector3i(2, 0, 2)
			and place.call(189, 327) == Vector3i(2, 1, 2) and place.call(178, 326) == Vector3i(2, 0, 2),
			"ramps: the south leg rises south (%s %s)" % [place.call(180, 327), place.call(178, 326)])
	_check.call(place.call(176, 327) == TerrainMesher.RAMP_CORNER and place.call(177, 326) == TerrainMesher.RAMP_CORNER,
			"ramps: where the legs meet are corners")
	var hip := TerrainMesher.ramp_heights(Vector3i(176, 327, -1), kind_at, low_at)
	var dip := TerrainMesher.ramp_heights(Vector3i(177, 326, -1), kind_at, low_at)
	var H := CddaCoords.LEVEL_M
	_check.call(hip == PackedFloat32Array([H, H / 2, H, H]) and dip == PackedFloat32Array([H / 2, 0, H / 2, H / 2]),
			"ramps: the outer corner is a hip at the top, the inner one dips to the ditch (%s %s)" % [hip, dip])
	_check.call(place.call(185, 324) == TerrainMesher.NOT_RAMP and place.call(176, 324).x >= 0,
			"ramps: the ditch itself is no ramp")
	# Made up: a 3 wide ramp rising north, one low row and two high rows.
	var map := {}
	var lows := {}
	for x in 3:
		lows[Vector3i(x, 3, 0)] = true
		map[Vector3i(x, 3, 0)] = K.FLOOR
		map[Vector3i(x, 2, 0)] = K.RAMP_UP
		map[Vector3i(x, 1, 0)] = K.RAMP_UP
	lows[Vector3i(8, 8, 0)] = true   # a ramp-named floor far from any ramp
	lows[Vector3i(1, 6, 0)] = true   # one behind the ramp but with plain floor between
	var ka := func(q: Vector3i) -> int: return map.get(q, K.FLOOR if q.z == 0 else -1)
	var la := func(q: Vector3i) -> bool: return lows.has(q)
	var wide := []
	for q in [Vector3i(0, 3, 0), Vector3i(1, 2, 0), Vector3i(2, 1, 0)]:
		wide.append(TerrainMesher.ramp_place(q, ka, la))
	_check.call(wide == [Vector3i(0, 0, 3), Vector3i(0, 1, 3), Vector3i(0, 2, 3)],
			"ramps: low then two high rows are one run in thirds (%s)" % [wide])
	_check.call(TerrainMesher.ramp_place(Vector3i(8, 8, 0), ka, la) == TerrainMesher.NOT_RAMP
			and TerrainMesher.ramp_place(Vector3i(1, 6, 0), ka, la) == TerrainMesher.NOT_RAMP,
			"ramps: a low-end id away from a RAMP_UP run, or cut off from it by plain floor, stays plain floor")
	var bare := TerrainMesher.ramp_place(Vector3i(1, 2, 0), ka, func(_q: Vector3i) -> bool: return false)
	_check.call(bare.x >= 0 and bare.z == 2, "ramps: without low ends the high end still rises as one flight (%s)" % bare)


## A 1 + 1 ramp meshed from a small snapshot (the mock's ramp is L-shaped): one slope over both squares, sides, no
## bottom; and on the mock, nothing drawn over its ramp on the level above.
func _test_ramp_mesh(world: WorldView, data: Variant, tables: IdTables) -> void:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var sm: Dictionary = d["submaps"][0]
	var floor_id := tables.index_of("ter", "t_floor")
	for i in 144:
		sm["ter"][i] = floor_id
		sm["furn"][i] = 0
		sm["flags"][i] = 1
	sm["items"] = []
	sm["ter"][6 * 12 + 5] = tables.index_of("ter", "t_earth_ramp_up_low")
	sm["ter"][5 * 12 + 5] = tables.index_of("ter", "t_earth_ramp_up_high")
	sm["ter"][9 * 12 + 9] = tables.index_of("ter", "t_ramp_up_low")   # alone: a plain floor
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid(), "ramp mesh: test snapshot (%s)" % snap.error)
	if not snap.is_valid():
		return
	var pos := Vector3i(sm["pos"][0], sm["pos"][1], sm["pos"][2])
	var r := TerrainMesher.new(snap, world.catalog).build(pos)
	var arr := r.terrain.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var H := CddaCoords.LEVEL_M
	var tops := 0
	var sides := 0
	var bottoms := 0
	var heights_ok := true
	var facing_ok := true
	var lone_flat := true
	for t in range(0, v.size(), 3):
		var c := (v[t] + v[t + 1] + v[t + 2]) / 3.0
		if c.x > 9 and c.x < 10 and c.z > 9 and c.z < 10:
			lone_flat = lone_flat and absf(c.y) < 0.001
		if c.x < 5 or c.x > 6 or c.z < 5 or c.z > 7:
			continue
		var n := nrm[t]
		facing_ok = facing_ok and (v[t + 1] - v[t]).cross(v[t + 2] - v[t]).dot(n) < 0.0   # front faces wind clockwise
		if n.y < -0.5:
			bottoms += 1
		elif n.y > 0.5:
			tops += 1
			facing_ok = facing_ok and n.z > 0.1   # rising north: the slope looks south, down it
			for k in 3:
				heights_ok = heights_ok and absf(v[t + k].y - H * (7.0 - v[t + k].z) / 2.0) < 0.001
		else:
			sides += 1
	_check.call(tops == 4 and heights_ok, "ramp mesh: one slope, floor at the low end's back, H/2 between, H at the top (%d tops)" % tops)
	_check.call(bottoms == 0 and sides >= 4 and facing_ok, "ramp mesh: side faces, no bottom, faces look out (%d sides)" % sides)
	_check.call(lone_flat, "ramp mesh: a low-end id away from a ramp is a flat floor")
	# The mock's ramp tops (RAMP_DOWN and see-through squares at x 176..179, y 324..327 on level 0) draw nothing
	# that could cut through the slope below them.
	var top := TerrainMesher.new(world.snapshot, world.catalog).build(Vector3i(14, 27, 0))
	var tv: PackedVector3Array = top.terrain.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var over := 0
	for t in range(0, tv.size(), 3):
		var c := (tv[t] + tv[t + 1] + tv[t + 2]) / 3.0
		if c.x > 8 and c.x < 12 and c.z > 0 and c.z < 4:
			over += 1
	_check.call(over == 0, "ramp mesh: nothing is drawn over the ramp on the level above (%d triangles)" % over)


## Pointing at stairs or a ramp picks the square their surface is drawn on, not what lies behind them.
func _test_stair_pick(world: WorldView) -> void:
	var lr := LookRay.new(world)
	var stair := Vector3i(228, 428, 0)   # rises north: from 0 on its south edge to 3 m on its north edge
	var eye := world.coords.ms_center_to_world(stair + Vector3i(-3, 0, 0)) + Vector3(0, 1.6, 0)
	var at := world.coords.ms_center_to_world(stair) + Vector3(0, 1.2, 0)
	var h := lr.cast(eye, at - eye)
	_check.call(h["hit"] and h["square"] == stair and h["what"] == "stairs",
			"stairs pick: a look at the middle step meets the stairs, not the wall behind (%s)" % h)
	if h["hit"]:
		_check.call(StairUse.find(world, h["square"], 0).get("dz") == 1, "stairs pick: and StairUse takes them up")
	var eye2 := world.coords.ms_center_to_world(Vector3i(182, 324, -1)) + Vector3(0, 1.6, 0)
	var at2 := world.coords.ms_center_to_world(Vector3i(182, 327, -1)) + Vector3(0, 2.0, 0)
	var h2 := lr.cast(eye2, at2 - eye2)
	_check.call(h2["hit"] and h2["what"] == "ramp" and h2["square"].y >= 326,
			"stairs pick: looking across the ditch meets the ramp's slope (%s)" % h2)

## The player's body: parts from the snapshot, worn items inner to outer each a layer larger, wounds on top,
## head hidden for the own camera, hostile player data rejected.
func _test_player_body(root: Node, data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(data)
	_check.call(snap.is_valid() and snap.player_parts.size() == 12 and snap.player_worn.size() == 9,
			"body: mock player has 12 parts and 9 worn items (%s)" % snap.error)
	_check.call(tables.body_part_name(35) == "torso", "body: id tables name body parts")
	var plan := PlayerBody.plan(snap, tables)
	var torso: Array = plan.filter(func(p: Dictionary) -> bool: return p["part"] == "torso" and p["kind"] in ["skin", "worn"])
	var grows := torso.size() == 4
	for i in range(1, torso.size()):
		grows = grows and torso[i]["size"].x > torso[i - 1]["size"].x
	_check.call(grows and torso[1]["item"] == 8696 and torso[3]["item"] == 4771,
			"body: torso skin < t-shirt < hoodie < leather jacket")
	var kinds := {}
	for p: Dictionary in plan:
		kinds[p["kind"] + ":" + p["part"]] = true
	_check.call(kinds.has("bandage:arm_l") and kinds.has("blood:leg_r") and kinds.has("tear:leg_l")
			and kinds.has("worn:head") and not kinds.has("bandage:arm_r"),
			"body: bandage on the left arm, blood on the right leg, torn jeans, a cap")
	var leg_r: Snapshot.BodyPart = snap.player_parts[9]
	var leg_l: Snapshot.BodyPart = snap.player_parts[8]
	_check.call(PlayerBody.skin_color(leg_r).b < PlayerBody.skin_color(leg_l).b
			and PlayerBody.skin_color(leg_r).g < PlayerBody.skin_color(leg_l).g, "body: hurt leg is redder")
	var gloves := snap.player_worn[8]
	var fresh := Snapshot.Worn.new()
	fresh.type = gloves.type
	_check.call(PlayerBody.worn_color(null, gloves).s < PlayerBody.worn_color(null, fresh).s,
			"body: worn-out gloves are paler")
	var pb := PlayerBody.new()
	root.add_child(pb)
	pb.apply(snap, tables)
	var built := pb.get_child_count()
	pb.show_head = false
	var head := pb.get_node_or_null("head") as Node3D
	var arm := pb.get_node_or_null("arm_l") as Node3D
	_check.call(built == 12 and head != null and not head.visible and arm.visible,
			"body: one node per part; own camera hides the head, not the arms")
	var hips := PlayerBody.next_hip_yaw(0.0, 0.3, 0.1)
	var turned := PlayerBody.next_hip_yaw(0.0, 1.5, 0.1)
	var caught := 0.0
	for i in 60:
		caught = PlayerBody.next_hip_yaw(caught, 1.5, 1.0 / 60.0)
	_check.call(hips == 0.0 and turned > 0.0 and turned < 1.5 and absf(1.5 - caught) <= PlayerBody.HIP_SLACK,
			"body: hips stay for a small head turn, follow a big one (%.2f, %.2f)" % [turned, caught])
	var sh := PlayerBody.shoulder_of(1.0)
	var far := PlayerBody.arm_ik(-1.0, Vector3(-0.25, 1.45, -2.0))
	var near := PlayerBody.arm_ik(1.0, Vector3(0.25, 1.2, -0.3))
	var far_w: Vector3 = far[1]
	var near_e: Vector3 = near[0]
	var near_w: Vector3 = near[1]
	_check.call(absf(far_w.distance_to(PlayerBody.shoulder_of(-1.0)) - PlayerBody.ARM_REACH) < 0.001
			and far_w.z < -0.5 and near_w.is_equal_approx(Vector3(0.25, 1.2, -0.3)),
			"body: wrists reach for the hands, arms don't stretch")
	_check.call(absf(near_e.distance_to(sh) - PlayerBody.UPPER_ARM) < 0.001
			and absf(near_e.distance_to(near_w) - PlayerBody.FOREARM) < 0.001
			and near_e.x > sh.x and near_e.y < (sh.y + near_w.y) * 0.5 and near_e.z > (sh.z + near_w.z) * 0.5,
			"body: a bent arm keeps its bone lengths, elbow out, down and back (%s)" % near_e)
	var cut := PlayerBody.split_at_elbow(Vector3(0.25, 1.17, 0), Vector3(0.1, 0.56, 0.1))
	var mark := PlayerBody.split_at_elbow(Vector3(0.25, 1.3, -0.06), Vector3(0.03, 0.03, 0.004))
	_check.call(cut.size() == 2 and is_equal_approx((cut[0][1] as Vector3).y, PlayerBody.UPPER_ARM)
			and is_equal_approx((cut[1][1] as Vector3).y, PlayerBody.FOREARM) and cut[1][2] == "fore"
			and mark.size() == 1 and mark[0][2] == "upper",
			"body: sleeves cut at the elbow, a mark goes to its half")
	pb.position = Vector3.ZERO
	pb.rotation = Vector3.ZERO
	pb.reach(pb.to_global(Vector3(-0.25, 1.3, -0.35)), null)
	var hl := pb.get_node("hand_l") as Node3D
	var hr := pb.get_node("hand_r") as Node3D
	var al := pb.get_node("arm_l") as Node3D
	var fore := al.get_node_or_null("fore") as Node3D
	var ik := PlayerBody.arm_ik(-1.0, Vector3(-0.25, 1.3, -0.35))
	var fore_mid := al.transform * fore.transform * (fore.get_child(0) as Node3D).position
	_check.call((hl.transform * (PlayerBody.PARTS["hand_l"][0] as Vector3)).z < -0.3 and hr.transform == Transform3D.IDENTITY
			and fore != null and fore.get_child_count() > 0 and not fore.transform.basis.is_equal_approx(Basis.IDENTITY)
			and fore_mid.distance_to(((ik[0] as Vector3) + (ik[1] as Vector3)) * 0.5) < 0.01,
			"body: left arm bends to reach forward, forearm between elbow and wrist, right arm hangs")
	pb.show_hands = false
	_check.call(not hl.visible and not hr.visible and al.visible, "body: VR hides the body's hands, keeps the arms")
	pb.show_hands = true
	var k := pb.key
	pb.apply(snap, tables)
	_check.call(pb.key == k and pb.get_child_count() == 12, "body: same snapshot, no rebuild")
	pb.free()
	var bad: Dictionary = (data as Dictionary).duplicate(true)
	bad["player"]["bleed"] = [1, 2]
	_check.call(not Snapshot.from_data(bad).is_valid(), "body: wound list of the wrong length rejected")
	bad = (data as Dictionary).duplicate(true)
	var many := []
	for i in 65:
		many.append({"type": 1, "covers": [35]})
	bad["player"]["worn"] = many
	_check.call(not Snapshot.from_data(bad).is_valid(), "body: more than 64 worn items rejected")
	bad = (data as Dictionary).duplicate(true)
	bad["player"]["worn"] = [{"type": 1, "covers": "torso"}]
	_check.call(not Snapshot.from_data(bad).is_valid(), "body: covers must be a list")
