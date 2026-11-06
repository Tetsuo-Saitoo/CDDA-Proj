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
	world.free()


func _test_args() -> void:
	_check.call(FirstPersonCamera.view_from_args({}) == "first", "fp: first person by default")
	_check.call(FirstPersonCamera.view_from_args({"view": "outside"}) == "outside", "fp: --view=outside")
	_check.call(FirstPersonCamera.view_from_args({"camera": "1,2,3,4,5"}) == "outside", "fp: --camera= starts outside")
	_check.call(FirstPersonCamera.view_from_args({"view": "first", "camera": "1,2,3,4,5"}) == "first",
			"fp: --view=first wins over --camera=")
	_check.call(FirstPersonCamera.view_from_args({"view": "top"}) == "first", "fp: a bad --view= keeps first person")


func _test_actions() -> void:
	InputActions.ensure()
	var all := true
	for a in InputActions.names():
		all = all and InputMap.has_action(a)
	_check.call(all, "fp: every default action exists")
	var w := InputMap.action_get_events(&"move_forward")
	_check.call(w.size() == 2 and w.any(func(e: InputEvent) -> bool: return e is InputEventKey and e.physical_keycode == KEY_W),
			"fp: move_forward is W and the left stick")
	InputActions.ensure()
	_check.call(InputMap.action_get_events(&"move_forward").size() == 2, "fp: ensure twice adds nothing")
	InputMap.erase_action(&"view_toggle")
	InputMap.add_action(&"view_toggle")
	var u := InputEventKey.new()
	u.physical_keycode = KEY_U
	InputMap.action_add_event(&"view_toggle", u)
	InputActions.ensure()
	var ev := InputMap.action_get_events(&"view_toggle")
	_check.call(ev.size() == 1 and ev[0].physical_keycode == KEY_U, "fp: a binding already there is kept")
	InputMap.erase_action(&"view_toggle")
	InputActions.ensure()


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
