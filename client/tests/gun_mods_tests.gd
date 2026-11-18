extends RefCounted
## Gun modification by hand, S1 (GunMods): each gun shape has a slot for CDDA's main gunmod locations where a mod of
## that kind goes (sights on top, muzzle past the muzzle, stock behind the grip, ...); mounts sit by their part,
## smaller; an unknown location still gets a place; more mods at one location step along it; the location charset;
## hostile `mods` lists; the boxes on a built model (meta, replaced, none for a shape without slots). S1 part 2: the
## snapshot's wielded_gun mods / fits / slots (cleaned, never failing it) and the id tables' gunmod_location /
## mod_locations (strict). Built data and the mock snapshot. Run by run_tests.gd.

var _check: Callable


func run(check: Callable, data: Variant) -> void:
	_check = check
	print("gun mods")
	_test_slots()
	_test_locations()
	_test_mods_of()
	_test_dress()
	_test_snapshot(data)
	_test_tables()


## wielded_gun.mods / fits / slots: parsed when sent, junk entries left out without failing the snapshot, capped;
## not sent: the old keys only. GunMods.mods_of takes the parsed list as it is.
func _test_snapshot(data: Variant) -> void:
	var dd: Dictionary = (data as Dictionary).duplicate(true)
	var long_reason := "a".repeat(500)
	dd["player"]["wielded_gun"] = {"type": 5, "rounds": 3,
		"mods": [[501, 7, "muzzle", 0], [502, 8, "stock mount", 1], [501, 9, "sights", 0], [0, 7, "rail", 0],
			[503, 7, "<b>", 0], [504, 7.5, "rail", 0], [505, 7, "rail"], "x", null, [506, 7, "rail", 300],
			[507.0, 7.0, "rail", 0.0, "more"]],
		"fits": [[601, 1, 100, 0, ""], [602, 0, 40, 30, "<color_red>requires at least 3 in marksmanship</color>"],
			[603, 2, 0, 0, ""], [604, 0, 101, 0, ""], [605, 0, -1, 0, "x"], [601, 1, 0, 0, "again"], [606, 0, 0, 0, 5],
			[607, 0, 0, 0, long_reason], {"uid": 608}],
		"slots": [["sights", 1, 0], ["rail", 2, 1], ["rail", 2, 2], ["muzzle", 1, 2], ["bad/one", 1, 1], ["stock", 99, 0],
			["barrel", 1]]}
	var s := Snapshot.from_data(dd)
	var g := s.player_gun
	var mods: Array = g.get("mods", [])
	var fits: Array = g.get("fits", [])
	var slots: Array = g.get("slots", [])
	var uids := []
	for m: Dictionary in mods:
		uids.append(m["uid"])
	var fit_uids := []
	for f: Dictionary in fits:
		fit_uids.append(f["uid"])
	var m_ok: bool = uids == [501, 502, 507] and mods[1] == {"uid": 502, "type": 8, "location": "stock mount", "flags": 1} \
			and mods[2]["uid"] is int and mods[2]["type"] is int and mods[2]["flags"] is int
	var f_ok: bool = fit_uids == [601, 602, 606, 607] and fits[0]["ok"] == true and fits[0]["chance"] == 100 \
			and fits[1]["ok"] == false and fits[1]["risk"] == 30 \
			and fits[1]["reason"] == "requires at least 3 in marksmanship" and fits[2]["reason"] == "" \
			and (fits[3]["reason"] as String).length() == Snapshot.MAX_FIT_REASON
	var s_ok: bool = slots == [{"location": "sights", "slots": 1, "free": 0}, {"location": "rail", "slots": 2, "free": 1}]
	_check.call(s.is_valid() and m_ok and f_ok and s_ok and GunMods.mods_of(g).size() == 3,
			"gun mods: wielded_gun mods / fits / slots parse; junk entries left out, the snapshot still valid (%s %s %s %s)"
			% [s.error, mods, fits, slots])
	var many := []
	for i in 40:
		many.append([1000 + i, 7, "rail", 0])
	dd["player"]["wielded_gun"] = {"type": 5, "mods": many, "fits": "junk", "slots": {"sights": 1}}
	var capped := Snapshot.from_data(dd)
	dd["player"]["wielded_gun"] = {"type": 5}
	var old := Snapshot.from_data(dd)
	_check.call(capped.is_valid() and (capped.player_gun["mods"] as Array).size() == Snapshot.MAX_GUN_MODS
			and (capped.player_gun["fits"] as Array).is_empty() and (capped.player_gun["slots"] as Array).is_empty()
			and old.is_valid() and not old.player_gun.has("mods") and not old.player_gun.has("fits")
			and not old.player_gun.has("slots"),
			"gun mods: a long mods list is capped at %d, a wrong-shaped one is empty; not sent: no keys" % Snapshot.MAX_GUN_MODS)


## The id tables' gunmod_location (gunmods) and mod_locations (guns): read when sent; a bad one fails the tables.
func _test_tables() -> void:
	var base := {"generation": 3, "ter": [{"id": "t_null"}], "furn": [{"id": "f_null"}], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "gun_x", "mod_locations": [["sights", 1], ["stock mount", 1], ["rail", 2]]},
				{"id": "scope_x", "gunmod_location": "sights"}, {"id": "rock_x", "gunmod_location": null}]}
	var t := IdTables.from_data(base)
	var gun: IdTables.Def = t.def_named("itype", "gun_x") if t.is_valid() else null
	var scope: IdTables.Def = t.def_named("itype", "scope_x") if t.is_valid() else null
	var rock: IdTables.Def = t.def_named("itype", "rock_x") if t.is_valid() else null
	_check.call(t.is_valid() and gun != null and gun.mod_locations == [{"location": "sights", "slots": 1},
			{"location": "stock mount", "slots": 1}, {"location": "rail", "slots": 2}] and gun.gunmod_location == ""
			and scope.gunmod_location == "sights" and scope.mod_locations.is_empty() and rock.gunmod_location == "",
			"gun mods: id tables read a gun's mod locations and a gunmod's location (%s)" % t.error)
	var seventeen := []
	for i in IdTables.MAX_MOD_LOCATIONS + 1:
		seventeen.append(["loc %d" % i, 1])
	var bad_rows: Array = [
		{"gunmod_location": "<b>sights</b>"}, {"gunmod_location": ""}, {"gunmod_location": 5},
		{"gunmod_location": "x".repeat(IdTables.MAX_MOD_LOCATION + 1)}, {"gunmod_location": ["sights"]},
		{"mod_locations": "sights"}, {"mod_locations": [["sights"]]}, {"mod_locations": [["sights", 1, 2]]},
		{"mod_locations": [["sights", -1]]}, {"mod_locations": [["sights", IdTables.MAX_MOD_SLOTS + 1]]},
		{"mod_locations": [["sights", 1.5]]}, {"mod_locations": [["bad/x", 1]]}, {"mod_locations": [["sights", null]]},
		{"mod_locations": [["sights", 1], ["sights", 2]]}, {"mod_locations": seventeen}, {"mod_locations": [{"sights": 1}]},
	]
	var let_in := []
	for r: Dictionary in bad_rows:
		var d: Dictionary = base.duplicate(true)
		var row := {"id": "bad_x"}
		row.merge(r)
		d["itype"].append(row)
		if IdTables.from_data(d).is_valid():
			let_in.append(r)
	_check.call(let_in.is_empty(), "gun mods: a bad gunmod_location or mod_locations fails the id tables (%s)" % [let_in])


func _test_slots() -> void:
	var ok := true
	var bad := []
	for sh: String in GunMods.SLOTS:
		var model := WeaponViewmodel.build(sh)
		var muzzle := (model.get_node("Muzzle") as Node3D).position
		var grip := (model.get_node("Grip") as Node3D).position
		var sights: Vector3 = GunMods.slot(sh, "sights")["at"]
		var muz: Vector3 = GunMods.slot(sh, "muzzle")["at"]
		var stock: Vector3 = GunMods.slot(sh, "stock")["at"]
		var under: Vector3 = GunMods.slot(sh, "underbarrel")["at"]
		var good := sights.y > grip.y and sights.y > muzzle.y and muz.z < muzzle.z and stock.z > grip.z \
				and under.y < muzzle.y and under.z < grip.z
		for loc: String in GunMods.SLOTS[sh]:
			var s := GunMods.slot(sh, loc)
			good = good and s["size"] is Vector3 and (s["size"] as Vector3).x > 0.0 and (s["at"] as Vector3).length() < 1.0
		if not good:
			bad.append(sh)
		ok = ok and good
		model.free()
	var missing := []   # lead-combat: a new gun shape must get its slots, not fall through silently
	for sh: String in WeaponViewmodel.GUN_SHAPES + VrGun.SHAPES:
		if not GunMods.SLOTS.has(sh):
			missing.append(sh)
	bad.append_array(missing)
	_check.call(ok and missing.is_empty() and GunMods.SLOTS.size() == WeaponViewmodel.GUN_SHAPES.size(),
			"gun mods: on each gun shape sights sit on top, a muzzle mod past the muzzle, a stock behind the grip (%s)" % [bad])
	var mount := GunMods.slot("long", "sights mount")
	var sight := GunMods.slot("long", "sights")
	var odd := GunMods.slot("long", "frobnicator")
	var mech := GunMods.slot("long", "mechanism")
	_check.call((mount["at"] as Vector3).distance_to(sight["at"]) < 0.03 and (mount["size"] as Vector3).x < (sight["size"] as Vector3).x
			and (odd["at"] as Vector3).distance_to(mech["at"]) < 0.03 and not odd.is_empty(),
			"gun mods: a mount sits by its part, smaller; an unknown location still gets a place")
	var r0: Vector3 = GunMods.slot("long", "rail", 0)["at"]
	var r1: Vector3 = GunMods.slot("long", "rail", 1)["at"]
	var r9: Vector3 = GunMods.slot("long", "rail", 99)["at"]
	var rN: Vector3 = GunMods.slot("long", "rail", GunMods.MAX_STACK)["at"]
	var rneg: Vector3 = GunMods.slot("long", "rail", -4)["at"]
	_check.call(r1.distance_to(r0) > 0.05 and r9.is_equal_approx(rN) and rneg.is_equal_approx(r0)
			and GunMods.slot("melee", "sights").is_empty() and GunMods.slot("bow", "rail").is_empty()
			and GunMods.slot("", "sights").is_empty(),
			"gun mods: a second mod at one location steps along it (capped); no slots on a sword or a bow")


func _test_locations() -> void:
	var good := ["sights", "stock mount", "brass catcher", "under_barrel-2", "x".repeat(GunMods.MAX_LOC)]
	var bad: Array = ["", "x".repeat(GunMods.MAX_LOC + 1), "<color_red>sights</color>", "rail\n", "sights\u0001",
			"pièce", "a/b", "../x", 5, null, ["sights"], {"a": 1}, &"sights"]
	var ok := true
	for s: Variant in good:
		ok = ok and GunMods.valid_location(s)
	var let_in := []
	for s: Variant in bad:
		if GunMods.valid_location(s):
			let_in.append(s)
	_check.call(ok and let_in.is_empty(), "gun mods: location ids: letters, digits, space, _ and - only, 1..32 (%s)" % [let_in])


func _test_mods_of() -> void:
	var many := []
	for i in 40:
		many.append({"uid": 1000 + i, "type": 7, "location": "rail"})
	var gun := {"mods": [
		{"uid": 11, "type": 3, "location": "sights", "flags": 1},
		{"uid": 12.0, "type": 4.0, "location": "muzzle"},
		{"uid": 0, "type": 3, "location": "sights"}, {"uid": -5, "type": 3, "location": "sights"},
		{"uid": 1 << 53, "type": 3, "location": "sights"}, {"uid": 1.5, "type": 3, "location": "sights"},
		{"uid": NAN, "type": 3, "location": "sights"}, {"uid": INF, "type": 3, "location": "sights"},
		{"uid": 13, "type": 0, "location": "sights"}, {"uid": 13, "type": Snapshot.MAX_ID + 1, "location": "sights"},
		{"uid": 13, "type": 3, "location": "<b>x</b>"}, {"uid": 13, "type": 3}, {"uid": 13, "type": 3, "location": 4},
		{"uid": 14, "type": 3, "location": "stock", "flags": "x"}, {"uid": 15, "type": 3, "location": "stock", "flags": 9999},
		"junk", 5, null, [11, 3, "sights", 0]]}
	var got := GunMods.mods_of(gun)
	var capped := GunMods.mods_of({"mods": many})
	var none: bool = GunMods.mods_of({}).is_empty() and GunMods.mods_of({"mods": "x"}).is_empty() \
			and GunMods.mods_of(null).is_empty() and GunMods.mods_of([1]).is_empty() and GunMods.mods_of({"mods": {}}).is_empty()
	_check.call(got.size() == 4 and got[0] == {"uid": 11, "type": 3, "location": "sights", "flags": 1}
			and got[1]["uid"] is int and got[1]["uid"] == 12 and got[1]["type"] == 4 and got[1]["flags"] == 0
			and got[2]["uid"] == 14 and got[2]["flags"] == 0 and got[3]["flags"] == 0
			and capped.size() == GunMods.MAX_MODS and none,
			"gun mods: hostile mods lists: only whole entries kept, numbers made ints, flags 0 when bad, capped at %d (%s)"
			% [GunMods.MAX_MODS, got])


func _test_dress() -> void:
	var model := WeaponViewmodel.build("long")
	var mods: Array[Dictionary] = [
		{"uid": 21, "type": 3, "location": "rail", "flags": 0},
		{"uid": 22, "type": 4, "location": "rail", "flags": 0},
		{"uid": 23, "type": 5, "location": "stock", "flags": 1},
	]
	var h := GunMods.dress(model, "long", mods)
	var kids: Array = h.get_children() if h != null else []
	var first: bool = kids.size() == 3 and h.get_parent() == model and h.name == GunMods.HOLDER \
			and kids[0].get_meta("uid") == 21 and kids[1].get_meta("uid") == 22 and kids[2].get_meta("location") == "stock" \
			and (kids[0] as Node3D).position.is_equal_approx(GunMods.slot("long", "rail", 0)["at"]) \
			and (kids[1] as Node3D).position.is_equal_approx(GunMods.slot("long", "rail", 1)["at"]) \
			and ((kids[2] as MeshInstance3D).mesh as BoxMesh).size.is_equal_approx(GunMods.slot("long", "stock")["size"])
	var grimed := WeaponViewmodel.grime_materials(model).size()
	var rest: Array[Dictionary] = [mods[2]]
	var h2 := GunMods.dress(model, "long", rest)
	var again: bool = h2 != null and h2.get_child_count() == 1 and model.get_children().filter(
			func(n: Node) -> bool: return n.name == GunMods.HOLDER).size() == 1 and not is_instance_valid(h)
	var empty: Array[Dictionary] = []
	var gone: bool = GunMods.dress(model, "long", empty) == null and model.get_node_or_null(GunMods.HOLDER) == null
	var melee := WeaponViewmodel.build("melee")
	var on_sword: bool = GunMods.dress(melee, "melee", mods) == null and melee.get_node_or_null(GunMods.HOLDER) == null
	var plain := WeaponViewmodel.build("long")
	var grimed_plain := WeaponViewmodel.grime_materials(plain).size()
	plain.free()
	_check.call(first and again and gone and on_sword and GunMods.dress(null, "long", mods) == null
			and grimed == grimed_plain and grimed > 0,
			"gun mods: the boxes go under the model's Mods node at their slots (two on one rail step along it), replaced "
			+ "on each call, none for no mods or a sword; the gun's grime parts are untouched")
	model.free()
	melee.free()
