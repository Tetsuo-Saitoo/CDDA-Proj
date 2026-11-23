extends RefCounted
## Block C5 interiors, slice 1 (CarInterior, CarDash, VehicleView's interiors): which parts get a wheel, a dash and
## lids (CDDA's controls; lockable, covered containers), lead-vr's anchors and their meta, built only near the camera
## (or for the vehicle the player is in) and dropped far off or when the parts change, lids opening on the client and
## hinged toward the middle, held nodes left alone, the wheel turning with CDDA's steering, a dash alive only for the
## player's vehicle (lit, its needles, numerals and lamps; dark again after), hostile readings checked, the baked
## dashboard in front of the passenger seat, the glovebox's door in it. Run by run_tests.gd.

const CAR := Vector3i(195, 385, 0)
const UID := 78
const OTHER := 79

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	print("vehicle interiors (C5)")
	_test_lids(tables)
	_test_reading()
	_test_view(root, data, tables)
	_test_glovebox(root, data)


## The mock town with two test cars (UID here, OTHER three squares south), facing east: in rows of mount x, (1, 0)
## cargo space, (1, 1) a box; (0, 0) a seat and the controls, (0, 1) a seat; (-1, 0) a trunk, (-1, 1) a sedan trunk;
## (-2, 0) a broken trunk, (-2, 1) a door; a frame under each.
func _data(data: Variant, tables: IdTables, edit := Callable()) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var v := func(id: String) -> int: return tables.index_of("vpart", id)
	var cars := []
	for e: Array in [[UID, CAR], [OTHER, CAR + Vector3i(0, 3, 0)]]:
		var parts := []
		for p: Array in [[1, 0, "cargo_space", 0], [1, 1, "box", 0], [0, 0, "seat", 0], [0, 0, "controls", 0],
				[0, 1, "seat", 0], [-1, 0, "trunk", 0], [-1, 1, "trunk_sedan", 0], [-2, 0, "trunk", Snapshot.VPART_BROKEN],
				[-2, 1, "door", 0]]:
			if not parts.any(func(q: Array) -> bool: return q[0] == p[0] and q[1] == p[1]):
				parts.append([p[0], p[1], v.call("frame"), 255, 0, p[0], p[1], 0])
			parts.append([p[0], p[1], v.call(p[2]), 255, p[3], p[0], p[1], 0])
		var pos: Vector3i = e[1]
		cars.append({"uid": e[0], "name": "Test Car", "pos": [pos.x, pos.y, pos.z], "face_deg": 0.0, "turn_deg": 0.0,
				"velocity": 0.0, "parts": parts})
	d["vehicles"] = cars
	if edit.is_valid():
		edit.call(cars[0])
	return d


func _test_lids(tables: IdTables) -> void:
	var lid := func(id: String) -> bool: return CarInterior.has_lid(tables.def_named("vpart", id))
	var yes := ["trunk", "trunk_sedan", "box", "wood box", "integrated_trashcan"].filter(func(id: String) -> bool: return not lid.call(id))
	var no := ["cargo_space", "seat", "door", "hatch", "trunk_floor", "stowboard", "basketsm", "frame"].filter(func(id: String) -> bool: return lid.call(id))
	_check.call(yes.is_empty() and no.is_empty() and not CarInterior.has_lid(null),
			"interiors: lockable, covered containers get a lid; open cargo, seats, doors, aisles and walls don't (%s; %s)" % [yes, no])


func _test_reading() -> void:
	var r := CarDash.reading_of({"lit": "yes", "top": "x", "step": 0.001, "speed": 1e12, "cruise": -50.0, "safe": NAN,
			"red": INF, "fuel": 7.0, "battery": -3.0, "lamps": 9999, "steer": NAN, "unit": "m\u0007h"})
	var long := CarDash.reading_of({"top": 1e9, "unit": "kilometres an hour", "step": 1.0})
	_check.call(r.lit == false and r.top == 120.0 and r.step == 10.0 and r.speed == 120.0 and r.cruise == 50.0
			and r.safe == 0.0 and r.red == 0.0 and r.fuel == 1.0 and r.battery == -1.0 and r.lamps == 31 and r.steer == 0.0
			and r.unit == CarDash.unit_seen and long.top == CarDash.MAX_TOP and long.step == CarDash.MAX_TOP / CarDash.MAX_TICKS
			and long.unit == CarDash.unit_seen and CarDash.reading_of("junk") == CarDash.reading_of({}),
			"interiors: a dash reading is checked (types, NaN, ranges, ticks, unit text) (%s)" % [r])
	# from the driving HUD's data: backing at 40 mph in km/h, a broken engine, tanks half and full, the battery low,
	# skidding, battered, steering 10 degrees left
	var ride := RideInfo.read({"uid": 5, "velocity": -4000, "cruise_velocity": 5000, "safe_velocity": 6000,
			"max_velocity": 9000, "engine_on": true, "engines": [[1, 4]], "fuels": [[3, 50, 100], [4, 10, 10]],
			"battery": [5, 100], "skidding": true, "turn_deg": 80, "health_pct": 50, "speed_unit": "km/h"}, Callable(), 90.0)
	var d := CarDash.reading_from(ride)
	var top := SpeedGauge.scale_top(ride)
	var want := {"lit": true, "speed": ride.shown(-4000), "cruise": ride.shown(5000), "top": top,
			"step": SpeedGauge.tick_step(top), "safe": ride.shown(6000), "red": ride.shown(9000), "unit": "km/h",
			"fuel": 0.75, "battery": 0.05, "steer": -10,
			"lamps": CarDash.Lamp.ENGINE | CarDash.Lamp.BATTERY | CarDash.Lamp.SKID | CarDash.Lamp.DAMAGE}
	var off := CarDash.reading_from(RideInfo.read({"uid": 5, "engine_on": false, "battery": [0, 100], "cruise_velocity": 5000}))
	var shown := CarDash.reading_of(d)
	_check.call(d == want and not off.lit and off.cruise == 0.0 and off.fuel == -1.0 and off.lamps == CarDash.Lamp.BATTERY
			and shown.lit and is_equal_approx(shown.speed, absf(ride.shown(-4000))) and shown.unit == "km/h"
			and CarDash.reading_from(RideInfo.read(null)).is_empty() and CarDash.reading_from(null).is_empty(),
			"interiors: the dash reads the driving HUD's data (scale and bands as its gauge, lamps, steering) (%s)" % [d])
	CarDash.unit_seen = "mph"


func _test_view(root: Node, data: Variant, tables: IdTables) -> void:
	var snap := Snapshot.from_data(_data(data, tables))
	if not snap.is_valid() or snap.vehicles.size() != 2:
		_check.call(false, "interiors: the test cars load " + snap.error)
		return
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := VehicleView.new()
	root.add_child(view)
	view.apply(snap, world)
	var car := snap.vehicles[0]
	var index := func(id: String, m: Vector2i) -> int:
		for i in car.part_count():
			var j := i * Snapshot.VPART_STRIDE
			if car.parts[j] == m.x and car.parts[j + 1] == m.y and car.parts[j + 2] == tables.index_of("vpart", id):
				return i
		return -1
	var controls: int = index.call("controls", Vector2i(0, 0))
	var trunk: int = index.call("trunk", Vector2i(-1, 0))
	var sedan: int = index.call("trunk_sedan", Vector2i(-1, 1))
	var box: int = index.call("box", Vector2i(1, 1))
	var p := CarInterior.parts_of(car, snap, tables, CddaCoords.Z_LIMIT)
	_check.call(p[0] == controls and p[1] == [[box, VehicleView.Kind.CARGO], [trunk, VehicleView.Kind.CARGO], [sedan, VehicleView.Kind.HALF]],
			"interiors: built from CDDA's controls and its containers with lids (a broken one, cargo space and a door left out) (%s)" % [p])
	# the baked dashboard: the controls' and one in front of the passenger seat beside them
	var dashes := view.instances(VehicleView.Look.SOLID).filter(func(e: Array) -> bool:
		return (e[0] as Transform3D).basis.get_scale().is_equal_approx(Vector3(0.12, 0.45, 1.0)))
	var at := func(m: Vector2i) -> Vector3: return world.coords.ms_center_to_world(CAR + Vector3i(m.x, m.y, 0))
	var near_cell := func(e: Array, m: Vector2i) -> bool:
		var o: Vector3 = (e[0] as Transform3D).origin - (at.call(m) as Vector3)
		return Vector2(o.x, o.z).length() < 0.6
	_check.call(dashes.size() == 4 and dashes.filter(func(e: Array) -> bool: return near_cell.call(e, Vector2i(0, 1))).size() == 1,
			"interiors: a dashboard runs across the front row (the controls' and the passenger seat's, both cars) (%d)" % dashes.size())
	# near the camera only
	var eye: Vector3 = at.call(Vector2i(0, 0)) + Vector3.UP * 1.6
	view.interiors(0.0, eye + Vector3(VehicleView.INTERIOR_NEAR + 15.0, 0, 0))
	var none := view.interior(UID).is_empty() and view.interior(OTHER).is_empty()
	view.interiors(0.0, eye)
	var a := view.interior(UID)
	var names := a.keys()
	names.sort()
	var want := ["Cargo_%d" % box, "Cargo_%d" % sedan, "Cargo_%d" % trunk, "Dash", "Wheel"]
	want.sort()
	_check.call(none and names == want and not view.interior(OTHER).is_empty(),
			"interiors: built for vehicles near the camera only, with lead-vr's anchors (%s)" % [names])
	if names != want:
		view.free()
		world.free()
		return
	var wheel: Node3D = a["Wheel"]
	var spin: Node3D = wheel.get_node("WheelSpin")
	var back := wheel.basis * Vector3.BACK   # the wheel's z, in the car's frame
	_check.call(wheel.get_meta("radius_m") == CarInterior.WHEEL_R and wheel.get_meta("part") == controls
			and spin.get_meta("held") == false and back.x < -0.8 and back.y > 0.3 and a["Dash"] is CarDash
			and wheel.get_parent().get_parent() != null and wheel.get_parent().get_parent().get_parent() == view,
			"interiors: the wheel at the controls faces the driver (its z back and up) in the drawn model (%s)" % back)
	# lids: meta, hinged toward the middle, opening on the client
	var cargo: Node3D = a["Cargo_%d" % trunk]
	var front: Node3D = a["Cargo_%d" % box]
	var lid: Node3D = cargo.get_node("Lid")
	var meta_ok: bool = cargo.get_meta("part") == trunk and cargo.get_meta("square") == car.square(trunk) \
			and cargo.get_meta("open_deg") == CarInterior.LID_OPEN and cargo.get_meta("cdda_open") == false \
			and cargo.get_meta("hinge_axis") == Vector3(0, 0, -1) and lid.get_meta("held") == false \
			and (cargo.get_meta("handle") as Vector3).x < -0.5 and cargo.get_meta("opening_out") == Vector3.UP \
			and cargo.get_meta("opening") == AABB(Vector3(-0.4, VehicleView.DECK, -0.4), Vector3(0.8, CarInterior.LID_TOP - VehicleView.DECK, 0.8))
	_check.call(meta_ok and lid.position.x > 0.3 and (front.get_node("Lid") as Node3D).position.x < -0.3
			and is_equal_approx((a["Cargo_%d" % sedan].get_node("Lid") as Node3D).position.y, CarInterior.LID_TOP + 0.006),
			"interiors: lids hinge on the side toward the middle (a trunk at its front, a box ahead at its back) with lead-vr's meta")
	var handle := func() -> Vector3: return lid.global_transform * (cargo.get_meta("handle") as Vector3)
	var shut: Vector3 = handle.call()
	var opened := view.open_lid(UID, trunk, true) and not view.open_lid(UID, controls, true) and not view.open_lid(OTHER + 5, trunk, true)
	for i in 60:
		view.interiors(0.05, eye)
	var it: CarInterior = wheel.get_parent()
	var up: Vector3 = handle.call()
	_check.call(opened and is_equal_approx(it.lid_deg(trunk), CarInterior.LID_OPEN) and up.y > shut.y + 0.5 and not it.moving,
			"interiors: a lid opens on the client and settles (%.1f degrees, its handle %.2f m up)" % [it.lid_deg(trunk), up.y - shut.y])
	lid.set_meta("held", true)
	view.open_lid(UID, trunk, false)
	for i in 10:
		view.interiors(0.05, eye)
	var held := is_equal_approx(it.lid_deg(trunk), CarInterior.LID_OPEN)
	lid.set_meta("held", false)
	view.open_lid(UID, trunk, false)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(held and absf(it.lid_deg(trunk)) < 0.1, "interiors: a held lid isn't moved; let go, it closes")
	# a hand moves it and lets go: it stays there while the car's dash and wheel move; open_lid still moves it
	lid.set_meta("held", true)
	lid.basis = Basis(cargo.get_meta("hinge_axis"), deg_to_rad(30.0))
	lid.set_meta("held", false)
	view.set_ride(UID, {"lit": true, "steer": 10})
	for i in 60:
		view.interiors(0.05, eye)
	var left_at := it.lid_deg(trunk)
	view.set_ride(0, {})
	view.open_lid(UID, trunk, false)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(absf(left_at - 30.0) < 0.1 and absf(it.lid_deg(trunk)) < 0.1,
			"interiors: a lid a hand let go of stays there (%.1f degrees) until it is opened or closed" % left_at)
	# the client's rule: hands reach into a lidded container only while its lid is open
	var seat: int = index.call("seat", Vector2i(0, 1))
	var frame: int = index.call("frame", Vector2i(-1, 0))   # on the trunk's square, under its lid
	var shut_reach := not view.can_reach(UID, trunk) and not view.can_reach(UID, frame) and view.can_reach(UID, seat) \
			and not view.can_reach(UID, 9999) and not view.can_reach(OTHER + 5, seat)
	view.open_lid(UID, frame, true)   # the lid over its square
	var half_open := false
	for i in 60:
		view.interiors(0.05, eye)
		half_open = half_open or (it.lid_deg(trunk) > 5.0 and it.lid_deg(trunk) < CarInterior.LID_REACH - 1.0 and not view.can_reach(UID, trunk))
	var open_reach := view.can_reach(UID, trunk) and view.can_reach(UID, frame)
	view.open_lid(UID, trunk, false)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(shut_reach and half_open and open_reach and not view.can_reach(UID, trunk)
			and CarInterior.lid_over(car, snap, tables, CddaCoords.Z_LIMIT, frame) == trunk
			and CarInterior.lid_over(car, snap, tables, CddaCoords.Z_LIMIT, seat) == -1,
			"interiors: hands reach into a lidded container only while its lid is open %d degrees or more; elsewhere always" % CarInterior.LID_REACH)
	# the player's car comes alive; the other stays dark
	var dash: CarDash = a["Dash"]
	var other: CarDash = view.interior(OTHER)["Dash"]
	var reading := {"lit": true, "speed": 60.0, "cruise": 45.0, "top": 120.0, "step": 20.0, "safe": 50.0, "red": 90.0,
			"unit": "km/h", "fuel": 0.5, "battery": 0.08, "lamps": CarDash.Lamp.BATTERY | CarDash.Lamp.SKID, "steer": -15.0}
	view.set_ride(UID, reading)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(dash.lit and is_equal_approx(dash.value("speed"), 0.5) and is_equal_approx(dash.value("cruise"), 0.375)
			and is_equal_approx(dash.value("fuel"), 0.5) and is_equal_approx(dash.value("battery"), 0.08)
			and dash.faces.get_instance_shader_parameter("glow") == 1.0
			and dash.lamps_lit() == CarDash.Lamp.BATTERY | CarDash.Lamp.SKID
			and Array(dash.numerals()).slice(0, 8) == ["0", "20", "40", "60", "80", "100", "120", "km/h"]
			and not other.lit and other.value("speed") == 0.0 and other.faces.get_instance_shader_parameter("glow") == 0.0
			and not (other.get_parent() as CarInterior).moving and not it.moving,
			"interiors: the player's dash is lit, its needles turn to the reading and settle; another car's stays dark (%s)" % [dash.numerals()])
	_check.call(is_equal_approx(it.wheel_deg(), 90.0) and is_equal_approx(spin.rotation.z, deg_to_rad(90.0)),
			"interiors: the wheel turns with CDDA's steering (15 degrees left: %.0f degrees, to the left)" % it.wheel_deg())
	spin.set_meta("held", true)
	reading.steer = 10.0
	view.set_ride(UID, reading)
	for i in 30:
		view.interiors(0.05, eye)
	var kept := is_equal_approx(it.wheel_deg(), 90.0)
	spin.set_meta("held", false)
	reading.lit = false
	view.set_ride(UID, reading)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(kept and is_equal_approx(it.wheel_deg(), -60.0) and not dash.lit and dash.value("speed") == 0.0
			and dash.value("fuel") == 0.0 and dash.lamps_lit() == 0 and dash.faces.get_instance_shader_parameter("glow") == 0.0,
			"interiors: a held wheel isn't turned; with no power every needle rests at zero and the lamps go out")
	reading.lit = true
	view.set_ride(UID, reading)
	view.set_ride(0, {})
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(not dash.lit and dash.value("speed") == 0.0 and is_equal_approx(it.wheel_deg(), 0.0),
			"interiors: when the player leaves, the dash goes dark and the wheel straight")
	# far off: dropped (the player's car kept); parts changed: built again; dropped with the model
	var dash_mesh: Mesh = dash.cluster.mesh   # freed with the interior just below
	view.set_ride(OTHER, {"lit": true})
	view.interiors(0.0, eye + Vector3(VehicleView.INTERIOR_FAR + 15.0, 0, 0))
	var dropped := view.interior(UID).is_empty() and not view.interior(OTHER).is_empty()
	var other_dash: CarDash = view.interior(OTHER).get("Dash")
	var shared := other_dash != null and other_dash.cluster.mesh == dash_mesh   # one cluster mesh for all
	view.set_ride(0, {})
	view.interiors(0.0, eye)
	var it2: CarInterior = (view.interior(UID)["Wheel"] as Node3D).get_parent()
	car.parts[box * Snapshot.VPART_STRIDE + 3] = 100   # worn: the same interior
	view.apply(snap, world)
	var same: bool = (view.interior(UID)["Wheel"] as Node3D).get_parent() == it2 and it2.seen[0] == car.parts   # checked once
	car.parts[box * Snapshot.VPART_STRIDE + 2] = tables.index_of("vpart", "cargo_space")   # no lid there now
	view.apply(snap, world)
	var gone := view.interior(UID).is_empty()
	var far_rule := gone and not view.can_reach(UID, trunk) and view.can_reach(UID, seat)   # no interior: lids shut
	view.interiors(0.0, eye)
	var again := view.interior(UID)
	_check.call(dropped and shared and same and gone and far_rule and again.has("Wheel") and not again.has("Cargo_%d" % box),
			"interiors: dropped far from the camera (not the player's), kept while parts only wear, built again when they change; one cluster mesh for every dash")
	view.max_verts = 0
	view.apply(snap, world)
	_check.call(view.interior(UID).is_empty(), "interiors: gone with the vehicle's model")
	CarDash.unit_seen = "mph"
	view.free()
	world.free()


## The glovebox (lead-bridge's fp3d_glovebox; the mock tables get it here): the box ahead of the passenger seat
## becomes one, a second at (2, 0) has no dashboard behind it. Its door in the dashboard in front of the seat with
## lead-vr's meta, opening on the client, the hands' rule, a look from the seat at the door giving its square.
func _test_glovebox(root: Node, data: Variant) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			ProjectSettings.globalize_path("res://").path_join("../contracts/mock/id_tables.json").simplify_path()))
	if not raw is Dictionary or not (raw as Dictionary).get("vpart") is Array:
		_check.call(false, "interiors: the mock id tables load for the glovebox")
		return
	(raw["vpart"] as Array).append({"id": CarInterior.GLOVEBOX, "name": "glovebox", "color": "c_light_gray",
			"flags": ["CARGO", "COVERED"]})
	var tables := IdTables.from_data(raw)
	var glove_id := tables.index_of("vpart", CarInterior.GLOVEBOX)
	var snap := Snapshot.from_data(_data(data, tables, func(car: Dictionary) -> void:
		for p: Array in car["parts"]:
			if p[0] == 1 and p[1] == 1 and p[2] == tables.index_of("vpart", "box"):
				p[2] = glove_id
		car["parts"].append([2, 0, tables.index_of("vpart", "frame"), 255, 0, 2, 0, 0])
		car["parts"].append([2, 0, glove_id, 255, 0, 2, 0, 0])))
	if glove_id < 0 or not snap.is_valid():
		_check.call(false, "interiors: the glovebox car loads " + snap.error)
		return
	var car := snap.vehicles[0]
	var find := func(m: Vector2i) -> int:
		for i in car.part_count():
			var j := i * Snapshot.VPART_STRIDE
			if car.parts[j] == m.x and car.parts[j + 1] == m.y and car.parts[j + 2] == glove_id:
				return i
		return -1
	var glove: int = find.call(Vector2i(1, 1))
	var bare: int = find.call(Vector2i(2, 0))
	var doors := CarInterior.glove_doors(car, snap, tables, CddaCoords.Z_LIMIT)
	var in_dash := (CarInterior.parts_of(car, snap, tables, CddaCoords.Z_LIMIT)[1] as Array).filter(func(e: Array) -> bool:
		return e[1] == VehicleView.Kind.DASH)
	_check.call(glove >= 0 and bare >= 0 and doors == [[glove, Vector2i(1, 1)]] and in_dash == [[glove, VehicleView.Kind.DASH]],
			"interiors: a glovebox gets a door where a dashboard is behind its square, not elsewhere (%s)" % [doors])
	var world := WorldView.new()
	world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	world.set_id_tables(tables)
	root.add_child(world)
	world.apply_snapshot(snap)
	var view := VehicleView.new()
	root.add_child(view)
	view.apply(snap, world)
	var eye: Vector3 = world.coords.ms_center_to_world(CAR + Vector3i(0, 1, 0)) + Vector3.UP * 1.5   # the passenger's
	view.interiors(0.0, eye)
	var a := view.interior(UID)
	var c: Node3D = a.get("Cargo_%d" % glove)
	if c == null:
		_check.call(false, "interiors: the glovebox's door is built (%s)" % [a.keys()])
		view.free()
		world.free()
		return
	var lid: Node3D = c.get_node("Lid")
	var it: CarInterior = c.get_parent()
	var meta_ok: bool = c.get_meta("part") == glove and c.get_meta("square") == car.square(glove) \
			and c.get_meta("hinge_axis") == Vector3(0, 0, 1) and c.get_meta("open_deg") == CarInterior.GLOVE_OPEN \
			and c.get_meta("cdda_open") == false and lid.get_meta("held") == false and not a.has("Cargo_%d" % bare)
	# the space behind the door, inside the dashboard, open toward the seat
	var op: AABB = c.get_meta("opening", AABB())
	meta_ok = meta_ok and c.get_meta("opening_out") == Vector3(-1, 0, 0) and op.position.x == 0.0 and op.size.x > 0.1 \
			and CarInterior.glove_box(Vector2i(1, 1)).grow(0.001).encloses(AABB(op.position + c.position, op.size))
	_check.call(meta_ok and c.position.is_equal_approx(Vector3(CarInterior.DASH_FACE, 0.0, 1.0))
			and is_equal_approx(lid.position.y, CarInterior.GLOVE_Y),
			"interiors: the glovebox's door is on the dashboard's face in front of the passenger seat, with lead-vr's meta (%s)" % c.position)
	# opens on the client: the handle comes down and toward the seat; hands reach in only while it is open
	var handle := func() -> Vector3: return it.to_local(lid.global_transform * (c.get_meta("handle") as Vector3))
	var shut: Vector3 = handle.call()
	var reach_shut := not view.can_reach(UID, glove) and view.can_reach(UID, bare) and not view.open_lid(UID, bare, true)
	var opened := view.open_lid(UID, glove, true)
	for i in 60:
		view.interiors(0.05, eye)
	var down: Vector3 = handle.call()
	var reach_open := view.can_reach(UID, glove)
	view.open_lid(UID, glove, false)
	for i in 60:
		view.interiors(0.05, eye)
	_check.call(reach_shut and opened and reach_open and absf(it.lid_deg(glove)) < 0.1
			and not view.can_reach(UID, glove) and down.y < shut.y - 0.1 and down.x < shut.x - 0.1,
			"interiors: the glovebox opens on the client, its door down toward the seat; hands reach in only then (%s to %s)" % [shut, down])
	# a look from the seat at the door meets the glovebox and gives its square; one over the dash doesn't
	var ray := LookRay.new(world)
	var door := VehicleView.frame_of(car, world.coords) * CarInterior.glove_box(Vector2i(1, 1)).get_center()
	var hit := ray.cast(eye, door - eye)
	var over := ray.cast(eye, Vector3(door.x, eye.y, door.z) - eye)
	_check.call(hit.get("hit", false) and hit.get("square") == car.square(glove) and hit.get("vehicle") == UID
			and hit.get("part") == glove and str(hit.get("what")).ends_with("glovebox")
			and (hit.get("point", Vector3.INF) as Vector3).distance_to(door) < 0.2 and over.get("part", -1) != glove
			and LookRay.box_t(AABB(Vector3.ZERO, Vector3.ONE), Vector3(-1, 0.5, 0.5), Vector3.RIGHT, 0.5) == -1.0,
			"interiors: a look from the seat at the glovebox's door meets it, its square the glovebox's (%s)" % [hit])
	view.free()
	world.free()
