class_name CddaCoords
extends RefCounted
## Block C1: the only place that converts between CDDA coordinates and Godot space.
##
## CDDA: absolute map squares (tiles) and submaps (12 x 12 squares); x east, y south, z up.
## Godot: 1 tile = 1 m, 1 z-level = 3 m, y up, east = +X, south = +Z (so north = -Z).
## Godot positions are relative to [member origin_ms] so floats stay small far from the map origin;
## call [method set_bubble_origin] whenever the snapshot's bubble_origin changes.

## Emitted after a rebase with the offset to add to everything already placed in Godot space.
signal origin_shifted(delta: Vector3)

const TILE_M := 1.0
const LEVEL_M := 3.0
const SEEX := 12        # squares per submap side
const MAPSIZE := 11     # submaps per bubble side
## The map's z range when a snapshot doesn't send `z_levels` (CDDA's OVERMAP_DEPTH / OVERMAP_HEIGHT today).
const Z_MIN_DEFAULT := -10
const Z_MAX_DEFAULT := 10
## No z range may reach past this either way (Snapshot rejects one that does); also "above every level".
const Z_LIMIT := 64

## Absolute square at Godot (0, 0, 0). Its z stays 0, so level z always sits at y = z * LEVEL_M.
var origin_ms := Vector3i.ZERO
## The map's whole z range, from the snapshot shown last (WorldView sets it on the main thread).
var z_min := Z_MIN_DEFAULT
var z_max := Z_MAX_DEFAULT


## Rebases on the bubble's corner submap. Returns the offset applied to existing Godot positions.
func set_bubble_origin(origin_sm: Vector3i) -> Vector3:
	var new_origin := Vector3i(origin_sm.x * SEEX, origin_sm.y * SEEX, 0)
	var delta := ms_offset_to_world(origin_ms - new_origin)
	origin_ms = new_origin
	if delta != Vector3.ZERO:
		origin_shifted.emit(delta)
	return delta


## A difference of squares (not a position), in metres.
static func ms_offset_to_world(d: Vector3i) -> Vector3:
	return Vector3(d.x * TILE_M, d.z * LEVEL_M, d.y * TILE_M)


## Corner of a square (min x, min y) at its floor height.
func ms_to_world(p: Vector3i) -> Vector3:
	return ms_offset_to_world(p - origin_ms)


func ms_center_to_world(p: Vector3i) -> Vector3:
	return ms_to_world(p) + Vector3(0.5 * TILE_M, 0.0, 0.5 * TILE_M)


## Corner of a submap (its square 0,0) at floor height.
func sm_to_world(sm: Vector3i) -> Vector3:
	return ms_to_world(sm_to_ms(sm))


## Square containing a Godot position; a point on a floor belongs to that floor's level.
func world_to_ms(w: Vector3) -> Vector3i:
	return origin_ms + Vector3i(floori(w.x / TILE_M), floori(w.z / TILE_M), floori(w.y / LEVEL_M))


func world_to_sm(w: Vector3) -> Vector3i:
	return ms_to_sm(world_to_ms(w))


static func sm_to_ms(sm: Vector3i) -> Vector3i:
	return Vector3i(sm.x * SEEX, sm.y * SEEX, sm.z)


static func ms_to_sm(p: Vector3i) -> Vector3i:
	return Vector3i((p.x - posmod(p.x, SEEX)) / SEEX, (p.y - posmod(p.y, SEEX)) / SEEX, p.z)


## Square within its submap, 0..11 on both axes.
static func ms_to_local(p: Vector3i) -> Vector2i:
	return Vector2i(posmod(p.x, SEEX), posmod(p.y, SEEX))
