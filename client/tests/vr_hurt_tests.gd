extends RefCounted
## VrHurt (F3 in VR): the player's hurt as a red edge in the headset, under the tunnel vignette, following the flat
## view's HurtCue; a short buzz in both hands per hit, rate-limited. No XR runtime: the view is assumed on where it
## must show.

var _check: Callable


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr hurt")
	var world := WorldView.new()
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	var cue := HurtCue.new()
	var h := rig.hurt
	_check.call(h != null and h.get_parent() == rig.camera, "vr hurt: the rig has a hurt edge on the eyes' camera")
	if h == null:
		cue.free()
		rig.free()
		world.free()
		return
	h.source = cue
	_test_place(rig, h)
	_test_level(h, cue)
	_test_buzz(rig, h, cue)
	cue.free()
	rig.free()
	world.free()


## Its own ring, behind the tunnel vignette and under its render priority: the vignette always covers it.
func _test_place(rig: VrRig, h: VrHurt) -> void:
	var v := rig.camera.get_node_or_null("Vignette") as MeshInstance3D
	var vmat: StandardMaterial3D = null
	if v != null and v.mesh != null:
		vmat = v.mesh.surface_get_material(0) as StandardMaterial3D
	var hmat: StandardMaterial3D = null
	if h.mesh != null:
		hmat = h.mesh.surface_get_material(0) as StandardMaterial3D
	_check.call(v != null and v != h and vmat != null and hmat != null and hmat != vmat
			and hmat.render_priority < vmat.render_priority and h.position.z < v.position.z and hmat.no_depth_test,
			"vr hurt: its own ring, farther than the tunnel vignette and drawn under it (priority %s < %s)"
			% [hmat.render_priority if hmat != null else "-", vmat.render_priority if vmat != null else "-"])


## It follows the flat cue's level, smoothly, capped, and only while the hurt tint is on and the view is the headset's.
func _test_level(h: VrHurt, cue: HurtCue) -> void:
	cue.hurt(int(HurtCue.HIT_FULL))
	cue.step(0.5)
	h.step(0.02)
	_check.call(cue.shown > 0.5 and h.level == cue.shown and not h.visible,
			"vr hurt: hurt, but no headset view (no XR here): the edge stays hidden")
	h.assume_view = true
	h.step(0.02)
	_check.call(h.visible and is_equal_approx(h.alpha(), VrHurt.MAX_ALPHA * cue.shown),
			"vr hurt: in the headset view the edge shows the cue's level (alpha %.2f)" % h.alpha())
	cue.shown = 7.0
	h.step(0.02)
	var capped := h.alpha() <= VrHurt.MAX_ALPHA + 1e-6
	cue.shown = NAN
	h.step(0.02)
	_check.call(capped and h.alpha() == 0.0 and not h.visible, "vr hurt: never over %.2f; a bad level shows nothing"
			% VrHurt.MAX_ALPHA)
	# hits every frame for a second, then none: it only rises, then only falls (no strobing)
	cue.shown = 0.0
	cue.peak = 0.0
	var dt := 1.0 / 72.0
	var last := 0.0
	var rising := true
	var falling := true
	for f in 300:
		if f < 72:
			cue.hurt(3)
		cue.step(dt)
		h.step(dt)
		var a := h.alpha()
		if f < 72 and a < last - 1e-6:
			rising = false
		if f >= 72 and a > last + 1e-6:
			falling = false
		last = a
	_check.call(rising and falling and last < 0.05, "vr hurt: hits coming fast hold it up, then it fades; no flashes")
	cue.hurt(int(HurtCue.HIT_FULL))
	cue.step(0.5)
	cue.enabled = false
	h.step(0.02)
	_check.call(not h.visible and h.alpha() == 0.0, "vr hurt: the hurt tint off (F1): hidden at once")
	cue.enabled = true
	h.source = null
	h.step(0.02)
	_check.call(not h.visible, "vr hurt: no source: hidden")
	h.source = cue


## A hit buzzes both hands, gently and briefly, at most once per BUZZ_GAP_S; none while off.
func _test_buzz(rig: VrRig, h: VrHurt, cue: HurtCue) -> void:
	h.step(VrHurt.BUZZ_GAP_S)
	var b := rig.buzzes.duplicate()
	var small := h.hurt(1)
	var amp_small: float = rig.buzz_amp[0]
	var again := h.hurt(int(HurtCue.HIT_FULL) * 3)
	_check.call(small and not again and rig.buzzes[0] == b[0] + 1 and rig.buzzes[1] == b[1] + 1
			and amp_small >= VrHurt.BUZZ_MIN and amp_small <= VrHurt.BUZZ_MAX and rig.buzz_amp[1] == amp_small,
			"vr hurt: a hit buzzes both hands (%.2f); the next within %.1f s doesn't" % [amp_small, VrHurt.BUZZ_GAP_S])
	h.step(VrHurt.BUZZ_GAP_S)
	var big := h.hurt(int(HurtCue.HIT_FULL) * 3)
	_check.call(big and rig.buzz_amp[0] == VrHurt.BUZZ_MAX and VrHurt.BUZZ_MAX <= 0.6 and VrHurt.BUZZ_S <= 0.15,
			"vr hurt: after the gap a big hit buzzes again, at most %.1f for %.2f s" % [VrHurt.BUZZ_MAX, VrHurt.BUZZ_S])
	h.step(VrHurt.BUZZ_GAP_S)
	cue.enabled = false
	var off := h.hurt(10)
	cue.enabled = true
	_check.call(not off and not h.hurt(0) and not h.hurt(-5), "vr hurt: no buzz while off or for no damage")
