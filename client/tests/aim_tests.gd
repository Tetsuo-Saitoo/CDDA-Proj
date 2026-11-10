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

	_test_bullets(root, world, tables, me, zp, ui, aim, cam, req)
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

	# an older bridge (no dispersion): FIRE draws its own tracer
	aim.on_request(req)
	ui.show_request(req)
	tracers = aim._tracers
	aim.on_fire(cam, Vector2.ZERO, true)
	_check.call(aim.dispersion == 0.0 and aim._tracers == tracers + 1, "shots: without dispersion FIRE draws its tracer as before")
	ui.clear()


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
	zdef.weakpoints = old_wp
	aim.wielded_gun = Callable()
	aim.creature_view = null
	cv.free()
