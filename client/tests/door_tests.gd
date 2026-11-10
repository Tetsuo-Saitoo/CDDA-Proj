extends RefCounted
## Blocks E6 / L2: doors dragged open (Grabbable leaves from TerrainMesher, WorldView's registry, thresholds,
## CDDA asks, locked doors, mouse and hand drags, picking, the VR grip) and closed doors blocking VrWalk.
## Block L8: furniture parts (Grabbable.part: cabinet doors, drawers, lids) from specs.
## Run by run_tests.gd on the mock town.

const PART_SQ := Vector3i(-800, -800, 0)

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
	_test_parts(root, world)
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
	var req := {"id": 7, "kind": "direction", "text": "Open where?"}
	_check.call(GrabController.answer_for(ctl.ask, req, 2000) == {"id": 7, "pos": Vector3i(1, -1, 0)},
			"doors: CDDA's 'Open where?' gets the door's direction")
	_check.call(GrabController.answer_for(ctl.ask, {"id": 7, "kind": "direction", "text": "Close where?"}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": 7, "kind": "menu", "text": "Open where?"}, 2000).is_empty()
			and GrabController.answer_for(ctl.ask, req, 1000 + GrabController.ASK_MS + 1).is_empty()
			and GrabController.answer_for(ctl.ask, {"id": "7", "kind": "direction", "text": "Open where?"}, 2000).is_empty(),
			"doors: other prompts, late ones and bad ids are left alone")
	ctl.world.free()
	ctl.free()


## Block L8: furniture parts built from specs, under a node in the tree (its parts sit at their pivots).
func _test_parts(root: Node, world: WorldView) -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var was_local := world.door_local
	world.door_local = true
	_test_part_specs(world)
	_test_drawer(holder, world)
	_test_cabinet(holder, world)
	_test_lid(holder, world)
	_test_part_cdda(holder, world)
	_test_part_locked(holder, world)
	holder.free()
	world.door_local = was_local
	for k: Variant in world.door_state.keys():
		if k is String and (k as String).begins_with("test_"):
			world.door_state.erase(k)


## A drawer 0.5 x 0.15 x 0.45 m (a BoxMesh centred on its slide origin), sliding out towards +Z.
func _drawer_spec(id: String, at: Vector3) -> Dictionary:
	var m := BoxMesh.new()
	m.size = Vector3(0.5, 0.15, 0.45)
	return {"id": id, "square": PART_SQ, "kind": "drawer", "mesh": m, "pivot": Transform3D(Basis.IDENTITY, at),
			"axis": Vector3(0, 0, 2), "max": 0.4}


## A cabinet door 0.5 m wide, 0.7 m tall (a model node), hinged on its left edge, opening towards +Z.
func _cabinet_spec(id: String, pivot: Transform3D) -> Dictionary:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.5, 0.7, 0.02)
	mi.mesh = m
	mi.position = Vector3(0.25, 0.35, -0.01)
	return {"id": id, "square": PART_SQ, "kind": "door", "mesh": mi, "pivot": pivot, "axis": Vector3.DOWN, "max": 1.9}


## A crate lid 0.6 x 0.4 m hinged along its back edge, lying towards +Z; opening lifts its front edge.
func _lid_spec(id: String, at: Vector3) -> Dictionary:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.6, 0.02, 0.4)
	mi.mesh = m
	mi.position = Vector3(0, 0.01, 0.2)
	return {"id": id, "square": PART_SQ, "kind": "lid", "mesh": mi, "pivot": Transform3D(Basis.IDENTITY, at),
			"axis": Vector3.LEFT, "max": 1.9}


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 0.001


func _test_part_specs(world: WorldView) -> void:
	var good := _drawer_spec("test_spec", Vector3.ZERO)
	var many: Array = []
	for i in Grabbable.MAX_SURFACES + 1:
		many.append([Transform3D(), Rect2(0, 0, 0.3, 0.3)])
	var bad: Array[Dictionary] = []
	for change: Array in [["axis", Vector3.ZERO], ["max", NAN], ["max", "0.4"], ["max", -1.0],
			["square", Vector3(1, 2, 3)], ["kind", "hatch"], ["mesh", "box"], ["id", ""], ["id", 7],
			["pivot", Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0))], ["size", AABB(Vector3.ZERO, Vector3(INF, 1, 1))],
			["size", AABB(Vector3(90, 0, 0), Vector3.ONE)], ["handle", Transform3D(Basis.IDENTITY, Vector3(0, 50, 0))],
			["locked", 1], ["open_id", 3], ["surfaces", many], ["surfaces", "shelf"]]:
		var s := good.duplicate()
		s[change[0]] = change[1]
		bad.append(s)
	var no_mesh := good.duplicate()
	no_mesh.erase("mesh")
	bad.append(no_mesh)
	var rejected := 0
	for s: Dictionary in bad:
		var g := Grabbable.part(world, s)
		if g == null:
			rejected += 1
		else:
			g.free()
	var taken := _cabinet_spec("test_spec_taken", Transform3D())
	var owner_node := Node3D.new()
	owner_node.add_child(taken["mesh"])
	var refused_taken := Grabbable.part(world, taken) == null
	owner_node.free()
	_check.call(rejected == bad.size() and refused_taken,
			"parts: bad specs refused (%d of %d; a model node with a parent too)" % [rejected, bad.size()])
	var s2 := good.duplicate()
	s2["max"] = 3
	s2["surfaces"] = [[Transform3D(Basis.IDENTITY, Vector3(0, -0.06, 0)), Rect2(-0.2, -0.2, 0.4, 0.4)], ["shelf"],
			[Transform3D(), Rect2(0, 0, 0.1, 0.1)]]
	var g2 := Grabbable.part(world, s2)
	_check.call(g2 != null and g2.kind == "drawer" and g2.mech == "slide" and g2.max_amount == Grabbable.MAX_SLIDE
			and g2.axis == Vector3(0, 0, 1) and g2.surfaces.size() == 2 and g2.leaf.name == &"Leaf",
			"parts: a drawer spec (max clamped, axis normalised, a bad surface skipped)")
	if g2 != null:
		g2.free()
	var c := _cabinet_spec("test_spec_c", Transform3D())
	c["max"] = 9.0
	var h := Grabbable.part(world, c)
	_check.call(h != null and h.mech == "hinge" and h.kind == "door" and h.max_amount == Grabbable.MAX_HINGE
			and h.leaf.get_child_count() == 1 and _near(h.handle.origin, Vector3(0.5, 0.35, -0.01)),
			"parts: a cabinet door from a model node (max clamped, handle on the far edge)")
	if h != null:
		h.free()


func _test_drawer(holder: Node3D, world: WorldView) -> void:
	var at := Vector3(10, 0.6, 10)
	var g := Grabbable.part(world, _drawer_spec("test_drawer", at))
	holder.add_child(g)
	var can := Node3D.new()
	g.contents().add_child(can)
	can.position = Vector3(0, 0.05, 0)
	var h0 := g.handle_point()
	_check.call(_near(h0, at + Vector3(0, 0, 0.225)) and g.open_amount() == 0.0, "parts: a closed drawer's handle is on its front")
	var front := at + Vector3(0, 0, 2)
	_check.call(absf(g.ray_distance(front, Vector3.FORWARD) - 1.775) < 0.001
			and g.ray_distance(front + Vector3(0.4, 0, 0), Vector3.FORWARD) == INF
			and absf(g.distance_to(front) - 1.775) < 0.001 and g.distance_to(at) < 0.0001,
			"parts: a ray hits the drawer and misses beside it; distance to it")
	g.begin_hand(h0)
	g.drag_hand(h0 + Vector3(0, 0, 0.2))
	_check.call(absf(g.amount - 0.2) < 0.001 and _near(g.handle_point(), h0 + Vector3(0, 0, 0.2)),
			"parts: a hand pulls a drawer out 0.2 m, its handle with it")
	g.drag_hand(h0 + Vector3(0.1, 0.05, 0.9))
	_check.call(g.amount == g.max_amount and _near(can.global_position, at + Vector3(0, 0.05, 0.4))
			and absf(g.ray_distance(front, Vector3.FORWARD) - 1.375) < 0.001,
			"parts: no further than its max; its contents and box come along")
	g.end_grab()
	g._process(0.1)
	_check.call(g.amount == g.max_amount and g.open_amount() == 1.0, "parts: a drawer with no CDDA pair stays where it was left")
	g.set_amount(0.0)
	var view := Basis.looking_at(Vector3.FORWARD)   # in front of it, looking level
	g.begin_grab(g.handle_point())
	g.drag_mouse(Vector2(0, 80), view)
	var pulled := g.amount
	g.drag_mouse(Vector2(0, -40), view)
	_check.call(absf(pulled - 0.2) < 0.001 and absf(g.amount - 0.1) < 0.001, "parts: mouse down pulls a drawer out, up pushes it in")
	g.end_grab()
	g.free()
	var again := Grabbable.part(world, _drawer_spec("test_drawer", at))
	holder.add_child(again)
	_check.call(absf(again.amount - 0.1) < 0.001 and absf(again.leaf.position.z - 0.1) < 0.001,
			"parts: the amount survives a rebuild (same id)")
	again.begin_grab(again.handle_point())
	again.set_amount(0.05 * again.max_amount)
	again.end_grab()
	for i in 3:
		again._process(0.1)
	_check.call(again.amount == 0.0, "parts: one left at 5 % shuts")
	again.free()


func _test_cabinet(holder: Node3D, world: WorldView) -> void:
	for piv: Transform3D in [Transform3D(Basis.IDENTITY, Vector3(20, 0.3, 20)),
			Transform3D(Basis(Vector3.UP, 1.2) * Basis(Vector3.RIGHT, 0.25), Vector3(24, 0.3, 20))]:
		var level := piv.basis == Basis.IDENTITY
		var g := Grabbable.part(world, _cabinet_spec("test_cabinet", piv))
		holder.add_child(g)
		var hinge := g.global_position
		var ax := (g.global_basis * g.axis).normalized()
		var h0 := g.handle_point()
		var turned := func(a: float) -> Vector3: return hinge + (h0 - hinge).rotated(ax, a)
		g.begin_hand(h0)
		g.drag_hand(turned.call(0.6))
		var ok := absf(g.amount - 0.6) < 0.001 and _near(g.handle_point(), turned.call(0.6))
		if level:
			ok = ok and g.handle_point().z > h0.z + 0.2   # the right-hand rule about -Y: towards +Z
		g.drag_hand(turned.call(-0.3))
		ok = ok and g.amount == 0.0
		g.drag_hand(turned.call(2.8))
		ok = ok and g.amount == g.max_amount
		g.end_grab()
		_check.call(ok, "parts: a cabinet door turns with a hand round its hinge, one way, up to its max (%s pivot)"
				% ("level" if level else "rotated"))
		if level:
			var mi := g.leaf.get_child(0) as MeshInstance3D
			g.set_highlight(true)
			var lit := g.highlighted() and mi.material_overlay != null
			g.set_highlight(false)
			_check.call(lit and not g.highlighted() and mi.material_overlay == null, "parts: highlight on and off")
		g.free()
		world.door_state.erase("test_cabinet")


func _test_lid(holder: Node3D, world: WorldView) -> void:
	var at := Vector3(30, 0.5, 30)
	var g := Grabbable.part(world, _lid_spec("test_lid", at))
	holder.add_child(g)
	_check.call(_near(g.handle_point(), at + Vector3(0, 0.01, 0.4)), "parts: a lid's handle is its front edge")
	var p0 := at + Vector3(0, 0.02, 0.38)
	g.begin_grab(p0)
	g.drag_mouse(Vector2(0, -60), Basis.looking_at(Vector3.FORWARD))   # looking at it level
	var p1 := g.leaf.global_transform * g._grab_local
	_check.call(g.amount > 0.3 and p1.y > p0.y + 0.1, "parts: mouse up lifts a lid (%.2f rad)" % g.amount)
	g.end_grab()
	g.free()


func _test_part_cdda(holder: Node3D, world: WorldView) -> void:
	var s := _lid_spec("test_crate", Vector3(40, 0.5, 40))
	s["open_id"] = "f_crate_o"
	s["close_id"] = "f_crate_c"
	var g := Grabbable.part(world, s)
	holder.add_child(g)
	var c := Grabbable.part(world, _cabinet_spec("test_cupboard", Transform3D(Basis.IDENTITY, Vector3(44, 0.3, 40))))
	holder.add_child(c)
	world.door_local = false
	var asked: Array = []
	var f := func(sq: Vector3i, open: bool) -> void: asked.append([sq, open])
	world.door_wants.connect(f)
	c.begin_grab(c.handle_point())
	c.set_amount(1.2)
	c.set_amount(0.05)
	c.set_amount(1.2)
	c.end_grab()
	c._process(0.1)
	_check.call(asked.is_empty() and absf(c.amount - 1.2) < 0.001, "parts: no CDDA pair: never asks CDDA, stays where left")
	g.begin_grab(g.handle_point())
	g.set_amount(0.2 * g.max_amount)
	var early := asked.is_empty()
	g.set_amount(0.35 * g.max_amount)
	g.set_amount(0.7 * g.max_amount)
	_check.call(early and asked == [[PART_SQ, true]] and not g.cdda_open, "parts: a CDDA pair asks to open once, past 30 %")
	g.end_grab()
	g._process(0.5)
	_check.call(absf(g.amount - 0.7 * g.max_amount) < 0.001, "parts: waits for CDDA's answer")
	world.door_state["test_crate"]["until"] = 0   # no answer (refused)
	for i in 10:
		g._process(0.1)
	_check.call(g.amount == 0.0, "parts: refused, it shuts")
	g.sync_part(true, false)
	for i in 10:
		g._process(0.1)
	_check.call(g.cdda_open and g.amount == g.max_amount, "parts: CDDA opened it: it swings fully open")
	asked.clear()
	g.begin_grab(g.handle_point())
	g.set_amount(0.05 * g.max_amount)
	_check.call(asked == [[PART_SQ, false]], "parts: dragged under 8 % asks CDDA to close")
	g.end_grab()
	asked.clear()
	world.door_local = true
	g.set_amount(g.max_amount)
	g.begin_grab(g.handle_point())
	g.set_amount(0.05 * g.max_amount)
	g.end_grab()
	_check.call(not g.cdda_open and world.door_state["test_crate"]["open"] == false and asked.is_empty(),
			"parts: mock: shut here, no ask")
	world.door_wants.disconnect(f)
	g.free()
	c.free()


func _test_part_locked(holder: Node3D, world: WorldView) -> void:
	var s := _lid_spec("test_safe", Vector3(48, 0.5, 40))
	s["open_id"] = "f_safe_o"
	s["close_id"] = "f_safe_c"
	s["locked"] = true
	var g := Grabbable.part(world, s)
	holder.add_child(g)
	var said: Array = []
	var m := func(t: String) -> void: said.append(t)
	world.door_message.connect(m)
	g.begin_grab(g.handle_point())
	g.set_amount(1.5)
	_check.call(g.amount > 0.0 and g.amount <= Grabbable.LOCKED_PLAY + 0.0001 and not g.cdda_open and said.size() == 1,
			"parts: a locked lid only rattles (mock says so)")
	g.end_grab()
	world.door_message.disconnect(m)
	var ds := _drawer_spec("test_locked_drawer", Vector3(52, 0.6, 40))
	ds["locked"] = true
	var d := Grabbable.part(world, ds)
	holder.add_child(d)
	var h0 := d.handle_point()
	d.begin_hand(h0)
	d.drag_hand(h0 + Vector3(0, 0, 0.3))
	_check.call(d.amount > 0.0 and d.amount <= Grabbable.LOCKED_SLIDE + 0.000001, "parts: a locked drawer only rattles too")
	d.end_grab()
	g.free()
	d.free()
