class_name CarDash
extends Node3D
## C5 interiors: the instrument cluster in front of a vehicle's controls (lead-vr's "Dash" anchor; CarInterior builds
## it). Built in 3D, not as pictures: a speedometer and two small gauges (fuel, battery) in recessed round housings
## with a chrome bezel and glass, dial faces with ticks, numerals and bands (safe, strained, over the top speed; low
## fuel or charge), needles that turn, and warning lamps. Its own frame: x to the driver's right, y up the face, z out
## of it toward the driver; the origin at its middle.
## Dark and still until display() gives it a reading (only the vehicle the player is in: VehicleView.set_ride). Lit
## (a soft backlight on the faces and needles, the lamps that apply, one small light) while that vehicle has power;
## with no power every needle rests at zero. Cheap: one mesh for the housings, one for the faces, a node per needle;
## the text is drawn only within TEXT_VIEW_M.

enum Lamp { ENGINE = 1, FUEL = 2, BATTERY = 4, SKID = 8, DAMAGE = 16 }

const BIG_R := 0.072          # m: the speedometer's face
const SMALL_R := 0.042        # fuel and battery
const SPEEDO := Vector2(0.0, 0.004)
const FUEL := Vector2(-0.15, -0.004)
const BATTERY := Vector2(0.15, -0.004)
const BACK_Z := -0.04         # the plate's back
const PLATE_Z := -0.025       # its front
const DIAL_Z := -0.022        # the faces, set back in their housings
const NEEDLE_Z := -0.016
const GLASS_Z := 0.004
const RIM_Z := 0.006          # the bezels' front
const PLATE := Rect2(-0.225, -0.1, 0.45, 0.2)
## A gauge's sweep: where zero points (degrees counterclockwise from the right, y up) and how far full turns clockwise.
const BIG_SWEEP := Vector2(210.0, 240.0)
const SMALL_SWEEP := Vector2(135.0, 90.0)
const LOW := 0.12             # the red band of the fuel and battery gauges
const TEXT_H := 0.013         # m: numerals' line height (readable 0.6 to 0.8 m away)
const SMALL_TEXT_H := 0.008
const LAMP_H := 0.0095
const TEXT_VIEW_M := 3.0      # text and lamps are drawn this near the camera only
const VIEW_M := 14.0          # needles and glass
const SEGS := 40
const EASE := 8.0             # needles go this much of the way per second (exponential)
const SETTLED := 0.0005
const MAX_TOP := 2000.0       # the largest dial (shown units)
const MAX_TICKS := 12
const MAX_UNIT := 8
const DEFAULT := {"lit": false, "speed": 0.0, "cruise": 0.0, "top": 120.0, "step": 20.0, "safe": 0.0, "red": 0.0,
		"unit": "mph", "fuel": -1.0, "battery": -1.0, "lamps": 0, "steer": 0.0}
const BAND_COLORS := [Color(0.3, 0.75, 0.3), Color(0.95, 0.68, 0.18), Color(0.9, 0.22, 0.18)]   # safe, strained, over
const PLAIN_BAND := Color(0.42, 0.42, 0.42)
const CRUISE_COLOR := Color(0.35, 0.85, 1.0)
const NEEDLE_COLOR := Color(1.0, 0.42, 0.1)
const DIAL := Color(0.045, 0.045, 0.05)
const INK := Color(0.9, 0.88, 0.82)
const HOUSING := Color(0.07, 0.07, 0.075)
const CHROME := Color(0.72, 0.73, 0.76)
const LAMP_OFF := Color(0.12, 0.12, 0.12)
const LIT_TEXT := Color(1.0, 0.96, 0.86)
const DARK_TEXT := Color(0.62, 0.62, 0.6)
const LIGHT_COLOR := Color(1.0, 0.78, 0.5)
## [bit, word, colour, where on the plate]
const LAMPS := [
	[Lamp.ENGINE, "ENGINE", Color(1.0, 0.6, 0.1), Vector2(-0.19, -0.076)],
	[Lamp.FUEL, "FUEL", Color(1.0, 0.6, 0.1), Vector2(-0.11, -0.076)],
	[Lamp.BATTERY, "BATT", Color(1.0, 0.22, 0.15), Vector2(0.11, -0.076)],
	[Lamp.SKID, "SKID", Color(1.0, 0.6, 0.1), Vector2(0.19, -0.076)],
	[Lamp.DAMAGE, "DAMAGE", Color(1.0, 0.22, 0.15), Vector2(0.0, -0.089)],
]
const DIAL_SHADER := preload("res://shaders/dash_glow.gdshader")
## Render layer 18: the faces, needles and text, which the dash's own light leaves out (backlit, not floodlit).
const FACE_LAYER := 1 << 17

static var unit_seen := "mph"   # the unit of the last lit reading: dark dashes are numbered in it
static var _mats := {}          # "dial", "glass" -> Material, made once
static var _meshes := {}        # needle meshes, made once

var reading := DEFAULT.duplicate()   # what it shows (reading_of: checked)
var lit := false
var cluster: MeshInstance3D   # housings, bezels, plate, hood (solid) and glass
var faces: MeshInstance3D     # the dial faces: built again when the scale changes
var needles := {}             # "speed", "cruise", "fuel", "battery" -> pivot (turns about its z)
var _at := {}                 # needle -> the fraction of its sweep it shows now
var _goal := {}               # and where it is going
var _scale_key: Array = []
var _numerals: Array[Label3D] = []
var _lamps: Array[Label3D] = []   # LAMPS' order
var _light: OmniLight3D


func _init() -> void:
	name = "Dash"
	reading.unit = unit_seen
	_build_cluster()
	for e: Array in [["speed", SPEEDO, BIG_R, NEEDLE_Z], ["cruise", SPEEDO, BIG_R, NEEDLE_Z - 0.002],
			["fuel", FUEL, SMALL_R, NEEDLE_Z], ["battery", BATTERY, SMALL_R, NEEDLE_Z]]:
		var pivot := Node3D.new()
		pivot.name = "needle_" + e[0]
		pivot.position = Vector3((e[1] as Vector2).x, (e[1] as Vector2).y, e[3])
		var mi := MeshInstance3D.new()
		mi.mesh = _needle_mesh(e[0] == "cruise", e[2])
		mi.material_override = _material("dial")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = VIEW_M
		mi.layers = FACE_LAYER
		pivot.add_child(mi)
		add_child(pivot)
		needles[e[0]] = pivot
		_at[e[0]] = 0.0
		_goal[e[0]] = 0.0
		_turn(e[0], 0.0)
	for l: Array in LAMPS:
		var lamp := _label(l[1], Vector3((l[3] as Vector2).x, (l[3] as Vector2).y, PLATE_Z + 0.0006), LAMP_H, LAMP_OFF)
		lamp.name = "lamp_" + (l[1] as String).to_lower()
		add_child(lamp)
		_lamps.append(lamp)
	_light = OmniLight3D.new()
	_light.name = "backlight"
	_light.position = Vector3(0.0, -0.13, 0.2)   # toward the wheel and the hands, its glint below the glass
	_light.omni_range = 0.3
	_light.light_energy = 0.12
	_light.light_cull_mask = 0xFFFFF & ~FACE_LAYER
	_light.light_color = LIGHT_COLOR
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)
	_build_faces()
	_light_up()


## A reading as a dash takes it, checked (any field missing, of the wrong type or out of range is its default):
## lit (bool: the vehicle has power), speed and cruise (shown units, either way: abs; the dial's 0..top), top (the
## dial's end, 1..MAX_TOP), step (its numbered ticks: at most MAX_TICKS), safe and red (where the strained and the
## over bands start, 0 unknown), unit (ASCII, MAX_UNIT), fuel and battery (0..1 full; -1 none), lamps (Lamp bits),
## steer (degrees CDDA steers off the facing, negative left; CarInterior's wheel).
static func reading_of(r: Variant) -> Dictionary:
	var out := DEFAULT.duplicate()
	out.unit = unit_seen
	if not r is Dictionary:
		return out
	var d: Dictionary = r
	out.lit = d.get("lit") is bool and d.lit
	out.top = _number(d.get("top"), 1.0, MAX_TOP, DEFAULT.top)
	out.step = _number(d.get("step"), out.top / MAX_TICKS, out.top, 0.0)
	if out.step <= 0.0:
		out.step = maxf(out.top / 6.0, out.top / MAX_TICKS)
	for k: String in ["speed", "cruise"]:
		out[k] = minf(absf(_number(d.get(k), -MAX_TOP, MAX_TOP, 0.0)), out.top)
	for k: String in ["safe", "red"]:
		out[k] = _number(d.get(k), 0.0, out.top, 0.0)
	for k: String in ["fuel", "battery"]:
		var v := _number(d.get(k), -1.0, 1.0, -1.0)
		out[k] = v if v >= 0.0 else -1.0
	out.lamps = int(_number(d.get("lamps"), 0.0, 31.0, 0.0))
	out.steer = _number(d.get("steer"), -180.0, 180.0, 0.0)
	var u: Variant = d.get("unit")
	if u is String and not (u as String).is_empty() and (u as String).length() <= MAX_UNIT:
		var ok := true
		for i in (u as String).length():
			ok = ok and (u as String).unicode_at(i) >= 32 and (u as String).unicode_at(i) < 127
		out.unit = u if ok else out.unit
	return out


## A number within lo..hi, else `fallback` (not a number, NaN or infinite).
static func _number(v: Variant, lo: float, hi: float, fallback: float) -> float:
	if not (v is int or v is float) or not is_finite(float(v)):
		return fallback
	return clampf(float(v), lo, hi)


## Shows reading `r` (reading_of checks it): the needles go to it (all to zero while not lit), the lamps light, the
## faces are numbered and banded again when the scale changed. step() moves the needles.
func display(r: Variant) -> void:
	reading = reading_of(r)
	lit = reading.lit
	if lit:
		unit_seen = reading.unit
	var top: float = reading.top
	_goal.speed = reading.speed / top if lit else 0.0
	_goal.cruise = reading.cruise / top if lit else 0.0
	_goal.fuel = maxf(reading.fuel, 0.0) if lit else 0.0
	_goal.battery = maxf(reading.battery, 0.0) if lit else 0.0
	_build_faces()
	_light_up()


## Moves the needles `delta` seconds on; true while one still moves.
func step(delta: float) -> bool:
	var busy := false
	var k := 1.0 - exp(-EASE * maxf(delta, 0.0))
	for n: String in needles:
		var at: float = _at[n]
		var goal: float = _goal[n]
		if at == goal:
			continue
		at = goal if absf(goal - at) < SETTLED else at + (goal - at) * k
		_at[n] = at
		_turn(n, at)
		busy = busy or at != goal
	return busy


## The fraction of its sweep needle `n` ("speed", "cruise", "fuel", "battery") shows now.
func value(n: String) -> float:
	return _at.get(n, 0.0)


## Where needle `n` goes.
func goal(n: String) -> float:
	return _goal.get(n, 0.0)


## The numerals drawn now (their text).
func numerals() -> PackedStringArray:
	var out := PackedStringArray()
	for l in _numerals:
		out.append(l.text)
	return out


## The lamps lit now (Lamp bits).
func lamps_lit() -> int:
	var out := 0
	for i in LAMPS.size():
		if _lamps[i].modulate != LAMP_OFF:
			out |= LAMPS[i][0]
	return out


func _turn(n: String, f: float) -> void:
	var sweep := BIG_SWEEP if n == "speed" or n == "cruise" else SMALL_SWEEP
	(needles[n] as Node3D).rotation = Vector3(0.0, 0.0, deg_to_rad(sweep.x - 90.0 - sweep.y * f))


## Lit or dark: the faces' and needles' backlight, the text, the lamps that apply, the light (lighting the wheel and
## the hands, not the faces).
func _light_up() -> void:
	var g := 1.0 if lit else 0.0
	faces.set_instance_shader_parameter("glow", g)
	for n: String in needles:
		((needles[n] as Node3D).get_child(0) as MeshInstance3D).set_instance_shader_parameter("glow", g)
	for l in _numerals:
		l.shaded = not lit
		l.modulate = LIT_TEXT if lit else DARK_TEXT
	for i in LAMPS.size():
		var on: bool = lit and (int(reading.lamps) & int(LAMPS[i][0])) != 0
		_lamps[i].modulate = LAMPS[i][2] if on else LAMP_OFF
	_light.visible = lit


## The math angle (radians, counterclockwise from the right) of fraction f on a gauge of `sweep`.
static func angle_of(f: float, sweep: Vector2) -> float:
	return deg_to_rad(sweep.x - sweep.y * clampf(f, 0.0, 1.0))


## The plate, hood and cheeks, each gauge's housing (an outer wall, the bore it is set back in), bezel and centre
## cap: one solid surface; the glass over each: another.
func _build_cluster() -> void:
	var solid := []
	var glass := []
	var box := func(size: Vector3, at: Vector3, col: Color) -> void:
		VehicleView._box(solid, Transform3D(Basis.from_scale(size), at), col)
	box.call(Vector3(PLATE.size.x, PLATE.size.y, PLATE_Z - BACK_Z), Vector3(0.0, PLATE.get_center().y, 0.5 * (PLATE_Z + BACK_Z)), HOUSING)
	box.call(Vector3(PLATE.size.x + 0.02, 0.016, 0.105), Vector3(0.0, PLATE.end.y + 0.008, 0.0125), HOUSING)
	for s: float in [-1.0, 1.0]:
		box.call(Vector3(0.012, PLATE.size.y + 0.016, 0.07), Vector3(s * (PLATE.end.x + 0.004), PLATE.get_center().y + 0.008, -0.005), HOUSING)
	for g: Array in [[SPEEDO, BIG_R, 0.0065], [FUEL, SMALL_R, 0.005], [BATTERY, SMALL_R, 0.005]]:
		var c: Vector2 = g[0]
		var r: float = g[1]
		var at := Transform3D(Basis(), Vector3(c.x, c.y, 0.0))
		CarInterior.tube(solid, at, r + 0.004, PLATE_Z, RIM_Z - 0.002, SEGS, HOUSING, false)
		CarInterior.tube(solid, at, r, DIAL_Z, RIM_Z, SEGS, Color(0.03, 0.03, 0.03), true)
		CarInterior.tube(solid, at, r + 0.006, RIM_Z - 0.003, RIM_Z, SEGS, CHROME, false)
		CarInterior.annulus(solid, at.translated_local(Vector3(0.0, 0.0, RIM_Z)), r, r + 0.006, 0.0, TAU, SEGS, CHROME)
		CarInterior.disk(solid, at.translated_local(Vector3(0.0, 0.0, NEEDLE_Z + 0.0025)), g[2], 16, Color(0.2, 0.2, 0.22))
		CarInterior.disk(glass, at.translated_local(Vector3(0.0, 0.0, GLASS_Z)), r, SEGS, Color(0.8, 0.85, 0.9, 0.1))
	var mesh := ArrayMesh.new()
	CarInterior.surface(mesh, solid, VehicleView._material(VehicleView.Look.SOLID))
	CarInterior.surface(mesh, glass, _material("glass"))
	cluster = MeshInstance3D.new()
	cluster.name = "cluster"
	cluster.mesh = mesh
	cluster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(cluster)
	faces = MeshInstance3D.new()
	faces.name = "faces"
	faces.material_override = _material("dial")
	faces.layers = FACE_LAYER
	faces.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(faces)


## The dial faces for the reading's scale (built again only when it changed): each face, its bands and ticks, and
## the numerals and words on it.
func _build_faces() -> void:
	var key := [reading.top, reading.step, reading.safe, reading.red, reading.unit]
	if key == _scale_key:
		return
	_scale_key = key
	for l in _numerals:
		l.free()
	_numerals.clear()
	var tris := []
	var top: float = reading.top
	var step: float = reading.step
	# the speedometer: bands safe (to the safe speed), strained (to the top speed), over (beyond)
	var bands := []
	if reading.safe > 0.0 and reading.red > reading.safe:
		bands = [[0.0, reading.safe / top, BAND_COLORS[0]], [reading.safe / top, reading.red / top, BAND_COLORS[1]],
				[reading.red / top, 1.0, BAND_COLORS[2]]]
	var ticks := []   # [fraction, major]
	var n := mini(int(round(top / step)), MAX_TICKS)
	for i in n + 1:
		var f := i * step / top
		if f <= 1.0001:
			ticks.append([f, true])
			_numerals.append(_numeral(_count(i * step), SPEEDO, BIG_R, f, BIG_SWEEP, 0.56, TEXT_H if top < 1000.0 else 0.0095))
		var half := (i + 0.5) * step / top
		if half <= 1.0001:
			ticks.append([half, false])
	_face(tris, SPEEDO, BIG_R, BIG_SWEEP, bands, ticks)
	_numerals.append(_word(reading.unit, SPEEDO + Vector2(0.0, -0.42 * BIG_R), SMALL_TEXT_H))
	# fuel and battery: low in red
	var small_ticks := [[0.0, true], [0.25, false], [0.5, true], [0.75, false], [1.0, true]]
	var low := [[0.0, LOW, BAND_COLORS[2]], [LOW, 1.0, PLAIN_BAND]]
	for g: Array in [[FUEL, "E", "F", "FUEL"], [BATTERY, "-", "+", "BATTERY"]]:
		_face(tris, g[0], SMALL_R, SMALL_SWEEP, low, small_ticks)
		_numerals.append(_numeral(g[1], g[0], SMALL_R, 0.0, SMALL_SWEEP, 0.58, SMALL_TEXT_H + 0.002))
		_numerals.append(_numeral(g[2], g[0], SMALL_R, 1.0, SMALL_SWEEP, 0.58, SMALL_TEXT_H + 0.002))
		_numerals.append(_word(g[3], (g[0] as Vector2) + Vector2(0.0, -0.4 * SMALL_R), SMALL_TEXT_H * 0.8))
	for l in _numerals:
		add_child(l)
	var mesh := ArrayMesh.new()
	CarInterior.surface(mesh, tris, _material("dial"))
	faces.mesh = mesh
	_light_up()


## One gauge's face at `c`, radius r: the dark disc, its bands ([from, to, colour] fractions) near the rim and ticks
## ([fraction, major]) across them.
static func _face(tris: Array, c: Vector2, r: float, sweep: Vector2, bands: Array, ticks: Array) -> void:
	var at := Transform3D(Basis(), Vector3(c.x, c.y, DIAL_Z))
	CarInterior.disk(tris, at, r, SEGS, DIAL)
	if bands.is_empty():
		CarInterior.annulus(tris, at.translated_local(Vector3(0.0, 0.0, 0.0005)), 0.86 * r, 0.9 * r,
				angle_of(1.0, sweep), angle_of(0.0, sweep), SEGS, PLAIN_BAND)
	for b: Array in bands:
		if b[1] > b[0]:
			CarInterior.annulus(tris, at.translated_local(Vector3(0.0, 0.0, 0.0005)), 0.78 * r, 0.9 * r,
					angle_of(b[1], sweep), angle_of(b[0], sweep), SEGS, b[2])
	for t: Array in ticks:
		var a := angle_of(t[0], sweep)
		var d := Vector3(cos(a), sin(a), 0.0)
		var side := Vector3(-d.y, d.x, 0.0) * (0.016 if t[1] else 0.009) * r
		var r0 := (0.68 if t[1] else 0.8) * r
		var p0 := at.origin + Vector3(0.0, 0.0, 0.001) + d * r0
		var p1 := at.origin + Vector3(0.0, 0.0, 0.001) + d * 0.92 * r
		CarInterior.quad(tris, p0 - side, p0 + side, p1 + side, p1 - side, Vector3.BACK, INK)


## A numeral on a gauge at fraction f, `inset` of the radius in from the rim's direction.
func _numeral(text: String, c: Vector2, r: float, f: float, sweep: Vector2, inset: float, h: float) -> Label3D:
	var a := angle_of(f, sweep)
	return _word(text, c + Vector2(cos(a), sin(a)) * inset * r, h)


func _word(text: String, at: Vector2, h: float) -> Label3D:
	return _label(text, Vector3(at.x, at.y, DIAL_Z + 0.0015), h, DARK_TEXT)


static func _label(text: String, at: Vector3, h: float, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 48
	l.pixel_size = h / 48.0
	l.outline_size = 0
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	l.modulate = col
	l.position = at
	l.visibility_range_end = TEXT_VIEW_M
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.layers = FACE_LAYER
	return l


## A tick count as numbered: whole numbers plain, else one decimal.
static func _count(v: float) -> String:
	return str(int(round(v))) if is_equal_approx(v, round(v)) else "%.1f" % v


## A needle pointing up its pivot's y (the speed's, the fuel's, the battery's: a tapered blade from a short tail to
## near the rim), or the cruise marker (a wedge at the rim).
static func _needle_mesh(cruise: bool, r: float) -> ArrayMesh:
	var key := "%s:%f" % [cruise, r]
	if not _meshes.has(key):
		var tris := []
		if cruise:
			tris.append(VehicleView._tri_n(Vector3(-0.0045, 0.95 * r, 0.0), Vector3(0.0045, 0.95 * r, 0.0),
					Vector3(0.0, 0.8 * r, 0.0), Vector3.BACK, CRUISE_COLOR))
		else:
			var w0 := 0.0016 if r > SMALL_R else 0.0012
			CarInterior.quad(tris, Vector3(-w0, -0.16 * r, 0.0), Vector3(w0, -0.16 * r, 0.0),
					Vector3(0.0006, 0.88 * r, 0.0), Vector3(-0.0006, 0.88 * r, 0.0), Vector3.BACK, NEEDLE_COLOR)
		var mesh := ArrayMesh.new()
		CarInterior.surface(mesh, tris, null)
		_meshes[key] = mesh
	return _meshes[key]


## The faces' and needles' material (vertex colours, backlit by the instance's `glow`), the glass's.
static func _material(which: String) -> Material:
	if not _mats.has(which):
		if which == "dial":
			var m := ShaderMaterial.new()
			m.shader = DIAL_SHADER
			_mats[which] = m
		else:
			var g := StandardMaterial3D.new()
			g.vertex_color_use_as_albedo = true
			g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			g.roughness = 0.12
			g.metallic_specular = 0.5
			_mats[which] = g
	return _mats[which]
