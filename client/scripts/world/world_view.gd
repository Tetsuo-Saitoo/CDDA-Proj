class_name WorldView
extends Node3D
## Shows the newest snapshot: one node per submap per z, holding "terrain", "roof" and "caps" meshes
## (TerrainMesher) and "props", "roof_props", "models", "roof_models" and "glyphs" (PropMesher:
## furniture, traps, item piles; models are one MultiMeshInstance3D per model part).
## Terrain is rebuilt when a submap's revision differs from the one built (any difference, not only an
## increase: a submap that leaves the bubble and comes back restarts at 1), together with its six
## neighbours, whose edge walls, wall tops and roof lids depend on it. Props are rebuilt with the
## terrain and also when only the detail_revision (items) changed.
## Single items on the ground (piles with handles) are kept as item slots per submap, for a crosshair or a
## hand to point at (items_on_ray, items_near, item_slot; ItemPicker); hidden_items are left out of the piles.

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
var prop_counts := {"furniture": 0, "items": 0, "traps": 0, "glyphs": 0, "models": 0}
## Asked for once per generation that doesn't match the snapshot's (live mode refetches).
var tables_mismatch := false
## Door leaves (Grabbable) by square. door_state keeps each one's angle across rebuilds; door_local: no sim,
## doors open and close in the client (door_open: square -> bool, read by VrWalk too).
var grabbables := {}
var door_state := {}
var door_local := true
var door_open := {}
## Items not drawn (uid -> true), e.g. one held in a hand. Read only: change it with set_hidden_items.
var hidden_items := {}
const MAX_HIDDEN := 64
## An item is hit as a ball around the middle of what is drawn: this share of its size, at least ITEM_HIT_MIN_M.
const ITEM_HIT_SCALE := 0.6
const ITEM_HIT_MIN_M := 0.06
var _built := {}   # Vector3i absolute submap -> {"rev", "detail", "node", "verts", "pverts", "counts", "slots"}
var _slot_of := {}         # uid -> [submap, item slot] of each drawn item ("slots": tile -> [item slot, ...])
var _hidden_rev := 0       # counts set_hidden_items changes
var _hidden_wait := {}     # uids whose hiding changed while a worker meshed: rebuilt when it is done


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
	var hidden := {}    # hidden_items when prepared (the worker's own copy) and their revision
	var hidden_rev := 0


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
	if not _hidden_wait.is_empty():   # the catalogs are free again
		var changed := _hidden_wait
		_hidden_wait = {}
		_rebuild_hidden(changed)


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
	job.hidden = hidden_items.duplicate()
	job.hidden_rev = _hidden_rev
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
	pmesher.hidden = job.hidden
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
			var pr: PropMesher.Result = job.props[pos]
			if job.hidden_rev != _hidden_rev and _holds_any(pos, snap, _changed(job.hidden, hidden_items)):
				pr = _mesh_props(pos, snap)   # an item was hidden or shown since the worker started
			_build_props(pos, pr, snap)
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
	_drop_doors(pos, {})
	_set_slots(pos, [])
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
	_build_doors(node, pos, r.doors)
	b["rev"] = (snap.submaps[pos] as Snapshot.Submap).revision
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


func _build_props(pos: Vector3i, r: PropMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built[pos]
	var node: Node3D = b["node"]
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
	_set_slots(pos, r.item_slots)


## Replaces the item slots of submap `pos` (PropMesher.Result.item_slots).
func _set_slots(pos: Vector3i, slots: Array) -> void:
	var b: Dictionary = _built[pos]
	for tile_slots: Array in (b.get("slots", {}) as Dictionary).values():
		for e: Array in tile_slots:
			var s: Array = _slot_of.get(e[0], [])
			if not s.is_empty() and s[0] == pos:
				_slot_of.erase(e[0])
	var by_tile := {}
	for e: Array in slots:
		if not by_tile.has(e[2]):
			by_tile[e[2]] = []
		(by_tile[e[2]] as Array).append(e)
		_slot_of[e[0]] = [pos, e]
	b["slots"] = by_tile


## Hides items (uid -> true; a copy is kept, MAX_HIDDEN at most) and shows the ones no longer listed: the
## props of the submaps that draw or hold a changed uid are rebuilt now, on this thread (only those), so a
## grabbed item leaves its pile in the same frame. While a worker meshes a submitted snapshot (it has the
## catalogs) the rebuild waits until it is done.
func set_hidden_items(uids: Dictionary) -> void:
	var next := {}
	for u: Variant in uids:
		if u is int and next.size() < MAX_HIDDEN:
			next[u] = true
	if next.size() < uids.size():
		push_warning("hidden items: %d given, kept %d (ints only, at most %d)" % [uids.size(), next.size(), MAX_HIDDEN])
	var changed := _changed(hidden_items, next)
	hidden_items = next
	if changed.is_empty():
		return
	_hidden_rev += 1
	if _task >= 0:
		_hidden_wait.merge(changed)
		return
	_rebuild_hidden(changed)


## Uids in one of the two sets but not the other.
static func _changed(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for u: Variant in a:
		if not b.has(u):
			out[u] = true
	for u: Variant in b:
		if not a.has(u):
			out[u] = true
	return out


## Rebuilds the props of the shown submaps that draw or hold one of `changed`; sets props_built.
func _rebuild_hidden(changed: Dictionary) -> void:
	var swapped := {}   # submaps a committing job already shows: built from its snapshot
	if _committing != null:
		for k in maxi(_committing.next - _committing.dirty.size(), 0):
			swapped[_committing.detail[k]] = true
	var n := 0
	for pos: Vector3i in _built.keys():
		var snap := _committing.snap if swapped.has(pos) else snapshot
		if snap != null and snap.submaps.has(pos) and _holds_any(pos, snap, changed):
			_build_props(pos, _mesh_props(pos, snap), snap)
			n += 1
	props_built = n


## Whether submap `pos` draws one of `uids` or holds it in its snapshot handles.
func _holds_any(pos: Vector3i, snap: Snapshot, uids: Dictionary) -> bool:
	if uids.is_empty():
		return false
	for u: Variant in uids:
		var s: Array = _slot_of.get(u, [])
		if not s.is_empty() and s[0] == pos:
			return true
	var sm: Snapshot.Submap = snap.submaps.get(pos)
	if sm == null:
		return false
	var hs := sm.handles
	for k in range(1, hs.size(), Snapshot.HANDLE_STRIDE):
		if uids.has(hs[k]):
			return true
	return false


## One submap's props, meshed now on this thread (only while no worker has the catalogs).
func _mesh_props(pos: Vector3i, snap: Snapshot) -> PropMesher.Result:
	catalog.set_snapshot(snap)
	props.set_snapshot(snap)
	var pm := PropMesher.new(snap, catalog, props)
	pm.hidden = hidden_items
	return pm.build(pos)


## Radius of the ball an item of `size_m` is hit as.
static func item_hit_radius(size_m: float) -> float:
	return maxf(size_m * ITEM_HIT_SCALE, ITEM_HIT_MIN_M)


## The drawn item a ray (normalized `dir`) meets first on the 3 x 3 squares around `centre` (same level),
## within `max_d`: [uid, itype, square, hit point, world transform (as drawn, scaled), size_m], or [].
func items_on_ray(origin: Vector3, dir: Vector3, centre: Vector3i, max_d: float) -> Array:
	var best: Array = []
	var best_t := max_d
	for e: Array in _slots_around(centre):
		var c := _slot_centre(e[0], e[1])
		var t := _ray_ball(origin, dir, c, item_hit_radius(e[1][4]))
		if t <= best_t and t < INF:
			best_t = t
			best = _slot_entry(e[0], e[1], origin + dir * t)
	return best


## The drawn item nearest `p` (its ball's surface; inside counts as nearer) within `radius` on the 3 x 3
## squares around `centre`, same entry as items_on_ray (the point: the ball's point nearest p), or [].
func items_near(p: Vector3, radius: float, centre: Vector3i) -> Array:
	var best: Array = []
	var best_d := radius
	for e: Array in _slots_around(centre):
		var c := _slot_centre(e[0], e[1])
		var r := item_hit_radius(e[1][4])
		var d := p.distance_to(c) - r
		if d <= best_d:
			best_d = d
			best = _slot_entry(e[0], e[1], c + (p - c).limit_length(r))
	return best


## The drawn item `uid` as items_on_ray gives it (the point: its middle), [] when it isn't drawn.
func item_slot(uid: int) -> Array:
	var s: Array = _slot_of.get(uid, [])
	if s.is_empty() or hidden_items.has(uid) or not _built.has(s[0]):
		return []
	return _slot_entry(s[0], s[1], _slot_centre(s[0], s[1]))


## [submap, item slot] of the drawn items on the 3 x 3 squares around `centre`.
func _slots_around(centre: Vector3i) -> Array:
	var out := []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var sq := centre + Vector3i(dx, dy, 0)
			var pos := CddaCoords.ms_to_sm(sq)
			var b: Dictionary = _built.get(pos, {})
			if b.is_empty():
				continue
			var l := CddaCoords.ms_to_local(sq)
			for e: Array in (b.get("slots", {}) as Dictionary).get(l.y * CddaCoords.SEEX + l.x, []):
				if not hidden_items.has(e[0]):
					out.append([pos, e])
	return out


func _slot_centre(pos: Vector3i, e: Array) -> Vector3:
	return coords.sm_to_world(pos) + (e[5] as Vector3)


func _slot_entry(pos: Vector3i, e: Array, point: Vector3) -> Array:
	var xf: Transform3D = e[3]
	var tile: int = e[2]
	var sq := CddaCoords.sm_to_ms(pos) + Vector3i(tile % CddaCoords.SEEX, tile / CddaCoords.SEEX, 0)
	return [e[0], e[1], sq, point, Transform3D(xf.basis, xf.origin + coords.sm_to_world(pos)), e[4]]


## Distance along a ray (normalized `d`) to a ball: 0 from inside it, INF when it misses or lies behind.
static func _ray_ball(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := c - o
	var t := oc.dot(d)
	var miss := oc.length_squared() - t * t - r * r
	if miss > 0.0:
		return INF
	var th := sqrt(-miss)
	if t + th < 0.0:
		return INF
	return maxf(t - th, 0.0)


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
	for pos: Vector3i in _built:
		var node: Node3D = _built[pos]["node"]
		node.visible = pos.z <= view_z_max
		for part in ["roof", "roof_props", "roof_models"]:
			var roof := node.get_node_or_null(part) as Node3D
			if roof:
				roof.visible = roofs_visible
		var caps := node.get_node_or_null("caps") as Node3D
		if caps:
			caps.visible = pos.z == view_z_max
