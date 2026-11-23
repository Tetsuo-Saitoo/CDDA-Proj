class_name LookRay
extends RefCounted
## Left-click look: the first thing a ray from the camera meets in the newest snapshot (a wall, a closed door,
## furniture, stairs or a ramp, a floor or a ceiling) and what the snapshot says is on that square. No nodes, so
## tests run it headless. The ray meets what the 3D view draws: every square in the snapshot, also ones the
## character never saw (the view has no fog of war yet); the details say so. Out to the edge of the loaded area
## (~60 squares). Stairs and ramps are met on their slope (TerrainMesher.surface_heights), so pointing at a step
## picks that stair's square. Creatures the player perceives are hit as their placeholder figures
## (CreatureView), vehicle parts as VehicleView draws them (VehicleView.part_at: `what` names the vehicle and the
## part, `vehicle` is its uid, `part` the part's index); a glovebox's door where it is drawn in the dashboard
## (_glovebox; `square` the glovebox's own, the windshield's). CDDA's own look text isn't in here: the bridge has no
## "describe".

const K := TerrainCatalog.Kind
const SOLID := [K.WALL, K.WINDOW, K.FENCE, K.TREE, K.BOX]
const FURN_H := 1.0      # metres: a ray below this height over furniture hits it
const STEP_M := 0.05
const MAX_M := 120.0
const VIS := ["your character hasn't seen it", "remembered", "in sight", "in sight, dark"]
const MAX_ITEM_LINES := 4

var world: WorldView
var _surfaces := {}   # Vector3i -> stair / ramp corner heights met by the current cast
var _ramp_cache := {}
var _kind_at: Callable
var _low_at: Callable


func _init(w: WorldView) -> void:
	world = w


## {hit: bool, square: Vector3i, point: Vector3, what: "wall" / "door" / "furniture" / "stairs" / "ramp" / "floor" /
## "ceiling"}.
## `creatures` false: only the map (BulletPhysics tests the figures itself).
## `skip_start` false: the square the ray starts in counts too (top-view picks start at eye height, possibly in
## the very square clicked); true skips it (the eye's own square: your furniture and stairs).
func cast(origin: Vector3, dir: Vector3, max_m := MAX_M, creatures := true, skip_start := true) -> Dictionary:
	if world.snapshot == null or dir.length() < 0.001:
		return {"hit": false}
	dir = dir.normalized()
	_surfaces = {}
	_ramp_cache = {}
	_kind_at = TerrainMesher.kind_lookup(world.snapshot, world.catalog)
	_low_at = TerrainMesher.low_lookup(world.snapshot, world.catalog)
	var start := world.coords.world_to_ms(origin)
	var prev := start
	var glove := _glovebox(origin, dir, start, max_m)
	for i in range(1, int(max_m / STEP_M) + 1):
		if not glove.is_empty() and i * STEP_M >= glove[0]:
			var veh: Snapshot.Vehicle = glove[1]
			var g := _hit(veh.square(glove[2]), origin + dir * glove[0],
					VehicleView.part_name(world.snapshot, world.tables, veh, glove[2]))
			g["vehicle"] = veh.uid
			g["part"] = glove[2]
			return g
		var pt := origin + dir * (i * STEP_M)
		var p := world.coords.world_to_ms(pt)
		if p.z < prev.z and _has_floor(Vector3i(p.x, p.y, prev.z)):
			return _hit(Vector3i(p.x, p.y, prev.z), pt, "floor")
		if p.z > prev.z and _has_floor(p):
			return _hit(p, pt, "ceiling")
		prev = p
		if skip_start and p == start:
			continue
		var c := _cell(p)
		if c.is_empty():
			return {"hit": false}   # out of the loaded area
		var floor_y := world.coords.ms_to_world(p).y
		var cr := world.snapshot.creature_at(p)
		if creatures and cr != null and pt.y - floor_y < CreatureView.height_of(cr.kind, CreatureView.def_of(world, cr)):
			return _hit(p, pt, creature_name(cr))
		var vp := VehicleView.part_at(world.snapshot, world.tables, p, pt.y - floor_y)
		if not vp.is_empty():
			var r := _hit(p, pt, VehicleView.part_name(world.snapshot, world.tables, vp[0], vp[1]))
			r["vehicle"] = (vp[0] as Snapshot.Vehicle).uid
			r["part"] = vp[1]   # its index in that vehicle's parts
			return r
		var style := world.catalog.style_for(c["ter"])
		if style.kind in SOLID:
			return _hit(p, pt, "object" if style.kind == K.BOX else K.keys()[style.kind].to_lower())
		if style.kind == K.DOOR and style.state == 0:
			return _hit(p, pt, "door")
		if style.kind in [K.STAIRS_UP, K.RAMP_UP] or style.ramp_low:
			var in_sq := pt - world.coords.ms_to_world(p)
			var hs := _surface(p)
			if not hs.is_empty() and in_sq.y < TerrainMesher.height_at(hs, in_sq.x, in_sq.z):
				return _hit(p, pt, "stairs" if style.kind == K.STAIRS_UP else "ramp")
		if c["furn"] != 0 and pt.y - floor_y < FURN_H:
			return _hit(p, pt, "furniture")
	return {"hit": false}


## The nearest glovebox door the ray meets as drawn (CarInterior.glove_box, in the vehicle's frame_of): [distance,
## Vehicle, part], [] for none. Only vehicles on the eye's square or one around it: the door is seen from the front
## seats (its square is the windshield's, ahead of the seat the eye is in); from further the body is met first.
func _glovebox(origin: Vector3, dir: Vector3, start: Vector3i, max_m: float) -> Array:
	var best := []
	var done := {}
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var at := world.snapshot.vehicle_at(start + Vector3i(dx, dy, 0))
			if at.is_empty() or done.has((at[0] as Snapshot.Vehicle).uid):
				continue
			var veh: Snapshot.Vehicle = at[0]
			done[veh.uid] = true
			var doors := CarInterior.glove_doors(veh, world.snapshot, world.tables, CddaCoords.Z_LIMIT)
			if doors.is_empty():
				continue
			var inv := VehicleView.frame_of(veh, world.coords).affine_inverse()
			var o := inv * origin
			var d := inv.basis * dir
			for e: Array in doors:
				var t := box_t(CarInterior.glove_box(e[1]), o, d, max_m)
				if t >= 0.0 and (best.is_empty() or t < best[0]):
					best = [t, veh, e[0]]
	return best


## How far along a ray from `o` (direction `d`, the distance's units) it first meets box `b`, within 0..max_m; -1
## when it doesn't.
static func box_t(b: AABB, o: Vector3, d: Vector3, max_m: float) -> float:
	var t0 := 0.0
	var t1 := max_m
	for a in 3:
		if absf(d[a]) < 1e-9:
			if o[a] < b.position[a] or o[a] > b.end[a]:
				return -1.0
			continue
		var ta := (b.position[a] - o[a]) / d[a]
		var tb := (b.end[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return -1.0
	return t0


## Lines about square p: terrain, furniture, trap, items, and how the player sees it.
func describe(p: Vector3i) -> PackedStringArray:
	var out := PackedStringArray()
	var c := _cell(p)
	if c.is_empty():
		out.append("nothing known")
		return out
	var snap := world.snapshot
	var cr := snap.creature_at(p)
	if cr != null:
		out.append("creature: %s, health %d%%" % [creature_name(cr), roundi(cr.hp_frac * 100.0 / 255.0)])
	var at := snap.vehicle_at(p)
	if not at.is_empty():
		var names := PackedStringArray()
		for i: int in at[1]:
			if names.size() < MAX_ITEM_LINES:
				names.append(VehicleView.part_label(snap, world.tables, at[0], i))
		var veh: Snapshot.Vehicle = at[0]
		out.append("vehicle: %s (%d parts here: %s)" % [veh.name if not veh.name.is_empty() else "unnamed",
				(at[1] as PackedInt32Array).size(), ", ".join(names)])
	out.append("terrain: " + _name("ter", c["ter"], snap.ter_names))
	if c["furn"] != 0:
		out.append("furniture: " + _name("furn", c["furn"], snap.furn_names))
	if c["trap"] != 0:
		out.append("trap: " + _name("trap", c["trap"], snap.trap_names))
	var pile: PackedInt32Array = c["pile"]
	if not pile.is_empty():
		var names := PackedStringArray()
		for k in range(2, Snapshot.PILE_TOP_END):
			if pile[k] > 0 and names.size() < MAX_ITEM_LINES:
				names.append(_name("itype", pile[k], {}))
		out.append("items (%d): %s" % [pile[1], ", ".join(names)])
	out.append(VIS[clampi(c["vis"], 0, VIS.size() - 1)])
	return out


func creature_name(cr: Snapshot.Creature) -> String:
	if cr.kind == Snapshot.Creature.NPC:
		return "someone (NPC)"
	return _name("mtype", cr.type, {})


func _hit(p: Vector3i, pt: Vector3, what: String) -> Dictionary:
	return {"hit": true, "square": p, "point": pt, "what": what}


## The stair flight or ramp surface drawn on square p (TerrainMesher.surface_heights), empty when none is.
func _surface(p: Vector3i) -> PackedFloat32Array:
	if not _surfaces.has(p):
		_surfaces[p] = TerrainMesher.surface_heights(p, _kind_at, _low_at, _ramp_cache)
	return _surfaces[p]


func _has_floor(p: Vector3i) -> bool:
	var c := _cell(p)
	return not c.is_empty() and (c["flags"] & Snapshot.FLAG_NO_FLOOR) == 0


## The snapshot's data for square p, {} when it isn't in the snapshot.
func _cell(p: Vector3i) -> Dictionary:
	var sm: Snapshot.Submap = world.snapshot.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return {}
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	var vis: int = sm.vis[i] if i < sm.vis.size() else 2
	var pile := PackedInt32Array()
	for j in range(0, sm.items.size() - Snapshot.PILE_STRIDE + 1, Snapshot.PILE_STRIDE):
		if sm.items[j] == i:
			pile = sm.items.slice(j, j + Snapshot.PILE_STRIDE)
			break
	return {"ter": sm.ter[i], "furn": sm.furn[i], "trap": sm.trap[i] if i < sm.trap.size() else 0,
			"flags": sm.flags[i], "vis": vis, "pile": pile}


## Name of a snapshot id: from the id tables when they match the snapshot, else the snapshot's own name.
func _name(table: String, id: int, names: Dictionary) -> String:
	var t := world.tables
	var d: IdTables.Def = null
	if t != null:
		var snap := world.snapshot
		if snap.ids_generation < 0 or snap.ids_generation == t.generation:
			d = t.def_at(table, id)
		elif names.has(id):
			d = t.def_named(table, names[id])
	var n := d.name if d != null and not d.name.is_empty() else str(names.get(id, "#%d" % id))
	return CddaText.plain(n).left(60)
