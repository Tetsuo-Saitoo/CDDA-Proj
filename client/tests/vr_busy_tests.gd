extends RefCounted
## VrBusy: the flat BusyNote ("Time passes...", "Sleeping...") drawn low in the headset view while the game runs on by
## itself; hidden while the game asks something, with no source, or when the note is empty.

var _check: Callable
var _calls := 0


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr busy")
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	var b := rig.busy
	_check.call(b != null and b.get_parent() == rig.camera and b.position.z < 0.0 and b.position.y < 0.0
			and b.render_priority > VrHurt.PRIORITY,
			"vr busy: the rig has a busy note low in front of the eyes, over the edges")
	if b == null:
		rig.free()
		world.free()
		return
	var note := BusyNote.new()
	b.source = note
	b.step()
	var quiet := not b.visible
	note.on_request({}, 1000)   # the game asks nothing from t = 1 s
	note.tick(1000 + BusyNote.AFTER_MS + 10, true)
	b.step()
	var passes: bool = b.visible and b.text == "Time passes."
	var snap := Snapshot.new()
	snap.asleep = true
	note.on_snapshot(snap)
	note.tick(1000 + BusyNote.AFTER_MS + BusyNote.DOT_MS + 20, true)
	b.step()
	var sleeping: bool = b.visible and b.text.begins_with("Sleeping.")
	note.on_request({"id": 1, "kind": "query"}, 3000)   # a question: the note goes
	note.tick(3001, true)
	b.step()
	var asked := not b.visible
	note.text = "x".repeat(200)
	note.visible = true
	b.step()
	var capped := b.text.length() == VrBusy.MAX_CHARS
	b.source = null
	b.step()
	_check.call(quiet and passes and sleeping and asked and capped and not b.visible,
			"vr busy: shows the flat note's text while the game runs on, hides on a question or without a source")
	_test_pause(rig)
	note.free()
	rig.free()
	world.free()


## Real time paused: the HUD's time line (HudData.clock) shows low in the view with how to go on, over the busy note;
## the menu's Time row calls main's toggle and flashes its note naming the row (not the flat key); opened while
## paused, the menu picks the Time row; nothing to call: no note.
func _test_pause(rig: VrRig) -> void:
	var b := rig.busy
	var data := HudData.new()
	rig.hud.data = data
	data.set_clock("TIME PAUSED: hostile spotted")
	b.step(0)
	var paused: bool = b.visible and b.text == "TIME PAUSED: hostile spotted\n" + VrBusy.GO_ON
	data.set_clock("Time runs (real time)")
	b.step(0)
	var runs := not b.visible
	b.clock = func() -> Variant: return 5   # junk from the line: nothing
	b.step(0)
	var junk := not b.visible
	b.clock = func() -> String: return rig.hud.data.clock if rig.hud.data != null else ""
	data.set_clock("TIME PAUSED")
	rig.toggle_menu()
	var picked := rig.menu.row == rig.menu.row_of("time") and rig.menu.row >= 0
	rig.time_pause = func() -> String:
		_calls += 1
		return "Paused. %s: go on." % InputActions.prompt_of(ClockControl.PAUSE)
	rig.menu.click()
	var now := Time.get_ticks_msec()
	b.step(now)
	var flashed: bool = _calls == 1 and not rig.menu_open() and b.visible and b.text == "Paused. menu > Time: go on."
	b.step(now + VrBusy.FLASH_MS + 1)
	var after: bool = b.text == "TIME PAUSED\n" + VrBusy.GO_ON
	rig.time_pause = Callable()
	data.set_clock("")
	rig.toggle_time()
	b.step(now + 2 * VrBusy.FLASH_MS)
	var none := not b.visible and _calls == 1
	_check.call(paused and runs and junk and picked and flashed and after and none,
			"vr pause: real time paused shows in the headset with how to go on; the menu opens on its Time row, which goes on (%s)"
			% [[paused, runs, junk, picked, flashed, after, none]])
	rig.hud.data = null
