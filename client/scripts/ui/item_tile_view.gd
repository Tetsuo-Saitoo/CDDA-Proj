class_name ItemTileView
extends Control
## Block "Live item tiles": an item's live state (an ItemTile) drawn behind its row in the Tab view or its line in
## the hands panel: how full it is as a band in the contents' colour with a solid line along the bottom (slice 2: a
## liquid's edge leans and settles back, Slosh, when the Tab view opens, a row is picked up to drag, the view turns
## or the player steps), a see-through container's glass (a faint sheen, its floor and a glint, empty or not:
## slice 4), a soft edge for
## frozen, cold or hot, a spoilage strip at the left for things that rot, and soot over a fouled gun. The band and
## soot are faint, so the row's text stays readable over them; the amount itself is a Label in the row
## (InspectView). Takes no mouse input: clicks, selection and drags reach the row under it.

const BAND_ALPHA := 0.24     # the fill band behind the row's text
const LINE_H := 3.0          # the fill line along the bottom
const ROT_W := 4.0           # the spoilage strip
const EDGE := 4              # px of the temperature edge, fading inward
const SOOT := Color(0.16, 0.12, 0.08)
const SOOT_ALPHA := 0.45     # the soot film at full grime
const SPECKS := 40           # soot specks at full grime
const SPECK := Vector2(2, 2)
const GLASS := Color(0.85, 0.93, 1.0)   # a see-through container, full or empty
const GLASS_ALPHA := 0.07

const LEAN_PX := 10.0        # how far the fill's edge leans at full slosh (top one way, bottom the other)
const STIR_MAX := 5.0        # one stir() at most
const DRAG_KICK := 3.0       # a row picked up to drag
const OPEN_STIR := 1.5       # the Tab view opening (main)
const TURN_STIR := 0.035     # per degree the view turns (main): a quick quarter turn is about a drag's kick
const STEP_STIR := 1.2       # a step (main), each one rocking the other way
const CARRY_MS := 1000       # a still-moving surface goes on in its item's next row made within this
const MAX_CARRIED := 64

## Slice 2: every sloshing tile feels the same stirs (main: the Tab view opening, the view turning, a step), as a
## running sum each tile catches up with in its own frame.
static var stirred := 0.0
## uid -> [Slosh, msec]: surfaces still moving when their row went (the Tab view rebuilds its rows each turn).
static var _carried := {}

## The ItemTile drawn.
var tile := {}
## Where the row's own content starts (its indent): nothing is drawn left of it.
var inset := 0.0
## A liquid's surface (tile.sloshes); null for anything else.
var slosh: Slosh
## The item's uid, -1 none: a moving surface is handed on to its next row.
var uid := -1
var _seen := 0.0


## Shoves every sloshing tile by `amount` (tilt per second, capped; signed: which way it leans).
static func stir(amount: float) -> void:
	if is_finite(amount):
		stirred += clampf(amount, -STIR_MAX, STIR_MAX)


func _init(t: Dictionary = {}, left := 0.0, id := -1) -> void:
	name = "ItemTile"
	tile = t
	inset = maxf(left, 0.0) if is_finite(left) else 0.0
	uid = id
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	if tile.get("sloshes", false) == true and float(tile.get("level", -1.0)) > 0.0:
		slosh = _take(uid)
	_seen = stirred
	set_process(slosh != null)


## The surface `id`'s last row left moving (CARRY_MS ago at most), else a still one.
static func _take(id: int) -> Slosh:
	var c: Variant = _carried.get(id)
	_carried.erase(id)
	if c is Array and Time.get_ticks_msec() - int(c[1]) <= CARRY_MS:
		return c[0]
	return Slosh.new()


func _exit_tree() -> void:
	if uid >= 0 and slosh != null and slosh.moving():
		if _carried.size() >= MAX_CARRIED:
			_carried.clear()
		_carried[uid] = [slosh, Time.get_ticks_msec()]


## Shoves this tile's liquid alone (its row picked up for a drag); nothing for a tile that doesn't slosh.
func kick(amount := DRAG_KICK) -> void:
	if slosh != null:
		slosh.push(clampf(amount, -STIR_MAX, STIR_MAX) if is_finite(amount) else 0.0)
		queue_redraw()


## Takes the stirs since the last frame and moves the surface on; tests call it with their own `delta`.
func tick(delta: float) -> void:
	if slosh == null:
		return
	if stirred != _seen:
		slosh.push(stirred - _seen)
		_seen = stirred
	var was := slosh.moving()
	if slosh.step(delta) or was:
		queue_redraw()


func _process(delta: float) -> void:
	if is_visible_in_tree():
		tick(delta)
	else:
		_seen = stirred   # stirs while hidden (the Tab view closed) are not saved up


func _draw() -> void:
	var r := Rect2(Vector2(minf(inset, size.x), 0.0), Vector2(maxf(size.x - inset, 0.0), size.y))
	if r.size.x < 1.0 or r.size.y < 1.0:
		return
	var grime := clampf(float(tile.get("grime", -1.0)), 0.0, 1.0)
	if grime > 0.0:
		draw_rect(r, Color(SOOT, SOOT_ALPHA * grime))
		var room := (r.size - SPECK).max(Vector2.ZERO)
		for i in int(SPECKS * grime):   # the same specks every time (golden-ratio steps)
			var at := Vector2(fposmod(i * 0.618034, 1.0), fposmod(0.31 + i * 0.754878, 1.0))
			draw_rect(Rect2(r.position + at * room, SPECK), Color(SOOT.darkened(0.4), 0.5 + 0.4 * grime))
	var raw_level := float(tile.get("level", -1.0))
	if tile.get("see_through", false) == true and raw_level >= 0.0:   # glass: a faint sheen, its floor, a glint
		draw_rect(r, Color(GLASS, GLASS_ALPHA))
		draw_rect(Rect2(r.position.x, r.end.y - 1.0, r.size.x, 1.0), Color(GLASS, 0.45))
		if r.size.x > 24.0 and r.size.y > 8.0:
			draw_line(Vector2(r.end.x - 16.0, r.end.y - 3.0), Vector2(r.end.x - 10.0, r.position.y + 3.0),
					Color(GLASS, 0.35), 1.0)
	var level := clampf(raw_level, 0.0, 1.0)
	var liquid: Color = tile.get("liquid", ItemLook.LIQUID_DEFAULT)
	if level > 0.0:
		var w := maxf(r.size.x * level, 2.0)
		var lean := clampf(slosh.tilt, -1.0, 1.0) * minf(LEAN_PX, w * 0.5) if slosh != null else 0.0
		var top := clampf(r.position.x + w + lean, r.position.x, r.end.x)
		var bottom := clampf(r.position.x + w - lean, r.position.x, r.end.x)
		draw_colored_polygon(PackedVector2Array([r.position, Vector2(top, r.position.y), Vector2(bottom, r.end.y),
				Vector2(r.position.x, r.end.y)]), Color(liquid, BAND_ALPHA))
		draw_rect(Rect2(r.position.x, r.end.y - LINE_H, bottom - r.position.x, LINE_H), Color(liquid, 0.95))
	if int(tile.get("rot", -1)) >= 0:
		draw_rect(Rect2(r.position, Vector2(minf(ROT_W, r.size.x), r.size.y)), tile.get("rot_color", ItemLook.FRESH_COLOR))
	var edge: Color = tile.get("temp_color", ItemTile.CLEAR)
	if edge.a > 0.0 and r.size.x > EDGE * 2 and r.size.y > EDGE * 2:
		for i in EDGE:   # 1 px rings, fading inward
			draw_rect(r.grow(-0.5 - i), Color(edge, edge.a * (1.0 - float(i) / EDGE)), false, 1.0)
