class_name LookRay
extends RefCounted
## Left-click look: the first thing a ray from the camera meets in the newest snapshot (a wall, a closed door,
## furniture, a floor or a ceiling) and what the snapshot says is on that square. No nodes, so tests run it
## headless. The ray meets what the 3D view draws: every square in the snapshot, also ones the character never
## saw (the view has no fog of war yet); the details say so. Out to the edge of the loaded area (~60 squares).
## Creatures the player perceives are hit
## as their placeholder figures (CreatureView). CDDA's own look text isn't in here: the bridge has no "describe".

const K := TerrainCatalog.Kind
const SOLID := [K.WALL, K.WINDOW, K.FENCE, K.TREE, K.BOX]
const FURN_H := 1.0      # metres: a ray below this height over furniture hits it
const STEP_M := 0.05
const MAX_M := 120.0
const VIS := ["your character hasn't seen it", "remembered", "in sight", "in sight, dark"]
const MAX_ITEM_LINES := 4

var world: WorldView


func _init(w: WorldView) -> void:
	world = w


## {hit: bool, square: Vector3i, point: Vector3, what: "wall" / "door" / "furniture" / "floor" / "ceiling"}.
func cast(origin: Vector3, dir: Vector3, max_m := MAX_M) -> Dictionary:
	if world.snapshot == null or dir.length() < 0.001:
		return {"hit": false}
	dir = dir.normalized()
	var start := world.coords.world_to_ms(origin)
	var prev := start
	for i in range(1, int(max_m / STEP_M) + 1):
		var pt := origin + dir * (i * STEP_M)
		var p := world.coords.world_to_ms(pt)
		if p.z < prev.z and _has_floor(Vector3i(p.x, p.y, prev.z)):
			return _hit(Vector3i(p.x, p.y, prev.z), pt, "floor")
		if p.z > prev.z and _has_floor(p):
			return _hit(p, pt, "ceiling")
		prev = p
		if p == start:
			continue
		var c := _cell(p)
		if c.is_empty():
			return {"hit": false}   # out of the loaded area
		var floor_y := world.coords.ms_to_world(p).y
		var cr := world.snapshot.creature_at(p)
		if cr != null and pt.y - floor_y < CreatureView.height_of(cr.kind, CreatureView.def_of(world, cr)):
			return _hit(p, pt, creature_name(cr))
		var style := world.catalog.style_for(c["ter"])
		if style.kind in SOLID:
			return _hit(p, pt, "object" if style.kind == K.BOX else K.keys()[style.kind].to_lower())
		if style.kind == K.DOOR and style.state == 0:
			return _hit(p, pt, "door")
		if c["furn"] != 0 and pt.y - floor_y < FURN_H:
			return _hit(p, pt, "furniture")
	return {"hit": false}


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
