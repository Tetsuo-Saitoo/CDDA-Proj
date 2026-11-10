class_name WorldView
extends Node3D
## Shows the newest snapshot: one node per submap per z, holding "terrain", "roof" and "caps" meshes
## (TerrainMesher) and "props", "roof_props" and "glyphs" (PropMesher: furniture, traps, item piles).
## Terrain is rebuilt when a submap's revision differs from the one built (any difference, not only an
## increase: a submap that leaves the bubble and comes back restarts at 1), together with its six
## neighbours, whose edge walls, wall tops and roof lids depend on it. Props are rebuilt with the
## terrain and also when only the detail_revision (items) changed.

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
var _built := {}   # Vector3i absolute submap -> {"rev", "detail", "node", "verts", "pverts", "counts"}


## Emitted on the main thread when a snapshot given to submit() is shown; `rebuilt` as apply_snapshot returns.
signal applied(snap: Snapshot, rebuilt: int)

var _task := -1          # WorkerThreadPool task meshing _job; -1 when none runs
var _job: Job
var _waiting: Snapshot   # the newest snapshot submitted while a job ran (older ones are skipped)
var _committing: Job     # meshed, being put into the scene a few submaps per frame
## Main-thread time per frame for putting a submitted snapshot's meshes into the scene (VR budget ~11 ms).
const COMMIT_BUDGET_US := 4000


## One apply: what to rebuild is decided on the main thread (_prepare, from _built), the meshes are made by
## _compute (a worker for submit(): it reads only the snapshot, the catalogs and the tables, which the main
## thread leaves alone while a job runs), and _commit puts them in the scene on the main thread.
class Job:
	var snap: Snapshot
	var drops: Array[Vector3i] = []
	var dirty: Array[Vector3i] = []    # terrain to rebuild (in the snapshot)
	var detail: Array[Vector3i] = []   # props to rebuild (includes dirty)
	var terrain := {}   # Vector3i -> TerrainMesher.Result
	var props := {}     # Vector3i -> PropMesher.Result
	var next := -1      # commit progress: -1 not begun, then an index into dirty + detail


## Id tables for the snapshots that follow (contracts/id_tables.md). Null or invalid: the snapshot's
## names and the registry only. Everything built so far is rebuilt on the next apply.
func set_id_tables(t: IdTables) -> void:
	finish_pending()
	tables = t if t != null and t.is_valid() else null
	catalog.set_tables(tables)
	props.set_tables(tables)
	for pos: Vector3i in _built:
		_built[pos]["rev"] = -1


## Shows a validated snapshot now (meshing on this thread); returns how many submaps' terrain was rebuilt.
func apply_snapshot(snap: Snapshot) -> int:
	assert(snap.is_valid())
	finish_pending()
	var job := _prepare(snap)
	_compute(job)
	_commit(job, -1)
	return job.dirty.size()


## Shows a validated snapshot without blocking: meshing runs on a worker and `applied` follows on a later
## frame (from _process). A snapshot submitted while one is meshing waits; only the newest waits.
func submit(snap: Snapshot) -> void:
	assert(snap.is_valid())
	if _task >= 0 or _committing != null:
		_waiting = snap
		return
	_job = _prepare(snap)
	_task = WorkerThreadPool.add_task(_compute.bind(_job), false, "world meshing")


func busy() -> bool:
	return _task >= 0 or _waiting != null or _committing != null


## Blocks until a submitted snapshot is shown (and the one waiting after it).
func finish_pending() -> void:
	while _task >= 0 or _committing != null:
		if _committing == null:
			WorkerThreadPool.wait_for_task_completion(_task)
			_take_task()
		_step_commit(-1)


## Main-thread microseconds the last _process took (for the bench and a HUD).
var process_us := 0


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_poll()
	process_us = Time.get_ticks_usec() - t0


func _poll() -> void:
	if _committing == null and _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_take_task()
	if _committing != null:
		_step_commit(COMMIT_BUDGET_US)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _take_task() -> void:
	_task = -1
	_committing = _job
	_job = null


## Puts more of _committing into the scene, within `budget_us` (-1: all of it); emits `applied` when done.
func _step_commit(budget_us: int) -> void:
	var job := _committing
	if not _commit(job, budget_us):
		return
	_committing = null
	applied.emit(job.snap, job.dirty.size())
	if _waiting != null:
		var next := _waiting
		_waiting = null
		submit(next)


func _prepare(snap: Snapshot) -> Job:
	var job := Job.new()
	job.snap = snap
	var dirty := {}
	var detail := {}
	for pos: Vector3i in _built:
		if not snap.submaps.has(pos):
			job.drops.append(pos)
			_mark_around(dirty, pos)
	for pos: Vector3i in snap.submaps:
		var b: Dictionary = _built.get(pos, {})
		var sm: Snapshot.Submap = snap.submaps[pos]
		if b.is_empty() or b["rev"] != sm.revision:
			_mark_around(dirty, pos)
		elif b["detail"] != sm.detail_revision:
			detail[pos] = true
	for pos: Vector3i in dirty:
		if snap.submaps.has(pos):
			job.dirty.append(pos)
			detail[pos] = true
	for pos: Vector3i in detail:
		job.detail.append(pos)
	return job


## Thread-safe as long as the main thread doesn't touch catalog, props or tables meanwhile (set_id_tables
## and apply_snapshot wait for the job first). ArrayMesh building goes through the thread-safe RenderingServer.
func _compute(job: Job) -> void:
	catalog.set_snapshot(job.snap)
	props.set_snapshot(job.snap)
	var mesher := TerrainMesher.new(job.snap, catalog)
	var pmesher := PropMesher.new(job.snap, catalog, props)
	for pos in job.dirty:
		job.terrain[pos] = mesher.build(pos)
	for pos in job.detail:
		job.props[pos] = pmesher.build(pos)


## Puts a meshed job into the scene, `budget_us` at a time (-1: all); true when done. Until then the old
## snapshot stays current: only the submaps already swapped show the new one.
func _commit(job: Job, budget_us: int) -> bool:
	var t0 := Time.get_ticks_usec()
	var snap := job.snap
	if job.next < 0:
		job.next = 0
		if snapshot == null or snap.bubble_origin != snapshot.bubble_origin:
			coords.set_bubble_origin(snap.bubble_origin)
			for pos: Vector3i in _built:
				(_built[pos]["node"] as Node3D).position = coords.sm_to_world(pos)
		for pos in job.drops:
			if _built.has(pos):
				_drop(pos)
	var total := job.dirty.size() + job.detail.size()
	while job.next < total:
		if budget_us >= 0 and Time.get_ticks_usec() - t0 >= budget_us:
			return false
		var i := job.next
		job.next += 1
		if i < job.dirty.size():
			_build(job.dirty[i], job.terrain[job.dirty[i]], snap)
		else:
			var pos := job.detail[i - job.dirty.size()]
			_build_props(pos, job.props[pos], snap)
	snapshot = snap
	tables_mismatch = tables != null and snap.ids_generation >= 0 and snap.ids_generation != tables.generation
	props_built = job.detail.size()
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
	return true


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


func _build(pos: Vector3i, r: TerrainMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built.get(pos, {})
	var node: Node3D = b.get("node")
	if node == null:
		node = Node3D.new()
		node.name = "sm_%d_%d_%d" % [pos.x, pos.y, pos.z]
		node.position = coords.sm_to_world(pos)
		add_child(node)
		b = {"node": node, "pverts": 0, "counts": {}}
		_built[pos] = b
	for part: Array in [["terrain", r.terrain], ["roof", r.roof], ["caps", r.caps]]:
		_set_mesh(node, part[0], part[1])
	b["rev"] = (snap.submaps[pos] as Snapshot.Submap).revision
	b["verts"] = r.vertices


func _build_props(pos: Vector3i, r: PropMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built[pos]
	var node: Node3D = b["node"]
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
	b["detail"] = (snap.submaps[pos] as Snapshot.Submap).detail_revision
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
