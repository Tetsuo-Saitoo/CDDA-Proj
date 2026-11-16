class_name SpawnSearch
extends RefCounted
## K7: finds item and monster types by name or id for the test range's spawn pickers, without any UI: the flat F1
## Cheats page (ui/cheat_panel.gd) and the VR page use the same results. Reads the live id tables, which are game
## data: names and ids are cleaned for display (no colour tags, no control characters, capped) and the query is
## capped. The lowered names are worked out once per id tables and kept.

const MAX_QUERY := 64
const MAX_RESULTS := 20
const MAX_TEXT := 64
const TABLES := ["itype", "mtype"]

static var _key := ""     # the id tables the cache below belongs to: instance id and generation
static var _rows := {}    # table -> [[index, lowered name, lowered id, name, id]]


## Up to `limit` (1..MAX_RESULTS) types of `table` ("itype" or "mtype") whose name or id holds every word of
## `query` (case ignored), best first: the exact id (also typed with spaces for _), the exact name, names starting with the query, a word of the
## name starting with it, the name holding it, then the id alone; within each, shorter names first, and of equal
## names the ones whose id holds the query too, shorter ids first.
## Each {index, id, name, text: "Name (id)"}; [] for an empty query, an unknown table or no tables.
static func find(tables: IdTables, table: String, query: String, limit := MAX_RESULTS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if tables == null or not table in TABLES:
		return out
	var q := " ".join(HudData.clean(query, MAX_QUERY).to_lower().split(" ", false))
	var words := q.split(" ", false)
	if words.is_empty():
		return out
	limit = clampi(limit, 1, MAX_RESULTS)
	var buckets := [[], [], [], [], [], []]
	for r: Array in _table_rows(tables, table):
		var lname: String = r[1]
		var lid: String = r[2]
		var all := true
		for w in words:
			if lname.find(w) < 0 and lid.find(w) < 0:
				all = false
				break
		if not all:
			continue
		var rank := 5
		if lid == q or lid.replace("_", " ") == q:   # "glock 19" is glock_19 ("Glock carry pistol")
			rank = 0
		elif lname == q:
			rank = 1
		elif lname.begins_with(q):
			rank = 2
		elif lname.find(" " + q) >= 0:
			rank = 3
		elif lname.find(q) >= 0:
			rank = 4
		# sort key: name length, name, the id holding the query too (CDDA names many types alike: of the "zombie"s,
		# mon_zombie before mon_pseudo_dormant_zombie or mon_zow), id length, id, then the row
		(buckets[rank] as Array).append([lname.length(), lname, 0 if lid.find(q) >= 0 else 1, lid.length(), lid, r])
	for b: Array in buckets:
		for e: Array in _best(b, limit - out.size()):
			var r: Array = e[5]
			var n: String = r[3] if not (r[3] as String).is_empty() else r[4]
			out.append({"index": r[0], "id": r[4], "name": n, "text": "%s (%s)" % [n, r[4]]})
		if out.size() >= limit:
			break
	return out


## The `k` best of `rows` (by their sort key, the first five fields) without sorting them all.
static func _best(rows: Array, k: int) -> Array:
	var top: Array = []
	if k <= 0:
		return top
	for r: Array in rows:
		if top.size() >= k and not _before(r, top.back()):
			continue
		top.insert(top.bsearch_custom(r, _before), r)
		if top.size() > k:
			top.pop_back()
	return top


static func _before(a: Array, b: Array) -> bool:
	for i in 5:
		if a[i] != b[i]:
			return a[i] < b[i]
	return (a[5] as Array)[0] < (b[5] as Array)[0]


static func _table_rows(tables: IdTables, table: String) -> Array:
	var key := "%d:%d" % [tables.get_instance_id(), tables.generation]
	if key != _key:
		_key = key
		_rows.clear()
	if not _rows.has(table):
		var rows: Array = []
		var defs: Array = tables.get(table)
		for i in range(1, defs.size()):   # 0 is CDDA's null type
			var d: IdTables.Def = defs[i]
			if d == null:
				continue
			var id := HudData.clean(d.id, MAX_TEXT)
			if id.is_empty():
				continue
			var n := HudData.clean(d.name, MAX_TEXT)
			rows.append([i, n.to_lower(), id.to_lower(), n, id])
		_rows[table] = rows
	return _rows[table]
