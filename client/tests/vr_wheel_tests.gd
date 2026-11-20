extends RefCounted
## Radial menus in VR (VrWheel, VrRig.wheel; the wheel itself is lead-ui's RadialRequestWidget): a hand on the sink
## next to the player sends fp3d_use for its square and asks RequestUI for a wheel; held, CDDA's menu shows around
## the hand (the panel hidden, no moving), a flick or the stick points, letting go of the trigger picks; a tap picks
## CDDA's default; let go on nothing it stays, the trigger picks, B cancels; the list option keeps the panel's list.
## No XR runtime: the test places the hands and calls the rig's buttons. Run by run_tests.gd.

const DT := 0.05
const ME := Vector3i(5, 5, 0)
const SINK_AT := Vector3i(6, 5, 0)
const SM := Vector3i(0, 0, 0)

var _check: Callable
var _world: WorldView
var _rig: VrRig
var _ui: RequestUI
var _w: VrWheel
var _sent: Array[String] = []
var _answers: Array[Dictionary] = []
var _ok := true   # what queue_action answers


func run(root: Node, check: Callable, tables: IdTables) -> void:
	_check = check
	print("vr wheel")
	var sink := tables.index_of("furn", "f_sink")
	var d: IdTables.Def = tables.def_at("furn", sink) if sink > 0 else null
	if d == null:
		_check.call(false, "vr wheel: the mock tables have a sink")
		return
	var was: Array = [d.examine, tables.has_examine]
	d.examine = "water_source"
	tables.has_examine = true
	_world = WorldView.new()
	_world.tables = tables
	root.add_child(_world)
	_world.snapshot = _snap(sink)
	_rig = VrRig.new(_world, {"blink": false, "hands": "boxes"})
	root.add_child(_rig)
	_rig.camera.global_position = _world.coords.ms_center_to_world(ME) + Vector3(0, 1.6, 0)
	_ui = RequestUI.new()
	_rig.panel.root.add_child(_ui)
	_ui.answered.connect(func(a: Dictionary) -> void: _answers.append(a))
	_w = _rig.wheel
	_w.request_ui = _ui
	_w.queue_action = func(a: String) -> bool:
		_sent.append(a)
		return _ok
	_rig.live_stairs = true
	_w.live = true
	_test_target(d)
	_test_hold_pick()
	_test_eyes()
	_test_tap()
	_test_click_and_cancel()
	_test_list()
	_test_label()
	d.examine = was[0]
	tables.has_examine = was[1]
	_rig.free()
	_world.free()


func _snap(sink: int) -> Snapshot:
	var s := Snapshot.new()
	s.player_pos = ME
	var sm := Snapshot.Submap.new()
	sm.pos = SM
	var f := PackedInt32Array()
	f.resize(CddaCoords.SEEX * CddaCoords.SEEX)
	var l := CddaCoords.ms_to_local(SINK_AT)
	f[l.y * CddaCoords.SEEX + l.x] = sink
	sm.furn = f
	var t := PackedInt32Array()
	t.resize(CddaCoords.SEEX * CddaCoords.SEEX)
	sm.ter = t
	s.submaps[SM] = sm
	return s


func _over(sq: Vector3i, up := 0.9) -> Vector3:
	return _world.coords.ms_center_to_world(sq) + Vector3(0.0, up, 0.0)


func _menu(id := 41) -> Dictionary:
	var e := []
	for k in 4:
		e.append({"id": k, "label": ["Drink", "Fill a container", "Empty it", "Examine"][k], "enabled": true,
				"description": ""})
	return {"id": id, "kind": "menu", "context": "", "title": "Sink", "text": "", "entries": e,
			"actions": PackedStringArray(), "allow_cancel": true, "selected": 0}


## The wheel's frame, both hands at `at` (the right one opened it), sticks `st`.
func _frame(at: Vector3, st := Vector2.ZERO) -> void:
	var hands: Array[Vector3] = [at, at]
	var sticks: Array[Vector2] = [Vector2.ZERO, st]
	var free: Array[bool] = [true, true]
	_w.update(hands, sticks, free, _rig.camera.global_transform)
	_rig.update_panel(DT)


## Opens a held wheel with the right hand at `p`: true when the use went out and the wheel shows.
func _open(p: Vector3) -> bool:
	_sent.clear()
	_answers.clear()
	_rig.right.global_position = p
	var ok := _w.press(1, p) and _ui.show_request(_menu())
	_frame(p)
	return ok and _w.active() and _sent == ["fp3d_use_RIGHT"]


func _test_target(d: IdTables.Def) -> void:
	var t := _w.target_at(_over(SINK_AT))
	_check.call(t.get("action") == "fp3d_use_RIGHT" and t.get("pos") == SINK_AT and t.get("name") == "sink"
			and t.get("text") == "Sink\ntrigger: drink   hold: choices",
			"vr wheel: a hand on the sink next to you: the trigger uses it (%s)" % [t])
	_check.call(_w.target_at(_over(ME)).is_empty() and _w.target_at(_over(Vector3i(7, 5, 0))).is_empty()
			and _w.target_at(_over(SINK_AT, 2.5)).is_empty() and _w.target_at(_over(Vector3i(6, 6, 0))).is_empty()
			and _w.target_at(Vector3(NAN, 0, 0)).is_empty(),
			"vr wheel: your own square, two away, too high, nothing there, a bad point: nothing to use")
	d.examine = ""
	var plain := _w.target_at(_over(SINK_AT)).is_empty()
	d.examine = "water_source"
	_check.call(plain, "vr wheel: furniture whose examine does nothing: not used by hand")
	var hands: Array[Vector3] = [_over(SINK_AT), _over(Vector3i(7, 5, 0))]
	var sticks: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
	var free: Array[bool] = [true, true]
	_w.update(hands, sticks, free, _rig.camera.global_transform)
	var shown := _w.hints[0] != null and _w.hints[0].visible and _w.hints[0].text.begins_with("Sink")
	var other := _w.hints[1] == null or not _w.hints[1].visible
	free[0] = false
	_w.update(hands, sticks, free, _rig.camera.global_transform)
	_check.call(shown and other and not _w.hints[0].visible,
			"vr wheel: the line by a free hand on it names it and the trigger's verb; a busy hand: none")


func _test_hold_pick() -> void:
	var p := _over(SINK_AT)
	var opened := _open(p)
	var w := _ui.widget as RadialRequestWidget
	var built := _w.wheel != null and _w.wheel.global_position.distance_to(p) < 0.001 \
			and _w.wheel.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D).size() >= RadialRequestWidget.SLOTS
	_check.call(opened and w != null and w.hold and built and not _rig.panel.shown and _rig.ui_open(),
			"vr wheel: held, CDDA's menu shows as a wheel around the hand; the panel stays hidden")
	var right := _w.wheel.global_basis.x
	_frame(p + right * VrWheel.FLICK_M)
	var flick := w.hovered
	_frame(p + right * VrWheel.FLICK_M, Vector2(0, 1))
	var stick := w.hovered
	_frame(p + right * VrWheel.FLICK_M)   # the stick let go, the hand still: the stick's pick stays
	var stays := w.hovered
	_frame(p - _w.wheel.global_basis.y * VrWheel.FLICK_M)
	var down := w.hovered
	var at := _rig.global_transform
	_rig.step(DT, {"move": Vector2(0, 1), "turn": Vector2(1, 0)})
	var still := _rig.global_transform.is_equal_approx(at)
	_check.call(flick == 2 and stick == 0 and stays == 0 and down == 4 and still,
			"vr wheel: a flick or the stick points (%d %d %d %d), the sticks don't move you" % [flick, stick, stays, down])
	_rig.release(_rig.right, "trigger_click")
	_frame(p)
	_check.call(_answers == [{"id": 41, "entry": 2}] and not _w.active() and _w.wheel == null,
			"vr wheel: letting go of the trigger picks what it points at (%s)" % [_answers])



## Eye tracking (VrRig.look): the tracked eyes on the wheel point while the hand rests in its middle; the stick and a
## flick of the hand win; head gaze never points; looking only points, letting go of the trigger picks.
func _test_eyes() -> void:
	var p := _over(SINK_AT)
	var opened := _open(p)
	var w := _ui.widget as RadialRequestWidget
	var cam := _rig.camera.global_transform
	var gaze := func(to: Vector3, eyes: bool) -> Dictionary:
		return {"from": cam.origin, "dir": (to - cam.origin).normalized(), "eyes": eyes}
	var right := _w.wheel.global_basis.x * VrWheel.RADIUS_M * 0.7
	var up := _w.wheel.global_basis.y * VrWheel.RADIUS_M * 0.7
	var hands: Array[Vector3] = [p, p]
	var sticks: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
	var free: Array[bool] = [true, true]
	var seen := []
	for g: Dictionary in [gaze.call(p + right, true), gaze.call(p - up, true), gaze.call(p + right, false),
			gaze.call(p + right * 5.0, true), {"from": cam.origin, "dir": Vector3(NAN, 0, 0), "eyes": true}]:
		_w.update(hands, sticks, free, cam, g)
		seen.append(w.hovered)
	sticks[1] = Vector2(0, 1)
	_w.update(hands, sticks, free, cam, gaze.call(p + right, true))
	var stick := w.hovered
	sticks[1] = Vector2.ZERO
	_w.update(hands, sticks, free, cam, gaze.call(p + right, true))   # the eyes still: the stick's pick stays
	var stays := w.hovered
	_w.update(hands, sticks, free, cam, gaze.call(p - up, true))   # the eyes moved: they point again
	var moved := w.hovered
	hands[1] = p - _w.wheel.global_basis.y * VrWheel.FLICK_M
	_w.update(hands, sticks, free, cam, gaze.call(p + right, true))   # a flick down: the hand wins
	var flick := w.hovered
	var none_yet := _answers.is_empty()
	hands[1] = p
	_w.update(hands, sticks, free, cam, gaze.call(p + right, true))
	_rig.release(_rig.right, "trigger_click")
	_frame(p)
	_check.call(opened and seen == [2, 4, -1, -1, -1] and stick == 0 and stays == 0 and moved == 4 and flick == 4
			and none_yet and _answers == [{"id": 41, "entry": 1}],   # slot 2: the second entry
			"vr wheel: tracked eyes point (the head, far off or junk: not); the stick and a flick win; the trigger picks (%s %d %d %d %d %s)"
			% [seen, stick, stays, moved, flick, _answers])


func _test_tap() -> void:
	var p := _over(SINK_AT)
	_sent.clear()
	_answers.clear()
	var sent := _w.press(1, p)
	_rig.release(_rig.right, "trigger_click")   # before CDDA's menu came
	_ui.show_request(_menu(42))
	_frame(p)
	_check.call(sent and _answers == [{"id": 42, "entry": 0}] and not _w.active(),
			"vr wheel: a tap picks CDDA's default, no wheel (%s)" % [_answers])


func _test_click_and_cancel() -> void:
	var p := _over(SINK_AT)
	var opened := _open(p)
	var w := _ui.widget as RadialRequestWidget
	if w != null:
		w.tap_until = -1   # held longer than a tap
	_rig.release(_rig.right, "trigger_click")
	_frame(p)
	var stays := _w.active() and _answers.is_empty()
	_rig.press(_rig.right, "trigger_click")   # nothing pointed: nothing picked
	var still := _w.active() and _answers.is_empty()
	_frame(p + _w.wheel.global_basis.x * VrWheel.FLICK_M)
	_rig.press(_rig.right, "trigger_click")
	_check.call(opened and stays and still and _answers == [{"id": 41, "entry": 1}],
			"vr wheel: let go on nothing, it stays; the trigger then picks what it points at (%s)" % [_answers])
	_open(p)
	_rig.press(_rig.right, "by_button")
	_frame(p)
	_check.call(_answers == [{"id": 41, "cancel": true}] and not _w.active(), "vr wheel: B cancels CDDA's menu")
	_rig.release(_rig.right, "trigger_click")


func _test_list() -> void:
	var p := _over(SINK_AT)
	_w.enabled = false
	_sent.clear()
	var sent := _w.press(1, p)
	_ui.show_request(_menu(43))
	_frame(p)
	var list := _ui.widget != null and not _ui.widget is RadialRequestWidget and not _w.active() and _rig.panel.shown
	_ui.widget.cancel()
	_w.release(1)
	_w.enabled = true
	_rig.update_panel(DT)
	_ok = false
	var refused := not _w.press(1, p)
	_ok = true
	_rig.live_stairs = false
	_w.live = false
	var mock := not _w.press(1, p)
	_rig.live_stairs = true
	_w.live = true
	_check.call(sent and list and refused and mock and _sent == ["fp3d_use_RIGHT", "fp3d_use_RIGHT"],
			"vr wheel: the list option: CDDA's list on the panel; the queue refusing or no live game: nothing used")


## Labels on look (LookLabel): the tracked eyes resting on the sink name it after DWELL_S; head gaze never does;
## looking away it stays LINGER_S, then goes; off: nothing.
func _test_label() -> void:
	var l := _rig.label
	l.clear()
	var sm: Snapshot.Submap = _world.snapshot.submaps[SM]
	sm.flags.resize(CddaCoords.SEEX * CddaCoords.SEEX)   # LookRay reads every square's flags
	# a creature on the sink's square: LookRay meets creatures before the mock map's terrain (drawn as solid boxes)
	var zed := Snapshot.Creature.new()
	zed.uid = 77
	zed.pos = SINK_AT
	zed.hp_frac = 128
	_world.snapshot.creatures.append(zed)
	_world.snapshot.creatures_moved()
	var cam := _over(SINK_AT + Vector3i(-1, 0, 0), 0.5)   # next door: the mock map's terrain is solid everywhere
	var at := _over(SINK_AT, 0.5)
	var eyes := {"from": cam, "dir": (at - cam).normalized(), "eyes": true}
	l.update(0.1, _world, eyes, true)
	var waits := not l.visible
	for i in 3:
		l.update(0.1, _world, eyes, true)
	var shown := l.visible and l.text.ends_with("\nhealth 50%") and l.text.length() > 12 \
			and l.global_position.distance_to(at) < 1.2
	var named := l.text
	var head := eyes.duplicate()
	head["eyes"] = false
	l.update(0.1, _world, head, true)
	var head_none := not l.visible
	for i in 4:
		l.update(0.1, _world, eyes, true)
	var sky := {"from": cam, "dir": Vector3(0, 1, 0), "eyes": true}
	l.update(0.1, _world, sky, true)
	l.update(0.1, _world, sky, true)
	var lingers := l.visible
	l.update(0.1, _world, sky, true)
	l.update(0.1, _world, sky, true)
	var gone := not l.visible
	for i in 4:
		l.update(0.1, _world, eyes, true)
	l.enabled = false
	l.update(0.1, _world, eyes, true)
	var off := not l.visible
	l.enabled = true
	l.update(0.1, _world, eyes, false)
	var menu := not l.visible
	var junk := {"from": cam, "dir": Vector3(NAN, 0, 0), "eyes": true}
	l.update(0.1, _world, junk, true)
	l.update(0.1, _world, {"eyes": true}, true)
	_check.call(waits and shown and head_none and lingers and gone and off and menu and not l.visible,
			"vr label: the eyes on a creature name it after a moment (%s); the head never; looking away it lingers, then goes"
			% [named.replace("\n", " / ")])
	l.clear()
	_world.snapshot.creatures.erase(zed)
	_world.snapshot.creatures_moved()
