class_name TerrainCatalog
extends RefCounted
## Decides how each terrain id is built, from its definition in the id tables (contracts/id_tables.md):
## an exact registry entry's `mesher` first (assets/registry, `kind: terrain`), then the terrain's flags,
## connect groups, open/close pair and `roof` links, then its `looks_like` chain, then a box, so nothing
## is invisible. Colour: the registry `material` of the id, else its CDDA colour, else the material of
## the first registered id in its looks_like chain. A registry `model` that loads (exact id, else the
## looks_like chain) replaces the procedural shape; TerrainMesher places it.
##
## Without id tables (or with tables of another generation than the snapshot's) terrain is looked up by
## the snapshot's id names: registered ids still mesh, the rest are boxes.

enum Kind { NONE, FLOOR, WALL, WINDOW, DOOR, FENCE, STAIRS_UP, STAIRS_DOWN, LADDER_UP, LADDER_DOWN,
		RAMP_UP, ROOF, WATER, TREE, TREETOP, SHRUB, BOX }

const MESHERS := {
	"floor": Kind.FLOOR, "wall": Kind.WALL, "window": Kind.WINDOW, "door": Kind.DOOR,
	"fence": Kind.FENCE, "stairs_up": Kind.STAIRS_UP, "stairs_down": Kind.STAIRS_DOWN,
	"ramp": Kind.RAMP_UP, "water": Kind.WATER, "roof": Kind.ROOF, "open_air": Kind.NONE,
}
## Kinds that say how the tile behaves, not only how it looks: never taken from a looks_like chain
## (monkey bars look like a ladder but don't lead up).
const STRUCTURAL := [Kind.NONE, Kind.STAIRS_UP, Kind.STAIRS_DOWN, Kind.LADDER_UP, Kind.LADDER_DOWN, Kind.RAMP_UP]
## Kinds that stay procedural even with a registry model: open air and the holes stairs and ladders come up
## through (nothing to draw), and doors (the leaf is a Grabbable that swings; models for it come later).
const MODEL_LESS := [Kind.NONE, Kind.STAIRS_DOWN, Kind.LADDER_DOWN, Kind.DOOR]
const FENCE_GROUPS := ["CHAINFENCE", "WOODFENCE", "RAILING"]
const WATER_FLAGS := ["SWIMMABLE", "SHALLOW_WATER", "DEEP_WATER", "LIQUID"]
const DOOR_FLAGS := ["DOOR", "LOCKED", "BARRICADABLE_DOOR", "BARRICADABLE_DOOR_DAMAGED", "BARRICADABLE_DOOR_REINFORCED"]

const GROUND := Color(0.38, 0.34, 0.26)
const UNKNOWN := Color(1.0, 0.0, 1.0)
const TRUNK := Color(0.36, 0.26, 0.17)
const STONE := Color(0.62, 0.61, 0.58)
const FRAME := Color(0.8, 0.78, 0.74)


class Style:
	var kind := 0
	var color := Color.MAGENTA
	var color2 := Color.MAGENTA   # tree crowns, curtains
	var state := 0                # door: 0 closed, 1 open, 2 empty/broken; window: 0 glass, 1 open, 2 curtains, 3 glass wall
	var height := 3.0
	var glass := false            # glass door leaf
	var locked := false           # door with CDDA's LOCKED flag
	var groups := 0               # connect groups (bits, IdTables.group_bit)
	var connects_to := 0          # groups this tile joins; both 0 = join by kind (no id tables)
	## Registry model drawn instead of the procedural shape (TerrainMesher); null = procedural. Never set
	## for MODEL_LESS kinds. Placement from the same entry:
	var model: ModelLibrary.Model
	var scale := 1.0
	var offset := Vector3.ZERO
	var random_yaw := false
	## Plain ground whose id names a ramp: maybe a ramp's low end (t_ramp_up_low, t_earth_ramp_up_low, ...). CDDA
	## gives the low end no flag, only that id; TerrainMesher.ramp_place makes it one only right behind a RAMP_UP run.
	var ramp_low := false


var registry := AssetRegistry.new()
## Bumped by every load_registry_dir (WorldView remakes its job catalogs on a change).
var registry_revision := 0
var tables: IdTables
## The registry's warnings (bad files and entries) and its models' (bad or missing .glb files).
var warnings: PackedStringArray:
	get:
		return registry.all_warnings()
var _names := {}       # int id -> name, from the snapshot (used when the tables don't match it)
var _by_index := true  # tables match the snapshot: look definitions up by index
var _styles := {}      # int id -> Style
var _wall_bit := 0
var _fence_bits := 0


func load_registry_dir(dir_path: String) -> void:
	registry.load_dir(dir_path)
	registry_revision += 1
	_styles.clear()


func set_tables(t: IdTables) -> void:
	tables = t if t != null and t.is_valid() else null
	_wall_bit = tables.group_bit("WALL") if tables else 0
	_fence_bits = 0
	if tables:
		for g: String in FENCE_GROUPS:
			_fence_bits |= tables.group_bit(g)
	_styles.clear()


## Index -> definition goes through the tables when their generation is the snapshot's, else through
## the snapshot's names. Clears cached styles when that changes.
func set_snapshot(snap: Snapshot) -> void:
	var by_index := tables != null and (snap.ids_generation < 0 or snap.ids_generation == tables.generation)
	if by_index != _by_index or (not by_index and snap.ter_names != _names):
		_styles.clear()
	_by_index = by_index
	_names = snap.ter_names


## The snapshot's id -> name table (no id tables). Clears cached styles.
func set_names(names: Dictionary) -> void:
	_names = names
	_by_index = false
	_styles.clear()


func style_for(id: int) -> Style:
	var s: Style = _styles.get(id)
	if s == null:
		var def: IdTables.Def = null
		var name: String = _names.get(id, "")
		if tables != null:
			def = tables.def_at("ter", id) if _by_index else tables.def_named("ter", name)
		if def != null:
			name = def.id
		elif name.is_empty():
			id = -1   # ids nothing defines or names share one style: a hostile snapshot can't grow the cache
			s = _styles.get(id)
			if s != null:
				return s
		s = make_style(def, name)
		_styles[id] = s
	return s


## Style of a terrain id name (tests, tools).
func style_for_id(name: String) -> Style:
	return make_style(tables.def_named("ter", name) if tables else null, name)


func make_style(def: IdTables.Def, name: String) -> Style:
	var s := Style.new()
	if name.is_empty() and def == null:
		s.kind = Kind.BOX
		s.color = UNKNOWN
		s.height = 1.0
		return s
	var reg := registry.entry(name, "terrain")
	if reg != null and MESHERS.has(reg.mesher):
		s.kind = MESHERS[reg.mesher]
	elif def != null:
		s.kind = _kind(def)
	elif name == "t_null":
		s.kind = Kind.NONE
	else:
		s.kind = Kind.BOX
	if def != null:
		s.groups = def.groups
		s.connects_to = def.connects_to
	s.ramp_low = s.kind == Kind.FLOOR and name.contains("ramp")
	_dress(def, name, s)
	if reg != null and CddaPalette.MATERIALS.has(reg.material):
		s.color = CddaPalette.material(reg.material)
	if not s.kind in MODEL_LESS:
		_take_model(def, reg, s)
	return s


## The tile's registry model, by the chain (contracts/assets.md) without generics: the exact entry when it has
## art (a `mesher`-only entry, or one whose model doesn't load, keeps the tile procedural), else the first
## terrain entry with art along the looks_like chain. Stairs, ladders and ramps take a looks_like model only
## from an id of their own kind, so they never look like a floor. The entry's `material` tints the model.
func _take_model(def: IdTables.Def, reg: AssetRegistry.Entry, s: Style) -> void:
	var e := reg
	if not registry.has_terrain_art(e):
		e = null
		var seen := {}
		var link := def.looks_like if def != null and tables != null else ""
		if def != null:
			seen[def.id] = true
		for i in AssetRegistry.MAX_CHAIN:
			if link.is_empty() or seen.has(link):
				break
			seen[link] = true
			var le := registry.entry(link, "terrain")
			var ld := tables.def_named("ter", link)
			if registry.has_terrain_art(le):
				if not s.kind in STRUCTURAL or _link_kind(le, ld) == s.kind:
					e = le
				break
			link = ld.looks_like if ld != null else ""
	var m := registry.model_of(e)
	if m == null:
		return
	s.model = m
	s.scale = e.scale
	s.offset = e.offset
	s.random_yaw = e.random_yaw


## Kind of a looks_like link: its entry's mesher, else its flags; -1 when neither says.
func _link_kind(e: AssetRegistry.Entry, d: IdTables.Def) -> int:
	if e != null and MESHERS.has(e.mesher):
		return MESHERS[e.mesher]
	return _kind(d) if d != null else -1


## Kind from the definition; its looks_like chain when the flags don't settle it.
func _kind(def: IdTables.Def) -> int:
	if def.id == "t_null":
		return Kind.NONE
	var k := _flag_kind(def)
	if k >= 0:
		return k
	var seen := {def.id: true}
	var d := def
	for i in AssetRegistry.MAX_CHAIN:
		if d.looks_like.is_empty() or seen.has(d.looks_like):
			break
		seen[d.looks_like] = true
		d = tables.def_named("ter", d.looks_like)
		if d == null:
			break
		k = _flag_kind(d)
		if k >= 0 and not k in STRUCTURAL:
			return k
	if def.move_cost > 0 and def.move_cost <= 2 and def.coverage == 0 and not def.has("THIN_OBSTACLE") 			and not def.has("MOUNTABLE"):
		return Kind.FLOOR   # plain walkable ground without a FLAT flag (grates, the low end of a ramp)
	return Kind.BOX


## Kind from flags and links alone, -1 when they don't settle it.
func _flag_kind(d: IdTables.Def) -> int:
	if d.has("NO_FLOOR") or d.has("EMPTY_SPACE") or d.has("RAMP_DOWN") \
			or (d.has("TRANSPARENT_FLOOR") and d.has("Z_TRANSPARENT")):
		return Kind.NONE   # open air, or the top of a ramp or stairs from below
	if d.has("GOES_DOWN"):
		return Kind.LADDER_DOWN if d.has("DIFFICULT_Z") else Kind.STAIRS_DOWN
	if d.has("GOES_UP"):
		return Kind.LADDER_UP if d.has("DIFFICULT_Z") else Kind.STAIRS_UP
	if d.has("RAMP_UP"):
		return Kind.RAMP_UP
	if d.has("TREE"):
		return Kind.TREE
	if tables.is_treetop(d.id):
		return Kind.TREETOP
	if d.has("WINDOW"):
		return Kind.WINDOW
	if d.has("WALL"):
		return Kind.WINDOW if d.transparent else Kind.WALL   # glass walls
	var in_wall := (d.groups & _wall_bit) != 0
	var in_fence := (d.groups & _fence_bits) != 0
	if _is_door(d) or (in_wall and d.has("FLAT")):
		return Kind.FENCE if in_fence and not in_wall else Kind.DOOR   # gates stand in fences
	if in_wall and d.move_cost > 0 and d.coverage >= 50:
		return Kind.WALL   # half walls
	if d.has("SHRUB"):
		return Kind.SHRUB
	for f: String in WATER_FLAGS:
		if d.has(f):
			return Kind.WATER
	if tables.is_roof(d.id):
		return Kind.ROOF
	if in_fence or (d.has("AUTO_WALL_SYMBOL") and not in_wall):
		return Kind.FENCE
	if d.has("FLAT") or d.has("RUG"):
		return Kind.FLOOR
	return -1


static func _is_door(d: IdTables.Def) -> bool:
	if not d.open.is_empty() or not d.close.is_empty():
		return true
	for f: String in DOOR_FLAGS:
		if d.has(f):
			return true
	return false


## Colour, state and height per kind, from the definition (CDDA colour, flags, passability).
func _dress(d: IdTables.Def, name: String, s: Style) -> void:
	var fallback := _chain_color(d) if d != null else _hash_color(name)
	var own := CddaPalette.fg(d.color, fallback) if d != null else fallback
	s.color = own
	match s.kind:
		Kind.WALL:
			s.height = CddaCoords.LEVEL_M if d == null or d.has("WALL") else 1.2
		Kind.DOOR:
			if d == null:
				return
			s.locked = d.has("LOCKED")
			var passable := d.move_cost > 0
			if passable:
				s.state = 1 if not d.close.is_empty() else 2   # open, or an empty frame
			elif d.transparent and d.has("PERMEABLE"):
				s.state = 2   # broken
			else:
				s.glass = d.transparent
		Kind.WINDOW:
			s.color = FRAME
			if d == null:
				return
			if d.has("WALL") and not d.has("WINDOW"):
				s.state = 3
			elif d.move_cost > 0 or d.has("PERMEABLE"):
				s.state = 1
			elif not d.transparent:
				s.state = 2
				s.color2 = own
		Kind.FENCE:
			s.height = 2.0
			if d != null and d.has("TINY"):
				s.height = 0.3
			elif d != null and d.has("SHORT"):
				s.height = 1.1
		Kind.TREE:
			s.color = TRUNK
			s.color2 = own
			if d != null and not d.roof.is_empty() and tables != null:
				var top := tables.def_named("ter", d.roof)
				if top != null:
					s.color2 = CddaPalette.fg(top.color, own)
		Kind.TREETOP:
			s.color2 = own
		Kind.SHRUB:
			s.color = CddaPalette.bg(d.color, own) if d != null else own
			s.height = 0.8
		Kind.STAIRS_UP, Kind.LADDER_UP:
			s.color = own.lerp(STONE, 0.6)   # ramps keep their own colour, the same as their low end's
		Kind.BOX:
			s.height = 1.0
			if d != null:
				s.height = 0.3 if d.has("TINY") else (0.9 if d.has("SHORT") else clampf(d.coverage / 50.0, 0.5, 2.0))


## Registry material of the first registered id in the looks_like chain, else a colour from the name.
func _chain_color(d: IdTables.Def) -> Color:
	var seen := {d.id: true}
	var link := d.looks_like
	for i in AssetRegistry.MAX_CHAIN:
		if link.is_empty() or seen.has(link):
			break
		seen[link] = true
		var e := registry.entry(link, "terrain")
		if e != null and CddaPalette.MATERIALS.has(e.material):
			return CddaPalette.material(e.material)
		var next: IdTables.Def = tables.def_named("ter", link) if tables else null
		link = next.looks_like if next else ""
	return _hash_color(d.id)


## Stable placeholder colour per id name.
static func _hash_color(n: String) -> Color:
	return Color.from_hsv(float(posmod(n.hash(), 360)) / 360.0, 0.5, 0.75)
