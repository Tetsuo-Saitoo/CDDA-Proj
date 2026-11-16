class_name PropBoxes
extends RefCounted
## Block L8: placeholder containers that open (cupboards, lockers, fridges, dressers, filing cabinets,
## freezers, crates, boxes, bins, dumpsters). Each is built once per shape and colour as a small
## ModelLibrary.Model, the same as a .glb with door_N / drawer_N / lid markers, handle_N points and
## surface_N planes would load, so ModelLibrary.make_movers turns it into a `still` body and movers and
## PropMesher draws it like a furniture model that opens: doors, drawers and lids become Grabbable parts,
## items lie on its shelves and drawer floors, hidden behind its doors and lids while they are closed.
## Built in shape space (front -z, as PropShapes) and turned into model space (front +z).
## A cupboard is counter-sized with a full-width top, so it lines up with the counters of its run.
## Shapes not listed (vending machines, tanks, appliances, ovens, stoves) stay closed placeholders.

const OPENS := ["cupboard", "cabinet_tall", "locker", "fridge", "dresser", "filing_cabinet", "chest_freezer", "crate",
		"cardboard_box", "trash_can", "recycle_bin", "dumpster"]
const MAX_MODELS := 128   # shape and colour pairs cached; past that, furniture stays a closed placeholder
const T := 0.02           # panel thickness
const ALL := PropShapes.ALL
const DARK := PropShapes.DARK
const METAL := PropShapes.METAL

static var _cache := {}
static var _lock := Mutex.new()


## The opening model for a placeholder prop, null when its shape doesn't open (or the cache is full).
## Worker-safe; the model is shared and read-only.
static func model_of(prop: PropCatalog.Prop) -> ModelLibrary.Model:
	if prop == null or prop.model != null or not prop.shape in OPENS:
		return null
	var key := "%s|%s|%s" % [prop.shape, prop.main.to_html(), prop.accent.to_html()]
	_lock.lock()
	var m: ModelLibrary.Model = _cache.get(key)
	if m == null and _cache.size() < MAX_MODELS:
		m = make(prop.shape, prop.main, prop.accent)
		_cache[key] = m
	_lock.unlock()
	return m


## Builds the model for `shape` (one of OPENS), null for another.
static func make(shape: String, main: Color, accent: Color) -> ModelLibrary.Model:
	var k := Kit.new()
	match shape:
		"cupboard":
			var lo := Vector3(-0.5, 0.08, -0.42)
			var hi := Vector3(0.5, 0.88, 0.5)
			k.body.box(Vector3(-0.5, 0, -0.34), Vector3(0.5, 0.08, 0.5), DARK.lightened(0.1), ALL)
			k.carcass(lo, hi, main)
			k.shelves(lo, hi, [lo.y + 0.05, 0.5], main.darkened(0.15))
			k.door(Vector3(-0.49, 0.12, lo.z), Vector3(-0.003, 0.84, lo.z), -0.49, -0.07, main)
			k.door(Vector3(0.003, 0.12, lo.z), Vector3(0.49, 0.84, lo.z), 0.49, 0.07, main)
			k.body.box(Vector3(-0.5, 0.88, -0.47), Vector3(0.5, 0.93, 0.5), PropShapes.STONE_TOP, ALL)
		"cabinet_tall":
			var lo := Vector3(-0.46, 0, -0.3)
			var hi := Vector3(0.46, 2.0, 0.46)
			k.carcass(lo, hi, main)
			k.shelves(lo, hi, [0.05, 0.7, 1.35], main.darkened(0.15))
			k.door(Vector3(lo.x, 0.05, lo.z), Vector3(-0.003, hi.y - 0.04, lo.z), lo.x, -0.06, main)
			k.door(Vector3(0.003, 0.05, lo.z), Vector3(hi.x, hi.y - 0.04, lo.z), hi.x, 0.06, main)
		"locker":
			var lo := Vector3(-0.38, 0, -0.25)
			var hi := Vector3(0.38, 1.9, 0.45)
			k.carcass(lo, hi, main)
			k.shelves(lo, hi, [0.05, 1.5], main.darkened(0.15))
			var d := k.door(Vector3(lo.x, 0.05, lo.z), Vector3(hi.x, hi.y - 0.04, lo.z), lo.x, hi.x - 0.1, main)
			for y: float in [1.6, 1.66, 1.72]:
				d.box(Vector3(-0.2, y, lo.z - T - 0.01), Vector3(0.2, y + 0.02, lo.z - T), DARK)
		"fridge":
			var lo := Vector3(-0.42, 0, -0.3)
			var hi := Vector3(0.42, 1.85, 0.45)
			k.carcass(lo, hi, main)
			k.shelves(lo, hi, [0.05, 0.5, 0.9, 1.29], PropShapes.CERAMIC)
			k.door(Vector3(lo.x, 0.05, lo.z), Vector3(hi.x, 1.25, lo.z), lo.x, 0.32, main)
			k.door(Vector3(lo.x, 1.27, lo.z), Vector3(hi.x, hi.y - 0.04, lo.z), lo.x, 0.32, main)
		"dresser":
			k.chest_of_drawers(Vector3(-0.46, 0, -0.28), Vector3(0.46, 1.0, 0.46), 3, main)
		"filing_cabinet":
			k.chest_of_drawers(Vector3(-0.25, 0, -0.32), Vector3(0.25, 1.3, 0.4), 4, main)
		"chest_freezer":
			k.tub(Vector3(-0.45, 0, -0.35), Vector3(0.45, 0.84, 0.42), 0.08, main)
			k.lid(Vector3(-0.45, 0.84, -0.35), Vector3(0.45, 0.88, 0.42), main.darkened(0.06))
		"crate":
			k.tub(Vector3(-0.4, 0, -0.4), Vector3(0.4, 0.71, 0.4), 0.05, main)
			k.lid(Vector3(-0.4, 0.71, -0.4), Vector3(0.4, 0.75, 0.4), main.darkened(0.1))
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					var c := Vector3(sx * 0.37, 0, sz * 0.37)
					k.body.box(c - Vector3(0.035, 0, 0.035), c + Vector3(0.035, 0.71, 0.035), main.darkened(0.25))
		"cardboard_box":
			k.tub(Vector3(-0.45, 0, -0.45), Vector3(0.45, 0.88, 0.45), 0.02, main)
			var l := k.lid(Vector3(-0.45, 0.88, -0.45), Vector3(0.45, 0.9, 0.45), main)
			l.box(Vector3(-0.06, 0.9, -0.46), Vector3(0.06, 0.905, 0.46), main.lightened(0.25), ALL)
		"trash_can":
			k.body.cyl(Vector3.ZERO, 0.24, 0.72, accent, 8, false)
			k.body.cyl(Vector3.ZERO, 0.22, 0.03, accent.darkened(0.3))
			k.surface(Vector3(0, 0.03, 0), Vector2(0.28, 0.28), "")
			var l := k.lid_at(Vector3(0, 0.72, 0.27))
			l.cyl(Vector3(0, 0.72, 0), 0.27, 0.05, accent.darkened(0.15))
			l.box(Vector3(-0.06, 0.77, -0.02), Vector3(0.06, 0.81, 0.02), PropShapes.METAL_DARK, ALL)
			k.handle(Vector3(0, 0.79, 0))
		"recycle_bin":
			k.tub(Vector3(-0.3, 0, -0.32), Vector3(0.3, 0.9, 0.3), 0.05, accent)
			k.lid(Vector3(-0.32, 0.9, -0.34), Vector3(0.32, 0.95, 0.32), accent.darkened(0.15))
		"dumpster":
			for x: float in [-0.42, 0.34]:
				for z: float in [-0.36, 0.32]:
					k.body.box(Vector3(x, 0, z), Vector3(x + 0.08, 0.15, z + 0.08), DARK)
			k.tub(Vector3(-0.5, 0.15, -0.42), Vector3(0.5, 1.2, 0.45), 0.2, accent)
			k.body.box(Vector3(-0.52, 1.0, -0.44), Vector3(0.52, 1.06, 0.47), accent.darkened(0.15))
			k.lid(Vector3(-0.5, 1.2, -0.42), Vector3(0.5, 1.26, 0.45), DARK.lightened(0.1))
		_:
			return null
	return k.finish(shape)


## Collects a model's pieces in shape space; finish() turns them into a ModelLibrary.Model.
class Kit:
	var body: PropShapes.Builder
	var _body_bufs: Array = []
	var _movers: Array = []     # [name, pivot (shape space), [solid Buf, glass Buf], Builder]
	var _handles: Array = []    # [mover name, point (shape space)]
	var _surfaces: Array = []   # [centre (shape space), size (x, z), mover name or ""]
	var _drawers := 0
	var _doors := 0

	func _init() -> void:
		_body_bufs = [TerrainMesher.Buf.new(), TerrainMesher.Buf.new()]
		body = _builder(_body_bufs)

	static func _builder(bufs: Array) -> PropShapes.Builder:
		var b := PropShapes.Builder.new(bufs[0], bufs[1])
		b.xf = PropMesher.MODEL_TURN   # shape space (front -z) -> model space (front +z)
		return b

	func _mover(name: String, pivot: Vector3) -> PropShapes.Builder:
		var bufs := [TerrainMesher.Buf.new(), TerrainMesher.Buf.new()]
		var b := _builder(bufs)
		_movers.append([name, pivot, bufs, b])
		return b

	## A handle point on the last mover.
	func handle(at: Vector3) -> void:
		_handles.append([_movers[-1][0], at])

	## An item surface (its middle at `c`, `size` across x and z) that moves with `owner` ("" stays put).
	func surface(c: Vector3, size: Vector2, owner: String) -> void:
		_surfaces.append([c, size, owner])

	## A cabinet body open at the front (-z): back, sides, plinth and top, with a top trim.
	func carcass(lo: Vector3, hi: Vector3, col: Color) -> void:
		body.box(Vector3(lo.x, lo.y, hi.z - T), hi, col, ALL)
		body.box(lo, Vector3(lo.x + T, hi.y, hi.z), col, ALL)
		body.box(Vector3(hi.x - T, lo.y, lo.z), hi, col, ALL)
		body.box(lo, Vector3(hi.x, lo.y + 0.05, hi.z), col.darkened(0.1), ALL)
		body.box(Vector3(lo.x, hi.y - 0.04, lo.z), hi, col, ALL)
		body.box(Vector3(lo.x - 0.015, hi.y - 0.04, lo.z - T - 0.015), Vector3(hi.x + 0.015, hi.y, hi.z), col.darkened(0.12), ALL)

	## Shelf boards inside a carcass (the lowest at the plinth: the floor), each an item surface.
	func shelves(lo: Vector3, hi: Vector3, ys: Array, col: Color) -> void:
		var x0 := lo.x + T
		var x1 := hi.x - T
		var z0 := lo.z + 0.01
		var z1 := hi.z - T
		for y: float in ys:
			if y > lo.y + 0.06:
				body.box(Vector3(x0, y - 0.02, z0), Vector3(x1, y, z1), col, ALL)
			surface(Vector3((x0 + x1) * 0.5, y, (z0 + z1) * 0.5), Vector2(x1 - x0 - 0.04, z1 - z0 - 0.04), "")

	## A door leaf from lo to hi (its back at lo.z, the front of the carcass), hinged on the vertical at x =
	## `hinge_x`, its handle at x = `handle_x`. Returns the door's builder for trim.
	func door(lo: Vector3, hi: Vector3, hinge_x: float, handle_x: float, col: Color) -> PropShapes.Builder:
		_doors += 1
		var d := _mover("door_%d" % _doors, Vector3(hinge_x, lo.y, lo.z))
		d.box(Vector3(lo.x, lo.y, lo.z - T), Vector3(hi.x, hi.y, lo.z), col, ALL)
		var y := (lo.y + hi.y) * 0.5
		d.box(Vector3(handle_x - 0.01, y - 0.09, lo.z - T - 0.03), Vector3(handle_x + 0.01, y + 0.09, lo.z - T), METAL, ALL)
		handle(Vector3(handle_x, y, lo.z - T - 0.03))
		return d

	## A carcass full of `n` drawers, each an open box sliding out of the front with a floor items lie on.
	func chest_of_drawers(lo: Vector3, hi: Vector3, n: int, col: Color) -> void:
		carcass(lo, hi, col)
		var step := (hi.y - lo.y - 0.1) / n
		for i in n:
			var y0 := lo.y + 0.05 + i * step
			var y1 := y0 + step - 0.01
			_drawers += 1
			var name := "drawer_%d" % _drawers
			var x0 := lo.x + T + 0.005
			var x1 := hi.x - T - 0.005
			var z0 := lo.z
			var z1 := hi.z - T - 0.02
			var d := _mover(name, Vector3(0, y0, z0))
			d.box(Vector3(lo.x + 0.01, y0, z0 - T), Vector3(hi.x - 0.01, y1, z0), col, ALL)   # front
			d.box(Vector3(x0, y0, z0), Vector3(x1, y0 + 0.015, z1), col.darkened(0.2), ALL)   # floor
			d.box(Vector3(x0, y0, z1 - 0.012), Vector3(x1, y1 - 0.03, z1), col.darkened(0.2), ALL)   # back
			for x: float in [x0, x1 - 0.012]:
				d.box(Vector3(x, y0, z0), Vector3(x + 0.012, y1 - 0.03, z1), col.darkened(0.2), ALL)
			var hy := (y0 + y1) * 0.5
			d.box(Vector3(-0.06, hy - 0.012, z0 - T - 0.03), Vector3(0.06, hy + 0.012, z0 - T), METAL, ALL)
			handle(Vector3(0, hy, z0 - T - 0.03))
			surface(Vector3(0, y0 + 0.015, (z0 + z1) * 0.5), Vector2(x1 - x0 - 0.06, z1 - z0 - 0.06), name)

	## A box open at the top: four walls and a floor `floor_h` thick, the floor an item surface.
	func tub(lo: Vector3, hi: Vector3, floor_h: float, col: Color) -> void:
		body.box(lo, Vector3(hi.x, lo.y + floor_h, hi.z), col.darkened(0.2), ALL)
		body.box(lo, Vector3(hi.x, hi.y, lo.z + T), col, ALL)
		body.box(Vector3(lo.x, lo.y, hi.z - T), hi, col, ALL)
		body.box(lo, Vector3(lo.x + T, hi.y, hi.z), col, ALL)
		body.box(Vector3(hi.x - T, lo.y, lo.z), hi, col, ALL)
		surface(Vector3((lo.x + hi.x) * 0.5, lo.y + floor_h, (lo.z + hi.z) * 0.5),
				Vector2(hi.x - lo.x - 2 * T - 0.06, hi.z - lo.z - 2 * T - 0.06), "")

	## A flat lid from lo to hi hinged along its back edge (+z), its handle at the front. Returns its builder.
	func lid(lo: Vector3, hi: Vector3, col: Color) -> PropShapes.Builder:
		var l := lid_at(Vector3(0, lo.y, hi.z))
		l.box(lo, hi, col, ALL)
		l.box(Vector3(-0.08, lo.y, lo.z - 0.03), Vector3(0.08, hi.y, lo.z), PropShapes.METAL_DARK, ALL)
		handle(Vector3(0, (lo.y + hi.y) * 0.5, lo.z - 0.03))
		return l

	func lid_at(hinge: Vector3) -> PropShapes.Builder:
		return _mover("lid", hinge)

	## The model: the body and each mover as parts, markers for movers, handles and surfaces, then movers made.
	func finish(shape: String) -> ModelLibrary.Model:
		var turn := PropMesher.MODEL_TURN
		var m := ModelLibrary.Model.new()
		m.path = "placeholder/" + shape
		var pieces := [["", _body_bufs]]
		for mv: Array in _movers:
			pieces.append([mv[0], mv[2]])
			m.markers[mv[0]] = Transform3D(Basis.IDENTITY, turn * (mv[1] as Vector3))
		for pc: Array in pieces:
			var mesh := PropMesher._mesh(pc[1][0], pc[1][1])
			if mesh == null:
				continue
			m.aabb = mesh.get_aabb() if m.parts.is_empty() else m.aabb.merge(mesh.get_aabb())
			m.parts.append([mesh, Transform3D.IDENTITY])
			m.part_owner.append(pc[0])
		for k in _handles.size():
			var name := "handle_%d" % (k + 1)
			m.markers[name] = Transform3D(Basis.IDENTITY, turn * (_handles[k][1] as Vector3))
			m.marker_owner[name] = _handles[k][0]
		for k in _surfaces.size():
			var s: Array = _surfaces[k]
			var size: Vector2 = s[1]
			var xf := Transform3D(Basis.IDENTITY, turn * (s[0] as Vector3))
			m.surfaces.append([xf, Rect2(-size.x * 0.5, -size.y * 0.5, size.x, size.y), 0.0])
			m.surface_owner.append(s[2])
			m.markers["surface_%d" % (k + 1)] = xf
			if not (s[2] as String).is_empty():
				m.marker_owner["surface_%d" % (k + 1)] = s[2]
		ModelLibrary.make_movers(m)
		return m
