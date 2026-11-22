class_name RideHud
extends Control
## The flat screen's driving HUD (user via the coordinator, 2026-11-21): while the player is on a vehicle, a speed
## gauge (SpeedGauge) and the vehicle's panel: name, engine, fuel per type, battery, health and mass, steering, and
## a skid warning. A passenger gets the gauge and the panel's name and warning only. main shows it (F1 > HUD >
## "Driving gauge" hides it) and calls place() with what it must keep off; a small window shrinks it to MIN_SCALE.
## VR has its own (lead-vr).

const MARGIN := 12.0
const MIN_SCALE := 0.7
const REF := Vector2(1280, 720)   # full size from this window up
const PANEL_W := 250.0
const BAR_H := 10.0
const STEER_MIN_DEG := 5
const TEXT_COLOR := Color(0.92, 0.92, 0.88)
const DIM_COLOR := Color(0.65, 0.65, 0.62)
const WARN_COLOR := Color(1.0, 0.32, 0.22)
const FUEL_COLOR := Color(0.95, 0.75, 0.3)
const BATTERY_COLOR := Color(0.45, 0.8, 1.0)

var info := RideInfo.new()
var dash: HBoxContainer
var gauge: SpeedGauge
var panel: PanelContainer
var name_label: Label
var engine_label: Label
var steer_label: Label
var health_label: Label
var health_bar: ProgressBar
var warn_label: Label
var battery_label: Label
var battery_bar: ProgressBar
var _fuel_rows: Array[Dictionary] = []   # {label, bar}, one per RideInfo.MAX_FUELS, the unused ones hidden
var _avoid: Array[Rect2] = []


func _init() -> void:
	name = "RideHud"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	dash = HBoxContainer.new()
	dash.name = "Dash"
	dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dash.add_theme_constant_override("separation", 6)
	add_child(dash)
	gauge = SpeedGauge.new()
	gauge.size_flags_vertical = Control.SIZE_SHRINK_END
	dash.add_child(gauge)
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size.x = PANEL_W
	panel.size_flags_vertical = Control.SIZE_SHRINK_END
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.7)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	dash.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	name_label = _label(box, 15, TEXT_COLOR)
	warn_label = _label(box, 16, WARN_COLOR)
	engine_label = _label(box, 13, TEXT_COLOR)
	steer_label = _label(box, 13, DIM_COLOR)
	for i in RideInfo.MAX_FUELS:
		var l := _label(box, 12, TEXT_COLOR)
		_fuel_rows.append({"label": l, "bar": _bar(box, FUEL_COLOR)})
	battery_label = _label(box, 12, TEXT_COLOR)
	battery_bar = _bar(box, BATTERY_COLOR)
	health_label = _label(box, 12, TEXT_COLOR)
	health_bar = _bar(box, Color.WHITE)
	resized.connect(func() -> void: place(_avoid))
	show_ride(info)


func _label(parent: Control, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 3)
	parent.add_child(l)
	return l


func _bar(parent: Control, color: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.custom_minimum_size = Vector2(0, BAR_H)
	b.show_percentage = false
	b.max_value = 1.0
	b.step = 0.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	b.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.6)
	b.add_theme_stylebox_override("background", bg)
	parent.add_child(b)
	return b


## Shows `r` (RideInfo.read of player.ride). Only what the player's seat tells: the driver sees it all.
func show_ride(r: RideInfo) -> void:
	info = r if r != null else RideInfo.new()
	gauge.info = info
	var d := info.driver
	name_label.text = "%s  (%s)" % [info.name if not info.name.is_empty() else "Vehicle",
			"driving" if d else "passenger"]
	warn_label.text = info.warning()
	warn_label.visible = not warn_label.text.is_empty()
	engine_label.visible = d
	engine_label.text = "Engine on" + ("   cruise on" if info.cruise_on else "") if info.engine_on else "Engine off"
	engine_label.add_theme_color_override("font_color", TEXT_COLOR if info.engine_on else DIM_COLOR)
	var st := info.steer()
	steer_label.visible = d and absi(st) >= STEER_MIN_DEG
	steer_label.text = "Steering %d° %s" % [absi(st), "left" if st < 0 else "right"]
	for i in _fuel_rows.size():
		var row: Dictionary = _fuel_rows[i]
		var on := d and i < info.fuels.size()
		(row["label"] as Label).visible = on
		(row["bar"] as ProgressBar).visible = on
		if on:
			var f: Dictionary = info.fuels[i]
			var frac := float(f["left"]) / float(f["cap"])
			(row["label"] as Label).text = "%s  %d%%" % [f["name"], roundi(frac * 100.0)]
			(row["bar"] as ProgressBar).value = frac
	var bat := d and info.battery_cap > 0
	battery_label.visible = bat
	battery_bar.visible = bat
	if bat:
		var bf := float(info.battery_left) / float(info.battery_cap)
		battery_label.text = "Battery  %d%%" % roundi(bf * 100.0)
		battery_bar.value = bf
	var hp := d and info.health >= 0
	health_label.visible = d and (info.health >= 0 or info.mass_kg >= 0)
	health_bar.visible = hp
	var parts := PackedStringArray()
	if info.health >= 0:
		parts.append("Health  %d%%" % info.health)
	if info.mass_kg >= 0:
		parts.append(mass_text(info.mass_kg))
	health_label.text = "   ".join(parts)
	if hp:
		health_bar.value = info.health / 100.0
		var fill := health_bar.get_theme_stylebox("fill") as StyleBoxFlat
		if fill != null:
			fill.bg_color = SpeedGauge.BAND_COLORS[0] if info.health >= 60 else (SpeedGauge.BAND_COLORS[1]
					if info.health >= 30 else SpeedGauge.BAND_COLORS[2])
	dash.reset_size()
	place(_avoid)


## "850 kg", or "1.5 t" from a tonne up.
static func mass_text(kg: int) -> String:
	return "%d kg" % kg if kg < 1000 else "%.1f t" % (kg / 1000.0)


## The scale for a window of `area`: full size from REF up, down to MIN_SCALE.
static func scale_for(area: Vector2) -> float:
	return clampf(minf(area.x / REF.x, area.y / REF.y), MIN_SCALE, 1.0)


## Puts the dash at the bottom, as near the middle as it can without covering `avoid` (screen rects: the hands
## panel, the look line, the HUD's text and left column): left of the hands panel, the middle, or above the hands
## panel on the right; else wherever it covers least.
func place(avoid: Array[Rect2]) -> void:
	_avoid = avoid
	var k := scale_for(size)
	dash.scale = Vector2(k, k)
	dash.reset_size()
	var dim := dash.size * k
	var bottom := size.y - MARGIN - dim.y
	var mid := (size.x - dim.x) / 2.0
	var hands := Rect2()
	for r in avoid:   # the lowest box on the right half: the hands panel
		if r.has_area() and r.get_center().x > size.x / 2.0 and r.end.y > hands.end.y:
			hands = r
	var spots: Array[Vector2] = []
	if hands.has_area():
		spots.append(Vector2(minf(mid, hands.position.x - MARGIN - dim.x), bottom))
	spots.append(Vector2(mid, bottom))
	if hands.has_area():
		spots.append(Vector2(size.x - MARGIN - dim.x, hands.position.y - MARGIN - dim.y))
	var best := Vector2(mid, bottom)
	var least := INF
	for p in spots:
		p = Vector2(clampf(p.x, MARGIN, maxf(size.x - MARGIN - dim.x, MARGIN)),
				clampf(p.y, MARGIN, maxf(bottom, MARGIN)))
		var covered := 0.0
		for r in avoid:
			covered += Rect2(global_position + p, dim).intersection(r).get_area()
		if covered < least - 0.5:
			least = covered
			best = p
	dash.position = best
