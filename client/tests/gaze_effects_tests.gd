extends RefCounted
## GazeEffects (eye tracking, visual only) with a simulated gaze: off or without tracked eyes nothing changes; eyes
## adjust to the dark slowly and to the light fast; a light gazed into dims the rest for a moment; peripheral
## shadows appear only off the gaze and away from creatures, fade when looked at, and are bounded; hostile gaze is
## ignored; WorldLighting gets the values, neutral when nothing is on.

var _check: Callable


func run(check: Callable) -> void:
	_check = check
	_test_off()
	_test_adapt()
	_test_glare()
	_test_unease()
	_test_hostile()


class Sim:
	var g := {"from": Vector3(0, 1.6, 0), "dir": Vector3(0, 0, -1), "eyes": true}
	var seen := 1.0
	var glare := 0.0
	var creatures: Array = []
	func gaze() -> Dictionary: return g
	func sample(_from: Vector3, _dir: Vector3) -> Array: return [seen, glare]
	func points() -> Array: return creatures


func _make(sim: Sim) -> GazeEffects:
	var fx := GazeEffects.new()
	fx.gaze = sim.gaze
	fx.sample = sim.sample
	fx.creature_points = sim.points
	fx.lighting = WorldLighting.new()
	fx.rng.seed = 7
	return fx


func _run(fx: GazeEffects, seconds: float, each := Callable()) -> void:
	for i in roundi(seconds * 30.0):
		fx.step(1.0 / 30.0)
		if each.is_valid():
			each.call()


## Steps until a shadow is up (at most a minute of game time); whether one is.
func _until_blob(fx: GazeEffects) -> bool:
	for i in 1800:
		if not fx.blobs.is_empty():
			return true
		fx.step(1.0 / 30.0)
	return not fx.blobs.is_empty()


func _free(fx: GazeEffects) -> void:
	fx.lighting.free()
	fx.free()


func _test_off() -> void:
	var sim := Sim.new()
	sim.seen = 0.03
	sim.glare = 1.0
	var fx := _make(sim)
	_run(fx, 10.0)
	var off_ok := fx.boost() == 0.0 and fx.glare == 0.0 and fx.blobs.is_empty() and fx._neutral()
	fx.adapt_on = true
	fx.unease_on = true
	sim.g["eyes"] = false   # the head's gaze: eye tracking off or not tracked
	_run(fx, 15.0)
	var head_ok := fx.boost() == 0.0 and fx.glare == 0.0 and fx.blobs.is_empty()
	sim.g["eyes"] = true
	_run(fx, 15.0)
	var on := fx.boost() > 0.0 and float(fx.lighting.gaze_now()["boost"]) > 0.0
	fx.adapt_on = false
	fx.unease_on = false
	_run(fx, 12.0)   # the glare fades last (GLARE_DOWN_S)
	var g: Dictionary = fx.lighting.gaze_now()
	_check.call(off_ok and head_ok and on and fx.boost() < 0.01 and fx.blobs.is_empty() and fx._neutral()
			and float(g["boost"]) == 0.0 and float(g["glare"]) == 0.0,
			"gaze fx: off, or with the head's gaze, nothing changes; switched off again, the view eases back to as it was")
	_free(fx)


func _test_adapt() -> void:
	var sim := Sim.new()
	var fx := _make(sim)
	fx.adapt_on = true
	sim.seen = 0.04   # a dark room
	_run(fx, 1.0)
	var after1 := fx.boost()
	_run(fx, 14.0)
	var after15 := fx.boost()
	sim.seen = 0.8    # a lit window
	_run(fx, 1.5)
	var back := fx.boost()
	_check.call(after1 > 0.0 and after1 < 0.3 * GazeEffects.BOOST_MAX and after15 > 0.9 * GazeEffects.BOOST_MAX
			and after15 <= GazeEffects.BOOST_MAX and back < 0.1 * GazeEffects.BOOST_MAX,
			"gaze fx: gazing into the dark the view slowly brightens (%.2f after 1 s, %.2f after 15), a bright look takes it back fast (%.2f)" % [after1, after15, back])
	_free(fx)


func _test_glare() -> void:
	var sim := Sim.new()
	var fx := _make(sim)
	fx.adapt_on = true
	sim.g["dir"] = Vector3(1, 0, 0)
	sim.glare = 1.0   # a fire in the gaze
	_run(fx, 0.4)
	var up := fx.glare
	var dir_ok := fx.glare_dir.is_equal_approx(Vector3(1, 0, 0)) \
			and is_equal_approx(float(fx.lighting.gaze_now()["glare"]), GazeEffects.GLARE_MAX * fx.glare)
	sim.glare = 0.0
	sim.g["dir"] = Vector3(0, 0, -1)
	_run(fx, 0.4)
	var moment := fx.glare
	_run(fx, 4.0)
	_check.call(up > 0.9 and dir_ok and moment > 0.3 and fx.glare < 0.05,
			"gaze fx: looking into a light dims the rest of the view (%.2f), for a moment after looking away (%.2f, then %.2f)" % [up, moment, fx.glare])
	_free(fx)


func _test_unease() -> void:
	var sim := Sim.new()
	var fx := _make(sim)
	fx.unease_on = true
	var w := {"seen": 0, "worst": 180.0, "strong": 0.0, "count": 0}   # lambdas copy locals: a shared dictionary
	var watch := func() -> void:
		w["count"] = maxi(w["count"], fx.blobs.size())
		for b: GazeEffects.Blob in fx.blobs:
			w["worst"] = minf(w["worst"], rad_to_deg(b.dir.angle_to(sim.g["dir"])))
			w["strong"] = maxf(w["strong"], b.strength)
			w["seen"] += 1
	_run(fx, 40.0, watch)
	_check.call(w["seen"] > 0 and w["worst"] >= GazeEffects.SEEN_DEG and w["strong"] <= 1.0 and w["strong"] > 0.0
			and w["count"] <= GazeEffects.BLOBS,
			"gaze fx: faint shadows come and go off the gaze (%d frames, at least %.0f degrees off, at most %d at once)" % [w["seen"], w["worst"], w["count"]])
	# looked at: gone
	var gone := false
	if _until_blob(fx):
		var b0: GazeEffects.Blob = fx.blobs[0]
		sim.g["dir"] = b0.dir
		fx.step(1.0 / 30.0)
		gone = not fx.blobs.has(b0)
	# a creature coming near one: gone at once
	sim.g["dir"] = Vector3(0, 0, -1)
	fx.blobs.clear()
	var spared := false
	if _until_blob(fx):
		var b1: GazeEffects.Blob = fx.blobs[0]
		sim.creatures = [(sim.g["from"] as Vector3) + b1.dir * 10.0]
		fx.step(1.0 / 30.0)
		spared = not fx.blobs.has(b1)
	# creatures all around (every 10 degrees, low and level): none is started
	sim.creatures = []
	for a in range(0, 360, 10):
		for y: float in [-0.6, -0.3, 0.0, 0.2]:
			sim.creatures.append((sim.g["from"] as Vector3) + Vector3(cos(deg_to_rad(a)), y, sin(deg_to_rad(a))) * 10.0)
	fx.blobs.clear()
	var started := [0]
	_run(fx, 40.0, func() -> void: started[0] += fx.blobs.size())
	sim.creatures = []
	_check.call(gone and spared and started[0] == 0,
			"gaze fx: a shadow looked at fades away; none near a creature (one comes near: gone at once; all around: none)")
	# eyes lost: the shadows go at once
	var up := _until_blob(fx)
	sim.g["eyes"] = false
	fx.step(1.0 / 30.0)
	_check.call(up and fx.blobs.is_empty(), "gaze fx: without tracked eyes the shadows go at once")
	_free(fx)


func _test_hostile() -> void:
	var sim := Sim.new()
	var fx := _make(sim)
	fx.adapt_on = true
	fx.unease_on = true
	sim.seen = 0.03
	sim.g["dir"] = Vector3(NAN, 0, 0)
	_run(fx, 5.0)
	var nan_ok := fx.boost() == 0.0 and fx.blobs.is_empty()
	sim.g["dir"] = Vector3.ZERO
	_run(fx, 5.0)
	var zero_ok := fx.boost() == 0.0
	sim.g = {"from": "x", "dir": 3, "eyes": true}
	_run(fx, 1.0)
	var junk_ok := fx.boost() == 0.0
	sim.g = {"from": Vector3(0, 1.6, 0), "dir": Vector3(0, 0, -1), "eyes": true}
	sim.seen = NAN
	sim.glare = INF
	_run(fx, 3.0)
	var bad_sample := fx.boost() == 0.0 and fx.glare == 0.0
	fx.step(NAN)
	fx.step(-5.0)
	fx.step(1e9)
	fx.lighting.set_gaze(NAN, INF, Vector3(NAN, 0, 0), [[Vector3.ZERO, 2.0, 5.0], "x", [Vector3(0, 1, 0), NAN, 1.0]])
	var g: Dictionary = fx.lighting.gaze_now()
	var blobs: PackedVector4Array = g["blobs"]
	_check.call(nan_ok and zero_ok and junk_ok and bad_sample and float(g["boost"]) == 0.0 and float(g["glare"]) == 0.0
			and blobs.size() == WorldLighting.GAZE_BLOBS and blobs[0].w == 0.0 and blobs[2].w == 0.0,
			"gaze fx: a broken gaze, sample or step is ignored; the pass bounds what it is given")
	_free(fx)
