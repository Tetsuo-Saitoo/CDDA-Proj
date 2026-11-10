class_name PlayerBody
extends Node3D
## The player's own body (placeholder until there are models): one box per CDDA main body part, tinted by its
## hp (red as it drops, grey at 0, green when infected), with what the player wears drawn over it inner to
## outer, each layer a little larger (socks under shoes, shirt under jacket). Worn items take CDDA's item
## colour, browner with damage, paler with degradation, with dark tears from damage 2 up. Bandages, bleeding
## and bites show on top of the outermost layer of that part, so they stay visible. The origin is the floor;
## it faces -Z. In first person and VR the head (and what is worn only there) is hidden from the own camera.

const SKIN := Color(0.85, 0.68, 0.55)
const LAYER_M := 0.016          # each worn layer stands this much farther out
const HEAD_PARTS := ["head", "eyes", "mouth"]
## body_part id -> [centre, size] in metres (floor origin, facing -Z, the character's left is -X).
const PARTS := {
	"torso": [Vector3(0, 1.18, 0), Vector3(0.36, 0.56, 0.22)],
	"head": [Vector3(0, 1.62, 0), Vector3(0.2, 0.24, 0.22)],
	"eyes": [Vector3(0, 1.65, -0.105), Vector3(0.16, 0.04, 0.03)],
	"mouth": [Vector3(0, 1.55, -0.105), Vector3(0.08, 0.03, 0.03)],
	"arm_l": [Vector3(-0.25, 1.17, 0), Vector3(0.1, 0.56, 0.1)],
	"arm_r": [Vector3(0.25, 1.17, 0), Vector3(0.1, 0.56, 0.1)],
	"hand_l": [Vector3(-0.25, 0.82, 0), Vector3(0.08, 0.13, 0.1)],
	"hand_r": [Vector3(0.25, 0.82, 0), Vector3(0.08, 0.13, 0.1)],
	"leg_l": [Vector3(-0.1, 0.5, 0), Vector3(0.15, 0.84, 0.15)],
	"leg_r": [Vector3(0.1, 0.5, 0), Vector3(0.15, 0.84, 0.15)],
	"foot_l": [Vector3(-0.1, 0.04, -0.04), Vector3(0.11, 0.08, 0.26)],
	"foot_r": [Vector3(0.1, 0.04, -0.04), Vector3(0.11, 0.08, 0.26)],
}
const SHOULDER_Y := 1.45
const ARM_REACH := 0.62         # shoulder to hand centre, metres
const HIP_SLACK := 0.6          # radians the head may turn before the hips follow
const HIP_RATE := 6.0           # rad/s the hips catch up with
## Fingers (VR): thumb, index, middle, ring, little; three segments each, metres.
const FINGER_LEN := [[0.035, 0.03, 0.025], [0.04, 0.025, 0.02], [0.045, 0.028, 0.022], [0.042, 0.026, 0.02],
		[0.033, 0.02, 0.018]]
const FINGER_W := 0.016
const CURL_RAD := 1.25          # bend per joint at full curl
const BLOOD := Color(0.55, 0.02, 0.02)
const BANDAGE := Color(0.95, 0.95, 0.9)
const BITE := Color(0.3, 0.1, 0.3)
const TEAR := Color(0.08, 0.06, 0.05)
const WORN_OUT := Color(0.32, 0.24, 0.16)

var show_head := true:
	set(v):
		show_head = v
		for n: Node3D in _head_nodes:
			n.visible = v
var key := ""                   # what it was last built from
var pieces: Array[Dictionary] = []   # the last plan (tests read it)

var hip_yaw := 0.0              # set by follow_head (VR)
var show_fingers := false:      # VR only (desktop hands stay boxes)
	set(v):
		show_fingers = v
		for side: String in _fingers:
			(_fingers[side] as Node3D).visible = v
var _fingers := {}              # "l"/"r" -> Node3D holding 15 segment meshes
var _head_nodes: Array[Node3D] = []
static var _mats := {}


## Rebuilds when the player's body or clothes changed.
func apply(snap: Snapshot, tables: IdTables) -> void:
	var k := key_of(snap)
	if k == key:
		return
	key = k
	pieces = plan(snap, tables)
	_build()


## VR: the hips turn only when the head has looked HIP_SLACK away, then catch up smoothly.
static func next_hip_yaw(hips: float, head: float, delta: float) -> float:
	var d := angle_difference(hips, head)
	if absf(d) <= HIP_SLACK:
		return hips
	var step := signf(d) * minf(absf(d) - HIP_SLACK * 0.5, HIP_RATE * delta)
	return wrapf(hips + step, -PI, PI)


func follow_head(head_yaw: float, delta: float) -> void:
	hip_yaw = next_hip_yaw(hip_yaw, head_yaw, delta)
	rotation = Vector3(0, hip_yaw, 0)


## VR: points each arm at its controller (global positions; null = the arm hangs). Call after placing the body.
func reach(left_hand: Variant, right_hand: Variant) -> void:
	_reach("arm_l", "hand_l", -1.0, left_hand)
	_reach("arm_r", "hand_r", 1.0, right_hand)


## Where the hand centre goes (body-local) for a target, and the arm's turn from hanging down.
static func arm_pose(side: float, target_local: Vector3) -> Array:
	var shoulder := Vector3(0.25 * side, SHOULDER_Y, 0)
	var to := target_local - shoulder
	if to.length() < 0.05:
		return [shoulder + Vector3.DOWN * ARM_REACH, Quaternion.IDENTITY]
	var dir := to.normalized()
	return [shoulder + dir * minf(to.length(), ARM_REACH), Quaternion(Vector3.DOWN, dir)]


func _reach(arm_name: String, hand_name: String, side: float, target: Variant) -> void:
	var arm := get_node_or_null(arm_name) as Node3D
	var hand := get_node_or_null(hand_name) as Node3D
	if target == null:
		if arm != null:
			arm.transform = Transform3D.IDENTITY
		if hand != null:
			hand.transform = Transform3D.IDENTITY
		return
	var pose := arm_pose(side, to_local(target))
	var shoulder := Vector3(0.25 * side, SHOULDER_Y, 0)
	if arm != null:
		var b := Basis(pose[1] as Quaternion)
		arm.transform = Transform3D(b, shoulder - b * shoulder)
	if hand != null:
		var rest: Vector3 = PARTS[hand_name][0]
		hand.transform = Transform3D(Basis.IDENTITY, (pose[0] as Vector3) - rest)


static func key_of(snap: Snapshot) -> String:
	var parts := []
	for b: Snapshot.BodyPart in snap.player_parts:
		parts.append([b.id, b.hp, b.hp_max, b.bleed, b.bandaged, b.bite, b.infected])
	var worn := []
	for w: Snapshot.Worn in snap.player_worn:
		worn.append([w.type, w.layer, w.damage, w.degradation, w.covers])
	return var_to_str([parts, worn])


## What to draw: a list of {part, kind (skin, worn, tear, bandage, blood, bite), centre, size, colour, item}.
static func plan(snap: Snapshot, tables: IdTables) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var by_name := {}   # part id -> Snapshot.BodyPart
	for b: Snapshot.BodyPart in snap.player_parts:
		by_name[_part_name(tables, b.id)] = b
	var depth := {}   # part id -> layers drawn so far
	for part: String in PARTS:
		if not by_name.is_empty() and not by_name.has(part):
			continue   # the character lacks it (or the bridge sent other parts)
		depth[part] = 0
		out.append(_piece(part, "skin", 0, skin_color(by_name.get(part))))
	for w: Snapshot.Worn in snap.player_worn:
		var def := tables.def_at("itype", w.type) if tables != null else null
		var col := worn_color(def, w)
		for id: int in w.covers:
			var part := _part_name(tables, id)
			if not depth.has(part):
				continue
			depth[part] += 1
			var p := _piece(part, "worn", depth[part], col)
			p["item"] = w.type
			out.append(p)
			for t in clampi(w.damage - 1, 0, 3):
				out.append(_tear(p, t, w.type))
	for part: String in by_name:
		if not depth.has(part):
			continue
		var b: Snapshot.BodyPart = by_name[part]
		var outer := _piece(part, "", depth[part] + 1, Color.WHITE)
		if b.bandaged > 0:
			var band := outer.duplicate()
			band["kind"] = "bandage"
			band["colour"] = BANDAGE
			band["size"] = Vector3(outer["size"].x, minf(0.08, outer["size"].y * 0.4), outer["size"].z)
			out.append(band)
		if b.bleed > 0:
			out.append(_mark(outer, "blood", BLOOD, 0.03 + 0.003 * mini(b.bleed, 20), Vector2(0.2, 0.25)))
		if b.bite > 0:
			out.append(_mark(outer, "bite", BITE, 0.04, Vector2(-0.25, -0.1)))
	return out


static func skin_color(b: Snapshot.BodyPart) -> Color:
	if b == null:
		return SKIN
	if b.hp <= 0:
		return Color(0.25, 0.22, 0.22)   # broken
	var c := SKIN.lerp(Color(0.8, 0.1, 0.08), 0.85 * (1.0 - clampf(float(b.hp) / maxi(1, b.hp_max), 0.0, 1.0)))
	if b.infected > 0:
		c = c.lerp(Color(0.35, 0.6, 0.2), 0.45)
	return c


static func worn_color(def: IdTables.Def, w: Snapshot.Worn) -> Color:
	var c := Color(0.5, 0.5, 0.48)
	if def != null:
		var fg_bg := CddaText.parse_color(def.color)
		if not fg_bg.is_empty():
			c = Color.html(fg_bg[0]).lerp(Color(0.42, 0.42, 0.4), 0.35)
	else:
		c = Color.from_hsv(fmod(w.type * 0.618034, 1.0), 0.35, 0.6)
	c = c.lerp(WORN_OUT, 0.12 * clampi(w.damage, 0, 5))
	c.s *= 1.0 - 0.6 * w.degradation / 255.0
	return c


static func _part_name(tables: IdTables, id: int) -> String:
	return tables.body_part_name(id) if tables != null else ""


static func _piece(part: String, kind: String, layer: int, col: Color) -> Dictionary:
	var box: Array = PARTS[part]
	var grow := 2.0 * LAYER_M * layer
	var size: Vector3 = box[1] + Vector3(grow, grow * 0.5, grow)
	return {"part": part, "kind": kind, "centre": box[0], "size": size, "colour": col, "item": 0, "layer": layer}


## A dark patch on the front of a worn piece (spots picked from the item id, so they stay put).
static func _tear(p: Dictionary, n: int, seed_id: int) -> Dictionary:
	var h := hash([seed_id, p["part"], n])
	var s: Vector3 = p["size"]
	var u := Vector2(((h & 0xFF) / 255.0 - 0.5) * 0.7, (((h >> 8) & 0xFF) / 255.0 - 0.5) * 0.7)
	return _mark(p, "tear", TEAR, minf(0.035, minf(s.x, s.y) * 0.35), u)


## A thin square on the front face of `p` at u (-0.5..0.5 across, up), `side` metres wide.
static func _mark(p: Dictionary, kind: String, col: Color, side: float, u: Vector2) -> Dictionary:
	var s: Vector3 = p["size"]
	var c: Vector3 = p["centre"] + Vector3(u.x * s.x, u.y * s.y, -s.z / 2.0 - 0.002)
	return {"part": p["part"], "kind": kind, "centre": c, "size": Vector3(side, side, 0.004), "colour": col,
			"item": p.get("item", 0), "layer": p.get("layer", 0)}


func _build() -> void:
	for c in get_children():
		c.free()
	_head_nodes.clear()
	var nodes := {}
	for p: Dictionary in pieces:
		var part: String = p["part"]
		if not nodes.has(part):
			var n := Node3D.new()
			n.name = part
			add_child(n)
			nodes[part] = n
			if part in HEAD_PARTS:
				_head_nodes.append(n)
				n.visible = show_head
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = p["size"]
		mi.mesh = box
		mi.position = p["centre"]
		mi.material_override = _material(p["colour"])
		(nodes[part] as Node3D).add_child(mi)
	_build_fingers()


## Finger joints for a hand without hand tracking: from the controller's curls (0 open .. 1 fist), thumb
## first. Body-local; returns 5 lists of 4 points (knuckle .. tip).
func curled_points(side: float, curls: Array) -> Array:
	var arm := get_node_or_null("arm_l" if side < 0 else "arm_r") as Node3D
	var hand := get_node_or_null("hand_l" if side < 0 else "hand_r") as Node3D
	var b := arm.transform.basis if arm != null else Basis.IDENTITY
	var palm: Vector3 = PARTS["hand_l" if side < 0 else "hand_r"][0]
	if hand != null:
		palm = hand.transform * palm
	return finger_points(side, b, palm, curls)


static func finger_points(side: float, b: Basis, palm: Vector3, curls: Array) -> Array:
	var fwd := (b * Vector3.DOWN).normalized()      # along the fingers
	var inward := (b * Vector3(-side, 0, 0)).normalized()   # the palm faces the thigh when the arm hangs
	var front := (b * Vector3.FORWARD).normalized()
	var out := []
	for f in 5:
		var c := clampf(float(curls[f]) if f < curls.size() else 0.0, 0.0, 1.0)
		var p: Vector3
		var dir: Vector3
		var bend_axis: Vector3
		if f == 0:   # thumb: from the front of the palm, pointing forward-down, curls across the palm
			p = palm + front * 0.04 + fwd * 0.01
			dir = (fwd + front).normalized()
			bend_axis = fwd.cross(inward).normalized()
		else:
			p = palm + fwd * 0.06 + front * (0.035 - 0.022 * f)
			dir = fwd
			bend_axis = inward.cross(fwd).normalized()
		var pts := [p]
		for seg in 3:
			dir = dir.rotated(bend_axis, -c * CURL_RAD).normalized()
			p += dir * float(FINGER_LEN[f][seg])
			pts.append(p)
		out.append(pts)
	return out


## Poses the fingers of one hand ("l"/"r") from 5 lists of 4 body-local points.
func pose_fingers(side: String, points: Array) -> void:
	var holder := _fingers.get(side) as Node3D
	if holder == null or points.size() != 5:
		return
	var i := 0
	for f in 5:
		var pts: Array = points[f]
		for seg in 3:
			var mi := holder.get_child(i) as MeshInstance3D
			i += 1
			var a: Vector3 = pts[seg]
			var e: Vector3 = pts[seg + 1]
			var len := a.distance_to(e)
			if len < 0.001:
				mi.visible = false
				continue
			mi.visible = true
			var z := (e - a) / len
			var up := Vector3.UP if absf(z.y) < 0.95 else Vector3.RIGHT
			var x := up.cross(z).normalized()
			mi.transform = Transform3D(Basis(x, z.cross(x), z).scaled_local(Vector3(1, 1, len)), (a + e) * 0.5)


func _build_fingers() -> void:
	_fingers.clear()
	for side: String in ["l", "r"]:
		var col := SKIN
		for p: Dictionary in pieces:
			if p["part"] == "hand_" + side and p["kind"] in ["skin", "worn"]:
				col = p["colour"]   # the outermost glove wins
		var holder := Node3D.new()
		holder.name = "fingers_" + side
		holder.visible = show_fingers
		add_child(holder)
		var box := BoxMesh.new()
		box.size = Vector3(FINGER_W, FINGER_W, 1.0)
		for k in 15:
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.material_override = _material(col)
			holder.add_child(mi)
		_fingers[side] = holder


static func _material(c: Color) -> StandardMaterial3D:
	var k := c.to_html(false)
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		_mats[k] = m
	return _mats[k]
