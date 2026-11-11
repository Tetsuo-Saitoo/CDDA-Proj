extends RefCounted
## QA checks, run by run_tests.gd: stress and hostile input for the world view. The meshing job against
## main-thread catalog lookups, live door leaves across bubble shifts, kept door angles that are not numbers,
## oversized body part / covers / worn / carried lists, the player body's shared caches, embedded JPEG headers
## against Godot's own decoder, and model loads and tints from several threads at once.
## Members that older versions of the scripts lack are read with get(), so this file compiles against them.

const ModelTests := preload("res://tests/model_tests.gd")
const REGISTRY := "assets/registry"
const BODY_SCRIPT := "res://scripts/world/player_body.gd"
const BIG := 100000
const PARSE_BUDGET_US := 200000
const JOB_ROUNDS := 20
const SHIFT_ROUNDS := 50
const JPEG_ROUNDS := 400
const WALK_BUDGET_MS := 5000
const TINT_WORKERS := 6
const TINT_ROUNDS := 8
const TINT_TIMEOUT_MS := 30000

var _check: Callable


func run(root: Node, check: Callable, data: Variant, tables: IdTables) -> void:
	_check = check
	_job_stress(root, data, tables)
	_live_doors(root, data, tables)
	_door_angles(root)
	_body_parts(data)
	_covers(data, tables)
	_worn_and_carried(data, tables)
	_body_caches(data, tables)
	_jpeg_headers()
	_tint_threads()


static func _repo(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()


## A shallow copy of the mock with only the submaps in the box (deep copies, mock order).
static func _region(data: Variant, x0: int, x1: int, y0: int, y1: int, z0: int, z1: int) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(false)
	var sms := []
	for s: Dictionary in (data as Dictionary)["submaps"]:
		var p: Array = s["pos"]
		if int(p[0]) >= x0 and int(p[0]) <= x1 and int(p[1]) >= y0 and int(p[1]) <= y1 \
				and int(p[2]) >= z0 and int(p[2]) <= z1:
			sms.append(s.duplicate(true))
	d["submaps"] = sms
	return d


## The same data with the bubble one submap east: the west column leaves (shares the submap dictionaries).
static func _east(d: Dictionary) -> Dictionary:
	var o: Array = d["bubble_origin"]
	var x := int(o[0]) + 1
	var s := d.duplicate(false)
	s["bubble_origin"] = [x, o[1], o[2]]
	s["submaps"] = (d["submaps"] as Array).filter(func(sm: Dictionary) -> bool: return int(sm["pos"][0]) >= x)
	return s


## The mock's player and header only (no submaps, no creatures): parse times measure the player alone.
static func _player_only(data: Variant) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(false)
	d["submaps"] = []
	d["creatures"] = []
	d["player"] = ((data as Dictionary)["player"] as Dictionary).duplicate(true)
	return d


static func _submap(d: Dictionary, pos: Vector3i) -> Dictionary:
	for s: Dictionary in d["submaps"]:
		if Vector3i(int(s["pos"][0]), int(s["pos"][1]), int(s["pos"][2])) == pos:
			return s
	return {}


# --- Meshing job (worker) against main-thread lookups ---------------------------------------------------

static func _worker_running(w: WorldView) -> bool:
	var t: Variant = w.get("_task")
	return t is int and t >= 0 and not WorkerThreadPool.is_task_completed(t)


## Main-thread lookups over every id, each pass starting from empty caches (so every lookup writes them).
static func _hammer(w: WorldView, tables: IdTables, n_ter: int, n_furn: int, n_item: int) -> void:
	w.catalog.set_tables(tables)
	w.props.set_tables(tables)
	for id in n_ter:
		w.catalog.style_for(id)
	for id in n_furn:
		w.props.furniture(id)
	for id in n_item:
		w.props.item(id)
	for id: int in [-5, 99999, Snapshot.MAX_ID]:
		w.catalog.style_for(id)
		w.props.furniture(id)
		w.props.trap(id)
		w.props.item(id)


static func _fields(o: Object, names: Array) -> Array:
	var out := []
	for n: String in names:
		out.append(o.get(n))
	return out


const STYLE_FIELDS := ["kind", "color", "color2", "state", "height", "glass", "locked", "groups", "connects_to",
		"model", "scale", "offset", "random_yaw", "ramp_low"]
const PROP_FIELDS := ["model", "shape", "step", "via", "main", "accent", "leaf", "symbol", "scale", "offset",
		"random_yaw", "height", "groups", "connects_to", "rotates_to", "align_workbench", "flat_surf", "blocks"]


## The main catalogs answer every id like catalogs made fresh for the snapshot shown.
static func _same_as_fresh(w: WorldView, tables: IdTables, n_ter: int, n_furn: int, n_item: int) -> bool:
	var cat := TerrainCatalog.new()
	cat.registry = w.catalog.registry
	cat.set_tables(tables)
	cat.set_snapshot(w.snapshot)
	var pc := PropCatalog.new(w.catalog.registry)
	pc.set_tables(tables)
	pc.set_snapshot(w.snapshot)
	for id in n_ter:
		if _fields(w.catalog.style_for(id), STYLE_FIELDS) != _fields(cat.style_for(id), STYLE_FIELDS):
			return false
	for id in n_furn:
		if _fields(w.props.furniture(id), PROP_FIELDS) != _fields(pc.furniture(id), PROP_FIELDS):
			return false
	for id in n_item:
		if _fields(w.props.item(id), PROP_FIELDS) != _fields(pc.item(id), PROP_FIELDS):
			return false
	return true


## The main catalogs point at this snapshot (TerrainCatalog / PropCatalog.set_snapshot keep its name tables).
static func _catalogs_on(w: WorldView, snap: Snapshot) -> bool:
	var pn: Variant = w.props.get("_names")
	return snap != null and is_same(w.catalog.get("_names"), snap.ter_names) and pn is Dictionary \
			and is_same((pn as Dictionary).get("furn"), snap.furn_names)


func _job_stress(root: Node, data: Variant, tables: IdTables) -> void:
	print("qa: meshing job against main-thread catalog lookups")
	var t0 := Time.get_ticks_msec()
	var w := WorldView.new()
	w.mesh_on_worker = true   # also headless: this test is about the worker; only lookups on this thread meanwhile
	w.catalog.load_registry_dir(_repo(REGISTRY))
	root.add_child(w)
	w.set_id_tables(tables)
	var d := _region(data, 11, 16, 27, 32, -1, 1)
	var east := _east(d)
	# Odd rounds: ids of another generation (looked up by name), with floor and wall names swapped, so a style
	# cached under the other mode answers differently.
	var floor_id := tables.index_of("ter", "t_floor")
	var wall_id := tables.index_of("ter", "t_wall_w")
	var swapped: Dictionary = (d["ids"] as Dictionary).duplicate(true)
	swapped["ter"][str(floor_id)] = "t_wall_w"
	swapped["ter"][str(wall_id)] = "t_floor"
	var first := Snapshot.from_data(d)
	_check.call(first.is_valid() and first.submaps.size() == 108, "qa job: region of 108 submaps " + first.error)
	w.apply_snapshot(first)
	var t_built := Time.get_ticks_msec()
	var n_ter := tables.ter.size() + 16
	var n_furn := tables.furn.size() + 16
	var n_item := mini(tables.itype.size(), 400) + 16
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261110
	var held := true       # main catalogs kept the shown snapshot while the worker meshed the next
	var followed := true   # and moved to each snapshot as it was shown
	var same := true
	var busy := true
	var passes := 0        # lookup passes made while the worker was still meshing
	var timed_out := false
	for r in JOB_ROUNDS:
		var sms: Array = d["submaps"]
		for k in 3:
			var s: Dictionary = sms[rng.randi_range(0, sms.size() - 1)]
			s["revision"] = int(s["revision"]) + 1
		var src: Dictionary = (east if r % 4 == 1 else d).duplicate(false)
		if r % 2 == 1:
			src["ids_generation"] = tables.generation + 1
			src["ids"] = swapped
		var snap := Snapshot.from_data(src)
		if not snap.is_valid():
			_check.call(false, "qa job: round %d snapshot valid %s" % [r, snap.error])
			break
		var shown := w.snapshot
		w.submit(snap)
		busy = busy and w.busy()
		var n := 0
		while n < 100 and _worker_running(w):
			_hammer(w, tables, n_ter, n_furn, n_item)
			n += 1
		passes += n
		var t_wait := Time.get_ticks_msec()
		while _worker_running(w):
			if Time.get_ticks_msec() - t_wait > 20000:
				timed_out = true
				break
			OS.delay_usec(200)
		held = held and _catalogs_on(w, shown) and not _catalogs_on(w, snap)
		var last := snap
		if r % 3 == 2:   # a second snapshot waits behind the one meshing
			var s2: Dictionary = sms[rng.randi_range(0, sms.size() - 1)]
			s2["revision"] = int(s2["revision"]) + 1
			last = Snapshot.from_data(src)
			w.submit(last)
		w.finish_pending()
		followed = followed and w.snapshot == last and _catalogs_on(w, last)
		if r % 5 == 4:
			same = same and _same_as_fresh(w, tables, n_ter, n_furn, n_item)
	var revs := true
	for pos: Vector3i in w.snapshot.submaps:
		revs = revs and w.built_revision(pos) == (w.snapshot.submaps[pos] as Snapshot.Submap).revision
	_check.call(busy and not timed_out, "qa job: %d rounds of submit, the worker finished each time" % JOB_ROUNDS)
	_check.call(held, "qa job: main catalogs keep the shown snapshot while the worker meshes the next")
	_check.call(followed, "qa job: main catalogs move to each snapshot when it is shown (waiting ones too)")
	_check.call(same, "qa job: main catalogs answer like fresh ones for the shown snapshot (both id modes)")
	_check.call(revs, "qa job: every shown submap is built at its revision after the rounds")
	var styles: Variant = w.catalog.get("_styles")
	_check.call(styles is Dictionary and (styles as Dictionary).size() <= tables.ter.size() + w.snapshot.ter_names.size() + 1,
			"qa job: main style cache stays bounded under lookups of undefined, negative and huge ids")
	print("        build %d ms, %d rounds %d ms, %d lookup passes while the worker meshed" % [t_built - t0,
			JOB_ROUNDS, Time.get_ticks_msec() - t_built, passes])
	w.free()


# --- Door leaves, live --------------------------------------------------------------------------------

static func _leaves_valid(w: WorldView) -> bool:
	for g: Variant in w.grabbables.values():
		if not is_instance_valid(g):
			return false
	return true


## Every submap _door_squares tracks is loaded, and every square it lists has a live leaf (false when the
## WorldView has no _door_squares).
static func _door_squares_loaded(w: WorldView) -> bool:
	var ds: Variant = w.get("_door_squares")
	if not ds is Dictionary or w.snapshot == null:
		return false
	for pos: Vector3i in ds:
		if not w.snapshot.submaps.has(pos):
			return false
		for sq: Vector3i in ds[pos]:
			if not is_instance_valid(w.grabbables.get(sq)):
				return false
	return true


static func _count_leaves(n: Node) -> int:
	var c := 1 if n is Grabbable else 0
	for k in n.get_children():
		c += _count_leaves(k)
	return c


func _live_doors(root: Node, data: Variant, tables: IdTables) -> void:
	print("qa: live door leaves across bubble shifts")
	var t0 := Time.get_ticks_msec()
	var w := WorldView.new()
	root.add_child(w)
	w.set_id_tables(tables)
	w.door_local = false
	var door_c := tables.index_of("ter", "t_door_c")
	var door_o := tables.index_of("ter", "t_door_o")
	_check.call(door_c > 0 and door_o > 0 and w.catalog.style_for(door_c).kind == TerrainCatalog.Kind.DOOR
			and w.catalog.style_for(door_o).kind == TerrainCatalog.Kind.DOOR, "qa doors: t_door_c and t_door_o are doors")
	var d := _region(data, 11, 12, 27, 27, 0, 0)
	d["bubble_origin"] = [11, 27, 0]
	var west := Vector3i(11, 27, 0)   # leaves the bubble when it moves east
	var stay := Vector3i(12, 27, 0)
	var smw := _submap(d, west)
	var sms := _submap(d, stay)
	smw["ter"][5 * 12 + 3] = door_c
	smw["ter"][5 * 12 + 8] = door_o
	sms["ter"][6 * 12 + 6] = door_c
	var sq_c := CddaCoords.sm_to_ms(west) + Vector3i(3, 5, 0)
	var sq_o := CddaCoords.sm_to_ms(west) + Vector3i(8, 5, 0)
	var sq_k := CddaCoords.sm_to_ms(stay) + Vector3i(6, 6, 0)
	var east := _east(d)
	var both := Snapshot.from_data(d)
	_check.call(both.is_valid() and both.submaps.size() == 2, "qa doors: two submaps " + both.error)
	w.apply_snapshot(both)
	var full := w.grabbables.size()
	_check.call(w.grabbables.has(sq_c) and w.grabbables.has(sq_o) and w.grabbables.has(sq_k),
			"qa doors: leaves made from the snapshot (%d)" % full)
	var left_c: Grabbable = w.grabbables.get(sq_c)
	var kept: Grabbable = w.grabbables.get(sq_k)
	left_c.set_angle(0.2)   # nudged, still under OPEN_AT
	kept.set_angle(0.25)
	w.apply_snapshot(Snapshot.from_data(east))
	_check.call(not w.door_state.has(sq_c) and not w.door_state.has(sq_o),
			"qa doors: live, leaves of a submap that left keep no state")
	_check.call(not w.grabbables.has(sq_c) and not w.grabbables.has(sq_o) and not is_instance_valid(left_c),
			"qa doors: their leaves are freed and unlisted")
	_check.call(_leaves_valid(w) and _door_squares_loaded(w), "qa doors: no freed leaf listed, tracked submaps all loaded")
	_check.call(is_same(w.grabbables.get(sq_k), kept) and w.door_state.has(sq_k)
			and is_equal_approx(float(w.door_state[sq_k].get("angle", -1.0)), 0.25),
			"qa doors: a leaf on a submap that stays is the same node and keeps its angle")
	# Back, and meanwhile CDDA opened the nudged door: the leaf made again must stand open.
	smw["ter"][5 * 12 + 3] = door_o
	w.apply_snapshot(Snapshot.from_data(d))
	var again: Grabbable = w.grabbables.get(sq_c)
	_check.call(again != null and again.cdda_open and again.angle == Grabbable.OPEN_REST,
			"qa doors: a leaf made again stands where CDDA has it, not at a dropped leaf's angle (%s)"
			% (again.angle if again != null else NAN))
	smw["ter"][5 * 12 + 3] = door_c
	# One more door on the west submap that comes back on another square each time (rows 0..4: 50 squares).
	var moving := func(r: int) -> int: return (r % 5) * 12 + (r / 5) % 12
	var orig: Array = (smw["ter"] as Array).duplicate()
	smw["ter"][moving.call(0)] = door_c
	smw["revision"] = int(smw["revision"]) + 1   # loaded: rebuilt only for a new revision
	w.apply_snapshot(Snapshot.from_data(d))
	full = w.grabbables.size()
	var shifted := -1
	var max_state := 0
	var max_leaves := 0
	var sizes_ok := true
	var valid := true
	var nodes0 := 0
	for r in SHIFT_ROUNDS:
		for sq: Vector3i in w.grabbables:
			(w.grabbables[sq] as Grabbable).set_angle(0.1 + 0.01 * (r % 5))   # a kept state for every leaf
		w.apply_snapshot(Snapshot.from_data(east))
		if shifted < 0:
			shifted = w.grabbables.size()
		sizes_ok = sizes_ok and w.grabbables.size() == shifted
		valid = valid and _leaves_valid(w) and _door_squares_loaded(w)
		max_state = maxi(max_state, w.door_state.size())
		smw["ter"][moving.call(r)] = orig[moving.call(r)]
		smw["ter"][moving.call(r + 1)] = door_c
		w.apply_snapshot(Snapshot.from_data(d))
		sizes_ok = sizes_ok and w.grabbables.size() == full and _count_leaves(w) == full
		valid = valid and _leaves_valid(w) and _door_squares_loaded(w)
		max_state = maxi(max_state, w.door_state.size())
		max_leaves = maxi(max_leaves, w.grabbables.size())
		if r == 0:
			nodes0 = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var nodes1 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_check.call(sizes_ok and max_leaves == full and max_state <= full,
			"qa doors: %d shifts, leaves stay %d / %d, door_state at most %d" % [SHIFT_ROUNDS, full, shifted, max_state])
	_check.call(valid, "qa doors: no freed leaf listed and no unloaded submap tracked after any shift")
	_check.call(nodes1 == nodes0, "qa doors: node count steady over the shifts (%d -> %d)" % [nodes0, nodes1])
	# CDDA destroys the door that stays (same submap, newer revision): its leaf and state go.
	kept = w.grabbables.get(sq_k)
	sms["ter"][6 * 12 + 6] = tables.index_of("ter", "t_floor")
	sms["revision"] = int(sms["revision"]) + 1
	w.apply_snapshot(Snapshot.from_data(d))
	_check.call(not w.grabbables.has(sq_k) and not w.door_state.has(sq_k) and not is_instance_valid(kept)
			and _leaves_valid(w), "qa doors: live, a door CDDA removed loses its leaf and state")
	print("        %d shifts in %d ms" % [SHIFT_ROUNDS * 2, Time.get_ticks_msec() - t0])
	w.free()


## Kept angles that are not finite numbers (or out of the leaf's range) never reach the leaf.
func _door_angles(root: Node) -> void:
	print("qa: kept door angles that are not numbers")
	var w := WorldView.new()
	root.add_child(w)
	w.door_local = false
	var sq := Vector3i(-700, -700, 0)
	for open: bool in [false, true]:
		for bad: float in [NAN, INF, -INF, 1e30]:
			var d := {"square": sq, "local": Vector3.ZERO, "along_x": true, "color": Color.GRAY, "glass": false,
					"open": open, "locked": false}
			w.door_state[sq] = {"angle": bad}
			var g := Grabbable.door(w, d)
			var what := "%s door, kept angle %s" % ["open" if open else "closed", "1e30" if is_finite(bad) else str(bad)]
			if is_finite(bad):
				_check.call(absf(g.angle) <= Grabbable.MAX_ANGLE,
						"qa doors: %s: the leaf stays within MAX_ANGLE (%s)" % [what, "1e30" if absf(g.angle) == 1e30 else str(g.angle)])
			else:
				_check.call(is_finite(g.angle) and g.transform.is_finite(),
						"qa doors: %s: the leaf's angle and transform are finite (%s)" % [what, g.angle])
			g.free()
	# A drag that works out a NaN angle (a hand position that is not a number) must not reach the leaf either.
	w.door_state.erase(sq)
	var leaf := Grabbable.door(w, {"square": sq, "local": Vector3.ZERO, "along_x": true, "color": Color.GRAY,
			"glass": false, "open": false, "locked": false})
	leaf.set_angle(NAN)
	var kept: Variant = (w.door_state.get(sq, {}) as Dictionary).get("angle", 0.0)
	_check.call(is_finite(leaf.angle) and leaf.transform.is_finite() and kept is float and is_finite(kept),
			"qa doors: set_angle(NAN) leaves the leaf and its kept angle finite (%s)" % leaf.angle)
	leaf.free()
	w.free()


# --- Snapshot: body parts, covers, worn, carried ------------------------------------------------------

## Parses and returns [snapshot, microseconds].
static func _timed(d: Dictionary) -> Array:
	var t := Time.get_ticks_usec()
	var s := Snapshot.from_data(d)
	return [s, Time.get_ticks_usec() - t]


func _body_parts(data: Variant) -> void:
	print("qa: hostile body part lists")
	var d := _player_only(data)
	var pl: Dictionary = d["player"]
	var ids: Array = (pl["body_parts"] as Array).duplicate()
	var n := ids.size()
	var keys := []
	for key: String in ["body_parts", "hp", "hp_max", "bleed", "bandaged", "disinfected", "bite", "infected"]:
		if pl.has(key):
			keys.append(key)
			var src: Array = pl[key]
			var col := []
			col.resize(BIG)
			for i in BIG:
				col[i] = src[i % n]
			pl[key] = col
	var r := _timed(d)
	var snap: Snapshot = r[0]
	var order := snap.player_parts.size() == Snapshot.MAX_BODY_PARTS
	for i in snap.player_parts.size():
		order = order and snap.player_parts[i].id == int(ids[i % n])
	_check.call(snap.is_valid() and order, "qa body: %d parts keep the first %d, in order %s" % [BIG,
			Snapshot.MAX_BODY_PARTS, snap.error])
	_check.call(r[1] < PARSE_BUDGET_US, "qa body: %d parts parse in %d ms" % [BIG, r[1] / 1000])
	var hp: Array = pl["hp"]
	pl["hp"] = hp.slice(0, BIG - 1)
	_check.call(not Snapshot.from_data(d).is_valid(), "qa body: a column one short of the parts is refused")
	pl["hp"] = hp.slice(0, Snapshot.MAX_BODY_PARTS)
	_check.call(not Snapshot.from_data(d).is_valid(), "qa body: a column the length of the cap (not of the list) is refused")
	pl["hp"] = {"0": 1}
	_check.call(not Snapshot.from_data(d).is_valid(), "qa body: a column that is no list is refused")
	pl["hp"] = hp
	hp[BIG - 1] = "junk"
	(pl["body_parts"] as Array)[BIG - 1] = -1
	var past := Snapshot.from_data(d)
	_check.call(past.is_valid() and past.player_parts.size() == Snapshot.MAX_BODY_PARTS,
			"qa body: bad values past the cap are ignored (not read) %s" % past.error)
	hp[3] = "junk"
	_check.call(not Snapshot.from_data(d).is_valid(), "qa body: a bad value inside the cap is refused")
	hp[3] = 10
	(pl["body_parts"] as Array)[3] = 1e30
	_check.call(not Snapshot.from_data(d).is_valid(), "qa body: a body part id out of range inside the cap is refused")


## One worn item with these covers: [snapshot, microseconds].
static func _with_covers(data: Variant, covers: Variant) -> Array:
	var d := _player_only(data)
	(d["player"] as Dictionary)["worn"] = [{"type": 5, "layer": 2, "covers": covers}]
	return _timed(d)


static func _covers_sane(snap: Snapshot) -> bool:
	if not snap.is_valid():
		return false
	for w: Snapshot.Worn in snap.player_worn:
		var seen := {}
		if w.covers.size() > Snapshot.MAX_BODY_PARTS:
			return false
		for x: int in w.covers:
			if seen.has(x) or x < 0 or x > Snapshot.MAX_ID:
				return false
			seen[x] = true
	return true


func _covers(data: Variant, tables: IdTables) -> void:
	print("qa: hostile covers lists")
	var big := []
	big.resize(BIG)
	for i in BIG:
		big[i] = i % 1000
	var d := _player_only(data)
	var worn := []
	for i in Snapshot.MAX_WORN:
		worn.append({"type": 1 + i, "layer": 2, "covers": big})   # one shared list: 64 x 100000 entries
	(d["player"] as Dictionary)["worn"] = worn
	var r := _timed(d)
	var snap: Snapshot = r[0]
	var first := PackedInt32Array(range(Snapshot.MAX_BODY_PARTS))
	_check.call(_covers_sane(snap) and snap.player_worn.size() == Snapshot.MAX_WORN
			and snap.player_worn.all(func(w: Snapshot.Worn) -> bool: return w.covers == first),
			"qa covers: %d worn x %d covers keep the first %d distinct parts %s" % [Snapshot.MAX_WORN, BIG,
			Snapshot.MAX_BODY_PARTS, snap.error])
	_check.call(r[1] < PARSE_BUDGET_US, "qa covers: %d x %d covers parse in %d ms" % [Snapshot.MAX_WORN, BIG, r[1] / 1000])
	var torso := tables.body_parts.find("torso")
	var same := []
	same.resize(BIG)
	same.fill(torso)
	var one: Snapshot = _with_covers(data, same)[0]
	_check.call(_covers_sane(one) and one.player_worn[0].covers == PackedInt32Array([torso]),
			"qa covers: %d copies of one part give it once" % BIG)
	# Bad entries: inside the scanned part of the list the snapshot is refused; past it they are never read.
	var scanned := Snapshot.MAX_BODY_PARTS * 4
	for bad: Variant in [-1, -1e9, 1.5, 1e30, NAN, INF, "torso", null, [1]]:
		var c := range(300)
		c[5] = bad
		_check.call(not (_with_covers(data, c)[0] as Snapshot).is_valid(),
				"qa covers: %s at index 5 is refused" % [bad])
		c[5] = 5
		c[scanned + 50] = bad
		var late: Snapshot = _with_covers(data, c)[0]
		_check.call(_covers_sane(late) and late.player_worn[0].covers == first,
				"qa covers: %s at index %d (past the %d read) is ignored" % [bad, scanned + 50, scanned])
	_check.call(not (_with_covers(data, {"0": 1})[0] as Snapshot).is_valid(), "qa covers: covers that is no list is refused")


func _worn_and_carried(data: Variant, tables: IdTables) -> void:
	print("qa: worn and carried lists past the caps")
	var torso := tables.body_parts.find("torso")
	var item := func(t: int) -> Dictionary: return {"type": t, "layer": 2, "covers": [torso]}
	for n: int in [Snapshot.MAX_WORN, Snapshot.MAX_WORN + 1, BIG]:
		var d := _player_only(data)
		var worn := []
		worn.resize(n)
		var filler: Dictionary = item.call(1)
		for i in n:
			worn[i] = item.call(1 + i) if i >= n - Snapshot.MAX_WORN else filler
		(d["player"] as Dictionary)["worn"] = worn
		var r := _timed(d)
		var snap: Snapshot = r[0]
		var outer := snap.player_worn.size() == mini(n, Snapshot.MAX_WORN)
		for i in snap.player_worn.size():
			outer = outer and snap.player_worn[i].type == n - snap.player_worn.size() + 1 + i
		_check.call(snap.is_valid() and outer, "qa worn: %d items keep the outer %d, in order %s" % [n,
				mini(n, Snapshot.MAX_WORN), snap.error])
		if n == BIG:
			_check.call(r[1] < PARSE_BUDGET_US, "qa worn: %d items parse in %d ms" % [BIG, r[1] / 1000])
	var d2 := _player_only(data)
	var w2 := []
	for i in Snapshot.MAX_WORN + 1:
		w2.append(item.call(1 + i))
	w2[0] = "junk"   # inner, past the cap: not read
	(d2["player"] as Dictionary)["worn"] = w2
	var s2 := Snapshot.from_data(d2)
	_check.call(s2.is_valid() and s2.player_worn.size() == Snapshot.MAX_WORN and s2.player_worn[0].type == 2,
			"qa worn: a bad inner item past the cap is ignored " + s2.error)
	w2[1] = "junk"   # inside the kept outer ones
	_check.call(not Snapshot.from_data(d2).is_valid(), "qa worn: a bad item among the kept ones is refused")

	var d := _player_only(data)
	var items := []
	items.resize(BIG)
	for i in BIG:
		items[i] = [i + 1, 1, 0, -1, 0]
	(d["player"] as Dictionary)["items"] = items
	var r := _timed(d)
	var snap: Snapshot = r[0]
	var stride := Snapshot.CARRIED_STRIDE
	var kept := snap.carried.size() == Snapshot.MAX_CARRIED * stride
	for i in snap.carried.size() / stride:
		kept = kept and snap.carried[i * stride] == i + 1
	_check.call(snap.is_valid() and kept, "qa carried: %d items keep the first %d, in order %s" % [BIG,
			Snapshot.MAX_CARRIED, snap.error])
	_check.call(r[1] < PARSE_BUDGET_US, "qa carried: %d items parse in %d ms" % [BIG, r[1] / 1000])
	items[Snapshot.MAX_CARRIED + 3] = ["junk"]
	items[Snapshot.MAX_CARRIED + 4] = [999999999, 1, 777, -1, 0]   # its container is never listed
	_check.call(Snapshot.from_data(d).is_valid(), "qa carried: bad items past the cap are ignored")
	items[7] = [8, 1, 300, -1, 0]   # inside the cap, in a container listed only past it
	_check.call(not Snapshot.from_data(d).is_valid(), "qa carried: an item whose container comes later is refused")


# --- Player body ----------------------------------------------------------------------------------

static func _meshes_of(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append([(n as MeshInstance3D).mesh, (n as MeshInstance3D).material_override])
	for c in n.get_children():
		_meshes_of(c, out)


func _body_caches(data: Variant, tables: IdTables) -> void:
	print("qa: player body layers and shared caches")
	var script := load(BODY_SCRIPT) as GDScript
	var consts := script.get_script_constant_map()
	var layers: int = consts.get("MAX_LAYERS", 6)
	var cached: int = consts.get("MAX_CACHED", 256)
	var d := _player_only(data)
	var pl: Dictionary = d["player"]
	var n := (pl["body_parts"] as Array).size()
	for key: String in ["bleed", "bandaged", "disinfected", "bite", "infected"]:
		if pl.has(key):
			var z := []
			z.resize(n)
			z.fill(0)
			pl[key] = z
	var every: Array = (pl["body_parts"] as Array).duplicate()   # every part the player has
	var worn := []
	for i in Snapshot.MAX_WORN:
		worn.append({"type": 1 + i, "layer": 2, "covers": every})
	pl["worn"] = worn
	var snap := Snapshot.from_data(d)
	var drawn := 0
	for b: Snapshot.BodyPart in snap.player_parts:
		if PlayerBody.PARTS.has(tables.body_part_name(b.id)):
			drawn += 1
	var plan := PlayerBody.plan(snap, tables)
	_check.call(snap.is_valid() and drawn > 0 and plan.size() <= drawn * (1 + layers),
			"qa body: %d worn items over every part draw %d pieces, at most %d parts x (1 + %d)" % [worn.size(),
			plan.size(), drawn, layers])
	for w: Dictionary in worn:
		w["damage"] = 5
	for key: String in ["bleed", "bandaged", "bite"]:
		var c := []
		c.resize(n)
		c.fill(9)
		pl[key] = c
	plan = PlayerBody.plan(Snapshot.from_data(d), tables)
	_check.call(plan.size() <= drawn * (1 + layers * 4) + drawn * 3,
			"qa body: torn and wounded, %d pieces stay bounded" % plan.size())

	var bodies: Array[PlayerBody] = []
	var max_mats := 0
	var max_boxes := -1
	var shared := true
	for i in 300:
		var wi := []
		for k in 1 + i % layers:
			wi.append({"type": 50000 + i * 8 + k, "layer": 2, "damage": (i + k) % 6, "degradation": (i * 7) % 256,
					"covers": every})
		pl["worn"] = wi
		var bl := []
		bl.resize(n)
		bl.fill(i % 21)
		pl["bleed"] = bl
		var b := PlayerBody.new()
		b.apply(Snapshot.from_data(d), tables)
		bodies.append(b)
		var mats: Variant = script.get("_mats")
		var boxes: Variant = script.get("_boxes")
		max_mats = maxi(max_mats, (mats as Dictionary).size() if mats is Dictionary else 1 << 30)
		max_boxes = maxi(max_boxes, (boxes as Dictionary).size() if boxes is Dictionary else 1 << 30)
	var first: Array = []
	_meshes_of(bodies[0], first)
	var colours := {}
	for p: Dictionary in bodies[0].pieces:
		colours[(p["colour"] as Color).to_html(false)] = true
	var drawn_cols := {}
	for e: Array in first:
		shared = shared and e[0] != null and e[1] != null
		if e[1] is StandardMaterial3D:
			drawn_cols[(e[1] as StandardMaterial3D).albedo_color.to_html(false)] = true
	_check.call(max_mats <= cached and max_boxes <= cached,
			"qa body: 300 bodies keep the shared caches at most %d (materials %d, boxes %d)" % [cached, max_mats, max_boxes])
	_check.call(not first.is_empty() and shared and drawn_cols == colours,
			"qa body: the first body keeps its meshes and materials after the caches start over")
	for b in bodies:
		b.free()


## Embedded JPEG headers: the size the model loader reads (ModelLibrary._image_size) is the size Godot's decoder
## makes. A real JPEG from Image.save_jpg_to_buffer gets odd segments put in front of its scan (APPn and COM with
## frames inside their data, a second frame, fill bytes, stuffed bytes, garbage, RSTn / TEM, unknown markers);
## whenever both read it, the sizes agree. Also: the walk stays inside the image's own bytes, every cut before the
## frame's end is unreadable, and long runs of fill bytes or tiny segments are walked in time.
func _jpeg_headers() -> void:
	print("qa: JPEG headers against the decoder")
	var src := Image.create(40, 24, false, Image.FORMAT_RGB8)
	src.fill(Color(0.4, 0.5, 0.6))
	var jpg := src.save_jpg_to_buffer(0.9)
	var bounds := PackedInt32Array()   # where a segment starts, from after SOI up to the scan
	var sof_end := -1
	var i := 2
	while i + 4 <= jpg.size() and jpg[i] == 0xFF and jpg[i + 1] != 0xDA:
		bounds.append(i)
		if jpg[i + 1] == 0xC0 or jpg[i + 1] == 0xC2:
			sof_end = i + 2 + ModelLibrary._be(jpg, i + 2, 2)
		i += 2 + ModelLibrary._be(jpg, i + 2, 2)
	bounds.append(i)
	var plain_ok := ModelLibrary._image_size(jpg, 0, jpg.size()) == Vector2i(40, 24) and sof_end > 0 \
			and i + 1 < jpg.size() and jpg[i + 1] == 0xDA
	_check.call(plain_ok, "qa jpeg: the encoder's own file reads 40 x 24 (%d segments before the scan)" % (bounds.size() - 1))
	if not plain_ok:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261110
	var walked := 0
	var decoded := 0
	var differ := PackedStringArray()
	# The decoder prints an error for each file it can't read; those are expected here, so they're kept out of
	# the run's error check while the loop runs.
	var printing := Engine.print_error_messages
	Engine.print_error_messages = false
	for r in JPEG_ROUNDS:
		var at := PackedInt32Array()
		for k in rng.randi_range(1, 3):
			at.append(bounds[rng.randi_range(0, bounds.size() - 1)])
		at.sort()
		var b := jpg.duplicate()
		var kinds := PackedStringArray()
		for k in range(at.size() - 1, -1, -1):
			var head := b.slice(0, at[k])
			head.append_array(_odd_segment(rng, kinds))
			head.append_array(b.slice(at[k]))
			b = head
		var claim := ModelLibrary._image_size(b, 0, b.size())
		if claim == Vector2i(-1, -1):
			continue
		walked += 1
		var img := Image.new()
		if img.load_jpg_from_buffer(b) != OK:
			continue
		decoded += 1
		if img.get_size() != claim and differ.size() < 4:
			differ.append("%s: header %s, decoded %s" % [",".join(kinds), claim, img.get_size()])
	Engine.print_error_messages = printing
	print("qa jpeg: %d of %d odd headers walked, %d of those decoded" % [walked, JPEG_ROUNDS, decoded])
	_check.call(differ.is_empty() and decoded >= 20,
			"qa jpeg: the header size matches the decoded size whenever both read the file " + str(differ))
	# the walk stays inside the image's view of the buffer
	var buf := PackedByteArray([1, 2, 3, 4, 5, 6, 7]) + jpg + jpg
	var view_ok := ModelLibrary._image_size(buf, 7, jpg.size()) == Vector2i(40, 24) \
			and ModelLibrary._image_size(buf, 7, sof_end - 1) == Vector2i(-1, -1) \
			and ModelLibrary._image_size(buf, 7, maxi(24, bounds[0])) == Vector2i(-1, -1)
	_check.call(view_ok, "qa jpeg: read at an offset inside the buffer; a view that ends before the frame's end is unreadable")
	var cuts_ok := true
	for n in range(2, sof_end + 1):
		var want := Vector2i(40, 24) if n >= sof_end else Vector2i(-1, -1)
		cuts_ok = cuts_ok and ModelLibrary._image_size(jpg, 0, n) == want
	_check.call(cuts_ok, "qa jpeg: every cut before the frame's end is unreadable, a cut after it reads the frame")
	# long walks: 256 KiB of fill bytes, then 256 KiB of empty COM segments, before the first segment
	var fill := PackedByteArray([0xFF])
	while fill.size() < 1 << 18:
		fill.append_array(fill)
	var coms := PackedByteArray([0xFF, 0xFE, 0, 2])
	while coms.size() < 1 << 18:
		coms.append_array(coms)
	for p: Array in [["fill bytes", fill], ["empty COM segments", coms]]:
		var long := jpg.slice(0, bounds[0])
		long.append_array(p[1])
		long.append_array(jpg.slice(bounds[0]))
		var t0 := Time.get_ticks_msec()
		var s := ModelLibrary._image_size(long, 0, long.size())
		var ms := Time.get_ticks_msec() - t0
		_check.call(s == Vector2i(40, 24) and ms < WALK_BUDGET_MS,
				"qa jpeg: 256 KiB of %s before the frame: walked in %d ms (budget %d)" % [p[0], ms, WALK_BUDGET_MS])
	# a small frame inside an APP segment's data is data: the real frame is read, and a big one is refused
	var hidden := PackedByteArray([0xFF, 0xD8, 0xFF, 0xE1, 0, 15, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0,
			0xFF, 0xC0, 0, 11, 8, 0x13, 0x88, 0x13, 0x88, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 0x3F, 0, 0xFF, 0xD9])
	var glb := ModelTests.glb_of({"asset": {"version": "2.0"}, "buffers": [{"byteLength": hidden.size()}],
			"bufferViews": [{"buffer": 0, "byteLength": hidden.size()}],
			"images": [{"bufferView": 0, "mimeType": "image/jpeg"}]}, hidden)
	_check.call(ModelLibrary._image_size(hidden, 0, hidden.size()) == Vector2i(5000, 5000)
			and not ModelLibrary.new().check_glb(glb).is_empty(),
			"qa jpeg: a frame inside an APP segment's data is skipped; the 5000 x 5000 frame after it is read and refused")


## One odd JPEG segment (or run of bytes) to put in front of the scan; appends its kind to `kinds`.
static func _odd_segment(rng: RandomNumberGenerator, kinds: PackedStringArray) -> PackedByteArray:
	var w := rng.randi_range(1, 6000)
	var h := rng.randi_range(1, 6000)
	var frame := PackedByteArray([0xFF, 0xC0, 0, 11, 8, h >> 8, h & 0xFF, w >> 8, w & 0xFF, 1, 1, 0x11, 0])
	var kind := rng.randi_range(0, 7)
	var out := PackedByteArray()
	match kind:
		0, 1:   # APPn or COM; half of them carry a frame inside their data
			var data := PackedByteArray()
			for k in rng.randi_range(0, 24):
				data.append(rng.randi_range(0, 255))
			if rng.randi_range(0, 1) == 1:
				var at := rng.randi_range(0, data.size())
				data = data.slice(0, at) + frame + data.slice(at)
			var mk := 0xE0 + rng.randi_range(0, 15) if kind == 0 else 0xFE
			out = PackedByteArray([0xFF, mk, (data.size() + 2) >> 8, (data.size() + 2) & 0xFF]) + data
			kinds.append("APPn" if kind == 0 else "COM")
		2:
			for k in rng.randi_range(1, 5):
				out.append(0xFF)
			kinds.append("fill")
		3:
			out = frame
			kinds.append("frame %dx%d" % [w, h])
		4:
			out = PackedByteArray([0xFF, 0x00])
			kinds.append("FF00")
		5:
			for k in rng.randi_range(1, 3):
				out.append(rng.randi_range(0, 0xFE))
			kinds.append("garbage")
		6:
			out = PackedByteArray([0xFF, 0x01 if rng.randi_range(0, 3) == 0 else 0xD0 + rng.randi_range(0, 7)])
			kinds.append("RST/TEM")
		_:
			var odd: Array = [0xC8, 0xDE, 0xDF, 0xF0 + rng.randi_range(0, 13), rng.randi_range(0x02, 0xBF)]
			var mk: int = odd[rng.randi_range(0, odd.size() - 1)]
			out = PackedByteArray([0xFF, mk, 0, 4, rng.randi_range(0, 255), rng.randi_range(0, 255)])
			kinds.append("marker %02X" % mk)
	return out


## Several workers load and tint the same two models at once from a fresh library while the main thread keeps
## asking it: every call finishes, each path (and path + material) gives one object to everyone, and the
## budgets count each kept model and variant once.
func _tint_threads() -> void:
	print("qa: model loads and tints from several threads")
	var paths := ["furniture/qa_a.glb", "furniture/qa_b.glb"]
	var mats := ["brick", "wood", "wood_dark", "metal"]
	var why := ""
	var spins := 0
	var ms := 0
	for rn in TINT_ROUNDS:
		var lib := SlowLib.new()
		var out: Array = []
		out.resize(TINT_WORKERS)
		var tasks: Array[int] = []
		for w in TINT_WORKERS:
			tasks.append(WorkerThreadPool.add_task(func() -> void:
				var got := []   # [key, object]
				for r in 2 * mats.size():   # every path with every material, in another order on each worker
					var p: String = paths[(w + r) % 2]
					got.append([p, lib.get_model(p)])
					var mat: String = mats[(w + (r >> 1)) % mats.size()]
					got.append([p + "|" + mat, lib.get_tinted(p, mat)])
				out[w] = got))
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < TINT_TIMEOUT_MS:
			var running := false
			for t in tasks:
				running = running or not WorkerThreadPool.is_task_completed(t)
			if not running:
				break
			lib.get_warnings()
			lib.get_model(paths[spins % 2])
			lib.get_tinted(paths[spins % 2], mats[spins % mats.size()])
			spins += 1
			OS.delay_usec(100)
		ms += Time.get_ticks_msec() - t0
		var finished := true
		for t in tasks:
			finished = finished and WorkerThreadPool.is_task_completed(t)
		if not finished:
			why = "round %d: still running after %d ms" % [rn, TINT_TIMEOUT_MS]
			break
		for t in tasks:
			WorkerThreadPool.wait_for_task_completion(t)
		var one := {}
		var same := true
		var tinted := true
		for got: Variant in out:
			for e: Array in got:
				var o: Object = e[1]
				same = same and o != null and one.get(e[0], o) == o
				one[e[0]] = o
				if o != null and (e[0] as String).contains("|"):
					tinted = tinted and (o as ModelLibrary.Model).tint == (e[0] as String).get_slice("|", 1)
		for k: String in one:
			var now: Object = lib.get_tinted(k.get_slice("|", 0), k.get_slice("|", 1)) if k.contains("|") \
					else lib.get_model(k)
			same = same and now == one[k]
		# what's counted toward the budgets: each kept model and variant once, never a copy another thread dropped
		var tris: int = lib._triangle_total
		var img: int = lib._image_bytes
		var want_tris := SlowLib.TRIANGLES * (paths.size() + paths.size() * mats.size())
		if not (same and tinted and one.size() == 2 + 2 * mats.size() and tris == want_tris
				and img == SlowLib.IMAGE_BYTES * paths.size()):
			why = "round %d: %d kept, same %s, tinted %s, triangles %d (want %d), image bytes %d %s" \
					% [rn, one.size(), same, tinted, tris, want_tris, img, str(lib.get_warnings())]
			break
	_check.call(why.is_empty(), ("qa tint: %d rounds of %d workers from a fresh library: all finish, each path and "
			+ "path + material is one object for every thread, budgets count each once (%d main-thread calls, %d ms) %s")
			% [TINT_ROUNDS, TINT_WORKERS, spins, ms, why])


## A library whose loads make an empty model after a short wait (no file, nothing for the renderer), so threads
## race on the cache, the tint table and the budgets only. Godot's headless renderer (all client tests) doesn't
## take textures or meshes from several threads at once, so real .glb loads can't race in a test.
class SlowLib extends ModelLibrary:
	const TRIANGLES := 7
	const IMAGE_BYTES := 1000

	func _load(rel: String) -> ModelLibrary.Model:
		OS.delay_usec(2000)
		var m := ModelLibrary.Model.new()
		m.path = rel
		m.triangles = TRIANGLES
		m.image_bytes = IMAGE_BYTES
		return m
