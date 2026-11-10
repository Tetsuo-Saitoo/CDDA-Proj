class_name LightMap
extends RefCounted
## Block C6: CDDA's light and visibility of one snapshot, for the light pass (WorldLighting).
##
## [member image] (R8) holds every loaded level of the bubble: level z at rows (z - z_lo) * SIZE.., bubble tile
## (x, y) at column x for its light (CDDA light level, 0..255) and at column x + SIZE for its vis (0..3). It is
## built off the main thread (WorldView._compute) with one blit per submap per channel. The shader turns
## (light, vis) into a colour through [member lut] (256 x 4, from tile_color), so the brightness curve lives
## here, where tests can reach it. The colours are linear multipliers: 1 leaves the lit scene as it is.
##
## Light sources (OmniLights): the snapshot's `lights` lists when the bridge sends them, otherwise local
## maxima of the light around the player that stand well above the natural light (lamps, fires, torches).

const SIZE := CddaCoords.SEEX * CddaCoords.MAPSIZE   # 132 tiles per bubble side
const LIGHT_LOW := 3.5     # CDDA LIGHT_AMBIENT_LOW: darker than this, nothing is seen
const LIGHT_LIT := 10.0    # CDDA LIGHT_AMBIENT_LIT
## Brightness by CDDA light level, piecewise linear between these points (light, multiplier).
const CURVE: Array[Vector2] = [Vector2(0.0, 0.03), Vector2(1.0, 0.07), Vector2(2.0, 0.13), Vector2(3.5, 0.25),
		Vector2(5.0, 0.33), Vector2(10.0, 0.6), Vector2(20.0, 0.82), Vector2(35.0, 0.95), Vector2(50.0, 1.0)]
const DARK := 0.03         # night-dark: tiles CDDA has in sight but too dark to see (vis 3)
const REMEMBERED := 0.7    # vis 1 (remembered, not in sight now): a little dimmer
const VIS_REMEMBERED := 1
const VIS_SEEN := 2
const VIS_DARK := 3
const WARM := Color(1.0, 0.78, 0.55)   # lamp and fire light, where a tile is well above the natural light
const WARM_MAX := 0.85
const COOL := Color(0.62, 0.74, 1.0)   # night (low natural light)
## Light sources: at most this many, the nearest to the player.
const MAX_SOURCES := 8
## Guessed sources: light at least this far above the natural light, falling off by at least 1/SOURCE_DROP of
## itself toward its lowest neighbour (a lamp, not a sunlit plateau), within SOURCE_RADIUS tiles and
## SOURCE_LEVELS levels of the player.
const SOURCE_MIN_EXCESS := 10
const SOURCE_DROP := 5
const SOURCE_RADIUS := 30
const SOURCE_LEVELS := 1
const KIND_GUESSED := -1


## A light source to show: an OmniLight3D at its square.
class Source:
	var square: Vector3i     # absolute map square
	var luminance := 0       # CDDA light level (the source's own, or its tile's when guessed)
	var kind := KIND_GUESSED   # Snapshot.LIGHT_*, or KIND_GUESSED
	var dist2 := 0           # squared distance to the player in metres (a level is 3 m)


var origin_ms := Vector3i.ZERO   # absolute square of bubble tile (0, 0), z 0
var z_lo := 0
var levels := 0
var image: Image
var lut: Image                   # null when built without one (the shader keeps the last)
var ambient := 0                 # natural light used for the tints
var sky := Color.WHITE           # multiplier for sky pixels
var outside := Color.WHITE       # multiplier on levels the atlas doesn't hold
var sources: Array[Source] = []


## Everything the light pass needs from a validated snapshot; thread-safe (reads only the snapshot).
static func build(snap: Snapshot, with_lut := true) -> LightMap:
	var m := LightMap.new()
	var sx := CddaCoords.SEEX
	m.origin_ms = CddaCoords.sm_to_ms(snap.bubble_origin)
	m.ambient = natural_light(snap)
	var lo := CddaCoords.Z_MAX
	var hi := CddaCoords.Z_MIN
	for pos: Vector3i in snap.submaps:
		lo = mini(lo, pos.z)
		hi = maxi(hi, pos.z)
	if lo > hi:
		lo = 0
		hi = 0
	m.z_lo = lo
	m.levels = hi - lo + 1
	m.image = Image.create_empty(2 * SIZE, SIZE * m.levels, false, Image.FORMAT_R8)
	var rect := Rect2i(0, 0, sx, sx)
	for pos: Vector3i in snap.submaps:
		var sm: Snapshot.Submap = snap.submaps[pos]
		var rel := pos - snap.bubble_origin
		if (sm.light.size() != Snapshot.TILES or sm.vis.size() != Snapshot.TILES or rel.x < 0
				or rel.x >= CddaCoords.MAPSIZE or rel.y < 0 or rel.y >= CddaCoords.MAPSIZE):
			push_warning("light map: skipping malformed submap %s" % pos)
			continue
		var at := Vector2i(rel.x * sx, (pos.z - lo) * SIZE + rel.y * sx)
		m.image.blit_rect(Image.create_from_data(sx, sx, false, Image.FORMAT_R8, sm.light), rect, at)
		m.image.blit_rect(Image.create_from_data(sx, sx, false, Image.FORMAT_R8, sm.vis), rect, at + Vector2i(SIZE, 0))
	if with_lut:
		m.lut = build_lut(m.ambient)
	m.sky = sky_color(m.ambient)
	m.outside = tile_color(m.ambient, VIS_SEEN, m.ambient)
	if snap.has_lights:
		m._listed_sources(snap)
	else:
		m._guessed_sources(snap)
	return m


## Light (0..255) and vis (0..3) of bubble tile (x, y) at level z, from the atlas; [-1, -1] off it.
func texel(x: int, y: int, z: int) -> Vector2i:
	var li := z - z_lo
	if x < 0 or x >= SIZE or y < 0 or y >= SIZE or li < 0 or li >= levels:
		return Vector2i(-1, -1)
	var row := li * SIZE + y
	return Vector2i(image.get_pixel(x, row).r8, image.get_pixel(x + SIZE, row).r8)


## CDDA's natural light at the player's z: env.ambient_light, or a guess from the sun when the bridge
## doesn't send it (about 100 by day, about 2 at night).
static func natural_light(snap: Snapshot) -> int:
	if snap.ambient_light >= 0:
		return snap.ambient_light
	var t := clampf((snap.sun_alt_deg + 12.0) / 22.0, 0.0, 1.0)   # -12 degrees (night) .. 10 (day)
	return roundi(lerpf(2.0, 100.0, t * t))


## Brightness multiplier for a CDDA light level: about 0.03 at 0, 0.25 at 3.5, 0.6 at 10, 1 from 50 up.
static func brightness(light: float) -> float:
	if not light > CURVE[0].x:   # also NaN
		return CURVE[0].y
	for i in range(1, CURVE.size()):
		if light <= CURVE[i].x:
			var a := CURVE[i - 1]
			var b := CURVE[i]
			return lerpf(a.y, b.y, (light - a.x) / (b.x - a.x))
	return CURVE[CURVE.size() - 1].y


## Brightness of a tile from its light and vis. In sight and lit: the curve. In sight but dark: night-dark.
## Not in sight (never seen or remembered): only light strong enough to see from afar shows, the rest
## fades to night-dark; remembered tiles are a little dimmer.
static func tile_brightness(light: float, vis: int) -> float:
	if vis == VIS_SEEN:
		return brightness(light)
	if vis == VIS_DARK:
		return DARK
	var b := lerpf(DARK, brightness(light), smoothstep(LIGHT_LOW, LIGHT_LIT, light))
	return maxf(DARK, b * REMEMBERED) if vis == VIS_REMEMBERED else b


## 0 by day, 1 at night: how blue the natural light is.
static func night(ambient_light: float) -> float:
	return 1.0 - smoothstep(4.0, 40.0, ambient_light)


## 0..1: how much of a tile's light comes from lamps and fires rather than the sky.
static func warmth(light: float, ambient_light: float) -> float:
	return smoothstep(3.0, 20.0, light - ambient_light) * (1.0 - smoothstep(40.0, 90.0, light))


## The multiplier the light pass applies to a tile: brightness, cool at night, warm near lamps and fires.
static func tile_color(light: float, vis: int, ambient_light: float) -> Color:
	var b := tile_brightness(light, vis)
	var tint := Color.WHITE.lerp(COOL, night(ambient_light))
	if vis != VIS_DARK:
		tint = tint.lerp(WARM, WARM_MAX * warmth(light, ambient_light))
	return Color(tint.r * b, tint.g * b, tint.b * b)


## The multiplier for the sky: full by day, nearly black at night.
static func sky_color(ambient_light: float) -> Color:
	var b := maxf(0.008, pow(brightness(ambient_light), 2.0))
	var tint := Color.WHITE.lerp(COOL, night(ambient_light))
	return Color(tint.r * b, tint.g * b, tint.b * b)


## tile_color for every light (x, 0..255) and vis (y, 0..3), RGBA float.
static func build_lut(ambient_light: int) -> Image:
	var f := PackedFloat32Array()
	f.resize(256 * 4 * 4)
	var i := 0
	for vis in 4:
		for light in 256:
			var c := tile_color(light, vis, ambient_light)
			f[i] = c.r
			f[i + 1] = c.g
			f[i + 2] = c.b
			f[i + 3] = 1.0
			i += 4
	return Image.create_from_data(256, 4, false, Image.FORMAT_RGBAF, f.to_byte_array())


## OmniLight3D reach in metres for a source of CDDA light `luminance` (where its light falls to about LIGHT_LOW).
static func light_range(luminance: float) -> float:
	return clampf(1.0 + 1.2 * sqrt(maxf(luminance, 0.0) / LIGHT_LOW), 2.0, 14.0)


static func light_energy(luminance: float) -> float:
	return clampf(luminance / 40.0, 0.3, 2.0)


func _listed_sources(snap: Snapshot) -> void:
	for pos: Vector3i in snap.submaps:
		var l := (snap.submaps[pos] as Snapshot.Submap).lights
		var base := CddaCoords.sm_to_ms(pos)
		for i in range(0, l.size() - Snapshot.LIGHT_STRIDE + 1, Snapshot.LIGHT_STRIDE):
			var t := l[i]
			if l[i + 1] <= 0 or t < 0 or t >= Snapshot.TILES:
				continue
			_keep(base + Vector3i(t % CddaCoords.SEEX, t / CddaCoords.SEEX, 0), l[i + 1], l[i + 2], snap.player_pos)


## Local maxima of the light near the player, well above the natural light and falling off around them.
func _guessed_sources(snap: Snapshot) -> void:
	var data := image.get_data()
	var w := 2 * SIZE
	var p := snap.player_pos - origin_ms
	var threshold := ambient + SOURCE_MIN_EXCESS
	if threshold > 255:
		return
	for z in range(p.z - SOURCE_LEVELS, p.z + SOURCE_LEVELS + 1):
		var li := z - z_lo
		if li < 0 or li >= levels:
			continue
		for y in range(maxi(p.y - SOURCE_RADIUS, 0), mini(p.y + SOURCE_RADIUS, SIZE - 1) + 1):
			var row := (li * SIZE + y) * w
			for x in range(maxi(p.x - SOURCE_RADIUS, 0), mini(p.x + SOURCE_RADIUS, SIZE - 1) + 1):
				var v := data[row + x]
				if v >= threshold and _is_peak(data, li, x, y, v):
					_keep(origin_ms + Vector3i(x, y, z), v, KIND_GUESSED, snap.player_pos)


## v is the highest of its 8 neighbours (ties go to the first in scan order) and drops off toward the lowest.
func _is_peak(data: PackedByteArray, li: int, x: int, y: int, v: int) -> bool:
	var lowest := v
	for dy in range(-1, 2):
		var ny := y + dy
		if ny < 0 or ny >= SIZE:
			continue
		var row := (li * SIZE + ny) * 2 * SIZE
		for dx in range(-1, 2):
			var nx := x + dx
			if (dx == 0 and dy == 0) or nx < 0 or nx >= SIZE:
				continue
			var n := data[row + nx]
			if n > v or (n == v and (dy < 0 or (dy == 0 and dx < 0))):
				return false
			lowest = mini(lowest, n)
	return (v - lowest) * SOURCE_DROP >= v


## Inserts a source, nearest to the player first, keeping MAX_SOURCES.
func _keep(square: Vector3i, luminance: int, kind: int, player: Vector3i) -> void:
	var d := square - player
	var d2 := d.x * d.x + d.y * d.y + 9 * d.z * d.z
	if sources.size() >= MAX_SOURCES and d2 >= sources[sources.size() - 1].dist2:
		return
	var s := Source.new()
	s.square = square
	s.luminance = luminance
	s.kind = kind
	s.dist2 = d2
	var i := sources.size()
	while i > 0 and sources[i - 1].dist2 > d2:
		i -= 1
	sources.insert(i, s)
	if sources.size() > MAX_SOURCES:
		sources.resize(MAX_SOURCES)
