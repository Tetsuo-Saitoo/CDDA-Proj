extends RefCounted
## V2: gun modification at a bench vise on the flat screen (ViseBench) on the mock town: a bench vise lying south of
## the player, a wielded glock with two mods on it (one irremovable) and a carried gunmod CDDA judged. Clamp and
## release (the mouse, the gun drawn at the jaws, BackOut's "vise" step), the lists, Fit and Take off through
## ItemActions (a recording backend), refusals, hostile `fits`, walking off and the gun put away. Run by run_tests.gd.

const InspectTests := preload("res://tests/inspect_tests.gd")
const P := Vector3i(192, 384, 0)       # the mock town's player
const GUN := 600
const MOD := 601                       # carried (off hand), judged by CDDA
const ON := 602                        # on the gun
const FIXED := 603                     # on the gun, irremovable
const STRAY := 999                     # judged but not carried: not listed

var _check: Callable
var _it := {}   # itype id -> index
var _tables: IdTables
var _data: Dictionary
var _world: WorldView
var _actions: ItemActions
var _hands: Hands
var _bench: ViseBench
var _mode := [Input.MOUSE_MODE_CAPTURED]   # the bench's mouse mode (a fake: mouse_hook)
var _released: Array[String] = []


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_tables = tables
	_data = data
	print("vise bench")
	for id: String in ["glock_19", "laser_sight", "suppressor", "rock", "bench_vise"]:
		_it[id] = tables.index_of("itype", id)
	var s := _snap_with(true)
	_check.call(s.is_valid() and s.player_pos == P and _it.values().all(func(t: int) -> bool: return t > 0),
			"vise bench: test town loads with a vise, a wielded glock and a suppressor " + s.error)
	if not s.is_valid():
		return
	_world = WorldView.new()
	_world.catalog.load_registry_dir(ProjectSettings.globalize_path("res://").path_join("../assets/registry").simplify_path())
	_world.set_id_tables(tables)
	root.add_child(_world)
	_world.apply_snapshot(s)
	_actions = ItemActions.new()
	var b := InspectTests.ModBackend.new()
	_actions.backend = b
	_actions.on_snapshot(s)
	_hands = Hands.new(_world, _actions)
	_hands.defer_steps = false
	_bench = ViseBench.new()
	_bench.actions = _actions
	_bench.world = _world
	_bench.model_parent = _world
	_bench.jaws = func(uid: int) -> Variant: return Vise.jaws(_hands.picker, uid)
	_bench.mouse_hook = func(set_to: int) -> int:   # the test runner's own mouse mode stays as it is
		if set_to >= 0:
			_mode[0] = set_to
		return _mode[0]
	_bench.released.connect(func(why: String) -> void: _released.append(why))
	_actions.refused.connect(_bench.on_refused)
	root.add_child(_bench)
	_test_lists(s)
	_test_clamp(s, b)
	_test_hostile(s)
	_test_leave(s)
	_bench.free()
	_hands.free()
	_actions.free()
	_world.free()


## The mock town with a bench vise lying south of the player (or none) and the glock wielded.
func _snap_with(vise: bool) -> Snapshot:
	var d: Dictionary = _data.duplicate(true)
	for sm: Dictionary in d["submaps"]:
		var pos: Array = sm["pos"]
		var at := Vector3i(int(pos[0]), int(pos[1]), int(pos[2]))
		if at == Vector3i(16, 32, 0):
			sm["items"] = [[12, 1, [_it["bench_vise"]]]] if vise else []
		elif at in [Vector3i(15, 32, 0), Vector3i(15, 31, 0), Vector3i(16, 31, 0)]:
			sm["items"] = []
		else:
			continue
		sm.erase("handles")
	(d["player"] as Dictionary)["items"] = [
			[GUN, _it["glock_19"], 0, -1, Snapshot.CARRIED_WIELDED],
			[MOD, _it["suppressor"], 0, -1, Snapshot.CARRIED_OFFHAND]]
	(d["player"] as Dictionary)["wielded_gun"] = {"type": _it["glock_19"], "faults": [],
			"mods": [[ON, _it["laser_sight"], "rail", 0], [FIXED, _it["rock"], "sights", GunModFit.IRREMOVABLE]],
			"fits": [[MOD, 1, 61, 8, ""], [STRAY, 1, 100, 0, ""]]}
	var s := Snapshot.from_data(d)
	if s.is_valid():
		MockItems.new(s, _tables).seed()   # handles for what lies around
	return s


func _gun() -> ItemRef:
	return ItemRef.on_player(GUN, _it["glock_19"], 0, -1, Snapshot.CARRIED_WIELDED, P)


## The vise found next to the player; what the panel would list: the gun's mods (the irremovable one marked) and the
## carried gunmods CDDA judged (not one it isn't carrying); nothing for what isn't the wielded gun.
func _test_lists(s: Snapshot) -> void:
	var near := Vise.near(s, _tables)
	var e := ViseBench.entries(s, _tables, _actions, _gun())
	var mods: Array = e["mods"]
	var fits: Array = e["fits"]
	var mod_ref := ItemRef.on_player(MOD, _it["suppressor"], 0, -1, Snapshot.CARRIED_OFFHAND, P)
	_check.call(near.size() == 1 and ViseBench.stay_reason(s, _tables, near[0], _gun()) == ""
			and ViseBench.stay_reason(s, _tables, near[0], mod_ref) == ViseBench.NOT_HELD
			and ViseBench.stay_reason(s, _tables, near[0] + 1, _gun()) == ViseBench.MOVED
			and ViseBench.stay_reason(null, _tables, near[0], _gun()) == ViseBench.MOVED,
			"vise bench: the vise next to the player holds the wielded gun, nothing else (%s)" % [near])
	_check.call(mods.map(func(m: Dictionary) -> int: return m["uid"]) == [ON, FIXED]
			and mods.map(func(m: Dictionary) -> bool: return m["fixed"]) == [false, true]
			and fits.size() == 1 and fits[0]["uid"] == MOD and fits[0]["ok"] == true and fits[0]["chance"] == 61
			and fits[0]["risk"] == 8 and (fits[0]["item"] as ItemRef).uid == MOD
			and (ViseBench.entries(s, _tables, _actions, mod_ref)["mods"] as Array).is_empty()
			and (ViseBench.entries(null, _tables, _actions, _gun())["fits"] as Array).is_empty(),
			"vise bench: the gun's mods and the carried gunmods CDDA judged are listed (%s / %s)" % [mods, fits])


## E on the vise: clamped, the mouse free, the gun drawn at the jaws (the hand's model hidden by main), Fit and Take off
## send through ItemActions, an irremovable mod and a refused fit aren't sent, CDDA's refusal on the panel; Esc
## (BackOut "vise") takes the gun back: the mouse as it was, the model gone.
func _test_clamp(s: Snapshot, b: RefCounted) -> void:
	var v := Vise.near(s, _tables)[0]
	var at: Variant = Vise.jaws(_hands.picker, v)
	var jaws: Vector3 = at if at is Vector3 else Vector3(1, 2, 3)
	var bad := _bench.clamp_gun(v + 1, _gun(), jaws)
	var ok := _bench.clamp_gun(v, _gun(), jaws, Vector3.FORWARD)
	var again := _bench.clamp_gun(v, _gun(), jaws)
	_check.call(at is Vector3 and not bad and ok and not again and _bench.clamped() and _bench.visible
			and _mode[0] == Input.MOUSE_MODE_VISIBLE and _bench.model != null and _bench.model.get_parent() == _world
			and _bench.model.visible and _bench.model.global_position.is_equal_approx(jaws)
			and _bench._title.text.ends_with("in the vise"),
			"vise bench: E on the vise clamps the gun: drawn at the jaws, the mouse free, the panel up (%s)" % [at])
	var on_b := _bench.button_of(ON)
	var mod_b := _bench.button_of(MOD)
	_check.call(on_b != null and not on_b.disabled and _bench.button_of(FIXED) == null and mod_b != null
			and not mod_b.disabled and _bench.button_of(STRAY) == null,
			"vise bench: Take off on each removable mod, Fit on the judged gunmod")
	var odds_row: String = (mod_b.get_parent().get_child(0) as Label).text
	mod_b.pressed.emit()
	var calls: Array = b.get("calls")
	var add_call: bool = calls.size() == 1 and (calls[0] as Array).slice(0, 5) == ["mod_add", float(MOD),
			float(_it["suppressor"]), float(GUN), float(_it["glock_19"])]
	var vise_named: bool = calls.size() == 1 and (calls[0] as Array).slice(6) == [float(v), float(_it["bench_vise"])]
	var fit_status := _bench.status
	var name := ViseBench._name(_tables, _it["suppressor"])
	var busy := _bench.button_of(MOD) != null and _bench.button_of(MOD).disabled
	_bench.button_of(ON).pressed.emit()
	var off_call: bool = calls.size() == 2 and (calls[1] as Array).slice(0, 5) == ["mod_remove", float(ON),
			float(_it["laser_sight"]), float(GUN), float(_it["glock_19"])]
	var fixed := _bench.take_off(FIXED)
	_check.call(add_call and fit_status == GunModFit.FITTING_ODDS % [name, 81, 4] and busy
			and off_call and fixed == "" and _bench.status.ends_with("can't be taken off.") and calls.size() == 2,
			"vise bench: Fit sends mod_add, Take off mod_remove; an irremovable one isn't sent (%s / %s)" % [calls, fit_status])
	_check.call(vise_named and odds_row.contains("81% (4% risk of damage) with the vise")
			and ViseBench.fitting_line("x", 85, 6, true) == GunModFit.FITTING % "x"
			and ViseBench.fitting_line("x", 61, 8, false) == GunModFit.FITTING_ODDS % ["x", 61, 8],
			"vise bench V3: a fit names the vise; the panel and its line show the vise's odds, none once sure (%s)" % odds_row)
	_actions.on_events([{"kind": "item_result", "detail": int(calls[0][5]), "amount": 0,
			"text": "Your Glock is not a gun."}])
	var refused := _bench.status
	var fits0: Variant = s.player_gun.get("fits")
	s.player_gun["fits"] = [{"uid": MOD, "ok": false, "chance": 0, "risk": 0, "reason": "is too difficult for you to modify."}]
	_bench.refresh()
	var sent := _bench.fit_mod(MOD)
	_check.call(refused == "Your Glock is not a gun." and _bench.button_of(MOD).disabled and sent == ""
			and _bench.status.ends_with("is too difficult for you to modify.") and calls.size() == 2,
			"vise bench: CDDA's refusal shows on the panel; a fit CDDA said no to isn't sent (%s)" % refused)
	s.player_gun["fits"] = fits0
	var bo := BackOut.new()
	var added := bo.add("vise", func() -> bool: return _bench.clamped(), func() -> bool:
		_bench.release()
		return true)
	var stepped := bo.step()
	_check.call(added and stepped == "vise" and not _bench.clamped() and not _bench.visible and _bench.model == null
			and _mode[0] == Input.MOUSE_MODE_CAPTURED and _released == [""] and bo.step() == "",
			"vise bench: Esc takes the gun back: the panel and model gone, the mouse as it was (%s)" % [_released])


## Hostile `fits` rows (not dictionaries, `ok` not a bool, odds out of range) are skipped or clamped.
func _test_hostile(s: Snapshot) -> void:
	var fits0: Variant = s.player_gun.get("fits")
	s.player_gun["fits"] = ["x", 7, {"uid": MOD, "ok": "yes"}, {"uid": MOD, "ok": true, "chance": "lots", "risk": -5,
			"reason": "a".repeat(5000)}]
	var e := ViseBench.entries(s, _tables, _actions, _gun())
	var fits: Array = e["fits"]
	s.player_gun["fits"] = "junk"
	var none := ViseBench.entries(s, _tables, _actions, _gun())
	s.player_gun["fits"] = fits0
	_check.call(fits.size() == 1 and fits[0]["chance"] == 100 and fits[0]["risk"] == 0
			and str(fits[0]["reason"]).length() <= ViseBench.MAX_STATUS and (none["fits"] as Array).is_empty()
			and (none["mods"] as Array).size() == 2,
			"vise bench: hostile fits rows are skipped, odds clamped, reasons capped (%s)" % [fits.size()])


## Walking off (the vise out of reach) or the gun no longer wielded takes it back, with a line for main to show.
func _test_leave(s: Snapshot) -> void:
	var v := Vise.near(s, _tables)[0]
	_released.clear()
	var ok1 := _bench.clamp_gun(v, _gun(), Vector3(1, 2, 3))
	_world.apply_snapshot(_snap_with(false))
	_bench.on_snapshot()
	var gone := not _bench.clamped()
	_world.apply_snapshot(s)
	var ok2 := _bench.clamp_gun(v, _gun(), Vector3(1, 2, 3))
	_bench.on_snapshot()
	var stays := _bench.clamped()
	var gun_type: Variant = s.player_gun.get("type")
	s.player_gun["type"] = -5   # another gun wielded: the clamped one is no longer it
	_bench.on_snapshot()
	s.player_gun["type"] = gun_type
	_check.call(ok1 and gone and ok2 and stays and not _bench.clamped()
			and _released == [ViseBench.MOVED, ViseBench.NOT_HELD] and _mode[0] == Input.MOUSE_MODE_CAPTURED,
			"vise bench: walking off or putting the gun away takes it out of the vise (%s)" % [_released])
