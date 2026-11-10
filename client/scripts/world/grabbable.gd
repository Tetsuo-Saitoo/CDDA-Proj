class_name Grabbable
extends Node3D
## Blocks E6 / L2 / L8: a part you open by dragging it, with the mouse (Amnesia-style: hold the left button on
## it and move the mouse the way it should go; how far = how far you drag) or a VR hand (grip it, move the hand).
## Terrain doors (`door()`): a leaf on a hinge whose angle is the client's own. Past OPEN_AT the sim is asked to
## open the door, back under CLOSE_AT to close it (WorldView.door_wants; main.gd queues CDDA's open / close with
## the door's direction, which costs CDDA's time). CDDA's door stays open or closed; when it disagrees with the
## leaf (refused, e.g. locked, or opened by someone else) the leaf swings to CDDA's state. With no sim (mock,
## WorldView.door_local) crossing a threshold opens or closes the door right here.
## Furniture parts (`part()`, block L8): cabinet / fridge / wardrobe doors and lids turn on a hinge, drawers
## slide. `amount` (0..max_amount, radians or metres) is their state, kept in WorldView.door_state[id]. Only
## parts with a CDDA open / closed pair (open_id / close_id) ask the sim, past OPEN_FRAC / under CLOSE_FRAC of
## max_amount; the others are the client's alone. Their "Leaf" child moves and carries what `contents()` holds.
## `mech` tells the two apart: "" for terrain doors, "hinge" or "slide" for parts.

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

# Furniture parts.
const OPEN_FRAC := 0.3             # past this share of max_amount a closed part asks to open
const CLOSE_FRAC := 0.08           # under it an open part asks to close (a part without a pair closes)
const MAX_HINGE := 2.2             # radians
const MAX_SLIDE := 1.0             # metres
const SLIDE_SPEED := 0.8           # m/s when a drawer moves on its own
const LOCKED_SLIDE := 0.005        # a locked drawer's play (metres)
const MIN_RADIUS := 0.15           # mouse drag on a hinge: grabbed points nearer the hinge count as this far
const MAX_SURFACES := 8
const MAX_EXTENT := 4.0            # size, handle and surfaces stay within this many metres of the pivot
const MAX_ID := 128                # characters in id / open_id / close_id
const MAX_NODES := 256             # nodes in a part's model
const MAX_STATES := 16384          # part entries in WorldView.door_state (more are not remembered)

var kind := "door"
var mech := ""           # "" terrain door, "hinge" or "slide" furniture part
var world: WorldView
var square: Vector3i
var cdda_open := false
var locked := false
var base_yaw := 0.0      # leaf direction when closed (0: along +X from the hinge, -PI/2: along +Z)
var angle := 0.0
var grabbed := false
var leaf: MeshInstance3D
# Parts only (pivot space = the Grabbable's own space; Leaf space is the same at rest).
var id := ""
var axis := Vector3.UP   # hinge axis (right-hand rule: positive amount opens) or slide direction, normalised
var amount := 0.0
var max_amount := 0.0
var size := AABB()       # the part's box in Leaf space
var handle := Transform3D()   # Leaf space
var open_id := ""
var close_id := ""
var surfaces: Array = []      # [Transform3D, Rect2] in Leaf space: shelves and drawer bottoms, moving with it
var _geo: Array[GeometryInstance3D] = []   # the part's own meshes (outlined), not what is put in it later
var _own := {}                # state when WorldView.door_state is full
var _grab_local := Vector3.ZERO   # mouse: grabbed point in leaf space
var _hand_offset := 0.0           # hand: leaf yaw minus hand yaw at the grab (parts: amount minus hand's)
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
	var av: Variant = st.get("angle")
	var a: float = av if typeof(av) == TYPE_FLOAT else NAN
	if not is_finite(a) or (absf(a) >= OPEN_AT) != g.cdda_open:   # a kept angle counts only while it agrees
		a = OPEN_REST if g.cdda_open else 0.0
	a = clampf(a, -MAX_ANGLE, MAX_ANGLE)
	g.angle = a
	if st.has("angle"):
		st["angle"] = a
	g._apply()
	g.set_process(false)
	return g


## A furniture part (door, drawer, lid) from a spec (hostile: checked, null with a warning when bad):
## id: String, square: Vector3i, kind: "door" | "drawer" | "lid", mesh: Mesh or Node3D (the part at rest in
## pivot space; a Node3D must have no parent and is adopted only when the spec is good), pivot: Transform3D
## (the node in its parent's space: on the hinge line or the slide's origin), axis: Vector3 (pivot space),
## max: float (radians, metres for drawers). Optional: handle: Transform3D, size: AABB, open_id / close_id:
## String, cdda_open / locked: bool, surfaces: Array of [Transform3D, Rect2] (at most MAX_SURFACES).
## The caller adds the node to the tree.
static func part(w: WorldView, spec: Dictionary) -> Grabbable:
	if w == null:
		return _reject("no world", "")
	var pid: Variant = spec.get("id")
	if typeof(pid) != TYPE_STRING or (pid as String).is_empty() or (pid as String).length() > MAX_ID:
		return _reject("id must be a String of 1..%d characters" % MAX_ID, "")
	var tag: String = pid
	var sq: Variant = spec.get("square")
	if typeof(sq) != TYPE_VECTOR3I:
		return _reject("square must be a Vector3i", tag)
	var k: Variant = spec.get("kind")
	if typeof(k) != TYPE_STRING or k not in ["door", "drawer", "lid"]:
		return _reject("kind must be door, drawer or lid", tag)
	var piv: Variant = spec.get("pivot")
	if typeof(piv) != TYPE_TRANSFORM3D or not (piv as Transform3D).is_finite() \
			or absf((piv as Transform3D).basis.determinant()) < 1e-6:
		return _reject("pivot must be a finite, invertible Transform3D", tag)
	var ax: Variant = spec.get("axis")
	if typeof(ax) != TYPE_VECTOR3 or not (ax as Vector3).is_finite() or (ax as Vector3).length() < 1e-4:
		return _reject("axis must be a finite, non-zero Vector3", tag)
	var mx: Variant = spec.get("max")
	if typeof(mx) != TYPE_FLOAT and typeof(mx) != TYPE_INT:
		return _reject("max must be a number", tag)
	var mxf := float(mx)
	if not is_finite(mxf) or mxf < 1e-3:
		return _reject("max must be finite and above 0", tag)
	var slide: bool = k == "drawer"
	mxf = minf(mxf, MAX_SLIDE if slide else MAX_HINGE)
	var opt := {}
	for p: Array in [["handle", TYPE_TRANSFORM3D], ["size", TYPE_AABB], ["open_id", TYPE_STRING],
			["close_id", TYPE_STRING], ["cdda_open", TYPE_BOOL], ["locked", TYPE_BOOL], ["surfaces", TYPE_ARRAY]]:
		if spec.has(p[0]):
			if typeof(spec[p[0]]) != p[1]:
				return _reject("%s has the wrong type" % p[0], tag)
			opt[p[0]] = spec[p[0]]
	for p: String in ["open_id", "close_id"]:
		if (opt.get(p, "") as String).length() > MAX_ID:
			return _reject("%s is too long" % p, tag)
	var m: Variant = spec.get("mesh")
	if typeof(m) != TYPE_OBJECT or not is_instance_valid(m) or not (m is Mesh or m is Node3D):
		return _reject("mesh must be a Mesh or a Node3D", tag)
	var geo: Array[GeometryInstance3D] = []
	var box := AABB()
	if m is Node3D:
		var n := m as Node3D
		if n.get_parent() != null or n.is_inside_tree():
			return _reject("mesh node already has a parent", tag)
		var walk := _walk(n, geo)
		if walk.is_empty():
			return _reject("mesh node has more than %d nodes" % MAX_NODES, tag)
		box = walk[0]
	else:
		box = (m as Mesh).get_aabb()
	if opt.has("size"):
		box = (opt["size"] as AABB).abs()
	if not box.is_finite() or box.size.length() < 0.01 or not _within(box.position) or not _within(box.end):
		return _reject("size must be finite, not empty and within %.0f m of the pivot" % MAX_EXTENT, tag)
	var sf: Array = opt.get("surfaces", [])
	if sf.size() > MAX_SURFACES:
		return _reject("more than %d surfaces" % MAX_SURFACES, tag)
	var a: Vector3 = (ax as Vector3).normalized()
	var hd: Transform3D = opt.get("handle", _default_handle(box, a, slide))
	if not hd.is_finite() or not _within(hd.origin):
		return _reject("handle must be finite and within %.0f m of the pivot" % MAX_EXTENT, tag)
	# Good: build it.
	var g := Grabbable.new()
	g.world = w
	g.id = tag
	g.square = sq
	g.kind = k
	g.mech = "slide" if slide else "hinge"
	g.name = ("part_%s" % tag).validate_node_name()
	g.transform = piv
	g.axis = a
	g.max_amount = mxf
	g.size = box
	g.handle = hd
	g.open_id = opt.get("open_id", "")
	g.close_id = opt.get("close_id", "")
	g.cdda_open = opt.get("cdda_open", false)
	g.locked = opt.get("locked", false)
	for s: Variant in sf:
		if _good_surface(s):
			g.surfaces.append([s[0], s[1]])
		else:
			push_warning("Grabbable.part %s: skipped a bad surface (want [Transform3D, Rect2] near the pivot)"
					% tag.c_escape())
	g.leaf = MeshInstance3D.new()
	g.leaf.name = "Leaf"
	g.add_child(g.leaf)
	if m is Mesh:
		g.leaf.mesh = m
		g._geo.append(g.leaf)
	else:
		g.leaf.add_child(m as Node3D)
		g._geo = geo
	var sv: Variant = w.door_state.get(tag)
	var st: Dictionary = sv if sv is Dictionary else {}
	if w.door_local and typeof(st.get("open")) == TYPE_BOOL:
		g.cdda_open = st["open"]
	var start := g.max_amount if g.cdda_open else 0.0
	var am: Variant = st.get("amount", start)
	g.amount = clampf(am, 0.0, g._limit()) if typeof(am) == TYPE_FLOAT and is_finite(am) else start
	g._apply_part()
	g.set_process(not is_equal_approx(g.amount, g.rest_amount()))
	return g


static func _reject(why: String, tag: String) -> Grabbable:
	push_warning("Grabbable.part %s: bad spec, %s" % [tag.left(64).c_escape(), why])
	return null


static func _within(p: Vector3) -> bool:
	return p.is_finite() and p.length() <= MAX_EXTENT


## [AABB of the model's meshes in Leaf space] and its GeometryInstance3D nodes into `geo`; [] when too big.
static func _walk(root: Node3D, geo: Array[GeometryInstance3D]) -> Array:
	var box := AABB()
	var first := true
	var stack: Array = [[root, root.transform]]
	var seen := 0
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var n: Node3D = e[0]
		var xf: Transform3D = e[1]
		seen += 1
		if seen > MAX_NODES:
			geo.clear()
			return []
		if n is GeometryInstance3D:
			geo.append(n)
		if n is VisualInstance3D:
			var b := xf * (n as VisualInstance3D).get_aabb()
			box = b if first else box.merge(b)
			first = false
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * (c as Node3D).transform])
	return [box]


## The middle of the box face farthest from the hinge line (through the origin along `a`), or for a drawer
## the face it slides out through.
static func _default_handle(box: AABB, a: Vector3, slide: bool) -> Transform3D:
	var c := box.get_center()
	var half := box.size / 2
	var best := c
	var best_v := -INF
	for i in 3:
		for s: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[i] = s
			var p := c + n * half[i]
			var v := n.dot(a) if slide else (p - a * p.dot(a)).length()
			if v > best_v + 1e-6:
				best_v = v
				best = p
	return Transform3D(Basis.IDENTITY, best)


static func _good_surface(s: Variant) -> bool:
	if typeof(s) != TYPE_ARRAY or (s as Array).size() != 2:
		return false
	var t: Variant = s[0]
	var r: Variant = s[1]
	if typeof(t) != TYPE_TRANSFORM3D or typeof(r) != TYPE_RECT2:
		return false
	var rr := r as Rect2
	return (t as Transform3D).is_finite() and _within((t as Transform3D).origin) and rr.is_finite() \
			and rr.size.x >= 0.0 and rr.size.y >= 0.0 and rr.size.length() <= MAX_EXTENT * 2.0


## The newest snapshot's door here (CDDA's state; in mock mode the client's own state wins). Parts: sync_part.
func sync(d: Dictionary) -> void:
	if mech != "":
		return
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


## A part's CDDA state from a newer snapshot (in mock mode the client's own state wins).
func sync_part(open: bool, is_locked: bool) -> void:
	if mech == "":
		return
	if world.door_local and typeof(_state().get("open")) == TYPE_BOOL:
		open = _state()["open"]
	locked = is_locked
	if open != cdda_open:
		cdda_open = open
		_asked = false
		_swing = NAN
		_state()["until"] = 0
		set_process(true)


## 0 = closed .. 1 = square to the wall (doors) or fully open (parts).
func open_amount() -> float:
	if mech != "":
		return amount / max_amount
	return absf(angle) / OPEN_REST


## Where the leaf settles when let go: closed, or open where it was left (at least OPEN_AT).
func rest_angle() -> float:
	if not cdda_open:
		return 0.0
	if absf(angle) >= OPEN_AT:
		return angle
	return OPEN_REST * (signf(angle) if angle != 0.0 else 1.0)


## Where a part settles when let go. With a CDDA pair: CDDA's state (open: where it was left if past
## OPEN_FRAC, else fully open). Without: where it was left, shut when under CLOSE_FRAC.
func rest_amount() -> float:
	if paired():
		if not cdda_open:
			return 0.0
		return amount if amount >= OPEN_FRAC * max_amount else max_amount
	return amount if amount >= CLOSE_FRAC * max_amount else 0.0


## CDDA has an open / closed pair for this part's furniture.
func paired() -> bool:
	return open_id != "" or close_id != ""


func set_angle(a: float) -> void:
	if not is_finite(a):
		return
	var lim := LOCKED_PLAY if locked and not cdda_open else MAX_ANGLE
	angle = clampf(a, -lim, lim)
	_apply()
	_state()["angle"] = angle
	if grabbed:
		_threshold(a)


## A part's opening (0..max_amount; a locked, closed part only rattles).
func set_amount(a: float) -> void:
	if mech == "" or not is_finite(a):
		return
	amount = clampf(a, 0.0, _limit())
	_apply_part()
	_state()["amount"] = amount
	if grabbed:
		_threshold_part(a)


func _limit() -> float:
	if locked and not cdda_open:
		return minf(LOCKED_SLIDE if mech == "slide" else LOCKED_PLAY, max_amount)
	return max_amount


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


## The same for a part with a CDDA pair (parts without one never ask).
func _threshold_part(wanted: float) -> void:
	if _asked or not paired():
		return
	var want_open := not cdda_open and wanted > OPEN_FRAC * max_amount
	var want_close := cdda_open and wanted < CLOSE_FRAC * max_amount
	if not want_open and not want_close:
		return
	_asked = true
	if world.door_local:
		if want_open and locked:
			world.door_message.emit("It's locked.")
			return
		_state()["open"] = want_open
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
	if not hand.is_finite():
		return
	begin_grab(hand)
	if mech == "hinge":
		_hand_offset = amount - _hinge_angle(hand)
	elif mech == "slide":
		_hand_offset = amount - _slide_pos(hand)
	else:
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
## Parts: down also pulls towards you, up also lifts.
func drag_mouse(rel: Vector2, view: Basis) -> void:
	if not grabbed:
		return
	if mech != "":
		_drag_mouse_part(rel, view)
		return
	var fwd := -view.z
	fwd.y = 0.0
	var rgt := view.x
	rgt.y = 0.0
	var w := (rgt.normalized() * rel.x - fwd.normalized() * rel.y) * M_PER_PX
	var t := tangent()
	var r := maxf(t.length(), 0.2)
	set_angle(angle + w.dot(t / t.length() if t.length() > 0.001 else Vector3.ZERO) / r)


func _drag_mouse_part(rel: Vector2, view: Basis) -> void:
	var rgt := view.x
	rgt.y = 0.0
	var toward := view.z   # horizontal, towards the player
	toward.y = 0.0
	if toward.length() < 0.2:   # looking (nearly) straight down: screen-down is towards the player
		toward = -view.y
		toward.y = 0.0
	var w := (rgt.normalized() * rel.x + toward.normalized() * rel.y + Vector3.UP * -rel.y) * M_PER_PX
	var a := global_basis * axis
	var unit := a.length()
	if unit < 1e-6 or not w.is_finite():
		return
	a /= unit
	if mech == "slide":
		set_amount(amount + w.dot(a) / unit)   # back to the pivot's own metres
		return
	var p := leaf.global_transform * _grab_local
	var r := p - (global_position + a * (p - global_position).dot(a))
	var t := a.cross(r)
	if t.length() < 1e-4:
		return
	set_amount(amount + w.dot(t.normalized()) / maxf(r.length(), MIN_RADIUS))


## A VR hand at `hand` (world): the leaf turns with it around the hinge (parts: or slides along with it).
func drag_hand(hand: Vector3) -> void:
	if not grabbed or not hand.is_finite():
		return
	if mech == "hinge":
		var h := _hinge_angle(hand)
		if is_nan(h):
			return
		if is_nan(_hand_offset):   # gripped on the hinge line: start from the first usable angle
			_hand_offset = amount - h
		var mid := max_amount / 2   # the wrap's seam sits opposite the middle of the travel
		set_amount(wrapf(h + _hand_offset, mid - PI, mid + PI))
	elif mech == "slide":
		set_amount(_slide_pos(hand) + _hand_offset)
	else:
		set_angle(wrapf(_yaw_of(hand) + _hand_offset - base_yaw, -PI, PI))


func _yaw_of(p: Vector3) -> float:
	var v := p - global_position
	return atan2(-v.z, v.x)


## Angle of world point `p` about the hinge line (right-hand rule about `axis`), NAN on the line itself.
func _hinge_angle(p: Vector3) -> float:
	var l := global_transform.affine_inverse() * p
	var v := l - axis * l.dot(axis)
	if v.length() < 0.02:
		return NAN
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	return atan2(v.dot(axis.cross(u)), v.dot(u))


## Position of world point `p` along a drawer's slide (pivot space).
func _slide_pos(p: Vector3) -> float:
	return (global_transform.affine_inverse() * p).dot(axis)


## Distance along a ray (normalized `dir`) to the leaf, INF when it misses.
func ray_distance(origin: Vector3, dir: Vector3) -> float:
	var inv := leaf.global_transform.affine_inverse()
	var o := inv * origin
	var d := inv.basis * dir
	var box := _box()
	var lo := box.position
	var hi := box.end
	var t0 := -INF
	var t1 := INF
	for a in 3:
		if absf(d[a]) < 1e-8:
			if o[a] < lo[a] or o[a] > hi[a]:
				return INF
			continue
		var ta := (lo[a] - o[a]) / d[a]
		var tb := (hi[a] - o[a]) / d[a]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
	if t0 > t1 or t1 < 0.0:
		return INF
	return maxf(t0, 0.0)


## Distance from `p` (world) to the leaf's surface (0 inside).
func distance_to(p: Vector3) -> float:
	var l := leaf.global_transform.affine_inverse() * p
	var box := _box()
	return (p - leaf.global_transform * l.clamp(box.position, box.end)).length()


## The box ray_distance and distance_to use, in Leaf space: a door's fixed leaf, a part's size.
func _box() -> AABB:
	if mech == "":
		var half := Vector3(LEAF_W, TerrainMesher.DOOR_H, LEAF_T) / 2
		return AABB(-half, half * 2)
	return size


## Where a hand takes hold now (world): a door's knob, a part's handle (it moves with the part).
func handle_point() -> Vector3:
	if mech == "":
		return (leaf.get_child(0) as Node3D).global_position
	return leaf.global_transform * handle.origin


## The node that moves with a part: put what lies in a drawer or on a shelf here.
func contents() -> Node3D:
	return leaf


## Surface `i` (see `surfaces`) in world space now, or an empty transform for a bad index.
func surface_global(i: int) -> Transform3D:
	if i < 0 or i >= surfaces.size():
		return Transform3D()
	return leaf.global_transform * (surfaces[i][0] as Transform3D)


## The grab highlight: an outline round the leaf (parts: round each of its own meshes).
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
	if mech == "":
		leaf.material_overlay = _outline if on else null
		return
	for gi: Variant in _geo:   # untyped: a mesh may have been freed
		if is_instance_valid(gi):
			(gi as GeometryInstance3D).material_overlay = _outline if on else null


func highlighted() -> bool:
	return _lit


func _process(delta: float) -> void:
	if grabbed or Time.get_ticks_msec() < int(_state().get("until", 0)):
		return
	if mech != "":
		_process_part(delta)
		return
	if is_nan(_swing):
		_swing = rest_angle()
	angle = move_toward(angle, _swing, SWING_SPEED * delta)
	_apply()
	_state()["angle"] = angle
	if angle == _swing:
		_swing = NAN
		set_process(false)


func _process_part(delta: float) -> void:
	if is_nan(_swing):
		_swing = rest_amount()
	amount = move_toward(amount, _swing, (SLIDE_SPEED if mech == "slide" else SWING_SPEED) * delta)
	_apply_part()
	_state()["amount"] = amount
	if amount == _swing:
		_swing = NAN
		set_process(false)


func _apply() -> void:
	rotation = Vector3(0, base_yaw + angle, 0)


func _apply_part() -> void:
	if mech == "slide":
		leaf.transform = Transform3D(Basis.IDENTITY, axis * amount)
	else:
		leaf.transform = Transform3D(Basis(axis, amount), Vector3.ZERO)


func _state() -> Dictionary:
	if mech != "":
		if not world.door_state.has(id):
			if world.door_state.size() >= MAX_STATES:
				return _own
			world.door_state[id] = {}
		return world.door_state[id]
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
