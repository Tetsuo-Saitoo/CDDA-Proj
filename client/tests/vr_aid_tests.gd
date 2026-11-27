extends RefCounted
## First aid in VR (VrAid, VrRig `aid`): a first aid item held to a body part it can treat (the other forearm, head,
## chest, a leg) lights it, and after HOLD_S sends CDDA's consume with that part; not a part it can't treat (whole, a
## broken limb), not food; CDDA's no by that hand; the mouth leaves first aid alone.

const SQ := Vector3i(5, 5, 0)

var _check: Callable


class Backend:
	extends RefCounted
	var calls: Array = []
	var tags: Array = []

	func consume_item(uid: float, type: float, tag := 0, part := "") -> bool:
		calls.append([uid, type, part])
		tags.append(tag)
		return true

	func queued_actions() -> int:
		return 0


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr aid")
	var t := IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "bandages", "category": "drugs", "heal": 5},
			{"id": "disinfectant", "category": "drugs", "heal": 10}, {"id": "apple", "category": "food"}],
			"tables": {"body_part": ["torso", "head", "arm_l", "arm_r", "leg_l", "leg_r"]}})
	var snap := Snapshot.new()
	snap.seq = 5
	var c := PackedInt64Array()
	for row: Array in [[41, 1, 0, -1, 0], [42, 2, 0, -1, 0], [43, 3, 0, -1, 0]]:
		c.append_array(PackedInt64Array(row))   # bandages 41, disinfectant 42, apple 43
	snap.carried = c
	# torso hurt; head whole; arm_l whole; arm_r bleeding (whole); leg_l broken and bleeding; leg_r whole
	for p: Array in [[0, 40, 60, 0], [1, 60, 60, 0], [2, 60, 60, 0], [3, 60, 60, 5], [4, 0, 60, 5], [5, 60, 60, 0]]:
		var b := Snapshot.BodyPart.new()
		b.id = p[0]
		b.hp = p[1]
		b.hp_max = p[2]
		b.bleed = p[3]
		snap.player_parts.append(b)
	var world := WorldView.new()
	world.tables = t
	world.snapshot = snap
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var acts := ItemActions.new()
	var be := Backend.new()
	acts.backend = be
	acts.on_snapshot(snap)
	rig.aid.actions = acts
	rig.mouth.actions = acts
	_test_parts(t, snap)
	_test_apply(rig, acts, be)
	acts.free()
	rig.free()
	world.free()


## Where each part is, and which a bandage (stops bleeding, bandages) or disinfectant (disinfects, bites) can treat.
func _test_parts(t: IdTables, snap: Snapshot) -> void:
	var eyes := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var other := Transform3D(Basis.IDENTITY, Vector3(0.3, 1.1, -0.3))
	var at := func(p: Vector3) -> String: return str(VrAid.part_at(p, eyes, other, "r").get("part", ""))
	var where := [at.call(Vector3(0.3, 1.1, -0.18)), at.call(Vector3(0, 1.66, 0)), at.call(Vector3(0, 1.15, -0.1)),
			at.call(Vector3(0.2, 0.6, 0)), at.call(Vector3(-0.2, 0.6, 0)), at.call(Vector3(0.6, 1.4, -0.6)),
			at.call(Vector3(INF, 0, 0))]
	_check.call(where == ["arm_r", "head", "torso", "leg_r", "leg_l", "", ""],
			"vr aid: the other forearm, head, chest, legs by side; nothing elsewhere (%s)" % [where])
	var bandage := [VrAid.needs("arm_r", 5, snap, t), VrAid.needs("torso", 5, snap, t), VrAid.needs("head", 5, snap, t),
			VrAid.needs("leg_l", 5, snap, t), VrAid.needs("arm_r", 10, snap, t), VrAid.needs("torso", 10, snap, t),
			VrAid.needs("nope", 5, snap, t), VrAid.needs("torso", 0, snap, t)]
	_check.call(bandage == [true, true, false, true, false, true, false, false]
			and VrAid.heals(ItemRef.on_player(41, 1, 0, -1, 0, SQ), t) == 5
			and VrAid.heals(ItemRef.on_player(43, 3, 0, -1, 0, SQ), t) == 0,
			"vr aid: a bleed takes a bandage (a broken leg's bleed too), a hurt part either; whole parts nothing (%s)"
			% [bandage])


func _test_apply(rig: VrRig, acts: ItemActions, be: Backend) -> void:
	var a := rig.aid
	var eyes := rig.camera.global_transform
	rig.right.global_position = Vector3(0.3, 1.1, -0.3)
	var arm: Vector3 = VrAid.part_at(rig.right.global_position + Vector3(0, 0, VrAid.ARM_BACK), eyes,
			rig.right.global_transform, "r")["at"]
	var bandage := ItemRef.on_player(41, 1, 0, -1, 0, SQ)
	var apple := ItemRef.on_player(43, 3, 0, -1, 0, SQ)
	var head := a.update(0, bandage, eyes.origin + Vector3.UP * VrAid.HEAD_UP, 0.4) == VrAid.NONE \
			and not a.mark_shown(0)   # whole: nothing to treat
	var food := a.update(0, apple, arm, 0.4) == VrAid.NONE
	var ticks := rig.buzzes[0]
	var near: bool = a.update(0, bandage, arm, 0.4) == VrAid.NEAR and a.mark_shown(0) and a.part_of(0) == "arm_r" \
			and rig.buzzes[0] == ticks + 1 and be.calls.is_empty()
	var sent: bool = a.update(0, bandage, arm, 0.4) == VrAid.SENT and be.calls == [[41.0, 1.0, "arm_r"]] \
			and not a.mark_shown(0) and acts.pending(41) == "consume"
	var mouth := not rig.mouth.edible(1, ItemRef.on_player(42, 2, 0, -1, 0, SQ)) and rig.mouth.edible(1, apple)
	_check.call(head and food and near and sent and mouth,
			"vr aid: a bandage at a bleeding forearm lights it, then sends consume on arm_r; not a whole head, not food; the mouth leaves first aid alone (%s)"
			% [be.calls])
	acts.on_events([{"kind": "item_result", "detail": be.tags[0], "amount": 0,
			"text": "You don't expect any effect from using this."}])
	var said: bool = rig.notes[0] != null and rig.notes[0].visible \
			and rig.notes[0].text == "You don't expect any effect from using this."
	var held := a.update(0, bandage, arm, 1.0) == VrAid.NONE   # not again before leaving the part
	a.update(0, bandage, Vector3(0.6, 1.4, -0.6), 0.1)
	var chest := eyes.origin + Vector3.DOWN * VrAid.CHEST_DOWN + Vector3.FORWARD * VrAid.CHEST_AHEAD
	a.update(0, bandage, chest, 0.4)
	var torso: bool = a.update(0, bandage, chest, 0.4) == VrAid.SENT and be.calls[-1] == [41.0, 1.0, "torso"]
	var one: bool = a._watch.size() == 1 and a._watch.has(41) and a._watch[41]["part"] == "torso"
	acts.on_events([{"kind": "item_result", "detail": be.tags[-1], "amount": 1}])   # CDDA done ...
	var before: String = rig.notes[0].text
	a.watch(0.5)   # ... the snapshot doesn't show it yet: nothing said
	var waits: bool = a._watch.has(41) and rig.notes[0].text == before
	var b0: int = rig.buzzes[0]
	(rig.world.snapshot.player_parts[0] as Snapshot.BodyPart).bandaged = 2   # now it does
	a.watch(0.1)
	var shown: bool = rig.notes[0].text == "Chest: bandaged" and rig.notes[0].modulate.g > rig.notes[0].modulate.r \
			and rig.buzzes[0] == b0 + 1 and a._watch.is_empty()
	a.update(0, bandage, Vector3(0.6, 1.4, -0.6), 0.1)   # once more; done, but the snapshot never shows it
	a.update(0, bandage, chest, 0.4)
	var again: bool = a.update(0, bandage, chest, 0.4) == VrAid.SENT and a._watch.has(41)
	acts.on_events([{"kind": "item_result", "detail": be.tags[-1], "amount": 1}])
	var b1: int = rig.buzzes[0]
	for k in int((VrAid.AFTER_S - 0.5) / 0.5):   # (a frame's delta counts at most 1 s)
		a.watch(0.5)
	var kept: bool = a._watch.has(41)
	a.watch(0.5)
	a.watch(0.5)
	var let_go: bool = a._watch.is_empty() and rig.notes[0].text == "Chest: bandaged" and rig.buzzes[0] == b1
	a.update(0, bandage, Vector3(0.6, 1.4, -0.6), 0.1)   # sent again, then the game left: forgotten
	a.update(0, bandage, chest, 0.4)
	a.update(0, bandage, chest, 0.4)
	acts.clear()
	var words := [VrAid.treated("arm_l", {"bleed": 5, "bandaged": 0, "disinfected": 0, "bite": 0, "infected": 0},
			{"bleed": 0, "bandaged": 3, "disinfected": 2, "bite": 0, "infected": 0}),
			VrAid.treated("leg_r", {"bleed": 9, "bandaged": 0, "disinfected": 0, "bite": 4, "infected": 0},
			{"bleed": 3, "bandaged": 0, "disinfected": 0, "bite": 0, "infected": 0}),
			VrAid.treated("head", {"bleed": 0, "bandaged": 0, "disinfected": 0, "bite": 0, "infected": 0},
			{"bleed": 0, "bandaged": 0, "disinfected": 0, "bite": 0, "infected": 0}),
			VrAid.treated("torso", {}, {"bleed": 0, "bandaged": 1, "disinfected": 0, "bite": 0, "infected": 0})]
	_check.call(said and held and torso and a._sent.is_empty() and a._watch.is_empty(),
			"vr aid: CDDA's no by that hand; again only after leaving the part; the chest is the torso; the game left forgets it (%s)"
			% [be.calls])
	_check.call(one and waits and shown and again and kept and let_go
			and words == ["Left arm: bleeding stopped, bandaged, disinfected", "Right leg: bleeding slowed, treated", "", ""],
			"vr aid: once the snapshot shows a treatment on that part, it says so by the hand in green with a buzz; done but never shown: let go %.0f s after; a refused one isn't watched (%s)"
			% [VrAid.AFTER_S, [one, waits, shown, again, kept, let_go, words]])
