class_name VrWalk
extends RefCounted
## Block L1: where the VR viewer may stand and how it moves, read from the newest snapshot. No nodes, so the
## tests run it headless. A square is standable when the snapshot has it, it has a floor, and neither its
## terrain nor its furniture is impassable. Walls, windows, fences, trees, impassable furniture and closed
## doors block; doors open by dragging them (Grabbable): in mock mode the client's own state
## (WorldView.door_open) counts, in a live game CDDA's.

const K := TerrainCatalog.Kind
const NO_STAND := [K.NONE, K.TREETOP]
const BLOCKS := [K.WALL, K.WINDOW, K.FENCE, K.TREE, K.BOX]   # without id tables: judged by look
const BODY_R := 0.2          # metres kept between the head and a blocked square
const MAX_TELEPORT := 10.0   # metres, horizontal
const ARC_SPEED := 7.0       # m/s along the controller's aim
const ARC_STEP := 0.03       # s per arc segment
const ARC_STEPS := 90
const GRAVITY := 9.8
const SEARCH_R := 4          # squares searched around a target that is blocked (level change, spawn)

var world: WorldView


func _init(w: WorldView) -> void:
	world = w


static func floor_y(z: int) -> float:
	return z * CddaCoords.LEVEL_M


## Square under a horizontal Godot position on level z.
func square_at(w: Vector3, z: int) -> Vector3i:
	var s := world.coords.world_to_ms(Vector3(w.x, 0.0, w.z))
	return Vector3i(s.x, s.y, z)


func can_stand(p: Vector3i) -> bool:
	var snap := world.snapshot
	if snap == null:
		return false
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return false
	var l := CddaCoords.ms_to_local(p)
	var i := l.y * CddaCoords.SEEX + l.x
	if (sm.flags[i] & Snapshot.FLAG_NO_FLOOR) != 0:
		return false
	var ter := sm.ter[i]
	var kind := world.catalog.style_for(ter).kind
	if kind in NO_STAND:
		return false
	if kind == K.DOOR:
		var open: bool = world.catalog.style_for(ter).state != 0
		if world.door_local:
			open = world.door_open.get(p, open)
		if not open:
			return false
	else:
		var td := _def("ter", ter, snap.ter_names)
		if td != null:
			if td.move_cost <= 0 and (td.open.is_empty() or kind == K.WINDOW):
				return false
		elif kind in BLOCKS:
			return false
	var f := sm.furn[i]
	if f != 0:
		var fd := _def("furn", f, snap.furn_names)
		if fd != null and fd.move_cost < 0:
			return false
	return true


## Definition of a snapshot id: by index when the tables match the snapshot, else by the snapshot's name.
func _def(table: String, id: int, names: Dictionary) -> IdTables.Def:
	var t := world.tables
	if t == null:
		return null
	var snap := world.snapshot
	if snap.ids_generation < 0 or snap.ids_generation == t.generation:
		return t.def_at(table, id)
	return t.def_named(table, names.get(id, ""))


## Moves a head at `from` by the horizontal `step` on level z, axis by axis, so it slides along walls.
## A head already inside a blocked square (walked there in the room) can always move.
func slide(from: Vector3, step: Vector3, z: int) -> Vector3:
	var p := from
	for axis: int in [0, 2]:
		var d: float = step[axis]
		if d == 0.0:
			continue
		var q := p
		q[axis] += d
		var probe := q
		probe[axis] += signf(d) * BODY_R
		if can_stand(square_at(probe, z)) or not can_stand(square_at(p, z)):
			p = q
	return p


## True when nothing that blocks stands between the centres of squares a and b (same level).
func clear_line(a: Vector3i, b: Vector3i) -> bool:
	var d := Vector2(b.x - a.x, b.y - a.y)
	var n := ceili(d.length() * 4.0)
	for i in range(1, n):
		var t := float(i) / n
		var q := Vector3i(floori(a.x + 0.5 + d.x * t), floori(a.y + 0.5 + d.y * t), a.z)
		if q != a and q != b and not _passable(q):
			return false
	return true


## Like can_stand, but a hole or open air doesn't stop a teleport arc.
func _passable(p: Vector3i) -> bool:
	if can_stand(p):
		return true
	var sm: Snapshot.Submap = world.snapshot.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return false
	var l := CddaCoords.ms_to_local(p)
	return world.catalog.style_for(sm.ter[l.y * CddaCoords.SEEX + l.x]).kind in NO_STAND


## Teleport arc from `origin` along `aim` (Godot space), landing on level z's floor. Returns
## {points: PackedVector3Array, hit: bool, pos: Vector3, valid: bool}; `pos` is the landing point.
func teleport_arc(origin: Vector3, aim: Vector3, z: int) -> Dictionary:
	var pts := PackedVector3Array([origin])
	var v := aim.normalized() * ARC_SPEED
	var p := origin
	var fy := floor_y(z)
	var out := {"points": pts, "hit": false, "pos": origin, "valid": false}
	if p.y < fy:
		return out
	for i in ARC_STEPS:
		var q := p + v * ARC_STEP
		v.y -= GRAVITY * ARC_STEP
		if q.y <= fy:
			var hit := p.lerp(q, (p.y - fy) / maxf(p.y - q.y, 1e-6))
			pts.append(hit)
			out["hit"] = true
			out["pos"] = hit
			break
		pts.append(q)
		p = q
	out["points"] = pts
	if out["hit"]:
		var to: Vector3 = out["pos"]
		var flat := Vector2(to.x - origin.x, to.z - origin.z).length()
		var from_sq := square_at(origin, z)
		var to_sq := square_at(to, z)
		out["valid"] = flat <= MAX_TELEPORT and can_stand(to_sq) and clear_line(from_sq, to_sq)
	return out


## Nearest standable square to p on its level, p itself first; null when none within SEARCH_R.
## `skip_self`: never p (a spot next to the player marker).
func nearest_standable(p: Vector3i, skip_self := false) -> Variant:
	if not skip_self and can_stand(p):
		return p
	for r in range(1, SEARCH_R + 1):
		var best: Variant = null
		var best_d := INF
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var q := p + Vector3i(dx, dy, 0)
				var d := Vector2(dx, dy).length_squared() + (0.1 if dy < 0 else 0.0)   # ties: south first
				if d < best_d and can_stand(q):
					best = q
					best_d = d
		if best != null:
			return best
	return null


## Yaw-only turn of an origin transform about a pivot (the head), so the head stays where it is.
static func turned(xf: Transform3D, pivot: Vector3, angle: float) -> Transform3D:
	return xf.translated(-pivot).rotated(Vector3.UP, angle).translated(pivot)
