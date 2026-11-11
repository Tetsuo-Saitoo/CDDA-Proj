class_name MockItems
extends RefCounted
## Blocks E6 / L2 / L8: the item backend for mock mode (no bridge). The same calls as LiveSession (take_item,
## put_item, drop_item, queued_actions) with the bridge's rules in simple form (contracts/bridge_api.md "Single
## items"), editing the mock Snapshot in place. Like the bridge, malformed calls return false and change nothing;
## every accepted call ends in a new capture (snap.seq + 1, `changed`), and a refusal first says why with
## `message` (CDDA's m_info) and changes no item. It answers inside the call: the caller re-applies the snapshot
## to the world on `changed` and passes it on to ItemActions.on_snapshot.
## Simplified: no weight, volume or pocket limits (tests add their own with `put_check`); what goes into a
## container lying on the ground isn't listed.

## Why a call was refused (CDDA's m_info message); `changed` follows.
signal message(text: String)
## The snapshot was captured again (seq + 1): re-apply it to the world.
signal changed(snap: Snapshot)

const FIRST_UID := 1_000_000
const HS := Snapshot.HANDLE_STRIDE
const CS := Snapshot.CARRIED_STRIDE
const PS := Snapshot.PILE_STRIDE
const THROW_RANGE := 10   # squares

var snap: Snapshot
var tables: IdTables
var _next_uid := FIRST_UID
## Optional pocket rule for put_item, as CDDA's would refuse: (item_type: int, container_type: int, pocket: int)
## -> String, "" to allow, else the refusal message (e.g. "The rock is too big for the pocket."). Called only
## once the put is otherwise allowed; nothing moves when it refuses.
var put_check := Callable()
## Optional ammo rule for reload_item: (item_type: int, ammo_type: int) -> String, "" to allow, else the
## refusal (e.g. "That ammo doesn't fit your Glock 19."). Without one any ammo fits.
var reload_check := Callable()


func _init(s: Snapshot, t: IdTables) -> void:
	snap = s
	tables = t


## A `message` event (contracts/events.md) for ItemActions.on_events.
static func message_event(text: String) -> Dictionary:
	return {"kind": "message", "type": ItemActions.M_INFO, "text": text}


## Can items be put into an itype? When the id tables send pockets: it has one the player may use. Older tables:
## category "container".
static func is_container(type: int, t: IdTables) -> bool:
	var def: IdTables.Def = t.def_at("itype", type) if t != null else null
	if def == null:
		return false
	if t.has_pockets:
		for p: Dictionary in def.pockets:
			if not int(p["flags"]) & IdTables.POCKET_FORBIDDEN:
				return true
		return false
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
	if put_check.is_valid():
		var why: Variant = put_check.call(t, ct, pocket)
		if why is String and not (why as String).is_empty():
			return _refuse((why as String).left(200))
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


## Unload a carried item: its first content (a gun's magazine with its rounds, a magazine's rounds) goes to
## `hand` as take puts things there. Items lying on the ground have no listed contents here: refused.
func unload_item(uid: float, type: float, pos: Vector3i, hand := "pack") -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not _pos_ok(pos) or not (hand in ItemActions.HANDS):
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You can't unload that from here.")
	if snap.carried[row * CS + 4] & Snapshot.CARRIED_WORN:
		return _refuse("You can't unload a %s!" % _name(t))   # containers are emptied with take and put
	if _subtree_end(row) == row + 1:
		return _refuse("Your %s isn't loaded." % _name(t))
	var first := row + 1   # its first content, with what is inside that
	var ft := snap.carried[first * CS + 1]
	var flags := 0
	var parent := 0
	var pocket := -1
	if hand == "main":
		var w := _flagged(Snapshot.CARRIED_WIELDED)
		if w >= 0:
			return _refuse("Your hand is full: you're holding your %s." % _name(snap.carried[w * CS + 1]))
		flags = Snapshot.CARRIED_WIELDED
	elif hand == "off" and _flagged(Snapshot.CARRIED_OFFHAND) >= 0:
		return _refuse("Your off hand is full.")
	elif hand == "off":
		flags = Snapshot.CARRIED_OFFHAND
	var moved := _remove_subtree(first)
	moved[2] = parent
	moved[3] = pocket
	moved[4] = flags
	var at := 0   # wielded first
	if hand != "main":
		var bag := _worn_container()
		if bag >= 0:
			moved[2] = snap.carried[bag * CS]
			moved[3] = 0
			at = _subtree_end(bag)
		else:
			at = snap.carried.size() / CS
	_insert_rows(at, moved)
	if hand == "main":
		snap.player_wielded = ft
	return _captured()


## Reload a carried item with `ammo` (carried, or a handle on `pos` in reach): the ammo row (with what is
## inside it) goes into the item, or merges into rounds of its type already there (counts aren't modelled).
## Refused when the item holds something else, or when reload_check says so.
func reload_item(uid: float, type: float, ammo: float, ammo_type: float, pos: Vector3i) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	var au := _uid(ammo)
	var at := _type(ammo_type)
	if snap == null or u <= 0 or t <= 0 or au <= 0 or at <= 0 or not _pos_ok(pos):
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	if au == u:
		return _refuse("You can't load the %s with itself." % _name(t))
	var arow := ItemActions.carried_row(snap, au, at)
	var sm: Snapshot.Submap = null
	var h := -1
	if arow < 0:
		if not _in_reach(pos):
			return _refuse("You can't reach that from here.")
		sm = _submap(pos)
		h = ItemActions.handle_index(sm, ItemActions.tile_of(pos), au, at)
		if h < 0:
			return _refuse("That isn't there any more.")
	elif _subtree(row).has(au) or _subtree(arow).has(u):
		return _refuse("You can't load the %s with that." % _name(t))
	if reload_check.is_valid():
		var why: Variant = reload_check.call(t, at)
		if why is String and not (why as String).is_empty():
			return _refuse((why as String).left(200))
	var merge := false
	if _subtree_end(row) > row + 1:
		if snap.carried[(row + 1) * CS + 1] != at:
			return _refuse("Your %s is already loaded." % _name(t))
		merge = true
	var aflags := snap.carried[arow * CS + 4] if arow >= 0 else 0
	var moved := PackedInt64Array([au, at, u, 0, 0])
	if arow >= 0:
		moved = _remove_subtree(arow)
		moved[2] = u
		moved[3] = 0
		moved[4] = 0
	else:
		_remove_handle(sm, ItemActions.tile_of(pos), h)
		_touch(sm)
	if not merge:
		_insert_rows(ItemActions.carried_row(snap, u, t) + 1, moved)
	if aflags & Snapshot.CARRIED_WIELDED:
		snap.player_wielded = 0
	return _captured()


## Clear the jam of the wielded gun: its jam faults (WeaponViewmodel.JAMS) go. Refused when it isn't the wielded
## gun or isn't jammed.
func clear_item(uid: float, type: float) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0:
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0 or (snap.carried[row * CS + 4] & Snapshot.CARRIED_WIELDED) == 0 or snap.player_gun.get("type") != t:
		return _refuse("You aren't wielding that gun.")
	var left: Array[String] = []
	for f: String in snap.player_gun.get("faults", []):
		if not WeaponViewmodel.JAMS.has(f):
			left.append(f)
	if left.size() == (snap.player_gun.get("faults", []) as Array).size():
		return _refuse("It isn't jammed.")
	snap.player_gun["faults"] = left
	return _captured()


## Throw a carried, unworn item at `pos`: a square seen, on your level, within THROW_RANGE, not your own. It
## lands there whole (no stacks or charges here).
func throw_item(uid: float, type: float, pos: Vector3i) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not _pos_ok(pos):
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	var flags := snap.carried[row * CS + 4]
	if flags & Snapshot.CARRIED_WORN:
		return _refuse("Take off your %s first." % _name(t))
	var d := pos - snap.player_pos
	if d == Vector3i.ZERO:
		return _refuse("You can't throw it at yourself.")
	if d.z != 0 or maxi(absi(d.x), absi(d.y)) > THROW_RANGE:
		return _refuse("That's too far to throw your %s." % _name(t))
	var sm := _submap(pos)
	var tile := ItemActions.tile_of(pos)
	if sm == null or tile >= sm.vis.size() or sm.vis[tile] != 2:
		return _refuse("You can't see where to throw it.")
	var p := _pile(sm, tile)
	if _handles_on(sm, tile) >= Snapshot.MAX_HANDLES_PER_TILE \
			or (p >= 0 and sm.items[p + 1] >= Snapshot.MAX_ITEM_COUNT):
		return _refuse("There's no room for your %s there." % _name(t))
	_remove_subtree(row)
	if flags & Snapshot.CARRIED_WIELDED:
		snap.player_wielded = 0
	_add_handle(sm, tile, u, t, -1, -1)
	_touch(sm)
	return _captured()


## Move a carried, unworn item into hand "main" (wielded: out of its container, first row; refused while another item
## is wielded) or "off" (held: it stays in its pocket; refused while another item is held there). ItemActions.hold.
func hold_item(uid: float, type: float, hand: String) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not (hand in ["main", "off"]):
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	var flags := snap.carried[row * CS + 4]
	if flags & Snapshot.CARRIED_WORN:
		return _refuse("Take off your %s first." % _name(t))
	var want := Snapshot.CARRIED_WIELDED if hand == "main" else Snapshot.CARRIED_OFFHAND
	var other := _flagged(want)
	if other >= 0 and other != row:
		if hand == "main":
			return _refuse("Your hand is full: you're holding your %s." % _name(snap.carried[other * CS + 1]))
		return _refuse("Your off hand is full.")
	if hand == "main":
		var moved := _remove_subtree(row)
		moved[2] = 0
		moved[3] = -1
		moved[4] = (flags & ~Snapshot.CARRIED_OFFHAND) | Snapshot.CARRIED_WIELDED
		_insert_rows(0, moved)   # wielded first
		snap.player_wielded = t
	else:
		snap.carried[row * CS + 4] = (flags & ~Snapshot.CARRIED_WIELDED) | Snapshot.CARRIED_OFFHAND
		if flags & Snapshot.CARRIED_WIELDED:
			snap.player_wielded = 0
	return _captured()


## Pour onto `pos` (your square or next to it): what a carried item holds first goes (spilt, no item left).
## The mock can't tell liquids from other things: it pours whatever is first inside.
func pour_item(uid: float, type: float, pos: Vector3i) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	if snap == null or u <= 0 or t <= 0 or not _pos_ok(pos):
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	if not _in_reach(pos):
		return _refuse("You can't pour that there.")
	if _subtree_end(row) == row + 1:
		return _refuse("Your %s is empty." % _name(t))
	_remove_subtree(row + 1)
	return _captured()


## Pour into `container`: what a carried item holds first goes into it (carried: listed inside it, pocket 0 or
## `pocket`; on a square in reach: not listed, as with put).
func pour_into(uid: float, type: float, container: float, container_type: float, pocket := -1) -> bool:
	var u := _uid(uid)
	var t := _type(type)
	var cu := _uid(container)
	var ct := _type(container_type)
	if snap == null or u <= 0 or t <= 0 or cu <= 0 or ct <= 0 or pocket < -1 or pocket > Snapshot.MAX_POCKET:
		return false
	var row := ItemActions.carried_row(snap, u, t)
	if row < 0:
		return _refuse("You don't have that any more.")
	if cu == u or _subtree(row).has(cu):
		return _refuse("You can't pour your %s into itself." % _name(t))
	if _subtree_end(row) == row + 1:
		return _refuse("Your %s is empty." % _name(t))
	var crow := ItemActions.carried_row(snap, cu, ct)
	if crow < 0 and not _ground_in_reach(cu, ct):
		return _refuse("You can't reach that from here.")
	var moved := _remove_subtree(row + 1)
	if crow >= 0:
		crow = ItemActions.carried_row(snap, cu, ct)
		moved[2] = cu
		moved[3] = maxi(pocket, 0)
		moved[4] = 0
		_insert_rows(_subtree_end(crow), moved)
	return _captured()


## A carried item for tests and mock scenes: a new row inside `parent` (a carried uid, pocket 0; 0 = on the
## body) after what that already holds, with CARRIED_* `flags`. Returns its uid, -1 when the parent isn't
## carried or the list is full.
func give(type: int, parent := 0, flags := 0) -> int:
	if snap == null or type <= 0 or type > Snapshot.MAX_ID or snap.carried.size() / CS >= Snapshot.MAX_CARRIED:
		return -1
	var at := snap.carried.size() / CS
	if parent != 0:
		at = -1
		for i in range(0, snap.carried.size() - CS + 1, CS):
			if snap.carried[i] == parent:
				at = _subtree_end(i / CS)
				break
		if at < 0:
			return -1
	_next_uid = maxi(_next_uid, _max_uid() + 1)
	var u := _next_uid
	_next_uid += 1
	_insert_rows(at, PackedInt64Array([u, type, parent, 0 if parent != 0 else -1, flags]))
	if flags & Snapshot.CARRIED_WIELDED:
		snap.player_wielded = type
	return u


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


## Is handle uid + type on your square or one next to it?
func _ground_in_reach(u: int, t: int) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var p := snap.player_pos + Vector3i(dx, dy, 0)
			if ItemActions.handle_index(_submap(p), ItemActions.tile_of(p), u, t) >= 0:
				return true
	return false


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
