class_name GazeSource
extends RefCounted
## Where the player looks (eye tracking, user 2026-11-19): the one interface every gaze feature reads, flat screen and
## VR. This base has no device: nothing is tracked, so every gaze feature stays off and the game is as before. A
## device source overrides `tracked`, `screen_point` and `on_screen` (the desktop tracker, later; VR: lead-vr's
## VrGaze overrides `ray`); tests use SimGaze. The gaze stays in memory: never logged, saved or sent to the bridge
## (features send squares or targets, never where the eyes are).


## A gaze is tracked now (a device, eyes found, confident enough).
func tracked() -> bool:
	return false


## The point looked at on the flat screen (viewport pixels), or null: not tracked, or off the screen.
func screen_point() -> Variant:
	return null


## Whether the player looks at the screen: true / false, or null when the source can't tell (no device, a headset).
## A device that sees no eyes on the screen (looking away, or nobody there) says false.
func on_screen() -> Variant:
	return null


## The world ray looked along, {from: Vector3, dir: Vector3 (unit)}, or {} when not tracked. Flat: through
## `screen_point` from camera `cam`; VR overrides it (the eyes in the headset).
func ray(cam: Camera3D) -> Dictionary:
	var p: Variant = point_in(screen_point(), cam.get_viewport().get_visible_rect().size) if cam != null \
			and cam.get_viewport() != null and tracked() else null
	if not p is Vector2:
		return {}
	var dir := cam.project_ray_normal(p)
	var from := cam.project_ray_origin(p)
	if not dir.is_finite() or not from.is_finite() or dir.length() < 0.5:
		return {}
	return {"from": from, "dir": dir.normalized()}


## `p` when it is a finite point inside a viewport of `size`, else null (a source's numbers are not trusted).
static func point_in(p: Variant, size: Vector2) -> Variant:
	if not p is Vector2 or not (p as Vector2).is_finite() or not size.is_finite():
		return null
	var v: Vector2 = p
	return v if v.x >= 0.0 and v.y >= 0.0 and v.x < size.x and v.y < size.y else null
