class_name TerrainMesher
extends RefCounted
## Block C2: builds the terrain meshes of one submap at one z-level from a validated Snapshot.
##
## Geometry is in submap-local metres: tile (lx, ly) spans x lx..lx+1, z ly..ly+1, y 0..3; the caller
## places the result at the submap's corner. Walls fill their whole tile (CDDA walls are a tile thick,
## and collision will be too), so neighbour connections show up as culled shared faces and as the
## direction doors, windows and fences run. Outputs three meshes:
## - terrain: floors, walls, door frames, windows (glass in its own transparent surface), stairs, ramps, props;
##   door leaves are not in it: they come out as `doors` (WorldView makes each a Grabbable that swings);
## - roof: roof terrain and, where the level above isn't loaded, a lid over roofed (indoor) tiles;
## - caps: wall tops hidden under the floor above, shown only when the level above is cut away.
## Tiles whose style has a registry model (TerrainCatalog) come out as `models` / `roof_models` transforms
## instead of procedural geometry (see _model_tile); WorldView draws them as multimeshes like prop models.

const K := TerrainCatalog.Kind
const SEEX := CddaCoords.SEEX
const H := CddaCoords.LEVEL_M
const DOOR_H := 2.2
const SILL_H := 0.9
const ROOF_LIFT := 0.03     # roof terrain sits just above wall tops so the two never z-fight
const DIRS: Array[Vector3i] = [Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(-1, 0, 0)]  # N E S W

const PX := 1
const NX := 2
const PY := 4
const NY := 8
const PZ := 16
const NZ := 32
const ALL := 63
const DIR_FACE: Array[int] = [NZ, PX, PZ, NX]   # face of a tile that looks toward DIRS[i]
## Facing (index into DIRS) -> yaw that turns a placeholder's front (-z) that way (PropMesher too).
const YAW: Array[float] = [0.0, -PI / 2, PI, PI / 2]
## Placeholders face -z, models +z (Godot's model front): a half turn about y.
const MODEL_TURN := Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)), Vector3.ZERO)
## A model facing DIRS[UNTURNED] needs no turn (+z is south).
const UNTURNED := 2
const CORNERS: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]   # NW NE SE SW (x, z)
const UP := Vector3i(0, 0, 1)
## Kinds one can step onto from stairs (and onto the level above from their top).
const WALKABLE := [K.FLOOR, K.ROOF, K.DOOR, K.SHRUB, K.TREE, K.LADDER_UP]

## The material of terrain under the open sky and of roofs: like "solid", but the weather changes it (wet_ground).
const GROUND := "ground"
const WET_ROUGHNESS := 0.35
const WET_SPECULAR := 0.8
const WET_TINT := Color(0.72, 0.74, 0.78)
static var _materials := {}
static var _materials_lock := Mutex.new()


class Buf:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	## Four corners in order around the face; fixes the winding so the face looks along n.
	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
		# Godot front faces wind clockwise: (b - a) x (c - a) must point away from the viewer.
		if (b - a).cross(c - a).dot(n) > 0.0:
			var t := b
			b = d
			d = t
		for v in [a, b, c, a, c, d]:
			verts.push_back(v)
			normals.push_back(n)
			colors.push_back(col)

	func box(lo: Vector3, hi: Vector3, col: Color, faces := ALL) -> void:
		if faces & PX:
			quad(Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3.RIGHT, col)
		if faces & NX:
			quad(Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.LEFT, col)
		if faces & PY:
			quad(Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.UP, col)
		if faces & NY:
			quad(Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.DOWN, col * 0.8)
		if faces & PZ:
			quad(Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.BACK, col)
		if faces & NZ:
			quad(Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3.FORWARD, col)

	## One triangle; fixes the winding so it looks along n. Degenerate triangles are skipped.
	func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
		var cr := (b - a).cross(c - a)
		if cr.length_squared() < 1e-10:
			return
		if cr.dot(n) > 0.0:
			var t := b
			b = c
			c = t
		for v in [a, b, c]:
			verts.push_back(v)
			normals.push_back(n)
			colors.push_back(col)

	## Horizontal 1 x 1 tile surface at height y, seen from above and (darker) from below.
	func slab(o: Vector3, y: float, col: Color) -> void:
		var a := o + Vector3(0, y, 0)
		var b := o + Vector3(1, y, 0)
		var c := o + Vector3(1, y, 1)
		var d := o + Vector3(0, y, 1)
		quad(a, b, c, d, Vector3.UP, col)
		quad(a, b, c, d, Vector3.DOWN, col * 0.75)

	func commit(mesh: ArrayMesh, material: Material) -> void:
		if verts.is_empty():
			return
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)


class Result:
	var terrain: ArrayMesh   # null when empty
	var roof: ArrayMesh
	var caps: ArrayMesh
	var vertices := 0
	## Door leaves to swing: {square, local (corner in the submap), along_x, color, glass, open, locked}.
	var doors: Array[Dictionary] = []
	## Tiles drawn as registry models: ModelLibrary.Model -> Array of Transform3D (submap-local, the model's
	## own transform: MODEL_TURN included, like PropMesher.Result.models). Roof terrain's go to roof_models.
	var models := {}
	var roof_models := {}


var _snap: Snapshot
var _cat: TerrainCatalog
var _solid: Buf      # where the square being built puts its solid faces: _indoor or _outdoor
var _indoor: Buf     # squares under a roof (material "solid")
var _outdoor: Buf    # squares under the open sky (material "ground": the weather wets it)
var _glass: Buf
var _roof: Buf
var _caps: Buf
var _doors: Array[Dictionary] = []
var _models := {}
var _roof_models := {}
var _kind_at: Callable
var _low_at: Callable
var _walk := func(k: int) -> bool: return k in WALKABLE
var _ramp_cache := {}


func _init(snap: Snapshot, catalog: TerrainCatalog) -> void:
	_snap = snap
	_cat = catalog
	_kind_at = kind_lookup(snap, catalog)
	_low_at = low_lookup(snap, catalog)


func build(sm_pos: Vector3i) -> Result:
	_indoor = Buf.new()
	_outdoor = Buf.new()
	_solid = _indoor
	_glass = Buf.new()
	_roof = Buf.new()
	_caps = Buf.new()
	_doors = []
	_models = {}
	_roof_models = {}
	_ramp_cache = {}
	var sm: Snapshot.Submap = _snap.submaps[sm_pos]
	var above_loaded := _snap.submaps.has(sm_pos + Vector3i(0, 0, 1))
	var base := CddaCoords.sm_to_ms(sm_pos)
	for ly in SEEX:
		for lx in SEEX:
			var i := ly * SEEX + lx
			var st := _cat.style_for(sm.ter[i])
			var o := Vector3(lx, 0, ly)
			var flags := sm.flags[i]
			_solid = _indoor if flags & Snapshot.FLAG_ROOF else _outdoor
			_tile(base + Vector3i(lx, ly, 0), o, st, (flags & Snapshot.FLAG_NO_FLOOR) == 0)
			if (flags & Snapshot.FLAG_ROOF) and not above_loaded and st.kind != K.ROOF:
				_roof.slab(o, H, Color(0.32, 0.3, 0.3))
	var r := Result.new()
	r.vertices = (_indoor.verts.size() + _outdoor.verts.size() + _glass.verts.size() + _roof.verts.size()
			+ _caps.verts.size())
	r.terrain = _mesh([_outdoor, _indoor, _glass], [GROUND, "solid", "glass"])
	r.roof = _mesh([_roof], [GROUND])
	r.caps = _mesh([_caps], ["solid"])
	r.doors = _doors
	r.models = _models
	r.roof_models = _roof_models
	return r


func _tile(p: Vector3i, o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	if st.model != null:
		_model_tile(p, o, st, floor_ok)
		return
	match st.kind:
		K.NONE, K.STAIRS_DOWN, K.LADDER_DOWN:
			pass   # open air, or the hole the stairs/ladder from below come up through
		K.FLOOR:
			var hs := _ramp_heights(p) if st.ramp_low else PackedFloat32Array()
			if not hs.is_empty():
				_wedge(p, o, hs, st.color)   # a ramp's low end
			elif floor_ok:
				_solid.slab(o, 0.0, st.color)
		K.ROOF:
			if floor_ok:
				_roof.slab(o, ROOF_LIFT, st.color)
		K.WATER:
			_solid.slab(o, -0.1, st.color)
		K.WALL:
			_wall(p, o, st)
		K.DOOR:
			_door(p, o, st, floor_ok)
		K.WINDOW:
			_window(p, o, st)
		K.FENCE:
			_fence(p, o, st, floor_ok)
		K.STAIRS_UP:
			_steps(p, o, 6, st.color)
		K.RAMP_UP:
			_wedge(p, o, _ramp_heights(p), st.color)
		K.LADDER_UP:
			_ladder(o, st.color, floor_ok)
		K.TREE:
			_ground(o, floor_ok)
			_solid.box(o + Vector3(0.4, 0, 0.4), o + Vector3(0.6, H, 0.6), st.color, ALL & ~NY)
			_solid.box(o + Vector3(0.05, 1.6, 0.05), o + Vector3(0.95, H - 0.1, 0.95), st.color2)
		K.TREETOP:
			_solid.box(o + Vector3(0.0, 0.0, 0.0), o + Vector3(1.0, 2.2, 1.0), st.color2)
		K.SHRUB:
			_ground(o, floor_ok)
			_solid.box(o + Vector3(0.15, 0, 0.15), o + Vector3(0.85, st.height, 0.85), st.color, ALL & ~NY)
		_:
			_ground(o, floor_ok)
			_solid.box(o + Vector3(0.1, 0, 0.1), o + Vector3(0.9, st.height, 0.9), st.color, ALL & ~NY)


## A tile drawn as its registry model, at the tile centre on its floor (roof terrain: lifted like its slab;
## then the entry's offset and scale). Facing: walls and windows with their run along the model's x (front
## +z out of the wall: south for an east-west run, east for a north-south one), fences the same over the
## fences they join, stairs and ramps with the bottom step at the front and rising toward the back (the
## flight's rise direction), the rest unturned (+z south) or turned freely with `random_yaw`. Floor, roof
## and water models replace their slab; standing things (trees, shrubs, ladders, fences, boxes) keep the
## ground slab under them; walls, windows, stairs and tree tops are the model alone.
func _model_tile(p: Vector3i, o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	var y := 0.0
	var facing := UNTURNED
	var free := false
	match st.kind:
		K.FLOOR:
			if not floor_ok:
				return
		K.ROOF:
			if not floor_ok:
				return
			y = ROOF_LIFT
		K.WATER, K.TREETOP:
			pass
		K.WALL, K.WINDOW:
			facing = UNTURNED if _connects(p, 1) or _connects(p, 3) else 1
		K.FENCE:
			_fence_base(o, st, floor_ok)
			facing = UNTURNED if _fence_joins(p, st, 1) or _fence_joins(p, st, 3) else 1
		K.STAIRS_UP, K.RAMP_UP:
			facing = (_flight(p).x + 2) % 4
		_:
			_ground(o, floor_ok)
			free = st.random_yaw
	var yaw := YAW[facing]
	if free:
		var rng := RandomNumberGenerator.new()
		rng.seed = square_hash(p)
		yaw = rng.randf() * TAU
	var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * st.scale),
			o + Vector3(0.5, y, 0.5) + st.offset) * MODEL_TURN
	var md := _roof_models if st.kind == K.ROOF else _models
	if not md.has(st.model):
		md[st.model] = []
	(md[st.model] as Array).append(xf)


func _ground(o: Vector3, floor_ok: bool) -> void:
	if floor_ok:
		_solid.slab(o, 0.0, TerrainCatalog.GROUND)


func _wall(p: Vector3i, o: Vector3, st: TerrainCatalog.Style) -> void:
	var faces := 0
	for d in 4:
		var n := _style_at(p + DIRS[d])
		# A model wall may not fill its tile: the face toward it stays.
		if n == null or n.kind != K.WALL or n.height < st.height or n.model != null:
			faces |= DIR_FACE[d]
	_solid.box(o, o + Vector3(1, st.height, 1), st.color, faces)
	_top(p, o, st.height, st.color)


## Top face of a full-height block: in the terrain mesh, or in caps when a floor above covers it.
func _top(p: Vector3i, o: Vector3, h: float, col: Color) -> void:
	var b := _caps if h >= H and _covered_above(p) else _solid
	b.box(o + Vector3(0, h, 0), o + Vector3(1, h, 1), col, PY)


func _door(p: Vector3i, o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	var along_x := _connects(p, 1) or _connects(p, 3)   # wall runs east-west: the leaf spans x
	if floor_ok:
		_solid.slab(o, 0.0, Color(0.4, 0.38, 0.35))
	var frame := _frame_color(p)
	_solid.box(o + Vector3(0, DOOR_H, 0), o + Vector3(1, H, 1), frame, ALL & ~PY)
	_top(p, o, H, frame)
	var col := Color(0.6, 0.8, 0.9, 0.35) if st.glass else st.color
	if st.state <= 1:   # a leaf (closed or open): its own node, so it can swing
		_doors.append({"square": p, "local": o, "along_x": along_x, "color": col, "glass": st.glass,
				"open": st.state == 1, "locked": st.locked})


func _window(p: Vector3i, o: Vector3, st: TerrainCatalog.Style) -> void:
	var along_x := _connects(p, 1) or _connects(p, 3)
	var sill := 0.1 if st.state == 3 else SILL_H
	var top := H - 0.1 if st.state == 3 else DOOR_H
	_solid.box(o, o + Vector3(1, sill, 1), st.color, ALL & ~NY)
	_solid.box(o + Vector3(0, top, 0), o + Vector3(1, H, 1), st.color, ALL & ~PY)
	_top(p, o, H, st.color)
	var pane := _glass if st.state != 2 else _solid
	var col := st.color2 if st.state == 2 else Color(0.6, 0.8, 0.9, 0.35)
	if st.state == 1:
		return
	if along_x:
		pane.box(o + Vector3(0, sill, 0.47), o + Vector3(1, top, 0.53), col, ALL & ~(PY | NY))
	else:
		pane.box(o + Vector3(0.47, sill, 0), o + Vector3(0.53, top, 1), col, ALL & ~(PY | NY))


## A post in the middle, a rail to each connected neighbour (fences, walls, doors, windows).
func _fence(p: Vector3i, o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	_fence_base(o, st, floor_ok)
	var t := 0.04
	var c := o + Vector3(0.5, 0, 0.5)
	_solid.box(c - Vector3(0.06, 0, 0.06), c + Vector3(0.06, st.height + 0.05, 0.06), st.color, ALL & ~NY)
	for d in 4:
		if not _fence_joins(p, st, d):
			continue
		var dv := Vector3(DIRS[d].x, 0, DIRS[d].y) * 0.5
		var lo := c + Vector3(minf(dv.x, 0) - (t if dv.x == 0 else 0.0), 0, minf(dv.z, 0) - (t if dv.z == 0 else 0.0))
		var hi := c + Vector3(maxf(dv.x, 0) + (t if dv.x == 0 else 0.0), st.height, maxf(dv.z, 0) + (t if dv.z == 0 else 0.0))
		_solid.box(lo, hi, st.color, ALL & ~NY)


## Under a fence: the ground, or roof for gutters (they line roof edges).
func _fence_base(o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	if st.height < 0.5:
		if floor_ok:
			_roof.slab(o, ROOF_LIFT, Color(0.32, 0.3, 0.3))
	else:
		_ground(o, floor_ok)


## The fence at p joins its neighbour in direction d (fences, walls, doors, windows).
func _fence_joins(p: Vector3i, st: TerrainCatalog.Style, d: int) -> bool:
	return _joins(st, _style_at(p + DIRS[d]), [K.FENCE, K.WALL, K.DOOR, K.WINDOW])


## Stairs: one flight per connected block (a 2x2 or 1x3 staircase is one wide or long flight, not a flight per
## tile in its own direction), see stair_flight. Each tile draws its share of the flight's steps.
func _steps(p: Vector3i, o: Vector3, count: int, col: Color) -> void:
	var f := stair_flight(p, _kind_at, K.STAIRS_UP, _walk)
	var rise := f.x
	var n := maxi(1, ceili(float(count) / f.z))   # steps on this tile, the same tread depth over the flight
	for k in n:
		var u0 := float(k) / n
		var u1 := float(k + 1) / n
		var h := H * (f.y + u1) / f.z
		var lo: Vector3
		var hi: Vector3
		match rise:
			0: # north: -z
				lo = Vector3(0, 0, 1 - u1)
				hi = Vector3(1, h, 1 - u0)
			1:
				lo = Vector3(u0, 0, 0)
				hi = Vector3(u1, h, 1)
			2:
				lo = Vector3(0, 0, u0)
				hi = Vector3(1, h, u1)
			_:
				lo = Vector3(1 - u1, 0, 0)
				hi = Vector3(1 - u0, h, 1)
		_solid.box(o + lo, o + hi, col.darkened(0.04 * ((f.y * n + k) % 2)), ALL & ~NY)


## stair_flight for the stairs or ramp at p, over this snapshot (terrain models rise along it).
func _flight(p: Vector3i) -> Vector3i:
	return stair_flight(p, _kind_at, _style_at(p).kind, _walk)


## Stable non-negative hash of an absolute square (random yaw, item slots: never changes between rebuilds).
static func square_hash(p: Vector3i) -> int:
	var h := (p.x * 73856093) ^ (p.y * 19349663) ^ (p.z * 83492791)
	h = (h ^ (h >> 13)) * 0x5bd1e995
	return (h ^ (h >> 15)) & 0x7fffffff


## A ramp square: its sloped top (two triangles) and side faces down to whatever is lower beside it; no bottom.
func _wedge(p: Vector3i, o: Vector3, hs: PackedFloat32Array, col: Color) -> void:
	var c: Array[Vector3] = []
	for i in 4:
		c.append(o + Vector3(CORNERS[i].x, hs[i], CORNERS[i].y))
	# Split along the diagonal with the lower ends: where two runs meet (the corner of a ditch's banks) the surface
	# is the higher of their two slopes, which creases along that diagonal, without a shelf.
	var tris := [[0, 1, 2], [0, 2, 3]] if hs[0] + hs[2] <= hs[1] + hs[3] else [[0, 1, 3], [1, 2, 3]]
	for t: Array in tris:
		var a: Vector3 = c[t[0]]
		var b: Vector3 = c[t[1]]
		var d: Vector3 = c[t[2]]
		var n := (b - a).cross(d - a).normalized()
		_solid.tri(a, b, d, n if n.y >= 0.0 else -n, col)
	var side := col.darkened(0.15)
	for e in 4:
		var e1 := (e + 1) % 4
		var nb := p + DIRS[e]
		var b0 := 0.0
		var b1 := 0.0
		var ns := _style_at(nb)
		if ns != null and ns.kind == K.WALL and ns.height >= maxf(hs[e], hs[e1]):
			continue   # the wall covers this side
		var nh := _ramp_heights(nb)
		if not nh.is_empty():   # edge e is the neighbour's edge e + 2: our corner e is its e + 3, e + 1 its e + 2
			b0 = nh[(e + 3) % 4]
			b1 = nh[(e + 2) % 4]
		if hs[e] - b0 < 0.001 and hs[e1] - b1 < 0.001:
			continue
		var bot0 := o + Vector3(CORNERS[e].x, minf(b0, hs[e]), CORNERS[e].y)
		var bot1 := o + Vector3(CORNERS[e1].x, minf(b1, hs[e1]), CORNERS[e1].y)
		var nrm := Vector3(DIRS[e].x, 0, DIRS[e].y)
		_solid.tri(bot0, bot1, c[e1], nrm, side)
		_solid.tri(bot0, c[e1], c[e], nrm, side)


func _ramp_heights(p: Vector3i) -> PackedFloat32Array:
	return ramp_heights(p, _kind_at, _low_at, _ramp_cache)


## The flight square p belongs to: Vector3i(rise direction (index into DIRS), p's place along it from the
## bottom, the flight's length in squares). `kind_at(q)` gives a square's terrain kind (-1 unknown; it is asked
## about the level above p too) and `walkable(kind)` whether one can step off onto it. The block is the squares of
## p's kind joined to p (at most MAX_FLIGHT); every square of it gets the same direction, so a block never shows
## crossing flights. The direction scores, per square of the block: the level above has a floor right beyond
## the top end (where you step off upstairs; the squares above the flight are the stairwell you come up
## through) +6 when that level is loaded; a walkable square right before the bottom end +2; a wall right
## beyond the top end +3.
const MAX_FLIGHT := 24
const ABOVE_SCORE := 6

static func stair_flight(p: Vector3i, kind_at: Callable, kind: int, walkable: Callable) -> Vector3i:
	var block := {p: true}
	var todo: Array[Vector3i] = [p]
	while not todo.is_empty() and block.size() < MAX_FLIGHT:
		var q: Vector3i = todo.pop_back()
		for d in DIRS:
			if not block.has(q + d) and kind_at.call(q + d) == kind:
				block[q + d] = true
				todo.append(q + d)
	var best := 0
	var best_score := -1
	for d in 4:
		var score := 0
		for q: Vector3i in block:
			var entry: int = kind_at.call(q - DIRS[d])
			if not block.has(q - DIRS[d]) and entry >= 0 and walkable.call(entry):
				score += 2
			if not block.has(q + DIRS[d]):
				if kind_at.call(q + DIRS[d]) == K.WALL:
					score += 3
				var top: int = kind_at.call(q + DIRS[d] + UP)
				if top >= 0 and walkable.call(top):
					score += ABOVE_SCORE
		if score > best_score:
			best_score = score
			best = d
	var i := 0
	while block.has(p - DIRS[best] * (i + 1)):
		i += 1
	var ahead := 0
	while block.has(p + DIRS[best] * (ahead + 1)):
		ahead += 1
	return Vector3i(best, i, i + 1 + ahead)


## Ramps. A CDDA road, earth, sidewalk, concrete or rail ramp is a run of plain "low end" squares (t_ramp_up_low,
## t_earth_ramp_up_low, ...) then RAMP_UP squares (the high end), with the level above beyond them; above the run
## lie the RAMP_DOWN and see-through top squares (drawn as nothing). The surface rises evenly from the floor at
## the back of the first low square to the level above at the front of the last RAMP_UP square: a 1 + 1 ramp
## is 0..H/2 on the low square and H/2..H on the high one. The low end has no flag in CDDA, only its id, so
## `low_at(q)` (TerrainCatalog.Style.ramp_low: plain ground whose id contains "ramp") says it may be one, and
## only a square straight behind a RAMP_UP run rising away from it becomes one.
const MAX_RUN := 8                       # squares followed along a ramp run, each way
const NOT_RAMP := Vector3i(-2, 0, 0)
const RAMP_CORNER := Vector3i(-1, 0, 0)

## Where square p sits on a ramp: Vector3i(rise direction (index into DIRS), its place from the bottom with the
## low squares counted, the run's length); RAMP_CORNER where two runs meet (an L-shaped ramp: no run of its own,
## its corners take the heights of the runs beside it); NOT_RAMP when p draws no ramp.
## - A RAMP_UP square rises away from the nearest low end straight behind it; ties go to the side whose top
##   meets a floor on the level above (kind_at is asked about it), then a wall at the top.
## - A low square belongs to the nearest RAMP_UP square straight ahead of it that rises that way.
## - RAMP_UP squares of a ramp without low ends rise like a flight of stairs (stair_flight).
## `cache` keeps answers about squares between calls on the same map.
static func ramp_place(p: Vector3i, kind_at: Callable, low_at: Callable, cache := {}) -> Vector3i:
	var key := Vector4i(p.x, p.y, p.z, 2)
	if cache.has(key):
		return cache[key]
	var r := _low_run(p, kind_at, low_at, cache)
	if r == NOT_RAMP:
		var high: bool = kind_at.call(p) == K.RAMP_UP
		if high or low_at.call(p):
			var beside := false
			for e in 4:
				beside = beside or _low_run(p + DIRS[e], kind_at, low_at, cache) != NOT_RAMP
			if beside and (high or _owners(p, kind_at, low_at, cache).size() > 1):
				r = RAMP_CORNER
			elif high:
				r = stair_flight(p, kind_at, K.RAMP_UP, func(k: int) -> bool: return k in WALKABLE)
	cache[key] = r
	return r


## Corner heights of the ramp surface on square p, in metres above its floor, in CORNERS order (NW, NE, SE,
## SW); empty when p draws no ramp. A corner square's points take the highest run beside them; a point no run
## reaches stays on the floor (low end) or at the level above (high end).
static func ramp_heights(p: Vector3i, kind_at: Callable, low_at: Callable, cache := {}) -> PackedFloat32Array:
	var r := ramp_place(p, kind_at, low_at, cache)
	if r == NOT_RAMP:
		return PackedFloat32Array()
	if r != RAMP_CORNER:
		return run_heights(r)
	var hs := PackedFloat32Array([-1.0, -1.0, -1.0, -1.0])
	for e in 4:
		var n := _low_run(p + DIRS[e], kind_at, low_at, cache)
		if n == NOT_RAMP:
			continue
		var nh := run_heights(n)
		hs[e] = maxf(hs[e], nh[(e + 3) % 4])
		hs[(e + 1) % 4] = maxf(hs[(e + 1) % 4], nh[(e + 2) % 4])
	var base := H if kind_at.call(p) == K.RAMP_UP else 0.0
	for i in 4:
		if hs[i] < 0.0:
			hs[i] = base
	return hs


## Corner heights (CORNERS order) of a square at place r of a run or stair flight (ramp_place, stair_flight).
static func run_heights(r: Vector3i) -> PackedFloat32Array:
	var h0 := H * r.y / maxi(1, r.z)
	var h1 := H * (r.y + 1) / maxi(1, r.z)
	match r.x:
		0:
			return PackedFloat32Array([h1, h1, h0, h0])
		1:
			return PackedFloat32Array([h0, h1, h1, h0])
		2:
			return PackedFloat32Array([h0, h0, h1, h1])
		_:
			return PackedFloat32Array([h1, h0, h0, h1])


## Surface height at (u, v) in 0..1 across a square (u east, v south) with corner heights hs.
static func height_at(hs: PackedFloat32Array, u: float, v: float) -> float:
	return lerpf(lerpf(hs[0], hs[1], u), lerpf(hs[3], hs[2], u), v)


## The run p is on when a low end decides it (no corners, no stair-like fallback), else NOT_RAMP.
static func _low_run(p: Vector3i, kind_at: Callable, low_at: Callable, cache: Dictionary) -> Vector3i:
	var key := Vector4i(p.x, p.y, p.z, 1)
	if cache.has(key):
		return cache[key]
	var r := NOT_RAMP
	if kind_at.call(p) == K.RAMP_UP:
		var d := _ramp_dir(p, kind_at, low_at, cache)
		if d >= 0:
			r = _high_run(p, d, kind_at, low_at, cache)
	elif low_at.call(p):
		var own := _owners(p, kind_at, low_at, cache)
		if own.size() == 1:
			var d: int = own.keys()[0]
			var m: int = own[d]
			var f := _high_run(p + DIRS[d] * m, d, kind_at, low_at, cache)
			if f.y - m >= 0:
				r = Vector3i(d, f.y - m, f.z)
	cache[key] = r
	return r


## Run of RAMP_UP square p rising toward d: the RAMP_UP squares behind it, the low squares behind those, the
## RAMP_UP squares ahead.
static func _high_run(p: Vector3i, d: int, kind_at: Callable, low_at: Callable, cache: Dictionary) -> Vector3i:
	var high := _count(p, -1, d, kind_at)
	var first := p - DIRS[d] * high
	var low := 0
	for m in range(1, MAX_RUN + 1):
		var q := first - DIRS[d] * m
		if not low_at.call(q):
			break
		if m > 1:   # a low square nearer to another run is that run's (one beside an L-shaped ramp's leg)
			var own := _owners(q, kind_at, low_at, cache)
			var nearer := false
			for e: int in own:
				nearer = nearer or (e != d and own[e] < m)
			if nearer:
				break
		low = m
	return Vector3i(d, low + high, low + high + 1 + _count(p, 1, d, kind_at))


## RAMP_UP squares in a row from p (not counted) toward way * DIRS[d] (way 1 ahead, -1 behind), at most MAX_RUN.
static func _count(p: Vector3i, way: int, d: int, kind_at: Callable) -> int:
	var n := 0
	while n < MAX_RUN and kind_at.call(p + DIRS[d] * (way * (n + 1))) == K.RAMP_UP:
		n += 1
	return n


## Rise direction of RAMP_UP square p, -1 when no low end lies straight behind it (after RAMP_UP squares only).
static func _ramp_dir(p: Vector3i, kind_at: Callable, low_at: Callable, cache: Dictionary) -> int:
	var key := Vector4i(p.x, p.y, p.z, 0)
	if cache.has(key):
		return cache[key]
	var best := -1
	var best_score := -1
	for d in 4:
		var high := _count(p, -1, d, kind_at)
		if high >= MAX_RUN or not low_at.call(p - DIRS[d] * (high + 1)):
			continue
		var top := p + DIRS[d] * (_count(p, 1, d, kind_at) + 1)
		var score := (MAX_RUN - high) * 16
		var above: int = kind_at.call(top + UP)
		if above in WALKABLE:
			score += 4
		if kind_at.call(top) == K.WALL:
			score += 2
		if score > best_score:
			best_score = score
			best = d
	cache[key] = best
	return best


## Runs a low square may belong to: {direction: squares to the RAMP_UP square that rises that way}, the
## nearest ones only (two when the square is the inside corner of an L-shaped ramp).
static func _owners(p: Vector3i, kind_at: Callable, low_at: Callable, cache: Dictionary) -> Dictionary:
	var found := {}
	var nearest := MAX_RUN + 1
	for d in 4:
		for k in range(1, MAX_RUN + 1):
			var q := p + DIRS[d] * k
			if low_at.call(q):
				continue
			if k <= nearest and kind_at.call(q) == K.RAMP_UP and _ramp_dir(q, kind_at, low_at, cache) == d:
				if k < nearest:
					found.clear()
					nearest = k
				found[d] = k
			break
	return found


func _ladder(o: Vector3, col: Color, floor_ok: bool) -> void:
	_ground(o, floor_ok)
	for x in [0.3, 0.66]:
		_solid.box(o + Vector3(x, 0, 0.47), o + Vector3(x + 0.04, H, 0.53), col)
	var y := 0.3
	while y < H:
		_solid.box(o + Vector3(0.3, y, 0.48), o + Vector3(0.7, y + 0.04, 0.52), col)
		y += 0.35


func _style_at(p: Vector3i) -> TerrainCatalog.Style:
	return style_in(_snap, _cat, p)


## Style of square p in snap, null where nothing is loaded.
static func style_in(snap: Snapshot, cat: TerrainCatalog, p: Vector3i) -> TerrainCatalog.Style:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	return cat.style_for(sm.ter[l.y * SEEX + l.x])


## `kind_at` for stair_flight and ramp_place over a snapshot: a square's terrain kind, -1 where nothing is loaded.
static func kind_lookup(snap: Snapshot, cat: TerrainCatalog) -> Callable:
	return func(q: Vector3i) -> int:
		var st := style_in(snap, cat, q)
		return -1 if st == null else st.kind


## `low_at` for ramp_place over a snapshot: the square's id names a ramp's low end (TerrainCatalog.Style.ramp_low).
static func low_lookup(snap: Snapshot, cat: TerrainCatalog) -> Callable:
	return func(q: Vector3i) -> bool:
		var st := style_in(snap, cat, q)
		return st != null and st.ramp_low


## Corner heights (CORNERS order) of the stair flight or ramp surface drawn on square p, empty where none is: what
## a look ray meets on stairs and ramps.
static func surface_heights(p: Vector3i, kind_at: Callable, low_at: Callable, cache := {}) -> PackedFloat32Array:
	if kind_at.call(p) == K.STAIRS_UP:
		return run_heights(stair_flight(p, kind_at, K.STAIRS_UP, func(k: int) -> bool: return k in WALKABLE))
	return ramp_heights(p, kind_at, low_at, cache)


## Wall-like neighbour in direction d (index into DIRS): doors and windows run along those.
func _connects(p: Vector3i, d: int) -> bool:
	return _joins(_style_at(p), _style_at(p + DIRS[d]), [K.WALL, K.DOOR, K.WINDOW])


## CDDA's rule: a tile joins a neighbour whose connect groups it connects to. Without id tables
## (no groups on either side) neighbours of the given kinds join.
func _joins(st: TerrainCatalog.Style, n: TerrainCatalog.Style, kinds: Array) -> bool:
	if st == null or n == null:
		return false
	if st.connects_to != 0 or n.groups != 0:
		return (st.connects_to & n.groups) != 0
	return n.kind in kinds


## A floor (not roof terrain, which is drawn lifted and can be hidden) lies on top of tile p.
func _covered_above(p: Vector3i) -> bool:
	var up := p + Vector3i(0, 0, 1)
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(up))
	if sm == null:
		return false
	var l := CddaCoords.ms_to_local(up)
	var i := l.y * SEEX + l.x
	if sm.flags[i] & Snapshot.FLAG_NO_FLOOR:
		return false
	return not _cat.style_for(sm.ter[i]).kind in [K.NONE, K.ROOF, K.STAIRS_DOWN, K.LADDER_DOWN]


func _frame_color(p: Vector3i) -> Color:
	for d in 4:
		var n := _style_at(p + DIRS[d])
		if n != null and n.kind == K.WALL:
			return n.color
	return Color(0.7, 0.68, 0.64)


func _mesh(bufs: Array, mats: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for i in bufs.size():
		(bufs[i] as Buf).commit(mesh, material(mats[i]))
	return mesh if mesh.get_surface_count() > 0 else null


## How wet the ground and roofs look, 0 dry .. 1 soaked: darker and shinier. Main thread.
static func wet_ground(wet: float) -> void:
	var m := material(GROUND)
	var w := clampf(wet, 0.0, 1.0)
	m.roughness = lerpf(0.9, WET_ROUGHNESS, w)
	m.metallic_specular = lerpf(0.5, WET_SPECULAR, w)
	m.albedo_color = Color.WHITE.lerp(WET_TINT, w)


## The shared material `name` ("solid", "ground" or "glass"), made on first use by whichever thread asks first: the meshing
## worker and the main thread (props rebuilt for hidden items) both do, hence the lock.
static func material(name: String) -> StandardMaterial3D:
	_materials_lock.lock()
	var m: StandardMaterial3D = _materials.get(name)
	if m == null:
		m = StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = 0.9
		if name == "glass":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.render_priority = WorldLighting.UNDER_PRIORITY   # darkened with what is behind it
			m.roughness = 0.1
			m.metallic_specular = 0.8
		_materials[name] = m
	_materials_lock.unlock()
	return m
