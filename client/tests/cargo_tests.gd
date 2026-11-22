extends RefCounted
## Car storage (lead-ui, 2026-11-21): Snapshot.Vehicle.cargo read from vehicles[].cargo (contracts/snapshot.md),
## ItemTray's "cargo" source and what Hands takes from it (ItemActions.listed_in_cargo). Run by run_tests.gd.

const UID := 4242
const ITEM_A := 901
const ITEM_B := 902

var _check: Callable


func run(_root: Node, check: Callable, data: Variant) -> void:
	_check = check
	_test_read(data)
	_test_tray(data)


## The mock with a car one square east of the player: part 0 a frame and part 1 its trunk there, part 2 a frame
## two squares east, part 3 a gap filler south of the trunk; `cargo` as given.
static func _with_car(data: Variant, cargo: Variant) -> Dictionary:
	var d: Dictionary = (data as Dictionary).duplicate(true)
	var p := Snapshot.from_data(data).player_pos + Vector3i(1, 0, 0)
	var parts := [[0, 0, 1, 255, 0, 0, 0, 0], [0, 0, 2, 255, 0, 0, 0, 0], [1, 0, 1, 255, 0, 1, 0, 0],
			[0, 1, 1, 255, Snapshot.VPART_FILLER, 0, 1, 0]]
	var car := {"uid": UID, "name": "Station Wagon", "pos": [p.x, p.y, p.z], "face_deg": 0.0, "parts": parts}
	if cargo != null:
		car["cargo"] = cargo
	d["vehicles"] = [car]
	return d


static func _items(n: int, from: int) -> Array:
	var out := []
	for i in n:
		out.append([from + i, 10])
	return out


func _test_read(data: Variant) -> void:
	var rows := [[1, 5000, 60000, 2, [[ITEM_A, 10], [ITEM_B, 11]]],   # the trunk
			[3, 0, 100, 0, []],                     # on a gap filler
			[1, 0, 0, 0, []],                       # the trunk again
			[0, 1, 2, 0, [[903, "x"]]],             # a junk item
			[99, 0, 1, 0, []], "junk", [0, -1, 2, 0, []], [0, 1, 2, 0, [[0, 3]]],
			[2, 0, 1, 0, _items(33, 1000)]]         # 33 items: 32 listed, one more
	var s := Snapshot.from_data(_with_car(data, rows))
	var veh: Snapshot.Vehicle = s.vehicles[0] if s.vehicles.size() == 1 else null
	var ok := s.is_valid() and veh != null and veh.cargo.size() == 2
	if ok:
		var a: Dictionary = veh.cargo[0]
		var b: Dictionary = veh.cargo[1]
		ok = a["part"] == 1 and a["used_ml"] == 5000 and a["capacity_ml"] == 60000 and a["more"] == 2 \
				and a["items"] == PackedInt64Array([ITEM_A, 10, ITEM_B, 11]) and b["part"] == 2 \
				and (b["items"] as PackedInt64Array).size() == 64 and b["more"] == 1
	var many := []
	for i in 12:
		many.append([0 if i < 9 else 2, 0, 1, 0, []])   # only the first 9 looked at: part 2's rows aren't
	var capped := Snapshot.from_data(_with_car(data, many))
	var none := Snapshot.from_data(_with_car(data, {"not": "a list"}))
	_check.call(ok and capped.is_valid() and capped.vehicles[0].cargo.size() == 1 and none.is_valid()
			and none.vehicles.size() == 1 and none.vehicles[0].cargo.is_empty(),
			"cargo: vehicles[].cargo read; junk rows, gap fillers and a part twice left out; 9 rows, 32 items "
			+ "(the rest in more); never a failed snapshot (%s)" % [veh.cargo if veh != null else "no car"])


func _test_tray(data: Variant) -> void:
	var s := Snapshot.from_data(_with_car(data, [[1, 5000, 60000, 2, [[ITEM_A, 10], [ITEM_B, 11]]],
			[2, 0, 1, 0, [[905, 10]]]]))
	var trunk := s.player_pos + Vector3i(1, 0, 0)
	var src := ItemTray.source_for_cargo(s, trunk)
	var l := ItemTray.list(s, src)
	var rows: Array = l.get("rows", [])
	var ok: bool = src == {"kind": "cargo", "vehicle": UID, "part": 1, "square": trunk} and rows.size() == 2 \
			and l["more"] == 2 and (rows[0] as ItemRef).uid == ITEM_A and (rows[0] as ItemRef).cargo \
			and (rows[0] as ItemRef).square == trunk and ItemActions.listed_in_cargo(s, rows[0])
	var stranger := ItemRef.on_square(999, 10, trunk)
	stranger.cargo = true
	var not_cargo := ItemRef.on_square(ITEM_A, 10, trunk)
	var far := ItemTray.source_for_cargo(s, trunk + Vector3i(1, 0, 0))   # listed, but two squares away
	var nothing := ItemTray.source_for_cargo(s, trunk + Vector3i(0, -1, 0))
	_check.call(ok and not ItemActions.listed_in_cargo(s, stranger) and not ItemActions.listed_in_cargo(s, not_cargo)
			and not far.is_empty() and ItemTray.list(s, far).is_empty() and nothing.is_empty()
			and ItemTray.source_for_cargo(null, trunk).is_empty(),
			"cargo tray: E's source on the trunk, its items as cargo ItemRefs Hands can take; only next to the player")
	var taken := Snapshot.from_data(_with_car(data, [[1, 2000, 60000, 2, [[ITEM_B, 11]]]]))
	var gone := Snapshot.from_data(_with_car(data, null))
	var moved := Snapshot.from_data(_with_car(data, [[0, 2000, 60000, 0, [[ITEM_A, 10]]]]))   # another part's row
	_check.call(ItemTray.list(taken, src)["rows"].size() == 1 and not ItemActions.listed_in_cargo(taken, rows[0])
			and ItemTray.list(gone, src).is_empty() and ItemTray.list(moved, src).is_empty(),
			"cargo tray: follows the snapshot: an item taken leaves it; no row, or the row for another part: gone")
