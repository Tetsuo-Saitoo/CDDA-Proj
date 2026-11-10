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
const SOFT_PASSES := 4         # furniture squares one segment flies through at most (soft cover)
const NEAR_MAX := 64           # a flight tests at most this many figures, the nearest along its line
const NEAR_MARGIN_M := 2.0     # ... within this of the launch line, plus the drop at MAX_M
const NEAR_DROP_CAP_M := 40.0  # (that drop capped here: slow arrows and grenades)

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


## The figures a flight can reach (keeps hordes cheap): those whose centre lies within NEAR_MARGIN_M + the
## drop at MAX_M for `speed` (capped at NEAR_DROP_CAP_M) + their height of the straight line from `origin`
## along `dir` (the launch direction), in front of the origin and not past MAX_M; at most NEAR_MAX, the nearest
## along the line. `shooter_uid`, hidden and freed figures are left out. uid -> CreatureFigure, like `figures`.
static func figures_near_line(figures: Dictionary, origin: Vector3, dir: Vector3, speed: float,
		shooter_uid := 1) -> Dictionary:
	var out := {}
	if not origin.is_finite() or not dir.is_finite() or dir.length_squared() < 1e-12:
		return out
	var d := dir.normalized()
	var t := MAX_M / (clampf(speed, 1.0, 1e5) if is_finite(speed) else 1.0)
	var margin := NEAR_MARGIN_M + minf(0.5 * G * t * t, NEAR_DROP_CAP_M)
	var near := []   # [distance along the line, uid]
	for uid: Variant in figures:
		if not uid is int or uid == shooter_uid:
			continue
		var f: Variant = figures[uid]
		if not is_instance_valid(f) or not f is CreatureFigure:
			continue
		var fig: CreatureFigure = f
		if not fig.visible or not fig.is_inside_tree():
			continue
		var h := clampf(fig.top, 0.0, 20.0) if is_finite(fig.top) else 1.0
		var rel := fig.global_position + Vector3(0, h * 0.5, 0) - origin
		var along := rel.dot(d)
		if along < -h or along > MAX_M + h or (rel - d * along).length() > margin + h:
			continue
		near.append([along, uid])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in mini(near.size(), NEAR_MAX):
		out[near[i][1]] = figures[near[i][1]]
	return out


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
			map_hit = _map_hit(look_ray, pos, seg / seg_len, seg_len)
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


## The first thing that stops a bullet along a segment (unit `dir`, `seg_len` m) on the map, as LookRay.cast, or
## {}. Furniture is soft cover: the bullet flies on through it (at most SOFT_PASSES squares a segment) and CDDA's
## own path decides what it stops (map::shoot); walls, doors, floors, stairs and the like stop it.
static func _map_hit(look_ray: LookRay, from: Vector3, dir: Vector3, seg_len: float) -> Dictionary:
	var start := from
	var left := seg_len
	for i in SOFT_PASSES + 1:
		var h := look_ray.cast(start, dir, left, false)
		if not h.get("hit", false) or h.get("what") != "furniture":
			return h
		var past: Vector3 = h["point"] + dir * LookRay.STEP_M   # on from inside that square (cast skips its start)
		left -= start.distance_to(past)
		if left <= 0.0:
			return {}
		start = past
	return {}


## The nearest body part a straight segment from `from` along `seg` passes through, if no wall, door, floor or
## furniture is in the way first: {d, point, uid, zone, quality} or {} (melee picks, AimController.melee_from).
static func reach_figure(from: Vector3, seg: Vector3, figures: Dictionary, look_ray: LookRay,
		shooter_uid := 1) -> Dictionary:
	var hit := _hit_figure(from, seg, figures, shooter_uid)
	if hit.is_empty() or look_ray == null:
		return hit
	var m := look_ray.cast(from, seg.normalized(), hit["d"], false)
	return {} if m.get("hit", false) else hit


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
