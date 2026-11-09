class_name CreatureFigure
extends Node3D
## A placeholder creature body (block C4, until there are models): built from simple shapes after CDDA's body
## type (human, dog, insect, snake, bird, fish, blob, ...; from the species when the bridge doesn't say),
## scaled by its size class, tinted with its CDDA colour, and animated in code: idle sway, a walk cycle while
## it moves, an attack lunge, a hurt flinch, a fall when it dies. The origin is the floor under the creature;
## it faces -Z. CreatureView moves it between squares (move_to) and calls animate() every frame.

enum Plan { HUMANOID, QUADRUPED, CRAWLER, SNAKE, FLYER, FISH, BLOB }

const SIZE_SCALE := {1: 0.35, 2: 0.6, 3: 1.0, 4: 1.4, 5: 2.0}   # creature_size -> scale (medium = 1)
const BODYTYPES := {
	"human": Plan.HUMANOID, "migo": Plan.HUMANOID,
	"dog": Plan.QUADRUPED, "pig": Plan.QUADRUPED, "horse": Plan.QUADRUPED, "bear": Plan.QUADRUPED,
	"cow": Plan.QUADRUPED, "kangaroo": Plan.QUADRUPED, "lizard": Plan.QUADRUPED, "turtle": Plan.QUADRUPED,
	"frog": Plan.QUADRUPED,
	"insect": Plan.CRAWLER, "spider": Plan.CRAWLER, "crab": Plan.CRAWLER,
	"snake": Plan.SNAKE, "bird": Plan.FLYER, "flying insect": Plan.FLYER, "fish": Plan.FISH, "blob": Plan.BLOB,
}
## Without a body type: the first species found decides (animals before HUMAN/ZOMBIE: zombie dogs are dogs).
const SPECIES_PLANS := [
	["FISH", Plan.FISH], ["BIRD", Plan.FLYER], ["INSECT_FLYING", Plan.FLYER], ["ROBOT_FLYING", Plan.FLYER],
	["INSECT", Plan.CRAWLER], ["SPIDER", Plan.CRAWLER], ["MAMMAL", Plan.QUADRUPED], ["AMPHIBIAN", Plan.QUADRUPED],
	["REPTILE", Plan.QUADRUPED], ["HUMAN", Plan.HUMANOID], ["FERAL", Plan.HUMANOID], ["ZOMBIE", Plan.HUMANOID],
]
const HUMAN_H := 1.75
const SKIN := Color(0.85, 0.68, 0.55)
const NPC_CLOTHES := Color(0.25, 0.4, 0.85)
const PLAYER_CLOTHES := Color(1.0, 0.55, 0.1)
const ATTACK_S := 0.45
const HURT_S := 0.3
const DIE_S := 0.6
const SINK_AFTER_S := 2.0
const GONE_AFTER_S := 3.5
const TURN_RATE := 10.0   # rad/s
const HOVER_M := 1.3

var plan := Plan.BLOB
var scale_f := 1.0
var top := 1.0            # metres above the floor: the look ray and the name label use it
var key := ""             # what it was built for (CreatureView rebuilds when this changes)
var z_level := 0
var dying := false
var done := false         # the death animation has finished: free it
var shamble := false      # zombies: arms forward, slower stride

var _body: Node3D         # everything; the death fall turns it
var _spine: Node3D        # humanoid torso pivot at the hips; other plans: the main body part
var _head: Node3D
var _limbs: Array[Node3D] = []    # legs (and arms for humanoids: the last two)
var _wings: Array[Node3D] = []
var _segments: Array[Node3D] = []
var _parts: Array[MeshInstance3D] = []
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _move_t := 1.0
var _move_s := 0.0
var _yaw_goal := 0.0
var _phase := 0.0
var _clock := 0.0
var _attack_t := -1.0
var _hurt_t := -1.0
var _die_t := -1.0

static var _mats := {}
static var _hurt_mat: StandardMaterial3D


static func plan_for(kind: int, def: IdTables.Def) -> int:
	if kind != Snapshot.Creature.MONSTER or def == null:
		return Plan.HUMANOID
	if BODYTYPES.has(def.bodytype):
		return BODYTYPES[def.bodytype]
	if def.bodytype != "":
		return Plan.BLOB   # a body type this client doesn't know (migo-likes, apeirohedra, ...)
	for sp: Array in SPECIES_PLANS:
		if def.species.has(sp[0]):
			return sp[1]
	return Plan.BLOB


static func scale_of(kind: int, def: IdTables.Def) -> float:
	if kind != Snapshot.Creature.MONSTER or def == null:
		return 1.0
	return SIZE_SCALE.get(def.size, 1.0)


## Height of the figure's top above the floor.
static func top_of(kind: int, def: IdTables.Def) -> float:
	var s := scale_of(kind, def)
	match plan_for(kind, def):
		Plan.HUMANOID:
			return HUMAN_H * s
		Plan.QUADRUPED:
			return 0.85 * s
		Plan.CRAWLER:
			return 0.45 * s
		Plan.SNAKE:
			return 0.2 * s
		Plan.FLYER:
			return HOVER_M + 0.25 * s
		Plan.FISH:
			return 0.2 + 0.3 * s
	return 0.75 * s


## A figure for a snapshot creature (kind, mtype definition or null).
static func make(kind: int, def: IdTables.Def, build_key := "") -> CreatureFigure:
	var f := CreatureFigure.new()
	f.key = build_key
	f.plan = plan_for(kind, def)
	f.scale_f = scale_of(kind, def)
	f.top = top_of(kind, def)
	f.shamble = def != null and def.species.has("ZOMBIE") and f.plan == Plan.HUMANOID
	var main := _tint(def)
	var second := main.darkened(0.35)
	if kind == Snapshot.Creature.NPC:
		main = SKIN
		second = NPC_CLOTHES
	elif kind == Snapshot.Creature.PLAYER:
		main = SKIN
		second = PLAYER_CLOTHES
	f._build(main, second)
	return f


## CDDA's colour for the monster, toned down (CDDA's are terminal colours: light green is #00ff00).
static func _tint(def: IdTables.Def) -> Color:
	var c := Color(0.55, 0.6, 0.5)
	if def != null:
		var fg_bg := CddaText.parse_color(def.color)
		if not fg_bg.is_empty():
			c = Color.html(fg_bg[0])
	return c.lerp(Color(0.42, 0.42, 0.4), 0.4)


## Starts a move to `target` (floor point) taking `seconds`; farther than `snap_m` (or 0 s) jumps there.
func move_to(target: Vector3, seconds: float, snap_m: float) -> void:
	if seconds <= 0.0 or position.distance_to(target) > snap_m:
		position = target
		_from = target
		_to = target
		_move_t = 1.0
		return
	if target.is_equal_approx(_to):
		return
	_from = position
	_to = target
	_move_t = 0.0
	_move_s = seconds
	var d := target - position
	if Vector2(d.x, d.z).length() > 0.05:
		_yaw_goal = atan2(-d.x, -d.z)


## Places it at once (no move), e.g. a new figure.
func place(target: Vector3) -> void:
	position = target
	_from = target
	_to = target
	_move_t = 1.0


func shift(d: Vector3) -> void:
	position += d
	_from += d
	_to += d


func face(point: Vector3) -> void:
	var d := point - position
	if Vector2(d.x, d.z).length() > 0.05:
		_yaw_goal = atan2(-d.x, -d.z)


func attack(toward = null) -> void:
	if toward is Vector3:
		face(toward)
	_attack_t = 0.0


func hurt() -> void:
	_hurt_t = 0.0
	_set_overlay(_hurt_material())


## A body on the ground (a corpse in an item pile): lying as after the death fall, darker, no animation.
func lie_dead() -> void:
	_body.rotation.x = PI / 2.0
	dying = false
	_die_t = -1.0
	for m in _parts:
		var mat := m.material_override as StandardMaterial3D
		if mat != null:
			mat = mat.duplicate() as StandardMaterial3D
			mat.albedo_color = mat.albedo_color.darkened(0.35)
			m.material_override = mat


const RAW := Color(0.62, 0.2, 0.2)          # skinned flesh
const GUTS := [Color(0.45, 0.08, 0.1), Color(0.55, 0.25, 0.35), Color(0.35, 0.05, 0.08)]
const BLOOD_POOL := Color(0.28, 0.02, 0.03, 0.85)

var corpse_state := 0       # Snapshot.CORPSE_* bits shown (lie_dead figures)


## A body's butchery state (Snapshot.CORPSE_* bits) on a lie_dead figure: a blood pool unless bled,
## raw flesh when skinned, opened with viscera beside it when field dressed (more, darker when it failed),
## limbs and head pulled apart when quartered, flattened when pulped, only scattered chunks when gibbed.
## Built once per state; deterministic (no random), so rebuilding gives the same look.
func show_corpse_state(bits: int) -> void:
	corpse_state = bits
	var s := scale_f
	var gore := Node3D.new()
	gore.name = "gore"
	add_child(gore)
	if bits & Snapshot.CORPSE_GIBBED:
		_body.visible = false
		for i in 7:
			var a := i * 2.4
			var r := (0.15 + 0.1 * (i % 3)) * s
			_gore_part(gore, _sphere((0.05 + 0.02 * (i % 2)) * s), Vector3(cos(a) * r * 2.0, 0.04 * s, sin(a) * r * 2.0),
					GUTS[i % GUTS.size()] if i % 3 else _tint_of_parts())
		_pool(gore, 0.7 * s)
		return
	if not (bits & Snapshot.CORPSE_BLED):
		_pool(gore, 0.55 * s)
	if bits & Snapshot.CORPSE_SKINNED:
		_recolour(RAW)
	if bits & (Snapshot.CORPSE_FIELD_DRESSED | Snapshot.CORPSE_DRESS_FAILED):
		var failed := (bits & Snapshot.CORPSE_DRESS_FAILED) != 0
		for i in (6 if failed else 4):
			var at := Vector3((0.28 + 0.07 * (i % 3)) * s, 0.05 * s, 0.35 * top + 0.09 * i * s)
			var g := _gore_part(gore, _sphere((0.06 + 0.015 * (i % 2)) * s), at, GUTS[i % GUTS.size()].darkened(0.3 if failed else 0.0))
			g.scale = Vector3(1.4, 0.6, 1.0)
		_gore_part(gore, _box(Vector3(0.12, 0.02, 0.3) * s), Vector3(0, 0.16 * s, 0.6 * top), GUTS[0])   # opened belly
	if bits & Snapshot.CORPSE_QUARTERED:
		for i in _limbs.size():
			var l := _limbs[i]
			# body-local x is sideways on the ground (the lying body is turned about x)
			var out := Vector3(signf(l.position.x) if absf(l.position.x) > 0.001 else (1.0 if i % 2 else -1.0), 0, 0)
			l.position += out * 0.3 * s
		if _head != null and _head != _spine:
			_head.position += _head.position.normalized() * 0.25 * s
	if bits & Snapshot.CORPSE_PULPED:
		_body.scale = Vector3(1.15, 1.15, 0.35)   # the body lies on its back: local z is up
		_recolour(RAW.darkened(0.3))


func _tint_of_parts() -> Color:
	var m := _parts[0].material_override as StandardMaterial3D if not _parts.is_empty() else null
	return m.albedo_color if m != null else RAW


func _recolour(c: Color) -> void:
	for m in _parts:
		var mat := m.material_override as StandardMaterial3D
		if mat != null:
			mat = mat.duplicate() as StandardMaterial3D
			mat.albedo_color = c.lerp(mat.albedo_color, 0.25)
			m.material_override = mat


func _gore_part(parent: Node3D, mesh: Mesh, at: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = _material(c)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _pool(parent: Node3D, r: float) -> void:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = 0.01
	c.radial_segments = 20
	var mi := _gore_part(parent, c, Vector3(0, 0.012, 0), BLOOD_POOL)
	(mi.material_override as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.scale = Vector3(1.0, 1.0, 0.7)


func die() -> void:
	dying = true
	_die_t = 0.0
	_move_t = 1.0


func is_attacking() -> bool:
	return _attack_t >= 0.0


func is_hurt() -> bool:
	return _hurt_t >= 0.0


func is_moving() -> bool:
	return _move_t < 1.0


## One frame of movement and animation.
func animate(delta: float) -> void:
	delta = minf(delta, 0.1)
	_clock += delta
	var walking := 0.0
	if _move_t < 1.0:
		_move_t = minf(1.0, _move_t + delta / maxf(_move_s, 0.01))
		position = _from.lerp(_to, smoothstep(0.0, 1.0, _move_t))
		walking = 1.0
	rotation.y = rotate_toward(rotation.y, _yaw_goal, TURN_RATE * delta)
	var stride := (5.0 if shamble else 8.0) / maxf(scale_f, 0.35)
	_phase += delta * stride * walking
	var atk := 0.0
	if _attack_t >= 0.0:
		_attack_t += delta
		atk = sin(PI * clampf(_attack_t / ATTACK_S, 0.0, 1.0))
		if _attack_t >= ATTACK_S:
			_attack_t = -1.0
	var hit := 0.0
	if _hurt_t >= 0.0:
		_hurt_t += delta
		hit = sin(PI * clampf(_hurt_t / HURT_S, 0.0, 1.0))
		if _hurt_t >= HURT_S:
			_hurt_t = -1.0
			_set_overlay(null)
	_pose(walking, atk, hit)
	if _die_t >= 0.0:
		_die_t += delta
		_body.rotation.x = lerpf(0.0, PI / 2.0, smoothstep(0.0, 1.0, _die_t / DIE_S))
		if _die_t > SINK_AFTER_S:
			_body.position.y = -top * clampf((_die_t - SINK_AFTER_S) / (GONE_AFTER_S - SINK_AFTER_S), 0.0, 1.0)
		done = _die_t >= GONE_AFTER_S


func _pose(walk: float, atk: float, hit: float) -> void:
	var sw := sin(_phase) * walk
	var idle := sin(_clock * 1.7)
	match plan:
		Plan.HUMANOID:
			var lean := (-0.25 if shamble else 0.0) - 0.45 * atk + 0.3 * hit
			_spine.rotation.x = lean + 0.02 * idle
			_limbs[0].rotation.x = 0.55 * sw
			_limbs[1].rotation.x = -0.55 * sw
			var arm_rest := 1.4 if shamble else 0.0
			var arm_swing := (0.1 if shamble else 0.5) * sw
			_limbs[2].rotation.x = arm_rest - arm_swing + 0.05 * idle
			_limbs[3].rotation.x = arm_rest + arm_swing + 1.6 * atk + 0.05 * idle
		Plan.QUADRUPED:
			for i in 4:
				_limbs[i].rotation.x = 0.5 * sw * (1.0 if i == 0 or i == 3 else -1.0)
			_spine.rotation.x = -0.15 * atk + 0.15 * hit
			_head.position.z = _head.get_meta("z0") - 0.25 * scale_f * atk
			_head.rotation.x = 0.04 * idle
		Plan.CRAWLER:
			for i in _limbs.size():
				_limbs[i].rotation.y = _limbs[i].get_meta("y0") + 0.35 * sin(_phase + i * PI) * walk
			_spine.position.y = _spine.get_meta("y0") + 0.01 * idle * scale_f
			_head.position.z = _head.get_meta("z0") - 0.15 * scale_f * atk
		Plan.SNAKE:
			for i in _segments.size():
				var wave := sin(_phase * 0.8 - i * 0.9) * (0.6 * walk + 0.15)
				_segments[i].position.x = wave * 0.08 * scale_f
			_segments[0].position.z = _segments[0].get_meta("z0") - 0.3 * scale_f * atk
			_segments[0].position.y = _segments[0].get_meta("y0") + 0.12 * scale_f * atk
		Plan.FLYER:
			var flap := sin(_clock * 14.0)
			_wings[0].rotation.z = 0.7 * flap
			_wings[1].rotation.z = -0.7 * flap
			_spine.position.y = HOVER_M + 0.08 * idle - 0.3 * atk
			_spine.position.z = -0.25 * scale_f * atk
		Plan.FISH:
			_segments[0].rotation.y = 0.4 * sin(_clock * 6.0 + _phase)
			_spine.position.z = -0.2 * scale_f * atk
		Plan.BLOB:
			var squash := 0.06 * idle + 0.15 * sw + 0.2 * atk - 0.15 * hit
			_spine.scale = Vector3(1.0 - squash * 0.5, 1.0 + squash, 1.0 - squash * 0.5)
			_spine.position.z = -0.2 * scale_f * atk


func _build(main: Color, second: Color) -> void:
	_body = Node3D.new()
	_body.name = "body"
	add_child(_body)
	var s := scale_f
	match plan:
		Plan.HUMANOID:
			var h := HUMAN_H * s
			for x: float in [-0.065, 0.065]:
				_limbs.append(_limb(_body, Vector3(x * h, 0.5 * h, 0), 0.5 * h, 0.06 * h, second))
			_spine = _pivot(_body, Vector3(0, 0.5 * h, 0))
			_part(_spine, _capsule(0.12 * h, 0.36 * h), Vector3(0, 0.17 * h, 0), Vector3.ZERO, second)
			_head = _pivot(_spine, Vector3(0, 0.4 * h, 0))
			_part(_head, _sphere(0.08 * h), Vector3.ZERO, Vector3.ZERO, main)
			_eyes(_head, 0.08 * h, 0.03 * h)
			for x: float in [-0.165, 0.165]:
				_limbs.append(_limb(_spine, Vector3(x * h, 0.3 * h, 0), 0.38 * h, 0.045 * h, main))
		Plan.QUADRUPED:
			var hs := 0.5 * s
			var l := 0.9 * s
			for p: Vector2 in [Vector2(-0.12, -0.32), Vector2(0.12, -0.32), Vector2(-0.12, 0.32), Vector2(0.12, 0.32)]:
				_limbs.append(_limb(_body, Vector3(p.x * s, hs, p.y * s), hs, 0.055 * s, second))
			_spine = _pivot(_body, Vector3(0, hs + 0.06 * s, 0))
			_part(_spine, _capsule(0.16 * s, l), Vector3.ZERO, Vector3(PI / 2.0, 0, 0), main)
			_part(_spine, _capsule(0.035 * s, 0.35 * s), Vector3(0, 0.1 * s, l / 2.0 + 0.05 * s), Vector3(-0.9, 0, 0), second)
			_head = _pivot(_spine, Vector3(0, 0.14 * s, -l / 2.0 - 0.06 * s))
			_head.set_meta("z0", _head.position.z)
			_part(_head, _sphere(0.13 * s), Vector3.ZERO, Vector3.ZERO, main)
			_part(_head, _box(Vector3(0.12, 0.1, 0.16) * s), Vector3(0, -0.03 * s, -0.14 * s), Vector3.ZERO, second)
			_eyes(_head, 0.13 * s, 0.05 * s)
		Plan.CRAWLER:
			var y := 0.22 * s
			_spine = _pivot(_body, Vector3(0, y, 0))
			_spine.set_meta("y0", y)
			var abdomen := _part(_spine, _sphere(1.0), Vector3(0, 0, 0.12 * s), Vector3.ZERO, main)
			abdomen.scale = Vector3(0.22, 0.15, 0.32) * s
			_head = _pivot(_spine, Vector3(0, 0.02 * s, -0.28 * s))
			_head.set_meta("z0", _head.position.z)
			_part(_head, _sphere(0.12 * s), Vector3.ZERO, Vector3.ZERO, second)
			_eyes(_head, 0.12 * s, 0.05 * s)
			for i in 6:
				var side := -1.0 if i % 2 == 0 else 1.0
				var z := (-0.12 + 0.12 * floorf(i / 2.0)) * s
				var leg := _pivot(_spine, Vector3(side * 0.12 * s, 0, z))
				leg.rotation.y = 0.0 if side > 0 else PI
				leg.set_meta("y0", leg.rotation.y)
				_part(leg, _capsule(0.025 * s, 0.42 * s), Vector3(0.18 * s, -0.1 * s, 0), Vector3(0, 0, 1.0), second)
				_limbs.append(leg)
		Plan.SNAKE:
			var r := maxf(0.06 * s, 0.035)
			for i in 7:
				var seg := _pivot(_body, Vector3(0, r, (i - 2) * r * 1.5))
				seg.set_meta("z0", seg.position.z)
				seg.set_meta("y0", seg.position.y)
				_part(seg, _sphere(r * (1.25 if i == 0 else 1.0 - i * 0.07)), Vector3.ZERO, Vector3.ZERO, main if i % 2 == 0 else second)
				_segments.append(seg)
			_head = _segments[0]
			_eyes(_head, r * 1.25, r * 0.5)
			_spine = _segments[0]
		Plan.FLYER:
			_spine = _pivot(_body, Vector3(0, HOVER_M, 0))
			var torso := _part(_spine, _sphere(1.0), Vector3.ZERO, Vector3.ZERO, main)
			torso.scale = Vector3(0.1, 0.1, 0.2) * s
			_head = _pivot(_spine, Vector3(0, 0.05 * s, -0.2 * s))
			_part(_head, _sphere(0.07 * s), Vector3.ZERO, Vector3.ZERO, main)
			_eyes(_head, 0.07 * s, 0.03 * s)
			for side: float in [-1.0, 1.0]:
				var w := _pivot(_spine, Vector3(side * 0.08 * s, 0.03 * s, 0))
				_part(w, _box(Vector3(0.35, 0.015, 0.16) * s), Vector3(side * 0.18 * s, 0, 0), Vector3.ZERO, second)
				_wings.append(w)
		Plan.FISH:
			_spine = _pivot(_body, Vector3(0, 0.2 + 0.15 * s, 0))
			var fish := _part(_spine, _sphere(1.0), Vector3.ZERO, Vector3.ZERO, main)
			fish.scale = Vector3(0.1, 0.15, 0.4) * s
			_head = _spine
			_eyes(_spine, 0.1 * s, 0.05 * s, -0.3 * s)
			var tail := _pivot(_spine, Vector3(0, 0, 0.38 * s))
			_part(tail, _box(Vector3(0.02, 0.22, 0.16) * s), Vector3(0, 0, 0.08 * s), Vector3.ZERO, second)
			_segments.append(tail)
		_:
			_spine = _pivot(_body, Vector3(0, 0.0, 0))
			var blob := _part(_spine, _sphere(1.0), Vector3(0, 0.35 * s, 0), Vector3.ZERO, main)
			blob.scale = Vector3(0.45, 0.36, 0.45) * s
			_head = _pivot(_spine, Vector3(0, 0.45 * s, -0.36 * s))
			_eyes(_head, 0.0, 0.08 * s)


func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n


## A limb hanging down from a joint at `at` (it swings around the joint).
func _limb(parent: Node3D, at: Vector3, length: float, radius: float, col: Color) -> Node3D:
	var j := _pivot(parent, at)
	_part(j, _capsule(radius, length), Vector3(0, -length / 2.0, 0), Vector3.ZERO, col)
	return j


func _part(parent: Node3D, mesh: Mesh, at: Vector3, rot: Vector3, col: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.position = at
	m.rotation = rot
	m.material_override = _material(col)
	parent.add_child(m)
	_parts.append(m)
	return m


## Two dark eyes on the front (-Z) of a head of radius r, `gap` apart.
func _eyes(head: Node3D, r: float, gap: float, z := 0.0) -> void:
	var er := maxf(gap * 0.4, 0.008)
	for x: float in [-gap / 2.0, gap / 2.0]:
		_part(head, _sphere(er), Vector3(x, r * 0.25, z - r * 0.9), Vector3.ZERO, Color(0.08, 0.06, 0.05))


func _set_overlay(mat: Material) -> void:
	for p in _parts:
		p.material_overlay = mat


static func _capsule(radius: float, height: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0)
	m.radial_segments = 10
	m.rings = 4
	return m


static func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 12
	m.rings = 6
	return m


static func _box(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


static func _material(c: Color) -> StandardMaterial3D:
	var k := c.to_html(false)
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.roughness = 0.85
		_mats[k] = m
	return _mats[k]


static func _hurt_material() -> StandardMaterial3D:
	if _hurt_mat == null:
		_hurt_mat = StandardMaterial3D.new()
		_hurt_mat.albedo_color = Color(1.0, 0.1, 0.05, 0.55)
		_hurt_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hurt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _hurt_mat
