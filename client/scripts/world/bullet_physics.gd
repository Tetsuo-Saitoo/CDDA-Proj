class_name BulletPhysics
extends RefCounted
## Client-side bullets (CDDA decides the damage, the client decides where the bullet goes; fp3d/shot.h).
## A bullet leaves the muzzle at the ammo's speed, slows with drag (a = -k v²), falls with gravity, and is
## stepped in short segments. Each segment is tested against the creature figures' body parts (the meshes as
## drawn, each a box in its own space) and against the map (LookRay: walls, closed doors, furniture, floors).
## The result says what was hit: a creature (uid, zone, the CDDA part to hit, quality = how far from the
## part's centre) or the map, where the bullet stopped, and the path for a tracer.
## Sights are zeroed at ZERO_M: `launch_dir` tilts the bore up so the path crosses the line of sight there.

const G := 9.81
const STEP_S := 0.004          # seconds per segment (~1.5-4 m at rifle / pistol speed)
const MAX_S := 2.0
const MAX_M := 130.0           # past the loaded bubble's edge
const ZERO_M := 25.0
const SEGMENT_REACH := 1.5     # figures within this of a segment are tested

## Ammo type (CDDA ammotype id, gun_ammo in the id tables) -> [muzzle speed m/s, drag k 1/m]. First match by
## substring of the id (the longest key wins); DEFAULT otherwise. Values are typical, not CDDA's (CDDA has no speeds).
const AMMO := [
	["arrow", 85.0, 0.0025], ["bolt", 100.0, 0.0022], ["40x46", 76.0, 0.0006], ["40x53", 240.0, 0.0006],
	["66mm", 145.0, 0.0004], ["84x246", 255.0, 0.0004], ["rocket", 145.0, 0.0004], ["shot", 400.0, 0.006],
	["410", 380.0, 0.006], ["22", 370.0, 0.0014], ["9mm", 360.0, 0.0012], ["9x18", 320.0, 0.0012],
	["380", 290.0, 0.0013], ["38", 300.0, 0.0012], ["357", 430.0, 0.001], ["40", 330.0, 0.0012],
	["10mm", 400.0, 0.0011], ["45", 260.0, 0.0012], ["44", 410.0, 0.001], ["454", 500.0, 0.0009],
	["500", 430.0, 0.0009], ["57", 715.0, 0.0009], ["46", 720.0, 0.0009], ["223", 940.0, 0.0008],
	["545", 900.0, 0.0008], ["762x39", 715.0, 0.0008], ["308", 850.0, 0.0006], ["762", 830.0, 0.0006],
	["3006", 860.0, 0.0006], ["300", 870.0, 0.0006], ["270", 900.0, 0.0006], ["50", 890.0, 0.0004],
	["blunderbuss", 300.0, 0.004], ["flintlock", 350.0, 0.002], ["nail", 120.0, 0.003], ["bb", 150.0, 0.004],
	["pebble", 60.0, 0.003],
]
const DEFAULT := [500.0, 0.001]

## Monster zones -> CDDA weak point ids to try, in order ("" = the body).
const MONSTER_PARTS := {
	"head": ["head"], "eye": ["eye", "head"], "torso": ["abdomen", "belly"], "arm_l": ["arm"], "arm_r": ["arm"],
	"leg_l": ["leg", "hindleg"], "leg_r": ["leg", "hindleg"], "leg": ["leg"], "wing": ["wing"],
}
## Character (player, NPC) zones -> CDDA body parts.
const CHARACTER_PARTS := {
	"head": "head", "eye": "eyes", "torso": "torso", "arm_l": "arm_l", "arm_r": "arm_r", "leg_l": "leg_l",
	"leg_r": "leg_r", "leg": "leg_l", "wing": "torso",
}


## [speed m/s, drag k] for a CDDA ammo type id.
static func ammo_profile(ammo: String) -> Array:
	var a := ammo.to_lower()
	var best: Array = []
	if not a.is_empty():
		for row: Array in AMMO:   # the longest matching key: "223" before "22", "762x39" before "762"
			if a.contains(row[0]) and (best.is_empty() or String(row[0]).length() > String(best[0]).length()):
				best = row
	return [best[1], best[2]] if not best.is_empty() else DEFAULT.duplicate()


## The bore direction for sights along `sight_dir` zeroed at ZERO_M: tilted up by the drop there.
static func launch_dir(sight_dir: Vector3, speed: float) -> Vector3:
	var d := sight_dir.normalized()
	var t := ZERO_M / maxf(speed, 1.0)
	var angle := atan2(0.5 * G * t * t, ZERO_M)
	var axis := d.cross(Vector3.UP)
	return d.rotated(axis.normalized(), angle) if axis.length() > 0.001 else d


## Flies a bullet. `figures`: uid -> CreatureFigure; `shooter_uid` is never hit; `look_ray` tests the map
## (null: no map). Returns {path: Array[Vector3], time: float, hit: "creature" / "map" / "", uid, zone,
## point: Vector3, quality: float}.
static func fly(origin: Vector3, dir: Vector3, speed: float, k: float, figures: Dictionary, look_ray: LookRay,
		shooter_uid := 1) -> Dictionary:
	var pos := origin
	var vel := dir.normalized() * speed
	var path: Array[Vector3] = [origin]
	var t := 0.0
	var travelled := 0.0
	while t < MAX_S and travelled < MAX_M and vel.length() > 30.0:
		var v := vel.length()
		var acc := Vector3(0, -G, 0) - vel * (k * v)
		var next := pos + vel * STEP_S + acc * (0.5 * STEP_S * STEP_S)
		var seg := next - pos
		var seg_len := seg.length()
		var hit := _hit_figure(pos, seg, figures, shooter_uid)
		var map_hit := {}
		if look_ray != null and seg_len > 0.0:
			map_hit = look_ray.cast(pos, seg, seg_len, false)
		var map_d: float = pos.distance_to(map_hit["point"]) if map_hit.get("hit", false) else INF
		if not hit.is_empty() and hit["d"] <= map_d:
			path.append(hit["point"])
			hit["path"] = path
			hit["time"] = t + STEP_S * hit["d"] / maxf(seg_len, 0.0001)
			hit["hit"] = "creature"
			return hit
		if map_d < INF:
			path.append(map_hit["point"])
			return {"path": path, "time": t, "hit": "map", "point": map_hit["point"], "uid": 0, "zone": "",
					"quality": 1.0}
		pos = next
		vel += acc * STEP_S
		t += STEP_S
		travelled += seg_len
		path.append(pos)
	return {"path": path, "time": t, "hit": "", "point": pos, "uid": 0, "zone": "", "quality": 1.0}


## The nearest body part a segment passes through: {d, point, uid, zone, quality} or {}.
static func _hit_figure(from: Vector3, seg: Vector3, figures: Dictionary, shooter_uid: int) -> Dictionary:
	var best := {}
	var seg_len := seg.length()
	if seg_len <= 0.0:
		return best
	var dir := seg / seg_len
	for uid: int in figures:
		if uid == shooter_uid:
			continue
		var f: CreatureFigure = figures[uid]
		if f == null or not f.visible or not f.is_inside_tree():
			continue
		var c := f.global_position + Vector3(0, f.top * 0.5, 0)
		var closest := from + dir * clampf((c - from).dot(dir), 0.0, seg_len)
		if closest.distance_to(c) > SEGMENT_REACH + f.top:
			continue
		for z: Array in f.hit_zones():
			var m: MeshInstance3D = z[0]
			var r := _ray_box(m.global_transform, m.get_aabb(), from, dir, seg_len)
			if r.is_empty() or (not best.is_empty() and r["d"] >= best["d"]):
				continue
			best = {"d": r["d"], "point": from + dir * r["d"], "uid": uid, "zone": z[1], "quality": r["off"]}
	return best


## Ray against an AABB in a mesh's own space: {d (along the world ray), off (0 centre .. 1 edge)} or {}.
static func _ray_box(xf: Transform3D, box: AABB, from: Vector3, dir: Vector3, max_d: float) -> Dictionary:
	var inv := xf.affine_inverse()
	var o := inv * from
	var e := inv * (from + dir * max_d)
	var hit: Variant = box.intersects_segment(o, e)
	if hit == null:
		return {}
	var world_hit := xf * (hit as Vector3)
	var c := box.get_center()
	var half := box.size * 0.5
	var rel := ((hit as Vector3) - c).abs()
	var off := 0.0
	for i in 3:
		if half[i] > 0.0001:
			off = maxf(off, rel[i] / half[i])
	# off from the face hit is ~1 on one axis: use the two others (how central across the part)
	var axes := []
	for i in 3:
		if half[i] > 0.0001:
			axes.append(rel[i] / half[i])
	axes.sort()
	var across: float = axes[axes.size() - 2] if axes.size() >= 2 else off
	return {"d": from.distance_to(world_hit), "off": clampf(across, 0.0, 1.0)}


## The CDDA part for a zone: a body part id for characters, a weak point id for monsters ("" = the body).
static func cdda_part(zone: String, is_monster: bool, weakpoints: Dictionary) -> String:
	if not is_monster:
		return CHARACTER_PARTS.get(zone, "torso")
	for w: String in MONSTER_PARTS.get(zone, []):
		if weakpoints.has(w):
			return w
	return ""


## CDDA's goodhit for a hit `off` from the part's centre: 0.05 dead centre .. 0.7 at the edge.
static func quality_of(off: float) -> float:
	return lerpf(0.05, 0.7, clampf(off, 0.0, 1.0))
