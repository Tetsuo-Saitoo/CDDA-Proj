extends RefCounted
## Eye tracking (VrGaze, VrRig.look): a simulated eye tracker drives the gaze; off, untracked, gone past a blink or
## hostile poses fall back to the head; the setting; gaze never reaches the settings file.

var _check: Callable
var _pose: Variant = null   # what the simulated eye tracker gives (a member: lambdas copy locals)
var _leans: Array = []      # what the rig's on_lean / on_unlean got


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr gaze")
	_test_source()
	_test_hostile()
	_test_rig(root)
	_test_menu(root)
	_test_look(root)
	_test_zoom(root)
	_test_lean(root)


## The head at the origin looking along -Z, turned `yaw` degrees left.
static func _head(yaw := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)), Vector3(0, 1.6, 0))


## An eye pose at the head looking `right` degrees right and `up` degrees up of the head's forward.
static func _eyes(head: Transform3D, right: float, up: float) -> Transform3D:
	var b := head.basis * Basis(Vector3.UP, deg_to_rad(-right)) * Basis(Vector3.RIGHT, deg_to_rad(up))
	return Transform3D(b, head.origin + head.basis * Vector3(0, -0.01, -0.02))


func _test_source() -> void:
	var g := VrGaze.new()
	g.eyes = func() -> Variant: return _pose
	var h := _head()
	var want := (-_eyes(h, 20, -10).basis.z).normalized()
	_pose = _eyes(h, 20, -10)
	var r := g.ray(h, 1.0)
	var by_eyes: bool = r["eyes"] and (r["dir"] as Vector3).is_equal_approx(want) and r["from"] == h.origin
	# A blink: the eyes lost for less than HOLD_S still look where they did, turned with the head.
	_pose = null
	var h2 := _head(30)
	var r2 := g.ray(h2, 1.0 + VrGaze.HOLD_S * 0.5)
	var held: bool = r2["eyes"] and (r2["dir"] as Vector3).is_equal_approx(h2.basis * (h.basis.inverse() * want))
	# Longer: the head.
	var r3 := g.ray(h2, 1.0 + VrGaze.HOLD_S * 2.0)
	var head: bool = not r3["eyes"] and (r3["dir"] as Vector3).is_equal_approx(-h2.basis.z) and not g.eyes_live(2.0)
	# Off: the head, even with the eyes tracked.
	_pose = _eyes(h, 20, -10)
	g.on = false
	var r4 := g.ray(h, 3.0)
	var off: bool = not r4["eyes"] and (r4["dir"] as Vector3).is_equal_approx(Vector3.FORWARD)
	g.on = true
	var none := VrGaze.new()   # no eye tracker at all
	var r5 := none.ray(h, 0.0)
	var no_tracker: bool = not r5["eyes"] and (r5["dir"] as Vector3).is_equal_approx(Vector3.FORWARD)
	_check.call(by_eyes and held and head and off and no_tracker,
			"vr gaze: tracked eyes drive the ray; a blink holds it; lost, off or no tracker: the head (%s, %s)" % [r, r3])


func _test_hostile() -> void:
	var g := VrGaze.new()
	g.eyes = func() -> Variant: return _pose
	var h := _head()
	var bad: Array = [
		Transform3D(Basis(), Vector3(NAN, 1.6, 0)),
		Transform3D(Basis(Vector3(INF, 0, 0), Vector3.UP, Vector3.BACK), h.origin),
		Transform3D(Basis(), h.origin + Vector3(0, 0, 1.0)),           # an origin 1 m off the head
		_eyes(h, 80, 0),                                                # past MAX_DEG
		Transform3D(Basis.from_scale(Vector3(0, 0, 0.1)), h.origin),   # no forward
		"eyes", 5, [h], null,
	]
	var ok := true
	var i := 0
	for p: Variant in bad:
		_pose = p
		g.forget()
		var r := g.ray(h, float(i))
		if r.is_empty() or r["eyes"] or not (r["dir"] as Vector3).is_equal_approx(Vector3.FORWARD):
			ok = false
			print("  bad pose %d believed: %s" % [i, r])
		i += 1
	# A bad pose right after a good one: the blink hold, never the bad direction.
	_pose = _eyes(h, 10, 0)
	g.ray(h, 10.0)
	_pose = _eyes(h, 85, 0)
	var r := g.ray(h, 10.1)
	var holds: bool = r["eyes"] and (r["dir"] as Vector3).is_equal_approx((-_eyes(h, 10, 0).basis.z).normalized())
	var junk_head := g.ray(Transform3D(Basis(), Vector3(INF, 0, 0)), 11.0).is_empty() \
			and g.ray(Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO), 11.0).is_empty()
	_check.call(ok and holds and junk_head,
			"vr gaze: NaN, inf, far, too wide, flat or wrong-typed eye poses fall back to the head; a bad head gives none")


func _test_rig(root: Node) -> void:
	var world := WorldView.new()
	world.snapshot = Snapshot.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	# No OpenXR here: the real eye source has nothing, so the head.
	var r0 := rig.look()
	var desktop: bool = not r0.is_empty() and not r0["eyes"] and (r0["dir"] as Vector3).is_equal_approx(Vector3.FORWARD)
	rig.gaze.eyes = func() -> Variant: return _pose
	_pose = _eyes(rig.camera.global_transform, -15, 5)
	var r1 := rig.look()
	var eyes: bool = r1["eyes"] and (r1["dir"] as Vector3).is_equal_approx((-(_pose as Transform3D).basis.z).normalized())
	rig.eye_on = func(id: String) -> bool: return id != "tracker" and id != "zoom"
	rig.apply_eye_switches()
	var r2 := rig.look()
	var off: bool = not r2["eyes"] and not rig.gaze.eyes_live(Time.get_ticks_msec() / 1000.0) \
			and not rig.zoom.enabled and rig.label.enabled
	rig.eye_on = func(id: String) -> Variant: return "yes"   # junk from the switch: off
	rig.apply_eye_switches()
	off = off and not rig.gaze.on and not rig.label.enabled
	rig.eye_on = Callable()
	rig.apply_eye_switches()
	off = off and rig.gaze.on and rig.zoom.enabled
	# The VR settings file holds no gaze, and no longer the switch (HudSettings' "tracker"; an old vr.json's `eyes`
	# is ignored: eye tracking is opt-in).
	var path := "user://vr_gaze_test.json"
	var saved := VrSettings.save_file(rig.settings, path)
	var real := UserFiles.at(path)
	var back: Variant = JSON.parse_string(FileAccess.get_file_as_string(real))
	var keys_only: bool = saved and back is Dictionary and (back as Dictionary).size() == VrSettings.DEFAULTS.size() \
			and VrSettings.DEFAULTS.keys().all(func(k: String) -> bool: return (back as Dictionary).has(k)) \
			and not (back as Dictionary).has("eyes")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(real))
	var setting: bool = not VrSettings.DEFAULTS.has("eyes") and not VrSettings.ROWS.any(func(row: Array) -> bool: return row[0] == "eyes")
	_check.call(desktop and eyes and off and keys_only and setting,
			"vr gaze: the rig looks by the head without eye tracking, by the eyes with it; the switches turn it off; vr.json has no eye switch")
	rig.free()
	world.free()


static func _row_of(key: String) -> int:
	for i in VrSettings.ROWS.size():
		if VrSettings.ROWS[i][0] == key:
			return i
	return -1


## The settings menu: where the tracked eyes rest on it is pointed at while the hand points away; only the trigger
## changes the row; eyes off, or the head alone, point at nothing (the hand's short ray, as before).
func _test_menu(root: Node) -> void:
	var world := WorldView.new()
	world.snapshot = Snapshot.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	rig.gaze.eyes = func() -> Variant: return _pose
	rig.press(rig.left, "menu_button")
	var row := _row_of("speed")
	var at := rig.menu.global_transform * Vector3(0.2, -(row + 1) * VrMenu.LINE_H, 0)
	var head := rig.camera.global_transform
	_pose = Transform3D(Basis.looking_at(at - head.origin, Vector3.UP), head.origin)
	rig.right.global_position = head.origin + Vector3(0.2, -0.4, 0)
	rig.right.look_at(rig.right.global_position + rig.menu.global_basis.z, Vector3.UP)   # pointing away
	var speed0: float = rig.settings["speed"]
	rig.update_pointer(true)
	var hover: bool = rig.menu.row == row and rig.pointer_dot.visible \
			and rig.pointer_dot.global_position.distance_to(at) < 0.001 and rig.settings["speed"] == speed0
	rig.press(rig.right, "trigger_click")
	var pressed: bool = rig.settings["speed"] == speed0 + 0.5
	rig.gaze.on = false
	rig.update_pointer(true)
	var off := rig.pointer.visible and not rig.pointer_dot.visible
	rig.gaze.on = true
	rig.eye_on = func(id: String) -> bool: return id != "menus"
	rig.apply_eye_switches()
	rig.update_pointer(true)
	var menus_off := rig.gaze.on and rig.pointer.visible and not rig.pointer_dot.visible
	rig.eye_on = Callable()
	rig.apply_eye_switches()
	_pose = null
	rig.gaze.forget()
	rig.update_pointer(true)
	var head_only := rig.pointer.visible and not rig.pointer_dot.visible
	_check.call(hover and pressed and off and menus_off and head_only,
			"vr gaze: the eyes on the menu point at a row, the trigger changes it; eyes off, the menus switch off or head only: nothing pointed")
	rig.settings["speed"] = speed0
	rig.press(rig.left, "menu_button")
	rig.free()
	world.free()


## Look at: the left X held shows a ring where the player looks and names it; looking never teleports; the main
## trigger does, with cheats on (else a buzz); letting go hides it.
func _test_look(root: Node) -> void:
	var world := WorldView.new()
	var snap := Snapshot.new()
	snap.player_pos = Vector3i(10, 10, 0)
	world.snapshot = snap
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var asked: Array = []
	rig.looking.teleport_to = func(sq: Vector3i) -> int:
		asked.append(sq)
		return 3
	rig.looking.update(0.1, world, rig.look(), true, true)
	var idle := not rig.looking.visible
	rig.press(rig.left, "ax_button")
	rig.looking.update(0.1, world, rig.look(), true, true)
	var nothing: bool = rig.looking.held and rig.looking.visible and rig.looking.marked == null \
			and rig.looking.text == "nothing there"
	rig.press(rig.right, "trigger_click")
	var no_square := asked.is_empty()
	var sq := Vector3i(13, 10, 0)
	var hit := {"hit": true, "square": sq, "point": world.coords.ms_center_to_world(sq), "what": "a wall",
			"dir": Vector3(1, 0, 0)}
	rig.looking.show_hit(world, hit, rig.camera.global_position, false)
	var shown: bool = rig.looking.marked is Vector3i and rig.looking.text.begins_with("a wall, 3 squares") \
			and not rig.looking.text.contains("trigger")
	rig.cheats_allowed = false
	rig.press(rig.right, "trigger_click")
	var no_cheats := asked.is_empty()
	rig.cheats_allowed = true
	rig.press(rig.left, "trigger_click")   # the off hand's trigger: a buzz
	var off_hand := asked.is_empty()
	rig.press(rig.right, "trigger_click")
	var went := asked == [rig.looking.marked]
	rig.release(rig.left, "ax_button")
	var gone: bool = not rig.looking.held and not rig.looking.visible and rig.looking.marked == null
	rig.looking.update(0.1, world, rig.look(), true, true)
	_check.call(idle and nothing and no_square and shown and no_cheats and off_hand and went and gone and not rig.looking.visible,
			"vr gaze: left X held: a ring where you look, named; only the main trigger teleports (cheats on); let go: gone (%s)"
			% [asked])
	rig.free()
	world.free()


## Zoom: the right stick click held shows a magnified inset where the player looks (narrow camera, its own layer
## unseen by that camera, level horizon), its aim smoothed; let go, a bad gaze, a menu or off: gone, not rendering.
func _test_zoom(root: Node) -> void:
	var world := WorldView.new()
	world.snapshot = Snapshot.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var z := rig.zoom
	var from := rig.camera.global_position
	var d1 := Vector3(0.3, -0.1, -1.0).normalized()
	rig.press(rig.right, "primary_click")
	var held := z.held
	z.update(0.016, {"from": from, "dir": d1, "eyes": true}, true)
	var aim := -z.cam.global_basis.z
	var shown: bool = z.visible and aim.is_equal_approx(d1) and is_equal_approx(z.cam.fov, VrZoom.INSET_DEG / VrZoom.MAG) \
			and z.view.render_target_update_mode == SubViewport.UPDATE_ALWAYS and z.cam.cull_mask & VrZoom.LAYER == 0 \
			and z.get_child_count() >= 3 and absf(z.cam.global_basis.x.y) < 0.001 \
			and z.global_position.distance_to(from + d1 * VrZoom.DIST_M) < 0.001
	var d2 := Vector3(-0.5, 0.0, -1.0).normalized()
	z.update(0.016, {"from": from, "dir": d2, "eyes": true}, true)
	var a1 := (-z.cam.global_basis.z).angle_to(d2)
	var smooth := a1 > 0.05 and a1 < d1.angle_to(d2)
	for i in 60:
		z.update(0.016, {"from": from, "dir": d2, "eyes": false}, true)
	var follows := (-z.cam.global_basis.z).angle_to(d2) < 0.01 and z.visible
	z.update(0.016, {"from": from, "dir": Vector3(NAN, 0, 0), "eyes": true}, true)
	var junk := not z.visible and z.view.render_target_update_mode == SubViewport.UPDATE_DISABLED
	z.update(0.016, {"from": from, "dir": d1, "eyes": true}, false)
	var menu := not z.visible
	z.enabled = false
	z.update(0.016, {"from": from, "dir": d1, "eyes": true}, true)
	var off := not z.visible
	z.enabled = true
	z.update(0.016, {"from": from, "dir": d1, "eyes": true}, true)
	rig.release(rig.right, "primary_click")
	var let_go: bool = not z.held and not z.visible and z.view.render_target_update_mode == SubViewport.UPDATE_DISABLED
	z.update(0.016, {"from": from, "dir": d1, "eyes": true}, true)
	_check.call(held and shown and smooth and follows and junk and menu and off and let_go and not z.visible,
			"vr zoom: right stick held: a magnified inset where you look, aim smoothed, horizon level; let go, junk, menu or off: gone")
	rig.free()
	world.free()


## A head facing `yaw` degrees left of north, tilted `roll` degrees to the left (negative: right).
static func _tilt(yaw: float, roll: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.BACK, deg_to_rad(roll)), Vector3(0, 1.6, 0))


## Leaning: a sideways head tilt past LEAN_DEG held HOLD_S peeks that way (snapped to the 8 ways); straightening up,
## tilting the other way, a bad pose or the switch off ends it; a short tilt does nothing. The rig calls on_lean /
## on_unlean.
func _test_lean(root: Node) -> void:
	var l := VrLean.new()
	var evs := []
	for i in 3:
		evs.append(l.update(0.1, _tilt(0, 30)))
	var west := evs == ["", "", "lean"] and l.side == Vector2i(-1, 0) and l.update(0.1, _tilt(0, 25)) == ""
	var back := l.update(0.1, _tilt(0, 5)) == "unlean" and l.side == Vector2i.ZERO
	for i in 3:
		l.update(0.1, _tilt(-90, -30))
	var south := l.side == Vector2i(0, 1)
	var other := l.update(0.1, _tilt(-90, -15)) == "" and l.update(0.1, _tilt(-90, -12)) == "" \
			and l.update(0.1, _tilt(-90, 12)) == "unlean"
	for i in 3:
		l.update(0.1, _tilt(-45, 30))
	var nw := l.side == Vector2i(-1, -1)
	var junk := l.update(0.1, Transform3D(Basis(), Vector3(NAN, 0, 0))) == "unlean"
	l.update(0.1, _tilt(0, 30))
	var short := l.update(0.1, _tilt(0, 5)) == "" and l.side == Vector2i.ZERO
	for i in 3:
		l.update(0.1, _tilt(0, 30))
	l.enabled = false
	var off := l.side != Vector2i.ZERO and l.update(0.1, _tilt(0, 30)) == "unlean" and l.update(0.1, _tilt(0, 30)) == ""
	var ways := VrLean.way_of(Vector3(1, 0, 0.1)) == Vector2i(1, 0) and VrLean.way_of(Vector3(0, 0, -1)) == Vector2i(0, -1) \
			and VrLean.way_of(Vector3(INF, 0, 0)) == Vector2i.ZERO and VrLean.way_of(Vector3.UP) == Vector2i.ZERO
	_check.call(west and back and south and other and nw and junk and short and off and ways,
			"vr lean: a sideways head tilt held peeks that way (8 ways); straightening, the other way, junk or off ends it (%s)"
			% [evs])
	var world := WorldView.new()
	world.snapshot = Snapshot.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.on_lean = func(d: Vector2i) -> void: _leans.append(d)
	rig.on_unlean = func() -> void: _leans.append("end")
	rig.camera.transform = _tilt(0, 30)
	for i in 3:
		rig.update_lean(0.1)
	rig.camera.transform = _tilt(0, 0)
	rig.update_lean(0.1)
	rig.eye_on = func(id: String) -> bool: return id != "lean"
	rig.apply_eye_switches()
	rig.camera.transform = _tilt(0, 30)
	for i in 3:
		rig.update_lean(0.1)
	_check.call(_leans == [Vector2i(-1, 0), "end"],
			"vr lean: the rig asks main for the peek and its end; the lean switch off: nothing (%s)" % [_leans])
	rig.free()
	world.free()
