class_name TeleportAim
extends RefCounted
## The teleport cheat's target (LiveSession.cheat_teleport): the square to stand on for what the crosshair points
## at. A floor or roof that was hit: the square on it (also levels up or down). Anything else (a wall, a door,
## furniture, a creature, stairs): the last square the ray crossed before it, the air side. The bridge still picks
## the nearest free square if that one is taken.

const STEP_M := 0.05
const BACK_M := 2.0


## `hit`: LookRay.cast's result for a ray along `dir`; `to_ms`: Callable(Vector3) -> Vector3i (world.coords.world_to_ms).
## null when nothing was hit.
static func square(hit: Dictionary, dir: Vector3, to_ms: Callable) -> Variant:
	if not hit.get("hit", false) or not hit.get("square") is Vector3i or not hit.get("point") is Vector3:
		return null
	var sq: Vector3i = hit["square"]
	if hit.get("what") in ["floor", "ceiling"] or dir.length() < 0.001 or not to_ms.is_valid():
		return sq
	var pt: Vector3 = hit["point"]
	var d := dir.normalized()
	for i in range(1, int(BACK_M / STEP_M) + 1):
		var p: Variant = to_ms.call(pt - d * (i * STEP_M))
		if p is Vector3i and p != sq:
			return p
	return sq
