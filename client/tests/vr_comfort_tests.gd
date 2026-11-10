extends RefCounted
## VR settings, controller layouts, the settings menu and hands (VrSettings, VrMenu, VrHand, VrRig), run by
## vr_tests.gd on its mock world. No XR runtime here: controllers are inactive, the test presses buttons.

const TestDir := preload("res://tests/test_dir.gd")

var _tmp := TestDir.path("fp3d_test_vr.json")

var _check: Callable


func run(root: Node, check: Callable, world: WorldView) -> void:
	_check = check
	_test_values()
	_test_file()
	_test_layouts()
	_test_hand()
	_test_rig(root, world)
	_test_compass(root, world)
	_test_pointer(root, world)
	_test_main_hand(root, world)
	_test_height(root, world)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp))


func _row_of(key: String) -> int:
	for i in VrSettings.ROWS.size():
		if VrSettings.ROWS[i][0] == key:
			return i
	return -1


## First square on level z whose terrain kind is `kind`.
func _find_kind(world: WorldView, z: int, kind: int) -> Variant:
	for pos: Vector3i in world.snapshot.submaps:
		if pos.z != z:
			continue
		var sm: Snapshot.Submap = world.snapshot.submaps[pos]
		for i in Snapshot.TILES:
			if world.catalog.style_for(sm.ter[i]).kind == kind:
				return CddaCoords.sm_to_ms(pos) + Vector3i(i % CddaCoords.SEEX, i / CddaCoords.SEEX, 0)
	return null


## The settings menu's laser pointer: rows under a point, the main hand's ray picking and changing them.
func _test_pointer(root: Node, world: WorldView) -> void:
	var n := VrSettings.ROWS.size()
	var lh := VrMenu.LINE_H
	_check.call(VrMenu.row_at(Vector3(0, -lh, 0)) == 0 and VrMenu.row_at(Vector3(-0.3, -n * lh + 0.015, 0)) == n - 1
			and VrMenu.row_at(Vector3(0.3, -3 * lh - 0.018, 0)) == 2, "vr pointer: row_at finds the row under a point")
	_check.call(VrMenu.row_at(Vector3.ZERO) == -1 and VrMenu.row_at(Vector3(0, -(n + 1) * lh, 0)) == -1
			and VrMenu.row_at(Vector3(0.5, -lh, 0)) == -1 and VrMenu.row_at(Vector3(0, 0.5, 0)) == -1
			and VrMenu.row_at(Vector3(NAN, -lh, 0)) == -1 and VrMenu.on_panel(Vector3(0, -lh, 0))
			and not VrMenu.on_panel(Vector3(0, 0.3, 0)), "vr pointer: title, help line and off the panel are no row")
	var plane := Transform3D(Basis(), Vector3(0, 1, -1))
	var hit: Variant = VrRig.ray_on_plane(plane, Vector3(0.1, 1.2, 0), Vector3(0, 0, -1), 4.0)
	_check.call(hit is Vector3 and (hit as Vector3).is_equal_approx(Vector3(0.1, 0.2, 0))
			and VrRig.ray_on_plane(plane, Vector3(0, 1, 0), Vector3(0, 0, 1), 4.0) == null
			and VrRig.ray_on_plane(plane, Vector3(0, 1, -2), Vector3(0, 0, 1), 4.0) == null
			and VrRig.ray_on_plane(plane, Vector3(0, 1, 9), Vector3(0, 0, -1), 4.0) == null,
			"vr pointer: ray on the menu plane (not pointing away, from behind or too far)")
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	rig.go_to_square(world.snapshot.player_pos)
	rig.update_pointer(true)
	_check.call(not rig.pointer.visible and not rig.pointer_dot.visible, "vr pointer: none while the menu is closed")
	rig.press(rig.left, "menu_button")
	var aim := func(c: XRController3D, r: int, x: float) -> Vector3:
		var at := rig.menu.global_transform * Vector3(x, -(r + 1) * lh, 0)
		c.global_position = at + rig.menu.global_basis.z * 0.6 + Vector3(0.05, -0.3, 0)
		c.look_at(at, Vector3.UP)
		return at
	var speed := _row_of("speed")
	var at: Vector3 = aim.call(rig.right, speed, 0.2)
	rig.update_pointer(true)
	_check.call(rig.pointer.visible and rig.pointer_dot.visible and rig.pointer_dot.global_position.distance_to(at) < 0.001
			and rig.menu.row == speed, "vr pointer: the main hand's ray picks the row under its dot")
	rig.press(rig.right, "trigger_click")
	_check.call(rig.settings["speed"] == 2.5, "vr pointer: trigger on a number's right half steps it up")
	aim.call(rig.right, speed, -0.2)
	rig.update_pointer(true)
	rig.press(rig.right, "trigger_click")
	rig.press(rig.right, "trigger_click")
	_check.call(rig.settings["speed"] == 1.5, "vr pointer: ... and on its left half down")
	var blink := _row_of("blink")
	aim.call(rig.right, blink, -0.2)
	rig.update_pointer(true)
	rig.press(rig.right, "trigger_click")
	_check.call(rig.menu.row == blink and rig.settings["blink"] == true, "vr pointer: trigger on an on/off row flips it")
	rig.step(0.1, {"move": Vector2(0, -1)})
	rig.step(0.1, {})
	rig.update_pointer(true)
	_check.call(rig.menu.row == blink + 1, "vr pointer: the sticks still pick rows while it rests")
	rig.right.look_at(rig.right.global_position + rig.menu.global_basis.z, Vector3.UP)
	rig.update_pointer(true)
	_check.call(rig.pointer.visible and not rig.pointer_dot.visible, "vr pointer: pointing away, a short ray and no dot")
	rig.press(rig.left, "menu_button")
	_check.call(not rig.pointer.visible and not rig.pointer_dot.visible, "vr pointer: gone when the menu closes")
	rig.free()


## Left-handed mode: the left controller is the main hand, the compass goes to the right wrist.
func _test_main_hand(root: Node, world: WorldView) -> void:
	var rig := VrRig.new(world, {"main_hand": "left", "hands": "boxes", "compass": "wrist", "blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var player := world.snapshot.player_pos
	rig.go_to_square(player)
	_check.call(rig.main_ctrl() == rig.left and rig.off_ctrl() == rig.right and rig.main_hand_model() == rig.left_hand
			and rig.off_hand_model() == rig.right_hand, "vr left-handed: the left controller is the main hand")
	var up: Variant = _find_kind(world, 0, TerrainCatalog.Kind.STAIRS_UP)
	if up != null:
		var used := []
		rig.stair_used.connect(func(s: Dictionary) -> void: used.append(s))
		var at := world.coords.ms_center_to_world(up)
		for c: XRController3D in [rig.left, rig.right]:
			c.global_position = at + Vector3(0.6, 1.2, 0.0)
			c.look_at(at, Vector3.UP)
		rig.press(rig.right, "trigger_click")
		var z_right := rig.z
		rig.press(rig.left, "trigger_click")
		_check.call(z_right == 0 and used.size() == 1 and rig.z == 1,
				"vr left-handed: the left trigger uses pointed stairs, the right one doesn't")
		rig.go_to_square(player)
	rig.left.transform = Transform3D(Basis.from_euler(Vector3(0.4, 0, 0)), Vector3(-0.2, 1.2, 0))
	rig.right.transform = Transform3D(Basis.from_euler(Vector3(0.4, PI, 0)), Vector3(0.2, 1.2, 0))
	rig.step(0.016, {"turn": Vector2(0, 1)})
	var pts: PackedVector3Array = rig.arc.get("points", PackedVector3Array())
	_check.call(rig.aiming and pts.size() > 1 and pts[0].is_equal_approx(rig.right.global_position),
			"vr left-handed: the teleport arc leaves the hand whose stick aims it (right stick)")
	rig.aiming = false
	rig.arc = {}
	rig.settings["swap_sticks"] = true
	rig.step(0.016, {"turn": Vector2(0, 1)})
	pts = rig.arc.get("points", PackedVector3Array())
	_check.call(rig.aiming and pts.size() > 1 and pts[0].is_equal_approx(rig.left.global_position)
			and (pts[1] - pts[0]).normalized().dot(-rig.left.global_basis.z) > 0.9,
			"vr left-handed: swapped sticks aim the arc from the left controller")
	rig.settings["swap_sticks"] = false
	rig.aiming = false
	rig.arc = {}
	rig.show_held({"main": {"name": "knife"}, "off": {}})
	_check.call(rig.left_held.visible and not rig.right_held.visible, "vr left-handed: the wielded item shows on the left hand")
	rig.settings["main_hand"] = "right"
	rig._settings_changed()
	_check.call(rig.right_held.visible and not rig.left_held.visible, "vr left-handed: switching hands moves the item over")
	rig.settings["main_hand"] = "left"
	rig.right.transform = Transform3D(Basis(), Vector3(0.2, 1.1, -0.3))
	rig.pose_hands()
	rig.place_compass()
	var wr := rig.compass.wrist
	_check.call(wr.visible and wr.global_position.distance_to(rig.right.global_position) < 0.25 and wr.global_basis.y.x > 0.9,
			"vr left-handed: compass on the back of the right wrist (box hand), face out")
	rig.settings["hands"] = "buttons"
	rig._boxes[0].visible = false
	rig._boxes[1].visible = false
	var open := VrHand.curls_from_buttons(0.0, false, 0.0, false)
	rig.right_hand.pose_from_controller(rig.right.transform, open)
	rig.place_compass()
	_check.call(wr.visible and wr.global_basis.y.x > 0.9
			and wr.global_position.distance_to(rig.global_transform * rig.right_hand.wrist()) < 0.05,
			"vr left-handed: compass on the right finger hand's wrist, face out")
	rig.settings["main_hand"] = "right"
	rig.left.transform = Transform3D(Basis(), Vector3(-0.2, 1.1, -0.3))
	rig.left_hand.pose_from_controller(rig.left.transform, open)
	rig.place_compass()
	_check.call(wr.visible and wr.global_basis.y.x < -0.9
			and wr.global_position.distance_to(rig.global_transform * rig.left_hand.wrist()) < 0.05,
			"vr compass: on the left finger hand's wrist, face out")
	rig.free()


## Seated play: the origin stands `height` over the level's floor; the menu calibrates it from the head.
func _test_height(root: Node, world: WorldView) -> void:
	_check.call(VrSettings.clean("height", 5) == 1.0 and VrSettings.clean("height", "-9") == -0.5
			and VrSettings.clean("height", "nan") == null and VrSettings.clean("main_hand", "left") == "left"
			and VrSettings.clean("main_hand", "both") == null and VrSettings.clean("calibrate", true) == null,
			"vr height / main hand: values checked and clamped")
	var a := VrSettings.from_args({"vr-height": "0.3", "vr-main-hand": "left"})
	var bad := VrSettings.from_args({"vr-height": "tall", "vr-main-hand": "both"})
	_check.call(is_equal_approx(a["height"], 0.3) and a["main_hand"] == "left" and bad["height"] == 0.0
			and bad["main_hand"] == "right", "vr height / main hand: options read, bad ones ignored")
	_check.call(VrSettings.label("height", 0.4) == "+0.40 m" and VrSettings.label("height", -0.25) == "-0.25 m"
			and VrSettings.label("height", 0.0) == "+0.00 m" and VrSettings.label("main_hand", "left").begins_with("left"),
			"vr height / main hand: labels")
	_check.call(is_equal_approx(VrSettings.step({"height": 0.95}, "height", 1), 1.0)
			and VrSettings.step({"height": 1.0}, "height", 1) == 1.0
			and is_equal_approx(VrSettings.step({"height": 0.0}, "height", -1), -0.05), "vr height: menu steps of 5 cm, stops at the ends")
	_check.call(is_equal_approx(VrRig.calibrated_height(1.2), 0.4) and VrRig.calibrated_height(0.2) == 1.0
			and VrRig.calibrated_height(2.5) == -0.5 and VrRig.calibrated_height(NAN) == null
			and is_equal_approx(VrRig.calibrated_height(1.53), 0.05), "vr height: calibration snapped and clamped")
	var rig := VrRig.new(world, {"height": 0.4, "blink": false})
	root.add_child(rig)
	rig.save_path = _tmp
	rig.camera.position = Vector3(0, 1.2, 0)   # seated
	var p := world.snapshot.player_pos
	rig.go_to_square(p)
	var fy := VrWalk.floor_y(p.z)
	_check.call(is_equal_approx(rig.floor_y(), fy) and is_equal_approx(rig.global_position.y, fy + 0.4)
			and is_equal_approx(rig.camera.global_position.y, fy + FirstPersonCamera.EYE_H),
			"vr height: the origin stands 0.4 m over the floor, the seated head at standing eye height")
	rig.go_to_square(p + Vector3i(0, 0, 1))
	_check.call(is_equal_approx(rig.floor_y(), VrWalk.floor_y(p.z + 1))
			and is_equal_approx(rig.global_position.y, rig.floor_y() + 0.4), "vr height: kept on a level change")
	rig.go_to_square(p)
	rig.settings["height"] = 0.0
	rig.place_height()
	rig.press(rig.left, "menu_button")
	rig.menu.row = _row_of("calibrate")
	rig.press(rig.left, "trigger_click")   # the off hand's trigger: the row the stick picked
	_check.call(is_equal_approx(rig.settings["height"], 0.4) and is_equal_approx(rig.global_position.y, fy + 0.4)
			and is_equal_approx(rig.floor_y(), fy), "vr height: calibrate from a seated head (1.2 m -> +0.40 m), the floor stays")
	rig.camera.position.y = 1.7
	rig.step(0.1, {"move": Vector2(-1, 0)})
	rig.step(0.1, {})
	_check.call(is_equal_approx(rig.settings["height"], 0.4), "vr height: stick left on the calibrate row does nothing")
	rig.step(0.1, {"move": Vector2(1, 0)})
	rig.step(0.1, {})
	_check.call(is_equal_approx(rig.settings["height"], -0.1) and is_equal_approx(rig.global_position.y, fy - 0.1),
			"vr height: stick right calibrates too (standing tall: -0.10 m)")
	rig.menu.row = _row_of("height")
	rig.step(0.1, {"move": Vector2(1, 0)})
	rig.step(0.1, {})
	_check.call(is_equal_approx(rig.settings["height"], -0.05) and is_equal_approx(rig.global_position.y, fy - 0.05),
			"vr height: the menu row moves the origin at once")
	rig.press(rig.left, "menu_button")
	var saved := VrSettings.load_file(_tmp)
	_check.call(is_equal_approx(saved["height"], -0.05) and not saved.has("calibrate") and not rig.settings.has("calibrate"),
			"vr height: saved and loaded; calibrate isn't a setting")
	rig.free()


func _test_values() -> void:
	_check.call(VrSettings.clean("blink", "off") == false and VrSettings.clean("blink", true) == true
			and VrSettings.clean("blink", "maybe") == null, "vr settings: on/off")
	_check.call(VrSettings.clean("speed", "inf") == null and VrSettings.clean("speed", 0.1) == 0.5
			and VrSettings.clean("evil", 1) == null and VrSettings.clean("turn", 3) == null, "vr settings: values checked")
	var s := VrSettings.from_args({"vr-layout": "vive", "vr-hands": "boxes", "vr-blink": "off", "vr-move-dir": "hand",
			"vr-turn": "off", "vr-swap-sticks": "on", "vr-turn-speed": "1000"})
	_check.call(s["layout"] == "vive" and s["hands"] == "boxes" and s["blink"] == false and s["move_dir"] == "hand"
			and s["turn"] == "off" and s["swap_sticks"] == true and s["turn_speed"] == 360.0, "vr settings: new options")
	var base := VrSettings.DEFAULTS.duplicate()
	base["vignette"] = 0.0
	_check.call(VrSettings.from_args({"vr-speed": "3"}, base)["vignette"] == 0.0, "vr settings: options go over the file")
	var d := VrSettings.DEFAULTS
	_check.call(VrSettings.step(d, "snap_deg", 1) == 60.0 and VrSettings.step({"speed": 5.0}, "speed", 1) == 5.0
			and VrSettings.step(d, "blink", 1) == false and VrSettings.step({"turn": "off"}, "turn", 1) == "snap",
			"vr settings: menu steps")
	_check.call(VrSettings.label("vignette", 0.0) == "off" and VrSettings.label("blink", true) == "on",
			"vr settings: labels")


func _write(text: String) -> void:
	var f := FileAccess.open(_tmp, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_file() -> void:
	var s := VrSettings.DEFAULTS.duplicate()
	s["turn"] = "smooth"
	s["vignette"] = 0.0
	s["layout"] = "vive"
	_check.call(VrSettings.save_file(s, _tmp) and VrSettings.load_file(_tmp) == s, "vr settings: file round trip")
	_write('{"speed": "fast", "turn": 3, "evil": 1, "vignette": 1e9, "hands": "buttons"}')
	var l := VrSettings.load_file(_tmp)
	var want := VrSettings.DEFAULTS.duplicate()
	want["vignette"] = 1.0
	want["hands"] = "buttons"
	_check.call(l == want, "vr settings: bad file values dropped, good ones kept")
	_write("[1, 2]")
	_check.call(VrSettings.load_file(_tmp) == VrSettings.DEFAULTS, "vr settings: not an object -> defaults")
	_write("{\"speed\": 3.0, \"pad\": \"%s\"}" % "x".repeat(VrSettings.MAX_FILE_BYTES))
	_check.call(VrSettings.load_file(_tmp) == VrSettings.DEFAULTS, "vr settings: oversized file -> defaults")
	_check.call(VrSettings.load_file(TestDir.path("no_such_vr.json")) == VrSettings.DEFAULTS, "vr settings: no file -> defaults")


func _test_layouts() -> void:
	_check.call(VrRig.layout_for("/interaction_profiles/htc/vive_controller") == "vive"
			and VrRig.layout_for("/interaction_profiles/valve/index_controller") == "quest"
			and VrRig.layout_for("") == "quest", "vr layout: from the interaction profile")
	_check.call(VrRig.wand_turn(Vector2(0.8, 0), false, false) == Vector2.ZERO, "vr layout: wand pad untouched by a click does nothing")
	_check.call(VrRig.wand_turn(Vector2(0.6, 0.4), false, true) == Vector2(0.6, 0), "vr layout: wand smooth turn follows the pad")
	_check.call(VrRig.wand_turn(Vector2(0, 0.9), true, false).y > VrRig.AIM_ON, "vr layout: wand click up aims")
	_check.call(VrRig.wand_turn(Vector2(0.9, 0.1), true, false).x > VrRig.TURN_ON, "vr layout: wand click right snaps")
	_check.call(VrRig.wand_turn(Vector2(0.1, -0.9), true, false) == Vector2.ZERO
			and VrRig.wand_turn(Vector2(0.1, 0.1), true, false) == Vector2.ZERO, "vr layout: wand click down / centre isn't a turn")


func _test_hand() -> void:
	var open := VrHand.curls_from_buttons(0.0, false, 0.0, false)
	var fist := VrHand.curls_from_buttons(1.0, true, 1.0, true)
	_check.call(is_equal_approx(open[1], 0.1) and is_equal_approx(open[2], 0.35) and is_equal_approx(open[0], 0.2)
			and fist[1] == 1.0 and fist[4] == 1.0,
			"vr hand: curls from trigger, grip and thumb")
	var flat := VrHand.rest_joints(PackedFloat32Array([0, 0, 0, 0, 0]))
	var curled := VrHand.rest_joints(PackedFloat32Array([1, 1, 1, 1, 1]))
	_check.call(flat.size() == VrHand.JOINTS and flat[10].z < flat[7].z - 0.07 and absf(flat[10].y) < 0.001,
			"vr hand: open index points forward")
	_check.call(curled[10].y < -0.02 and curled[10].distance_to(curled[1]) < flat[10].distance_to(flat[1]),
			"vr hand: curled index bends toward the palm")
	_check.call(is_equal_approx(curled[8].distance_to(curled[7]), 0.040) and is_equal_approx(curled[15].distance_to(curled[14]), 0.022),
			"vr hand: bones keep their length")
	var r := VrHand.new(false)
	var l := VrHand.new(true)
	r.pose_from_controller(Transform3D.IDENTITY, open)
	l.pose_from_controller(Transform3D.IDENTITY, open)
	_check.call(r.visible and r.source == "buttons" and r.joints[7].y > r.joints[22].y and r.joints[1].z > 0.0,
			"vr hand: around the controller, index on top, wrist behind")
	_check.call(is_equal_approx(l.joints[1].x, -r.joints[1].x) and is_equal_approx(l.joints[1].y, r.joints[1].y),
			"vr hand: left is the mirror image")
	r.set_joints(PackedVector3Array([Vector3.ONE]))
	_check.call(r.joints[1] != Vector3.ONE, "vr hand: wrong joint count ignored")
	_check.call(not r.pose_from_tracker(null), "vr hand: no tracker, no tracked pose")
	var t := XRHandTracker.new()
	t.has_tracking_data = true
	var want := PackedVector3Array()
	for i in VrHand.JOINTS:
		want.append(Vector3(i * 0.01, 1.2, -0.3))
		t.set_hand_joint_transform(i, Transform3D(Basis(), want[i]))
		t.set_hand_joint_flags(i, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID)
	_check.call(r.pose_from_tracker(t) and r.source == "tracked" and r.joints == want, "vr hand: finger tracking joints used")
	t.set_hand_joint_flags(9, 0)
	_check.call(not r.pose_from_tracker(t) and r.joints == want, "vr hand: a lost joint keeps the last pose")
	r.free()
	l.free()


## The VR compass: a rose turned to north on the left wrist or a belt ring, Compass's blips on it.
func _test_compass(root: Node, world: WorldView) -> void:
	var flat := VrCompass.face_north(Vector3.UP, Vector3.FORWARD)
	var side := VrCompass.face_north(Vector3(1, 0.2, 0), Vector3.FORWARD)
	var odd := VrCompass.face_north(Vector3.FORWARD, Vector3.UP)
	_check.call(flat.is_equal_approx(Basis()) and (-side.z).is_equal_approx(Vector3.FORWARD)
			and side.y.is_equal_approx(Vector3(1, 0.2, 0).normalized()) and odd.is_conformal()
			and odd.y.is_equal_approx(Vector3.FORWARD), "vr compass: the rose faces its normal, north stays north")
	_check.call(VrCompass.dir_of(0).is_equal_approx(Vector3.FORWARD) and VrCompass.dir_of(90).is_equal_approx(Vector3.RIGHT),
			"vr compass: bearings on the rose (north -Z, east +X)")
	var list: Array[Vector3] = [Vector3(90, 2, Snapshot.Creature.HOSTILE), Vector3(270, 35, Snapshot.Creature.HOSTILE),
			Vector3(180, 50, Snapshot.Creature.NEUTRAL), Vector3(0, 5, Snapshot.Creature.FRIENDLY)]
	var lay := VrCompass.layout(list, 1.0)
	_check.call(lay.size() == 4 and lay[0][0] == "arrow" and (lay[0][1] as Vector3).x > 1.0 and lay[0][2] > lay[1][2]
			and (lay[0][3] as Color).a > (lay[1][3] as Color).a and lay[2][0] == "dot" and (lay[2][1] as Vector3).z > 0.5
			and (lay[3][3] as Color).g > 0.9, "vr compass: hostile arrows on the rim (nearer bigger), dots inside")
	var rig := VrRig.new(world, {"compass": "wrist", "hands": "boxes"})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	rig.left.transform = Transform3D(Basis(), Vector3(-0.2, 1.1, -0.3))
	rig.compass.set_blips(list)
	rig.pose_hands()
	rig.place_compass()
	var wr := rig.compass.wrist
	_check.call(wr.visible and not rig.compass.belt.visible and wr.arrow_count() == 2 and wr.dot_count() == 2
			and wr.global_position.distance_to(rig.left.global_position) < 0.25 and wr.global_basis.y.x < -0.9,
			"vr compass: on the back of the left wrist (box hand), creatures shown")
	var lv: Array[Vector4] = [Vector4(90, 2, Snapshot.Creature.HOSTILE, 0), Vector4(270, 35, Snapshot.Creature.HOSTILE, 1),
			Vector4(180, 50, Snapshot.Creature.NEUTRAL, -3), Vector4(0, 5, Snapshot.Creature.FRIENDLY, 0)]
	var lay2 := VrCompass.layout(list, 1.0, PackedInt32Array([0, 1, -3, 0]))
	rig.compass.set_level_blips(lv)
	_check.call(lay2[1][0] == "ring" and lay2[2][0] == "ring" and lay2[0][0] == "arrow"
			and is_equal_approx((lay2[1][3] as Color).a, (lay[1][3] as Color).a * Compass.OTHER_LEVEL_FADE)
			and wr.arrow_count() == 1 and wr.dot_count() == 1 and wr.ring_count() == 2
			and wr.chevron_counts() == Vector2i(1, 2) and rig.compass.blip_levels.size() == 4,
			"vr compass: creatures on other levels are faint rings with up / down chevrons (two for 2+ levels)")
	rig.compass.set_blips(list)
	_check.call(wr.ring_count() == 0 and wr.arrow_count() == 2 and rig.compass.blip_levels.is_empty(),
			"vr compass: plain blips clear the levels")
	rig.settings["compass"] = "belt"
	rig.place_compass()
	var head := rig.camera.global_position
	var bt := rig.compass.belt
	_check.call(bt.visible and not wr.visible and is_equal_approx(bt.global_position.y, head.y - VrCompass.BELT_DROP)
			and bt.global_basis.is_equal_approx(Basis()), "vr compass: belt ring level, under the head")
	rig.compass.opacity = 0.0
	rig.place_compass()
	_check.call(not bt.visible and not wr.visible, "vr compass: opacity 0 hides it")
	rig.compass.opacity = 1.0
	rig.settings["compass"] = "wrist"
	rig.settings["hands"] = "auto"
	rig.pose_hands()
	rig.place_compass()
	_check.call(not wr.visible, "vr compass: no tracked left hand, no wrist compass")
	_check.call(VrSettings.from_args({"vr-compass": "both"})["compass"] == "both"
			and VrSettings.from_args({"vr-compass": "hat"})["compass"] == "wrist", "vr compass: setting and option checked")
	rig.free()


## One hand system: the rig's hands are the only hands; the body's arms reach for their wrists.
func _test_body(root: Node, world: WorldView, rig: VrRig) -> void:
	var pb := PlayerBody.new()
	root.add_child(pb)
	pb.apply(world.snapshot, world.tables)
	var head := rig.camera.global_position
	pb.global_position = Vector3(head.x, rig.global_position.y, head.z)
	rig.left.transform = Transform3D(Basis(), rig.camera.position + Vector3(-0.25, -0.3, -0.4))
	rig.body = pb
	rig.drive_body()   # box hands showing (set just before)
	var hl := pb.get_node_or_null("hand_l") as Node3D
	var al := pb.get_node_or_null("arm_l") as Node3D
	var w: Variant = rig.wrist(0)
	_check.call(hl != null and not hl.visible and w is Vector3
			and (w as Vector3).is_equal_approx(rig.left.global_transform * VrRig.BOX_WRIST)
			and not al.transform.basis.is_equal_approx(Basis.IDENTITY),
			"vr rig: one hand system: body hands hidden, the arm reaches for the box hand")
	rig.settings["hands"] = "buttons"
	rig._boxes[0].visible = false
	rig.left_hand.pose_from_controller(rig.left.transform, VrHand.curls_from_buttons(0.0, false, 0.0, false))
	w = rig.wrist(0)
	_check.call(w is Vector3 and (w as Vector3).is_equal_approx(rig.global_transform * rig.left_hand.joints[1]),
			"vr rig: the arm reaches for the finger hand's wrist")
	rig.left_hand.visible = false
	rig._boxes[1].visible = false
	_check.call(rig.wrist(0) == null and rig.wrist(1) == null, "vr rig: no hand shown, the arm hangs")
	var gloved: Array[Dictionary] = [{"part": "hand_l", "kind": "skin", "colour": Color.RED},
			{"part": "hand_l", "kind": "worn", "colour": Color.BLUE}, {"part": "hand_l", "kind": "blood", "colour": Color.BLACK},
			{"part": "hand_r", "kind": "worn", "colour": Color.GREEN}]
	var bare: Array[Dictionary] = []
	_check.call(VrRig.hand_colour(gloved, "hand_l") == Color.BLUE and VrRig.hand_colour(bare, "hand_l") == VrHand.SKIN,
			"vr rig: hands take the outermost glove's colour")
	_check.call(rig.left_hand.colour == VrRig.hand_colour(pb.pieces, "hand_l"), "vr rig: hand colour from the body")
	rig.body = null
	rig.settings["hands"] = "boxes"
	pb.free()


func _test_rig(root: Node, world: WorldView) -> void:
	var rig := VrRig.new(world, {"turn": "off", "blink": false})
	root.add_child(rig)
	rig.save_path = _tmp
	rig.camera.position = Vector3(0, 1.7, 0)
	var player := world.snapshot.player_pos
	rig.go_to_player(player)
	var yaw := rig.global_basis.get_euler().y
	rig.step(0.016, {"turn": Vector2(1, 0)})
	_check.call(is_equal_approx(rig.global_basis.get_euler().y, yaw), "vr rig: turning off means no stick turn")
	_check.call(rig._fade == 0.0, "vr rig: no blink when blink is off")
	rig.pose_hands()
	_check.call(not rig.left_hand.visible and not rig._boxes[0].visible, "vr rig: no hands without tracked controllers")
	rig.settings["hands"] = "boxes"
	rig.pose_hands()
	_check.call(rig._boxes[0].visible and rig._boxes[1].visible, "vr rig: simple box hands")
	_test_body(root, world, rig)
	# Moving toward the hand: the left controller points away from the player, the head at them.
	rig.settings["move_dir"] = "hand"
	rig.left.transform = Transform3D(rig.camera.transform.basis.rotated(Vector3.UP, PI), Vector3(-0.2, 1.2, 0))
	var head := rig.camera.global_position
	var to_player := world.coords.ms_center_to_world(player) - head
	to_player.y = 0
	rig.step(0.25, {"move": Vector2(0, 1)})
	_check.call((rig.camera.global_position - head).dot(to_player) <= 0.0, "vr rig: moves where the hand points")
	rig.settings["swap_sticks"] = true
	_check.call(rig._move_ctrl() == rig.right and rig._turn_ctrl() == rig.left, "vr rig: swapped sticks")
	rig.settings["swap_sticks"] = false
	# The menu: open, change the first line with the trigger, move down, change with the stick, close + save.
	rig.press(rig.left, "menu_button")
	_check.call(rig.menu_open() and rig.menu.row == 0, "vr menu: left menu button opens it")
	rig.press(rig.right, "trigger_click")
	_check.call(rig.settings["move"] == "teleport", "vr menu: trigger changes the line")
	head = rig.camera.global_position
	rig.step(0.1, {"move": Vector2(0, -1)})
	rig.step(0.1, {})
	rig.step(0.1, {"move": Vector2(-1, 0)})
	_check.call(rig.menu.row == 1 and rig.settings["move_dir"] == "head", "vr menu: stick picks and changes lines")
	_check.call(rig.camera.global_position == head, "vr menu: no walking while it is open")
	rig.press(rig.left, "menu_button")
	_check.call(not rig.menu_open() and VrSettings.load_file(_tmp) == rig.settings, "vr menu: closing saves the settings")
	# Vive layout buttons.
	rig.settings["layout"] = "vive"
	_check.call(rig.current_layout() == "vive", "vr layout: chosen layout wins over auto")
	rig.teleport_to(rig.camera.global_position + Vector3(3, 0, 0))
	rig.press(rig.left, "primary_click")
	_check.call(rig.walk.square_at(rig.camera.global_position, rig.z) == rig.walk.nearest_standable(player, true),
			"vr layout: wand left pad click goes back to the player")
	var z0 := rig.z
	var below: Variant = rig.walk.nearest_standable(rig.walk.square_at(rig.camera.global_position, z0 - 1))
	rig.press(rig.right, "primary_click", Vector2(0, -0.9))
	_check.call(rig.z == (z0 - 1 if below != null else z0), "vr layout: wand right pad click down = level down")
	rig.settings["layout"] = "quest"
	rig.press(rig.right, "grip_click")
	rig.update_hands(0.016, true)
	rig.release(rig.right, "grip_click")
	_check.call(rig.hands == null and rig.let_go(rig.right) == "" and rig.buzzes[0] == 0 and rig.buzzes[1] == 0,
			"vr rig: without hands the grip grabs nothing")
	# D5: a door leaf freed under a hand (its submap dropped) that one hand holds and the other outlines.
	var acts := ItemActions.new()
	var hands := Hands.new(world, acts)
	rig.hands = hands
	var sq := Vector3i(-900, -900, 0)
	var leaf := Grabbable.door(world, {"square": sq, "local": Vector3.ZERO, "along_x": true, "color": Color.GRAY,
			"glass": false, "open": false, "locked": false})
	root.add_child(leaf)
	var t := {"kind": "door", "node": leaf, "item": null, "square": sq, "point": leaf.global_position, "dist": 0.0,
			"name": "door"}
	hands.set_hand_pose("vr_l", rig.left.global_transform, true)
	var grabbed := hands.grab("vr_l", t)
	hands.hover("vr_r", t)
	leaf.free()
	rig.update_hands(0.016, true)
	var hover_node: Variant = hands.hand("vr_r").hover.get("node")
	_check.call(grabbed and hands.holding("vr_l").is_empty() and (typeof(hover_node) == TYPE_NIL or is_instance_valid(hover_node)),
			"vr rig: a door that went away under a hand is let go")
	world.door_state.erase(sq)
	rig.free()
	hands.free()
	acts.free()
