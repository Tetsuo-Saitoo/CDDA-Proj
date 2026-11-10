class_name GoreView
extends Node3D
## Blood, gibs and bile on the ground: CDDA's fields (snapshot `fields`, seen tiles only) of those kinds drawn
## as splats (blood, bile) and chunks (gibs), sized by intensity, coloured by what bled (flesh, plant, insect,
## invertebrate). Other fields (fire, smoke, gas) are left to their own views. Rebuilt per snapshot; at most
## MAX_SPLATS instances per kind. Deterministic per square, so a rebuild doesn't move anything.

const MAX_SPLATS := 2048
## field id -> [shape, colour]; shapes: "splat" (flat disc) or "chunks".
const KINDS := {
	"fd_blood": ["splat", Color(0.42, 0.03, 0.04, 0.9)],
	"fd_blood_veggy": ["splat", Color(0.25, 0.4, 0.08, 0.9)],
	"fd_blood_insect": ["splat", Color(0.45, 0.5, 0.1, 0.9)],
	"fd_blood_invertebrate": ["splat", Color(0.25, 0.35, 0.55, 0.9)],
	"fd_bile": ["splat", Color(0.5, 0.55, 0.12, 0.85)],
	"fd_gibs_flesh": ["chunks", Color(0.5, 0.1, 0.12)],
	"fd_gibs_veggy": ["chunks", Color(0.3, 0.42, 0.12)],
	"fd_gibs_insect": ["chunks", Color(0.4, 0.42, 0.15)],
	"fd_gibs_invertebrate": ["chunks", Color(0.3, 0.35, 0.5)],
}

var view_z_max := CddaCoords.Z_MAX
var _layers := {}     # field id -> MultiMeshInstance3D
var _count := 0


func _init() -> void:
	name = "Gore"


## Splats and chunks drawn after the last apply (tests).
func count() -> int:
	return _count


func apply(snap: Snapshot, world: WorldView) -> void:
	var by_kind := {}   # field id -> Array of Transform3D
	_count = 0
	if world.tables != null:
		for sm: Snapshot.Submap in snap.submaps.values():
			if sm.pos.z > view_z_max:
				continue
			var base := CddaCoords.sm_to_ms(sm.pos)
			for j in range(0, sm.fields.size() - Snapshot.FIELD_STRIDE + 1, Snapshot.FIELD_STRIDE):
				var d: IdTables.Def = world.tables.def_at("field", sm.fields[j + 1])
				if d == null or not KINDS.has(d.id):
					continue
				var list: Array = by_kind.get(d.id, [])
				if list.size() >= MAX_SPLATS:
					continue
				var t := sm.fields[j]
				var sq := base + Vector3i(t % CddaCoords.SEEX, t / CddaCoords.SEEX, 0)
				_place(list, KINDS[d.id][0], world.coords.ms_center_to_world(sq), sq, clampi(sm.fields[j + 2], 1, 3))
				by_kind[d.id] = list
	for id: String in _layers.keys():
		if not by_kind.has(id):
			(_layers[id] as Node).queue_free()
			_layers.erase(id)
	for id: String in by_kind:
		var mi: MultiMeshInstance3D = _layers.get(id)
		if mi == null:
			mi = _layer(KINDS[id][0], KINDS[id][1])
			add_child(mi)
			_layers[id] = mi
		var xs: Array = by_kind[id]
		mi.multimesh.instance_count = xs.size()
		for i in xs.size():
			mi.multimesh.set_instance_transform(i, xs[i])
		_count += xs.size()


func shift(d: Vector3) -> void:
	for mi: MultiMeshInstance3D in _layers.values():
		mi.position += d


## A splat: one disc a bit off-centre, wider with intensity. Chunks: 2-4 bits around the square.
static func _place(list: Array, shape: String, at: Vector3, sq: Vector3i, intensity: int) -> void:
	var h := absi(hash(sq))
	var off := Vector3(((h % 7) - 3) * 0.06, 0.015, (((h >> 3) % 7) - 3) * 0.06)
	if shape == "splat":
		var r := 0.2 + 0.13 * intensity
		list.append(Transform3D(Basis(Vector3.UP, (h % 628) / 100.0).scaled(Vector3(r, 1.0, r * 0.75)), at + off))
		return
	for k in 1 + intensity:
		var a := (h % 360 + k * 137) * PI / 180.0
		var d := 0.12 + 0.08 * k
		var sc := 0.05 + 0.02 * ((h >> k) % 3)
		list.append(Transform3D(Basis(Vector3.UP, a).scaled(Vector3(sc, sc * 0.6, sc * 1.3)),
				at + Vector3(cos(a) * d, sc * 0.5, sin(a) * d)))


static func _layer(shape: String, c: Color) -> MultiMeshInstance3D:
	var mesh: Mesh
	if shape == "splat":
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.0
		cyl.bottom_radius = 1.0
		cyl.height = 0.005
		cyl.radial_segments = 14
		cyl.rings = 1
		mesh = cyl
	else:
		var sp := SphereMesh.new()
		sp.radius = 1.0
		sp.height = 2.0
		sp.radial_segments = 8
		sp.rings = 4
		mesh = sp
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = 0.3 if shape == "splat" else 0.6
	if c.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
