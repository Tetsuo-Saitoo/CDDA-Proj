extends RefCounted
## Blocks E6 / L2: doors dragged open (Grabbable leaves from TerrainMesher, WorldView's registry, thresholds,
## CDDA asks, locked doors, mouse and hand drags, picking, the VR grip) and closed doors blocking VrWalk.
## Run by run_tests.gd on the mock town.

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("doors")
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(world)
	world.set_id_tables(tables)
	world.apply_snapshot(Snapshot.from_data(data))
	var g := _closed_door(world)
	_check.call(world.grabbables.size() > 10 and g != null, "doors: the mock's doors are leaves (%d)" % world.grabbables.size())
	if g != null:
		_test_leaf(world, g)
		_test_local(world, g)
		_test_live(world, g)
		_test_drags(world, g)
		_test_pick(root, world, g)
		_test_vr(root, world, g)
	_test_locked(root, world)
	_test_asks()
	world.free()


## A closed, unlocked door on level 0.
func _closed_door(world: WorldView) -> Grabbable:
	for sq: Vector3i in world.grabbables:
		var g: Grabbable = world.grabbables[sq]
		if sq.z == 0 and not g.cdda_open and not g.locked:
			return g
	return null


func _reset(world: WorldView, g: Grabbable) -> void:
	g.grabbed = false
	g.cdda_open = false
	g.set_angle(0.0)
	world.door_open.erase(g.square)
	world.door_state[g.square]["until"] = 0
	world.door_local = true


func _test_leaf(world: WorldView, g: Grabbable) -> void:
	_check.call(world.catalog.style_for(_ter(world, g.square)).kind == TerrainCatalog.Kind.DOOR and g.angle == 0.0,
			"doors: a closed door's leaf stands closed")
	var c := world.coords.ms_center_to_world(g.square) + Vector3(0, 1.0, 0)
	var across := Vector3(0, 0, 1) if g.base_yaw == 0.0 else Vector3(1, 0, 0)   # the side the leaf faces
	var t := g.ray_distance(c + across * 1.5, -across)
	_check.call(absf(t - (1.5 - Grabbable.LEAF_T / 2)) < 0.02, "doors: the leaf fills the doorway (hit at %.2f m)" % t)
	_check.call(g.ray_distance(c + across * 1.5, across) == INF, "doors: a ray away from the leaf misses")
	_check.call(g.distance_to(c) < 0.001 and absf(g.distance_to(c + across * 0.5) - (0.5 - Grabbable.LEAF_T / 2)) < 0.001,
			"doors: distance to the leaf")
	var open: Grabbable = null
	for sq: Vector3i in world.grabbables:
		if (world.grabbables[sq] as Grabbable).cdda_open:
			open = world.grabbables[sq]
			break
	_check.call(open == null or open.angle == Grabbable.OPEN_REST, "doors: an open door's leaf stands square to the wall")


func _ter(world: WorldView, p: Vector3i) -> int:
	var sm: Snapshot.Submap = world.snapshot.submaps[CddaCoords.ms_to_sm(p)]
	var l := CddaCoords.ms_to_local(p)
	return sm.ter[l.y * CddaCoords.SEEX + l.x]


func _test_local(world: WorldView, g: Grabbable) -> void:
	_reset(world, g)
	var w := VrWalk.new(world)
	_check.call(not w.can_stand(g.square), "doors: a closed door blocks walking")
	g.begin_grab(g.leaf.global_position)
	g.set_angle(0.2)
	_check.call(not g.cdda_open, "doors: a little ajar is still closed")
	g.set_angle(0.6)
	_check.call(g.cdda_open and world.door_open[g.square] and w.can_stand(g.square), "doors: dragged open (mock), walkable")
	g.set_angle(0.3)
	_check.call(g.cdda_open, "doors: no flapping between the thresholds")
	g.set_angle(0.05)
	_check.call(not g.cdda_open and not w.can_stand(g.square), "doors: dragged shut, blocks again")
	g.set_angle(-0.7)
	_check.call(g.cdda_open, "doors: opens the other way too")
	g.end_grab()
	g._process(0.1)
	_check.call(g.angle == -0.7, "doors: an open door stays where it was left")
	_reset(world, g)


func _test_live(world: WorldView, g: Grabbable) -> void:
	_reset(world, g)
	world.door_local = false
	var asked: Array = []
	var f := func(sq: Vector3i, open: bool) -> void: asked.append([sq, open])
	world.door_wants.connect(f)
	g.begin_grab(g.leaf.global_position)
	g.set_angle(0.6)
	g.set_angle(0.8)
	_check.call(asked == [[g.square, true]] and not g.cdda_open, "doors: live, past the threshold asks CDDA once")
	g.end_grab()
	g._process(0.5)
	_check.call(g.angle == 0.8, "doors: waits for CDDA's answer")
	world.door_state[g.square]["until"] = 0   # no answer (refused): swings shut
	for i in 10:
		g._process(0.1)
	_check.call(g.angle == 0.0, "doors: refused, the leaf swings back shut")
	g.sync({"open": true, "color": Color.BROWN, "glass": false, "locked": false})
	for i in 10:
		g._process(0.1)
	_check.call(g.cdda_open and g.angle == Grabbable.OPEN_REST, "doors: CDDA opened it: the leaf swings open")
	asked.clear()
	g.begin_grab(g.leaf.global_position)
	g.set_angle(0.05)
	_check.call(asked == [[g.square, false]], "doors: dragged shut asks CDDA to close")
	g.end_grab()
	world.door_wants.disconnect(f)
	g.sync({"open": false, "color": Color.BROWN, "glass": false, "locked": false})
	_reset(world, g)


func _test_drags(world: WorldView, g: Grabbable) -> void:
	_reset(world, g)
	var knob := g.leaf.global_transform * Vector3(Grabbable.LEAF_W / 2 - 0.09, 0, 0)
	var front := Vector3(0, 0, 1) if g.base_yaw == 0.0 else Vector3(1, 0, 0)
	var view := Basis.looking_at(-(front * 1.2 + g.global_basis.x * 0.3))   # in front of it, a bit to the side
	g.begin_grab(knob)
	g.drag_mouse(Vector2(120, 0), view)
	var after := g.leaf.global_transform * g._grab_local
	_check.call(absf(g.angle) > 0.02 and (after - knob).dot(view.x) > 0.0, "doors: mouse right moves the grabbed point right")
	g.end_grab()
	_reset(world, g)
	g.begin_grab(knob)
	g.drag_mouse(Vector2(0, -120), view)
	after = g.leaf.global_transform * g._grab_local
	_check.call(absf(g.angle) > 0.2 and (after - knob).dot(-view.z) > 0.0, "doors: mouse forward pushes it away")
	var a1 := g.angle
	g.drag_mouse(Vector2(0, 120), view)
	_check.call(absf(g.angle) < absf(a1) * 0.2, "doors: mouse back pulls it back")
	g.end_grab()
	_reset(world, g)
	var h := g.global_position
	var out := g.global_basis.x * 0.8 + Vector3(0, 1.0, 0)
	g.begin_hand(h + out)
	g.drag_hand(h + out.rotated(Vector3.UP, 0.5))
	_check.call(absf(g.angle - 0.5) < 0.001, "doors: the leaf turns with the hand")
	g.drag_hand(h + out.rotated(Vector3.UP, -0.4))
	_check.call(absf(g.angle + 0.4) < 0.001, "doors: both ways")
	g.end_grab()
	_reset(world, g)


func _test_pick(root: Node, world: WorldView, g: Grabbable) -> void:
	_reset(world, g)
	var across := Vector3(0, 0, 1) if g.base_yaw == 0.0 else Vector3(1, 0, 0)
	var c := world.coords.ms_center_to_world(g.square) + Vector3(0, 1.2, 0)
	var r := world.grabbable_on_ray(c + across * 2.0, -across, g.square, 10.0)
	_check.call(not r.is_empty() and r[0] == g, "doors: a ray picks the leaf")
	_check.call(world.grabbable_on_ray(c + across * 2.0, -across, g.square + Vector3i(5, 0, 0), 10.0).is_empty(),
			"doors: not from a square out of reach")
	_check.call(world.grabbable_near(c + across * 0.1, 0.12) == g and world.grabbable_near(c + across * 0.5, 0.12) == null,
			"doors: a hand near the leaf finds it")
	var ctl := GrabController.new(world)
	root.add_child(ctl)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(c + across * 1.8, c)
	cam.make_current()
	ctl.reach = func() -> Variant: return g.square
	var mid := root.get_viewport().get_visible_rect().size / 2
	ctl.update(cam, mid, true, true)
	_check.call(ctl.hover == g and g.highlighted() and ctl.icon.mode == GrabController.GrabIcon.HAND,
			"doors: under the crosshair: outline and hand pointer")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	_check.call(ctl.handle_event(press, cam, mid) and ctl.grabbed == g and g.grabbed, "doors: left button grabs it")
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(150, 0)
	ctl.handle_event(mm, cam, mid)
	ctl.update(cam, mid, true, true)
	_check.call(g.angle != 0.0 and ctl.icon.mode == GrabController.GrabIcon.FIST, "doors: dragging swings it, fist pointer")
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_LEFT
	rel.pressed = false
	_check.call(ctl.handle_event(rel, cam, mid) and ctl.grabbed == null and not g.grabbed, "doors: release lets go")
	ctl.reach = func() -> Variant: return g.square + Vector3i(5, 0, 0)
	ctl.update(cam, mid, true, true)
	_check.call(ctl.hover == null and not g.highlighted() and ctl.icon.mode == GrabController.GrabIcon.DOT,
			"doors: out of reach: no outline, a dot")
	cam.free()
	ctl.free()
	_reset(world, g)


func _test_vr(root: Node, world: WorldView, g: Grabbable) -> void:
	_reset(world, g)
	var rig := VrRig.new(world)
	root.add_child(rig)
	var out := g.global_basis.x * 0.8 + Vector3(0, 1.0, 0)
	var knob := g.global_position + out
	rig.left.global_position = knob
	rig.update_grabs(true)
	_check.call(rig.near[0] == g and g.highlighted(), "doors vr: a hand at the door outlines it")
	rig.press(rig.left, "grip_click")
	_check.call(rig.grabs[0] == g and g.grabbed, "doors vr: grip grabs it")
	rig.left.global_position = g.global_position + out.rotated(Vector3.UP, 0.7)
	rig.update_grabs(true)
	_check.call(absf(g.angle - 0.7) < 0.01 and g.cdda_open, "doors vr: it swings with the hand (opened)")
	rig.release(rig.left, "grip_click")
	_check.call(rig.grabs[0] == null and not g.grabbed, "doors vr: letting go of the grip")
	rig.grab_ok = func(_sq: Vector3i) -> bool: return false
	rig.left.global_position = knob
	rig.update_grabs(true)
	_check.call(rig.near[0] == null and not g.highlighted(), "doors vr: no grip on doors out of the player's reach")
	rig.free()
	_reset(world, g)


func _test_locked(root: Node, world: WorldView) -> void:
	var d := {"square": Vector3i(-900, -900, 0), "local": Vector3.ZERO, "along_x": true, "color": Color.GRAY,
			"glass": false, "open": false, "locked": true}
	var g := Grabbable.door(world, d)
	root.add_child(g)
	var said: Array = []
	var f := func(t: String) -> void: said.append(t)
	world.door_message.connect(f)
	world.door_local = true
	g.begin_grab(g.leaf.global_position)
	g.set_angle(1.0)
	_check.call(g.angle <= Grabbable.LOCKED_PLAY + 0.0001 and not g.cdda_open and said.size() == 1,
			"doors: a locked door only rattles (mock says so)")
	g.end_grab()
	world.door_message.disconnect(f)
	world.door_local = false
	var asked: Array = []
	var w := func(sq: Vector3i, open: bool) -> void: asked.append(open)
	world.door_wants.connect(w)
	g.begin_grab(g.leaf.global_position)
	g.set_angle(1.0)
	_check.call(asked == [true], "doors: live, a locked door still asks CDDA (its message says why)")
	world.door_wants.disconnect(w)
	world.door_local = true
	g.free()
	world.door_state.erase(d["square"])


func _test_asks() -> void:
	var ctl := GrabController.new(WorldView.new())
	var p := Vector3i(10, 10, 0)
	_check.call(ctl.want(p + Vector3i(3, 0, 0), true, p, 0) == "" and ctl.ask.is_empty(), "doors: no ask for a far door")
	_check.call(ctl.want(p + Vector3i(1, -1, 0), true, p, 1000) == "open", "doors: open queued for a door next to you")
	var req := {"id": 7, "kind": "direction", "text": "Open where?", "origin": p}
	_check.call(GrabController.answer_for(ctl.ask, req, 2000) == {"id": 7, "pos": Vector3i(1, -1, 0)},
			"doors: CDDA's 'Open where?' gets the door's direction")
	var moved := {"id": 7, "kind": "direction", "text": "Open where?", "origin": p + Vector3i(1, 0, 0)}
	_check.call(GrabController.answer_for(ctl.ask, moved, 2000) == {"id": 7, "pos": Vector3i(0, -1, 0)},
			"doors: the answer follows where the prompt says you stand")
	_check.call(GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Open where?",
			"origin": p + Vector3i(-1, 0, 0)}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Open where?",
			"origin": p + Vector3i(1, -1, 0)}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Open where?",
			"origin": p + Vector3i(0, 0, 1)}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Open where?"}, 2000).is_empty(),
			"doors: no answer when the door isn't next to the prompt's origin, or there is none")
	_check.call(GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Close where?", "origin": p}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": 7, "kind": "menu", "text": "Open where?", "origin": p}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, req, 1000 + GrabController.ASK_MS + 1).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": "7", "kind": "direction", "text": "Open where?", "origin": p}, 2000).is_empty(),
			"doors: other prompts, late ones and bad ids are left alone")
	ctl.world.free()
	ctl.free()
