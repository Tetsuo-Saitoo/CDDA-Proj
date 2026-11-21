extends SceneTree
## Headless smoke run of the test range through the client's own UI path: main in live mode shows the main menu,
## its "Test range" button starts the range (cheats allowed, the F1 Cheats page forced on), the Cheats page's
## range controls show the zones, and each control (heal, freeze, set time, wait an hour, spawn an item at the
## feet and a monster ahead, go to a zone) comes back done from the game and shows in the client's world. Before
## those, stairs through the client: up and back down in the hub, each snapshot around the new level and no submap's
## revisions running backwards. After each move that changes the map (over a submap border, a level up or down,
## another zone) the delta snapshots are compared with the plain snapshot (_deltas_ok), and on the hub's level the
## vehicles must be drawn on their squares (_vehicles_ok). Uses this run's own CDDA folder, never the player's saves.
## Needs the DLL (build target fp3d-cdda) and the game data (../cdda, or --cdda=<folder>). ~3 min. From the repo
## root:
##   godot --headless --path client --script res://tests/range_ui_live_test.gd -- --live
## Exit code 0 = all passed.

const Main := preload("res://scripts/main.gd")
const TestDir := preload("res://tests/test_dir.gd")
const SnapSame := preload("res://tests/snapshot_same.gd")
const BOOT_TIMEOUT_MS := 300000
const OP_TIMEOUT_MS := 90000
const SHOW_TIMEOUT_MS := 20000   # an op's effect reaching the client's world after the game says done
const HOUR_TURNS := 3600         # CDDA turns are seconds
const ITEM := "glock_19"
const MONSTER := "mon_zombie"

var _failed := 0
var _main: Main
var _live: LiveSession
var _cp: CheatPanel
var _done := {}       # op id -> error ("" = done), from LiveSession.range_done
var _answered := 0    # the last prompt this script answered
var _held: Snapshot   # the snapshot this script holds for the delta call, beside LiveSession's own (_deltas_ok)
var _deltas_off := false
var _full_after := {"shift": 0, "level": 0}   # full answers _deltas_ok read after a map shift, on another level
var _veh_off := false
var _veh_seen := []   # per _vehicles_ok that had vehicles to compare: how many points it compared
var _drive_keys := false   # _send: driving actions go as step keys through main's input path (lead-world's driving keys)
var _msg_changes := 0      # changes of the HUD's message feed since _watch_messages
var _msg_watched := false
## CDDA's driving actions and the step keys that send them while driving, whichever way the camera faces.
const DRIVE_STEP := {"UP": &"step_forward", "DOWN": &"step_back", "LEFT": &"step_left", "RIGHT": &"step_right"}


func _initialize() -> void:
	_run()


func _run() -> void:
	if not "--live" in OS.get_cmdline_user_args():
		_check(false, "run with -- --live (main takes its mode from the command line)")
		_finish()
		return
	_check(LiveSession.test_range_available(), "the bridge has the test range")
	if _failed > 0:
		_finish()
		return
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	_main.cdda_user_dir = TestDir.global("cdda-range")
	root.add_child(_main)
	await process_frame
	_live = _main.live
	_cp = _main.cheat_panel
	_live.range_done.connect(func(id: int, err: String) -> void: _done[id] = err)
	var menu := _main.main_menu
	var button := _find_button(menu, "Test range") if menu != null else null
	_check(menu != null and menu.test_range and button != null, "the main menu shows the Test range button")
	if button == null:
		_finish()
		return
	button.pressed.emit()
	_check(_main.main_menu == null and _live.cheats_allowed and _main.key_menu.cheats_allowed(),
			"the button starts the range with cheats allowed (%s)" % _live.error)
	var t0 := Time.get_ticks_msec()
	var shown := func() -> bool: return (_live.state == "running" and _main.world.snapshot != null
			and _cp.range_box.visible and _cp.tables != null)
	var up := await _until(shown, BOOT_TIMEOUT_MS)
	_check(up, "the range runs and the Cheats page shows its controls (%.0f s, state %s %s)"
			% [(Time.get_ticks_msec() - t0) / 1000.0, _live.state, _live.error])
	if not up:
		_finish()
		return
	var info := _live.range_info()
	var zones: Array = info.get("zones", [])
	_check(_live.in_range() and zones.size() > 1 and _cp.zone_pick.item_count == zones.size()
			and _cp.zone_pick.selected == info.get("zone", -1) and info.get("zone", -1) == 0,
			"zones listed, the hub picked (%d zones, at %d)" % [zones.size(), info.get("zone", -1)])
	_check(info.get("ai_frozen", false) and _cp.freeze.button_pressed, "monsters start frozen, and the switch says so")
	await _stairs_live()

	_check(await _op(_cp.heal, "Heal") == "", "Heal: done")
	var thawed := func() -> bool: return not _live.range_info().get("ai_frozen", true)
	var frozen := func() -> bool: return _live.range_info().get("ai_frozen", false) and _cp.freeze.button_pressed
	_cp.freeze.button_pressed = false   # as a click: toggled -> set_frozen
	var off := await _last_op("Monsters moving")
	_check(off == "" and await _until(thawed, OP_TIMEOUT_MS), "freeze switch off: monsters move (%s)" % off)
	_cp.freeze.button_pressed = true
	var on := await _last_op("Monsters frozen")
	_check(on == "" and await _until(frozen, OP_TIMEOUT_MS), "freeze switch on: frozen again (%s)" % on)
	var boot_turn := _main.world.snapshot.turn
	_cp.hour.value = 22
	var timed := await _op(_cp.set_time, "Time 22:00")
	var jumped := func() -> bool: return _main.world.snapshot.turn >= boot_turn + 11 * HOUR_TURNS
	var shown_time := await _until(jumped, SHOW_TIMEOUT_MS)
	_check(timed == "" and shown_time, "Set time 22:00 (from 10:00): done, the world shows it (turn %d -> %d, %s)"
			% [boot_turn, _main.world.snapshot.turn, timed])
	# before the monster: a hostile in view cuts a wait short
	var turn := _main.world.snapshot.turn
	var waited := await _op(_cp.wait_hour, "Wait 1 hour")
	var hour_on := func() -> bool: return _main.world.snapshot.turn >= turn + HOUR_TURNS - 60
	var later := await _until(hour_on, OP_TIMEOUT_MS)
	_check(waited == "" and later, "Wait 1 hour: done, an hour went by (turn %d -> %d, %s)"
			% [turn, _main.world.snapshot.turn, waited])
	var here := _main.world.snapshot.player_pos
	var t := _cp.tables.index_of("itype", ITEM)
	_cp.item_id.text = ITEM
	_cp.item_count.value = 2
	var spawned := await _op(_cp.spawn_item, "Spawn " + ITEM)
	var on_floor := func() -> bool: return _ground_count(t, here) >= 2
	var listed := await _until(on_floor, SHOW_TIMEOUT_MS)
	_check(spawned == "" and listed, "Spawn 2 %s at the feet: done, the Tab list shows %d there (%s)"
			% [ITEM, _ground_count(t, here), spawned])
	var ahead: Variant = _cp.ahead_square.call()
	_cp.monster_id.text = MONSTER
	var mon := await _op(_cp.spawn_monster, "Spawn " + MONSTER)
	var seen := func() -> bool: return ahead is Vector3i and _main.world.snapshot.creature_at(ahead) != null
	var stands := await _until(seen, SHOW_TIMEOUT_MS)
	_check(mon == "" and stands, "Spawn %s ahead: done, it stands at %s (%s)" % [MONSTER, ahead, mon])
	var pos := _main.world.snapshot.player_pos
	_cp.zone_pick.select(1)
	var went := await _op(_cp.go_zone, "Go to")
	var arrived := func() -> bool: return (_live.range_info().get("zone", -1) == 1
			and _main.world.snapshot.player_pos != pos)
	var moved := await _until(arrived, OP_TIMEOUT_MS)
	var zone_name: String = zones[1].get("name", "?")
	_check(went == "" and moved and _cp.zone_pick.selected == 1,
			"Go to %s: done, the player moved (%s -> %s)" % [zone_name, pos, _main.world.snapshot.player_pos])
	var built := func() -> bool: return _cp.zone_pick.get_item_text(1) == zone_name
	_check(await _until(built, SHOW_TIMEOUT_MS) and _cp.status.text == "Go to %s: done." % zone_name,
			"the zone reads built and the status line names it (%s / %s)" % [_cp.zone_pick.get_item_text(1), _cp.status.text])
	await _deltas_ok("in another zone")
	_deltas_done()
	_vehicles_done()
	await _stop()
	_finish()


## Stairs through the client, in the hub: the teleport cheat next to the stairs up, then main.use_stair up and back
## down. After each change of level the snapshot is around the new level (every level the client asks for, whole)
## and no submap's revisions run backwards, the level left out meanwhile included. Then back to the arrival square.
## After each of these moves the delta snapshots are checked too (_deltas_ok).
func _stairs_live() -> void:
	var start := _main.world.snapshot.player_pos
	await _deltas_ok("on arrival")
	_vehicles_ok("on arrival")
	await _border_live(start)
	var st := _stair_near(start)
	var z0 := st.z
	var next := func() -> bool:
		var p := _main.world.snapshot.player_pos
		return p.z == z0 and maxi(absi(p.x - st.x), absi(p.y - st.y)) <= 1 and not _main.world.busy() \
				and StairUse.find(_main.world, st, z0).get("dz", 0) == 1
	var near := false
	for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(0, -1, 0)]:
		if await _cheat(_live.cheat_teleport(st + d)) == "" and await _until(next, SHOW_TIMEOUT_MS):
			near = true
			break
	_check(near, "the teleport cheat puts the player next to the hub's stairs up at %s (player %s)"
			% [st, _main.world.snapshot.player_pos])
	if not near:
		return
	var seen := {}   # submap -> Vector2i(revision, detail revision), the highest seen
	_levels_ok("by the stairs", seen)
	await _deltas_ok("by the stairs")
	_vehicles_ok("by the stairs")
	var is_up := await _take_stair(st, z0, 1)
	_check(is_up, "use_stair up: the player is on level %d (%s, \"%s\")" % [z0 + 1, _main.world.snapshot.player_pos, _main.status])
	_levels_ok("upstairs", seen)
	await _deltas_ok("upstairs")
	var is_down := is_up and await _take_stair(Vector3i(st.x, st.y, z0 + 1), z0 + 1, -1)
	_check(is_down, "use_stair down again: the player is on level %d (%s, \"%s\")" % [z0, _main.world.snapshot.player_pos, _main.status])
	_levels_ok("back down", seen)
	await _deltas_ok("back down")
	var back := func() -> bool: return _main.world.snapshot.player_pos == start and not _main.world.busy()
	_check(await _cheat(_live.cheat_teleport(start)) == "" and await _until(back, SHOW_TIMEOUT_MS),
			"teleported back to the arrival square (%s)" % _main.world.snapshot.player_pos)
	await _deltas_ok("back at the arrival square")
	await _spawn_vehicle_live(start)
	await _drive_live(start)
	await _bike_live(start)
	await _rain_far_live()


## The range's vehicle spawn through the client (the bridge's range_spawn_vehicle; skipped, said so, on a bridge
## without it): a car facing 45 degrees, then one facing 30 (between the axes, where CDDA's line steps), each on
## the next of a few squares round the arrival square `start` where the game takes it. The snapshot then lists one
## vehicle more with that facing, it is drawn on its squares (_vehicles_ok), and every cell of its drawn grid lies
## within 0.75 m of the square CDDA has it on. On the player's own square, or with an id that is no prototype, the
## game refuses in its words; a facing of 360 or an overlong id isn't sent.
func _spawn_vehicle_live(start: Vector3i) -> void:
	if not _live.sim().has_method("range_spawn_vehicle"):
		print("  (no vehicle spawn in this bridge: not checked)")
		return
	var spots: Array[Vector3i] = [Vector3i(14, 14, 0), Vector3i(14, -14, 0), Vector3i(-14, -14, 0), Vector3i(-18, 18, 0),
			Vector3i(22, 0, 0), Vector3i(0, 22, 0), Vector3i(30, 30, 0), Vector3i(-30, 30, 0), Vector3i(30, -30, 0),
			Vector3i(0, -22, 0), Vector3i(-22, 0, 0)]
	for facing: int in [45, 30]:
		var before := {}
		for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
			before[veh.uid] = true
		var tried := []
		var placed := false
		while not placed and not spots.is_empty():
			var d: Vector3i = spots.pop_front()
			var why := await _cheat(_spawn_vehicle("car", start + d, facing))
			tried.append([d, why])
			placed = why == ""
		var fresh := func() -> Snapshot.Vehicle:
			for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
				if not before.has(veh.uid):
					return veh
			return null
		var listed := func() -> bool: return fresh.call() != null and not _main.world.busy()
		var seen := placed and await _until(listed, SHOW_TIMEOUT_MS)
		var car: Snapshot.Vehicle = fresh.call()
		_check(seen and car != null and is_equal_approx(car.face_deg, float(facing)) and car.part_count() > 20,
				"vehicle spawn: a car facing %d degrees is placed and the snapshot lists it (%s parts, facing %s; tried %s)"
				% [facing, car.part_count() if car != null else 0, car.face_deg if car != null else "?", tried])
		if seen:
			_vehicles_ok("a car spawned facing %d degrees" % facing)
			_cells_ok("vehicle spawn: facing %d degrees" % facing, car)
	var on_me := await _cheat(_spawn_vehicle("car", _main.world.snapshot.player_pos, 0))
	var unknown := await _cheat(_spawn_vehicle("car_nope", start + Vector3i(0, 30, 0), 0))
	_check(on_me.contains("in the way") and unknown == "No such vehicle.",
			"vehicle spawn: refused in the game's words on the player's square (\"%s\") and for an id that is no prototype (\"%s\")"
			% [on_me, unknown])
	_check(_spawn_vehicle("car", start + Vector3i(0, 30, 0), 360) == 0
			and _spawn_vehicle("a".repeat(65), start + Vector3i(0, 30, 0), 0) == 0,
			"vehicle spawn: a facing of 360 or an overlong id isn't sent")


## Driving through the client (the bridge's control_vehicle and vehicle spawn, VehicleView with a node per vehicle;
## skipped, said so, without any of them). A car facing east is spawned on a stretch of open hub floor, the player
## walks in through the door next to its controls and takes them (control_vehicle), sets a speed (UP) and lets
## turns pass. Each turn the car rolled, with the view's own gliding switched off: the node is still where it was
## drawn, a part of the glide brings it nearer the snapshot's pose, the camera's ride transform isn't the identity
## meanwhile, and the whole glide ends on the pose with the ride the identity again (_drive_turn). The player stays
## on the car. Where the floor leaves room, LEFT twice steers it off the axis: the node's turn must glide too, and
## the car must lie on CDDA's squares at that angle; RIGHT twice steers it back. Then the car is stopped, the
## controls let go, and the player walks out and goes back to `start`. On a client with lead-world's driving keys
## the controls are taken with CDDA's control key and the car is driven by the step keys with the camera turned off
## its heading (they must still be CDDA's driving keys); then, on the seat beside the driver's, the key takes
## nothing and the feed says there are no controls.
func _drive_live(start: Vector3i) -> void:
	var vv: VehicleView = _main.vehicles_view
	var asking := func() -> bool: return _live.request.get("timed", false)   # the main loop's request lists its actions
	await _until(asking, SHOW_TIMEOUT_MS)
	if not _live.sim().has_method("range_spawn_vehicle") or not vv.has_method("drawn") \
			or not "control_vehicle" in (_live.request.get("actions", []) as Array):
		print("  (no vehicle spawn or no control_vehicle in this bridge, or no node per vehicle in this client: driving not checked)")
		return
	# a lane of open floor east of the car: with room to steer left (north) if the hub has it, else straight only
	var before := {}
	for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
		before[veh.uid] = true
	var feet := _floor_at(start)
	var wide := true
	var lanes := _lanes(start, feet, 38, 9)
	if lanes.is_empty():
		wide = false
		lanes = _lanes(start, feet, 24, 3)
	var at := Vector3i.ZERO
	var placed := false
	for c: Vector3i in lanes.slice(0, 6):
		if not placed and await _cheat(_spawn_vehicle("car", c, 0)) == "":
			placed = true
			at = c
	var car_of := func() -> Snapshot.Vehicle:
		for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
			if not before.has(veh.uid):
				return veh
		return null
	var listed := func() -> bool: return car_of.call() != null and not _main.world.busy()
	var seen := placed and await _until(listed, SHOW_TIMEOUT_MS)
	_check(seen, "driving: a car facing east stands on open floor at %s (room to steer: %s)" % [at, wide])
	if not seen:
		return
	var car: Snapshot.Vehicle = car_of.call()
	var uid := car.uid
	# the controls' square, the door beside it, and the floor outside that door
	var seat := Vector3i.MAX
	var doors := {}
	for i in car.part_count():
		var k := i * Snapshot.VPART_STRIDE
		var kind := VehicleView.kind_of(VehicleView.def_of(_main.world.tables, _main.world.snapshot, car.parts[k + 2]),
				car.parts[k + 4])
		if kind == VehicleView.Kind.CONTROLS:
			seat = car.square(i)
		elif kind in [VehicleView.Kind.DOOR, VehicleView.Kind.GLASS_DOOR, VehicleView.Kind.DOOR_OPEN]:
			doors[car.square(i)] = true   # CDDA leaves some doors of a new car open
	var door := Vector3i.MAX
	var out := Vector3i.MAX
	for d: Vector3i in [Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0)]:
		if seat != Vector3i.MAX and door == Vector3i.MAX and doors.has(seat + d) and _floor_at(seat + d * 2) == feet \
				and _main.world.snapshot.vehicle_at(seat + d * 2).is_empty():
			door = seat + d
			out = seat + d * 2
	var by_door := func() -> bool: return _main.world.snapshot.player_pos == out and not _main.world.busy()
	var there: bool = door != Vector3i.MAX and await _cheat(_live.cheat_teleport(out)) == "" \
			and await _until(by_door, SHOW_TIMEOUT_MS)
	_check(there, "driving: the player stands outside the door next to the car's controls (controls %s, door %s, player %s; doors from the controls: %s; floor %d, two squares out: %s)"
			% [seat, door, _main.world.snapshot.player_pos, doors.keys().map(func(k: Vector3i) -> Vector3i: return k - seat),
			feet, [Vector3i(0, -2, 0), Vector3i(0, 2, 0), Vector3i(-2, 0, 0), Vector3i(2, 0, 0)].map(
			func(d: Vector3i) -> int: return _floor_at(seat + d))])
	if not there:
		return
	var step_in := _step_name(door - out)
	var seated := func() -> bool: return _main.world.snapshot.player_pos == seat and not _main.world.busy()
	for n in 6:   # the door opens, then two steps
		if seated.call():
			break
		await _turn(step_in)
	_check(seated.call(), "driving: walking in through the door (%s) puts the player on the controls' square (%s)"
			% [step_in, _main.world.snapshot.player_pos])
	if not seated.call():
		return
	# lead-world's driving keys (a client with them): CDDA's control key, and the step keys as CDDA's driving keys
	var keys: bool = InputMap.has_action(&"cdda_control_vehicle") and _main.has_method("_step_octant")
	if keys:
		root.push_input(_key_of(&"cdda_control_vehicle"))
	else:
		_live.queue_action("control_vehicle")
	var driving := func() -> bool: return _player_field("driving") == true
	var took := await _until_slow(driving, OP_TIMEOUT_MS)
	_check(took and _player_field("vehicle") == uid, "driving: %s takes the controls: the snapshot says driving, on that vehicle (%s)"
			% [InputActions.prompt_of(&"cdda_control_vehicle") if keys else "control_vehicle", _player_field("vehicle")])
	if not took:
		return
	var yaw0: float = _main.fp.yaw
	var pitch0: float = _main.fp.pitch
	var cam_way := ""   # what the forward step key would be by the camera alone
	if keys:
		var known := func() -> bool: return _main.world.snapshot.get("player_driving") == true
		await _until(known, SHOW_TIMEOUT_MS)
		_drive_keys = true
		for yaw: float in [PI / 2.0, PI, -PI / 2.0]:   # the camera turned off the car's heading
			if _main._fp_active() and (cam_way.is_empty() or cam_way == "UP"):
				_main.fp.set_look(yaw, 0.0)
				cam_way = _main.OCT_ACTIONS[_main._octant(Vector2(0, 1))]
		_check(_main.world.snapshot.get("player_driving") == true and not cam_way.is_empty() and cam_way != "UP",
				"driving: the client's snapshot says driving, and the camera is turned off the car's heading (by the camera alone the forward key would send %s)"
				% [cam_way if not cam_way.is_empty() else "nothing: not in first person"])
	vv.set_process(false)   # its glide by hand from here on
	for n in 2:
		_send("UP")
	var rolled := 0
	var bad := []
	for n in 6:
		var r := await _drive_turn("pause", uid, car_of)
		rolled += 1 if r.get("moved", false) else 0
		if r.get("bad", "") != "":
			bad.append("turn %d: %s" % [n, r["bad"]])
	var last: Snapshot.Vehicle = car_of.call()
	var went := _main.world.snapshot.player_pos.x - seat.x
	var aboard: bool = last != null and not _main.world.snapshot.vehicle_at(_main.world.snapshot.player_pos).is_empty() \
			and (_main.world.snapshot.vehicle_at(_main.world.snapshot.player_pos)[0] as Snapshot.Vehicle).uid == uid
	_check(rolled >= 3 and went >= 5 and aboard and bad.is_empty(),
			"driving: UP x2 and six turns roll the car %d squares east with the player on it; each of the %d turns it rolled, the node glides from where it was drawn onto the new pose and the eyes ride along (%s)"
			% [went, rolled, bad])
	if wide and last != null:
		# off the axis and back: the turn glides as well, and the car lies on CDDA's squares at that angle
		var turned := 0
		bad = []
		for act: String in ["LEFT", "LEFT", "pause"]:
			var r := await _drive_turn(act, uid, car_of)
			turned += 1 if r.get("turned", false) else 0
			if r.get("bad", "") != "":
				bad.append("%s: %s" % [act, r["bad"]])
		var steered: Snapshot.Vehicle = car_of.call()
		var face: float = steered.face_deg if steered != null else 0.0
		_check(turned >= 1 and bad.is_empty() and steered != null and not _faces(face, 0.0),
				"driving: LEFT x2 steers the car to face %.0f degrees; each of the %d turns it turned, the node's turn glides onto the new pose too (%s)"
				% [face, turned, bad])
		if steered != null:
			_vehicles_ok("the car steered to face %.0f degrees" % face)
			_cells_ok("driving: facing %.0f degrees" % face, steered)
		bad = []
		for act: String in ["RIGHT", "RIGHT", "pause"]:
			var r := await _drive_turn(act, uid, car_of)
			if r.get("bad", "") != "":
				bad.append("%s: %s" % [act, r["bad"]])
		var again: Snapshot.Vehicle = car_of.call()
		_check(again != null and _faces(again.face_deg, 0.0) and bad.is_empty(), "driving: RIGHT x2 steers it back to face east (%s; %s)"
				% [again.face_deg if again != null else "?", bad])
	# stop (back to no speed), let go, walk out
	for n in 2:
		_send("DOWN")
	for n in 12:
		var v: Snapshot.Vehicle = car_of.call()
		if v == null or is_zero_approx(v.velocity):
			break
		await _turn("pause")
	vv.call("glide", 10.0)
	vv.set_process(true)
	_drive_keys = false
	if keys:
		_main.fp.set_look(yaw0, pitch0)
		print("    (driven by the step keys with the camera turned: forward UP, left / right steer, back DOWN)")
		root.push_input(_key_of(&"cdda_control_vehicle"))
	else:
		_live.queue_action("control_vehicle")
	var stopped := await _let_go()
	var stands: Snapshot.Vehicle = car_of.call()
	_check(stopped and stands != null and is_zero_approx(stands.velocity),
			"driving: DOWN stops the car and \"Let go of controls\" from CDDA's menu ends the driving (velocity %s)"
			% [stands.velocity if stands != null else "?"])
	if keys and _main.world.snapshot.has_method("controls_at"):
		# the seat beside the driver's has no controls: CDDA says nothing there, the client says why
		var side: Vector3i = _main.world.snapshot.player_pos - (door - seat)   # (the car has rolled on; it faces east again)
		await _until(asking, SHOW_TIMEOUT_MS)
		await _turn(_step_name(seat - door))
		var on_side: bool = _main.world.snapshot.player_pos == side
		var found: int = _main.world.snapshot.call("controls_at", side, _main.world.tables)
		var note := str((Main as Script).get_script_constant_map().get("NO_CONTROLS_NOTE", "?"))
		var had := _said_times(note)
		await _until(asking, SHOW_TIMEOUT_MS)
		root.push_input(_key_of(&"cdda_control_vehicle"))
		var said := func() -> bool: return _said_times(note) > had
		var hinted := await _until(said, 5000)
		_check(on_side and found == 1 and hinted and _player_field("driving") == null and _live.request.get("timed", false),
				"driving: on the seat beside the driver's (no controls there) %s takes nothing and the feed says why (\"%s\"; on the seat %s, controls_at %d, said %s)"
				% [InputActions.prompt_of(&"cdda_control_vehicle"), note.left(40), on_side, found, hinted])
	var step_out := _step_name(out - door)
	var here := _main.world.snapshot.player_pos
	for n in 6:   # onto the door's square, then out
		if _main.world.snapshot.vehicle_at(_main.world.snapshot.player_pos).is_empty():
			break
		await _turn(step_out)
	var back := func() -> bool: return _main.world.snapshot.player_pos == start and not _main.world.busy()
	_check(_main.world.snapshot.player_pos != here and await _cheat(_live.cheat_teleport(start)) == ""
			and await _until(back, SHOW_TIMEOUT_MS), "driving: the player walks out of the car (%s) and is back at the arrival square (%s)"
			% [step_out, _main.world.snapshot.player_pos])


## CDDA's control_vehicle key away from a car (lead-world's key; skipped, said so, on a client without it or a bridge
## without the vehicle spawn). With no vehicle next to the player the key does nothing: no prompt, no turn, no
## message. Then a bicycle is spawned. From the floor next to its controls the key is CDDA's to answer (what it does
## is printed) and the client adds no hint of its own. On the bicycle the key takes the controls (the snapshot says
## driving), the key again brings CDDA's menu, and "Let go" there ends the driving. Then back to `start`.
func _bike_live(start: Vector3i) -> void:
	if not InputMap.has_action(&"cdda_control_vehicle") or not _main.world.snapshot.has_method("controls_at") \
			or not _live.sim().has_method("range_spawn_vehicle"):
		print("  (no control_vehicle key in this client, or no vehicle spawn: the key away from a car not checked)")
		return
	var key_name := InputActions.prompt_of(&"cdda_control_vehicle")
	var note := str((Main as Script).get_script_constant_map().get("NO_CONTROLS_NOTE", "?"))
	var hints := func() -> int: return _said_times(note)
	var in_loop := func() -> bool: return _live.request.get("timed", false)
	await _until(in_loop, SHOW_TIMEOUT_MS)
	_watch_messages()
	var alone := true
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			alone = alone and _main.world.snapshot.vehicle_at(start + Vector3i(dx, dy, 0)).is_empty()
	if alone:
		var turn: int = _main.world.snapshot.turn
		var seen := _msg_changes
		var had0: int = hints.call()
		root.push_input(_key_of(&"cdda_control_vehicle"))
		await create_timer(1.5).timeout
		_check(_live.request.get("timed", false) and _main.world.snapshot.turn == turn and hints.call() == had0
				and _player_field("driving") == null,
				"control key: with no vehicle around, %s takes nothing: no prompt, no turn, no hint from the client (CDDA said: %s)"
				% [key_name, str(_main.hud_data.messages.back()).left(120) if _msg_changes > seen else "nothing"])
	else:
		print("  (a vehicle stands next to the arrival square: the key with no vehicle around not checked)")
	var before := {}
	for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
		before[veh.uid] = true
	var feet := _floor_at(start)
	var placed := false
	for d: Vector3i in [Vector3i(4, 0, 0), Vector3i(-4, 0, 0), Vector3i(0, 4, 0), Vector3i(0, -4, 0), Vector3i(6, 6, 0)]:
		if not placed and _floor_at(start + d) == feet and await _cheat(_spawn_vehicle("bicycle", start + d, 0)) == "":
			placed = true
	var bike_of := func() -> Snapshot.Vehicle:
		for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
			if not before.has(veh.uid):
				return veh
		return null
	var listed := func() -> bool: return bike_of.call() != null and not _main.world.busy()
	if not placed or not await _until(listed, SHOW_TIMEOUT_MS):
		_check(false, "control key: a bicycle is spawned near the arrival square")
		return
	var bike: Snapshot.Vehicle = bike_of.call()
	var ctl := Vector3i.MAX
	var beside := Vector3i.MAX
	for i in bike.part_count():
		var sq := bike.square(i)
		if ctl == Vector3i.MAX and _main.world.snapshot.call("controls_at", sq, _main.world.tables) == 2:
			ctl = sq
	for d: Vector3i in [Vector3i(0, -1, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0), Vector3i(1, 0, 0)]:
		if ctl != Vector3i.MAX and beside == Vector3i.MAX and _floor_at(ctl + d) == feet:   # not a vehicle's square
			beside = ctl + d
	var there := func() -> bool: return _main.world.snapshot.player_pos == beside and not _main.world.busy()
	var by: bool = beside != Vector3i.MAX and await _cheat(_live.cheat_teleport(beside)) == "" \
			and await _until(there, SHOW_TIMEOUT_MS)
	_check(by, "control key: the player stands on the floor next to the bicycle's controls (controls %s, player %s, %d parts)"
			% [ctl, _main.world.snapshot.player_pos, bike.part_count()])
	if not by:
		return
	# from beside it: CDDA's own answer, no hint from the client
	await _until(in_loop, SHOW_TIMEOUT_MS)
	var had: int = hints.call()
	var seen_msgs := _msg_changes
	root.push_input(_key_of(&"cdda_control_vehicle"))
	var got := ""
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until and got.is_empty():
		var r := _live.request
		if not r.is_empty() and not r.get("timed", false):
			got = "%s \"%s\"" % [r.get("kind", "?"), (str(r.get("title", "")) + " " + str(r.get("text", ""))).strip_edges().left(60)]
		elif _msg_changes > seen_msgs:
			got = "a message: %s" % str(_main.hud_data.messages.back()).left(120)
		await create_timer(0.05).timeout
	print("    (%s from beside the bicycle: CDDA answers with %s)" % [key_name, got if not got.is_empty() else "nothing"])
	_check(hints.call() == had and _player_field("driving") == null,
			"control key: from beside the bicycle the client adds no hint and nothing is driven (CDDA: %s)"
			% [got if not got.is_empty() else "nothing"])
	await _until(in_loop, SHOW_TIMEOUT_MS)   # (a menu of CDDA's is cancelled here)
	# on it
	await _turn(_step_name(ctl - beside))
	var on_it: bool = _main.world.snapshot.player_pos == ctl
	root.push_input(_key_of(&"cdda_control_vehicle"))
	var driving := func() -> bool: return _player_field("driving") == true
	var took := on_it and await _until_slow(driving, 20000)
	var shown := func() -> bool: return _main.world.snapshot.get("player_driving") == true
	_check(took and await _until(shown, SHOW_TIMEOUT_MS) and _main.world.snapshot.get("player_vehicle") == bike.uid,
			"control key: on the bicycle, %s takes its controls: the snapshot says driving, on that vehicle (on its square %s, driving %s, vehicle %s)"
			% [key_name, on_it, took, _main.world.snapshot.get("player_vehicle")])
	if took:
		await _until(in_loop, SHOW_TIMEOUT_MS)
		root.push_input(_key_of(&"cdda_control_vehicle"))
		_check(await _let_go(), "control key: driving, %s brings CDDA's menu and \"Let go\" there ends the driving" % key_name)
	await _until(in_loop, SHOW_TIMEOUT_MS)
	await _turn(_step_name(beside - ctl))   # off the bicycle first
	var back := func() -> bool: return _main.world.snapshot.player_pos == start and not _main.world.busy()
	var why := await _cheat(_live.cheat_teleport(start))
	_check(why == "" and await _until(back, SHOW_TIMEOUT_MS),
			"control key: the player steps off and is back at the arrival square (%s; teleport: %s)"
			% [_main.world.snapshot.player_pos, why if not why.is_empty() else "done"])


## Rain seen from afar (lead-world's far layer; skipped, said so, on a client without it or without the weather
## cheat). With rain held by the cheat: in first person the far layer is off. In the top view zoomed out it runs:
## its start points are bounded, and it rains wherever a cell of its ring is open to the sky. How long working the
## ring out takes is printed. Then the view and the weather are as they were.
func _rain_far_live() -> void:
	var precip: Variant = _main.weather.get("precip") if _main.weather != null else null
	if precip == null or not "far_view" in precip or not _live.can_set_weather() or not _main._fp_active():
		print("  (no far rain in this client, no weather cheat, or not in first person: rain from afar not checked)")
		return
	var rain_id := ""
	for t: Dictionary in _live.weather_types():
		if rain_id.is_empty() and str(t["id"]).contains("rain") and not str(t["id"]).contains("acid"):
			rain_id = t["id"]
	var held := _live.cheat_weather()
	var set_ok := not rain_id.is_empty() and await _cheat(_live.cheat_set_weather(rain_id, LiveSession.WIND_GAME)) == ""
	_live.queue_action("pause")
	var raining := func() -> bool:
		var last: Array = precip.get("_last")
		return last.size() == 3 and last[2] != null and last[2].precip > 0.0
	var wet := set_ok and await _until(raining, SHOW_TIMEOUT_MS)
	await _frames(3)
	var near_only: bool = not precip.far_view and not precip.far_rain.emitting
	var near_points: int = precip.points
	_main._set_view("top")
	for n in 10:
		if precip.far_view:
			break
		_main.view_cam.zoom(1)
		await _frames(3)
	await _frames(3)
	var is_far: bool = precip.far_view
	var cells: int = precip.far_cells
	var pts: int = precip.far_points
	var cap := int((precip.get_script() as Script).get_script_constant_map().get("MAX_FAR_POINTS", 4096))
	var falls: bool = precip.far_rain.emitting
	var ms := -1.0
	var last: Array = precip.get("_last")
	if wet and last.size() == 3:   # the ring worked out again, timed
		precip.set("_far_key", [])
		var t0 := Time.get_ticks_usec()
		precip.apply(last[0], last[1], last[2])
		ms = (Time.get_ticks_usec() - t0) / 1000.0
	_check(wet and near_only and is_far and pts <= cap and falls == (pts > 0) and (cells == 0 or pts > 0),
			"rain from afar (%s): off in first person; on in the top view zoomed out, raining on %d of %d cells of its ring from %d start points (at most %d); the near rain has %d (set %s, raining %s, far view %s, falling %s)"
			% [rain_id, cells, int(precip.call("far_total")), pts, cap, near_points, set_ok, wet, is_far, falls])
	print("    (working the far ring out again took %.1f ms)" % ms)
	_main._set_view("first")
	await _frames(3)
	_check(not precip.far_view and not precip.far_rain.emitting, "rain from afar: back in first person the far layer is off again")
	await _cheat(_live.cheat_set_weather(held, LiveSession.WIND_GAME))


## With CDDA's menu for the controls asked for while driving: picks its "Let go" entry. True once the snapshot no
## longer says driving.
func _let_go() -> bool:
	var menu := func() -> bool: return _live.request.get("kind", "") == "menu"
	var entry := -1
	if await _until(menu, SHOW_TIMEOUT_MS):
		for e: Variant in _live.request.get("entries", []):
			if e is Dictionary and e.get("enabled", false) and CddaText.plain(str(e.get("label", ""))).contains("Let go"):
				entry = int(e.get("id", -1))
		_answered = int(_live.request["id"])
		_live.answer({"id": _answered, "entry": entry} if entry >= 0 else {"id": _answered, "cancel": true})
	var free := func() -> bool: return _player_field("driving") == null
	return entry >= 0 and await _until_slow(free, OP_TIMEOUT_MS)


## Sends CDDA action `act`: while this script drives by the step keys (_drive_keys), a driving action goes as its
## step key through main's own input path, whichever way the camera faces; otherwise it is queued.
func _send(act: String) -> void:
	if _drive_keys and DRIVE_STEP.has(act):
		root.push_input(_key_of(DRIVE_STEP[act]))
	else:
		_live.queue_action(act)


## The key bound first to `action` (F1 defaults), as a press; null if it has none.
func _key_of(action: StringName) -> InputEventKey:
	for e in InputActions.slots(action):
		if e is InputEventKey:
			var k := (e as InputEventKey).duplicate() as InputEventKey
			if k.keycode == KEY_NONE:
				k.keycode = k.physical_keycode
			if k.physical_keycode == KEY_NONE:
				k.physical_keycode = k.keycode
			k.pressed = true
			return k
	return null


## How many of the HUD's messages have `text` (by their own text: str() of the list would escape it).
func _said_times(text: String) -> int:
	var n := 0
	for m: Dictionary in _main.hud_data.messages:
		n += 1 if str(m.get("text", "")) == text else 0
	return n


## Counts the changes of the HUD's message feed from now on (_msg_changes); once.
func _watch_messages() -> void:
	if _msg_watched:
		return
	_msg_watched = true
	_main.hud_data.changed.connect(func(parts: PackedStringArray) -> void:
		if "messages" in parts:
			_msg_changes += 1)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## One turn at the wheel with the view's own gliding off: queues `act`, and when the car `uid` (car_of gives its
## snapshot row) moved or turned in that turn, checks its glide: the node is still where it was drawn (over half a
## metre from the new pose), 0.04 s of gliding brings it nearer without arriving, the camera's ride transform isn't
## the identity meanwhile, and the whole glide ends on the pose with the ride the identity; a turn of the car must
## glide the same way. {moved, turned, bad: what was off, "" nothing}; {} when the car stood still.
func _drive_turn(act: String, uid: int, car_of: Callable) -> Dictionary:
	var vv: VehicleView = _main.vehicles_view
	var was: Snapshot.Vehicle = car_of.call()
	if was == null:
		return {"bad": "the car is gone"}
	var pos0 := was.pos
	var face0 := was.face_deg
	await _turn(act)
	var now: Snapshot.Vehicle = car_of.call()
	if now == null:
		return {"bad": "the car is gone"}
	var a0: Variant = vv.call("drawn", uid)
	var turned := not is_equal_approx(now.face_deg, face0)
	if (now.pos == pos0 and not turned) or not a0 is Transform3D:
		vv.call("glide", 10.0)
		return {}
	var pose: Transform3D = vv.call("pose_of", now, _main.world)
	var d0 := (a0 as Transform3D).origin.distance_to(pose.origin)
	var g0 := (a0 as Transform3D).basis.x.angle_to(pose.basis.x)
	var ride0: Transform3D = vv.call("ride_transform", _main.world.snapshot)
	vv.call("glide", 0.04)
	var a1: Transform3D = vv.call("drawn", uid)
	var d1 := a1.origin.distance_to(pose.origin)
	var g1 := a1.basis.x.angle_to(pose.basis.x)
	vv.call("glide", 10.0)
	var end: Transform3D = vv.call("drawn", uid)
	var ride1: Transform3D = vv.call("ride_transform", _main.world.snapshot)
	var ok := d0 > 0.5 and d1 < d0 and d1 > 0.0 and not ride0.is_equal_approx(Transform3D()) \
			and end.is_equal_approx(pose) and ride1.is_equal_approx(Transform3D()) \
			and (not turned or (g0 > 0.02 and g1 < g0 and g1 > 0.0))
	return {"moved": true, "turned": turned, "bad": "" if ok else
			"%.2f m off, then %.2f; turned %s (%.3f rad off, then %.3f); ride %s, at the end %s; on the pose %s" % [d0, d1,
			turned, g0, g1, not ride0.is_equal_approx(Transform3D()), not ride1.is_equal_approx(Transform3D()),
			end.is_equal_approx(pose)]}


## Whether a facing of `deg` degrees is `want` degrees (the same direction).
func _faces(deg: float, want: float) -> bool:
	return absf(angle_difference(deg_to_rad(deg), deg_to_rad(want))) < 0.02


## Squares round `start` where a car facing east has open floor of terrain `feet` under it, for `ahead` squares
## east of it and from `left` squares north of it to 3 south, nearest rows of the scan first (_lane_open).
func _lanes(start: Vector3i, feet: int, ahead: int, left: int) -> Array:
	var out := []
	for dy in range(-40, 41, 4):
		for dx in range(-40, 21, 4):
			var c := start + Vector3i(dx, dy, 0)
			if maxi(absi(dx), absi(dy)) >= 8 and _lane_open(c, feet, ahead, left):
				out.append(c)
	return out


## Every cell of `veh`'s drawn grid lies within 0.75 m of the square CDDA has its part on (said as `what`); skipped
## on a client that can't say where the grid is.
func _cells_ok(what: String, veh: Snapshot.Vehicle) -> void:
	var worst := _cells_off(veh)
	if worst.is_empty():
		return
	_check(float(worst[0][2]) <= 0.75, "%s: every cell of the car's drawn grid lies within 0.75 m of its square (the farthest, as [mount, square, m]: %s)"
			% [what, worst.slice(0, 2)])


## Queues CDDA action `act` and waits for the turn it takes to show (or 5 s when it takes none).
func _turn(act: String) -> void:
	var turn := _main.world.snapshot.turn
	var pos := _main.world.snapshot.player_pos
	_send(act)
	var passed := func() -> bool:
		var s: Snapshot = _main.world.snapshot
		return (s.turn > turn or s.player_pos != pos) and s.seq == _live.sim().get_snapshot_seq() and not _main.world.busy()
	await _until(passed, 5000)


## The step action that moves by `d` (one square along an axis).
func _step_name(d: Vector3i) -> String:
	return {Vector3i(0, -1, 0): "UP", Vector3i(1, 0, 0): "RIGHT", Vector3i(0, 1, 0): "DOWN", Vector3i(-1, 0, 0): "LEFT"}.get(d, "pause")


## The terrain index of square `sq` when it is plain floor in the shown snapshot (known, a floor, no furniture, no
## vehicle), else -1.
func _floor_at(sq: Vector3i) -> int:
	var sm: Snapshot.Submap = _main.world.snapshot.submaps.get(CddaCoords.ms_to_sm(sq))
	if sm == null:
		return -1
	var l := CddaCoords.ms_to_local(sq)
	var i := l.y * CddaCoords.SEEX + l.x
	if (sm.flags[i] & (Snapshot.FLAG_NO_FLOOR | Snapshot.FLAG_VEHICLE)) != 0 or sm.furn[i] != 0:
		return -1
	return sm.ter[i]


## Whether a car put on `c` facing east has open floor of terrain `feet` under it and for `ahead` squares east of
## it, from `left` squares north of it to 3 south, with no creature on it.
func _lane_open(c: Vector3i, feet: int, ahead: int, left: int) -> bool:
	if feet < 0:
		return false
	for dy in range(-left, 4):
		for dx in range(-5, ahead + 1):
			var sq := c + Vector3i(dx, dy, 0)
			if _floor_at(sq) != feet or _main.world.snapshot.creature_at(sq) != null or sq == _main.world.snapshot.player_pos:
				return false
	return true


## `player.<key>` of the bridge's newest snapshot as JSON gives it (fields the client's parser doesn't read yet);
## null when it isn't there.
func _player_field(key: String) -> Variant:
	var d: Variant = JSON.parse_string(_live.sim().get_snapshot_json(0, 0))
	var p: Variant = (d as Dictionary).get("player") if d is Dictionary else null
	var v: Variant = (p as Dictionary).get(key) if p is Dictionary else null
	return int(v) if v is float and key == "vehicle" else v


## _until for a condition that is slow to work out: asked every 0.25 s.
func _until_slow(cond: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
		_answer_prompt()
		await create_timer(0.25).timeout
	return false


## For a report: the four cells of `veh` whose place in its drawn grid (VehicleView.frame_of) is farthest from the
## square CDDA has the part on: [[mount, the square's offset from the vehicle's position, metres apart], ...].
func _cells_off(veh: Snapshot.Vehicle) -> Array:
	var vv: VehicleView = _main.vehicles_view
	if not vv.has_method("frame_of"):
		return []
	var f: Transform3D = vv.call("frame_of", veh, _main.world.coords)
	var rows := []
	var seen := {}
	for i in veh.part_count():
		var k := i * Snapshot.VPART_STRIDE
		var m := Vector2i(veh.parts[k], veh.parts[k + 1])
		if (veh.parts[k + 4] & Snapshot.VPART_FILLER) != 0 or seen.has(m):
			continue
		seen[m] = true
		var cell: Vector3 = f * Vector3(m.x, 0.0, m.y)
		var sq: Vector3 = _main.world.coords.ms_center_to_world(veh.square(i))
		rows.append([m, Vector2i(veh.parts[k + 5], veh.parts[k + 6]), snappedf(Vector2(cell.x - sq.x, cell.z - sq.z).length(), 0.01)])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[2] > b[2])
	return rows.slice(0, 4)


## Asks the game for vehicle `id` on `pos` facing `facing` degrees: the op id, 0 when not sent (LiveSession's own
## call once it has one, else its range op with the bridge's method).
func _spawn_vehicle(id: String, pos: Vector3i, facing: int) -> int:
	if _live.has_method("range_spawn_vehicle"):
		return int(_live.call("range_spawn_vehicle", id, pos, facing))
	return _live._range_op("range_spawn_vehicle", [id, pos, facing])


## A walk across a submap border: the teleport cheat a submap's width (12 squares) to one side of `start`, which
## makes the map shift by a submap, most of it still the same ground; then back. Deltas checked after each
## (_deltas_ok: a full answer is due after the shift, and that it came is counted for _deltas_done).
func _border_live(start: Vector3i) -> void:
	var origin := _main.world.snapshot.bubble_origin
	var shifted := func() -> bool:
		var s: Snapshot = _main.world.snapshot
		return s.bubble_origin != origin and s.player_pos.z == start.z and not _main.world.busy()
	var over := false
	for d: Vector3i in [Vector3i(12, 0, 0), Vector3i(0, -12, 0), Vector3i(-12, 0, 0), Vector3i(0, 12, 0)]:
		if await _cheat(_live.cheat_teleport(start + d)) == "" and await _until(shifted, SHOW_TIMEOUT_MS):
			over = true
			break
	_check(over, "the teleport cheat takes the player over a submap border and the map shifts (player %s -> %s, origin %s -> %s)"
			% [start, _main.world.snapshot.player_pos, origin, _main.world.snapshot.bubble_origin])
	if not over:
		return
	await _deltas_ok("over a submap border")
	_vehicles_ok("over a submap border")
	var back := func() -> bool: return _main.world.snapshot.player_pos == start and not _main.world.busy()
	_check(await _cheat(_live.cheat_teleport(start)) == "" and await _until(back, SHOW_TIMEOUT_MS),
			"teleported back over the border (%s)" % _main.world.snapshot.player_pos)
	await _deltas_ok("back over the border")
	_vehicles_ok("back over the border")


## Delta snapshots after the move `what`, where a move changes what the bridge can build on (contracts/snapshot.md
## "Deltas"). Once the world shows the newest snapshot, two readings of it must be the plain snapshot of that moment
## (SnapSame.diff): the one the world shows, which LiveSession fetched on the snapshot it held, and the delta call's
## answer read here on the snapshot this script holds (_held). After a map shift and on another level that answer
## must be a full one. Then a turn is waited and both are compared again: the answer must now be a delta on the
## snapshot just read. Skipped, said once, on a bridge without the call or a client without the parser.
func _deltas_ok(what: String) -> void:
	if _deltas_off:
		return
	if not _live.sim().has_method("get_snapshot_delta_json") or Snapshot.new().get("base_seq") == null:
		_deltas_off = true
		print("  (no delta call in this bridge, or no delta parser in this client: deltas not checked)")
		return
	var before := _held
	var got := await _read_newest()
	var next: Snapshot = got.get("next")
	var moved := ""   # "shift" / "level": the bridge can't build on the one held
	var place := "nothing held"
	if before != null and next != null:
		place = "the same map"
		if next.player_pos.z != before.player_pos.z:
			moved = "level"
			place = "level %d -> %d" % [before.player_pos.z, next.player_pos.z]
		elif next.bubble_origin != before.bubble_origin:
			moved = "shift"
			place = "the map shifted by %s submaps" % (next.bubble_origin - before.bubble_origin)
	var full_ok: bool = next != null and (next.base_seq == -1 or (before != null and moved == ""))
	_check(got["diff"] == "" and full_ok, ("deltas, %s (%s): the world's snapshot and the delta call's answer read on the "
			+ "one held are the plain snapshot%s (%s) %s") % [what, place, ", the answer a full one" if moved != "" else "",
			_answer_note(got), got["diff"]])
	if next == null:
		return
	if moved != "" and next.base_seq == -1:
		_full_after[moved] += 1
	_held = next
	var passed := func() -> bool: return _main.world.snapshot.turn > next.turn
	var waited: bool = _live.queue_action("pause") and await _until(passed, OP_TIMEOUT_MS)
	got = await _read_newest()
	var later: Snapshot = got.get("next")
	_check(waited and got["diff"] == "" and later != null and later.base_seq == next.seq, ("deltas, %s: a turn later both "
			+ "are the plain snapshot again, the answer a delta on the one just read (%s) %s") % [what, _answer_note(got),
			got["diff"]])
	if later != null:
		_held = later


## The newest snapshot of one moment, read three ways: {next: the delta call's answer read on _held (absent when it
## or the plain one wasn't read), kb: the answer's size, diff: "" when the world's snapshot and `next` are both the
## plain snapshot, else what is off}. Read again when a newer snapshot came between the readings.
func _read_newest() -> Dictionary:
	var sim := _live.sim()
	var settled := func() -> bool:
		var s: Snapshot = _main.world.snapshot
		return s != null and s.seq == sim.get_snapshot_seq() and not _main.world.busy()
	for attempt in 5:
		if not await _until(settled, SHOW_TIMEOUT_MS):
			return {"diff": "the world doesn't show the newest snapshot (%d, the bridge has %d)"
					% [_main.world.snapshot.seq, sim.get_snapshot_seq()]}
		var shown: Snapshot = _main.world.snapshot
		var text: String = sim.get_snapshot_delta_json(LiveSession.Z_BELOW, LiveSession.Z_ABOVE,
				_held.seq if _held != null else 0)
		var next := Snapshot.parse_text(text, _held)
		var plain := Snapshot.parse_text(sim.get_snapshot_json(LiveSession.Z_BELOW, LiveSession.Z_ABOVE))
		if not next.is_valid() or not plain.is_valid():
			return {"diff": "not read: %s %s" % [next.error, plain.error]}
		if next.seq != shown.seq or plain.seq != shown.seq:
			continue
		var d := SnapSame.diff(shown, plain)
		if d != "":
			d = "the world's: " + d
		else:
			d = SnapSame.diff(next, plain)
			if d != "":
				d = "the answer: " + d
		return {"next": next, "kb": text.length() / 1024, "diff": d}
	return {"diff": "newer snapshots kept coming"}


## What _read_newest's answer was, for a check's line: full or a delta, the submaps taken from the one held, its size.
func _answer_note(got: Dictionary) -> String:
	var next: Snapshot = got.get("next")
	if next == null:
		return "no answer"
	return "%s, %d of %d submaps reused, %d KB" % ["full" if next.base_seq == -1 else "a delta on %d" % next.base_seq,
			next.reused_submaps, next.submaps.size(), got["kb"]]


## The delta checks as a whole, once the walk is over: a full answer came after a map shift and on another level,
## and LiveSession itself read deltas all along and never one that didn't fit the snapshot it held.
func _deltas_done() -> void:
	if _deltas_off:
		return
	_check(_full_after["shift"] >= 2 and _full_after["level"] >= 2 and _live.deltas_read > 0 and _live.delta_fallbacks == 0,
			"deltas: full answers after %d map shifts and %d changes of level; the live game read %d deltas, %d didn't fit"
			% [_full_after["shift"], _full_after["level"], _live.deltas_read, _live.delta_fallbacks])


## The vehicles of the shown snapshot are drawn where their parts' squares are, after the move `what` (VehicleView
## with bodies, C5 slice 2; skipped, said once, on a client without them): the bodies' vertices and the small parts'
## places lie within 2 m of a square of a vehicle (a cell stretched at an angle, a cut corner, a wheel pushed out),
## and what is on screen is there too: with a node per vehicle (slice 3: VehicleView.drawn) each node, its glide
## finished, is at the pose the snapshot gives it (pose_of); before that, every layer that draws something sits at
## the origin again. A view that kept a map shift would be a submap (12 m) off.
func _vehicles_ok(what: String) -> void:
	var vv: VehicleView = _main.vehicles_view
	if vv == null or not vv.has_method("hull"):
		if not _veh_off:
			print("  (no vehicle bodies in this client: where vehicles are drawn isn't checked)")
		_veh_off = true
		return
	var snap: Snapshot = _main.world.snapshot
	var cells := {}   # Vector2i(world x, z, rounded to metres) of every vehicle part's square
	for veh: Snapshot.Vehicle in snap.vehicles:
		for i in veh.part_count():
			var w: Vector3 = _main.world.coords.ms_center_to_world(veh.square(i))
			cells[Vector2i(roundi(w.x), roundi(w.z))] = true
	if cells.is_empty():
		print("  (%s: no vehicle in the snapshot)" % what)
		return
	var moved := []   # what is on screen somewhere else than the snapshot puts it
	if vv.has_method("drawn"):
		vv.call("glide", 10.0)   # a glide still going ends
		for veh: Snapshot.Vehicle in snap.vehicles:
			var at: Variant = vv.call("drawn", veh.uid)
			var pose: Variant = vv.call("pose_of", veh, _main.world)
			if at is Transform3D and not (pose is Transform3D and (at as Transform3D).is_equal_approx(pose)):
				moved.append([veh.uid, (at as Transform3D).origin, (pose as Transform3D).origin if pose is Transform3D else pose])
		if not (vv as Node3D).transform.is_equal_approx(Transform3D()):
			moved.append(["the view", (vv as Node3D).position])
	else:
		for c: Node in vv.get_children():
			var draws: bool = c is MeshInstance3D or (c is MultiMeshInstance3D
					and (c as MultiMeshInstance3D).multimesh != null and (c as MultiMeshInstance3D).multimesh.instance_count > 0)
			if draws and not (c as Node3D).position.is_zero_approx():
				moved.append([c.name, (c as Node3D).position])
	var pts := PackedVector3Array()
	for look: int in VehicleView.Look.values():
		var verts: PackedVector3Array = vv.call("hull", look)[0]
		for i in range(0, verts.size(), 5):   # every fifth vertex is plenty
			pts.append(verts[i])
		for e: Array in vv.instances(look):
			pts.append((e[0] as Transform3D).origin)
	var off := []     # the first few points with no square near
	var off_n := 0
	var worst := 0.0  # how far the farthest of them is from the nearest square's centre (m, the larger of x and z)
	for p: Vector3 in pts:
		var near := false
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				near = near or cells.has(Vector2i(roundi(p.x) + dx, roundi(p.z) + dz))
		if near:
			continue
		off_n += 1
		if off.size() < 3:
			off.append(p)
		var best := INF
		for c: Vector2i in cells:
			best = minf(best, maxf(absf(p.x - c.x), absf(p.z - c.y)))
		worst = maxf(worst, best)
	_veh_seen.append(pts.size())
	_check(moved.is_empty() and off_n == 0 and not pts.is_empty(), ("vehicles, %s: the %d in the snapshot are drawn "
			+ "on their squares (%d points compared; %d off, the farthest %.1f m from a square: %s; on screen elsewhere: %s)")
			% [what, snap.vehicles.size(), pts.size(), off_n, worst, off, moved])


## The vehicle checks as a whole: vehicles were compared after at least two moves that shifted the map.
func _vehicles_done() -> void:
	if _veh_off:
		return
	_check(_veh_seen.size() >= 3, "vehicles: drawn on their squares at the start and after map shifts (%d times, points: %s)"
			% [_veh_seen.size(), _veh_seen])


## The stairs up nearest `from` on its level that the client knows of (within 16 squares); the hub's own (10 west,
## 8 south of the arrival square, fork test_range.cpp) when none is in sight yet.
func _stair_near(from: Vector3i) -> Vector3i:
	var best := from + Vector3i(-10, 8, 0)
	var best_d := 1 << 20
	for dy in range(-16, 17):
		for dx in range(-16, 17):
			var sq := from + Vector3i(dx, dy, 0)
			var d := maxi(absi(dx), absi(dy))
			if d > 0 and d < best_d and StairUse.find(_main.world, sq, from.z).get("dz", 0) == 1:
				best = sq
				best_d = d
	return best


## main.use_stair on the stair at `sq` from level `z` (asked until main takes it), then the player on level z + dz
## and the world showing it.
func _take_stair(sq: Vector3i, z: int, dz: int) -> bool:
	var asked := [false]
	var there := func() -> bool:
		if not asked[0]:
			var s := StairUse.find(_main.world, sq, z)
			asked[0] = s.get("dz", 0) == dz and _main.use_stair(s)
		return asked[0] and _main.world.snapshot.player_pos.z == z + dz and not _main.world.busy()
	return await _until(there, OP_TIMEOUT_MS)


## The shown snapshot around the player's level: every level the client asks for (LiveSession.Z_BELOW / Z_ABOVE)
## is there whole (121 submaps), and no submap's revision or detail revision is lower than the highest seen before
## (`seen`, brought up to date).
func _levels_ok(what: String, seen: Dictionary) -> void:
	var snap: Snapshot = _main.world.snapshot
	var pz := snap.player_pos.z
	var count := {}
	var back := []
	for key: Vector3i in snap.submaps:
		var sm: Snapshot.Submap = snap.submaps[key]
		count[key.z] = int(count.get(key.z, 0)) + 1
		var now := Vector2i(sm.revision, sm.detail_revision)
		var was: Vector2i = seen.get(key, Vector2i.ZERO)
		if now.x < was.x or now.y < was.y:
			back.append([key, was, now])
		seen[key] = Vector2i(maxi(now.x, was.x), maxi(now.y, was.y))
	var want := range(pz - LiveSession.Z_BELOW, pz + LiveSession.Z_ABOVE + 1)
	var whole := want.all(func(z: int) -> bool: return int(count.get(z, 0)) == 121)
	_check(whole and count.size() == want.size(), "%s: the snapshot has levels %s whole, around the player's (submaps a level: %s)"
			% [what, want, count])
	_check(back.is_empty(), "%s: no submap's revisions ran backwards (%d submaps known) %s" % [what, seen.size(), back.slice(0, 4)])


## Waits for range_done of a cheat op `id` sent past the panel (0 = refused before sending); "" when it was done.
func _cheat(id: int) -> String:
	if id < 1:
		return "not sent"
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS):
		return "no answer"
	return _done[id]


## Presses a range control and waits for the game's answer: "" done, else the error (or why it wasn't sent).
## `label` starts the status line the panel shows for it.
func _op(press: Callable, label: String) -> String:
	var before: Array = _cp._range_ops.keys()
	press.call()
	return await _wait_new(before, label)


## The op a control just sent by signal (the freeze switch): the newest one waiting.
func _last_op(label: String) -> String:
	var keys: Array = _cp._range_ops.keys()
	return await _wait_new(keys.slice(0, keys.size() - 1), label)


func _wait_new(before: Array, label: String) -> String:
	var sent: Array = _cp._range_ops.keys().filter(func(k: int) -> bool: return not k in before)
	if sent.is_empty():
		return "not sent: " + _cp.status.text
	var id: int = sent[0]
	var answered := func() -> bool: return _done.has(id)
	if not await _until(answered, OP_TIMEOUT_MS):
		return "no answer"
	var err: String = _done[id]
	var said := _cp.status.text
	if not said.begins_with(label) or said.ends_with("done.") != err.is_empty():
		return "status line says \"%s\" for \"%s\"" % [said, err]
	print("  %s -> %s" % [label, "done" if err.is_empty() else err])
	return err


## Waits (playing on) until `cond` holds; false on timeout or if the game stops.
func _until(cond: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		if _live.state == "ended" or _live.state == "failed":
			return false
		_answer_prompt()
		await create_timer(0.05).timeout
	return false


## A prompt main would show the player gets the answer a player would give (YES to confirmations, else cancel);
## main answers raw-key screens and shots itself.
func _answer_prompt() -> void:
	var req := _live.request
	if req.is_empty() or req.get("timed", false) or req.get("context", "") == "RAW_KEY":
		return
	var id := int(req.get("id", 0))
	if id == _answered:
		return
	_answered = id
	var a := {"id": id, "cancel": true}
	var acts: Array = req.get("actions", [])
	if req.get("kind", "") == "popup" and not acts.is_empty():
		var pick: String = "YES" if "YES" in acts else acts[0]
		if req.get("context", "") == "CANCEL_ACTIVITY_OR_IGNORE_QUERY":   # "Stop waiting?": keep on
			pick = "IGNORE" if "IGNORE" in acts else ("NO" if "NO" in acts else pick)
		a = {"id": id, "action": pick}
	print("  answering %s %s %s: %s" % [req.get("kind", "?"), req.get("context", ""), acts, a])
	_live.answer(a)


func _stop() -> void:
	_live.stop()
	var stopped := func() -> bool: return _live.state != "running"
	await _until(stopped, 30000)
	_main.queue_free()
	await process_frame


## Items of itype `t` lying on square `sq`, as the Tab inventory's "nearby" column lists them.
func _ground_count(t: int, sq: Vector3i) -> int:
	var n := 0
	for col: Dictionary in InventoryModel.columns(_main.hands.picker, _main.world.tables, _main.item_actions):
		if col["kind"] != "nearby":
			continue
		for g: Dictionary in col["groups"]:
			for row: Dictionary in g["rows"]:
				var r: ItemRef = row["item"]
				if r.type == t and r.square == sq:
					n += 1
	return n


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _finish() -> void:
	if _failed == 0:
		TestDir.clean()
	else:
		print("  files kept in " + ProjectSettings.globalize_path(TestDir.dir()))
	print("range live tests: " + ("all passed" if _failed == 0 else "%d FAILED" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("  ok    " + what)
	else:
		_failed += 1
		printerr("  FAIL  " + what)
