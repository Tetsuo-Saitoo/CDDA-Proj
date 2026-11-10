class_name WeaponViewmodel
extends Node3D
## First-person viewmodel: a low-poly model of what the player wields, low right of the view, child of the
## first-person camera. The shape comes from the item's id-table entry: `gun` (the skill the bridge sends for
## guns: pistol, smg, rifle, shotgun, archery, launcher, ...), else the category (weapons / tools), else
## nothing for empty hands. Brought up while aiming (a target request in an attack mode); `kick()` recoils.
## `sway_arcmin` (CDDA's dispersion while aiming, 0 otherwise) makes it breathe in a slow figure eight, wider
## the worse the aim, capped at SWAY_ROT / SWAY_POS. Purely visual: the shot's error is CDDA's roll.
## `set_dirt()` shows the held gun's fouling (CDDA's item var `dirt`) as grime on a gun's parts (grime.gdshader).
## `set_faults()` shows a jam (CDDA's gun_mechanical_simple faults): slide / bolt held open, the gun canted to show
## its port, and a small label saying what jammed and that R (reload) clears it (the fork's fp3d::rack_jammed).
## A gun's parts are named (Muzzle, Grip, MagWell, Magazine, Slide / Bolt: see build()).

const REST := Vector3(0.22, -0.2, -0.42)
const AIMED := Vector3(0.0, -0.13, -0.38)
const RAISE_RATE := 10.0
const KICK_BACK := 0.06
const KICK_RATE := 14.0
const SWAY_HZ := 0.3
const SWAY_FULL_ARCMIN := 900.0       # this much dispersion (15 degrees) or more sways fully
const SWAY_ROT := 0.02618             # full sway: rotation (radians, 1.5 degrees)
const SWAY_POS := 0.01                # full sway: offset (m)
const SWAY_RATE := 1.5                # how fast the sway grows / settles (per second)
const DIRT_MAX := 10000               # CDDA's most fouling; its fouling symbol steps every 2000
const GUN_SHAPES: Array[String] = ["pistol", "long", "launcher"]   # the shapes that show grime
const GRIME_SHADER := preload("res://scripts/combat/grime.gdshader")
## CDDA's jams (fault type gun_mechanical_simple, data/json/faults/faults_guns.json) and how the label names them.
const JAMS := {"fault_fail_to_feed": "Failure to feed", "fault_stovepipe": "Stovepipe",
	"fault_double_feed": "Double feed", "fault_gun_chamber_spent": "Spent case in the chamber"}
const JAM_BACK := 0.03                # a jammed gun's slide / bolt stands this far open (m)
const JAM_CANT := 0.5                 # and the gun turns this far on its side (radians about the bore)
const JAM_RATE := 4.0                 # how fast it turns (per second)
const METAL := Color(0.18, 0.18, 0.2)
const WOOD := Color(0.4, 0.26, 0.14)
const OLIVE := Color(0.25, 0.3, 0.2)
const BUNDLE := Color(0.5, 0.45, 0.35)

var shape := ""          # "" none, "pistol", "long", "bow", "launcher", "melee", "item"
var dirt := -1           # the held gun's fouling as last set (0..DIRT_MAX), -1 none / NON-FOULING
var grime := 0.0         # dirt as 0..1, on the gun's parts
var aimed := false
var sway_arcmin := 0.0:
	set(v):
		sway_arcmin = clampf(v, 0.0, SWAY_FULL_ARCMIN) if is_finite(v) else 0.0
var _kick := 0.0
var _item := -1
var _root: Node3D
var _base := REST
var _sway := 0.0         # 0..1, eased toward sway_arcmin / SWAY_FULL_ARCMIN
var _sway_t := 0.0
var _grime_mats: Array[ShaderMaterial] = []
var jam := ""            # the held gun's jam (a JAMS key), "" none
var _cant := 0.0         # 0..1, eased toward 1 while jammed
var _jam_label: Label3D


func _init() -> void:
	name = "Viewmodel"
	position = REST


## The shape for an itype definition (null = empty hands).
static func shape_for(d: IdTables.Def) -> String:
	if d == null:
		return ""
	match d.gun:
		"":
			pass
		"pistol":
			return "pistol"
		"archery":
			return "bow"
		"launcher":
			return "launcher"
		_:
			return "long"   # rifle, smg, shotgun and any other gun skill
	if d.category == "guns":
		return "pistol" if d.volume_ml <= 750 else "long"
	if d.category == "weapons":
		return "melee"
	return "item"


## Shows the wielded item (itype index; 0 = nothing). Rebuilds only when it changes.
func set_item(index: int, tables: IdTables) -> void:
	if index == _item:
		return
	_item = index
	var d: IdTables.Def = tables.def_at("itype", index) if tables != null and index > 0 else null
	var s := shape_for(d)
	if s == shape and _root != null:
		return
	shape = s
	if _root != null:
		_root.queue_free()
		_root = null
	_grime_mats.clear()
	if s != "":
		_root = build(s, grime)
		add_child(_root)
		_grime_mats = grime_materials(_root)
	_pose_jam()


## The held gun's fouling: CDDA's item var `dirt`, 0..DIRT_MAX; negative = no fouling info (a NON-FOULING gun,
## or nothing sent), shown clean. A gun's parts show it as grime: 2000 a light film, 4000 visibly dirty, 6000
## fouled (soot starts), 8000 and up heavily caked. Kept across set_item; the parts change only when it does.
func set_dirt(value: int) -> void:
	var d := -1 if value < 0 else mini(value, DIRT_MAX)
	if d == dirt:
		return
	dirt = d
	var g := grime_for(d)
	if g == grime:
		return
	grime = g
	for m: ShaderMaterial in _grime_mats:
		m.set_shader_parameter("grime", g)


## The held gun's faults (`Snapshot.player_gun.faults`, fault ids): a jam among them shows; kept across
## set_item (a jam belongs to the gun the snapshot names, and the next snapshot corrects it).
func set_faults(faults: Array) -> void:
	var j := jam_of(faults)
	if j == jam:
		return
	jam = j
	_pose_jam()


## The first jam among `faults` (anything else, junk included, ignored), "" for none.
static func jam_of(faults: Array) -> String:
	for f: Variant in faults:
		if f is String and JAMS.has(f):
			return f
	return ""


## The label for a jam: what jammed and how to clear it; "" for none.
static func jam_hint(id: String) -> String:
	return "%s: R to clear" % JAMS[id] if JAMS.has(id) else ""


func _pose_jam() -> void:
	var on := jam != "" and shape in GUN_SHAPES
	if _root != null:
		for part: String in ["Slide", "Bolt"]:
			var n := _root.get_node_or_null(part) as Node3D
			if n == null:
				continue
			if not n.has_meta("rest"):
				n.set_meta("rest", n.position)
			n.position = (n.get_meta("rest") as Vector3) + Vector3(0, 0, JAM_BACK if on else 0.0)
	if on and _jam_label == null:
		_jam_label = Label3D.new()
		_jam_label.name = "JamHint"
		_jam_label.pixel_size = 0.0004
		_jam_label.font_size = 48
		_jam_label.outline_size = 12
		_jam_label.modulate = Color(1.0, 0.75, 0.3)
		_jam_label.no_depth_test = true
		_jam_label.position = Vector3(-0.05, 0.07, -0.1)
		add_child(_jam_label)
	if _jam_label != null:
		_jam_label.text = jam_hint(jam) if on else ""
		_jam_label.visible = on


## CDDA's `dirt` (0..DIRT_MAX, negative none) as the shader's grime, 0..1.
static func grime_for(d: int) -> float:
	return float(clampi(d, 0, DIRT_MAX)) / DIRT_MAX


func kick() -> void:
	_kick = 1.0


func _process(delta: float) -> void:
	_kick = move_toward(_kick, 0.0, KICK_RATE * delta * maxf(_kick, 0.2))
	var goal := (AIMED if aimed and shape != "melee" else REST) + Vector3(0, 0, KICK_BACK * _kick)
	_base = _base.lerp(goal, minf(RAISE_RATE * delta, 1.0))
	_sway = move_toward(_sway, sway_arcmin / SWAY_FULL_ARCMIN, SWAY_RATE * delta)
	_sway_t = fmod(_sway_t + delta, 1000.0 / SWAY_HZ)
	var w := TAU * SWAY_HZ * _sway_t
	var sx := sin(w)                # side to side
	var sy := 0.6 * sin(2.0 * w)    # up and down twice as fast: a figure eight
	position = _base + Vector3(sx, sy, 0.0) * (SWAY_POS * _sway)
	rotation.x = 0.25 * _kick + sy * SWAY_ROT * _sway
	rotation.y = -sx * SWAY_ROT * _sway
	_cant = move_toward(_cant, 1.0 if jam != "" and shape in GUN_SHAPES else 0.0, JAM_RATE * delta)
	rotation.z = JAM_CANT * _cant


## The model for a shape, pointing down -z (the camera's forward). A gun's parts wear the grime shader at
## `grime_level` (0..1), each part its own material (the soot follows its edges); other shapes plain materials.
## Guns (pistol, long, launcher) carry named parts, the names later gun models will use as markers:
## - `Muzzle` (Marker3D): the barrel's tip; its -z is the bore.
## - `Grip` (Marker3D): where the main hand holds it (its +y up the grip).
## - `MagWell` (Marker3D): where a magazine (a launcher's round) goes in; its +y is the way it slides in.
## - `Magazine` (mesh): long guns a box under the receiver in front of the grip, pistols the bottom of the grip;
##   launchers have none.
## - `Slide` (pistol, mesh): the top part. `Bolt` (long, mesh): a small box on the right of the receiver.
## Other meshes: `Frame` (a grip), `Receiver`, `Barrel`, `Stock` (long), `Tube` (launcher).
static func build(s: String, grime_level := 0.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Model"
	var metal := _mat(METAL)
	var wood := _mat(WOOD)
	match s:
		"pistol":
			_box(root, Vector3(0.035, 0.045, 0.2), Vector3(0, 0, -0.06), metal, 0.0, "Slide")
			# the grip, raked back: its top 6 cm is the frame, the bottom 4 cm the magazine
			var tilt := -0.25
			var c := Vector3(0, -0.06, 0.02)
			var up := Vector3(0, cos(tilt), sin(tilt))
			_box(root, Vector3(0.03, 0.06, 0.045), c + up * 0.02, metal, tilt, "Frame")
			_box(root, Vector3(0.03, 0.04, 0.045), c - up * 0.03, metal, tilt, "Magazine")
			_marker(root, "Muzzle", Vector3(0, 0, -0.16))
			_marker(root, "Grip", c, tilt)
			_marker(root, "MagWell", c - up * 0.05, tilt)
		"long":
			_box(root, Vector3(0.04, 0.06, 0.34), Vector3(0, 0, -0.1), metal, 0.0, "Receiver")
			_cyl(root, 0.012, 0.36, Vector3(0, 0.012, -0.44), metal, false, "Barrel")
			_box(root, Vector3(0.035, 0.08, 0.22), Vector3(0, -0.03, 0.17), wood, 0.0, "Stock")
			_box(root, Vector3(0.03, 0.08, 0.04), Vector3(0, -0.07, -0.02), metal, -0.3, "Frame")
			_box(root, Vector3(0.028, 0.08, 0.045), Vector3(0, -0.07, -0.13), metal, 0.0, "Magazine")
			_box(root, Vector3(0.012, 0.016, 0.05), Vector3(0.026, 0.012, -0.02), metal, 0.0, "Bolt")
			_marker(root, "Muzzle", Vector3(0, 0.012, -0.62))
			_marker(root, "Grip", Vector3(0, -0.07, -0.02), -0.3)
			_marker(root, "MagWell", Vector3(0, -0.03, -0.13))
		"bow":
			_box(root, Vector3(0.025, 0.7, 0.03), Vector3(-0.05, 0, -0.2), wood)
			_cyl(root, 0.004, 0.45, Vector3(0, 0.0, -0.2), wood, true)
		"launcher":
			_cyl(root, 0.05, 0.6, Vector3(0, 0.02, -0.15), _mat(OLIVE), false, "Tube")
			_box(root, Vector3(0.03, 0.09, 0.04), Vector3(0, -0.07, -0.05), metal, -0.25, "Frame")
			_marker(root, "Muzzle", Vector3(0, 0.02, -0.45))
			_marker(root, "Grip", Vector3(0, -0.07, -0.05), -0.25)
			_marker(root, "MagWell", Vector3(0, 0.02, 0.15), -PI / 2.0)   # the breech: a round slides in forward
		"melee":
			_box(root, Vector3(0.03, 0.03, 0.12), Vector3(0, -0.04, 0.0), wood)
			_box(root, Vector3(0.04, 0.04, 0.45), Vector3(0, 0, -0.26), metal)
			root.rotation = Vector3(0.6, 0.2, 0)
		_:
			_box(root, Vector3(0.08, 0.08, 0.1), Vector3(0, -0.02, -0.05), _mat(BUNDLE))
	if s in GUN_SHAPES:
		for n: Node in root.get_children():
			var mi := n as MeshInstance3D
			var pm: PrimitiveMesh = mi.mesh as PrimitiveMesh if mi != null else null
			var look: StandardMaterial3D = pm.material as StandardMaterial3D if pm != null else null
			if look != null:
				pm.material = grime_material(look, _half_size(pm), grime_level)
	return root


## The grime shader with a plain material's look (at grime 0 it renders the same), for a part of this half size.
static func grime_material(look: StandardMaterial3D, half: Vector3, grime_level: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GRIME_SHADER
	m.set_shader_parameter("albedo", look.albedo_color)
	m.set_shader_parameter("metallic", look.metallic)
	m.set_shader_parameter("roughness", look.roughness)
	m.set_shader_parameter("specular", look.metallic_specular)
	m.set_shader_parameter("half_extents", half)
	m.set_shader_parameter("grime", clampf(grime_level, 0.0, 1.0) if is_finite(grime_level) else 0.0)
	return m


## The grime materials on a built model's parts.
static func grime_materials(root: Node3D) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for n: Node in root.get_children():
		var mi := n as MeshInstance3D
		var m: ShaderMaterial = (mi.mesh as PrimitiveMesh).material as ShaderMaterial if mi != null and mi.mesh is PrimitiveMesh else null
		if m != null and m.shader == GRIME_SHADER:
			out.append(m)
	return out


## A part mesh's half size in its own space (a cylinder stands along y).
static func _half_size(pm: PrimitiveMesh) -> Vector3:
	if pm is BoxMesh:
		return (pm as BoxMesh).size * 0.5
	if pm is CylinderMesh:
		var c := pm as CylinderMesh
		var r := maxf(c.top_radius, c.bottom_radius)
		return Vector3(r, c.height * 0.5, r)
	return Vector3.ONE * 0.05


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.6
	return m


static func _box(parent: Node3D, sz: Vector3, at: Vector3, mat: Material, tilt := 0.0, part := "") -> void:
	var b := BoxMesh.new()
	b.size = sz
	b.material = mat
	var mi := MeshInstance3D.new()
	if part != "":
		mi.name = part
	mi.mesh = b
	mi.position = at
	mi.rotation.x = tilt
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


static func _cyl(parent: Node3D, r: float, length: float, at: Vector3, mat: Material, upright := false,
		part := "") -> void:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = length
	c.radial_segments = 10
	c.material = mat
	var mi := MeshInstance3D.new()
	if part != "":
		mi.name = part
	mi.mesh = c
	mi.position = at
	mi.rotation.x = 0.0 if upright else PI / 2.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## A named point on a gun (Muzzle, Grip, MagWell), turned by `tilt` about x.
static func _marker(parent: Node3D, part: String, at: Vector3, tilt := 0.0) -> void:
	var m := Marker3D.new()
	m.name = part
	m.position = at
	m.rotation.x = tilt
	parent.add_child(m)
