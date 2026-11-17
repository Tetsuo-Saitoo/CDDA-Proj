extends RefCounted
## Live item tiles in VR (VrTile, lead-vr), run by run_tests.gd: the short line and words from ItemTile; the hand
## labels (VrHeld) with a tile: the gauge in the contents' colour and from the tile's fill when get_held gives no
## numbers, its back in the temperature's colour, the spoilage strip, the words; the rig gives the held items' tiles
## and reads them again from a newer snapshot; the tray's item labels and the pack's hover name carry the line.

var _check: Callable
var _t: IdTables
var _world: WorldView


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr tiles")
	_t = IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "juice", "name": "orange <color_red>juice</color>", "color": "c_yellow"},
			{"id": "long", "name": "a very long name for a liquid that goes on and on and on and on"}]})
	_check.call(_t.is_valid(), "vr tile: test tables load (%s)" % _t.error)
	_world = WorldView.new()
	_world.tables = _t
	_test_tag()
	_test_held(root)
	_test_rig(root)
	_test_lists()
	_world.free()


static func _s(a: Array) -> PackedInt32Array:
	return PackedInt32Array(a)


## [temp, rot, fill, fill_type, see_through, fill_ml, dirt] (contracts/snapshot.md)
func _jug() -> Dictionary:
	return ItemTile.of(_s([ItemLook.Temp.COLD, -1, 500, 1, 1, 500, -1]), _t)


func _test_tag() -> void:
	var jug := _jug()
	var jar := ItemTile.of(_s([0, -1, 0, 0, 1, 0, -1]), _t)
	var apple := ItemTile.of(_s([ItemLook.Temp.FROZEN, 1500, -1, 0, 0, -1, -1]), _t)
	var gun := ItemTile.of(_s([0, -1, -1, 0, 0, -1, 4000]), _t)
	var plain := ItemTile.of(_s([0, -1, -1, 0, 0, -1, -1]), _t)
	var fouled := "fouled %d%%" % roundi(GunGrime.grime_for(4000) * 100.0)
	var tags := [VrTile.tag(jug), VrTile.tag(jug, true), VrTile.tag(jar), VrTile.tag(apple), VrTile.tag(gun),
			VrTile.tag(plain), VrTile.tag({})]
	_check.call(tags == ["500 ml orange juice, cold", "500 ml, cold", "empty", "frozen, rotten", fouled, "", ""],
			"vr tile: the short line: how much of what, temperature, spoilage, fouling; nothing for a plain item %s" % [tags])
	_check.call(VrTile.line("jug", jug) == "jug\n500 ml orange juice, cold" and VrTile.line("rock", plain) == "rock"
			and VrTile.words(jug) == "Cold\n500 ml orange juice, 50% full" and VrTile.words(jug, false) == "Cold"
			and VrTile.words({}) == "" and VrTile.color(jug) == Color(ItemLook.COLD_TINT, 1.0)
			and VrTile.color(plain) == VrTile.TEXT, "vr tile: name and line, words with and without the fill, colour")
	var long := ItemTile.of(_s([ItemLook.Temp.FROZEN, 1500, 1000, 2, 1, ItemLook.ML_MAX, 10000]), _t)
	var junk := [ItemTile.of("junk", _t), ItemTile.of([NAN, "x", -7, 1 << 40, 3, INF, -2], _t),
			ItemTile.of(_s([99, 99999, 5000, -3, 7, -1, 99999]), _t)]
	var junk_tags := junk.map(func(t: Dictionary) -> String: return VrTile.tag(t))
	_check.call(VrTile.tag(long).length() == VrTile.TAG_MAX and VrTile.tag(long, true).length() <= VrTile.SHORT_MAX
			and junk_tags.all(func(s: String) -> bool: return s.length() <= VrTile.TAG_MAX and not s.contains("\n")),
			"vr tile: the line is capped and one line; junk states say little or nothing %s" % [junk_tags])
	_check.call(VrTile.of(null, 5).is_empty() and VrTile.of(_world, 5).is_empty(), "vr tile: no world or snapshot: none")


func _test_held(root: Node) -> void:
	var vh := VrHeld.new("Right")
	root.add_child(vh)
	var jug := _jug()
	vh.show_hand({"name": "jug", "uid": 9}, false, jug)   # get_held gives no numbers: the tile's fill
	var back := vh._back_mat.albedo_color
	_check.call(vh.visible and is_equal_approx(vh.ratio, 0.5) and vh._gauge.visible and vh._fill.visible
			and vh._fill_mat.albedo_color == jug["liquid"] and vh._state.visible
			and vh._state.text == "Cold\n500 ml orange juice, 50% full" and vh._state.modulate == Color(ItemLook.COLD_TINT, 1.0)
			and back != VrHeld.BACK and is_equal_approx(back.a, VrHeld.BACK.a) and back.b > VrHeld.BACK.b and not vh._rot.visible,
			"vr tile: hand: the gauge from the tile in the juice's colour, its back cold, the words under the name")
	var can := {"name": "jug", "uid": 9, "liquid": "orange juice", "ml": 250, "capacity_ml": 1000}
	vh.show_hand(can, false, jug)
	var numbers: bool = is_equal_approx(vh.ratio, 0.25) and vh._state.text == "Cold" and vh._fill_mat.albedo_color == jug["liquid"]
	vh.show_hand(can, true, jug)
	var filling: bool = vh._fill_mat.albedo_color == HandsPanel.FILL_COLOR
	_check.call(numbers and filling, "vr tile: hand: get_held's numbers win (the name line has the litres, the words don't); filling: highlighted")
	var apple := ItemTile.of(_s([0, 1500, -1, 0, 0, -1, -1]), _t)
	vh.show_hand({"name": "apple", "uid": 10}, false, apple)
	var rot: bool = vh._rot.visible and vh._rot_mat.albedo_color == apple["rot_color"] and not vh._gauge.visible \
			and vh._state.text == "Spoilage 150% (rotten)" and vh._state.modulate == VrTile.TEXT
	vh.show_hand({"name": "rock", "uid": 11}, false, {})
	var plain: bool = not vh._rot.visible and not vh._state.visible and vh._back_mat.albedo_color == VrHeld.BACK \
			and not vh._gauge.visible and vh.tile.is_empty()
	vh.show_hand({}, false, apple)
	_check.call(rot and plain and not vh.visible and vh.tile.is_empty(),
			"vr tile: hand: spoilage strip in its colour; no tile: nothing extra; an empty hand: hidden")
	vh.free()


func _test_rig(root: Node) -> void:
	var snap := Snapshot.new()
	snap.item_states = {9: _s([ItemLook.Temp.COLD, -1, 500, 1, 1, 500, -1])}
	_world.snapshot = snap
	var rig := VrRig.new(_world, {"blink": false, "hands": "boxes"})
	root.add_child(rig)
	rig.show_held({"main": {"name": "jug", "uid": 9}, "off": {"name": "rock", "uid": 12}})
	var main_held := rig.right_held if rig.main_ctrl() == rig.right else rig.left_held
	var off_held := rig.left_held if main_held == rig.right_held else rig.right_held
	var first: bool = is_equal_approx(main_held.ratio, 0.5) and main_held.tile.get("temp") == ItemLook.Temp.COLD and off_held.tile.is_empty()
	var newer := Snapshot.new()
	newer.item_states = {9: _s([ItemLook.Temp.HOT, -1, 1000, 1, 1, 1000, -1]), 12: _s([0, -1, -1, 0, 0, -1, 3000])}
	_world.snapshot = newer
	rig.update_hands(0.016)
	var again: bool = is_equal_approx(main_held.ratio, 1.0) and main_held.tile.get("temp") == ItemLook.Temp.HOT \
			and float(off_held.tile.get("grime", -1.0)) > 0.0
	_world.snapshot = null
	rig.update_hands(0.016)
	_check.call(first and again and main_held.tile.is_empty() and main_held.ratio == -1.0,
			"vr tile: the rig gives each hand its item's tile and reads them again from a newer snapshot (none: none)")
	rig.free()


func _test_lists() -> void:
	var snap := Snapshot.new()
	snap.item_states = {9: _s([ItemLook.Temp.COLD, -1, 500, 1, 1, 500, -1])}
	_world.snapshot = snap
	var e := {"visual": null, "uid": 9, "pending": false, "name": "jug"}
	VrPack._dress(e, snap, _t)
	var dim := {"visual": null, "uid": 9, "pending": true, "name": "jug"}
	VrPack._dress(dim, snap, _t)
	_check.call(VrTile.line(e["name"], e["tile"]) == "jug\n500 ml orange juice, cold" and (dim["tile"] as Dictionary).is_empty(),
			"vr tile: the pack keeps each item's tile for its hover name (a pending one: none)")
	var tray := ItemTray.new()
	tray.world = _world
	var l := Label3D.new()
	var rock := Label3D.new()
	tray.items = [{"item": ItemRef.on_square(9, 1, Vector3i.ZERO), "name": "jug", "label": l},
			{"item": ItemRef.on_square(12, 1, Vector3i.ZERO), "name": "rock", "label": rock}]
	tray._dress_all()
	var shown := l.text
	_world.snapshot = null
	tray._dress_all()
	_check.call(shown == "jug\n500 ml, cold" and rock.text == "rock" and l.text == "jug",
			"vr tile: the tray's item label says the state in a short line, again on each snapshot (%s)" % shown)
	l.free()
	rock.free()
	tray.free()
