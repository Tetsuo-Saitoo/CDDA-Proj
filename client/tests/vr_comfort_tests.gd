extends RefCounted
## VR settings, controller layouts, the settings menu and hands (VrSettings, VrMenu, VrHand, VrRig), run by
## vr_tests.gd on its mock world. No XR runtime here: controllers are inactive, the test presses buttons.

const TMP := "user://fp3d_test_vr.json"

var _check: Callable


func run(root: Node, check: Callable, world: WorldView) -> void:
	_check = check
	_test_values()
	_test_file()
	_test_layouts()
	_test_hand()
	_test_rig(root, world)
	_test_compass(root, world)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))


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
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_file() -> void:
	var s := VrSettings.DEFAULTS.duplicate()
	s["turn"] = "smooth"
	s["vignette"] = 0.0
	s["layout"] = "vive"
	_check.call(VrSettings.save_file(s, TMP) and VrSettings.load_file(TMP) == s, "vr settings: file round trip")
	_write('{"speed": "fast", "turn": 3, "evil": 1, "vignette": 1e9, "hands": "buttons"}')
	var l := VrSettings.load_file(TMP)
	var want := VrSettings.DEFAULTS.duplicate()
	want["vignette"] = 1.0
	want["hands"] = "buttons"
	_check.call(l == want, "vr settings: bad file values dropped, good ones kept")
	_write("[1, 2]")
	_check.call(VrSettings.load_file(TMP) == VrSettings.DEFAULTS, "vr settings: not an object -> defaults")
	_write("{\"speed\": 3.0, \"pad\": \"%s\"}" % "x".repeat(VrSettings.MAX_FILE_BYTES))
	_check.call(VrSettings.load_file(TMP) == VrSettings.DEFAULTS, "vr settings: oversized file -> defaults")
	_check.call(VrSettings.load_file("user://no_such_vr.json") == VrSettings.DEFAULTS, "vr settings: no file -> defaults")


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
	rig.save_path = TMP
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
	_check.call(not rig.menu_open() and VrSettings.load_file(TMP) == rig.settings, "vr menu: closing saves the settings")
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
	rig.free()
