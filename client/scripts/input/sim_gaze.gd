class_name SimGaze
extends GazeSource
## A gaze source set by hand (tests, and a debug stand-in until the desktop tracker is read): `point` in viewport
## pixels or null, `present` false when the "player" looks away. Untracked while `point` is null and `present` true.

var point: Variant = null
var present := true


func tracked() -> bool:
	return present and point is Vector2


func screen_point() -> Variant:
	return point if tracked() else null


func on_screen() -> Variant:
	if not present:
		return false
	return true if point is Vector2 else null
