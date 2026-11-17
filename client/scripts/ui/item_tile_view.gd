class_name ItemTileView
extends Control
## Block "Live item tiles", slice 1: an item's live state (an ItemTile) drawn behind its row in the Tab view, static
## for now: how full it is as a band in the contents' colour with a solid line along the bottom, a soft edge for
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

## The ItemTile drawn.
var tile := {}
## Where the row's own content starts (its indent): nothing is drawn left of it.
var inset := 0.0


func _init(t: Dictionary = {}, left := 0.0) -> void:
	name = "ItemTile"
	tile = t
	inset = maxf(left, 0.0) if is_finite(left) else 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


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
	var level := clampf(float(tile.get("level", -1.0)), 0.0, 1.0)
	var liquid: Color = tile.get("liquid", ItemLook.LIQUID_DEFAULT)
	if level > 0.0:
		var w := maxf(r.size.x * level, 2.0)
		draw_rect(Rect2(r.position, Vector2(w, r.size.y)), Color(liquid, BAND_ALPHA))
		draw_rect(Rect2(r.position.x, r.end.y - LINE_H, w, LINE_H), Color(liquid, 0.95))
	if int(tile.get("rot", -1)) >= 0:
		draw_rect(Rect2(r.position, Vector2(minf(ROT_W, r.size.x), r.size.y)), tile.get("rot_color", ItemLook.FRESH_COLOR))
	var edge: Color = tile.get("temp_color", ItemTile.CLEAR)
	if edge.a > 0.0 and r.size.x > EDGE * 2 and r.size.y > EDGE * 2:
		for i in EDGE:   # 1 px rings, fading inward
			draw_rect(r.grow(-0.5 - i), Color(edge, edge.a * (1.0 - float(i) / EDGE)), false, 1.0)
