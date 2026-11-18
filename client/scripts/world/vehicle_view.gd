class_name VehicleView
extends Node3D
## Block C5 (PLAN.md), slice 1: CDDA's vehicles (Snapshot.vehicles) drawn part by part on their squares. A plain
## shape per kind of part (Kind, from the vpart's flags and location in the id tables), turned to the vehicle's
## facing, in the part's CDDA colour; damaged parts go rusty and dark, broken ones charred, broken glass is gone.
## CDDA's gap fillers (Snapshot.VPART_FILLER: the parts it adds on a turned vehicle's diagonals) draw and block as
## the part they copy. One MultiMesh per look (solid, glass, wheels), rebuilt per snapshot (driving moves them) and
## when the cutaway moves. What blocks walking (blocks), which part a ray meets at a height (part_at) and what items
## rest on (rest_at) are here too, for walking, LookRay and the item physics. Real models, smooth turning and doors
## by hand are later slices.

enum Kind { NONE, FRAME, BOARD, HALF, DOOR, GLASS_DOOR, DOOR_OPEN, WINDOW, ROOF, WHEEL, SEAT, ENGINE, TANK, CARGO,
		LIGHT, ROOF_LIGHT, TURRET, CONTROLS, OTHER }
enum Look { SOLID, GLASS, WHEEL }

const DECK := 0.55     # metres above the square's floor: top of the frame, the floor inside
const TOP := 2.0       # top of the walls: taller than a real car, so the eyes (1.6 m) fit under the roof
const ROOF_T := 0.1
const SILL := 1.05     # glass starts here
const MAX_PER_LOOK := 1 << 17
const DEFAULT_COLOR := Color(0.55, 0.56, 0.58)
const TYRE := Color(0.1, 0.1, 0.11)
const GLASS := Color(0.62, 0.8, 0.9, 0.3)
const RUST := Color(0.45, 0.26, 0.14)
const CHAR := Color(0.12, 0.11, 0.1)
const LIT := Color(1.0, 0.95, 0.75)
const MAX_NAME := 60
const LIGHT_FLAGS := ["CONE_LIGHT", "WIDE_CONE_LIGHT", "HALF_CIRCLE_LIGHT", "CIRCLE_LIGHT"]
## How high an item lies on a part of each kind that doesn't block (m above the floor); kinds not listed add nothing.
const REST := {Kind.FRAME: DECK, Kind.HALF: SILL, Kind.WHEEL: 0.8, Kind.TANK: 0.25, Kind.SEAT: DECK + 0.45,
		Kind.CARGO: DECK + 0.5, Kind.ENGINE: DECK + 0.6, Kind.OTHER: DECK + 0.5}

var view_z_max := CddaCoords.Z_LIMIT   # levels above are hidden: WorldView.things_z_max() (main.gd, refresh)
var _world: WorldView = null   # the world last applied (refresh follows its cutaway)
var _layers := {}      # Look -> MultiMeshInstance3D
var _counts := {}      # Look -> instances drawn by the last apply
var _drawn := {}       # Look -> [[Transform3D, Color], ...] drawn by the last apply (what the MultiMeshes hold)
static var _shapes := {}       # Kind -> [[Look, AABB], ...], made once
static var _mats := {}         # Look -> Material


func _init() -> void:
	name = "Vehicles"


## Instances drawn after the last apply: all of them, or one look's.
func count(look := -1) -> int:
	if look >= 0:
		return _counts.get(look, 0)
	var n := 0
	for k: int in _counts:
		n += _counts[k]
	return n


## What the last apply drew of one look: [[transform, colour], ...], as its MultiMesh holds them (headless runs
## can't read a MultiMesh back).
func instances(look: int) -> Array:
	return _drawn.get(look, [])


func apply(snap: Snapshot, world: WorldView) -> void:
	_world = world
	var by_look := {}   # Look -> [[Transform3D, Color], ...]
	if snap != null:
		for veh in snap.vehicles:
			var turn := Basis(Vector3.UP, -deg_to_rad(veh.face_deg))
			for i in veh.part_count():
				var k := i * Snapshot.VPART_STRIDE
				if veh.pos.z + veh.parts[k + 7] > view_z_max:
					continue
				var def := def_of(world.tables, snap, veh.parts[k + 2])
				var kind := kind_of(def, veh.parts[k + 4])
				if kind == Kind.NONE:
					continue
				place(by_look, kind, color_of(kind, def, veh.parts[k + 3], veh.parts[k + 4]),
						world.coords.ms_center_to_world(veh.square(i)), turn, (veh.parts[k + 4] & Snapshot.VPART_BROKEN) != 0)
	_counts.clear()
	_drawn = by_look
	for look: int in _layers.keys():
		if not by_look.has(look):
			(_layers[look] as Node).free()
			_layers.erase(look)
	for look: int in by_look:
		var mi: MultiMeshInstance3D = _layers.get(look)
		if mi == null:
			mi = _layer(look)
			add_child(mi)
			_layers[look] = mi
		var xs: Array = by_look[look]
		var mm := mi.multimesh
		mm.instance_count = xs.size()
		for j in xs.size():
			mm.set_instance_transform(j, xs[j][0])
			mm.set_instance_color(j, xs[j][1])
		_counts[look] = xs.size()


## Each frame: a cutaway change (WorldView.things_z_max) redraws at once, not on the next snapshot.
func _process(_delta: float) -> void:
	refresh()


## Follows the cutaway of the world last applied: redraws its snapshot when things_z_max() moved.
func refresh() -> void:
	if _world == null or not is_instance_valid(_world) or _world.snapshot == null:
		return
	var z := _world.things_z_max()
	if z != view_z_max:
		view_z_max = z
		apply(_world.snapshot, _world)


func shift(d: Vector3) -> void:
	for mi: MultiMeshInstance3D in _layers.values():
		mi.position += d


## Adds the boxes of one part of kind `kind` on the square whose floor centre is `at` (world), turned by `turn`, to
## by_look (Look -> [[transform, colour], ...], MAX_PER_LOOK per look at most). A box's transform scales a unit mesh
## to its size. Broken glass is left out.
static func place(by_look: Dictionary, kind: int, col: Color, at: Vector3, turn: Basis, broken := false) -> void:
	for sh: Array in shapes(kind):
		var look: int = sh[0]
		if look == Look.GLASS and broken:
			continue
		var list: Array = by_look.get(look, [])
		if list.size() >= MAX_PER_LOOK:
			continue
		var box: AABB = sh[1]
		var b := turn * Basis.from_scale(box.size)
		if look == Look.WHEEL:
			b = b * Basis(Vector3.RIGHT, PI / 2)   # the cylinder's axis across the vehicle
		list.append([Transform3D(b, at + turn * box.get_center()), GLASS if look == Look.GLASS else col])
		by_look[look] = list


## The boxes a kind of part is drawn with: [[Look, AABB], ...] in the part's own frame (x ahead, y up, z to the
## right, the square's floor centre at 0).
static func shapes(kind: int) -> Array:
	if _shapes.is_empty():
		var s := Look.SOLID
		var full := func(y0: float, y1: float) -> AABB: return AABB(Vector3(-0.5, y0, -0.5), Vector3(1.0, y1 - y0, 1.0))
		_shapes = {
			Kind.NONE: [],
			Kind.FRAME: [[s, full.call(0.25, DECK)]],
			Kind.BOARD: [[s, full.call(DECK, TOP)]],
			Kind.HALF: [[s, full.call(DECK, SILL)]],
			Kind.WINDOW: [[s, full.call(DECK, SILL)], [Look.GLASS, full.call(SILL, TOP)]],
			Kind.DOOR: [[s, AABB(Vector3(-0.45, DECK, -0.45), Vector3(0.9, TOP - DECK, 0.9))]],
			Kind.GLASS_DOOR: [[s, AABB(Vector3(-0.45, DECK, -0.45), Vector3(0.9, SILL - DECK, 0.9))],
					[Look.GLASS, AABB(Vector3(-0.45, SILL, -0.45), Vector3(0.9, TOP - SILL, 0.9))]],
			Kind.DOOR_OPEN: [[s, AABB(Vector3(-0.45, DECK, -0.5), Vector3(0.9, TOP - DECK, 0.08))]],
			Kind.ROOF: [[s, full.call(TOP, TOP + ROOF_T)]],
			Kind.WHEEL: [[Look.WHEEL, AABB(Vector3(-0.4, 0.0, -0.15), Vector3(0.8, 0.8, 0.3))]],
			Kind.SEAT: [[s, AABB(Vector3(-0.3, DECK, -0.35), Vector3(0.65, 0.45, 0.7))],
					[s, AABB(Vector3(-0.42, DECK, -0.35), Vector3(0.14, 1.1, 0.7))]],
			Kind.ENGINE: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.6, 0.8))]],
			Kind.TANK: [[s, AABB(Vector3(-0.35, 0.05, -0.35), Vector3(0.7, 0.2, 0.7))]],
			Kind.CARGO: [[s, AABB(Vector3(-0.4, DECK, -0.4), Vector3(0.8, 0.5, 0.8))]],
			Kind.LIGHT: [[s, AABB(Vector3(0.35, 0.85, -0.1), Vector3(0.15, 0.2, 0.2))]],
			Kind.ROOF_LIGHT: [[s, AABB(Vector3(-0.15, TOP + ROOF_T, -0.15), Vector3(0.3, 0.2, 0.3))]],
			Kind.TURRET: [[s, AABB(Vector3(-0.25, TOP + ROOF_T, -0.25), Vector3(0.5, 0.3, 0.5))],
					[s, AABB(Vector3(0.25, TOP + ROOF_T + 0.1, -0.05), Vector3(0.6, 0.1, 0.1))]],
			Kind.CONTROLS: [[s, AABB(Vector3(0.1, 1.0, -0.2), Vector3(0.3, 0.25, 0.4))]],
			Kind.OTHER: [[s, AABB(Vector3(-0.25, DECK, -0.25), Vector3(0.5, 0.5, 0.5))]],
		}
	return _shapes.get(kind, [])


## The kind of a part from its definition and state (Snapshot.VPART_* bits): OTHER for a part the tables don't
## know, NONE for one not drawn (armour plating, seatbelts, locks, batteries and the like).
static func kind_of(def: IdTables.Def, state: int) -> int:
	if def == null:
		return Kind.OTHER
	var f := def.flags
	if f.has("WHEEL"):
		return Kind.WHEEL
	if f.has("DOOR") or (f.has("OPENABLE") and f.has("OBSTACLE")):
		if (state & Snapshot.VPART_OPEN) != 0:
			return Kind.DOOR_OPEN
		return Kind.GLASS_DOOR if f.has("WINDOW") and not f.has("OPAQUE") else Kind.DOOR
	if f.has("WINDOW"):
		return Kind.WINDOW
	if f.has("ROOF") or def.location == "roof":
		return Kind.ROOF
	if f.has("TURRET"):
		return Kind.TURRET
	if f.has("SEAT") or f.has("BED"):
		return Kind.SEAT
	if f.has("ENGINE"):
		return Kind.ENGINE
	if f.has("CONTROLS"):
		return Kind.CONTROLS
	if f.has("FULL_BOARD") or (f.has("OBSTACLE") and f.has("OPAQUE")):
		return Kind.BOARD
	if f.has("HALF_BOARD") or f.has("OBSTACLE"):
		return Kind.HALF
	for l: String in LIGHT_FLAGS:
		if f.has(l):
			return Kind.ROOF_LIGHT if def.location == "on_roof" else Kind.LIGHT
	if f.has("FLUIDTANK"):
		return Kind.TANK
	if f.has("CARGO") and def.location == "center":
		return Kind.CARGO
	if def.location == "structure":
		return Kind.FRAME
	return Kind.NONE


## A part's colour: its CDDA colour (CddaPalette), tyres black, lights bright while on; then as damaged() shows it.
## Glass is always GLASS.
static func color_of(kind: int, def: IdTables.Def, hp: int, state: int) -> Color:
	var c := CddaPalette.fg(def.color, DEFAULT_COLOR) if def != null else DEFAULT_COLOR
	if kind == Kind.WHEEL:
		c = TYRE
	elif kind == Kind.LIGHT or kind == Kind.ROOF_LIGHT:
		c = LIT if (state & Snapshot.VPART_ENABLED) != 0 else DEFAULT_COLOR
	return damaged(c, hp, state)


## `c` as a part with hp_frac `hp` (0..255) and state `state` shows it: rustier and darker the more it is damaged,
## charred when broken.
static func damaged(c: Color, hp: int, state: int) -> Color:
	var out: Color
	if (state & Snapshot.VPART_BROKEN) != 0:
		out = c.lerp(CHAR, 0.75)
	else:
		var dmg := 1.0 - clampf(hp / 255.0, 0.0, 1.0)
		out = c.lerp(RUST, 0.7 * dmg).darkened(0.35 * dmg)
	out.a = c.a
	return out


## The vpart definition of index `vpart`: null when the tables don't hold it or are of another generation than the
## snapshot's ids (the index means something else).
static func def_of(tables: IdTables, snap: Snapshot, vpart: int) -> IdTables.Def:
	if tables == null or (snap != null and snap.ids_generation >= 0 and snap.ids_generation != tables.generation):
		return null
	return tables.def_at("vpart", vpart)


## Whether a vehicle part keeps you from walking onto square p, as CDDA's vehicle::obstacle_at_part: the first part
## there that has OBSTACLE and isn't broken blocks, unless it opens and is open. Parts the tables don't know don't.
static func blocks(snap: Snapshot, tables: IdTables, p: Vector3i) -> bool:
	if snap == null:
		return false
	var at := snap.vehicle_at(p)
	if at.is_empty():
		return false
	var veh: Snapshot.Vehicle = at[0]
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		var def := def_of(tables, snap, veh.parts[k + 2])
		var state := veh.parts[k + 4]
		if def != null and def.flags.has("OBSTACLE") and (state & Snapshot.VPART_BROKEN) == 0:
			return not (def.flags.has("OPENABLE") and (state & Snapshot.VPART_OPEN) != 0)
	return false


## The heights (m above the floor) a kind of part is drawn between: Vector2(bottom, top); ZERO when not drawn.
static func span_of(kind: int) -> Vector2:
	var out := Vector2.ZERO
	for sh: Array in shapes(kind):
		var box: AABB = sh[1]
		out = Vector2(box.position.y, box.end.y) if out == Vector2.ZERO \
				else Vector2(minf(out.x, box.position.y), maxf(out.y, box.end.y))
	return out


## The vehicle part on square p that a look meets at height h (m above the square's floor): of the parts drawn there
## whose span holds h the narrowest (a seat before the wall around it), open doors left out (you look past them).
## [Vehicle, part index], or [] where none is.
static func part_at(snap: Snapshot, tables: IdTables, p: Vector3i, h: float) -> Array:
	if snap == null:
		return []
	var at := snap.vehicle_at(p)
	if at.is_empty():
		return []
	var veh: Snapshot.Vehicle = at[0]
	var best := -1
	var best_w := INF
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		var kind := kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4])
		if kind == Kind.DOOR_OPEN:
			continue
		var sp := span_of(kind)
		if sp != Vector2.ZERO and h >= sp.x and h <= sp.y and sp.y - sp.x < best_w:
			best = i
			best_w = sp.y - sp.x
	return [veh, best] if best >= 0 else []


## The top of what is drawn of a vehicle on square p (m above its floor), 0 where nothing is.
static func top_at(snap: Snapshot, tables: IdTables, p: Vector3i) -> float:
	var at := snap.vehicle_at(p) if snap != null else []
	if at.is_empty():
		return 0.0
	var veh: Snapshot.Vehicle = at[0]
	var top := 0.0
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		top = maxf(top, span_of(kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4])).y)
	return top


## How high an item dropped on square p lies on the vehicle there (m above the floor; 0 where none is): on top of
## the parts (top_at) where they block walking, else on the highest seat, cargo, engine, wheel or frame (REST): in
## the car, under its roof.
static func rest_at(snap: Snapshot, tables: IdTables, p: Vector3i) -> float:
	if blocks(snap, tables, p):
		return top_at(snap, tables, p)
	var at := snap.vehicle_at(p) if snap != null else []
	if at.is_empty():
		return 0.0
	var veh: Snapshot.Vehicle = at[0]
	var h := 0.0
	for i: int in at[1]:
		var k := i * Snapshot.VPART_STRIDE
		h = maxf(h, REST.get(kind_of(def_of(tables, snap, veh.parts[k + 2]), veh.parts[k + 4]), 0.0))
	return h


## "<vehicle>: <part>" for look-at (part_label), "vehicle" for a vehicle with no name.
static func part_name(snap: Snapshot, tables: IdTables, veh: Snapshot.Vehicle, i: int) -> String:
	return "%s: %s" % [veh.name if not veh.name.is_empty() else "vehicle", part_label(snap, tables, veh, i)]


## Part i of a vehicle in words: its name as plain text (CddaText.plain), "part" when the tables don't know it,
## " (broken)" after it when broken.
static func part_label(snap: Snapshot, tables: IdTables, veh: Snapshot.Vehicle, i: int) -> String:
	var def := def_of(tables, snap, veh.parts[i * Snapshot.VPART_STRIDE + 2])
	var part := CddaText.plain(def.name if def != null and not def.name.is_empty() else "part").left(MAX_NAME)
	if (veh.parts[i * Snapshot.VPART_STRIDE + 4] & Snapshot.VPART_BROKEN) != 0:
		part += " (broken)"
	return part


static func _layer(look: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	if look == Look.WHEEL:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5
		cyl.bottom_radius = 0.5
		cyl.height = 1.0
		cyl.radial_segments = 12
		cyl.rings = 1
		mm.mesh = cyl
	else:
		mm.mesh = BoxMesh.new()
	var mi := MultiMeshInstance3D.new()
	mi.name = Look.keys()[look].to_lower()
	mi.multimesh = mm
	mi.material_override = _material(look)
	if look == Look.GLASS:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _material(look: int) -> Material:
	var m: StandardMaterial3D = _mats.get(look)
	if m == null:
		m = StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.roughness = 0.75 if look != Look.GLASS else 0.1
		if look == Look.GLASS:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.render_priority = WorldLighting.UNDER_PRIORITY   # darkened by the light pass with what is behind it
		_mats[look] = m
	return m
