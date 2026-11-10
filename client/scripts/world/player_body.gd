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
const UPPER_ARM := 0.29         # shoulder to elbow, metres (the arm box spans shoulder .. wrist)
const FOREARM := 0.27           # elbow to wrist
const ELBOW_Y := SHOULDER_Y - UPPER_ARM
const WRIST_Y := ELBOW_Y - FOREARM
const ARM_REACH := UPPER_ARM + FOREARM   # shoulder to wrist, arm straight
## Where an elbow points when the arm bends (body-local, x outward for the side): down, out and back.
const ELBOW_HINT := Vector3(0.6, -1.0, 0.35)
const HIP_SLACK := 0.6          # radians the head may turn before the hips follow
const HIP_RATE := 6.0           # rad/s the hips catch up with
const ARMS := ["arm_l", "arm_r"]
const HANDS := ["hand_l", "hand_r"]
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
## False in VR: the rig draws the hands (VrHand, fingers and all) and the arms reach for their wrists.
var show_hands := true:
	set(v):
		show_hands = v
		for n: Node3D in _hand_nodes:
			n.visible = v
var _head_nodes: Array[Node3D] = []
var _hand_nodes: Array[Node3D] = []
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


## VR: each arm reaches for a wrist (global positions; null = the arm hangs), bending at the elbow. Call after
## placing the body.
func reach(left_wrist: Variant, right_wrist: Variant) -> void:
	_reach(0, -1.0, left_wrist)
	_reach(1, 1.0, right_wrist)


static func shoulder_of(side: float) -> Vector3:
	return Vector3(0.25 * side, SHOULDER_Y, 0)


## Two-bone arm for a wrist target (body-local): [elbow, wrist]. The wrist stops at the arm's length (the arm
## doesn't stretch); the elbow bends toward ELBOW_HINT.
static func arm_ik(side: float, target_local: Vector3) -> Array:
	var s := shoulder_of(side)
	var to := target_local - s
	var d := to.length()
	if d < 0.05:
		return [s + Vector3.DOWN * UPPER_ARM, s + Vector3.DOWN * ARM_REACH]
	var dir := to / d
	var r := clampf(d, absf(UPPER_ARM - FOREARM) + 0.02, ARM_REACH - 0.0001)
	var a := acos(clampf((UPPER_ARM * UPPER_ARM + r * r - FOREARM * FOREARM) / (2.0 * UPPER_ARM * r), -1.0, 1.0))
	var hint := Vector3(ELBOW_HINT.x * side, ELBOW_HINT.y, ELBOW_HINT.z)
	var perp := hint - dir * hint.dot(dir)
	if perp.length() < 0.001:   # pointing along the hint: bend outward
		perp = Vector3(side, 0, 0) - dir * dir.x * side
	perp = perp.normalized()
	return [s + dir * (UPPER_ARM * cos(a)) + perp * (UPPER_ARM * sin(a)), s + dir * r]


## Moves rest point `from` to `to`, turned so that straight down points along `dir`.
static func _bone(from: Vector3, to: Vector3, dir: Vector3) -> Transform3D:
	var b := Basis(Quaternion(Vector3.DOWN, dir.normalized())) if dir.length() > 0.0001 else Basis.IDENTITY
	return Transform3D(b, to - b * from)


func _reach(i: int, side: float, target: Variant) -> void:
	var arm := get_node_or_null(ARMS[i]) as Node3D
	var fore := arm.get_node_or_null("fore") as Node3D if arm != null else null
	var hand := get_node_or_null(HANDS[i]) as Node3D
	var upper_xf := Transform3D.IDENTITY
	var fore_xf := Transform3D.IDENTITY   # body space
	if target != null:
		var ew := arm_ik(side, to_local(target))
		var s := shoulder_of(side)
		var e0 := Vector3(s.x, ELBOW_Y, 0)
		upper_xf = _bone(s, s, (ew[0] as Vector3) - s)
		fore_xf = _bone(e0, ew[0], (ew[1] as Vector3) - (ew[0] as Vector3))
	if arm != null:
		arm.transform = upper_xf
	if fore != null:
		fore.transform = upper_xf.affine_inverse() * fore_xf
	if hand != null:
		hand.transform = fore_xf


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
	_hand_nodes.clear()
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
			if part in HANDS:
				_hand_nodes.append(n)
				n.visible = show_hands
			if part in ARMS:   # the forearm bends at the elbow (reach)
				var fore := Node3D.new()
				fore.name = "fore"
				n.add_child(fore)
		if part in ARMS:
			for half: Array in split_at_elbow(p["centre"], p["size"]):
				var holder: Node3D = nodes[part] if half[2] == "upper" else (nodes[part] as Node3D).get_node("fore")
				holder.add_child(_box(half[0], half[1], p["colour"]))
		else:
			(nodes[part] as Node3D).add_child(_box(p["centre"], p["size"], p["colour"]))


## An arm piece cut at the elbow: [[centre, size, "upper" | "fore"], ...] (one entry when it lies on one side).
static func split_at_elbow(centre: Vector3, size: Vector3) -> Array:
	var top := centre.y + size.y * 0.5
	var bottom := centre.y - size.y * 0.5
	var out := []
	if top > ELBOW_Y:
		var lo := maxf(bottom, ELBOW_Y)
		out.append([Vector3(centre.x, (top + lo) * 0.5, centre.z), Vector3(size.x, top - lo, size.z), "upper"])
	if bottom < ELBOW_Y:
		var hi := minf(top, ELBOW_Y)
		out.append([Vector3(centre.x, (hi + bottom) * 0.5, centre.z), Vector3(size.x, hi - bottom, size.z), "fore"])
	return out


static func _box(centre: Vector3, size: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = centre
	mi.material_override = _material(col)
	return mi


static func _material(c: Color) -> StandardMaterial3D:
	var k := c.to_html(false)
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.9
		_mats[k] = m
	return _mats[k]
