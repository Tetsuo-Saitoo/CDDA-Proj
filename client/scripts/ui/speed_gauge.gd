class_name SpeedGauge
extends Control
## The driving HUD's speedometer (RideHud): a 240-degree dial, its scale green up to the vehicle's safe speed, amber
## up to its top speed, red beyond; the needle at the speed, a marker at the throttle / cruise setting (the driver's
## only; dim while cruise is off), and the speed in the player's units under it, "R" in reverse. Drawn, no children.

const SIZE := Vector2(220, 142)
const CENTRE := Vector2(110, 84)
const RADIUS := 66.0
const START_DEG := 150.0   # 0 sits down left; the dial runs clockwise over the top to down right
const SWEEP_DEG := 240.0
const ARC_W := 7.0
const BAND_COLORS := [Color(0.35, 0.8, 0.35), Color(0.95, 0.7, 0.2), Color(0.9, 0.25, 0.2)]
const UNKNOWN_COLOR := Color(0.55, 0.55, 0.55)
const CRUISE_COLOR := Color(0.35, 0.85, 1.0)
const STEPS := [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]

var info := RideInfo.new():
	set(v):
		info = v if v != null else RideInfo.new()
		queue_redraw()


func _init() -> void:
	name = "SpeedGauge"
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## The dial's top, in shown units: past the top speed (or the safe one, or the speed itself), on a round step.
static func scale_top(r: RideInfo) -> float:
	var want := maxf(maxf(r.shown(r.top) * 1.15, r.shown(r.safe) * 1.3), maxf(absf(r.shown(r.velocity)), 10.0))
	var step := tick_step(want)
	return ceilf(want / step - 0.001) * step


## A round tick step giving 4 to 8 ticks up to `top`.
static func tick_step(top: float) -> float:
	for s: int in STEPS:
		if top / s <= 8.0:
			return float(s)
	return ceilf(top / 8.0)


## The angle (radians, Godot's: clockwise from the right) of `shown` speed on a dial up to `top`.
static func angle_of(shown: float, top: float) -> float:
	var f := clampf(absf(shown) / top, 0.0, 1.0) if top > 0.0 else 0.0
	return deg_to_rad(START_DEG + SWEEP_DEG * f)


func _draw() -> void:
	var font := get_theme_default_font()
	var top := scale_top(info)
	var a0 := angle_of(0.0, top)
	var end := angle_of(top, top)
	draw_arc(CENTRE, RADIUS, a0, end, 64, Color(0, 0, 0, 0.55), ARC_W + 6.0)   # a dark rim: readable on any sky
	if info.safe > 0:
		var a_safe := angle_of(info.shown(info.safe), top)
		var a_top := angle_of(info.shown(info.top), top)
		draw_arc(CENTRE, RADIUS, a0, a_safe, 48, BAND_COLORS[0], ARC_W)
		if a_top > a_safe:
			draw_arc(CENTRE, RADIUS, a_safe, a_top, 24, BAND_COLORS[1], ARC_W)
		draw_arc(CENTRE, RADIUS, a_top, end, 24, BAND_COLORS[2], ARC_W)
	else:
		draw_arc(CENTRE, RADIUS, a0, end, 64, UNKNOWN_COLOR, ARC_W)
	var step := tick_step(top)
	var n := roundi(top / step)
	for i in n + 1:
		var a := angle_of(i * step, top)
		var dir := Vector2.from_angle(a)
		draw_line(CENTRE + dir * (RADIUS - ARC_W), CENTRE + dir * (RADIUS + ARC_W * 0.5), Color.WHITE, 2.0)
		if i % 2 == 0 or n <= 5:
			var label := str(roundi(i * step))
			var at := CENTRE + dir * (RADIUS - 20.0) + Vector2(-font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 11).x / 2.0, 4.0)
			draw_string_outline(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color.BLACK)
			draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.9, 0.9, 0.9))
	if info.driver:   # the throttle / cruise setting: a wedge outside the dial
		var c := angle_of(info.shown(info.cruise), top)
		var col := CRUISE_COLOR if info.cruise_on else CRUISE_COLOR.darkened(0.45)
		var tip := CENTRE + Vector2.from_angle(c) * (RADIUS + ARC_W * 0.5)
		var side := Vector2.from_angle(c + PI / 2.0) * 5.0
		var out := Vector2.from_angle(c) * 10.0
		draw_colored_polygon(PackedVector2Array([tip, tip + out + side, tip + out - side]), col)
	var speed := info.shown(info.velocity)
	var needle := Vector2.from_angle(angle_of(speed, top))
	var col_v: Color = BAND_COLORS[info.band(info.velocity)] if info.safe > 0 else Color.WHITE
	draw_line(CENTRE, CENTRE + needle * (RADIUS - 6.0), Color.BLACK, 5.0)
	draw_line(CENTRE, CENTRE + needle * (RADIUS - 6.0), col_v, 3.0)
	draw_circle(CENTRE, 5.0, Color(0.15, 0.15, 0.15))
	var text := "%s%d" % ["R " if info.velocity < 0 else "", roundi(absf(speed))]
	var big := 24
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, big).x
	var at_v := Vector2(CENTRE.x - w / 2.0, CENTRE.y + 36.0)
	draw_string_outline(font, at_v, text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, 4, Color.BLACK)
	draw_string(font, at_v, text, HORIZONTAL_ALIGNMENT_LEFT, -1, big, col_v)
	var uw := font.get_string_size(info.unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var at_u := Vector2(CENTRE.x - uw / 2.0, CENTRE.y + 52.0)
	draw_string_outline(font, at_u, info.unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
	draw_string(font, at_u, info.unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.85, 0.85))
