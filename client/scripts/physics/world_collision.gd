class_name WorldCollision
extends Node3D
## Block E2 slice 1 (item physics): static collision near the player for the item bodies (ItemBodies). Box shapes
## on the squares within ACTIVE_R of a centre square (the player's), on its level and the one below, read from the
## newest snapshot the way the meshers and LookRay / VrWalk read it, every index bounds-checked:
## - a floor slab per square, unless Snapshot.FLAG_NO_FLOOR (open air, a hole: items fall to the level below);
## - a box filling the square (1 x 3 x 1 m) for terrain CDDA can't walk through (move_cost 0: walls, closed doors,
##   windows, trees); a door counts as the client shows it (WorldView.door_open in mock mode); without id tables
##   the look decides (VrWalk.BLOCKS);
## - impassable furniture (move_cost < 0): the same full box;
## - other furniture: a box over the square, coverage / 100 x FURN_FULL_M high (none under FURN_MIN_M: flowers);
##   FLAT_SURF furniture (tables, counters) is as high as the top surface PropMesher lays items on (PropShapes.info),
##   so items rest on its top.
## Stairs and ramps get a flat floor slab for now; their sloped surfaces (TerrainMesher.surface_heights) come later.
## Rebuilt only when the centre square, the snapshot (instance or seq), the id tables or a client-side door change,
## and then only the shapes whose box changed are touched: StaticBody3D nodes, pooled and reused, at most
## max_shapes (the nearest squares first). Its own physics layer, LAYER_WORLD (nothing else in the client uses
## physics). Nothing here decides a game outcome: these boxes only stop the client's item bodies.

const LAYER_WORLD := 1 << 8    # physics layer 9: this collision
const LAYER_ITEMS := 1 << 9    # physics layer 10: item bodies (ItemBodies)
const ACTIVE_R := 6.0          # metres from the middle of the centre square to the middle of a square
## 113 squares x 2 levels, a slab each plus a box on wall and furniture squares: ~230-450 in practice.
const MAX_SHAPES := 640
const SLAB_M := 0.2            # floor slab thickness, under the floor line (thick enough that a fall can't skip it)
const FURN_FULL_M := 1.5       # furniture box height at coverage 100
const FURN_MIN_M := 0.05       # furniture lower than this gets no box
const FLAT_MIN_M := 0.3        # FLAT_SURF furniture without a known surface height: at least this high
const SLAB := 0                # shape kinds, one of each at most per square
const BOX := 1
const K := TerrainCatalog.Kind

var world: WorldView
## () -> Variant: the centre square (Vector3i), null for none. Default: the snapshot's player square.
var centre := Callable()
var max_shapes := MAX_SHAPES
var rebuilds := 0              # how many times the shapes were rebuilt
var last_touched := 0          # shapes placed, resized, moved or released by the last rebuild
var _key := []
var _active := {}              # Vector4i(x, y, z, kind) -> StaticBody3D
var _spec := {}                # Vector4i -> AABB, local to the square's corner at its floor
var _pool: Array[StaticBody3D] = []   # released bodies, disabled (out of the physics space)
var _warned_cap := false

static var _offsets: Array[Vector2i] = []


func _init(w: WorldView) -> void:
	name = "WorldCollision"
	world = w
	w.coords.origin_shifted.connect(shift)


func _process(_delta: float) -> void:
	update()


## Rebuilds when something it depends on changed; true when it did.
func update() -> bool:
	var snap := world.snapshot
	var c: Variant = null
	if snap != null:
		c = centre.call() if centre.is_valid() else snap.player_pos
	if snap == null or not c is Vector3i:
		if not _active.is_empty():
			_apply({})
		_key = []
		return false
	var doors := world.door_open.hash() if world.door_local else 0
	var tables_id := world.tables.get_instance_id() if world.tables != null else 0
	var key := [snap.get_instance_id(), snap.seq, c, tables_id, doors]
	if key == _key:
		return false
	_key = key
	rebuild(c)
	return true


## Builds the shapes around square c from the current snapshot.
func rebuild(c: Vector3i) -> void:
	rebuilds += 1
	var want := {}
	var full := false
	for off: Vector2i in offsets():
		for dz: int in [0, -1]:
			var p := Vector3i(c.x + off.x, c.y + off.y, c.z + dz)
			for e: Array in specs(p):
				if want.size() >= max_shapes:
					full = true
					break
				want[Vector4i(p.x, p.y, p.z, e[0])] = e[1]
	if full and not _warned_cap:
		_warned_cap = true
		push_warning("world collision: more than %d shapes near %s, the farthest left out" % [max_shapes, c])
	_apply(want)


func shape_count() -> int:
	return _active.size()


## The box of `kind` (SLAB / BOX) on square p, in world space; an empty AABB when there is none.
func box_at(p: Vector3i, kind: int) -> AABB:
	var k := Vector4i(p.x, p.y, p.z, kind)
	if not _spec.has(k):
		return AABB()
	var a: AABB = _spec[k]
	return AABB(world.coords.ms_to_world(p) + a.position, a.size)


## The body holding that box (tests), null when there is none.
func body_at(p: Vector3i, kind: int) -> StaticBody3D:
	return _active.get(Vector4i(p.x, p.y, p.z, kind))


## How high the box on square p reaches above its floor (wall, furniture), 0 when it has none. Read from the
## snapshot, so it answers for squares the shape cap left out too.
func top_at(p: Vector3i) -> float:
	var top := 0.0
	for e: Array in specs(p):
		if e[0] == BOX:
			top = maxf(top, (e[1] as AABB).end.y)
	return top


## The shapes square p needs: [[kind, AABB local to its corner], ...], none when it isn't in the snapshot.
func specs(p: Vector3i) -> Array:
	var snap := world.snapshot
	if snap == null:
		return []
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return []
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	if i < 0 or i >= sm.ter.size() or i >= sm.furn.size() or i >= sm.flags.size():
		return []
	var t := CddaCoords.TILE_M
	if _ter_blocks(p, sm.ter[i], snap):
		return [[BOX, AABB(Vector3.ZERO, Vector3(t, CddaCoords.LEVEL_M, t))]]
	var out := []
	if (sm.flags[i] & Snapshot.FLAG_NO_FLOOR) == 0:
		out.append([SLAB, AABB(Vector3(0.0, -SLAB_M, 0.0), Vector3(t, SLAB_M, t))])
	var h := furniture_height(sm.furn[i], snap)
	if h > 0.0:
		out.append([BOX, AABB(Vector3.ZERO, Vector3(t, h, t))])
	return out


## Height of the box furniture `f` gets (0: none); see the class comment.
func furniture_height(f: int, snap: Snapshot) -> float:
	if f <= 0:
		return 0.0
	var d := _def("furn", f, snap.furn_names, snap)
	if d == null:
		return 0.0
	if d.move_cost < 0:
		return CddaCoords.LEVEL_M
	var h := clampi(d.coverage, 0, 100) / 100.0 * FURN_FULL_M
	if d.has("FLAT_SURF"):
		var top := _surface_top(f)
		h = top if top > 0.0 else maxf(h, FLAT_MIN_M)
	return h if h >= FURN_MIN_M else 0.0


## Moves every shape by `delta` (CddaCoords.origin_shifted).
func shift(delta: Vector3) -> void:
	for b: StaticBody3D in _active.values():
		b.position += delta


## Square offsets within ACTIVE_R, nearest first (the shape cap keeps the nearest).
static func offsets() -> Array[Vector2i]:
	if _offsets.is_empty():
		var n := ceili(ACTIVE_R)
		for dy in range(-n, n + 1):
			for dx in range(-n, n + 1):
				if dx * dx + dy * dy <= ACTIVE_R * ACTIVE_R:
					_offsets.append(Vector2i(dx, dy))
		_offsets.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			if a.length_squared() != b.length_squared():
				return a.length_squared() < b.length_squared()
			return a.y < b.y if a.y != b.y else a.x < b.x)
	return _offsets


## Makes the shapes match `want` (Vector4i -> local AABB), touching only those that changed.
func _apply(want: Dictionary) -> void:
	var touched := 0
	for k: Vector4i in _active.keys():
		if not want.has(k):
			_release(_active[k])
			_active.erase(k)
			_spec.erase(k)
			touched += 1
	for k: Vector4i in want:
		var a: AABB = want[k]
		if _active.has(k) and _spec[k] == a:
			continue
		var b: StaticBody3D = _active[k] if _active.has(k) else _take()
		var shape := (b.get_child(0) as CollisionShape3D).shape as BoxShape3D
		shape.size = a.size
		b.position = world.coords.ms_to_world(Vector3i(k.x, k.y, k.z)) + a.get_center()
		_active[k] = b
		_spec[k] = a
		touched += 1
	last_touched = touched


func _take() -> StaticBody3D:
	if not _pool.is_empty():
		var b: StaticBody3D = _pool.pop_back()
		b.process_mode = Node.PROCESS_MODE_INHERIT   # back into the physics space
		return b
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	add_child(body)
	return body


func _release(b: StaticBody3D) -> void:
	b.process_mode = Node.PROCESS_MODE_DISABLED   # DISABLE_MODE_REMOVE: out of the physics space
	_pool.append(b)


## True when terrain `ter` on square p stops an item (a wall box), as VrWalk.can_stand judges it.
func _ter_blocks(p: Vector3i, ter: int, snap: Snapshot) -> bool:
	var style := world.catalog.style_for(ter)
	if style.kind == K.DOOR:
		var open := style.state != 0
		if world.door_local:
			var o: Variant = world.door_open.get(p, open)
			open = o if o is bool else open
		return not open
	var d := _def("ter", ter, snap.ter_names, snap)
	if d != null:
		return d.move_cost <= 0
	return style.kind in VrWalk.BLOCKS


## The highest surface PropMesher lays items on for furniture `f` (its placeholder shape), 0 when none is known.
func _surface_top(f: int) -> float:
	var prop := world.props.furniture(f)
	if prop == null:
		return 0.0
	var surfaces: Variant = PropShapes.info(prop.shape).get("surfaces", [])
	var top := 0.0
	if surfaces is Array:
		for v: Variant in surfaces:
			if v is float and is_finite(v):
				top = maxf(top, v)
	return minf(top, CddaCoords.LEVEL_M)


## Definition of a snapshot id: by index when the tables match the snapshot, else by the snapshot's name (VrWalk).
func _def(table: String, id: int, names: Dictionary, snap: Snapshot) -> IdTables.Def:
	var t := world.tables
	if t == null:
		return null
	if snap.ids_generation < 0 or snap.ids_generation == t.generation:
		return t.def_at(table, id)
	var n: Variant = names.get(id, "")
	return t.def_named(table, n) if n is String else null
