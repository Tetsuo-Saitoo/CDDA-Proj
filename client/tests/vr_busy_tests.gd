extends RefCounted
## VrBusy: the flat BusyNote ("Time passes...", "Sleeping...") drawn low in the headset view while the game runs on by
## itself; hidden while the game asks something, with no source, or when the note is empty.

var _check: Callable


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
	note.free()
	rig.free()
	world.free()
