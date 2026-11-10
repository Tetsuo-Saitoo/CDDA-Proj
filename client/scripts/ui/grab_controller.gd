class_name GrabController
extends Node
## Block E6: the mouse's hand, Amnesia-style. In first person the door leaf (Grabbable) or the single item under the
## pointer (the mouse, or the screen centre while the mouse looks around) on a square you can reach gets an
## outline and the pointer becomes a hand. Doors: hold `look_at` (LMB) on one and drag; the leaf follows the mouse
## (Grabbable.drag_mouse) and lets go with the button. Items (with `hands` set): E takes the one you look at into
## the pack; holding LMB carries it in front of you (the wheel moves it nearer / farther, Shift+wheel turns it),
## and letting go puts it into the container, onto the surface (it keeps the spot) or onto the burner you point
## at, through Hands -> ItemActions (one CDDA action each; CDDA decides). Esc while carrying puts it back.
## Outside view: no hover, but a press on a door still grabs it. In a live game it also remembers which door
## crossed its threshold, so main.gd can answer the "Open where?" / "Close where?" prompt that CDDA's open /
## close asks (`want`, `answer_for`).

const HOVER_M := 4.0
const ASK_MS := 3000
const CARRY_MIN_M := 0.35
const CARRY_MAX_M := 2.5
const CARRY_STEP_M := 0.1
const TURN_STEP := PI / 12
const FLASH_MS := 2500

var world: WorldView
var look_ray: LookRay
var icon: GrabIcon
var reach: Callable          # () -> Variant: the square you reach from (Vector3i), or null
## () -> Dictionary: the eyes when the shown camera is away from them (main.eyes_view: {mode, eye, facing});
## {} otherwise. Reach and carrying then count from in front of the player, not from the camera.
var view := Callable()
var grabbed: Grabbable
var hover: Grabbable
var ask := {}                # {word, pos, until}: the door prompt a queued open / close will bring
## Items and doors through the shared hands (E6 / L2); null: doors only, as before.
var hands: Hands:
	set(h):
		hands = h
		if h != null:
			_reach_fn = func() -> Variant: return reach.call() if reach.is_valid() else null
			h.picker.reach = _reach_fn
			h.refused.connect(func(id: String, _t: Dictionary, reason: String) -> void:
				if id == "mouse":
					flash(reason, true))
var item_hover := {}         # the item target under the pointer (Hands target), {} if none
var _reach_fn := Callable()  # what this controller gave hands.picker.reach
var carry_m := 0.8           # how far in front of the camera a carried item floats
var drop := {}               # carrying: what letting go does now (Hands.drop_on_ray)
var _flash := ""
var _flash_until := 0
var _flash_bad := false


func _init(w: WorldView) -> void:
	name = "Grab"
	world = w
	look_ray = LookRay.new(w)
	icon = GrabIcon.new()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	if is_instance_valid(icon) and icon.get_parent() == null:
		icon.free()   # never shown (tests)
	if hands != null and is_instance_valid(hands) and hands.picker.reach == _reach_fn:
		hands.picker.reach = Callable()   # it calls into this controller


## [Grabbable, hit point] under screen point `pt` on a reachable square, or [].
func pick(cam: Camera3D, pt: Vector2, max_m := LookRay.MAX_M) -> Array:
	var centre: Variant = reach.call() if reach.is_valid() else null
	if centre == null or cam == null or world.snapshot == null:
		return []
	var ray := ray_from(cam, pt)
	var o: Vector3 = ray[0]
	var d: Vector3 = ray[1]
	var r := look_ray.cast(o, d, max_m, true, ray[2])
	var limit := max_m
	if r["hit"]:   # nothing behind the first wall; a closed door's leaf stands inside its square
		limit = o.distance_to(r["point"]) + (1.5 if r["what"] == "door" else 0.3)
	return world.grabbable_on_ray(o, d, centre, limit)


## [origin, direction, skip_start (LookRay.cast)] of the pointer's ray. With `view` set the origin moves along the
## ray to in front of the player (ViewCamera.ray_start), so hover and carry distances count from the player; a
## top-down ray then starts at eye height, maybe in the very square pointed at, which counts.
func ray_from(cam: Camera3D, pt: Vector2) -> Array:
	var d := cam.project_ray_normal(pt)
	var o := cam.project_ray_origin(pt)
	var v: Variant = view.call() if view.is_valid() else {}
	var vd: Dictionary = v if v is Dictionary else {}
	var mode := str(vd.get("mode", ""))
	var s := ViewCamera.ray_start(mode, o, d, vd.get("eye"))
	return [s, d, not (mode == "top" and s != o)]


## A short line under the pointer for a while (a refusal's reason in red).
func flash(text: String, bad := false) -> void:
	_flash = text.left(160)
	_flash_bad = bad
	_flash_until = Time.get_ticks_msec() + FLASH_MS


## Carrying an item with the mouse.
func carrying() -> bool:
	if hands == null:
		return false
	var h := hands.holding("mouse")
	return not h.is_empty() and h["kind"] == "item"


## Per frame: hover outline, the pointer icon and its line, the carried item's place.
## `enabled`: first person, nothing else using the mouse.
func update(cam: Camera3D, pt: Vector2, enabled: bool, captured: bool) -> void:
	if grabbed != null and not is_instance_valid(grabbed):
		grabbed = null
	icon.at = pt
	var text := ""
	if hands != null and cam != null and carrying():
		_carry(cam, pt)
		icon.mode = GrabIcon.FIST
		text = Hands.drop_hint(drop, world.tables)
	elif hands != null:
		var t := {}
		if grabbed == null and enabled and cam != null:
			var ray := ray_from(cam, pt)
			t = hands.find_on_ray(ray[0], ray[1], HOVER_M)
		hands.hover("mouse", t)
		hover = t["node"] if not t.is_empty() and t["kind"] == "door" else null
		item_hover = t if not t.is_empty() and t["kind"] == "item" else {}
		if grabbed != null:
			icon.mode = GrabIcon.FIST
		elif not t.is_empty():
			icon.mode = GrabIcon.HAND
			if not item_hover.is_empty():
				text = "%s\n%s take   hold %s carry" % [t["name"], InputActions.key_of(&"use_held"),
						InputActions.key_of(&"look_at")]
			else:   # a door leaf or furniture part (drawer, lid)
				text = "%s\nhold %s and drag" % [t["name"], InputActions.key_of(&"look_at")]
		else:
			icon.mode = GrabIcon.DOT if enabled and captured else GrabIcon.NONE
	else:
		var h: Grabbable = null
		if grabbed == null and enabled:
			var p := pick(cam, pt, HOVER_M)
			h = p[0] if not p.is_empty() else null
		_set_hover(h)
		if grabbed != null:
			icon.mode = GrabIcon.FIST
		elif hover != null:
			icon.mode = GrabIcon.HAND
		else:
			icon.mode = GrabIcon.DOT if enabled and captured else GrabIcon.NONE
	if Time.get_ticks_msec() < _flash_until:
		text = _flash
		icon.bad = _flash_bad
	else:
		icon.bad = false
	icon.text = text


## The carried item floats `carry_m` in front of the camera, or rests where the pointer meets a place it can go.
func _carry(cam: Camera3D, pt: Vector2) -> void:
	var held: ItemRef = hands.holding("mouse")["item"]
	var ray := ray_from(cam, pt)
	var o: Vector3 = ray[0]
	var d: Vector3 = ray[1]
	drop = hands.drop_on_ray(o, d, held)
	var pos := o + d * carry_m
	var p: Variant = drop.get("point")
	if drop.get("kind", "none") != "none" and p is Vector3 and o.distance_to(p) < carry_m:
		pos = p as Vector3
	hands.set_hand("mouse", Transform3D(cam.global_basis, pos))


func _set_hover(h: Grabbable) -> void:
	if h == hover:
		return
	if is_instance_valid(hover) and hover != grabbed:
		hover.set_highlight(false)
	hover = h
	if h != null:
		h.set_highlight(true)


## Press on a leaf or an item grabs it, motion drags a leaf, release lets go; true when the event was used.
func handle_event(event: InputEvent, cam: Camera3D, pt: Vector2) -> bool:
	if grabbed != null and not is_instance_valid(grabbed):
		grabbed = null
	if carrying():
		return _carry_event(event)
	if grabbed != null:
		if event is InputEventMouseMotion and cam != null:
			grabbed.drag_mouse((event as InputEventMouseMotion).relative, cam.global_basis)
			return true
		if event.is_action_released(&"look_at"):
			release()
			return true
		return false
	if not InputActions.pressed(event, &"look_at"):
		return false
	if hands != null:
		if cam == null:
			return false
		var ray := ray_from(cam, pt)
		var t := hands.find_on_ray(ray[0], ray[1], LookRay.MAX_M)
		if t.is_empty() or not hands.grab("mouse", t):
			return false
		if t["kind"] == "door":
			grabbed = t["node"]
		else:
			carry_m = clampf(float(t["dist"]), CARRY_MIN_M + 0.1, 1.2)
			item_hover = {}
		return true
	var p := pick(cam, pt)
	if p.is_empty():
		return false
	grabbed = p[0]
	grabbed.begin_grab(p[1])
	grabbed.set_highlight(true)
	return true


func _carry_event(event: InputEvent) -> bool:
	if event.is_action_released(&"look_at"):
		hands.release("mouse", drop)
		drop = {}
		return true
	if InputActions.pressed(event, &"carry_farther"):
		carry_m = minf(carry_m + CARRY_STEP_M, CARRY_MAX_M)
	elif InputActions.pressed(event, &"carry_closer"):
		carry_m = maxf(carry_m - CARRY_STEP_M, CARRY_MIN_M)
	elif InputActions.pressed(event, &"carry_turn_left"):
		hands.turn_held("mouse", TURN_STEP)
	elif InputActions.pressed(event, &"carry_turn_right"):
		hands.turn_held("mouse", -TURN_STEP)
	elif event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		hands.cancel("mouse")
		drop = {}
	elif not InputActions.pressed(event, &"look_at"):
		return false
	return true


## E on the item under the pointer takes it into the pack; true when the event was used that way.
func take_hovered(event: InputEvent) -> bool:
	if hands == null or item_hover.is_empty() or carrying() or not InputActions.pressed(event, &"use_held"):
		return false
	if not hands.take("mouse", item_hover, "pack"):
		flash("You can't take that now.", true)
	return true


func release() -> void:
	if is_instance_valid(grabbed):
		if hands != null and not hands.holding("mouse").is_empty():
			hands.release("mouse", {})
		else:
			grabbed.end_grab()
		grabbed.set_highlight(grabbed == hover)
	grabbed = null


## A leaf crossed its threshold in a live game: the main-loop action to queue ("" when the door isn't next to
## the player), remembering the prompt that will follow (the door's own square: the answer is worked out from
## where the prompt says the player stands then).
func want(square: Vector3i, open: bool, player: Vector3i, now: int) -> String:
	if not adjacent(square - player):
		return ""
	ask = {"word": "open" if open else "close", "square": square, "until": now + ASK_MS}
	return "open" if open else "close"


## The answer to CDDA's direction prompt when it is the one `a` waits for, else {}: the door's square relative
## to the prompt's `origin`, and only when that is one of the eight squares around it on the same level.
static func answer_for(a: Dictionary, req: Dictionary, now: int) -> Dictionary:
	if a.is_empty() or now > int(a["until"]) or req.get("kind", "") != "direction" or not req.get("id") is int:
		return {}
	if not str(req.get("text", "")).to_lower().contains(a["word"]):
		return {}
	var o: Variant = req.get("origin")
	if not o is Vector3i or not a.get("square") is Vector3i:
		return {}
	var d: Vector3i = a["square"] - (o as Vector3i)
	if not adjacent(d):
		return {}
	return {"id": req["id"], "pos": d}


## One of the eight squares around, same level.
static func adjacent(d: Vector3i) -> bool:
	return d.z == 0 and absi(d.x) <= 1 and absi(d.y) <= 1 and d != Vector3i.ZERO


## The pointer: a dot while the mouse looks around, an open hand over something to grab, a fist while dragging,
## and a short line under it (what you point at and its keys, where a carried item would go, a refusal).
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
	var text := "":
		set(v):
			if v != text:
				text = v
				queue_redraw()
	var bad := false:
		set(v):
			if v != bad:
				bad = v
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
		if text.is_empty() or mode == NONE and not bad:
			return
		var font := ThemeDB.fallback_font
		var y := at.y + 34.0
		for line in text.split("\n"):
			var w := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
			var p := Vector2(at.x - w / 2.0, y)
			draw_string_outline(font, p, line, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4, Color.BLACK)
			draw_string(font, p, line, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 0.45, 0.4) if bad else Color(1, 1, 0.9))
			y += 18.0
