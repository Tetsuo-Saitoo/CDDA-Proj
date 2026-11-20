class_name GazeEffects
extends Node
## Eye-tracking effects that only change the picture, never the game (the user's eye-tracking ideas 4 and 8,
## 2026-11-19). They work only while the eyes themselves are tracked (`gaze`: VrRig.look, "eyes" true); with eye
## tracking off, no tracker or the head's gaze, they ease back to nothing and the view is as it was. Each has its own
## switch (the "Eye tracking" settings, lead-ui's), both off by default. WorldLighting's pass draws them.
##
## (4) Eyes adjust to light (`adapt_on`): gazing at dark places, the seen, lit parts of the view slowly brighten
## (up to BOOST_MAX over about DARK_S); a bright look takes it back quickly. Night-dark and unseen squares stay as
## dark as they were (the pass only brightens lit pixels), so the eyes show nothing CDDA hides. Gazing into a fire,
## lamp or flashlight (a LightMap source of at least GLARE_MIN within GLARE_DEG of the gaze, not behind what the gaze
## meets) dims the rest of the view for a moment (GLARE_DOWN_S).
##
## (8) Peripheral unease (`unease_on`): now and then a faint soft shadow drifts and flickers 28 to 45 degrees off
## the gaze, and fades as the gaze reaches it. Round and shapeless (never a creature's shape), at most SHADE_MAX
## darker, and never on or near a creature the player perceives: it isn't started there and goes at once when one
## comes near, so it can neither fake a zombie nor hide one.
##
## Privacy: the gaze is read each frame and dropped. Nothing of it is logged, saved or sent.

const SAMPLE_S := 0.2         # how often the gazed square's light is looked up (LookRay)
const SAMPLE_M := 40.0
const DARK_LO := 0.12         # LightMap.tile_brightness gazed at: at or under this the eyes adjust to the dark
const DARK_HI := 0.35         # at or over: to the light
const DARK_S := 4.0           # time constant (s): adjusting to the dark
const LIGHT_S := 0.4          # back to the light
const BOOST_MAX := 0.6        # lit pixels at most this much brighter (WorldLighting: gaze_boost)
const GLARE_DEG := 6.0
const GLARE_MIN := 20         # CDDA light level of a source bright enough to dazzle
const GLARE_UP_S := 0.1
const GLARE_DOWN_S := 1.0
const GLARE_MAX := 0.45       # the rest of the view at most this much darker
const BLOBS := 3              # shadows at once (WorldLighting.GAZE_BLOBS)
const SHADE_MAX := 0.3        # a shadow darkens at most this much (the shader's own cap too)
const UNEASE_EVERY := Vector2(4.0, 10.0)   # seconds between shadows
const UNEASE_OFF_DEG := Vector2(28.0, 45.0)
const UNEASE_R_DEG := Vector2(7.0, 12.0)
const UNEASE_LIFE := Vector2(2.5, 5.0)
const UNEASE_FADE_S := 0.8
const UNEASE_DRIFT_DEG := 4.0   # at most this many degrees a second sideways
const SEEN_DEG := 14.0        # a shadow this close to the gaze is gone; it fades from twice this
const CREATURE_MARGIN_DEG := 6.0
const CREATURE_M := 60.0
const MAX_CREATURES := 256
const MAX_STEP_S := 0.25

var adapt_on := false
var unease_on := false
## () -> Dictionary: the gaze this frame, {"from": Vector3, "dir": Vector3, "eyes": bool} (VrRig.look).
var gaze := Callable()
## The pass that draws the effects (WorldView.lighting); null: nothing is drawn (tests).
var lighting: WorldLighting
var world: WorldView
## (from, dir) -> [brightness gazed at (0..1), glare (0..1)]: what the eyes see; default `sample_world`.
var sample := Callable()
## () -> Array[Vector3]: where the creatures the player perceives are (world); default from world.snapshot.
var creature_points := Callable()

var dark := 0.0               # 0..1: how far the eyes have adjusted to the dark
var glare := 0.0              # 0..1
var glare_dir := Vector3.FORWARD
var blobs: Array[Blob] = []
var rng := RandomNumberGenerator.new()

var _sample_in := 0.0
var _seen := 1.0
var _glare_seen := 0.0
var _next_blob := 0.0
var _look_ray: LookRay
var _pushed_neutral := true


## A peripheral shadow: a direction from the eyes (world), its radius, its life and flicker.
class Blob:
	var dir := Vector3.FORWARD
	var r_deg := 6.0
	var age := 0.0
	var life := 4.0
	var phase := 0.0
	var drift := 0.0          # radians a second about the vertical
	var strength := 0.0       # 0..1 now


func _init() -> void:
	name = "GazeEffects"
	rng.randomize()
	_next_blob = rng.randf_range(UNEASE_EVERY.x, UNEASE_EVERY.y)


func _process(delta: float) -> void:
	step(delta)


## One frame `delta` seconds on.
func step(delta: float) -> void:
	delta = clampf(delta, 0.0, MAX_STEP_S) if is_finite(delta) else 0.0
	if not adapt_on and not unease_on and _neutral():
		_push()
		return
	var g := _gaze()
	var eyes := not g.is_empty()
	var dark_to := 0.0
	var glare_to := 0.0
	if adapt_on and eyes:
		_sample_in -= delta
		if _sample_in <= 0.0:
			_sample_in = SAMPLE_S
			_look(g["from"], g["dir"])
		dark_to = 1.0 - smoothstep(DARK_LO, DARK_HI, _seen)
		glare_to = _glare_seen
		if glare_to > 0.0:
			glare_dir = g["dir"]
	else:
		_sample_in = 0.0
	dark = _toward(dark, dark_to, DARK_S if dark_to > dark else LIGHT_S, delta)
	glare = _toward(glare, glare_to, GLARE_UP_S if glare_to > glare else GLARE_DOWN_S, delta)
	_unease(delta, g if unease_on else {})
	_push()


## The extra brightness of lit pixels now (WorldLighting gaze_boost).
func boost() -> float:
	return BOOST_MAX * dark


## The gaze if the eyes drive it and it is believable, else {}.
func _gaze() -> Dictionary:
	var g: Variant = gaze.call() if gaze.is_valid() else null
	if not g is Dictionary or (g as Dictionary).get("eyes") != true:
		return {}
	var from: Variant = (g as Dictionary).get("from")
	var dir: Variant = (g as Dictionary).get("dir")
	if not from is Vector3 or not dir is Vector3 or not (from as Vector3).is_finite() or not (dir as Vector3).is_finite():
		return {}
	if (dir as Vector3).length() < 0.5:
		return {}
	return {"from": from, "dir": (dir as Vector3).normalized()}


func _look(from: Vector3, dir: Vector3) -> void:
	var s: Variant = sample.call(from, dir) if sample.is_valid() else sample_world(from, dir)
	if s is Array and (s as Array).size() == 2 and (s[0] is float or s[0] is int) and (s[1] is float or s[1] is int):
		_seen = clampf(float(s[0]), 0.0, 1.0) if is_finite(float(s[0])) else 1.0
		_glare_seen = clampf(float(s[1]), 0.0, 1.0) if is_finite(float(s[1])) else 0.0
	else:
		_seen = 1.0
		_glare_seen = 0.0


## What the eyes see along (from, dir) in the shown world: [the brightness of the square met (LightMap's
## tile_brightness; the sky's when nothing is met), the glare of the brightest light source near the gaze line and
## not behind what it meets]. [1, 0] without a light map.
func sample_world(from: Vector3, dir: Vector3) -> Array:
	if world == null or lighting == null or lighting.map == null or world.snapshot == null:
		return [1.0, 0.0]
	var map := lighting.map
	if _look_ray == null:
		_look_ray = LookRay.new(world)
	var hit := _look_ray.cast(from, dir, SAMPLE_M, false, true)
	var seen := map.sky.get_luminance()
	var far := SAMPLE_M
	if hit.get("hit", false):
		var sq: Vector3i = hit["square"]
		far = from.distance_to(hit["point"])
		var t := map.texel(sq.x - map.origin_ms.x, sq.y - map.origin_ms.y, sq.z)
		seen = LightMap.tile_brightness(t.x, t.y) if t.x >= 0 else 1.0
	var gl := 0.0
	for s: LightMap.Source in map.sources:
		if s.luminance < GLARE_MIN:
			continue
		var h := 0.4 if s.kind == Snapshot.LIGHT_FIRE else (1.0 if s.kind == Snapshot.LIGHT_ITEM else 1.5)
		var v := world.coords.ms_center_to_world(s.square) + Vector3(0.0, h, 0.0) - from
		var d := v.length()
		if d < 0.5 or d > far + 1.5:
			continue
		if rad_to_deg(v.angle_to(dir)) <= maxf(GLARE_DEG, rad_to_deg(atan(0.5 / d))):
			gl = maxf(gl, clampf(s.luminance / 100.0, 0.3, 1.0))
	return [seen, gl]


## The peripheral shadows: started in the gaze's periphery now and then, drifting, flickering; gone when looked at,
## when their time is up, near a creature, and at once when unease is off or the eyes aren't tracked.
func _unease(delta: float, g: Dictionary) -> void:
	if g.is_empty():
		blobs.clear()   # at once: without the eyes there's no gaze to keep them off creatures by
		return
	var near := _creature_dirs(g["from"])
	_next_blob -= delta
	if _next_blob <= 0.0:
		_next_blob = rng.randf_range(UNEASE_EVERY.x, UNEASE_EVERY.y)
		if blobs.size() < BLOBS:
			_spawn(g["dir"], near)
	var kept: Array[Blob] = []
	for b in blobs:
		b.age += delta
		b.dir = b.dir.rotated(Vector3.UP, b.drift * delta).normalized()
		var looked := rad_to_deg((g["dir"] as Vector3).angle_to(b.dir))
		if looked < SEEN_DEG or b.age >= b.life or _near(b.dir, b.r_deg, near):
			continue
		var fade := minf(1.0, minf(b.age / UNEASE_FADE_S, (b.life - b.age) / UNEASE_FADE_S))
		var flicker := 0.7 + 0.3 * sin(b.age * 7.3 + b.phase) * sin(b.age * 2.9 + b.phase * 1.7)
		b.strength = clampf(fade * smoothstep(SEEN_DEG, SEEN_DEG * 2.0, looked) * flicker, 0.0, 1.0)
		kept.append(b)
	blobs = kept


func _spawn(gaze_dir: Vector3, near: Array[Vector3]) -> void:
	var side := gaze_dir.cross(Vector3.UP)
	if side.length() < 0.1:
		side = gaze_dir.cross(Vector3.RIGHT)
	side = side.normalized()
	for attempt in 4:
		var axis := side.rotated(gaze_dir, rng.randf_range(0.0, TAU))
		var d := gaze_dir.rotated(axis, deg_to_rad(rng.randf_range(UNEASE_OFF_DEG.x, UNEASE_OFF_DEG.y))).normalized()
		var r := rng.randf_range(UNEASE_R_DEG.x, UNEASE_R_DEG.y)
		if d.y > 0.2 or d.y < -0.6 or _near(d, r, near):   # low, where shadows lie; never by a creature
			continue
		var b := Blob.new()
		b.dir = d
		b.r_deg = r
		b.life = rng.randf_range(UNEASE_LIFE.x, UNEASE_LIFE.y)
		b.phase = rng.randf_range(0.0, TAU)
		b.drift = deg_to_rad(rng.randf_range(-UNEASE_DRIFT_DEG, UNEASE_DRIFT_DEG))
		blobs.append(b)
		return


## Directions (unit, world) from `from` to the creatures the player perceives within CREATURE_M.
func _creature_dirs(from: Vector3) -> Array[Vector3]:
	var pts: Variant = creature_points.call() if creature_points.is_valid() else _creature_world()
	var out: Array[Vector3] = []
	if not pts is Array:
		return out
	for p: Variant in pts:
		if out.size() >= MAX_CREATURES:
			break
		if p is Vector3 and (p as Vector3).is_finite():
			var v: Vector3 = (p as Vector3) - from
			if v.length() > 0.05 and v.length() <= CREATURE_M:
				out.append(v.normalized())
	return out


func _creature_world() -> Array:
	var out := []
	if world == null or world.snapshot == null:
		return out
	for c: Snapshot.Creature in world.snapshot.creatures:
		if c.kind != Snapshot.Creature.PLAYER and out.size() < MAX_CREATURES:
			out.append(world.coords.ms_center_to_world(c.pos) + Vector3(0.0, 1.0, 0.0))
	return out


static func _near(d: Vector3, r_deg: float, dirs: Array[Vector3]) -> bool:
	for c in dirs:
		if rad_to_deg(d.angle_to(c)) < r_deg + CREATURE_MARGIN_DEG:
			return true
	return false


static func _toward(v: float, to: float, tau: float, delta: float) -> float:
	return lerpf(v, to, 1.0 - exp(-delta / tau)) if absf(to - v) > 1e-4 else to


func _neutral() -> bool:
	return dark == 0.0 and glare == 0.0 and blobs.is_empty()


func _push() -> void:
	if lighting == null:
		return
	if _neutral():
		if not _pushed_neutral:
			lighting.set_gaze(0.0, 0.0, glare_dir, [])
			_pushed_neutral = true
		return
	var data := []
	for b in blobs:
		data.append([b.dir, cos(deg_to_rad(b.r_deg)), b.strength])
	lighting.set_gaze(boost(), GLARE_MAX * glare, glare_dir, data)
	_pushed_neutral = false
