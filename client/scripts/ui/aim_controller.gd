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
## Guns (fire mode with a wielded gun): the client flies the bullet (BulletPhysics: speed, drag, drop, sights
## zeroed at 25 m) from the eye along the crosshair / clicked point against the creature figures' body parts
## and the map, and answers FIRE with that exact outcome plus `fly: true` (`shot`), keeping the aim (origin,
## sight line, ammo) for 60 s. Old bridges use the exact outcome; this one also draws its tracer.
## Newer bridges (target requests carry `dispersion`, arcmin) then roll CDDA's error per projectile and send a
## `shot` request (shot_error arcmin, shot_angle degrees): on_request() turns the kept sight line by it
## (ShotError), flies that bullet, draws its tracer and answers at once with the outcome, or cancels so CDDA
## rolls it. While aiming, the crosshair shows the dispersion as a circle and the viewmodel sways with it.

signal fired

const MARKER_COLOR := Color(1.0, 0.2, 0.15)
const AIM_KEEP_MS := 60000        # a kept aim answers shot requests this long after the trigger pull
const MAX_DISPERSION := 10800.0   # arcmin; larger values from the bridge are refused
const MAX_TRACERS := 32

var world: WorldView
var request_ui: RequestUI
var look_ray: LookRay
var first_person := false     # main.gd sets it each frame
var crosshair: Crosshair
var _marker: MeshInstance3D
var creature_view: CreatureView   # bullets hit its figures; null = CDDA rolls the shot as before
var wielded_gun := Callable()     # -> IdTables.Def of the wielded gun, or null (main.gd)
var last_shot := {}               # the last client-flown shot (tests, debugging)
var shot_aim := {}                # the last client-flown FIRE: {origin, sight (unturned), ammo, time msec}
var dispersion := 0.0             # arcmin, from the last target request (0 = none / old bridge)
var shown_dispersion := 0.0       # dispersion while a fire-mode target request shows, else 0 (viewmodel sway)
var _sim_rolls := false           # the last target request had `dispersion`: shot requests will follow FIRE
var _tracers := 0


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
	shown_dispersion = dispersion if t != null and t.mode == "fire" else 0.0
	var spread := 0.0
	if crosshair.visible and shown_dispersion > 0.0 and cam != null \
			and cam.projection == Camera3D.PROJECTION_PERSPECTIVE:
		var vp := cam.get_viewport().get_visible_rect().size
		var h := crosshair.size.y if crosshair.size.y > 0.0 else vp.y
		spread = ShotError.spread_pixels(_vertical_fov(cam, vp), h, shown_dispersion)
	crosshair.spread_px = spread
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
			shot_aim = {}   # a new trigger pull replaces the kept aim
		var gun: IdTables.Def = wielded_gun.call() if wielded_gun.is_valid() else null
		if t.mode == "fire" and gun != null and creature_view != null and world.snapshot != null:
			var at := aim_point(cam, mouse, captured)
			var origin := cam.project_ray_origin(at)
			var sight := cam.project_ray_normal(at)
			# with shot requests coming, their tracers show where the bullets really went
			var shot := fly_from(origin, sight, gun.gun_ammo, not _sim_rolls)
			if not shot.is_empty():
				var answer: Dictionary = (shot["answer"] as Dictionary).duplicate()
				answer["fly"] = true
				shot_aim = {"origin": origin, "sight": sight, "ammo": gun.gun_ammo, "time": Time.get_ticks_msec()}
				t.fire_shot(shot["square"], answer)
				return true
		t.fire()
	else:
		request_ui.set_target_cursor(sq)   # first click picks, the second on the same square shoots
	return true


## Flies a bullet through screen point `at` of `cam` (see fly_from).
func fly_shot(cam: Camera3D, at: Vector2, ammo: String) -> Dictionary:
	return fly_from(cam.project_ray_origin(at), cam.project_ray_normal(at), ammo)


## Flies a bullet from world point `origin` with sights along `sight` (the bore is zeroed from it), e.g. the
## eye or, in VR, a gun barrel: {square, answer (the `shot` dictionary), result} or {} (no world / creature
## view, a bad sight, or the bullet stopped in the shooter's own square). Draws the tracer if `tracer`.
func fly_from(origin: Vector3, sight: Vector3, ammo: String, tracer := true) -> Dictionary:
	if creature_view == null or world == null or world.snapshot == null:
		return {}
	if not origin.is_finite() or not sight.is_finite() or sight.length_squared() < 1e-12:
		return {}
	var prof := BulletPhysics.ammo_profile(ammo)
	var r := BulletPhysics.fly(origin, BulletPhysics.launch_dir(sight, prof[0]), prof[0], prof[1],
			creature_view.figures(), look_ray)
	var sq := world.coords.world_to_ms(r["point"])
	var path: Array = r["path"]
	if r["hit"] == "map" and path.size() >= 2:
		# a floor / ceiling hit's point lies just past it, on the next level: keep the bullet's level
		var back: Vector3 = r["point"] - (path[-1] - path[-2]).normalized() * (LookRay.STEP_M + 0.01)
		sq.z = world.coords.world_to_ms(back).z
	var answer := {"end": sq, "hit_uid": 0, "part": "", "quality": 0.99}
	if r["hit"] == "creature":
		var c: Snapshot.Creature = null
		for x in world.snapshot.creatures:
			if x.uid == r["uid"]:
				c = x
		if c != null:
			sq = c.pos
			var d := CreatureView.def_of(world, c)
			answer = {"end": sq, "hit_uid": c.uid, "quality": BulletPhysics.quality_of(r["quality"]),
					"part": BulletPhysics.cdda_part(r["zone"], c.kind == Snapshot.Creature.MONSTER,
							d.weakpoints if d != null else {})}
	if sq == world.coords.world_to_ms(origin):
		return {}   # stopped in our own square: let CDDA handle it
	last_shot = {"square": sq, "answer": answer, "result": r}
	if tracer:
		_tracer(r["path"])
	return last_shot


## Called by main.gd for every live request before it shows. `target`: remembers its `dispersion`, returns {}.
## `shot` (one projectile CDDA fires after a client-flown FIRE): the answer to send right away, no UI:
## {id, shot} from the kept aim turned by shot_error / shot_angle, or {id, cancel} (CDDA rolls it itself);
## {} only when the id is unusable. Other kinds: {}.
func on_request(req: Dictionary) -> Dictionary:
	var kind: Variant = req.get("kind")
	if not kind is String:
		return {}
	if kind == "target":
		var v: Variant = req.get("dispersion")
		var f := _finite(v)
		_sim_rolls = (v is float or v is int) and f == float(v) and f >= 0.0 and f <= MAX_DISPERSION
		dispersion = f if _sim_rolls else 0.0
		return {}
	if kind != "shot":
		return {}
	var id: Variant = RequestWidget.id_value(req.get("id"))
	if id == null or id <= 0:
		push_warning("aim: shot request without a usable id")
		return {}
	var cancel := {"id": id, "cancel": true}
	if shot_aim.is_empty() or Time.get_ticks_msec() - int(shot_aim.get("time", 0)) > AIM_KEEP_MS:
		return cancel
	var origin: Variant = shot_aim.get("origin")
	var sight: Variant = shot_aim.get("sight")
	if not origin is Vector3 or not sight is Vector3:
		return cancel
	var dir := ShotError.apply(sight, _finite(req.get("shot_error")), _finite(req.get("shot_angle")))
	var shot := fly_from(origin, dir, str(shot_aim.get("ammo", "")))
	if shot.is_empty():
		return cancel
	return {"id": id, "shot": shot["answer"]}


## A bridge number as a float: ints and finite floats; anything else is 0.
static func _finite(v: Variant) -> float:
	if v is int:
		return float(v)
	if v is float and is_finite(v):
		return v
	return 0.0


## The camera's vertical field of view in degrees (fov is horizontal when it keeps the width).
static func _vertical_fov(cam: Camera3D, vp: Vector2) -> float:
	if cam.keep_aspect == Camera3D.KEEP_WIDTH and vp.x > 0.0 and vp.y > 0.0:
		return rad_to_deg(2.0 * atan(tan(deg_to_rad(cam.fov) * 0.5) * vp.y / vp.x))
	return cam.fov


func _tracer(path: Array) -> void:
	if path.size() < 2 or not is_inside_tree() or _tracers >= MAX_TRACERS:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.4, 0.9)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for i in mini(path.size(), 512):
		im.surface_add_vertex(path[i] + Vector3(0, -0.08, 0) * (1.0 - float(i) / path.size()))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.name = "Tracer"
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_tracers += 1
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tw.tween_callback(func() -> void:
		_tracers -= 1
		mi.queue_free())


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


## A small cross at the screen centre; brighter while aiming (mouse captured). A thin circle of radius
## `spread_px` shows CDDA's dispersion (0 = none).
class Crosshair:
	extends Control
	var aiming := false:
		set(v):
			if v != aiming:
				aiming = v
				queue_redraw()
	var spread_px := 0.0:
		set(v):
			var r := v if is_finite(v) and v > 0.0 else 0.0
			if absf(r - spread_px) > 0.5 or (r == 0.0) != (spread_px == 0.0):
				spread_px = r
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
		if spread_px > gap:
			draw_arc(c, spread_px, 0.0, TAU, 64, Color(0, 0, 0, 0.35), 3.0, true)
			draw_arc(c, spread_px, 0.0, TAU, 64, Color(col, 0.6), 1.2, true)
