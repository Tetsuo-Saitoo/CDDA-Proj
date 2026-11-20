class_name VrZoom
extends Node3D
## VR zoom (VrRig `zoom`): while the right stick is clicked and held (Quest / Index / Pico / WMR; Vive wands have no
## free button), a small inset INSET_DEG wide shows where the player looks (VrRig.look: the eyes when tracked, else
## the head) magnified MAG times, like a pair of binoculars held up to the eyes. Comfort: the rest of the view is
## untouched (no field of view change); the inset's aim follows the gaze smoothed (SMOOTH_S), so the magnified
## shake of head and eyes stays small; its horizon stays level; it grows in over FADE_S. It only shows: nothing is done
## by looking. The inset's own camera renders only while it shows; the inset is on its own layer (LAYER) so that
## camera never sees it.

const MAG := 3.0
const INSET_DEG := 14.0         # the inset's width as seen from the eyes
const DIST_M := 0.6             # how far in front of the eyes it floats
const SMOOTH_S := 0.12          # the aim's time constant
const FADE_S := 0.15
const PIXELS := 448             # the inset's picture, square
const LAYER := 1 << 18          # render layer 19: the inset itself
const FRAME_M := 0.006          # the dark rim around the picture

var held := false               # the button is down (VrRig.press / release)
var enabled := true             # the feature's toggle (the Eye tracking settings group)
var aim_dir := Vector3.ZERO     # the smoothed aim (world, unit); ZERO before the first look
var cam: Camera3D               # the magnified view's camera (in `view`)
var view: SubViewport
var _quad: MeshInstance3D
var _rim: MeshInstance3D
var _grow := 0.0                # 0..1 while it fades in


func _init() -> void:
	name = "Zoom"
	top_level = true
	view = SubViewport.new()
	view.size = Vector2i(PIXELS, PIXELS)
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view.msaa_3d = Viewport.MSAA_DISABLED
	add_child(view)
	cam = Camera3D.new()
	cam.fov = INSET_DEG / MAG
	cam.near = 0.1
	cam.far = 600.0
	cam.cull_mask = 0xFFFFF & ~LAYER
	cam.top_level = true
	view.add_child(cam)
	var w := 2.0 * DIST_M * tan(deg_to_rad(INSET_DEG) / 2.0)
	var q := QuadMesh.new()
	q.size = Vector2(w, w)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = view.get_texture()
	m.no_depth_test = true
	m.render_priority = 100
	q.material = m
	_quad = MeshInstance3D.new()
	_quad.mesh = q
	_quad.layers = LAYER
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_quad)
	var r := QuadMesh.new()
	r.size = Vector2(w + 2.0 * FRAME_M, w + 2.0 * FRAME_M)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.05, 0.05, 0.05)
	rm.no_depth_test = true
	rm.render_priority = 99
	r.material = rm
	_rim = MeshInstance3D.new()
	_rim.mesh = r
	_rim.layers = LAYER
	_rim.position = Vector3(0, 0, -0.001)
	_rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rim)
	visible = false


## Per frame (VrRig): `look` is VrRig.look() ({} when none), `can` false while a menu or panel is up.
func update(delta: float, look: Dictionary, can: bool) -> void:
	var from: Variant = look.get("from")
	var dir: Variant = look.get("dir")
	if not held or not enabled or not can or not from is Vector3 or not dir is Vector3 \
			or not (from as Vector3).is_finite() or not (dir as Vector3).is_finite() or (dir as Vector3).length() < 0.5 \
			or not is_finite(delta) or delta < 0.0:
		stop()
		return
	var d := (dir as Vector3).normalized()
	if aim_dir == Vector3.ZERO or not visible:
		aim_dir = d
	else:
		aim_dir = aim_dir.slerp(d, 1.0 - exp(-minf(delta, 0.1) / SMOOTH_S)).normalized()
	_grow = minf(_grow + delta / FADE_S, 1.0) if visible else 0.0
	visible = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var up := Vector3.UP if absf(aim_dir.dot(Vector3.UP)) < 0.98 else Vector3.BACK
	var b := Basis.looking_at(aim_dir, up)
	cam.global_transform = Transform3D(b, from)
	global_transform = Transform3D(b.scaled(Vector3.ONE * maxf(_grow, 0.05)), (from as Vector3) + aim_dir * DIST_M)


## Hidden, its camera not rendering.
func stop() -> void:
	visible = false
	aim_dir = Vector3.ZERO
	_grow = 0.0
	if view != null:
		view.render_target_update_mode = SubViewport.UPDATE_DISABLED
