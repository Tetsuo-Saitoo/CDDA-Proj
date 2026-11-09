class_name AimController
extends Node3D
## FPS-style aiming for CDDA's `target` request (fire / throw / ... and look). While a target request shows:
## - a red marker stands on the cursor square in the 3D view (any view but VR);
## - in first person a crosshair sits at the screen centre; holding `look` (RMB, mouse captured) aims like an
##   FPS: the square under the crosshair becomes the cursor as you turn (attack modes only), and `aim_fire`
##   (LMB / F) shoots at it;
## - with a free mouse, `aim_fire` on a creature or square picks it, a second click on the same square shoots.
## Picking is LookRay's ray from the camera (creatures as their figures, walls, floors). Answers go through
## TargetRequestWidget (pos + FIRE etc.), so CDDA still checks range, line of fire and ammo.
## The weapon viewmodel (WeaponViewmodel) lives on the first-person camera; `fired` kicks it.

signal fired

const MARKER_COLOR := Color(1.0, 0.2, 0.15)

var world: WorldView
var request_ui: RequestUI
var look_ray: LookRay
var first_person := false     # main.gd sets it each frame
var crosshair: Crosshair
var _marker: MeshInstance3D


func _init(w: WorldView, ui: RequestUI) -> void:
	name = "Aim"
	world = w
	request_ui = ui
	look_ray = LookRay.new(w)
	crosshair = Crosshair.new()
	crosshair.visible = false
	_marker = _marker_mesh()
	_marker.visible = false
	add_child(_marker)


## The square a ray through screen point `pos` of camera `cam` meets, or null.
func pick(cam: Camera3D, pos: Vector2) -> Variant:
	if cam == null or world.snapshot == null:
		return null
	var r := look_ray.cast(cam.project_ray_origin(pos), cam.project_ray_normal(pos))
	return r["square"] if r["hit"] else null


## Where the crosshair (or the mouse) points: the screen centre while the mouse is captured.
func aim_point(cam: Camera3D, mouse: Vector2, captured: bool) -> Vector2:
	return cam.get_viewport().get_visible_rect().size / 2.0 if captured else mouse


## Per frame: crosshair, FPS aim (cursor follows the crosshair) and the cursor marker.
func update(cam: Camera3D, captured: bool) -> void:
	var t := request_ui.target_widget()
	crosshair.visible = t != null and first_person
	crosshair.aiming = captured
	if t == null:
		_marker.visible = false
		return
	if first_person and captured and TargetRequestWidget.is_attack_mode(t.mode):
		var sq: Variant = pick(cam, aim_point(cam, Vector2.ZERO, true))
		if sq != null and sq != t.cursor:
			request_ui.set_target_cursor(sq)
	_place_marker(t.cursor)


## A fire input (`aim_fire`, `cdda_fire`, or `look_at` = LMB) while a target request shows; true if used.
## Keyboard and pad fire straight at the cursor; the mouse picks or fires as in on_fire.
func handle_event(event: InputEvent, cam: Camera3D) -> bool:
	if request_ui.target_widget() == null:
		return false
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if InputActions.pressed(event, &"look_at"):
		var mb := event as InputEventMouseButton
		return on_fire(cam, mb.position if mb != null else cam.get_viewport().get_mouse_position(), captured)
	if InputActions.pressed(event, &"aim_fire") or InputActions.pressed(event, &"cdda_fire"):
		return on_fire(cam, cam.get_viewport().get_mouse_position(), true)
	return false


## `aim_fire` pressed at screen point `mouse`; true if a target request used it.
func on_fire(cam: Camera3D, mouse: Vector2, captured: bool) -> bool:
	var t := request_ui.target_widget()
	if t == null:
		return false
	var sq: Variant = pick(cam, aim_point(cam, mouse, captured))
	if captured or (sq != null and sq == t.cursor) or sq == null:
		if sq != null:
			request_ui.set_target_cursor(sq)
		if TargetRequestWidget.is_attack_mode(t.mode):
			fired.emit()
		t.fire()
	else:
		request_ui.set_target_cursor(sq)   # first click picks, the second on the same square shoots
	return true


func _place_marker(sq: Vector3i) -> void:
	if world.snapshot == null:
		_marker.visible = false
		return
	_marker.visible = true
	_marker.global_position = world.coords.ms_center_to_world(sq) + Vector3(0, 0.03, 0)


static func _marker_mesh() -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(MARKER_COLOR, 0.8)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.38
	ring.outer_radius = 0.46
	ring.rings = 24
	ring.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "TargetMarker"
	mi.mesh = ring
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A small cross at the screen centre; brighter while aiming (mouse captured).
class Crosshair:
	extends Control
	var aiming := false:
		set(v):
			if v != aiming:
				aiming = v
				queue_redraw()

	func _init() -> void:
		name = "Crosshair"
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size / 2.0
		var col := Color(1, 0.25, 0.2) if aiming else Color(1, 1, 1, 0.7)
		var gap := 4.0 if aiming else 7.0
		for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * gap, c + d * (gap + 9.0), Color.BLACK, 4.0)
			draw_line(c + d * gap, c + d * (gap + 9.0), col, 2.0)
		draw_circle(c, 1.5, col)
