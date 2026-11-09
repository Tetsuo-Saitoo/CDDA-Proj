extends RefCounted
## FPS aiming checks, run by run_tests.gd: a camera ray picks a zombie for a `fire` target request, the
## crosshair (captured mouse) follows the view and fires, a free mouse picks first and fires on the second
## click, keys fire straight away, and the weapon viewmodel picks a shape from the id tables.

var _check: Callable
var answers: Array = []


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("aim")
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	root.add_child(world)
	world.set_id_tables(tables)
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var pp: Array = d["player"]["pos"]
	var me := Vector3i(int(pp[0]), int(pp[1]), int(pp[2]))
	var zp := me + Vector3i(3, 0, 0)
	d["creatures"] = [d["creatures"][0], {"uid": 8589934593, "kind": 2, "type": tables.index_of("mtype", "mon_zombie"),
			"pos": [zp.x, zp.y, zp.z], "hp_frac": 255}]
	world.apply_snapshot(Snapshot.from_data(d))
	var ui := RequestUI.new()
	root.add_child(ui)
	ui.answered.connect(func(a: Dictionary) -> void: answers.append(a))
	var aim := AimController.new(world, ui)
	root.add_child(aim)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = world.coords.ms_center_to_world(me) + Vector3(0, 1.5, 0)
	var east := world.coords.ms_center_to_world(zp) + Vector3(0, 1.2, 0)
	cam.look_at(east)
	var centre := cam.get_viewport().get_visible_rect().size / 2.0
	var at_zombie := cam.unproject_position(east)

	_check.call(aim.pick(cam, at_zombie) == zp, "aim: a ray through the zombie on screen picks its square")
	var req := {"id": 9, "kind": "target", "mode": "fire", "origin": me, "cursor": me, "range": 10,
			"candidates": [zp], "actions": PackedStringArray(["AIM", "FIRE"]), "allow_cancel": true}
	_check.call(ui.show_request(req), "aim: fire request shows")
	aim.first_person = true
	aim.update(cam, false)
	_check.call(aim.crosshair.visible and ui.target_widget().cursor == me, "aim: crosshair shows; free mouse leaves the cursor")
	aim.update(cam, true)
	_check.call(ui.target_widget().cursor == zp, "aim: captured mouse, the crosshair moves the cursor to the zombie")
	var kicks := [0]
	aim.fired.connect(func() -> void: kicks[0] += 1)
	_check.call(aim.on_fire(cam, Vector2.ZERO, true) and answers.back() == {"id": 9, "pos": zp, "action": "FIRE"}
			and kicks[0] == 1, "aim: fire at the crosshair answers FIRE at the zombie and kicks")

	ui.show_request(req)
	answers.clear()
	aim.on_fire(cam, at_zombie, false)
	_check.call(answers.is_empty() and ui.target_widget().cursor == zp, "aim: first click on the zombie picks it")
	aim.on_fire(cam, at_zombie, false)
	_check.call(answers.size() == 1 and answers[0]["action"] == "FIRE", "aim: second click on it fires")

	var look := req.duplicate()
	look["mode"] = "look"
	look["actions"] = PackedStringArray()
	ui.show_request(look)
	aim.update(cam, true)
	_check.call(ui.target_widget().cursor == me, "aim: looking around, the crosshair doesn't drag the cursor")
	ui.clear()
	aim.update(cam, false)
	_check.call(not aim.crosshair.visible and not aim.on_fire(cam, centre, true), "aim: no request, no crosshair, fire unused")
	_check.call(TargetRequestWidget.is_attack_mode("throw") and not TargetRequestWidget.is_attack_mode("look"),
			"aim: throw is an attack mode, look isn't")
	_check.call(InputActions.info(&"aim_fire").size() == 4, "aim: aim_fire is a bindable action")
	_check.call(InputActions.CDDA.get(&"cdda_reload") == "reload_weapon" and InputActions.key_of(&"cdda_reload") == "R",
			"aim: R reloads outside aiming too (%s)" % InputActions.key_of(&"cdda_reload"))
	var queued: Array = []
	ui.queue_after.connect(func(acts: PackedStringArray) -> void: queued.append_array(acts))
	ui.show_request(req)
	answers.clear()
	ui.handle_input(_key(KEY_R))
	_check.call(answers == [{"id": 9, "cancel": true}] and queued == ["reload_weapon", "fire"],
			"aim: R cancels aiming, then reload_weapon and fire are queued (%s %s)" % [answers, queued])
	ui.show_request(look)
	answers.clear()
	ui.handle_input(_key(KEY_R))
	_check.call(answers.is_empty(), "aim: no reload while looking")
	ui.clear()
	var corpse: PropCatalog.Prop = world.props.item(tables.index_of("itype", "corpse"))
	_check.call(corpse.shape == "item_corpse" and corpse.scale >= 0.9,
			"aim: a corpse is drawn body-sized (%s %s)" % [corpse.shape, corpse.scale])

	_test_viewmodel(root, tables)
	_test_corpses(root, world, d, tables)
	_test_explosions(root, world, tables, me)
	aim.crosshair.free()
	for n: Node in [cam, aim, ui, world]:
		n.free()
	aim = null


func _test_viewmodel(root: Node, tables: IdTables) -> void:
	var gun := IdTables.Def.new()
	gun.gun = "rifle"
	var pistol := IdTables.Def.new()
	pistol.gun = "pistol"
	var bow := IdTables.Def.new()
	bow.gun = "archery"
	var old := IdTables.Def.new()   # an older bridge: no gun skill, the category decides
	old.category = "guns"
	old.volume_ml = 500
	var knife := IdTables.Def.new()
	knife.category = "weapons"
	var VM := WeaponViewmodel
	_check.call(VM.shape_for(gun) == "long" and VM.shape_for(pistol) == "pistol" and VM.shape_for(bow) == "bow"
			and VM.shape_for(old) == "pistol" and VM.shape_for(knife) == "melee" and VM.shape_for(null) == "",
			"viewmodel: shapes from gun skill, category, empty hands")
	var vm := WeaponViewmodel.new()
	root.add_child(vm)
	vm.set_item(0, tables)
	_check.call(vm.get_child_count() == 0, "viewmodel: nothing in empty hands")
	var i := tables.index_of("itype", "rock")
	vm.set_item(i, tables)
	_check.call(i <= 0 or vm.get_child_count() == 1, "viewmodel: a model for a held rock")
	vm.kick()
	vm._process(0.016)
	_check.call(vm.rotation.x > 0.0, "viewmodel: a shot kicks it up")
	vm.free()


func _key(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.pressed = true
	e.keycode = code
	e.physical_keycode = code
	return e


func _test_corpses(root: Node, world: WorldView, d: Dictionary, tables: IdTables) -> void:
	var zi := tables.index_of("mtype", "mon_zombie")
	var dd: Dictionary = d.duplicate(true)
	var sm0: Dictionary = dd["submaps"][0]
	sm0["items"] = [[5, 1, [maxi(tables.index_of("itype", "corpse"), 1)], zi]]
	var snap := Snapshot.from_data(dd)
	_check.call(snap.is_valid(), "corpses: a pile with a corpse mtype reads (%s)" % snap.error)
	world.apply_snapshot(snap)
	var cv := CreatureView.new()
	root.add_child(cv)
	cv.apply(snap, world)
	_check.call(cv.corpse_count() == 1, "corpses: the zombie's body lies on its square")
	var states := [Snapshot.CORPSE_FIELD_DRESSED, Snapshot.CORPSE_SKINNED | Snapshot.CORPSE_QUARTERED,
			Snapshot.CORPSE_PULPED, Snapshot.CORPSE_GIBBED]
	for st: int in states:
		sm0["items"] = [[5, 1, [maxi(tables.index_of("itype", "corpse"), 1)], zi, st]]
		cv.apply(Snapshot.from_data(dd), world)
		var f: CreatureFigure = cv.get_node_or_null(NodePath(cv.get_child(cv.get_child_count() - 1).name))
		_check.call(cv.corpse_count() == 1 and f != null and f.corpse_state == st and f.get_node_or_null("gore") != null,
				"corpses: state %d rebuilds the body with its gore" % st)
	var gv := GoreView.new()
	root.add_child(gv)
	sm0["fields"] = []
	gv.apply(Snapshot.from_data(dd), world)
	var before := gv.count()
	sm0["fields"] = [[5, tables.index_of("field", "fd_blood"), 2, 0], [6, tables.index_of("field", "fd_gibs_flesh"), 3, 0],
			[7, tables.index_of("field", "fd_smoke"), 1, 0]]
	var gs := Snapshot.from_data(dd)
	gv.apply(gs, world)
	_check.call(gs.is_valid() and gv.count() == before + 1 + 4, "gore: a blood splat and 4 gib chunks, smoke left out (%d %s)" % [gv.count(), gs.error])
	sm0["fields"] = [[5, 1, 2]]
	_check.call(not Snapshot.from_data(dd).is_valid(), "gore: a malformed field is refused")
	sm0.erase("fields")
	gv.free()
	sm0["items"] = [[5, 1, [maxi(tables.index_of("itype", "corpse"), 1)]]]
	cv.apply(Snapshot.from_data(dd), world)
	_check.call(cv.corpse_count() == 0, "corpses: gone when the pile no longer has it (old 3-field piles still read)")
	sm0["items"] = [[5, 1, [], 7, 9, 1]]
	_check.call(not Snapshot.from_data(dd).is_valid(), "corpses: a 6-field pile is refused")
	cv.free()


func _test_explosions(root: Node, world: WorldView, tables: IdTables, me: Vector3i) -> void:
	var P := ExplosionView
	_check.call(P.profile_for("flashbang", "")["flash"] == 1.0 and P.profile_for("weird", "")["kind"] == "blast"
			and P.profile_for("blast", "c4_armed")["size"] > 1.0 and P.profile_for("blast", "")["size"] == 1.0,
			"explosions: looks by kind and item (flashbang flashes, C4 bigger, unknown kind = blast)")
	var ev := ExplosionView.new(world)
	root.add_child(ev)
	var gi := tables.index_of("itype", "grenade_act")
	ev.on_events([{"kind": "explosion", "pos": me, "amount": 3, "text": "blast", "detail": maxi(gi, 0),
			"path": [me, me + Vector3i(1, 0, 0)]}, {"kind": "explosion", "pos": "junk"}, "junk"])
	_check.call(ev.live_count() == 1, "explosions: a blast starts, junk is skipped")
	ev.on_events([{"kind": "explosion", "pos": me, "amount": 8, "text": "flashbang", "detail": 0, "path": []}])
	_check.call(ev.flash_strength() > 0.0, "explosions: a flashbang next to the camera whites the screen")
	for i in 40:
		ev.tick(0.05)
	_check.call(ev.live_count() == 0 and ev.flash_strength() == 0.0, "explosions: effects end and the flash fades")
	ev.flash_rect.free()
	ev.free()
