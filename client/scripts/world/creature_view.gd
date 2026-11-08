class_name CreatureView
extends Node3D
## The creatures the player perceives (block C4 placeholders, CreatureFigure): one figure per snapshot creature,
## moved smoothly from square to square (or snapped: `smooth` false), facing where it goes, with the monster's
## name above it. Events animate them: `attack` lunges at the target, `damage` flinches, `death` falls over.
## A creature missing from a snapshot stays a moment (its death event may come right after) and is then
## removed. Call apply() after WorldView.apply_snapshot so the origin is current, shift() on an origin shift.

const SNAP_DIST_M := 2.6      # a jump longer than this (teleport, first sight) isn't animated
const LINGER_S := 0.6
const MIN_MOVE_S := 0.12
const MAX_MOVE_S := 0.7
const NAME_RANGE_M := 25.0

var smooth := true
var show_player := false:     # the player's own figure (the outside view and VR; not first person)
	set(v):
		if v == show_player:
			return
		show_player = v
		if _snap != null and _world != null:
			apply(_snap, _world)
var view_z_max := CddaCoords.Z_MAX:
	set(z):
		if z == view_z_max:
			return
		view_z_max = z
		for f: CreatureFigure in _figs.values():
			f.visible = f.z_level <= z

var _figs := {}        # uid -> CreatureFigure
var _gone := {}        # uid -> [CreatureFigure, seconds left]
var _dying: Array[CreatureFigure] = []
var _snap: Snapshot
var _world: WorldView
var _last_ms := -1


static func height_of(kind: int, def: IdTables.Def) -> float:
	return CreatureFigure.top_of(kind, def)


func apply(snap: Snapshot, world: WorldView) -> void:
	_snap = snap
	_world = world
	var now := Time.get_ticks_msec()
	var dur := clampf((now - _last_ms) / 1000.0, MIN_MOVE_S, MAX_MOVE_S) if _last_ms >= 0 else MAX_MOVE_S
	_last_ms = now
	var seen := {}
	for c in snap.creatures:
		if c.kind == Snapshot.Creature.PLAYER and not show_player:
			continue
		var d := def_of(world, c)
		var key := "%d:%d:%d" % [c.kind, c.type, 1 if d != null else 0]
		var f: CreatureFigure = _figs.get(c.uid)
		if f == null and _gone.has(c.uid):   # back in sight before it was removed
			f = _gone[c.uid][0]
			_gone.erase(c.uid)
		var target := world.coords.ms_center_to_world(c.pos)
		if f == null or f.key != key:
			if f != null:
				f.free()
			f = _make(c, d, key)
			f.place(target)
		else:
			f.move_to(target, dur if smooth else 0.0, SNAP_DIST_M)
		_figs[c.uid] = f
		f.z_level = c.pos.z
		f.visible = c.pos.z <= view_z_max
		seen[c.uid] = true
	for uid: int in _figs.keys():
		if not seen.has(uid):
			_gone[uid] = [_figs[uid], LINGER_S]
			_figs.erase(uid)


## Events from the bridge (contracts/events.md); anything malformed is skipped.
func on_events(events: Array) -> void:
	for e: Variant in events:
		if not e is Dictionary:
			continue
		var kind: Variant = e.get("kind")
		var f := _find(e.get("uid"))
		if f == null or not kind is String:
			continue
		match kind:
			"attack":
				var t := _find(e.get("other"))
				if t != null:
					f.attack(t.position)
				elif e.get("pos") is Vector3i and _world != null:
					f.attack(_world.coords.ms_center_to_world(e["pos"]))
				else:
					f.attack()
			"damage":
				f.hurt()
			"death":
				var uid: int = int(e["uid"])
				_figs.erase(uid)
				_gone.erase(uid)
				f.die()
				_dying.append(f)


func _process(delta: float) -> void:
	tick(delta)


## Moves and animates every figure by `delta` seconds (tests call it directly).
func tick(delta: float) -> void:
	for f: CreatureFigure in _figs.values():
		f.animate(delta)
	for uid: int in _gone.keys():
		var g: Array = _gone[uid]
		(g[0] as CreatureFigure).animate(delta)
		g[1] -= delta
		if g[1] <= 0.0:
			(g[0] as CreatureFigure).free()
			_gone.erase(uid)
	for i in range(_dying.size() - 1, -1, -1):
		_dying[i].animate(delta)
		if _dying[i].done:
			_dying[i].free()
			_dying.remove_at(i)


## The origin moved (map shift): keep every figure on its square.
func shift(d: Vector3) -> void:
	for f: CreatureFigure in _figs.values():
		f.shift(d)
	for g: Array in _gone.values():
		(g[0] as CreatureFigure).shift(d)
	for f in _dying:
		f.shift(d)


func count() -> int:
	return _figs.size()


func figure(uid: int) -> CreatureFigure:
	return _figs.get(uid)


func dying_count() -> int:
	return _dying.size()


func _find(uid: Variant) -> CreatureFigure:
	if not (uid is int or uid is float):
		return null
	var u := int(uid)
	if _figs.has(u):
		return _figs[u]
	if _gone.has(u):
		return _gone[u][0]
	return null


func _make(c: Snapshot.Creature, d: IdTables.Def, key: String) -> CreatureFigure:
	var f := CreatureFigure.make(c.kind, d, key)
	f.name = "creature_%d" % c.uid
	if d != null and d.name != "":
		var l := Label3D.new()
		l.text = CddaText.plain(d.name).left(40)
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.pixel_size = 0.004
		l.outline_size = 8
		l.position.y = f.top + 0.25
		l.visibility_range_end = NAME_RANGE_M
		f.add_child(l)
	add_child(f)
	return f


## The mtype definition of a monster, or null (NPCs, the player, tables of another session).
static func def_of(world: WorldView, c: Snapshot.Creature) -> IdTables.Def:
	if c.kind != Snapshot.Creature.MONSTER or world.tables == null:
		return null
	var snap := world.snapshot
	if snap != null and snap.ids_generation >= 0 and snap.ids_generation != world.tables.generation:
		return null   # tables from another session: the index means something else
	return world.tables.def_at("mtype", c.type)
