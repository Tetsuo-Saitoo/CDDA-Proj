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


## The range's vehicle spawn through the client (the bridge's range_spawn_vehicle; skipped, said so, on a bridge
## without it): a car facing 45 degrees on the first of a few squares round the arrival square `start` where the
## game takes it. The snapshot then lists one vehicle more, facing 45, and it is drawn on its squares (_vehicles_ok:
## a vehicle off the axes). On the player's own square, or with an id that is no prototype, the game refuses in its
## words; a facing of 360 or an overlong id isn't sent.
func _spawn_vehicle_live(start: Vector3i) -> void:
	if not _live.sim().has_method("range_spawn_vehicle"):
		print("  (no vehicle spawn in this bridge: not checked)")
		return
	var before := {}
	for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
		before[veh.uid] = true
	var tried := []
	var placed := false
	for d: Vector3i in [Vector3i(14, 14, 0), Vector3i(14, -14, 0), Vector3i(-14, -14, 0), Vector3i(-18, 18, 0),
			Vector3i(22, 0, 0), Vector3i(0, 22, 0), Vector3i(0, -22, 0), Vector3i(-22, 0, 0), Vector3i(30, 30, 0)]:
		var why := await _cheat(_spawn_vehicle("car", start + d, 45))
		tried.append([d, why])
		if why == "":
			placed = true
			break
	var fresh := func() -> Snapshot.Vehicle:
		for veh: Snapshot.Vehicle in _main.world.snapshot.vehicles:
			if not before.has(veh.uid):
				return veh
		return null
	var listed := func() -> bool: return fresh.call() != null and not _main.world.busy()
	var seen := placed and await _until(listed, SHOW_TIMEOUT_MS)
	var car: Snapshot.Vehicle = fresh.call()
	_check(seen and car != null and is_equal_approx(car.face_deg, 45.0) and car.part_count() > 20,
			"vehicle spawn: a car facing 45 degrees is placed and the snapshot lists it (%s parts, facing %s; tried %s)"
			% [car.part_count() if car != null else 0, car.face_deg if car != null else "?", tried])
	if seen:
		_vehicles_ok("a car spawned facing 45 degrees")
	var on_me := await _cheat(_spawn_vehicle("car", _main.world.snapshot.player_pos, 0))
	var unknown := await _cheat(_spawn_vehicle("car_nope", start + Vector3i(0, 30, 0), 0))
	_check(on_me.contains("in the way") and unknown == "No such vehicle.",
			"vehicle spawn: refused in the game's words on the player's square (\"%s\") and for an id that is no prototype (\"%s\")"
			% [on_me, unknown])
	_check(_spawn_vehicle("car", start + Vector3i(0, 30, 0), 360) == 0
			and _spawn_vehicle("a".repeat(65), start + Vector3i(0, 30, 0), 0) == 0,
			"vehicle spawn: a facing of 360 or an overlong id isn't sent")


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
