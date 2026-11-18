extends RefCounted
## Gun modification by hand, S1 (GunMods): each gun shape has a slot for CDDA's main gunmod locations where a mod of
## that kind goes (sights on top, muzzle past the muzzle, stock behind the grip, ...); mounts sit by their part,
## smaller; an unknown location still gets a place; more mods at one location step along it; the location charset;
## hostile `mods` lists; the boxes on a built model (meta, replaced, none for a shape without slots).
## Built data only. Run by run_tests.gd.

var _check: Callable


func run(check: Callable) -> void:
	_check = check
	print("gun mods")
	_test_slots()
	_test_locations()
	_test_mods_of()
	_test_dress()


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
