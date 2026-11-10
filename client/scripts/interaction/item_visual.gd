class_name ItemVisual
extends RefCounted
## Blocks E6 / L2: what one item looks like in a hand or floating in front of the camera: its model when the
## registry has one, else its placeholder shape (PropShapes, as PropMesher draws piles), at the size the world
## draws it. Meshes are built once per itype and id-table generation and shared; make() only adds nodes, so it is
## cheap enough to call on every grab. Main thread only (it reads WorldView's catalogs).

const GRIP := "grip"   # model marker where a hand holds the item (docs/MODELS.md); else its centre
const MAX_CACHED := 512

static var _meshes := {}   # "<generation>:<itype>" -> ArrayMesh (placeholder shapes)


## A node showing item `type` at its drawn size; its origin is where the item rests (the bottom centre).
static func make(type: int, world: WorldView) -> Node3D:
	var prop := world.props.item(type)
	var root := Node3D.new()
	root.name = "Item_%d" % type
	if prop.model != null:
		for p: Array in prop.model.parts:
			var mi := MeshInstance3D.new()
			mi.mesh = p[0]
			mi.transform = p[1]
			root.add_child(mi)
	else:
		var mi := MeshInstance3D.new()
		mi.name = "Shape"
		mi.mesh = _shape_mesh(type, prop, world)
		root.add_child(mi)
	root.scale = Vector3.ONE * size_of(type, world)
	return root


## The item's drawn size in metres (the scale piles use).
static func size_of(type: int, world: WorldView) -> float:
	var prop := world.props.item(type)
	return prop.scale if prop.scale > 0.0 else 0.1


## Where a hand holds it, in the item's own space (scaled): the model's `grip` marker, else the centre.
static func grip(type: int, world: WorldView) -> Transform3D:
	var prop := world.props.item(type)
	var s := size_of(type, world)
	if prop.model != null and prop.model.has_marker(GRIP):
		var m: Transform3D = prop.model.marker(GRIP)
		return Transform3D(m.basis, m.origin * s)
	if prop.model != null:
		return Transform3D(Basis.IDENTITY, prop.model.aabb.get_center() * s)
	return Transform3D(Basis.IDENTITY, Vector3(0, s * 0.5, 0))


static func _shape_mesh(type: int, prop: PropCatalog.Prop, world: WorldView) -> Mesh:
	var gen := world.tables.generation if world.tables != null else -1
	var key := "%d:%d" % [gen, type]
	if _meshes.has(key):
		return _meshes[key]
	if _meshes.size() >= MAX_CACHED:
		_meshes.clear()
	var mesh: Mesh
	if prop.shape.is_empty() or not PropShapes.has_shape(prop.shape):
		var box := BoxMesh.new()   # no art at all: a small box in the item's colour
		box.size = Vector3(1, 1, 1)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = prop.accent
		box.material = mat
		mesh = box
	else:
		var solid := TerrainMesher.Buf.new()
		var glass := TerrainMesher.Buf.new()
		var b := PropShapes.Builder.new(solid, glass)
		b.xf = Transform3D.IDENTITY
		var rng := RandomNumberGenerator.new()
		rng.seed = type   # as PropMesher._pile: the same look as in the pile
		PropShapes.build(prop.shape, b, prop.main, prop.main, prop.leaf, 0, 1.0, rng)
		mesh = PropMesher._mesh(solid, glass)
		if mesh == null:
			mesh = BoxMesh.new()
	_meshes[key] = mesh
	return mesh
