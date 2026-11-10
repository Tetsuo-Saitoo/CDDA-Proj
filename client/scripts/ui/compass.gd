class_name Compass
extends Control
## Heading strip at the top of the screen. CDDA's north is -z in Godot space (CDDA y points south).
## Creatures the player perceives show under the strip at their bearing from the view, nearer = bigger and
## brighter: hostiles as red arrows (ones behind the shown span point out from the strip's ends), others as
## small dots, green when friendly, pale when neutral or unknown. Creatures on another level than the player's
## (set_level_blips) are hollow and fainter, with a chevron beside them pointing up or down (two for 2+ levels).

const SPAN_DEG := 180.0   # degrees shown across the strip
const LETTERS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
const FONT_SIZE := 14
const MAX_BLIPS := 64        # nearest hostiles drawn; the rest are left out
const MAX_OTHER_BLIPS := 32  # nearest non-hostiles drawn
const FAR_M := 40.0          # at this distance or more a marker is at its smallest and dimmest
const HOSTILE_COLOR := Color(1.0, 0.18, 0.12)
const FRIENDLY_COLOR := Color(0.3, 0.95, 0.4)
const NEUTRAL_COLOR := Color(0.9, 0.9, 0.8)
const OTHER_LEVEL_FADE := 0.6   # alpha factor for markers on another level

var heading_deg := 0.0:
	set(v):
		heading_deg = fposmod(v, 360.0)
		queue_redraw()

## 0 (invisible) .. 1 (opaque), the HUD setting (HudSettings.compass_opacity).
var opacity := 1.0:
	set(v):
		opacity = HudSettings.clamp_opacity(v)
		modulate.a = opacity

## Vector3(bearing in degrees, distance in metres, Snapshot.Creature attitude HOSTILE/NEUTRAL/FRIENDLY) per
## creature: hostiles nearest first, then the others nearest first (set_blips).
var blips: Array[Vector3] = []
## Level offset per blip (creature z minus the player's: + above, - below); missing entries count as 0.
var blip_levels := PackedInt32Array()


## Compass heading of a view (0 north, 90 east); looking straight down, up on screen counts as forward.
static func heading_of(b: Basis) -> float:
	var f := -b.z
	if Vector2(f.x, f.z).length() < 0.01:
		f = b.y
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


## Compass bearing (0 north, 90 east) from one Godot-space point to another; height doesn't count.
static func bearing_deg(from: Vector3, to: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(to.x - from.x, from.z - to.z)), 360.0)


## Where a bearing falls on the strip for a heading: -1 left end, 0 centre, 1 right end; beyond is off it.
static func strip_pos(bearing: float, heading: float) -> float:
	return wrapf(bearing - heading, -180.0, 180.0) / (SPAN_DEG / 2.0)


## 1 for a creature next to you, falling to 0 at FAR_M.
static func nearness(dist_m: float) -> float:
	return clampf(1.0 - dist_m / FAR_M, 0.0, 1.0)


## How a creature is marked: HOSTILE, FRIENDLY, or NEUTRAL (also when the bridge doesn't say); -1 for the player.
static func marker_kind(c: Snapshot.Creature) -> int:
	if c.kind == Snapshot.Creature.PLAYER:
		return -1
	if c.is_hostile():
		return Snapshot.Creature.HOSTILE
	return Snapshot.Creature.FRIENDLY if c.attitude == Snapshot.Creature.FRIENDLY else Snapshot.Creature.NEUTRAL


## Blips for the snapshot's creatures as seen from `from` (Godot space); `to_world` maps an absolute square to
## Godot space (CddaCoords.ms_center_to_world). The snapshot holds only creatures the player perceives.
static func creature_blips(snap: Snapshot, from: Vector3, to_world: Callable) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for b in level_blips(snap, from, to_world):
		out.append(Vector3(b.x, b.y, b.z))
	return out


## Level offset of each creature_blips marker, in the same order: the creature's z minus the player's
## (snap.player_pos.z), + above, - below.
static func creature_blip_levels(snap: Snapshot, from: Vector3, to_world: Callable) -> PackedInt32Array:
	var out := PackedInt32Array()
	for b in level_blips(snap, from, to_world):
		out.append(int(b.w))
	return out


## creature_blips with the level offset as w: Vector4(bearing, distance, kind, level offset), same order and
## caps. One pass for set_level_blips.
static func level_blips(snap: Snapshot, from: Vector3, to_world: Callable) -> Array[Vector4]:
	var hostile: Array[Vector4] = []
	var others: Array[Vector4] = []
	if snap == null:
		return hostile
	for c in snap.creatures:
		var k := marker_kind(c)
		if k < 0:
			continue
		var at: Vector3 = to_world.call(c.pos)
		var b := Vector4(bearing_deg(from, at), Vector2(at.x - from.x, at.z - from.z).length(), k,
				c.pos.z - snap.player_pos.z)
		(hostile if k == Snapshot.Creature.HOSTILE else others).append(b)
	var nearer := func(a: Vector4, b: Vector4) -> bool: return a.y < b.y
	hostile.sort_custom(nearer)
	others.sort_custom(nearer)
	if hostile.size() > MAX_BLIPS:
		hostile.resize(MAX_BLIPS)
	if others.size() > MAX_OTHER_BLIPS:
		others.resize(MAX_OTHER_BLIPS)
	hostile.append_array(others)
	return hostile


## Markers all drawn as on the player's level (see set_level_blips).
func set_blips(list: Array[Vector3]) -> void:
	if list == blips and blip_levels.is_empty():
		return
	blips = list
	blip_levels = PackedInt32Array()
	queue_redraw()


## Markers with their level offsets (level_blips).
func set_level_blips(list: Array[Vector4]) -> void:
	var b: Array[Vector3] = []
	var levels := PackedInt32Array()
	for v in list:
		b.append(Vector3(v.x, v.y, v.z))
		levels.append(int(v.w))
	if b == blips and levels == blip_levels:
		return
	blips = b
	blip_levels = levels
	queue_redraw()


## Chevrons beside a marker at `at` for a level offset: one per level up to two, pointing up (above) or down
## (below); none on the player's level. Each is a 3-point polyline.
static func level_ticks(at: Vector2, dz: int) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var d := -1.5 if dz > 0 else 1.5   # screen y grows down: the tip is at y + d
	for i in mini(absi(dz), 2):
		var o := at + Vector2(0.0, i * 3.0 * signf(d))   # the second chevron further the same way
		out.append(PackedVector2Array([o + Vector2(-2.5, -d), o + Vector2(0.0, d), o + Vector2(2.5, -d)]))
	return out


func _level(i: int) -> int:
	return blip_levels[i] if i < blip_levels.size() else 0


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.4))
	var font := get_theme_default_font()
	for deg in range(0, 360, 15):
		var off := wrapf(deg - heading_deg, -180.0, 180.0)
		if absf(off) > SPAN_DEG / 2.0:
			continue
		var x := w / 2.0 + off / SPAN_DEG * w
		if LETTERS.has(deg):
			var t: String = LETTERS[deg]
			var col := Color(1.0, 0.4, 0.3) if deg == 0 else Color.WHITE
			var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
			draw_string(font, Vector2(x - tw / 2.0, h - 5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
			draw_line(Vector2(x, 0), Vector2(x, 7), col, 2.0)
		else:
			draw_line(Vector2(x, 0), Vector2(x, 5), Color(1, 1, 1, 0.6), 1.0)
	draw_line(Vector2(w / 2.0, 0), Vector2(w / 2.0, h), Color(1.0, 0.85, 0.2), 2.0)
	var deg_text := "%d°" % (roundi(heading_deg) % 360)
	draw_string(font, Vector2(w + 6, h - 5), deg_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color.WHITE)
	var readout := font.get_string_size("360°", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	_draw_blips(w, h, w + 6.0 + readout + 4.0)


## Others under hostiles, farthest first, so the nearest is on top; one arrow per end for hostiles off the strip
## (the nearest's, left of the strip and right of the degree readout, which ends at `right_x`); others off the
## strip aren't shown. Markers on another level are hollow and fainter, with level_ticks beside them.
func _draw_blips(w: float, h: float, right_x: float) -> void:
	for i in range(blips.size() - 1, -1, -1):
		var b := blips[i]
		var s := strip_pos(b.x, heading_deg)
		if b.z == Snapshot.Creature.HOSTILE or absf(s) > 1.0:
			continue
		var t := nearness(b.y)
		var r := lerpf(2.0, 3.5, t)
		var col := Color(FRIENDLY_COLOR if b.z == Snapshot.Creature.FRIENDLY else NEUTRAL_COLOR, lerpf(0.4, 0.9, t))
		var at := Vector2(w / 2.0 + s * w / 2.0, h + 2.0 + r)
		var dz := _level(i)
		if dz == 0:
			draw_circle(at, r, col)
		else:
			col.a *= OTHER_LEVEL_FADE
			draw_arc(at, r, 0.0, TAU, 12, col, 1.0)
			_draw_ticks(at + Vector2(r + 3.0, 0.0), dz, col)
	var edge := {-1: [-1.0, 0], 1: [-1.0, 0]}   # side -> [nearness, level offset] of the nearest off-strip hostile
	for i in range(blips.size() - 1, -1, -1):
		var b := blips[i]
		if b.z != Snapshot.Creature.HOSTILE:
			continue
		var t := nearness(b.y)
		var s := strip_pos(b.x, heading_deg)
		var dz := _level(i)
		if absf(s) > 1.0:
			var side := 1 if s > 0.0 else -1
			if t > edge[side][0]:
				edge[side] = [t, dz]
			continue
		var x := w / 2.0 + s * w / 2.0
		var r := lerpf(4.0, 8.0, t)
		var tip := Vector2(x, h + 1.0)   # points up at its bearing on the strip
		_draw_arrow(PackedVector2Array([tip, tip + Vector2(r, r * 1.6), tip + Vector2(-r, r * 1.6)]), t, dz)
		if dz != 0:
			_draw_ticks(tip + Vector2(r + 3.0, r * 0.8), dz, Color(HOSTILE_COLOR, lerpf(0.45, 1.0, t) * OTHER_LEVEL_FADE))
	for side: int in edge:
		var t: float = edge[side][0]
		if t < 0.0:
			continue
		var r := lerpf(4.0, 8.0, t)
		var back := -4.0 if side < 0 else right_x
		var tip := Vector2(back + side * r * 1.6, h / 2.0)
		_draw_arrow(PackedVector2Array([tip, Vector2(back, tip.y - r), Vector2(back, tip.y + r)]), t, edge[side][1])


## A hostile arrow: filled on the player's level, an outline (fainter) on another.
func _draw_arrow(points: PackedVector2Array, t: float, dz: int) -> void:
	var col := Color(HOSTILE_COLOR, lerpf(0.45, 1.0, t))
	if dz == 0:
		draw_colored_polygon(points, col)
		return
	col.a *= OTHER_LEVEL_FADE
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, col, 1.5)


func _draw_ticks(at: Vector2, dz: int, col: Color) -> void:
	for p in level_ticks(at, dz):
		draw_polyline(p, col, 1.5)
