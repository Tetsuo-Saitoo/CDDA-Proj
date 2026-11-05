class_name PropCatalog
extends RefCounted
## Decides how each furniture, trap and item id is shown: the registry's fallback chain
## (contracts/assets.md) over the id tables' definitions, cached per index. Steps 1-3 give a placeholder
## shape (PropShapes); billboards (step 4) don't exist yet, so the rest become glyph cards (step 5).
##
## Furniture categories for `generic_furniture_<category>`, in order: flower, sign, seat, table,
## container, shelf (from FLOWER, SIGN, CAN_SIT, FLAT_SURF, CONTAINER, PLACE_ITEM). Items use their
## itype category; traps have none.

const FURNITURE_CATEGORIES := [["FLOWER", "flower"], ["SIGN", "sign"], ["CAN_SIT", "seat"],
		["FLAT_SURF", "table"], ["CONTAINER", "container"], ["PLACE_ITEM", "shelf"]]
## Item size: the edge of a cube of its volume, made a bit larger to read at a distance, clamped.
const ITEM_MIN_M := 0.06
const ITEM_MAX_M := 0.45
const ITEM_GROW := 1.4


class Prop:
	var shape := ""            # "" = glyph card
	var step := AssetRegistry.Step.GLYPH
	var via := ""
	var main := Color.WHITE    # body (registry material, else the CDDA colour)
	var accent := Color.WHITE  # CDDA colour (foreground)
	var leaf := Color.WHITE    # CDDA background colour (plants carry leaves there)
	var symbol := "?"
	var scale := 1.0           # registry scale (items: also their size)
	var offset := Vector3.ZERO
	var random_yaw := false
	var height := 1.0          # blocks: from coverage and SHORT/TINY
	var groups := 0
	var connects_to := 0
	var rotates_to := 0
	var align_workbench := false
	var flat_surf := false
	var blocks := false        # impassable


var registry: AssetRegistry
var tables: IdTables
var _by_index := true
var _names := {}    # table -> {index -> name} from the snapshot
var _cache := {}    # table -> {index -> Prop}


func _init(reg: AssetRegistry) -> void:
	registry = reg


func set_tables(t: IdTables) -> void:
	tables = t if t != null and t.is_valid() else null
	_cache.clear()


func set_snapshot(snap: Snapshot) -> void:
	var by_index := tables != null and (snap.ids_generation < 0 or snap.ids_generation == tables.generation)
	var names := {"furn": snap.furn_names, "trap": snap.trap_names}
	if by_index != _by_index or (not by_index and names != _names):
		_cache.clear()
	_by_index = by_index
	_names = names


func clear() -> void:
	_cache.clear()


func furniture(index: int) -> Prop:
	return _lookup("furn", index)


func trap(index: int) -> Prop:
	return _lookup("trap", index)


func item(index: int) -> Prop:
	return _lookup("itype", index)


func _lookup(table: String, index: int) -> Prop:
	if not _cache.has(table):
		_cache[table] = {}
	var c: Dictionary = _cache[table]
	var p: Prop = c.get(index)
	if p == null:
		# Ids nothing defines or names share one entry, so a hostile snapshot can't grow the cache.
		if _def(table, index) == null and not (_names.get(table, {}) as Dictionary).has(index):
			index = -1
			p = c.get(index)
		if p == null:
			p = _make(table, index)
			c[index] = p
	return p


func _def(table: String, index: int) -> IdTables.Def:
	if tables == null:
		return null
	if _by_index:
		return tables.def_at(table, index)
	if table == "itype":
		return null   # the snapshot names no itypes: generic items until the tables match
	return tables.def_named(table, (_names.get(table, {}) as Dictionary).get(index, ""))


func _make(table: String, index: int) -> Prop:
	var kind: String = {"furn": "furniture", "trap": "trap", "itype": "item"}[table]
	var d := _def(table, index)
	var id: String = d.id if d != null else (_names.get(table, {}) as Dictionary).get(index, "")
	var p := Prop.new()
	var chain := PackedStringArray()
	var cats := PackedStringArray()
	if d != null:
		p.symbol = d.symbol if not d.symbol.is_empty() else "?"
		p.accent = CddaPalette.fg(d.color)
		p.leaf = CddaPalette.bg(d.color, CddaPalette.MATERIALS["foliage"])
		p.groups = d.groups
		p.connects_to = d.connects_to
		p.rotates_to = d.rotates_to
		p.align_workbench = d.has("ALIGN_WORKBENCH")
		p.flat_surf = d.has("FLAT_SURF")
		p.blocks = table == "furn" and d.move_cost < 0
		p.height = 0.3 if d.has("TINY") else (0.9 if d.has("SHORT") else clampf(d.coverage / 50.0, 0.5, 2.0))
		chain = _chain(table, d)
		if table == "furn":
			for fc: Array in FURNITURE_CATEGORIES:
				if d.has(fc[0]):
					cats.append(fc[1])
		elif table == "itype" and not d.category.is_empty():
			cats.append(d.category)
	p.main = p.accent
	var found := registry.find_prop(kind, id, chain, cats)
	if found.entry != null and PropShapes.has_shape(found.entry.placeholder):
		var e := found.entry
		p.shape = e.placeholder
		p.step = found.step
		p.via = found.via
		p.scale = e.scale
		p.offset = e.offset
		p.random_yaw = e.random_yaw
		if CddaPalette.MATERIALS.has(e.material):
			p.main = CddaPalette.material(e.material)
	if table == "itype":
		var edge := pow(maxf(d.volume_ml if d != null else 250, 1), 1.0 / 3.0) / 100.0 * ITEM_GROW
		p.scale *= clampf(edge, ITEM_MIN_M, ITEM_MAX_M)
	return p


## looks_like links of a definition, in order (max AssetRegistry.MAX_CHAIN, stops on a cycle). Links
## leave the table when an id isn't in it (a hedge looks like a terrain shrub); the chain ends there.
func _chain(table: String, d: IdTables.Def) -> PackedStringArray:
	var out := PackedStringArray()
	var seen := {d.id: true}
	var cur := d
	while out.size() < AssetRegistry.MAX_CHAIN and cur != null:
		var link := cur.looks_like
		if link.is_empty() or seen.has(link):
			break
		seen[link] = true
		out.append(link)
		cur = tables.def_named(table, link)
	return out
