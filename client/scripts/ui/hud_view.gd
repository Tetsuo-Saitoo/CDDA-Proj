class_name HudView
extends Control
## G1: the flat-screen view of HudData. Left edge, middle: the body (one bar per main body part, coloured by
## level) and the needs CDDA has words for, the message feed under them (the look panel keeps the bottom left); top centre: warnings, worst first, pulsing while one is
## bad; top right: an orange marker while any testing cheat is on. It only draws what HudData decided (VR draws the same data on the wrist, vr/). All text is plain Label
## text or draw_string, never BBCode.

const FEED_LINES := 6
const WARN_LINES := 3
const BAR_W := 90.0
const ROW_H := 16.0
const FONT_SIZE := 14
const CHEAT_COLOR := Color(1.0, 0.55, 0.1)

var data: HudData:
	set(d):
		if data != null and data.changed.is_connected(_on_changed):
			data.changed.disconnect(_on_changed)
		data = d
		if d != null:
			d.changed.connect(_on_changed)
		_on_changed(PackedStringArray(["body", "needs", "messages", "warnings", "cheats"]))

var feed: Label
var warn: Label
var cheat_mark: Label
var _body: Control
var _pulse := 0.0


func _init() -> void:
	name = "HudView"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed = _label("Feed", HORIZONTAL_ALIGNMENT_LEFT)
	feed.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	feed.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	feed.position = Vector2(12, 40)
	feed.size = Vector2(560, FEED_LINES * 18)
	warn = _label("Warnings", HORIZONTAL_ALIGNMENT_CENTER)
	warn.set_anchors_preset(Control.PRESET_CENTER_TOP)
	warn.position = Vector2(-300, 40)
	warn.size = Vector2(600, WARN_LINES * 20)
	cheat_mark = _label("Cheats", HORIZONTAL_ALIGNMENT_RIGHT)
	cheat_mark.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	cheat_mark.position = Vector2(-612, 8)
	cheat_mark.size = Vector2(600, 20)
	cheat_mark.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cheat_mark.add_theme_color_override("font_color", CHEAT_COLOR)
	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_body.position = Vector2(12, -100)
	_body.size = Vector2(320, 130)
	_body.draw.connect(_draw_body)
	add_child(_body)


func _label(n: String, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.name = n
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	add_child(l)
	return l


func _process(delta: float) -> void:
	if data == null or data.warnings.is_empty() or int(data.warnings[0]["level"]) < HudData.BAD:
		warn.modulate.a = 1.0
		return
	_pulse = fmod(_pulse + delta * 2.0, TAU)
	warn.modulate.a = 0.65 + 0.35 * sin(_pulse)


## [name, frac, level] per body bar, in order (also what the tests read).
func body_rows() -> Array:
	var out: Array = []
	if data != null:
		for p: Dictionary in data.body:
			out.append([p["name"], p["frac"], p["level"]])
	return out


## The need lines shown: CDDA's word, or the stamina bar's label; unknown needs are left out.
func need_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if data == null:
		return out
	for k: String in HudData.NEEDS:
		var n: Dictionary = data.needs[k]
		if n["level"] == HudData.UNKNOWN:
			continue
		if k == "stamina":
			out.append("stamina %d%%" % n["value"])
		elif not (n["word"] as String).is_empty():
			out.append(n["word"])
	return out


## "CHEATS: invincible, night vision" for the names on, "" for none.
static func cheat_text(names: PackedStringArray) -> String:
	if names.is_empty():
		return ""
	var words := PackedStringArray()
	for n in names:
		words.append(n.replace("_", " "))
	return "CHEATS: " + ", ".join(words)


func _on_changed(parts: PackedStringArray) -> void:
	if data == null:
		feed.text = ""
		warn.text = ""
		cheat_mark.text = ""
		_body.queue_redraw()
		return
	if "messages" in parts:
		var lines := PackedStringArray()
		for m: Dictionary in data.messages.slice(maxi(0, data.messages.size() - FEED_LINES)):
			lines.append(m["text"])
		feed.text = "\n".join(lines)
	if "warnings" in parts:
		var lines := PackedStringArray()
		for w: Dictionary in data.warnings.slice(0, WARN_LINES):
			lines.append(w["text"])
		warn.text = "\n".join(lines)
		var worst: int = data.warnings[0]["level"] if not data.warnings.is_empty() else HudData.OK
		warn.add_theme_color_override("font_color", HudData.level_color(worst))
	if "cheats" in parts:
		cheat_mark.text = cheat_text(data.cheats)
	if "body" in parts or "needs" in parts:
		_body.queue_redraw()


func _draw_body() -> void:
	var font := ThemeDB.fallback_font
	var y := 0.0
	for r in body_rows():
		var col := HudData.level_color(r[2])
		var name_s: String = r[0]
		_body.draw_string_outline(font, Vector2(0, y + ROW_H - 3), name_s, HORIZONTAL_ALIGNMENT_LEFT, 110, FONT_SIZE - 2, 3,
				Color.BLACK)
		_body.draw_string(font, Vector2(0, y + ROW_H - 3), name_s, HORIZONTAL_ALIGNMENT_LEFT, 110, FONT_SIZE - 2, col)
		var bar := Rect2(115, y + 4, BAR_W, ROW_H - 7)
		_body.draw_rect(bar.grow(1), Color(0, 0, 0, 0.7))
		_body.draw_rect(Rect2(bar.position, Vector2(BAR_W * float(r[1]), bar.size.y)), col)
		y += ROW_H
	var x := 215.0
	var ny := 0.0
	for line in need_lines():
		_body.draw_string_outline(font, Vector2(x, ny + ROW_H - 3), line, HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2, 3,
				Color.BLACK)
		_body.draw_string(font, Vector2(x, ny + ROW_H - 3), line, HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2, Color(1, 1, 0.9))
		ny += ROW_H
