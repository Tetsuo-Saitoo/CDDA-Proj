class_name TerrainMesher
extends RefCounted
## Block C2: builds the terrain meshes of one submap at one z-level from a validated Snapshot.
##
## Geometry is in submap-local metres: tile (lx, ly) spans x lx..lx+1, z ly..ly+1, y 0..3; the caller
## places the result at the submap's corner. Walls fill their whole tile (CDDA walls are a tile thick,
## and collision will be too), so neighbour connections show up as culled shared faces and as the
## direction doors, windows and fences run. Outputs three meshes:
## - terrain: floors, walls, doors, windows (glass in its own transparent surface), stairs, props;
## - roof: roof terrain and, where the level above isn't loaded, a lid over roofed (indoor) tiles;
## - caps: wall tops hidden under the floor above, shown only when the level above is cut away.

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

static var _materials := {}


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


var _snap: Snapshot
var _cat: TerrainCatalog
var _solid: Buf
var _glass: Buf
var _roof: Buf
var _caps: Buf


func _init(snap: Snapshot, catalog: TerrainCatalog) -> void:
	_snap = snap
	_cat = catalog


func build(sm_pos: Vector3i) -> Result:
	_solid = Buf.new()
	_glass = Buf.new()
	_roof = Buf.new()
	_caps = Buf.new()
	var sm: Snapshot.Submap = _snap.submaps[sm_pos]
	var above_loaded := _snap.submaps.has(sm_pos + Vector3i(0, 0, 1))
	var base := CddaCoords.sm_to_ms(sm_pos)
	for ly in SEEX:
		for lx in SEEX:
			var i := ly * SEEX + lx
			var st := _cat.style_for(sm.ter[i])
			var o := Vector3(lx, 0, ly)
			var flags := sm.flags[i]
			_tile(base + Vector3i(lx, ly, 0), o, st, (flags & Snapshot.FLAG_NO_FLOOR) == 0)
			if (flags & Snapshot.FLAG_ROOF) and not above_loaded and st.kind != K.ROOF:
				_roof.slab(o, H, Color(0.32, 0.3, 0.3))
	var r := Result.new()
	r.vertices = _solid.verts.size() + _glass.verts.size() + _roof.verts.size() + _caps.verts.size()
	r.terrain = _mesh([_solid, _glass], ["solid", "glass"])
	r.roof = _mesh([_roof], ["solid"])
	r.caps = _mesh([_caps], ["solid"])
	return r


func _tile(p: Vector3i, o: Vector3, st: TerrainCatalog.Style, floor_ok: bool) -> void:
	match st.kind:
		K.NONE, K.STAIRS_DOWN, K.LADDER_DOWN:
			pass   # open air, or the hole the stairs/ladder from below come up through
		K.FLOOR:
			if floor_ok:
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
			_steps(p, o, 12, st.color)
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


func _ground(o: Vector3, floor_ok: bool) -> void:
	if floor_ok:
		_solid.slab(o, 0.0, TerrainCatalog.GROUND)


func _wall(p: Vector3i, o: Vector3, st: TerrainCatalog.Style) -> void:
	var faces := 0
	for d in 4:
		var n := _style_at(p + DIRS[d])
		if n == null or n.kind != K.WALL or n.height < st.height:
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
	var leaf := _glass if st.glass else _solid
	var col := Color(0.6, 0.8, 0.9, 0.35) if st.glass else st.color
	if st.state == 0:
		if along_x:
			leaf.box(o + Vector3(0, 0, 0.45), o + Vector3(1, DOOR_H, 0.55), col)
		else:
			leaf.box(o + Vector3(0.45, 0, 0), o + Vector3(0.55, DOOR_H, 1), col)
	elif st.state == 1:   # swung back against the side of the opening
		if along_x:
			leaf.box(o + Vector3(0, 0, 0), o + Vector3(0.08, DOOR_H, 1), col)
		else:
			leaf.box(o + Vector3(0, 0, 0), o + Vector3(1, DOOR_H, 0.08), col)


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
	if st.height < 0.5:   # gutters line roof edges: stand on roof, not ground
		if floor_ok:
			_roof.slab(o, ROOF_LIFT, Color(0.32, 0.3, 0.3))
	else:
		_ground(o, floor_ok)
	var t := 0.04
	var c := o + Vector3(0.5, 0, 0.5)
	_solid.box(c - Vector3(0.06, 0, 0.06), c + Vector3(0.06, st.height + 0.05, 0.06), st.color, ALL & ~NY)
	for d in 4:
		var n := _style_at(p + DIRS[d])
		if n == null or not n.kind in [K.FENCE, K.WALL, K.DOOR, K.WINDOW]:
			continue
		var dv := Vector3(DIRS[d].x, 0, DIRS[d].y) * 0.5
		var lo := c + Vector3(minf(dv.x, 0) - (t if dv.x == 0 else 0.0), 0, minf(dv.z, 0) - (t if dv.z == 0 else 0.0))
		var hi := c + Vector3(maxf(dv.x, 0) + (t if dv.x == 0 else 0.0), st.height, maxf(dv.z, 0) + (t if dv.z == 0 else 0.0))
		_solid.box(lo, hi, st.color, ALL & ~NY)


## Stairs and ramps: steps rising away from a walkable neighbour, preferably toward a wall.
func _steps(p: Vector3i, o: Vector3, count: int, col: Color) -> void:
	var rise := -1
	for d in 4:
		var entry := _style_at(p - DIRS[d])
		var far := _style_at(p + DIRS[d])
		if entry != null and _walkable(entry):
			if rise < 0:
				rise = d
			if far != null and far.kind == K.WALL:
				rise = d
				break
	if rise < 0:
		rise = 0
	for k in count:
		var u0 := float(k) / count
		var u1 := float(k + 1) / count
		var h := H * u1
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
		_solid.box(o + lo, o + hi, col.darkened(0.04 * (k % 2)), ALL & ~NY)


func _ladder(o: Vector3, col: Color, floor_ok: bool) -> void:
	_ground(o, floor_ok)
	for x in [0.3, 0.66]:
		_solid.box(o + Vector3(x, 0, 0.47), o + Vector3(x + 0.04, H, 0.53), col)
	var y := 0.3
	while y < H:
		_solid.box(o + Vector3(0.3, y, 0.48), o + Vector3(0.7, y + 0.04, 0.52), col)
		y += 0.35


func _style_at(p: Vector3i) -> TerrainCatalog.Style:
	var sm: Snapshot.Submap = _snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return null
	var l := CddaCoords.ms_to_local(p)
	return _cat.style_for(sm.ter[l.y * SEEX + l.x])


## Wall-like neighbour in direction d (index into DIRS): doors and windows run along those.
func _connects(p: Vector3i, d: int) -> bool:
	var n := _style_at(p + DIRS[d])
	return n != null and n.kind in [K.WALL, K.DOOR, K.WINDOW]


func _walkable(s: TerrainCatalog.Style) -> bool:
	return s.kind in [K.FLOOR, K.ROOF, K.DOOR, K.SHRUB, K.TREE, K.LADDER_UP]


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


static func material(name: String) -> StandardMaterial3D:
	var m: StandardMaterial3D = _materials.get(name)
	if m == null:
		m = StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = 0.9
		if name == "glass":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.roughness = 0.1
			m.metallic_specular = 0.8
		_materials[name] = m
	return m
