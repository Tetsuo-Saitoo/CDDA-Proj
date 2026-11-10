class_name AssetRegistry
extends RefCounted
## The asset registry (contracts/assets.md): `fp3d_model` entries from assets/registry/**/*.json, and the
## fallback chain that finds art for a CDDA id.
##
## Registry files are hostile input too (mods will ship them): file count, depth, sizes, types and
## string lengths are capped; bad files and entries are skipped and listed in [member warnings].
## Art for props is a `model` that loads (ModelLibrary, from assets/models next to the registry folder)
## or a `placeholder` (a procedural shape, see PropShapes); terrain a `mesher` or a model that loads. A
## model that is missing or bad doesn't count: the entry's placeholder (or mesher) takes over, else the
## chain goes on. An entry's `material` tints its model (ModelLibrary.get_tinted).

const MAX_FILE_BYTES := 4 << 20
const MAX_FILES := 256
const MAX_DEPTH := 4
const MAX_ENTRIES := 100000
const MAX_IDS_PER_ENTRY := 256
const MAX_STR := 128
## Steps 2 of the chain: looks_like links followed at most.
const MAX_CHAIN := 16
const KINDS := ["terrain", "furniture", "trap", "field", "item", "monster", "vehicle_part"]
const MESHERS := ["floor", "wall", "window", "door", "fence", "stairs_up", "stairs_down", "ramp",
		"water", "roof", "open_air"]

## Fallback steps (contracts/assets.md).
enum Step { EXACT = 1, LOOKS_LIKE = 2, GENERIC = 3, BILLBOARD = 4, GLYPH = 5 }


class Entry:
	var kind := ""
	var model := ""
	var mesher := ""
	var placeholder := ""
	var material := ""
	var scale := 1.0
	var offset := Vector3.ZERO
	var random_yaw := false


## Where the chain landed: the entry (null at the glyph step), the step and the id it was found under.
class Found:
	var entry: Entry
	var step := Step.GLYPH
	var via := ""


var warnings := PackedStringArray()
## Models of `model` paths; its root is set by the first load_dir (../models next to the registry).
var models := ModelLibrary.new()
var _entries := {}   # id -> {kind -> Entry}
var _count := 0


func entry(id: String, kind: String) -> Entry:
	return (_entries.get(id, {}) as Dictionary).get(kind)


## Registry warnings and model warnings (models load on first use, so these grow as the world shows).
func all_warnings() -> PackedStringArray:
	return warnings + models.warnings


## The entry's model, tinted toward its `material` when that is a palette material (one cached variant per
## model and material, ModelLibrary.get_tinted); null when it has none or it doesn't load.
func model_of(e: Entry) -> ModelLibrary.Model:
	return null if e == null or e.model.is_empty() else models.get_tinted(e.model, e.material)


## Whether the entry's model loads (no tinted variant is made for asking).
func model_loads(e: Entry) -> bool:
	return e != null and not e.model.is_empty() and models.get_model(e.model) != null


## Whether the client can show this entry as a prop: a placeholder, or a model that loads.
func has_art(e: Entry) -> bool:
	return e != null and (not e.placeholder.is_empty() or model_loads(e))


## Whether the client can show this entry as terrain: a mesher, or a model that loads.
func has_terrain_art(e: Entry) -> bool:
	return e != null and (not e.mesher.is_empty() or model_loads(e))


## Follows the chain for a prop-like id: exact entry of this kind, then the `looks_like` chain
## (an entry of any kind with art, e.g. a hedge that looks like a terrain shrub), then
## `generic_<kind>_<category>` for each category in order, then `generic_<kind>`. Steps 4 (billboards)
## and 5 (glyph cards) are the caller's. `chain` is the looks_like ids to try, in order.
func find_prop(kind: String, id: String, chain: PackedStringArray, categories: PackedStringArray) -> Found:
	var f := Found.new()
	var e := entry(id, kind)
	if has_art(e):
		return _found(f, e, Step.EXACT, id)
	for link in chain:
		var by_kind: Dictionary = _entries.get(link, {})
		e = by_kind.get(kind)
		if not has_art(e):
			e = null
			for k: String in by_kind:
				if has_art(by_kind[k]):
					e = by_kind[k]
					break
		if e != null:
			return _found(f, e, Step.LOOKS_LIKE, link)
	for c in categories:
		var g := "generic_%s_%s" % [kind, c]
		e = entry(g, kind)
		if has_art(e):
			return _found(f, e, Step.GENERIC, g)
	e = entry("generic_" + kind, kind)
	if has_art(e):
		return _found(f, e, Step.GENERIC, "generic_" + kind)
	return f


func _found(f: Found, e: Entry, step: Step, via: String) -> Found:
	f.entry = e
	f.step = step
	f.via = via
	return f


## Loads every *.json under dir (depth and count capped). Missing dir: a warning, no entries.
func load_dir(dir_path: String) -> void:
	if models.root.is_empty():
		models.root = dir_path.simplify_path().get_base_dir().path_join("models")
	var files := PackedStringArray()
	_collect(dir_path, 0, files)
	for f in files:
		_load_file(f)


func _collect(dir_path: String, depth: int, out: PackedStringArray) -> void:
	if depth > MAX_DEPTH:
		return
	var da := DirAccess.open(dir_path)
	if da == null:
		warnings.append("registry: cannot open %s" % dir_path)
		return
	var names := da.get_files()
	names.sort()
	for name in names:
		if name.ends_with(".json"):
			if out.size() >= MAX_FILES:
				warnings.append("registry: more than %d files, rest skipped" % MAX_FILES)
				return
			out.append(dir_path.path_join(name))
	var dirs := da.get_directories()
	dirs.sort()
	for sub in dirs:
		_collect(dir_path.path_join(sub), depth + 1, out)


func _load_file(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		warnings.append("registry: cannot open %s" % path)
		return
	if f.get_length() > MAX_FILE_BYTES:
		warnings.append("registry: %s is larger than %d bytes, skipped" % [path, MAX_FILE_BYTES])
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not json.data is Array:
		warnings.append("registry: %s is not a JSON list, skipped" % path)
		return
	for v: Variant in json.data:
		_count += 1
		if _count > MAX_ENTRIES:
			warnings.append("registry: more than %d entries, rest skipped" % MAX_ENTRIES)
			return
		if not v is Dictionary or _str(v.get("type")) != "fp3d_model":
			continue
		var e := _entry(v)
		if e == null:
			warnings.append("registry: %s: bad entry skipped (%s)" % [path, _describe(v)])
			continue
		var ids: Variant = v.get("id")
		var list: Array = [ids] if ids is String else (ids if ids is Array else [])
		if list.is_empty() or list.size() > MAX_IDS_PER_ENTRY:
			warnings.append("registry: %s: bad id list, entry skipped" % path)
			continue
		for id: Variant in list:
			if _is_id(id):
				if not _entries.has(id):
					_entries[id] = {}
				_entries[id][e.kind] = e


## A checked entry, or null. Unknown fields are ignored (the schema forbids them; the client needn't).
func _entry(d: Dictionary) -> Entry:
	var e := Entry.new()
	e.kind = _str(d.get("kind"))
	e.model = _str(d.get("model"))
	e.mesher = _str(d.get("mesher"))
	e.placeholder = _str(d.get("placeholder"))
	e.material = _str(d.get("material"))
	if not e.kind in KINDS:
		return null
	if not e.mesher.is_empty() and not e.mesher in MESHERS:
		return null
	for s: String in [e.placeholder, e.material]:
		if s.length() > MAX_STR or not _is_word(s):
			return null
	if e.model.length() > 200 or e.model.contains("..") or (not e.model.is_empty() and not e.model.ends_with(".glb")):
		return null
	if e.model.is_empty() and e.mesher.is_empty() and e.placeholder.is_empty():
		return null
	var sc: Variant = d.get("scale", 1.0)
	if not (sc is float or sc is int) or not (float(sc) > 0.0 and float(sc) <= 100.0):
		return null
	e.scale = float(sc)
	var off: Variant = d.get("offset", [0, 0, 0])
	if not off is Array or (off as Array).size() != 3:
		return null
	for i in 3:
		var x: Variant = off[i]
		if not (x is float or x is int) or not (float(x) >= -10.0 and float(x) <= 10.0):
			return null
		e.offset[i] = float(x)
	var ry: Variant = d.get("random_yaw", false)
	if not ry is bool:
		return null
	e.random_yaw = ry
	return e


static func _str(v: Variant) -> String:
	return v if v is String else ""


static func _is_word(s: String) -> bool:
	for c in s:
		if not ((c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_"):
			return false
	return true


static func _is_id(v: Variant) -> bool:
	if not v is String or (v as String).is_empty() or (v as String).length() > MAX_STR:
		return false
	for c: String in v:
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in "_:-"):
			return false
	return true


static func _describe(d: Dictionary) -> String:
	var id: Variant = d.get("id")
	return (id as String).left(40) if id is String else "kind %s" % _str(d.get("kind")).left(20)
