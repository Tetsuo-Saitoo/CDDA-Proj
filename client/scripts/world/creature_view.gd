class_name CreatureView
extends Node3D
## Placeholder creatures (until block C4's models): a capsule on each square the snapshot says holds a
## creature the player perceives, green for monsters and blue for NPCs, as tall as CDDA's size class
## (a zombie is medium, 1.75 m), with the monster's name above it. The player itself isn't drawn here.
## Rebuilt from each snapshot; call apply() after WorldView.apply_snapshot so the origin is current.

const MONSTER_COLOR := Color(0.3, 0.8, 0.25)
const NPC_COLOR := Color(0.3, 0.5, 1.0)
const NAME_RANGE_M := 25.0
## creature_size (1 tiny .. 5 huge) -> [height, radius] in metres; 0 (unknown) is drawn medium.
const SIZES := {1: [0.5, 0.2], 2: [1.0, 0.25], 3: [1.75, 0.3], 4: [2.2, 0.45], 5: [3.0, 0.5]}

var _nodes := {}      # uid -> MeshInstance3D
var _meshes := {}     # "kind:size" -> CapsuleMesh
var view_z_max := CddaCoords.Z_MAX:
	set(z):
		if z == view_z_max:
			return
		view_z_max = z
		for n: MeshInstance3D in _nodes.values():
			n.visible = n.get_meta("z", 0) <= z


static func height_of(size: int) -> float:
	return SIZES.get(size, SIZES[3])[0]


func apply(snap: Snapshot, world: WorldView) -> void:
	var seen := {}
	for c in snap.creatures:
		if c.kind == Snapshot.Creature.PLAYER:
			continue
		var d := _def(world, c)
		var size := d.size if d != null else 0
		var n: MeshInstance3D = _nodes.get(c.uid)
		var key := "%d:%d" % [c.kind, size]
		if n == null or n.get_meta("key", "") != key:
			if n != null:
				n.free()
			n = _make(c, d, size, key)
			_nodes[c.uid] = n
		var h := height_of(size)
		n.position = world.coords.ms_center_to_world(c.pos) + Vector3(0, h / 2.0, 0)
		n.set_meta("z", c.pos.z)
		n.visible = c.pos.z <= view_z_max
		seen[c.uid] = true
	for uid: int in _nodes.keys():
		if not seen.has(uid):
			(_nodes[uid] as Node).free()
			_nodes.erase(uid)


func count() -> int:
	return _nodes.size()


func _make(c: Snapshot.Creature, d: IdTables.Def, size: int, key: String) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "creature_%d" % c.uid
	n.set_meta("key", key)
	n.mesh = _mesh(c.kind, size, key)
	if d != null and d.name != "":
		var l := Label3D.new()
		l.text = CddaText.plain(d.name).left(40)
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.pixel_size = 0.004
		l.outline_size = 8
		l.position.y = height_of(size) / 2.0 + 0.25
		l.visibility_range_end = NAME_RANGE_M
		n.add_child(l)
	add_child(n)
	return n


func _mesh(kind: int, size: int, key: String) -> CapsuleMesh:
	if _meshes.has(key):
		return _meshes[key]
	var hr: Array = SIZES.get(size, SIZES[3])
	var m := CapsuleMesh.new()
	m.height = hr[0]
	m.radius = hr[1]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MONSTER_COLOR if kind == Snapshot.Creature.MONSTER else NPC_COLOR
	m.material = mat
	_meshes[key] = m
	return m


static func _def(world: WorldView, c: Snapshot.Creature) -> IdTables.Def:
	if c.kind != Snapshot.Creature.MONSTER or world.tables == null:
		return null
	var snap := world.snapshot
	if snap != null and snap.ids_generation >= 0 and snap.ids_generation != world.tables.generation:
		return null   # tables from another session: the index means something else
	return world.tables.def_at("mtype", c.type)
