class_name PropMesher
extends RefCounted
## Block C3: builds the props of one submap from a validated Snapshot: furniture, known traps and item
## piles, as placeholder shapes (PropShapes) chosen by PropCatalog, in submap-local metres like
## TerrainMesher, and lists the transforms of props that have a model (ModelLibrary; WorldView draws
## them as multimeshes). Props on roof terrain go to separate meshes and lists, hidden with the roofs.
##
## Facing (90° steps), as in Project Zomboid: furniture faces the open side it is used from. CDDA sends
## no per-tile rotation (mapgen rotation isn't in the snapshot), so it is read from the neighbours.
## Joined tiles (the same furniture, or furniture in each other's connect groups: a counter run with its
## sink) are laid out together:
## - rows (ROW_SHAPES: counters, sofas, benches, shelves, desks, ...): a straight run of joined tiles
##   shares one facing, across the run (a tile in an L corner goes with its longer run);
## - beds and bathtubs: a block of joined tiles shares one facing, along its long axis when it is one
##   tile wide (head at the wall end); a block bigger than one bed splits into beds BED_LEN long from the
##   head end, 2 wide when the block is exactly 2 wide, else 1 wide (a dorm row), and links (the joins a
##   shape draws) stay inside each bed;
## - anything else (tables, hedges): the whole block shares one facing.
## Each facing scores the tiles' fronts and backs, summed over the run or block; the best wins (ties: a
## hash of the piece). CDDA's hint counts most: a neighbour in one of the prop's `rotates_to` groups
## (racks face the room, street lights the road), and for seats (ALIGN_WORKBENCH, or a plain chair,
## stool or bench) a table or counter. Then the front onto walkable floor (not a wall, window, door or
## blocking furniture) and the back to a wall. Runs over MAX_RUN and blocks over MAX_BLOCK tiles: each
## tile on its own. `random_yaw` props turn freely. Item piles show up to MAX_SHOWN items
## (the four largest from the snapshot, small clutter for the rest) at sub-tile slots (4 x 4 per tile)
## picked by a hash of the square, so a pile looks the same every rebuild. A pile whose tile has item
## handles (contracts/snapshot.md) shows one item per handle instead, at its placed spot or its slot,
## and lists each as an item slot (Result.item_slots) a crosshair or a hand can point at; `hidden`
## ones (held in a hand) are left out. Items rest on the surfaces
## of the furniture they share a tile with (tables, shelves) and are hidden in closed containers. A
## furniture model's `surface_N` planes replace the placeholder's surfaces (items behind a model's doors
## are drawn there and hidden by the doors).

const K := TerrainCatalog.Kind
const SEEX := CddaCoords.SEEX
const DIRS := TerrainMesher.DIRS
const MAX_SHOWN := 8
const MAX_GLYPHS := 144
const SUB := 4   # sub-tiles per tile side
## Facing (index into DIRS) -> yaw that turns a shape's front (-z) that way.
const YAW: Array[float] = TerrainMesher.YAW
## Shapes face -z, models +z (Godot's model front): a half turn about y.
const MODEL_TURN := TerrainMesher.MODEL_TURN
const WALLISH := [K.WALL, K.WINDOW, K.DOOR]
const WALKABLE := [K.FLOOR, K.ROOF, K.SHRUB]
## Layouts of joined tiles (see the class notes).
enum Lay { FREE, ROW, LENGTH }
const ROW_SHAPES := ["counter", "sink", "sofa", "bench", "park_bench", "shelf", "bookcase", "desk",
		"workbench", "dresser", "cabinet_tall", "locker", "filing_cabinet", "fridge", "glass_fridge",
		"chest_freezer", "appliance", "oven", "stove", "toilet", "display_case", "glass_cabinet", "vending",
		"arcade", "machine", "console", "chair", "stool", "armchair"]
const LENGTH_SHAPES := ["bed", "bathtub"]
## Seats that turn to a table beside them even without CDDA's ALIGN_WORKBENCH.
const SEATS := ["chair", "stool", "armchair", "bench"]
const MAX_RUN := 12
const MAX_BLOCK := 24
const BED_LEN := 2
const NO_LAYOUT := Vector2i(0, -2)
const CLUTTER: Array[Color] = [Color(0.7, 0.68, 0.62), Color(0.45, 0.5, 0.55), Color(0.62, 0.45, 0.3),
		Color(0.8, 0.8, 0.78), Color(0.5, 0.36, 0.32)]
## Bounds of the item shapes at unit size (PropShapes builds them from y 0 up): the middle is what a
## pointer aims at, the top where the next item of a stack lies, the longest side the item's size.
const ITEM_BOX := {
	"item_box": AABB(Vector3(-0.51, 0, -0.51), Vector3(1.02, 0.9, 1.02)),
	"item_book": AABB(Vector3(-0.5, 0, -0.38), Vector3(1.0, 0.32, 0.76)),
	"item_cloth": AABB(Vector3(-0.5, 0, -0.4), Vector3(1.0, 0.28, 0.8)),
	"item_bottle": AABB(Vector3(-0.24, 0, -0.24), Vector3(0.48, 1.08, 0.48)),
	"item_can": AABB(Vector3(-0.37, 0, -0.37), Vector3(0.74, 0.89, 0.74)),
	"item_long": AABB(Vector3(-0.1, 0, -1.4), Vector3(0.2, 0.22, 2.7)),
	"item_tool": AABB(Vector3(-0.3, 0, -0.9), Vector3(0.6, 0.2, 1.5)),
	"item_small": AABB(Vector3(-0.5, 0, -0.35), Vector3(1.0, 0.6, 0.85)),
	"item_bag": AABB(Vector3(-0.45, 0, -0.35), Vector3(0.9, 0.85, 0.7)),
	"item_corpse": AABB(Vector3(-0.5, 0, -0.28), Vector3(1.12, 0.3, 0.56)),
}
const ITEM_BOX_OTHER := AABB(Vector3(-0.42, 0, -0.42), Vector3(0.84, 1.0, 0.84))   # blocks, anything else
const GLYPH_UP := 0.3   # item glyph cards float this far above their spot


class Result:
	var props: ArrayMesh        # null when empty
	var roof_props: ArrayMesh
	var glyphs: Array = []      # [position (submap-local), symbol, colour]
	var models := {}            # ModelLibrary.Model -> Array of Transform3D (submap-local)
	var roof_models := {}
	var model_props := 0
	var vertices := 0
	var furniture := 0
	var items := 0
	var traps := 0
	## One per drawn item that has a handle: [uid, itype, tile, Transform3D (submap-local, as drawn,
	## scaled), size_m (its longest side), centre (submap-local: the middle of what is drawn)].
	var item_slots: Array = []


## Items not to draw (uid -> true), e.g. one held in a hand: no shape, no slot, not counted as clutter.
var hidden := {}
var _snap: Snapshot
var _ter: TerrainCatalog
var _cat: PropCatalog
var _solid: TerrainMesher.Buf
var _glass: TerrainMesher.Buf
var _roof_solid: TerrainMesher.Buf
var _roof_glass: TerrainMesher.Buf
var _layout := {}       # absolute square -> Vector2i(facing, piece); piece -1: links to every joined neighbour
var _run_facing := {}   # Vector4i(first square of a run, axis) -> facing
var _pieces := 0


func _init(snap: Snapshot, terrain: TerrainCatalog, props: PropCatalog) -> void:
	_snap = snap
	_ter = terrain
	_cat = props


func build(sm_pos: Vector3i) -> Result:
	_solid = TerrainMesher.Buf.new()
	_glass = TerrainMesher.Buf.new()
	_roof_solid = TerrainMesher.Buf.new()
	_roof_glass = TerrainMesher.Buf.new()
	var r := Result.new()
	var sm: Snapshot.Submap = _snap.submaps[sm_pos]
	var base := CddaCoords.sm_to_ms(sm_pos)
	var tile_xf := {}   # tile -> furniture transform, for items resting on it
	var rng := RandomNumberGenerator.new()
	for i in SEEX * SEEX:
		var f := sm.furn[i]
		var t := sm.trap[i]
		if f == 0 and t == 0:
			continue
		var p := base + Vector3i(i % SEEX, i / SEEX, 0)
		var b := _builder(sm, i)
		var md := _models(sm, i, r)
		if f != 0:
			var prop := _cat.furniture(f)
			rng.seed = _hash(p)
			var xf := _place(p, i, prop, rng)
			tile_xf[i] = xf
			_emit(b, md, prop, xf, _links(p, prop, _facing_of(xf)), r, rng)
			r.furniture += 1
		if t != 0:
			var prop := _cat.trap(t)
			rng.seed = _hash(p) ^ 0x5bd1e995
			var xf := _tile_xf(i, sm).translated_local(Vector3(0, 0.005, 0))
			_emit(b, md, prop, xf, 0, r, rng)
			r.traps += 1
	var handles := handles_by_tile(sm)
	var piles := sm.items
	for k in range(0, piles.size(), Snapshot.PILE_STRIDE):
		var pile := piles.slice(k, k + Snapshot.PILE_STRIDE)
		r.items += _pile(sm, base, pile, tile_xf, r, rng, handles.get(pile[0], []))
	r.props = _mesh(_solid, _glass)
	r.roof_props = _mesh(_roof_solid, _roof_glass)
	r.vertices = _solid.verts.size() + _glass.verts.size() + _roof_solid.verts.size() + _roof_glass.verts.size()
	return r


## Shapes on roof terrain go to the roof meshes.
func _builder(sm: Snapshot.Submap, i: int) -> PropShapes.Builder:
	if _ter.style_for(sm.ter[i]).kind == K.ROOF:
		return PropShapes.Builder.new(_roof_solid, _roof_glass)
	return PropShapes.Builder.new(_solid, _glass)


## Model transform list for a tile (roof terrain: the roof list).
func _models(sm: Snapshot.Submap, i: int, r: Result) -> Dictionary:
	return r.roof_models if _ter.style_for(sm.ter[i]).kind == K.ROOF else r.models


static func _add_model(md: Dictionary, m: ModelLibrary.Model, xf: Transform3D) -> void:
	if not md.has(m):
		md[m] = []
	(md[m] as Array).append(xf)


## Tile centre on its floor (roof terrain is drawn lifted), submap-local.
func _tile_xf(i: int, sm: Snapshot.Submap) -> Transform3D:
	var y := TerrainMesher.ROOF_LIFT if _ter.style_for(sm.ter[i]).kind == K.ROOF else 0.0
	return Transform3D(Basis.IDENTITY, Vector3(i % SEEX + 0.5, y, i / SEEX + 0.5))


func _place(p: Vector3i, i: int, prop: PropCatalog.Prop, rng: RandomNumberGenerator) -> Transform3D:
	var yaw := rng.randf() * TAU if prop.random_yaw else YAW[facing(p, prop, rng)]
	var o := _tile_xf(i, _snap.submaps[CddaCoords.ms_to_sm(p)]).origin + prop.offset
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * prop.scale), o)


## Which way (index into DIRS) the front of the prop at p faces; see the class notes. Deterministic: the
## same snapshot always gives the same facings (`_rng` is not used).
func facing(p: Vector3i, prop: PropCatalog.Prop, _rng: RandomNumberGenerator = null) -> int:
	return _lay(p, prop).x


## Facing and piece of the furniture at p, cached; a bed or table block is laid out whole on its first tile.
func _lay(p: Vector3i, prop: PropCatalog.Prop) -> Vector2i:
	if not _layout.has(p):
		if _kind(prop) == Lay.ROW:
			_layout[p] = Vector2i(_row_facing(p, prop), -1)
		else:
			_lay_block(p, prop)
	return _layout[p]


static func _kind(prop: PropCatalog.Prop) -> int:
	if prop.shape in LENGTH_SHAPES:
		return Lay.LENGTH
	return Lay.ROW if prop.shape in ROW_SHAPES else Lay.FREE


## A row tile faces across its run: the longer of its two straight runs of joined tiles (x on a tie).
func _row_facing(p: Vector3i, prop: PropCatalog.Prop) -> int:
	var rx := _run(p, Vector3i(1, 0, 0))
	var ry := _run(p, Vector3i(0, 1, 0))
	var along_x: bool = rx[1] >= ry[1]
	var run: Array = rx if along_x else ry
	if run[1] == 1:
		return _best([p], prop, [0, 1, 2, 3], p)
	var dirs := [0, 2] if along_x else [1, 3]
	if run[1] > MAX_RUN:
		return _best([p], prop, dirs, p)
	var first: Vector3i = run[0]
	var key := Vector4i(first.x, first.y, first.z, 0 if along_x else 1)
	if not _run_facing.has(key):
		var step := Vector3i(1, 0, 0) if along_x else Vector3i(0, 1, 0)
		var tiles := []
		for k in run[1]:
			tiles.append(first + step * k)
		_run_facing[key] = _best(tiles, prop, dirs, first)
	return _run_facing[key]


## The straight run of tiles laid out with p along `step`: [first square, length]. A run longer than
## MAX_RUN reports MAX_RUN + 1 from every tile in it (so its tiles agree that it is too long).
func _run(p: Vector3i, step: Vector3i) -> Array:
	var lo := 0
	while lo < MAX_RUN and _together(p - step * lo, p - step * (lo + 1)):
		lo += 1
	var hi := 0
	while hi < MAX_RUN and _together(p + step * hi, p + step * (hi + 1)):
		hi += 1
	var n := lo + hi + 1
	return [p - step * lo, MAX_RUN + 1 if lo == MAX_RUN or hi == MAX_RUN else n]


## Lays out the block of joined tiles around p (a bed, a big table) with one facing; beds and bathtubs
## along the block's long axis when it is one tile wide, split into beds (see the class notes). A block
## over MAX_BLOCK tiles: p faces on its own (and a bed tile there joins nothing).
func _lay_block(p: Vector3i, prop: PropCatalog.Prop) -> void:
	var length := _kind(prop) == Lay.LENGTH
	var tiles := _block(p)
	_pieces += 1
	if tiles.is_empty():
		_layout[p] = Vector2i(_best([p], prop, [0, 1, 2, 3], p), _pieces if length else -1)
		return
	var lo: Vector3i = tiles[0]
	var hi: Vector3i = tiles[0]
	for t: Vector3i in tiles:
		lo = Vector3i(mini(lo.x, t.x), mini(lo.y, t.y), lo.z)
		hi = Vector3i(maxi(hi.x, t.x), maxi(hi.y, t.y), hi.z)
	var dirs := [0, 1, 2, 3]
	if length and lo.x == hi.x and lo.y != hi.y:
		dirs = [0, 2]
	elif length and lo.y == hi.y and lo.x != hi.x:
		dirs = [1, 3]
	var face := _best(tiles, prop, dirs, tiles[0])
	var base := _pieces
	for t: Vector3i in tiles:
		_layout[t] = Vector2i(face, base + _bed_of(t, lo, hi, face) if length else -1)
	_pieces += (MAX_BLOCK + 1) * (MAX_BLOCK + 1)


## Which bed of a block (lo..hi) facing `face` a tile is in: beds BED_LEN long counted from the head end
## (the back), 2 wide when the block is exactly 2 wide, else 1 wide.
static func _bed_of(t: Vector3i, lo: Vector3i, hi: Vector3i, face: int) -> int:
	var along: int = [hi.y - t.y, t.x - lo.x, t.y - lo.y, hi.x - t.x][face]
	var across := t.x - lo.x if face % 2 == 0 else t.y - lo.y
	var width := hi.x - lo.x + 1 if face % 2 == 0 else hi.y - lo.y + 1
	return (along / BED_LEN) * (MAX_BLOCK + 1) + (0 if width <= 2 else across)


## The tiles laid out together with p (4-neighbours, across submaps), sorted; empty when there are more
## than MAX_BLOCK (the search stops there, so a hostile snapshot can't make it long).
func _block(p: Vector3i) -> Array:
	var seen := {p: true}
	var todo: Array[Vector3i] = [p]
	while not todo.is_empty():
		var t: Vector3i = todo.pop_back()
		for d in 4:
			var q := t + DIRS[d]
			if not seen.has(q) and _together(t, q):
				if seen.size() >= MAX_BLOCK:
					return []
				seen[q] = true
				todo.append(q)
	var out := seen.keys()
	out.sort()
	return out


## The direction in `dirs` with the highest score summed over `tiles`; a tie goes by a hash of `anchor`.
func _best(tiles: Array, prop: PropCatalog.Prop, dirs: Array, anchor: Vector3i) -> int:
	var best: Array[int] = []
	var best_score := -(1 << 30)
	for d: int in dirs:
		var s := 0
		for t: Vector3i in tiles:
			var f := _furn_at(t)
			s += _score(t, _cat.furniture(f) if f != 0 else prop, d)
		if s > best_score:
			best_score = s
			best.clear()
		if s == best_score:
			best.append(d)
	return best[_hash(anchor) % best.size()]


## How well the tile's front faces DIRS[d]: CDDA's hints (rotates_to, seats to a table), the front onto
## walkable floor, the back to a wall. Neighbours laid out with the tile count for nothing.
func _score(t: Vector3i, prop: PropCatalog.Prop, d: int) -> int:
	var s := 0
	var n := t + DIRS[d]
	if not _together(t, n):
		var nf := _furn_prop(n)
		if prop.rotates_to != 0 and (_groups_at(n) & prop.rotates_to) != 0:
			s += 8
		if (prop.align_workbench or prop.shape in SEATS) and nf != null and nf.flat_surf:
			s += 8
		var ts := _ter_style(n)
		if ts != null:
			if ts.kind in WALLISH:
				s -= 3
			elif nf != null and nf.blocks:
				s -= 2
			elif ts.kind in WALKABLE:
				s += 3 if nf == null else 1
	var bk := t - DIRS[d]
	if not _together(t, bk):
		var tb := _ter_style(bk)
		if tb != null:
			if tb.kind == K.WALL:
				s += 3
			elif tb.kind == K.WINDOW:
				s += 2
			elif tb.kind == K.DOOR:
				s += 1
			elif _furn_prop(bk) != null and _furn_prop(bk).blocks:
				s += 1
	return s


## True when the furniture at a joins the one at b: the same id, or one is in the other's connect groups.
func _joined(a: Vector3i, b: Vector3i) -> bool:
	var fa := _furn_at(a)
	var fb := _furn_at(b)
	if fa == 0 or fb == 0:
		return false
	if fa == fb:
		return true
	var pa := _cat.furniture(fa)
	var pb := _cat.furniture(fb)
	return (pa.connects_to & pb.groups) != 0 or (pb.connects_to & pa.groups) != 0


## Joined and laid out together: the same kind of layout, neither turned at random.
func _together(a: Vector3i, b: Vector3i) -> bool:
	if not _joined(a, b):
		return false
	var pa := _cat.furniture(_furn_at(a))
	var pb := _cat.furniture(_furn_at(b))
	return not pa.random_yaw and not pb.random_yaw and _kind(pa) == _kind(pb)


## Inverse of YAW for an unscaled-or-scaled transform: which DIRS index the front faces.
static func _facing_of(xf: Transform3D) -> int:
	var f := xf.basis * Vector3.FORWARD
	if absf(f.x) > absf(f.z):
		return 1 if f.x > 0 else 3
	return 2 if f.z > 0 else 0


## Neighbours this prop joins, as shape-local direction bits (1 front, 2 +x, 4 back, 8 -x): the same
## furniture (a sofa, a table), or furniture in each other's connect groups (counters, tent walls); a bed
## or bathtub only joins the tiles of its own bed (see the class notes).
func _links(p: Vector3i, prop: PropCatalog.Prop, facing: int) -> int:
	var piece := -1 if prop.random_yaw else _lay(p, prop).y
	var bits := 0
	for d in 4:
		var q := p + DIRS[d]
		if _joined(p, q) and (piece < 0 or (_layout.get(q, NO_LAYOUT) as Vector2i).y == piece):
			bits |= 1 << posmod(d - facing, 4)   # world direction -> shape-local (front = 0)
	return bits


func _emit(b: PropShapes.Builder, md: Dictionary, prop: PropCatalog.Prop, xf: Transform3D, links: int,
		r: Result, rng: RandomNumberGenerator) -> void:
	if prop.model != null:
		_add_model(md, prop.model, xf * MODEL_TURN)
		r.model_props += 1
		return
	if prop.shape.is_empty():
		if r.glyphs.size() < MAX_GLYPHS:
			r.glyphs.append([xf.origin + Vector3(0, 0.6, 0), prop.symbol, prop.accent])
		return
	b.xf = xf
	PropShapes.build(prop.shape, b, prop.main, prop.accent, prop.leaf, links, prop.height, rng)


## Items of one pile [tile, count, top0..3] (`handles`: its tile's, handles_by_tile); returns how many
## were shown. Items with a handle are listed in r.item_slots.
func _pile(sm: Snapshot.Submap, base: Vector3i, pile: PackedInt32Array, tile_xf: Dictionary, r: Result,
		rng: RandomNumberGenerator, handles: Array = []) -> int:
	var placed := pile_transforms(sm, base, pile, tile_xf, handles)
	var b := _builder(sm, pile[0])
	var md := _models(sm, pile[0], r)
	var behind_doors := _inside_closed(sm, pile[0])
	for k in placed.size():
		var e: Array = placed[k]
		var xf: Transform3D = e[0]
		var itype: int = e[1]
		var prop := _cat.item(itype)
		if prop.shape == "item_corpse" and pile[Snapshot.PILE_CORPSE] != 0:
			continue   # CreatureView lays the body there
		if not xf.is_finite() or not (e[4] as Vector3).is_finite():
			continue   # a degenerate surface (zero scale): nothing to draw or point at
		# Pointable only when drawn where it can be seen: not behind a closed model's doors, not a glyph
		# past MAX_GLYPHS.
		var glyph_only := prop.model == null and prop.shape.is_empty()
		var pointable: bool = e[2] != 0 and not behind_doors and not (glyph_only and r.glyphs.size() >= MAX_GLYPHS)
		if pointable:
			r.item_slots.append([e[2], itype, pile[0], xf, e[3], e[4]])
		if prop.model != null and itype != 0:
			_add_model(md, prop.model, xf)
			r.model_props += 1
			continue
		if prop.shape.is_empty():
			if r.glyphs.size() < MAX_GLYPHS:
				r.glyphs.append([xf.origin + Vector3(0, GLYPH_UP, 0), prop.symbol, prop.accent])
			continue
		b.xf = xf
		var main := prop.main if itype != 0 else CLUTTER[(pile[0] + k) % CLUTTER.size()]
		rng.seed = itype
		PropShapes.build(prop.shape if itype != 0 else "item_small", b, main, main, prop.leaf, 0, 1.0, rng)
	return placed.size()


## Where the items of a pile [tile, count, top0..3] go: one [transform (scaled to the item), itype, uid,
## size_m, centre, height] per shown item, on the surfaces of the tile's furniture (its model's surface_N
## planes when it has them); empty when they are inside a closed container. Deterministic per square.
## Without `handles` (the tile's [uid, itype, spot_x, spot_y] lists): the four largest itypes, then
## clutter (itype 0) for the smaller rest, MAX_SHOWN at most, uid 0. With them: one item per handle in
## their order, at its spot (permille of the square, turned onto the surface) or else at its sub-tile
## slot, the 17th and later on top of the ones before on the same slot; `hidden` ones are skipped (their
## slot stays empty, so the rest don't move); then clutter for the items without a handle.
func pile_transforms(sm: Snapshot.Submap, base: Vector3i, pile: PackedInt32Array, tile_xf: Dictionary,
		handles: Array = []) -> Array:
	var out := []
	var i := pile[0]
	var count := pile[1]
	var furn: PropCatalog.Prop = _cat.furniture(sm.furn[i]) if sm.furn[i] != 0 else null
	var info := PropShapes.info(furn.shape) if furn != null else PropShapes.FLOOR_INFO
	var planes: Array = furn.model.surfaces if furn != null and furn.model != null else []
	if count <= 0 or (planes.is_empty() and info.get("hide", false)):
		return out
	var surf := Surface.new()
	surf.heights = info.get("surfaces", [0.0])
	surf.rect = info.get("rect", PropShapes.FLOOR_INFO["rect"])
	surf.planes = planes
	var full: Transform3D = tile_xf.get(i, _tile_xf(i, sm))
	surf.on = Transform3D(full.basis.orthonormalized(), full.origin)   # items keep their own size
	surf.model_xf = full * MODEL_TURN
	var h := _hash(base + Vector3i(i % SEEX, i / SEEX, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = h
	var start := h % (SUB * SUB)
	var step := 2 * ((h >> 4) % 8) + 1   # odd: visits all 16 slots
	if handles.is_empty():
		for k in mini(count, MAX_SHOWN):
			var slot := (start + k * step) % (SUB * SUB)
			var u := (slot % SUB + 0.5) / SUB + rng.randf_range(-0.04, 0.04)
			var v := (slot / SUB + 0.5) / SUB + rng.randf_range(-0.04, 0.04)
			var pos := surf.at(k, u, v)
			var itype := pile[2 + k] if k < 4 else 0
			var size := _cat.item(itype).scale if itype != 0 else ITEM_CLUTTER_M
			out.append(_placed(Transform3D(surf.on.basis * Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size), pos), itype, 0, size))
		return out
	var jitter: Array[Vector2] = []   # per slot, so a stack stands straight
	for _s in SUB * SUB:
		jitter.append(Vector2(rng.randf_range(-0.04, 0.04), rng.randf_range(-0.04, 0.04)))
	var tops := {}   # Vector2i(slot, surface) -> height of what lies there
	var n := handles.size()
	for k in n + clampi(count - n, 0, MAX_SHOWN):
		var uid := 0
		var itype := 0
		var spot := Vector2(-1, -1)
		if k < n:
			var hd: Array = handles[k]
			uid = hd[0]
			if hidden.has(uid):
				continue
			itype = hd[1]
			if hd[2] >= 0 and hd[3] >= 0:
				spot = Vector2(hd[2] / 1000.0, hd[3] / 1000.0)
		rng.seed = hash([h, uid] if uid != 0 else [h, -1 - k])   # an item keeps its turn when others leave
		var slot := (start + k * step) % (SUB * SUB)
		var sk := k % surf.count()
		var uv := surf.spot_uv(sk, spot) if spot.x >= 0.0 else \
				Vector2((slot % SUB + 0.5) / SUB, (slot / SUB + 0.5) / SUB) + jitter[slot]
		var size := _cat.item(itype).scale if itype != 0 else ITEM_CLUTTER_M
		var xf := Transform3D(surf.on.basis * Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size), surf.at(sk, uv.x, uv.y))
		var key := Vector2i(slot, sk)
		var lift: float = tops.get(key, 0.0) if spot.x < 0.0 else 0.0
		xf.origin.y += lift
		var e := _placed(xf, itype, uid, size)
		if spot.x < 0.0:
			tops[key] = lift + float(e[5])
		out.append(e)
	return out


const ITEM_CLUTTER_M := 0.07


## Items on square `i` lie on a furniture model's inner surface_N planes behind doors that are drawn closed
## (its placeholder hides contents): drawn, but not pointable through the doors.
func _inside_closed(sm: Snapshot.Submap, i: int) -> bool:
	if sm.furn[i] == 0:
		return false
	var furn := _cat.furniture(sm.furn[i])
	return furn.model != null and not furn.model.surfaces.is_empty() and PropShapes.info(furn.shape).get("hide", false)


## [transform, itype, uid, size_m, centre, height] of an item drawn at `xf` (scaled by `size`).
func _placed(xf: Transform3D, itype: int, uid: int, size: float) -> Array:
	var ext := _extent(_cat.item(itype), itype, xf, size)
	return [xf, itype, uid, ext[0], ext[1], ext[2]]


## [size_m (longest side), centre, height] of an item drawn at `xf`: from its model's bounds, its shape's
## (ITEM_BOX), or around a glyph card.
static func _extent(prop: PropCatalog.Prop, itype: int, xf: Transform3D, size: float) -> Array:
	var box: AABB = ITEM_BOX.get(prop.shape if itype != 0 else "item_small", ITEM_BOX_OTHER)
	if itype != 0 and prop.model != null and prop.model.aabb.has_volume():
		box = prop.model.aabb
	elif itype != 0 and prop.model == null and prop.shape.is_empty():
		return [size, xf.origin + Vector3(0, GLYPH_UP, 0), size]
	return [box.get_longest_axis_size() * size, xf * box.get_center(), maxf(box.end.y, 0.0) * size]


## The tiles' handles of a submap: tile -> [[uid, itype, spot_x, spot_y], ...] in the snapshot's order.
static func handles_by_tile(sm: Snapshot.Submap) -> Dictionary:
	var out := {}
	var hs := sm.handles
	for k in range(0, hs.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
		var t := int(hs[k])
		if not out.has(t):
			out[t] = []
		(out[t] as Array).append([hs[k + 1], int(hs[k + 2]), int(hs[k + 3]), int(hs[k + 4])])
	return out


## Where the items of one tile can lie: the placeholder's surface heights and rect, or a furniture model's
## surface_N planes.
class Surface:
	var on: Transform3D          # the furniture (or the tile), unscaled
	var model_xf: Transform3D    # the furniture's model
	var heights: Array = [0.0]
	var rect: Array = []
	var planes: Array = []

	func count() -> int:
		return maxi(planes.size() if not planes.is_empty() else heights.size(), 1)

	## The point u, v (0..1 across) of surface k.
	func at(k: int, u: float, v: float) -> Vector3:
		if planes.is_empty():
			return on * Vector3(lerpf(rect[0], rect[2], u), heights[k % heights.size()], lerpf(rect[1], rect[3], v))
		var s: Array = planes[k % planes.size()]
		var r2: Rect2 = s[1]
		var local := Vector3(lerpf(r2.position.x, r2.end.x, u), s[2], lerpf(r2.position.y, r2.end.y, v))
		return model_xf * ((s[0] as Transform3D) * local)

	## A spot (fractions of the square, x east, y south) as u, v on surface k, turned with the surface: the
	## item lies toward the same side of the square whichever way the furniture faces.
	func spot_uv(k: int, spot: Vector2) -> Vector2:
		var b := on.basis
		if not planes.is_empty():
			b = (model_xf.basis * ((planes[k % planes.size()] as Array)[0] as Transform3D).basis).orthonormalized()
		var d := b.inverse() * Vector3(spot.x - 0.5, 0.0, spot.y - 0.5)
		return Vector2(clampf(d.x + 0.5, 0.0, 1.0), clampf(d.z + 0.5, 0.0, 1.0))


func _ter_style(p: Vector3i) -> TerrainCatalog.Style:
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	return _ter.style_for(sm.ter[l.y * SEEX + l.x])


## Furniture id at an absolute square (0: none, or the submap isn't loaded).
func _furn_at(p: Vector3i) -> int:
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return 0
	var l := CddaCoords.ms_to_local(p)
	return sm.furn[l.y * SEEX + l.x]


func _furn_prop(p: Vector3i) -> PropCatalog.Prop:
	var f := _furn_at(p)
	return _cat.furniture(f) if f != 0 else null


## Connect groups of a square: its terrain's and its furniture's.
func _groups_at(p: Vector3i) -> int:
	var t := _ter_style(p)
	var f := _furn_prop(p)
	return (t.groups if t != null else 0) | (f.groups if f != null else 0)


## Stable non-negative hash of an absolute square.
static func _hash(p: Vector3i) -> int:
	return TerrainMesher.square_hash(p)


static func _mesh(solid: TerrainMesher.Buf, glass: TerrainMesher.Buf) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	solid.commit(mesh, TerrainMesher.material("solid"))
	glass.commit(mesh, TerrainMesher.material("glass"))
	return mesh if mesh.get_surface_count() > 0 else null
