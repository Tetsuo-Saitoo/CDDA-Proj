class_name MockItems
extends RefCounted
## Blocks E6 / L2 / L8: the item backend for mock mode (no bridge). The same calls as LiveSession (take_item,
## put_item, drop_item, queued_actions) with the bridge's rules in simple form (contracts/bridge_api.md "Single
## items"), editing the mock Snapshot in place. Like the bridge, malformed calls return false and change nothing;
## every accepted call ends in a new capture (snap.seq + 1, `changed`), and a refusal first says why with
## `message` (CDDA's m_info) and changes no item. It answers inside the call: the caller re-applies the snapshot
## to the world on `changed` and passes it on to ItemActions.on_snapshot.
## Simplified: no weight, volume or pocket limits; what goes into a container lying on the ground isn't listed.

## Why a call was refused (CDDA's m_info message); `changed` follows.
signal message(text: String)
## The snapshot was captured again (seq + 1): re-apply it to the world.
signal changed(snap: Snapshot)

const FIRST_UID := 1_000_000
const HS := Snapshot.HANDLE_STRIDE
const CS := Snapshot.CARRIED_STRIDE
const PS := Snapshot.PILE_STRIDE

var snap: Snapshot
var tables: IdTables
var _next_uid := FIRST_UID


func _init(s: Snapshot, t: IdTables) -> void:
	snap = s
	tables = t


## A `message` event (contracts/events.md) for ItemActions.on_events.
static func message_event(text: String) -> Dictionary:
	return {"kind": "message", "type": ItemActions.M_INFO, "text": text}


## Can items be put into an itype? The id tables' pocket count when they have one, else category "container".
static func is_container(type: int, t: IdTables) -> bool:
	var def: IdTables.Def = t.def_at("itype", type) if t != null else null
	if def == null:
		return false
	if "pockets" in def:
		var n: Variant = def.get("pockets")
		return (n is int or n is float) and n > 0
	return def.category == "container"


## Gives every pile without handles one handle per non-zero top itype (up to its count), spot -1. Returns how
## many it added.
func seed() -> int:
	if snap == null:
		return 0
	_next_uid = maxi(_next_uid, _max_uid() + 1)
	var added := 0
	for sm: Snapshot.Submap in snap.submaps.values():
		var has := {}
		for i in range(0, sm.handles.size() - HS + 1, HS):
			has[sm.handles[i]] = true
		var h := sm.handles
		for p in range(0, sm.items.size() - PS + 1, PS):
			var tile := sm.items[p]
			if has.has(tile):
				continue
			var n := 0
			for k in range(2, Snapshot.PILE_TOP_END):
				var t := sm.items[p + k]
				if t > 0 and n < sm.items[p + 1] and n < Snapshot.MAX_HANDLES_PER_TILE:
					h.append_array(PackedInt64Array([tile, _next_uid, t, -1, -1]))
					_next_uid += 1
					n += 1
			added += n
		sm.handles = h
	return added


## Take from a pile handle on `pos` (in reach) into the pack (the first worn container, else on the body),
## the main hand (refused while it holds something) or the off hand.
func take_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not _pos_ok(pos) or not (hand in ItemActions.HANDS):
		return false
	if not _in_reach(pos):
		return _refuse("You can't reach that from here.")
	var sm := _submap(pos)
	var tile := ItemActions.tile_of(pos)
	var h := ItemActions.handle_index(sm, tile, u, t)
	if h < 0:
		return _refuse("That isn't there any more.")
	if snap.carried.size() / CS >= Snapshot.MAX_CARRIED:
		return _refuse("There's no room in your inventory for the %s." % _name(t))
	var flags := 0
	var parent := 0
	var pocket := -1
	var at := snap.carried.size() / CS
	if hand == "main":
		var w := _flagged(Snapshot.CARRIED_WIELDED)
		if w >= 0:
			return _refuse("Your hand is full: you're holding your %s." % _name(snap.carried[w * CS + 1]))
		flags = Snapshot.CARRIED_WIELDED
		at = 0   # wielded first
	else:
		if hand == "off":
			if _flagged(Snapshot.CARRIED_OFFHAND) >= 0:
				return _refuse("Your off hand is full.")
			flags = Snapshot.CARRIED_OFFHAND
		var bag := _worn_container()
		if bag >= 0:
			parent = snap.carried[bag * CS]
			pocket = 0
			at = _subtree_end(bag)
	_remove_handle(sm, tile, h)
	_insert_rows(at, PackedInt64Array([u, t, parent, pocket, flags]))
	if hand == "main":
		snap.player_wielded = t
	_touch(sm)
	return _captured()


## Put a carried item into a container: a carried one, else the one lying on `pos` (in reach).
func put_item(uid: float, type: float, container: float, container_type: float, pos: Vector3i,
		pocket := -1) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	var cu := _uid(container)
	var ct := _type(container_type)
	if snap == null or u <= 0 or t <= 0 or cu <= 0 or ct <= 0 or not _pos_ok(pos) or pocket < -1 \
			or pocket > Snapshot.MAX_POCKET:
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	var flags := snap.carried[row * CS + 4]
	if flags & Snapshot.CARRIED_WORN:
		return _refuse("Take off your %s first." % _name(t))
	var crow := ItemActions.carried_row(snap, cu, ct)
	var sm: Snapshot.Submap = null
	if crow < 0:
		if not _in_reach(pos):
			return _refuse("You can't reach that from here.")
		sm = _submap(pos)
		if ItemActions.handle_index(sm, ItemActions.tile_of(pos), cu, ct) < 0:
			return _refuse("That container isn't there any more.")
	if cu == u or (crow >= 0 and _subtree(row).has(cu)):
		return _refuse("You can't put your %s inside itself." % _name(t))
	if not is_container(ct, tables):
		return _refuse("Could not put %s into %s, it can't hold anything." % [_name(t), _name(ct)])
	var moved := _remove_subtree(row)
	if crow >= 0:
		moved[2] = cu
		moved[3] = maxi(pocket, 0)
		moved[4] = flags & ~(Snapshot.CARRIED_WIELDED | Snapshot.CARRIED_OFFHAND)
		_insert_rows(_subtree_end(ItemActions.carried_row(snap, cu, ct)), moved)
	else:
		_touch(sm)
	if flags & Snapshot.CARRIED_WIELDED:
		snap.player_wielded = 0
	return _captured()


## Drop a carried item (with what is inside it) on `pos` (in reach); `spot` each 0..1 is kept in permille.
func drop_item(uid: float, type: float, pos: Vector3i, spot := Vector2(-1, -1)) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not _pos_ok(pos) or is_nan(spot.x) or is_nan(spot.y):
		return false
	var sx := -1
	var sy := -1
	if spot.x >= 0.0 and spot.y >= 0.0:
		if spot.x > 1.0 or spot.y > 1.0:
			return false
		sx = mini(int(spot.x * 1000.0), 999)
		sy = mini(int(spot.y * 1000.0), 999)
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	var flags := snap.carried[row * CS + 4]
	if flags & Snapshot.CARRIED_WORN:
		return _refuse("Take off your %s first." % _name(t))
	if not _in_reach(pos):
		return _refuse("You can't reach that from here.")
	var sm := _submap(pos)
	if sm == null:
		return _refuse("You can't put your %s there." % _name(t))
	var tile := ItemActions.tile_of(pos)
	var p := _pile(sm, tile)
	if _handles_on(sm, tile) >= Snapshot.MAX_HANDLES_PER_TILE \
			or (p >= 0 and sm.items[p + 1] >= Snapshot.MAX_ITEM_COUNT):
		return _refuse("There's no room for your %s there." % _name(t))
	_remove_subtree(row)
	if flags & Snapshot.CARRIED_WIELDED:
		snap.player_wielded = 0
	_add_handle(sm, tile, u, t, sx, sy)
	_touch(sm)
	return _captured()


## The bridge's action queue: the mock answers at once.
func queued_actions() -> int:
	return 0


func _refuse(text: String) -> bool:
	message.emit(text)
	return _captured()


func _captured() -> bool:
	snap.seq += 1
	changed.emit(snap)
	return true


## A uid from the bridge's float argument: an integer in 1 .. 2^53 - 1, else -1.
static func _uid(v: float) -> int:
	if not is_finite(v) or v != floorf(v) or v < 1.0 or v >= float(Snapshot.MAX_UID):
		return -1
	return int(v)


static func _type(v: float) -> int:
	if not is_finite(v) or v != floorf(v) or v < 1.0 or v > float(Snapshot.MAX_ID):
		return -1
	return int(v)


static func _pos_ok(p: Vector3i) -> bool:
	return ItemActions.ok_square(p)


## The player's square or one of the eight around it, same z.
func _in_reach(p: Vector3i) -> bool:
	var d := p - snap.player_pos
	return d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1


func _submap(p: Vector3i) -> Snapshot.Submap:
	return snap.submaps.get(CddaCoords.ms_to_sm(p))


func _name(t: int) -> String:
	var d: IdTables.Def = tables.def_at("itype", t) if tables != null else null
	if d == null:
		return "item"
	return d.name if not d.name.is_empty() else d.id


func _touch(sm: Snapshot.Submap) -> void:
	if sm != null:
		sm.detail_revision = (sm.detail_revision + 1) & Snapshot.MAX_REVISION


func _max_uid() -> int:
	var m := 0
	for sm: Snapshot.Submap in snap.submaps.values():
		for i in range(0, sm.handles.size() - HS + 1, HS):
			m = maxi(m, sm.handles[i + 1])
	for i in range(0, snap.carried.size() - CS + 1, CS):
		m = maxi(m, snap.carried[i])
	return m


## First carried row with `flag`, -1 if none.
func _flagged(flag: int) -> int:
	for i in range(0, snap.carried.size() - CS + 1, CS):
		if snap.carried[i + 4] & flag:
			return i / CS
	return -1


func _worn_container() -> int:
	for i in range(0, snap.carried.size() - CS + 1, CS):
		if snap.carried[i + 4] & Snapshot.CARRIED_WORN and is_container(snap.carried[i + 1], tables):
			return i / CS
	return -1


## Uids (-> true) of carried row `row` and everything inside it (containers are listed before their contents).
func _subtree(row: int) -> Dictionary:
	var c := snap.carried
	var inside := {c[row * CS]: true}
	for i in range((row + 1) * CS, c.size() - CS + 1, CS):
		if inside.has(c[i + 2]):
			inside[c[i]] = true
	return inside


## The row after `row`'s contents (depth first, they follow it).
func _subtree_end(row: int) -> int:
	var c := snap.carried
	var inside := {c[row * CS]: true}
	var i := row + 1
	while i * CS < c.size() and inside.has(c[i * CS + 2]):
		inside[c[i * CS]] = true
		i += 1
	return i


## Removes row `row` and its contents from carried; returns their rows in order.
func _remove_subtree(row: int) -> PackedInt64Array:
	var inside := _subtree(row)
	var keep := PackedInt64Array()
	var gone := PackedInt64Array()
	var c := snap.carried
	for i in range(0, c.size() - CS + 1, CS):
		if inside.has(c[i]):
			gone.append_array(c.slice(i, i + CS))
		else:
			keep.append_array(c.slice(i, i + CS))
	snap.carried = keep
	return gone


func _insert_rows(at: int, rows: PackedInt64Array) -> void:
	var c := snap.carried
	var out := c.slice(0, at * CS)
	out.append_array(rows)
	out.append_array(c.slice(at * CS))
	snap.carried = out


## Index into sm.items of the pile on `tile`, -1 if none.
static func _pile(sm: Snapshot.Submap, tile: int) -> int:
	for p in range(0, sm.items.size() - PS + 1, PS):
		if sm.items[p] == tile:
			return p
	return -1


static func _handles_on(sm: Snapshot.Submap, tile: int) -> int:
	var n := 0
	for i in range(0, sm.handles.size() - HS + 1, HS):
		if sm.handles[i] == tile:
			n += 1
	return n


func _remove_handle(sm: Snapshot.Submap, tile: int, h: int) -> void:
	var a := sm.handles
	for k in HS:
		a.remove_at(h * HS)
	sm.handles = a
	var p := _pile(sm, tile)
	if p < 0:
		return
	var items := sm.items
	if items[p + 1] <= 1:
		for k in PS:
			items.remove_at(p)
		sm.items = items
		return
	items[p + 1] -= 1
	sm.items = items
	_refresh_top(sm, tile)


func _add_handle(sm: Snapshot.Submap, tile: int, u: int, t: int, sx: int, sy: int) -> void:
	var a := sm.handles
	a.append_array(PackedInt64Array([tile, u, t, sx, sy]))
	sm.handles = a
	var items := sm.items
	var p := _pile(sm, tile)
	if p < 0:
		items.append_array(PackedInt32Array([tile, 1, t, 0, 0, 0, 0, 0]))
		sm.items = items
		return
	items[p + 1] = mini(items[p + 1] + 1, Snapshot.MAX_ITEM_COUNT)
	sm.items = items
	_refresh_top(sm, tile)


## The pile's top4 from the handles on its tile, largest volume first. Items without a handle (more than the
## handles) are of unknown types: the old top types stay in then.
func _refresh_top(sm: Snapshot.Submap, tile: int) -> void:
	var p := _pile(sm, tile)
	if p < 0:
		return
	var items := sm.items
	var types: Array[int] = []
	var n := 0
	for i in range(0, sm.handles.size() - HS + 1, HS):
		if sm.handles[i] == tile:
			n += 1
			if not (sm.handles[i + 2] in types):
				types.append(sm.handles[i + 2])
	if items[p + 1] > n:
		for k in range(2, Snapshot.PILE_TOP_END):
			if items[p + k] > 0 and not (items[p + k] in types):
				types.append(items[p + k])
	types.sort_custom(_bigger)
	for k in 4:
		items[p + 2 + k] = types[k] if k < types.size() else 0
	sm.items = items


## Sorts larger volume first, then lower index.
func _bigger(a: int, b: int) -> bool:
	var va := _volume(a)
	var vb := _volume(b)
	return va > vb or (va == vb and a < b)


func _volume(t: int) -> int:
	var d: IdTables.Def = tables.def_at("itype", t) if tables != null else null
	return d.volume_ml if d != null else 0
