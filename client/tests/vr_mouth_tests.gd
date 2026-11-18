extends RefCounted
## Eat or drink in VR (VrMouth, VrRig `mouth`): food or a drink held at the mouth HOLD_S sends CDDA's consume once;
## not a passing hand, not what isn't food, not twice without leaving the mouth; CDDA's no by that hand.

const SQ := Vector3i(5, 5, 0)

var _check: Callable


class Backend:
	extends RefCounted
	var calls: Array = []
	var tags: Array = []

	func consume_item(uid: float, type: float, tag := 0) -> bool:
		calls.append([uid, type])
		tags.append(tag)
		return true

	func queued_actions() -> int:
		return 0


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr mouth")
	var t := IdTables.from_data({"generation": 1, "ter": [{"id": "t_null"}], "furn": [], "trap": [], "field": [],
			"itype": [{"id": ""}, {"id": "apple", "category": "food"}, {"id": "bottle", "category": "container"},
			{"id": "water", "category": "food"}, {"id": "rock", "category": "other"}]})
	var snap := Snapshot.new()
	snap.seq = 5
	var c := PackedInt64Array()
	for row: Array in [[41, 1, 0, -1, 0], [42, 2, 0, -1, 0], [43, 3, 42, 0, 0], [44, 4, 0, -1, 0]]:
		c.append_array(PackedInt64Array(row))   # apple 41; bottle 42 > water 43; rock 44
	snap.carried = c
	var world := WorldView.new()
	world.tables = t
	world.snapshot = snap
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	var acts := ItemActions.new()
	var b := Backend.new()
	acts.backend = b
	acts.on_snapshot(snap)
	rig.mouth.actions = acts
	var hints: Array[String] = []
	rig.hint_due.connect(func(id: String) -> void: hints.append(id))
	_test_point()
	_test_eat(rig, acts, b, hints)
	acts.free()
	rig.free()
	world.free()


## The mouth is under and a little ahead of the eyes, and turns with the head.
func _test_point() -> void:
	var ahead := VrMouth.point(Transform3D.IDENTITY)
	var turned := VrMouth.point(Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(1, 1.6, 0)))
	_check.call(ahead.is_equal_approx(Vector3(0, -VrMouth.BELOW, -VrMouth.AHEAD))
			and turned.is_equal_approx(Vector3(1.0 - VrMouth.AHEAD, 1.6 - VrMouth.BELOW, 0)),
			"vr mouth: under and ahead of the eyes, turning with the head (%s, %s)" % [ahead, turned])


func _test_eat(rig: VrRig, acts: ItemActions, b: Backend, hints: Array[String]) -> void:
	var m := rig.mouth
	var at := VrMouth.point(rig.camera.global_transform)
	var apple := ItemRef.on_player(41, 1, 0, -1, 0, SQ)
	var rock := ItemRef.on_player(44, 4, 0, -1, 0, SQ)
	var far := m.update(0, apple, at + Vector3(0, -0.4, 0), 0.6)
	var not_food := m.update(0, rock, at, 0.6) == VrMouth.NONE and m.update(0, rock, at, 0.6) == VrMouth.NONE
	var ticks := rig.buzzes[0]
	var near := m.update(0, apple, at, 0.3)
	var tick := rig.buzzes[0] == ticks + 1
	var passing := m.update(0, apple, at + Vector3(0, 0, -0.3), 0.3)   # gone before HOLD_S: starts over
	var waits: bool = m.update(0, apple, at, 0.3) == VrMouth.NEAR and b.calls.is_empty()
	var sent := m.update(0, apple, at, 0.3)
	var once: bool = m.update(0, apple, at, 2.0) == VrMouth.NONE and b.calls.size() == 1
	_check.call(far == VrMouth.NONE and not_food and near == VrMouth.NEAR and tick and passing == VrMouth.NONE
			and waits and sent == VrMouth.SENT and once and b.calls[0] == [41.0, 1.0] and acts.pending(41) == "consume"
			and hints == ["vr_eat"],
			"vr mouth: food held at the mouth HOLD_S eats it once (CDDA's consume); not far, not a rock, not passing (%s)"
			% [b.calls])
	acts.on_events([{"kind": "item_result", "detail": b.tags[0], "amount": 0, "text": "You're full."}])
	var said: bool = rig.notes[0] != null and rig.notes[0].visible and rig.notes[0].text == "You're full."
	m.update(0, apple, at + Vector3(0, -0.5, 0), 0.1)   # away from the mouth: it may again
	var again: bool = m.update(0, apple, at, 0.6) == VrMouth.SENT and b.calls.size() == 2
	var bottle := ItemRef.on_player(42, 2, 0, -1, 0, SQ)
	m.update(1, bottle, at, 0.3)
	var drink: bool = m.update(1, bottle, at, 0.3) == VrMouth.SENT and b.calls[-1] == [42.0, 2.0]
	_check.call(said and again and drink,
			"vr mouth: CDDA's no by that hand; again after leaving the mouth; a bottle in the other hand drinks (%s)"
			% [b.calls])
