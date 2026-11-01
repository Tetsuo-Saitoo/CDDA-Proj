class_name WorldView
extends Node3D
## Shows the terrain of the newest snapshot: one node per submap per z, holding "terrain", "roof" and
## "caps" meshes (see TerrainMesher). A submap is rebuilt when its revision differs from the one built
## (any difference, not only an increase: a submap that leaves the bubble and comes back restarts at 1),
## together with its six neighbours, whose edge walls, wall tops and roof lids depend on it.

var coords := CddaCoords.new()
var catalog := TerrainCatalog.new()
var snapshot: Snapshot
## Levels above this are hidden (cutaway). Clamped to the loaded levels.
var view_z_max := CddaCoords.Z_MAX
var roofs_visible := true
var z_min_loaded := 0
var z_max_loaded := 0
var vertex_count := 0
var _built := {}   # Vector3i absolute submap -> {"rev": int, "node": Node3D, "verts": int}


## Shows a validated snapshot; returns how many submaps were rebuilt.
func apply_snapshot(snap: Snapshot) -> int:
	assert(snap.is_valid())
	if snapshot == null or snap.bubble_origin != snapshot.bubble_origin:
		coords.set_bubble_origin(snap.bubble_origin)
		for pos: Vector3i in _built:
			(_built[pos]["node"] as Node3D).position = coords.sm_to_world(pos)
	catalog.set_names(snap.ter_names)
	var dirty := {}
	for pos: Vector3i in _built.keys():
		if not snap.submaps.has(pos):
			_drop(pos)
			_mark_around(dirty, pos)
	for pos: Vector3i in snap.submaps:
		var b: Dictionary = _built.get(pos, {})
		if b.is_empty() or b["rev"] != (snap.submaps[pos] as Snapshot.Submap).revision:
			_mark_around(dirty, pos)
	snapshot = snap
	var mesher := TerrainMesher.new(snap, catalog)
	var count := 0
	for pos: Vector3i in dirty:
		if snap.submaps.has(pos):
			_build(mesher, pos)
			count += 1
	z_min_loaded = CddaCoords.Z_MAX
	z_max_loaded = CddaCoords.Z_MIN
	vertex_count = 0
	for pos: Vector3i in _built:
		z_min_loaded = mini(z_min_loaded, pos.z)
		z_max_loaded = maxi(z_max_loaded, pos.z)
		vertex_count += _built[pos]["verts"]
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
	(_built[pos]["node"] as Node3D).free()
	_built.erase(pos)


func _build(mesher: TerrainMesher, pos: Vector3i) -> void:
	if _built.has(pos):
		_drop(pos)
	var r := mesher.build(pos)
	var node := Node3D.new()
	node.name = "sm_%d_%d_%d" % [pos.x, pos.y, pos.z]
	node.position = coords.sm_to_world(pos)
	for part: Array in [["terrain", r.terrain], ["roof", r.roof], ["caps", r.caps]]:
		if part[1] != null:
			var mi := MeshInstance3D.new()
			mi.name = part[0]
			mi.mesh = part[1]
			node.add_child(mi)
	add_child(node)
	_built[pos] = {"rev": (snapshot.submaps[pos] as Snapshot.Submap).revision, "node": node, "verts": r.vertices}


func _update_visibility() -> void:
	for pos: Vector3i in _built:
		var node: Node3D = _built[pos]["node"]
		node.visible = pos.z <= view_z_max
		var roof := node.get_node_or_null("roof") as Node3D
		if roof:
			roof.visible = roofs_visible
		var caps := node.get_node_or_null("caps") as Node3D
		if caps:
			caps.visible = pos.z == view_z_max
