extends RefCounted
## G6 in VR: the VR hints (Hints.VR_TEXTS: short, one button each, no keys to fill), kept in the same seen set and file
## as the flat ones; VrHint draws the one shown low in front of the eyes and follows the head's turn lazily; VrRig's
## hint_due asks for the VR-only ones.

var _check: Callable


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr hint")
	_test_texts()
	_test_file()
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	var h := Hints.new()
	h.persist = false
	root.add_child(h)
	_test_view(rig, h)
	h.free()
	rig.free()
	world.free()


## Each VR text: about 60 characters at most, no "!", no {action} to fill; the flat hints that have a VR one.
func _test_texts() -> void:
	var ok := true
	for id: String in Hints.VR_TEXTS:
		var t: String = Hints.VR_TEXTS[id]
		ok = ok and id.begins_with("vr_") and t.length() <= 64 and not "!" in t and not "{" in t \
				and Hints.text_of(id) == t and Hints.known(id) and not Hints.TEXTS.has(id)
	for id: String in Hints.VR_START:
		ok = ok and Hints.known(id)
	_check.call(ok and Hints.vr_id("hostile") == "vr_hostile" and Hints.vr_id("tired") == "vr_tired"
			and Hints.vr_id("prompt") == "vr_prompt" and Hints.vr_id("eat") == "vr_eat" and Hints.vr_id("bleed") == "vr_bleed"
			and Hints.text_of("nope") == "" and Hints.text_of("") == "" and not Hints.known("vr_nope")
			and Hints.text_of("prompt") == Hints.fill(Hints.TEXTS["prompt"]),
			"vr hint: short VR texts with their own ids; the flat ones with a VR version map to it")


## A VR id seen is saved and read back with the flat ones; an unknown id in the file is dropped.
func _test_file() -> void:
	var path: String = preload("res://tests/test_dir.gd").path("vr_hints_test.cfg")
	var a := Hints.new()
	a.path = path
	var shown := a.trigger("vr_gun") and a.trigger("prompt") and not a.trigger("vr_gun") and not a.trigger("vr_nope")
	a.free()
	var b := Hints.new()
	b.path = path
	var why := b.load_file()
	var read := why == "" and b.seen.has("vr_gun") and b.seen.has("prompt") and b.seen.size() == 2
	b.free()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string('[hints]\nenabled=true\nseen=["vr_gun", "vr_bogus", 5]\n')
	f.close()
	var c := Hints.new()
	c.path = path
	c.load_file()
	var cleaned := c.seen.size() == 1 and c.seen.has("vr_gun")
	c.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_check.call(shown and read and cleaned, "vr hint: a VR hint seen is kept in the hints file; unknown ids in it dropped")


## The hint shown, in its VR words, low ahead; it follows a turn of the head lazily; gone when its time is up or with
## hints off; hint_due reaches Hints.
func _test_view(rig: VrRig, h: Hints) -> void:
	var v := rig.hint
	v.source = h
	v.step(0.016)
	var none := v != null and not v.visible
	h.trigger("inspect")   # a flat one (queued before the headset started): not in keyboard words in the headset
	v.step(0.016)
	none = none and h.shown == "inspect" and not v.visible
	h.dismiss()
	h.trigger("vr_start")
	v.step(0.016)
	var cam := rig.camera.global_position
	var off := v.global_position - cam
	var placed: bool = v.visible and v.text == Hints.VR_TEXTS["vr_start"] and is_equal_approx(off.y, -VrHint.DROP) \
			and is_equal_approx(Vector2(off.x, off.z).length(), VrHint.DIST)
	var before := v.global_position
	rig.camera.rotate_y(PI / 2.0)
	var to := v.target()
	v.step(0.1)
	var part := v.global_position.distance_to(to) < before.distance_to(to) and v.global_position.distance_to(to) > 0.05
	for i in 6:
		v.step(1.0)
	var caught := v.global_position.distance_to(to) < 0.01
	rig.camera.rotate_y(-PI / 2.0)
	var asked: Array[String] = []
	rig.hint_due.connect(func(id: String) -> void: asked.append(id))
	rig.hint_due.connect(h.trigger)
	rig.hint_due.emit("vr_vise")
	var queued := h.queue.has("vr_vise") and asked == ["vr_vise"]
	h.tick(Hints.SHOW_S + 0.1)   # vr_start's time is up: vr_vise shows, starting in front again
	v.step(0.016)
	var next: bool = v.visible and v.text == Hints.VR_TEXTS["vr_vise"]
	h.set_enabled(false)
	v.step(0.016)
	var off_hidden := not v.visible
	h.set_enabled(true)
	_check.call(none and placed and part and caught and queued and next and off_hidden,
			"vr hint: the hint shows low ahead in VR words (not a flat one), follows a head turn lazily; the next one, hints off hide it")
