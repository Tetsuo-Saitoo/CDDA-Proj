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
	_check.call(built == 14 and head != null and not head.visible and arm.visible,
			"body: one node per part; own camera hides the head, not the arms")
	var hips := PlayerBody.next_hip_yaw(0.0, 0.3, 0.1)
	var turned := PlayerBody.next_hip_yaw(0.0, 1.5, 0.1)
	var caught := 0.0
	for i in 60:
		caught = PlayerBody.next_hip_yaw(caught, 1.5, 1.0 / 60.0)
	_check.call(hips == 0.0 and turned > 0.0 and turned < 1.5 and absf(1.5 - caught) <= PlayerBody.HIP_SLACK,
			"body: hips stay for a small head turn, follow a big one (%.2f, %.2f)" % [turned, caught])
	var far := PlayerBody.arm_pose(-1.0, Vector3(-0.25, 1.45, -2.0))
	var near := PlayerBody.arm_pose(1.0, Vector3(0.25, 1.2, -0.3))
	_check.call(absf((far[0] as Vector3).distance_to(Vector3(-0.25, 1.45, 0)) - PlayerBody.ARM_REACH) < 0.001
			and (far[0] as Vector3).z < -0.6 and (near[0] as Vector3).is_equal_approx(Vector3(0.25, 1.2, -0.3)),
			"body: hands reach for the controllers, arms don't stretch")
	pb.position = Vector3.ZERO
	pb.rotation = Vector3.ZERO
	pb.reach(pb.to_global(Vector3(-0.25, 1.45, -2.0)), null)
	var hl := pb.get_node("hand_l") as Node3D
	var hr := pb.get_node("hand_r") as Node3D
	_check.call(hl.position.z < -0.5 and hr.transform == Transform3D.IDENTITY
			and not (pb.get_node("arm_l") as Node3D).transform.basis.is_equal_approx(Basis.IDENTITY),
			"body: left arm points forward, right arm hangs")
	var open_pts := PlayerBody.finger_points(1.0, Basis.IDENTITY, Vector3(0.25, 0.82, 0), [0, 0, 0, 0, 0])
	var fist_pts := PlayerBody.finger_points(1.0, Basis.IDENTITY, Vector3(0.25, 0.82, 0), [1, 1, 1, 1, 1])
	var idx_open: Vector3 = open_pts[1][3]
	var idx_fist: Vector3 = fist_pts[1][3]
	_check.call(open_pts.size() == 5 and idx_open.y < 0.7 and idx_fist.y > idx_open.y + 0.03,
			"body: fingers hang open and curl up into a fist")
	pb.show_fingers = true
	pb.pose_fingers("l", pb.curled_points(-1.0, [0.5, 1, 0, 0, 0]))
	var fl := pb.get_node_or_null("fingers_l") as Node3D
	_check.call(fl != null and fl.visible and fl.get_child_count() == 15
			and (fl.get_child(3) as Node3D).position.distance_to(pb.get_node("hand_l").position) < 1.0,
			"body: 15 finger segments per hand, shown in VR")
	pb.show_fingers = false
	_check.call(not fl.visible and VrHands.JOINTS.size() == 5, "body: no fingers on the desktop")
	var k := pb.key
	pb.apply(snap, tables)
	_check.call(pb.key == k and pb.get_child_count() == 14, "body: same snapshot, no rebuild")
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
