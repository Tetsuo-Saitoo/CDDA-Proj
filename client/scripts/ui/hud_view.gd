class_name HudView
extends Control
## G1: the flat-screen view of HudData. Left edge, middle: the body (one bar per main body part, coloured by
## level), the move mode (walking, running ...) and the needs CDDA has words for, then the player's effects (coloured by rating), the message feed under
## them (the look panel keeps the bottom left); top centre: warnings, worst first, pulsing while one is
## bad; top right: an orange marker while any testing cheat is on. It only draws what HudData decided (VR draws the same data on the wrist, vr/). All text is plain Label
## text or draw_string, never BBCode.

const FEED_LINES := 6
const WARN_LINES := 3
const EFFECT_LINES := 8
const EFFECT_W := 220.0
const BAR_W := 90.0
const ROW_H := 16.0
const FONT_SIZE := 14
const CHEAT_COLOR := Color(1.0, 0.55, 0.1)
## The left column's top, in pixels from the screen's middle: the body block, then the mood line, then the feed,
## each under what the one above draws (_layout), so they never overlap however many rows CDDA sends.
const BODY_TOP := -140.0
## The warning lines' top (px from the screen's top), under the compass; lower while they would cover the developer
## status lines (avoid).
const WARN_TOP := 40.0
const MOOD_H := 36.0
## px the left column leaves at the bottom (the look panel) when it moves down under the status text (avoid).
const BOTTOM_KEEP := 80.0

var data: HudData:
	set(d):
		if data != null and data.changed.is_connected(_on_changed):
			data.changed.disconnect(_on_changed)
		data = d
		if d != null:
			d.changed.connect(_on_changed)
		_on_changed(PackedStringArray(["body", "needs", "effects", "move", "mood", "messages", "warnings", "cheats", "clock"]))

var feed: Label
var mood: Label
var warn: Label
var cheat_mark: Label
var clock_mark: Label   # HudData.clock: time runs, waits for you, or is paused
var _body: Control
var _shift := 0.0      # the left column's move down, under main's status text (avoid)
var _column_h := 0.0   # the left column's height: body block, mood line, feed (_layout)
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
	mood = _label("Mood", HORIZONTAL_ALIGNMENT_LEFT)   # between the body block and the feed (_layout)
	mood.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	mood.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	mood.position = Vector2(12, 0)
	mood.size = Vector2(310, MOOD_H)
	mood.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mood.max_lines_visible = 2
	mood.clip_text = true
	mood.add_theme_font_size_override("font_size", FONT_SIZE - 2)
	warn = _label("Warnings", HORIZONTAL_ALIGNMENT_CENTER)
	warn.set_anchors_preset(Control.PRESET_CENTER_TOP)
	warn.position = Vector2(-300, WARN_TOP)
	warn.size = Vector2(600, WARN_LINES * 20)
	cheat_mark = _label("Cheats", HORIZONTAL_ALIGNMENT_RIGHT)
	cheat_mark.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	cheat_mark.position = Vector2(-612, 8)
	cheat_mark.size = Vector2(600, 20)
	cheat_mark.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cheat_mark.add_theme_color_override("font_color", CHEAT_COLOR)
	clock_mark = _label("Clock", HORIZONTAL_ALIGNMENT_RIGHT)
	clock_mark.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	clock_mark.position = Vector2(-612, 8)
	clock_mark.size = Vector2(600, 20)
	_body = Control.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_body.position = Vector2(12, BODY_TOP)
	_body.size = Vector2(330 + EFFECT_W, 130)
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


## [text, level] of the move mode line (walking, running, crouching, prone), [] when unknown.
func move_line() -> Array:
	if data == null or data.move.is_empty():
		return []
	return [data.move["text"], data.move["level"]]


## [text, level] of the mood line ("Mood: Unhappy (Wet -12, Cold -8)"), [] when the snapshot has no morale.
func mood_line() -> Array:
	if data == null or data.mood.is_empty():
		return []
	return [data.mood["text"], data.mood["level"]]


## The mood line's colour: by level when low, green when good (Content and up: band 1..3), plain while calm.
static func mood_color(m: Dictionary) -> Color:
	var level: int = m.get("level", HudData.UNKNOWN)
	if level == HudData.HURT or level == HudData.BAD:
		return HudData.level_color(level)
	var band: Variant = m.get("band")
	return HudData.level_color(HudData.OK) if band is int and band > 0 else Color(1, 1, 0.9)


## [text, level] per effect line shown (at most EFFECT_LINES; the last says how many more when cut).
func effect_lines() -> Array:
	var out: Array = []
	if data == null:
		return out
	var n := data.effects.size()
	for i in mini(n, EFFECT_LINES):
		if i == EFFECT_LINES - 1 and n > EFFECT_LINES:
			out.append(["+%d more" % (n - i), HudData.UNKNOWN])
			break
		out.append([data.effects[i]["text"], data.effects[i]["level"]])
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
		mood.text = ""
		warn.text = ""
		cheat_mark.text = ""
		clock_mark.text = ""
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
	if "clock" in parts:
		clock_mark.text = data.clock
		clock_mark.add_theme_color_override("font_color",
				HudData.level_color(HudData.HURT if data.clock.begins_with("TIME PAUSED") else HudData.OK))
		cheat_mark.position.y = 30.0 if not data.clock.is_empty() else 8.0   # the cheats under it
	if "mood" in parts:
		var ml := mood_line()
		mood.text = ml[0] if not ml.is_empty() else ""
		mood.add_theme_color_override("font_color", mood_color(data.mood))
	if "body" in parts or "needs" in parts or "effects" in parts or "move" in parts:
		_body.queue_redraw()
	if "body" in parts or "needs" in parts or "effects" in parts or "move" in parts or "mood" in parts:
		_layout()


## The mood line goes under the body block's tallest column (body bars, move and needs, effects), the feed under
## the mood line, or under the body when there is none.
func _layout() -> void:
	var needs := need_lines().size() + (0 if move_line().is_empty() else 1)
	var rows := maxi(body_rows().size(), maxi(needs, effect_lines().size()))
	var top := BODY_TOP + _shift
	_place(_body, top)
	var y := top + rows * ROW_H + 6.0
	_place(mood, y)
	if not mood.text.is_empty():
		y += MOOD_H + 4.0
	_place(feed, y)
	_column_h = y + (feed.offset_bottom - feed.offset_top) - top


## Where the top right marks (the time line, the cheats) end, in px from the top; 0 when both are empty. The
## hints go under them.
func marks_bottom() -> float:
	var b := 0.0
	for m: Label in [clock_mark, cheat_mark]:
		if m.visible and not m.text.is_empty():
			b = maxf(b, m.position.y + maxf(m.size.y, m.get_combined_minimum_size().y))
	return b


## The left column (body, mood, feed) as drawn on screen; other panels keep off it (RideHud).
func column_rect() -> Rect2:
	var w := 330.0 + (EFFECT_W if data != null and not effect_lines().is_empty() else 0.0)
	w = maxf(w, feed.get_combined_minimum_size().x)
	return Rect2(global_position + Vector2(12.0, size.y / 2.0 + BODY_TOP + _shift), Vector2(w, _column_h))


## How far down (px from this view's top) main's status text may reach: the left column moves down under it
## (avoid) while keeping BOTTOM_KEEP px at the bottom, and never above its own place.
func text_limit() -> float:
	var home := size.y / 2.0 + BODY_TOP
	return maxf(home, size.y - BOTTOM_KEEP - _column_h) - 4.0


## `box`: the developer status lines' text (main.gd's top-left label, in this view's canvas; empty while hidden). The
## left column (body, mood, feed) moves down under it, as far as text_limit allows. The warning lines go just
## under it while their text (centred) would overlap it, else back under the compass. A box reaching down the
## screen pushes them no lower than the bottom edge: they stay in sight.
func avoid(box: Rect2) -> void:
	var home := size.y / 2.0 + BODY_TOP
	var shift := 0.0
	if box.has_area():
		shift = clampf(box.end.y - global_position.y + 4.0 - home, 0.0, maxf(text_limit() + 4.0 - home, 0.0))
	if not is_equal_approx(shift, _shift):
		_shift = shift
		_layout()
	var top := WARN_TOP
	if not warn.text.is_empty() and box.has_area():
		var w := warn.get_combined_minimum_size().x
		var mine := Rect2(global_position.x + (size.x - w) / 2.0, global_position.y + WARN_TOP, w, warn.size.y)
		if mine.intersects(box):
			top = maxf(WARN_TOP, minf(box.end.y - global_position.y + 4.0, size.y - warn.size.y))
	if not is_equal_approx(warn.offset_top, top):
		_place(warn, top)


## Moves `c` to `y` px from its anchor (the left middle; the warnings: the top), keeping its height.
static func _place(c: Control, y: float) -> void:
	var h := c.offset_bottom - c.offset_top
	c.offset_top = y
	c.offset_bottom = y + h


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
	var mv := move_line()   # first in the needs column, coloured by its level
	if not mv.is_empty():
		_body.draw_string_outline(font, Vector2(x, ROW_H - 3), mv[0], HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2, 3,
				Color.BLACK)
		_body.draw_string(font, Vector2(x, ROW_H - 3), mv[0], HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2,
				HudData.level_color(mv[1]))
		ny += ROW_H
	for line in need_lines():
		_body.draw_string_outline(font, Vector2(x, ny + ROW_H - 3), line, HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2, 3,
				Color.BLACK)
		_body.draw_string(font, Vector2(x, ny + ROW_H - 3), line, HORIZONTAL_ALIGNMENT_LEFT, 105, FONT_SIZE - 2, Color(1, 1, 0.9))
		ny += ROW_H
	var ey := 0.0
	for r in effect_lines():
		var text: String = r[0]
		_body.draw_string_outline(font, Vector2(330, ey + ROW_H - 3), text, HORIZONTAL_ALIGNMENT_LEFT, EFFECT_W,
				FONT_SIZE - 2, 3, Color.BLACK)
		_body.draw_string(font, Vector2(330, ey + ROW_H - 3), text, HORIZONTAL_ALIGNMENT_LEFT, EFFECT_W, FONT_SIZE - 2,
				HudData.level_color(r[1]))
		ey += ROW_H
