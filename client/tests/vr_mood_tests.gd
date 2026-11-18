extends RefCounted
## VrMood (player mood in VR): HudData.mood's cue as a soft edge in the headset, behind the hurt edge and the tunnel
## vignette; cold and darker when low, faintly warm when high, fading, never a jump; off with the VR setting
## `mood_cues`; hidden out of the headset's view. No XR runtime: the view is assumed on where it must show.

var _check: Callable


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr mood")
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	var m := rig.mood
	_check.call(m != null and m.get_parent() == rig.camera and rig.hurt != null and m.position.z < rig.hurt.position.z
			and (m.mesh.surface_get_material(0) as StandardMaterial3D).render_priority < VrHurt.PRIORITY,
			"vr mood: the rig has a mood edge on the eyes' camera, behind the hurt edge and under its priority")
	if m == null:
		rig.free()
		world.free()
		return
	var d := HudData.new()
	rig.hud.data = d
	_test_fade(m, d)
	_test_setting(rig, m, d)
	_test_odd(rig, m, d)
	rig.free()
	world.free()


## Low mood: fades in cold over two seconds, then holds (no pulse); high mood: back through clear to a faint warmth.
func _test_fade(m: VrMood, d: HudData) -> void:
	m.assume_view = true
	d.mood = {"word": "Miserable", "cue": -1.0}
	m.step(1.0)
	var half := m.alpha()
	var half_ok := m.visible and is_equal_approx(m.shown, -0.5) \
			and is_equal_approx(half, MoodCue.LOW_ALPHA * 0.5 * VrMood.ALPHA_SCALE)
	m.step(1.0)
	var full := m.alpha()
	m.step(1.0)
	m.step(0.5)
	var c := (m.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color
	_check.call(half_ok and is_equal_approx(full, MoodCue.LOW_ALPHA * VrMood.ALPHA_SCALE) and is_equal_approx(m.alpha(), full)
			and Color(c, 1.0).is_equal_approx(Color(MoodCue.LOW_TINT, 1.0)) and full <= 0.3 + 1e-6,
			"vr mood: low mood fades in cold over about two seconds, at most 0.3, and holds without a pulse")
	d.mood = {"word": "Joyful", "cue": 1.0}
	m.step(1.0)
	m.step(1.0)
	var through_clear := is_zero_approx(m.shown) and not m.visible
	m.step(1.0)
	m.step(1.0)
	c = (m.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color
	_check.call(through_clear and m.visible and is_equal_approx(m.alpha(), MoodCue.HIGH_ALPHA * VrMood.ALPHA_SCALE)
			and Color(c, 1.0).is_equal_approx(Color(MoodCue.HIGH_TINT, 1.0)) and m.alpha() < 0.1,
			"vr mood: high mood fades back through clear to a faint warm edge")


## The VR setting `mood_cues` off (VrRig.place_hud): it fades out and stays clear; on again: back.
func _test_setting(rig: VrRig, m: VrMood, d: HudData) -> void:
	d.mood = {"word": "Miserable", "cue": -1.0}
	for i in 4:
		m.step(1.0)
	rig.settings["mood_cues"] = "off"
	rig.place_hud(0.016)
	m.step(1.0)
	var fading := m.visible and m.alpha() > 0.0 and not m.enabled
	m.step(1.0)
	var off := not m.visible and is_zero_approx(m.shown)
	rig.settings["mood_cues"] = "on"
	rig.place_hud(0.016)
	m.step(1.0)
	_check.call(fading and off and m.enabled and m.visible and VrSettings.DEFAULTS["mood_cues"] == "on"
			and VrSettings.clean("mood_cues", "off") == "off" and VrSettings.clean("mood_cues", "dim") == null
			and VrSettings.ROWS.any(func(r: Array) -> bool: return r[0] == "mood_cues"),
			"vr mood: the VR setting Mood tint off fades it out, on brings it back")


## No mood, a cue that isn't a number, no HudData, or not the headset's view: clear.
func _test_odd(rig: VrRig, m: VrMood, d: HudData) -> void:
	var ok := true
	for bad: Variant in [{}, {"cue": "low"}, {"cue": NAN}, {"cue": INF}, {"cue": -1}]:
		d.mood = bad
		ok = ok and is_zero_approx(m.target())
	d.mood = {"cue": -5.0}
	ok = ok and is_equal_approx(m.target(), -1.0)
	m.assume_view = false
	m.step(1.0)
	var out_of_view := not m.visible
	rig.hud.data = null
	ok = ok and is_zero_approx(m.target())
	_check.call(ok and out_of_view, "vr mood: no mood, odd cues or no HudData give no edge; out of the headset's view hidden")
