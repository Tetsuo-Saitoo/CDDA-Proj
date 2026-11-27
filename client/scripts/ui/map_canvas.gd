class_name MapCanvas
extends Control
## G5 map (lead-ui, 2026-11-26; docs/MAP.md): the one painter of the overmap, for the screen map (MapView) and VR's
## held map (lead-vr's vr_map.gd shows it in a SubViewport). It draws only from `data` (MapData): each cell in CDDA's
## symbol and colour at the vision level the player has (dimmer the less is known; unseen and unread cells are fog),
## the notes (a danger note's area tinted), the destination's path and the player. Below GLYPH_MIN a cell is its
## colour only. Each canvas keeps its own view (level, middle, zoom) and tells MapData which pages it shows.

## The view moved (pan, zoom, level, back to the player).
signal view_moved

const MIN_CELL := 8.0
const MAX_CELL := 48.0
const ZOOM_STEP := 1.25
const GLYPH_MIN := 16.0       # glyphs from this cell size up
const BACK := Color(0.03, 0.035, 0.04)
const FOG := Color(0.1, 0.105, 0.11)
const GLYPH_BACK := 0.22      # how bright a cell's colour is behind its glyph
const PATH := Color(1.0, 0.85, 0.3, 0.9)
const DANGER := Color(1.0, 0.1, 0.1, 0.22)
const PLAYER := Color(1.0, 1.0, 1.0)
const CURSOR := Color(1.0, 1.0, 1.0, 0.9)
const OUTLINE := Color(0.0, 0.0, 0.0, 0.85)
## How bright a cell is by CDDA's vision level (0 unseen .. 4 full).
const SHADE := [0.0, 0.5, 0.65, 0.82, 1.0]

var data: MapData:
	set(v):
		if data != null and data.changed.is_connected(_on_data):
			data.changed.disconnect(_on_data)
		data = v
		_textures.clear()
		if data != null:
			data.changed.connect(_on_data)
		_moved(false)
## The level shown (CDDA's z).
var level := 0
## Pixels on a cell's side.
var cell_px := 20.0
## The map point (in cells; a cell's middle is its x + 0.5) at the canvas's middle.
var middle := Vector2(0.5, 0.5)

## The picked cell on the shown level (pick); has_cursor false: none.
var cursor := Vector2i.ZERO
var has_cursor := false
var _textures := {}   # Vector3i page origin -> [MapData.Page, ImageTexture]


func _init() -> void:
	name = "MapCanvas"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # the view around it takes the mouse (MapView) or a hand's ray (VR)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_moved(false)


## The cell (absolute OMT x, y on `level`) under `local_px`.
func cell_at(local_px: Vector2) -> Vector2i:
	var m := to_map(local_px)
	return Vector2i(floori(m.x), floori(m.y))


func to_map(local_px: Vector2) -> Vector2:
	return middle + (local_px - size * 0.5) / cell_px


func to_px(map_point: Vector2) -> Vector2:
	return (map_point - middle) * cell_px + size * 0.5


## Moves the map with the pointer by `delta` pixels, 1:1, keeping the part of a cell.
func pan_px(delta: Vector2) -> void:
	if delta == Vector2.ZERO or not delta.is_finite():
		return
	middle = _bounded(middle - delta / cell_px)
	_moved()


## Zooms in (steps > 0) or out, keeping the map point under `local_px` where it is.
func zoom_at(local_px: Vector2, steps: int) -> void:
	var was := cell_px
	var under := to_map(local_px)
	cell_px = clampf(cell_px * pow(ZOOM_STEP, clampi(steps, -8, 8)), MIN_CELL, MAX_CELL)
	if cell_px == was:
		return
	middle = _bounded(under - (local_px - size * 0.5) / cell_px)
	_moved()


func change_level(dz: int) -> void:
	var was := level
	level = clampi(level + dz, MapData.Z_MIN, MapData.Z_MAX)
	if level != was:
		_moved()


## Back to the player's cell and level.
## Picks cell `c` on the shown level (MapView: a click; its note dialog writes there): drawn as a box.
func pick(c: Vector2i) -> void:
	cursor = c
	has_cursor = true
	queue_redraw()


func center_on_player() -> void:
	if data == null or not data.has_player:
		return
	level = data.player_cell.z
	middle = Vector2(data.player_cell.x + 0.5, data.player_cell.y + 0.5)
	_moved()


## The view is put away: MapData no longer reads for it.
func release() -> void:
	if data != null:
		data.want(Rect2i(), level, get_instance_id())


## Shown again (or first): MapData reads what it shows.
func refresh() -> void:
	_moved(false)


## The cells the canvas shows now.
func visible_cells() -> Rect2i:
	var lo := cell_at(Vector2.ZERO)
	var hi := cell_at(size)
	return Rect2i(lo, hi - lo + Vector2i.ONE)


static func _bounded(p: Vector2) -> Vector2:
	var m := float(MapData.MAX_XY)
	return Vector2(clampf(p.x, -m, m), clampf(p.y, -m, m))


func _moved(tell := true) -> void:
	if data != null and size.x >= 1.0 and size.y >= 1.0 and is_visible_in_tree():
		data.want(visible_cells(), level, get_instance_id())
	queue_redraw()
	if tell:
		view_moved.emit()


func _on_data() -> void:
	for o: Vector3i in _textures.keys():   # drop the images of pages read again or let go
		if data == null or data.page(o) != _textures[o][0]:
			_textures.erase(o)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACK)
	if data == null:
		return
	var r := visible_cells()
	var glyphs := cell_px >= GLYPH_MIN
	var font := get_theme_default_font()
	var fsize := int(cell_px * 0.8)
	var lo := MapData.page_origin(Vector3i(r.position.x, r.position.y, level))
	var shown: Array[MapData.Page] = []
	var y := lo.y
	while y < r.end.y:
		var x := lo.x
		while x < r.end.x:
			var o := Vector3i(x, y, level)
			var at := Rect2(to_px(Vector2(x, y)), Vector2.ONE * (MapData.PAGE * cell_px))
			var pg := data.page(o)
			if pg == null:
				draw_rect(at, FOG)
			else:
				var g := GLYPH_BACK if glyphs else 1.0
				draw_texture_rect(_texture(pg), at, false, Color(g, g, g))
				if glyphs:
					_draw_glyphs(pg, r, font, fsize)
				shown.append(pg)
			x += MapData.PAGE
		y += MapData.PAGE
	for a: Rect2i in danger_areas():
		draw_rect(Rect2(to_px(Vector2(a.position)), Vector2(a.size) * cell_px), DANGER)
	for pg: MapData.Page in shown:
		_draw_notes(pg, glyphs, font, fsize)
	_draw_path()
	if has_cursor:
		draw_rect(Rect2(to_px(Vector2(cursor)), Vector2.ONE * cell_px), CURSOR, false, 2.0)
	_draw_player()


## The page as one pixel a cell: its look's colour at its vision's shade, fog where unseen.
func _texture(pg: MapData.Page) -> ImageTexture:
	var held: Array = _textures.get(pg.origin, [])
	if not held.is_empty() and held[0] == pg:
		return held[1]
	var img := Image.create(MapData.PAGE, MapData.PAGE, false, Image.FORMAT_RGBA8)
	for ly in MapData.PAGE:
		for lx in MapData.PAGE:
			img.set_pixel(lx, ly, cell_color(pg, ly * MapData.PAGE + lx))
	var tex := ImageTexture.create_from_image(img)
	_textures[pg.origin] = [pg, tex]
	return tex


## Cell i's colour on page pg: its look's, darker the less it was seen; fog unseen; grey when seen but its look
## was left out of a full page.
static func cell_color(pg: MapData.Page, i: int) -> Color:
	var v := pg.vision[i]
	if v == 0:
		return FOG
	var k := pg.look[i]
	var base: Color = pg.looks[k - 1]["color"] if k > 0 and k <= pg.looks.size() else MapData.UNSENT
	var f: float = SHADE[mini(v, MapData.MAX_VISION)]
	return Color(base.r * f, base.g * f, base.b * f)


func _draw_glyphs(pg: MapData.Page, r: Rect2i, font: Font, fsize: int) -> void:
	var x0 := maxi(r.position.x, pg.origin.x)
	var x1 := mini(r.end.x, pg.origin.x + MapData.PAGE)
	var y0 := maxi(r.position.y, pg.origin.y)
	var y1 := mini(r.end.y, pg.origin.y + MapData.PAGE)
	for cy in range(y0, y1):
		for cx in range(x0, x1):
			var i := (cy - pg.origin.y) * MapData.PAGE + (cx - pg.origin.x)
			var v := pg.vision[i]
			var k := pg.look[i]
			if v == 0 or k == 0 or k > pg.looks.size() or pg.notes.has(Vector2i(cx - pg.origin.x, cy - pg.origin.y)):
				continue
			var l: Dictionary = pg.looks[k - 1]
			var base: Color = l["color"]
			var f: float = SHADE[mini(v, MapData.MAX_VISION)]
			_glyph(Vector2(cx, cy), l["symbol"], Color(base.r * f, base.g * f, base.b * f), font, fsize)


func _glyph(cell: Vector2, symbol: String, color: Color, font: Font, fsize: int) -> void:
	var p := to_px(cell)
	draw_string(font, p + Vector2(0, cell_px * 0.8), symbol, HORIZONTAL_ALIGNMENT_CENTER, cell_px, fsize, color)


## The danger areas (cells) of read notes that reach into the view, also from read pages up to MAX_RADIUS cells
## outside it (a page is read while it is shown, so a note far off counts once its page has been on screen).
func danger_areas() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	if data == null:
		return out
	var r := visible_cells()
	var reach := r.grow(MapData.MAX_RADIUS)
	var lo := MapData.page_origin(Vector3i(reach.position.x, reach.position.y, level))
	var y := lo.y
	while y < reach.end.y:
		var x := lo.x
		while x < reach.end.x:
			var pg := data.page(Vector3i(x, y, level))
			if pg != null:
				for lc: Vector2i in pg.notes:
					var n: Dictionary = pg.notes[lc]
					var rad: int = n["radius"]
					var a := Rect2i(x + lc.x - rad, y + lc.y - rad, 2 * rad + 1, 2 * rad + 1)
					if n["danger"] and a.intersects(r):
						out.append(a)
			x += MapData.PAGE
		y += MapData.PAGE
	return out


func _draw_notes(pg: MapData.Page, glyphs: bool, font: Font, fsize: int) -> void:
	for lc: Vector2i in pg.notes:
		var n: Dictionary = pg.notes[lc]
		var cell := Vector2(pg.origin.x + lc.x, pg.origin.y + lc.y)
		if glyphs:
			draw_rect(Rect2(to_px(cell), Vector2.ONE * cell_px), OUTLINE)
			_glyph(cell, n["symbol"], n["color"], font, fsize)
		else:
			draw_circle(to_px(cell + Vector2(0.5, 0.5)), maxf(2.0, cell_px * 0.4), n["color"])


func _draw_path() -> void:
	var pts := PackedVector2Array()
	for c in data.path:
		if c.z == level:
			pts.append(to_px(Vector2(c.x + 0.5, c.y + 0.5)))
	if pts.size() >= 2:
		draw_polyline(pts, PATH, maxf(1.5, cell_px * 0.15))
	var d: Variant = data.destination
	if d is Vector3i and (d as Vector3i).z == level:
		var p := to_px(Vector2((d as Vector3i).x + 0.5, (d as Vector3i).y + 0.5))
		var s := maxf(3.0, cell_px * 0.35)
		draw_line(p - Vector2(s, s), p + Vector2(s, s), PATH, 2.0)
		draw_line(p - Vector2(s, -s), p + Vector2(s, -s), PATH, 2.0)


func _draw_player() -> void:
	if not data.has_player:
		return
	var c := data.player_cell
	var p := to_px(Vector2(c.x + 0.5, c.y + 0.5))
	var rad := maxf(3.0, cell_px * 0.35)
	if c.z == level:
		draw_circle(p, rad + 1.5, OUTLINE)
		draw_circle(p, rad, PLAYER)
	else:   # on another level: an empty ring where the player is
		draw_arc(p, rad, 0.0, TAU, 24, PLAYER, 2.0)
