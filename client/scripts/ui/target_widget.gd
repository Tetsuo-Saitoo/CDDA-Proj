class_name TargetRequestWidget
extends RequestWidget
## `target` requests (look_around, target_ui): a cursor square, the creatures in view and CDDA's actions.
## Keys: arrows / numpad move the cursor (relative to the screen), < > change level, Tab / Shift+Tab next /
## previous creature, Enter = the main action (FIRE, else CONFIRM or SELECT, else the first), Space checks
## the square (CDDA asks again with a new status), 1-9 press an action, Esc cancels. Mouse: click a creature,
## then an action. `set_cursor` lets the 3D view pick a square (block E2).
## Answer: `pos` (absolute square) with or without `action`.

const REACH := 132          # the cursor stays within a bubble's width of the origin
const MAX_ROWS := 64
const MAX_CANDIDATES := 256
const COORD_LIMIT := (1 << 28) - REACH - 1
const PRIMARY := ["FIRE", "CONFIRM", "SELECT"]
const STATUS_TEXT := {
	"bad_target": "No valid target there", "out_of_ammo": "Out of ammo", "out_of_range": "Out of range",
}

var mode := ""
var origin := Vector3i.ZERO
var cursor := Vector3i.ZERO
var range_limit := 0
var candidates: Array[Vector3i] = []   # nearest first
var actions := PackedStringArray()
var action_buttons: Array[Button] = []
var candidate_buttons: Array[Button] = []
var _cursor_label: RichTextLabel
var _candidate := -1


func setup(req: Dictionary) -> void:
	super(req)
	mode = str_of(req, "mode", 32)
	var o := vec_of(req, "origin")
	origin = Vector3i(clampi(o.x, -COORD_LIMIT, COORD_LIMIT), clampi(o.y, -COORD_LIMIT, COORD_LIMIT),
			clampi(o.z, -10, 10))
	cursor = _clamp(vec_of(req, "cursor"))
	range_limit = int_of(req, "range", 0, 0, 1000000)
	actions = actions_of(req)
	var list: Variant = req.get("candidates")
	if list is Array:
		for c: Variant in list:
			if candidates.size() >= MAX_CANDIDATES:
				break
			if c is Vector3i and c == _clamp(c) and not candidates.has(c):
				candidates.append(c)
	candidates.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return _dist(a) < _dist(b))

	if CddaText.plain(str_of(req, "title")).strip_edges().is_empty():
		var t := add_rich("<color_white>%s</color>" % (mode.capitalize() if not mode.is_empty() else "Target"))
		t.add_theme_font_size_override("normal_font_size", 18)
	add_header(req)
	var status := str_of(req, "status", 64)
	if not status.is_empty():
		add_rich("<color_light_red>%s</color>" % STATUS_TEXT.get(status, status))
	_cursor_label = add_rich("")
	if not candidates.is_empty():
		var l := Label.new()
		l.text = "In view (Tab):"
		add_child(l)
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.custom_minimum_size.y = minf(candidates.size(), 5) * 36.0
		add_child(scroll)
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(box)
		for i in mini(candidates.size(), MAX_ROWS):
			var d := candidates[i] - origin
			var b := add_button("%s   (%d)" % [offset_text(d), _dist(candidates[i])], pick_candidate.bind(i), box)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			candidate_buttons.append(b)
	var bar := HFlowContainer.new()
	add_child(bar)
	for i in actions.size():
		var label := action_label(actions[i])
		if i < 9:
			label = "%d  %s" % [i + 1, label]
		action_buttons.append(add_button(label, press.bind(i), bar))
	add_button("Check square (Space)", check, bar)
	if allow_cancel:
		add_button("Cancel (Esc)", cancel, bar)
	add_hint("Arrows / numpad: cursor  < > level  Tab next  Enter %s  Space check%s" % [
			action_label(actions[primary_index()]) if primary_index() >= 0 else "check",
			"  Esc cancel" if allow_cancel else ""])
	_update_cursor()


## Moves the cursor (clamped near the origin) without answering.
func set_cursor(p: Vector3i) -> void:
	cursor = _clamp(p)
	_candidate = candidates.find(cursor)
	_update_cursor()


func move_cursor(step: Vector3i) -> void:
	set_cursor(cursor + step)


func pick_candidate(i: int) -> void:
	if i >= 0 and i < candidates.size():
		set_cursor(candidates[i])


func next_candidate(delta: int) -> void:
	if not candidates.is_empty():
		pick_candidate(wrapi((_candidate if _candidate >= 0 else (-1 if delta > 0 else 0)) + delta, 0,
				candidates.size()))


func press(i: int) -> void:
	if i >= 0 and i < actions.size():
		send({"pos": cursor, "action": actions[i]})


## Sends the cursor square without an action; CDDA moves its cursor there and asks again.
func check() -> void:
	send({"pos": cursor})


func primary_index() -> int:
	for a: String in PRIMARY:
		if actions.has(a):
			return actions.find(a)
	return 0 if not actions.is_empty() else -1


## "3 E, 2 N, 1 up" for a relative square (CDDA's y points south).
static func offset_text(d: Vector3i) -> String:
	var parts := PackedStringArray()
	if d.y != 0:
		parts.append("%d %s" % [absi(d.y), "N" if d.y < 0 else "S"])
	if d.x != 0:
		parts.append("%d %s" % [absi(d.x), "E" if d.x > 0 else "W"])
	if d.z != 0:
		parts.append("%d %s" % [absi(d.z), "up" if d.z > 0 else "down"])
	return ", ".join(parts) if not parts.is_empty() else "here"


func handle_input(event: InputEvent) -> bool:
	var key := key_of(event, true)
	if key == KEY_NONE:
		return false
	var k := event as InputEventKey
	var c := char_of(event)
	if c == "<" or c == ">":
		move_cursor(Vector3i(0, 0, 1 if c == "<" else -1))
	elif MOVE_KEYS.has(key):
		var s := map_step(MOVE_KEYS[key])
		move_cursor(Vector3i(s.x, s.y, 0))
	elif key == KEY_TAB:
		if not k.echo:
			next_candidate(-1 if k.shift_pressed else 1)
	elif key == KEY_ENTER or key == KEY_KP_ENTER:
		if not k.echo:
			var p := primary_index()
			if p >= 0:
				press(p)
			else:
				check()
	elif key == KEY_SPACE:
		if not k.echo:
			check()
	elif key == KEY_ESCAPE:
		if not k.echo:
			cancel()
	elif key >= KEY_1 and key <= KEY_9:
		if not k.echo:
			press(key - KEY_1)
	else:
		return false
	return true


func _clamp(p: Vector3i) -> Vector3i:
	return Vector3i(clampi(p.x, origin.x - REACH, origin.x + REACH), clampi(p.y, origin.y - REACH, origin.y + REACH),
			clampi(p.z, -10, 10))


func _dist(p: Vector3i) -> int:
	return maxi(absi(p.x - origin.x), absi(p.y - origin.y))


func _update_cursor() -> void:
	var dist := _dist(cursor)
	var r := ""
	if range_limit > 0:
		r = " / range %d" % range_limit
		if dist > range_limit:
			r += " <color_light_red>(out of range)</color>"
	_cursor_label.text = CddaText.to_bbcode("Cursor: %s, distance %d%s" % [offset_text(cursor - origin), dist, r])
	for i in candidate_buttons.size():
		mark(candidate_buttons[i], candidates[i] == cursor)
