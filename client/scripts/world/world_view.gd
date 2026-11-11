class_name WorldView
extends Node3D
## Shows the newest snapshot: one node per submap per z that has anything to draw (open sky gets none),
## holding "terrain", "roof" and "caps" meshes and "terrain_models", "terrain_roof_models" (TerrainMesher)
## and "props", "roof_props", "models", "roof_models" and "glyphs" (PropMesher: furniture, traps, item
## piles); models are one MultiMeshInstance3D per model part. Door leaves (TerrainMesher doors) and furniture
## doors, drawers and lids (PropMesher parts) are Grabbable children of the submap's node (block L8).
## Terrain is rebuilt when a submap's revision differs from the one built (any difference, not only an
## increase: a submap that leaves the bubble and comes back restarts at 1), together with its six
## neighbours, whose edge walls, wall tops and roof lids depend on it. Props are rebuilt with the
## terrain and also when only the detail_revision (items) changed.
## Every snapshot also gives `lighting` (WorldLighting, block C6) a new LightMap: CDDA's light and vis.
## Single items on the ground (piles with handles) are kept as item slots per submap, for a crosshair or a
## hand to point at (items_on_ray, items_near, item_slot; ItemPicker); hidden_items are left out of the piles.

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
var _rebuild_all := false   # set_id_tables came while a job was meshing or committing
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
var prop_counts := {"furniture": 0, "items": 0, "traps": 0, "glyphs": 0, "models": 0, "parts": 0}
## Asked for once per generation that doesn't match the snapshot's (live mode refetches).
var tables_mismatch := false
## Door leaves (Grabbable) by square. door_state keeps each one's angle across rebuilds; door_local: no sim,
## doors open and close in the client (door_open: square -> bool, read by VrWalk too).
var grabbables := {}
var _door_squares := {}   # submap -> {square: true}: the leaves _build_doors made there
var door_state := {}
var door_local := true
var door_open := {}
## Furniture doors, drawers and lids (Grabbable.part, block L8; PropMesher.Result.parts) by id ("x_y_z/door_1"),
## several to a square. The same node stays while its id and key last (a newer snapshot: sync_part); freed with
## its submap. grabbable_near / grabbable_on_ray find them with the door leaves.
var parts := {}
var _part_ids := {}    # submap -> {id: true}: the parts _build_parts made there
var _part_info := {}   # id -> [key, square]
var _parts_at := {}    # square -> Array of Grabbable
## Meshes a part is drawn with (a model has at most ModelLibrary.MAX_PARTS drawn meshes).
const MAX_PART_MESHES := 32
## Darkens the world by CDDA's light (block C6); main.gd turns it off with --no-light.
var lighting := WorldLighting.new()
## Vector3i absolute submap -> {"rev", "detail", "verts", "pverts", "counts", "terrain", "props", "slots"}: every
## submap built, drawn or not ("terrain" / "props": that part has something to draw).
var _built := {}
var _nodes := {}   # Vector3i absolute submap -> Node3D, only for the submaps with something drawn
var _content_levels := PackedInt32Array()   # the levels with a node, ascending
var _view_want := CddaCoords.Z_LIMIT        # the cutaway asked for; Z_LIMIT: every level
## Items not drawn (uid -> true), e.g. one held in a hand. Read only: change it with set_hidden_items.
var hidden_items := {}
const MAX_HIDDEN := 64         # per owner
const MAX_HIDDEN_OWNERS := 8
var _hidden_by_owner := {}     # StringName -> {uid: true}, see set_hidden_items_for
## An item is hit as a ball around the middle of what is drawn: this share of its size, ITEM_HIT_MIN_M to
## ITEM_HIT_MAX_M (a long item's ball would swallow its neighbours: a can next to a rifle).
const ITEM_HIT_SCALE := 0.6
const ITEM_HIT_MIN_M := 0.06
const ITEM_HIT_MAX_M := 0.15
var _slot_of := {}         # uid -> [submap, item slot] of each drawn item ("slots": tile -> [item slot, ...])
var _hidden_rev := 0       # counts set_hidden_items changes
var _hidden_at := {}       # uid -> submap that drew it when it was hidden (where it shows again)


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
	var light_on := false   # build `light` (lighting enabled)
	var light_lut := false  # with a new LUT (the natural light changed)
	var light: LightMap
	var catalog: TerrainCatalog   # the job catalogs it was prepared with (the worker reads only these)
	var props_catalog: PropCatalog
	var hidden := {}    # hidden_items when prepared (the worker's own copy) and their revision
	var hidden_rev := 0


func _init() -> void:
	add_child(lighting)


## Id tables for the snapshots that follow (contracts/id_tables.md). Null or invalid: the snapshot's
## names and the registry only. Everything built so far is rebuilt on the next apply.
func set_id_tables(t: IdTables) -> void:
	tables = t if t != null and t.is_valid() else null
	catalog.set_tables(tables)
	props.set_tables(tables)
	_rebuild_all = _task >= 0 or _committing != null   # a job made with the old tables: redo all after it
	_mark_all_stale()


func _mark_all_stale() -> void:
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
	if _rebuild_all:
		_rebuild_all = false
		_mark_all_stale()
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
	job.catalog = _job_catalog
	job.props_catalog = _job_props
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
	job.light_on = lighting.enabled
	job.light_lut = lighting.lut_ambient != LightMap.natural_light(snap)
	return job


## Runs on a worker: touches only the job and the job catalogs (the main thread keeps using `catalog` and
## `props` and may change them meanwhile; apply_snapshot waits for the job first). ArrayMesh building goes through the
## thread-safe RenderingServer.
func _compute(job: Job) -> void:
	job.catalog.set_snapshot(job.snap)
	job.props_catalog.set_snapshot(job.snap)
	var mesher := TerrainMesher.new(job.snap, job.catalog)
	var pmesher := PropMesher.new(job.snap, job.catalog, job.props_catalog)
	pmesher.hidden = job.hidden
	for pos in job.dirty:
		job.terrain[pos] = mesher.build(pos)
	for pos in job.detail:
		job.props[pos] = pmesher.build(pos)
	if job.light_on:
		job.light = LightMap.build(job.snap, job.light_lut)


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
		if job.light != null:
			lighting.apply(job.light, coords)
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
	catalog.set_snapshot(snap)   # a hidden-item rebuild may have pointed them elsewhere meanwhile
	props.set_snapshot(snap)
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


## World y of what one stands on at point p (x, z used) on level z: the floor, or the stair flight or ramp
## surface drawn on that square (TerrainMesher.surface_heights), so cameras and figures climb them. Squares
## are looked up once per shown snapshot (at most MAX_GROUND kept).
func ground_y(p: Vector3, z: int) -> float:
	var sq := coords.world_to_ms(p)
	sq.z = z
	var base := coords.ms_to_world(sq)
	var hs := _ground_heights(sq)
	if hs.size() != 4:
		return base.y
	var h := TerrainMesher.height_at(hs, clampf((p.x - base.x) / CddaCoords.TILE_M, 0.0, 1.0),
			clampf((p.z - base.z) / CddaCoords.TILE_M, 0.0, 1.0))
	return base.y + (clampf(h, -CddaCoords.LEVEL_M, CddaCoords.LEVEL_M) if is_finite(h) else 0.0)


const MAX_GROUND := 4096
var _ground := {}        # square -> its surface heights (empty: flat floor), for _ground_of
var _ground_ramps := {}
var _ground_of: Array = []   # [snapshot, tables] the cache was filled from


func _ground_heights(sq: Vector3i) -> PackedFloat32Array:
	if snapshot == null:
		return PackedFloat32Array()
	if _ground_of.size() != 2 or _ground_of[0] != snapshot or _ground_of[1] != tables or _ground.size() >= MAX_GROUND:
		_ground = {}
		_ground_ramps = {}
		_ground_of = [snapshot, tables]
	if not _ground.has(sq):
		var hs := PackedFloat32Array()
		var st := TerrainMesher.style_in(snapshot, catalog, sq)
		if st != null and (st.kind in [TerrainCatalog.Kind.STAIRS_UP, TerrainCatalog.Kind.RAMP_UP] or st.ramp_low):
			hs = TerrainMesher.surface_heights(sq, TerrainMesher.kind_lookup(snapshot, catalog),
					TerrainMesher.low_lookup(snapshot, catalog), _ground_ramps)
		_ground[sq] = hs
	return _ground[sq]


## How many submaps have a node (something drawn).
func node_count() -> int:
	return _nodes.size()


## Door leaves and furniture parts live under their submap's node, so a submap without one has none to drop.
func _free_node(pos: Vector3i) -> void:
	if _built.has(pos):
		_set_slots(pos, [])
	var node: Node3D = _nodes.get(pos)
	if node == null:
		return
	_drop_doors(pos, {})
	_drop_parts(pos, {})
	node.free()
	_nodes.erase(pos)


## Terrain first, then props (every terrain rebuild is followed by a props one, which frees an empty node).
func _build(pos: Vector3i, r: TerrainMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built.get(pos, {})
	if b.is_empty():
		b = {"pverts": 0, "counts": {}, "props": false}
		_built[pos] = b
	var drawn := r.terrain != null or r.roof != null or r.caps != null or not r.doors.is_empty() \
			or not r.models.is_empty() or not r.roof_models.is_empty()
	var node := _node(pos, drawn)
	if node != null:
		for part: Array in [["terrain", r.terrain], ["roof", r.roof], ["caps", r.caps]]:
			_set_mesh(node, part[0], part[1])
		_set_models(node, "terrain_models", r.models)
		_set_models(node, "terrain_roof_models", r.roof_models)
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
	if not keep.is_empty():
		_door_squares[pos] = keep


## Frees the submap's leaves not in `keep`. Live, their kept angle goes too: CDDA's state rules a leaf made again.
func _drop_doors(pos: Vector3i, keep: Dictionary) -> void:
	for sq: Vector3i in _door_squares.get(pos, {}):
		if keep.has(sq):
			continue
		var g: Grabbable = grabbables.get(sq)
		if g != null and is_instance_valid(g):
			g.free()
		grabbables.erase(sq)
		if not door_local:
			door_state.erase(sq)
	_door_squares.erase(pos)


## The leaf or furniture part nearest `p` (world) within `reach` metres on squares around it, or null. `ok`
## filters squares.
func grabbable_near(p: Vector3, reach: float, ok := Callable()) -> Grabbable:
	var c := coords.world_to_ms(p)
	var best: Grabbable = null
	var best_d := reach
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for g: Grabbable in _grabbables_at(c + Vector3i(dx, dy, 0)):
				if ok.is_valid() and not ok.call(g.square):
					continue
				var d := g.distance_to(p)
				if d <= best_d:
					best = g
					best_d = d
	return best


## The leaf or furniture part a ray (normalized `dir`) meets first on the squares around `centre` (same
## level), within `max_d`; [Grabbable, hit point] or [].
func grabbable_on_ray(origin: Vector3, dir: Vector3, centre: Vector3i, max_d: float) -> Array:
	var best: Array = []
	var best_t := max_d
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for g: Grabbable in _grabbables_at(centre + Vector3i(dx, dy, 0)):
				var t := g.ray_distance(origin, dir)
				if t < best_t:
					best_t = t
					best = [g, origin + dir * t]
	return best


## The door leaf and the furniture parts on square `sq` (live nodes only).
func _grabbables_at(sq: Vector3i) -> Array[Grabbable]:
	var out: Array[Grabbable] = []
	var d: Variant = grabbables.get(sq)
	if d != null and is_instance_valid(d):
		out.append(d)
	for g: Variant in _parts_at.get(sq, []):
		if is_instance_valid(g):
			out.append(g)
	return out


## The submap's furniture parts from PropMesher.Result.parts: a part whose id and key are already shown keeps its
## node (a grabbed one keeps its grab) and takes CDDA's newer state (sync_part); new ones are made, gone ones
## freed. A spec Grabbable.part refuses is drawn still (node "still_parts") rather than lost.
func _build_parts(node: Node3D, pos: Vector3i, specs: Array) -> void:
	var keep := {}
	var old := node.get_node_or_null("still_parts")
	if old:
		old.free()
	var still: Node3D = null
	for v: Variant in specs:
		if keep.size() >= PropMesher.MAX_PARTS:
			break
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var spec: Dictionary = v
		var id: Variant = spec.get("id")
		if typeof(id) != TYPE_STRING or keep.has(id):
			continue
		var g: Grabbable = parts.get(id) if is_instance_valid(parts.get(id)) else null
		var info: Array = _part_info.get(id, [])
		var key: Variant = spec.get("key")
		if g != null and g.get_parent() == node and info.size() == 2 and typeof(info[0]) == typeof(key) and info[0] == key:
			g.sync_part(_flag(spec, "cdda_open"), _flag(spec, "locked"))
		else:
			if parts.has(id):
				_free_part(id)
			var model := _part_model(spec)
			var made := spec.duplicate()
			made["mesh"] = model
			g = Grabbable.part(self, made)
			if g == null:   # refused (warned): draw it where it rests
				if still == null:
					still = Node3D.new()
					still.name = "still_parts"
					node.add_child(still)
				var piv: Variant = spec.get("pivot")
				model.transform = piv if typeof(piv) == TYPE_TRANSFORM3D and (piv as Transform3D).is_finite() else Transform3D()
				_set_part_items(model, spec)
				still.add_child(model)
				continue
			node.add_child(g)
			parts[id] = g
			_part_info[id] = [spec.get("key"), g.square]
			if not _parts_at.has(g.square):
				_parts_at[g.square] = []
			(_parts_at[g.square] as Array).append(g)
		keep[id] = true
		_set_part_items(g.contents(), spec)
	_drop_parts(pos, keep)
	if not keep.is_empty():
		_part_ids[pos] = keep


static func _flag(spec: Dictionary, key: String) -> bool:
	var v: Variant = spec.get(key, false)
	return typeof(v) == TYPE_BOOL and v


## A parentless node with the spec's meshes (pivot space), MAX_PART_MESHES at most; bad entries are skipped.
static func _part_model(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Model"
	var meshes: Variant = spec.get("meshes")
	if typeof(meshes) != TYPE_ARRAY:
		return root
	for e: Variant in meshes:
		if root.get_child_count() >= MAX_PART_MESHES:
			break
		if typeof(e) != TYPE_ARRAY or (e as Array).size() != 2 or not e[0] is Mesh or typeof(e[1]) != TYPE_TRANSFORM3D \
				or not (e[1] as Transform3D).is_finite():
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = e[0]
		mi.transform = e[1]
		root.add_child(mi)
	return root


## Replaces what lies on a part ("Items" under `at`, its contents()): the spec's items_mesh, items_models and
## items_glyphs, in pivot space.
static func _set_part_items(at: Node3D, spec: Dictionary) -> void:
	var old := at.get_node_or_null("Items")
	if old:
		old.free()
	var mesh: Variant = spec.get("items_mesh")
	var models: Variant = spec.get("items_models")
	var glyphs: Variant = spec.get("items_glyphs")
	var has_mesh := mesh is ArrayMesh
	var has_models := typeof(models) == TYPE_DICTIONARY and not (models as Dictionary).is_empty()
	var has_glyphs := typeof(glyphs) == TYPE_ARRAY and not (glyphs as Array).is_empty()
	if not has_mesh and not has_models and not has_glyphs:
		return
	var holder := Node3D.new()
	holder.name = "Items"
	if has_mesh:
		var mi := MeshInstance3D.new()
		mi.name = "shapes"
		mi.mesh = mesh
		holder.add_child(mi)
	if has_models:
		_set_models(holder, "models", models)
	if has_glyphs:
		for e: Variant in (glyphs as Array).slice(0, PropMesher.MAX_GLYPHS):
			if typeof(e) == TYPE_ARRAY and (e as Array).size() == 3 and typeof(e[0]) == TYPE_VECTOR3 \
					and typeof(e[1]) == TYPE_STRING and typeof(e[2]) == TYPE_COLOR:
				holder.add_child(_glyph(e[0], e[1], e[2]))
	at.add_child(holder)


## Frees the submap's parts not in `keep`. Live, their kept state goes too: CDDA's state rules a part made again.
func _drop_parts(pos: Vector3i, keep: Dictionary) -> void:
	for id: String in _part_ids.get(pos, {}):
		if keep.has(id):
			continue
		_free_part(id)
		if not door_local:
			door_state.erase(id)
	_part_ids.erase(pos)


func _free_part(id: String) -> void:
	var info: Array = _part_info.get(id, [])
	var g: Variant = parts.get(id)
	if info.size() == 2:
		var list: Array = _parts_at.get(info[1], [])
		list.erase(g)
		if list.is_empty():
			_parts_at.erase(info[1])
	if g != null and is_instance_valid(g):
		(g as Node).free()
	parts.erase(id)
	_part_info.erase(id)


func _build_props(pos: Vector3i, r: PropMesher.Result, snap: Snapshot) -> void:
	var b: Dictionary = _built[pos]
	var drawn := r.props != null or r.roof_props != null or not r.models.is_empty() \
			or not r.roof_models.is_empty() or not r.glyphs.is_empty() or not r.parts.is_empty()
	var node := _node(pos, drawn)
	if node != null:
		_set_mesh(node, "props", r.props)
		_set_mesh(node, "roof_props", r.roof_props)
		_set_models(node, "models", r.models)
		_set_models(node, "roof_models", r.roof_models)
		_build_parts(node, pos, r.parts)
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
			"models": r.model_props, "parts": r.parts.size()}
	b["props"] = drawn
	if not drawn and not b.get("terrain", false):
		_free_node(pos)   # nothing left to draw: open sky keeps no node
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


## Hides items for Hands (its owner set, see set_hidden_items_for).
func set_hidden_items(uids: Dictionary) -> void:
	set_hidden_items_for(&"hands", uids)


## Hides items (uid -> true; a copy is kept, MAX_HIDDEN at most per owner) for one owner, e.g. the hands holding
## copies or the physics bodies standing in for items; hidden_items is the union of all owners' sets, and an
## empty set drops the owner. Shows the ones no longer hidden by anyone: the props of the submaps that draw or
## hold a changed uid are rebuilt now, on this thread (only those), so a grabbed item leaves its pile in the same
## frame. A job meshed meanwhile with the old set is fixed as it commits.
func set_hidden_items_for(owner: StringName, uids: Dictionary) -> void:
	var mine := {}
	for u: Variant in uids:
		if u is int and mine.size() < MAX_HIDDEN:
			mine[u] = true
	if mine.size() < uids.size():
		push_warning("hidden items: %d given, kept %d (ints only, at most %d)" % [uids.size(), mine.size(), MAX_HIDDEN])
	if mine.is_empty():
		_hidden_by_owner.erase(owner)
	elif _hidden_by_owner.has(owner) or _hidden_by_owner.size() < MAX_HIDDEN_OWNERS:
		_hidden_by_owner[owner] = mine
	else:
		push_warning("hidden items: more than %d owners, %s ignored" % [MAX_HIDDEN_OWNERS, owner])
		return
	var next := {}
	for o: StringName in _hidden_by_owner:
		next.merge(_hidden_by_owner[o])
	var changed := _changed(hidden_items, next)
	hidden_items = next
	if changed.is_empty():
		return
	_hidden_rev += 1
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


## Rebuilds the props of the shown submaps that draw or held one of `changed`; sets props_built. Only a uid
## shown again whose submap isn't known (hidden while not drawn) makes it look through the piles.
func _rebuild_hidden(changed: Dictionary) -> void:
	var where := {}
	var lost := {}
	for u: Variant in changed:
		var s: Array = _slot_of.get(u, [])
		if not s.is_empty():
			where[s[0]] = true
			if hidden_items.has(u):
				_hidden_at[u] = s[0]
		elif _hidden_at.has(u):
			where[_hidden_at[u]] = true
		elif not hidden_items.has(u):
			lost[u] = true
		if not hidden_items.has(u):
			_hidden_at.erase(u)
	var swapped := {}   # submaps a committing job already shows: built from its snapshot
	if _committing != null:
		for k in maxi(_committing.next - _committing.dirty.size(), 0):
			swapped[_committing.detail[k]] = true
	if not lost.is_empty():
		for pos: Vector3i in _built:
			var sn := _committing.snap if swapped.has(pos) else snapshot
			if sn != null and _holds_any(pos, sn, lost):
				where[pos] = true
	var n := 0
	for pos: Vector3i in where:
		var snap := _committing.snap if swapped.has(pos) else snapshot
		if _built.has(pos) and snap != null and snap.submaps.has(pos):
			_build_props(pos, _mesh_props(pos, snap), snap)
			n += 1
	var shown := _committing.snap if _committing != null else snapshot
	if shown != null:
		catalog.set_snapshot(shown)   # the main-thread catalogs follow the snapshot being shown again
		props.set_snapshot(shown)
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


## One submap's props, meshed now on this thread with the main-thread catalogs (the worker has its own).
func _mesh_props(pos: Vector3i, snap: Snapshot) -> PropMesher.Result:
	catalog.set_snapshot(snap)
	props.set_snapshot(snap)
	var pm := PropMesher.new(snap, catalog, props)
	pm.hidden = hidden_items
	return pm.build(pos)


## Radius of the ball an item of `size_m` is hit as.
static func item_hit_radius(size_m: float) -> float:
	return clampf(size_m * ITEM_HIT_SCALE, ITEM_HIT_MIN_M, ITEM_HIT_MAX_M)


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
	if s.is_empty() or hidden_items.has(uid) or not _built.has(s[0]) or not _slot_shown(s[1]):
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
				if not hidden_items.has(e[0]) and _slot_shown(e):
					out.append([pos, e])
	return out


## An item on a furniture part (drawer, cabinet door shelf) can be pointed at while the part is open (a lid's
## always: they lie on top of it); one behind a model's doors or lid while one of them is open
## (PropMesher.Result.item_slots ride / gates). A part that is gone hides its items.
func _slot_shown(e: Array) -> bool:
	if e.size() < 8:
		return true
	var ride: String = e[6]
	if not ride.is_empty():
		var g: Variant = parts.get(ride)
		if not is_instance_valid(g) or not (g is Grabbable) or ((g as Grabbable).kind != "lid" and not part_open(g)):
			return false
	var gates: PackedStringArray = e[7]
	if gates.is_empty():
		return true
	for id in gates:
		var g: Variant = parts.get(id)
		if is_instance_valid(g) and g is Grabbable and part_open(g):
			return true
	return false


## A furniture part open far enough to see into: past Grabbable.OPEN_FRAC of its travel.
static func part_open(g: Grabbable) -> bool:
	return g.max_amount > 0.0 and g.amount >= g.max_amount * Grabbable.OPEN_FRAC


## How far an item drawn with part `e[6]` has moved from where PropMesher placed it (submap-local): the part's
## Leaf motion, taken from the part's own space (Leaf space = pivot space at rest). Identity for the others.
func _ride_xf(e: Array) -> Transform3D:
	if e.size() < 8 or (e[6] as String).is_empty():
		return Transform3D.IDENTITY
	var g: Variant = parts.get(e[6])
	if not is_instance_valid(g) or not (g is Grabbable) or (g as Grabbable).leaf == null:
		return Transform3D.IDENTITY
	var p := g as Grabbable
	var m := p.transform * p.leaf.transform * p.transform.affine_inverse()
	return m if m.is_finite() else Transform3D.IDENTITY


func _slot_centre(pos: Vector3i, e: Array) -> Vector3:
	return coords.sm_to_world(pos) + _ride_xf(e) * (e[5] as Vector3)


func _slot_entry(pos: Vector3i, e: Array, point: Vector3) -> Array:
	var xf: Transform3D = _ride_xf(e) * (e[3] as Transform3D)
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
	for pos: Vector3i in _nodes:
		var node: Node3D = _nodes[pos]
		node.visible = pos.z <= view_z_max
		for part in ["roof", "roof_props", "roof_models", "terrain_roof_models"]:
			var roof := node.get_node_or_null(part) as Node3D
			if roof:
				roof.visible = roofs_visible
		var caps := node.get_node_or_null("caps") as Node3D
		if caps:
			caps.visible = pos.z == view_z_max
