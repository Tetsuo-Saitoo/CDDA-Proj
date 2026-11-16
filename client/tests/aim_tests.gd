extends RefCounted
## FPS aiming checks, run by run_tests.gd: a camera ray picks a zombie for a `fire` target request, the
## crosshair (captured mouse) follows the view and fires, a free mouse picks first and fires on the second
## click, keys fire straight away, and the weapon viewmodel picks a shape from the id tables.
## Combat too: client-flown bullets (hordes, weapon_wielded, VR fire_from / live_aim), CDDA's shot requests,
## hit feedback from events, the gun model's named parts and grime, player.wielded_gun in snapshots.
## Melee: aimed strikes and their swing answers, called techniques and the crosshair's note, strikes that hit
## several creatures.

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

	_test_views(world, me, zp, ui, aim, cam, req)
	_test_bullets(root, world, tables, me, zp, ui, aim, cam, req)
	_test_hits(aim, ui, cam, tables)
	_test_viewmodel(root, tables)
	_test_grime(root, tables)
	_test_gun_parts()
	_test_muzzle_flash(root, tables)
	_test_gun_state(d, tables)
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
	var sway_of := func(arcmin: Variant) -> Array:   # [max |yaw|, max offset from the rest point] over 4 s
		vm.sway_arcmin = arcmin
		var most := [0.0, 0.0]
		for f in 200:
			vm._process(0.02)
			most = [maxf(most[0], absf(vm.rotation.y)), maxf(most[1], vm.position.distance_to(vm._base))]
		return most
	var mild: Array = sway_of.call(300.0)
	var wild: Array = sway_of.call(1e9)
	_check.call(mild[0] > 0.002 and wild[0] > mild[0] and wild[0] <= WeaponViewmodel.SWAY_ROT + 1e-4
			and wild[1] <= 0.012 and vm.sway_arcmin == WeaponViewmodel.SWAY_FULL_ARCMIN,
			"viewmodel: sways more with more dispersion, capped (%s %s)" % [mild, wild])
	vm.sway_arcmin = NAN
	var nan_ok := vm.sway_arcmin == 0.0
	var still: Array = sway_of.call(0.0)
	vm._process(0.02)
	_check.call(nan_ok and absf(vm.rotation.y) < 1e-4 and vm.position.distance_to(vm._base) < 1e-4,
			"viewmodel: no sway without dispersion, NaN is none (%s)" % [still])
	vm.free()


## Gun fouling on the viewmodel: CDDA's `dirt` (0..10000) as grime on a gun's parts (grime.gdshader).
func _test_grime(root: Node, tables: IdTables) -> void:
	var VM := WeaponViewmodel
	var sh: Shader = load("res://scripts/combat/grime.gdshader")
	var names := []
	for u: Dictionary in sh.get_shader_uniform_list() if sh != null else []:
		names.append(u.get("name"))
	_check.call(sh != null and sh.get_mode() == Shader.MODE_SPATIAL
			and ["albedo", "metallic", "roughness", "specular", "grime", "half_extents"].all(func(x: String) -> bool: return x in names),
			"grime: the shader loads as spatial with its uniforms (%s)" % [names])
	var probe := ShaderMaterial.new()
	probe.shader = sh
	probe.set_shader_parameter("grime", 0.5)
	_check.call(probe.shader == sh and probe.get_shader_parameter("grime") == 0.5, "grime: a ShaderMaterial takes it")

	# parts: guns wear the shader with their plain look; bows, blades and other items keep plain materials
	var looks := func(model: Node3D) -> Array:   # [[material, mesh], ...]
		var out := []
		for n: Node in model.get_children():
			var mi := n as MeshInstance3D
			if mi != null:
				out.append([(mi.mesh as PrimitiveMesh).material, mi.mesh])
		return out
	var plain := {}   # colour -> the plain material it had (melee: metal and wood)
	for s: String in ["melee", "bow", "item"]:
		var model := VM.build(s, 0.7)
		var ps: Array = looks.call(model)
		_check.call(not ps.is_empty() and ps.all(func(x: Array) -> bool: return x[0] is StandardMaterial3D)
				and VM.grime_materials(model).is_empty(), "grime: a %s keeps its plain materials" % s)
		for x: Array in ps:
			plain[(x[0] as StandardMaterial3D).albedo_color] = x[0]
		model.free()
	for s: String in ["pistol", "long", "launcher"]:
		var model := VM.build(s)
		var ps: Array = looks.call(model)
		var same := not ps.is_empty()
		var parts := []
		for x: Array in ps:
			var m := x[0] as ShaderMaterial
			var c: Variant = m.get_shader_parameter("albedo") if m != null else null
			var p: StandardMaterial3D = plain.get(c, VM._mat(VM.OLIVE) if c == VM.OLIVE else null)
			same = (same and m != null and m.shader == sh and m.get_shader_parameter("grime") == 0.0 and p != null
					and m.get_shader_parameter("metallic") == p.metallic and m.get_shader_parameter("roughness") == p.roughness
					and m.get_shader_parameter("specular") == p.metallic_specular)
			parts.append(c)
		var halves: Array = ps.map(func(x: Array) -> Variant: return (x[0] as ShaderMaterial).get_shader_parameter("half_extents") if x[0] is ShaderMaterial else null)
		_check.call(same and VM.grime_materials(model).size() == ps.size()
				and ps.all(func(x: Array) -> bool: return ps.filter(func(y: Array) -> bool: return y[0] == x[0]).size() == 1),
				"grime: a %s's parts each wear the shader, at 0 with the plain look (%s)" % [s, parts])
		_check.call(halves.all(func(h: Variant) -> bool: return h is Vector3 and (h as Vector3).x > 0.0 and (h as Vector3).y > 0.0),
				"grime: each %s part knows its half size (%s)" % [s, halves])
		model.free()
	var box := BoxMesh.new()
	box.size = Vector3(0.04, 0.06, 0.34)
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.012
	cyl.bottom_radius = 0.012
	cyl.height = 0.36
	_check.call(VM._half_size(box).is_equal_approx(Vector3(0.02, 0.03, 0.17)) and VM._half_size(cyl).is_equal_approx(Vector3(0.012, 0.18, 0.012)),
			"grime: half sizes of a box and a barrel (along y)")

	# set_dirt: CDDA's stages, junk clamped, kept across rebuilds, uniforms touched only on change
	var stages := []
	for dd: int in [0, 2000, 4000, 6000, 8000, 10000]:
		stages.append(VM.grime_for(dd))
	_check.call(stages == [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] and VM.grime_for(-1) == 0.0 and VM.grime_for(-99999) == 0.0
			and VM.grime_for(99999) == 1.0 and VM.grime_for(1000) == 0.1, "grime: dirt 0..10000 maps to 0..1 (%s)" % [stages])
	var rifle := tables.index_of("itype", "remington_870")
	var pistol := tables.index_of("itype", "glock_19")
	var knife := tables.index_of("itype", "knife_combat")
	var vm := WeaponViewmodel.new()
	root.add_child(vm)
	var grimes := func() -> Array:
		return vm._grime_mats.map(func(m: ShaderMaterial) -> Variant: return m.get_shader_parameter("grime"))
	vm.set_dirt(6000)
	var before_gun := vm.grime == 0.6 and vm.dirt == 6000
	vm.set_item(rifle, tables)
	var on_rifle: Array = grimes.call()
	_check.call(rifle > 0 and vm.shape == "long" and before_gun and on_rifle.size() == 6 and on_rifle.all(func(g: Variant) -> bool: return g == 0.6),
			"grime: dirt set before the gun shows on it once it's held (%s)" % [on_rifle])
	vm.set_dirt(2000)
	var light: Array = grimes.call()
	vm.set_item(pistol, tables)
	var on_pistol: Array = grimes.call()
	_check.call(light.all(func(g: Variant) -> bool: return g == 0.2) and vm.shape == "pistol" and on_pistol.size() == 3
			and on_pistol.all(func(g: Variant) -> bool: return g == 0.2), "grime: a rebuilt gun keeps the grime (%s %s)" % [light, on_pistol])
	vm.set_item(knife, tables)
	_check.call(vm.shape == "melee" and vm._grime_mats.is_empty() and vm.grime == 0.2, "grime: a knife shows none, the dirt is kept")
	vm.set_item(rifle, tables)
	vm.set_dirt(-500)
	var none_ok := vm.dirt == -1 and vm.grime == 0.0 and (grimes.call() as Array).all(func(g: Variant) -> bool: return g == 0.0)
	vm.set_dirt(123456)
	var max_ok := vm.dirt == 10000 and vm.grime == 1.0 and (grimes.call() as Array).all(func(g: Variant) -> bool: return g == 1.0)
	vm.set_dirt(-1)
	_check.call(none_ok and max_ok and vm.grime == 0.0, "grime: negative dirt (NON-FOULING) is clean, over 10000 is 10000")
	vm.set_dirt(8000)
	var m0: ShaderMaterial = vm._grime_mats[0]
	m0.set_shader_parameter("grime", 0.123)   # a marker: set_dirt with the same value leaves it
	vm.set_dirt(8000)
	var kept: Variant = m0.get_shader_parameter("grime")
	vm.set_dirt(8001)
	_check.call(kept == 0.123 and is_equal_approx(m0.get_shader_parameter("grime"), 0.8001),
			"grime: the uniform is set only when the dirt changes (%s)" % [kept])

	# set_faults: a jam opens the slide / bolt, shows the hint, survives a rebuild; junk and other faults ignored
	_check.call(VM.jam_of([1, null, "fault_gun_dirt", "fault_stovepipe", "fault_double_feed"]) == "fault_stovepipe"
			and VM.jam_of([]) == "" and VM.jam_of(["x".repeat(64)]) == "" and VM.jam_hint("fault_stovepipe") == "Stovepipe: R to clear"
			and VM.jam_hint("nope") == "", "jam: the first jam among the faults, junk ignored")
	vm.set_item(pistol, tables)
	var slide: Node3D = vm._root.get_node("Slide")
	var shut := slide.position
	vm.set_faults(["fault_stovepipe"])
	var open_ok := is_equal_approx(slide.position.z - shut.z, VM.JAM_BACK) and vm._jam_label != null and vm._jam_label.visible \
			and vm._jam_label.text == "Stovepipe: R to clear"
	vm.set_item(rifle, tables)
	var bolt: Node3D = vm._root.get_node("Bolt")
	var bolt_open := bolt.has_meta("rest") and is_equal_approx(bolt.position.z - (bolt.get_meta("rest") as Vector3).z, VM.JAM_BACK)
	vm.set_item(knife, tables)
	var knife_hidden := not vm._jam_label.visible and vm.jam == "fault_stovepipe"
	vm.set_item(pistol, tables)
	slide = vm._root.get_node("Slide")
	vm.set_faults([])
	var shut_again := slide.position.is_equal_approx(slide.get_meta("rest")) and not vm._jam_label.visible
	_check.call(open_ok and bolt_open and knife_hidden and shut_again, "jam: slide / bolt open and the hint while jammed, shut when cleared")
	vm.free()


## CDDA's dispersion roll as angular error: ShotError, target requests' `dispersion`, `shot` requests answered
## from the aim kept by the FIRE just before (the camera looks at the zombie's head, a rifle in hand).
func _test_shot_requests(aim: AimController, ui: RequestUI, cam: Camera3D, req: Dictionary, me: Vector3i,
		zp: Vector3i) -> void:
	var S := ShotError
	var fwd := Vector3.FORWARD
	var up := S.apply(fwd, 120.0, 0.0)
	var right := S.apply(fwd, 120.0, 90.0)
	_check.call(absf(rad_to_deg(up.angle_to(fwd)) - 2.0) < 0.001 and up.y > 0.0 and absf(up.x) < 1e-5
			and absf(rad_to_deg(right.angle_to(fwd)) - 2.0) < 0.001 and right.x > 0.0 and absf(right.y) < 1e-5
			and is_equal_approx(right.length(), 1.0), "shots: 120' of error turns a level sight 2° up (0) or right (90) (%s %s)" % [up, right])
	var diag := Vector3(0.6, 0.0, -0.8)
	var vert := S.apply(Vector3.DOWN, 60.0, 0.0)
	_check.call(absf(rad_to_deg(S.apply(diag, 300.0, 45.0).angle_to(diag)) - 5.0) < 0.001 and vert.is_finite()
			and absf(rad_to_deg(vert.angle_to(Vector3.DOWN)) - 1.0) < 0.001, "shots: any sight turns by the error, straight down too")
	var wild := S.apply(fwd, 1e9, 180.0)
	_check.call(absf(rad_to_deg(wild.angle_to(fwd)) - 30.0) < 0.001 and wild.y < 0.0, "shots: error capped at 30°, 180 goes down (%s)" % wild)
	_check.call(S.apply(fwd, NAN, 0.0) == fwd and S.apply(fwd, -50.0, 0.0) == fwd and S.apply(fwd, 60.0, NAN).y > 0.0
			and S.apply(fwd, 60.0, INF).y > 0.0 and S.apply(Vector3.ZERO, 60.0, 0.0) == Vector3.ZERO
			and S.apply(Vector3(NAN, 0, 0), 60.0, 0.0) == Vector3.ZERO, "shots: NaN / negative error is none, NaN angle is up, no sight stays none")
	var px := S.spread_pixels(75.0, 1000.0, 60.0)
	_check.call(px > 10.0 and px < 13.0 and S.spread_pixels(75.0, 1000.0, 120.0) > px
			and S.spread_pixels(75.0, 1000.0, 10800.0) == 450.0 and S.spread_pixels(75.0, 1000.0, NAN) == 0.0
			and S.spread_pixels(NAN, 1000.0, 60.0) == 0.0 and S.spread_pixels(0.0, 1000.0, 60.0) == 0.0
			and S.spread_pixels(75.0, 1000.0, -5.0) == 0.0 and S.spread_pixels(75.0, INF, 60.0) == 0.0,
			"shots: spread circle radius from fov and dispersion, capped, junk is 0 (%.2f)" % px)

	# target requests: dispersion remembered, junk ignored
	var fire_req := req.duplicate()
	var junk_ok := true
	for bad: Variant in ["240", NAN, INF, -1.0, 1e9, null, [240], 10801]:
		fire_req["dispersion"] = bad
		junk_ok = junk_ok and aim.on_request(fire_req).is_empty() and aim.dispersion == 0.0
	fire_req["dispersion"] = 300
	var int_ok := aim.dispersion == 0.0 and aim.on_request(fire_req).is_empty() and aim.dispersion == 300.0
	fire_req["dispersion"] = 240.0
	_check.call(junk_ok and int_ok and aim.on_request(fire_req).is_empty() and aim.dispersion == 240.0,
			"shots: a target request's dispersion is kept, junk is 0 (%s)" % aim.dispersion)
	ui.show_request(fire_req)
	aim.first_person = true
	aim.update(cam, true)
	var ring := aim.crosshair.spread_px
	_check.call(aim.shown_dispersion == 240.0 and ring > 1.0, "shots: the crosshair rings the dispersion (%.1f px)" % ring)
	var look := req.duplicate()
	look["mode"] = "look"
	ui.show_request(look)
	aim.update(cam, true)
	_check.call(aim.shown_dispersion == 0.0 and aim.crosshair.spread_px == 0.0, "shots: no ring while looking")

	# a newer bridge: FIRE draws no tracer, the shot requests do
	ui.show_request(fire_req)
	answers.clear()
	var tracers := aim._tracers
	aim.on_fire(cam, Vector2.ZERO, true)
	var a: Dictionary = answers[0] if not answers.is_empty() else {}
	_check.call(a.get("action") == "FIRE" and a.get("shot", {}).get("fly") == true and aim._tracers == tracers,
			"shots: FIRE says fly, its tracer waits for the shot requests (%s)" % [a])
	var sreq := {"id": 31, "kind": "shot", "shot_error": 0.0, "shot_angle": 0.0, "dispersion": 240.0, "origin": me,
			"cursor": zp, "range": 10}
	var r := aim.on_request(sreq)
	var s: Dictionary = r.get("shot", {})
	_check.call(r.get("id") == 31 and s.get("hit_uid") == 8589934593 and s.get("part") == "head" and s.get("end") == zp
			and not s.has("fly") and aim._tracers == tracers + 1 and aim.last_shot["answer"] == s,
			"shots: no error, the bullet goes along the sight into the head (%s)" % [r])
	sreq["shot_error"] = 600.0
	r = aim.on_request(sreq)
	_check.call(r.get("id") == 31 and r.has("shot") and r["shot"].get("hit_uid") == 0,
			"shots: 10° high misses the zombie (%s)" % [r])
	sreq["shot_error"] = 1800.0
	sreq["shot_angle"] = 135.0
	r = aim.on_request(sreq)
	var low: Vector3i = r.get("shot", {}).get("end", Vector3i(0, 0, -99))
	_check.call(r.get("shot", {}).get("hit_uid") == 0 and low.z == me.z and low != me,
			"shots: 30° low right hits the floor on our level, not the one below (%s)" % [r])
	sreq["shot_angle"] = 0.0
	sreq["shot_error"] = "600"
	sreq["shot_angle"] = NAN
	sreq["id"] = 32.0
	r = aim.on_request(sreq)
	_check.call(r.get("id") == 32 and r.get("shot", {}).get("hit_uid") == 8589934593,
			"shots: a string error and a NaN angle count as 0 (%s)" % [r])
	_check.call(typeof(r.get("id")) == TYPE_INT and r.size() == 2 and _bridge_typed(r.get("shot", {}))
			and _bridge_typed(a.get("shot", {}), true) and _bridge_typed(aim.last_shot.get("answer", {})),
			"shots: answers hold exactly the bridge's types, a float id becomes an int (%s %s)" % [r, a])
	var mreq := sreq.duplicate()
	mreq["shot_error"] = 600.0
	mreq["shot_angle"] = 0.0
	var miss := aim.on_request(mreq)
	_check.call(_bridge_typed(miss.get("shot", {})) and miss["shot"]["hit_uid"] == 0, "shots: a miss's answer is typed too (%s)" % [miss])
	var preq := mreq.duplicate()
	preq["shot_error"] = 0.0
	preq["pellets"] = [0.0, 30.0, -30.0, 1200.0]
	var pr := aim.on_request(preq)
	var pl: Variant = pr.get("shot", {}).get("pellets")
	_check.call(pl is Array and pl.size() == 4 and pl[0].get("hit_uid") == 8589934593 and pl[3].get("hit_uid") == 0
			and pl.all(func(x: Dictionary) -> bool: return _bridge_typed(x)),
			"shots: a shell flies each pellet, 20° right misses (%s)" % [pr])
	var junk_pellets := []
	for junk: Variant in ["1,2", [1.0, NAN], [1.0, "2"], [2000.0], range(AimController.MAX_PELLETS + 1)]:
		preq["pellets"] = junk
		junk_pellets.append(aim.on_request(preq).get("shot", {}))
	_check.call(junk_pellets.all(func(x: Dictionary) -> bool: return x.has("end") and not x.has("pellets")),
			"shots: bad pellets fly one bullet (%s)" % [junk_pellets])
	var bad_ids := []
	for id: Variant in ["31", -3, 0, 1.5, null]:
		sreq["id"] = id
		bad_ids.append(aim.on_request(sreq))
	_check.call(bad_ids.all(func(x: Dictionary) -> bool: return x.is_empty()), "shots: no usable id, no answer (%s)" % [bad_ids])
	sreq["id"] = 33
	var cancel := {"id": 33, "cancel": true}
	var kept := aim.shot_aim.duplicate()
	var cancels := []
	aim.shot_aim = {}
	cancels.append(aim.on_request(sreq))
	aim.shot_aim = kept.duplicate()
	aim.shot_aim["time"] = Time.get_ticks_msec() - AimController.AIM_KEEP_MS - 1000
	cancels.append(aim.on_request(sreq))
	aim.shot_aim = kept.duplicate()
	aim.shot_aim["sight"] = "junk"
	cancels.append(aim.on_request(sreq))
	aim.shot_aim = kept.duplicate()
	aim.shot_aim["sight"] = Vector3.DOWN   # into the floor of our own square
	cancels.append(aim.on_request(sreq))
	aim.shot_aim = kept.duplicate()
	var cv := aim.creature_view
	aim.creature_view = null
	cancels.append(aim.on_request(sreq))
	aim.creature_view = cv
	_check.call(cancels.all(func(x: Dictionary) -> bool: return x == cancel),
			"shots: no aim, an old aim, a bad aim, a shot into our own square, no figures: cancel (%s)" % [cancels])
	_check.call(aim.on_request({"id": 5, "kind": "menu"}).is_empty() and aim.on_request({"id": 5, "kind": 7}).is_empty()
			and aim.on_request({}).is_empty(), "shots: other requests aren't answered here")
	_test_shot_answers()

	# an older bridge (no dispersion): FIRE draws its own tracer
	aim.on_request(req)
	ui.show_request(req)
	tracers = aim._tracers
	aim.on_fire(cam, Vector2.ZERO, true)
	_check.call(aim.dispersion == 0.0 and aim._tracers == tracers + 1, "shots: without dispersion FIRE draws its tracer as before")
	ui.clear()


## A `shot` answer of exactly the bridge's types (contracts/bridge_api.md `answer`): end, hit_uid, part, quality
## and, for a FIRE (`fire`), fly.
static func _bridge_typed(s: Variant, fire := false) -> bool:
	if not s is Dictionary:
		return false
	var d: Dictionary = s
	var keys := ["end", "hit_uid", "part", "quality"]
	if fire:
		keys.append("fly")
	if d.size() != keys.size() or not d.has_all(keys):
		return false
	if fire and typeof(d["fly"]) != TYPE_BOOL:
		return false
	return typeof(d["end"]) == TYPE_VECTOR3I and typeof(d["hit_uid"]) == TYPE_INT and d["hit_uid"] >= 0 \
			and typeof(d["part"]) == TYPE_STRING and (d["part"] as String).to_utf8_buffer().size() <= 64 \
			and typeof(d["quality"]) == TYPE_FLOAT and d["quality"] >= 0.0 and d["quality"] <= 0.99


## shot_answer() keeps the bridge's types and ranges; send_shot() cancels a shot whose answer the bridge refuses,
## so CDDA never waits on it.
func _test_shot_answers() -> void:
	var A := AimController
	var end := Vector3i(4, -2, 1)
	var ok := A.shot_answer(end, 7, "head", 0.5)
	var junk := A.shot_answer(end, -5, "x".repeat(65), NAN)
	var wide := A.shot_answer(end, 7, "é".repeat(33), 3.0)
	_check.call(ok == {"end": end, "hit_uid": 7, "part": "head", "quality": 0.5} and _bridge_typed(ok)
			and junk == {"end": end, "hit_uid": 0, "part": "", "quality": 0.0} and _bridge_typed(junk)
			and wide["part"] == "" and wide["quality"] == 0.99 and A.shot_answer(end, 1, "eyes", -1.0)["quality"] == 0.0
			and A.shot_answer(end, 1, "e".repeat(64), INF)["part"].length() == 64,
			"shot answers: a negative uid is 0, a part over 64 bytes is \"\", quality clamped to 0..0.99, NaN 0 (%s %s %s)" % [ok, junk, wide])
	var fb_ok := A.fallback_answer(31) == {"id": 31, "cancel": true} and typeof(A.fallback_answer(31.0)["id"]) == TYPE_INT
	for bad: Variant in ["31", -1, 0, 1.5, null, NAN, INF, [31], 1e12]:
		fb_ok = fb_ok and A.fallback_answer(bad).is_empty()
	_check.call(fb_ok, "shot answers: the fallback is a cancel with the int id, none for a bad id")

	var sent := []
	var refuse := [0]   # 0 none, 1 everything but a cancel, 2 everything
	var send := func(d: Dictionary) -> bool:
		sent.append(d)
		return refuse[0] == 0 or (refuse[0] == 1 and d.has("cancel"))
	var shot := {"id": 31, "shot": ok}
	var cancel := {"id": 31, "cancel": true}
	var taken := A.send_shot(shot, send)
	var took_ok := taken == shot and sent == [shot]
	refuse[0] = 1
	sent.clear()
	taken = A.send_shot(shot, send)
	var fell_back := taken == cancel and sent == [shot, cancel]
	refuse[0] = 2
	sent.clear()
	taken = A.send_shot(shot, send)
	var both := taken.is_empty() and sent == [shot, cancel]
	sent.clear()
	taken = A.send_shot(cancel, send)
	var no_resend := taken.is_empty() and sent == [cancel]
	sent.clear()
	taken = A.send_shot({"id": "31", "shot": ok}, send)
	var bad_id := taken.is_empty() and sent.size() == 1
	var odd := [0]
	var not_bool := func(_d: Dictionary) -> Variant:
		odd[0] += 1
		return 1
	var odd_ok: bool = A.send_shot(shot, not_bool).is_empty() and odd[0] == 2 and A.send_shot(shot, Callable()).is_empty()
	_check.call(took_ok and fell_back and both and no_resend and bad_id and odd_ok,
			"shot answers: a refused shot answer is followed by a cancel, once; a refused cancel isn't resent (%s)"
			% [[took_ok, fell_back, both, no_resend, bad_id, odd_ok]])


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
	_check.call(ev.shake_strength() > 0.0 and ev.shake_offset().length() > 0.0, "explosions: nearby blasts shake")
	for i in 40:
		ev.tick(0.05)
	_check.call(ev.live_count() == 0 and ev.flash_strength() == 0.0 and ev.shake_strength() == 0.0
			and ev.shake_offset() == Vector2.ZERO, "explosions: effects end, the flash and the shake fade")
	var boom := ev.sound_for("blast", 5.0)
	_check.call(boom.data.size() > 40000 and ev.sound_for("blast", 5.0) == boom
			and ev.sound_for("flashbang", 1.0).data.size() < boom.data.size(),
			"explosions: a boom per kind and size, made once (flashbang shorter)")
	ev.flash_rect.free()
	ev.free()


## C9 views: over the shoulder the pick still finds what's under the crosshair but the bullet leaves the eyes;
## top-down (the screen centre is the player) mouse-look aiming follows the facing, a click picks what's under the
## mouse, and no crosshair shows.
func _test_views(world: WorldView, me: Vector3i, zp: Vector3i, ui: RequestUI, aim: AimController, cam: Camera3D,
		req: Dictionary) -> void:
	var keep := cam.global_transform
	var eye := world.coords.ms_center_to_world(me) + Vector3(0, 1.5, 0)
	var east := world.coords.ms_center_to_world(zp) + Vector3(0, 1.2, 0)
	var facing := ((east - eye) * Vector3(1, 0, 1)).normalized()
	var mode := ["shoulder"]
	aim.view = func() -> Dictionary: return {"mode": mode[0], "eye": eye, "facing": facing}
	aim.first_person = true
	ui.show_request(req)
	cam.global_position = eye - facing * ViewCamera.SHOULDER_BACK + Vector3(0, ViewCamera.SHOULDER_UP, 0) \
			+ facing.cross(Vector3.UP) * ViewCamera.SHOULDER_RIGHT
	cam.look_at(east)
	var centre := cam.get_viewport().get_visible_rect().size / 2.0
	var line := aim.shot_line(cam, centre, true)
	_check.call(aim.pick(cam, centre, true) == zp and (line[0] as Vector3).is_equal_approx(eye)
			and (line[1] as Vector3).dot((east - eye).normalized()) > 0.98,
			"aim views: over the shoulder the crosshair picks the zombie, the bullet leaves the eyes towards it")
	mode[0] = "top"
	cam.global_position = eye - facing * 8.0 + Vector3(0, 12, 0)
	cam.look_at(eye - Vector3(0, 0.8, 0))
	var top_line := aim.shot_line(cam, centre, true)
	_check.call(aim.pick(cam, centre, true) == zp and (top_line[0] as Vector3).is_equal_approx(eye)
			and (top_line[1] as Vector3).is_equal_approx(facing),
			"aim views: top-down, mouse-look aims along the facing, not at the player under the screen centre")
	var at_zombie := cam.unproject_position(east)
	_check.call(aim.pick(cam, at_zombie) == zp, "aim views: top-down, a click on the zombie picks it")
	aim.update(cam, false)
	_check.call(not aim.crosshair.visible, "aim views: no crosshair top-down")
	ui.clear()
	aim.view = Callable()
	cam.global_transform = keep


func _test_bullets(root: Node, world: WorldView, tables: IdTables, me: Vector3i, zp: Vector3i, ui: RequestUI,
		aim: AimController, cam: Camera3D, req: Dictionary) -> void:
	var B := BulletPhysics
	var nine: Array = B.ammo_profile("9mm")
	var rifle: Array = B.ammo_profile("223")
	_check.call(nine[0] < rifle[0] and B.ammo_profile("")[0] == B.DEFAULT[0], "bullets: rifles are faster, unknown ammo gets a default")
	# zeroed: the path crosses the line of sight at ZERO_M, then drops below it; pistols drop more
	var drops := []
	for prof: Array in [nine, rifle]:
		var r := B.fly(Vector3.ZERO, B.launch_dir(Vector3.FORWARD, prof[0]), prof[0], prof[1], {}, null)
		var y_at := func(z: float) -> float:
			var path: Array = r["path"]
			for i in range(1, path.size()):
				if -path[i].z >= z:
					return lerpf(path[i - 1].y, path[i].y, (z - -path[i - 1].z) / maxf(-path[i].z - -path[i - 1].z, 0.0001))
			return NAN
		drops.append([y_at.call(B.ZERO_M), y_at.call(100.0)])
	_check.call(absf(drops[0][0]) < 0.01 and absf(drops[1][0]) < 0.01, "bullets: sights zeroed at 25 m (%s)" % [drops])
	_check.call(drops[0][1] < drops[1][1] and drops[0][1] < -0.05, "bullets: at 100 m the pistol bullet has dropped more (%s)" % [drops])
	# a zombie figure: aimed at its head / legs, the bullet hits that zone
	var cv := CreatureView.new()
	root.add_child(cv)
	cv.apply(world.snapshot, world)
	aim.creature_view = cv
	var z: CreatureFigure = null
	for uid: int in cv.figures():
		z = cv.figures()[uid]
	var head := Vector3.ZERO
	var leg := Vector3.ZERO
	for zz: Array in z.hit_zones():
		if zz[1] == "head":
			head = (zz[0] as MeshInstance3D).global_position
		elif zz[1] == "leg_l":
			leg = (zz[0] as MeshInstance3D).global_position
	var eye := world.coords.ms_center_to_world(me) + Vector3(0, 1.6, 0)
	for want: Array in [["head", head], ["leg_l", leg]]:
		var r := B.fly(eye, B.launch_dir(eye.direction_to(want[1]), rifle[0]), rifle[0], rifle[1], cv.figures(), aim.look_ray)
		_check.call(r["hit"] == "creature" and r["zone"] == want[0], "bullets: aimed at the %s, hit the %s (%s)" % [want[0], r.get("zone"), r["hit"]])
	# soft cover: furniture in front of the zombie's legs doesn't stop the client's bullet (CDDA's path decides)
	var cover := zp - Vector3i(signi(zp.x - me.x), signi(zp.y - me.y), 0)
	var csm: Snapshot.Submap = world.snapshot.submaps.get(CddaCoords.ms_to_sm(cover))
	var cl := CddaCoords.ms_to_local(cover)
	var stopped := {}
	var through := {}
	if cover != me and csm != null:
		var ci := cl.y * CddaCoords.SEEX + cl.x
		var old_furn: int = csm.furn[ci]
		csm.furn[ci] = 1
		stopped = aim.look_ray.cast(eye, eye.direction_to(leg), 30.0, false)
		through = B.fly(eye, B.launch_dir(eye.direction_to(leg), rifle[0]), rifle[0], rifle[1], cv.figures(), aim.look_ray)
		csm.furn[ci] = old_furn
	_check.call(stopped.get("what") == "furniture" and through.get("hit") == "creature",
			"bullets: furniture is soft cover, the bullet flies through it (%s, %s)" % [stopped.get("what"), through.get("hit")])
	_check.call(B.cdda_part("head", true, {"head": true}) == "head" and B.cdda_part("torso", true, {"head": true}) == ""
			and B.cdda_part("arm_l", false, {}) == "arm_l", "bullets: zones map to weak points / body parts")
	# through the aim controller: a gun in hand answers FIRE with the shot
	var gun := IdTables.Def.new()
	gun.gun = "rifle"
	gun.gun_ammo = "223"
	aim.wielded_gun = func() -> IdTables.Def: return gun
	var zdef: IdTables.Def = tables.def_named("mtype", "mon_zombie")
	var old_wp := zdef.weakpoints
	zdef.weakpoints = {"head": true, "eye": true}
	cam.global_position = eye
	cam.look_at(head)
	ui.show_request(req)
	answers.clear()
	aim.on_fire(cam, Vector2.ZERO, true)
	var a: Dictionary = answers[0] if not answers.is_empty() else {}
	var shot: Dictionary = a.get("shot", {})
	_check.call(a.get("action") == "FIRE" and shot.get("hit_uid") == 8589934593 and shot.get("part") == "head"
			and a.get("pos") == zp and shot.get("quality") is float, "bullets: FIRE carries the client's shot (%s)" % [a])
	_check.call(shot.get("fly") == true and aim.shot_aim.get("sight") is Vector3 and aim.shot_aim.get("ammo") == "223",
			"shots: a client-flown FIRE says fly and keeps the aim (%s)" % [aim.shot_aim])
	_test_shot_requests(aim, ui, cam, req, me, zp)
	_test_horde(root, aim, cv, eye, head)
	_test_wielded_and_vr(aim, ui, cam, req, eye, head)
	_test_melee(aim, eye, head, me, zp)
	_test_techniques(aim, ui, cam, eye, head, zp)
	zdef.weakpoints = old_wp
	aim.wielded_gun = Callable()
	aim.creature_view = null
	cv.free()


const ZUID := 8589934593   # the test zombie


## Melee: an aimed strike picks the figure within reach (not past MELEE_REACH_M, not through a wall), names the
## way to it, and answers the swing request for its square once; anything else cancels.
func _test_melee(aim: AimController, eye: Vector3, head: Vector3, me: Vector3i, zp: Vector3i) -> void:
	var S := AimController
	_check.call(S.strike_dir(me, me + Vector3i(-1, 0, 0)) == "LEFT" and S.strike_dir(me, me + Vector3i(2, -2, 0)) == "RIGHTUP"
			and S.strike_dir(me, me + Vector3i(0, 2, 0)) == "DOWN" and S.strike_dir(me, me + Vector3i(2, 1, 0)) == ""
			and S.strike_dir(me, me + Vector3i(3, 0, 0)) == "" and S.strike_dir(me, me) == ""
			and S.strike_dir(me, me + Vector3i(1, 0, 1)) == "", "melee: strike ways (8 ways, 2 squares, this level)")
	var dir := eye.direction_to(head)
	var near := head - dir * 1.5
	var m := aim.melee_from(near, dir)
	_check.call(m.get("uid") == ZUID and m.get("part") == "head" and m.get("square") == zp,
			"melee: a strike at the head picks the zombie's head (%s)" % [m])
	var far := head - dir * (S.MELEE_REACH_M + 1.0)
	_check.call(aim.melee_from(far, dir).is_empty() and aim.melee_aim.is_empty(), "melee: nothing past the reach")
	aim.melee_from(near, dir)
	var a := aim.on_request({"kind": "swing", "id": 41, "cursor": zp, "origin": me, "range": 1, "mode": "main"})
	var s: Dictionary = a.get("shot", {})
	_check.call(a.get("id") == 41 and s.get("end") == zp and s.get("hit_uid") == ZUID and s.get("part") == "head"
			and _bridge_typed(s), "melee: the swing request gets the aimed part (%s)" % [a])
	var again := aim.on_request({"kind": "swing", "id": 42, "cursor": zp})
	aim.melee_from(near, dir)
	var elsewhere := aim.on_request({"kind": "swing", "id": 43, "cursor": zp + Vector3i(0, 1, 0)})
	var bad_id := aim.on_request({"kind": "swing", "id": "x", "cursor": zp})
	_check.call(again.get("cancel") == true and not again.has("shot") and elsewhere.get("cancel") == true
			and not elsewhere.has("shot") and bad_id.is_empty(),
			"melee: one answer per strike, another square cancels (%s, %s)" % [again, elsewhere])
	# by hand (VR): a segment from the hand to the weapon's tip
	var tip := head + dir * 0.2
	var seg := aim.melee_segment(near, tip)
	_check.call(seg.get("uid") == ZUID and seg.get("part") == "head" and seg.get("square") == zp and aim.melee_aim == seg,
			"melee: a hand segment through the head picks the zombie's head (%s)" % [seg])
	var short := aim.melee_segment(near, near + dir * 0.3).is_empty() and aim.melee_aim.is_empty()
	var too_long := aim.melee_segment(head - dir * (S.MELEE_REACH_M + 0.5), head + dir * 0.2).is_empty()
	var junk := aim.melee_segment(Vector3(NAN, 0, 0), tip).is_empty() and aim.melee_segment(near, Vector3(INF, 0, 0)).is_empty() \
			and aim.melee_segment(near, near).is_empty() and aim.melee_aim.is_empty()
	_check.call(short and too_long and junk, "melee: a segment short of the figure, over the reach, or junk picks nothing (%s)"
			% [[short, too_long, junk]])
	var beside := zp + Vector3i(1, 0, 0)   # the player's square for these: the zombie is one square west
	var act := aim.strike_segment("off", near, tip, beside)
	var kept: Dictionary = aim.melee_aim.duplicate()
	var by_hand := aim.on_request({"kind": "swing", "id": 44, "cursor": zp, "origin": beside, "range": 1, "mode": "off"})
	_check.call(act == "fp3d_attack_off_aim_LEFT" and kept.get("uid") == ZUID
			and by_hand.get("shot", {}).get("hit_uid") == ZUID and by_hand.get("shot", {}).get("part") == "head",
			"melee: a strike by hand is the aimed action and answers the swing request (%s, %s)" % [act, by_hand])
	_check.call(seg.get("want") == "stun" and kept.get("want") == "stun" and by_hand.get("action") == "stun",
			"melee: a strike by hand keeps the family its zone calls and sends it (%s, %s)" % [kept, by_hand])
	var off_way := aim.strike_segment("main", near, tip, zp + Vector3i(2, 1, 0)) == "" and aim.melee_aim.is_empty()
	var bad_hand := aim.strike_segment("left", near, tip, beside) == "" and aim.strike_segment("", near, tip, beside) == "" \
			and aim.melee_aim.is_empty()
	var miss := aim.strike_segment("main", near, near + dir * 0.3, beside) == "" and aim.melee_aim.is_empty()
	_check.call(off_way and bad_hand and miss, "melee: by hand off the 8 ways, an unknown hand or a miss: no action, no aim kept (%s)"
			% [[off_way, bad_hand, miss]])
	# techniques: the zone a strike lands on calls a family, sent as the swing answer's `action`
	var calls := {"head": "stun", "eye": "stun", "leg_l": "down", "leg_r": "down", "leg": "down", "arm_l": "disarm",
			"arm_r": "disarm", "torso": "", "wing": ""}
	var junk_zones := ["", "HEAD", "Head", "head ", "eyes", "legs", "arm", "stun", "x".repeat(500)]
	var call_ok := calls.keys().all(func(zn: String) -> bool: return S.technique_call(zn) == calls[zn]) \
			and junk_zones.all(func(zn: String) -> bool: return S.technique_call(zn) == "")
	var fig: CreatureFigure = aim.creature_view.figures()[ZUID]
	var leg := Vector3.ZERO
	var zones_known := BulletPhysics.CHARACTER_PARTS.keys().all(func(zn: String) -> bool: return calls.has(zn)) \
			and BulletPhysics.MONSTER_PARTS.keys().all(func(zn: String) -> bool: return calls.has(zn))
	for zz: Array in fig.hit_zones():
		zones_known = zones_known and calls.has(zz[1])
		if zz[1] == "leg_l":
			leg = (zz[0] as MeshInstance3D).global_position
	_check.call(call_ok and zones_known,
			"melee: technique_call: head and eye stun, legs down, arms disarm; torso, wing and junk nothing (%s)"
			% [[call_ok, zones_known]])
	var hm := aim.melee_from(near, dir)
	var ha := aim.on_request({"kind": "swing", "id": 45, "cursor": zp, "origin": me, "range": 1, "mode": "main"})
	var hs: Dictionary = ha.get("shot", {})
	_check.call(hm.get("want") == "stun" and ha.size() == 3 and ha.get("id") == 45 and typeof(ha.get("action")) == TYPE_STRING
			and ha.get("action") == "stun" and hs.get("part") == "head" and hs.get("hit_uid") == ZUID and _bridge_typed(hs)
			and aim._last_call.get("uid") == ZUID and aim._last_call.get("family") == 3,
			"melee: a strike at the head calls a stun: the answer names the head and says action stun (%s)" % [ha])
	var to_leg := eye.direction_to(leg)
	var lm := aim.melee_from(leg - to_leg * 1.5, to_leg)
	var la := aim.on_request({"kind": "swing", "id": 46, "cursor": zp})
	_check.call(lm.get("want") == "down" and lm.get("part") == "" and la.get("action") == "down"
			and la.get("shot", {}).get("part") == "" and _bridge_typed(la.get("shot")),
			"melee: a strike at a leg with no weak point there still answers, calling a takedown (%s, %s)" % [lm, la])
	var by := func(part: String, want: Array) -> Dictionary:   # a melee aim set by hand; want [] = no `want` key
		aim.melee_aim = {"square": zp, "uid": ZUID, "part": part, "quality": 0.5, "time": Time.get_ticks_msec()}
		if not want.is_empty():
			aim.melee_aim["want"] = want[0]
		return aim.on_request({"kind": "swing", "id": 47, "cursor": zp})
	var down: Dictionary = by.call("", ["down"])
	var down_ok: bool = down.size() == 3 and down.get("action") == "down" and _bridge_typed(down.get("shot")) \
			and down["shot"]["part"] == "" and down["shot"]["hit_uid"] == ZUID and aim._last_call.get("family") == 2
	var no_want: Dictionary = by.call("", [])
	var empty_want: Dictionary = by.call("", [""])
	var none_ok := no_want == {"id": 47, "cancel": true} and empty_want == no_want and aim._last_call.is_empty()
	var long_part: Dictionary = by.call("p".repeat(S.MAX_PART_BYTES + 1), ["stun"])
	_check.call(down_ok and none_ok and long_part == no_want,
			"melee: no part but a call answers a shot plus the action; no part and no call, or a part over the cap, cancels (%s)"
			% [[down, no_want, empty_want, long_part]])
	var families := []
	for w: String in S.CALL_FAMILY:
		var r: Dictionary = by.call("head", [w])
		families.append(r.get("action") == w and aim._last_call.get("uid") == ZUID
				and aim._last_call.get("family") == S.CALL_FAMILY[w])
	var junk_wants := []
	for w: Variant in ["sweep", 7, null, "push", "strike", "STUN", "stun ", ["stun"], 3.0, "x".repeat(500)]:
		var r: Dictionary = by.call("head", [w])
		var r2: Dictionary = by.call("", [w])
		junk_wants.append(r.size() == 2 and not r.has("action") and r.get("shot", {}).get("part") == "head"
				and r2 == no_want and aim._last_call.is_empty())
	_check.call(families == [true, true, true] and not junk_wants.has(false),
			"melee: down, stun and disarm are sent and remembered; a junk want sends no action (%s, %s)" % [families, junk_wants])
	aim.melee_aim = {}
	aim._last_call = {}


## Melee techniques: the player's hit names the technique CDDA used (HitFeedback.technique_used, one clean line);
## the crosshair shows it as a note, gold when the swing answer called its family on that creature, and hides
## again when the note is over. A call ends with its own swing (HitFeedback.swing_resolved). Attack events only:
## nothing here confirms a hit.
func _test_techniques(aim: AimController, ui: RequestUI, cam: Camera3D, eye: Vector3, head: Vector3, zp: Vector3i) -> void:
	var hf := aim.hits
	var me := hf.player_uid()
	var z := ZUID
	var used := []
	var on_used := func(uid: int, technique: String, family: int) -> void: used.append([uid, technique, family])
	hf.technique_used.connect(on_used)
	var resolved := []   # swing_resolved: [uid, hit, techniques told before it]
	var on_resolved := func(uid: int, struck: bool) -> void: resolved.append([uid, struck, used.size()])
	hf.swing_resolved.connect(on_resolved)
	var hit := func(attacker: Variant, target: Variant, detail: Variant, more: Dictionary) -> Dictionary:
		var e := {"kind": "attack", "uid": attacker, "other": target, "detail": detail, "pos": Vector3i.ZERO}
		e.merge(more)
		return e
	hf.on_events([hit.call(me, z, 1, {"text": "Leg Sweep", "amount": 2}),
			hit.call(float(me), float(z), 1.0, {"text": " <color_yellow>Feint</color> ", "amount": 1.0})])
	_check.call(used == [[z, "Leg Sweep", 2], [z, "Feint", 1]],
			"techniques: the player's hit with a technique tells the creature, the name and the family (%s)" % [used])
	var after_technique := resolved == [[z, true, 1], [z, true, 2]]
	used.clear()
	resolved.clear()
	hf.on_events([hit.call(me, z, 0, {"text": "Leg Sweep", "amount": 2}), hit.call(z + 4, z, 1, {"text": "Bite", "amount": 1}),
			hit.call(me, me, 1, {"text": "Trip", "amount": 2}), hit.call(me, z, 2, {"text": "Trip", "amount": 2}),
			hit.call(me, -1, 1, {"text": "Trip"}), hit.call(NAN, z, 1, {"text": "Trip"}), hit.call(me, z, "1", {"text": "Trip"}),
			hit.call(me, z, 1, {}), hit.call(me, z, 1, {"text": "", "amount": 2}),
			hit.call(me, z, 1, {"text": "  \t ", "amount": 2}), hit.call(me, z, 1, {"text": 7}), hit.call(me, z, 1, {"text": null}),
			hit.call(me, z, 1, {"text": ["Trip"]}), hit.call(me, z, 1, {"text": {"name": "Trip"}}),
			hit.call(me, z, 1, {"text": "<color_red></color>\n\u202e", "amount": 2})])
	_check.call(used.is_empty(),
			"techniques: a miss, another attacker, a malformed attack, no text, an empty or non-String text: nothing (%s)"
			% [used])
	var ends := [[z, false, 0]]   # the miss, then the eight hits with no name; no one else's, no malformed attack
	for i in 8:
		ends.append([z, true, 0])
	_check.call(after_technique and resolved == ends,
			"techniques: swing_resolved follows each strike of the player at a creature, hit (after its technique) or miss; "
			+ "not anyone else's or a malformed attack (%s, %s)" % [after_technique, resolved])
	hf.swing_resolved.disconnect(on_resolved)
	var junk_amounts: Array = [NAN, -1, 99, "2", 2.5, INF, null, [3], 6, true]
	for a: Variant in junk_amounts:
		hf.on_events([hit.call(me, z, 1, {"text": "Jab", "amount": a})])
	hf.on_events([hit.call(me, z, 1, {"text": "Jab"})])
	var zeros := used.size() == junk_amounts.size() + 1 and used.all(func(u: Array) -> bool: return u == [z, "Jab", 0])
	used.clear()
	for f in HitFeedback.MAX_FAMILY + 1:
		hf.on_events([hit.call(me, z, 1, {"text": "Jab", "amount": f})])
	_check.call(zeros and used.map(func(u: Array) -> int: return u[2]) == [0, 1, 2, 3, 4, 5],
			"techniques: the family is 0..5, a junk amount (NaN, -1, 99, \"2\", none) gives 0 (%s)" % [used])
	used.clear()
	var nasty := "<color_red>Brutal\u202e Strike</color>\n\t\u0007\u200b" + "x".repeat(5000)
	hf.on_events([hit.call(me, z, 1, {"text": nasty, "amount": 5}), hit.call(me, z, 1, {"text": "A".repeat(5000), "amount": 5})])
	var clean: bool = used.size() == 2 and used[0] == [z, "Brutal Strike" + "x".repeat(27), 5] \
			and used[1] == [z, "A".repeat(40), 5]
	for u: Array in used:
		var t: String = u[1]
		clean = clean and t.length() <= HitFeedback.MAX_TECHNIQUE_LEN and not t.contains("<")
		for i in t.length():
			clean = clean and t.unicode_at(i) >= 0x20 and not CddaText.is_hidden(t.unicode_at(i))
	_check.call(clean, "techniques: a hostile name (colour tags, control and direction characters, 5000 long) arrives clean, "
			+ "at most 40 characters (%s)" % [used.map(func(u: Array) -> int: return (u[1] as String).length())])
	used.clear()

	# the note over the crosshair
	var cross := aim.crosshair
	var was_first_person := aim.first_person
	aim.first_person = true
	ui.clear()
	var dir := eye.direction_to(head)
	var near := head - dir * 1.5
	var swing := func() -> String:   # an aimed strike at the zombie's head, its swing request answered
		aim.melee_from(near, dir)
		return str(aim.on_request({"kind": "swing", "id": 60, "cursor": zp}).get("action", ""))
	var blow := func(uid: int, family: int) -> void:   # CDDA's hit event for it
		hf.on_events([hit.call(me, uid, 1, {"text": "Stunning Blow", "amount": family})])
	cross.tick_note(5.0)   # the notes of the events above are over
	var sent: String = swing.call()
	aim.update(cam, false)
	var hidden_before := not cross.visible and not cross.noting() and not cross.marking()
	blow.call(z, 3)
	aim.update(cam, false)
	_check.call(sent == "stun" and hidden_before and cross.noting() and cross.note_called and cross.note == "Stunning Blow"
			and cross.visible and not cross.show_cross and not cross.marking() and aim._last_call.is_empty(),
			"techniques: a called stun that CDDA used shows as a called note, without aiming or a hit marker (%s, %s)"
			% [sent, cross.note])
	var plain := []   # notes that show but aren't called
	swing.call()
	blow.call(z, 2)   # another family than the one called
	plain.append(cross.noting() and not cross.note_called)
	swing.call()
	blow.call(z + 1, 3)   # another creature
	plain.append(cross.noting() and not cross.note_called)
	swing.call()
	blow.call(z, 3)
	var first := cross.note_called
	blow.call(z, 3)   # one call, one note: the second isn't called
	plain.append(first and cross.noting() and not cross.note_called)
	swing.call()
	aim._last_call["time"] = Time.get_ticks_msec() - AimController.CALL_KEEP_MS - 1
	blow.call(z, 3)   # the call is too old
	plain.append(cross.noting() and not cross.note_called)
	aim.melee_aim = {}
	var cancelled := aim.on_request({"kind": "swing", "id": 61, "cursor": zp})
	blow.call(z, 3)   # nothing was called
	plain.append(cancelled.get("cancel") == true and cross.noting() and not cross.note_called)
	swing.call()
	aim._last_call["time"] = Time.get_ticks_msec() - AimController.CALL_KEEP_MS + 2000
	blow.call(z, 3)   # an older call still inside CALL_KEEP_MS
	_check.call(plain == [true, true, true, true, true] and cross.note_called,
			"techniques: another family, another creature, a used-up, old or missing call: the note shows, not called (%s)"
			% [plain])
	# a call ends with its own swing: a later strike that called nothing (plain, a bump) never shows as called
	var ended := []
	swing.call()
	hf.on_events([hit.call(me, z, 0, {})])   # the called strike misses
	ended.append(aim._last_call.is_empty())
	blow.call(z, 3)   # no swing request since: CDDA's own pick of the family that was called
	ended.append(cross.noting() and not cross.note_called)
	swing.call()
	hf.on_events([hit.call(me, z, 1, {})])   # the called strike hits with no technique
	ended.append(aim._last_call.is_empty())
	blow.call(z, 3)
	ended.append(cross.noting() and not cross.note_called)
	swing.call()
	hf.on_events([hit.call(me, z + 1, 0, {})])   # the swing's attack event names another creature: still its end
	ended.append(aim._last_call.is_empty())
	swing.call()
	hf.on_events([hit.call(z + 4, z, 1, {"text": "Bite", "amount": 3}), hit.call(me, me, 1, {}), hit.call(me, z, 2, {}),
			{"kind": "message", "text": "x"}, {"kind": "sound"}])
	var kept: bool = aim._last_call.get("uid") == z   # someone else's or a malformed attack isn't the swing's
	blow.call(z, 3)
	_check.call(ended == [true, true, true, true, true] and kept and cross.note_called,
			"techniques: a call ends with its own swing, a miss or a hit with no technique too: the next technique isn't "
			+ "called; other attacks and messages leave it (%s, %s)" % [ended, kept])
	# the note ends on its own: no hit marker is showing
	cross.tick_note(1.0)
	aim.update(cam, false)
	var still := cross.noting() and cross.visible and cross.note == "Stunning Blow" and not cross.marking()
	cross.tick_note(0.51)
	var over := not cross.noting() and cross.note == "" and not cross.marking()
	aim.update(cam, false)
	_check.call(still and over and not cross.visible,
			"techniques: with no hit marker showing the note ends after 1.5 s and the crosshair hides again (%s)"
			% [[still, over, cross.visible]])
	cross.show_note("Jab", false)
	cross._process(1.0)
	var mid := cross.noting() and not cross.marking()
	cross._process(0.51)
	aim.update(cam, false)
	_check.call(mid and not cross.noting() and not cross.visible,
			"techniques: the crosshair's own frames count the note down with no hit marker showing (%s)"
			% [[mid, cross.note_left]])
	# the marker and the note keep their own time
	var C := AimController.Crosshair
	cross.show_hit(false, false)
	cross.show_note("Jab", true)
	cross._process(0.2)
	var both: bool = cross.marking() and is_equal_approx(cross.hit_left, C.HIT_FADE_S - 0.2) \
			and is_equal_approx(cross.note_left, C.NOTE_S - 0.2)
	cross._process(0.11)
	var marker_first := not cross.marking() and cross.noting()
	cross.tick_hit(5.0)
	var note_kept: bool = is_equal_approx(cross.note_left, C.NOTE_S - 0.31) and cross.note == "Jab" and cross.note_called
	cross.show_hit(true, true)
	cross.tick_note(5.0)
	var marker_kept: bool = cross.marking() and cross.hit_left == C.HIT_FADE_S and not cross.noting()
	cross.tick_hit(0.31)
	_check.call(both and marker_first and note_kept and marker_kept and not cross.marking(),
			"techniques: the marker still fades in 0.3 s beside a note, each counts down on its own (%s)"
			% [[both, marker_first, note_kept, marker_kept]])
	# where the note is drawn: the hand pointer's hint lines (GrabController) are under the centre
	var centre := Vector2(400, 300)
	var at: Vector2 = C.note_at(centre, 80.0)
	var bottom: float = at.y + ThemeDB.fallback_font.get_descent(C.NOTE_SIZE)
	_check.call(is_equal_approx(at.x, centre.x - 40.0) and bottom <= centre.y - 15.0 * C.HEAD_SCALE,
			"techniques: the note is drawn centred over the centre, above the biggest hit marker, not under it (%s, %s)"
			% [at, bottom])
	cross.show_note("", true)
	var empty := not cross.noting()
	cross.show_note("y".repeat(500), false)
	for d: float in [NAN, -1.0, INF]:
		cross.tick_note(d)
	_check.call(empty and cross.note.length() == C.MAX_NOTE_LEN and cross.note_left == C.NOTE_S and not cross.note_called,
			"techniques: an empty note shows nothing, a long one is cut, junk time steps change nothing (%d)"
			% cross.note.length())
	cross.tick_note(5.0)
	aim.update(cam, false)
	aim.first_person = was_first_person
	aim.melee_aim = {}
	aim._last_call = {}
	hf.technique_used.disconnect(on_used)


## Hordes: a flight tests only the figures near its line (at most 64, the nearest along it) and still hits one on it.
func _test_horde(root: Node, aim: AimController, cv: CreatureView, eye: Vector3, head: Vector3) -> void:
	var B := BulletPhysics
	var speed: float = B.ammo_profile("223")[0]
	var dir := B.launch_dir(eye.direction_to(head), speed)
	var side := dir.cross(Vector3.UP).normalized()
	var figs := cv.figures()
	var extra: Array[int] = []
	var add := func(uid: int, at: Vector3) -> void:   # a blob figure standing at `at`
		var f := CreatureFigure.make(Snapshot.Creature.MONSTER, null)
		root.add_child(f)
		f.global_position = at
		figs[uid] = f
		extra.append(uid)
	for i in 400:   # 20 wide, 20 deep, 30-50 m off to the side
		add.call((1 << 40) + i, eye + side * (30.0 + float(i % 20)) + dir * floorf(i / 20.0) * 2.0 - Vector3(0, 1.6, 0))
	var near := B.figures_near_line(figs, eye, dir, speed)
	var r := aim.fly_from(eye, eye.direction_to(head), "223", false)
	_check.call(figs.size() >= 401 and near.size() == 1 and near.has(ZUID) and r.get("answer", {}).get("hit_uid") == ZUID,
			"horde: 400 figures off to the side aren't tested, the zombie on the line is hit (%d of %d)" % [near.size(), figs.size()])
	for i in 100:   # behind the zombie along the line, and one behind the shooter
		add.call((1 << 41) + i, eye + dir * (6.0 + i) - Vector3(0, 1.6, 0))
	add.call(1 << 42, eye - dir * 5.0 - Vector3(0, 1.6, 0))
	near = B.figures_near_line(figs, eye, dir, speed)
	r = aim.fly_from(eye, eye.direction_to(head), "223", false)
	_check.call(near.size() == B.NEAR_MAX and near.has(ZUID) and near.has((1 << 41)) and not near.has(1 << 42)
			and not near.has((1 << 41) + 99) and r.get("answer", {}).get("hit_uid") == ZUID,
			"horde: at most %d on the line, the nearest, none behind the shooter (%d)" % [B.NEAR_MAX, near.size()])
	var slow := B.figures_near_line(figs, eye, dir, 1.0)   # a crawling projectile: the drop margin is capped
	_check.call(B.figures_near_line(figs, Vector3(NAN, 0, 0), dir, speed).is_empty()
			and B.figures_near_line(figs, eye, Vector3.ZERO, speed).is_empty() and slow.size() == B.NEAR_MAX
			and B.figures_near_line({"x": 1, 5: null, 6: "junk"}, eye, dir, speed).is_empty(),
			"horde: bad lines and junk entries give none, a slow projectile's margin is capped")
	for uid in extra:
		(figs[uid] as Node).free()
		figs.erase(uid)


## Only the wielded gun flies (`weapon_wielded`); VR's fire_from() and live_aim.
func _test_wielded_and_vr(aim: AimController, ui: RequestUI, cam: Camera3D, req: Dictionary, eye: Vector3,
		head: Vector3) -> void:
	var flown := []
	for v: Array in [[false], [true], ["yes"], [1], [null], []]:   # [] = no field (an old bridge)
		var r := req.duplicate()
		if not v.is_empty():
			r["weapon_wielded"] = v[0]
		aim.on_request(r)
		ui.show_request(r)
		answers.clear()
		aim.on_fire(cam, Vector2.ZERO, true)
		var a: Dictionary = answers[0] if not answers.is_empty() else {}
		flown.append(a.get("action") == "FIRE" and a.has("shot"))
	_check.call(flown == [false, true, false, false, false, true],
			"wielded: only weapon_wielded true (or no field) flies, else plain FIRE (%s)" % [flown])

	# fire_from: a barrel pose, no camera
	var barrel := eye + Vector3(0.15, -0.3, 0.0)
	var to_head := barrel.direction_to(head)
	ui.clear()
	var none_ok := not aim.fire_from(barrel, to_head)
	var look := req.duplicate()
	look["mode"] = "look"
	ui.show_request(look)
	var look_ok := not aim.fire_from(barrel, to_head)
	var other := req.duplicate()
	other["weapon_wielded"] = false
	aim.on_request(other)
	ui.show_request(other)
	answers.clear()
	var other_ok := not aim.fire_from(barrel, to_head) and answers.is_empty()
	aim.on_request(req)
	ui.show_request(req)
	var kicks := [0]
	var kick := func() -> void: kicks[0] += 1
	aim.fired.connect(kick)
	var bad_ok: bool = not aim.fire_from(barrel, Vector3.ZERO) and not aim.fire_from(Vector3(NAN, 0, 0), to_head) \
			and not aim.fire_from(barrel, Vector3(INF, 0, 0)) and answers.is_empty() and kicks[0] == 0
	var gun: Callable = aim.wielded_gun
	aim.wielded_gun = func() -> IdTables.Def: return null
	var nogun_ok := not aim.fire_from(barrel, to_head) and answers.is_empty()
	aim.wielded_gun = gun
	_check.call(none_ok and look_ok and other_ok and bad_ok and nogun_ok,
			"fire_from: no request, look mode, another gun firing, a bad pose, no gun: false, nothing sent (%s)"
			% [[none_ok, look_ok, other_ok, bad_ok, nogun_ok]])
	var ok := aim.fire_from(barrel, to_head)
	var a: Dictionary = answers[0] if not answers.is_empty() else {}
	var shot: Dictionary = a.get("shot", {})
	_check.call(ok and answers.size() == 1 and a.get("action") == "FIRE" and shot.get("fly") == true
			and shot.get("hit_uid") == ZUID and aim.shot_aim.get("origin") == barrel and kicks[0] == 1,
			"fire_from: flies from the barrel, FIRE says fly, the aim is kept, it kicks (%s)" % [a])
	aim.fired.disconnect(kick)

	# live_aim: each shot request flies from the hand's pose now; junk poses fall back to the kept aim
	aim.shot_aim["sight"] = to_head.rotated(Vector3.UP, 0.5)   # the kept aim now misses
	aim.shot_aim["time"] = Time.get_ticks_msec()
	var pose: Array = [{}]
	aim.live_aim = func() -> Variant: return pose[0]
	var sreq := {"id": 41, "kind": "shot", "shot_error": 0.0, "shot_angle": 0.0}
	var hit_of := func() -> Variant:
		var res := aim.on_request(sreq)
		return res.get("shot", {}).get("hit_uid", -1) if res.get("id") == 41 else null
	var kept: Variant = hit_of.call()
	pose[0] = {"origin": eye, "sight": eye.direction_to(head) * 3.0}
	var live: Variant = hit_of.call()
	var junk := [{}, "x", null, [eye, to_head], {"origin": eye}, {"origin": Vector3(NAN, 0, 0), "sight": to_head},
			{"origin": eye, "sight": Vector3.ZERO}, {"origin": eye, "sight": Vector3(INF, 0, 0)},
			{"origin": eye + Vector3(10, 0, 0), "sight": (eye + Vector3(10, 0, 0)).direction_to(head)},
			{"origin": [1, 2, 3], "sight": to_head}, {"origin": eye, "sight": "up"}]
	var junk_hits := []
	for p: Variant in junk:
		pose[0] = p
		junk_hits.append(hit_of.call())
	aim.live_aim = Callable()
	_check.call(kept != null and kept != ZUID and live == ZUID,
			"live_aim: a burst's shot flies from the live pose, not the kept aim (%s %s)" % [kept, live])
	_check.call(junk_hits.all(func(x: Variant) -> bool: return x != null and x != ZUID),
			"live_aim: junk poses are ignored, the kept aim flies (%s)" % [junk_hits])
	ui.clear()


## Hit feedback: only CDDA's events confirm hits: the player's projectile event confirms the damage / death on the
## creature it names that came before it in the same batch.
func _test_hits(aim: AimController, ui: RequestUI, cam: Camera3D, tables: IdTables) -> void:
	var hf := aim.hits
	var got := []
	hf.hit_confirmed.connect(func(uid: int, part: String, amount: int, killed: bool) -> void:
		got.append([uid, part, amount, killed]))
	var me := hf.player_uid()
	var head := tables.body_parts.find("head")
	var torso := tables.body_parts.find("torso")
	var z := ZUID
	var shot_by := func(shooter: Variant, hit: Variant) -> Dictionary:
		return {"kind": "projectile", "uid": shooter, "other": hit, "pos": Vector3i.ZERO, "path": []}
	var dmg := func(uid: Variant, amount: Variant, part: Variant) -> Dictionary:
		return {"kind": "damage", "uid": uid, "amount": amount, "detail": part, "pos": Vector3i.ZERO}
	_check.call(me == 1 and head >= 0 and torso >= 0, "hits: the player is uid 1, the tables name head and torso")
	var death := func(uid: Variant) -> Dictionary:
		return {"kind": "death", "uid": uid, "pos": Vector3i.ZERO}
	# CDDA's order: the shot's damage, then its projectile event, in one batch
	hf.on_events([dmg.call(z, 7, torso), shot_by.call(me, z)])
	var cross := aim.crosshair
	_check.call(got == [[z, "torso", 7, false]] and cross.marking() and cross.hit_color == AimController.Crosshair.HIT_WHITE
			and cross.hit_scale == 1.0 and hf.ticks == 1, "hits: damage then the player's projectile in one batch confirms a hit (%s)" % [got])
	aim.first_person = true
	ui.clear()
	aim.update(cam, false)
	var shows := aim.crosshair.visible and not aim.crosshair.show_cross
	hf.on_events([dmg.call(z, 20.0, head), shot_by.call(me, z)])
	_check.call(got.size() == 2 and got[1] == [z, "head", 20, false] and cross.hit_scale == AimController.Crosshair.HEAD_SCALE and shows,
			"hits: a head hit is a bigger marker, shown without aiming (%s)" % [got])
	hf.on_events([dmg.call(z, 12, head), death.call(z), shot_by.call(me, z)])
	_check.call(got.size() == 4 and got[2] == [z, "head", 12, false] and got[3] == [z, "head", 12, true]
			and cross.hit_color == AimController.Crosshair.HIT_RED, "hits: damage and death before the projectile: hit, then a red kill (%s)" % [got])
	cross.tick_hit(0.31)
	aim.update(cam, false)
	_check.call(not cross.marking() and not cross.visible, "hits: the marker fades in 0.3 s")

	# a monster's weak point (the damage event's text) is the part: an eye is a head marker; anything that is no
	# plain id falls back to the body part
	got.clear()
	var wp_dmg := func(text: Variant) -> Dictionary:
		var d0: Dictionary = dmg.call(z, 5, torso)
		d0["text"] = text
		return d0
	hf.on_events([wp_dmg.call("eye"), shot_by.call(me, z)])
	var eye_big := cross.hit_scale == AimController.Crosshair.HEAD_SCALE
	for t: Variant in ["leg_joint", "<b>x", "a".repeat(HitFeedback.MAX_PART_LEN + 1), "", 7, "héad", "head\n", null]:
		hf.on_events([wp_dmg.call(t), shot_by.call(me, z)])
	var parts: Array = got.map(func(g: Array) -> Variant: return g[1])
	_check.call(eye_big and parts == ["eye", "leg_joint", "torso", "torso", "torso", "torso", "torso", "torso", "torso"],
			"hits: a monster's weak point names the part, an eye is a head hit, junk text is the body part (%s)" % [parts])
	cross.tick_hit(0.31)

	# a burst: each projectile event claims only the damage since the one before
	got.clear()
	hf.on_events([dmg.call(z + 1, 3, torso), shot_by.call(me, z + 1), dmg.call(z + 1, 4, head), shot_by.call(me, z + 1),
			shot_by.call(me, z + 1)])
	_check.call(got == [[z + 1, "torso", 3, false], [z + 1, "head", 4, false]],
			"hits: a burst credits each shot's own damage once (%s)" % [got])
	# a later batch, after the projectile, an earlier batch: nothing
	got.clear()
	hf.on_events([dmg.call(z + 1, 5, torso)])
	var later := got.is_empty()
	hf.on_events([shot_by.call(me, z + 1), dmg.call(z + 1, 5, torso), death.call(z + 1)])
	var after := got.is_empty()
	_check.call(later and after, "hits: damage in a later batch or after the projectile event isn't the player's (%s)" % [got])
	# another creature, a miss in between, an ally's projectile
	hf.on_events([dmg.call(z + 3, 5, torso), death.call(z + 3), shot_by.call(me, z + 2)])
	var other := got.is_empty()
	hf.on_events([dmg.call(z + 2, 5, torso), shot_by.call(me, 0), shot_by.call(me, z + 2)])
	var missed := got.is_empty()
	hf.on_events([dmg.call(z + 2, 5, torso), shot_by.call(z + 4, z + 2)])
	var ally := got.is_empty()
	hf.on_events([dmg.call(z + 2, 6, torso), death.call(z + 2), shot_by.call(z + 4, z + 2), shot_by.call(me, z + 2)])
	var ally_first := got.is_empty()
	hf.on_events([dmg.call(z + 2, 6, torso), shot_by.call(z + 2, me), shot_by.call(me, z + 2)])
	var at_me := got.is_empty()
	_check.call(other and missed and ally and ally_first and at_me,
			"hits: damage on another creature, before the player's miss, an ally's or a monster's projectile: nothing (%s)"
			% [[other, missed, ally, ally_first, at_me]])
	hf.on_events([dmg.call(z + 3, 5, torso), dmg.call(z + 2, 8, torso), dmg.call(me, 9, torso), shot_by.call(me, z + 2)])
	_check.call(got == [[z + 2, "torso", 8, false]], "hits: of several creatures hurt, only the one shot counts (%s)" % [got])
	# junk
	got.clear()
	hf.on_events(["junk", 5, null, {"kind": 7, "uid": z + 5}, {"kind": "damage"}, dmg.call("x", 5, torso),
			dmg.call(z + 5, -3, torso), dmg.call(z + 5, NAN, torso), dmg.call(z + 5, "5", torso), dmg.call(z + 5, 1e12, torso),
			dmg.call(z + 5, 4.5, torso), dmg.call(z + 5, 5, -1), dmg.call(z + 5, 5, "head"), dmg.call(z + 5, 5, INF),
			{"kind": "death", "uid": [z + 5]}, death.call(-1), shot_by.call(me, z + 5)])
	hf.on_events([shot_by.call(me, -4), shot_by.call(1.5, z), shot_by.call(me, NAN), shot_by.call(me, 1e300), shot_by.call(me, me),
			{"kind": "projectile", "uid": me, "other": "z"}, {"kind": "projectile"}])
	var junk_ok := got.is_empty()
	hf.on_events([dmg.call(z + 5, 9, 99999), {"kind": "damage", "uid": z + 5, "amount": 2}, shot_by.call(me, z + 5)])
	_check.call(junk_ok and got == [[z + 5, "", 9, false], [z + 5, "", 2, false]],
			"hits: junk events are skipped, an unknown or missing body part is \"\" (%s)" % [got])
	# melee: the player's hit attack, then damage from the player on that creature (messages may come between)
	got.clear()
	var strike := func(attacker: Variant, target: Variant, hit: Variant) -> Dictionary:
		return {"kind": "attack", "uid": attacker, "other": target, "detail": hit, "pos": Vector3i.ZERO}
	var hurt_by := func(uid: Variant, amount: Variant, part: Variant, source: Variant) -> Dictionary:
		var d: Dictionary = dmg.call(uid, amount, part)
		d["other"] = source
		return d
	var said := {"kind": "message", "text": "You hit the zombie."}
	var strikes := []
	hf.strike_confirmed.connect(func(uid: int, part: String, amount: int, killed: bool) -> void:
		strikes.append([uid, part, amount, killed]))
	hf.on_events([strike.call(me, z + 6, 1), said, hurt_by.call(z + 6, 9, torso, me)])
	var one := got == [[z + 6, "torso", 9, false]] and strikes == got
	hf.on_events([strike.call(me, z + 6, 1), hurt_by.call(z + 6, 11, head, me), {"kind": "sound", "amount": 5},
			death.call(z + 6), shot_by.call(me, z + 6)])
	_check.call(one and got.size() == 3 and got[1] == [z + 6, "head", 11, false] and got[2] == [z + 6, "head", 11, true]
			and strikes == got,
			"hits: melee: the player's hit, then its damage and death confirm, never again for a shot (%s)" % [got])
	got.clear()
	hf.on_events([strike.call(me, z + 7, 0), hurt_by.call(z + 7, 5, torso, me)])
	var miss := got.is_empty()
	hf.on_events([strike.call(z + 4, z + 7, 1), hurt_by.call(z + 7, 5, torso, z + 4)])
	var ally_hit := got.is_empty()
	hf.on_events([strike.call(me, z + 7, 1), hurt_by.call(z + 7, 5, torso, 0), hurt_by.call(z + 7, 5, torso, me)])
	var bleed := got.is_empty()
	hf.on_events([strike.call(me, z + 7, 1), dmg.call(z + 7, 5, torso)])
	var no_source := got.is_empty()
	hf.on_events([strike.call(me, z + 7, 1), hurt_by.call(z + 8, 5, torso, me), hurt_by.call(z + 7, 5, torso, me)])
	var elsewhere := got.is_empty()
	hf.on_events([strike.call(me, z + 7, 1), {"kind": "turn_end"}, hurt_by.call(z + 7, 5, torso, me)])
	var next_turn := got.is_empty()
	hf.on_events([strike.call(me, z + 7, 1), death.call(z + 7)])
	var no_damage := got.is_empty()
	hf.on_events([strike.call(me, me, 1), hurt_by.call(me, 5, torso, me), strike.call(me, z + 7, "1"),
			hurt_by.call(z + 7, 5, torso, me), strike.call(me, z + 7, 2), hurt_by.call(z + 7, 5, torso, me),
			strike.call(NAN, z + 7, 1), hurt_by.call(z + 7, 5, torso, me), {"kind": "attack"}, hurt_by.call(z + 7, 5, torso, me)])
	var junk := got.is_empty()
	var strikes_before := strikes.size()
	hf.on_events([dmg.call(z + 7, 7, torso), shot_by.call(me, z + 7)])
	_check.call(got.size() == 1 and strikes.size() == strikes_before, "hits: a shot's hit isn't a strike (%s)" % [strikes])
	got.clear()
	_check.call(miss and ally_hit and bleed and no_source and elsewhere and next_turn and no_damage and junk,
			"hits: melee: a miss, an ally's hit, other or no source, another creature, a later turn, junk: nothing (%s)"
			% [[miss, ally_hit, bleed, no_source, elsewhere, next_turn, no_damage, junk]])
	_test_strike_runs(aim, me, head, torso)
	var snd := HitFeedback.tick_stream()
	_check.call(snd.data.size() == int(HitFeedback.TICK_RATE * HitFeedback.TICK_S) * 2 and HitFeedback.tick_stream() == snd
			and hf.ticks >= 5, "hits: a short tick, made once, plays per confirmation (%d)" % hf.ticks)
	aim.first_person = false


## Several creatures struck by one swing (a technique that strikes around hits the others before the main hit's
## damage comes): each creature the player hit waits for its own damage, anyone else's attack ends the run, and a
## run holds at most HitFeedback.MAX_RUN creatures. `head`, `torso`: body part indices.
func _test_strike_runs(aim: AimController, me: int, head: int, torso: int) -> void:
	var hf := aim.hits
	var got := []
	var strikes := []
	var used := []
	var on_hit := func(uid: int, part: String, amount: int, killed: bool) -> void: got.append([uid, part, amount, killed])
	var on_strike := func(uid: int, part: String, amount: int, killed: bool) -> void: strikes.append([uid, part, amount, killed])
	var on_used := func(uid: int, technique: String, family: int) -> void: used.append([uid, technique, family])
	hf.hit_confirmed.connect(on_hit)
	hf.strike_confirmed.connect(on_strike)
	hf.technique_used.connect(on_used)
	var a := ZUID + 20
	var b := ZUID + 21
	var c := ZUID + 22
	var strike := func(attacker: Variant, target: Variant, hit: Variant) -> Dictionary:
		return {"kind": "attack", "uid": attacker, "other": target, "detail": hit, "pos": Vector3i.ZERO}
	var hurt := func(uid: Variant, amount: Variant, part: Variant, source: Variant) -> Dictionary:
		return {"kind": "damage", "uid": uid, "amount": amount, "detail": part, "other": source, "pos": Vector3i.ZERO}
	var death := func(uid: Variant) -> Dictionary:
		return {"kind": "death", "uid": uid, "pos": Vector3i.ZERO}
	var shot_by := func(shooter: Variant, hit: Variant) -> Dictionary:
		return {"kind": "projectile", "uid": shooter, "other": hit, "pos": Vector3i.ZERO, "path": []}
	var wide: Dictionary = strike.call(me, a, 1)
	wide["text"] = "Wide Strike"
	wide["amount"] = 1
	hf.on_events([wide, strike.call(me, b, 1), hurt.call(b, 4, torso, me), strike.call(me, c, 0), hurt.call(a, 9, head, me)])
	_check.call(got == [[b, "torso", 4, false], [a, "head", 9, false]] and strikes == got and used == [[a, "Wide Strike", 1]],
			"hits: melee: two creatures hit by one swing, a miss on a third between: both confirm, each on its own damage (%s)"
			% [got])
	got.clear()
	strikes.clear()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), hurt.call(b, 4, torso, me), death.call(b),
			{"kind": "message", "text": "The zombie falls."}, hurt.call(a, 9, head, me), death.call(a), death.call(a)])
	_check.call(got == [[b, "torso", 4, false], [b, "torso", 4, true], [a, "head", 9, false], [a, "head", 9, true]]
			and strikes == got,
			"hits: melee: one of the creatures dies in the middle: its kill, the other still confirms (%s)" % [got])
	got.clear()
	strikes.clear()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), hurt.call(b, 4, torso, me), strike.call(ZUID + 4, a, 1),
			hurt.call(a, 9, head, me)])
	var ally := got == [[b, "torso", 4, false]] and strikes == got
	got.clear()
	strikes.clear()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), strike.call(me, c, 2), hurt.call(a, 9, head, me),
			hurt.call(b, 4, torso, me)])
	var malformed := got.is_empty()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), hurt.call(c, 3, torso, me), hurt.call(a, 9, head, me),
			hurt.call(b, 4, torso, me)])
	var elsewhere := got.is_empty()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), death.call(b), hurt.call(a, 9, head, me)])
	var early_death := got.is_empty()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), hurt.call(b, 4, torso, 0), hurt.call(a, 9, head, me)])
	var bleed := got.is_empty()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), {"kind": "turn_end"}, hurt.call(a, 9, head, me)])
	var next_turn := got.is_empty()
	_check.call(ally and malformed and elsewhere and early_death and bleed and next_turn and strikes.is_empty(),
			"hits: melee: someone else's or a malformed attack, damage elsewhere or from no one, a death with no damage, "
			+ "a later turn end the whole run (%s)" % [[ally, malformed, elsewhere, early_death, bleed, next_turn]])
	hf.on_events([strike.call(me, a, 1), strike.call(me, a, 0), hurt.call(a, 5, torso, me), strike.call(me, a, 1), death.call(a)])
	var again := got == [[a, "torso", 5, false]]
	got.clear()
	strikes.clear()
	hf.on_events([strike.call(me, a, 1), strike.call(me, b, 1), hurt.call(b, 4, torso, me), hurt.call(a, 9, head, me),
			shot_by.call(me, a), shot_by.call(me, b)])
	_check.call(again and got.size() == 2 and strikes == got,
			"hits: melee: the player's miss leaves the run alone, a new hit starts that creature again, a run's damage is "
			+ "never a shot's (%s)" % [got])
	# bounds
	var first := ZUID + 100
	var crowd := func(n: int) -> Array:   # the player hits n different creatures
		var ev := []
		for i in n:
			ev.append(strike.call(me, first + i, 1))
		return ev
	got.clear()
	var full: Array = crowd.call(HitFeedback.MAX_RUN)
	full.append(hurt.call(first, 3, torso, me))
	hf.on_events(full)
	var at_bound := got == [[first, "torso", 3, false]]
	got.clear()
	var many: Array = crowd.call(70)
	many.append_array([hurt.call(first + 69, 3, torso, me), hurt.call(first, 3, torso, me), hurt.call(first + 68, 3, torso, me)])
	hf.on_events(many)
	_check.call(at_bound and got == [[first + 69, "torso", 3, false]],
			"hits: melee: a run holds 64 creatures; the 65th hit ends it and starts a new one: of 70 struck the first one's "
			+ "damage isn't confirmed, the last one's is (%s, %s)" % [at_bound, got])
	got.clear()
	var filler: Array = []
	filler.resize(HitFeedback.MAX_EVENTS - 2)
	filler.fill({"kind": "message", "text": "x"})
	var inside: Array = filler + [strike.call(me, a, 1), hurt.call(a, 2, torso, me)]
	var outside: Array = filler + [{"kind": "sound"}, strike.call(me, a, 1), hurt.call(a, 2, torso, me)]
	hf.on_events(inside)
	var in_cap := got == [[a, "torso", 2, false]]
	got.clear()
	hf.on_events(outside)
	_check.call(in_cap and got.is_empty(), "hits: events past the 4096th of a batch are ignored (%s)" % [got])
	aim.crosshair.tick_note(5.0)   # the note of this test's technique
	aim.crosshair.tick_hit(5.0)
	hf.hit_confirmed.disconnect(on_hit)
	hf.strike_confirmed.disconnect(on_strike)
	hf.technique_used.disconnect(on_used)


## A gun model's named parts (later models carry the same names as markers).
func _test_gun_parts() -> void:
	var VM := WeaponViewmodel
	var want := {"pistol": ["Muzzle", "Grip", "MagWell", "Magazine", "Slide"], "long": ["Muzzle", "Grip", "MagWell",
			"Magazine", "Bolt"], "launcher": ["Muzzle", "Grip", "MagWell"]}
	for s: String in want:
		var m := VM.build(s, 0.5)
		var names: Array = want[s]
		var have := names.filter(func(n: String) -> bool: return m.get_node_or_null(NodePath(n)) != null)
		var muzzle := m.get_node_or_null("Muzzle") as Marker3D
		var front := INF
		for n: Node in m.get_children():
			var mi := n as MeshInstance3D
			if mi != null:
				var box := mi.transform * mi.get_aabb()
				front = minf(front, box.position.z)
		var markers_ok := m.get_node_or_null("Grip") is Marker3D and m.get_node_or_null("MagWell") is Marker3D
		var mag := m.get_node_or_null("Magazine")
		var mag_ok := mag == null if s == "launcher" else (mag is MeshInstance3D
				and VM.grime_materials(m).has(((mag as MeshInstance3D).mesh as PrimitiveMesh).material))
		_check.call(have.size() == names.size() and muzzle != null and markers_ok and mag_ok
				and muzzle.position.z <= front + 1e-4 and muzzle.basis.z.is_equal_approx(Vector3.BACK),
				"gun parts: a %s has %s, the muzzle at the front looking down -z (%s, %.3f vs %.3f)"
				% [s, names, have, muzzle.position.z if muzzle != null else NAN, front])
		m.free()
	for s: String in ["bow", "melee", "item"]:
		var m := VM.build(s)
		_check.call(m.get_node_or_null("Muzzle") == null and m.get_children().all(func(n: Node) -> bool: return n is MeshInstance3D),
				"gun parts: a %s has none" % s)
		m.free()


## Muzzle flash: a gun's kick shows a star at its muzzle for FLASH_S and lights it, both at most once every
## FLASH_GAP_S (a burst at any rate never flashes over 3 times a second, and nothing shows between flashes), none
## for a knife or with `flashes` off.
func _test_muzzle_flash(root: Node, tables: IdTables) -> void:
	var VM := WeaponViewmodel
	var rifle := tables.index_of("itype", "remington_870")
	var pistol := tables.index_of("itype", "glock_19")
	var knife := tables.index_of("itype", "knife_combat")
	var vm := WeaponViewmodel.new()
	root.add_child(vm)
	vm.set_item(rifle, tables)
	var under_muzzle := vm._root.get_node_or_null("Muzzle/Flash") != null and not vm.flashing() and not vm.lit()
	vm.kick()
	var on := vm.flashing() and vm.lit()
	vm._process(VM.FLASH_S * 0.5)
	var fading := vm.flashing() and vm._flash.scale.x < 1.0 and vm._flash.scale.x > 0.5
	vm._process(VM.FLASH_S)
	var off := not vm.flashing() and not vm.lit()
	_check.call(rifle > 0 and under_muzzle and on and fading and off,
			"muzzle flash: a shot shows the star and the light at the muzzle, gone after %.2f s" % VM.FLASH_S)
	# bursts of 3 s at 20, 10 and 3.3 shots a second, at 60 frames a second: the star only shows when a flash
	# starts (no re-show, no pulse in between), and no 4 flashes start within one second
	var bursts := []
	var bursts_ok := true
	for period: float in [0.05, 0.1, 0.3]:
		vm._process(1.0)
		var starts: Array[float] = []
		var shows := 0
		var was := vm.flashing()
		var t := 0.0
		var next := 0.0
		while t < 3.0:
			if t >= next:
				vm.kick()
				next += period
				if vm._flash_t == VM.FLASH_S:
					starts.append(t)
			shows += 1 if vm.flashing() and not was else 0
			vm._process(1.0 / 60.0)
			was = vm.flashing()
			t += 1.0 / 60.0
		var spaced := not starts.is_empty()
		for i in starts.size() - 3:
			spaced = spaced and starts[i + 3] - starts[i] > 1.0
		bursts_ok = bursts_ok and spaced and shows == starts.size() and starts.size() <= 9
		bursts.append([period, starts.size(), shows])
	_check.call(bursts_ok, "muzzle flash: bursts at 20, 10 and 3.3 shots a second flash under 3 times a second, "
			+ "nothing between ([period, flashes, shown] %s)" % [bursts])
	vm._process(1.0)
	vm.flashes = false
	vm.kick()
	var dark := not vm.flashing() and not vm.lit()
	vm.flashes = true
	vm._process(1.0)
	vm.kick()
	vm.flashes = false
	vm._process(0.001)
	dark = dark and not vm.flashing() and not vm.lit()
	vm.flashes = true
	vm._process(1.0)
	vm.set_item(pistol, tables)
	var rebuilt := vm._root.get_node_or_null("Muzzle/Flash") != null and not vm.flashing()
	vm.kick()
	var pistol_on := vm.flashing() and vm.lit()
	vm.set_item(knife, tables)
	vm.kick()
	_check.call(dark and rebuilt and pistol_on and not vm.flashing() and vm._flash == null,
			"muzzle flash: none with flashes off (and one showing goes), a new gun gets its own, a knife has none")
	vm.free()


## player.wielded_gun in snapshots: parsed into player_gun, junk fails the snapshot.
func _test_gun_state(d: Dictionary, tables: IdTables) -> void:
	var dd: Dictionary = d.duplicate(true)
	var gi := maxi(tables.index_of("itype", "glock_19"), 1)
	var snap_with := func(g: Variant) -> Snapshot:
		dd["player"]["wielded_gun"] = g
		return Snapshot.from_data(dd)
	var good: Snapshot = snap_with.call({"type": gi, "dirt": 4200, "faults": ["fault_gun_dirt", "fault_gun_blackpowder"], "rounds": 12})
	_check.call(good.is_valid() and good.player_gun == {"type": gi, "dirt": 4200, "rounds": 12,
			"faults": ["fault_gun_dirt", "fault_gun_blackpowder"]} and good.player_gun["faults"] is Array,
			"gun state: a wielded gun's type, dirt, faults and rounds parse (%s %s)" % [good.error, good.player_gun])
	var bare: Snapshot = snap_with.call({"type": gi})
	_check.call(bare.is_valid() and bare.player_gun == {"type": gi, "dirt": -1, "rounds": -1, "faults": []},
			"gun state: no dirt / rounds give -1, no faults none (%s)" % [bare.player_gun])
	dd["player"].erase("wielded_gun")
	var none := Snapshot.from_data(dd)
	var null_gun: Snapshot = snap_with.call(null)
	_check.call(none.is_valid() and none.player_gun == {} and null_gun.is_valid() and null_gun.player_gun == {},
			"gun state: absent gives {}")
	var long_fault := "f".repeat(65)
	var bad := [[], "glock", 5, {"type": -1}, {"type": "x"}, {"type": gi, "dirt": 10001}, {"type": gi, "dirt": -1},
			{"type": gi, "dirt": "4200"}, {"type": gi, "dirt": 4.5}, {"type": gi, "dirt": NAN}, {"type": gi, "rounds": -1},
			{"type": gi, "rounds": 100001}, {"type": gi, "rounds": [1]}, {"type": gi, "faults": "fault_gun_dirt"},
			{"type": gi, "faults": {}}, {"type": gi, "faults": [5]}, {"type": gi, "faults": [long_fault]},
			{"type": gi, "faults": _strings(17)}, {"type": gi, "dirt": null}]
	var passed := []
	for g: Variant in bad:
		var s: Snapshot = snap_with.call(g)
		if s.is_valid():
			passed.append(g)
	var ok16: Snapshot = snap_with.call({"type": gi, "faults": _strings(16)})
	var ok64: Snapshot = snap_with.call({"type": gi, "faults": ["f".repeat(64)]})
	_check.call(passed.is_empty() and ok16.is_valid() and ok64.is_valid(),
			"gun state: non-objects, bad types, out-of-range values, too many or too long faults fail the snapshot (%s)" % [passed])


static func _strings(n: int) -> Array:
	var out := []
	for i in n:
		out.append("fault_%d" % i)
	return out
