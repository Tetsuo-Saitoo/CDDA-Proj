class_name GrabController
extends Node
## Block E6: grabbing with the mouse, Amnesia-style. In first person the door leaf (Grabbable) under the
## pointer (the mouse, or the screen centre while the mouse looks around) on a square you can reach gets an
## outline and the pointer becomes a hand; hold `look_at` (LMB) on it and drag: the leaf follows the mouse
## (Grabbable.drag_mouse) and lets go with the button. Outside view: no hover, but a press on a door still
## grabs it. In a live game it also remembers which door crossed its threshold, so main.gd can answer the
## "Open where?" / "Close where?" prompt that CDDA's open / close asks (`want`, `answer_for`).

const HOVER_M := 4.0
const ASK_MS := 3000

var world: WorldView
var look_ray: LookRay
var icon: GrabIcon
var reach: Callable          # () -> Variant: the square you reach from (Vector3i), or null
var grabbed: Grabbable
var hover: Grabbable
var ask := {}                # {word, pos, until}: the door prompt a queued open / close will bring


func _init(w: WorldView) -> void:
	name = "Grab"
	world = w
	look_ray = LookRay.new(w)
	icon = GrabIcon.new()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(icon) and icon.get_parent() == null:
		icon.free()   # never shown (tests)


## [Grabbable, hit point] under screen point `pt` on a reachable square, or [].
func pick(cam: Camera3D, pt: Vector2, max_m := LookRay.MAX_M) -> Array:
	var centre: Variant = reach.call() if reach.is_valid() else null
	if centre == null or cam == null or world.snapshot == null:
		return []
	var o := cam.project_ray_origin(pt)
	var d := cam.project_ray_normal(pt)
	var r := look_ray.cast(o, d, max_m)
	var limit := max_m
	if r["hit"]:   # nothing behind the first wall; a closed door's leaf stands inside its square
		limit = o.distance_to(r["point"]) + (1.5 if r["what"] == "door" else 0.3)
	return world.grabbable_on_ray(o, d, centre, limit)


## Per frame: hover outline and the pointer icon. `enabled`: first person, nothing else using the mouse.
func update(cam: Camera3D, pt: Vector2, enabled: bool, captured: bool) -> void:
	if grabbed != null and not is_instance_valid(grabbed):
		grabbed = null
	var h: Grabbable = null
	if grabbed == null and enabled:
		var p := pick(cam, pt, HOVER_M)
		h = p[0] if not p.is_empty() else null
	_set_hover(h)
	icon.at = pt
	if grabbed != null:
		icon.mode = GrabIcon.FIST
	elif hover != null:
		icon.mode = GrabIcon.HAND
	else:
		icon.mode = GrabIcon.DOT if enabled and captured else GrabIcon.NONE


func _set_hover(h: Grabbable) -> void:
	if h == hover:
		return
	if is_instance_valid(hover) and hover != grabbed:
		hover.set_highlight(false)
	hover = h
	if h != null:
		h.set_highlight(true)


## Press on a leaf grabs it, motion drags it, release lets go; true when the event was used.
func handle_event(event: InputEvent, cam: Camera3D, pt: Vector2) -> bool:
	if grabbed != null and not is_instance_valid(grabbed):
		grabbed = null
	if grabbed != null:
		if event is InputEventMouseMotion and cam != null:
			grabbed.drag_mouse((event as InputEventMouseMotion).relative, cam.global_basis)
			return true
		if event.is_action_released(&"look_at"):
			release()
			return true
		return false
	if InputActions.pressed(event, &"look_at"):
		var p := pick(cam, pt)
		if p.is_empty():
			return false
		grabbed = p[0]
		grabbed.begin_grab(p[1])
		grabbed.set_highlight(true)
		return true
	return false


func release() -> void:
	if is_instance_valid(grabbed):
		grabbed.end_grab()
		grabbed.set_highlight(grabbed == hover)
	grabbed = null


## A leaf crossed its threshold in a live game: the main-loop action to queue ("" when the door isn't next to
## the player), remembering the prompt that will follow.
func want(square: Vector3i, open: bool, player: Vector3i, now: int) -> String:
	var d := square - player
	if d.z != 0 or absi(d.x) > 1 or absi(d.y) > 1:
		return ""
	ask = {"word": "open" if open else "close", "pos": Vector3i(d.x, d.y, 0), "until": now + ASK_MS}
	return "open" if open else "close"


## The answer to CDDA's direction prompt when it is the one `a` waits for, else {}.
static func answer_for(a: Dictionary, req: Dictionary, now: int) -> Dictionary:
	if a.is_empty() or now > int(a["until"]) or req.get("kind", "") != "direction" or not req.get("id") is int:
		return {}
	if not str(req.get("text", "")).to_lower().contains(a["word"]):
		return {}
	return {"id": req["id"], "pos": a["pos"]}


## The pointer: a dot while the mouse looks around, an open hand over something to grab, a fist while dragging.
class GrabIcon:
	extends Control
	enum { NONE, DOT, HAND, FIST }
	var at := Vector2.ZERO:
		set(v):
			if v != at:
				at = v
				queue_redraw()
	var mode := NONE:
		set(v):
			if v != mode:
				mode = v
				queue_redraw()

	func _init() -> void:
		name = "GrabIcon"
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var col := Color(1.0, 0.9, 0.55)
		match mode:
			DOT:
				draw_circle(at, 3.0, Color.BLACK)
				draw_circle(at, 2.0, Color(1, 1, 1, 0.8))
			HAND, FIST:
				var fist := mode == FIST
				var palm := Rect2(at + Vector2(-8, -2), Vector2(16, 13))
				draw_rect(palm.grow(1.5), Color.BLACK)
				draw_rect(palm, col)
				for i in 4:   # fingers: long when open, knuckles when closed
					var x := at.x - 7.0 + i * 4.6
					var top := at.y - (4.0 if fist else 15.0 - absf(i - 1.5) * 1.5)
					draw_line(Vector2(x, at.y), Vector2(x, top), Color.BLACK, 5.5)
					draw_line(Vector2(x, at.y), Vector2(x, top), col, 3.0)
				var thumb := at + (Vector2(-9, 2) if fist else Vector2(-14, -3))
				draw_line(at + Vector2(-7, 7), thumb, Color.BLACK, 5.5)
				draw_line(at + Vector2(-7, 7), thumb, col, 3.0)
