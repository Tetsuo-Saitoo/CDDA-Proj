class_name WorldView
extends Node3D
## Shows the newest snapshot: one node per submap per z, holding "terrain", "roof" and "caps" meshes
## (TerrainMesher) and "props", "roof_props" and "glyphs" (PropMesher: furniture, traps, item piles).
## Terrain is rebuilt when a submap's revision differs from the one built (any difference, not only an
## increase: a submap that leaves the bubble and comes back restarts at 1), together with its six
## neighbours, whose edge walls, wall tops and roof lids depend on it. Props are rebuilt with the
## terrain and also when only the detail_revision (items) changed.

## A door leaf crossed its open / close threshold (Grabbable): main.gd asks the sim. Not in mock mode.
signal door_wants(square: Vector3i, open: bool)
## Mock mode's own door messages ("The door is locked.").
signal door_message(text: String)

var coords := CddaCoords.new()
var catalog := TerrainCatalog.new()
var props := PropCatalog.new(catalog.registry)
var tables: IdTables
var snapshot: Snapshot
## Levels above this are hidden (cutaway). Clamped to the loaded levels.
var view_z_max := CddaCoords.Z_MAX
var roofs_visible := true
var z_min_loaded := 0
var z_max_loaded := 0
var vertex_count := 0
var props_built := 0      # submaps whose props the last apply rebuilt
var prop_counts := {"furniture": 0, "items": 0, "traps": 0, "glyphs": 0}
## Asked for once per generation that doesn't match the snapshot's (live mode refetches).
var tables_mismatch := false
## Door leaves (Grabbable) by square. door_state keeps each one's angle across rebuilds; door_local: no sim,
## doors open and close in the client (door_open: square -> bool, read by VrWalk too).
var grabbables := {}
var door_state := {}
var door_local := true
var door_open := {}
var _built := {}   # Vector3i absolute submap -> {"rev", "detail", "node", "verts", "pverts", "counts"}


## Id tables for the snapshots that follow (contracts/id_tables.md). Null or invalid: the snapshot's
## names and the registry only. Everything built so far is rebuilt on the next apply.
func set_id_tables(t: IdTables) -> void:
	tables = t if t != null and t.is_valid() else null
	catalog.set_tables(tables)
	props.set_tables(tables)
	for pos: Vector3i in _built:
		_built[pos]["rev"] = -1


## Shows a validated snapshot; returns how many submaps' terrain was rebuilt.
func apply_snapshot(snap: Snapshot) -> int:
	assert(snap.is_valid())
	if snapshot == null or snap.bubble_origin != snapshot.bubble_origin:
		coords.set_bubble_origin(snap.bubble_origin)
		for pos: Vector3i in _built:
			(_built[pos]["node"] as Node3D).position = coords.sm_to_world(pos)
	catalog.set_snapshot(snap)
	props.set_snapshot(snap)
	tables_mismatch = tables != null and snap.ids_generation >= 0 and snap.ids_generation != tables.generation
	var dirty := {}
	var detail := {}
	for pos: Vector3i in _built.keys():
		if not snap.submaps.has(pos):
			_drop(pos)
			_mark_around(dirty, pos)
	for pos: Vector3i in snap.submaps:
		var b: Dictionary = _built.get(pos, {})
		var sm: Snapshot.Submap = snap.submaps[pos]
		if b.is_empty() or b["rev"] != sm.revision:
			_mark_around(dirty, pos)
		elif b["detail"] != sm.detail_revision:
			detail[pos] = true
	snapshot = snap
	var mesher := TerrainMesher.new(snap, catalog)
	var pmesher := PropMesher.new(snap, catalog, props)
	var count := 0
	props_built = 0
	for pos: Vector3i in dirty:
		if snap.submaps.has(pos):
			_build(mesher, pos)
			count += 1
			detail[pos] = true
	for pos: Vector3i in detail:
		_build_props(pmesher, pos)
		props_built += 1
	z_min_loaded = CddaCoords.Z_MAX
	z_max_loaded = CddaCoords.Z_MIN
	vertex_count = 0
	for k: String in prop_counts:
		prop_counts[k] = 0
	for pos: Vector3i in _built:
		var b: Dictionary = _built[pos]
		z_min_loaded = mini(z_min_loaded, pos.z)
		z_max_loaded = maxi(z_max_loaded, pos.z)
		vertex_count += b["verts"] + b["pverts"]
		for k: String in prop_counts:
			prop_counts[k] += b["counts"].get(k, 0)
	set_view_z_max(view_z_max)
	return count


func set_view_z_max(z: int) -> void:
	view_z_max = clampi(z, z_min_loaded, z_max_loaded)
	_update_visibility()


func set_roofs_visible(v: bool) -> void:
	roofs_visible = v
	_update_visibility()


func built_revision(pos: Vector3i) -> int:
	return _built[pos]["rev"] if _built.has(pos) else -1


func node_of(pos: Vector3i) -> Node3D:
	return _built[pos]["node"] if _built.has(pos) else null


func _mark_around(dirty: Dictionary, pos: Vector3i) -> void:
	dirty[pos] = true
	for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		dirty[pos + d] = true


func _drop(pos: Vector3i) -> void:
	_drop_doors(pos, {})
	(_built[pos]["node"] as Node3D).free()
	_built.erase(pos)


func _build(mesher: TerrainMesher, pos: Vector3i) -> void:
	var b: Dictionary = _built.get(pos, {})
	var node: Node3D = b.get("node")
	if node == null:
		node = Node3D.new()
		node.name = "sm_%d_%d_%d" % [pos.x, pos.y, pos.z]
		node.position = coords.sm_to_world(pos)
		add_child(node)
		b = {"node": node, "pverts": 0, "counts": {}}
		_built[pos] = b
	var r := mesher.build(pos)
	for part: Array in [["terrain", r.terrain], ["roof", r.roof], ["caps", r.caps]]:
		_set_mesh(node, part[0], part[1])
	_build_doors(node, pos, r.doors)
	b["rev"] = (snapshot.submaps[pos] as Snapshot.Submap).revision
	b["verts"] = r.vertices


## Leaves stay the same nodes across rebuilds (a grabbed one keeps its grab); new ones are made, gone ones freed.
func _build_doors(node: Node3D, pos: Vector3i, doors: Array[Dictionary]) -> void:
	var keep := {}
	for d: Dictionary in doors:
		var sq: Vector3i = d["square"]
		keep[sq] = true
		var g: Grabbable = grabbables.get(sq)
		if g != null and is_instance_valid(g):
			g.sync(d)
		else:
			g = Grabbable.door(self, d)
			node.add_child(g)
			grabbables[sq] = g
	_drop_doors(pos, keep)


func _drop_doors(pos: Vector3i, keep: Dictionary) -> void:
	for sq: Vector3i in grabbables.keys():
		if CddaCoords.ms_to_sm(sq) == pos and not keep.has(sq):
			var g: Grabbable = grabbables[sq]
			if is_instance_valid(g):
				g.free()
			grabbables.erase(sq)


## The leaf nearest `p` (world) within `reach` metres on squares around it, or null. `ok` filters squares.
func grabbable_near(p: Vector3, reach: float, ok := Callable()) -> Grabbable:
	var c := coords.world_to_ms(p)
	var best: Grabbable = null
	var best_d := reach
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var g: Grabbable = grabbables.get(c + Vector3i(dx, dy, 0))
			if g == null or (ok.is_valid() and not ok.call(g.square)):
				continue
			var d := g.distance_to(p)
			if d <= best_d:
				best = g
				best_d = d
	return best


## The leaf a ray (normalized `dir`) meets first on the squares around `centre` (same level), within `max_d`;
## [Grabbable, hit point] or [].
func grabbable_on_ray(origin: Vector3, dir: Vector3, centre: Vector3i, max_d: float) -> Array:
	var best: Array = []
	var best_t := max_d
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var g: Grabbable = grabbables.get(centre + Vector3i(dx, dy, 0))
			if g == null:
				continue
			var t := g.ray_distance(origin, dir)
			if t < best_t:
				best_t = t
				best = [g, origin + dir * t]
	return best


func _build_props(mesher: PropMesher, pos: Vector3i) -> void:
	var b: Dictionary = _built[pos]
	var node: Node3D = b["node"]
	var r := mesher.build(pos)
	_set_mesh(node, "props", r.props)
	_set_mesh(node, "roof_props", r.roof_props)
	var old := node.get_node_or_null("glyphs")
	if old:
		old.free()
	if not r.glyphs.is_empty():
		var g := Node3D.new()
		g.name = "glyphs"
		for e: Array in r.glyphs:
			g.add_child(_glyph(e[0], e[1], e[2]))
		node.add_child(g)
	b["detail"] = (snapshot.submaps[pos] as Snapshot.Submap).detail_revision
	b["pverts"] = r.vertices
	b["counts"] = {"furniture": r.furniture, "items": r.items, "traps": r.traps, "glyphs": r.glyphs.size()}


## Step 5 of the fallback chain: the CDDA symbol in its colour, facing the camera.
static func _glyph(pos: Vector3, symbol: String, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = symbol.left(2)
	l.position = pos
	l.modulate = col
	l.font_size = 64
	l.pixel_size = 0.006
	l.outline_size = 12
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.shaded = false
	return l


static func _set_mesh(node: Node3D, part: String, mesh: ArrayMesh) -> void:
	var mi := node.get_node_or_null(part) as MeshInstance3D
	if mesh == null:
		if mi:
			mi.free()
		return
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = part
		node.add_child(mi)
	mi.mesh = mesh


func _update_visibility() -> void:
	for pos: Vector3i in _built:
		var node: Node3D = _built[pos]["node"]
		node.visible = pos.z <= view_z_max
		for part in ["roof", "roof_props"]:
			var roof := node.get_node_or_null(part) as Node3D
			if roof:
				roof.visible = roofs_visible
		var caps := node.get_node_or_null("caps") as Node3D
		if caps:
			caps.visible = pos.z == view_z_max
