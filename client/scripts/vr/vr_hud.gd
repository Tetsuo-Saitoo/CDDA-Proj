class_name VrHud
extends Node3D
## L4: the wrist HUD, the VR view of HudData (the screen view is ui/hud_view.gd). A small panel (about 12 x 10 cm)
## on the inside of the off-hand forearm (left, right when left-handed: VrSettings `main_hand`; the compass is on
## the back of the same wrist). It shows when you turn the inner wrist toward your eyes (`facing`) and fades in
## and out. Content: the body as a doll (your left on the left) coloured by level, broken parts crossed, bleeding
## ones dotted red; the needs CDDA has words for; the warnings, worst first; how you move ("Running (stamina 23%)")
## and your mood (HudData `mood`, read duck-typed: its word and strongest reason, "Unhappy (Wet)"); the other effects ("Stunned",
## "Hurt (left arm)"), bad ones first, the last line counting what doesn't fit; the last messages; an amber
## "CHEATS: a, b" line while testing cheats are on (K7: HudData `cheats`, read duck-typed). Text is plain
## Label text, capped per line.
## Drawn by Controls in a SubViewport onto a quad, and the viewport renders only after HudData's `changed` named a
## group it shows, once, when the panel is turned to the eyes (VR runs at 90 fps). A new bad warning (level BAD or
## worse, not shown in the last REARM_S) buzzes the off controller even while the panel is hidden (`alerted`;
## VrRig does the buzz). Setting VrSettings `wrist_hud` on / off. Nothing here talks to the sim.

## A new bad warning came in (VrRig buzzes the off controller).
signal alerted

const SIZE_M := Vector2(0.12, 0.10)   # the panel, metres
const PX := Vector2i(480, 400)        # its texture, 4 px per mm
const ALL_PARTS: PackedStringArray = ["body", "needs", "warnings", "messages", "cheats", "effects", "move", "mood"]
const LIFT := 0.035     # metres from the wrist line out of the inner forearm (over the body's arm)
const BACK := 0.075     # the panel's middle this far from the wrist toward the elbow
const SHOW_DEG := 50.0  # shown while its face is within this of the direction to the head ...
const SHOW_DIST := 0.7  # ... and the head is this close
const FADE_S := 0.15
const REARM_S := 30.0   # a bad warning gone this long buzzes again when it comes back
const MAX_SEEN := 64
const WARN_LINES := 3
const NEED_LINES := 6
const MSG_LINES := 4
const EFFECT_LINES := 6  # two rows of EFFECT_COLS under the doll
const EFFECT_COLS := 3
const EFFECT_CHARS := 17
const STATE_CHARS := 22  # the move line and the mood line, side by side
const MAX_MOOD := 64     # characters read from a mood line
const WARN_CHARS := 30   # per line, so a line fits its label
const NEED_CHARS := 16
const MSG_CHARS := 52
const CHEAT_CHARS := 36
const BG := Color(0.04, 0.05, 0.07, 0.72)
const NO_DATA := Color(0.6, 0.6, 0.6, 0.3)   # a doll part the snapshot says nothing about
## The doll: slot -> rectangle (px, doll space), drawn in this order (eyes and mouth over the head).
const DOLL := {
	"head": Rect2(40, 0, 30, 30), "eyes": Rect2(45, 8, 20, 6), "mouth": Rect2(49, 19, 12, 5),
	"torso": Rect2(36, 33, 38, 70), "arm_l": Rect2(19, 33, 14, 62), "arm_r": Rect2(77, 33, 14, 62),
	"hand_l": Rect2(17, 98, 18, 16), "hand_r": Rect2(75, 98, 18, 16), "leg_l": Rect2(36, 106, 18, 70),
	"leg_r": Rect2(56, 106, 18, 70), "foot_l": Rect2(30, 179, 24, 13), "foot_r": Rect2(56, 179, 24, 13),
}

## What it shows; null: an empty panel.
var data: HudData:
	set(d):
		if data != null and data.changed.is_connected(_on_changed):
			data.changed.disconnect(_on_changed)
		data = d
		if d != null:
			d.changed.connect(_on_changed)
		_show(ALL_PARTS, true)
## VrSettings `wrist_hud` (VrRig.place_hud): off hides it and silences the buzz.
var enabled := true:
	set(v):
		enabled = v
		if not v:
			_set_alpha(0.0)
## 0 .. 1 over the fade (ready for a HUD-wide opacity setting; HudSettings has only the compass's).
var opacity := 1.0:
	set(v):
		opacity = HudSettings.clamp_opacity(v)
		_set_alpha(alpha)
var alpha := 0.0          # the fade, 0 hidden .. 1 shown
var redraws := 0          # viewport renders asked for (tests count them)
var alerts := 0           # new bad warnings signalled
var viewport: SubViewport
var doll := {}            # slot -> ColorRect, with "Broken" (Label) and "Bleed" (Panel) children
var warn_labels: Array[Label] = []
var need_labels: Array[Label] = []
var msg_labels: Array[Label] = []
var effect_labels: Array[Label] = []
var move_label: Label     # how the player moves (HudData.move)
var mood_label: Label     # the mood line (HudData `mood`, when it has one)
var cheat_label: Label    # "CHEATS: ..." while any testing cheat is on
var _quad: MeshInstance3D
var _mat: StandardMaterial3D
var _dirty := true        # the labels changed since the viewport last rendered
var _clock := 0.0         # seconds placed (REARM_S)
var _bad_now := {}        # bad warning ids in the last update
var _gone_at := {}        # bad warning id -> _clock when it went away


func _init() -> void:
	name = "WristHud"
	top_level = true   # placed in world space each frame
	visible = false
	viewport = SubViewport.new()
	viewport.name = "HudViewport"
	viewport.size = PX
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	viewport.add_child(_build_panel())
	var q := QuadMesh.new()   # faces +Z
	q.size = SIZE_M
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_mat.disable_fog = true
	_mat.albedo_color = Color(1, 1, 1, 0)
	q.material = _mat
	_quad = MeshInstance3D.new()
	_quad.name = "Panel"
	_quad.mesh = q
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)
	_show(ALL_PARTS, true)


func _ready() -> void:
	_mat.albedo_texture = viewport.get_texture()


## Places the panel for this frame on the off forearm and fades it toward shown while it faces the head; renders
## the viewport once when it is about to show changed content. Hidden at once when off or the hand is lost.
func place(rig: VrRig, delta: float) -> void:
	_clock += clampf(delta, 0.0, 1.0)
	var f: Variant = forearm_frame(rig) if enabled and opacity > 0.01 else null
	if f == null:
		_set_alpha(0.0)
		return
	if is_inside_tree():
		global_transform = f
	else:
		transform = f
	var want := rig.camera != null and rig.camera.is_inside_tree() and facing(f, rig.camera.global_position)
	if want and _dirty:
		_dirty = false
		redraws += 1
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_set_alpha(move_toward(alpha, 1.0 if want else 0.0, clampf(delta, 0.0, 1.0) / FADE_S))


## The panel's face (+Z) is turned to a head at `head`: within `max_deg` of the direction to it and no farther
## than `max_dist`.
static func facing(panel: Transform3D, head: Vector3, max_deg := SHOW_DEG, max_dist := SHOW_DIST) -> bool:
	if not panel.is_finite() or not head.is_finite():
		return false
	var to := head - panel.origin
	var d := to.length()
	var n := panel.basis.z
	if d < 0.0001 or d > max_dist or n.length() < 0.0001:
		return false
	return n.normalized().dot(to / d) >= cos(deg_to_rad(max_deg))


## Where the panel goes (global), or null when the off hand is neither drawn nor tracked: on the inside of the
## forearm, face out of the palm side, its up toward the thumb, so it reads elbow to hand. Finger hands use the
## VrHand joints, box hands and bare controllers the controller (as VrCompass.wrist_frame does for the back).
static func forearm_frame(rig: VrRig) -> Variant:
	var h := rig.off_hand_model()
	var c := rig.off_ctrl()
	if h == null or c == null:
		return null
	var out := -1.0 if h.left else 1.0   # the back of a hand faces out: -X for the left, +X for the right
	var xf := rig.global_transform if rig.is_inside_tree() else rig.transform
	if h.visible and h.joints.size() == VrHand.JOINTS:
		var p := h.joints
		var along := xf.basis * (p[12] - p[1])   # wrist -> middle knuckle
		var thumb := xf.basis * (p[7] - p[22])   # little -> index knuckle
		return panel_frame(xf * p[1], thumb.cross(along) * out, thumb, along)
	var box := 0 if c == rig.left else 1
	if c.get_is_active() or rig._boxes[box].visible:
		var g := c.global_transform if c.is_inside_tree() else xf * c.transform
		return panel_frame(g * VrRig.BOX_WRIST, -g.basis.x * out, g.basis.y, -g.basis.z)
	return null


## A panel frame on a forearm: face (+Z) along `palm`, up (+Y) toward `thumb`, its middle LIFT out of the wrist
## line and BACK toward the elbow (against `along`, wrist to fingers). Null for a degenerate hand.
static func panel_frame(wrist: Vector3, palm: Vector3, thumb: Vector3, along: Vector3) -> Variant:
	if not wrist.is_finite() or not palm.is_finite() or not thumb.is_finite() or not along.is_finite() \
			or palm.length() < 0.000001 or along.length() < 0.001:
		return null
	var z := palm.normalized()
	var y := thumb - z * thumb.dot(z)
	if y.length() < 0.0001:
		y = z.cross(along)
	if y.length() < 0.0001:
		return null
	y = y.normalized()
	var x := y.cross(z).normalized()
	var a := along - z * along.dot(z)
	if a.length() < 0.0001:
		a = along
	return Transform3D(Basis(x, y, z), wrist + z * LIFT - a.normalized() * BACK)


## The doll slot of a CDDA bodypart id ("" when it has none): side from the _l / _r end, so prosthetics and stubs
## sit where the limb is.
static func doll_slot(id: String) -> String:
	if id in ["head", "eyes", "mouth", "torso"]:
		return id
	if id.ends_with("head"):   # big_head
		return "head"
	var side := "_l" if id.ends_with("_l") else ("_r" if id.ends_with("_r") else "")
	if side.is_empty():
		return ""
	for limb: String in ["arm", "hand", "leg", "foot"]:
		if id.begins_with(limb + "_") or id == limb + side:
			return limb + side
	return ""


## `s` capped at `cap` characters (an ellipsis ends a cut line).
static func fit(s: String, cap: int) -> String:
	return s if s.length() <= cap else s.left(maxi(cap - 1, 0)) + "…"


## The texts of the labels that show, in order (tests read them).
static func shown(labels: Array[Label]) -> PackedStringArray:
	var out := PackedStringArray()
	for l in labels:
		if l.visible:
			out.append(l.text)
	return out


## [text, level] per need line: stamina in percent, the others by CDDA's word; unknown and wordless needs are left
## out (as the screen's HudView).
func need_lines() -> Array:
	var out: Array = []
	if data == null:
		return out
	for k: String in HudData.NEEDS:
		var n: Variant = data.needs.get(k)
		if not n is Dictionary:
			continue
		var lv := _level((n as Dictionary).get("level"))
		if lv == HudData.UNKNOWN:
			continue
		var w: Variant = (n as Dictionary).get("word")
		var v: Variant = (n as Dictionary).get("value")
		if k == "stamina" and (v is int or v is float):
			out.append(["Stamina %d%%" % clampi(int(v), 0, 100), lv])
		elif w is String and not (w as String).is_empty():
			out.append([w, lv])
	return out


## [text, level] per effect line: HudData.effects with the bad ones first (each group in CDDA's order), at most
## EFFECT_LINES; with more, the last line says how many aren't shown. Odd entries are skipped.
func effect_lines() -> Array:
	var bad: Array = []
	var rest: Array = []
	var list: Variant = data.get("effects") if data != null else null
	if not list is Array:
		return []
	for i in mini((list as Array).size(), HudData.MAX_EFFECTS):
		var e: Variant = (list as Array)[i]
		var t: Variant = (e as Dictionary).get("text") if e is Dictionary else null
		if not t is String or (t as String).is_empty():
			continue
		var lv := _level((e as Dictionary).get("level"))
		(bad if lv >= HudData.HURT else rest).append([t, lv])
	var all := bad + rest
	if all.size() <= EFFECT_LINES:
		return all
	var out := all.slice(0, EFFECT_LINES - 1)
	out.append(["+%d more" % (all.size() - EFFECT_LINES + 1), HudData.UNKNOWN])
	return out


## [text, level] of the move line (HudData.move: "Walking", "Running (stamina 23%)"), [] when unknown.
func move_line() -> Array:
	var m: Variant = data.get("move") if data != null else null
	return _line_of(m)


## [text, level] of the mood line (HudData `mood`), [] when there is none.
func mood_line() -> Array:
	return mood_text(data.get("mood") if data != null else null)


## [text, level] for a mood ({word, level, reasons: [{name, value}], text, ...}): its word and the strongest reason
## ("Unhappy (Wet)": the wrist line is short), else its ready text; a plain text works too. [] for anything else.
static func mood_text(m: Variant) -> Array:
	if m is String:
		return _line_of({"text": m})
	if not m is Dictionary:
		return []
	var w: Variant = (m as Dictionary).get("word")
	if not w is String or (w as String).is_empty():
		return _line_of(m)
	var text := (w as String).left(MAX_MOOD)
	var rs: Variant = (m as Dictionary).get("reasons")
	var first: Variant = (rs as Array)[0] if rs is Array and not (rs as Array).is_empty() else null
	var n: Variant = (first as Dictionary).get("name") if first is Dictionary else null
	if n is String and not (n as String).is_empty():
		text += " (%s)" % (n as String).left(MAX_MOOD)
	return [text, _level((m as Dictionary).get("level"))]


## [text, level] from a {text, level} line, [] for anything else or an empty text.
static func _line_of(v: Variant) -> Array:
	var t: Variant = (v as Dictionary).get("text") if v is Dictionary else null
	if not t is String or (t as String).is_empty():
		return []
	return [(t as String).left(MAX_MOOD), _level((v as Dictionary).get("level"))]


func _set_line(l: Label, line: Array, cap: int) -> void:
	l.visible = not line.is_empty()
	if l.visible:
		l.text = fit(line[0], cap)
		l.add_theme_color_override("font_color", HudData.level_color(line[1]))


func _set_alpha(a: float) -> void:
	alpha = clampf(a, 0.0, 1.0)
	visible = alpha > 0.001
	if _mat != null:
		_mat.albedo_color.a = alpha * opacity


func _on_changed(parts: PackedStringArray) -> void:
	_show(parts, false)


## Fills the groups named in `parts`; `seeding`: warnings already there are not new (no buzz).
func _show(parts: PackedStringArray, seeding: bool) -> void:
	var any := false
	if "body" in parts:
		_show_body()
		any = true
	if "needs" in parts:
		var lines := need_lines()
		for i in need_labels.size():
			var l := need_labels[i]
			l.visible = i < lines.size()
			if l.visible:
				l.text = fit(lines[i][0], NEED_CHARS)
				l.add_theme_color_override("font_color", HudData.level_color(lines[i][1]))
		any = true
	if "warnings" in parts:
		_show_warnings(seeding)
		any = true
	if "messages" in parts:
		var msgs: Array = []
		if data != null:
			msgs = data.messages.slice(maxi(0, data.messages.size() - MSG_LINES))
		for i in msg_labels.size():
			var l := msg_labels[i]
			var k := i - (MSG_LINES - msgs.size())   # the newest at the bottom
			var m: Variant = msgs[k] if k >= 0 else null
			var t: Variant = (m as Dictionary).get("text") if m is Dictionary else null
			l.visible = t is String and not (t as String).is_empty()
			l.text = fit(t, MSG_CHARS) if l.visible else ""
			l.modulate.a = lerpf(0.55, 1.0, float(i + 1) / MSG_LINES)
		any = true
	if "effects" in parts:
		var lines := effect_lines()
		for i in effect_labels.size():
			_set_line(effect_labels[i], lines[i] if i < lines.size() else [], EFFECT_CHARS)
		any = true
	if "move" in parts:
		_set_line(move_label, move_line(), STATE_CHARS)
		any = true
	if "mood" in parts or "needs" in parts:   # morale is a need: a mood line may come with it
		_set_line(mood_label, mood_line(), STATE_CHARS)
		any = true
	if "cheats" in parts:
		# HudData gets `cheats` with lead-ui's K7 work: until then get() is null and the line stays hidden.
		var t := VrCheats.marker(data.get("cheats") if data != null else null)
		cheat_label.visible = not t.is_empty()
		cheat_label.text = fit(t, CHEAT_CHARS)
		any = true
	if any:
		_dirty = true


func _show_body() -> void:
	var worst := {}   # slot -> [level, bleeding, broken]: an arm and its prosthetic share a slot, the worst shows
	if data != null:
		for i in mini(data.body.size(), HudData.MAX_PARTS):
			var p: Dictionary = data.body[i]
			var id: Variant = p.get("part")
			var slot := doll_slot(id) if id is String else ""
			if slot.is_empty():
				continue
			var lv := _level(p.get("level"))
			var bleed: Variant = p.get("bleed")
			var w: Array = worst.get(slot, [HudData.UNKNOWN, false, false])
			worst[slot] = [maxi(w[0], lv), w[1] or ((bleed is int or bleed is float) and bleed > 0),
					w[2] or lv == HudData.BROKEN]
	for slot: String in doll:
		var r: ColorRect = doll[slot]
		var w: Array = worst.get(slot, [HudData.UNKNOWN, false, false])
		r.color = NO_DATA if w[0] == HudData.UNKNOWN else Color(HudData.level_color(w[0]), 0.9)
		(r.get_node("Bleed") as Control).visible = w[1]
		(r.get_node("Broken") as Control).visible = w[2]


func _show_warnings(seeding: bool) -> void:
	var list: Array = []
	if data != null:
		for i in mini(data.warnings.size(), HudData.MAX_WARNINGS):
			var w: Dictionary = data.warnings[i]
			var t: Variant = w.get("text")
			var id: Variant = w.get("id")
			if t is String and not (t as String).is_empty():
				list.append([t, _level(w.get("level")), str(id if id is String else t).left(HudData.MAX_NAME)])
	list.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])   # bad ones first
	for i in warn_labels.size():
		var l := warn_labels[i]
		l.visible = i < list.size()
		if l.visible:
			l.text = fit(list[i][0], WARN_CHARS)
			l.add_theme_color_override("font_color", HudData.level_color(list[i][1]))
	# A bad warning that wasn't in the last list (nor in the last REARM_S) is new: one buzz per update.
	var now := {}
	var fresh := false
	for w: Array in list:
		if w[1] < HudData.BAD:
			continue
		now[w[2]] = true
		if not _bad_now.has(w[2]) and (not _gone_at.has(w[2]) or _clock - float(_gone_at[w[2]]) > REARM_S):
			fresh = true
	for id: String in _bad_now:
		if not now.has(id):
			_gone_at[id] = _clock
	for id: String in now:
		_gone_at.erase(id)
	while _gone_at.size() > MAX_SEEN:
		_gone_at.erase(_gone_at.keys()[0])
	_bad_now = now
	if fresh and not seeding and enabled:
		alerts += 1
		alerted.emit()


static func _level(v: Variant) -> int:
	if v is int or (v is float and is_finite(v)):
		return clampi(int(v), HudData.UNKNOWN, HudData.BROKEN)
	return HudData.UNKNOWN


func _build_panel() -> Control:
	var root := Panel.new()
	root.name = "HudPanel"
	root.size = Vector2(PX)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG
	bg.set_corner_radius_all(14)
	bg.set_border_width_all(2)
	bg.border_color = Color(1, 1, 1, 0.15)
	root.add_theme_stylebox_override("panel", bg)
	var body := Control.new()
	body.name = "Doll"
	body.position = Vector2(12, 12)
	body.size = Vector2(110, 196)
	root.add_child(body)
	var drop := StyleBoxFlat.new()
	drop.bg_color = Color(0.95, 0.05, 0.05)
	drop.set_corner_radius_all(5)
	drop.set_border_width_all(1)
	drop.border_color = Color.WHITE
	for slot: String in DOLL:
		var rect: Rect2 = DOLL[slot]
		var r := ColorRect.new()
		r.name = slot
		r.position = rect.position
		r.size = rect.size
		r.color = NO_DATA
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var b := Panel.new()   # bleeding: a red drop at its corner
		b.name = "Bleed"
		b.size = Vector2(9, 9)
		b.position = Vector2(rect.size.x - 6, -3)
		b.add_theme_stylebox_override("panel", drop)
		b.visible = false
		r.add_child(b)
		var x := _label("Broken", 16, Vector2(rect.size.x, rect.size.y))   # broken: crossed
		x.text = "X"
		x.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		x.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		x.position = Vector2.ZERO
		x.add_theme_constant_override("outline_size", 4)
		x.add_theme_color_override("font_outline_color", Color.BLACK)
		x.visible = false
		r.add_child(x)
		body.add_child(r)
		doll[slot] = r
	for side: Array in [["L", 0.0], ["R", 98.0]]:   # your left on the left
		var s := _label("Side" + side[0], 14, Vector2(14, 18))
		s.text = side[0]
		s.position = Vector2(side[1], 0)
		s.modulate = Color(1, 1, 1, 0.5)
		s.visible = true
		body.add_child(s)
	var col := 134.0
	for i in WARN_LINES:
		var l := _label("Warning%d" % i, 22, Vector2(PX.x - col - 10, 26))
		l.position = Vector2(col, 10 + i * 26)
		root.add_child(l)
		warn_labels.append(l)
	for i in NEED_LINES:   # two columns
		var l := _label("Need%d" % i, 20, Vector2((PX.x - col - 10) / 2.0 - 4, 24))
		l.position = Vector2(col + (i % 2) * (PX.x - col - 10) / 2.0, 100 + (i >> 1) * 25)
		root.add_child(l)
		need_labels.append(l)
	var half := (PX.x - col - 10) / 2.0
	move_label = _label("Move", 18, Vector2(half - 4, 24))   # under the needs, right of the doll: move | mood
	move_label.position = Vector2(col, 180)
	root.add_child(move_label)
	mood_label = _label("Mood", 18, Vector2(half - 4, 24))
	mood_label.position = Vector2(col + half, 180)
	root.add_child(mood_label)
	var ew := (PX.x - 24) / float(EFFECT_COLS)
	for i in EFFECT_LINES:   # under the doll, EFFECT_COLS per row
		var l := _label("Effect%d" % i, 18, Vector2(ew - 4, 24))
		@warning_ignore("integer_division")
		l.position = Vector2(12 + (i % EFFECT_COLS) * ew, 214 + (i / EFFECT_COLS) * 24)
		root.add_child(l)
		effect_labels.append(l)
	cheat_label = _label("Cheats", 18, Vector2(PX.x - 24, 24))   # under the effects
	cheat_label.position = Vector2(12, 264)
	cheat_label.add_theme_color_override("font_color", VrCheats.WARN)
	root.add_child(cheat_label)
	for i in MSG_LINES:
		var l := _label("Message%d" % i, 18, Vector2(PX.x - 24, 24))
		l.position = Vector2(12, 292 + i * 24)
		root.add_child(l)
		msg_labels.append(l)
	return root


func _label(n: String, font_size: int, sz: Vector2) -> Label:
	var l := Label.new()
	l.name = n
	l.size = sz
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.visible = false
	return l
