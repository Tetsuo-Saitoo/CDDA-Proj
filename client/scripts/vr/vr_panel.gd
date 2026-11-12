class_name VrPanel
extends Node3D
## L4 (with lead-ui's G1): the world-space panel for CDDA's 2D menus and prompts in the headset (RequestUI, later
## the main menu, chargen, the F1 menu and the Tab view). main.gd puts those Controls under `root`, a full-rect
## Control inside `viewport`, a SubViewport of PX logical pixels (rendered at SUPERSAMPLE for sharp text), drawn on
## a quad of SIZE_M. Lay out from `get_viewport().get_visible_rect()` (PX), never the window or the OS mouse.
## It shows while any direct child of `root` is visible and hides otherwise (`shown_changed`; the rig calls
## `update` every frame). World-locked: placed in front of the head when it shows, and again once it has been out
## of view for AWAY_S.
## Input, from the rig, pushed into `viewport` in its logical pixels (nothing reaches the 2D window):
## - the main hand's laser: `point` (InputEventMouseMotion, button mask LEFT while the trigger holds), `press` and
##   `release` (the left mouse button; a press only on the panel, its release always, even off the panel);
## - the sticks: `nav` (ui_up / ui_down / ui_left / ui_right, pressed and released, repeating while held; the main
##   stick's up / down scrolls the wheel where the laser points instead);
## - buttons: `action` (ui_accept / ui_cancel, press and release as the button goes).
## Hiding lets go of everything still held (the mouse button, any ui_* action).
## Text: 1 logical px is SIZE_M.x / PX.x = 1.1 mm at DIST 1.2 m, so body text wants 20 px or more (about 1 degree).

signal shown_changed(on: bool)

const PX := Vector2i(1280, 800)        # logical pixels: what root lays out to
const SUPERSAMPLE := 1.5               # the texture is PX * this
const SIZE_M := Vector2(1.4, 0.875)    # the quad, PX's aspect: about 60 degrees wide at DIST
const DIST := 1.2                      # metres in front of the head
const DROP := 0.1                      # metres below the eyes
const AWAY_S := 1.0                    # out of view this long: placed in front again
const AWAY_DEG := 50.0                 # "out of view": the panel this far off the head's forward
const ON := 0.7                        # a stick past this fires ...
const OFF := 0.3                       # ... and back inside this arms the next one
const REPEAT_DELAY_S := 0.45           # a stick held past ON repeats after this ...
const REPEAT_S := 0.12                 # ... every this
const PRIORITY := 105                  # drawn over the world, under the settings menu (110, 111) and the pointer (112)
const MAX_PX := 100000.0               # a laser point farther off than this is ignored (bad pose)

var viewport: SubViewport
var root: Control
var shown := false
## The logical pixel the laser is on, or null (off the panel or not pointing at it).
var hover: Variant = null
## Events pushed into the viewport (tests).
var events := 0

var _held := false                 # the laser's left button is down in the viewport
var _at := Vector2(-1.0, -1.0)     # the last position sent (motion or button)
var _mouse_in := false             # the viewport was told the mouse is over it
var _actions_down := {}            # StringName -> true: ui_* actions pressed and not yet released
var _stick_dir: Array[Vector2i] = [Vector2i.ZERO, Vector2i.ZERO]   # per stick: the direction it fired, ZERO = armed
var _stick_wait: Array[float] = [0.0, 0.0]                        # per stick: seconds to its next repeat
var _away := 0.0
var _mat: StandardMaterial3D


func _init() -> void:
	name = "MenuPanel"
	visible = false
	viewport = SubViewport.new()
	viewport.name = "PanelViewport"
	viewport.size = Vector2i(Vector2(PX) * SUPERSAMPLE)
	viewport.size_2d_override = PX
	viewport.size_2d_override_stretch = true
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.gui_embed_subwindows = true   # popups stay inside the panel
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	root = Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(root)
	var q := QuadMesh.new()   # faces +Z, the head's side
	q.size = SIZE_M
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_mat.no_depth_test = true   # a wall closer than the panel doesn't cut it
	_mat.disable_fog = true
	_mat.render_priority = PRIORITY
	q.material = _mat
	var quad := MeshInstance3D.new()
	quad.name = "Quad"
	quad.mesh = q
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(quad)


func _ready() -> void:
	_mat.albedo_texture = viewport.get_texture()


## Something under root is visible (a Control or an embedded Window).
func has_content() -> bool:
	for n in root.get_children():
		if (n is CanvasItem and (n as CanvasItem).visible) or (n is Window and (n as Window).visible):
			return true
	return false


## Every frame from the rig: shows or hides with root's content, and puts the panel back in front of the head (`head`,
## in the parent's space) once it has been out of view for AWAY_S. Also times the sticks' repeats.
func update(delta: float, head: Transform3D) -> void:
	var on := has_content()
	if on != shown:
		_set_shown(on, head)
	if not shown or not is_finite(delta) or delta < 0.0:
		return
	if in_view(head):
		_away = 0.0
	else:
		_away += delta
		if _away >= AWAY_S:
			place(head)


func _set_shown(on: bool, head: Transform3D) -> void:
	shown = on
	visible = on
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		place(head)
	else:
		let_go()
	shown_changed.emit(on)


## Lets go of everything held in the viewport: the mouse button (released where it was last) and ui_* actions.
func let_go() -> void:
	release()
	for a: StringName in _actions_down.keys():
		action(a, false)
	_stick_dir = [Vector2i.ZERO, Vector2i.ZERO]
	_set_mouse_in(false)
	hover = null


## Stands the panel DIST in front of `head` (level, facing it), DROP below the eyes.
func place(head: Transform3D) -> void:
	_away = 0.0
	if not head.origin.is_finite() or not head.basis.is_finite():
		return
	var fwd := -head.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), head.origin + fwd * DIST - Vector3(0, DROP, 0))


## The panel is within AWAY_DEG of where `head` looks.
func in_view(head: Transform3D) -> bool:
	var to := transform.origin - head.origin
	var fwd := -head.basis.z
	if to.length() < 0.001 or fwd.length() < 0.001:
		return true
	return rad_to_deg(fwd.angle_to(to)) <= AWAY_DEG


## A point on the panel's plane (panel space, z = 0) in logical pixels, or null; off the panel gives pixels outside
## PX (a drag goes on there).
static func to_px(p: Variant) -> Variant:
	if not p is Vector3 or not (p as Vector3).is_finite():
		return null
	var v: Vector3 = p
	var px := Vector2((v.x / SIZE_M.x + 0.5) * PX.x, (0.5 - v.y / SIZE_M.y) * PX.y)
	return px if absf(px.x) < MAX_PX and absf(px.y) < MAX_PX else null


## The point (panel space) is on the panel.
static func covers(p: Variant) -> bool:
	if not p is Vector3 or not (p as Vector3).is_finite():
		return false
	var v: Vector3 = p
	return absf(v.x) <= SIZE_M.x * 0.5 and absf(v.y) <= SIZE_M.y * 0.5


## The laser this frame: where it meets the panel's plane (panel space), or null. Sends a motion when it moved
## (button mask LEFT while held); off the panel the viewport hears the mouse left it, and a held button keeps
## dragging on the plane.
func point(p: Variant) -> void:
	if not shown:
		return
	var px: Variant = to_px(p)
	hover = px if covers(p) else null
	_set_mouse_in(hover != null or _held)
	if px == null:
		return
	var at: Vector2 = px
	if at.distance_squared_to(_at) < 0.25:
		return
	var e := InputEventMouseMotion.new()
	e.position = at
	e.global_position = at
	e.relative = at - _at if _at.x >= 0.0 else Vector2.ZERO
	if _held:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	_at = at
	_push(e)


## The laser's trigger went down: the left button presses where it points. False off the panel (nothing sent).
func press() -> bool:
	if not shown or hover == null or _held:
		return false
	_at = hover
	_held = true
	_button(MOUSE_BUTTON_LEFT, true)
	return true


## The laser's trigger came up: the left button lets go where the laser was last, on the panel or not. False
## when it wasn't held.
func release() -> bool:
	if not _held:
		return false
	_held = false
	_button(MOUSE_BUTTON_LEFT, false)
	_set_mouse_in(hover != null)
	return true


func _button(index: MouseButton, down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = index
	e.pressed = down
	e.position = _at
	e.global_position = _at
	if _held:
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	if index == MOUSE_BUTTON_WHEEL_UP or index == MOUSE_BUTTON_WHEEL_DOWN:
		e.factor = 1.0
	_push(e)


## A ui_* action pressed (`down`) or released, as from a key. A release only follows a press.
func action(a: StringName, down: bool) -> void:
	if not shown and down:
		return
	if not down and not _actions_down.has(a):
		return
	if down:
		_actions_down[a] = true
	else:
		_actions_down.erase(a)
	var e := InputEventAction.new()
	e.action = a
	e.pressed = down
	e.strength = 1.0 if down else 0.0
	_push(e)


## The sticks this frame (x right, y forward, -1..1): `move` steps ui_up / ui_down / ui_left / ui_right; `turn` does
## too, except that up / down turns the wheel where the laser points while it is on the panel.
func nav(move: Vector2, turn: Vector2, delta: float) -> void:
	if not shown:
		return
	var d := _stick_step(0, move, delta)
	if d != Vector2i.ZERO:
		_tap(d)
	d = _stick_step(1, turn, delta)
	if d != Vector2i.ZERO:
		if d.y != 0 and hover != null:
			_at = hover
			var w := MOUSE_BUTTON_WHEEL_UP if d.y > 0 else MOUSE_BUTTON_WHEEL_DOWN
			_button(w, true)
			_button(w, false)
		else:
			_tap(d)


## Stick i: the direction to fire this frame (ZERO: none). Fires on a push past ON, then repeats while held.
func _stick_step(i: int, v: Vector2, delta: float) -> Vector2i:
	if not v.is_finite():
		v = Vector2.ZERO
	var d := Vector2i.ZERO
	if maxf(absf(v.x), absf(v.y)) > ON:
		d = Vector2i(int(signf(v.x)), 0) if absf(v.x) > absf(v.y) else Vector2i(0, int(signf(v.y)))
	if maxf(absf(v.x), absf(v.y)) < OFF:
		_stick_dir[i] = Vector2i.ZERO
		return Vector2i.ZERO
	if d == Vector2i.ZERO:
		return Vector2i.ZERO   # between OFF and ON: neither fires nor arms
	if d != _stick_dir[i]:
		_stick_dir[i] = d
		_stick_wait[i] = REPEAT_DELAY_S
		return d
	_stick_wait[i] -= clampf(delta, 0.0, 1.0) if is_finite(delta) else 0.0
	if _stick_wait[i] > 0.0:
		return Vector2i.ZERO
	_stick_wait[i] = REPEAT_S
	return d


func _tap(d: Vector2i) -> void:
	var a: StringName = &"ui_right" if d.x > 0 else &"ui_left" if d.x < 0 else &"ui_up" if d.y > 0 else &"ui_down"
	action(a, true)
	action(a, false)


func _set_mouse_in(on: bool) -> void:
	if on == _mouse_in:
		return
	_mouse_in = on
	if viewport.is_inside_tree():
		viewport.notification(NOTIFICATION_VP_MOUSE_ENTER if on else NOTIFICATION_VP_MOUSE_EXIT)


func _push(e: InputEvent) -> void:
	if not viewport.is_inside_tree():
		return
	events += 1
	viewport.push_input(e, true)
