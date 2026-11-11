class_name InventoryModel
extends RefCounted
## Blocks E6 / L8: what the Tab inspect view lists, as plain data with no UI, so the flat-screen view
## (ui/InspectView) and a VR one build from the same columns. Built from the newest snapshot through an
## ItemPicker (carried items, worn containers, ground handles in reach), the id tables (names, weight, volume)
## and ItemActions (what is in flight). Nothing here decides anything: moves go through Hands / ItemActions and
## the sim judges them. Names come from game data: control characters are stripped and lengths capped.
##
## columns() returns, in order:
##   "hands"   wielded (group "main") and off hand (group "off"), each with what is inside it;
##   "worn:<uid>" one per worn container, outermost first: its contents grouped by pocket (key = pocket index);
##   "loose"   carried items on the body outside any container (only when there are some);
##   "nearby"  ground items on the squares in reach, grouped by square (key = Vector3i; "here" always listed).
## A column: {id, kind ("hands" | "worn" | "loose" | "nearby"), title, container (ItemRef, worn only, else null),
##   square (Vector3i: the reach square for "nearby", else the player's), groups: [{key, title, rows, weight_g,
##   volume_ml}], weight_g, volume_ml (everything listed in it, nested items too), rows (rows kept), cut (rows left
##   out by MAX_ROWS)}.
## A row: {uid, item (ItemRef), name, weight_g, volume_ml (one item of the itype; a stack counts as one), pending
##   (an action is in flight), depth (0 = right in the group; 1 = inside a carried container listed above it ...),
##   is_container, note ("" or why its contents aren't listed)}.

const MAX_ROWS := 200            # rows per column; the rest only count in `cut` (and the totals)
const MAX_NAME := 60             # characters of an item name
const MAX_TITLE := 80            # characters of a column / group title
const MAX_COLUMNS := 12          # worn containers listed
const MAX_DEPTH := 8             # nesting listed (the bridge sends 8 deep)
const MAX_ITEM := 1_000_000_000  # one item's grams / millilitres are clamped to this
const GROUND_NOTE := "contents not listed yet"
## Squares in reach by offset from the reach square, in listing order.
const SQUARES := [
	[Vector2i(0, 0), "here"], [Vector2i(0, -1), "north"], [Vector2i(1, -1), "north-east"],
	[Vector2i(1, 0), "east"], [Vector2i(1, 1), "south-east"], [Vector2i(0, 1), "south"],
	[Vector2i(-1, 1), "south-west"], [Vector2i(-1, 0), "west"], [Vector2i(-1, -1), "north-west"],
]


## Every column (see above); [] without a picker or a snapshot. `actions` may be null (nothing pending).
static func columns(picker: ItemPicker, tables: IdTables, actions: ItemActions) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if picker == null or picker.world == null or picker.world.snapshot == null:
		return out
	var snap := picker.world.snapshot
	var all := picker.carried()
	var kids := {}   # parent uid -> Array[ItemRef], in carried order
	for r in all:
		if not kids.has(r.parent):
			kids[r.parent] = []
		(kids[r.parent] as Array).append(r)
	var hands := _column("hands", "hands", "Hands", snap.player_pos)
	var main := _group(hands, "main", "main hand")
	var off := _group(hands, "off", "off hand")
	var loose := _column("loose", "loose", "On you (no container)", snap.player_pos)
	var on_body := _group(loose, 0, "on you")
	var seen := {}
	var worn := picker.worn_containers()
	var worn_uids := {}
	for c in worn:
		worn_uids[c.uid] = true
	for r: ItemRef in kids.get(0, []):
		if r.is_wielded():
			_add_tree(hands, main, r, 0, kids, tables, actions, seen)
		elif r.is_off_hand():
			_add_tree(hands, off, r, 0, kids, tables, actions, seen)
		elif not r.is_worn() and not worn_uids.has(r.uid):
			_add_tree(loose, on_body, r, 0, kids, tables, actions, seen)
	out.append(hands)
	if worn.size() > MAX_COLUMNS:
		push_warning("inspect: %d worn containers, listing the first %d" % [worn.size(), MAX_COLUMNS])
	for i in mini(worn.size(), MAX_COLUMNS):
		out.append(_worn_column(worn[i], kids, tables, actions, seen, snap.player_pos))
	if loose["rows"] + loose["cut"] > 0:
		out.append(loose)
	out.append(_nearby_column(picker, tables, actions))
	return out


## The column with `id` in `cols`, {} if none.
static func find_column(cols: Array, id: String) -> Dictionary:
	for c: Dictionary in cols:
		if c.get("id") == id:
			return c
	return {}


## The row of item `uid` in `cols`, {} if none.
static func find_row(cols: Array, uid: int) -> Dictionary:
	for c: Dictionary in cols:
		for g: Dictionary in c["groups"]:
			for r: Dictionary in g["rows"]:
				if r["uid"] == uid:
					return r
	return {}


## "657 g", "1.25 kg".
static func weight_text(g: int) -> String:
	return "%d g" % g if g < 1000 else "%.2f kg" % (g / 1000.0)


## "250 ml", "1.50 L".
static func volume_text(ml: int) -> String:
	return "%d ml" % ml if ml < 1000 else "%.2f L" % (ml / 1000.0)


## Text from game data for a plain Label: no colour tags, no control characters, at most `cap` characters.
static func clean(s: String, cap := MAX_NAME) -> String:
	var out := ""
	for c in CddaText.plain(s.left(cap * 4)).left(cap):
		var u := c.unicode_at(0)
		if u < 32:
			out += " "
		elif not CddaText.is_hidden(u):
			out += c
	return out.strip_edges()


# --- inside ---

static func _column(id: String, kind: String, title: String, square: Vector3i) -> Dictionary:
	return {"id": id, "kind": kind, "title": clean(title, MAX_TITLE), "container": null, "square": square,
			"groups": [], "weight_g": 0, "volume_ml": 0, "rows": 0, "cut": 0}


static func _group(col: Dictionary, key: Variant, title: String) -> Dictionary:
	var g := {"key": key, "title": clean(title, MAX_TITLE), "rows": [], "weight_g": 0, "volume_ml": 0}
	(col["groups"] as Array).append(g)
	return g


## A worn container's column: its direct contents grouped by pocket (lowest first), each with what is inside it.
static func _worn_column(c: ItemRef, kids: Dictionary, tables: IdTables, actions: ItemActions, seen: Dictionary,
		at: Vector3i) -> Dictionary:
	var col := _column("worn:%d" % c.uid, "worn", c.display_name(tables), at)
	col["container"] = c
	seen[c.uid] = true
	var by_pocket := {}
	for r: ItemRef in kids.get(c.uid, []):
		if not by_pocket.has(r.pocket):
			by_pocket[r.pocket] = []
		(by_pocket[r.pocket] as Array).append(r)
	# The type's own pockets (id tables) are listed even when empty, so items can be dropped into them; ones the
	# player can't use only when something is in them.
	var def: IdTables.Def = tables.def_at("itype", c.type) if tables != null else null
	var known: Array[Dictionary] = []
	if def != null:
		known = def.pockets   # read only: Defs never change after loading
	for p in known.size():
		if by_pocket.has(p) or not int(known[p]["flags"]) & IdTables.POCKET_FORBIDDEN:
			by_pocket[p] = by_pocket.get(p, [])
	var pockets := by_pocket.keys()
	pockets.sort()
	for p: int in pockets:
		var g := _group(col, p, pocket_title(known[p], p) if p >= 0 and p < known.size()
				else ("pocket %d" % (p + 1) if p >= 0 else "pocket ?"))
		for r: ItemRef in by_pocket[p]:
			_add_tree(col, g, r, 0, kids, tables, actions, seen)
	return col


## A pocket heading from its id tables entry: "holster (max 1.00 L, 2.00 kg)"; the name when sent, else
## "pocket N" / "holster N".
static func pocket_title(pocket: Dictionary, index: int) -> String:
	var flags := int(pocket.get("flags", 0))
	var title := clean(str(pocket.get("name", "")), MAX_NAME)
	if title.is_empty():
		title = "%s %d" % ["holster" if flags & IdTables.POCKET_HOLSTER else "pocket", index + 1]
	var cap := PackedStringArray()
	if int(pocket.get("volume_ml", 0)) > 0:
		cap.append(volume_text(mini(int(pocket["volume_ml"]), MAX_ITEM)))
	if int(pocket.get("max_weight_g", 0)) > 0:
		cap.append(weight_text(mini(int(pocket["max_weight_g"]), MAX_ITEM)))
	var notes := PackedStringArray()
	if not cap.is_empty():
		notes.append("max " + ", ".join(cap))
	if flags & IdTables.POCKET_WATERTIGHT:
		notes.append("watertight")
	if flags & IdTables.POCKET_AMMO_ONLY:
		notes.append("ammo only")
	elif flags & IdTables.POCKET_RESTRICTED:
		notes.append("some items only")
	if flags & IdTables.POCKET_FORBIDDEN:
		notes.append("can't use")
	return title + (" (%s)" % "; ".join(notes) if not notes.is_empty() else "")


## Ground items on the squares in reach, from the snapshot's handles (seen tiles only). A container lying there is
## listed with GROUND_NOTE: snapshots don't list what is inside it yet.
static func _nearby_column(picker: ItemPicker, tables: IdTables, actions: ItemActions) -> Dictionary:
	var snap := picker.world.snapshot
	var centre: Variant = picker.centre()
	var col := _column("nearby", "nearby", "Nearby", centre if centre is Vector3i else snap.player_pos)
	if not centre is Vector3i:
		return col
	for s: Array in SQUARES:
		var off: Vector2i = s[0]
		var sq: Vector3i = (centre as Vector3i) + Vector3i(off.x, off.y, 0)
		if not picker.in_reach(sq):
			continue
		var g := {}
		if off == Vector2i.ZERO:
			g = _group(col, sq, s[1])
		var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(sq))
		if sm == null:
			continue
		var tile := ItemActions.tile_of(sq)
		var hs := sm.handles
		for k in range(0, hs.size() - Snapshot.HANDLE_STRIDE + 1, Snapshot.HANDLE_STRIDE):
			if hs[k] != tile or hs[k + 1] <= 0 or hs[k + 2] <= 0:
				continue
			if g.is_empty():
				g = _group(col, sq, s[1])
			var r := ItemRef.on_square(hs[k + 1], int(hs[k + 2]), sq, int(hs[k + 3]), int(hs[k + 4]))
			var row := _row(r, 0, tables, actions, false)
			if row["is_container"]:
				row["note"] = GROUND_NOTE
			_add_row(col, g, row)
	return col


## Adds `r` and (carried) everything inside it, depth first. `seen` stops an item being listed twice.
static func _add_tree(col: Dictionary, g: Dictionary, r: ItemRef, depth: int, kids: Dictionary, tables: IdTables,
		actions: ItemActions, seen: Dictionary) -> void:
	if seen.has(r.uid) or depth > MAX_DEPTH:
		return
	seen[r.uid] = true
	_add_row(col, g, _row(r, depth, tables, actions, kids.has(r.uid)))
	for c: ItemRef in kids.get(r.uid, []):
		_add_tree(col, g, c, depth + 1, kids, tables, actions, seen)


static func _add_row(col: Dictionary, g: Dictionary, row: Dictionary) -> void:
	for d: Dictionary in [col, g]:
		d["weight_g"] = mini(int(d["weight_g"]) + int(row["weight_g"]), MAX_ITEM)
		d["volume_ml"] = mini(int(d["volume_ml"]) + int(row["volume_ml"]), MAX_ITEM)
	if col["rows"] >= MAX_ROWS:
		col["cut"] += 1
		return
	col["rows"] += 1
	(g["rows"] as Array).append(row)


static func _row(r: ItemRef, depth: int, tables: IdTables, actions: ItemActions, holds: bool) -> Dictionary:
	return {"uid": r.uid, "item": r, "name": clean(r.display_name(tables)),
			"weight_g": clampi(r.weight_g(tables), 0, MAX_ITEM), "volume_ml": clampi(r.volume_ml(tables), 0, MAX_ITEM),
			"pending": actions != null and actions.pending(r.uid) != "", "depth": depth,
			"is_container": holds or r.is_container(tables), "note": ""}
