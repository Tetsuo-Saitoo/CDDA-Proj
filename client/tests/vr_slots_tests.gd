extends RefCounted
## Block L8 slice 5 (VR): body slots (VrSlots on VrRig) on the mock town with MockItems answering inside each call.
## The worn holster and sheath sit at the hips and the pouch on the chest; the biggest bag stays the shoulder's. A
## hand coming to a slot ticks once and shows its ring and line. Grip at the sheath takes the knife (nothing sent),
## let go there puts it back (nothing sent), and carried away it is held in that hand. A world item let go at the
## pouch goes in; a refused put buzzes with CDDA's reason. The wielded gun's grip let go at the holster holsters
## it; a slot with nothing in it leaves the grip to what lies nearby. No XR runtime: the test moves the controllers
## and presses buttons. Run by run_tests.gd.

const P := Vector3i(192, 384, 0)       # the mock town's player
const E := P + Vector3i(1, 0, 0)       # pile: rock, hammer, plank
const BAG := 910                       # worn canvas sack (the biggest: the shoulder's)
const HOL := 911                       # worn holster (empty)
const POUCH := 912                     # worn leather pouch (empty)
const SHEATH := 913                    # worn sheath: the knife
const KNIFE := 914
const GUN := 915                       # in the bag; flagged wielded for the holster test
const CS := Snapshot.CARRIED_STRIDE

var _check: Callable
var _it := {}   # itype id -> index
var _tables: IdTables
var _snap: Snapshot
var _mock: MockItems
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _rig: VrRig
var _old := {}  # itype index -> its pockets before the test
var _had_pockets := false


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_tables = tables
	print("vr slots")
	for id: String in ["rock", "hammer", "2x4", "bag_canvas", "holster", "leather_pouch", "sheath", "knife_combat", "glock_19"]:
		_it[id] = tables.index_of("itype", id)
		if _it[id] <= 0:
			_check.call(false, "vr slots: the mock tables have " + id)
			return
	_pockets(tables)
	if _setup(root, data):
		_test_layout()
		_test_hover()
		_test_take_and_back()
		_test_quick_switch()
		_test_put_in()
		_test_refused()
		_test_gun()
		_rig.free()
		_hands.free()
		_actions.free()
		_world.free()
	for t: int in _old:
		tables.def_at("itype", t).pockets = _old[t]
	tables.has_pockets = _had_pockets


## The test's pockets (the mock tables send none): holster and sheath one holster pocket each, the pouch and the
## sack plain ones.
func _pockets(tables: IdTables) -> void:
	_had_pockets = tables.has_pockets
	tables.has_pockets = true
	var plain := {"name": "", "volume_ml": 1000, "max_weight_g": 5000, "max_item_ml": -1, "flags": 0}
	var holster := {"name": "", "volume_ml": 800, "max_weight_g": 2000, "max_item_ml": -1, "flags": IdTables.POCKET_HOLSTER}
	for id: String in ["bag_canvas", "holster", "leather_pouch", "sheath"]:
		var d: IdTables.Def = tables.def_at("itype", _it[id])
		_old[_it[id]] = d.pockets
		var p: Array[Dictionary] = [holster.duplicate() if id in ["holster", "sheath"] else plain.duplicate()]
		if id == "bag_canvas":
			p.append(plain.duplicate())
		d.pockets = p


func _setup(root: Node, data: Variant) -> bool:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[1, 3, [_it["rock"], _it["hammer"], _it["2x4"]]]]
		elif at in [Vector3i(15, 32, 0), Vector3i(15, 31, 0), Vector3i(16, 31, 0)]:
			sm["items"] = []
		else:
			continue
		sm.erase("handles")
	(d["player"] as Dictionary)["items"] = [   # worn inner to outer
		[SHEATH, _it["sheath"], 0, -1, Snapshot.CARRIED_WORN],
		[KNIFE, _it["knife_combat"], SHEATH, 0, 0],
		[POUCH, _it["leather_pouch"], 0, -1, Snapshot.CARRIED_WORN],
		[HOL, _it["holster"], 0, -1, Snapshot.CARRIED_WORN],
		[BAG, _it["bag_canvas"], 0, -1, Snapshot.CARRIED_WORN],
		[GUN, _it["glock_19"], BAG, 1, 0],
	]
	_snap = Snapshot.from_data(d)
	_check.call(_snap.is_valid() and _snap.player_pos == P and _snap.carried.size() == 6 * CS,
			"vr slots: test town loads with a sheath, a pouch, a holster and a sack worn " + _snap.error)
	if not _snap.is_valid():
		return false
	_mock = MockItems.new(_snap, _tables)
	_mock.seed()
	_world = WorldView.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(_tables)
	root.add_child(_world)
	_world.apply_snapshot(_snap)
	_actions = ItemActions.new()
	_actions.backend = _mock
	_mock.changed.connect(func(s: Snapshot) -> void:
		_world.apply_snapshot(s)
		_actions.on_snapshot(s))
	_mock.message.connect(func(t: String) -> void: _actions.on_events([MockItems.message_event(t)]))
	_actions.on_snapshot(_snap)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	_rig.hands = _hands
	root.add_child(_rig)
	_rig.camera.position = Vector3(0, 1.6, 0)
	_rig.go_to_square(P)
	_away()
	_rig.update_hands(0.016, true)
	return true


## Both hands out in front at arm's length (no slot, nothing lying there).
func _away() -> void:
	var h := _rig.camera.global_position
	_rig.left.global_position = h + Vector3(-0.2, -0.3, -0.6)
	_rig.right.global_position = h + Vector3(0.2, -0.3, -0.6)


func _slot(uid: int) -> Vector3:
	return _rig.slots.point_of(uid)


## [parent, flags, pocket] of carried item `uid`, [] when it isn't carried.
func _row(uid: int) -> Array:
	var c := _snap.carried
	for i in range(0, c.size() - CS + 1, CS):
		if c[i] == uid:
			return [c[i + 2], c[i + 4], c[i + 3]]
	return []


## Uid of the first handle of `type` on square p, -1 if none.
func _handle(p: Vector3i, type: int) -> int:
	var h := (_snap.submaps[CddaCoords.ms_to_sm(p)] as Snapshot.Submap).handles
	for i in range(0, h.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		if h[i] == ItemActions.tile_of(p) and h[i + 2] == type:
			return h[i + 1]
	return -1


func _mid(uid: int) -> Vector3:
	var s := _world.item_slot(uid)
	return s[3] if not s.is_empty() else Vector3.INF


func _clean() -> bool:
	return _world.hidden_items.is_empty() and _actions.pending_count() == 0 and _hands.proxy("vr_l") == null \
			and _hands.proxy("vr_r") == null and _hands.holding("vr_l").is_empty() and _hands.holding("vr_r").is_empty()


func _test_layout() -> void:
	var s := _rig.slots
	var got: Array = s.slots.map(func(e: Dictionary) -> Array: return [e["uid"], e["anchor"], e["holster"]])
	var bag := VrRig.shoulder_bag(_hands.picker.worn_containers(), null, _tables)
	_check.call(bag != null and bag.uid == BAG and got == [[HOL, 0, true], [POUCH, 4, false], [SHEATH, 1, true]],
			"vr slots: the holster at the main hip, the pouch on the chest, the sheath at the other hip; the sack stays the shoulder's (%s)" % [got])
	var cam := _rig.camera.global_position
	var floor_y := _rig.global_position.y
	var hip := _slot(HOL)
	var other := _slot(SHEATH)
	var chest := _slot(POUCH)
	_check.call(hip.x > cam.x + 0.15 and other.x < cam.x - 0.15 and is_equal_approx(hip.y, floor_y + 0.52 * 1.6)
			and chest.y > hip.y and chest.z < hip.z and VrSlots.is_holster(_it["sheath"], _tables)
			and not VrSlots.is_holster(_it["leather_pouch"], _tables) and not VrSlots.is_holster(_it["rock"], _tables),
			"vr slots: places follow the head: hips at the sides at half its height, the chest higher and in front (%s %s %s)" % [hip, other, chest])
	_rig.settings["main_hand"] = "left"
	_rig.update_hands(0.016, true)
	var flipped := _slot(HOL).x < cam.x - 0.15
	_rig.settings["main_hand"] = "right"
	_rig.update_hands(0.016, true)
	_check.call(flipped and _slot(HOL).x > cam.x + 0.15, "vr slots: left-handed, the main hip is the left one")


func _test_hover() -> void:
	var s := _rig.slots
	var b := _rig.buzzes[1]
	_rig.right.global_position = _slot(HOL)
	_rig.update_hands(0.016, true)
	var k := s.slot_at(_slot(HOL))
	var ring := s.ring_of(k)
	var label := s.label_of(k)
	var shown := s.at[1] == k and _rig.buzzes[1] == b + 1 and ring != null and ring.visible and label.visible \
			and label.text == "Holster: empty"
	_rig.update_hands(0.016, true)
	var once := _rig.buzzes[1] == b + 1
	_rig.left.global_position = _slot(SHEATH)
	_rig.update_hands(0.016, true)
	var ks := s.slot_at(_slot(SHEATH))
	var line: String = s.label_of(ks).text if s.label_of(ks) != null else ""
	_away()
	_rig.update_hands(0.016, true)
	_check.call(shown and once and line.begins_with("Sheath: ") and not line.ends_with("empty") and not ring.visible
			and s.at == [-1, -1], "vr slots: a hand at a slot ticks once and shows its ring and what's in it; away: hidden (%s)" % line)
	# a new snapshot with the same slots: the same list, rings and lines (nothing made again)
	var b0 := s.builds
	var n := _rig.get_child_count() + s.get_child_count()
	_snap.seq += 1
	_mock.changed.emit(_snap)
	_rig.right.global_position = _slot(HOL)
	_rig.update_hands(0.016, true)
	_away()
	_rig.update_hands(0.016, true)
	_check.call(s.builds == b0 and s.ring_of(k) == ring and _rig.get_child_count() + s.get_child_count() == n,
			"vr slots: a snapshot that changes no slot rebuilds nothing")


func _test_take_and_back() -> void:
	var seq := _snap.seq
	_rig.left.global_position = _slot(SHEATH)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.left, "grip_click")
	var l: ItemRef = _hands.holding("vr_l").get("item")
	var took := l != null and l.uid == KNIFE and _snap.seq == seq
	_rig.update_hands(0.016, true)
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	var row := _row(KNIFE)
	_check.call(took and _snap.seq == seq and row == [SHEATH, 0, 0] and _clean(),
			"vr slots: grip at the sheath takes the knife, let go there puts it back: nothing sent (%s)" % [row])


func _test_quick_switch() -> void:
	_rig.left.global_position = _slot(SHEATH)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	var at_slot := (int(_row(KNIFE)[1]) & Snapshot.CARRIED_OFFHAND) == 0
	_rig.left.global_position = _slot(SHEATH) + Vector3(0, 0.1, -(VrRig.SWITCH_M + 0.1))
	_rig.update_hands(0.016, true)
	var row := _row(KNIFE)
	_check.call(at_slot and row[0] == SHEATH and (int(row[1]) & Snapshot.CARRIED_OFFHAND) != 0 and _actions.pending_count() == 0,
			"vr slots: taken out and carried away from the slot, the knife is held in the off hand (%s)" % [row])
	_rig.left.global_position = _slot(SHEATH)
	_rig.update_hands(0.016, true)
	_rig.release(_rig.left, "grip_click")
	_rig.update_hands(0.016, true)
	row = _row(KNIFE)
	_check.call(row == [SHEATH, 0, 0] and _clean(), "vr slots: ... let go at the sheath it is put away, out of the hand (%s)" % [row])


func _test_put_in() -> void:
	var hammer := _handle(E, _it["hammer"])
	_rig.right.global_position = _mid(hammer)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.right, "grip_click")
	var r: ItemRef = _hands.holding("vr_r").get("item")
	_rig.right.global_position = _slot(POUCH)
	_rig.update_hands(0.016, true)
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	var row := _row(hammer)
	_check.call(r != null and r.uid == hammer and not row.is_empty() and row[0] == POUCH and row[2] == 0
			and (int(row[1]) & Snapshot.CARRIED_WIELDED) == 0 and _clean()
			and (_rig.slots.slots[_rig.slots.slot_at(_slot(POUCH))]["contents"] as Array).size() == 1,
			"vr slots: a world item let go at the pouch goes into it (%s)" % [row])
	# the pouch has something now: grip there takes it, not the rock lying near (an empty slot leaves that alone)
	var rock := _handle(E, _it["rock"])
	_rig.right.global_position = _slot(HOL)
	_rig.update_hands(0.016, true)
	var free_slot := _rig.slot_take(1, {}, {}) == null
	_rig.right.global_position = _slot(POUCH)
	_rig.update_hands(0.016, true)
	var taken := _rig.slot_take(1, {}, {})
	_away()
	_rig.update_hands(0.016, true)
	_check.call(free_slot and taken != null and taken.uid == hammer and rock > 0,
			"vr slots: an empty slot takes nothing; one with something gives it to the grip")


func _test_refused() -> void:
	_mock.put_check = func(_t: int, ct: int, _p: int) -> String:
		return "Your sheath can't hold that." if ct == _it["sheath"] else ""
	var rock := _handle(E, _it["rock"])
	var b := _rig.buzzes[1]
	_rig.right.global_position = _mid(rock)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.right, "grip_click")
	_rig.right.global_position = _slot(SHEATH)
	_rig.update_hands(0.016, true)
	var ticks := _rig.buzzes[1] - b
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	var note := _rig.notes[1]
	var row := _row(rock)
	_mock.put_check = Callable()
	_check.call(note != null and note.visible and note.text == "Your sheath can't hold that." and _rig.buzzes[1] > b + ticks
			and (row.is_empty() or row[0] != SHEATH) and _clean(),
			"vr slots: a refused put-in: a buzz and CDDA's reason by the hand, not in the sheath (%s)" % [row])


func _test_gun() -> void:
	var c := _snap.carried
	for i in range(0, c.size() - CS + 1, CS):
		if c[i] != GUN and (c[i + 4] & Snapshot.CARRIED_WIELDED):
			c[i + 4] = 0   # (the rock the last test left in CDDA's main hand: out of it)
		if c[i] == GUN:
			c[i + 2] = 0
			c[i + 3] = -1
			c[i + 4] = Snapshot.CARRIED_WIELDED
	_snap.seq += 1
	_mock.changed.emit(_snap)
	_rig.gun.shown = true   # (VrGun shows CDDA's wielded gun; the test stands in for it)
	_rig.right.global_position = _slot(HOL)
	_rig.update_hands(0.016, true)
	_rig.press(_rig.right, "grip_click")
	var none_taken := _hands.holding("vr_r").is_empty()
	_rig.release(_rig.right, "grip_click")
	_rig.update_hands(0.016, true)
	var row := _row(GUN)
	_rig.gun.shown = false
	_check.call(none_taken and not row.is_empty() and row[0] == HOL and row[2] == 0
			and (int(row[1]) & Snapshot.CARRIED_WIELDED) == 0 and _clean(),
			"vr slots: the wielded gun's grip let go at the holster holsters it (%s)" % [row])
	_rig.right.global_position = _slot(SHEATH) + Vector3(0, 0.5, -0.5)
	_rig.press(_rig.right, "grip_click")
	var seq := _snap.seq
	_rig.release(_rig.right, "grip_click")
	_check.call(_snap.seq == seq and _clean(), "vr slots: a grip let go away from every slot sends nothing")
