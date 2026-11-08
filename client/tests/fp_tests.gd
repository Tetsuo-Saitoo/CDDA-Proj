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
	_test_cdda_keys()
	_test_rebinding(root)
	_test_creatures(root, world, data, tables)
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
		fp.go_to_square(start)
		fp.set_look(-PI / 2, 0.0)
		var x0 := fp.position.x
		for i in 5:
			fp.step(0.05, {"move": Vector2(0, 1)})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75) and fp.walk.square_at(fp.position, 0) == door,
				"fp: walks into a door square (doors don't block)")
		fp.go_to_square(start)
		fp.step(0.1, {"move": Vector2(0, 1), "fast": true})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75), "fp: fast walks 2.5x")
		fp.go_to_square(start)
		for i in 5:
			fp.step(0.05, {"move": Vector2(0, 5)})
		_check.call(is_equal_approx(fp.position.x - x0, 0.75), "fp: stick input past 1 is cut to 1")
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
	var path := "user://keys_test.json"
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
	var x: Array[InputEvent] = [InputActions.parse_event("X")]
	InputActions.set_slots(&"cdda_examine", x)
	_check.call(InputActions.save_bindings(path) == "", "keys: saved")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check.call(saved is Dictionary and saved["actions"].keys() == ["cdda_examine"], "keys: only changed actions are written")
	InputActions.reset_all()
	_check.call(InputActions.load_bindings(path).is_empty() and InputActions.key_of(&"cdda_examine") == "X"
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
	menu.free()
	InputActions.reset_all()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


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


## Placeholder creatures: read from the snapshot, drawn as capsules, met by look; bad data is refused.
func _test_creatures(root: Node, world: WorldView, data: Variant, tables: IdTables) -> void:
	var zi := -1
	for i in tables.mtype.size():
		if tables.mtype[i].id == "mon_zombie":
			zi = i
	_check.call(zi >= 0 and tables.mtype[zi].size == 3, "creatures: the id tables have mon_zombie, medium")
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var pp: Array = d["player"]["pos"]
	var me: Dictionary = d["creatures"][0]
	var zp := Vector3i(int(pp[0]) + 1, int(pp[1]), int(pp[2]))
	d["creatures"] = [me, {"uid": 8589934593, "kind": 2, "type": zi, "pos": [zp.x, zp.y, zp.z], "hp_frac": 128},
			{"uid": 4294967297, "kind": 1, "type": 0, "pos": [zp.x - 1, zp.y + 1, zp.z], "hp_frac": 255}]
	var snap := Snapshot.from_data(d)
	_check.call(snap.is_valid() and snap.creatures.size() == 3, "creatures: read (%s)" % snap.error)
	if not snap.is_valid():
		return
	world.apply_snapshot(snap)
	var cv := CreatureView.new()
	root.add_child(cv)
	cv.apply(snap, world)
	_check.call(cv.count() == 2, "creatures: a capsule each for the zombie and the NPC, none for the player")
	var z := cv.get_node_or_null("creature_8589934593") as MeshInstance3D
	var ok := z != null
	if ok:
		var m := z.mesh as CapsuleMesh
		var l := z.get_child(0) as Label3D
		ok = (is_equal_approx(m.height, 1.75) and (m.material as StandardMaterial3D).albedo_color == CreatureView.MONSTER_COLOR
				and z.position.is_equal_approx(world.coords.ms_center_to_world(zp) + Vector3(0, 0.875, 0))
				and l != null and l.text == "zombie")
	_check.call(ok, "creatures: the zombie is a green 1.75 m capsule on its square, named")
	var lr := LookRay.new(world)
	var eye := world.coords.ms_center_to_world(zp - Vector3i(1, 0, 0)) + Vector3(0, 1.0, 0)
	var h := lr.cast(eye, Vector3.RIGHT)
	_check.call(h["hit"] and h["what"] == "zombie" and h["square"] == zp, "creatures: look meets the zombie (%s)" % h)
	_check.call("creature: zombie, health 50%" in lr.describe(zp), "creatures: look names it with its health")
	cv.view_z_max = zp.z - 1
	_check.call(not z.visible, "creatures: hidden above the cutaway")
	cv.view_z_max = CddaCoords.Z_MAX
	d["creatures"] = [me]
	var gone := Snapshot.from_data(d)
	world.apply_snapshot(gone)
	cv.apply(gone, world)
	_check.call(cv.count() == 0, "creatures: gone when the next snapshot doesn't have them")
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
