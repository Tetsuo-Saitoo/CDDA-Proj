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
## `save_path`), with a laser pointer from the main hand, and its Cheats and Test range pages (K7: `cheats_backend`,
## `cheats_allowed`; a refused cheat or range op buzzes the main hand; after a range teleport the head follows the
## player: follow_teleport). Hands (VrHand) show finger tracking when the runtime
## gives it, else fingers from the buttons; they are the only hands: the player's body hides its own and
## reaches its arms for their wrists (drive_body).
## Main hand (setting `main_hand`, right unless left-handed): its trigger uses pointed stairs (else it pulls, below),
## it aims the teleport arc and the menu pointer, and it shows CDDA's main hand; the compass sits on the off wrist,
## the HUD panel (VrHud, setting `wrist_hud`) on the inside of the off forearm.
## Seated play: the origin stands `height` over the level's floor (floor_y), so the head rises by it; the menu
## can set it from the head's height now ("Calibrate height").
## Hands (block L2): each controller is a hand of the shared Hands layer ("vr_l" / "vr_r"; `hands`, set by main.gd).
## What a free hand touches (a door leaf or an item in reach) is outlined; the grip (setting `grip`: hold, or toggle)
## grabs it. A door swings with the hand. An item is taken at once into CDDA's main hand (main controller) or off
## hand (the other), so it is carried while you walk; letting go puts it where the hand is (Hands.drop_at), or into
## the biggest worn container when the hand is over the shoulder. Grip on nothing picks up what CDDA already holds
## in that hand, ready to put down. CDDA decides every move; a refusal buzzes and shows its reason by the hand.
## Heavy items lag behind the hand; a two-handed one sags in one hand and sits between both when the other hand
## grips it too. Gripping near what the other hand holds (anything one hand carries) takes it over (Hands.hand_over:
## CDDA moves it to that hand; refused: it goes back). Letting go passes the hand's velocity on (Hands.release: with
## item physics on, the item falls and rolls from the hand).
## Point and pull (L2): an empty hand touching nothing, its trigger half pressed (PULL_TRIGGER), shows a
## faint ray; the item it meets in reach (Hands.find_on_ray: not a door leaf, and for the main hand not one lying on
## stairs) is outlined. The trigger click takes it into that hand like a grip (the same one-item take: CDDA judges
## reach) and its copy flies from where it lay into the hand over FLY_S, a buzz on arrival; a grip click lets it go.
## The main trigger uses pointed stairs first; nothing pointed at all: one buzz.
## Throw: an item let go with the hand faster than Hands.THROW_SPEED, at least THROW_FLAT_SPEED of it level (a
## slam down is a put down), not into the pack or over the shoulder, is thrown (Hands.throw) at the square where a
## flight from the hand at its velocity lands (track_hands, throw_square). A hand that isn't tracked has no speed.
## Guns (L2, VrGun `gun`): while CDDA wields a gun its model is in the main hand and takes the main trigger right after
## the pack (fires from its muzzle); the off grip takes its magazine out at the well or racks its slide / bolt, a held
## magazine brought to the well goes in; the main grip on nothing just holds it.
## Backpack (block L8, VrPack `pack`): grip with an empty hand over the shoulder while wearing a container takes
## the biggest one off (nothing worn: a buzz); letting go in front leaves it floating open there, one compartment
## per CDDA pocket. Looking costs nothing (no CDDA action). A free hand on an item in it holds that item
## (Hands.adopt) and lets it go the usual way; letting go of any held item over a compartment puts it into that
## pocket. Grip its frame or handle to carry it again; let go over the shoulder, or press the trigger with a hand
## on its frame (or holding it), to close it. It stays put in the world while you walk or teleport and closes
## itself past VrPack.CLOSE_M from the head or when the bag is gone.
## Cooking (block L9, VrCook `cook`, shows only): a card over each pot on a heat square near the head (heat, contents,
## CDDA's craft progress or the recipes its contents match; main.gd sets `cook.backend`).
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
var hud: VrHud            # HUD panel inside the off forearm (place_hud); main.gd sets its data
var panel: VrPanel        # L4: CDDA's 2D menus and prompts (main.gd puts them under panel.root); the laser works it
var pointer: MeshInstance3D       # the menu's laser pointer from the main hand (update_pointer) ...
var pointer_dot: MeshInstance3D   # ... and its dot on the panel
var _held := {}                   # the last show_held, shown again when the main hand changes
## K7: the menu's Cheats page talks to this (main.gd: the LiveSession; null in the mock) ...
var cheats_backend: Object:
	set(b):
		cheats_backend = b
		if menu != null:
			menu.cheats_backend = b
## ... and shows only when this is on (main.gd: --test / --cheats).
var cheats_allowed := false:   # main.gd sets it every frame from the F1 menu's gate: only a change refreshes
	set(v):
		if v == cheats_allowed:
			return
		cheats_allowed = v
		if menu != null:
			menu.cheats_allowed = v
			menu.refresh()
## K7 range teleports sent from the menu: op id -> the player's square when sent (null: no snapshot yet) ...
var _teleports := {}
## ... and after one came back done: where the player stood, and seconds left to see them moved (< 0: not waiting).
var _follow_from: Variant = null
var _follow_s := -1.0
const FOLLOW_WAIT_S := 5.0   # no move seen by then (a teleport to where they stood): go to the player anyway
const MAX_TELEPORTS := 8

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
const PULL_TRIGGER := 0.15 # a trigger past this points an empty hand's pull ray (not a mere touch: a finger
                           # rests on Quest / Index triggers most of the time)
const PULL_RAY_S := 0.05   # the pull ray looks again at most this often (each look casts two look rays)
const FLY_S := 0.2         # a pulled item's copy flies into the hand in this long
const THROW_MAX_M := 20.0  # a throw's square is at most this far (CDDA's range, aim and rules still decide)
const VEL_RATE := 25.0     # 1/s: hand speed smoothing (about the last 40 ms)
const MAX_HAND_SPEED := 15.0   # m/s: a faster reading is a tracking jump, not a throw
const THROW_FLAT_SPEED := 1.5  # m/s: a throw needs at least this much level speed (else a slam down: put down)
const HAND_OVER_M := 0.2       # a grip this near the other hand's item's grip point takes it over
const GRAVITY := 9.8

## The shared hands (main.gd); null: the controllers grab nothing.
var hands: Hands:
	set(h):
		if is_instance_valid(hands) and hands.refused.is_connected(_on_refused):
			hands.refused.disconnect(_on_refused)
		hands = h
		if h != null and not h.refused.is_connected(_on_refused):
			h.refused.connect(_on_refused)
		if pack != null:
			pack.hands = h
var pack: VrPack           # L8: the worn bag opened in front of the player (built in _build)
var gun: VrGun             # L2: the wielded gun in the main hand (built in _build; main.gd wires it)
var cook: VrCook           # L9: cards over pots on the heat near the head (built in _build)
var strength := STRENGTH   # how much a hand carries without lag (ItemRef.two_handed's rule)
var notes: Array[Label3D] = [null, null]   # CDDA's reason for a refusal, by the left / right hand
var buzzes: Array[int] = [0, 0]            # haptic pulses asked of each hand (tests count them)
var buzz_amp: Array[float] = [0.0, 0.0]    # the strength of each hand's last pulse (tests)
var hand_vel: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]   # each hand's smoothed velocity (world; walking and
                                                              # turning the rig don't count): track_hands
var _hand_was: Array = [null, null]        # each controller's last position in the rig's space
## Tests: controllers count as tracked though inactive (no XR runtime); else a controller is tracked while active
## with tracking data (track_hands).
var assume_tracked := false
var _note_left: Array[float] = [0.0, 0.0]
var _grip_down: Array[bool] = [false, false]   # the grip button is held (two-handed support uses it)
var pull_rays: Array[MeshInstance3D] = []      # each hand's faint pull ray (left, right)
## Tests: each controller's trigger value as if read from it (< 0: read the controller).
var trigger_in: Array[float] = [-1.0, -1.0]
var _pointed: Array[Dictionary] = [{}, {}]     # the item each hand's pull ray met at its last look
var _ray_wait: Array[float] = [0.0, 0.0]       # seconds to the next look
var _fly_from: Array[Transform3D] = [Transform3D(), Transform3D()]   # where a pulled copy lay
var _fly_t: Array[float] = [-1.0, -1.0]        # seconds into its flight; < 0: none


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
	hud = VrHud.new()
	add_child(hud)
	hud.alerted.connect(func() -> void: _feel(off_ctrl()))   # a new bad warning: a buzz in the HUD's hand
	panel = VrPanel.new()
	add_child(panel)
	pack = VrPack.new()
	pack.head = camera
	pack.ids.assign(HAND_IDS)
	add_child(pack)
	cook = VrCook.new()
	cook.world = world
	cook.head = camera
	add_child(cook)
	gun = VrGun.new()
	gun.rig = self
	add_child(gun)
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
	var faint := _overlay_mat(Color(0.45, 0.8, 1.0, 0.3), 90)   # the pointer's look, fainter, hidden by walls
	faint.no_depth_test = false
	for side: String in ["Left", "Right"]:
		var ray := MeshInstance3D.new()
		ray.name = "PullRay" + side
		ray.mesh = rod
		ray.material_override = faint
		pull_rays.append(ray)
	for n: MeshInstance3D in [pointer, pointer_dot, pull_rays[0], pull_rays[1]]:
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
	panel.update(delta, camera.transform)
	step(delta, inp)
	update_pointer()
	track_hands(delta)
	update_hands(delta)
	gun.update(delta)
	pose_hands()
	drive_body()
	place_compass()
	place_hud(delta)
	cook.update(delta)   # looks for pots every VrCook.TICK_S, turns the cards every frame
	follow_teleport(delta)


## The HUD panel inside the off forearm (setting `wrist_hud`): shows while turned to the eyes.
func place_hud(delta: float) -> void:
	hud.enabled = settings["wrist_hud"] == "on"
	hud.place(self, delta)


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
## weight (follow_rate, sag, two_hand_pose), a pulled one flies in first (_fly); a free hand outlines what it could
## grip, else with its trigger half pressed what its pull ray points at. CDDA's own hand display (VrHeld) hides while
## that hand holds a copy. `all_hands`: count hands the runtime doesn't track (tests).
func update_hands(delta: float, all_hands := false) -> void:
	_tick_notes(delta)
	if hands == null:
		pack.close("gone")
		for i in 2:
			_show_pull_ray(i, {})
		return
	pack.update()
	var drawn: Array = [null, null]   # where each held item was drawn last frame
	for i in 2:
		var id: String = HAND_IDS[i]
		var p := hands.proxy(id)
		if p != null:
			drawn[i] = p.global_transform
		hands.set_hand_pose(id, _ctrl(i).global_transform, true)
	if pack.hand >= 0:
		pack.follow(_ctrl(pack.hand).global_transform)
	for i in 2:
		var c := _ctrl(i)
		var id: String = HAND_IDS[i]
		var held := hands.holding(id)
		if held.is_empty():
			_fly_t[i] = -1.0
			var t := {}
			var pt := {}   # the open pack goes first, then what the hand touches, then what its pull ray meets
			var pointing := false
			if pack.hand != i and (all_hands or c.get_is_active()) and world.snapshot != null and not ui_open() \
					and not _supports(i, drawn[1 - i]):
				pt = pack.target_at(c.global_position)
				if pt.is_empty():
					t = hands.find_near(c.global_position, GRAB_REACH)
				# (a finger resting on a gun's trigger points nothing)
				pointing = pt.is_empty() and t.is_empty() and trigger_half(i) and not _gun_hand(i)
				if pointing:
					t = _point(i, c, delta)
			if not pointing:   # the next pointing looks at once
				_pointed[i] = {}
				_ray_wait[i] = 0.0
			pack.hover(i, pt)
			hands.hover(id, t)
			_show_pull_ray(i, t if pointing else {})
			continue
		hands.hover(id, {})   # a held door stays lit; it lights again as a hover after it is let go
		_show_pull_ray(i, {})
		_pointed[i] = {}
		_ray_wait[i] = 0.0
		pack.show_drop(i, c.global_position if held.get("kind") == "item" else Vector3.INF)
		if held.get("kind") == "door":
			var n: Variant = held.get("node")   # untyped: a leaf can be freed under a hand (D5)
			if is_instance_valid(n):
				(n as Grabbable).drag_hand(c.global_position)
			else:
				hands.cancel(id)
		elif _fly_t[i] >= 0.0:
			_fly(i, delta)
		elif drawn[i] is Transform3D:
			_weigh(i, drawn[i], delta)
	_sync_held()


## Hand i is the main hand and a gun shows in it (VrGun).
func _gun_hand(i: int) -> bool:
	return gun.shown and _ctrl(i) == main_ctrl()


## Controller c's grip button is held.
func grip_down(c: XRController3D) -> bool:
	return _grip_down[0 if c == left else 1]


## Controller i's trigger is pressed past PULL_TRIGGER (trigger_in in tests).
func trigger_half(i: int) -> bool:
	if trigger_in[i] >= 0.0:
		return trigger_in[i] > PULL_TRIGGER
	var c := _ctrl(i)
	return c.get_is_active() and c.get_float(&"trigger") > PULL_TRIGGER


## The item controller c's ray meets in reach (Hands.find_on_ray), {} for none: a door leaf in front of it hides it,
## and the main hand points at no item lying on stairs (its trigger uses the stairs).
func pointed_item(c: XRController3D) -> Dictionary:
	if hands == null or world.snapshot == null:
		return {}
	var from := c.global_position
	var dir := -c.global_basis.z
	if not from.is_finite() or not dir.is_finite() or dir.length() < 0.001:
		return {}
	var t := hands.find_on_ray(from, dir.normalized(), Hands.RAY_M)
	if t.get("kind") != "item" or not t.get("item") is ItemRef or not t.get("square") is Vector3i:
		return {}
	if c == main_ctrl() and not StairUse.find(world, t["square"], z).is_empty():
		return {}
	return t


## Hand i's pull ray this frame: what pointed_item found, looked for again every PULL_RAY_S, not every frame.
func _point(i: int, c: XRController3D, delta: float) -> Dictionary:
	_ray_wait[i] -= clampf(delta, 0.0, 1.0)
	if _ray_wait[i] <= 0.0:
		_ray_wait[i] = PULL_RAY_S
		_pointed[i] = pointed_item(c)
	return _pointed[i]


## Hand i's faint ray to the item it points at (target t), hidden for {}.
func _show_pull_ray(i: int, t: Dictionary) -> void:
	var r := pull_rays[i]
	var to: Variant = t.get("point")
	r.visible = to is Vector3 and (to as Vector3).is_finite() and is_inside_tree()
	if r.visible:
		r.global_transform = _segment(_ctrl(i).global_position, to, POINTER_R)


## Trigger on controller c with an empty hand touching nothing: the item it points at (pointed_item, looked for
## now) is taken at once into that hand like a grip (main controller: CDDA's main hand, the other: the off hand), and
## its copy flies from where it lay into the hand (_fly). False when nothing is pointed (the caller buzzes); a refusal
## from CDDA comes through Hands.refused (a buzz and its reason, the hand empty again, no flight).
func pull_with(c: XRController3D) -> bool:
	if hands == null or world.snapshot == null or ui_open():
		return false
	var i := 0 if c == left else 1
	var id: String = HAND_IDS[i]
	if not hands.holding(id).is_empty() or pack.hand == i or not pack.target_at(c.global_position).is_empty() \
			or not hands.find_near(c.global_position, GRAB_REACH).is_empty():
		return false
	var other := hands.proxy(HAND_IDS[1 - i])
	if other != null and _supports(i, other.global_transform):
		return false
	var t := pointed_item(c)
	if t.is_empty():
		return false
	var slot := hands.picker.slot((t["item"] as ItemRef).uid)   # where it lies drawn or as a body (gone once held)
	hands.set_hand_pose(id, c.global_transform, true)
	if not hands.grab(id, t, "main" if c == main_ctrl() else "off"):
		return false
	_show_pull_ray(i, {})
	var p := hands.proxy(id)   # null when CDDA refused inside the call
	if p == null:
		return true
	var from := Transform3D(p.global_basis.orthonormalized(), p.global_position)
	if slot.size() > 4 and slot[4] is Transform3D and (slot[4] as Transform3D).is_finite():
		var xf: Transform3D = slot[4]   # the copy starts as the item was drawn, turned the same way
		from = Transform3D(Basis(xf.basis.get_rotation_quaternion()), xf.origin)
		hands.set_proxy_pose(id, from)
	if from.is_finite():
		_fly_from[i] = from
		_fly_t[i] = 0.0
	return true


## One frame of a pulled copy's flight: from where it lay (_fly_from) into the hand (where Hands put it this frame)
## over FLY_S, fast off the ground and slowing in; a buzz when it arrives, then it follows by weight (_weigh).
func _fly(i: int, delta: float) -> void:
	var id: String = HAND_IDS[i]
	var p := hands.proxy(id)
	if p == null:
		_fly_t[i] = -1.0
		return
	_fly_t[i] += clampf(delta, 0.0, 1.0)
	if _fly_t[i] >= FLY_S:
		_fly_t[i] = -1.0
		_feel(_ctrl(i))
		return
	var k := 1.0 - pow(1.0 - _fly_t[i] / FLY_S, 2.0)
	var to := p.global_transform
	hands.set_proxy_pose(id, _fly_from[i].interpolate_with(Transform3D(to.basis.orthonormalized(), to.origin), k))


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
		hands.set_proxy_pose(id, two_hand_pose(m.global_position, f.global_position, c.global_basis.y,
				ItemVisual.grip(it.type, world), Vector3.ONE))
		return
	var to := p.global_transform   # where Hands put it: held rigidly by its grip
	if both:
		to = sag(to, c.global_transform, SAG_RAD)
	hands.set_proxy_pose(id, ease_toward(from, to, follow_rate(it.weight_g(world.tables), strength, both), delta,
			Vector3.ONE))   # Hands keeps the copy's own scale


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


## Grip on controller c: an item or the frame of the open pack (VrPack.grip), else the door leaf or item it
## touches, else over the shoulder the biggest worn container (taken off: VrPack.open_in), else what CDDA holds in
## that hand (main controller: the wielded item; the other: the off-hand item). An item lying in the world is
## taken at once into that hand. Near the other hand's two-handed item it only steadies it; touching nothing else
## near another item the other hand holds, it takes it over (takes_over, Hands.hand_over: CDDA moves it to this
## hand). False (and a buzz) when there is nothing to grab; a refusal from CDDA comes later through Hands.refused.
func grab_with(c: XRController3D) -> bool:
	if hands == null:
		return false
	var i := 0 if c == left else 1
	var id: String = HAND_IDS[i]
	if not hands.holding(id).is_empty() or pack.hand == i:
		return false
	var other := hands.proxy(HAND_IDS[1 - i])
	if other != null and _supports(i, other.global_transform):
		return true
	var t := {}
	var pt := {}
	var looks := world.snapshot != null and not menu_open()
	if looks:
		pt = pack.target_at(c.global_position)
		if pt.is_empty():
			t = hands.find_near(c.global_position, GRAB_REACH)
	# touching nothing else, the gun not in this hand (its grip just holds the gun) and the shoulder not reached: the other
	if pt.is_empty() and t.is_empty() and other != null and not _gun_hand(i) and takes_over(i) \
			and not (looks and over_shoulder(camera.global_transform, c.global_position)):
		var ok_over := hands.hand_over(HAND_IDS[1 - i], id, "main" if c == main_ctrl() else "off")   # hand's item
		if ok_over:
			hands.set_hand_pose(id, c.global_transform, true)
		else:
			_feel(c)
		return ok_over
	hands.set_hand_pose(id, c.global_transform, true)   # a door starts its swing here, an adopted item shows here
	var ok := false
	if not pt.is_empty():
		ok = pack.grip(i, pt)
	elif t.is_empty() and looks and not pack.is_open() and over_shoulder(camera.global_transform, c.global_position):
		var bag := shoulder_bag(hands.picker.worn_containers(), null, world.tables)
		ok = bag != null and pack.open_in(i, bag)
	elif t.is_empty() and _gun_hand(i):
		ok = true   # the gun is in that hand already (VrGun): squeezing the grip holds it
	elif t.is_empty():
		var it := cdda_holds(c)
		ok = it != null and hands.adopt(id, it)
	elif t["kind"] == "item":
		ok = hands.grab(id, t, "main" if c == main_ctrl() else "off")
	else:
		ok = hands.grab(id, t)
	if not ok:
		_feel(c)
	return ok


## Hand i (empty) grips near the item the other hand holds: within HAND_OVER_M of its grip point.
func takes_over(i: int) -> bool:
	var o: String = HAND_IDS[1 - i]
	var p: Node3D = hands.proxy(o) if hands != null else null
	var it: ItemRef = hands.holding(o).get("item") if p != null else null
	if it == null or hands.holding(o).get("kind") != "item" or not hands.holding(HAND_IDS[i]).is_empty():
		return false
	var xf := p.global_transform
	var s := maxf(absf(xf.basis.get_scale().x), 0.001)
	var g := xf * (ItemVisual.grip(it.type, world).origin / s)
	return g.is_finite() and _ctrl(i).global_position.distance_to(g) <= HAND_OVER_M


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


## Lets go of what hand c holds. The pack: over the shoulder it closes, elsewhere it floats open in front (nothing
## sent). An item: over a compartment of the open pack into that pocket (its own pocket: back, nothing sent), over
## the shoulder into the biggest worn container (none: a buzz, and it goes where the hand is), else where the hand
## is (Hands.drop_at; nowhere it can go: it stays in CDDA's hand), with the hand's velocity (item physics). A door
## settles. `throw_ok` false: never a throw (a magazine let go in a moving hand). Returns Hands.release's action
## ("" when nothing was sent).
func let_go(c: XRController3D, throw_ok := true) -> String:
	if hands == null:
		return ""
	var id := hand_id(c)
	if pack.hand == (0 if c == left else 1):
		pack.let_go(over_shoulder(camera.global_transform, c.global_position), c.global_position)
		return ""
	var held := hands.holding(id)
	if held.is_empty():
		return ""
	var it: ItemRef = held.get("item")
	if held.get("kind") != "item" or it == null or world.snapshot == null:
		return hands.release(id, {})
	var drop := pack.drop_for(c.global_position, it)
	var shoulder := over_shoulder(camera.global_transform, c.global_position)
	if drop.is_empty() and not shoulder and throw_ok:
		var sq: Variant = throw_square(c)
		if sq is Vector3i:
			return hands.throw(id, sq)   # CDDA throws it (a lying item is taken first); refused: back where it was
	if drop.is_empty() and shoulder:
		var bag := shoulder_bag(hands.picker.worn_containers(), it, world.tables)
		if bag != null:
			drop = {"kind": "container", "container": bag}
		else:
			_feel(c)
	if drop.is_empty():
		drop = hands.drop_at(c.global_position, it)
	var v: Vector3 = hand_vel[0 if c == left else 1]
	return hands.release(id, drop, v if v.is_finite() else Vector3.ZERO)


func release(c: XRController3D, n: String) -> void:
	if n != "grip_click":
		panel_button(c, n, false)   # a release always reaches the panel (a no-op when nothing there is held)
		return
	_grip_down[0 if c == left else 1] = false
	if gun.release(c):
		return   # the end of a rack (VrGun)
	if settings["grip"] != "toggle":   # toggle: the next press lets go
		let_go(c)


## A button for the CDDA panel (`down`: pressed, else released); true if the panel takes it. The main trigger is the
## laser's left button (a press off the panel buzzes); the other trigger, A / X and a Vive pad click are ui_accept;
## B / Y and the right Vive menu are ui_cancel. Grips and the left menu button stay as they are.
func panel_button(c: XRController3D, n: String, down: bool) -> bool:
	var a: StringName = &""
	match n:
		"trigger_click":
			if c == main_ctrl():
				if not down:
					panel.release()
				elif not panel.press():
					_feel(c)
				return true
			a = &"ui_accept"
		"ax_button":
			a = &"ui_accept"
		"by_button":
			a = &"ui_cancel"
		"primary_click":
			if current_layout() == "vive":
				a = &"ui_accept"
		"menu_button":
			if c == right:
				a = &"ui_cancel"
	if a == &"":
		return false
	panel.action(a, down)
	return true


## Each hand's velocity (hand_vel) from its moves in the rig's space, smoothed over VEL_RATE, turned to world. A
## reading faster than MAX_HAND_SPEED (lost tracking coming back) counts as standing still; a controller that isn't
## tracked (inactive, or no tracking data) has no speed and starts afresh once tracked again.
func track_hands(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	for i in 2:
		if not tracked(i):
			_hand_was[i] = null
			hand_vel[i] = Vector3.ZERO
			continue
		var p := _ctrl(i).position
		var was: Variant = _hand_was[i]
		_hand_was[i] = p if p.is_finite() else null
		var v := Vector3.ZERO
		if was is Vector3 and p.is_finite():
			v = global_basis * ((p - (was as Vector3)) / delta)
			if not v.is_finite() or v.length() > MAX_HAND_SPEED:
				v = Vector3.ZERO
		hand_vel[i] = hand_vel[i].lerp(v, clampf(VEL_RATE * delta, 0.0, 1.0))


## Controller i gives a pose to trust: active with tracking data (or `assume_tracked`, tests).
func tracked(i: int) -> bool:
	if assume_tracked:
		return true
	var c := _ctrl(i)
	return c.get_is_active() and c.get_has_tracking_data()


## Where a throw from `from` at `vel` (world, m/s) lands on a floor at height floor_y: a flight without drag, its
## flat distance at most THROW_MAX_M (floor_y's height, Vector3); null when it goes nowhere (straight up or down).
static func throw_point(from: Vector3, vel: Vector3, floor_y: float) -> Variant:
	if not from.is_finite() or not vel.is_finite() or not is_finite(floor_y):
		return null
	var flat := Vector3(vel.x, 0.0, vel.z)
	var speed := flat.length()
	if speed < 0.01:
		return null
	var h := maxf(from.y - floor_y, 0.0)
	var t := (vel.y + sqrt(vel.y * vel.y + 2.0 * GRAVITY * h)) / GRAVITY
	var p := from + flat / speed * minf(speed * t, THROW_MAX_M)
	return Vector3(p.x, floor_y, p.z)


## The square controller c's item is thrown at when let go now: faster than Hands.THROW_SPEED with at least
## THROW_FLAT_SPEED level, where its flight lands on the player's level (on the player's own square: the next one
## along the throw). null: not a throw.
func throw_square(c: XRController3D) -> Variant:
	var v: Vector3 = hand_vel[0 if c == left else 1]
	var s := world.snapshot
	if s == null or not (v.length() > Hands.THROW_SPEED) or not (Vector2(v.x, v.z).length() >= THROW_FLAT_SPEED):
		return null
	var at: Variant = throw_point(c.global_position, v, world.coords.ms_to_world(s.player_pos).y)
	if not at is Vector3:
		return null
	var sq := world.coords.world_to_ms(at as Vector3)
	sq.z = s.player_pos.z
	if sq == s.player_pos:
		var step := world.coords.world_to_ms(world.coords.ms_center_to_world(s.player_pos)
				+ Vector3(v.x, 0.0, v.z).normalized()) - s.player_pos
		sq = s.player_pos + Vector3i(step.x, step.y, 0)
	return sq if sq != s.player_pos else null


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


## main.gd turned down something the main hand asked for (a stair use while the last move is still going): a
## buzz in that hand and the reason by it.
func refused_here(reason: String) -> void:
	var i := 0 if main_ctrl() == left else 1
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
	feel(c)


## A buzz in controller c of `amplitude` (0..1) for `seconds`, counted (buzzes, buzz_amp).
func feel(c: XRController3D, amplitude := 0.5, seconds := 0.08) -> void:
	var i := 0 if c == left else 1
	buzzes[i] += 1
	buzz_amp[i] = amplitude
	if c.get_is_active():
		c.trigger_haptic_pulse(&"haptic", 0.0, clampf(amplitude, 0.0, 1.0), maxf(seconds, 0.0), 0.0)


## VrHeld (CDDA's hands, show_held) shows on a controller unless that hand holds the item's copy or the gun (it
## would show twice).
func _sync_held() -> void:
	if left_held == null:
		return
	for i in 2:
		var node: VrHeld = left_held if i == 0 else right_held
		var h: Variant = _held.get("main" if _ctrl(i) == main_ctrl() else "off")
		node.visible = h is Dictionary and not (h as Dictionary).is_empty() \
				and (hands == null or hands.proxy(HAND_IDS[i]) == null) and not _gun_hand(i)


## The same, now (VrGun when its gun shows or goes).
func sync_held() -> void:
	_sync_held()


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
	elif panel.shown:   # a CDDA menu or prompt: the sticks pick in it, no moving
		panel.nav(inp.get("move", Vector2.ZERO), inp.get("turn", Vector2.ZERO), delta)
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


## The map's origin moved (CddaCoords.origin_shifted): the rig and what it keeps in world space move with it (the
## open pack is top_level; a pulled copy's start).
func shift(d: Vector3) -> void:
	if not d.is_finite():
		return
	position += d
	if pack != null and is_instance_valid(pack):
		pack.position += d
	for i in _fly_from.size():
		_fly_from[i].origin += d


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


## Stairs: in the mock (live_stairs false) the rig goes to the level they lead to; a live game moves the ghost
## when the player's level changes.
var live_stairs := false

## The stairs controller c points at (StairUse.find's dictionary), {} for none.
func pointed_stair(c: XRController3D) -> Dictionary:
	var r := LookRay.new(world).cast(c.global_position, -c.global_basis.z)
	return StairUse.find(world, r["square"], z) if r["hit"] else {}


## Uses stairs `s` (pointed_stair) from controller c and emits stair_used; in the mock with no free square at the
## other end: a buzz and false.
func use_stair(c: XRController3D, s: Dictionary) -> bool:
	if not live_stairs:
		var to: Variant = walk.nearest_standable(s["to"])
		if to == null:
			_feel(c)
			return false
		go_to_square(to)
	stair_used.emit(s)
	return true


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


## The settings menu or a CDDA menu / prompt (panel) is up: the triggers and sticks work it, not the world.
func ui_open() -> bool:
	return menu_open() or (panel != null and panel.shown)


## Opens the settings menu in front of the head, or closes it and saves the settings.
func toggle_menu() -> void:
	if menu == null:
		menu = VrMenu.new(settings)
		add_child(menu)
		menu.visible = false
		menu.action.connect(_menu_action)
		menu.cheats_backend = cheats_backend
		menu.cheats_allowed = cheats_allowed
		menu.cheat_refused.connect(func(_why: String) -> void: _feel(main_ctrl()))   # the reason shows on the page
		menu.range_sent.connect(_on_range_sent)
		menu.range_finished.connect(_on_range_finished)
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


## The menu sent a range op: a teleport remembers where the player stands now.
func _on_range_sent(op_id: int, key: String) -> void:
	if not VrRange.is_teleport(key):
		return
	if _teleports.size() >= MAX_TELEPORTS:
		_teleports.erase(_teleports.keys()[0])
	_teleports[op_id] = world.snapshot.player_pos if world.snapshot != null else null


## A range op from the menu came back: a teleport done starts the follow.
func _on_range_finished(op_id: int, _key: String, error: String) -> void:
	if not _teleports.has(op_id):
		return
	var from: Variant = _teleports[op_id]
	_teleports.erase(op_id)
	if error.is_empty():
		_follow_from = from
		_follow_s = FOLLOW_WAIT_S
		follow_teleport(0.0)


## K7: after a range teleport came back done, the head goes to the player once (go_to_player) as soon as a shown
## snapshot has them off the square they stood on when it was sent (the snapshot may come before or after the
## op's result), or, none by FOLLOW_WAIT_S, to wherever the player is then. Every frame (_process).
func follow_teleport(delta: float) -> void:
	if _follow_s < 0.0:
		return
	_follow_s -= delta
	var s := world.snapshot
	if s == null:
		return
	if _follow_s >= 0.0 and _follow_from is Vector3i and s.player_pos == _follow_from:
		return
	_follow_s = -1.0
	go_to_player(s.player_pos)


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
	var live := is_inside_tree() and (all_hands or c.get_is_active()) and c.global_transform.is_finite()
	var on_menu := menu_open() and live
	var on_panel := not menu_open() and panel.shown and live
	pointer.visible = on_menu or on_panel
	pointer_dot.visible = false
	if menu != null and not on_menu:
		menu.hover(null)
	if not on_panel:
		panel.point(null)
	if not pointer.visible:
		return
	var plane := menu.global_transform if on_menu else panel.global_transform
	var p: Variant = pointer_at(c) if on_menu 			else ray_on_plane(plane, c.global_position, -c.global_basis.z, POINTER_MAX)
	var hit := menu.covers(p) if on_menu else VrPanel.covers(p)
	if on_menu:
		menu.hover(p if hit else null)
	else:
		panel.point(p)
	var from := c.global_position
	var to: Vector3 = plane * (p as Vector3) if hit else from - c.global_basis.z.normalized() * POINTER_LEN
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
			var changed := menu.click_at(p) if menu.covers(p) else menu.click()
			if changed:
				_settings_changed()
		return
	if panel.shown and panel_button(c, n, true):
		return
	if world.snapshot == null:
		return
	var ci := 0 if c == left else 1
	if n == "trigger_click" and pack.is_open() \
			and (pack.hand == ci or pack.target_at(c.global_position).get("kind") == "frame"):
		pack.close("closed")   # the trigger on the pack's frame (or holding it) closes it
		return
	if n == "trigger_click" and c == main_ctrl() and gun.trigger():
		return   # a gun in the main hand fires (VrGun)
	if n == "trigger_click":   # main hand: pointed stairs first; both hands: the pull; nothing pointed: one buzz
		var s := pointed_stair(c) if c == main_ctrl() else {}
		if not s.is_empty():
			use_stair(c, s)
		elif not pull_with(c):
			_feel(c)
		return
	if n == "grip_click":
		var holds := hands != null and (not hands.holding(hand_id(c)).is_empty() or pack.hand == ci)
		if holds and settings["grip"] == "toggle":
			let_go(c)
		elif not holds and not gun.grip(c):   # the off hand on the gun's magazine or slide first
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
