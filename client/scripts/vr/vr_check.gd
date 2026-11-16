class_name VrCheck
extends Node
## Automated checks inside a real VR session (`-- --vr --vr-check=<names>`, e.g. under SteamVR's null headset,
## TASKS "VR without a headset"): once the world is up and the session has drawn frames, each named scenario runs
## on the live rig and prints `vr check ok: ...` / `vr check FAIL: ...` lines, then a summary line
## `vr check: N ok, M failed`, and the game quits (main.gd `_quit`). The lines also go to user://vr_check.log.
## There are no controllers under the null headset: the rig counts its hands as tracked and the scenario places them.
## Scenarios: "report" (the bug report row saves a text and a picture of the view); "loot" (mock mode: a dresser
## with a rock in it next to the player; the right hand pulls a drawer open by its handle and takes the rock, L8).

const LOG_PATH := "user://vr_check.log"
const START_FRAMES := 30          # frames drawn before the first scenario
const MAX_WAIT_S := 120.0         # for the world to come up

var rig: VrRig
var quit := Callable()            # main.gd's _quit
var mock_of := Callable()         # () -> MockItems: main.gd's in mock mode (no --live), else null
var oks := 0
var fails := 0
var _log: FileAccess


func run(names: String) -> void:
	_log = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	var t := 0.0
	while rig.world.snapshot == null and t < MAX_WAIT_S:
		await get_tree().process_frame
		t += get_process_delta_time()
	for k in START_FRAMES:
		await get_tree().process_frame
	rig.assume_tracked = true
	for n in names.split(",", false):
		match n.strip_edges():
			"report":
				await _report()
			"loot":
				await _loot()
			var other:
				_check(false, "unknown scenario '%s'" % Snapshot.plain_text(other, 40))
	_line("vr check: %d ok, %d failed" % [oks, fails])
	if _log != null:
		_log.close()
	if quit.is_valid():
		quit.call()


func _check(ok: bool, what: String) -> void:
	if ok:
		oks += 1
	else:
		fails += 1
	_line(("vr check ok: " if ok else "vr check FAIL: ") + what)


func _line(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)


## The menu's "Report a bug": a new report with a picture that isn't one flat colour.
func _report() -> void:
	var before := _reports()
	rig.report_bug()
	var path := ""
	for k in 240:
		await get_tree().process_frame
		for n in _reports():
			if n.ends_with(".png") and not before.has(n):
				path = VrReport.DIR + "/" + n
		if not path.is_empty():
			break
	var img: Image = Image.load_from_file(path) if not path.is_empty() else null
	var varied := false
	if img != null and not img.is_empty():
		var c0 := img.get_pixel(0, 0)
		for k in 64:
			var p := img.get_pixel(int(img.get_width() * ((k % 8) + 0.5) / 8.0), int(img.get_height() * (floori(k / 8.0) + 0.5) / 8.0))
			if not p.is_equal_approx(c0):
				varied = true
				break
	_check(img != null and varied, "report: a bug report with a picture of the view (%s)" % path)


## L8: puts a dresser with a rock in it on a free square next to the one the hands reach from (mock VR: the
## headset's, beside the player; mock mode only: the client's own copy of the snapshot), then works the right
## controller as a hand would (no controllers under the null headset): grip at a drawer's handle, pull it out, let
## go; grip inside the open drawer takes the rock into the hand.
func _loot() -> void:
	var w := rig.world
	var snap := w.snapshot
	var mock: MockItems = mock_of.call() if mock_of.is_valid() else null
	var centre: Variant = rig.hands.picker.centre()
	var e := Vector3i(-1073741824, 0, 0)   # none yet
	for d: Vector3i in [Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0)]:
		if centre is Vector3i and (centre as Vector3i) + d != snap.player_pos and rig.walk.can_stand((centre as Vector3i) + d):
			e = (centre as Vector3i) + d
			break
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(e)) if mock != null else null
	var rock := w.tables.index_of("itype", "rock")
	var dresser := w.tables.index_of("furn", "f_dresser")
	if sm == null or rock < 1 or dresser < 1:
		_check(false, "loot: needs mock mode (no --live) and a free square within reach")
		return
	var tile := ItemActions.tile_of(e)
	sm.furn[tile] = dresser
	var piles := PackedInt32Array()
	for p in range(0, sm.items.size() - Snapshot.PILE_STRIDE + 1, Snapshot.PILE_STRIDE):
		if sm.items[p] != tile:
			piles.append_array(sm.items.slice(p, p + Snapshot.PILE_STRIDE))
	var pile := PackedInt32Array()
	pile.resize(Snapshot.PILE_STRIDE)
	pile[0] = tile
	pile[1] = 1
	pile[2] = rock
	piles.append_array(pile)
	sm.items = piles
	var hs := PackedInt64Array()
	for i in range(0, sm.handles.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if sm.handles[i] != tile:
			hs.append_array(sm.handles.slice(i, i + Snapshot.HANDLE_STRIDE))
	sm.handles = hs
	mock.seed()
	var uid := -1
	for i in range(0, sm.handles.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if sm.handles[i] == tile:
			uid = sm.handles[i + 1]
	sm.revision = (sm.revision + 1) & Snapshot.MAX_REVISION   # its furniture changed: the world rebuilds it
	snap.seq += 1
	mock.changed.emit(snap)   # as MockItems does after a change: main.gd shows it again
	var g: Grabbable = null
	for k in 300:
		await get_tree().process_frame
		var s: Array = w._slot_of.get(uid, [])
		if not s.is_empty() and (s[1] as Array).size() >= 8:
			g = w.parts.get(s[1][6]) as Grabbable
		if g != null:
			break
	if g == null:
		var s0: Array = w._slot_of.get(uid, [])
		_check(false, "loot: the dresser's drawers didn't come (rock %d, slot %s, drawer part %s, furniture %s)" % [uid,
				Snapshot.plain_text(str(s0[1].slice(6)) if not s0.is_empty() else "none", 120),
				w.parts.has("%d_%d_%d/drawer_1" % [e.x, e.y, e.z]), w.snapshot.submaps[CddaCoords.ms_to_sm(e)].furn[tile] == dresser])
		return
	var c := rig.right
	var tracker := c.tracker
	c.tracker = &"vr_check"   # no such tracker: the runtime leaves the controller where the check puts it
	var h0 := g.handle_point()
	var out := g.global_transform.basis * g.axis
	c.global_position = h0
	await get_tree().process_frame
	var near := rig.hands.find_near(c.global_position, VrRig.GRAB_REACH)
	var state := "near %s, in reach %s" % [near.get("kind", "nothing"), rig.hands.picker.in_reach(g.square)]
	rig.press(c, "grip_click")
	var took := str(rig.hands.holding("vr_r").get("kind", "nothing")) + "; " + state
	for k in 30:
		c.global_position = h0 + out * (0.03 * k)   # 0.87 m: past any drawer's travel
		await get_tree().process_frame
	var moved := c.global_position.distance_to(h0 + out * 0.87)
	rig.release(c, "grip_click")
	await get_tree().process_frame
	var slot := w.item_slot(uid)
	_check(g.open_amount() > 0.99 and not slot.is_empty(),
			"loot: the right hand pulls a drawer open by its handle (%.2f open; grip took %s, hand %.2f m off)"
			% [g.open_amount(), Snapshot.plain_text(took, 200), moved])
	if slot.is_empty():
		c.tracker = tracker
		return
	c.global_position = slot[3]
	await get_tree().process_frame
	rig.press(c, "grip_click")
	var held := {}
	for k in 60:
		await get_tree().process_frame
		held = rig.hands.holding("vr_r")
		if not held.is_empty():
			break
	var it: Variant = held.get("item")
	_check(it is ItemRef and (it as ItemRef).uid == uid and (it as ItemRef).is_wielded(),
			"loot: a grip inside the open drawer takes the rock into the hand (%s)" % Snapshot.plain_text(str(held.get("kind", "nothing")), 16))
	rig.release(c, "grip_click")
	c.tracker = tracker


func _reports() -> PackedStringArray:
	return DirAccess.get_files_at(VrReport.DIR) if DirAccess.dir_exists_absolute(VrReport.DIR) else PackedStringArray()
