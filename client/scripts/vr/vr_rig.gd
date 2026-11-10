class_name VrRig
extends XROrigin3D
## Block L1: the VR ghost-walk rig. A head (XRCamera3D) and two controllers on an origin that stands on the
## floor of level `z`. Controller layouts (setting `layout`, auto = from the runtime's interaction profile):
## - quest (sticks + A/B/X/Y: Quest, Index, Pico, WMR): left stick moves relative to the head (or the hand)
##   and slides along walls; right stick turns (snap or smooth) and, pushed forward, aims a teleport arc that
##   jumps on release. Right B / A: level up / down. Left Y: back to the player. WMR / Index trackpad click:
##   right up / down half = level up / down, left = back to the player.
## - vive (trackpad wands): left pad touched moves; right pad clicked: left / right half snap turns, up half
##   held aims the teleport, down half = level down. Right menu: level up. Left pad click: back to the player.
## Left menu button (Index: left stick click): the settings menu (VrMenu; settings in VrSettings, saved to
## `save_path`), with a laser pointer from the main hand. Hands (VrHand) show finger tracking when the runtime
## gives it, else fingers from the buttons; they are the only hands: the player's body hides its own and
## reaches its arms for their wrists (drive_body).
## Main hand (setting `main_hand`, right unless left-handed): its trigger uses pointed stairs, it aims the
## teleport arc and the menu pointer, and it shows CDDA's main hand; the compass sits on the off wrist.
## Seated play: the origin stands `height` over the level's floor (floor_y), so the head rises by it; the menu
## can set it from the head's height now ("Calibrate height").
## Hands (block L2): each controller is a hand of the shared Hands layer ("vr_l" / "vr_r"; `hands`, set by main.gd).
## What a free hand touches (a door leaf or an item in reach) is outlined; the grip (setting `grip`: hold, or toggle)
## grabs it. A door swings with the hand. An item is taken at once into CDDA's main hand (main controller) or off
## hand (the other), so it is carried while you walk; letting go puts it where the hand is (Hands.drop_at), or into
## the biggest worn container when the hand is over the shoulder. Grip on nothing picks up what CDDA already holds
## in that hand, ready to put down. CDDA decides every move; a refusal buzzes and shows its reason by the hand.
## Heavy items lag behind the hand; a two-handed one sags in one hand and sits between both when the other hand
## grips it too.
## A tunnel vignette darkens the edges while moving or turning smoothly; a blink hides jumps.
## Nothing here talks to the sim: the viewer is a ghost beside the player's body (VR-ready rule: the camera
## rig is separate from the body).

signal level_changed(z: int)
## The main-hand trigger pointed at stairs (StairUse.find's dictionary). In a live game main.gd queues CDDA's
## actions.
signal stair_used(stair: Dictionary)

const DEADZONE := 0.2
const TURN_ON := 0.7      # stick x past this snaps a turn ...
const TURN_OFF := 0.3     # ... and must come back inside this before the next one
const AIM_ON := 0.7       # stick forward past this aims the teleport ...
const AIM_OFF := 0.3      # ... and back inside this jumps
const FADE_S := 0.12      # blink after a teleport or level change
const VIGNETTE_DIST := 0.2
const VIGNETTE_OPEN := 0.3    # hole radius at VIGNETTE_DIST with strength 0 (about 56 deg, the view's edge)
const VIGNETTE_SHUT := 0.07   # ... and with strength 1
const DEFAULTS := VrSettings.DEFAULTS
const HAND_TRACKERS := [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const POINTER_MAX := 4.0      # metres: the menu pointer reaches this far
const POINTER_LEN := 1.0      # the pointer's length when it misses the panel
const POINTER_R := 0.0015     # its radius

var world: WorldView
var walk: VrWalk
var settings := DEFAULTS.duplicate()
var z := 0
var camera: XRCamera3D
var left: XRController3D
var right: XRController3D
var vignette := 0.0       # current strength, eases toward settings.vignette while moving
var aiming := false
var arc := {}             # VrWalk.teleport_arc result while aiming
var _turn_armed := true
var _fade := 0.0
var _vignette_node: MeshInstance3D
var _fade_mat: StandardMaterial3D
var _fade_node: MeshInstance3D
var _arc_mesh: ImmediateMesh
var _arc_mat: StandardMaterial3D
var _marker: MeshInstance3D
var left_held: VrHeld      # live game: what each hand holds, on its controller (show_held)
var right_held: VrHeld
var _was_filling := false
var save_path := ""       # where the menu saves the settings ("" = don't, e.g. in tests)
var menu: VrMenu          # created on first open
var left_hand: VrHand
var right_hand: VrHand
var _boxes: Array[MeshInstance3D] = []   # simple hands (setting hands = boxes)
const BOX_WRIST := Vector3(0, 0, 0.13)   # the wrist behind a box hand, controller space
var body: PlayerBody      # the player's body (main.gd): its arms reach for these hands (drive_body)
var _glove_key := "-"     # body.key the hand colours were taken from
var compass: VrCompass    # wrist rose / belt ring (place_compass)
var pointer: MeshInstance3D       # the menu's laser pointer from the main hand (update_pointer) ...
var pointer_dot: MeshInstance3D   # ... and its dot on the panel
var _held := {}                   # the last show_held, shown again when the main hand changes

const HAND_IDS := ["vr_l", "vr_r"]   # Hands ids of the left / right controller
const GRAB_REACH := 0.12   # metres from a hand to a door leaf or an item it can grip
const SHOULDER_DROP := 0.3 # over the shoulder: the hand higher than this under the head (and behind it)
const STRENGTH := 8        # CDDA's starting strength: the snapshot doesn't carry the player's stats yet
const LIGHT := 0.25        # items under this share of a one-hand load follow the hand at once
const LAG_RATE := 6.0      # 1/s at a full one-hand load (heavier: slower)
const ALONE_RATE := 0.4    # a two-handed item in one hand follows this much slower ...
const MIN_RATE := 1.0      # ... but never slower than this
const MAX_LAG_M := 1.0     # farther behind than this (a jump, a teleport): it is in the hand at once
const SAG_RAD := 0.5       # a two-handed item in one hand tips down this much ...
const SAG_DROP := 0.06     # ... and hangs this much lower
const TWO_HAND_M := 0.35   # the other hand grips within this of a two-handed item's grip: it holds it too
const NOTE_S := 3.0        # a refusal's reason shows this long by the hand
const NOTE_MAX := 120      # characters of it (the text comes from the sim)

## The shared hands (main.gd); null: the controllers grab nothing.
var hands: Hands:
	set(h):
		if is_instance_valid(hands) and hands.refused.is_connected(_on_refused):
			hands.refused.disconnect(_on_refused)
		hands = h
		if h != null and not h.refused.is_connected(_on_refused):
			h.refused.connect(_on_refused)
var strength := STRENGTH   # how much a hand carries without lag (ItemRef.two_handed's rule)
var notes: Array[Label3D] = [null, null]   # CDDA's reason for a refusal, by the left / right hand
var buzzes: Array[int] = [0, 0]            # haptic pulses asked of each hand (tests count them)
var _note_left: Array[float] = [0.0, 0.0]
var _grip_down: Array[bool] = [false, false]   # the grip button is held (two-handed support uses it)


## Options after `--` over the defaults (VrSettings.ARGS: --vr-move= --vr-turn= --vr-snap= ...).
static func settings_from_args(args: Dictionary) -> Dictionary:
	return VrSettings.from_args(args)


## Layout for an OpenXR interaction profile path: trackpad wands get "vive", everything else "quest".
static func layout_for(profile: String) -> String:
	return "vive" if profile.contains("htc/vive_controller") else "quest"


func current_layout() -> String:
	if settings["layout"] != "auto":
		return settings["layout"]
	var t := XRServer.get_tracker(&"left_hand") as XRPositionalTracker
	return layout_for(t.profile if t != null else "")


## The Vive wand's turn pad as a stick: only while clicked (up = aim the teleport, left / right = snap turn;
## down is level down, a button); smooth turning follows a touched pad's x.
static func wand_turn(pad: Vector2, click: bool, smooth: bool) -> Vector2:
	if click:
		if pad.length() < 0.3 or (pad.y < -0.5 and absf(pad.y) > absf(pad.x)):
			return Vector2.ZERO
		return pad.normalized()
	return Vector2(pad.x, 0.0) if smooth else Vector2.ZERO


func _move_ctrl() -> XRController3D:
	return right if settings["swap_sticks"] else left


func _turn_ctrl() -> XRController3D:
	return left if settings["swap_sticks"] else right


## The controller of CDDA's main hand (setting main_hand): stairs, teleport arc, menu pointer, wielded item.
func main_ctrl() -> XRController3D:
	return left if settings["main_hand"] == "left" else right


func off_ctrl() -> XRController3D:
	return right if settings["main_hand"] == "left" else left


func main_hand_model() -> VrHand:
	return left_hand if settings["main_hand"] == "left" else right_hand


## The off hand's model: the wrist compass sits on it.
func off_hand_model() -> VrHand:
	return right_hand if settings["main_hand"] == "left" else left_hand


func _init(w: WorldView, s := {}) -> void:
	world = w
	walk = VrWalk.new(w)
	settings.merge(s, true)
	name = "VrRig"
	_build()   # children exist before the rig enters the tree (tests drive it without one)


func _ready() -> void:
	current = true


func _build() -> void:
	camera = XRCamera3D.new()
	camera.name = "Head"
	camera.near = 0.05
	camera.far = 600.0
	add_child(camera)
	left = _controller("LeftHand", &"left_hand", Color(0.35, 0.6, 1.0))
	right = _controller("RightHand", &"right_hand", Color(1.0, 0.6, 0.25))
	left.button_pressed.connect(func(n: String) -> void: press(left, n))
	right.button_pressed.connect(func(n: String) -> void: press(right, n))
	left.button_released.connect(func(n: String) -> void: release(left, n))
	right.button_released.connect(func(n: String) -> void: release(right, n))
	left_hand = VrHand.new(true)
	right_hand = VrHand.new(false)
	add_child(left_hand)
	add_child(right_hand)
	compass = VrCompass.new()
	add_child(compass)
	_vignette_node = _make_vignette()
	camera.add_child(_vignette_node)
	_fade_node = _make_fade()
	camera.add_child(_fade_node)
	_arc_mesh = ImmediateMesh.new()
	_arc_mat = _overlay_mat(Color.WHITE, 90)
	_arc_mat.vertex_color_use_as_albedo = true
	var arc_node := MeshInstance3D.new()
	arc_node.name = "TeleportArc"
	arc_node.mesh = _arc_mesh
	arc_node.top_level = true   # points are in world space
	add_child(arc_node)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.22
	ring.outer_radius = 0.3
	ring.material = _overlay_mat(Color.WHITE, 90)
	_marker = MeshInstance3D.new()
	_marker.name = "TeleportTarget"
	_marker.mesh = ring
	_marker.top_level = true
	_marker.visible = false
	add_child(_marker)
	var rod := CylinderMesh.new()   # radius 1, height 1 along Y: scaled to the ray (_segment)
	rod.top_radius = 1.0
	rod.bottom_radius = 1.0
	rod.height = 1.0
	rod.radial_segments = 6
	rod.rings = 1
	rod.material = _overlay_mat(Color(0.45, 0.8, 1.0, 0.8), 112)   # over the menu (110, 111)
	pointer = MeshInstance3D.new()
	pointer.name = "MenuPointer"
	pointer.mesh = rod
	var dot := SphereMesh.new()
	dot.radius = 0.007
	dot.height = 0.014
	dot.radial_segments = 8
	dot.rings = 4
	dot.material = _overlay_mat(Color(1.0, 1.0, 1.0, 0.95), 113)
	pointer_dot = MeshInstance3D.new()
	pointer_dot.name = "MenuPointerDot"
	pointer_dot.mesh = dot
	for n: MeshInstance3D in [pointer, pointer_dot]:
		n.top_level = true   # placed in world space
		n.visible = false
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(n)
	_update_visuals()


func _controller(n: String, tracker: StringName, col: Color) -> XRController3D:
	var c := XRController3D.new()
	c.name = n
	c.tracker = tracker
	c.pose = &"aim"
	var box := BoxMesh.new()   # placeholder hand until L2
	box.size = Vector3(0.05, 0.04, 0.14)
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	box.material = m
	var hand := MeshInstance3D.new()
	hand.mesh = box
	hand.visible = false
	_boxes.append(hand)
	hand.position = Vector3(0, 0, 0.06)   # the aim pose points along -Z; the hand sits behind it
	c.add_child(hand)
	add_child(c)
	return c


func _process(delta: float) -> void:
	var tc := _turn_ctrl()
	var inp := {"move": _stick(_move_ctrl()), "turn": _stick(tc)}
	if current_layout() == "vive":
		inp["turn"] = wand_turn(inp["turn"], tc.get_is_active() and tc.is_button_pressed(&"primary_click"),
				settings["turn"] == "smooth")
	step(delta, inp)
	update_pointer()
	update_hands(delta)
	pose_hands()
	drive_body()
	place_compass()


## The compass on the off-hand wrist and/or the belt (settings `compass`); main.gd feeds its blips.
func place_compass() -> void:
	compass.mode = settings["compass"]
	compass.heading_deg = Compass.heading_of(camera.global_basis)
	compass.place(self)


## One hand system: VrHand draws the hands (fingers from tracking or buttons), the player's body draws the arms,
## which reach for the hands' wrists; the body's own hand boxes hide and the hands take the glove's colour.
## Runs after main.gd placed the body under the head this frame.
func drive_body() -> void:
	if body == null or not is_instance_valid(body):
		return
	body.show_hands = false
	if body.key != _glove_key:
		_glove_key = body.key
		left_hand.set_colour(hand_colour(body.pieces, "hand_l"))
		right_hand.set_colour(hand_colour(body.pieces, "hand_r"))
	body.reach(wrist(0), wrist(1))


## Hand i's wrist (global), or null when neither the hand nor its box shows (the arm hangs then).
func wrist(i: int) -> Variant:
	var h: VrHand = left_hand if i == 0 else right_hand
	if h.visible and h.joints.size() == VrHand.JOINTS:
		return global_transform * h.wrist()
	if _boxes[i].visible:
		var c: XRController3D = left if i == 0 else right
		return c.global_transform * BOX_WRIST
	return null


## The outermost skin or worn piece on a hand part (PlayerBody.plan lists inner to outer), else bare skin.
static func hand_colour(pieces: Array[Dictionary], part: String) -> Color:
	var col := VrHand.SKIN
	for p: Dictionary in pieces:
		if p.get("part") == part and p.get("kind") in ["skin", "worn"]:
			col = p["colour"]
	return col


func _ctrl(i: int) -> XRController3D:
	return left if i == 0 else right


## The Hands id of controller c.
func hand_id(c: XRController3D) -> String:
	return HAND_IDS[0] if c == left else HAND_IDS[1]


## Per frame: the hands follow the controllers; a held door swings with its hand; a held item follows by its
## weight (follow_rate, sag, two_hand_pose); a free hand outlines what it could grip. CDDA's own hand display
## (VrHeld) hides while that hand holds a copy. `all_hands`: count hands the runtime doesn't track (tests).
func update_hands(delta: float, all_hands := false) -> void:
	_tick_notes(delta)
	if hands == null:
		return
	var drawn: Array = [null, null]   # where each held item was drawn last frame
	for i in 2:
		var id: String = HAND_IDS[i]
		_forget_freed(id)
		var p := hands.proxy(id)
		if p != null:
			drawn[i] = p.global_transform
		hands.set_hand_pose(id, _ctrl(i).global_transform, true)
	for i in 2:
		var c := _ctrl(i)
		var id: String = HAND_IDS[i]
		var held := hands.holding(id)
		if held.is_empty():
			var t := {}
			if (all_hands or c.get_is_active()) and world.snapshot != null and not menu_open() \
					and not _supports(i, drawn[1 - i]):
				t = hands.find_near(c.global_position, GRAB_REACH)
			hands.hover(id, t)
			continue
		hands.hover(id, {})   # a held door stays lit; it lights again as a hover after it is let go
		if held.get("kind") == "door":
			var n: Variant = held.get("node")   # untyped: a leaf can be freed under a hand (_forget_freed)
			if is_instance_valid(n):
				(n as Grabbable).drag_hand(c.global_position)
			else:
				hands.cancel(id)
		elif drawn[i] is Transform3D:
			_weigh(i, drawn[i], delta)
	_sync_held()


## D5: a door leaf can be freed under a hand (its submap dropped, the door gone). In Godot 4.7 a freed object
## compares equal to null and can't be typed, and Hands keeps the leaf in typed variables, so a stale leaf it
## still holds or outlines becomes null first (Hands then lets go of it as of nothing).
func _forget_freed(id: String) -> void:
	var h := hands.hand(id)
	for t: Dictionary in [h.hover, h.held]:
		if t.get("kind") == "door" and not is_instance_valid(t.get("node")):
			t["node"] = null


## The held item of hand i follows its controller by weight: light ones at once, heavy ones eased from where they
## were drawn (`from`); a two-handed one sags and lags in one hand and sits between both when the other grips it.
func _weigh(i: int, from: Transform3D, delta: float) -> void:
	var id: String = HAND_IDS[i]
	var p := hands.proxy(id)
	var it: ItemRef = hands.holding(id).get("item")
	if p == null or it == null:
		return
	var c := _ctrl(i)
	var both := it.two_handed(world.tables, strength)
	if both and _supports(1 - i, from):
		var o := _ctrl(1 - i)
		var m: XRController3D = c if c == main_ctrl() else o
		var f: XRController3D = o if m == c else c
		p.global_transform = two_hand_pose(m.global_position, f.global_position, c.global_basis.y,
				ItemVisual.grip(it.type, world), p.scale)
		return
	var to := p.global_transform   # where Hands put it: held rigidly by its grip
	if both:
		to = sag(to, c.global_transform, SAG_RAD)
	p.global_transform = ease_toward(from, to, follow_rate(it.weight_g(world.tables), strength, both), delta, p.scale)


## Hand j steadies the two-handed item the other hand holds (drawn at `drawn`): its grip is held, it holds
## nothing, and it is within TWO_HAND_M of the item's grip point.
func _supports(j: int, drawn: Variant) -> bool:
	if hands == null or not _grip_down[j] or not drawn is Transform3D or not hands.holding(HAND_IDS[j]).is_empty():
		return false
	var it: ItemRef = hands.holding(HAND_IDS[1 - j]).get("item")
	if it == null or not it.two_handed(world.tables, strength):
		return false
	var xf: Transform3D = drawn
	var g := ItemVisual.grip(it.type, world)
	var s := maxf(absf(xf.basis.get_scale().x), 0.001)
	return _ctrl(j).global_position.distance_to(xf * (g.origin / s)) <= TWO_HAND_M


## Grip on controller c: the door leaf or item it touches, else what CDDA holds in that hand (main controller:
## the wielded item; the other: the off-hand item). An item lying in the world is taken at once into that hand.
## Near the other hand's two-handed item it only steadies it. False (and a buzz) when there is nothing to grab;
## a refusal from CDDA comes later through Hands.refused.
func grab_with(c: XRController3D) -> bool:
	if hands == null:
		return false
	var i := 0 if c == left else 1
	var id: String = HAND_IDS[i]
	_forget_freed(id)
	if not hands.holding(id).is_empty():
		return false
	var other := hands.proxy(HAND_IDS[1 - i])
	if other != null and _supports(i, other.global_transform):
		return true
	hands.set_hand_pose(id, c.global_transform, true)   # a door starts its swing here, an adopted item shows here
	var t := {}
	if world.snapshot != null and not menu_open():
		t = hands.find_near(c.global_position, GRAB_REACH)
	var ok := false
	if t.is_empty():
		var it := cdda_holds(c)
		ok = it != null and hands.adopt(id, it)
	elif t["kind"] == "item":
		ok = hands.grab(id, t, "main" if c == main_ctrl() else "off")
	else:
		ok = hands.grab(id, t)
	if not ok:
		_feel(c)
	return ok


## What CDDA holds in controller c's hand (main: wielded; off: the item flagged off hand), as a carried ItemRef
## from the snapshot's carried rows; null for nothing.
func cdda_holds(c: XRController3D) -> ItemRef:
	var s := world.snapshot
	if s == null:
		return null
	var flag := Snapshot.CARRIED_WIELDED if c == main_ctrl() else Snapshot.CARRIED_OFFHAND
	var cs := Snapshot.CARRIED_STRIDE
	var n := mini(s.carried.size(), Snapshot.MAX_CARRIED * cs)
	for k in range(0, n - cs + 1, cs):
		if (s.carried[k + 4] & flag) != 0:
			return ItemRef.on_player(s.carried[k], int(s.carried[k + 1]), s.carried[k + 2], int(s.carried[k + 3]),
					int(s.carried[k + 4]), s.player_pos)
	return null


## Lets go of what hand c holds. An item: over the shoulder into the biggest worn container (none: a buzz, and it
## goes where the hand is), else where the hand is (Hands.drop_at; nowhere it can go: it stays in CDDA's hand).
## A door settles. Returns Hands.release's action ("" when nothing was sent).
func let_go(c: XRController3D) -> String:
	if hands == null:
		return ""
	var id := hand_id(c)
	_forget_freed(id)
	var held := hands.holding(id)
	if held.is_empty():
		return ""
	var it: ItemRef = held.get("item")
	if held.get("kind") != "item" or it == null or world.snapshot == null:
		return hands.release(id, {})
	var drop := {}
	if over_shoulder(camera.global_transform, c.global_position):
		var bag := shoulder_bag(hands.picker.worn_containers(), it, world.tables)
		if bag != null:
			drop = {"kind": "container", "container": bag}
		else:
			_feel(c)
	if drop.is_empty():
		drop = hands.drop_at(c.global_position, it)
	return hands.release(id, drop)


func release(c: XRController3D, n: String) -> void:
	if n != "grip_click":
		return
	_grip_down[0 if c == left else 1] = false
	if settings["grip"] != "toggle":   # toggle: the next press lets go
		let_go(c)


## A hand at `hand_pos` is over the shoulder of a head at `head`: higher than SHOULDER_DROP under it and behind
## the head's level forward plane (looking straight down or up, the top of the head says where forward is).
static func over_shoulder(head: Transform3D, hand_pos: Vector3) -> bool:
	if not head.is_finite() or not hand_pos.is_finite():
		return false
	var z := head.basis.z
	var fwd := -z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = head.basis.y * signf(z.y)
		fwd.y = 0.0
	if fwd.length() < 0.0001:
		return false
	var d := hand_pos - head.origin
	return d.y > -SHOULDER_DROP and d.dot(fwd.normalized()) < 0.0


## The worn container an item goes into over the shoulder: the biggest (by volume) that isn't the item; null.
static func shoulder_bag(worn: Array[ItemRef], held: ItemRef, tables: IdTables) -> ItemRef:
	var best: ItemRef = null
	var best_ml := -1
	for r in worn:
		if r == null or (held != null and r.uid == held.uid):
			continue
		var ml := r.volume_ml(tables)
		if ml > best_ml:
			best = r
			best_ml = ml
	return best


## What one hand lifts without strain: CDDA's two-handed limit (ItemRef.two_handed), strength x 4 x 113 g.
static func one_hand_g(str_stat: int) -> float:
	return float(clampi(str_stat, 1, 100) * 4 * 113)


## How fast (1/s) a carried item catches up with its hand: INF (at once) for light ones, slower the heavier
## against `str_stat`; a two-handed item in one hand much slower.
static func follow_rate(weight_g: int, str_stat: int, two_handed: bool) -> float:
	var share := float(maxi(weight_g, 0)) / one_hand_g(str_stat)
	if share < LIGHT and not two_handed:
		return INF
	var k := LAG_RATE / maxf(share, LIGHT)
	if two_handed:
		k *= ALONE_RATE
	return maxf(k, MIN_RATE)


## One frame of an item following its hand: from `from` toward `to` at `rate` (1/s, INF = at once), keeping
## the item's own scale `item_scale`. Far behind (a jump): at `to` at once.
static func ease_toward(from: Transform3D, to: Transform3D, rate: float, delta: float,
		item_scale: Vector3) -> Transform3D:
	if not is_finite(rate) or not from.is_finite() or from.origin.distance_to(to.origin) > MAX_LAG_M:
		return to
	var a := 1.0 - exp(-maxf(rate, 0.0) * clampf(delta, 0.0, 1.0))
	var q := from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), a)
	return Transform3D(Basis(q).scaled(item_scale), from.origin.lerp(to.origin, a))


## `xf` (an item held by a hand at `hand`) tipped down by `angle` about the hand, the way it points, and hung
## SAG_DROP lower: a heavy item in one hand.
static func sag(xf: Transform3D, hand: Transform3D, angle: float) -> Transform3D:
	var out := xf
	var fwd := -hand.basis.z
	fwd.y = 0.0
	if fwd.length() > 0.01 and is_finite(angle):
		var r := Basis(Vector3.UP.cross(fwd.normalized()).normalized(), angle)
		out = Transform3D(r * xf.basis, hand.origin + r * (xf.origin - hand.origin))
	out.origin.y -= SAG_DROP
	return out


## An item held in both hands: its grip (`grip`, ItemVisual.grip) midway between them, pointing (-Z) from the
## off hand to the main hand, `up` (the main hand's up) as its up where it can be; `item_scale`: its own scale.
static func two_hand_pose(main_pos: Vector3, off_pos: Vector3, up: Vector3, grip: Transform3D,
		item_scale: Vector3) -> Transform3D:
	var d := main_pos - off_pos
	if not d.is_finite() or d.length() < 0.01:
		d = Vector3.FORWARD
	d = d.normalized()
	var u: Vector3 = up.normalized() if up.is_finite() and up.length() > 0.01 else Vector3.UP
	if absf(u.dot(d)) > 0.99:
		u = Vector3.UP if absf(d.y) < 0.99 else Vector3.BACK
	var b := Basis.looking_at(d, u) * grip.basis.inverse()
	var mid: Vector3 = (main_pos + off_pos) * 0.5 if main_pos.is_finite() and off_pos.is_finite() else Vector3.ZERO
	return Transform3D(b.scaled(item_scale), mid - b * grip.origin)


## CDDA said no to something a VR hand started: a buzz, and its reason by that hand for a while.
func _on_refused(id: String, _target: Dictionary, reason: String) -> void:
	var i := HAND_IDS.find(id)
	if i < 0:
		return
	_feel(_ctrl(i))
	say(i, reason)


## A short line by hand i (VR has no status line): billboarded, over everything, gone after NOTE_S.
func say(i: int, text: String) -> void:
	if notes[i] == null or not is_instance_valid(notes[i]):
		var l := Label3D.new()
		l.name = "Note"
		l.pixel_size = 0.0003
		l.font_size = 32
		l.outline_size = 8
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.render_priority = 5
		l.modulate = Color(1.0, 0.55, 0.5)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.width = 700.0
		l.position = Vector3(0, 0.13, 0.04)   # over the hand, above VrHeld's line
		_ctrl(i).add_child(l)
		notes[i] = l
	notes[i].text = text.strip_edges().replace("\n", " ").left(NOTE_MAX)
	notes[i].visible = true
	_note_left[i] = NOTE_S


func _tick_notes(delta: float) -> void:
	for i in 2:
		if _note_left[i] <= 0.0:
			continue
		_note_left[i] -= maxf(delta, 0.0)
		if _note_left[i] <= 0.0 and notes[i] != null:
			notes[i].visible = false


## A buzz in controller c, counted.
func _feel(c: XRController3D) -> void:
	buzzes[0 if c == left else 1] += 1
	_buzz(c)


## VrHeld (CDDA's hands, show_held) shows on a controller unless that hand holds the item's copy (it would show
## twice).
func _sync_held() -> void:
	if left_held == null:
		return
	for i in 2:
		var node: VrHeld = left_held if i == 0 else right_held
		var h: Variant = _held.get("main" if _ctrl(i) == main_ctrl() else "off")
		node.visible = h is Dictionary and not (h as Dictionary).is_empty() \
				and (hands == null or hands.proxy(HAND_IDS[i]) == null)


## Hands from the runtime's hand tracking, else from each controller's buttons, else hidden; or the simple
## boxes (setting hands).
func pose_hands() -> void:
	var mode: String = settings["hands"]
	var i := 0
	for c: XRController3D in [left, right]:
		var h: VrHand = left_hand if c == left else right_hand
		_boxes[i].visible = mode == "boxes"
		if mode == "boxes":
			h.visible = false
		elif mode == "auto" and h.pose_from_tracker(XRServer.get_tracker(HAND_TRACKERS[i]) as XRHandTracker):
			pass
		elif c.get_is_active():
			var thumb := false
			for b: StringName in [&"primary_touch", &"primary_click", &"ax_touch", &"by_touch", &"secondary_touch"]:
				thumb = thumb or c.is_button_pressed(b)
			h.pose_from_controller(c.transform, VrHand.curls_from_buttons(c.get_float(&"trigger"),
					c.is_button_pressed(&"trigger_touch"), c.get_float(&"grip"), thumb))
		else:
			h.visible = false
		i += 1


static func _stick(c: XRController3D) -> Vector2:
	return c.get_vector2(&"primary") if c.get_is_active() else Vector2.ZERO


## One frame of locomotion from stick values (tests call this directly): `move` and `turn` are Vector2
## with x right and y forward, -1..1.
func step(delta: float, inp: Dictionary) -> void:
	var moving := false
	if menu_open():
		if menu.nav(inp.get("move", Vector2.ZERO)):
			_settings_changed()
	elif world.snapshot != null:
		var mv := _dead(inp.get("move", Vector2.ZERO))
		if settings["move"] == "smooth" and mv != Vector2.ZERO:
			_move(mv, delta)
			moving = true
		var tv: Vector2 = inp.get("turn", Vector2.ZERO)
		_aim(tv)
		if _turn(tv, delta):
			moving = true
	vignette = move_toward(vignette, settings["vignette"] if moving else 0.0, delta * 4.0)
	_fade = maxf(_fade - delta / FADE_S, 0.0)
	_update_visuals()


static func _dead(v: Vector2) -> Vector2:
	var l := minf(v.length(), 1.0)
	if l < DEADZONE:
		return Vector2.ZERO
	return v.normalized() * inverse_lerp(DEADZONE, 1.0, l)


func _move(mv: Vector2, delta: float) -> void:
	var src: Node3D = camera if settings["move_dir"] == "head" else _move_ctrl()
	var fwd := -src.global_basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = src.global_basis.y   # looking (or pointing) straight down: the top is forward
		fwd.y = 0.0
	fwd = fwd.normalized()
	var rgt := Vector3(-fwd.z, 0.0, fwd.x)
	var head := camera.global_position
	var to := walk.slide(head, (rgt * mv.x + fwd * mv.y) * float(settings["speed"]) * delta, z)
	global_position += Vector3(to.x - head.x, 0.0, to.z - head.z)


## True while turning smoothly (the vignette shows).
func _turn(tv: Vector2, delta: float) -> bool:
	if aiming or settings["turn"] == "off":
		return false
	var x := tv.x
	if settings["turn"] == "smooth":
		var d := _dead(Vector2(x, 0.0)).x
		if d != 0.0:
			turn_by(-d * deg_to_rad(settings["turn_speed"]) * delta)
			return true
		return false
	if _turn_armed and absf(x) > TURN_ON and absf(x) > absf(tv.y):
		turn_by(-signf(x) * deg_to_rad(settings["snap_deg"]))
		_turn_armed = false
	elif absf(x) < TURN_OFF:
		_turn_armed = true
	return false


func _aim(tv: Vector2) -> void:
	if not aiming and tv.y > AIM_ON and tv.y > absf(tv.x):
		aiming = true
	if not aiming:
		return
	var c := _turn_ctrl()   # the arc leaves the hand whose stick aims it
	arc = walk.teleport_arc(c.global_position, -c.global_basis.z, z)
	if tv.y < AIM_OFF:
		aiming = false
		if arc.get("valid", false):
			teleport_to(arc["pos"])
		else:
			_buzz(c)
		arc = {}


## Turns about the head (positive = counter-clockwise seen from above).
func turn_by(angle: float) -> void:
	global_transform = VrWalk.turned(global_transform, camera.global_position, angle)


## Moves so the head stands over `pos` (only x and z; the level stays).
func teleport_to(pos: Vector3) -> void:
	var head := camera.global_position
	global_position += Vector3(pos.x - head.x, 0.0, pos.z - head.z)
	if settings["blink"]:
		_fade = 1.0


## Up (+1) or down (-1) a level, to the nearest standable square; false (and a buzz) when there is none.
func change_level(dz: int) -> bool:
	var target: Variant = walk.nearest_standable(walk.square_at(camera.global_position, z + dz))
	if target == null:
		_buzz(right)
		return false
	go_to_square(target)
	return true


## Stairs the controller points at: in the mock (live_stairs false) the rig goes to the level they lead to; a
## live game moves the ghost when the player's level changes. Emits stair_used; a buzz and {} when it's no stair.
var live_stairs := false

func use_pointed_stair(c: XRController3D) -> Dictionary:
	var r := LookRay.new(world).cast(c.global_position, -c.global_basis.z)
	var s := StairUse.find(world, r["square"], z) if r["hit"] else {}
	if s.is_empty():
		_buzz(c)
		return {}
	if not live_stairs:
		var to: Variant = walk.nearest_standable(s["to"])
		if to == null:
			_buzz(c)
			return {}
		go_to_square(to)
	stair_used.emit(s)
	return s


func go_to_square(sq: Vector3i) -> void:
	z = sq.z
	place_height()
	teleport_to(world.coords.ms_center_to_world(sq))
	level_changed.emit(z)


## The floor of the rig's level (world y): where the body stands. The origin is `height` above it.
func floor_y() -> float:
	return VrWalk.floor_y(z)


## Stands the origin `height` over the level's floor: a seated player (head 0.4 m lower) with height 0.4
## sees from standing eye height. Every vertical placement of the rig goes through here.
func place_height() -> void:
	global_position.y = floor_y() + float(settings["height"])


## The height setting that puts a head now `head_y` over the tracking floor at standing eye height
## (FirstPersonCamera.EYE_H), snapped to the menu's step and clamped; null for a bad reading.
static func calibrated_height(head_y: float) -> Variant:
	if not is_finite(head_y):
		return null
	var spec: Array = VrSettings.SPEC["height"]
	return VrSettings.clean("height", snappedf(FirstPersonCamera.EYE_H - head_y, spec[2]))


## The menu's "Calibrate height": the head's height now becomes standing eye height.
func calibrate_height() -> void:
	var h: Variant = calibrated_height(camera.position.y)
	if h == null:
		_buzz(main_ctrl())
		return
	settings["height"] = h
	_settings_changed()


## Stands on a free square next to the player (CDDA square p), facing them.
func go_to_player(p: Vector3i) -> void:
	var spot: Variant = walk.nearest_standable(p, true)
	go_to_square(spot if spot != null else p)
	var fwd := -camera.global_basis.z
	fwd.y = 0.0
	var to := world.coords.ms_center_to_world(p) - camera.global_position
	to.y = 0.0
	if fwd.length() > 0.01 and to.length() > 0.01:
		turn_by(fwd.signed_angle_to(to, Vector3.UP))


func menu_open() -> bool:
	return menu != null and menu.visible


## Opens the settings menu in front of the head, or closes it and saves the settings.
func toggle_menu() -> void:
	if menu == null:
		menu = VrMenu.new(settings)
		add_child(menu)
		menu.visible = false
		menu.action.connect(_menu_action)
	menu.visible = not menu.visible
	aiming = false
	arc = {}
	if menu.visible:
		menu.place(camera.transform)
		menu.refresh()
	else:
		update_pointer()
		if not save_path.is_empty() and not VrSettings.save_file(settings, save_path):
			push_warning("VR settings: couldn't save " + save_path)


func _menu_action(key: String) -> void:
	if key == "calibrate":
		calibrate_height()


## A menu change takes effect now: the height, and the held items when the main hand changed sides.
func _settings_changed() -> void:
	place_height()
	if left_held != null:
		show_held(_held)
	if menu != null:
		menu.refresh()


## Where controller c's ray meets the open menu's plane, in menu space (z = 0), or null (menu closed, pointing
## away, past POINTER_MAX, or from behind the panel).
func pointer_at(c: XRController3D) -> Variant:
	if not menu_open() or not is_inside_tree():
		return null
	return ray_on_plane(menu.global_transform, c.global_position, -c.global_basis.z, POINTER_MAX)


## A ray (from, dir) on the plane z = 0 of `plane`, seen from its +Z side: the point in plane space, or null.
static func ray_on_plane(plane: Transform3D, from: Vector3, dir: Vector3, max_len: float) -> Variant:
	var inv := plane.affine_inverse()
	var o := inv * from
	var d := (inv.basis * dir).normalized()
	if not o.is_finite() or not d.is_finite() or o.z <= 0.0 or d.z > -0.001:
		return null
	var t := -o.z / d.z
	if t > max_len:
		return null
	var p := o + d * t
	p.z = 0.0
	return p


## The settings menu's laser pointer from the main hand: a ray to the panel with a dot where it meets it (a
## short ray when it misses), and the row under the dot picked. Hidden when the menu is closed. `all_hands`:
## draw it for a controller the runtime doesn't track (tests).
func update_pointer(all_hands := false) -> void:
	var c := main_ctrl()
	var on := menu_open() and is_inside_tree() and (all_hands or c.get_is_active())
	pointer.visible = on
	pointer_dot.visible = false
	if not on:
		if menu != null:
			menu.hover(null)
		return
	var p: Variant = pointer_at(c)
	var hit := p is Vector3 and VrMenu.on_panel(p)
	menu.hover(p if hit else null)
	var from := c.global_position
	var to: Vector3 = menu.global_transform * (p as Vector3) if hit else from - c.global_basis.z.normalized() * POINTER_LEN
	pointer.global_transform = _segment(from, to, POINTER_R)
	if hit:
		pointer_dot.global_position = to
		pointer_dot.visible = true


## A unit cylinder (radius 1, height 1 along Y) stretched from a to b with radius r.
static func _segment(a: Vector3, b: Vector3, r: float) -> Transform3D:
	var d := b - a
	var l := d.length()
	if l < 0.0001:
		return Transform3D(Basis.from_scale(Vector3.ZERO), a)
	var y := d / l
	var x := y.cross(Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).normalized()
	return Transform3D(Basis(x * r, y * l, x.cross(y) * r), (a + b) * 0.5)


## A controller button (signal, or tests). `pad`: the Vive trackpad position, read from the controller when
## not given.
func press(c: XRController3D, n: String, pad := Vector2.INF) -> void:
	if n == "grip_click":
		_grip_down[0 if c == left else 1] = true
	if c == left and n == "menu_button":
		toggle_menu()
		return
	if menu_open():
		if n == "trigger_click":
			# The main hand's trigger presses where its pointer meets the panel; off the panel (or the other
			# trigger) it changes the row the stick picked.
			var p: Variant = pointer_at(c) if c == main_ctrl() else null
			var changed := menu.click_at(p) if p is Vector3 and VrMenu.on_panel(p) else menu.click()
			if changed:
				_settings_changed()
		return
	if world.snapshot == null:
		return
	if c == main_ctrl() and n == "trigger_click":
		use_pointed_stair(c)
		return
	if n == "grip_click":
		var holds := hands != null and not hands.holding(hand_id(c)).is_empty()
		if holds and settings["grip"] == "toggle":
			let_go(c)
		elif not holds:
			grab_with(c)
		return
	if current_layout() == "vive":
		if c == right and n == "menu_button":
			change_level(1)
		elif n == "primary_click" and c == _move_ctrl():
			go_to_player(world.snapshot.player_pos)
		elif n == "primary_click":
			var v := _stick(c) if pad == Vector2.INF else pad
			if v.y < -0.5 and absf(v.y) > absf(v.x):
				change_level(-1)
		return
	match n:
		"by_button":
			if c == left:
				go_to_player(world.snapshot.player_pos)
			else:
				change_level(1)
		"ax_button":
			if c == right:
				change_level(-1)
		"secondary_click":   # WMR / Index trackpads
			if c == left:
				go_to_player(world.snapshot.player_pos)
			else:
				var v := c.get_vector2(&"secondary") if pad == Vector2.INF else pad
				change_level(1 if v.y >= 0.0 else -1)


## Live game: what the hands hold (CddaSim.get_held) on the controllers: CDDA's main hand on the main
## controller (right unless left-handed), the off hand on the other. A buzz in both hands when a fill ends.
func show_held(held: Dictionary) -> void:
	if left == null or right == null:
		return
	if left_held == null:
		left_held = VrHeld.new("Left")
		left.add_child(left_held)
		right_held = VrHeld.new("Right")
		right.add_child(right_held)
	_held = held
	var main_held := left_held if main_ctrl() == left else right_held
	var off_held := right_held if main_held == left_held else left_held
	var filling := str(held.get("activity", "")) == HandsPanel.FILL_ACTIVITY
	off_held.show_hand(held.get("off") if held.get("off") is Dictionary else {}, filling)
	main_held.show_hand(held.get("main") if held.get("main") is Dictionary else {}, filling)
	_sync_held()
	if _was_filling and not filling:
		_buzz(left)
		_buzz(right)
	_was_filling = filling


static func _buzz(c: XRController3D) -> void:
	if c.get_is_active():
		c.trigger_haptic_pulse(&"haptic", 0.0, 0.5, 0.08, 0.0)


func _update_visuals() -> void:
	if _vignette_node == null:
		return
	_vignette_node.visible = vignette > 0.01
	var r := lerpf(VIGNETTE_OPEN, VIGNETTE_SHUT, vignette)
	_vignette_node.scale = Vector3(r, r, 1.0)
	_fade_node.visible = _fade > 0.0
	_fade_mat.albedo_color.a = _fade
	_arc_mesh.clear_surfaces()
	var pts: PackedVector3Array = arc.get("points", PackedVector3Array())
	_marker.visible = aiming and arc.get("hit", false)
	if not aiming or pts.size() < 2:
		return
	var col := Color(0.3, 1.0, 0.4) if arc.get("valid", false) else Color(1.0, 0.3, 0.25)
	_arc_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _arc_mat)
	for i in pts.size():
		var along := pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]
		var side := along.cross(Vector3.UP).normalized() * 0.015
		_arc_mesh.surface_set_color(col)
		_arc_mesh.surface_add_vertex(pts[i] - side)
		_arc_mesh.surface_set_color(col)
		_arc_mesh.surface_add_vertex(pts[i] + side)
	_arc_mesh.surface_end()
	_marker.global_position = arc["pos"] + Vector3(0, 0.02, 0)
	(_marker.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color = col


## Unshaded, drawn over everything, both faces: overlays in front of the eyes.
static func _overlay_mat(col: Color, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.disable_fog = true
	m.albedo_color = col
	m.render_priority = priority
	return m


## A black annulus in front of the eyes: clear inside radius 1, black from radius 1.6 on (to 40). The node's
## x/y scale sets the hole's size.
func _make_vignette() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 48
	for ring: Array in [[1.0, 1.6, 0.0, 1.0], [1.6, 40.0, 1.0, 1.0]]:
		for i in segs:
			var a0 := TAU * i / segs
			var a1 := TAU * (i + 1) / segs
			var p := [Vector3(cos(a0), sin(a0), 0), Vector3(cos(a1), sin(a1), 0)]
			var quad := [[p[0] * ring[0], ring[2]], [p[1] * ring[0], ring[2]], [p[1] * ring[1], ring[3]],
					[p[0] * ring[0], ring[2]], [p[1] * ring[1], ring[3]], [p[0] * ring[1], ring[3]]]
			for v: Array in quad:
				st.set_color(Color(0, 0, 0, v[1]))
				st.add_vertex(v[0])
	var mat := _overlay_mat(Color.WHITE, 100)
	mat.vertex_color_use_as_albedo = true
	st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.name = "Vignette"
	mi.mesh = st.commit()
	mi.position = Vector3(0, 0, -VIGNETTE_DIST)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_fade() -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = 0.1
	s.height = 0.2
	_fade_mat = _overlay_mat(Color(0, 0, 0, 0), 101)
	s.material = _fade_mat
	var mi := MeshInstance3D.new()
	mi.name = "Fade"
	mi.mesh = s
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
