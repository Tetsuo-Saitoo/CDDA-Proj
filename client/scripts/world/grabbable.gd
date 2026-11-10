class_name Grabbable
extends Node3D
## Blocks E6 / L2: a part you open by dragging it, with the mouse (Amnesia-style: hold the left button on it
## and move the mouse the way it should go; how far = how far you drag) or a VR hand (grip it, move the hand).
## Doors for now: a leaf on a hinge whose angle is the client's own. Past OPEN_AT the sim is asked to open the
## door, back under CLOSE_AT to close it (WorldView.door_wants; main.gd queues CDDA's open / close with the
## door's direction, which costs CDDA's time). CDDA's door stays open or closed; when it disagrees with the
## leaf (refused, e.g. locked, or opened by someone else) the leaf swings to CDDA's state. With no sim (mock,
## WorldView.door_local) crossing a threshold opens or closes the door right here.
## Drawers and lids (models' handle_N parts) will be other kinds: `tangent()` and `_apply()` are the only
## places that know this one turns on a hinge.

const OPEN_AT := deg_to_rad(30.0)
const CLOSE_AT := deg_to_rad(8.0)
const MAX_ANGLE := deg_to_rad(100.0)
const OPEN_REST := PI / 2          # where a door the sim opened by itself swings to
const LOCKED_PLAY := deg_to_rad(3.0)   # a door known to be locked only rattles
const SWING_SPEED := 3.0           # rad/s when it moves on its own
const WAIT_MS := 2500              # how long a leaf waits for the sim's answer before giving up
const M_PER_PX := 0.0025           # mouse drag: metres the grabbed point moves per pixel
const LEAF_W := 0.96
const LEAF_T := 0.08
const OUTLINE := Color(1.0, 0.85, 0.3)

var kind := "door"
var world: WorldView
var square: Vector3i
var cdda_open := false
var locked := false
var base_yaw := 0.0      # leaf direction when closed (0: along +X from the hinge, -PI/2: along +Z)
var angle := 0.0
var grabbed := false
var leaf: MeshInstance3D
var _grab_local := Vector3.ZERO   # mouse: grabbed point in leaf space
var _hand_offset := 0.0           # hand: leaf yaw minus hand yaw at the grab
var _asked := false               # asked the sim during this grab, waiting for its answer
var _swing := NAN                 # where a leaf moving on its own is heading (fixed when it starts)
var _lit := false

static var _meshes := {}   # colour + glass -> BoxMesh
static var _outline: StandardMaterial3D


## A door from TerrainMesher.Result.doors (local = its square's corner inside the submap node).
static func door(w: WorldView, d: Dictionary) -> Grabbable:
	var g := Grabbable.new()
	g.world = w
	g.square = d["square"]
	g.name = "door_%d_%d_%d" % [g.square.x, g.square.y, g.square.z]
	var o: Vector3 = d["local"]
	if d["along_x"]:
		g.position = o + Vector3(0.02, 0, 0.5)
		g.base_yaw = 0.0
	else:
		g.position = o + Vector3(0.5, 0, 0.02)
		g.base_yaw = -PI / 2
	g.leaf = MeshInstance3D.new()
	g.leaf.name = "Leaf"
	g.leaf.position = Vector3(LEAF_W / 2, TerrainMesher.DOOR_H / 2, 0)
	g.add_child(g.leaf)
	var knob := MeshInstance3D.new()   # where a hand goes; models will mark it as handle_1
	var ball := SphereMesh.new()
	ball.radius = 0.035
	ball.height = 0.07
	ball.radial_segments = 8
	ball.rings = 4
	knob.mesh = ball
	knob.position = Vector3(LEAF_W / 2 - 0.09, 1.0 - TerrainMesher.DOOR_H / 2, 0)
	knob.scale = Vector3(1, 1, 2.6)   # through the leaf: a knob each side
	g.leaf.add_child(knob)
	g.sync(d)
	var st: Dictionary = w.door_state.get(g.square, {})
	var a: float = st.get("angle", NAN)
	if is_nan(a) or (absf(a) >= OPEN_AT) != g.cdda_open:   # a kept angle counts only while it agrees
		a = OPEN_REST if g.cdda_open else 0.0
	g.angle = a
	g._apply()
	g.set_process(false)
	return g


## The newest snapshot's door here (CDDA's state; in mock mode the client's own state wins).
func sync(d: Dictionary) -> void:
	var open: bool = d["open"]
	if world.door_local:
		open = world.door_open.get(square, open)
	locked = d.get("locked", false)
	var key := "%s%s" % [d["color"], d["glass"]]
	if not _meshes.has(key):
		var m := BoxMesh.new()
		m.size = Vector3(LEAF_W, TerrainMesher.DOOR_H, LEAF_T)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = d["color"]
		if d["glass"]:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.render_priority = WorldLighting.UNDER_PRIORITY   # darkened by the light pass
		m.material = mat
		_meshes[key] = m
	leaf.mesh = _meshes[key]
	(leaf.get_child(0) as MeshInstance3D).material_override = _knob_mat()
	if open != cdda_open:
		cdda_open = open
		_asked = false
		_swing = NAN
		_state()["until"] = 0
		set_process(true)   # swing to the new state


## 0 = closed .. 1 = square to the wall.
func open_amount() -> float:
	return absf(angle) / OPEN_REST


## Where the leaf settles when let go: closed, or open where it was left (at least OPEN_AT).
func rest_angle() -> float:
	if not cdda_open:
		return 0.0
	if absf(angle) >= OPEN_AT:
		return angle
	return OPEN_REST * (signf(angle) if angle != 0.0 else 1.0)


func set_angle(a: float) -> void:
	var lim := LOCKED_PLAY if locked and not cdda_open else MAX_ANGLE
	angle = clampf(a, -lim, lim)
	_apply()
	_state()["angle"] = angle
	if grabbed:
		_threshold(a)


## Past a threshold during a grab: ask the sim once (a locked door asks too, so CDDA can say it's locked).
func _threshold(wanted: float) -> void:
	if _asked:
		return
	var want_open := not cdda_open and absf(wanted) > OPEN_AT
	var want_close := cdda_open and absf(wanted) < CLOSE_AT
	if not want_open and not want_close:
		return
	_asked = true
	if world.door_local:
		if want_open and locked:
			world.door_message.emit("The door is locked.")
			return
		world.door_open[square] = want_open
		cdda_open = want_open
		_asked = false
		return
	_state()["until"] = Time.get_ticks_msec() + WAIT_MS
	world.door_wants.emit(square, want_open)


## The hinge-local point on the leaf the mouse grabbed (world `point`).
func begin_grab(point: Vector3) -> void:
	grabbed = true
	_asked = false
	_swing = NAN
	_grab_local = leaf.global_transform.affine_inverse() * point
	set_process(false)


func begin_hand(hand: Vector3) -> void:
	begin_grab(hand)
	_hand_offset = base_yaw + angle - _yaw_of(hand)


func end_grab() -> void:
	grabbed = false
	_swing = NAN
	set_process(true)


## Direction the grabbed point moves as the angle grows (world, horizontal).
func tangent() -> Vector3:
	var r := leaf.global_transform * _grab_local - global_position
	r.y = 0.0
	return Vector3.UP.cross(r)


## Mouse motion `rel` (pixels) with the view's basis: sideways and forward / back move the grabbed point.
func drag_mouse(rel: Vector2, view: Basis) -> void:
	if not grabbed:
		return
	var fwd := -view.z
	fwd.y = 0.0
	var rgt := view.x
	rgt.y = 0.0
	var w := (rgt.normalized() * rel.x - fwd.normalized() * rel.y) * M_PER_PX
	var t := tangent()
	var r := maxf(t.length(), 0.2)
	set_angle(angle + w.dot(t / t.length() if t.length() > 0.001 else Vector3.ZERO) / r)


## A VR hand at `hand` (world): the leaf turns with it around the hinge.
func drag_hand(hand: Vector3) -> void:
	if grabbed:
		set_angle(wrapf(_yaw_of(hand) + _hand_offset - base_yaw, -PI, PI))


func _yaw_of(p: Vector3) -> float:
	var v := p - global_position
	return atan2(-v.z, v.x)


## Distance along a ray (normalized `dir`) to the leaf, INF when it misses.
func ray_distance(origin: Vector3, dir: Vector3) -> float:
	var inv := leaf.global_transform.affine_inverse()
	var o := inv * origin
	var d := inv.basis * dir
	var half := Vector3(LEAF_W, TerrainMesher.DOOR_H, LEAF_T) / 2
	var t0 := -INF
	var t1 := INF
	for a in 3:
		if absf(d[a]) < 1e-8:
			if absf(o[a]) > half[a]:
				return INF
			continue
		var ta := (-half[a] - o[a]) / d[a]
		var tb := (half[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t0 > t1 or t1 < 0.0:
		return INF
	return maxf(t0, 0.0)


## Distance from `p` (world) to the leaf's surface (0 inside).
func distance_to(p: Vector3) -> float:
	var l := leaf.global_transform.affine_inverse() * p
	var half := Vector3(LEAF_W, TerrainMesher.DOOR_H, LEAF_T) / 2
	return (l - l.clamp(-half, half)).length()


## The grab highlight: an outline round the leaf.
func set_highlight(on: bool) -> void:
	if on == _lit:
		return
	_lit = on
	if _outline == null:
		_outline = StandardMaterial3D.new()
		_outline.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_outline.cull_mode = BaseMaterial3D.CULL_FRONT
		_outline.grow = true
		_outline.grow_amount = 0.025
		_outline.albedo_color = OUTLINE
	leaf.material_overlay = _outline if on else null


func highlighted() -> bool:
	return _lit


func _process(delta: float) -> void:
	if grabbed or Time.get_ticks_msec() < int(_state().get("until", 0)):
		return
	if is_nan(_swing):
		_swing = rest_angle()
	angle = move_toward(angle, _swing, SWING_SPEED * delta)
	_apply()
	_state()["angle"] = angle
	if angle == _swing:
		_swing = NAN
		set_process(false)


func _apply() -> void:
	rotation = Vector3(0, base_yaw + angle, 0)


func _state() -> Dictionary:
	if not world.door_state.has(square):
		world.door_state[square] = {}
	return world.door_state[square]


static func _knob_mat() -> StandardMaterial3D:
	if not _meshes.has("knob"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.75, 0.7, 0.55)
		m.metallic = 0.6
		m.roughness = 0.4
		_meshes["knob"] = m
	return _meshes["knob"]
