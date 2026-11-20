extends RefCounted
## C5, VR riding (VrRide, VrRig.ride_along): standing on the player's vehicle, the rig is carried as the vehicle is
## drawn gliding (moved and turned, never tilted, its height its own); off the vehicle, or no vehicle: nothing; a map
## shift doesn't carry it twice.

var _check: Callable
var _now: Array = []   # what the ride stub returns (a member: lambdas copy locals)


func run(root: Node, check: Callable) -> void:
	_check = check
	print("vr ride")
	var world := WorldView.new()
	var snap := Snapshot.new()
	snap.player_pos = Vector3i(11, 10, 0)
	var car := Snapshot.Vehicle.new()
	car.uid = 7
	car.pos = Vector3i(10, 10, 0)
	car.parts = _parts(3)
	snap.vehicles = [car] as Array[Snapshot.Vehicle]
	snap.vehicles_moved()
	world.snapshot = snap
	var rig := VrRig.new(world, {"blink": false})
	root.add_child(rig)
	rig.camera.position = Vector3(0, 1.6, 0)
	_test_carry(rig, world, car)
	_test_unit()
	rig.free()
	world.free()


## `n` parts in a row going east from the vehicle's position (frame-like rows: mount, vpart 1, whole, square).
static func _parts(n: int) -> PackedInt32Array:
	var p := PackedInt32Array()
	for i in n:
		p.append_array(PackedInt32Array([i, 0, 1, 255, 0, i, 0, 0]))
	return p


func _test_carry(rig: VrRig, world: WorldView, car: Snapshot.Vehicle) -> void:
	var c := world.coords
	var head0 := c.ms_center_to_world(Vector3i(11, 10, 0))
	rig.global_position += Vector3(head0.x - rig.camera.global_position.x, 0.0, head0.z - rig.camera.global_position.z)
	var y0 := rig.global_position.y
	var d0 := Transform3D(Basis(), c.ms_to_world(Vector3i(10, 10, 0)))
	_now = [7, d0, d0]
	rig.ride = func() -> Array: return _now
	rig.ride_along()
	var starts: bool = rig.riding.following() == 7 and _xz(rig.camera.global_position).is_equal_approx(_xz(head0))
	# The snapshot put the car 3 squares east; it is drawn 1 m on its way (and a little up a ramp).
	car.pos = Vector3i(13, 10, 0)
	world.snapshot.vehicles_moved()
	var d1 := Transform3D(Basis(), d0.origin + Vector3(1.0, 0.3, 0.0))
	_now = [7, d1, Transform3D(Basis(), c.ms_to_world(Vector3i(13, 10, 0)))]
	rig.ride_along()
	var head1 := rig.camera.global_position
	var moved: bool = _xz(head1).is_equal_approx(_xz(head0) + Vector2(1.0, 0.0)) and is_equal_approx(rig.global_position.y, y0)
	# It turns a quarter left about its position, arrived (drawn where the snapshot has it).
	car.pos = Vector3i(12, 10, 0)
	world.snapshot.vehicles_moved()
	var basis0 := rig.global_basis
	var d2 := Transform3D(Basis(Vector3.UP, PI / 2.0), d1.origin)
	_now = [7, d2, d2]
	rig.ride_along()
	var rel := head1 - d1.origin
	var want := d1.origin + Vector3(rel.z, 0.0, -rel.x)
	var head2 := rig.camera.global_position
	var turned: bool = Vector2(head2.x, head2.z).is_equal_approx(Vector2(want.x, want.z)) \
			and rig.global_basis.is_equal_approx(Basis(Vector3.UP, PI / 2.0) * basis0) \
			and is_equal_approx(rig.global_position.y, y0)
	_check.call(starts and moved and turned,
			"vr ride: on the player's car the rig is carried as it glides: moved, turned a quarter about it, never raised (%s, %s)"
			% [head1, head2])
	# Off it: the car moves on without the rig.
	car.pos = Vector3i(30, 10, 0)
	world.snapshot.vehicles_moved()
	var before := rig.global_transform
	var d3 := d2.translated(Vector3(5.0, 0.0, 0.0))
	_now = [7, d3, d3]
	rig.ride_along()
	var off: bool = rig.global_transform.is_equal_approx(before) and rig.riding.following() == 0
	_now = []
	rig.ride_along()
	var none: bool = rig.global_transform.is_equal_approx(before)
	_now = [7, Transform3D(Basis(), Vector3(NAN, 0, 0)), d3]
	rig.ride_along()
	none = none and rig.global_transform.is_equal_approx(before)
	_now = ["7", d3, d3]
	rig.ride_along()
	none = none and rig.global_transform.is_equal_approx(before)
	_check.call(off and none, "vr ride: off the car, no car or junk from the callable: the rig stays where it is")
	# On it again, then the map's origin shifts: rig and car move by the same; no extra carry.
	var head3 := rig.camera.global_position
	var under := world.coords.world_to_ms(head3)
	car.pos = Vector3i(under.x, under.y, 0)
	world.snapshot.vehicles_moved()
	_now = [7, d3, d3]
	rig.ride_along()
	var dshift := Vector3(-64.0, 0.0, 32.0)
	rig.shift(dshift)
	var d4 := d3.translated(dshift)
	_now = [7, d4, d4]
	under = world.coords.world_to_ms(rig.camera.global_position - dshift)   # the snapshot's squares don't shift
	rig.ride = func() -> Array:
		var s := rig.camera.global_position
		return [7, d4, d4.translated(-dshift)] if world.coords.world_to_ms(s - dshift) == under else []
	rig.ride_along()
	var shifted: bool = rig.camera.global_position.is_equal_approx(head3 + dshift) and rig.riding.following() == 7
	_check.call(shifted, "vr ride: a map shift moves rig and car alike: no extra carry (%s)" % [rig.camera.global_position])


static func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## VrRide alone: a vehicle leaning on a ramp tilts nothing; another vehicle starts afresh.
func _test_unit() -> void:
	var r := VrRide.new()
	var rig := Transform3D(Basis(), Vector3(2, 0, 3))
	var head := Vector3(2.2, 1.6, 2.9)
	r.carry(rig, head, 5, Transform3D())
	var lean := Transform3D(Basis(Vector3.RIGHT, 0.4), Vector3(0, 0.5, 0))
	var out := r.carry(rig, head, 5, lean)
	var flat: bool = out.basis.is_equal_approx(rig.basis) and is_equal_approx(out.origin.y, rig.origin.y)
	var other := r.carry(rig, head, 6, Transform3D(Basis(), Vector3(9, 0, 9)))
	var fresh: bool = other.is_equal_approx(rig) and r.following() == 6
	_check.call(flat and fresh, "vr ride: a leaning vehicle never tilts the rig or lifts it; another vehicle starts afresh (%s)"
			% [out])
