class_name PrecipView
extends Node3D
## Blocks C6 / I2: rain and snow around the player.
##
## Two GPUParticles3D (rain streaks, snow flakes) with engine materials only. Drops start above the squares near the
## player that are open to the sky and whose way down is clear of roofs (landing_squares), so nothing falls indoors
## or under a roof, also when the wind leans the fall; what falls outside shows through the windows. Bounded: at
## most MAX_RAIN / MAX_SNOW particles within RADIUS squares of the player, fewer for lighter weather and for less
## open ground. The GPU moves them (once a frame, not per eye); the start points are worked out again only when
## the player has walked a few squares, or the wind or the map nearby changes.

const RADIUS := 12             # squares around the centre
const CENTRE_STEP := 3         # the centre follows the player in steps of this many squares
const TOP_M := 6.0             # drops start this far above the player's level
const MAX_DROP_LEVELS := 3     # and fall past open air at most this many levels below it
const MAX_RAIN := 2400
const MAX_SNOW := 1600
const RAIN_SPEED := 11.0       # m/s
const SNOW_SPEED := 1.6
const RAIN_LEAN_MAX := 0.5     # metres sideways per metre fallen, at most
const SNOW_LEAN_MAX := 0.8
const WIND_SHARE := 0.6        # how much of the region's wind the drops near the ground take
const MAX_POINTS := 2048       # start points, several per square so drops don't fall in a grid
const POINTS_PER_SQUARE := 4
const POINTS_W := 64           # width of the start point texture
const NEAR_GONE_M := 0.7       # drops nearer to the camera than this aren't drawn
const NEAR_FULL_M := 2.5       # and from here on they are drawn in full
const FLAKE_PX := 32           # the snow flake's texture: a soft round dot
const RAIN_COLOR := Color(0.8, 0.85, 0.95, 0.3)
const SNOW_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const BOUNDS_UP := 12.0        # the drops' box reaches this far above their start and below the player's level

var rain := GPUParticles3D.new()
var snow := GPUParticles3D.new()
var squares := 0               # open squares the drops land on now
var points := 0                # start points in use
var rebuilds := 0              # times the start points were worked out
var _key := []                 # what the start points were made for
var _tex: ImageTexture
var _starts := PackedVector3Array()   # the start points, as placed (world space)
var _bounds := AABB()                 # the box around all drops, in this node's space
static var _flake: ImageTexture


func _init() -> void:
	_setup(rain, MAX_RAIN, Vector2(0.012, 0.45), RAIN_COLOR, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY)
	_setup(snow, MAX_SNOW, Vector2(0.05, 0.05), SNOW_COLOR, GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD)
	add_child(rain)
	add_child(snow)


func _setup(p: GPUParticles3D, amount: int, size: Vector2, color: Color, align: GPUParticles3D.TransformAlign) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	# Before the light pass, like glass: the drops take the darkness of what is behind them.
	mat.render_priority = WorldLighting.UNDER_PRIORITY
	# A drop right at the eye would cover half the view: they fade out on the last metres to the camera.
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = NEAR_GONE_M
	mat.distance_fade_max_distance = NEAR_FULL_M
	if p == snow:
		mat.albedo_texture = flake_texture()
	var quad := QuadMesh.new()
	quad.size = size
	quad.material = mat
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	process.gravity = Vector3.ZERO
	p.process_material = process
	p.draw_pass_1 = quad
	p.amount = amount
	p.transform_align = align
	p.local_coords = true   # the drops move with this node when the bubble shifts (shift)
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emitting = false


## Shows `state`'s precipitation around `snap`'s player.
func apply(snap: Snapshot, coords: CddaCoords, state: WeatherState) -> void:
	var on := (state.precip > 0.0 and snap != null and coords != null and snap.is_valid()
			and snap.player_pos.z >= 0)   # nothing underground
	var p := snow if state.snow else rain
	(rain if state.snow else snow).emitting = false
	if not on:
		p.emitting = false
		return
	var speed := SNOW_SPEED if state.snow else RAIN_SPEED
	var lean := lean_of(state.wind, speed, SNOW_LEAN_MAX if state.snow else RAIN_LEAN_MAX)
	var key := [centre(snap), coords.origin_ms, state.snow, lean.snappedf(0.05), _revisions(snap)]
	if key != _key:
		_key = key
		_place(snap, coords, lean)
	if points == 0:
		p.emitting = false
		return
	var process := p.process_material as ParticleProcessMaterial
	var velocity := Vector3(lean.x, -1.0, lean.y) * speed
	process.direction = velocity.normalized()
	process.spread = 12.0 if state.snow else 2.0
	process.initial_velocity_min = velocity.length() * 0.9
	process.initial_velocity_max = velocity.length() * 1.1
	process.emission_point_texture = _tex
	process.emission_point_count = points
	p.lifetime = drop_m(snap) / speed
	p.amount_ratio = amount_ratio(state.precip, squares)
	p.visibility_aabb = _bounds
	p.emitting = true


## A soft round white dot (made once, on the main thread).
static func flake_texture() -> ImageTexture:
	if _flake == null:
		_flake = ImageTexture.create_from_image(flake_image())
	return _flake


static func flake_image() -> Image:
	var img := Image.create(FLAKE_PX, FLAKE_PX, false, Image.FORMAT_RGBA8)
	var mid := (FLAKE_PX - 1) / 2.0
	for y in FLAKE_PX:
		for x in FLAKE_PX:
			var r := Vector2(x - mid, y - mid).length() / (FLAKE_PX / 2.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0 - smoothstep(0.35, 1.0, r)))
	return img


## The bubble moved: the falling drops and their start points move with the world (CddaCoords.origin_shifted).
## The start points are stored relative to this node, so they stay right until they are placed again.
func shift(d: Vector3) -> void:
	position += d


## Sideways metres per metre fallen (x east, y south), for a wind in world space.
static func lean_of(wind: Vector3, fall_speed: float, lean_max: float) -> Vector2:
	return (Vector2(wind.x, wind.z) * WIND_SHARE / fall_speed).limit_length(lean_max)


## The share of the particles in use: heavier weather has more, and so does more open ground (a few open squares
## seen from a porch don't get the whole storm).
static func amount_ratio(precip: float, open_squares: int) -> float:
	var full := PI * RADIUS * RADIUS
	return clampf(precip * precip * open_squares / full, 0.0, 1.0)


## The square the drops fall around: the player's, in steps of CENTRE_STEP (walking one square moves nothing).
static func centre(snap: Snapshot) -> Vector3i:
	var p := snap.player_pos
	return Vector3i(snappedi(p.x, CENTRE_STEP), snappedi(p.y, CENTRE_STEP), p.z)


## How far the drops fall, metres: from TOP_M above the player's level to the lowest ground they can reach.
static func drop_m(snap: Snapshot) -> float:
	return TOP_M + CddaCoords.LEVEL_M * (snap.player_pos.z - _lowest(snap))


static func _lowest(snap: Snapshot) -> int:
	return maxi(snap.player_pos.z - MAX_DROP_LEVELS, 0)


## The flags of square `p`, or -1 where the snapshot has no map.
static func _flags(snap: Snapshot, p: Vector3i) -> int:
	var sm: Snapshot.Submap = snap.submaps.get(CddaCoords.ms_to_sm(p))
	if sm == null:
		return -1
	var l := CddaCoords.ms_to_local(p)
	return sm.flags[l.y * CddaCoords.SEEX + l.x]


## The level where a drop coming down on square (p.x, p.y) from above the player's level lands: p.z, or lower past
## open air. -1: nothing lands there (under a roof, or no map).
static func landing_level(snap: Snapshot, p: Vector3i) -> int:
	var f := _flags(snap, p)
	if f < 0 or f & Snapshot.FLAG_ROOF:
		return -1
	var z := p.z
	var lowest := _lowest(snap)
	while f & Snapshot.FLAG_NO_FLOOR and z > lowest:
		var below := _flags(snap, Vector3i(p.x, p.y, z - 1))
		if below < 0 or below & Snapshot.FLAG_ROOF:
			break
		z -= 1
		f = below
	return z


## The squares a drop passes over on its last `drop` metres, as offsets from the square it lands on (x, y, levels
## up; one sample a metre, the landing square itself left out). A leaning drop comes down from upwind.
static func way(lean: Vector2, drop: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var last := Vector3i.ZERO
	for h in range(1, drop + 1):
		var at := Vector3i(-roundi(lean.x * h), -roundi(lean.y * h), int(h / CddaCoords.LEVEL_M))
		if at != last:
			out.append(at)
			last = at
	return out


## Whether no roof is in the way down to landing square `p` (offsets from way()).
static func way_clear(snap: Snapshot, p: Vector3i, offsets: Array[Vector3i]) -> bool:
	for o in offsets:
		var f := _flags(snap, p + o)
		if f >= 0 and f & Snapshot.FLAG_ROOF:
			return false
	return true


## The squares within RADIUS of the centre where drops land, with the level they land on (x, y, level).
static func landing_squares(snap: Snapshot, lean: Vector2) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var c := centre(snap)
	if c.z < 0:
		return out   # underground
	var ways := {}   # levels below the player's -> way()
	for dy in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			if dx * dx + dy * dy > RADIUS * RADIUS:
				continue
			var z := landing_level(snap, Vector3i(c.x + dx, c.y + dy, c.z))
			if z < 0:
				continue
			if not ways.has(c.z - z):
				ways[c.z - z] = way(lean, int(TOP_M + CddaCoords.LEVEL_M * (c.z - z)))
			var p := Vector3i(c.x + dx, c.y + dy, z)
			if way_clear(snap, p, ways[c.z - z]):
				out.append(p)
	return out


## Where the drops for landing square `p` start: above it by the drop and upwind by the lean, so they come down
## on the square's north-west corner; add up to a square east and south for a point anywhere over it.
static func start_point(coords: CddaCoords, snap: Snapshot, p: Vector3i, lean: Vector2) -> Vector3:
	var drop := TOP_M + CddaCoords.LEVEL_M * (snap.player_pos.z - p.z)
	return coords.ms_to_world(p) + Vector3(-lean.x * drop, drop, -lean.y * drop)


## The revisions of the submaps the drops can land on, as one number: a changed map (a roof gone) gives new
## start points.
static func _revisions(snap: Snapshot) -> int:
	var revs := PackedInt64Array()
	var c := CddaCoords.ms_to_sm(snap.player_pos)
	var reach := RADIUS / CddaCoords.SEEX + 1
	for z in range(_lowest(snap), snap.player_pos.z + 3):
		for y in range(c.y - reach, c.y + reach + 1):
			for x in range(c.x - reach, c.x + reach + 1):
				var sm: Snapshot.Submap = snap.submaps.get(Vector3i(x, y, z))
				revs.append(sm.revision if sm != null else -1)
	return hash(revs)


func _place(snap: Snapshot, coords: CddaCoords, lean: Vector2) -> void:
	rebuilds += 1
	var land := landing_squares(snap, lean)
	squares = land.size()
	var per := clampi(MAX_POINTS / maxi(squares, 1), 1, POINTS_PER_SQUARE)
	points = squares * per
	_starts.resize(points)
	if points == 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([snap.player_pos, snap.turn])
	var rows := ceili(points / float(POINTS_W))
	var data := PackedFloat32Array()
	data.resize(POINTS_W * rows * 3)
	var i := 0
	var n := 0
	for p in land:
		var corner := start_point(coords, snap, p, lean)
		for k in per:
			var at := Vector3(corner.x + rng.randf() * CddaCoords.TILE_M, corner.y, corner.z + rng.randf() * CddaCoords.TILE_M)
			_starts[n] = at
			n += 1
			data[i] = at.x - position.x
			data[i + 1] = at.y - position.y
			data[i + 2] = at.z - position.z
			i += 3
	var mid := coords.ms_to_world(centre(snap)) - position
	var reach := RADIUS + 1.0 + BOUNDS_UP   # the circle, and how far a leaning drop starts outside it
	_bounds = AABB(mid - Vector3(reach, BOUNDS_UP + drop_m(snap), reach),
			Vector3(2.0 * reach, 2.0 * BOUNDS_UP + drop_m(snap) + TOP_M, 2.0 * reach))
	var img := Image.create_from_data(POINTS_W, rows, false, Image.FORMAT_RGBF, data.to_byte_array())
	if _tex != null and _tex.get_height() == rows:
		_tex.update(img)
	else:
		_tex = ImageTexture.create_from_image(img)


## The start points in use, as placed (for tests and debugging).
func start_points() -> PackedVector3Array:
	return _starts
