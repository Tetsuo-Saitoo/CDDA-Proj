extends RefCounted
## L4: the VR wrist HUD (VrHud), run by run_tests.gd: what it shows from HudData (doll, needs, warnings, messages),
## bounded text and hostile entries, when it shows (turned to the eyes, near), where it sits on the off forearm
## (box and finger hands, left-handed too), the buzz for a new bad warning, the `wrist_hud` setting, and that the
## viewport renders only after a change. No XR runtime: the test places the head and the hands.

var _check: Callable


func run(root: Node, check: Callable, tables: IdTables) -> void:
	_check = check
	print("vr wrist hud")
	_test_static()
	_test_settings()
	_test_content(tables)
	_test_state_lines(tables)
	_test_rig(root, tables)


func _part(id: int, hp: int, hp_max: int, bleed := 0) -> Snapshot.BodyPart:
	var p := Snapshot.BodyPart.new()
	p.id = id
	p.hp = hp
	p.hp_max = hp_max
	p.bleed = bleed
	return p


## A snapshot whose player has these [part id, hp, hp_max, bleed] rows.
func _snap(tables: IdTables, rows: Array) -> Snapshot:
	var s := Snapshot.new()
	var parts: Array[Snapshot.BodyPart] = []
	for r: Array in rows:
		parts.append(_part(tables.body_parts.find(r[0]), r[1], r[2], r[3] if r.size() > 3 else 0))
	s.player_parts = parts
	return s


func _test_static() -> void:
	var p := Transform3D(Basis(), Vector3(0, 1, 0))
	var at60 := Vector3(0.4 * sin(deg_to_rad(60.0)), 1.0, 0.4 * cos(deg_to_rad(60.0)))
	_check.call(VrHud.facing(p, Vector3(0, 1, 0.4)) and VrHud.facing(p, Vector3(0, 1.3, 0.4))
			and not VrHud.facing(p, at60) and not VrHud.facing(p, Vector3(0, 1, -0.4)),
			"vr hud: shown when its face is turned to the head (37 deg yes, 60 deg and behind no)")
	_check.call(not VrHud.facing(p, Vector3(0, 1, 0.8)) and not VrHud.facing(p, Vector3(NAN, 1, 0.4))
			and not VrHud.facing(p, p.origin) and not VrHud.facing(Transform3D(Basis.from_scale(Vector3.ZERO), p.origin), Vector3(0, 1, 0.4)),
			"vr hud: not shown too far (0.8 m), on bad input or a flat frame")
	_check.call(VrHud.doll_slot("arm_l") == "arm_l" and VrHud.doll_slot("hand_prosthetic_r") == "hand_r"
			and VrHud.doll_slot("arm_stub_l") == "arm_l" and VrHud.doll_slot("big_head") == "head"
			and VrHud.doll_slot("eyes") == "eyes" and VrHud.doll_slot("debug_tail") == "" and VrHud.doll_slot("bp_null") == ""
			and VrHud.doll_slot("part_999") == "" and VrHud.doll_slot("") == "", "vr hud: CDDA body parts on the doll")
	_check.call(VrHud.fit("x".repeat(100), 10).length() == 10 and VrHud.fit("x".repeat(100), 10).ends_with("…")
			and VrHud.fit("abc", 10) == "abc", "vr hud: lines capped with an ellipsis")


func _test_settings() -> void:
	_check.call(VrSettings.DEFAULTS["wrist_hud"] == "on" and VrSettings.clean("wrist_hud", "off") == "off"
			and VrSettings.clean("wrist_hud", true) == null and VrSettings.clean("wrist_hud", "maybe") == null,
			"vr hud setting: on by default, values checked")
	_check.call(VrSettings.from_args({"vr-hud": "off"})["wrist_hud"] == "off"
			and VrSettings.from_args({"vr-hud": "maybe"})["wrist_hud"] == "on"
			and VrSettings.step(VrSettings.DEFAULTS, "wrist_hud", 1) == "off"
			and VrSettings.ROWS.any(func(r: Array) -> bool: return r[0] == "wrist_hud")
			and VrSettings.label("wrist_hud", "on").length() > 2, "vr hud setting: --vr-hud, menu row and label")


func _test_content(tables: IdTables) -> void:
	var hud := VrHud.new()
	var torso: ColorRect = hud.doll["torso"]
	_check.call(VrHud.shown(hud.warn_labels).is_empty() and VrHud.shown(hud.msg_labels).is_empty()
			and VrHud.shown(hud.need_labels).is_empty() and torso.color == VrHud.NO_DATA,
			"vr hud: no data, an empty panel")
	var h := HudData.new()
	hud.data = h
	_check.call(VrHud.shown(hud.need_labels).is_empty() and torso.color == VrHud.NO_DATA,
			"vr hud: no snapshot: needs unknown, none shown; the doll grey")
	var have := ["torso", "arm_l", "leg_r", "hand_prosthetic_r"].all(func(id: String) -> bool: return tables.body_parts.find(id) >= 0)
	var s := _snap(tables, [["torso", 80, 80], ["arm_l", 0, 60], ["leg_r", 40, 60, 2], ["hand_prosthetic_r", 10, 60]])
	s.player_stamina = 40
	s.player_stamina_max = 100
	s.player_needs = {"thirst": 300, "sleepiness": 0, "pain": 25, "morale": 0}
	h.update(s, tables)
	var arm: ColorRect = hud.doll["arm_l"]
	var leg: ColorRect = hud.doll["leg_r"]
	var hand: ColorRect = hud.doll["hand_r"]
	var vis := func(r: ColorRect, mark: String) -> bool: return (r.get_node(mark) as Control).visible
	_check.call(have and torso.color == Color(HudData.level_color(HudData.OK), 0.9)
			and arm.color == Color(HudData.level_color(HudData.BROKEN), 0.9) and vis.call(arm, "Broken") and not vis.call(arm, "Bleed")
			and leg.color == Color(HudData.level_color(HudData.BAD), 0.9) and vis.call(leg, "Bleed") and not vis.call(leg, "Broken")
			and hand.color == Color(HudData.level_color(HudData.BAD), 0.9) and (hud.doll["foot_l"] as ColorRect).color == VrHud.NO_DATA
			and not vis.call(torso, "Broken"), "vr hud: the doll coloured by level, broken crossed, bleeding dotted, a prosthetic on its limb")
	var needs := VrHud.shown(hud.need_labels)
	_check.call(needs == PackedStringArray(["Stamina 40%", "Dehydrated", "Moderate pain"])
			and hud.need_labels[1].get_theme_color("font_color") == HudData.level_color(HudData.BAD)
			and hud.need_labels[2].get_theme_color("font_color") == HudData.level_color(HudData.HURT),
			"vr hud: known needs with CDDA's words and level colours; unknown and wordless ones hidden (%s)" % [needs])
	var warns := VrHud.shown(hud.warn_labels)
	_check.call(warns.size() == 3 and warns[0] == "Left Arm broken" and "Dehydrated" in warns
			and "Bleeding (right leg)" in warns and hud.warn_labels[0].get_theme_color("font_color") == HudData.level_color(HudData.BROKEN),
			"vr hud: warnings, worst first (%s)" % [warns])
	var ev: Array = []
	for i in 6:
		ev.append({"kind": "message", "text": "m%d" % i})
	ev.append({"kind": "message", "text": "y".repeat(150)})
	h.on_events(ev)
	var msgs := VrHud.shown(hud.msg_labels)
	_check.call(msgs.size() == VrHud.MSG_LINES and msgs[0] == "m3" and msgs[2] == "m5"
			and msgs[3].length() == VrHud.MSG_CHARS and msgs[3].ends_with("…"),
			"vr hud: the last 4 messages, newest at the bottom, long ones cut (%s)" % [msgs])
	# Hostile or odd entries (another writer than HudData): skipped or clamped, never an error.
	var odd: Array[Dictionary] = [{"id": 5, "text": 7, "level": "bad"}, {"text": "w".repeat(300), "level": 1e9},
			{"id": "x", "text": "low", "level": -50}]
	h.warnings = odd
	h.changed.emit(PackedStringArray(["warnings"]))
	warns = VrHud.shown(hud.warn_labels)
	_check.call(warns.size() == 2 and warns[0].length() == VrHud.WARN_CHARS and warns[1] == "low"
			and hud.warn_labels[0].get_theme_color("font_color") == HudData.level_color(HudData.BROKEN),
			"vr hud: bad warning entries skipped, long text bounded, levels clamped (%s)" % [warns])
	var body: Array[Dictionary] = [{"part": 5, "level": "x"}, {"part": "torso", "level": 99, "bleed": "a"}, {}]
	h.body = body
	h.needs = {"stamina": "junk", "thirst": {"value": 1e30, "word": 5, "level": 2}}
	h.changed.emit(PackedStringArray(["body", "needs"]))
	_check.call(torso.color == Color(HudData.level_color(HudData.BROKEN), 0.9) and not vis.call(torso, "Bleed")
			and arm.color == VrHud.NO_DATA and VrHud.shown(hud.need_labels).is_empty(),
			"vr hud: odd body and need entries skipped or clamped")
	hud.data = null
	_check.call(VrHud.shown(hud.warn_labels).is_empty() and VrHud.shown(hud.msg_labels).is_empty()
			and torso.color == VrHud.NO_DATA and not h.changed.is_connected(hud._on_changed),
			"vr hud: data taken away: empty again, no longer listening")
	hud.free()


func _effect(id: String, text: String, rating: int, part := 0) -> Dictionary:
	return {"id": id, "name": text, "body_part": part, "intensity": 1, "rating": rating, "seconds_left": -1}


## The move line, the mood line and the effects: HudData's own lines; bad effects first, the rest counted; odd
## entries skipped; nothing when the data doesn't say.
func _test_state_lines(tables: IdTables) -> void:
	var hud := VrHud.new()
	var h := HudData.new()
	hud.data = h
	_check.call(VrHud.shown(hud.effect_labels).is_empty() and not hud.move_label.visible and not hud.mood_label.visible,
			"vr hud: no effects, move or mood known: those lines stay empty")
	var s := Snapshot.new()
	var fx: Array[Dictionary] = [_effect("took_xanax", "Calm", Snapshot.EFFECT_GOOD), _effect("stunned", "Stunned", Snapshot.EFFECT_BAD),
			_effect("bleed", "Bleeding", Snapshot.EFFECT_BAD), _effect("hurt", "Hurt", Snapshot.EFFECT_BAD, tables.body_parts.find("arm_l"))]
	s.player_effects = fx
	s.player_move_mode = 3
	s.player_stamina = 5
	s.player_stamina_max = 100
	var before := hud._dirty
	hud._dirty = false
	h.update(s, tables)
	var lines := VrHud.shown(hud.effect_labels)
	_check.call(lines == PackedStringArray(["Stunned", "Hurt (left arm)", "Calm"]) and hud._dirty
			and hud.effect_labels[0].get_theme_color("font_color") == HudData.level_color(HudData.HURT)
			and hud.effect_labels[2].get_theme_color("font_color") == HudData.level_color(HudData.OK),
			"vr hud: the effects, bad ones first, coloured; bleeding stays on the doll (%s)" % [lines])
	_check.call(hud.move_label.visible and hud.move_label.text == VrHud.fit("Running (stamina 5%)", VrHud.STATE_CHARS)
			and hud.move_label.get_theme_color("font_color") == HudData.level_color(HudData.BAD) and (before or true),
			"vr hud: the move line, coloured by stamina while running (%s)" % hud.move_label.text)
	var many: Array[Dictionary] = []
	for i in 9:
		many.append(_effect("e%d" % i, "Effect %d" % i, Snapshot.EFFECT_BAD if i == 8 else Snapshot.EFFECT_NEUTRAL))
	s.player_effects = many
	h.update(s, tables)
	lines = VrHud.shown(hud.effect_labels)
	_check.call(lines.size() == VrHud.EFFECT_LINES and lines[0] == "Effect 8" and lines[1] == "Effect 0"
			and lines[VrHud.EFFECT_LINES - 1] == "+4 more", "vr hud: more effects than lines: the last line counts the rest (%s)" % [lines])
	# Odd entries from another writer: skipped or clamped, never an error.
	var odd: Array[Dictionary] = [{"text": 5}, {}, {"text": "z".repeat(200), "level": 1e9}, {"text": "ok", "level": "x"}]
	h.effects = odd
	h.move = {"text": 7}
	h.changed.emit(PackedStringArray(["effects", "move"]))
	lines = VrHud.shown(hud.effect_labels)
	_check.call(lines.size() == 2 and lines[0].length() == VrHud.EFFECT_CHARS and lines[1] == "ok" and not hud.move_label.visible,
			"vr hud: odd effect and move entries skipped, long text bounded (%s)" % [lines])
	# The mood line: read duck-typed (HudData gets it from lead-ui): a text, or {text, level}.
	_check.call(VrHud._line_of({"text": "Content", "level": HudData.OK}) == ["Content", HudData.OK]
			and VrHud._line_of("x") == [] and VrHud._line_of({"text": ""}) == [] and VrHud._line_of(null) == []
			and (VrHud._line_of({"text": "m".repeat(500)})[0] as String).length() == VrHud.MAX_MOOD,
			"vr hud: a state line is {text, level}; anything else is no line")
	var mood := {"value": -20, "word": "Unhappy", "level": HudData.HURT, "text": "Mood: Unhappy (Wet -12, Cold -8, +2 more)",
			"reasons": [{"name": "Wet", "value": -12}, {"name": "Cold", "value": -8}], "cue": -0.4}
	_check.call(VrHud.mood_text(mood) == ["Unhappy (Wet)", HudData.HURT]
			and VrHud.mood_text({"word": "Content", "level": HudData.OK, "reasons": []}) == ["Content", HudData.OK]
			and VrHud.mood_text({"word": "Sad", "reasons": [7, {"name": 5}]}) == ["Sad", HudData.UNKNOWN]
			and VrHud.mood_text({"text": "Mood: fine", "level": HudData.OK}) == ["Mood: fine", HudData.OK]
			and VrHud.mood_text("Calm") == ["Calm", HudData.UNKNOWN] and VrHud.mood_text({}) == []
			and VrHud.mood_text(null) == [] and VrHud.mood_text(5) == [],
			"vr hud: the mood line is the mood's word and its strongest reason; odd moods give no line")
	if "mood" in h:
		h.set("mood", mood)
		h.changed.emit(PackedStringArray(["mood"]))
		_check.call(hud.mood_label.visible and hud.mood_label.text == "Unhappy (Wet)"
				and hud.mood_label.get_theme_color("font_color") == HudData.level_color(HudData.HURT),
				"vr hud: the mood line shows HudData's mood")
	else:
		_check.call(hud.mood_line().is_empty() and not hud.mood_label.visible, "vr hud: HudData has no mood yet: no mood line")
	hud.data = null
	_check.call(VrHud.shown(hud.effect_labels).is_empty() and not hud.move_label.visible and not hud.mood_label.visible,
			"vr hud: data taken away: the state lines are empty again")
	hud.free()


func _test_rig(root: Node, tables: IdTables) -> void:
	var world := WorldView.new()
	var rig := VrRig.new(world, {"hands": "boxes", "blink": false})
	root.add_child(rig)
	var hud := rig.hud
	var h := HudData.new()
	hud.data = h
	rig.camera.position = Vector3(0, 1.6, 0)
	rig.left.transform = Transform3D(Basis(), Vector3(-0.2, 1.1, -0.3))
	rig.right.transform = Transform3D(Basis(), Vector3(0.2, 1.1, -0.3))
	rig.pose_hands()
	# Box hands, right-handed: inside the left forearm, face toward the middle (+X), up toward the thumb.
	var f: Variant = VrHud.forearm_frame(rig)
	var wrist := rig.left.global_transform * VrRig.BOX_WRIST
	_check.call(f is Transform3D and (f as Transform3D).basis.z.x > 0.9 and (f as Transform3D).basis.y.y > 0.9
			and (f as Transform3D).origin.distance_to(wrist) < 0.12 and (f as Transform3D).origin.z > wrist.z,
			"vr hud: inside the left forearm (box hand), behind the wrist, face in, up to the thumb")
	var fx: Transform3D = f if f is Transform3D else Transform3D()
	rig.camera.global_position = fx.origin + fx.basis.z * 0.4
	rig.place_hud(0.05)
	_check.call(hud.visible and hud.alpha > 0.3 and hud.alpha < 0.4 and hud.global_transform.is_equal_approx(fx)
			and hud.redraws == 1 and hud.viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
			"vr hud: turned to the eyes it fades in, rendered once")
	rig.place_hud(0.2)
	rig.place_hud(0.016)
	_check.call(hud.visible and hud.alpha == 1.0 and hud.redraws == 1, "vr hud: shown, no new render without a change")
	hud.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED   # as the renderer leaves it
	h.on_events([{"kind": "message", "text": "You hear a noise."}])
	rig.place_hud(0.016)
	_check.call(hud.redraws == 2 and hud.viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
			"vr hud: a new message renders it once more")
	h.set_held({"main": {"liquid": "water", "ml": 100, "capacity_ml": 500}})
	rig.place_hud(0.016)
	_check.call(hud.redraws == 2, "vr hud: a change it doesn't show (held) doesn't render")
	rig.camera.global_position = fx.origin - fx.basis.z * 0.4
	rig.place_hud(0.05)
	_check.call(hud.visible and hud.alpha > 0.6 and hud.alpha < 0.7, "vr hud: turned away it fades out ...")
	rig.place_hud(0.2)
	_check.call(not hud.visible and hud.alpha == 0.0, "vr hud: ... and hides")
	h.on_events([{"kind": "message", "text": "Hidden."}])
	rig.place_hud(0.016)
	_check.call(hud.redraws == 2, "vr hud: hidden: a change waits until it shows")
	rig.camera.global_position = fx.origin + fx.basis.z * 0.9
	rig.place_hud(0.2)
	_check.call(not hud.visible and hud.redraws == 2, "vr hud: too far from the eyes: hidden")
	rig.camera.global_position = fx.origin + fx.basis.z * 0.4
	rig.place_hud(0.016)
	_check.call(hud.visible and hud.redraws == 3, "vr hud: shown again, the waiting change rendered")
	# A new bad warning buzzes the off (left) controller once, shown or not.
	rig.camera.global_position = fx.origin - fx.basis.z * 0.4
	rig.place_hud(0.2)
	var b0 := rig.buzzes.duplicate()
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60]]), tables)
	_check.call(not hud.visible and rig.buzzes[0] == b0[0] + 1 and rig.buzzes[1] == b0[1] and hud.alerts == 1,
			"vr hud: a broken arm buzzes the off controller once, the panel hidden")
	h.on_events([{"kind": "message", "text": "Ouch."}])
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60], ["leg_r", 50, 60, 1]]), tables)
	_check.call(rig.buzzes[0] == b0[0] + 1 and hud.alerts == 1, "vr hud: messages, a known warning and a light bleed don't buzz")
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60], ["leg_r", 50, 60, 2]]), tables)
	_check.call(rig.buzzes[0] == b0[0] + 2 and hud.alerts == 2, "vr hud: a heavy bleed (new bad warning) buzzes again")
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 30, 60]]), tables)
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60]]), tables)
	_check.call(hud.alerts == 2, "vr hud: a warning back within a short while doesn't buzz again")
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 30, 60]]), tables)
	for i in 31:
		rig.place_hud(1.0)
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60]]), tables)
	_check.call(hud.alerts == 3 and rig.buzzes[0] == b0[0] + 3, "vr hud: ... but does after %d s" % VrHud.REARM_S)
	# The setting: off hides it and silences the buzz; on again shows it.
	rig.camera.global_position = fx.origin + fx.basis.z * 0.4
	rig.settings["wrist_hud"] = "off"
	rig.place_hud(0.2)
	h.update(_snap(tables, [["torso", 80, 80], ["arm_l", 0, 60], ["leg_l", 10, 60]]), tables)   # nothing new and bad
	h.update(_snap(tables, [["torso", 0, 80], ["arm_l", 0, 60]]), tables)   # torso broken: new
	_check.call(not hud.visible and not hud.enabled and hud.alerts == 3, "vr hud setting off: hidden and silent")
	rig.settings["wrist_hud"] = "on"
	rig.place_hud(0.2)
	_check.call(hud.visible and hud.enabled and hud.alerts == 3, "vr hud setting on: shown again, old warnings don't buzz")
	# Finger hands: on the hand's wrist joints.
	rig.settings["hands"] = "buttons"
	rig._boxes[0].visible = false
	rig._boxes[1].visible = false
	var open := VrHand.curls_from_buttons(0.0, false, 0.0, false)
	rig.left_hand.pose_from_controller(rig.left.transform, open)
	f = VrHud.forearm_frame(rig)
	var fw := rig.global_transform * rig.left_hand.wrist()
	_check.call(f is Transform3D and (f as Transform3D).basis.z.x > 0.9 and (f as Transform3D).basis.y.y > 0.8
			and (f as Transform3D).origin.distance_to(fw) < 0.12, "vr hud: inside the left finger hand's forearm, face in")
	# Left-handed: the right forearm, face toward the middle (-X); the buzz in the right controller.
	rig.settings["main_hand"] = "left"
	rig.right_hand.pose_from_controller(rig.right.transform, open)
	f = VrHud.forearm_frame(rig)
	fw = rig.global_transform * rig.right_hand.wrist()
	_check.call(f is Transform3D and (f as Transform3D).basis.z.x < -0.9 and (f as Transform3D).basis.y.y > 0.8
			and (f as Transform3D).origin.distance_to(fw) < 0.12, "vr hud left-handed: inside the right finger hand's forearm")
	rig.settings["hands"] = "boxes"
	rig.pose_hands()
	f = VrHud.forearm_frame(rig)
	wrist = rig.right.global_transform * VrRig.BOX_WRIST
	_check.call(f is Transform3D and (f as Transform3D).basis.z.x < -0.9 and (f as Transform3D).origin.distance_to(wrist) < 0.12,
			"vr hud left-handed: inside the right forearm (box hand)")
	var b1 := rig.buzzes.duplicate()
	h.update(_snap(tables, [["torso", 0, 80], ["arm_l", 0, 60], ["arm_r", 0, 60]]), tables)
	_check.call(rig.buzzes[1] == b1[1] + 1 and rig.buzzes[0] == b1[0], "vr hud left-handed: the buzz in the right controller")
	# No hand drawn or tracked: nowhere to show.
	rig.settings["hands"] = "auto"
	rig.pose_hands()
	rig.place_hud(0.016)
	_check.call(VrHud.forearm_frame(rig) == null and not hud.visible, "vr hud: no off hand, no panel")
	hud.data = null
	rig.free()
	world.free()
