class_name WeaponViewmodel
extends Node3D
## First-person viewmodel: a low-poly model of what the player wields, low right of the view, child of the
## first-person camera. The shape comes from the item's id-table entry: `gun` (the skill the bridge sends for
## guns: pistol, smg, rifle, shotgun, archery, launcher, ...), else the category (weapons / tools), else
## nothing for empty hands. Brought up while aiming (a target request in an attack mode); `kick()` recoils.

const REST := Vector3(0.22, -0.2, -0.42)
const AIMED := Vector3(0.0, -0.13, -0.38)
const RAISE_RATE := 10.0
const KICK_BACK := 0.06
const KICK_RATE := 14.0

var shape := ""          # "" none, "pistol", "long", "bow", "launcher", "melee", "item"
var aimed := false
var _kick := 0.0
var _item := -1
var _root: Node3D


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
	if s != "":
		_root = build(s)
		add_child(_root)


func kick() -> void:
	_kick = 1.0


func _process(delta: float) -> void:
	_kick = move_toward(_kick, 0.0, KICK_RATE * delta * maxf(_kick, 0.2))
	var goal := (AIMED if aimed and shape != "melee" else REST) + Vector3(0, 0, KICK_BACK * _kick)
	position = position.lerp(goal, minf(RAISE_RATE * delta, 1.0))
	rotation.x = 0.25 * _kick


## The model for a shape, pointing down -z (the camera's forward).
static func build(s: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Model"
	var metal := _mat(Color(0.18, 0.18, 0.2))
	var wood := _mat(Color(0.4, 0.26, 0.14))
	match s:
		"pistol":
			_box(root, Vector3(0.035, 0.045, 0.2), Vector3(0, 0, -0.06), metal)
			_box(root, Vector3(0.03, 0.1, 0.045), Vector3(0, -0.06, 0.02), metal, -0.25)
		"long":
			_box(root, Vector3(0.04, 0.06, 0.34), Vector3(0, 0, -0.1), metal)
			_cyl(root, 0.012, 0.36, Vector3(0, 0.012, -0.44), metal)
			_box(root, Vector3(0.035, 0.08, 0.22), Vector3(0, -0.03, 0.17), wood)
			_box(root, Vector3(0.03, 0.08, 0.04), Vector3(0, -0.07, -0.02), metal, -0.3)
		"bow":
			_box(root, Vector3(0.025, 0.7, 0.03), Vector3(-0.05, 0, -0.2), wood)
			_cyl(root, 0.004, 0.45, Vector3(0, 0.0, -0.2), wood, true)
		"launcher":
			_cyl(root, 0.05, 0.6, Vector3(0, 0.02, -0.15), _mat(Color(0.25, 0.3, 0.2)))
			_box(root, Vector3(0.03, 0.09, 0.04), Vector3(0, -0.07, -0.05), metal, -0.25)
		"melee":
			_box(root, Vector3(0.03, 0.03, 0.12), Vector3(0, -0.04, 0.0), wood)
			_box(root, Vector3(0.04, 0.04, 0.45), Vector3(0, 0, -0.26), metal)
			root.rotation = Vector3(0.6, 0.2, 0)
		_:
			_box(root, Vector3(0.08, 0.08, 0.1), Vector3(0, -0.02, -0.05), _mat(Color(0.5, 0.45, 0.35)))
	return root


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.6
	return m


static func _box(parent: Node3D, sz: Vector3, at: Vector3, mat: Material, tilt := 0.0) -> void:
	var b := BoxMesh.new()
	b.size = sz
	b.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = b
	mi.position = at
	mi.rotation.x = tilt
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


static func _cyl(parent: Node3D, r: float, length: float, at: Vector3, mat: Material, upright := false) -> void:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = length
	c.radial_segments = 10
	c.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.position = at
	mi.rotation.x = 0.0 if upright else PI / 2.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
