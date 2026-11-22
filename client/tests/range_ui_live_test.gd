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
	await _chase_wall_live(start)
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
			await _frames(2)
			_marks_ok("vehicle spawn: facing %d degrees, seen on foot" % facing, car)
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
	_marks_ok("driving: the car parked facing east", car)
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
	# lead-world's driving views (a client with them): the chase view while driving, V goes round the driving views
	var views: bool = ("drive_view" in _main or "drive" in _main.hud_settings) and InputMap.has_action(&"view_toggle")
	await _ride_parked(car)
	var walk_view: String = _main.view_mode
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
	if views:
		var chase := func() -> bool: return _main.view_mode == "chase"
		var started := await _until(chase, SHOW_TIMEOUT_MS)
		var went_round := [_main.view_mode]
		var cfg_path: String = UserFiles.at(_main.key_menu.hud_path)
		var saved_top := ""
		var ride := _ride_hud()   # lead-ui's driving HUD: in first person at the controls only with F1's switch
		var fp_box := _main.key_menu.get("ride_fp_check") as CheckBox
		var gauge := [ride.visible] if ride != null else []
		var with_switch := false
		for n in 3:
			root.push_input(_key_of(&"view_toggle"))
			await _frames(3)
			went_round.append(_main.view_mode)
			if n == 0:
				saved_top = _cfg_text(cfg_path, "view", "drive")
			if ride != null:
				gauge.append(ride.visible)
				if _main.view_mode == "first" and fp_box != null:
					fp_box.button_pressed = true
					await _frames(3)
					with_switch = ride.visible
					fp_box.button_pressed = false
					await _frames(3)
		_check(started and went_round == ["chase", "top", "first", "chase"] and _main.hud_settings.view == walk_view,
				"driving views: taking the controls switches to the chase view and %s goes round %s; the walking view kept for later is still \"%s\""
				% [InputActions.prompt_of(&"view_toggle"), went_round, _main.hud_settings.view])
		if ride != null:
			_check(gauge == [true, true, false, true] and with_switch,
					"driving HUD: it shows in the chase and top views, not in first person at the controls (shown by view: %s), and there with F1's \"%s\" on (%s)"
					% [gauge, fp_box.text if fp_box != null else "?", with_switch])
		var pick := _main.key_menu.get("drive_pick") as OptionButton
		if pick != null and "drive" in _main.hud_settings:
			# the driving view is a setting: V saved its pick, and F1's picker switches the view while driving
			var saved_round := _cfg_text(cfg_path, "view", "drive")
			pick.select(2)
			pick.item_selected.emit(2)
			await _frames(3)
			var picked := _main.view_mode
			var saved_pick := _cfg_text(cfg_path, "view", "drive")
			pick.select(1)
			pick.item_selected.emit(1)
			await _frames(3)
			_check(saved_top == "top" and saved_round == "chase" and picked == "top" and saved_pick == "top"
					and _main.view_mode == "chase" and _cfg_text(cfg_path, "view", "drive") == "chase",
					"driving views: %s's pick is saved under [view] drive (%s after the first press, %s after the round); F1's picker on \"%s\" switches the view at once (%s, saved %s), and back to chase"
					% [InputActions.prompt_of(&"view_toggle"), saved_top, saved_round, pick.get_item_text(2), picked, saved_pick])
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
	await _ride_set_speed()
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
	await _ride_sizes()
	var steers := []   # the driving HUD's steering reading after each key, degrees off the heading
	if wide and last != null:
		# off the axis and back: the turn glides as well, and the car lies on CDDA's squares at that angle
		var turned := 0
		bad = []
		var look0: float = _main.fp.yaw
		var car0: Variant = vv.call("drawn", uid)
		for act: String in ["LEFT", "LEFT", "pause"]:
			var r := await _drive_turn(act, uid, car_of)
			turned += 1 if r.get("turned", false) else 0
			if r.get("bad", "") != "":
				bad.append("%s: %s" % [act, r["bad"]])
			var ri: Variant = _ride_info()
			if ri != null:
				steers.append(int(ri.steer()))
		if not steers.is_empty():   # (off the heading only on a turn the car hasn't moved since the key: not judged)
			print("    (driving HUD: the steering reading after LEFT, LEFT, a turn on: %s degrees off the heading)" % [steers])
		var steered: Snapshot.Vehicle = car_of.call()
		var face: float = steered.face_deg if steered != null else 0.0
		_check(turned >= 1 and bad.is_empty() and steered != null and not _faces(face, 0.0),
				"driving: LEFT x2 steers the car to face %.0f degrees; each of the %d turns it turned, the node's turn glides onto the new pose too (%s)"
				% [face, turned, bad])
		if steered != null:
			_vehicles_ok("the car steered to face %.0f degrees" % face)
			_cells_ok("driving: facing %.0f degrees" % face, steered)
			# lead-world's marks: shown for the player's own car in the chase view
			await _frames(2)
			_marks_ok("driving: facing %.0f degrees, in the %s view" % [face, _main.view_mode], steered, _main.view_mode != "first")
		if steered != null and car0 is Transform3D and _main.has_method("_carry_look") and vv.has_method("seat_transform"):
			# the look turns with the car, and the eyes and the body sit on the driver's cell as the car is drawn
			await _frames(3)
			var car1: Transform3D = vv.call("drawn", uid)
			var car_turn := wrapf(float(_main.call("car_yaw", car1)) - float(_main.call("car_yaw", car0)), -PI, PI)
			var look_turn := wrapf(_main.fp.yaw - look0, -PI, PI)
			var snap: Snapshot = _main.world.snapshot
			var sq_w: Vector3 = _main.world.coords.ms_center_to_world(snap.player_pos)
			var seat_w: Vector3 = (vv.call("seat_transform", snap, snap.player_pos) as Transform3D) * sq_w
			var seat_off := Vector2(seat_w.x - sq_w.x, seat_w.z - sq_w.z).length()
			var eyes_off := Vector2(_main.fp.global_position.x - seat_w.x, _main.fp.global_position.z - seat_w.z).length()
			var body_off := Vector2(_main.player_body.position.x - seat_w.x, _main.player_body.position.z - seat_w.z).length()
			_check(absf(car_turn) > 0.4 and absf(look_turn - car_turn) < 0.03 and eyes_off < 0.3 and body_off < 0.3,
					"driving: the look turns with the car (%.1f degrees for the car's %.1f), and the eyes and the body sit on the driver's cell as drawn (%.2f and %.2f m from it; that cell is %.2f m from its square's middle; view %s)"
					% [rad_to_deg(look_turn), rad_to_deg(car_turn), eyes_off, body_off, seat_off, _main.view_mode])
		if steered != null:
			# (after the look check: first person while driving may ease the look back to the road)
			var dp := _main.key_menu.get("drive_pick") as OptionButton
			if dp != null and vv.has_method("off_squares"):   # the marks are never shown from the seat in first person
				dp.select(0)
				dp.item_selected.emit(0)
				await _frames(3)
				_marks_ok("driving: facing %.0f degrees, from the seat in first person" % face, steered, false)
				dp.select(1)
				dp.item_selected.emit(1)
				await _frames(3)
			await _top_drive_live()
			await _recentre_live()
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
	if views:
		var walking := func() -> bool: return _main.view_mode == walk_view
		_check(await _until(walking, SHOW_TIMEOUT_MS),
				"driving views: with the controls let go the view is the walking view again (%s)" % _main.view_mode)
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
		await _ride_passenger()
		await _cargo_seat_live(uid)
	var had_ride := _ride_hud() != null
	var step_out := _step_name(out - door)
	var here := _main.world.snapshot.player_pos
	for n in 6:   # onto the door's square, then out
		if _main.world.snapshot.vehicle_at(_main.world.snapshot.player_pos).is_empty():
			break
		await _turn(step_out)
	if had_ride:
		var gone := func() -> bool: return not (_main.get("ride_hud") as Control).visible
		_check(await _until(gone, SHOW_TIMEOUT_MS), "driving HUD: out of the car it is gone")
	await _cargo_trunk_live(uid, start)
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


## The marks on a turned car's real squares (lead-world's VehicleView.off_squares; nothing checked on a client
## without them). Off the axes: every square of `veh` whose own cell is drawn 0.25 m or more from it is marked, so
## is every square of it that blocks walking unless its own cell is drawn on it, nothing is marked that isn't one
## of its squares, a block stands on each marked square's middle, and the marks show (`shown`: whether they should,
## e.g. not from the seat in first person). On the axes nothing is marked.
func _marks_ok(what: String, veh: Snapshot.Vehicle, shown := true) -> void:
	var vv: VehicleView = _main.vehicles_view
	if not vv.has_method("off_squares") or not vv.has_method("frame_of"):
		return
	var car: Variant = (vv.get("_cars") as Dictionary).get(veh.uid)
	if car == null:
		_check(false, "%s: the car is drawn" % what)
		return
	var marked := {}
	for sq: Vector3i in car.marked:
		marked[sq] = true
	var marks: Node3D = car.marks
	var on_axes := absf(fposmod(veh.face_deg + 45.0, 90.0) - 45.0) < 0.01
	if on_axes:
		_check(marked.is_empty() and marks == null, "%s: a car on the axes has no marks (%d marked)" % [what, marked.size()])
		return
	var f: Transform3D = vv.call("pose_of", veh, _main.world)
	var snap: Snapshot = _main.world.snapshot
	var own := {}       # square -> metres its own cell is drawn from it (the nearest of its parts' cells)
	var squares := {}   # every square of the vehicle
	var cells := []     # every drawn cell's middle (x, z)
	for i in veh.part_count():
		var k := i * Snapshot.VPART_STRIDE
		var sq := veh.square(i)
		squares[sq] = true
		if (veh.parts[k + 4] & Snapshot.VPART_FILLER) != 0:
			continue
		var cell: Vector3 = f * Vector3(veh.parts[k], 0.0, veh.parts[k + 1])
		var c: Vector3 = _main.world.coords.ms_center_to_world(sq)
		cells.append(Vector2(cell.x, cell.z))
		own[sq] = minf(float(own.get(sq, INF)), Vector2(cell.x - c.x, cell.z - c.z).length())
	var unmarked_off := []      # drawn off its square (a gap filler's square: no cell drawn on it), not marked
	var unmarked_block := []    # ... and it blocks walking
	for sq: Vector3i in squares:
		var d := float(own.get(sq, INF))
		if not own.has(sq):   # a gap filler's square: the nearest cell of any part
			var c: Vector3 = _main.world.coords.ms_center_to_world(sq)
			for p: Vector2 in cells:
				d = minf(d, p.distance_to(Vector2(c.x, c.z)))
		if d >= 0.25 and not marked.has(sq):
			unmarked_off.append(sq)
			if VehicleView.blocks(snap, _main.world.tables, sq):
				unmarked_block.append(sq)
	var strays := marked.keys().filter(func(sq: Vector3i) -> bool: return not squares.has(sq))
	var blocks: MultiMesh = (marks.get_child(0) as MultiMeshInstance3D).multimesh if marks != null and marks.get_child_count() > 0 else null
	var signs: MultiMesh = (marks.get_child(1) as MultiMeshInstance3D).multimesh if marks != null and marks.get_child_count() > 1 else null
	# (how many are drawn; where each stands can't be read back in a headless run)
	var placed: bool = blocks != null and signs != null and blocks.instance_count == (car.marked as Array).size() \
			and signs.instance_count == (car.signed as Array).size()
	var blocking := squares.keys().filter(func(sq: Vector3i) -> bool: return VehicleView.blocks(snap, _main.world.tables, sq)).size()
	_check(not marked.is_empty() and unmarked_off.is_empty() and unmarked_block.is_empty() and strays.is_empty() and placed
			and marks.visible == shown,
			"%s: the car's real squares are marked: %d of its %d squares (%d of them block walking), %d with a sign; none drawn off its square is left out (%s), none marked outside the car (%s); a block and a sign drawn for each (%s); shown %s (wanted %s)"
			% [what, marked.size(), squares.size(), blocking, (car.signed as Array).size(), unmarked_off.slice(0, 3),
			strays.slice(0, 3), placed, marks.visible if marks != null else "no marks", shown])


## The top view while driving (lead-world's; skipped on a client without it): picked in F1, it looks at the car's
## middle and, once it has turned, along the car's heading; with F1's "north up" it settles looking north and still
## at the car. Then both pickers are put back.
func _top_drive_live() -> void:
	var vc: ViewCamera = _main.view_cam
	var km := _main.key_menu
	var drive_pick := km.get("drive_pick") as OptionButton
	var top_pick := km.get("top_pick") as OptionButton
	if not "top_yaw" in vc or drive_pick == null or top_pick == null:
		return
	var target := func() -> Transform3D: return _main.vehicles_view.call("chase_target", _main.world.snapshot)
	var aims_at := func() -> float:   # metres from the car's middle to where the camera's ray meets its floor
		var t: Transform3D = target.call()
		var o := vc.global_position
		var d := -vc.global_basis.z
		var hit := o + d * ((t.origin.y - o.y) / d.y) if absf(d.y) > 1e-3 else o
		return Vector2(hit.x - t.origin.x, hit.z - t.origin.z).length()
	drive_pick.select(2)
	drive_pick.item_selected.emit(2)
	await create_timer(2.5).timeout
	var goal: float = vc.call("heading_yaw", target.call())
	var turned := absf(wrapf(float(vc.get("top_yaw")) - goal, -PI, PI))
	var centred: float = aims_at.call()
	top_pick.select(1)
	top_pick.item_selected.emit(1)
	await create_timer(2.5).timeout
	var north := absf(wrapf(float(vc.get("top_yaw")), -PI, PI))
	var centred_north: float = aims_at.call()
	var north_saved := _cfg_text(UserFiles.at(km.hud_path), "view", "top_up")
	top_pick.select(0)
	top_pick.item_selected.emit(0)
	drive_pick.select(1)
	drive_pick.item_selected.emit(1)
	await _frames(3)
	_check(_main.view_mode == "chase" and turned < 0.05 and centred < 1.5 and absf(wrapf(goal, -PI, PI)) > 0.3
			and north < 0.05 and centred_north < 1.5 and north_saved == "north",
			"top view while driving: it looks at the car's middle (%.1f m off) along the car's heading (%.0f degrees; %.1f off); with \"%s\" (saved %s) it looks north (%.1f degrees off) and still at the car (%.1f m off)"
			% [centred, rad_to_deg(goal), rad_to_deg(turned), top_pick.get_item_text(1), north_saved, rad_to_deg(north), centred_north])


## First person while driving (lead-world's recentre; skipped on a client without it): with the look turned off the
## road it stays for the first second, then eases back toward the car's heading and level; while look input keeps
## coming it isn't pulled; with F1's "Recentre while driving" off it isn't pulled either. Then the pickers and the
## switch are put back.
func _recentre_live() -> void:
	var fp := _main.fp
	var km := _main.key_menu
	var drive_pick := km.get("drive_pick") as OptionButton
	var box := km.get("recentre_check") as CheckBox
	if not "look_idle" in fp or drive_pick == null or box == null or not _main.has_method("_recentre_goal"):
		return
	drive_pick.select(0)   # first person
	drive_pick.item_selected.emit(0)
	await _frames(3)
	var g: Variant = _main.call("_recentre_goal")
	if not (g is float or g is int):
		_check(false, "recentre: driving in first person there is a heading to come back to (view %s, goal %s)" % [_main.view_mode, g])
	else:
		var goal := float(g)
		var off := func() -> float: return absf(wrapf(fp.yaw - goal, -PI, PI))
		fp.look(Vector2.ZERO)
		fp.set_look(goal + 1.0, 0.4)
		await create_timer(1.0).timeout
		var held: float = off.call()          # before 1.5 s: where it was put
		await create_timer(2.5).timeout
		var eased: float = off.call()
		var level := absf(fp.pitch)
		fp.set_look(goal + 1.0, 0.4)
		for n in 12:                         # look input every quarter second: no pull
			fp.look(Vector2.ZERO)
			await create_timer(0.25).timeout
		var kept: float = off.call()
		box.button_pressed = false           # as a click: saved, and no pull at rest
		fp.look(Vector2.ZERO)
		fp.set_look(goal + 1.0, 0.4)
		await create_timer(3.0).timeout
		var off_kept: float = off.call()
		var off_saved := _cfg_flag(UserFiles.at(km.hud_path), "view", "recentre")
		box.button_pressed = true
		_check(absf(held - 1.0) < 0.02 and eased < 0.5 and level < 0.2 and absf(kept - 1.0) < 0.02
				and absf(off_kept - 1.0) < 0.02 and off_saved == "false",
				"recentre: driving in first person, a look turned 57 degrees off the road stays for a second (%.0f), then eases back (%.0f degrees off and %.0f up after 3.5 s); with look input coming it stays (%.0f); with \"%s\" off (saved %s) it stays (%.0f)"
				% [rad_to_deg(held), rad_to_deg(eased), rad_to_deg(level), rad_to_deg(kept), box.text, off_saved, rad_to_deg(off_kept)])
		fp.set_look(goal, 0.0)
	drive_pick.select(1)
	drive_pick.item_selected.emit(1)
	await _frames(3)


## The value saved under [section] key in the settings file at `path`, as text ("" when it isn't there).
func _cfg_flag(path: String, section: String, key: String) -> String:
	var cfg := ConfigFile.new()
	var v: Variant = cfg.get_value(section, key, null) if cfg.load(path) == OK else null
	return "" if v == null else str(v)


## The shown snapshot's vehicle `uid`, null when it isn't listed.
func _vehicle(uid: int) -> Snapshot.Vehicle:
	for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
		if veh.uid == uid:
			return veh
	return null


## The cargo row of vehicle `uid` on square `sq` in the shown snapshot ({} when none is listed, or on a client that
## doesn't read them).
func _cargo_row(uid: int, sq: Vector3i) -> Dictionary:
	var veh := _vehicle(uid)
	if veh == null or not veh.has_method("cargo_on"):
		return {}
	return veh.call("cargo_on", sq)


## Whether that row lists item handle `item`.
func _in_cargo(uid: int, sq: Vector3i, item: int) -> bool:
	var its: Variant = _cargo_row(uid, sq).get("items")
	if its is PackedInt64Array:
		for i in range(0, (its as PackedInt64Array).size() - 1, 2):
			if its[i] == item:
				return true
	return false


## One round through a cargo space next to the player (`what` names it; vehicle `uid`, square `sq`), by the
## client's own calls: a carried item is dropped into it (ItemActions.drop with cargo) and the snapshot's row lists
## it with more room used; the tray's list for that space has it; taken from there (ItemActions.take) it is carried
## again and the row no longer lists it.
func _cargo_round(what: String, uid: int, sq: Vector3i) -> void:
	var tray: Script = load("res://scripts/vr/item_tray.gd")
	var acts := _main.item_actions
	var row0 := _cargo_row(uid, sq)
	if row0.is_empty():
		_check(false, "car storage, %s: the snapshot lists the space next to the player (square %s)" % [what, sq])
		return
	if (row0.get("items", PackedInt64Array()) as PackedInt64Array).is_empty():
		await _cargo_e(what, uid, sq, true)
	if _main.hands.picker.carried().is_empty():
		var kits := _live.kits_given()
		_live.give_test_kit()
		_live.queue_action("pause")
		var kit_in := func() -> bool: return _live.kits_given() > kits and not _main.hands.picker.carried().is_empty()
		await _until(kit_in, OP_TIMEOUT_MS)
	var put: ItemRef = null
	var tried := 0
	for r: ItemRef in _main.hands.picker.carried().slice(0, 12):
		if put != null or acts.pending(r.uid) != "":
			continue
		tried += 1
		if not acts.call("drop", r, sq, Vector2(-1, -1), -1, true):
			continue
		var settled := func() -> bool: return acts.pending(r.uid) == "" or _in_cargo(uid, sq, r.uid)
		await _until(settled, 15000)
		var listed := func() -> bool: return _in_cargo(uid, sq, r.uid)
		if await _until(listed, 3000):
			put = r
	var row1 := _cargo_row(uid, sq)
	var src: Dictionary = tray.call("source_for_cargo", _main.world.snapshot, sq)
	var shown: Variant = tray.call("list", _main.world.snapshot, src) if not src.is_empty() else {}
	var in_tray: ItemRef = null
	if put != null and shown is Dictionary:
		for r: Variant in (shown as Dictionary).get("rows", []):
			if r is ItemRef and (r as ItemRef).uid == put.uid and (r as ItemRef).get("cargo") == true:
				in_tray = r
	_check(put != null and int(row1.get("used_ml", 0)) > int(row0.get("used_ml", 0)) and in_tray != null,
			"car storage, %s: a carried item put in by the client's drop is listed in the snapshot's row (%d of %d ml used, was %d; %d items) and in the tray's list for that space (items tried: %d)"
			% [what, row1.get("used_ml", -1), row1.get("capacity_ml", -1), row0.get("used_ml", -1),
			(row1.get("items", PackedInt64Array()) as PackedInt64Array).size() / 2, tried])
	if in_tray == null:
		return
	await _cargo_e(what, uid, sq, false)
	var sent: bool = acts.take(in_tray, "pack")
	var back := func() -> bool:
		return not _in_cargo(uid, sq, put.uid) and _main.hands.picker.carried().any(func(c: ItemRef) -> bool: return c.uid == put.uid)
	_check(sent and await _until(back, 15000),
			"car storage, %s: taken from the tray's list by the client's take it is carried again and the row no longer lists it (%d ml used now)"
			% [what, _cargo_row(uid, sq).get("used_ml", -1)])


## Car storage from a seat (skipped, said so, on a client that reads no cargo rows or a bridge that sends none): on
## the seat beside the driver's the snapshot lists the spaces in reach; with the fork's glovebox in the game's data
## one of them is the glovebox, ahead of that seat, and an item goes in and comes out of it (_cargo_round). Without
## a glovebox the round runs on the first space listed.
func _cargo_seat_live(uid: int) -> void:
	var veh := _vehicle(uid)
	if veh == null or not "cargo" in veh or not ResourceLoader.exists("res://scripts/vr/item_tray.gd") \
			or not (load("res://scripts/vr/item_tray.gd") as Script).get_script_method_list().any(
			func(m: Dictionary) -> bool: return m["name"] == "source_for_cargo"):
		print("  (this client reads no vehicle cargo: car storage not checked)")
		return
	var rows_in := func() -> bool: return _vehicle(uid) != null and not (_vehicle(uid).get("cargo") as Array).is_empty()
	if not await _until(rows_in, 5000):
		print("  (this bridge lists no cargo spaces next to the player: car storage not checked)")
		return
	veh = _vehicle(uid)
	var glovebox := _main.world.tables.index_of("vpart", "fp3d_glovebox")
	var sq := Vector3i.MAX
	var names := []
	for row: Dictionary in veh.get("cargo"):
		var part: int = row["part"]
		var type := veh.parts[part * Snapshot.VPART_STRIDE + 2]
		names.append(type)
		if glovebox >= 0 and type == glovebox:
			sq = veh.square(part)
	if glovebox >= 0:
		_check(sq != Vector3i.MAX and sq != _main.world.snapshot.player_pos,
				"car storage: from the seat beside the driver's the snapshot lists %d spaces in reach, the glovebox among them, ahead of the seat (at %s, the player on %s; part types %s)"
				% [(veh.get("cargo") as Array).size(), sq, _main.world.snapshot.player_pos, names])
	else:
		print("  (no glovebox in this game's data: the round runs on the first space listed)")
	if sq == Vector3i.MAX:
		sq = veh.square((veh.get("cargo") as Array)[0]["part"])
	await _cargo_round("the glovebox" if glovebox >= 0 else "a space by the seat", uid, sq)


## E on a cargo space (lead-ui's _open_cargo), in first person: the look is turned onto square `sq` at a few
## heights until the pointer's ray meets a part of vehicle `uid` there (printed, not failed, when it never does: the
## space can't be aimed at from here). Then E: `empty` true: it says the space is empty and opens nothing; else the
## tray opens on that square's space and its lid is noted; Esc closes both. The look and the mouse are put back.
func _cargo_e(what: String, uid: int, sq: Vector3i, empty: bool) -> void:
	if not _main.has_method("_open_cargo") or not _main._fp_active() or _main.view_mode != "first":
		return
	var mouse := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # the pointer is the middle of the screen
	var yaw0: float = _main.fp.yaw
	var pitch0: float = _main.fp.pitch
	var met := []
	var aimed := false
	for h: float in [1.0, 0.8, 0.6, 0.4, 1.2]:
		if aimed:
			break
		var aim := (_main.world.coords.ms_center_to_world(sq) + Vector3.UP * h - _main.fp.global_position).normalized()
		_main.fp.set_look(atan2(-aim.x, -aim.z), asin(clampf(aim.y, -1.0, 1.0)))
		await _frames(2)
		var hit: Dictionary = _main.call("_cast_screen", _main.call("_pointer"), false)
		met.append([h, hit.get("square"), str(hit.get("what", "")).left(40)])
		aimed = hit.get("hit", false) and hit.get("square") == sq and hit.get("vehicle") == uid
	if not aimed:
		print("    (car storage, %s: from %s the pointer meets no part on its square %s, so E on it is not checked; aimed at heights, it met: %s)"
				% [what, _main.world.snapshot.player_pos, sq, met])
	else:
		var whys := []
		var note_why := func(why: String) -> void: whys.append(why)
		_main.grab.tray.closed.connect(note_why)
		var on_it: bool = _main.call("_open_cargo")
		var at_once: bool = _main.grab.tray_open()
		var listed_then: Variant = load("res://scripts/vr/item_tray.gd").call("list", _main.world.snapshot,
				load("res://scripts/vr/item_tray.gd").call("source_for_cargo", _main.world.snapshot, sq), _main.world.tables)
		await process_frame
		var one_frame: bool = _main.grab.tray_open()
		await process_frame
		_main.grab.tray.closed.disconnect(note_why)
		if not empty:
			print("    (E on %s: tray open at once %s, a frame later %s, two frames later %s, closed because %s; the tray's list then: %s; player %s, in the main loop %s, menu open %s)"
					% [what, at_once, one_frame, _main.grab.tray_open(), whys, listed_then, _main.world.snapshot.player_pos,
					_main._in_main_loop(), [_main.key_menu.visible, _main.inspect.visible, _main.character.visible,
					_main.request_ui.visible, _main.vise_bench.visible, _main.main_menu != null, _main.vr != null]])
		var tray_open: bool = _main.grab.tray_open()
		var src: Variant = _main.grab.tray.get("source") if tray_open else {}
		var lid: Array = _main.get("_cargo_lid")
		var note := str(_main.grab.get("_flash"))
		var esc := InputEventKey.new()
		esc.keycode = KEY_ESCAPE
		esc.physical_keycode = KEY_ESCAPE
		esc.pressed = true
		root.push_input(esc)
		await _frames(3)
		var closed: bool = not _main.grab.tray_open() and (_main.get("_cargo_lid") as Array).is_empty()
		if _main.grab.tray_open():
			_main.grab.call("close_tray")
		var right: bool = (not tray_open and note.contains("Nothing in the")) if empty \
				else (tray_open and src is Dictionary and (src as Dictionary).get("square") == sq and lid.size() == 2 and lid[0] == uid)
		_check(on_it and closed and right,
				"car storage, %s: E with the pointer on it %s; Esc closes it (E on it %s, tray open %s, lid noted %s, note \"%s\", closed %s)"
				% [what, "says it is empty" if empty else "opens the tray on it and notes its lid", on_it, tray_open, lid, note, closed])
	_main.fp.set_look(yaw0, pitch0)
	Input.mouse_mode = mouse


## Car storage, the trunk (skipped as _cargo_seat_live; said so when the car has no trunk square with a square to
## stand on beside it): the player is put beside a trunk square, on open floor if there is some, else on a square of
## the car that doesn't block. An item goes in and comes out (_cargo_round, with E on it). Letting go over the trunk
## is a cargo target; over a square of the car without storage, or with another vehicle's uid, it is not. From
## `far` (the arrival square) no space of the car is listed and there is no target.
func _cargo_trunk_live(uid: int, far: Vector3i) -> void:
	var veh := _vehicle(uid)
	if veh == null or not "cargo" in veh or not _main.has_method("_open_cargo"):
		return
	var trunks := []
	var bare := Vector3i.MAX     # a square of the car with no cargo part
	var cargo_sq := {}
	for i in veh.part_count():
		var def: Variant = VehicleView.def_of(_main.world.tables, _main.world.snapshot, veh.parts[i * Snapshot.VPART_STRIDE + 2])
		if def != null and (def.flags as Dictionary).has("CARGO"):
			cargo_sq[veh.square(i)] = true
			if str(def.id).contains("trunk"):
				trunks.append(veh.square(i))
	for i in veh.part_count():
		if bare == Vector3i.MAX and not cargo_sq.has(veh.square(i)):
			bare = veh.square(i)
	var trunk := Vector3i.MAX
	var stand := Vector3i.MAX
	var snap: Snapshot = _main.world.snapshot
	for floor_only: bool in [true, false]:
		for t: Vector3i in trunks:
			for d: Vector3i in [Vector3i(-1, 0, 0), Vector3i(1, 0, 0), Vector3i(0, -1, 0), Vector3i(0, 1, 0)]:
				var at: Vector3i = t + d
				var free: bool = _floor_at(at) >= 0 if floor_only else (not snap.vehicle_at(at).is_empty() and not trunks.has(at)
						and not VehicleView.blocks(snap, _main.world.tables, at) and snap.creature_at(at) == null)
				if stand == Vector3i.MAX and free:
					trunk = t
					stand = at
	if stand == Vector3i.MAX:
		print("  (no trunk square of this car has a square to stand on beside it: the trunk not checked; trunk squares %s)" % [trunks])
		return
	var there := func() -> bool: return _main.world.snapshot.player_pos == stand and not _main.world.busy()
	var by: bool = await _cheat(_live.cheat_teleport(stand)) == "" and await _until(there, SHOW_TIMEOUT_MS)
	var listed := func() -> bool: return not _cargo_row(uid, trunk).is_empty()
	if not by or not await _until(listed, 5000):
		_check(false, "car storage: the player stands beside the trunk and the snapshot lists it (trunk %s, to stand on %s, player %s)"
				% [trunk, stand, _main.world.snapshot.player_pos])
		return
	await _cargo_round("the trunk", uid, trunk)
	# cargo targets: the trunk yes; a square without storage, another vehicle, or from far off: no
	var hands: Script = load("res://scripts/interaction/hands.gd")
	var yes := func(_u: int, _p: int) -> bool: return true
	snap = _main.world.snapshot
	var on_trunk: Dictionary = hands.call("cargo_target", snap, _main.world.tables, {"hit": true, "square": trunk, "vehicle": uid}, yes)
	var on_bare: Dictionary = hands.call("cargo_target", snap, _main.world.tables, {"hit": true, "square": bare, "vehicle": uid}, yes) \
			if bare != Vector3i.MAX else {}
	var other: Dictionary = hands.call("cargo_target", snap, _main.world.tables, {"hit": true, "square": trunk, "vehicle": uid + 1}, yes)
	var away := func() -> bool: return _main.world.snapshot.player_pos == far and not _main.world.busy()
	var gone: bool = await _cheat(_live.cheat_teleport(far)) == "" and await _until(away, SHOW_TIMEOUT_MS)
	var unlisted := func() -> bool: return _vehicle(uid) != null and (_vehicle(uid).get("cargo") as Array).is_empty()
	var off_list: bool = gone and await _until(unlisted, 5000)
	var from_far: Dictionary = hands.call("cargo_target", _main.world.snapshot, _main.world.tables,
			{"hit": true, "square": trunk, "vehicle": uid}, yes)
	_check(on_trunk.get("kind") == "cargo" and on_trunk.get("square") == trunk and on_bare.is_empty() and other.is_empty()
			and off_list and from_far.is_empty(),
			"car storage: letting go over the trunk is a cargo target (\"put it in the %s\"); over a square of the car without storage (%s) or with another vehicle's uid it is not; from the arrival square no space of the car is listed and there is no target (%s, %s, there %s, unlisted %s, %s)"
			% [on_trunk.get("name", "?"), bare, on_bare, other, gone, off_list, from_far])


## lead-ui's driving HUD (RideHud), when this client has it and the bridge sends player.vehicle_state while the player
## is on a vehicle; null otherwise.
func _ride_hud() -> Control:
	var h: Variant = _main.get("ride_hud")
	return (h as Control) if h is Control and _player_field("vehicle_state") is Dictionary else null


## The player's vehicle as lead-ui's RideInfo reads it from the shown snapshot, read afresh (the HUD keeps its own
## copy only while it shows); null on a client without it or while the snapshot has no vehicle_state.
func _ride_info() -> Variant:
	var snap: Snapshot = _main.world.snapshot
	var state: Variant = snap.get("player_vehicle_state")
	if not state is Dictionary or (state as Dictionary).is_empty() or not ResourceLoader.exists("res://scripts/hud/ride_info.gd"):
		return null
	var face := NAN
	for veh: Snapshot.Vehicle in snap.vehicles:
		if veh.uid == snap.get("player_vehicle"):
			face = veh.face_deg
	var names := Callable(_main, "_itype_name") if _main.has_method("_itype_name") else Callable()
	return load("res://scripts/hud/ride_info.gd").call("read", state, names, face)


## The driving HUD's rect on screen (its dash, scaled as it is drawn).
func _ride_rect(hud: Control) -> Rect2:
	var d := hud.get("dash") as Control
	return d.get_global_transform() * Rect2(Vector2.ZERO, d.size) if d != null else Rect2()


## The driving HUD, parked: on the controls' square before the controls are taken it reads the car as CDDA has it
## (its name, engine off, standing, the set speed at rest, every fuel full, the battery full, health 100 "like new",
## a car's mass). Whether it shows there in first person is printed with it.
func _ride_parked(car: Snapshot.Vehicle) -> void:
	var hud := _ride_hud()
	if hud == null:
		print("  (no driving HUD in this client, or no vehicle_state from this bridge: the driving HUD not checked)")
		return
	var read := func() -> bool:
		var now: Variant = _ride_info()
		return now != null and now.ok and now.at_controls
	await _until(read, SHOW_TIMEOUT_MS)
	var i: Variant = _ride_info()
	if i == null:
		_check(false, "driving HUD: on the controls' square the snapshot has the car's numbers")
		return
	var fuels: Array = i.fuels
	var full: bool = not fuels.is_empty() and fuels.all(func(f: Dictionary) -> bool: return f["left"] == f["cap"])
	_check(i.ok and not i.driver and i.at_controls and not i.engine_on and i.velocity == 0 and i.set_speed() == 0
			and i.name == car.name and full and i.battery_cap > 0 and i.battery_left == i.battery_cap and i.health == 100
			and i.health_word() == "like new" and i.mass_kg > 500 and i.mass_kg < 3000,
			"driving HUD: parked at the controls it reads the car: \"%s\" (the snapshot's \"%s\"), engine on %s, speed %d, set speed %d, %s full %s, battery %d of %d, health %d%% (%s), %d kg; shown in first person before the controls are taken: %s"
			% [i.name, car.name, i.engine_on, i.velocity, i.set_speed(), fuels.map(func(f: Dictionary) -> String: return str(f["name"])),
			full, i.battery_left, i.battery_cap, i.health, i.health_word(), i.mass_kg, hud.visible])


## The driving HUD after the forward key: the set speed is there, in CDDA's unit, while the car still does less; the
## engine is on.
func _ride_set_speed() -> void:
	var hud := _ride_hud()
	if hud == null:
		return
	var set := func() -> bool:
		var now: Variant = _ride_info()
		return now != null and now.driver and now.cruise > 0
	var is_set := await _until(set, SHOW_TIMEOUT_MS)
	var i: Variant = _ride_info()
	_check(is_set and i != null and i.engine_on and i.set_speed() == i.cruise and absi(i.velocity) < i.cruise,
			"driving HUD: after the forward key twice the set speed is %.0f %s while the car does %.0f; the engine is on (safe %.0f, top %.0f %s)"
			% [i.shown(i.cruise), i.unit, i.shown(i.velocity), i.shown(i.safe), i.shown(i.top), i.unit])


## The driving HUD at 1280x720 and 800x450, while driving: in the window and clear of the HUD's text, the left
## column and the hands panel; F1's "Driving gauge" box hides it and shows it again. The compass reads the camera
## that draws the screen. Then the window is as it was.
func _ride_sizes() -> void:
	var hud := _ride_hud()
	if hud == null:
		return
	if not hud.visible:
		_check(false, "driving HUD: it shows while driving in the %s view" % _main.view_mode)
		return
	var was: Vector2i = root.size
	for hands: String in ["empty hands", "something held"]:
		if hands == "something held" and not await _hold_something():
			print("  (nothing could be put into a hand: the driving HUD beside the hands panel not checked)")
			break
		for s: Vector2i in [Vector2i(1280, 720), Vector2i(800, 450)]:
			root.size = s
			await _frames(4)
			await create_timer(0.6).timeout
			var r := _ride_rect(hud)
			var keep := [_main.hud.get_global_rect(), _main.hud_view.call("column_rect")]
			if _main.hands_panel.visible:
				keep.append(_main.hands_panel.get_global_rect())
			var over := keep.filter(func(k: Rect2) -> bool: return k.has_area() and k.intersects(r))
			_check(hud.visible and r.has_area() and Rect2(Vector2.ZERO, Vector2(s)).grow(1.0).encloses(r) and over.is_empty()
					and _main.hands_panel.visible == (hands == "something held"),
					"driving HUD %dx%d, %s: in the window and clear of the HUD's text, the left column and the hands panel (the HUD at %s; the hands panel %s; the feed %s; overlapping: %s)"
					% [s.x, s.y, hands, r, _main.hands_panel.get_global_rect() if _main.hands_panel.visible else "hidden",
					_main.hud_view.call("feed_rect") if _main.hud_view.has_method("feed_rect") else "?", over])
	root.size = was
	await _frames(4)
	_main.vehicles_view.call("glide", 10.0)   # (the kit's turn rolled the car on: its node up to date again)
	var box := _main.key_menu.get("ride_check") as CheckBox
	if box != null:
		box.button_pressed = false
		await _frames(2)
		var hidden := not hud.visible
		box.button_pressed = true
		await _frames(2)
		_check(hidden and hud.visible, "driving HUD: F1's \"%s\" off hides it, on shows it again" % box.text)
	var cam := _main.get_viewport().get_camera_3d()
	if cam != null and _main.has_method("drawn_view"):
		var want := Compass.heading_of(cam.global_basis)
		_check(absf(wrapf(_main.compass.heading_deg - want, -180.0, 180.0)) < 1.0,
				"compass: it reads the camera on screen (%.0f degrees in the %s view; the eyes look %.0f)"
				% [_main.compass.heading_deg, _main.view_mode, Compass.heading_of(_main.fp.global_basis)])


## Puts a carried item into the off hand so the hands panel shows (the test kit is asked for first: a turn passes).
## True once the panel shows.
func _hold_something() -> bool:
	if _main.hands_panel.visible:
		return true
	var kits := _live.kits_given()
	if not _live.give_test_kit():
		return false
	_live.queue_action("pause")
	var kit_in := func() -> bool: return _live.kits_given() > kits and not _main.hands.picker.carried().is_empty()
	if not await _until(kit_in, OP_TIMEOUT_MS):
		return false
	var shows := func() -> bool: return _main.hands_panel.visible
	for r: ItemRef in _main.hands.picker.carried().slice(0, 8):
		if _main.item_actions.hold(r, "off") and await _until(shows, 8000):
			return true
	return false


## The driving HUD on a seat without controls: a passenger's (the name, no engine line), shown in first person.
func _ride_passenger() -> void:
	var hud := _ride_hud()
	if hud == null:
		return
	await _frames(3)
	var i: Variant = _ride_info()
	if i == null:
		_check(false, "driving HUD: on the seat beside the driver's the snapshot has the car's numbers")
		return
	var name_l := hud.get("name_label") as Label
	var engine_l := hud.get("engine_label") as Label
	_check(i.ok and not i.driver and not i.at_controls and hud.visible and name_l != null and name_l.text.contains(i.name)
			and (engine_l == null or not engine_l.is_visible_in_tree()),
			"driving HUD: on the seat beside the driver's it is a passenger's: the name (\"%s\") and no engine line (in control %s, at controls %s, shown %s, engine line %s)"
			% [name_l.text if name_l != null else "?", i.driver, i.at_controls, hud.visible,
			engine_l.is_visible_in_tree() if engine_l != null else "none"])


## The text saved under [section] key in the settings file at `path`; "" when it isn't a string there.
func _cfg_text(path: String, section: String, key: String) -> String:
	var cfg := ConfigFile.new()
	var v: Variant = cfg.get_value(section, key, "") if cfg.load(path) == OK else ""
	return v if v is String else ""


## The chase camera at something solid (lead-world's driving views; skipped, said so, on a client without them).
## The camera's own free-way probe looks along the four axes from the arrival square, at the boom's height, for
## something solid 10 to 40 m away. A car's pose is then given to the camera by hand (no car is there): 3 m in front
## of that wall heading away from it, and at the arrival square with the same heading. At the wall the boom is
## pulled in and the camera stays on this side of it; at the arrival square it is out further.
func _chase_wall_live(start: Vector3i) -> void:
	var vc: ViewCamera = _main.view_cam
	if not "chase_heading" in vc or not vc.blocked.is_valid():
		print("  (no chase view in this client: the chase camera at a wall not checked)")
		return
	var k: Dictionary = (vc.get_script() as Script).get_script_constant_map()
	var pivot_up := Vector3.UP * float(k.get("CHASE_PIVOT_UP", 2.4))
	var back := float(k.get("CHASE_BACK", 7.0))
	var floor_w: Vector3 = _main.world.coords.ms_center_to_world(start)
	var wall_dir := Vector3.ZERO
	var free_m := INF
	for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]:
		var f: Variant = vc.blocked.call(floor_w + pivot_up, floor_w + pivot_up + dir * 40.0)
		if (f is float or f is int) and float(f) > back + 3.0 and float(f) < 40.0 and float(f) < free_m:
			free_m = float(f)
			wall_dir = dir
	if wall_dir == Vector3.ZERO:
		print("  (the camera's probe meets nothing solid 10 to 40 m from the arrival square at the boom's height: the chase camera at a wall not checked)")
		return
	var was_mode: String = vc.mode
	var was_car: Variant = vc.get("car")
	var ahead := -wall_dir
	var cam_for := func(mid: Vector3) -> Vector3:   # where the chase camera goes for a car at `mid` heading `ahead`
		vc.set("car", func() -> Variant: return Transform3D(Basis(ahead, Vector3.UP, ahead.cross(Vector3.UP)), mid))
		vc.set("chase_heading", NAN)
		vc.mode = "chase"
		vc.call("follow", 0.0)
		return vc.global_position
	var near_mid := floor_w + wall_dir * (free_m - 3.0)
	var cam_wall: Vector3 = cam_for.call(near_mid)
	var cam_open: Vector3 = cam_for.call(floor_w)
	vc.mode = was_mode
	vc.set("car", was_car)
	_main._set_view(_main.view_mode)
	var boom_wall := (near_mid + pivot_up).distance_to(cam_wall)
	var boom_open := (floor_w + pivot_up).distance_to(cam_open)
	var this_side := (cam_wall - floor_w).dot(wall_dir) < free_m
	_check(boom_wall < boom_open - 1.5 and this_side and cam_wall.is_finite() and cam_open.is_finite(),
			"chase camera: with something solid 3 m behind the car the boom is pulled in to %.1f m and the camera stays on this side of it; with %.0f m free behind it is out %.1f m"
			% [boom_wall, free_m, boom_open])


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
	# the ride at the end: none left; with one rigid model it seats the eyes on the driver's cell as drawn (off the
	# axes not the square's middle), with no turn left, and the model never stretches or shears on the way
	var rigid := vv.has_method("seat_transform")
	var arrived: bool = ride1.is_equal_approx(Transform3D()) if not rigid else (ride1.basis.is_equal_approx(Basis())
			and not ride0.is_equal_approx(ride1) and _rigid(a1.basis) and _rigid(end.basis))
	var ok := d0 > 0.5 and d1 < d0 and d1 > 0.0 and not ride0.is_equal_approx(Transform3D()) \
			and end.is_equal_approx(pose) and arrived \
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
	var vv: VehicleView = _main.vehicles_view
	if vv.has_method("seat_transform"):
		# one rigid model (lead-world, C5 slice 4): turned by CDDA's facing, not laid out on CDDA's stepped squares
		var f: Transform3D = vv.call("frame_of", veh, _main.world.coords)
		var on_axes := absf(fposmod(veh.face_deg + 45.0, 90.0) - 45.0) < 0.01
		var far := float(worst[0][2])
		var half := worst.filter(func(r: Array) -> bool: return float(r[2]) > 0.5).size()
		var whole := worst.filter(func(r: Array) -> bool: return float(r[2]) > 1.0).size()
		_check(_rigid(f.basis) and far <= (0.05 if on_axes else 2.6),
				"%s: the car is one rigid model, %s (%d of its %d cells over 0.5 m off, %d over 1 m; the farthest, as [mount, square, m]: %s)"
				% [what, "every cell on its square" if on_axes else "its cells up to %.2f m from CDDA's squares" % far,
				half, worst.size(), whole, worst.slice(0, 2)])
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


## For a report: the cells of `veh` by how far their place in its drawn grid (VehicleView.frame_of) is from the
## square CDDA has the part on, farthest first: [[mount, the square's offset from the vehicle's position, metres
## apart], ...].
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
	return rows


## Whether basis b turns without stretching or shearing (its level axes at right angles and of one length).
func _rigid(b: Basis) -> bool:
	return absf(b.x.normalized().dot(b.z.normalized())) < 1e-3 and absf(b.x.length() - b.z.length()) < 1e-3


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
