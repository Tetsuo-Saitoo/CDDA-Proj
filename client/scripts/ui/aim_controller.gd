class_name AimController
extends Node3D
## FPS-style aiming for CDDA's `target` request (fire / throw / ... and look). While a target request shows:
## - a red marker stands on the cursor square in the 3D view (any view but VR);
## - in first person a crosshair sits at the screen centre; holding `look` (RMB, mouse captured) aims like an
##   FPS: the square under the crosshair becomes the cursor as you turn (attack modes only), and `aim_fire`
##   (LMB / F) shoots at it;
## - with a free mouse, `aim_fire` on a creature or square picks it, a second click on the same square shoots.
## Picking is LookRay's ray from the camera (creatures as their figures, walls, floors); in the shoulder and top
## views it starts in front of the player and bullets fly from the eyes (`view`). Answers go through
## TargetRequestWidget (pos + FIRE etc.), so CDDA still checks range, line of fire and ammo.
## The weapon viewmodel (WeaponViewmodel) lives on the first-person camera; `fired` kicks it.
## Guns (fire mode with a wielded gun): the client flies the bullet (BulletPhysics: speed, drag, drop, sights
## zeroed at 25 m) from the eye along the crosshair / clicked point against the creature figures' body parts
## and the map, and answers FIRE with that exact outcome plus `fly: true` (`shot`), keeping the aim (origin,
## sight line, ammo) for 60 s. Old bridges use the exact outcome; this one also draws its tracer.
## Newer bridges (target requests carry `dispersion`, arcmin) then roll CDDA's error per projectile and send a
## `shot` request (shot_error arcmin, shot_angle degrees): on_request() turns the kept sight line by it
## (ShotError), flies that bullet, draws its tracer and answers at once with the outcome, or cancels so CDDA
## rolls it. A shotgun shell's request names each pellet's spread (`pellets`): every pellet is flown and answered
## (pellet_turns). Bullets fly through furniture (soft cover, BulletPhysics). While aiming, the crosshair shows the dispersion as a circle and the viewmodel sways with it.
## Shot requests have no time limit and no UI: main.gd sends their answer through send_shot(), which cancels
## instead when the bridge refuses it, so CDDA never waits on one. Answers hold exactly the bridge's types
## (shot_answer()).
## Only the wielded gun flies: a fire-mode target request with `weapon_wielded: false` (a gunmod, a turret...)
## is plain FIRE; without the field (old bridges) the wielded gun flies. A flight tests only the figures near
## its line (BulletPhysics.figures_near_line), so hordes stay cheap.
## VR: fire_from() shoots from a barrel pose instead of the camera; `live_aim` gives the hand's pose for each
## shot request, so bursts follow the hand.
## Hits are confirmed only by CDDA's events (`hits`, HitFeedback, fed by main.gd): the crosshair then shows a
## hit marker (white, bigger for head / eyes, red for a kill).

signal fired

const MARKER_COLOR := Color(1.0, 0.2, 0.15)
const AIM_KEEP_MS := 60000        # a kept aim answers shot requests this long after the trigger pull
const MAX_DISPERSION := 10800.0   # arcmin; larger values from the bridge are refused
const MAX_TRACERS := 32
const LIVE_AIM_REACH := 4.0       # m: a live_aim pose farther than this from the kept origin is refused
const MAX_PART_BYTES := 64        # the bridge's cap on a shot answer's `part`
const MAX_QUALITY := 0.99         # the bridge's range for a shot answer's `quality` is 0..0.99
const MAX_PELLETS := 32           # a shot request's `pellets` and its answer's, at most (the bridge's cap)
const MELEE_REACH_M := 3.5        # a melee pick looks this far (a reach weapon strikes 2 squares off)
const MELEE_KEEP_MS := 3000       # a melee aim answers the swing request this long after the strike key
const MELEE_SQUARES := 2          # aimed strikes go to creatures this many squares off at most, along the 8 ways
const DIR_NAMES := {Vector2i(0, -1): "UP", Vector2i(1, -1): "RIGHTUP", Vector2i(1, 0): "RIGHT",
		Vector2i(1, 1): "RIGHTDOWN", Vector2i(0, 1): "DOWN", Vector2i(-1, 1): "LEFTDOWN", Vector2i(-1, 0): "LEFT",
		Vector2i(-1, -1): "LEFTUP"}

var world: WorldView
var request_ui: RequestUI
var look_ray: LookRay
var first_person := false     # main.gd sets it each frame
var crosshair: Crosshair
var hits: HitFeedback             # hit confirmations from CDDA's events (main.gd feeds it)
var _marker: MeshInstance3D
var creature_view: CreatureView   # bullets hit its figures; null = CDDA rolls the shot as before
var wielded_gun := Callable()     # -> IdTables.Def of the wielded gun, or null (main.gd)
var live_aim := Callable()        # VR: -> {origin: Vector3, sight: Vector3} or {}; shot requests fly from it
## () -> Dictionary: the eyes when the shown camera is away from them (C9 shoulder and top views,
## main.eyes_view: {mode, eye, facing}); {} otherwise. Picks then start in front of the player
## (ViewCamera.ray_start), bullets fly from the eyes to what the pick meets, and in the top view, where the
## screen centre is the player, mouse-look aiming follows the facing (no crosshair).
var view := Callable()
var last_shot := {}               # the last client-flown shot (tests, debugging)
var shot_aim := {}                # the last client-flown FIRE: {origin, sight (unturned), ammo, time msec}
var melee_aim := {}               # the last aimed strike: {square, uid, part, quality, time msec} (melee_from)
var dispersion := 0.0             # arcmin, from the last target request (0 = none / old bridge)
var shown_dispersion := 0.0       # dispersion while a fire-mode target request shows, else 0 (viewmodel sway)
var _sim_rolls := false           # the last target request had `dispersion`: shot requests will follow FIRE
var _wielded_fires := true        # the last target request fires the wielded gun (`weapon_wielded`)
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
	hits = HitFeedback.new(w)
	add_child(hits)
	hits.hit_confirmed.connect(_on_hit)


## The square a ray through screen point `pos` of camera `cam` meets, or null. `captured`: mouse-look aiming
## (the top view then follows the eyes' facing).
func pick(cam: Camera3D, pos: Vector2, captured := false) -> Variant:
	if cam == null or world.snapshot == null:
		return null
	var line := pick_line(cam, pos, captured)
	var r := look_ray.cast(line[0], line[1], LookRay.MAX_M, true, line[2])
	return r["square"] if r["hit"] else null


func _view() -> Dictionary:
	var v: Variant = view.call() if view.is_valid() else {}
	return v if v is Dictionary else {}


func _top() -> bool:
	return _view().get("mode", "") == "top"


## [origin, unit direction, skip_start (LookRay.cast)] of a pick through screen point `at` of `cam` (see `view`).
## Top-down camera rays start at eye height, maybe in the very square clicked: that square counts.
func pick_line(cam: Camera3D, at: Vector2, captured := false) -> Array:
	var v := _view()
	var mode := str(v.get("mode", ""))
	var eye: Variant = v.get("eye")
	var f: Variant = v.get("facing")
	if captured and mode == "top" and eye is Vector3 and f is Vector3 and (eye as Vector3).is_finite() \
			and (f as Vector3).is_finite() and (f as Vector3).length_squared() > 1e-6:
		return [eye, (f as Vector3).normalized(), true]
	var d := cam.project_ray_normal(at)
	var o := cam.project_ray_origin(at)
	var s := ViewCamera.ray_start(mode, o, d, eye)
	return [s, d, not (mode == "top" and s != o)]


## [origin, sight] of a client-flown bullet through screen point `at`: the pick line in first person; with the
## camera away from the eyes, from the eyes to what the pick line meets.
func shot_line(cam: Camera3D, at: Vector2, captured := false) -> Array:
	var line := pick_line(cam, at, captured)
	var eye: Variant = _view().get("eye")
	if not eye is Vector3 or not (eye as Vector3).is_finite():
		return line
	var o: Vector3 = line[0]
	var d: Vector3 = line[1]
	var r := look_ray.cast(o, d, LookRay.MAX_M, true, line[2])
	var p: Vector3 = r["point"] if r["hit"] else o + d * LookRay.MAX_M
	var sight := p - (eye as Vector3)
	return [eye, sight.normalized() if sight.length_squared() > 1e-4 else d, true]


## Where the crosshair (or the mouse) points: the screen centre while the mouse is captured.
func aim_point(cam: Camera3D, mouse: Vector2, captured: bool) -> Vector2:
	return cam.get_viewport().get_visible_rect().size / 2.0 if captured else mouse


## Per frame: crosshair, FPS aim (cursor follows the crosshair) and the cursor marker.
func update(cam: Camera3D, captured: bool) -> void:
	var t := request_ui.target_widget()
	crosshair.show_cross = t != null
	crosshair.visible = first_person and not _top() and (t != null or crosshair.marking())
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
		var sq: Variant = pick(cam, aim_point(cam, Vector2.ZERO, true), true)
		if sq != null and sq != t.cursor:
			request_ui.set_target_cursor(sq)
	_place_marker(t.cursor)


## A fire input (`aim_fire`, `cdda_fire`, or `click` = LMB) while a target request shows; true if used.
## Keyboard and pad fire straight at the cursor; the mouse picks or fires as in on_fire.
func handle_event(event: InputEvent, cam: Camera3D) -> bool:
	if request_ui.target_widget() == null:
		return false
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if InputActions.pressed(event, &"click"):
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
	var at := aim_point(cam, mouse, captured)
	var sq: Variant = pick(cam, at, captured)
	if captured or (sq != null and sq == t.cursor) or sq == null:
		if sq != null:
			request_ui.set_target_cursor(sq)
		var line := shot_line(cam, at, captured)
		if not _fire_flown(t, line[0], line[1]):
			if TargetRequestWidget.is_attack_mode(t.mode):
				fired.emit()
				shot_aim = {}   # a new trigger pull replaces the kept aim
			t.fire()
	else:
		request_ui.set_target_cursor(sq)   # first click picks, the second on the same square shoots
	return true


## VR: fires the showing fire-mode target request from a barrel pose (world `origin`, bore `dir`) the way the
## crosshair does: flies the bullet, answers FIRE with it and `fly: true`, keeps the aim, kicks. False, with
## nothing sent, when no fire-mode target request shows, the wielded gun isn't the one firing
## (`weapon_wielded`), no gun is held, or nothing could be flown; the caller may then fall back to plain FIRE.
func fire_from(origin: Vector3, dir: Vector3) -> bool:
	var t := request_ui.target_widget()
	if t == null or t.mode != "fire":
		return false
	return _fire_flown(t, origin, dir)


## A trigger pull flown by the client (on_fire and fire_from): when `t` fires the wielded gun, flies it from
## `origin` along `sight`, kicks, answers FIRE with the outcome plus `fly: true` and keeps the aim. False, with
## nothing sent, when it can't.
func _fire_flown(t: TargetRequestWidget, origin: Vector3, sight: Vector3) -> bool:
	if t.mode != "fire" or not _wielded_fires or t.done or t.primary_index() < 0:
		return false
	if creature_view == null or world == null or world.snapshot == null:
		return false
	var gun: IdTables.Def = wielded_gun.call() if wielded_gun.is_valid() else null
	if gun == null:
		return false
	# with shot requests coming, their tracers show where the bullets really went
	var shot := fly_from(origin, sight, gun.gun_ammo, not _sim_rolls)
	if shot.is_empty():
		return false
	fired.emit()
	var answer: Dictionary = (shot["answer"] as Dictionary).duplicate()
	answer["fly"] = true
	shot_aim = {"origin": origin, "sight": sight.normalized(), "ammo": gun.gun_ammo, "time": Time.get_ticks_msec()}
	t.fire_shot(shot["square"], answer)
	return true


## Flies a bullet through screen point `at` of `cam` (see fly_from and shot_line).
func fly_shot(cam: Camera3D, at: Vector2, ammo: String) -> Dictionary:
	var line := shot_line(cam, at)
	return fly_from(line[0], line[1], ammo)


## Flies a bullet from world point `origin` with sights along `sight` (the bore is zeroed from it), e.g. the
## eye or, in VR, a gun barrel: {square, answer (the `shot` dictionary), result} or {} (no world / creature
## view, a bad sight, or the bullet stopped in the shooter's own square). Draws the tracer if `tracer`.
func fly_from(origin: Vector3, sight: Vector3, ammo: String, tracer := true) -> Dictionary:
	if creature_view == null or world == null or world.snapshot == null:
		return {}
	if not origin.is_finite() or not sight.is_finite() or sight.length_squared() < 1e-12:
		return {}
	var prof := BulletPhysics.ammo_profile(ammo)
	var dir := BulletPhysics.launch_dir(sight, prof[0])
	var near := BulletPhysics.figures_near_line(creature_view.figures(), origin, dir, prof[0])
	var r := BulletPhysics.fly(origin, dir, prof[0], prof[1], near, look_ray)
	var sq := world.coords.world_to_ms(r["point"])
	var path: Array = r["path"]
	if r["hit"] == "map" and path.size() >= 2:
		# a floor / ceiling hit's point lies just past it, on the next level: keep the bullet's level
		var back: Vector3 = r["point"] - (path[-1] - path[-2]).normalized() * (LookRay.STEP_M + 0.01)
		sq.z = world.coords.world_to_ms(back).z
	var answer := shot_answer(sq, 0, "", MAX_QUALITY)
	if r["hit"] == "creature":
		var c: Snapshot.Creature = null
		for x in world.snapshot.creatures:
			if x.uid == r["uid"]:
				c = x
		if c != null:
			sq = c.pos
			var d := CreatureView.def_of(world, c)
			answer = shot_answer(sq, c.uid, BulletPhysics.cdda_part(str(r["zone"]), c.kind == Snapshot.Creature.MONSTER,
					d.weakpoints if d != null else {}), BulletPhysics.quality_of(float(r["quality"])))
	if sq == world.coords.world_to_ms(origin):
		return {}   # stopped in our own square: let CDDA handle it
	last_shot = {"square": sq, "answer": answer, "result": r}
	if tracer:
		_tracer(r["path"])
	return last_shot


## Melee: the creature figure a strike from world point `origin` along `sight` meets within MELEE_REACH_M, with
## nothing solid in between: {square, uid, part, quality, time} or {}. Kept as melee_aim for the swing request.
func melee_from(origin: Vector3, sight: Vector3) -> Dictionary:
	melee_aim = {}
	if not origin.is_finite() or not sight.is_finite() or sight.length_squared() < 1e-12:
		return {}
	return _melee_pick(origin, sight.normalized() * MELEE_REACH_M)


## Melee by hand (VR): the creature figure the segment a -> b (a held weapon from the hand to its tip, say) meets
## first, nothing solid before it: sets and returns melee_aim, or {} (melee_aim cleared). Points that aren't
## finite, a segment of no length or one longer than MELEE_REACH_M give {}.
func melee_segment(a: Vector3, b: Vector3) -> Dictionary:
	melee_aim = {}
	if not a.is_finite() or not b.is_finite():
		return {}
	var seg := b - a
	var len2 := seg.length_squared()
	if len2 < 1e-12 or len2 > MELEE_REACH_M * MELEE_REACH_M:
		return {}
	return _melee_pick(a, seg)


## The aimed hand action ("fp3d_attack_<hand>_aim_<DIR>") for a strike by hand along a -> b (melee_segment) from
## the player's square `me`; "" when `hand` isn't "main" or "off" or the segment meets no creature at most
## MELEE_SQUARES off along one of the 8 ways on this level (melee_aim cleared): a hand that touches nothing
## strikes nothing.
func strike_segment(hand: String, a: Vector3, b: Vector3, me: Vector3i) -> String:
	melee_aim = {}
	if hand != "main" and hand != "off":
		return ""
	var aim := melee_segment(a, b)
	if aim.is_empty():
		return ""
	var dir := strike_dir(me, aim["square"])
	if dir == "":
		melee_aim = {}
		return ""
	return "fp3d_attack_%s_aim_%s" % [hand, dir]


## The creature figure the segment from `origin` along `seg` meets first, as melee_aim (set), or {}.
func _melee_pick(origin: Vector3, seg: Vector3) -> Dictionary:
	if creature_view == null or world == null or world.snapshot == null:
		return {}
	var h := BulletPhysics.reach_figure(origin, seg, creature_view.figures(), look_ray)
	if h.is_empty():
		return {}
	for c: Snapshot.Creature in world.snapshot.creatures:
		if c.uid == int(h["uid"]):
			var d := CreatureView.def_of(world, c)
			melee_aim = {"square": c.pos, "uid": c.uid, "part": BulletPhysics.cdda_part(str(h["zone"]),
					c.kind == Snapshot.Creature.MONSTER, d.weakpoints if d != null else {}),
					"quality": BulletPhysics.quality_of(float(h["quality"])), "time": Time.get_ticks_msec()}
			return melee_aim
	return {}


## The hand action for a strike key (`hand`: "main" or "off") from the player's square `me`: aimed
## ("fp3d_attack_<hand>_aim_<DIR>") at the creature under the crosshair through screen point `at` of `cam` when
## it is at most MELEE_SQUARES off along one of the 8 ways on this level; else a plain strike the way you face
## (`facing`, a direction name such as "LEFT").
func strike_action(hand: String, cam: Camera3D, at: Vector2, captured: bool, me: Vector3i, facing: String) -> String:
	var plain := "fp3d_attack_%s_%s" % [hand, facing]
	melee_aim = {}
	if cam == null or world == null or world.snapshot == null:
		return plain
	var line := shot_line(cam, at, captured)
	var aim := melee_from(line[0], line[1])
	if aim.is_empty():
		return plain
	var dir := strike_dir(me, aim["square"])
	if dir == "":
		melee_aim = {}
		return plain
	return "fp3d_attack_%s_aim_%s" % [hand, dir]


## The direction name from square `me` to `to` when it lies 1..MELEE_SQUARES off along one of the 8 ways on the
## same level, else "".
static func strike_dir(me: Vector3i, to: Vector3i) -> String:
	var d := to - me
	var n := maxi(absi(d.x), absi(d.y))
	if d.z != 0 or n < 1 or n > MELEE_SQUARES or (d.x != 0 and absi(d.x) != n) or (d.y != 0 and absi(d.y) != n):
		return ""
	return DIR_NAMES.get(Vector2i(signi(d.x), signi(d.y)), "")


## A swing request (an aimed strike, fp3d/swing.h): the kept melee aim as a `shot` answer when it is fresh and on
## the request's cursor square with a part to name; else a cancel (CDDA picks the part). {} for an unusable id.
func _swing_answer(req: Dictionary) -> Dictionary:
	var id: Variant = RequestWidget.id_value(req.get("id"))
	if id == null or id <= 0:
		push_warning("aim: swing request without a usable id")
		return {}
	var cancel := fallback_answer(id)
	var aim := melee_aim
	melee_aim = {}   # one strike, one answer
	if aim.is_empty() or Time.get_ticks_msec() - int(aim.get("time", 0)) > MELEE_KEEP_MS:
		return cancel
	var cursor: Variant = req.get("cursor")
	var part := str(aim.get("part", ""))
	if not cursor is Vector3i or cursor != aim.get("square") or part == "" or part.to_utf8_buffer().size() > MAX_PART_BYTES:
		return cancel
	return {"id": int(id), "shot": shot_answer(cursor, int(aim["uid"]), part, float(aim["quality"]))}


## Called by main.gd for every live request before it shows. `target`: remembers its `dispersion` and
## `weapon_wielded`, returns {}.
## `shot` (one projectile CDDA fires after a client-flown FIRE): the answer to send right away, no UI:
## {id, shot} from the kept aim (or live_aim's pose) turned by shot_error / shot_angle, or {id, cancel} (CDDA
## rolls it itself); {} only when the id is unusable. Other kinds: {}.
func on_request(req: Dictionary) -> Dictionary:
	var kind: Variant = req.get("kind")
	if not kind is String:
		return {}
	if kind == "target":
		var v: Variant = req.get("dispersion")
		var f := _finite(v)
		_sim_rolls = (v is float or v is int) and f == float(v) and f >= 0.0 and f <= MAX_DISPERSION
		dispersion = f if _sim_rolls else 0.0
		# old bridges don't say: the wielded gun fires; anything but true says it doesn't
		_wielded_fires = not req.has("weapon_wielded") or (req["weapon_wielded"] is bool and req["weapon_wielded"])
		return {}
	if kind == "swing":
		return _swing_answer(req)
	if kind != "shot":
		return {}
	var id: Variant = RequestWidget.id_value(req.get("id"))
	if id == null or id <= 0:
		push_warning("aim: shot request without a usable id")
		return {}
	var cancel := fallback_answer(id)
	if shot_aim.is_empty() or Time.get_ticks_msec() - int(shot_aim.get("time", 0)) > AIM_KEEP_MS:
		return cancel
	var origin: Variant = shot_aim.get("origin")
	var sight: Variant = shot_aim.get("sight")
	if not origin is Vector3 or not sight is Vector3:
		return cancel
	var pose := _live_pose(origin)   # VR: the hand's pose now, so a burst follows it
	if not pose.is_empty():
		origin = pose["origin"]
		sight = pose["sight"]
	var dir := ShotError.apply(sight, _finite(req.get("shot_error")), _finite(req.get("shot_angle")))
	var ammo := str(shot_aim.get("ammo", ""))
	var turns := pellet_turns(req.get("pellets"))
	var shot := fly_from(origin, dir, ammo, turns.is_empty())
	if shot.is_empty():
		return cancel
	if turns.is_empty():
		return {"id": int(id), "shot": shot["answer"]}
	# a shell: each pellet flown along the shell's line turned by its spread ({}: not flown, CDDA rolls that one)
	var answer: Dictionary = (shot["answer"] as Dictionary).duplicate()
	var pellets: Array = []
	for t: float in turns:
		var p := fly_from(origin, ShotError.apply(dir, absf(t), 90.0 if t >= 0.0 else 270.0), ammo)
		pellets.append(p["answer"] if not p.is_empty() else {})
	answer["pellets"] = pellets
	return {"id": int(id), "shot": answer}


## A shot request's `pellets` (a shotgun shell): each pellet's turn off the shot's line, arcmin, + to the right. At
## most MAX_PELLETS finite numbers within ShotError.MAX_ERROR_ARCMIN; anything else gives [] (one bullet).
static func pellet_turns(v: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not (v is Array or v is PackedFloat32Array or v is PackedFloat64Array) or v.size() > MAX_PELLETS:
		return out
	for x: Variant in v:
		if not (x is float or x is int) or not is_finite(float(x)) or absf(float(x)) > ShotError.MAX_ERROR_ARCMIN:
			return PackedFloat32Array()
		out.append(float(x))
	return out


## A `shot` answer of exactly the types the bridge takes (contracts/bridge_api.md `answer`): end Vector3i,
## hit_uid int (0 = none, never negative), part String (over MAX_PART_BYTES it is ""), quality float in
## 0..MAX_QUALITY (NaN = 0).
static func shot_answer(end: Vector3i, hit_uid: int, part: String, quality: float) -> Dictionary:
	var q: float = clampf(quality, 0.0, MAX_QUALITY) if is_finite(quality) else 0.0
	var p: String = part if part.to_utf8_buffer().size() <= MAX_PART_BYTES else ""
	return {"end": Vector3i(end), "hit_uid": int(maxi(hit_uid, 0)), "part": String(p), "quality": float(q)}


## What a shot request `req_id` is answered with when the bridge refuses its answer: a cancel (CDDA rolls the
## shot itself), or {} when the id is unusable.
static func fallback_answer(req_id: Variant) -> Dictionary:
	var id: Variant = RequestWidget.id_value(req_id)
	if id == null or id <= 0:
		return {}
	return {"id": int(id), "cancel": true}


## Sends a shot request's `answer` through `send` (Callable(Dictionary) -> bool, e.g. LiveSession.answer). When
## the bridge refuses it, sends fallback_answer() instead, so CDDA never waits on the shot. Returns the answer
## that was taken: `answer`, the cancel, or {} when both were refused (or the id was unusable).
static func send_shot(answer: Dictionary, send: Callable) -> Dictionary:
	if not send.is_valid():
		return {}
	var ok: Variant = send.call(answer)
	if ok is bool and ok:
		return answer
	var fb := fallback_answer(answer.get("id"))
	if fb.is_empty() or fb == answer:
		return {}
	ok = send.call(fb)
	return fb if ok is bool and ok else {}


## live_aim's pose, checked: {origin, sight (unit)}, or {} when there is no live_aim or it gives anything but a
## dictionary of finite Vector3s with a non-zero sight and an origin within LIVE_AIM_REACH of `kept_origin`.
func _live_pose(kept_origin: Vector3) -> Dictionary:
	if not live_aim.is_valid():
		return {}
	var p: Variant = live_aim.call()
	if not p is Dictionary:
		return {}
	var o: Variant = (p as Dictionary).get("origin")
	var s: Variant = (p as Dictionary).get("sight")
	if not o is Vector3 or not s is Vector3:
		return {}
	var ov: Vector3 = o
	var sv: Vector3 = s
	if not ov.is_finite() or not sv.is_finite() or sv.length_squared() < 1e-12 \
			or ov.distance_to(kept_origin) > LIVE_AIM_REACH:
		return {}
	return {"origin": ov, "sight": sv.normalized()}


## A hit CDDA confirmed (HitFeedback): the crosshair's hit marker.
func _on_hit(_uid: int, part: String, _amount: int, killed: bool) -> void:
	crosshair.show_hit(part in HitFeedback.HEAD_PARTS, killed)


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


## A small cross at the screen centre (while `show_cross`); brighter while aiming (mouse captured). A thin circle
## of radius `spread_px` shows CDDA's dispersion (0 = none). show_hit() flashes a hit marker, four diagonal ticks
## around the centre fading over HIT_FADE_S: white, bigger for the head / eyes, red for a kill.
class Crosshair:
	extends Control
	const HIT_FADE_S := 0.3
	const HIT_WHITE := Color(1, 1, 1)
	const HIT_RED := Color(1, 0.15, 0.1)
	const HEAD_SCALE := 1.6
	var show_cross := true:
		set(v):
			if v != show_cross:
				show_cross = v
				queue_redraw()
	var hit_left := 0.0           # seconds the hit marker still shows
	var hit_color := HIT_WHITE
	var hit_scale := 1.0          # 1, or HEAD_SCALE for the head / eyes
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

	## Flashes the hit marker: bigger for a head (or eyes) hit, red for a kill.
	func show_hit(head: bool, killed: bool) -> void:
		hit_left = HIT_FADE_S
		hit_color = HIT_RED if killed else HIT_WHITE
		hit_scale = HEAD_SCALE if head else 1.0
		queue_redraw()

	## The hit marker is showing.
	func marking() -> bool:
		return hit_left > 0.0

	func _process(delta: float) -> void:
		if hit_left > 0.0:
			tick_hit(delta)

	## Fades the hit marker by `delta` seconds (tests call it directly).
	func tick_hit(delta: float) -> void:
		if not is_finite(delta) or delta < 0.0:
			return
		hit_left = maxf(hit_left - delta, 0.0)
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var col := Color(1, 0.25, 0.2) if aiming else Color(1, 1, 1, 0.7)
		var gap := 4.0 if aiming else 7.0
		if show_cross:
			for d: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
				draw_line(c + d * gap, c + d * (gap + 9.0), Color.BLACK, 4.0)
				draw_line(c + d * gap, c + d * (gap + 9.0), col, 2.0)
			draw_circle(c, 1.5, col)
			if spread_px > gap:
				draw_arc(c, spread_px, 0.0, TAU, 64, Color(0, 0, 0, 0.35), 3.0, true)
				draw_arc(c, spread_px, 0.0, TAU, 64, Color(col, 0.6), 1.2, true)
		if hit_left > 0.0:
			var a := clampf(hit_left / HIT_FADE_S, 0.0, 1.0)
			var r0 := 7.0 * hit_scale
			var r1 := 15.0 * hit_scale
			for d: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
				var n := d.normalized()
				draw_line(c + n * r0, c + n * r1, Color(0, 0, 0, 0.6 * a), 4.0)
				draw_line(c + n * r0, c + n * r1, Color(hit_color, a), 2.0)
