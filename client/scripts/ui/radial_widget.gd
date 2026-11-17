class_name RadialRequestWidget
extends RequestWidget
## Radial context menu (user, 2026-11-16; TASKS "Radial context menus"): a CDDA menu (an object's examine options:
## a sink's drink / fill / empty / wash) as a wheel of SLOTS fixed slots. An entry goes to the first slot whose
## SLOT_WORDS its label names ("Drink" always at the top, "Fill" at the right...), so the same action sits in the
## same place on every object; the rest fill the free slots in order. Entries CDDA disables are greyed in place.
## The mouse or a stick off the centre highlights a slot; a click, Enter, E or (hold mode) letting go of E picks it;
## 1..8 pick a slot outright, the arrows move to one, Esc cancels. RequestUI shows a request as a wheel only when
## main asked for it (E on an object) and fits() says it can be one; else CDDA's list as before.

const SLOTS := 8
const RADIUS := 150.0
const INNER := 42.0                  # the dead centre: nothing highlighted
## Slot -> the words that put an entry there; slot 0 is the top, then clockwise. Whole words or phrases, lower case.
const SLOT_WORDS := [
	["use", "drink", "eat", "activate", "sit", "read"],
	["light", "turn on", "start", "ignite", "open", "unlock"],
	["fill", "take", "get", "pick", "harvest", "collect", "gather"],
	["turn off", "extinguish", "stop", "close", "lock"],
	["empty", "pour", "drop", "unload", "put", "store", "deposit"],
	["cook", "craft", "make", "boil", "heat", "brew"],
	["wash", "clean", "repair", "fix"],
	["examine", "look", "inspect", "info", "check"],
]
const ARROW_SLOTS := {KEY_UP: 0, KEY_RIGHT: 2, KEY_DOWN: 4, KEY_LEFT: 6}
const COLOR_SLOT := Color(0.16, 0.16, 0.2, 0.92)
const COLOR_EMPTY := Color(0.1, 0.1, 0.12, 0.6)
const COLOR_HOVER := Color(0.33, 0.45, 0.7, 0.95)
const COLOR_TEXT := Color(0.92, 0.92, 0.92)
const COLOR_GREY := Color(0.5, 0.5, 0.5)

## The entry in each slot ({id, label, enabled, description}) or null.
var slots: Array = []
## The highlighted slot, -1 none.
var hovered := -1
## Hold mode: letting go of `release_action` picks the highlighted slot (none highlighted: the wheel stays, as in
## click mode).
var hold := false
var release_action := &"use_held"
var _aim := Vector2.ZERO
var _wheel: Control
var _about: Label


## True when `req` can show as a wheel: a menu with 1..SLOTS entries and no extra actions.
static func fits(req: Dictionary) -> bool:
	if req.get("kind") != "menu" or not actions_of(req).is_empty():
		return false
	var n := entries_of(req).size()
	return n >= 1 and n <= SLOTS


## `entries` (entries_of) in their slots: SLOTS long, null where none.
static func layout(entries: Array) -> Array:
	var out := []
	out.resize(SLOTS)
	var rest := []
	for e: Dictionary in entries.slice(0, SLOTS):
		var s := slot_for(str(e.get("label", "")))
		if s >= 0 and out[s] == null:
			out[s] = e
		else:
			rest.append(e)
	for e: Dictionary in rest:
		var free := out.find(null)
		if free < 0:
			break
		out[free] = e
	return out


## The slot `label`'s words name (SLOT_WORDS), -1 none.
static func slot_for(label: String) -> int:
	var words := " %s " % _words(CddaText.plain(label).to_lower())
	for s in SLOTS:
		for w: String in SLOT_WORDS[s]:
			if words.contains(" %s " % w):
				return s
	return -1


static func _words(text: String) -> String:
	var out := ""
	for ch in text:
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else " "
	return " ".join(out.split(" ", false))


## The slot a point `v` from the centre (screen axes, y down) points at; -1 inside INNER.
static func slot_at(v: Vector2) -> int:
	if not v.is_finite() or v.length() < INNER:
		return -1
	return posmod(roundi(atan2(v.x, -v.y) / (TAU / SLOTS)), SLOTS)


func setup(req: Dictionary) -> void:
	super.setup(req)
	add_header(req)
	slots = layout(entries_of(req))
	_wheel = Control.new()
	_wheel.custom_minimum_size = Vector2.ONE * (RADIUS * 2.0 + 8.0)
	_wheel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel.draw.connect(_draw_wheel)
	add_child(_wheel)
	_about = Label.new()
	_about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_about.custom_minimum_size = Vector2(_wheel.custom_minimum_size.x, 0)
	_about.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_about)
	add_hint("Point at a choice and %s; 1-%d pick, Esc cancels." % [
			"let go of E" if hold else "click or press E", SLOTS])


## Moves the highlight to where `v` (from the centre) points.
func aim(v: Vector2) -> void:
	_aim = v.limit_length(RADIUS) if v.is_finite() else Vector2.ZERO
	_set_hovered(slot_at(_aim))


## Picks slot `s` if it holds an entry CDDA allows; true if it answered.
func pick(s: int) -> bool:
	if s < 0 or s >= slots.size() or slots[s] == null or not slots[s]["enabled"]:
		return false
	send({"entry": slots[s]["id"]})
	return true


## Hold mode's letting go: picks the highlighted slot; nothing highlighted, the wheel stays (click mode from now).
func release() -> bool:
	hold = false
	return pick(hovered)


func handle_input(event: InputEvent) -> bool:
	if done:
		return false
	if event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or not is_inside_tree():
			aim(_aim + m.relative)
		else:
			aim(_wheel.get_local_mouse_position() - _wheel.size * 0.5)
		return true
	if event is InputEventJoypadMotion:
		var j := event as InputEventJoypadMotion
		if j.axis == JOY_AXIS_LEFT_X or j.axis == JOY_AXIS_LEFT_Y or j.axis == JOY_AXIS_RIGHT_X or j.axis == JOY_AXIS_RIGHT_Y:
			var right := j.axis == JOY_AXIS_RIGHT_X or j.axis == JOY_AXIS_RIGHT_Y
			var v := Vector2(Input.get_joy_axis(j.device, JOY_AXIS_RIGHT_X if right else JOY_AXIS_LEFT_X),
					Input.get_joy_axis(j.device, JOY_AXIS_RIGHT_Y if right else JOY_AXIS_LEFT_Y))
			if j.axis == (JOY_AXIS_RIGHT_X if right else JOY_AXIS_LEFT_X):
				v.x = j.axis_value
			else:
				v.y = j.axis_value
			if v.length() >= 0.5:
				aim(v.normalized() * RADIUS)
			return true
		return false
	var is_e := InputMap.has_action(release_action) and event.is_action(release_action)
	if is_e and not event.is_pressed():
		if hold:
			release()
		return true   # E's own release: ours either way
	if event is InputEventMouseButton and event.is_pressed() \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		pick(hovered)
		return true
	if not event is InputEventKey or not event.is_pressed() or (event as InputEventKey).echo:
		return is_e   # E held down repeats: ours too
	var k := event as InputEventKey
	var code := k.keycode if k.keycode != KEY_NONE else k.physical_keycode
	if code >= KEY_1 and code < KEY_1 + SLOTS:
		pick(code - KEY_1)
		return true
	if ARROW_SLOTS.has(code):
		_set_hovered(ARROW_SLOTS[code])
		_aim = Vector2.UP.rotated(hovered * TAU / SLOTS) * RADIUS * 0.6
		return true
	if code == KEY_ENTER or code == KEY_KP_ENTER or is_e:
		pick(hovered)
		return true
	if code == KEY_ESCAPE:
		cancel()
		return true
	return false


func _set_hovered(s: int) -> void:
	if s == hovered:
		return
	hovered = s
	if _about != null:
		var e: Variant = slots[s] if s >= 0 and s < slots.size() else null
		_about.text = "" if e == null else CddaText.plain(str(e.get("description", ""))).left(MAX_LABEL)
	if _wheel != null:
		_wheel.queue_redraw()


func _draw_wheel() -> void:
	var c := _wheel.size * 0.5
	var font := ThemeDB.fallback_font
	var step := TAU / SLOTS
	for s in SLOTS:
		var e: Variant = slots[s]
		var mid := -PI / 2.0 + s * step   # 0 at the top, clockwise on screen
		var pts := PackedVector2Array()
		for i in 9:
			var a := mid - step * 0.5 + 0.02 + (step - 0.04) * i / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * RADIUS)
		for i in range(8, -1, -1):
			var a := mid - step * 0.5 + 0.02 + (step - 0.04) * i / 8.0
			pts.append(c + Vector2(cos(a), sin(a)) * INNER)
		var col := COLOR_EMPTY if e == null else (COLOR_HOVER if s == hovered and e["enabled"] else COLOR_SLOT)
		_wheel.draw_colored_polygon(pts, col)
		var at := c + Vector2(cos(mid), sin(mid)) * (INNER + RADIUS) * 0.5
		_wheel.draw_string(font, at + Vector2(-4, -18), str(s + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COLOR_GREY)
		if e != null:
			var text := CddaText.plain(str(e["label"])).left(24)
			var w := 92.0
			_wheel.draw_string(font, at + Vector2(-w * 0.5, 5), text, HORIZONTAL_ALIGNMENT_CENTER, w, 14,
					COLOR_TEXT if e["enabled"] else COLOR_GREY)
