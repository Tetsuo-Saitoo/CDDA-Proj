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
## `save_path`). Hands (VrHand) show finger tracking when the runtime gives it, else fingers from the buttons;
## they are the only hands: the player's body hides its own and reaches its arms for their wrists (drive_body).
## Grip near a door (Grabbable, outlined when in reach) grabs it; it swings with the hand (block L2).
## A tunnel vignette darkens the edges while moving or turning smoothly; a blink hides jumps.
## Nothing here talks to the sim: the viewer is a ghost beside the player's body (VR-ready rule: the camera
## rig is separate from the body).

signal level_changed(z: int)
## The right trigger pointed at stairs (StairUse.find's dictionary). In a live game main.gd queues CDDA's actions.
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
const GRAB_REACH := 0.12  # metres from a hand to a door leaf it can grip
var grab_ok := Callable() # square -> bool: may a hand open the door there (live: next to the player)
var grabs: Array = [null, null]   # Grabbable held by the left / right hand
var near: Array = [null, null]    # Grabbable each hand could grip (outlined)
var _lit: Array = []


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
	update_grabs()
	pose_hands()
	drive_body()
	place_compass()


## The compass on the left wrist and/or the belt (settings `compass`); main.gd feeds its blips.
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


## Held doors follow their hand; free hands outline the door they could grip. `all_hands`: count hands the
## runtime doesn't track (tests).
func update_grabs(all_hands := false) -> void:
	for i in 2:
		var c: XRController3D = left if i == 0 else right
		var g: Grabbable = grabs[i]
		if g != null and not is_instance_valid(g):
			grabs[i] = null
			g = null
		if g != null:
			g.drag_hand(c.global_position)
			near[i] = g
		elif (all_hands or c.get_is_active()) and world.snapshot != null and not menu_open():
			near[i] = world.grabbable_near(c.global_position, GRAB_REACH, grab_ok)
		else:
			near[i] = null
	for g: Grabbable in _lit:
		if is_instance_valid(g) and g not in near:
			g.set_highlight(false)
	_lit = near.filter(func(g: Variant) -> bool: return g != null)
	for g: Grabbable in _lit:
		g.set_highlight(true)


func release(c: XRController3D, n: String) -> void:
	var i := 0 if c == left else 1
	if n == "grip_click" and grabs[i] != null:
		if is_instance_valid(grabs[i]):
			grabs[i].end_grab()
		grabs[i] = null


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
		menu.nav(inp.get("move", Vector2.ZERO))
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
	arc = walk.teleport_arc(right.global_position, -right.global_basis.z, z)
	if tv.y < AIM_OFF:
		aiming = false
		if arc.get("valid", false):
			teleport_to(arc["pos"])
		else:
			_buzz(right)
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
	global_position.y = VrWalk.floor_y(z)
	teleport_to(world.coords.ms_center_to_world(sq))
	level_changed.emit(z)


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
	menu.visible = not menu.visible
	aiming = false
	arc = {}
	if menu.visible:
		menu.place(camera.transform)
		menu.refresh()
	elif not save_path.is_empty() and not VrSettings.save_file(settings, save_path):
		push_warning("VR settings: couldn't save " + save_path)


## A controller button (signal, or tests). `pad`: the Vive trackpad position, read from the controller when
## not given.
func press(c: XRController3D, n: String, pad := Vector2.INF) -> void:
	if c == left and n == "menu_button":
		toggle_menu()
		return
	if menu_open():
		if n == "trigger_click":
			menu.click()
		return
	if world.snapshot == null:
		return
	if c == right and n == "trigger_click":
		use_pointed_stair(c)
		return
	var hand := 0 if c == left else 1
	if n == "grip_click" and near[hand] != null and is_instance_valid(near[hand]):
		grabs[hand] = near[hand]
		grabs[hand].begin_hand(c.global_position)
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


## Live game: what the hands hold (CddaSim.get_held) on the controllers, left = off hand, right = main hand.
## A buzz in both hands when a fill ends.
func show_held(held: Dictionary) -> void:
	if left == null or right == null:
		return
	if left_held == null:
		left_held = VrHeld.new("Left")
		left.add_child(left_held)
		right_held = VrHeld.new("Right")
		right.add_child(right_held)
	var filling := str(held.get("activity", "")) == HandsPanel.FILL_ACTIVITY
	left_held.show_hand(held.get("off") if held.get("off") is Dictionary else {}, filling)
	right_held.show_hand(held.get("main") if held.get("main") is Dictionary else {}, filling)
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
