class_name VrCompass
extends Node3D
## The compass in VR (the flat strip's logic, Compass's static functions, in a headset-friendly form): a rose
## turned to north (CDDA's north is -Z) with the creatures the player perceives at their bearing from the
## viewer: hostiles as red arrows on the rim pointing out (nearer = bigger and brighter), others as small dots
## inside it (green friendly, pale neutral), and a yellow tick where the head looks. Where (VrSettings
## `compass`): "wrist" (default) on the back of the left wrist like a watch, turn the wrist to read it; "belt"
## a ring around the waist that stays level, look down; "both"; "off". Nothing is fixed to the view (comfort).
## Opacity is the HUD's compass setting (HudSettings). Blips come from main.gd: Compass.creature_blips, the
## same list the flat strip draws. The wrist rose also sits on a box hand or a bare controller.

const WRIST_R := 0.032          # rose radius on the wrist, metres
const WRIST_LIFT := 0.024       # over the back of the wrist
const BELT_R := 0.42
const BELT_DROP := 0.62         # belt this far under the eyes
const LETTERS := {0: "N", 90: "E", 180: "S", 270: "W"}
const HEAD_COLOR := Color(1.0, 0.85, 0.2)
const DISC_COLOR := Color(0.05, 0.06, 0.08, 0.6)

var mode := "wrist":
	set(v):
		mode = v if v in ["wrist", "belt", "both", "off"] else "wrist"
var heading_deg := 0.0          # where the head looks (Compass.heading_of)
## 0 (invisible) .. 1, the HUD's compass opacity.
var opacity := 1.0:
	set(v):
		opacity = HudSettings.clamp_opacity(v)
		for r: Rose in [wrist, belt]:
			if r != null:
				r.set_opacity(opacity)
var blips: Array[Vector3] = []  # Compass.creature_blips
var wrist: Rose
var belt: Rose


func _init() -> void:
	name = "VrCompass"
	wrist = Rose.new(WRIST_R, false)
	wrist.name = "WristCompass"
	belt = Rose.new(BELT_R, true)
	belt.name = "BeltCompass"
	for r: Rose in [wrist, belt]:
		r.top_level = true   # placed in world space each frame
		r.visible = false
		add_child(r)


func set_blips(list: Array[Vector3]) -> void:
	if list == blips:
		return
	blips = list
	wrist.show_blips(list)
	belt.show_blips(list)


## Places the roses for this frame: the wrist one on the left hand (VrHand joints, else its controller), the
## belt one around the waist under the head. Hidden when off, fully transparent or the hand isn't tracked.
func place(rig: VrRig) -> void:
	var on := opacity > 0.01
	var w: Variant = wrist_frame(rig) if on and mode in ["wrist", "both"] else null
	wrist.visible = w != null
	if w != null:
		wrist.global_transform = w
		wrist.set_heading(heading_deg)
	belt.visible = on and mode in ["belt", "both"] and rig.camera != null
	if belt.visible:
		var head := rig.camera.global_position
		belt.global_transform = Transform3D(Basis(), Vector3(head.x, head.y - BELT_DROP, head.z))
		belt.set_heading(heading_deg)


## Where the wrist rose goes (global), or null when the left hand is neither drawn nor tracked.
static func wrist_frame(rig: VrRig) -> Variant:
	var h := rig.left_hand
	var xf := rig.global_transform if rig.is_inside_tree() else rig.transform
	if h != null and h.visible and h.joints.size() == VrHand.JOINTS:
		var p := h.joints
		var along := xf.basis * (p[12] - p[1])   # wrist -> middle knuckle
		var across := xf.basis * (p[7] - p[22])  # little -> index knuckle
		var back := across.cross(along)          # back of a left hand (VrHand mirrors the right one)
		if along.length() < 0.001 or back.length() < 0.000001:
			return null
		back = back.normalized()
		return Transform3D(face_north(back, along), xf * p[1] + back * WRIST_LIFT - along.normalized() * 0.01)
	var c := rig.left
	if c != null and (c.get_is_active() or rig._boxes[0].visible):
		var g := c.global_transform if c.is_inside_tree() else xf * c.transform
		var back := -g.basis.x.normalized()      # the back of the left hand faces out to the left
		return Transform3D(face_north(back, -g.basis.z), g * (VrRig.BOX_WRIST + Vector3(-WRIST_LIFT - 0.01, 0, 0)))
	return null


## A rose frame with its face (+Y) along `normal` and its -Z as close to north (-Z) as the face allows; when
## the face looks north or south, `fallback_fwd` stands in for north.
static func face_north(normal: Vector3, fallback_fwd: Vector3) -> Basis:
	var y := normal.normalized()
	var north := Vector3.FORWARD - y * Vector3.FORWARD.dot(y)
	if north.length() < 0.05:
		north = fallback_fwd - y * fallback_fwd.dot(y)
		if north.length() < 0.001:
			north = Vector3.RIGHT - y * y.x
	var z := -north.normalized()
	var x := y.cross(z).normalized()
	return Basis(x, y, x.cross(y))


## A bearing (degrees, 0 north, 90 east) as a direction in the rose's plane (-Z north, +X east).
static func dir_of(bearing: float) -> Vector3:
	var a := deg_to_rad(bearing)
	return Vector3(sin(a), 0.0, -cos(a))


## Markers for a blip list on a rose of radius r: [[kind ("arrow"/"dot"), position, size, colour], ...], hostiles
## first (on the rim, pointing out), others inside. Same nearness and colours as the flat strip.
static func layout(list: Array[Vector3], r: float) -> Array:
	var out := []
	for b: Vector3 in list:
		var t := Compass.nearness(b.y)
		if b.z == Snapshot.Creature.HOSTILE:
			out.append(["arrow", dir_of(b.x) * r * 1.08, r * lerpf(0.14, 0.26, t),
					Color(Compass.HOSTILE_COLOR, lerpf(0.45, 1.0, t))])
		else:
			var col := Compass.FRIENDLY_COLOR if b.z == Snapshot.Creature.FRIENDLY else Compass.NEUTRAL_COLOR
			out.append(["dot", dir_of(b.x) * r * 0.78, r * lerpf(0.05, 0.08, t), Color(col, lerpf(0.4, 0.9, t))])
	return out


## One compass rose: a dark disc (wrist) or ring (belt), ticks every 15 degrees (north red), N/E/S/W, the head
## tick and the creature markers. Lies in its local XZ plane, -Z north.
class Rose extends Node3D:
	var radius: float
	var ring: bool
	var opacity := 1.0
	var _arrows: MultiMesh
	var _dots: MultiMesh
	var _ticks: MultiMesh
	var _head: MeshInstance3D
	var _disc_mat: StandardMaterial3D
	var _mm_mats: Array[StandardMaterial3D] = []   # ticks, arrows, dots: opacity scales their instance colours
	var _labels: Array[Label3D] = []
	var _shown := []   # the last layout, colours before opacity

	func _init(r: float, is_ring: bool) -> void:
		radius = r
		ring = is_ring
		var disc := MeshInstance3D.new()
		_disc_mat = VrCompass._mat(DISC_COLOR, false)
		if ring:
			var t := TorusMesh.new()
			t.inner_radius = r * 0.94
			t.outer_radius = r * 1.0
			t.rings = 48
			t.ring_segments = 4
			t.material = _disc_mat
			disc.mesh = t
		else:
			var c := CylinderMesh.new()
			c.top_radius = r * 1.12
			c.bottom_radius = r * 1.12
			c.height = r * 0.08
			c.radial_segments = 24
			c.rings = 1
			c.material = _disc_mat
			disc.mesh = c
			disc.position = Vector3(0, -r * 0.05, 0)
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(disc)
		var tick := BoxMesh.new()
		tick.size = Vector3.ONE
		_ticks = _multimesh(tick, 24)
		for i in 24:
			var d := VrCompass.dir_of(i * 15.0)
			var long := r * (0.2 if i % 6 == 0 else 0.1)
			var x := d.cross(Vector3.UP)
			_ticks.set_instance_transform(i, Transform3D(Basis(x * r * 0.04, Vector3.UP * r * 0.02, -d * long),
					d * (r * 0.97 - long * 0.5) + Vector3(0, r * 0.02, 0)))
			_ticks.set_instance_color(i, Compass.HOSTILE_COLOR.lerp(Color.WHITE, 0.2) if i == 0 else Color(1, 1, 1, 0.8))
		var prism := PrismMesh.new()
		prism.size = Vector3.ONE
		_arrows = _multimesh(prism, Compass.MAX_BLIPS)
		var ball := SphereMesh.new()
		ball.radius = 1.0
		ball.height = 2.0
		ball.radial_segments = 8
		ball.rings = 4
		_dots = _multimesh(ball, Compass.MAX_OTHER_BLIPS)
		var hb := BoxMesh.new()
		hb.size = Vector3(r * 0.07, r * 0.05, r * 0.3)
		hb.material = VrCompass._mat(HEAD_COLOR, false)
		_head = MeshInstance3D.new()
		_head.mesh = hb
		_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_head)
		for deg: int in LETTERS:
			var l := Label3D.new()
			l.text = LETTERS[deg]
			l.font_size = 48
			l.outline_size = 8
			l.pixel_size = r * (0.2 if ring else 0.42) / 48.0
			l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			l.shaded = false
			l.modulate = Color(1.0, 0.4, 0.3) if deg == 0 else Color.WHITE
			l.position = VrCompass.dir_of(deg) * r * (1.12 if ring else 0.62) + Vector3(0, r * (0.12 if ring else 0.1), 0)
			add_child(l)
			_labels.append(l)
		_arrows.visible_instance_count = 0
		_dots.visible_instance_count = 0

	func _multimesh(mesh: Mesh, count: int) -> MultiMesh:
		var m := VrCompass._mat(Color.WHITE, true)
		(mesh as PrimitiveMesh).material = m
		_mm_mats.append(m)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = count
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		return mm

	func show_blips(list: Array[Vector3]) -> void:
		_shown = VrCompass.layout(list, radius)
		_paint()

	func _paint() -> void:
		var na := 0
		var nd := 0
		for m: Array in _shown:
			var pos: Vector3 = m[1]
			var s: float = m[2]
			var col: Color = m[3]
			if m[0] == "arrow" and na < _arrows.instance_count:
				var out := pos.normalized()
				var x := out.cross(Vector3.UP)
				_arrows.set_instance_transform(na, Transform3D(Basis(x * s, out * s * 1.5, Vector3.UP * s * 0.3),
						pos + Vector3(0, radius * 0.03, 0)))
				_arrows.set_instance_color(na, col)
				na += 1
			elif m[0] == "dot" and nd < _dots.instance_count:
				_dots.set_instance_transform(nd, Transform3D(Basis.from_scale(Vector3.ONE * s), pos + Vector3(0, s, 0)))
				_dots.set_instance_color(nd, col)
				nd += 1
		_arrows.visible_instance_count = na
		_dots.visible_instance_count = nd

	func arrow_count() -> int:
		return _arrows.visible_instance_count

	func dot_count() -> int:
		return _dots.visible_instance_count

	func set_heading(deg: float) -> void:
		var d := VrCompass.dir_of(deg)
		_head.transform = Transform3D(Basis.looking_at(d, Vector3.UP), d * radius * 0.85 + Vector3(0, radius * 0.04, 0))

	func set_opacity(a: float) -> void:
		opacity = a
		_disc_mat.albedo_color.a = DISC_COLOR.a * a
		for l: Label3D in _labels:
			l.modulate.a = a
			l.outline_modulate.a = a
		((_head.mesh as PrimitiveMesh).material as StandardMaterial3D).albedo_color.a = a
		for m: StandardMaterial3D in _mm_mats:
			m.albedo_color.a = a


## Unshaded so it reads in the dark; `instance_colors`: colour per multimesh instance.
static func _mat(col: Color, instance_colors: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	m.vertex_color_use_as_albedo = instance_colors
	m.disable_fog = true
	return m
