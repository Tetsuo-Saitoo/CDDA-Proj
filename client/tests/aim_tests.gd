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

	_test_viewmodel(root, tables)
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
