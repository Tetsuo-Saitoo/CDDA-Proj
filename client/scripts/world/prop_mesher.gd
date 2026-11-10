class_name PropMesher
extends RefCounted
## Block C3: builds the props of one submap from a validated Snapshot: furniture, known traps and item
## piles, as placeholder shapes (PropShapes) chosen by PropCatalog, in submap-local metres like
## TerrainMesher. Props on roof terrain go to separate meshes, hidden with the roofs.
##
## Facing (90° steps): toward a neighbour in one of the prop's `rotates_to` groups (racks face the
## room, street lights the road), seats with ALIGN_WORKBENCH toward a table or counter, anything else
## with its back to a wall; `random_yaw` props turn freely. Item piles show up to MAX_SHOWN items
## (the four largest from the snapshot, small clutter for the rest) at sub-tile slots (4 x 4 per tile)
## picked by a hash of the square, so a pile looks the same every rebuild. Items rest on the surfaces
## of the furniture they share a tile with (tables, shelves) and are hidden in closed containers.

const K := TerrainCatalog.Kind
const SEEX := CddaCoords.SEEX
const DIRS := TerrainMesher.DIRS
const MAX_SHOWN := 8
const MAX_GLYPHS := 144
const SUB := 4   # sub-tiles per tile side
## Facing (index into DIRS) -> yaw that turns a shape's front (-z) that way.
const YAW: Array[float] = [0.0, -PI / 2, PI, PI / 2]
const WALLISH := [K.WALL, K.WINDOW, K.DOOR]
const CLUTTER: Array[Color] = [Color(0.7, 0.68, 0.62), Color(0.45, 0.5, 0.55), Color(0.62, 0.45, 0.3),
		Color(0.8, 0.8, 0.78), Color(0.5, 0.36, 0.32)]


class Result:
	var props: ArrayMesh        # null when empty
	var roof_props: ArrayMesh
	var glyphs: Array = []      # [position (submap-local), symbol, colour]
	var vertices := 0
	var furniture := 0
	var items := 0
	var traps := 0


var _snap: Snapshot
var _ter: TerrainCatalog
var _cat: PropCatalog
var _solid: TerrainMesher.Buf
var _glass: TerrainMesher.Buf
var _roof_solid: TerrainMesher.Buf
var _roof_glass: TerrainMesher.Buf


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
		if f != 0:
			var prop := _cat.furniture(f)
			rng.seed = _hash(p)
			var xf := _place(p, i, prop, rng)
			tile_xf[i] = xf
			_emit(b, prop, xf, _links(p, f, prop, _facing_of(xf)), r, rng)
			r.furniture += 1
		if t != 0:
			var prop := _cat.trap(t)
			rng.seed = _hash(p) ^ 0x5bd1e995
			var xf := _tile_xf(i, sm).translated_local(Vector3(0, 0.005, 0))
			_emit(b, prop, xf, 0, r, rng)
			r.traps += 1
	var piles := sm.items
	for k in range(0, piles.size(), Snapshot.PILE_STRIDE):
		r.items += _pile(sm, base, piles.slice(k, k + Snapshot.PILE_STRIDE), tile_xf, r, rng)
	r.props = _mesh(_solid, _glass)
	r.roof_props = _mesh(_roof_solid, _roof_glass)
	r.vertices = _solid.verts.size() + _glass.verts.size() + _roof_solid.verts.size() + _roof_glass.verts.size()
	return r


## Shapes on roof terrain go to the roof meshes.
func _builder(sm: Snapshot.Submap, i: int) -> PropShapes.Builder:
	if _ter.style_for(sm.ter[i]).kind == K.ROOF:
		return PropShapes.Builder.new(_roof_solid, _roof_glass)
	return PropShapes.Builder.new(_solid, _glass)


## Tile centre on its floor (roof terrain is drawn lifted), submap-local.
func _tile_xf(i: int, sm: Snapshot.Submap) -> Transform3D:
	var y := TerrainMesher.ROOF_LIFT if _ter.style_for(sm.ter[i]).kind == K.ROOF else 0.0
	return Transform3D(Basis.IDENTITY, Vector3(i % SEEX + 0.5, y, i / SEEX + 0.5))


func _place(p: Vector3i, i: int, prop: PropCatalog.Prop, rng: RandomNumberGenerator) -> Transform3D:
	var yaw := rng.randf() * TAU if prop.random_yaw else YAW[facing(p, prop, rng)]
	var o := _tile_xf(i, _snap.submaps[CddaCoords.ms_to_sm(p)]).origin + prop.offset
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * prop.scale), o)


## Which way (index into DIRS) the prop's front faces; see the class notes.
func facing(p: Vector3i, prop: PropCatalog.Prop, rng: RandomNumberGenerator) -> int:
	var best := -1
	var best_score := 0
	for d in 4:
		var score := 0
		var n := p + DIRS[d]
		var behind := _ter_style(p - DIRS[d])
		if prop.rotates_to != 0 and (_groups_at(n) & prop.rotates_to) != 0:
			score += 4
			if _furn_prop(n) == null:
				score += 1
		if prop.align_workbench:
			var other := _furn_prop(n)
			if other != null and other.flat_surf:
				score += 4
		if behind != null and behind.kind in WALLISH:
			score += 2
		if score > best_score:
			best_score = score
			best = d
	return best if best >= 0 else rng.randi() % 4


## Inverse of YAW for an unscaled-or-scaled transform: which DIRS index the front faces.
static func _facing_of(xf: Transform3D) -> int:
	var f := xf.basis * Vector3.FORWARD
	if absf(f.x) > absf(f.z):
		return 1 if f.x > 0 else 3
	return 2 if f.z > 0 else 0


## Neighbours this prop joins, as shape-local direction bits: the same furniture (a two-tile bed or
## sofa), or furniture in a group it connects to (CDDA's rule: counters, tent walls).
func _links(p: Vector3i, f: int, prop: PropCatalog.Prop, facing: int) -> int:
	var bits := 0
	for d in 4:
		var q := p + DIRS[d]
		var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(q))
		if sm == null:
			continue
		var l := CddaCoords.ms_to_local(q)
		var nf := sm.furn[l.y * SEEX + l.x]
		if nf == 0:
			continue
		if nf == f or (_cat.furniture(nf).groups & prop.connects_to) != 0:
			bits |= 1 << posmod(d - facing, 4)   # world direction -> shape-local (front = 0)
	return bits


func _emit(b: PropShapes.Builder, prop: PropCatalog.Prop, xf: Transform3D, links: int, r: Result,
		rng: RandomNumberGenerator) -> void:
	if prop.shape.is_empty():
		if r.glyphs.size() < MAX_GLYPHS:
			r.glyphs.append([xf.origin + Vector3(0, 0.6, 0), prop.symbol, prop.accent])
		return
	b.xf = xf
	PropShapes.build(prop.shape, b, prop.main, prop.accent, prop.leaf, links, prop.height, rng)


## Items of one pile [tile, count, top0..3]; returns how many were shown.
func _pile(sm: Snapshot.Submap, base: Vector3i, pile: PackedInt32Array, tile_xf: Dictionary, r: Result,
		rng: RandomNumberGenerator) -> int:
	var placed := pile_transforms(sm, base, pile, tile_xf)
	var b := _builder(sm, pile[0])
	for k in placed.size():
		var xf: Transform3D = placed[k][0]
		var itype: int = placed[k][1]
		var prop := _cat.item(itype)
		if prop.shape == "item_corpse" and pile[Snapshot.PILE_CORPSE] != 0:
			continue   # CreatureView lays the body there
		if prop.shape.is_empty():
			if r.glyphs.size() < MAX_GLYPHS:
				r.glyphs.append([xf.origin + Vector3(0, 0.3, 0), prop.symbol, prop.accent])
			continue
		b.xf = xf
		var main := prop.main if itype != 0 else CLUTTER[(pile[0] + k) % CLUTTER.size()]
		rng.seed = itype
		PropShapes.build(prop.shape if itype != 0 else "item_small", b, main, main, prop.leaf, 0, 1.0, rng)
	return placed.size()


## Where the items of a pile [tile, count, top0..3] go: one [transform (scaled to the item), itype]
## per shown item (itype 0: clutter for the smaller rest of the pile), on the surfaces of the tile's
## furniture; empty when they are inside a closed container. Deterministic per square.
func pile_transforms(sm: Snapshot.Submap, base: Vector3i, pile: PackedInt32Array, tile_xf: Dictionary) -> Array:
	var out := []
	var i := pile[0]
	var count := pile[1]
	var furn: PropCatalog.Prop = _cat.furniture(sm.furn[i]) if sm.furn[i] != 0 else null
	var info := PropShapes.info(furn.shape) if furn != null else PropShapes.FLOOR_INFO
	if count <= 0 or info.get("hide", false):
		return out
	var surfaces: Array = info.get("surfaces", [0.0])
	var rect: Array = info.get("rect", PropShapes.FLOOR_INFO["rect"])
	var on: Transform3D = tile_xf.get(i, _tile_xf(i, sm))
	on = Transform3D(on.basis.orthonormalized(), on.origin)   # items keep their own size
	var h := _hash(base + Vector3i(i % SEEX, i / SEEX, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = h
	var start := h % (SUB * SUB)
	var step := 2 * ((h >> 4) % 8) + 1   # odd: visits all 16 slots
	for k in mini(count, MAX_SHOWN):
		var slot := (start + k * step) % (SUB * SUB)
		var u := (slot % SUB + 0.5) / SUB + rng.randf_range(-0.04, 0.04)
		var v := (slot / SUB + 0.5) / SUB + rng.randf_range(-0.04, 0.04)
		var local := Vector3(lerpf(rect[0], rect[2], u), surfaces[k % surfaces.size()], lerpf(rect[1], rect[3], v))
		var itype := pile[2 + k] if k < 4 else 0
		var size := _cat.item(itype).scale if itype != 0 else ITEM_CLUTTER_M
		out.append([on * Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * size), local), itype])
	return out


const ITEM_CLUTTER_M := 0.07


func _ter_style(p: Vector3i) -> TerrainCatalog.Style:
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	return _ter.style_for(sm.ter[l.y * SEEX + l.x])


func _furn_prop(p: Vector3i) -> PropCatalog.Prop:
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	var f := sm.furn[l.y * SEEX + l.x]
	return _cat.furniture(f) if f != 0 else null


## Connect groups of a square: its terrain's and its furniture's.
func _groups_at(p: Vector3i) -> int:
	var t := _ter_style(p)
	var f := _furn_prop(p)
	return (t.groups if t != null else 0) | (f.groups if f != null else 0)


## Stable non-negative hash of an absolute square.
static func _hash(p: Vector3i) -> int:
	var h := (p.x * 73856093) ^ (p.y * 19349663) ^ (p.z * 83492791)
	h = (h ^ (h >> 13)) * 0x5bd1e995
	return (h ^ (h >> 15)) & 0x7fffffff


static func _mesh(solid: TerrainMesher.Buf, glass: TerrainMesher.Buf) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	solid.commit(mesh, TerrainMesher.material("solid"))
	glass.commit(mesh, TerrainMesher.material("glass"))
	return mesh if mesh.get_surface_count() > 0 else null
