class_name Compass
extends Control
## Heading strip at the top of the screen. CDDA's north is -z in Godot space (CDDA y points south).

const SPAN_DEG := 180.0   # degrees shown across the strip
const LETTERS := {0: "N", 45: "NE", 90: "E", 135: "SE", 180: "S", 225: "SW", 270: "W", 315: "NW"}
const FONT_SIZE := 14

var heading_deg := 0.0:
	set(v):
		heading_deg = fposmod(v, 360.0)
		queue_redraw()


## Compass heading of a view (0 north, 90 east); looking straight down, up on screen counts as forward.
static func heading_of(b: Basis) -> float:
	var f := -b.z
	if Vector2(f.x, f.z).length() < 0.01:
		f = b.y
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.4))
	var font := get_theme_default_font()
	for deg in range(0, 360, 15):
		var off := wrapf(deg - heading_deg, -180.0, 180.0)
		if absf(off) > SPAN_DEG / 2.0:
			continue
		var x := w / 2.0 + off / SPAN_DEG * w
		if LETTERS.has(deg):
			var t: String = LETTERS[deg]
			var col := Color(1.0, 0.4, 0.3) if deg == 0 else Color.WHITE
			var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
			draw_string(font, Vector2(x - tw / 2.0, h - 5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, col)
			draw_line(Vector2(x, 0), Vector2(x, 7), col, 2.0)
		else:
			draw_line(Vector2(x, 0), Vector2(x, 5), Color(1, 1, 1, 0.6), 1.0)
	draw_line(Vector2(w / 2.0, 0), Vector2(w / 2.0, h), Color(1.0, 0.85, 0.2), 2.0)
	var deg_text := "%d°" % (roundi(heading_deg) % 360)
	draw_string(font, Vector2(w + 6, h - 5), deg_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color.WHITE)
