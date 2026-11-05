extends RefCounted
## Block L1 checks, run by run_tests.gd: VrWalk on the mock town and VrRig's locomotion without a headset
## (no XR runtime here, so the head and hands stay where the test puts them).

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vr")
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(world)
	world.set_id_tables(tables)
	world.apply_snapshot(Snapshot.from_data(data))
	_test_settings()
	_test_walk(world)
	_test_rig(root, world)
	world.free()


func _test_settings() -> void:
	_check.call(VrRig.settings_from_args({}) == VrRig.DEFAULTS, "vr: default settings")
	var s := VrRig.settings_from_args({"vr-move": "teleport", "vr-turn": "smooth", "vr-snap": "30",
			"vr-speed": "99", "vr-vignette": "-1"})
	_check.call(s["move"] == "teleport" and s["turn"] == "smooth" and s["snap_deg"] == 30.0 and s["speed"] == 5.0
			and s["vignette"] == 0.0, "vr: settings read and clamped")
	s = VrRig.settings_from_args({"vr-move": "fly", "vr-turn": "", "vr-snap": "abc", "vr-speed": "nan"})
	_check.call(s == VrRig.DEFAULTS, "vr: bad settings keep the defaults")


## First square on level z whose terrain kind is `kind` (and, if given, whose west neighbour is standable).
func _find(world: WorldView, w: VrWalk, z: int, kind: int, west_free := false) -> Variant:
	for pos: Vector3i in world.snapshot.submaps:
		if pos.z != z:
			continue
		var sm: Snapshot.Submap = world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if world.catalog.style_for(sm.ter[i]).kind != kind:
				continue
			var p := CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
			if not west_free or w.can_stand(p - Vector3i(1, 0, 0)):
				return p
	return null


func _test_walk(world: WorldView) -> void:
	var w := VrWalk.new(world)
	var player := world.snapshot.player_pos
	var K := TerrainCatalog.Kind
	_check.call(w.can_stand(player), "vr: the player's square is standable")
	var wall: Variant = _find(world, w, 0, K.WALL, true)
	var floor: Variant = _find(world, w, 0, K.FLOOR)
	var air: Variant = _find(world, w, 1, K.NONE)
	_check.call(wall != null and not w.can_stand(wall), "vr: walls block")
	_check.call(floor != null and w.can_stand(floor), "vr: floors are standable")
	_check.call(air != null and not w.can_stand(air), "vr: open air is not standable")
	_check.call(not w.can_stand(player + Vector3i(500, 0, 0)), "vr: outside the bubble is not standable")
	_check.call(not w.can_stand(Vector3i(player.x, player.y, 7)), "vr: levels not loaded are not standable")
	if wall != null:
		var west: Vector3i = wall - Vector3i(1, 0, 0)
		var start := world.coords.ms_center_to_world(west) + Vector3(0, 1.7, 0)
		var to := w.slide(start, Vector3(2.0, 0, 0), 0)
		var wall_x := world.coords.ms_to_world(wall).x
		_check.call(to.x <= wall_x - VrWalk.BODY_R + 0.001 and to.x >= start.x, "vr: moving into a wall stops before it")
		_check.call(to.y == start.y and to.z == start.z, "vr: a blocked move changes nothing else")
		_check.call(not w.clear_line(west, wall + Vector3i(1, 0, 0)), "vr: no teleport line through a wall")
		var inside := world.coords.ms_center_to_world(wall)
		_check.call(w.slide(inside, Vector3(0.1, 0, 0), 0).x > inside.x, "vr: a head inside a wall can get out")
	_check.call(w.clear_line(player, player), "vr: a square sees itself")
	var head := world.coords.ms_center_to_world(player) + Vector3(0, 1.2, 0)
	var a := w.teleport_arc(head, Vector3(0, 0.5, -1), 0)
	var pts: PackedVector3Array = a["points"]
	var land: Vector3 = a["pos"]
	var dist := Vector2(land.x - head.x, land.z - head.z).length()
	_check.call(a["hit"] and pts.size() > 3 and is_equal_approx(land.y, 0.0) and dist > 3.0
			and dist < VrWalk.MAX_TELEPORT, "vr: teleport arc lands on the floor ahead (%.1f m)" % dist)
	_check.call(a["valid"] == (w.can_stand(w.square_at(land, 0)) and w.clear_line(player, w.square_at(land, 0))),
			"vr: arc validity matches the square and the line")
	var up := w.teleport_arc(head, Vector3.UP, 0)
	_check.call(up["hit"] and up["valid"] and (up["pos"] as Vector3).distance_to(Vector3(head.x, 0, head.z)) < 0.01,
			"vr: an arc straight up lands where it started")
	_check.call(not w.teleport_arc(head - Vector3(0, 3, 0), Vector3.FORWARD, 0)["hit"], "vr: no arc from under the floor")
	var spot: Variant = w.nearest_standable(player, true)
	_check.call(spot != null and spot != player and w.can_stand(spot) and spot.z == player.z
			and maxi(absi(spot.x - player.x), absi(spot.y - player.y)) <= VrWalk.SEARCH_R, "vr: a free square next to the player")
	_check.call(w.nearest_standable(player) == player, "vr: nearest standable square of a free one is itself")
	_check.call(w.nearest_standable(Vector3i(player.x, player.y, 7)) == null, "vr: nothing on a level not loaded")
	var xf := Transform3D(Basis(Vector3.UP, 0.3), Vector3(5, 0, 2))
	var cam := Vector3(0.3, 1.7, -0.2)
	var t := VrWalk.turned(xf, xf * cam, 0.5)
	_check.call((t * cam).is_equal_approx(xf * cam) and is_equal_approx(t.basis.get_euler().y, 0.8),
			"vr: turning keeps the head in place")


func _test_rig(root: Node, world: WorldView) -> void:
	var rig := VrRig.new(world, {"vignette": 1.0})
	root.add_child(rig)
	rig.camera.position = Vector3(0.2, 1.7, -0.1)   # not at the origin, so turns must pivot on the head
	var player := world.snapshot.player_pos
	rig.go_to_player(player)
	var head := rig.camera.global_position
	var sq := rig.walk.square_at(head, rig.z)
	var to_player := world.coords.ms_center_to_world(player) - head
	to_player.y = 0
	var fwd := -rig.camera.global_basis.z
	fwd.y = 0
	_check.call(sq == rig.walk.nearest_standable(player, true) and rig.z == player.z
			and is_equal_approx(head.y, player.z * CddaCoords.LEVEL_M + 1.7), "vr: rig stands next to the player")
	_check.call(fwd.normalized().dot(to_player.normalized()) > 0.99, "vr: rig faces the player")
	var yaw := rig.global_basis.get_euler().y
	rig.step(0.016, {"turn": Vector2(1, 0)})
	var yaw1 := rig.global_basis.get_euler().y
	_check.call(is_equal_approx(wrapf(yaw1 - yaw, -PI, PI), -deg_to_rad(45.0)) and rig.camera.global_position.is_equal_approx(head),
			"vr: snap turn right 45 deg about the head")
	rig.step(0.016, {"turn": Vector2(1, 0)})
	_check.call(is_equal_approx(rig.global_basis.get_euler().y, yaw1), "vr: holding the stick turns once")
	rig.step(0.016, {})
	rig.step(0.016, {"turn": Vector2(-1, 0)})
	_check.call(is_equal_approx(rig.global_basis.get_euler().y, yaw), "vr: back after release and a turn left")
	head = rig.camera.global_position
	rig.step(0.25, {"move": Vector2(0, 1)})
	var moved := rig.camera.global_position - head
	_check.call(moved.length() > 0.3 and moved.length() <= 0.5 + 0.001 and is_zero_approx(moved.y),
			"vr: smooth move toward the player (%.2f m)" % moved.length())
	_check.call(rig.vignette > 0.0, "vr: vignette shows while moving")
	for i in 30:
		rig.step(0.016, {})
	_check.call(rig.vignette == 0.0, "vr: vignette fades when still")
	rig.right.position = Vector3(0, 1.2, 0)
	rig.right.rotation = Vector3(0.4, 0, 0)
	head = rig.camera.global_position
	rig.step(0.016, {"turn": Vector2(0, 1)})
	var a := rig.arc.duplicate()
	_check.call(rig.aiming and a.get("hit", false), "vr: stick forward aims a teleport arc")
	rig.step(0.016, {})
	var now := rig.camera.global_position
	if a.get("valid", false):
		var land: Vector3 = a["pos"]
		_check.call(not rig.aiming and is_equal_approx(now.x, land.x) and is_equal_approx(now.z, land.z)
				and is_equal_approx(now.y, head.y), "vr: release jumps to the target")
	else:
		_check.call(not rig.aiming and now.is_equal_approx(head), "vr: release on a bad target stays")
	var z0 := rig.z
	_check.call(not rig.change_level(5) and rig.z == z0, "vr: no level change to a level not loaded")
	if rig.change_level(1):
		_check.call(rig.z == z0 + 1 and is_equal_approx(rig.global_position.y, (z0 + 1) * CddaCoords.LEVEL_M)
				and rig.walk.can_stand(rig.walk.square_at(rig.camera.global_position, rig.z)), "vr: level up lands on a free square")
	else:
		_check.call(rig.z == z0, "vr: level up refused keeps the level")
	rig.free()
