class_name HandsPanel
extends PanelContainer
## Live game: what each hand holds (CddaSim.get_held, contracts/bridge_api.md), bottom right. A container shows
## its liquid, "1.3 / 10.0 L" and a level bar; while a fill runs (ACT_FILL_LIQUID) the bar is highlighted and
## rises turn by turn. The data comes from the bridge: names are capped there, numbers are clamped here.

const FILL_ACTIVITY := "ACT_FILL_LIQUID"
const MAX_NAME := 60

const FILL_COLOR := Color(1.0, 0.75, 0.2)     # a fill running
const LEVEL_COLOR := Color(0.45, 0.7, 1.0)    # just showing how full

var _rows: Array[Dictionary] = []   # per hand: {label: Label, bar: ProgressBar, fill: StyleBoxFlat}
var _title: Label


func _init() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_right = -10
	offset_bottom = -10
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(400, 0)
	add_child(box)
	_title = Label.new()
	_title.text = "Filling..."
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	box.add_child(_title)
	for i in 2:
		var label := Label.new()
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		box.add_child(label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 14)
		bar.show_percentage = false
		var fill := StyleBoxFlat.new()
		fill.bg_color = LEVEL_COLOR
		bar.add_theme_stylebox_override("fill", fill)
		box.add_child(bar)
		_rows.append({"label": label, "bar": bar, "fill": fill})


## One get_held() result: {seq, turn, main: {}, off: {}, activity}. A hand is {} when empty.
func show_held(held: Dictionary) -> void:
	var main: Dictionary = held.get("main", {}) if held.get("main") is Dictionary else {}
	var off: Dictionary = held.get("off", {}) if held.get("off") is Dictionary else {}
	var filling := str(held.get("activity", "")) == FILL_ACTIVITY
	visible = not main.is_empty() or not off.is_empty()
	_title.visible = filling
	var hands := [["Left", off], ["Right", main]]
	for i in 2:
		var hand: Dictionary = hands[i][1]
		var label: Label = _rows[i]["label"]
		var bar: ProgressBar = _rows[i]["bar"]
		label.text = hand_text(hands[i][0], hand)
		var ratio := fill_ratio(hand)
		bar.visible = ratio >= 0.0
		bar.value = maxf(ratio, 0.0) * 100.0
		(_rows[i]["fill"] as StyleBoxFlat).bg_color = FILL_COLOR if filling else LEVEL_COLOR


## "Left: plastic jerrycan - gasoline 1.3 / 10.0 L", "Right: rubber hose", "Left: -".
static func hand_text(side: String, hand: Dictionary) -> String:
	if hand.is_empty():
		return "%s: -" % side
	var text := "%s: %s" % [side, str(hand.get("name", "?")).left(MAX_NAME)]
	var cap := _num(hand.get("capacity_ml"))
	if cap > 0:
		var ml := clampi(_num(hand.get("ml")), 0, cap)
		var liquid := str(hand.get("liquid", "")).left(MAX_NAME)
		text += " - %s%.1f / %.1f L" % [liquid + " " if liquid != "" else "", ml / 1000.0, cap / 1000.0]
	return text


## How full a container is, 0..1; -1 when the hand holds no container.
static func fill_ratio(hand: Dictionary) -> float:
	var cap := _num(hand.get("capacity_ml"))
	if hand.is_empty() or cap <= 0:
		return -1.0
	return clampf(float(_num(hand.get("ml"))) / cap, 0.0, 1.0)


static func _num(v: Variant) -> int:
	return int(v) if v is int or v is float else 0
