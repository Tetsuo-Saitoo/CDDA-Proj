class_name EyeView
extends RefCounted
## The flat screen's eye-tracking view as one FirstPersonCamera view offset (lead-ui): zoom where you look while the
## zoom key is held (1), see a little past the screen edge you look at (2), and the lean's tilt (9). Only angles and
## a lean side come in; nothing is kept but the zoom's aim while its key is down.

const ZOOM := 0.5             # fov scale while zooming
const EDGE := 0.15            # the outer part of each half of the screen that turns the view
const EDGE_DEG := 8.0         # the turn with the eyes at the very edge
const LEAN_ROLL_DEG := 10.0
const LEAN_SIDE_M := 0.25

var _zoom_at: Variant = null  # Vector2: degrees (left +, up +) from the look to where you looked as the key went down


## One frame -> [yaw, pitch, roll (deg), side (m), fov scale] for FirstPersonCamera.set_view_offset.
## `look`: where the eyes are, in degrees from the look itself (Vector2, left +, up +), null when not tracked or zoom
## is off; `edge`: the eyes on the screen, -1..1 each way (x right, y down), null when not tracked or the edge turn
## is off; `zoom`: the zoom key held; `lean` -1 left, 0, 1 right; `peeking`: CDDA's peek is open (the view already
## stands on the peeked square, so no side shift).
func step(look: Variant, edge: Variant, zoom: bool, lean: int, peeking: bool) -> Array[float]:
	var out: Array[float] = [0.0, 0.0, 0.0, 0.0, 1.0]
	if not zoom:
		_zoom_at = null
	elif _zoom_at == null and look is Vector2 and (look as Vector2).is_finite():
		_zoom_at = look   # held: the aim stays where you looked when the key went down
	if _zoom_at != null:
		var a: Vector2 = (_zoom_at as Vector2) * (1.0 - ZOOM)   # the spot stays about where it was on the screen
		out[0] = a.x
		out[1] = a.y
		out[4] = ZOOM
	elif edge is Vector2 and (edge as Vector2).is_finite():
		out[0] = -_edge((edge as Vector2).x) * EDGE_DEG
		out[1] = -_edge((edge as Vector2).y) * EDGE_DEG
	var s := clampi(lean, -1, 1)
	out[2] = -s * LEAN_ROLL_DEG
	out[3] = 0.0 if peeking else s * LEAN_SIDE_M
	return out


## True while the zoom key holds an aim.
func zooming() -> bool:
	return _zoom_at != null


## -1..1 across the screen -> how far into the edge band: 0 inside, +-1 at the edge.
static func _edge(v: float) -> float:
	var m := absf(v) - (1.0 - EDGE)
	return 0.0 if m <= 0.0 else signf(v) * minf(m / EDGE, 1.0)


## A world direction as degrees from the look `base` (yaw / pitch only): Vector2(left +, up +); null when not finite
## or behind.
static func angles(base: Basis, dir: Vector3) -> Variant:
	if not dir.is_finite() or dir.length() < 0.001:
		return null
	var l := base.inverse() * dir.normalized()
	if l.z >= 0.0:
		return null
	return Vector2(rad_to_deg(atan2(-l.x, -l.z)), rad_to_deg(atan2(l.y, Vector2(l.x, l.z).length())))


## A screen point (px) as -1..1 each way (x right, y down) on a screen of `size`; null when outside or not finite.
static func on_screen(p: Variant, size: Vector2) -> Variant:
	var q: Variant = GazeSource.point_in(p, size)
	if q == null:
		return null
	var v: Vector2 = q
	return Vector2(v.x / size.x * 2.0 - 1.0, v.y / size.y * 2.0 - 1.0)
