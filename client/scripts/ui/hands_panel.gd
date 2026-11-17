class_name HandsPanel
extends PanelContainer
## Live game: what each hand holds (CddaSim.get_held, contracts/bridge_api.md), bottom right. A container shows
## its liquid, "1.3 / 10.0 L" and a level bar; while a fill runs (ACT_FILL_LIQUID) the bar is highlighted and
## rises turn by turn. The data comes from the bridge: names are capped there, numbers are clamped here.
## Live item tiles: a held item with a live state (its `uid` in the snapshot's item_states, `tile_of`) gets an
## ItemTileView behind its line: fill (its liquid sloshes as you turn and walk), temperature, spoilage, grime; the
## tile's band then shows how full it is and the bar only shows while a fill runs.

const FILL_ACTIVITY := "ACT_FILL_LIQUID"
const MAX_NAME := 60

const FILL_COLOR := Color(1.0, 0.75, 0.2)     # a fill running
const LEVEL_COLOR := Color(0.45, 0.7, 1.0)    # just showing how full

## uid -> ItemTile ({} for none): main gives ItemTile.for_item on the newest snapshot; unset, no tiles.
var tile_of := Callable()

## per hand: {label: Label, bar: ProgressBar, fill: StyleBoxFlat, box: MarginContainer, tile: ItemTileView or null,
## uid: int, shown: the ItemTile drawn}
var _rows: Array[Dictionary] = []
var _title: Label
## Left-handed (HudSettings.main_hand, set by main.gd): the main hand shows as Left, the off hand as Right.
var left_handed := false:
	set(v):
		if v == left_handed:
			return
		left_handed = v
		if not _last.is_empty():
			show_held(_last)
var _last := {}   # the last get_held() result shown


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
		var line := MarginContainer.new()   # the tile, when there is one, behind the label
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(line)
		var label := Label.new()
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		line.add_child(label)
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 14)
		bar.show_percentage = false
		var fill := StyleBoxFlat.new()
		fill.bg_color = LEVEL_COLOR
		bar.add_theme_stylebox_override("fill", fill)
		box.add_child(bar)
		_rows.append({"label": label, "bar": bar, "fill": fill, "box": line, "tile": null, "uid": 0, "shown": {}})


## One get_held() result: {seq, turn, main: {}, off: {}, activity}. A hand is {} when empty.
func show_held(held: Dictionary) -> void:
	var main: Dictionary = held.get("main", {}) if held.get("main") is Dictionary else {}
	var off: Dictionary = held.get("off", {}) if held.get("off") is Dictionary else {}
	var filling := str(held.get("activity", "")) == FILL_ACTIVITY
	visible = not main.is_empty() or not off.is_empty()
	_title.visible = filling
	_last = held
	var hands := [["Left", main], ["Right", off]] if left_handed else [["Left", off], ["Right", main]]
	for i in 2:
		var hand: Dictionary = hands[i][1]
		var label: Label = _rows[i]["label"]
		label.text = hand_text(hands[i][0], hand)
		(_rows[i]["fill"] as StyleBoxFlat).bg_color = FILL_COLOR if filling else LEVEL_COLOR
	refresh_tiles()


## Puts each hand's tile from `tile_of` (call it on each snapshot: the states change with it); a tile is only
## replaced when its item or what it shows changed, so a sloshing surface keeps going.
func refresh_tiles() -> void:
	if _last.is_empty():
		return
	var main: Dictionary = _last.get("main", {}) if _last.get("main") is Dictionary else {}
	var off: Dictionary = _last.get("off", {}) if _last.get("off") is Dictionary else {}
	var filling := str(_last.get("activity", "")) == FILL_ACTIVITY
	var hands := [main, off] if left_handed else [off, main]
	for i in 2:
		var hand: Dictionary = hands[i]
		var row := _rows[i]
		var uid := uid_of(hand)
		var t: Dictionary = {}
		if uid > 0 and tile_of.is_valid():
			var got: Variant = tile_of.call(uid)
			t = got if got is Dictionary else {}
		if uid != row["uid"] or t != row["shown"]:
			var old: ItemTileView = row["tile"]
			var surface: Slosh = old.slosh if old != null and old.uid == uid else null   # the same item: it goes on
			if old != null:
				row["box"].remove_child(old)
				old.queue_free()
			row["tile"] = null
			if not t.is_empty():
				var tv := ItemTileView.new(t, 0.0, uid)
				if surface != null and tv.slosh != null:
					tv.slosh = surface
				row["box"].add_child(tv)
				row["box"].move_child(tv, 0)   # behind the label
				row["tile"] = tv
			row["uid"] = uid
			row["shown"] = t
		var ratio := fill_ratio(hand)
		var bar: ProgressBar = row["bar"]
		bar.visible = ratio >= 0.0 and (filling or float(t.get("level", -1.0)) < 0.0)
		bar.value = maxf(ratio, 0.0) * 100.0


## A get_held() hand's item uid (its handle in the snapshot), 0 when none: an empty hand, an older bridge, an item
## with no handle yet, or anything but a whole number above 0.
static func uid_of(hand: Dictionary) -> int:
	var v: Variant = hand.get("uid")
	if not (v is int or v is float) or not is_finite(float(v)) or float(v) != floorf(float(v)) or float(v) <= 0.0 \
			or float(v) > float(1 << 62):
		return 0
	return int(v)


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
