class_name WorldView
extends Node3D
## Shows the newest snapshot: one node per submap per z that has anything to draw (open sky gets none),
## holding "terrain", "roof" and "caps" meshes
## (TerrainMesher) and "props", "roof_props", "models", "roof_models" and "glyphs" (PropMesher:
## furniture, traps, item piles; models are one MultiMeshInstance3D per model part).
## Terrain is rebuilt when a submap's revision differs from the one built (any difference, not only an
## increase: a submap that leaves the bubble and comes back restarts at 1), together with its six
## neighbours, whose edge walls, wall tops and roof lids depend on it. Props are rebuilt with the
## terrain and also when only the detail_revision (items) changed.

## A door leaf crossed its open / close threshold (Grabbable): main.gd asks the sim. Not in mock mode.
signal door_wants(square: Vector3i, open: bool)
## Mock mode's own door messages ("The door is locked.").
signal door_message(text: String)

var coords := CddaCoords.new()
## Main-thread catalogs (VrWalk, LookRay, StairUse...); set to a snapshot only when it is shown (_commit).
var catalog := TerrainCatalog.new()
var props := PropCatalog.new(catalog.registry)
## The meshing job's own catalogs: they share the registry and tables (read-only during a job), so the worker
## never writes a cache the main thread reads. Made fresh by _prepare when the tables or registry change.
var _job_catalog: TerrainCatalog
var _job_props: PropCatalog
var _job_key := []
var tables: IdTables
var snapshot: Snapshot
## Levels above this are hidden (cutaway). Clamped to the levels with something drawn (set_view_z_max).
var view_z_max := CddaCoords.Z_LIMIT
var roofs_visible := true
var z_min_loaded := 0
var z_max_loaded := 0
## The lowest and highest level with something drawn (the loaded levels when none has).
var z_min_content := 0
var z_max_content := 0
var vertex_count := 0
var props_built := 0      # submaps whose props the last apply rebuilt
var prop_counts := {"furniture": 0, "items": 0, "traps": 0, "glyphs": 0, "models": 0}
## Asked for once per generation that doesn't match the snapshot's (live mode refetches).
var tables_mismatch := false
## Door leaves (Grabbable) by square. door_state keeps each one's angle across rebuilds; door_local: no sim,
## doors open and close in the client (door_open: square -> bool, read by VrWalk too).
var grabbables := {}
var door_state := {}
var door_local := true
var door_open := {}
## Vector3i absolute submap -> {"rev", "detail", "verts", "pverts", "counts", "terrain", "props"}: every submap
## built, drawn or not ("terrain" / "props": that part has something to draw).
var _built := {}
var _nodes := {}   # Vector3i absolute submap -> Node3D, only for the submaps with something drawn
var _content_levels := PackedInt32Array()   # the levels with a node, ascending
var _view_want := CddaCoords.Z_LIMIT        # the cutaway asked for; Z_LIMIT: every level


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
	var key := [catalog.registry, catalog.registry_revision, tables]
	if _job_catalog == null or key != _job_key:
		_job_key = key
		_job_catalog = TerrainCatalog.new()
		_job_catalog.registry = catalog.registry
		_job_catalog.set_tables(tables)
		_job_props = PropCatalog.new(catalog.registry)
		_job_props.set_tables(tables)
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


## Runs on a worker: touches only the job and the job catalogs (the main thread keeps using `catalog` and
## `props`; set_id_tables and apply_snapshot wait for the job first). ArrayMesh building goes through the
## thread-safe RenderingServer.
func _compute(job: Job) -> void:
	_job_catalog.set_snapshot(job.snap)
	_job_props.set_snapshot(job.snap)
	var mesher := TerrainMesher.new(job.snap, _job_catalog)
	var pmesher := PropMesher.new(job.snap, _job_catalog, _job_props)
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
		catalog.set_snapshot(snap)
		props.set_snapshot(snap)
		coords.z_min = snap.z_min
		coords.z_max = snap.z_max
		if snapshot == null or snap.bubble_origin != snapshot.bubble_origin:
			coords.set_bubble_origin(snap.bubble_origin)
			for pos: Vector3i in _nodes:
				(_nodes[pos] as Node3D).position = coords.sm_to_world(pos)
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
	z_min_loaded = snap.z_max
	z_max_loaded = snap.z_min
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
	if _built.is_empty():
		z_min_loaded = 0
		z_max_loaded = 0
	var levels := {}
	for pos: Vector3i in _nodes:
		levels[pos.z] = true
	_content_levels = PackedInt32Array(levels.keys())
	_content_levels.sort()
	z_min_content = _content_levels[0] if not _content_levels.is_empty() else z_min_loaded
	z_max_content = _content_levels[-1] if not _content_levels.is_empty() else z_max_loaded
	_apply_view()
	return true


## Hides the levels above z (cutaway), within the levels that have something drawn. A z at or above the top one
## means every level, and keeps meaning it when later snapshots draw higher levels.
func set_view_z_max(z: int) -> void:
	_view_want = CddaCoords.Z_LIMIT if z >= z_max_content else z
	_apply_view()


## Moves the cutaway to the next level up (dir > 0) or down that has something drawn, jumping over empty sky
## or rock; stays put at the top or bottom one.
func step_view_z(dir: int) -> void:
	if dir > 0:
		for z in _content_levels:
			if z > view_z_max:
				set_view_z_max(z)
				return
	elif dir < 0:
		for i in range(_content_levels.size() - 1, -1, -1):
			if _content_levels[i] < view_z_max:
				set_view_z_max(_content_levels[i])
				return


## The levels with something drawn, ascending (from the last apply).
func levels_with_content() -> PackedInt32Array:
	return _content_levels


## The cutaway for what isn't terrain (creatures, gore, the player's body): with the view at the top level with
## something drawn nothing is cut, so a bird above the last roof still shows.
func things_z_max() -> int:
	return coords.z_max if view_z_max >= z_max_content else view_z_max


## "level 1 (-1..3)": the cutaway level and the range of levels with something drawn, for the HUD.
func level_text() -> String:
	return "level %d (%d..%d)" % [view_z_max, z_min_content, z_max_content]


func _apply_view() -> void:
	view_z_max = clampi(_view_want, z_min_content, z_max_content)
	_update_visibility()


func set_roofs_visible(v: bool) -> void:
	roofs_visible = v
	_update_visibility()


func built_revision(pos: Vector3i) -> int:
	return _built[pos]["rev"] if _built.has(pos) else -1


## The submap's node; null when it isn't loaded or has nothing to draw.
func node_of(pos: Vector3i) -> Node3D:
	return _nodes.get(pos)


func _mark_around(dirty: Dictionary, pos: Vector3i) -> void:
	dirty[pos] = true
	for d: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0),
			Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		dirty[pos + d] = true


func _drop(pos: Vector3i) -> void:
	_free_node(pos)
	_built.erase(pos)


## The submap's node, made when `make` and it has none yet.
func _node(pos: Vector3i, make: bool) -> Node3D:
	var node: Node3D = _nodes.get(pos)
	if node == null and make:
		node = Node3D.new()
		node.name = "sm_%d_%d_%d" % [pos.x, pos.y, pos.z]
		node.position = coords.sm_to_world(pos)
		node.visible = pos.z <= view_z_max
		add_child(node)
		_nodes[pos] = node
	return node


## Door leaves live under their submap's node, so a submap without one has none to drop.
func _free_node(pos: Vector3i) -> void:
	var node: Node3D = _nodes.get(pos)
	if node == null:
		return
	_drop_doors(pos, {})
	node.free()
	_nodes.erase(pos)


## Terrain first, then props (every terrain rebuild is followed by a props one, which frees an empty node).
func _build(pos: Vector3i, r: TerrainMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built.get(pos, {})
	if b.is_empty():
		b = {"pverts": 0, "counts": {}, "props": false}
		_built[pos] = b
	var drawn := r.terrain != null or r.roof != null or r.caps != null or not r.doors.is_empty()
	var node := _node(pos, drawn)
	if node != null:
		for part: Array in [["terrain", r.terrain], ["roof", r.roof], ["caps", r.caps]]:
			_set_mesh(node, part[0], part[1])
		_build_doors(node, pos, r.doors)
	b["rev"] = (snap.submaps[pos] as Snapshot.Submap).revision
	b["verts"] = r.vertices
	b["terrain"] = drawn


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


func _build_props(pos: Vector3i, r: PropMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built[pos]
	var drawn := r.props != null or r.roof_props != null or not r.models.is_empty() \
			or not r.roof_models.is_empty() or not r.glyphs.is_empty()
	var node := _node(pos, drawn)
	if node != null:
		_set_mesh(node, "props", r.props)
		_set_mesh(node, "roof_props", r.roof_props)
		_set_models(node, "models", r.models)
		_set_models(node, "roof_models", r.roof_models)
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
	b["counts"] = {"furniture": r.furniture, "items": r.items, "traps": r.traps, "glyphs": r.glyphs.size(),
			"models": r.model_props}
	b["props"] = drawn
	if not drawn and not b.get("terrain", false):
		_free_node(pos)   # nothing left to draw: open sky keeps no node


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


## Replaces the node's model holder: one multimesh per part of each model, an instance per prop.
static func _set_models(node: Node3D, part: String, models: Dictionary) -> void:
	var old := node.get_node_or_null(part)
	if old:
		old.free()
	if models.is_empty():
		return
	var holder := Node3D.new()
	holder.name = part
	for m: ModelLibrary.Model in models:
		var xfs: Array = models[m]
		for p: Array in m.parts:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = p[0]
			mm.instance_count = xfs.size()
			for k in xfs.size():
				mm.set_instance_transform(k, (xfs[k] as Transform3D) * (p[1] as Transform3D))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			holder.add_child(mmi)
	node.add_child(holder)


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
	for pos: Vector3i in _nodes:
		var node: Node3D = _nodes[pos]
		node.visible = pos.z <= view_z_max
		for part in ["roof", "roof_props", "roof_models"]:
			var roof := node.get_node_or_null(part) as Node3D
			if roof:
				roof.visible = roofs_visible
		var caps := node.get_node_or_null("caps") as Node3D
		if caps:
			caps.visible = pos.z == view_z_max
