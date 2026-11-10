class_name StairUse
extends RefCounted
## Using stairs by pointing at them: the mouse (first person) or a VR controller ray picks a square with
## LookRay; `find` says whether it is a stair (stairs or ladder, up or down) that leads away from the
## level you are on, and where it goes. `live_actions` turns that into CDDA's own actions: LEVEL_UP / LEVEL_DOWN
## when the player stands on it, a step onto it first when it is next to them, nothing when it is farther.
## No nodes, so tests run it headless.

const K := TerrainCatalog.Kind
const UP := [K.STAIRS_UP, K.LADDER_UP]   # ramps change level by walking on, no use needed
const DOWN := [K.STAIRS_DOWN, K.LADDER_DOWN]
## CDDA's move actions by square step (x east, y south), as main.gd's OCT_ACTIONS.
const STEP_ACTIONS := {Vector2i(1, 0): "RIGHT", Vector2i(1, 1): "RIGHTDOWN", Vector2i(0, 1): "DOWN",
		Vector2i(-1, 1): "LEFTDOWN", Vector2i(-1, 0): "LEFT", Vector2i(-1, -1): "LEFTUP", Vector2i(0, -1): "UP",
		Vector2i(1, -1): "RIGHTUP"}


## Stairs at square `sq` seen from level `from_z`: {dz: +1/-1, stand: the stair's square on from_z, to: the
## square it leads to}; {} when sq is no stair or the stair doesn't touch from_z. Looking down a stairwell the
## ray lands on the stairs up below, so both ends count.
static func find(world: WorldView, sq: Vector3i, from_z: int) -> Dictionary:
	if world == null or world.snapshot == null:
		return {}
	var c := LookRay.new(world)._cell(sq)
	if c.is_empty():
		return {}
	var kind := world.catalog.style_for(c["ter"]).kind
	var lower: int
	if kind in UP:
		lower = sq.z
	elif kind in DOWN:
		lower = sq.z - 1
	else:
		return {}
	var dz := 0
	if from_z == lower:
		dz = 1
	elif from_z == lower + 1:
		dz = -1
	else:
		return {}
	return {"dz": dz, "stand": Vector3i(sq.x, sq.y, from_z), "to": Vector3i(sq.x, sq.y, from_z + dz)}


## Uses stair `s` (from `find`) through the bridge's own stairs action (CddaSim.use_stairs: from next to them
## it steps on first, and it checks reach itself, so the snapshot needn't be settled). 1 queued, 0 refused,
## -1 the bridge has no such action (older builds: `live_actions` instead).
static func use_live(sim: Object, s: Dictionary) -> int:
	if sim == null or not sim.has_method("use_stairs"):
		return -1
	if typeof(s.get("stand")) != TYPE_VECTOR3I or typeof(s.get("dz")) != TYPE_INT or not (s["dz"] in [1, -1]):
		return 0
	return 1 if sim.use_stairs(s["stand"], s["dz"]) else 0


## CDDA actions that take the player at `player` along stair `s` (from `find`); empty when it is too far.
static func live_actions(player: Vector3i, s: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if s.is_empty():
		return out
	var stand: Vector3i = s["stand"]
	var lvl := "LEVEL_UP" if s["dz"] > 0 else "LEVEL_DOWN"
	if stand == player:
		out.append(lvl)
	elif stand.z == player.z and STEP_ACTIONS.has(Vector2i(stand.x - player.x, stand.y - player.y)):
		out.append(STEP_ACTIONS[Vector2i(stand.x - player.x, stand.y - player.y)])
		out.append(lvl)
	return out
